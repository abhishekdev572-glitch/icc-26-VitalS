import 'package:flutter/material.dart';
import '../providers/vital_sense_provider.dart';

/// Simple inline connection status badge used in the AppBar.
class ConnectionStatusBadge extends StatelessWidget {
  final ConnectionStatus status;
  const ConnectionStatusBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    Color color;
    String label;
    switch (status) {
      case ConnectionStatus.live:
        color = const Color(0xFF4ADE80);
        label = 'LIVE';
        break;
      case ConnectionStatus.stale:
        color = const Color(0xFFF59E0B);
        label = 'STALE';
        break;
      case ConnectionStatus.offline:
        color = const Color(0xFFEF4444);
        label = 'OFFLINE';
        break;
      default:
        color = const Color(0xFF71787F);
        label = 'SCANNING';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
