import 'package:flutter/material.dart';
import '../models/vital_sense_data.dart';

/// Grid showing 8 raw FSR values and 4 plate averaged values.
class FsrGrid extends StatelessWidget {
  final List<int> fsr;
  final PlatesData plates;

  const FsrGrid({super.key, required this.fsr, required this.plates});

  static const _fsrLabels = [
    'Head A',
    'Head B',
    'Shoulders A',
    'Shoulders B',
    'Hips A',
    'Hips B',
    'Heels A',
    'Heels B',
  ];

  static const _icons = [
    Icons.face_outlined,
    Icons.face_outlined,
    Icons.accessibility_new_rounded,
    Icons.accessibility_new_rounded,
    Icons.hive_outlined,
    Icons.hive_outlined,
    Icons.directions_walk_rounded,
    Icons.directions_walk_rounded,
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 12),
          child: Row(
            children: [
              const Text(
                'RAW SENSOR DATA',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: Color(0xFF71787F),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  height: 1,
                  color: const Color(0xFFC1C7CF).withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ),

        // Plate values row
        Row(
          children: [
            _PlateCard(label: 'Head', value: plates.head),
            const SizedBox(width: 8),
            _PlateCard(label: 'Shoulders', value: plates.shoulders),
            const SizedBox(width: 8),
            _PlateCard(label: 'Hips', value: plates.hips),
            const SizedBox(width: 8),
            _PlateCard(label: 'Heels', value: plates.heels),
          ],
        ),

        const SizedBox(height: 12),

        // 8 FSR values in 2x4 grid
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 0.95,
          ),
          itemCount: 8,
          itemBuilder: (context, index) {
            return _FsrCell(
              index: index,
              label: _fsrLabels[index],
              icon: _icons[index],
              value: fsr[index],
            );
          },
        ),
      ],
    );
  }
}

class _PlateCard extends StatelessWidget {
  final String label;
  final int value;

  const _PlateCard({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final pct = (value / 4095.0).clamp(0.0, 1.0);

    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF90CAF9).withValues(alpha: 0.1),
          border: Border.all(color: const Color(0xFF90CAF9).withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Text(
              label.toUpperCase(),
              style: const TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: Color(0xFF41474E),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              value.toString(),
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Color(0xFF21638D),
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: pct,
                backgroundColor: const Color(0xFFE7EEFF),
                valueColor:
                    const AlwaysStoppedAnimation<Color>(Color(0xFF90CAF9)),
                minHeight: 4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FsrCell extends StatelessWidget {
  final int index;
  final String label;
  final IconData icon;
  final int value;

  const _FsrCell({
    required this.index,
    required this.label,
    required this.icon,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final pct = (value / 4095.0).clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE2E8F0)),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1E293B).withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'FSR $index',
            style: const TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: Color(0xFF71787F),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value.toString(),
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: Color(0xFF21638D),
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct,
              backgroundColor: const Color(0xFFE7EEFF),
              valueColor: AlwaysStoppedAnimation<Color>(
                _barColor(pct),
              ),
              minHeight: 5,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(
              fontSize: 8,
              fontWeight: FontWeight.w500,
              color: Color(0xFF71787F),
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Color _barColor(double pct) {
    if (pct < 0.33) return const Color(0xFF90CAF9);
    if (pct < 0.66) return const Color(0xFFFBBF24);
    return const Color(0xFFEF4444);
  }
}
