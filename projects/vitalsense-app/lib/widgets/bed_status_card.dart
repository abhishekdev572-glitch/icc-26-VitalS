import 'package:flutter/material.dart';
import '../providers/vital_sense_provider.dart';

/// Top card showing bed number, device ID, and animated connection status.
class BedStatusCard extends StatelessWidget {
  final DeviceState device;

  const BedStatusCard({super.key, required this.device});

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
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                device.data.bedLabel,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF111C2D),
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Device: ${device.data.deviceId}',
                style: const TextStyle(
                  fontSize: 14,
                  color: Color(0xFF41474E),
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
          _ConnectionBadge(status: device.connectionStatus),
        ],
      ),
    );
  }
}

class _ConnectionBadge extends StatefulWidget {
  final ConnectionStatus status;
  const _ConnectionBadge({required this.status});

  @override
  State<_ConnectionBadge> createState() => _ConnectionBadgeState();
}

class _ConnectionBadgeState extends State<_ConnectionBadge>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _opacity = Tween<double>(begin: 1.0, end: 0.4).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _dotColor(widget.status);
    final label = widget.status.name.toUpperCase();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFC1C7CF)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          widget.status == ConnectionStatus.live
              ? FadeTransition(
                  opacity: _opacity,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                )
              : Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Color _dotColor(ConnectionStatus status) {
    switch (status) {
      case ConnectionStatus.live:
        return const Color(0xFF4ADE80);
      case ConnectionStatus.stale:
        return const Color(0xFFF59E0B);
      case ConnectionStatus.offline:
        return const Color(0xFFEF4444);
      default:
        return const Color(0xFF71787F);
    }
  }
}
