import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vitalsense_app/models/ble_provisioning_models.dart';
import 'package:vitalsense_app/models/vital_sense_data.dart';
import 'package:vitalsense_app/models/wifi_provisioning_status.dart';
import 'package:vitalsense_app/providers/ble_provisioning_provider.dart';
import 'package:vitalsense_app/services/ble_provisioning_service.dart';
import 'package:vitalsense_app/services/udp_service.dart';

void main() {
  late _FakeProvisioningService service;
  late StreamController<VitalSensePacket> udpPackets;
  late BleProvisioningProvider provider;

  setUp(() {
    service = _FakeProvisioningService();
    udpPackets = StreamController<VitalSensePacket>.broadcast();
    provider = BleProvisioningProvider(
      service: service,
      udpPackets: udpPackets.stream,
      connectedMessageDuration: Duration.zero,
      udpDiscoveryTimeout: const Duration(milliseconds: 100),
    );
  });

  tearDown(() async {
    provider.dispose();
    await udpPackets.close();
  });

  test('fresh device provisions over BLE then completes only after UDP',
      () async {
    await provider.startScan();
    await _flushEvents();
    final device = provider.devices.single;

    await provider.connect(device);
    service.emitStatus(
      const ProvisioningStatus(type: ProvisioningStatusType.noCredentials),
    );
    await _flushEvents();
    expect(provider.state, ProvisioningState.readyForCredentials);

    await provider.submitCredentials(
      ssid: 'Hospital_WiFi',
      password: 'temporary-secret',
    );
    expect(provider.state, ProvisioningState.connectingWifi);
    expect(service.commands, ['STATUS', 'CONNECT']);

    service.emitStatus(
      const ProvisioningStatus(
        type: ProvisioningStatusType.connected,
        ssid: 'Hospital_WiFi',
        ipAddress: '192.168.1.37',
      ),
    );
    await _flushEvents();
    expect(provider.state, ProvisioningState.waitingForUdp);
    expect(service.disconnectCount, 1);

    udpPackets.add(_packet(sourceIp: '192.168.1.37'));
    await _flushEvents();
    expect(provider.state, ProvisioningState.completed);
  });

  test('wrong password is recoverable without rescanning', () async {
    await provider.startScan();
    await _flushEvents();
    await provider.connect(provider.devices.single);
    await provider.submitCredentials(
      ssid: 'Hospital_WiFi',
      password: 'wrong',
    );

    service.emitStatus(
      const ProvisioningStatus(
        type: ProvisioningStatusType.failed,
        reason: 'CHECK_SSID_PASSWORD',
      ),
    );
    await _flushEvents();
    expect(provider.state, ProvisioningState.wifiFailed);

    provider.retryCredentials();
    expect(provider.state, ProvisioningState.readyForCredentials);
    expect(service.scanCount, 1);
    expect(service.connectedDevice?.id, 'device-1');
  });

  test('a delayed valid UDP packet completes waiting state', () async {
    await provider.startScan();
    await _flushEvents();
    await provider.connect(provider.devices.single);
    await _flushEvents();
    await provider.submitCredentials(ssid: 'Ward', password: 'secret');
    service.emitStatus(
      const ProvisioningStatus(
        type: ProvisioningStatusType.connected,
        ssid: 'Ward',
        ipAddress: '10.0.0.8',
      ),
    );
    await _flushEvents();
    expect(provider.state, ProvisioningState.waitingForUdp);

    udpPackets.add(_packet(sourceIp: '10.0.0.99'));
    await _flushEvents();
    expect(provider.state, ProvisioningState.waitingForUdp);

    udpPackets.add(_packet(sourceIp: '10.0.0.8'));
    await _flushEvents();
    expect(provider.state, ProvisioningState.completed);
  });

  test('the explicitly selected bed remains the provisioning target', () async {
    service.devices = const [
      ProvisioningDevice(
        id: 'device-1',
        name: 'VS-BED-01',
        rssi: -50,
        advertisesProvisioningService: true,
      ),
      ProvisioningDevice(
        id: 'device-2',
        name: 'VS-BED-02',
        rssi: -65,
        advertisesProvisioningService: true,
      ),
    ];
    await provider.startScan();
    await _flushEvents();

    await provider.connect(provider.devices[1]);
    await provider.submitCredentials(ssid: 'Ward', password: 'secret');

    expect(provider.selectedDevice?.name, 'VS-BED-02');
    expect(service.connectedDevice?.id, 'device-2');
  });

  test('STATUS response preserves existing working credentials', () async {
    await provider.startScan();
    await _flushEvents();
    await provider.connect(provider.devices.single);
    service.emitStatus(
      const ProvisioningStatus(
        type: ProvisioningStatusType.connected,
        ssid: 'ExistingNetwork',
        ipAddress: '192.168.1.44',
      ),
    );
    await _flushEvents();

    expect(provider.state, ProvisioningState.alreadyConnected);
    expect(service.commands, ['STATUS']);
  });
}

Future<void> _flushEvents() async {
  await Future<void>.delayed(const Duration(milliseconds: 20));
}

VitalSensePacket _packet({required String sourceIp}) {
  return (
    data: const VitalSenseData(
      protocol: 1,
      deviceId: 'VS-BED-01',
      bed: 1,
      position: 'CENTER',
      positionDuration: 1,
      plates: PlatesData(head: 1, shoulders: 2, hips: 3, heels: 4),
      fsr: [1, 2, 3, 4, 5, 6, 7, 8],
      riskValid: true,
      risk: RiskData(head: 1, shoulders: 2, hips: 3, heels: 4),
      highestRisk: HighestRisk(zone: 'HEELS', score: 4, level: 'LOW'),
      avoidReturn: AvoidReturnData(head: 0, shoulders: 0, hips: 0, heels: 0),
      uptime: 10,
    ),
    sourceIp: sourceIp,
  );
}

class _FakeProvisioningService implements ProvisioningService {
  final _scanController =
      StreamController<List<ProvisioningDevice>>.broadcast();
  final _statusController = StreamController<ProvisioningStatus>.broadcast();
  final _phaseController = StreamController<BleConnectionPhase>.broadcast();

  List<ProvisioningDevice> devices = const [
    ProvisioningDevice(
      id: 'device-1',
      name: 'VS-BED-01',
      rssi: -50,
      advertisesProvisioningService: true,
    ),
  ];
  final List<String> commands = [];
  ProvisioningDevice? connectedDevice;
  int scanCount = 0;
  int disconnectCount = 0;

  @override
  Stream<BleConnectionPhase> get connectionPhases => _phaseController.stream;

  @override
  Stream<List<ProvisioningDevice>> get scanResults => _scanController.stream;

  @override
  Stream<ProvisioningStatus> get statuses => _statusController.stream;

  @override
  Future<void> scan() async {
    scanCount++;
    _scanController.add(devices);
  }

  @override
  Future<void> connect(ProvisioningDevice device) async {
    connectedDevice = device;
    _phaseController.add(BleConnectionPhase.connecting);
    _phaseController.add(BleConnectionPhase.discoveringServices);
    _phaseController.add(BleConnectionPhase.ready);
    commands.add('STATUS');
  }

  @override
  Future<void> sendCredentials({
    required String ssid,
    required String password,
  }) async {
    commands.add('CONNECT');
  }

  @override
  Future<void> requestStatus() async {
    commands.add('STATUS');
  }

  @override
  Future<void> clearCredentials() async {
    commands.add('CLEAR');
  }

  void emitStatus(ProvisioningStatus status) {
    _statusController.add(status);
  }

  @override
  Future<void> disconnect() async {
    disconnectCount++;
    connectedDevice = null;
  }

  @override
  Future<void> enableBluetooth() async {}

  @override
  Future<void> openPermissionsSettings() async {}

  @override
  Future<void> dispose() async {
    await _scanController.close();
    await _statusController.close();
    await _phaseController.close();
  }
}
