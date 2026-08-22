# VitalSense Projects

VitalSense is an end-to-end pressure-injury prevention system for monitoring bedridden patients. Sensor and posture data are processed on embedded hardware, broadcast over the local network, and presented to caregivers through mobile and web dashboards.

## System Overview

```text
8x FSR sensors --> ESP32-C3 <-- BLE --> EFR32xG26 (IMU + ML inference)
                     |
                     | VitalSense Protocol v1
                     | UDP JSON broadcast, port 5005, once per second
                     v
              Mobile app / Web dashboard

Android app -- temporary BLE connection --> ESP32-C3
              Wi-Fi provisioning only
```

The ESP32-C3 acquires pressure data, exchanges sensor and risk packets with the EFR32xG26, and broadcasts the combined telemetry. The Flutter app can provision the ESP32's Wi-Fi credentials over BLE; normal monitoring then continues over Wi-Fi and UDP.

## Repository Components

| Component | Path | Purpose |
|---|---|---|
| Engineering pipeline | [`Pipeline/`](./Pipeline/README.md) | ESP32 and EFR32 firmware, ML models, datasets, and training/export tools |
| ESP32-C3 firmware | [`Pipeline/ESP32 firmware/`](./Pipeline/ESP32%20firmware/README.md) | FSR acquisition, BLE services, Wi-Fi provisioning, and UDP broadcasting |
| Caregiver mobile app | [`vitalsense-app/`](./vitalsense-app/README.md) | Flutter Android dashboard, BLE device setup, live monitoring, and diagnostics |
| Web dashboard | [`vitalsense-dashboard/`](./vitalsense-dashboard/README.md) | Python/Flask monitoring dashboard |

## Mobile App v1.2.0

The latest documented app release is **v1.2.0**, released on **August 21, 2026**. It adds guided ESP32 Wi-Fi credential provisioning from the Android app.

Key additions include:

- BLE scanning and explicit VitalSense device selection with signal-strength labels.
- Wi-Fi SSID/password setup, including support for open networks.
- Detection of existing ESP32 credentials through the `STATUS` command.
- Options to keep, replace, or clear saved credentials.
- Live setup progress, strict response validation, timeouts, and recovery screens.
- End-to-end verification using a UDP packet from the selected ESP32's IP address.
- Android 12+ Bluetooth permissions and legacy Android BLE/location support.
- Password privacy protections: passwords are neither retained by the provider nor logged.

See the complete [v1.2.0 release notes](./vitalsense-app/RELEASE_NOTES_v1.2.0.md).

## ESP32 Wi-Fi Provisioning

App v1.2.0 requires ESP32 firmware that implements the VitalSense provisioning GATT service. The phone uses BLE only for setup; the ESP32 then joins Wi-Fi and sends monitoring data over UDP.

### Setup flow

1. Power on an ESP32 running compatible VitalSense firmware.
2. In the Android app, choose **Set Up VitalSense** or open **Settings > Device Connectivity**.
3. Allow the requested Bluetooth/Nearby Devices permission and select the intended unit.
4. Enter the Wi-Fi SSID and password, then start the connection.
5. Wait for the ESP32 to report its SSID and IP address.
6. Connect the phone to the same Wi-Fi network if needed.
7. Setup completes after the app receives a matching VitalSense UDP packet.

The app configures the ESP32 but does not switch the phone's Wi-Fi network.

### Provisioning contract

| Purpose | UUID |
|---|---|
| Service | `7a0a0101-5b8a-4f4c-9d1d-8b4e3d7a1000` |
| SSID write | `7a0a0102-5b8a-4f4c-9d1d-8b4e3d7a1000` |
| Password write | `7a0a0103-5b8a-4f4c-9d1d-8b4e3d7a1000` |
| Command write | `7a0a0104-5b8a-4f4c-9d1d-8b4e3d7a1000` |
| Status read/notify | `7a0a0105-5b8a-4f4c-9d1d-8b4e3d7a1000` |

Supported commands are `STATUS`, `CONNECT`, and `CLEAR`. For a new connection, the app writes the SSID, writes the password, and then sends `CONNECT`. Credentials are saved to ESP32 NVS only after the network connection succeeds.

For the complete BLE behavior, status values, and error handling, see the [app firmware contract](./vitalsense-app/README.md#esp32-firmware-contract) and [ESP32 firmware documentation](./Pipeline/ESP32%20firmware/README.md#wifi-provisioning-from-the-app-over-ble).

## Runtime Telemetry

After provisioning, the ESP32 broadcasts VitalSense Protocol v1 JSON to UDP port `5005` once per second. Packets include:

- Device and bed identifiers.
- Current posture and uninterrupted posture duration.
- Eight raw FSR readings and four anatomical plate averages.
- Per-zone risk for the Head, Shoulders, Hips, and Heels.
- Highest-risk zone, score, and level.
- Avoid-Return flags and device uptime.

The app reports the connection as `LIVE`, `STALE`, or `OFFLINE` based on incoming packet timestamps.

## Getting Started

### Mobile app

```bash
cd vitalsense-app
flutter pub get
flutter analyze
flutter test
flutter run
```

Build a release APK with:

```bash
flutter build apk --release
```

### ESP32 firmware

Open `Pipeline/ESP32 firmware/VitalSense_ESP32.ino` in Arduino IDE 2.x, select an ESP32-C3 board, install NimBLE-Arduino 2.x, and upload the sketch. Wi-Fi credentials are provisioned from the app and are not compiled into the firmware.

See the component READMEs for EFR32 firmware, ML pipeline, dashboard, hardware, and platform-specific setup details.

## Project Structure

```text
projects/
|-- Pipeline/
|   |-- ESP32 firmware/
|   |-- EFR xG26 firmware/
|   |-- model/
|   |-- Dataset/
|   `-- Synthetic dataset kit/
|-- vitalsense-app/
|-- vitalsense-dashboard/
`-- README.md
```


## License

VitalSense project content is licensed under the [Apache License 2.0](../LICENSE.md).

SPDX-License-Identifier: Apache-2.0

Individual components and bundled third-party libraries may have additional licenses; consult their documentation before redistribution.
