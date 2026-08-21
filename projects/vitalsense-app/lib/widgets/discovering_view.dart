import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/vital_sense_provider.dart';
import '../screens/device_setup_screen.dart';

/// Shown on the dashboard when no VitalSense device has been discovered yet.
class DiscoveringView extends StatefulWidget {
  const DiscoveringView({super.key});

  @override
  State<DiscoveringView> createState() => _DiscoveringViewState();
}

class _DiscoveringViewState extends State<DiscoveringView>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scale;
  late Animation<double> _opacity;
  bool _isRetrying = false;
  bool _showSetupOptions = false;
  Timer? _discoveryTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _scale = Tween<double>(begin: 0.9, end: 1.1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    _opacity = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    _discoveryTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _showSetupOptions = true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _discoveryTimer?.cancel();
    super.dispose();
  }

  Future<void> _openSetup(BuildContext context) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const DeviceSetupScreen()),
    );
  }

  Future<void> _onRetryPressed(BuildContext context) async {
    setState(() => _isRetrying = true);
    final provider = context.read<VitalSenseProvider>();
    await provider.reconnect();
    if (mounted) setState(() => _isRetrying = false);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<VitalSenseProvider>();
    final error = provider.lastError;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ScaleTransition(
              scale: _scale,
              child: FadeTransition(
                opacity: _opacity,
                child: Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    color: const Color(0xFF90CAF9).withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.monitor_heart_rounded,
                    size: 52,
                    color: Color(0xFF21638D),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 32),
            Text(
              _showSetupOptions
                  ? 'No VitalSense device detected'
                  : 'Scanning for Devices',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: Color(0xFF111C2D),
              ),
            ),
            const SizedBox(height: 12),
            if (error != null) ...[
              Container(
                padding: const EdgeInsets.all(16),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFEBEE),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: const Color(0xFFEF4444).withValues(alpha: 0.3)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.error_outline,
                            color: Color(0xFFEF4444), size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            error,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFFEF4444),
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed:
                            _isRetrying ? null : () => _onRetryPressed(context),
                        icon: _isRetrying
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.refresh, size: 18),
                        label: Text(
                            _isRetrying ? 'Retrying...' : 'Retry Connection'),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFEF4444),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              Text(
                _showSetupOptions
                    ? 'Make sure your VitalSense unit and phone are connected to the same Wi-Fi network.'
                    : 'Listening on UDP port 5005.\nMake sure your device and the ESP32 are on the same Wi-Fi network.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  color: Color(0xFF71787F),
                  height: 1.6,
                ),
              ),
            ],
            const SizedBox(height: 32),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFE7EEFF),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.wifi_rounded,
                    size: 18,
                    color: Color(0xFF21638D),
                  ),
                  SizedBox(width: 8),
                  Text(
                    'UDP broadcast :5005',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF21638D),
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            if (_showSetupOptions) ...[
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => _openSetup(context),
                  icon: const Icon(Icons.settings_input_antenna),
                  label: const Text('Set Up VitalSense'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
            if (error == null) ...[
              const SizedBox(height: 24),
              TextButton.icon(
                onPressed: () => _onRetryPressed(context),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Try Again'),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF21638D),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
