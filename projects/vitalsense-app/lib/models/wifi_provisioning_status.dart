enum ProvisioningStatusType {
  noCredentials,
  ssidReceived,
  passwordReceived,
  connecting,
  connected,
  failed,
  disconnected,
  malformed,
}

/// Typed representation of a response from the ESP32 Wi-Fi provisioning
/// status characteristic.
class ProvisioningStatus {
  final ProvisioningStatusType type;
  final String? ssid;
  final String? ipAddress;
  final String? reason;

  const ProvisioningStatus({
    required this.type,
    this.ssid,
    this.ipAddress,
    this.reason,
  });

  factory ProvisioningStatus.parse(String value) {
    final message = value.trim();
    final parts = message.split('|');

    switch (parts.firstOrNull) {
      case 'NO_CREDENTIALS':
        return parts.length == 1
            ? const ProvisioningStatus(
                type: ProvisioningStatusType.noCredentials,
              )
            : _malformed(message);
      case 'SSID_RECEIVED':
        return parts.length == 1
            ? const ProvisioningStatus(
                type: ProvisioningStatusType.ssidReceived,
              )
            : _malformed(message);
      case 'PASSWORD_RECEIVED':
        return parts.length == 1
            ? const ProvisioningStatus(
                type: ProvisioningStatusType.passwordReceived,
              )
            : _malformed(message);
      case 'CONNECTING':
        return parts.length == 2 && parts[1].isNotEmpty
            ? ProvisioningStatus(
                type: ProvisioningStatusType.connecting,
                ssid: parts[1],
              )
            : _malformed(message);
      case 'CONNECTED':
        return parts.length == 3 && parts[1].isNotEmpty && parts[2].isNotEmpty
            ? ProvisioningStatus(
                type: ProvisioningStatusType.connected,
                ssid: parts[1],
                ipAddress: parts[2],
              )
            : _malformed(message);
      case 'FAILED':
        return parts.length == 2 && parts[1].isNotEmpty
            ? ProvisioningStatus(
                type: ProvisioningStatusType.failed,
                reason: parts[1],
              )
            : _malformed(message);
      case 'DISCONNECTED':
        return parts.length == 2 && parts[1].isNotEmpty
            ? ProvisioningStatus(
                type: ProvisioningStatusType.disconnected,
                ssid: parts[1],
              )
            : _malformed(message);
      default:
        return _malformed(message);
    }
  }

  static ProvisioningStatus _malformed(String value) {
    return ProvisioningStatus(
      type: ProvisioningStatusType.malformed,
      reason: value.isEmpty ? 'Empty status response' : 'Unexpected response',
    );
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
