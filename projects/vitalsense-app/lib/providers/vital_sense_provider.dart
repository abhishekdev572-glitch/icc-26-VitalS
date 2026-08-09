import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import '../models/vital_sense_data.dart';
import '../services/udp_service.dart';
import '../services/notification_service.dart';
import '../services/background_service.dart';
import '../screens/logs_screen.dart';

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
  UdpService _udpService = UdpService();
  final NotificationService _notificationService = NotificationService();
  final BackgroundService _backgroundService = BackgroundService.instance;
  StreamSubscription<VitalSensePacket>? _dataSub;
  StreamSubscription<String>? _errorSub;
  Timer? _statusTimer;

  /// Map of deviceId -> DeviceState
  final Map<String, DeviceState> _devices = {};

  /// Currently selected device ID (for single-bed focus view).
  String? _selectedDeviceId;

  bool _backgroundMonitoringActive = false;
  bool _notificationsEnabled = true;

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
  bool get backgroundMonitoringActive => _backgroundMonitoringActive;
  bool get notificationsEnabled => _notificationsEnabled;

  String? _lastError;
  String? get lastError => _lastError;

  VitalSenseProvider() {
    _init();
  }

  Future<void> _init() async {
    await _notificationService.initialize();
    await _backgroundService.initialize();

    try {
      await _udpService.start();
      LogService.logConnection(deviceId: 'system', event: 'UDP listener started', details: 'Port 5005');
    } catch (e) {
      debugPrint('VitalSenseProvider: Failed to start UDP service: $e');
      _lastError = 'Failed to start UDP service: $e';
      LogService.logError(message: 'Failed to start UDP service', details: e.toString());
      notifyListeners();
    }

    _dataSub = _udpService.dataStream.listen(_onPacket);
    _errorSub = _udpService.errorStream.listen((err) {
      _lastError = err;
      LogService.logError(message: 'UDP Error', details: err);
      notifyListeners();
    });

    // Poll every second to update connection status
    _statusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateConnectionStatuses();
    });

    _startBackgroundMonitoring();
  }

  void _startBackgroundMonitoring() {
    if (_backgroundMonitoringActive) return;
    _backgroundMonitoringActive = true;

    _backgroundService.startForegroundMonitoring(
      devices: _devices,
      onReconnectNeeded: () {
        if (_notificationsEnabled) {
          reconnect();
        }
      },
    );
  }

  void _stopBackgroundMonitoring() {
    if (!_backgroundMonitoringActive) return;
    _backgroundMonitoringActive = false;
    _backgroundService.stopForegroundMonitoring();
  }

  void setNotificationsEnabled(bool enabled) {
    _notificationsEnabled = enabled;
    notifyListeners();
    if (!enabled) {
      _notificationService.cancelAll();
    }
  }

  void _onPacket(VitalSensePacket packet) {
    final now = DateTime.now();
    final deviceId = packet.data.deviceId;
    final existingDevice = _devices[deviceId];

    _devices[deviceId] = DeviceState(
      data: packet.data,
      lastPacketAt: now,
      connectionStatus: ConnectionStatus.live,
      sourceIp: packet.sourceIp,
    );

    // Log connection event if new device or reconnected
    if (existingDevice == null) {
      LogService.logConnection(deviceId: deviceId, event: 'Device discovered', details: 'IP: ${packet.sourceIp}');
      if (_notificationsEnabled) {
        _notificationService.showConnectionAlert(
          deviceId: deviceId,
          bedLabel: packet.data.bedLabel,
          event: 'Discovered',
          status: 'LIVE',
        );
      }
    } else if (existingDevice.connectionStatus != ConnectionStatus.live) {
      LogService.logConnection(deviceId: deviceId, event: 'Reconnected', details: 'Was ${existingDevice.connectionStatus.name}');
      if (_notificationsEnabled) {
        _notificationService.showConnectionAlert(
          deviceId: deviceId,
          bedLabel: packet.data.bedLabel,
          event: 'Reconnected',
          status: 'LIVE',
        );
      }
    }

    // Log position change
    if (existingDevice != null && existingDevice.data.position != packet.data.position) {
      LogService.logPosition(deviceId: deviceId, position: packet.data.position, duration: packet.data.positionDuration);
    }

    // Log risk alerts and show notifications
    if (existingDevice != null && packet.data.riskValid) {
      final highestRisk = packet.data.highestRisk;
      if (highestRisk.level == 'HIGH' || highestRisk.level == 'MEDIUM') {
        if (existingDevice.data.highestRisk.level != highestRisk.level || existingDevice.data.highestRisk.zone != highestRisk.zone) {
          LogService.logRisk(deviceId: deviceId, zone: highestRisk.zone, score: highestRisk.score, level: highestRisk.level);
          if (_notificationsEnabled) {
            _notificationService.showRiskAlert(
              deviceId: deviceId,
              bedLabel: packet.data.bedLabel,
              zone: highestRisk.zone,
              score: highestRisk.score,
              level: highestRisk.level,
              position: packet.data.positionLabel,
            );
          }
        }
      }
    }

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
        final oldStatus = entry.value.connectionStatus;
        _devices[entry.key] = entry.value.copyWith(
          connectionStatus: newStatus,
        );

        // Log status change
        LogService.logConnection(
          deviceId: entry.key,
          event: 'Status changed: ${oldStatus.name.toUpperCase()} → ${newStatus.name.toUpperCase()}',
          details: 'Last packet ${age}s ago',
        );

        // Show notification for status changes
        if (_notificationsEnabled && (newStatus == ConnectionStatus.offline || newStatus == ConnectionStatus.stale)) {
          _notificationService.showConnectionAlert(
            deviceId: entry.key,
            bedLabel: entry.value.data.bedLabel,
            event: newStatus.name.toUpperCase(),
            status: newStatus.name.toUpperCase(),
          );
        }

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
    LogService.logConnection(deviceId: 'system', event: 'Manual reconnect initiated');
    notifyListeners();

    _dataSub?.cancel();
    _errorSub?.cancel();
    _statusTimer?.cancel();
    _udpService.dispose();

    // Create a fresh UdpService instance to avoid closed stream controllers
    // (UdpService.dispose() closes the stream controllers permanently)
    final newUdpService = UdpService();
    _udpService = newUdpService;

    try {
      await _udpService.start();
      LogService.logConnection(deviceId: 'system', event: 'UDP listener restarted', details: 'Port 5005');
      _dataSub = _udpService.dataStream.listen(_onPacket);
      _errorSub = _udpService.errorStream.listen((err) {
        _lastError = err;
        LogService.logError(message: 'UDP Error', details: err);
        notifyListeners();
      });
      _statusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        _updateConnectionStatuses();
      });
      _startBackgroundMonitoring();
    } catch (e) {
      debugPrint('VitalSenseProvider: Reconnect failed: $e');
      _lastError = 'Reconnect failed: $e';
      LogService.logError(message: 'Reconnect failed', details: e.toString());
      _backgroundService.scheduleReconnectCheck();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _dataSub?.cancel();
    _errorSub?.cancel();
    _statusTimer?.cancel();
    _udpService.dispose();
    _stopBackgroundMonitoring();
    _backgroundService.dispose();
    super.dispose();
  }
}

