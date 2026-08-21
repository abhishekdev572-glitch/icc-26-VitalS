import 'package:flutter/material.dart';

import '../models/vital_sense_data.dart';

/// Compact dashboard summary for the latest ML-derived risk estimate.
///
/// Risk values are intentionally hidden until [VitalSenseData.riskValid] is
/// true so protocol placeholder values are never presented as real scores.
class RiskAssessmentCard extends StatelessWidget {
  const RiskAssessmentCard({super.key, required this.data});

  final VitalSenseData data;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: _semanticLabel,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: const Color(0xFFE2E8F0)),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF1E293B).withValues(alpha: 0.05),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(level: data.riskValid ? data.highestRisk.level : null),
            const SizedBox(height: 14),
            if (data.riskValid)
              _ValidEstimate(data: data)
            else
              _WaitingEstimate(positionDuration: data.positionDuration),
          ],
        ),
      ),
    );
  }

  String get _semanticLabel {
    if (!data.riskValid) {
      final remaining = (60 - data.positionDuration).clamp(0, 60);
      return remaining > 0
          ? 'Risk estimate waiting. Approximately $remaining seconds remaining.'
          : 'Risk estimate inference in progress.';
    }

    return '${data.highestRisk.levelLabel}. Highest risk region '
        '${data.highestRisk.zoneLabel}, score ${data.highestRisk.score}. '
        'Head ${data.risk.head}, shoulders ${data.risk.shoulders}, '
        'hips ${data.risk.hips}, heels ${data.risk.heels}.';
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.level});

  final String? level;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: const Color(0xFF90CAF9).withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(
            Icons.health_and_safety_outlined,
            size: 17,
            color: Color(0xFF21638D),
          ),
        ),
        const SizedBox(width: 9),
        const Expanded(
          child: Text(
            'RISK ESTIMATE',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
              color: Color(0xFF41474E),
            ),
          ),
        ),
        _RiskBadge(level: level),
      ],
    );
  }
}

class _ValidEstimate extends StatelessWidget {
  const _ValidEstimate({required this.data});

  final VitalSenseData data;

  @override
  Widget build(BuildContext context) {
    final highestRisk = data.highestRisk;
    final accent = _riskColor(highestRisk.level);

    return Column(
      children: [
        Row(
          children: [
            _RiskRing(value: highestRisk.score, color: accent),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'HIGHEST-RISK REGION',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.65,
                      color: Color(0xFF71787F),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    highestRisk.zoneLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 21,
                      height: 1.05,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF111C2D),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _supportingText(highestRisk.level),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: accent,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(child: _RegionScore(label: 'Head', value: data.risk.head)),
            const SizedBox(width: 8),
            Expanded(
              child: _RegionScore(
                label: 'Shoulders',
                value: data.risk.shoulders,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: _RegionScore(label: 'Hips', value: data.risk.hips)),
            const SizedBox(width: 8),
            Expanded(
                child: _RegionScore(label: 'Heels', value: data.risk.heels)),
          ],
        ),
      ],
    );
  }

  String _supportingText(String level) {
    switch (level) {
      case 'HIGH':
        return 'Reposition recommended';
      case 'MEDIUM':
        return 'Monitor closely';
      case 'LOW':
        return 'Within low range';
      default:
        return 'Estimate available';
    }
  }
}

class _RiskRing extends StatelessWidget {
  const _RiskRing({required this.value, required this.color});

  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final safeValue = value.clamp(0, 100);

    return SizedBox(
      width: 62,
      height: 62,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const CircularProgressIndicator(
            value: 1,
            strokeWidth: 7,
            color: Color(0xFFE7EEFF),
            strokeCap: StrokeCap.round,
          ),
          CircularProgressIndicator(
            value: safeValue / 100,
            strokeWidth: 7,
            color: color,
            strokeCap: StrokeCap.round,
          ),
          Center(
            child: Text(
              '$safeValue',
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: Color(0xFF111C2D),
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RegionScore extends StatelessWidget {
  const _RegionScore({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final safeValue = value.clamp(0, 100);
    final color = _scoreColor(safeValue);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: Color(0xFF71787F),
          ),
        ),
        const SizedBox(height: 3),
        Text(
          '$safeValue%',
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w800,
            color: Color(0xFF111C2D),
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            value: safeValue / 100,
            minHeight: 4,
            backgroundColor: const Color(0xFFE7EEFF),
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      ],
    );
  }
}

class _WaitingEstimate extends StatelessWidget {
  const _WaitingEstimate({required this.positionDuration});

  final int positionDuration;

  @override
  Widget build(BuildContext context) {
    final progress = (positionDuration / 60).clamp(0.0, 1.0);
    final remaining = (60 - positionDuration).clamp(0, 60);

    return Column(
      children: [
        Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFFE7EEFF),
                borderRadius: BorderRadius.circular(13),
              ),
              child: const Icon(
                Icons.hourglass_top_rounded,
                size: 23,
                color: Color(0xFF21638D),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Waiting for assessment',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF111C2D),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    remaining > 0
                        ? 'Estimate in about $remaining seconds'
                        : 'Running risk inference...',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF71787F),
                    ),
                  ),
                ],
              ),
            ),
            Text(
              '${(progress * 100).round()}%',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: Color(0xFF21638D),
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 6,
            backgroundColor: const Color(0xFFE7EEFF),
            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF42A5F5)),
          ),
        ),
      ],
    );
  }
}

class _RiskBadge extends StatelessWidget {
  const _RiskBadge({required this.level});

  final String? level;

  @override
  Widget build(BuildContext context) {
    final color = _riskColor(level);
    final label = switch (level) {
      'LOW' => 'LOW',
      'MEDIUM' => 'MEDIUM',
      'HIGH' => 'HIGH',
      _ => 'PENDING',
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

Color _riskColor(String? level) {
  switch (level) {
    case 'LOW':
      return const Color(0xFF16834A);
    case 'MEDIUM':
      return const Color(0xFFB85C00);
    case 'HIGH':
      return const Color(0xFFC62828);
    default:
      return const Color(0xFF5F6B7A);
  }
}

Color _scoreColor(int value) {
  if (value < 30) return const Color(0xFF22A55B);
  if (value < 60) return const Color(0xFFF59E0B);
  return const Color(0xFFEF4444);
}
