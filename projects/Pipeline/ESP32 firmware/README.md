# VitalSense ESP32-C3 Firmware

**Build Type:** LEAN (NimBLE + Manual JSON, no ArduinoJson)

This firmware runs on the **ESP32-C3** and serves as the FSR sensor acquisition + BLE peripheral + UDP broadcaster in the VitalSense pressure ulcer prevention system.

---

## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     VITALSENSE SYSTEM                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐      BLE (Peripheral)     ┌────────────────┐  │
│  │  EFR32xG26   │ ◄─────────────────────►   │   ESP32-C3     │  │
│  │  (Central)   │      GATT Server          │  (This FW)     │  │
│  └──────┬───────┘                           └───────┬────────┘  │
│         │                                           │            │
│         │                    8× FSR via 74HC4051    │            │
│         │                                           ▼            │
│         │  ┌─────────────────────────────────────────────────┐  │
│         │  │              UDP Broadcast (JSON)                │  │
│         │  │  Dashboard / App / Cloud ingestion               │  │
│         │  └─────────────────────────────────────────────────┘  │
│         │                                                       │
│         └───────────────────────────────────────────────────────│
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## ESP32-C3 Responsibilities

| # | Responsibility | Details |
|---|----------------|---------|
| 1 | **FSR Acquisition** | Read 8 FSR sensors via 74HC4051/CD4051 MUX (12-bit ADC) |
| 2 | **Plate Averaging** | Average pairs → Head, Shoulders, Hips, Heels |
| 3 | **BLE Peripheral** | Advertise as `VitalSense-ESP32C3`, GATT server |
| 4 | **FSR Response** | On `0x01` command: fresh scan + notify 18-byte packet |
| 5 | **Risk RX** | Receive 4× `0x02` risk packets from EFR32 |
| 6 | **State RX** | Receive `0x03` posture+duration summary from EFR32 |
| 7 | **UDP Broadcast** | Send complete VitalSense Protocol v1 JSON every 1s |
| 8 | **Status LED** | GPIO 7 (active-low): solid = ready, blink = issues |

---

## Hardware

| Component | Pin | Notes |
|-----------|-----|-------|
| MCU | ESP32-C3 | Any dev board (SuperMini, DevKitC-02, etc.) |
| MUX SIG | GPIO 0 | ADC1_CH0 (12-bit) |
| MUX S0 | GPIO 4 | Channel select bit 0 |
| MUX S1 | GPIO 3 | Channel select bit 1 |
| MUX S2 | GPIO 2 | Channel select bit 2 |
| MUX INH | GPIO 5 | Active-low enable (tie LOW) |
| Status LED | GPIO 7 | Active-low (LOW = ON) |
| FSR Sensors | 8× | Connected to MUX channels 0–7 |

### FSR → Plate Mapping

| Plate | FSR Channels | Average Of |
|-------|--------------|------------|
| Head | 0, 1 | `(FSR0 + FSR1) / 2` |
| Shoulders | 2, 3 | `(FSR2 + FSR3) / 2` |
| Hips | 4, 5 | `(FSR4 + FSR5) / 2` |
| Heels | 6, 7 | `(FSR6 + FSR7) / 2` |

---

## BLE Protocol

**Device Name:** `VitalSense-ESP32C3`  
**Service UUID:** `7a0a0001-5b8a-4f4c-9d1d-8b4e3d7a1000`  
**RX Char (EFR→ESP):** `7a0a0002-5b8a-4f4c-9d1d-8b4e3d7a1000` (WRITE)  
**TX Char (ESP→EFR):** `7a0a0003-5b8a-4f4c-9d1d-8b4e3d7a1000` (READ | NOTIFY)

### Commands (EFR32 → ESP32)

| CMD | Payload | Description |
|-----|---------|-------------|
| `0x01` | — | Request fresh 8-FSR scan |
| `0x02` | `bodyId, risk(0-100), avoidFlag` | ML risk per body (×4) |
| `0x03` | `pos, dur_u32_le, riskValid, zone, score, level` | Posture summary |

### Response (ESP32 → EFR32)

| Byte | Value |
|------|-------|
| `[0]` | `0x81` |
| `[1]` | `0x08` (sensor count) |
| `[2..17]` | 8 × `uint16_t` little-endian FSR values |

### Body IDs (for `0x02`)

| ID | Body Part |
|----|-----------|
| 1 | Head |
| 2 | Shoulders |
| 3 | Hips |
| 4 | Heels |

### State Packet (`0x03`) — 10 bytes

| Offset | Field | Description |
|--------|-------|-------------|
| `[0]` | `0x03` | Command |
| `[1]` | position | 0=CENTER, 1=LEFT, 2=RIGHT |
| `[2..5]` | duration_sec | uint32 little-endian |
| `[6]` | risk_valid | 0/1 |
| `[7]` | highest_zone | 0=none, 1=Head, 2=Shoulders, 3=Hips, 4=Heels |
| `[8]` | highest_score | 0–100 |
| `[9]` | risk_level | 0=LOW, 1=MEDIUM, 2=HIGH |

---

## UDP Broadcast (VitalSense Protocol v1)

**Port:** 5005 (broadcast to subnet)  
**Interval:** 1000 ms  
**Format:** Manual JSON (no ArduinoJson)

```json
{
  "protocol": 1,
  "deviceId": "VS-BED-001",
  "bed": 1,
  "position": "CENTER",
  "positionDuration": 45,
  "plates": {"head": 2048, "shoulders": 1892, "hips": 3120, "heels": 1567},
  "fsr": [2010, 2086, 1845, 1939, 3088, 3152, 1521, 1613],
  "riskValid": true,
  "risk": {"head": 12, "shoulders": 8, "hips": 45, "heels": 3},
  "highestRisk": {"zone": "HIPS", "score": 45, "level": "MEDIUM"},
  "avoidReturn": {"head": 0, "shoulders": 0, "hips": 0, "heels": 0},
  "uptime": 1234
}
```

### Field Notes

| Field | Description |
|-------|-------------|
| `position` | `"CENTER"`, `"LEFT"`, `"RIGHT"`, `"UNKNOWN"` |
| `positionDuration` | Uninterrupted seconds in current posture |
| `plates` | 4 averaged plate ADC values (0–4095) |
| `fsr` | 8 raw FSR ADC values (0–4095) |
| `riskValid` | `true` only after EFR32 threshold + all 4 risk packets |
| `risk` | Per-body risk 0–100 (or `-1` if not valid) |
| `highestRisk` | Zone with max risk + score + level |
| `avoidReturn` | Per-body flag (0/1) from EFR32 `0x02` packets |
| `uptime` | ESP32 uptime in seconds |

---

## Status LED (GPIO 7, Active-Low)

| Pattern | Meaning |
|---------|---------|
| **Solid ON** | Wi-Fi connected + BLE connected + UDP transmitted |
| **Blinking (500 ms)** | Any of: Wi-Fi down, BLE disconnected, no UDP success yet |
| **OFF** | Never (LED only OFF during solid ON state) |

> **Electrical:** GPIO LOW = LED ON, GPIO HIGH = LED OFF

---

## Key Timing Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `SENSOR_SCAN_INTERVAL_MS` | 250 | Periodic FSR scan for local freshness |
| `UDP_SEND_INTERVAL_MS` | 1000 | UDP broadcast interval |
| `WIFI_RETRY_INTERVAL_MS` | 5000 | Wi-Fi reconnect retry |
| `MUX_SETTLE_MS` | 3 | MUX channel settle time |
| `SAMPLES_PER_READ` | 8 | ADC samples per channel (averaged) |
| `SAMPLE_DELAY_MS` | 1 | Delay between samples |

---

## User Configuration

Edit at top of `VitalSense_ESP32.ino`:

```cpp
static const char* WIFI_SSID     = "Blink";
static const char* WIFI_PASSWORD = "Arpan@123";

static const uint16_t UDP_PORT = 5005;

static const uint8_t PROTOCOL_VERSION = 1;
static const char* DEVICE_ID = "VS-BED-001";
static const uint8_t BED_ID = 1;
```

---

## Building & Flashing

### Prerequisites

- **Arduino IDE** 2.x or **VS Code + PlatformIO**
- **ESP32 Arduino Core** 3.x
- **NimBLE-Arduino** library (Library Manager → search "NimBLE-Arduino")

### Arduino IDE

1. Install ESP32 board package:  
   `File → Preferences → Additional Boards Manager URLs:`  
   `https://raw.githubusercontent.com/espressif/arduino-esp32/gh-pages/package_esp32_index.json`
2. `Tools → Board → ESP32 Arduino → ESP32C3 Dev Module` (or your board)
3. Install library: `Sketch → Include Library → Manage Libraries → NimBLE-Arduino`
4. Open `VitalSense_ESP32.ino`
5. Select port, click **Upload**

### PlatformIO (`platformio.ini`)

```ini
[env:esp32c3]
platform = espressif32
board = esp32c3-devkitm-1  ; or your board
framework = arduino
lib_deps =
    h2zero/NimBLE-Arduino@^2.3.7
monitor_speed = 115200
```

---

## Serial Debug Output (115200 baud)

```
[BOOT] VitalSense LEAN ready
[BLE] Service start: OK
[BLE] Server start: CALLED
[BLE] Local GATT service check: FOUND
[BLE] VitalSense peripheral ready
[WiFi] IP=192.168.1.42
[UDP] Broadcast=192.168.1.255:5005
[BLE] EFR32 connected
[BLE TX] FSR 2010,2086,1845,1939,3088,3152,1521,1613
[BLE] EFR32 disconnected
[BLE] EFR32 connected
```

---

## Project Structure

```
ESP32 firmware/
└── VitalSense_ESP32.ino    # Single-file sketch (lean build)
```

### Lean Build Optimizations

| Removed | Replaced With |
|---------|---------------|
| Arduino BLE (large) | NimBLE-Arduino 2.x |
| ArduinoJson | Manual `snprintf` JSON |
| Local ML / pressure algorithm | EFR32 does all inference |
| Movement / duration tracking | EFR32 tracks posture time |
| BLE2902 CCCD object | NimBLE auto-creates |

---

## Protocol Compatibility

| EFR32 Firmware | ESP32 Firmware | Protocol |
|----------------|----------------|----------|
| `VITALSENSE_XG26_IMU_BLE_ML_V1` | This lean build | v1 |

---

## References

- [NimBLE-Arduino GitHub](https://github.com/h2zero/NimBLE-Arduino)
- [ESP32-C3 Technical Reference](https://www.espressif.com/en/products/socs/esp32-c3)
- [74HC4051 Datasheet](https://www.nxp.com/docs/en/data-sheet/74HC_HCT4051.pdf)
- VitalSense Protocol v1 (this document)

---

## License

SPDX-License-Identifier: MIT  
Copyright 2025 VitalSense Project Contributors