import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/vital_sense_provider.dart';
import '../widgets/bed_status_card.dart';
import '../widgets/position_card.dart';
import '../widgets/risk_assessment_card.dart';
import '../widgets/fsr_grid.dart';
import '../widgets/connection_status_badge.dart';
import '../widgets/discovering_view.dart';
import 'diagnostics_screen.dart';
import 'settings_screen.dart';
import 'logs_screen.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9F9FF),
      appBar: _buildAppBar(context),
      body: Consumer<VitalSenseProvider>(
        builder: (context, provider, _) {
          final device = provider.selectedDevice;
          if (device == null) {
            return const DiscoveringView();
          }

          return RefreshIndicator(
            onRefresh: () => provider.reconnect(),
            child: ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 20.0,
              ),
              children: [
                // Bed Status + Connection
                BedStatusCard(device: device),
                const SizedBox(height: 16),

                // Position + Duration
                PositionCard(data: device.data),
                const SizedBox(height: 16),

                // Risk Assessment
                RiskAssessmentCard(data: device.data),
                const SizedBox(height: 16),

                // FSR Raw Values
                FsrGrid(fsr: device.data.fsr, plates: device.data.plates),
                const SizedBox(height: 24),
              ],
            ),
          );
        },
      ),
      bottomNavigationBar: _buildBottomNav(context),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      backgroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 1,
      shadowColor: const Color(0xFFC1C7CF),
      title: Row(
        children: [
          const Icon(
            Icons.monitor_heart_rounded,
            color: Color(0xFF21638D),
            size: 28,
          ),
          const SizedBox(width: 10),
          Text(
            'VitalSense',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: const Color(0xFF21638D),
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
      actions: [
        Consumer<VitalSenseProvider>(
          builder: (context, provider, _) {
            final device = provider.selectedDevice;
            if (device != null) {
              final isOfflineOrStale = device.connectionStatus == ConnectionStatus.offline ||
                  device.connectionStatus == ConnectionStatus.stale;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8.0),
                    child: Center(
                      child: ConnectionStatusBadge(
                        status: device.connectionStatus,
                      ),
                    ),
                  ),
                  if (isOfflineOrStale)
                    IconButton(
                      icon: const Icon(Icons.refresh_rounded, color: Color(0xFF21638D)),
                      onPressed: () => provider.reconnect(),
                      tooltip: 'Reconnect',
                    ),
                ],
              );
            }
            return const SizedBox.shrink();
          },
        ),
        IconButton(
          icon: const Icon(Icons.person_outline_rounded,
              color: Color(0xFF21638D)),
          onPressed: () {},
          tooltip: 'Account',
        ),
      ],
    );
  }

  Widget _buildBottomNav(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          top: BorderSide(color: const Color(0xFFC1C7CF).withValues(alpha: 0.5)),
        ),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1E293B).withValues(alpha: 0.05),
            blurRadius: 15,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _NavItem(
                icon: Icons.dashboard_rounded,
                label: 'Dashboard',
                isActive: true,
                onTap: () {},
              ),
              _NavItem(
                icon: Icons.history_rounded,
                label: 'Logs',
                isActive: false,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const LogsScreen()),
                  );
                },
              ),
              _NavItem(
                icon: Icons.build_circle_outlined,
                label: 'Diagnostics',
                isActive: false,
                onTap: () {
                  final provider = context.read<VitalSenseProvider>();
                  final device = provider.selectedDevice;
                  if (device != null) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            DiagnosticsScreen(device: device),
                      ),
                    );
                  }
                },
              ),
              _NavItem(
                icon: Icons.settings_outlined,
                label: 'Settings',
                isActive: false,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isActive
        ? const Color(0xFF21638D)
        : const Color(0xFF71787F);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isActive
              ? const Color(0xFF90CAF9).withValues(alpha: 0.25)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight:
                    isActive ? FontWeight.w700 : FontWeight.w500,
                color: color,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
