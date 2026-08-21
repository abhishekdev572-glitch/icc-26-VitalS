import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/ble_provisioning_provider.dart';
import '../providers/vital_sense_provider.dart';

/// Engineering/diagnostics screen showing raw FSR values, plate ADC values,
/// ESP32 uptime, device ID, and source IP.
class DiagnosticsScreen extends StatelessWidget {
  final DeviceState device;

  const DiagnosticsScreen({super.key, required this.device});

  @override
  Widget build(BuildContext context) {
    final data = device.data;
    final vitalSense = context.watch<VitalSenseProvider>();
    final provisioning = context.watch<BleProvisioningProvider>();

    return Scaffold(
      backgroundColor: const Color(0xFFF9F9FF),
      appBar: AppBar(
        title: const Text('Diagnostics'),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF21638D),
        elevation: 0,
        scrolledUnderElevation: 1,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _SectionHeader(title: 'Device Info'),
          _InfoCard(children: [
            _InfoRow(label: 'Device ID', value: data.deviceId),
            _InfoRow(label: 'Bed', value: data.bedLabel),
            _InfoRow(label: 'Protocol Version', value: 'v${data.protocol}'),
            _InfoRow(
                label: 'Source IP',
                value: device.sourceIp.isEmpty ? 'N/A' : device.sourceIp),
            _InfoRow(label: 'ESP32 Uptime', value: _formatUptime(data.uptime)),
          ]),
          const SizedBox(height: 16),
          const _SectionHeader(title: 'Network'),
          _InfoCard(children: [
            _InfoRow(
              label: 'UDP Listener',
              value: vitalSense.udpListenerActive ? 'Active' : 'Inactive',
            ),
            _InfoRow(label: 'UDP Port', value: '${vitalSense.udpPort}'),
            _InfoRow(
              label: 'ESP32 IP',
              value: device.sourceIp.isEmpty ? 'N/A' : device.sourceIp,
            ),
            _InfoRow(label: 'Device ID', value: data.deviceId),
          ]),
          const SizedBox(height: 16),
          const _SectionHeader(title: 'Provisioning'),
          _InfoCard(children: [
            _InfoRow(
              label: 'BLE',
              value: provisioning.isBleConnected
                  ? 'Connected for setup'
                  : 'Not Connected',
            ),
            _InfoRow(
              label: 'Configured SSID',
              value: provisioning.configuredSsid ?? 'Unknown',
            ),
          ]),
          const SizedBox(height: 16),
          const _SectionHeader(title: 'Connection'),
          _InfoCard(children: [
            _InfoRow(
              label: 'Status',
              value: device.connectionStatus.name.toUpperCase(),
              valueColor: _connectionColor(device.connectionStatus),
            ),
            _InfoRow(
              label: 'Last Packet',
              value: _formatLastSeen(device.lastPacketAt),
            ),
          ]),
          const SizedBox(height: 16),
          const _SectionHeader(title: 'Raw FSR Values (ADC 0–4095)'),
          _FsrDiagnosticCard(fsr: data.fsr),
          const SizedBox(height: 16),
          const _SectionHeader(title: 'Plate Values (Averaged ADC)'),
          _InfoCard(children: [
            _InfoRow(label: 'Head Plate', value: data.plates.head.toString()),
            _InfoRow(
                label: 'Shoulders Plate',
                value: data.plates.shoulders.toString()),
            _InfoRow(label: 'Hips Plate', value: data.plates.hips.toString()),
            _InfoRow(label: 'Heels Plate', value: data.plates.heels.toString()),
          ]),
          const SizedBox(height: 16),
          const _SectionHeader(title: 'Position'),
          _InfoCard(children: [
            _InfoRow(label: 'Position', value: data.position),
            _InfoRow(label: 'Duration', value: data.formattedDuration),
          ]),
          const SizedBox(height: 16),
          const _SectionHeader(title: 'Risk Assessment'),
          _InfoCard(children: [
            _InfoRow(
              label: 'Risk Valid',
              value: data.riskValid ? 'YES' : 'NO',
              valueColor: data.riskValid
                  ? const Color(0xFF006D36)
                  : const Color(0xFF71787F),
            ),
            _InfoRow(
              label: 'Head Risk',
              value: data.riskValid ? '${data.risk.head}%' : '—',
            ),
            _InfoRow(
              label: 'Shoulders Risk',
              value: data.riskValid ? '${data.risk.shoulders}%' : '—',
            ),
            _InfoRow(
              label: 'Hips Risk',
              value: data.riskValid ? '${data.risk.hips}%' : '—',
            ),
            _InfoRow(
              label: 'Heels Risk',
              value: data.riskValid ? '${data.risk.heels}%' : '—',
            ),
            _InfoRow(
              label: 'Highest Risk Zone',
              value: data.highestRisk.zone,
            ),
            _InfoRow(
              label: 'Highest Risk Score',
              value: data.riskValid ? '${data.highestRisk.score}%' : '—',
            ),
            _InfoRow(
              label: 'Risk Level',
              value: data.highestRisk.level,
              valueColor: _riskLevelColor(data.highestRisk.level),
            ),
          ]),
          const SizedBox(height: 16),
          const _SectionHeader(title: 'Avoid-Return Flags'),
          _InfoCard(children: [
            _InfoRow(
                label: 'Head',
                value: data.avoidReturn.head == 1 ? 'ACTIVE' : 'None'),
            _InfoRow(
                label: 'Shoulders',
                value: data.avoidReturn.shoulders == 1 ? 'ACTIVE' : 'None'),
            _InfoRow(
                label: 'Hips',
                value: data.avoidReturn.hips == 1 ? 'ACTIVE' : 'None'),
            _InfoRow(
                label: 'Heels',
                value: data.avoidReturn.heels == 1 ? 'ACTIVE' : 'None'),
          ]),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  String _formatUptime(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    return '${h}h ${m}m ${s}s';
  }

  String _formatLastSeen(DateTime dt) {
    final diff = DateTime.now().difference(dt).inSeconds;
    if (diff < 1) return 'Just now';
    if (diff < 60) return '${diff}s ago';
    return '${diff ~/ 60}m ago';
  }

  Color _connectionColor(ConnectionStatus status) {
    switch (status) {
      case ConnectionStatus.live:
        return const Color(0xFF006D36);
      case ConnectionStatus.stale:
        return const Color(0xFFF57F17);
      case ConnectionStatus.offline:
        return const Color(0xFFBA1A1A);
      default:
        return const Color(0xFF71787F);
    }
  }

  Color _riskLevelColor(String level) {
    switch (level) {
      case 'LOW':
        return const Color(0xFF006D36);
      case 'MEDIUM':
        return const Color(0xFFF57F17);
      case 'HIGH':
        return const Color(0xFFBA1A1A);
      default:
        return const Color(0xFF71787F);
    }
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: Color(0xFF71787F),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final List<Widget> children;
  const _InfoCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
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
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _InfoRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0xFFF1F5F9), width: 1),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 14,
              color: Color(0xFF41474E),
              fontWeight: FontWeight.w500,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              color: valueColor ?? const Color(0xFF111C2D),
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _FsrDiagnosticCard extends StatelessWidget {
  final List<int> fsr;
  const _FsrDiagnosticCard({required this.fsr});

  static const _labels = [
    'FSR 0 — Head A',
    'FSR 1 — Head B',
    'FSR 2 — Shoulders A',
    'FSR 3 — Shoulders B',
    'FSR 4 — Hips A',
    'FSR 5 — Hips B',
    'FSR 6 — Heels A',
    'FSR 7 — Heels B',
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
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
      child: Column(
        children: List.generate(fsr.length, (i) {
          final pct = fsr[i] / 4095.0;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Color(0xFFF1F5F9), width: 1),
              ),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 160,
                  child: Text(
                    _labels[i],
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF41474E),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: pct,
                      backgroundColor: const Color(0xFFE7EEFF),
                      valueColor:
                          const AlwaysStoppedAnimation(Color(0xFF90CAF9)),
                      minHeight: 8,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 44,
                  child: Text(
                    fsr[i].toString(),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF21638D),
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }
}
