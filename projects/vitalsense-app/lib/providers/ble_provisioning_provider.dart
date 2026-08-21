import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/ble_provisioning_models.dart';
import '../models/wifi_provisioning_status.dart';
import '../services/ble_provisioning_service.dart';
import '../services/udp_service.dart';

/// Explicit state machine coordinating temporary BLE provisioning with the
/// existing, independently-owned UDP packet stream.
class BleProvisioningProvider extends ChangeNotifier {
  final ProvisioningService _service;
  final Stream<VitalSensePacket> _udpPackets;
  final Duration udpDiscoveryTimeout;
  final Duration connectedMessageDuration;

  late final StreamSubscription<List<ProvisioningDevice>> _scanSubscription;
  late final StreamSubscription<ProvisioningStatus> _statusSubscription;
  late final StreamSubscription<BleConnectionPhase> _phaseSubscription;
  StreamSubscription<VitalSensePacket>? _udpSubscription;
  Timer? _wifiTimer;
  Timer? _udpTimer;
  Timer? _connectedMessageTimer;

  ProvisioningState _state = ProvisioningState.idle;
  List<ProvisioningDevice> _devices = const [];
  ProvisioningDevice? _selectedDevice;
  ProvisioningStatus? _lastStatus;
  VitalSensePacket? _pendingUdpPacket;
  String? _errorMessage;
  String? _configuredSsid;
  String? _provisionedIp;
  bool _credentialsSubmissionActive = false;
  bool _expectedBleDisconnect = false;
  bool _disposed = false;

  BleProvisioningProvider({
    required ProvisioningService service,
    required Stream<VitalSensePacket> udpPackets,
    this.udpDiscoveryTimeout = const Duration(seconds: 20),
    this.connectedMessageDuration = const Duration(seconds: 2),
  })  : _service = service,
        _udpPackets = udpPackets {
    _scanSubscription = _service.scanResults.listen(
      (devices) {
        _devices = devices;
        _notify();
      },
      onError: (Object error) => _handleError(error),
    );
    _statusSubscription = _service.statuses.listen(_handleStatus);
    _phaseSubscription = _service.connectionPhases.listen(_handlePhase);
  }

  ProvisioningState get state => _state;
  List<ProvisioningDevice> get devices => _devices;
  ProvisioningDevice? get selectedDevice => _selectedDevice;
  ProvisioningStatus? get lastStatus => _lastStatus;
  String? get errorMessage => _errorMessage;
  String? get configuredSsid => _configuredSsid;
  String? get provisionedIp => _provisionedIp;

  bool get isBleConnected => {
        ProvisioningState.readyForCredentials,
        ProvisioningState.sendingCredentials,
        ProvisioningState.connectingWifi,
        ProvisioningState.alreadyConnected,
        ProvisioningState.wifiFailed,
        ProvisioningState.credentialsCleared,
      }.contains(_state);

  Future<void> startScan() async {
    await _stopUdpWait();
    _cancelTimers();
    _devices = const [];
    _selectedDevice = null;
    _lastStatus = null;
    _errorMessage = null;
    _pendingUdpPacket = null;
    _credentialsSubmissionActive = false;
    _expectedBleDisconnect = false;
    _setState(ProvisioningState.scanning);
    try {
      await _service.scan();
      if (_state == ProvisioningState.scanning && _devices.isEmpty) {
        _setState(ProvisioningState.noDevicesFound);
      }
    } catch (error) {
      _handleError(error);
    }
  }

  Future<void> connect(ProvisioningDevice device) async {
    _selectedDevice = device;
    _errorMessage = null;
    _expectedBleDisconnect = false;
    _setState(ProvisioningState.connectingBle);
    try {
      await _service.connect(device);
    } catch (error) {
      _handleError(error);
    }
  }

  Future<void> reconnectSelectedDevice() async {
    final device = _selectedDevice;
    if (device == null) {
      await startScan();
      return;
    }
    await connect(device);
  }

  Future<void> submitCredentials({
    required String ssid,
    required String password,
  }) async {
    final normalizedSsid = ssid.trim();
    if (normalizedSsid.isEmpty || _credentialsSubmissionActive) return;

    _credentialsSubmissionActive = true;
    _errorMessage = null;
    _configuredSsid = normalizedSsid;
    _setState(ProvisioningState.sendingCredentials);
    try {
      // The password is intentionally neither retained on this provider nor
      // logged. It exists only for this awaited transport operation.
      await _service.sendCredentials(
        ssid: normalizedSsid,
        password: password,
      );
      if (_state != ProvisioningState.wifiConnected &&
          _state != ProvisioningState.waitingForUdp &&
          _state != ProvisioningState.completed) {
        _setState(ProvisioningState.connectingWifi);
      }
      _wifiTimer?.cancel();
      _wifiTimer = Timer(const Duration(seconds: 45), () {
        if (_state == ProvisioningState.connectingWifi) {
          _errorMessage =
              'VitalSense did not finish joining Wi-Fi. Check the network and try again.';
          _setState(ProvisioningState.wifiFailed);
        }
      });
    } catch (error) {
      _handleError(error, wifiFailure: true);
    } finally {
      _credentialsSubmissionActive = false;
    }
  }

  void retryCredentials() {
    _wifiTimer?.cancel();
    _errorMessage = null;
    if (isBleConnected) {
      _setState(ProvisioningState.readyForCredentials);
    } else {
      _setState(ProvisioningState.bleDisconnected);
    }
  }

  void changeWifi() {
    _errorMessage = null;
    _setState(ProvisioningState.readyForCredentials);
  }

  Future<void> forgetCredentials() async {
    _errorMessage = null;
    try {
      await _service.clearCredentials();
      _configuredSsid = null;
      _provisionedIp = null;
      _setState(ProvisioningState.credentialsCleared);
    } catch (error) {
      _handleError(error);
    }
  }

  void credentialsClearedAcknowledged() {
    _setState(ProvisioningState.readyForCredentials);
  }

  Future<void> enableBluetoothAndScan() async {
    try {
      await _service.enableBluetooth();
      await startScan();
    } catch (error) {
      _handleError(error);
    }
  }

  Future<void> openPermissionsSettings() {
    return _service.openPermissionsSettings();
  }

  Future<void> continueToDashboard() async {
    _expectedBleDisconnect = true;
    await _service.disconnect();
    _setState(ProvisioningState.completed);
  }

  Future<void> keepListening() async {
    _errorMessage = null;
    _setState(ProvisioningState.waitingForUdp);
    _startUdpTimer();
  }

  Future<void> cancelSetup() async {
    _cancelTimers();
    await _stopUdpWait();
    _expectedBleDisconnect = true;
    await _service.disconnect();
    _selectedDevice = null;
    _devices = const [];
    _lastStatus = null;
    _errorMessage = null;
    _setState(ProvisioningState.idle);
  }

  void _handlePhase(BleConnectionPhase phase) {
    switch (phase) {
      case BleConnectionPhase.connecting:
        _setState(ProvisioningState.connectingBle);
      case BleConnectionPhase.discoveringServices:
        _setState(ProvisioningState.discoveringServices);
      case BleConnectionPhase.ready:
        if (_state != ProvisioningState.alreadyConnected) {
          _setState(ProvisioningState.readyForCredentials);
        }
      case BleConnectionPhase.disconnected:
        if (!_expectedBleDisconnect &&
            _state != ProvisioningState.idle &&
            _state != ProvisioningState.scanning) {
          _wifiTimer?.cancel();
          _errorMessage = 'The connection to VitalSense was interrupted.';
          _setState(ProvisioningState.bleDisconnected);
        }
    }
  }

  void _handleStatus(ProvisioningStatus status) {
    _lastStatus = status;
    switch (status.type) {
      case ProvisioningStatusType.noCredentials:
        if (_state != ProvisioningState.credentialsCleared) {
          _setState(ProvisioningState.readyForCredentials);
        }
      case ProvisioningStatusType.ssidReceived:
      case ProvisioningStatusType.passwordReceived:
        _notify();
      case ProvisioningStatusType.connecting:
        _configuredSsid = status.ssid ?? _configuredSsid;
        _setState(ProvisioningState.connectingWifi);
      case ProvisioningStatusType.connected:
        _configuredSsid = status.ssid;
        _provisionedIp = status.ipAddress;
        if (_credentialsSubmissionActive ||
            _state == ProvisioningState.sendingCredentials ||
            _state == ProvisioningState.connectingWifi) {
          _onWifiConnected();
        } else {
          _setState(ProvisioningState.alreadyConnected);
        }
      case ProvisioningStatusType.failed:
        _wifiTimer?.cancel();
        _errorMessage = status.reason == 'CHECK_SSID_PASSWORD'
            ? 'VitalSense could not connect. Check the Wi-Fi name, password, and signal strength.'
            : 'VitalSense could not connect to the selected Wi-Fi network.';
        _setState(ProvisioningState.wifiFailed);
      case ProvisioningStatusType.disconnected:
        _configuredSsid = status.ssid ?? _configuredSsid;
        _errorMessage = 'VitalSense is not connected to Wi-Fi.';
        _setState(ProvisioningState.readyForCredentials);
      case ProvisioningStatusType.malformed:
        _errorMessage = status.reason ??
            'VitalSense returned an unexpected setup response.';
        if (_state == ProvisioningState.connectingWifi) {
          _setState(ProvisioningState.wifiFailed);
        } else {
          _notify();
        }
    }
  }

  void _onWifiConnected() {
    _wifiTimer?.cancel();
    debugPrint('Wi-Fi connected');
    _setState(ProvisioningState.wifiConnected);
    _listenForUdpPackets();
    _connectedMessageTimer?.cancel();
    _connectedMessageTimer = Timer(connectedMessageDuration, () async {
      _expectedBleDisconnect = true;
      await _service.disconnect();
      if (_pendingUdpPacket != null) {
        _completeWithUdpPacket();
      } else if (_state == ProvisioningState.wifiConnected) {
        _setState(ProvisioningState.waitingForUdp);
        _startUdpTimer();
      }
    });
  }

  void _listenForUdpPackets() {
    _udpSubscription?.cancel();
    _udpSubscription = _udpPackets.listen((packet) {
      if (!_matchesProvisionedDevice(packet)) return;
      debugPrint('UDP packet received');
      _pendingUdpPacket = packet;
      if (_state == ProvisioningState.waitingForUdp ||
          _state == ProvisioningState.udpTimedOut) {
        _completeWithUdpPacket();
      }
    });
  }

  bool _matchesProvisionedDevice(VitalSensePacket packet) {
    final expectedIp = _provisionedIp;
    if (expectedIp != null && expectedIp.isNotEmpty) {
      return packet.sourceIp == expectedIp;
    }
    final advertisedName = _selectedDevice?.name;
    if (advertisedName != null && advertisedName.startsWith('VS-')) {
      return packet.data.deviceId == advertisedName;
    }
    return true;
  }

  void _completeWithUdpPacket() {
    _udpTimer?.cancel();
    _setState(ProvisioningState.completed);
  }

  void _startUdpTimer() {
    _udpTimer?.cancel();
    _udpTimer = Timer(udpDiscoveryTimeout, () {
      if (_state == ProvisioningState.waitingForUdp) {
        _setState(ProvisioningState.udpTimedOut);
      }
    });
  }

  void _handleError(Object error, {bool wifiFailure = false}) {
    final exception = error is ProvisioningException
        ? error
        : const ProvisioningException(
            ProvisioningErrorCode.unknown,
            'Something went wrong while setting up VitalSense.',
          );
    _errorMessage = exception.message;
    switch (exception.code) {
      case ProvisioningErrorCode.bluetoothUnsupported:
        _setState(ProvisioningState.bluetoothUnsupported);
      case ProvisioningErrorCode.bluetoothDisabled:
        _setState(ProvisioningState.bluetoothDisabled);
      case ProvisioningErrorCode.permissionDenied:
        _setState(ProvisioningState.permissionDenied);
      case ProvisioningErrorCode.disconnected:
        _setState(ProvisioningState.bleDisconnected);
      case ProvisioningErrorCode.ssidWriteFailed:
      case ProvisioningErrorCode.passwordWriteFailed:
      case ProvisioningErrorCode.commandWriteFailed:
        _setState(
          wifiFailure ? ProvisioningState.wifiFailed : ProvisioningState.error,
        );
      case ProvisioningErrorCode.connectionTimeout:
      case ProvisioningErrorCode.serviceNotFound:
      case ProvisioningErrorCode.characteristicNotFound:
      case ProvisioningErrorCode.malformedResponse:
      case ProvisioningErrorCode.unknown:
        _setState(ProvisioningState.error);
    }
  }

  Future<void> _stopUdpWait() async {
    _udpTimer?.cancel();
    _udpTimer = null;
    await _udpSubscription?.cancel();
    _udpSubscription = null;
  }

  void _cancelTimers() {
    _wifiTimer?.cancel();
    _udpTimer?.cancel();
    _connectedMessageTimer?.cancel();
  }

  void _setState(ProvisioningState state) {
    _state = state;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelTimers();
    _scanSubscription.cancel();
    _statusSubscription.cancel();
    _phaseSubscription.cancel();
    _udpSubscription?.cancel();
    _service.dispose();
    super.dispose();
  }
}
