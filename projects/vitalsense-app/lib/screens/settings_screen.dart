import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/vital_sense_provider.dart';
import '../services/notification_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _udpPort = 5005;
  int _liveTimeout = 3;
  int _staleTimeout = 10;
  bool _darkMode = false;
  int _maxLogEntries = 500;
  bool _autoReconnect = true;
  int _reconnectInterval = 5;
  bool _notificationsEnabled = true;
  bool _backgroundMonitoring = true;
  bool _criticalAlertsOnly = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final provider = context.read<VitalSenseProvider>();
    setState(() {
      _udpPort = prefs.getInt('udp_port') ?? 5005;
      _liveTimeout = prefs.getInt('live_timeout') ?? 3;
      _staleTimeout = prefs.getInt('stale_timeout') ?? 10;
      _darkMode = prefs.getBool('dark_mode') ?? false;
      _maxLogEntries = prefs.getInt('max_log_entries') ?? 500;
      _autoReconnect = prefs.getBool('auto_reconnect') ?? true;
      _reconnectInterval = prefs.getInt('reconnect_interval') ?? 5;
      _notificationsEnabled = prefs.getBool('notifications_enabled') ?? true;
      _backgroundMonitoring = prefs.getBool('background_monitoring') ?? true;
      _criticalAlertsOnly = prefs.getBool('critical_alerts_only') ?? false;
    });
    provider.setNotificationsEnabled(_notificationsEnabled);
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('udp_port', _udpPort);
    await prefs.setInt('live_timeout', _liveTimeout);
    await prefs.setInt('stale_timeout', _staleTimeout);
    await prefs.setBool('dark_mode', _darkMode);
    await prefs.setInt('max_log_entries', _maxLogEntries);
    await prefs.setBool('auto_reconnect', _autoReconnect);
    await prefs.setInt('reconnect_interval', _reconnectInterval);
    await prefs.setBool('notifications_enabled', _notificationsEnabled);
    await prefs.setBool('background_monitoring', _backgroundMonitoring);
    await prefs.setBool('critical_alerts_only', _criticalAlertsOnly);

    if (!mounted) return;
    final provider = context.read<VitalSenseProvider>();
    provider.setNotificationsEnabled(_notificationsEnabled);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved. Restart app to apply network changes.')),
      );
    }
  }

  Future<void> _testNotification() async {
    await NotificationService().showRiskAlert(
      deviceId: 'test_device',
      bedLabel: 'Bed 01 (Test)',
      zone: 'HIPS',
      score: 85,
      level: 'HIGH',
      position: 'Left Side',
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Test notification sent')),
      );
    }
  }

  Future<void> _clearDeviceData() async {
    final provider = context.read<VitalSenseProvider>();
    provider.reconnect();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Device data cleared, reconnecting...')),
      );
    }
  }

  Future<void> _clearLogs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('event_logs');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Logs cleared')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9F9FF),
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF21638D),
        elevation: 0,
        scrolledUnderElevation: 1,
        actions: [
          TextButton(
            onPressed: _saveSettings,
            child: const Text('SAVE', style: TextStyle(color: Color(0xFF21638D), fontWeight: FontWeight.w700)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSection('Network', [
            _buildNumberField(
              label: 'UDP Port',
              value: _udpPort,
              onChanged: (v) => setState(() => _udpPort = v.clamp(1024, 65535)),
              helper: 'Port for VitalSense broadcasts',
            ),
            _buildNumberField(
              label: 'Live Timeout (seconds)',
              value: _liveTimeout,
              onChanged: (v) => setState(() => _liveTimeout = v.clamp(1, 60)),
              helper: 'Seconds before connection marked LIVE',
            ),
            _buildNumberField(
              label: 'Stale Timeout (seconds)',
              value: _staleTimeout,
              onChanged: (v) => setState(() => _staleTimeout = v.clamp(_liveTimeout + 1, 300)),
              helper: 'Seconds before connection marked STALE',
            ),
            _buildSwitchTile(
              title: 'Auto Reconnect',
              subtitle: 'Automatically attempt reconnection on disconnect',
              value: _autoReconnect,
              onChanged: (v) => setState(() => _autoReconnect = v),
            ),
            _buildNumberField(
              label: 'Reconnect Interval (seconds)',
              value: _reconnectInterval,
              onChanged: (v) => setState(() => _reconnectInterval = v.clamp(1, 60)),
              helper: 'Delay between reconnection attempts',
            ),
          ]),
          const SizedBox(height: 24),
          _buildSection('Notifications', [
            _buildSwitchTile(
              title: 'Enable Notifications',
              subtitle: 'Receive risk alerts and connection updates',
              value: _notificationsEnabled,
              onChanged: (v) => setState(() => _notificationsEnabled = v),
            ),
            _buildSwitchTile(
              title: 'Critical Alerts Only',
              subtitle: 'Only notify for HIGH risk (not MEDIUM)',
              value: _criticalAlertsOnly,
              onChanged: _notificationsEnabled ? (v) => setState(() => _criticalAlertsOnly = v) : null,
            ),
            _buildSwitchTile(
              title: 'Background Monitoring',
              subtitle: 'Check for risks even when app is in background',
              value: _backgroundMonitoring,
              onChanged: (v) => setState(() => _backgroundMonitoring = v),
            ),
            _buildActionTile(
              title: 'Test Notification',
              subtitle: 'Send a test HIGH risk alert to verify setup',
              icon: Icons.notifications_active,
              color: const Color(0xFF21638D),
              onTap: _notificationsEnabled ? _testNotification : null,
            ),
          ]),
          const SizedBox(height: 24),
          _buildSection('Appearance', [
            _buildSwitchTile(
              title: 'Dark Mode',
              subtitle: 'Use dark theme (requires app restart)',
              value: _darkMode,
              onChanged: (v) => setState(() => _darkMode = v),
            ),
          ]),
          const SizedBox(height: 24),
          _buildSection('Data & Storage', [
            _buildNumberField(
              label: 'Max Log Entries',
              value: _maxLogEntries,
              onChanged: (v) => setState(() => _maxLogEntries = v.clamp(100, 5000)),
              helper: 'Maximum events to keep in history',
            ),
            _buildActionTile(
              title: 'Clear Event Logs',
              subtitle: 'Remove all stored connection and event history',
              icon: Icons.delete_outline,
              color: const Color(0xFFEF4444),
              onTap: _clearLogs,
            ),
            _buildActionTile(
              title: 'Clear Device Data',
              subtitle: 'Reset connection and rediscover devices',
              icon: Icons.refresh,
              color: const Color(0xFFF59E0B),
              onTap: _clearDeviceData,
            ),
          ]),
          const SizedBox(height: 24),
          _buildSection('About', [
            _buildInfoTile('App Version', '1.0.0'),
            _buildInfoTile('Protocol', 'VitalSense v1'),
            _buildInfoTile('Transport', 'UDP Broadcast'),
            _buildInfoTile('Default Port', '5005'),
          ]),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: Color(0xFF71787F),
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: const Color(0xFFE2E8F0)),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF1E293B).withValues(alpha: 0.04),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(children: children),
        ),
      ],
    );
  }

  Widget _buildNumberField({
    required String label,
    required int value,
    required ValueChanged<int> onChanged,
    String? helper,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFF1F5F9), width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF41474E),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              SizedBox(
                width: 80,
                child: TextFormField(
                  initialValue: value.toString(),
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (text) {
                    final v = int.tryParse(text);
                    if (v != null) onChanged(v);
                  },
                ),
              ),
            ],
          ),
          if (helper != null) ...[
            const SizedBox(height: 4),
            Text(helper, style: const TextStyle(fontSize: 12, color: Color(0xFF71787F))),
          ],
        ],
      ),
    );
  }

  Widget _buildSwitchTile({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final enabled = onChanged != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFF1F5F9), width: 1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: enabled ? const Color(0xFF111C2D) : const Color(0xFFC1C7CF),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: enabled ? const Color(0xFF71787F) : const Color(0xFFC1C7CF),
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: const Color(0xFF21638D),
            inactiveThumbColor: Colors.grey[400],
            inactiveTrackColor: Colors.grey[300],
          ),
        ],
      ),
    );
  }

  Widget _buildActionTile({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFFF1F5F9), width: 1)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: (enabled ? color : Colors.grey).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: enabled ? color : Colors.grey, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: enabled ? const Color(0xFF111C2D) : const Color(0xFFC1C7CF),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: enabled ? const Color(0xFF71787F) : const Color(0xFFC1C7CF),
                    ),
                  ),
                ],
              ),
            ),
            if (enabled)
              const Icon(Icons.chevron_right, color: Color(0xFFC1C7CF)),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoTile(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFF1F5F9), width: 1)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 14, color: Color(0xFF41474E), fontWeight: FontWeight.w500)),
          Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF21638D), fontFeatures: [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}