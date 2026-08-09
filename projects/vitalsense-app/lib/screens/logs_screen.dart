import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

enum LogFilter { all, connection, position, risk, error }

class _LogsScreenState extends State<LogsScreen> {
  List<LogEntry> _logs = [];
  LogFilter _currentFilter = LogFilter.all;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    setState(() => _isLoading = true);
    final prefs = await SharedPreferences.getInstance();
    final logsJson = prefs.getString('event_logs') ?? '[]';
    final List<dynamic> decoded = jsonDecode(logsJson);
    setState(() {
      _logs = decoded.map((e) => LogEntry.fromJson(e as Map<String, dynamic>)).toList();
      _isLoading = false;
    });
  }

  Future<void> _clearLogs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('event_logs');
    setState(() => _logs = []);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Logs cleared')));
    }
  }

  Future<void> _exportLogs() async {
    if (_logs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No logs to export')));
      return;
    }
    final jsonString = const JsonEncoder.withIndent('  ').convert(_logs.map((e) => e.toJson()).toList());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Exported ${_logs.length} entries (${jsonString.length} bytes)')),
      );
    }
  }

  List<LogEntry> get _filteredLogs {
    if (_currentFilter == LogFilter.all) return _logs;
    return _logs.where((log) => log.type == _currentFilter).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9F9FF),
      appBar: AppBar(
        title: const Text('Logs'),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF21638D),
        elevation: 0,
        scrolledUnderElevation: 1,
        actions: [
          if (_logs.isNotEmpty) ...[
            IconButton(
              icon: const Icon(Icons.download_rounded, color: Color(0xFF21638D)),
              onPressed: _exportLogs,
              tooltip: 'Export Logs',
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFFEF4444)),
              onPressed: _clearLogs,
              tooltip: 'Clear Logs',
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          if (_logs.isNotEmpty) _buildFilterChips(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredLogs.isEmpty
                    ? _buildEmptyState()
                    : _buildLogList(),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChips() {
    final filters = [
      (LogFilter.all, 'All'),
      (LogFilter.connection, 'Connection'),
      (LogFilter.position, 'Position'),
      (LogFilter.risk, 'Risk Alerts'),
      (LogFilter.error, 'Errors'),
    ];

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: filters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final (filter, label) = filters[index];
          final isSelected = _currentFilter == filter;
          return FilterChip(
            label: Text(label),
            selected: isSelected,
            onSelected: (_) => setState(() => _currentFilter = filter),
            selectedColor: const Color(0xFF90CAF9).withValues(alpha: 0.3),
            checkmarkColor: const Color(0xFF21638D),
            labelStyle: TextStyle(
              color: isSelected ? const Color(0xFF21638D) : const Color(0xFF41474E),
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
            ),
            side: BorderSide(
              color: isSelected ? const Color(0xFF21638D) : const Color(0xFFC1C7CF),
            ),
            backgroundColor: Colors.white,
            showCheckmark: false,
          );
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _logs.isEmpty ? Icons.history_rounded : Icons.filter_list_off_rounded,
              size: 64,
              color: const Color(0xFFC1C7CF),
            ),
            const SizedBox(height: 16),
            Text(
              _logs.isEmpty ? 'No Logs Yet' : 'No Matching Logs',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Color(0xFF111C2D)),
            ),
            const SizedBox(height: 8),
            Text(
              _logs.isEmpty
                  ? 'Connection events, position changes, and risk alerts will appear here.'
                  : 'Try changing the filter or wait for new events.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: Color(0xFF71787F), height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogList() {
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _filteredLogs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final log = _filteredLogs[index];
        return _LogTile(log: log);
      },
    );
  }
}

class _LogTile extends StatelessWidget {
  final LogEntry log;
  const _LogTile({required this.log});

  @override
  Widget build(BuildContext context) {
    final colors = {
      LogFilter.connection: const Color(0xFF21638D),
      LogFilter.position: const Color(0xFF006D36),
      LogFilter.risk: const Color(0xFFF59E0B),
      LogFilter.error: const Color(0xFFEF4444),
    };

    final color = colors[log.type] ?? const Color(0xFF71787F);
    final icons = {
      LogFilter.connection: Icons.wifi_rounded,
      LogFilter.position: Icons.swap_horiz_rounded,
      LogFilter.risk: Icons.warning_amber_rounded,
      LogFilter.error: Icons.error_outline_rounded,
    };

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE2E8F0)),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1E293B).withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
            child: Icon(icons[log.type] ?? Icons.info_outline, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      log.message,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF111C2D)),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        log.type.name.toUpperCase(),
                        style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: color, letterSpacing: 0.5),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _formatTime(log.timestamp),
                  style: const TextStyle(fontSize: 11, color: Color(0xFF71787F)),
                ),
                if (log.details != null && log.details!.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    log.details!,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF41474E), fontFamily: 'monospace'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays > 0) return '${diff.inDays}d ago';
    if (diff.inHours > 0) return '${diff.inHours}h ago';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m ago';
    return '${diff.inSeconds}s ago';
  }
}

class LogEntry {
  final DateTime timestamp;
  final LogFilter type;
  final String message;
  final String? details;
  final String? deviceId;

  LogEntry({
    required this.timestamp,
    required this.type,
    required this.message,
    this.details,
    this.deviceId,
  });

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'type': type.name,
        'message': message,
        'details': details,
        'deviceId': deviceId,
      };

  factory LogEntry.fromJson(Map<String, dynamic> json) => LogEntry(
        timestamp: DateTime.parse(json['timestamp'] as String),
        type: LogFilter.values.firstWhere((e) => e.name == json['type'], orElse: () => LogFilter.all),
        message: json['message'] as String,
        details: json['details'] as String?,
        deviceId: json['deviceId'] as String?,
      );
}

class LogService {
  static const _key = 'event_logs';
  static const _maxEntries = 500;

  static Future<void> addLog({
    required LogFilter type,
    required String message,
    String? details,
    String? deviceId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final logsJson = prefs.getString(_key) ?? '[]';
    final List<dynamic> decoded = jsonDecode(logsJson);

    final entry = LogEntry(
      timestamp: DateTime.now(),
      type: type,
      message: message,
      details: details,
      deviceId: deviceId,
    );

    decoded.insert(0, entry.toJson());
    if (decoded.length > _maxEntries) decoded.removeRange(_maxEntries, decoded.length);

    await prefs.setString(_key, jsonEncode(decoded));
  }

  static Future<void> logConnection({
    required String deviceId,
    required String event,
    String? details,
  }) async {
    await addLog(
      type: LogFilter.connection,
      message: event,
      details: details,
      deviceId: deviceId,
    );
  }

  static Future<void> logPosition({
    required String deviceId,
    required String position,
    required int duration,
  }) async {
    await addLog(
      type: LogFilter.position,
      message: 'Position changed to $position',
      details: 'Duration: ${_formatDuration(duration)}',
      deviceId: deviceId,
    );
  }

  static Future<void> logRisk({
    required String deviceId,
    required String zone,
    required int score,
    required String level,
  }) async {
    await addLog(
      type: LogFilter.risk,
      message: '$level risk detected: $zone ($score%)',
      details: 'Zone: $zone, Score: $score%, Level: $level',
      deviceId: deviceId,
    );
  }

  static Future<void> logError({
    required String message,
    String? details,
  }) async {
    await addLog(
      type: LogFilter.error,
      message: message,
      details: details,
    );
  }

  static String _formatDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '${h}h ${m}m ${s}s';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }
}