enum ProvisioningState {
  idle,
  scanning,
  noDevicesFound,
  connectingBle,
  discoveringServices,
  readyForCredentials,
  sendingCredentials,
  connectingWifi,
  alreadyConnected,
  wifiConnected,
  waitingForUdp,
  udpTimedOut,
  completed,
  wifiFailed,
  bleDisconnected,
  bluetoothDisabled,
  bluetoothUnsupported,
  permissionDenied,
  credentialsCleared,
  error,
}

enum BleConnectionPhase {
  disconnected,
  connecting,
  discoveringServices,
  ready,
}

class ProvisioningDevice {
  final String id;
  final String name;
  final int rssi;
  final bool advertisesProvisioningService;

  const ProvisioningDevice({
    required this.id,
    required this.name,
    required this.rssi,
    required this.advertisesProvisioningService,
  });

  String get signalLabel {
    if (rssi >= -60) return 'Strong';
    if (rssi >= -75) return 'Medium';
    return 'Weak';
  }
}

enum ProvisioningErrorCode {
  bluetoothUnsupported,
  bluetoothDisabled,
  permissionDenied,
  connectionTimeout,
  disconnected,
  serviceNotFound,
  characteristicNotFound,
  ssidWriteFailed,
  passwordWriteFailed,
  commandWriteFailed,
  malformedResponse,
  unknown,
}

class ProvisioningException implements Exception {
  final ProvisioningErrorCode code;
  final String message;

  const ProvisioningException(this.code, this.message);

  @override
  String toString() => message;
}
