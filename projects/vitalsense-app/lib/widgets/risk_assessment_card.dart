import 'package:flutter/material.dart';
import '../models/vital_sense_data.dart';

/// Risk assessment card. Shows "Waiting for assessment" when riskValid == false.
/// When valid, shows circular gauges for all 4 body regions + highest risk banner.
class RiskAssessmentCard extends StatelessWidget {
  final VitalSenseData data;
  const RiskAssessmentCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE2E8F0)),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1E293B).withValues(alpha: 0.05),
            blurRadius: 15,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'RISK ASSESSMENT',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: Color(0xFF71787F),
                ),
              ),
              if (data.riskValid)
                _RiskLevelBadge(level: data.highestRisk.level),
            ],
          ),
          const SizedBox(height: 16),

          if (!data.riskValid) ...[
            _WaitingState(positionDuration: data.positionDuration),
          ] else ...[
            // Highest risk banner
            _HighestRiskBanner(highestRisk: data.highestRisk),
            const SizedBox(height: 20),
            // Four circular gauges
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _RiskGauge(label: 'HEAD', value: data.risk.head),
                _RiskGauge(label: 'SHOULDERS', value: data.risk.shoulders),
                _RiskGauge(label: 'HIPS', value: data.risk.hips),
                _RiskGauge(label: 'HEELS', value: data.risk.heels),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _WaitingState extends StatefulWidget {
  final int positionDuration;
  const _WaitingState({required this.positionDuration});

  @override
  State<_WaitingState> createState() => _WaitingStateState();
}

class _WaitingStateState extends State<_WaitingState>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _anim = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Threshold is 60 seconds per protocol spec
    final pct = (widget.positionDuration / 60.0).clamp(0.0, 1.0);
    final remaining = (60 - widget.positionDuration).clamp(0, 60);

    return Column(
      children: [
        FadeTransition(
          opacity: Tween<double>(begin: 0.5, end: 1.0).animate(_anim),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Column(
              children: [
                const Icon(
                  Icons.hourglass_top_rounded,
                  size: 40,
                  color: Color(0xFF90CAF9),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Waiting for Assessment',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF111C2D),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  remaining > 0
                      ? 'Assessment begins in ~${remaining}s'
                      : 'Running ML inference...',
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF71787F),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: pct,
            backgroundColor: const Color(0xFFE7EEFF),
            valueColor:
                const AlwaysStoppedAnimation<Color>(Color(0xFF90CAF9)),
            minHeight: 8,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '${(pct * 100).toStringAsFixed(0)}% of position threshold reached',
          style: const TextStyle(
            fontSize: 11,
            color: Color(0xFF71787F),
          ),
        ),
      ],
    );
  }
}

class _HighestRiskBanner extends StatelessWidget {
  final HighestRisk highestRisk;
  const _HighestRiskBanner({required this.highestRisk});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF9F9FF),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'HIGHEST RISK REGION',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: Color(0xFF71787F),
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Text(
                    highestRisk.zoneLabel,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF111C2D),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${highestRisk.score}%',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: _levelColor(highestRisk.level),
                    ),
                  ),
                ],
              ),
            ],
          ),
          Icon(
            _levelIcon(highestRisk.level),
            size: 36,
            color: _levelColor(highestRisk.level),
          ),
        ],
      ),
    );
  }

  Color _levelColor(String level) {
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

  IconData _levelIcon(String level) {
    switch (level) {
      case 'LOW':
        return Icons.check_circle_outline_rounded;
      case 'MEDIUM':
        return Icons.warning_amber_rounded;
      case 'HIGH':
        return Icons.error_outline_rounded;
      default:
        return Icons.help_outline_rounded;
    }
  }
}

class _RiskLevelBadge extends StatelessWidget {
  final String level;
  const _RiskLevelBadge({required this.level});

  @override
  Widget build(BuildContext context) {
    Color bg, fg;
    switch (level) {
      case 'LOW':
        bg = const Color(0xFFDCFCE7);
        fg = const Color(0xFF006D36);
        break;
      case 'MEDIUM':
        bg = const Color(0xFFFFF8E1);
        fg = const Color(0xFFF57F17);
        break;
      case 'HIGH':
        bg = const Color(0xFFFFDAD6);
        fg = const Color(0xFFBA1A1A);
        break;
      default:
        bg = const Color(0xFFE7EEFF);
        fg = const Color(0xFF41474E);
    }

    final label = level == 'LOW'
        ? 'Low Risk'
        : level == 'MEDIUM'
            ? 'Medium Risk'
            : level == 'HIGH'
                ? 'High Risk'
                : 'Waiting';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
          color: fg,
        ),
      ),
    );
  }
}

class _RiskGauge extends StatelessWidget {
  final String label;
  final int value; // 0–100

  const _RiskGauge({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final pct = value / 100.0;
    final color = _gaugeColor(value);

    return Column(
      children: [
        SizedBox(
          width: 72,
          height: 72,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const CircularProgressIndicator(
                value: 1.0,
                strokeWidth: 8,
                valueColor: AlwaysStoppedAnimation<Color>(
                    Color(0xFFE7EEFF)),
                strokeCap: StrokeCap.round,
              ),
              CircularProgressIndicator(
                value: pct,
                strokeWidth: 8,
                valueColor: AlwaysStoppedAnimation<Color>(color),
                strokeCap: StrokeCap.round,
              ),
              Center(
                child: Text(
                  '$value%',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF111C2D),
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: Color(0xFF41474E),
          ),
        ),
      ],
    );
  }

  Color _gaugeColor(int value) {
    if (value < 30) return const Color(0xFF4ADE80);
    if (value < 60) return const Color(0xFFFBBF24);
    return const Color(0xFFEF4444);
  }
}
