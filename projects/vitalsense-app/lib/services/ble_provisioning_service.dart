import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/ble_provisioning_models.dart';
import '../models/wifi_provisioning_status.dart';

abstract interface class ProvisioningService {
  Stream<List<ProvisioningDevice>> get scanResults;
  Stream<ProvisioningStatus> get statuses;
  Stream<BleConnectionPhase> get connectionPhases;

  Future<void> scan();
  Future<void> connect(ProvisioningDevice device);
  Future<void> sendCredentials({
    required String ssid,
    required String password,
  });
  Future<void> requestStatus();
  Future<void> clearCredentials();
  Future<void> enableBluetooth();
  Future<void> openPermissionsSettings();
  Future<void> disconnect();
  Future<void> dispose();
}

/// BLE transport used only for the VitalSense Wi-Fi provisioning GATT
/// service. It never discovers, subscribes to, or writes any EFR32 telemetry
/// service.
class BleProvisioningService implements ProvisioningService {
  static const String provisioningServiceUuid =
      '7a0a0101-5b8a-4f4c-9d1d-8b4e3d7a1000';
  static const String ssidCharacteristicUuid =
      '7a0a0102-5b8a-4f4c-9d1d-8b4e3d7a1000';
  static const String passwordCharacteristicUuid =
      '7a0a0103-5b8a-4f4c-9d1d-8b4e3d7a1000';
  static const String commandCharacteristicUuid =
      '7a0a0104-5b8a-4f4c-9d1d-8b4e3d7a1000';
  static const String statusCharacteristicUuid =
      '7a0a0105-5b8a-4f4c-9d1d-8b4e3d7a1000';

  static const MethodChannel _platformChannel =
      MethodChannel('com.vitalsense.vitalsense_app/platform');
  static const Duration _scanDuration = Duration(seconds: 10);
  static const Duration _connectionTimeout = Duration(seconds: 15);

  final StreamController<List<ProvisioningDevice>> _scanController =
      StreamController<List<ProvisioningDevice>>.broadcast();
  final StreamController<ProvisioningStatus> _statusController =
      StreamController<ProvisioningStatus>.broadcast();
  final StreamController<BleConnectionPhase> _phaseController =
      StreamController<BleConnectionPhase>.broadcast();

  final Map<String, ProvisioningDevice> _devices = {};
  final Map<String, BluetoothDevice> _bluetoothDevices = {};
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<List<int>>? _statusSubscription;
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _ssidCharacteristic;
  BluetoothCharacteristic? _passwordCharacteristic;
  BluetoothCharacteristic? _commandCharacteristic;
  BluetoothCharacteristic? _statusCharacteristic;
  bool _connectionEstablished = false;
  bool _disconnectRequested = false;
  bool _commandInProgress = false;

  @override
  Stream<List<ProvisioningDevice>> get scanResults => _scanController.stream;

  @override
  Stream<ProvisioningStatus> get statuses => _statusController.stream;

  @override
  Stream<BleConnectionPhase> get connectionPhases => _phaseController.stream;

  @override
  Future<void> scan() async {
    await _ensureBleReady();
    await disconnect();
    await FlutterBluePlus.stopScan();

    _devices.clear();
    _bluetoothDevices.clear();
    _scanController.add(const []);
    await _scanSubscription?.cancel();
    _scanSubscription = FlutterBluePlus.scanResults.listen(
      _handleScanResults,
      onError: (Object error) {
        _scanController.addError(
          const ProvisioningException(
            ProvisioningErrorCode.unknown,
            'Could not scan for nearby VitalSense devices.',
          ),
        );
      },
    );

    debugPrint('BLE scan started');
    try {
      // Scan broadly so devices that omit service UUIDs from advertisements can
      // still be accepted by the guarded VitalSense name-prefix fallback.
      await FlutterBluePlus.startScan(
        timeout: _scanDuration,
        androidUsesFineLocation: await _androidRequiresLocation(),
      );
      await FlutterBluePlus.isScanning
          .where((isScanning) => !isScanning)
          .first
          .timeout(_scanDuration + const Duration(seconds: 2));
    } on TimeoutException {
      await FlutterBluePlus.stopScan();
    } catch (error) {
      throw _mapPlatformError(
        error,
        fallback: 'Could not scan for nearby VitalSense devices.',
      );
    }
  }

  void _handleScanResults(List<ScanResult> results) {
    for (final result in results) {
      final advertisedName = result.advertisementData.advName.trim();
      final platformName = result.device.platformName.trim();
      final name = advertisedName.isNotEmpty ? advertisedName : platformName;
      final hasService = result.advertisementData.serviceUuids.any(
        (uuid) => uuid.toString().toLowerCase() == provisioningServiceUuid,
      );
      final hasVitalSenseName = name == 'VitalSense' ||
          name.startsWith('VitalSense-') ||
          name.startsWith('VS-');

      if (!hasService && !hasVitalSenseName) continue;

      final id = result.device.remoteId.str;
      _devices[id] = ProvisioningDevice(
        id: id,
        name: name.isEmpty ? 'VitalSense device' : name,
        rssi: result.rssi,
        advertisesProvisioningService: hasService,
      );
      _bluetoothDevices[id] = result.device;
    }

    final sorted = _devices.values.toList()
      ..sort((a, b) {
        if (a.advertisesProvisioningService !=
            b.advertisesProvisioningService) {
          return a.advertisesProvisioningService ? -1 : 1;
        }
        return b.rssi.compareTo(a.rssi);
      });
    _scanController.add(List.unmodifiable(sorted));
  }

  @override
  Future<void> connect(ProvisioningDevice device) async {
    await _ensureBleReady();
    final bluetoothDevice = _bluetoothDevices[device.id];
    if (bluetoothDevice == null) {
      throw const ProvisioningException(
        ProvisioningErrorCode.unknown,
        'That VitalSense device is no longer available. Scan again.',
      );
    }

    await FlutterBluePlus.stopScan();
    await disconnect();
    _disconnectRequested = false;
    _connectedDevice = bluetoothDevice;
    _phaseController.add(BleConnectionPhase.connecting);

    await _connectionSubscription?.cancel();
    _connectionSubscription = bluetoothDevice.connectionState.listen(
      (connectionState) {
        if (connectionState == BluetoothConnectionState.connected) {
          _connectionEstablished = true;
        } else if (connectionState == BluetoothConnectionState.disconnected &&
            _connectionEstablished) {
          _connectionEstablished = false;
          _clearCharacteristics();
          if (!_disconnectRequested) {
            _phaseController.add(BleConnectionPhase.disconnected);
          }
        }
      },
    );

    try {
      await bluetoothDevice.connect(
        timeout: _connectionTimeout,
        autoConnect: false,
      );
      debugPrint('BLE connected');
      _phaseController.add(BleConnectionPhase.discoveringServices);

      final services = await bluetoothDevice.discoverServices();
      final provisioningService = _findService(services);
      _resolveCharacteristics(provisioningService.characteristics);
      debugPrint('Provisioning service discovered');

      // Subscribe before requesting STATUS so the first response cannot be
      // missed. Only the provisioning status characteristic is touched.
      _statusSubscription = _statusCharacteristic!.onValueReceived.listen(
        _handleStatusValue,
        onError: (_) => _statusController.add(
          const ProvisioningStatus(
            type: ProvisioningStatusType.malformed,
            reason: 'Status notifications stopped unexpectedly.',
          ),
        ),
      );
      await _statusCharacteristic!.setNotifyValue(true);
      _phaseController.add(BleConnectionPhase.ready);
      await requestStatus();
    } on TimeoutException {
      await disconnect();
      throw const ProvisioningException(
        ProvisioningErrorCode.connectionTimeout,
        'Connection timed out. Move closer to VitalSense and try again.',
      );
    } on ProvisioningException {
      await disconnect();
      rethrow;
    } catch (error) {
      await disconnect();
      throw _mapPlatformError(
        error,
        fallback: 'Could not connect to VitalSense.',
      );
    }
  }

  BluetoothService _findService(List<BluetoothService> services) {
    for (final service in services) {
      if (service.uuid.toString().toLowerCase() == provisioningServiceUuid) {
        return service;
      }
    }
    throw const ProvisioningException(
      ProvisioningErrorCode.serviceNotFound,
      'This device does not expose the VitalSense Wi-Fi setup service.',
    );
  }

  void _resolveCharacteristics(List<BluetoothCharacteristic> characteristics) {
    for (final characteristic in characteristics) {
      switch (characteristic.uuid.toString().toLowerCase()) {
        case ssidCharacteristicUuid:
          _ssidCharacteristic = characteristic;
        case passwordCharacteristicUuid:
          _passwordCharacteristic = characteristic;
        case commandCharacteristicUuid:
          _commandCharacteristic = characteristic;
        case statusCharacteristicUuid:
          _statusCharacteristic = characteristic;
      }
    }

    if (_ssidCharacteristic == null ||
        _passwordCharacteristic == null ||
        _commandCharacteristic == null ||
        _statusCharacteristic == null) {
      throw const ProvisioningException(
        ProvisioningErrorCode.characteristicNotFound,
        'VitalSense Wi-Fi setup is incomplete on this device.',
      );
    }
  }

  void _handleStatusValue(List<int> value) {
    try {
      final response = utf8.decode(value, allowMalformed: false);
      _statusController.add(ProvisioningStatus.parse(response));
    } catch (_) {
      _statusController.add(
        const ProvisioningStatus(
          type: ProvisioningStatusType.malformed,
          reason: 'The device returned an unreadable setup response.',
        ),
      );
    }
  }

  @override
  Future<void> sendCredentials({
    required String ssid,
    required String password,
  }) async {
    if (_commandInProgress) return;
    _requireReady();
    _commandInProgress = true;
    try {
      await _write(
        _ssidCharacteristic!,
        utf8.encode(ssid),
        ProvisioningErrorCode.ssidWriteFailed,
        'Could not send the Wi-Fi network name.',
      );
      debugPrint('SSID sent');
      await _write(
        _passwordCharacteristic!,
        utf8.encode(password),
        ProvisioningErrorCode.passwordWriteFailed,
        'Could not send the Wi-Fi password.',
      );
      await _writeCommand('CONNECT');
      debugPrint('Wi-Fi connecting');
    } finally {
      _commandInProgress = false;
    }
  }

  @override
  Future<void> requestStatus() => _writeCommand('STATUS');

  @override
  Future<void> clearCredentials() => _writeCommand('CLEAR');

  Future<void> _writeCommand(String command) async {
    _requireReady();
    await _write(
      _commandCharacteristic!,
      utf8.encode(command),
      ProvisioningErrorCode.commandWriteFailed,
      'VitalSense did not accept the setup command.',
    );
  }

  Future<void> _write(
    BluetoothCharacteristic characteristic,
    List<int> value,
    ProvisioningErrorCode code,
    String message,
  ) async {
    try {
      final useWriteWithoutResponse = !characteristic.properties.write &&
          characteristic.properties.writeWithoutResponse;
      await characteristic
          .write(value, withoutResponse: useWriteWithoutResponse)
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      throw ProvisioningException(code, message);
    }
  }

  void _requireReady() {
    if (_connectedDevice == null ||
        !_connectionEstablished ||
        _commandCharacteristic == null) {
      throw const ProvisioningException(
        ProvisioningErrorCode.disconnected,
        'The VitalSense setup connection was lost.',
      );
    }
  }

  Future<void> _ensureBleReady() async {
    if (!await FlutterBluePlus.isSupported) {
      throw const ProvisioningException(
        ProvisioningErrorCode.bluetoothUnsupported,
        'This phone does not support Bluetooth Low Energy.',
      );
    }

    await _requestPermissions();
    BluetoothAdapterState adapterState;
    try {
      adapterState = await FlutterBluePlus.adapterState
          .where((state) => state != BluetoothAdapterState.unknown)
          .first
          .timeout(const Duration(seconds: 4));
    } catch (_) {
      throw const ProvisioningException(
        ProvisioningErrorCode.bluetoothDisabled,
        'Bluetooth is unavailable. Turn it on to set up VitalSense.',
      );
    }

    if (adapterState != BluetoothAdapterState.on) {
      throw const ProvisioningException(
        ProvisioningErrorCode.bluetoothDisabled,
        'Bluetooth is required only while setting up VitalSense Wi-Fi.',
      );
    }
  }

  Future<void> _requestPermissions() async {
    if (!Platform.isAndroid) return;
    final sdk = await _androidSdkInt();
    final permissions = sdk >= 31
        ? <Permission>[Permission.bluetoothScan, Permission.bluetoothConnect]
        : <Permission>[Permission.locationWhenInUse];
    final statuses = await permissions.request();
    if (statuses.values.any((status) => !status.isGranted)) {
      throw const ProvisioningException(
        ProvisioningErrorCode.permissionDenied,
        'Nearby-device permission is needed to find and configure VitalSense.',
      );
    }
  }

  Future<bool> _androidRequiresLocation() async {
    return Platform.isAndroid && await _androidSdkInt() <= 30;
  }

  Future<int> _androidSdkInt() async {
    if (!Platform.isAndroid) return 0;
    try {
      return await _platformChannel.invokeMethod<int>('androidSdkInt') ?? 31;
    } catch (_) {
      return 31;
    }
  }

  @override
  Future<void> enableBluetooth() async {
    if (!Platform.isAndroid) {
      throw const ProvisioningException(
        ProvisioningErrorCode.bluetoothDisabled,
        'Turn on Bluetooth in Settings, then try again.',
      );
    }
    try {
      await FlutterBluePlus.turnOn();
    } catch (_) {
      throw const ProvisioningException(
        ProvisioningErrorCode.bluetoothDisabled,
        'Turn on Bluetooth in Settings, then try again.',
      );
    }
  }

  @override
  Future<void> openPermissionsSettings() async {
    await openAppSettings();
  }

  ProvisioningException _mapPlatformError(
    Object error, {
    required String fallback,
  }) {
    final description = error.toString().toLowerCase();
    if (description.contains('permission')) {
      return const ProvisioningException(
        ProvisioningErrorCode.permissionDenied,
        'Nearby-device permission is needed to find and configure VitalSense.',
      );
    }
    if (description.contains('turned off') ||
        description.contains('adapter is not on')) {
      return const ProvisioningException(
        ProvisioningErrorCode.bluetoothDisabled,
        'Bluetooth is required only while setting up VitalSense Wi-Fi.',
      );
    }
    return ProvisioningException(ProvisioningErrorCode.unknown, fallback);
  }

  @override
  Future<void> disconnect() async {
    _disconnectRequested = true;
    await _statusSubscription?.cancel();
    _statusSubscription = null;
    if (_statusCharacteristic?.isNotifying == true) {
      try {
        await _statusCharacteristic!.setNotifyValue(false);
      } catch (_) {
        // The peripheral may already have dropped the provisioning link.
      }
    }
    try {
      await _connectedDevice?.disconnect();
    } catch (_) {
      // Disconnect is idempotent from the app's perspective.
    }
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    _connectedDevice = null;
    _connectionEstablished = false;
    _clearCharacteristics();
  }

  void _clearCharacteristics() {
    _ssidCharacteristic = null;
    _passwordCharacteristic = null;
    _commandCharacteristic = null;
    _statusCharacteristic = null;
  }

  @override
  Future<void> dispose() async {
    await FlutterBluePlus.stopScan();
    await _scanSubscription?.cancel();
    await disconnect();
    await _scanController.close();
    await _statusController.close();
    await _phaseController.close();
  }
}
