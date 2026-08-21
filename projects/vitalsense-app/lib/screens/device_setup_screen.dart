import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/ble_provisioning_models.dart';
import '../models/wifi_provisioning_status.dart';
import '../providers/ble_provisioning_provider.dart';

class DeviceSetupScreen extends StatefulWidget {
  const DeviceSetupScreen({super.key});

  @override
  State<DeviceSetupScreen> createState() => _DeviceSetupScreenState();
}

class _DeviceSetupScreenState extends State<DeviceSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _ssidController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _showPassword = false;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<BleProvisioningProvider>();
      provider.addListener(_handleProviderChange);
      provider.startScan();
    });
  }

  void _handleProviderChange() {
    if (!mounted || _closing) return;
    final provider = context.read<BleProvisioningProvider>();
    if (provider.state == ProvisioningState.completed) {
      _closing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop(true);
      });
    }
  }

  @override
  void dispose() {
    final provider = context.read<BleProvisioningProvider>();
    provider.removeListener(_handleProviderChange);
    _passwordController.clear();
    _passwordController.dispose();
    _ssidController.dispose();
    super.dispose();
  }

  Future<void> _cancel() async {
    if (_closing) return;
    _closing = true;
    await context.read<BleProvisioningProvider>().cancelSetup();
    if (mounted) Navigator.of(context).pop(false);
  }

  Future<void> _submitCredentials() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final provider = context.read<BleProvisioningProvider>();
    final password = _passwordController.text;
    await provider.submitCredentials(
      ssid: _ssidController.text,
      password: password,
    );
    // Do not retain the password after the transport operation completes.
    _passwordController.clear();
  }

  Future<void> _confirmForgetWifi() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Forget Wi-Fi Configuration?'),
        content: const Text(
          'This will remove the Wi-Fi credentials stored on the VitalSense device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFBA1A1A),
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Forget Wi-Fi'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await context.read<BleProvisioningProvider>().forgetCredentials();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF9F9FF),
        appBar: AppBar(
          title: const Text('Set Up VitalSense'),
          backgroundColor: Colors.white,
          leading: IconButton(
            onPressed: _cancel,
            icon: const Icon(Icons.close),
            tooltip: 'Cancel setup',
          ),
        ),
        body: SafeArea(
          child: Consumer<BleProvisioningProvider>(
            builder: (context, provider, _) => AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _buildState(context, provider),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildState(
    BuildContext context,
    BleProvisioningProvider provider,
  ) {
    switch (provider.state) {
      case ProvisioningState.idle:
      case ProvisioningState.scanning:
      case ProvisioningState.noDevicesFound:
        return _buildScanner(provider);
      case ProvisioningState.connectingBle:
        return _buildProgress(
          icon: Icons.bluetooth_searching,
          title: 'Connecting to VitalSense',
          message: provider.selectedDevice?.name ?? 'Selected device',
        );
      case ProvisioningState.discoveringServices:
        return _buildProgress(
          icon: Icons.settings_input_antenna,
          title: 'Preparing Device Setup',
          message: 'Checking the VitalSense Wi-Fi setup service...',
        );
      case ProvisioningState.readyForCredentials:
        return _buildCredentials(provider);
      case ProvisioningState.sendingCredentials:
      case ProvisioningState.connectingWifi:
        return _buildConnectingWifi(provider);
      case ProvisioningState.alreadyConnected:
        return _buildAlreadyConnected(provider);
      case ProvisioningState.wifiConnected:
        return _buildWifiConnected(provider);
      case ProvisioningState.waitingForUdp:
        return _buildWaitingForUdp(provider);
      case ProvisioningState.udpTimedOut:
        return _buildUdpTimeout(provider);
      case ProvisioningState.wifiFailed:
        return _buildWifiFailure(provider);
      case ProvisioningState.bleDisconnected:
        return _buildConnectionLost(provider);
      case ProvisioningState.bluetoothDisabled:
        return _buildBluetoothDisabled(provider);
      case ProvisioningState.bluetoothUnsupported:
        return _buildError(
          title: 'Bluetooth Not Supported',
          message: provider.errorMessage ??
              'This phone cannot configure VitalSense over Bluetooth.',
          primaryLabel: 'Cancel',
          onPrimary: _cancel,
        );
      case ProvisioningState.permissionDenied:
        return _buildPermissionDenied(provider);
      case ProvisioningState.credentialsCleared:
        return _buildCredentialsCleared(provider);
      case ProvisioningState.error:
        return _buildError(
          title: 'Setup Could Not Continue',
          message: provider.errorMessage ?? 'Please try again.',
          primaryLabel:
              provider.selectedDevice == null ? 'Scan Again' : 'Reconnect',
          onPrimary: provider.selectedDevice == null
              ? provider.startScan
              : provider.reconnectSelectedDevice,
          secondaryLabel: 'Cancel',
          onSecondary: _cancel,
        );
      case ProvisioningState.completed:
        return _buildProgress(
          icon: Icons.check_circle,
          title: 'Device Discovered',
          message: 'Opening the VitalSense dashboard...',
        );
    }
  }

  Widget _buildScanner(BleProvisioningProvider provider) {
    final scanning = provider.state == ProvisioningState.scanning ||
        provider.state == ProvisioningState.idle;
    return ListView(
      key: const ValueKey('scanner'),
      padding: const EdgeInsets.all(20),
      children: [
        const Icon(
          Icons.sensors_rounded,
          size: 52,
          color: Color(0xFF21638D),
        ),
        const SizedBox(height: 16),
        Text(
          scanning
              ? 'Searching for nearby VitalSense devices...'
              : 'No VitalSense devices found',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: Color(0xFF111C2D),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Keep the VitalSense unit powered on and stay nearby.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFF71787F), height: 1.5),
        ),
        if (scanning) ...[
          const SizedBox(height: 18),
          const LinearProgressIndicator(),
        ],
        const SizedBox(height: 24),
        if (provider.devices.isNotEmpty) ...[
          const Text(
            'Nearby VitalSense Devices',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
          const SizedBox(height: 10),
          ...provider.devices.map((device) => _DeviceCard(
                device: device,
                onConnect: () => provider.connect(device),
              )),
        ],
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: scanning ? null : provider.startScan,
          icon: const Icon(Icons.refresh),
          label: const Text('Scan Again'),
        ),
        TextButton(onPressed: _cancel, child: const Text('Cancel')),
      ],
    );
  }

  Widget _buildCredentials(BleProvisioningProvider provider) {
    final statusSsid = provider.lastStatus?.ssid;
    if (_ssidController.text.isEmpty && statusSsid != null) {
      _ssidController.text = statusSsid;
    }
    final mayHaveCredentials =
        provider.lastStatus?.type != ProvisioningStatusType.noCredentials;
    return ListView(
      key: const ValueKey('credentials'),
      padding: const EdgeInsets.all(20),
      children: [
        const _StepHeader(
          step: '2 of 4',
          title: 'Connect VitalSense to Wi-Fi',
          subtitle: 'Enter the network used by this phone.',
        ),
        const SizedBox(height: 20),
        _DeviceIdentity(name: provider.selectedDevice?.name),
        const SizedBox(height: 20),
        Form(
          key: _formKey,
          child: Column(
            children: [
              TextFormField(
                controller: _ssidController,
                autofocus: true,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Wi-Fi Network',
                  hintText: 'Network name',
                  prefixIcon: Icon(Icons.wifi),
                  border: OutlineInputBorder(),
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Wi-Fi network is required'
                    : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _passwordController,
                obscureText: !_showPassword,
                enableSuggestions: false,
                autocorrect: false,
                onFieldSubmitted: (_) => _submitCredentials(),
                decoration: InputDecoration(
                  labelText: 'Password',
                  helperText: 'Leave empty for an open network',
                  prefixIcon: const Icon(Icons.lock_outline),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    onPressed: () =>
                        setState(() => _showPassword = !_showPassword),
                    icon: Icon(
                      _showPassword ? Icons.visibility_off : Icons.visibility,
                    ),
                    tooltip: _showPassword ? 'Hide password' : 'Show password',
                  ),
                ),
              ),
            ],
          ),
        ),
        if (provider.errorMessage != null) ...[
          const SizedBox(height: 12),
          _InlineMessage(
            message: provider.errorMessage!,
            color: const Color(0xFFF57F17),
          ),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _submitCredentials,
          icon: const Icon(Icons.wifi_rounded),
          label: const Text('Connect to Wi-Fi'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
        if (mayHaveCredentials) ...[
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _confirmForgetWifi,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Forget Device Wi-Fi'),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFBA1A1A),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildConnectingWifi(BleProvisioningProvider provider) {
    return _buildProgress(
      key: const ValueKey('connecting-wifi'),
      icon: Icons.wifi_find,
      title: 'Connecting VitalSense',
      message:
          'Connecting VitalSense to:\n\n${provider.configuredSsid ?? _ssidController.text}\n\nPlease keep the VitalSense device powered on.',
    );
  }

  Widget _buildAlreadyConnected(BleProvisioningProvider provider) {
    return _CenteredPanel(
      key: const ValueKey('already-connected'),
      icon: Icons.check_circle,
      iconColor: const Color(0xFF006D36),
      title: 'VitalSense is already connected',
      message:
          'Network:\n${provider.configuredSsid ?? 'Unknown'}\n\nIP:\n${provider.provisionedIp ?? 'Unknown'}',
      children: [
        FilledButton(
          onPressed: provider.continueToDashboard,
          child: const Text('Continue to Dashboard'),
        ),
        OutlinedButton(
          onPressed: provider.changeWifi,
          child: const Text('Change Wi-Fi'),
        ),
        TextButton.icon(
          onPressed: _confirmForgetWifi,
          icon: const Icon(Icons.delete_outline),
          label: const Text('Forget Device Wi-Fi'),
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFFBA1A1A),
          ),
        ),
      ],
    );
  }

  Widget _buildWifiConnected(BleProvisioningProvider provider) {
    return _CenteredPanel(
      key: const ValueKey('wifi-connected'),
      icon: Icons.check_circle,
      iconColor: const Color(0xFF006D36),
      title: 'VitalSense Connected',
      message:
          'VitalSense successfully joined:\n${provider.configuredSsid}\n\nDevice IP\n${provider.provisionedIp}\n\nSwitching to live monitoring...',
    );
  }

  Widget _buildWaitingForUdp(BleProvisioningProvider provider) {
    return _CenteredPanel(
      key: const ValueKey('waiting-udp'),
      icon: Icons.monitor_heart_outlined,
      iconColor: const Color(0xFF21638D),
      title: 'Wi-Fi connected',
      message:
          'Waiting for VitalSense data...\n\nThe dashboard is listening for a valid VitalSense broadcast.',
      showProgress: true,
      children: [
        TextButton(
            onPressed: _cancel, child: const Text('Continue in Background')),
      ],
    );
  }

  Widget _buildUdpTimeout(BleProvisioningProvider provider) {
    return _CenteredPanel(
      key: const ValueKey('udp-timeout'),
      icon: Icons.wifi_off_rounded,
      iconColor: const Color(0xFFF57F17),
      title: 'Live Data Not Detected Yet',
      message:
          'VitalSense joined Wi-Fi successfully, but live data has not been detected yet.\n\nMake sure this phone is connected to:\n${provider.configuredSsid ?? 'the same Wi-Fi network'}\n\nDevice IP:\n${provider.provisionedIp ?? 'Unknown'}',
      children: [
        FilledButton(
          onPressed: provider.keepListening,
          child: const Text('Keep Listening'),
        ),
        OutlinedButton(
          onPressed: provider.startScan,
          child: const Text('Configure Wi-Fi Again'),
        ),
      ],
    );
  }

  Widget _buildWifiFailure(BleProvisioningProvider provider) {
    return _CenteredPanel(
      key: const ValueKey('wifi-failed'),
      icon: Icons.error_outline,
      iconColor: const Color(0xFFBA1A1A),
      title: 'Could Not Connect',
      message: provider.errorMessage ??
          'VitalSense could not connect to the selected Wi-Fi network.\n\nCheck the Wi-Fi name, password, and signal strength.',
      children: [
        FilledButton(
          onPressed: provider.retryCredentials,
          child: const Text('Try Again'),
        ),
        TextButton(onPressed: _cancel, child: const Text('Cancel')),
      ],
    );
  }

  Widget _buildConnectionLost(BleProvisioningProvider provider) {
    return _CenteredPanel(
      key: const ValueKey('connection-lost'),
      icon: Icons.bluetooth_disabled,
      iconColor: const Color(0xFFBA1A1A),
      title: 'Connection Lost',
      message: provider.errorMessage ??
          'The connection to VitalSense was interrupted.',
      children: [
        FilledButton(
          onPressed: provider.reconnectSelectedDevice,
          child: const Text('Reconnect'),
        ),
        TextButton(onPressed: _cancel, child: const Text('Cancel')),
      ],
    );
  }

  Widget _buildBluetoothDisabled(BleProvisioningProvider provider) {
    return _CenteredPanel(
      key: const ValueKey('bluetooth-disabled'),
      icon: Icons.bluetooth_disabled,
      iconColor: const Color(0xFF21638D),
      title: 'Bluetooth Required',
      message:
          'Bluetooth is required only while setting up or changing VitalSense Wi-Fi.',
      children: [
        FilledButton(
          onPressed: provider.enableBluetoothAndScan,
          child: const Text('Enable Bluetooth'),
        ),
        TextButton(onPressed: _cancel, child: const Text('Cancel')),
      ],
    );
  }

  Widget _buildPermissionDenied(BleProvisioningProvider provider) {
    return _CenteredPanel(
      key: const ValueKey('permission-denied'),
      icon: Icons.location_disabled,
      iconColor: const Color(0xFFF57F17),
      title: 'Nearby Devices Permission Needed',
      message: provider.errorMessage ??
          'Allow nearby-device access to find VitalSense during Wi-Fi setup.',
      children: [
        FilledButton(
          onPressed: provider.startScan,
          child: const Text('Try Again'),
        ),
        OutlinedButton(
          onPressed: provider.openPermissionsSettings,
          child: const Text('Open App Settings'),
        ),
        TextButton(onPressed: _cancel, child: const Text('Cancel')),
      ],
    );
  }

  Widget _buildCredentialsCleared(BleProvisioningProvider provider) {
    return _CenteredPanel(
      key: const ValueKey('credentials-cleared'),
      icon: Icons.check_circle_outline,
      iconColor: const Color(0xFF006D36),
      title: 'Wi-Fi configuration removed.',
      message: 'VitalSense is ready to be configured for another network.',
      children: [
        FilledButton(
          onPressed: provider.credentialsClearedAcknowledged,
          child: const Text('Set Up Wi-Fi'),
        ),
        TextButton(onPressed: _cancel, child: const Text('Cancel')),
      ],
    );
  }

  Widget _buildError({
    required String title,
    required String message,
    required String primaryLabel,
    required VoidCallback onPrimary,
    String? secondaryLabel,
    VoidCallback? onSecondary,
  }) {
    return _CenteredPanel(
      key: ValueKey(title),
      icon: Icons.error_outline,
      iconColor: const Color(0xFFBA1A1A),
      title: title,
      message: message,
      children: [
        FilledButton(onPressed: onPrimary, child: Text(primaryLabel)),
        if (secondaryLabel != null)
          TextButton(
            onPressed: onSecondary,
            child: Text(secondaryLabel),
          ),
      ],
    );
  }

  Widget _buildProgress({
    Key? key,
    required IconData icon,
    required String title,
    required String message,
  }) {
    return _CenteredPanel(
      key: key ?? ValueKey(title),
      icon: icon,
      iconColor: const Color(0xFF21638D),
      title: title,
      message: message,
      showProgress: true,
    );
  }
}

class _DeviceCard extends StatelessWidget {
  final ProvisioningDevice device;
  final VoidCallback onConnect;

  const _DeviceCard({required this.device, required this.onConnect});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            const CircleAvatar(
              backgroundColor: Color(0xFFE7EEFF),
              child: Icon(Icons.single_bed, color: Color(0xFF21638D)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    device.name,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Signal: ${device.signalLabel}',
                    style: const TextStyle(color: Color(0xFF71787F)),
                  ),
                ],
              ),
            ),
            FilledButton(onPressed: onConnect, child: const Text('Connect')),
          ],
        ),
      ),
    );
  }
}

class _StepHeader extends StatelessWidget {
  final String step;
  final String title;
  final String subtitle;

  const _StepHeader({
    required this.step,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          step.toUpperCase(),
          style: const TextStyle(
            color: Color(0xFF21638D),
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          title,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          style: const TextStyle(color: Color(0xFF71787F)),
        ),
      ],
    );
  }
}

class _DeviceIdentity extends StatelessWidget {
  final String? name;

  const _DeviceIdentity({required this.name});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFE7EEFF),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.single_bed, color: Color(0xFF21638D)),
          const SizedBox(width: 10),
          const Text('Device: ', style: TextStyle(color: Color(0xFF41474E))),
          Expanded(
            child: Text(
              name ?? 'VitalSense device',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _CenteredPanel extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String message;
  final bool showProgress;
  final List<Widget> children;

  const _CenteredPanel({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.message,
    this.showProgress = false,
    this.children = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 64, color: iconColor),
              const SizedBox(height: 20),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF111C2D),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF71787F),
                  height: 1.55,
                ),
              ),
              if (showProgress) ...[
                const SizedBox(height: 24),
                const CircularProgressIndicator(),
              ],
              if (children.isNotEmpty) ...[
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final child in children) ...[
                        child,
                        const SizedBox(height: 8),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineMessage extends StatelessWidget {
  final String message;
  final Color color;

  const _InlineMessage({required this.message, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}
