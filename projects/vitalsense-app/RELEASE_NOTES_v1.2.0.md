# VitalSense Caregiver Dashboard v1.2.0

Release date: August 21, 2026

This release adds in-app Wi-Fi credential provisioning for compatible VitalSense ESP32 devices. Caregivers can now configure, change, verify, or clear an ESP32 Wi-Fi connection from the Android app without a separate setup utility.

## Highlights

- Added a guided **Set Up VitalSense** flow using a temporary Bluetooth Low Energy connection.
- Added nearby VitalSense device scanning, explicit device selection, signal-strength labels, and guarded device filtering.
- Added SSID and password entry, including support for open Wi-Fi networks.
- Added detection of an ESP32's existing Wi-Fi configuration through the `STATUS` command.
- Added options to keep the current connection, change networks, or remove stored credentials with `CLEAR`.
- Added live setup progress for BLE connection, GATT service discovery, credential transmission, and ESP32 Wi-Fi connection.
- Added ESP32-reported SSID and IP display after a successful connection.
- Added end-to-end verification: setup completes only after a matching VitalSense UDP packet is received from the provisioned device.
- Added setup entry points from both the empty dashboard state and **Settings > Device Connectivity**.

## Reliability and Recovery

- Added a 10-second BLE scan window and a 15-second BLE connection timeout.
- Added an 8-second timeout to each characteristic write.
- Added a 45-second timeout while waiting for the ESP32 to finish joining Wi-Fi.
- Added a 20-second UDP discovery window after Wi-Fi connects, with **Keep Listening** and **Configure Wi-Fi Again** actions.
- Added retry handling for incorrect credentials without requiring another BLE scan while the setup connection remains active.
- Added recovery screens for Bluetooth disabled, BLE unsupported, permission denied, lost BLE connection, missing GATT services or characteristics, malformed ESP32 responses, and Wi-Fi failures.
- Added strict status parsing for successful, connecting, failed, disconnected, and unconfigured ESP32 states.
- Added source-IP matching so UDP traffic from another VitalSense bed does not complete the selected device's setup flow.
- Preserved explicit multi-device selection throughout provisioning to prevent configuring the wrong bed.

## Credential Privacy

- Wi-Fi passwords are not stored in the provisioning provider or written to application logs.
- The password input is cleared immediately after the BLE transport operation finishes.
- BLE is disconnected after setup; ongoing monitoring continues over Wi-Fi and UDP.
- Clearing credentials requires caregiver confirmation before the app sends the `CLEAR` command.

## Android Integration

- Added Android 12+ Bluetooth Scan and Bluetooth Connect permission support.
- Added legacy Bluetooth and Location permissions for BLE scanning on older Android versions.
- BLE remains an optional hardware feature for installing and using the monitoring dashboard, but is required for in-app ESP32 Wi-Fi setup.
- Added user actions to enable Bluetooth and open app permission settings when setup cannot continue.

## ESP32 Firmware Compatibility

The ESP32 firmware must expose the VitalSense provisioning service and all required characteristics:

| Purpose | UUID |
|---|---|
| Provisioning service | `7a0a0101-5b8a-4f4c-9d1d-8b4e3d7a1000` |
| SSID write | `7a0a0102-5b8a-4f4c-9d1d-8b4e3d7a1000` |
| Password write | `7a0a0103-5b8a-4f4c-9d1d-8b4e3d7a1000` |
| Command write | `7a0a0104-5b8a-4f4c-9d1d-8b4e3d7a1000` |
| Status notification | `7a0a0105-5b8a-4f4c-9d1d-8b4e3d7a1000` |

Supported app commands are `STATUS`, `CONNECT`, and `CLEAR`. Supported ESP32 status notifications are:

- `NO_CREDENTIALS`
- `SSID_RECEIVED`
- `PASSWORD_RECEIVED`
- `CONNECTING|<ssid>`
- `CONNECTED|<ssid>|<ip-address>`
- `FAILED|<reason>`
- `DISCONNECTED|<ssid>`

See the [README](README.md#esp32-firmware-contract) for the complete write order, discovery rules, expected characteristic capabilities, and setup instructions.

## Upgrade Notes

- Update the ESP32 firmware to implement the provisioning GATT contract before using the new setup screen.
- For the most reliable scan result, advertise the provisioning service UUID. Firmware may also advertise a supported name: `VitalSense`, `VitalSense-*`, or `VS-*`.
- The phone and ESP32 must be on the same Wi-Fi network for UDP monitoring after provisioning.
- Existing UDP telemetry remains on VitalSense Protocol v1 and port `5005`; the BLE feature does not replace the monitoring transport.

## Verification

Automated coverage now verifies:

- Provisioning a fresh device over BLE and completing only after UDP discovery.
- Retrying after an incorrect password without rescanning.
- Ignoring UDP packets from a different source IP.
- Keeping the explicitly selected bed as the provisioning target.
- Preserving existing working credentials after a `STATUS` response.
- Parsing every supported status response and rejecting malformed payloads.
