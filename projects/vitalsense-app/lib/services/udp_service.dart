import 'dart:io';
import 'dart:convert';
import 'dart:async';
import '../models/vital_sense_data.dart';

/// A parsed VitalSense packet paired with the source IP address.
typedef VitalSensePacket = ({VitalSenseData data, String sourceIp});

/// UDP service that listens on port 5005 for VitalSense Protocol v1 broadcasts.
class UdpService {
  static const int _udpPort = 5005;
  RawDatagramSocket? _socket;
  final StreamController<VitalSensePacket> _controller =
      StreamController<VitalSensePacket>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();

  Stream<VitalSensePacket> get dataStream => _controller.stream;
  Stream<String> get errorStream => _errorController.stream;

  bool _isListening = false;
  bool get isListening => _isListening;

  /// Starts listening for UDP broadcasts on 0.0.0.0:5005.
  Future<void> start() async {
    if (_isListening) return;
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _udpPort,
        reuseAddress: true,
        reusePort: false,
      );
      _socket!.broadcastEnabled = true;
      _isListening = true;

      _socket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = _socket!.receive();
          if (datagram == null) return;
          _processPacket(datagram.data, datagram.address.address);
        }
      }, onError: (error) {
        _errorController.add('Socket error: $error');
      }, onDone: () {
        _isListening = false;
      });
    } on SocketException catch (e) {
      // Handle platform-specific bind failures (e.g. reusePort not supported)
      _isListening = false;
      _errorController.add('Failed to bind UDP socket: $e');
    } catch (e) {
      _isListening = false;
      _errorController.add('Failed to bind UDP socket: $e');
    }
  }

  void _processPacket(List<int> data, String sourceIp) {
    try {
      final payload = utf8.decode(data);
      final json = jsonDecode(payload) as Map<String, dynamic>;

      if (!VitalSenseData.isValid(json)) {
        _errorController.add('Invalid or unsupported packet from $sourceIp');
        return;
      }

      final packet = VitalSenseData.fromJson(json);
      _controller.add((data: packet, sourceIp: sourceIp));
    } on FormatException {
      _errorController.add('Non-UTF8 packet from $sourceIp');
    } on TypeError catch (e) {
      _errorController.add('Malformed JSON structure from $sourceIp: $e');
    } catch (e) {
      _errorController.add('Packet error from $sourceIp: $e');
    }
  }

  /// Stops listening and releases the socket.
  void stop() {
    _socket?.close();
    _socket = null;
    _isListening = false;
  }

  void dispose() {
    stop();
    _controller.close();
    _errorController.close();
  }
}

