# 🚀 VitalSense Caregiver Dashboard v1.1.0

Welcome to the **v1.1.0** update of the **VitalSense Caregiver Dashboard** Android application! This release focuses on stability enhancements, performance optimizations, and quality-of-life improvements based on caregiver feedback.

---

## ✨ New Features & Enhancements

- 🔔 **Customizable Alert Thresholds**: Configure per-region pressure injury risk thresholds (Head, Shoulders, Hips, Heels) with adjustable time-to-alert durations (30s–120s).
- 📱 **Landscape Mode Support**: Full landscape orientation support for tablet-mounted dashboard stations with responsive layout reflow.
- 🌙 **Dark/Light Theme Toggle**: System-following theme with manual override in Settings for improved visibility in low-light care environments.
- 📈 **Historical Trend Viewer**: New 24-hour pressure trend charts per anatomical region with peak/average indicators and export capability.
- 🔊 **Audible Alert Options**: Configurable notification sounds (chime, vibration, silent) with per-severity assignment (Warning/Critical).
- 🌐 **Multi-Language Support**: Added Spanish (ES) and French (FR) localizations with RTL layout preparation.

---

## 🛠️ Technical Improvements & Stability Fixes

- **Performance Optimization**: Reduced CPU usage by ~35% during continuous streaming via frame-batching and optimized ADC rendering pipeline.
- **Memory Leak Fixes**: Resolved subscription leaks in `DeviceStreamManager` and `RiskAssessmentEngine` during rapid device connect/disconnect cycles.
- **Network Resilience**: Improved UDP packet reassembly with 200ms jitter buffer; added automatic reconnection with exponential backoff (1s→30s).
- **JSON Parsing Hardening**: Extended null-safe parsing to new telemetry fields (battery %, firmware build hash, sensor calibration metadata).
- **Flutter 3.24 Migration**: Updated to Flutter 3.24.4 with Dart 3.5.3; resolved deprecation warnings and enabled `wasm` compilation target.
- **Strict Lint Compliance**: Maintains 0 warnings/errors under `flutter analyze` with additional `very_good_analysis` rules enabled.

---

## 🐛 Bug Fixes

- Fixed posture duration counter reset on brief signal loss (<2s)
- Corrected Heels region ADC mapping for ESP32 firmware v2.1+ (channel remap)
- Resolved occasional "STALE" false positives during Wi-Fi roaming
- Fixed landscape keyboard overlay obscuring alert configuration dialog
- Patched APK installation failure on Android 14+ with scoped storage enforcement

---

## 📦 Download Assets

| Asset | Description | Size |
|---|---|---|
| 📱 `app-release-v1.1.0.apk` | Production Release APK (ARM64 / Universal) | ~46.2 MB |
| 📦 `app-release-v1.1.0.aab` | Android App Bundle for Play Store | ~42.8 MB |

---

### 📋 Installation Instructions

1. Download `app-release-v1.1.0.apk` onto your Android device.
2. Allow installation from unknown sources if prompted.
3. Connect your mobile device to the same Wi-Fi network as the VitalSense ESP32 units.
4. Launch **VitalSense** — the dashboard will automatically discover active bed streams on port `5005`.

---

### 🔄 Upgrade Notes from v1.0.0

- **Configuration Migration**: Existing alert thresholds reset to defaults; reconfigure in Settings → Alert Thresholds.
- **Theme Preference**: Defaults to system theme; previous light-only behavior migrated to "Light" manual selection.
- **Data Compatibility**: Historical trend data requires v1.1.0+ firmware on ESP32 units (v2.1+ recommended).

---

**Full Changelog**: [Compare v1.0.0...v1.1.0](https://github.com/your-org/vitalsense-app/compare/v1.0.0...v1.1.0)