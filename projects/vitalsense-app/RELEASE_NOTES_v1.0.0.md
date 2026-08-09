# 🚀 VitalSense Caregiver Dashboard v1.0.0

Welcome to the initial official release of the **VitalSense Caregiver Dashboard** Android application! 🩺

This release provides real-time, non-invasive patient pressure monitoring, body posture tracking, and ML-driven pressure injury risk assessment directly over local Wi-Fi.

---

## ✨ Key Highlights

- ⚡ **Zero-Config Auto-Discovery**: Automatically discovers and streams live data from ESP32 bed units broadcasting over UDP port `5005`.
- 🛏️ **Real-Time Bed & Connection Monitor**: Live connection badges (`LIVE`, `STALE`, `OFFLINE`) with dynamic heartbeats and packet delay indicators.
- 🧘 **Posture & Duration Tracking**: Monitors orientation (`CENTER/BACK`, `LEFT`, `RIGHT`) and posture duration counters.
- ⚠️ **Anatomical Risk Assessment**: Visual circular gauges for 4 anatomical regions (Head, Shoulders, Hips, Heels) with highest-risk highlights and 60s threshold progression.
- 📊 **Raw Sensor Array & Plate ADC Grid**: 8-channel raw FSR pressure visualizer (ADC 0–4095) with 4-zone averaged plate progress bars.
- 🔧 **Engineering Diagnostics**: Technical telemetry screen displaying ESP32 uptime, protocol version, source IP, raw ADC values, and Avoid-Return alerts.

---

## 🛠️ Technical Improvements & Stability Fixes

- **Robust JSON Parsing**: Handles both integer and double JSON values from ESP32 edge firmware with null-safe fallbacks across all payload sub-objects.
- **Source IP Forwarding**: Accurately tracks source IP addresses across broadcast packets for multi-bed diagnostic identification.
- **Race Condition Prevention**: Hardened device lookup state to prevent null reference crashes when devices connect or disconnect.
- **Strict Lint Compliance**: Clean code base passing `flutter analyze` with 0 warnings/errors under Flutter standard lint rules.

---

## 📦 Download Assets

| Asset | Description | Size |
|---|---|---|
| 📱 `app-release.apk` | Production Release APK (ARM64 / Universal) | ~44.7 MB |

---

### 📋 Installation Instructions
1. Download `app-release.apk` onto your Android device.
2. Allow installation from unknown sources if prompted.
3. Connect your mobile device to the same Wi-Fi network as the VitalSense ESP32 units.
4. Launch **VitalSense** — the dashboard will automatically discover active bed streams on port `5005`.
