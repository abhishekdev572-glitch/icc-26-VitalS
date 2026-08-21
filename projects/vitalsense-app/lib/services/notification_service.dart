import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz;
import 'package:permission_handler/permission_handler.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  bool _permissionGranted = false;

  static const String _channelId = 'vitalsense_risk_alerts';
  static const String _channelName = 'VitalSense Risk Alerts';
  static const String _channelDescription =
      'Critical risk notifications for patient monitoring';

  Future<void> initialize() async {
    if (_initialized) return;

    tz.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('UTC'));

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const initSettings =
        InitializationSettings(android: androidSettings, iOS: iosSettings);

    await _notifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTap,
    );

    await _createNotificationChannel();
    await _requestPermissions();
    _initialized = true;
  }

  Future<void> _createNotificationChannel() async {
    const channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: _channelDescription,
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      enableLights: true,
      showBadge: true,
    );
    await _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  Future<void> _requestPermissions() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final androidPlugin =
          _notifications.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      _permissionGranted =
          await androidPlugin?.requestNotificationsPermission() ?? false;

      if (!_permissionGranted) {
        await Permission.notification.request();
        _permissionGranted = await Permission.notification.isGranted;
      }
    } else {
      final iosPlugin = _notifications.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      _permissionGranted = await iosPlugin?.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          ) ??
          false;
    }
  }

  void _onNotificationTap(NotificationResponse response) {
    debugPrint('Notification tapped: ${response.payload}');
  }

  Future<void> showRiskAlert({
    required String deviceId,
    required String bedLabel,
    required String zone,
    required int score,
    required String level,
    required String position,
  }) async {
    if (!_permissionGranted) await _requestPermissions();
    if (!_permissionGranted) return;

    final color = _getRiskColor(level);
    final title = '⚠️ $level Risk Alert';
    final body = '$bedLabel - $zone risk: $score%\nPosition: $position';

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      enableLights: true,
      color: color,
      ledColor: color,
      ledOnMs: 1000,
      ledOffMs: 500,
      category: AndroidNotificationCategory.alarm,
      fullScreenIntent: true,
      visibility: NotificationVisibility.public,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      sound: 'default',
      interruptionLevel: InterruptionLevel.critical,
    );

    final details =
        NotificationDetails(android: androidDetails, iOS: iosDetails);

    await _notifications.show(
      deviceId.hashCode,
      title,
      body,
      details,
      payload: 'risk_alert:$deviceId:$zone:$score:$level',
    );
  }

  Future<void> showConnectionAlert({
    required String deviceId,
    required String bedLabel,
    required String event,
    required String status,
  }) async {
    if (!_permissionGranted) await _requestPermissions();
    if (!_permissionGranted) return;

    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      color: Color(0xFFF59E0B),
      category: AndroidNotificationCategory.status,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const details =
        NotificationDetails(android: androidDetails, iOS: iosDetails);

    await _notifications.show(
      deviceId.hashCode ^ 1,
      'Connection: $event',
      '$bedLabel is now $status',
      details,
      payload: 'connection:$deviceId:$status',
    );
  }

  Future<void> cancelAll() async {
    await _notifications.cancelAll();
  }

  Future<void> cancel(String deviceId) async {
    await _notifications.cancel(deviceId.hashCode);
    await _notifications.cancel(deviceId.hashCode ^ 1);
  }

  Color _getRiskColor(String level) {
    switch (level) {
      case 'HIGH':
        return const Color(0xFFEF4444);
      case 'MEDIUM':
        return const Color(0xFFF59E0B);
      case 'LOW':
        return const Color(0xFF4ADE80);
      default:
        return const Color(0xFF71787F);
    }
  }
}
