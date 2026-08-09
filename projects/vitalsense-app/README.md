# VitalSense Caregiver Dashboard 🩺

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.x-0175C2?logo=dart)](https://dart.dev)
[![Protocol](https://img.shields.io/badge/Protocol-VitalSense_v1-006D36)](VitalSense_Dashboard_Integration_Protocol_v1.md)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**VitalSense** is a real-time caregiver dashboard mobile application built with Flutter. It listens for UDP JSON broadcasts from the VitalSense ESP32 gateway to continuously monitor bedridden patient posture, pressure sensor (FSR) arrays, and ML-inferred pressure injury risk across critical anatomical regions.

---

## 📱 Features

- ⚡ **Auto-Discovery & Zero-Config Networking**: Listens on UDP port `5005` to automatically discover and stream live data from ESP32 bed units on the local Wi-Fi network.
- 🛏️ **Bed & Connection Status Monitoring**: Visual status indicators (`LIVE`, `STALE`, `OFFLINE`) with dynamic heartbeats and last-packet tracking.
- 🧘 **Posture & Duration Tracking**: Displays real-time body orientation (`CENTER/BACK`, `LEFT`, `RIGHT`) and precise posture duration counters.
- ⚠️ **Pressure Injury Risk Assessment**: Circular gauges for 4 key anatomical zones (Head, Shoulders, Hips, Heels) alongside highest-risk highlights and 60-second threshold progression.
- 📊 **Raw Sensor & Plate ADC Data**: Interactive visualizers for 8-channel FSR raw values (ADC 0–4095) and 4-zone averaged plate data.
- 🔧 **Engineering & Diagnostics View**: Deep-dive hardware panel showing ESP32 uptime, protocol version, IP, raw ADC streams, and Avoid-Return alerts.

---

## 🏗️ System Architecture

```text
  [8x FSR Array]
        |
        v
  [ESP32-C3 Gateway] <--- BLE ---> [EFR32xG26 MCU (IMU & ML Inference)]
        |
        | UDP Broadcast (0.0.0.0:5005)
        v
  ┌────────────────────────────────────────────────────────┐
  │         VitalSense Caregiver Dashboard (Flutter)       │
  │                                                        │
  │  ┌───────────────┐ ┌───────────────┐ ┌──────────────┐  │
  │  │ Bed Status    │ │ Posture & Time│ │ Risk Gauges  │  │
  │  └───────────────┘ └───────────────┘ └──────────────┘  │
  │  ┌───────────────┐ ┌───────────────┐                  │
  │  │ FSR Grid      │ │ Diagnostics   │                  │
  │  └───────────────┘ └───────────────┘                  │
  └────────────────────────────────────────────────────────┘
```

---

## ⚙️ Getting Started

### Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (`>= 3.0.0`)
- Android SDK (for building `.apk`)
- ESP32 gateway device sending [VitalSense Protocol v1](VitalSense_Dashboard_Integration_Protocol_v1.md) packets over Wi-Fi.

### Installation & Setup

1. **Clone the repository**:
   ```bash
   git clone https://github.com/your-org/vitalsense-app.git
   cd vitalsense-app
   ```

2. **Install dependencies**:
   ```bash
   flutter pub get
   ```

3. **Run code analysis**:
   ```bash
   flutter analyze
   ```

4. **Run on connected device/emulator**:
   ```bash
   flutter run
   ```

---

## 📦 Building for Production

To build the release Android APK:

```bash
flutter build apk --release
```

The compiled APK will be available at:
`build/app/outputs/flutter-apk/app-release.apk`

---

## 📡 Communication Protocol Spec

The app implements **VitalSense Protocol v1** over UDP port `5005`.

### Sample Payload Format

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

Refer to [VitalSense_Dashboard_Integration_Protocol_v1.md](VitalSense_Dashboard_Integration_Protocol_v1.md) for full protocol specifications.

---

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.
