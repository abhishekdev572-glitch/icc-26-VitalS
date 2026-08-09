import 'dart:async';
import 'package:workmanager/workmanager.dart';
import 'package:flutter/foundation.dart';
import '../services/notification_service.dart';
import '../providers/vital_sense_provider.dart';

class BackgroundService {
  static const String _taskName = 'vitalsense_background_monitor';
  static const String _reconnectTaskName = 'vitalsense_auto_reconnect';

  static BackgroundService? _instance;
  static BackgroundService get instance => _instance ??= BackgroundService._();
  BackgroundService._();

  Timer? _monitorTimer;
  final Map<String, DateTime> _lastNotificationTime = {};

  Future<void> initialize() async {
    await Workmanager().initialize(
      _callbackDispatcher,
    );

    await _registerPeriodicTasks();
  }

  static void _callbackDispatcher() {
    Workmanager().executeTask((task, inputData) async {
      switch (task) {
        case _taskName:
          await _performBackgroundCheck(inputData);
          break;
        case _reconnectTaskName:
          await _attemptBackgroundReconnect(inputData);
          break;
      }
      return Future.value(true);
    });
  }

  static Future<void> _performBackgroundCheck(Map<String, dynamic>? inputData) async {
    debugPrint('[Background] Performing periodic check...');
  }

  static Future<void> _attemptBackgroundReconnect(Map<String, dynamic>? inputData) async {
    debugPrint('[Background] Attempting reconnect...');
  }

  Future<void> _registerPeriodicTasks() async {
    await Workmanager().registerPeriodicTask(
      _taskName,
      _taskName,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
    );

    await Workmanager().registerPeriodicTask(
      _reconnectTaskName,
      _reconnectTaskName,
      frequency: const Duration(minutes: 5),
      initialDelay: const Duration(minutes: 1),
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
    );
  }

  void startForegroundMonitoring({
    required Map<String, DeviceState> devices,
    required Function() onReconnectNeeded,
  }) {
    _monitorTimer?.cancel();
    _monitorTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _checkDevices(devices, onReconnectNeeded);
    });
  }

  void stopForegroundMonitoring() {
    _monitorTimer?.cancel();
    _monitorTimer = null;
  }

  void _checkDevices(
    Map<String, DeviceState> devices,
    Function() onReconnectNeeded,
  ) {
    final now = DateTime.now();
    bool anyLive = false;

    for (final entry in devices.entries) {
      final device = entry.value;
      final age = now.difference(device.lastPacketAt).inSeconds;

      if (device.connectionStatus == ConnectionStatus.live) {
        anyLive = true;
        _checkRiskAndNotify(device);
      } else if (age > 30) {
        onReconnectNeeded();
      }
    }

    if (!anyLive && devices.isNotEmpty) {
      onReconnectNeeded();
    }
  }

  void _checkRiskAndNotify(DeviceState device) {
    if (!device.data.riskValid) return;

    final highestRisk = device.data.highestRisk;
    if (highestRisk.level != 'HIGH' && highestRisk.level != 'MEDIUM') return;

    final deviceId = device.data.deviceId;
    final now = DateTime.now();
    final lastNotify = _lastNotificationTime[deviceId];

    if (lastNotify != null && now.difference(lastNotify).inMinutes < 15) {
      return;
    }

    _lastNotificationTime[deviceId] = now;

    NotificationService().showRiskAlert(
      deviceId: deviceId,
      bedLabel: device.data.bedLabel,
      zone: highestRisk.zone,
      score: highestRisk.score,
      level: highestRisk.level,
      position: device.data.positionLabel,
    );
  }

  void scheduleReconnectCheck() {
    Workmanager().registerOneOffTask(
      'vitalsense_reconnect_now',
      _reconnectTaskName,
      initialDelay: const Duration(seconds: 30),
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  void cancelAllTasks() {
    Workmanager().cancelAll();
  }

  Future<void> dispose() async {
    stopForegroundMonitoring();
    cancelAllTasks();
  }
}