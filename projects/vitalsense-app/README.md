# VitalSense Caregiver Dashboard

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.x-0175C2?logo=dart)](https://dart.dev)
[![Protocol](https://img.shields.io/badge/Protocol-VitalSense_v1-006D36)](VitalSense_Dashboard_Integration_Protocol_v1.md)

**VitalSense** is a Flutter caregiver dashboard for monitoring bedridden patients. It receives real-time UDP telemetry from a VitalSense ESP32 gateway and displays posture, pressure-sensor data, pressure-injury risk, device status, and engineering diagnostics.

The app can also configure or change the ESP32 Wi-Fi credentials directly from an Android phone over Bluetooth Low Energy (BLE). BLE is used only during device setup; normal monitoring continues over local Wi-Fi and UDP.

## Features

- **ESP32 Wi-Fi setup over BLE**: Scan for a nearby VitalSense unit, select it, and send a Wi-Fi SSID and password from the app.
- **Credential management**: Detect an existing ESP32 Wi-Fi configuration, continue with it, replace it, or clear it from the device.
- **Provisioning feedback and recovery**: Show connection progress, validation errors, Bluetooth or permission issues, Wi-Fi failures, and retry actions.
- **End-to-end setup verification**: Confirm the ESP32-reported SSID and IP address, then wait for a matching VitalSense UDP packet before returning to live monitoring.
- **Automatic UDP discovery**: Listen on UDP port `5005` for VitalSense telemetry on the local Wi-Fi network.
- **Bed and connection monitoring**: Display `LIVE`, `STALE`, and `OFFLINE` states using packet timestamps and heartbeats.
- **Posture and duration tracking**: Display body orientation (`CENTER/BACK`, `LEFT`, or `RIGHT`) and posture duration.
- **Pressure-injury risk assessment**: Show risk gauges for the Head, Shoulders, Hips, and Heels, including the highest-risk zone.
- **Raw sensor data**: Visualize the eight-channel FSR array and four anatomical plate values.
- **Diagnostics**: Display ESP32 uptime, protocol version, source IP, raw ADC streams, Avoid-Return alerts, and provisioning status.

## Communication Architecture

```text
During setup

  Android phone  <-- temporary BLE GATT connection -->  ESP32
       |                                               receives SSID/password
       |                                               and joins Wi-Fi
       v
  waits for a matching UDP packet on port 5005

During monitoring

  [8x FSR Array]
         |
         v
  [ESP32 Gateway] <--- BLE ---> [EFR32xG26 MCU (IMU and ML inference)]
         |
         | UDP JSON broadcast on the local Wi-Fi network
         v
  [VitalSense Caregiver Dashboard]
```

The ESP32 provisioning connection is separate from the EFR32 telemetry BLE connection. The app accesses only the VitalSense Wi-Fi provisioning GATT service described below.

## Configure ESP32 Wi-Fi from the App

### Requirements

- An Android phone with Bluetooth Low Energy support.
- Bluetooth enabled while configuring the device.
- Nearby Devices permission on Android 12 or newer. Android 11 and older use Location permission for BLE scanning.
- A powered VitalSense ESP32 running firmware that implements the provisioning GATT contract in [ESP32 firmware contract](#esp32-firmware-contract).
- The Wi-Fi network name and password. Open networks are supported by leaving the password empty.

### Setup steps

1. Power on the VitalSense ESP32 and keep the phone nearby.
2. Open the app and use one of these entry points:
   - If no device is detected, wait for **Set Up VitalSense** to appear on the dashboard.
   - Open **Settings > Device Connectivity > Configure Device Wi-Fi** or **Change Wi-Fi Network**.
3. Allow Bluetooth/Nearby Devices access when prompted.
4. Select the correct VitalSense device from the scan results. Devices are shown with their BLE signal strength.
5. Enter the Wi-Fi network name and password, then tap **Connect to Wi-Fi**.
6. Keep the ESP32 powered while it joins the network. The app waits up to 45 seconds for the Wi-Fi result.
7. After the ESP32 reports its SSID and IP address, ensure the phone is connected to the same Wi-Fi network. The app disconnects the temporary BLE session and waits for live UDP data.
8. When a matching UDP packet arrives, setup completes and the dashboard opens. If data is not detected within 20 seconds, choose **Keep Listening** or **Configure Wi-Fi Again**.

The app configures the ESP32; it does not switch the phone to the selected Wi-Fi network.

### Existing credentials

When the selected ESP32 already reports a working Wi-Fi connection, the app shows the network name and device IP. You can:

- **Continue to Dashboard** without overwriting the stored credentials.
- **Change Wi-Fi** and submit another network.
- **Forget Device Wi-Fi** to send the `CLEAR` command and remove the ESP32 configuration.

### Credential handling

- The app sends the SSID and password only to the selected ESP32 over the active BLE connection.
- The password is not logged or retained by the provisioning provider.
- The password field is cleared immediately after the BLE write operation completes.
- The ESP32 firmware is responsible for securely storing, using, and clearing credentials on the device.

## ESP32 Firmware Contract

The ESP32 must expose the following BLE service and characteristics. UUID comparisons are case-insensitive.

| Purpose | UUID | App operation |
|---|---|---|
| Provisioning service | `7a0a0101-5b8a-4f4c-9d1d-8b4e3d7a1000` | Discover service |
| SSID | `7a0a0102-5b8a-4f4c-9d1d-8b4e3d7a1000` | Write UTF-8 SSID |
| Password | `7a0a0103-5b8a-4f4c-9d1d-8b4e3d7a1000` | Write UTF-8 password; may be empty |
| Command | `7a0a0104-5b8a-4f4c-9d1d-8b4e3d7a1000` | Write UTF-8 command |
| Status | `7a0a0105-5b8a-4f4c-9d1d-8b4e3d7a1000` | Enable notifications and receive UTF-8 status |

The SSID, password, and command characteristics must support BLE write or write-without-response. The status characteristic must support notifications.

### Device discovery

For reliable discovery, advertise the provisioning service UUID. The app also accepts devices whose BLE name is exactly `VitalSense` or starts with `VitalSense-` or `VS-`, then verifies that the required service and all four characteristics exist after connecting.

### Commands sent by the app

| Command | ESP32 behavior |
|---|---|
| `STATUS` | Report whether credentials exist and the current Wi-Fi state. Sent automatically after the app subscribes to status notifications. |
| `CONNECT` | Use the most recently written SSID and password to join Wi-Fi. |
| `CLEAR` | Remove stored Wi-Fi credentials and return the device to an unconfigured state. |

For a new connection, the app writes the SSID, writes the password, and then writes `CONNECT` in that order.

### Status notifications expected by the app

| Status payload | Meaning |
|---|---|
| `NO_CREDENTIALS` | No Wi-Fi credentials are stored. |
| `SSID_RECEIVED` | The SSID write was accepted. |
| `PASSWORD_RECEIVED` | The password write was accepted. |
| `CONNECTING\|<ssid>` | The ESP32 is attempting to join the network. |
| `CONNECTED\|<ssid>\|<ip-address>` | Wi-Fi joined successfully. The IP is also used to match the subsequent UDP packet. |
| `FAILED\|<reason>` | The connection failed. Use `CHECK_SSID_PASSWORD` to show the app's specific credential/signal guidance. |
| `DISCONNECTED\|<ssid>` | Credentials are known, but the ESP32 is not connected to Wi-Fi. |

Status fields must be present and non-empty where shown. Unknown or incomplete payloads are treated as malformed responses.

## Getting Started for Development

### Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) compatible with Dart `>=3.0.0 <4.0.0`
- Android SDK
- A compatible ESP32 for end-to-end BLE and UDP testing

### Install and run

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

### Build a release APK

```bash
flutter build apk --release
```

The APK is generated at `build/app/outputs/flutter-apk/app-release.apk`.

## UDP Telemetry Protocol

The dashboard implements **VitalSense Protocol v1** and listens on UDP port `5005` by default.

```json
{
  "protocol": 1,
  "deviceId": "VS-BED-01",
  "bed": 1,
  "position": "LEFT",
  "positionDuration": 1420,
  "plates": {
    "head": 120,
    "shoulders": 850,
    "hips": 2100,
    "heels": 430
  },
  "fsr": [100, 140, 800, 900, 2000, 2200, 400, 460],
  "riskValid": true,
  "risk": {
    "head": 15,
    "shoulders": 35,
    "hips": 82,
    "heels": 40
  },
  "highestRisk": {
    "zone": "HIPS",
    "score": 82,
    "level": "HIGH"
  },
  "avoidReturn": {
    "head": 0,
    "shoulders": 0,
    "hips": 1,
    "heels": 0
  },
  "uptime": 36400
}
```

See [VitalSense Dashboard Integration Protocol v1](VitalSense_Dashboard_Integration_Protocol_v1.md) for the full telemetry specification.

## Release Notes

- [v1.2.0 - ESP32 Wi-Fi Credential Provisioning](RELEASE_NOTES_v1.2.0.md)
- [v1.1.0](RELEASE_NOTES_v1.1.0.md)
- [v1.0.0](RELEASE_NOTES_v1.0.0.md)

## License

This project is licensed under the [Apache License 2.0](../../LICENSE.md).

SPDX-License-Identifier: Apache-2.0
