import 'package:flutter/material.dart';
import '../models/vital_sense_data.dart';

/// Card showing current patient position and duration.
class PositionCard extends StatelessWidget {
  final VitalSenseData data;
  const PositionCard({super.key, required this.data});

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
      child: Row(
        children: [
          // Position visualizer icon
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: const Color(0xFF90CAF9).withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              _positionIcon(data.position),
              color: const Color(0xFF21638D),
              size: 36,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'CURRENT POSITION',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: Color(0xFF71787F),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  data.positionLabel,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF21638D),
                    letterSpacing: -0.5,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text(
                'DURATION',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: Color(0xFF71787F),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(
                    Icons.schedule_rounded,
                    size: 16,
                    color: Color(0xFF41474E),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    data.formattedDuration,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF111C2D),
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  IconData _positionIcon(String position) {
    switch (position) {
      case 'LEFT':
        return Icons.airline_seat_flat_angled;
      case 'RIGHT':
        return Icons.airline_seat_flat_angled;
      case 'CENTER':
      default:
        return Icons.airline_seat_flat;
    }
  }
}
