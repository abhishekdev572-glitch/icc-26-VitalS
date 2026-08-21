import 'package:flutter_test/flutter_test.dart';
import 'package:vitalsense_app/models/wifi_provisioning_status.dart';

void main() {
  group('ProvisioningStatus.parse', () {
    test('parses simple acknowledgements', () {
      expect(
        ProvisioningStatus.parse('NO_CREDENTIALS').type,
        ProvisioningStatusType.noCredentials,
      );
      expect(
        ProvisioningStatus.parse('SSID_RECEIVED').type,
        ProvisioningStatusType.ssidReceived,
      );
      expect(
        ProvisioningStatus.parse('PASSWORD_RECEIVED').type,
        ProvisioningStatusType.passwordReceived,
      );
    });

    test('parses connected network and IP', () {
      final status = ProvisioningStatus.parse(
        'CONNECTED|Hospital_WiFi|192.168.1.37',
      );

      expect(status.type, ProvisioningStatusType.connected);
      expect(status.ssid, 'Hospital_WiFi');
      expect(status.ipAddress, '192.168.1.37');
    });

    test('parses connecting, failed, and disconnected responses', () {
      final connecting = ProvisioningStatus.parse('CONNECTING|Hospital_WiFi');
      final failed = ProvisioningStatus.parse('FAILED|CHECK_SSID_PASSWORD');
      final disconnected =
          ProvisioningStatus.parse('DISCONNECTED|Hospital_WiFi');

      expect(connecting.type, ProvisioningStatusType.connecting);
      expect(connecting.ssid, 'Hospital_WiFi');
      expect(failed.type, ProvisioningStatusType.failed);
      expect(failed.reason, 'CHECK_SSID_PASSWORD');
      expect(disconnected.type, ProvisioningStatusType.disconnected);
      expect(disconnected.ssid, 'Hospital_WiFi');
    });

    test('rejects missing fields and unknown messages as malformed', () {
      expect(
        ProvisioningStatus.parse('CONNECTED|Hospital_WiFi').type,
        ProvisioningStatusType.malformed,
      );
      expect(
        ProvisioningStatus.parse('SOMETHING_ELSE').type,
        ProvisioningStatusType.malformed,
      );
      expect(
        ProvisioningStatus.parse('').type,
        ProvisioningStatusType.malformed,
      );
    });
  });
}
