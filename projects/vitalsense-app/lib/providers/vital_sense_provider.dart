import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/vital_sense_data.dart';
import '../services/udp_service.dart';

/// Connection state of a VitalSense device.
enum ConnectionStatus { discovering, live, stale, offline }

/// State container for a single discovered VitalSense device.
class DeviceState {
  final VitalSenseData data;
  final DateTime lastPacketAt;
  final ConnectionStatus connectionStatus;
  final String sourceIp;

  const DeviceState({
    required this.data,
    required this.lastPacketAt,
    required this.connectionStatus,
    required this.sourceIp,
  });

  DeviceState copyWith({
    VitalSenseData? data,
    DateTime? lastPacketAt,
    ConnectionStatus? connectionStatus,
    String? sourceIp,
  }) {
    return DeviceState(
      data: data ?? this.data,
      lastPacketAt: lastPacketAt ?? this.lastPacketAt,
      connectionStatus: connectionStatus ?? this.connectionStatus,
      sourceIp: sourceIp ?? this.sourceIp,
    );
  }
}

/// Provider that manages UDP reception and device state for all discovered
/// VitalSense beds.
class VitalSenseProvider extends ChangeNotifier {
  final UdpService _udpService = UdpService();
  StreamSubscription<VitalSensePacket>? _dataSub;
  StreamSubscription<String>? _errorSub;
  Timer? _statusTimer;

  /// Map of deviceId -> DeviceState
  final Map<String, DeviceState> _devices = {};

  /// Currently selected device ID (for single-bed focus view).
  String? _selectedDeviceId;

  List<DeviceState> get devices => _devices.values.toList();

  DeviceState? get selectedDevice {
    if (_selectedDeviceId != null && _devices.containsKey(_selectedDeviceId)) {
      return _devices[_selectedDeviceId!];
    }
    // Auto-select first device
    if (_devices.isNotEmpty) {
      return _devices.values.first;
    }
    return null;
  }

  bool get hasDevices => _devices.isNotEmpty;

  String? _lastError;
  String? get lastError => _lastError;

  VitalSenseProvider() {
    _init();
  }

  Future<void> _init() async {
    try {
      await _udpService.start();
    } catch (e) {
      debugPrint('VitalSenseProvider: Failed to start UDP service: $e');
      _lastError = 'Failed to start UDP service: $e';
      notifyListeners();
    }

    _dataSub = _udpService.dataStream.listen(_onPacket);
    _errorSub = _udpService.errorStream.listen((err) {
      _lastError = err;
      notifyListeners();
    });

    // Poll every second to update connection status
    _statusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateConnectionStatuses();
    });
  }

  void _onPacket(VitalSensePacket packet) {
    final now = DateTime.now();

    _devices[packet.data.deviceId] = DeviceState(
      data: packet.data,
      lastPacketAt: now,
      connectionStatus: ConnectionStatus.live,
      sourceIp: packet.sourceIp,
    );

    // Auto-select if first device
    _selectedDeviceId ??= packet.data.deviceId;

    notifyListeners();
  }

  void _updateConnectionStatuses() {
    final now = DateTime.now();
    bool changed = false;

    // Iterate over a snapshot to avoid ConcurrentModificationError
    final entries = _devices.entries.toList();
    for (final entry in entries) {
      final age = now.difference(entry.value.lastPacketAt).inSeconds;
      ConnectionStatus newStatus;

      if (age <= 3) {
        newStatus = ConnectionStatus.live;
      } else if (age <= 10) {
        newStatus = ConnectionStatus.stale;
      } else {
        newStatus = ConnectionStatus.offline;
      }

      if (newStatus != entry.value.connectionStatus) {
        _devices[entry.key] = entry.value.copyWith(
          connectionStatus: newStatus,
        );
        changed = true;
      }
    }

    if (changed) notifyListeners();
  }

  void selectDevice(String deviceId) {
    _selectedDeviceId = deviceId;
    notifyListeners();
  }

  Future<void> reconnect() async {
    _lastError = null;
    _devices.clear();
    _selectedDeviceId = null;
    notifyListeners();

    _dataSub?.cancel();
    _errorSub?.cancel();
    _statusTimer?.cancel();
    _udpService.dispose();

    try {
      await _udpService.start();
      _dataSub = _udpService.dataStream.listen(_onPacket);
      _errorSub = _udpService.errorStream.listen((err) {
        _lastError = err;
        notifyListeners();
      });
      _statusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        _updateConnectionStatuses();
      });
    } catch (e) {
      debugPrint('VitalSenseProvider: Reconnect failed: $e');
      _lastError = 'Reconnect failed: $e';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _dataSub?.cancel();
    _errorSub?.cancel();
    _statusTimer?.cancel();
    _udpService.dispose();
    super.dispose();
  }
}

