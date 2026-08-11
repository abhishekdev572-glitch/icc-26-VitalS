# VitalSense EFR32xG26 Firmware

**Firmware Version:** `VITALSENSE_XG26_IMU_BLE_ML_V1`

This firmware runs on the **Silicon Labs EFR32xG26 (BRD2608A)** and serves as the IMU + BLE central + ML inference node in the VitalSense pressure ulcer prevention system.

---

## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     VITALSENSE SYSTEM                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐      BLE (Central)      ┌────────────────┐  │
│  │  EFR32xG26   │ ◄─────────────────────► │   ESP32-C3     │  │
│  │  (This FW)   │      GATT Client        │  (Peripheral)  │  │
│  └──────┬───────┘                         └───────┬────────┘  │
│         │                                         │            │
│         │ IMU (ICM-40627)                         │ 8× FSR     │
│         │ ~60 Hz sampling                         │ sensors    │
│         ▼                                         ▼            │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │              pressure_risk_mlp (TFLite Micro)            │  │
│  │  Inputs: posture + duration + 4 plate ADC averages       │  │
│  │  Output: 4 risk scores (0-100) for Head/Shoulders/Hips/Heels│
│  └─────────────────────────────────────────────────────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## EFR32xG26 Responsibilities

| # | Responsibility | Details |
|---|----------------|---------|
| 1 | **IMU Calibration** | Calibrate CENTER / LEFT / RIGHT postures using ICM-40627 accelerometer |
| 2 | **Posture Tracking** | Classify posture at ~60 Hz, track uninterrupted duration |
| 3 | **BLE Central** | Scan for `VitalSense-ESP32C3`, connect, discover GATT |
| 4 | **FSR Request** | After posture threshold (default 60s), request 8-FSR array once/sec |
| 5 | **FSR Decode** | Parse `[0x81, 0x08, FSR0_L, FSR0_H, ... FSR7_L, FSR7_H]` |
| 6 | **Plate Averaging** | Average 8 FSRs into 4 plates: Head, Shoulders, Hips, Heels |
| 7 | **ML Inference** | Run `pressure_risk_mlp` with posture + duration + 4 plate ADCs |
| 8 | **Risk TX** | Send 4 risk packets `[0x02, bodyId, risk0-100, avoidFlag]` to ESP32 |
| 9 | **State TX** | Send periodic posture+duration summary `[0x03, pos, dur, risk...]` |

---

## Hardware

| Component | Part | Connection |
|-----------|------|------------|
| MCU | EFR32MG26B510F3200IM68 | BRD2608A (xG26 Dev Kit) |
| IMU | ICM-40627 | I²C (enabled via PA10) |
| Buttons | BTN0, BTN1 | On-board |
| RGB LED | status_rgb | PWM (RED/GREEN/BLUE) |
| Debug | VCOM | USART0 (115200 baud) |

---

## Button Mapping

| Button | Action |
|--------|--------|
| **BTN0** | During calibration: CENTER → LEFT → RIGHT<br>After calibration: Restart calibration |
| **BTN1** | Toggle Awake ↔ Standby |

---

## RGB LED Status Codes

| Color | State |
|-------|-------|
| **OFF** | Standby (BTN1 to wake) |
| **YELLOW** | Calibration required (press BTN0) |
| **RED** | IMU / ML / BLE error |
| **BLUE** | Scanning for ESP32 |
| **PURPLE** | Connecting / Discovering GATT |
| **CYAN** | ESP32 link ready |
| **GREEN** | Waiting for FSR response |

---

## BLE Protocol (EFR32 → ESP32)

**Target Device:** `VitalSense-ESP32C3`  
**Service UUID:** `7a0a0001-5b8a-4f4c-9d1d-8b4e3d7a1000`  
**RX Char (EFR→ESP):** `7a0a0002-5b8a-4f4c-9d1d-8b4e3d7a1000` (Write w/ Response)  
**TX Char (ESP→EFR):** `7a0a0003-5b8a-4f4c-9d1d-8b4e3d7a1000` (Notify)

### Commands (EFR32 → ESP32)

| CMD | Payload | Description |
|-----|---------|-------------|
| `0x01` | — | Request fresh 8-FSR array |
| `0x02` | `bodyId, risk(0-100), avoidFlag` | ML risk update (×4 bodies) |
| `0x03` | `pos, durationSec, riskValid, zoneId, score, level` | Posture + summary state |

### Response (ESP32 → EFR32)

| Byte | Value |
|------|-------|
| `[0]` | `0x81` |
| `[1]` | `0x08` (sensor count) |
| `[2..17]` | 8 × `uint16_t` little-endian FSR values |

### Body IDs

| ID | Body Part |
|----|-----------|
| 1 | Head |
| 2 | Shoulders |
| 3 | Hips |
| 4 | Heels |

### Risk Levels

| Level | Value |
|-------|-------|
| LOW | 0 |
| MEDIUM | 1 |
| HIGH | 2 |

> **Note on `avoidReturnFlag`**: Currently always `0`. Reserved for future forbidden-posture logic.

---

## ML Model: `pressure_risk_mlp`

- **Framework:** TensorFlow Lite Micro (via Silicon Labs AI/ML SDK)
- **Inputs (5):** `posture (0/1/2)`, `duration_sec`, `head_adc`, `shoulders_adc`, `hips_adc`, `heels_adc`
- **Outputs (4):** Risk scores 0–100 for Head, Shoulders, Hips, Heels
- **Model File:** `config/tflite/pressure_risk_mlp.tflite`

---

## Key Timing Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `POSITION_SAMPLE_RATE_HZ` | 60 | IMU sampling / posture classification rate |
| `RISK_PREDICTION_THRESHOLD_SECONDS` | 60 | Uninterrupted posture before ML starts |
| `RISK_PREDICTION_INTERVAL_SECONDS` | 1 | ML inference interval after threshold |
| `FSR_RESPONSE_TIMEOUT_SECONDS` | 3 | Max wait for ESP32 FSR response |
| `BLE_SCAN_INTERVAL_UNITS` | 80 | 50 ms scan interval |
| `BLE_CONNECTION_INTERVAL_UNITS` | 24 | 30 ms connection interval |

---

## Building & Flashing

### Prerequisites

- **Simplicity Studio 5** (v5.2+)
- **Silicon Labs Gecko SDK** 2026.6.0
- **EFR32xG26 BRD2608A** dev kit

### Steps

1. Open Simplicity Studio
2. `File → Import → Silicon Labs → Project from SLCP`
3. Select `bt_imu_mode.slcp`
4. Connect BRD2608A (power switch → **AEM** position)
5. Build project (hammer icon)
6. Flash (debug icon)

### Post-Build (for OTA DFU)

Add a post-build step to generate `.gbl`:
```bash
commander gbl create output.gbl --app output.s37
```

---

## Debug Output (VCOM @ 115200)

```
[IMU] Ready. ID=0x47 actual_rate=100 Hz
[ML] Model ready
[ML] Prediction gate = 60 s uninterrupted posture
[CAL] Press BTN0 to capture the requested posture
[CAL] Capturing CENTER. Keep still.
[CAL] CENTER reference mg: X=12 Y=-4 Z=1012
[CAL] CENTER saved. Hold LEFT and press BTN0
...
[CAL] COMPLETE
[BLE] Starting scan for VitalSense-ESP32C3
[BLE] Scanning for VitalSense-ESP32C3
[BLE] Found VitalSense-ESP32C3, connecting...
[BLE] Connected, discovering services...
[BLE] GATT discovery complete, enabling TX notifications
[BLE] Link ready
RISK_WAIT,CENTER,10,60
RISK_WAIT,CENTER,20,60
...
[FSR] Request sent | position=CENTER duration=60 s
[FSR] Response received: 1234 2345 3456 4567 5678 6789 7890 8901
[ML] pred: head=12.3 should=8.7 hips=45.2 heels=3.1 max=HIPS(45.2) lvl=MEDIUM
[BLE] Risk write started body=1
[BLE] Risk write started body=2
[BLE] Risk write started body=3
[BLE] Risk write started body=4
```

---

## Project Structure

```
bt_imu_mode/
├── app.c / app.h              # Main application logic
├── main.c                     # Silicon Labs main() entry
├── pressure_risk_ml_xg26.h/.cpp  # ML model C API wrapper
├── bt_imu_mode.slcp           # Project configuration
├── config/
│   ├── tflite/pressure_risk_mlp.tflite   # TFLite model
│   └── *.h                       # Component configs
├── autogen/                    # Auto-generated SDK code
├── cmake_gcc/                  # GCC/CMake build
├── image/                      # README images
└── firmware file/
    └── bt_imu_mode.s37         # Pre-built firmware
```

---

## References

- [UG103.14: Bluetooth LE Fundamentals](https://www.silabs.com/documents/public/user-guides/ug103-14-fundamentals-ble.pdf)
- [QSG169: Bluetooth SDK v3.x Quick Start](https://www.silabs.com/documents/public/quick-start-guides/qsg169-bluetooth-sdk-v3x-quick-start-guide.pdf)
- [UG434: Bluetooth C SoC Developer's Guide](https://www.silabs.com/documents/public/user-guides/ug434-bluetooth-c-soc-dev-guide-sdk-v3x.pdf)
- [ICM-40627 Datasheet](https://invensense.tdk.com/products/motion-tracking/6-axis/icm-40627/)

---

## License

SPDX-License-Identifier: Zlib  
Copyright 2025 Silicon Laboratories Inc. / VitalSense Project Contributors