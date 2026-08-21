/*
  VitalSense ESP32-C3 - LEAN BUILD

  Purpose
  -------
  Keeps only the functions needed for the final xG26 architecture:

  1. Read 8 FSR sensors through 74HC4051/CD4051.
  2. Average them into Head / Shoulders / Hips / Heels.
  3. Act as BLE peripheral for the EFR32xG26.
  4. On command 0x01, perform a fresh FSR scan and notify all 8 FSR values.
  5. Receive four EFR32 ML risk packets:
       [0x02, bodyId, risk0to100, avoidReturnFlag]
  6. Receive EFR32 posture / summary state:
       [0x03, position, duration_u32_le, riskValid,
        highestZone, highestScore, riskLevel]
  7. Provision local Wi-Fi credentials from a phone over BLE and retain them
     in ESP32 NVS across reboots.
  8. Broadcast the complete VitalSense Protocol v1 JSON over UDP.
  9. Drive the active-low GPIO 7 system-status LED.

  Size reductions compared with the previous sketch
  -------------------------------------------------
  - NimBLE instead of the larger classic Arduino BLE classes.
  - ArduinoJson removed.
  - ESP32 local pressure-risk algorithm removed.
  - Pressure-duration and movement tracking removed.
  - BLE2902 object removed; NimBLE creates CCCD automatically.
  - Logging reduced.

  BLE protocol
  ------------
  Name:
    VitalSense-ESP32C3

  Service:
    7a0a0001-5b8a-4f4c-9d1d-8b4e3d7a1000

  RX (EFR32 -> ESP32):
    7a0a0002-5b8a-4f4c-9d1d-8b4e3d7a1000

  TX (ESP32 -> EFR32):
    7a0a0003-5b8a-4f4c-9d1d-8b4e3d7a1000

  EFR32 -> ESP32:
    01
    02 BODY RISK FLAG
    03 POSITION DURATION_U32_LE RISK_VALID HIGHEST_ZONE HIGHEST_SCORE LEVEL

  ESP32 -> EFR32:
    81 08 FSR0_L FSR0_H ... FSR7_L FSR7_H

  Phone Wi-Fi provisioning BLE service:
    Service: 7a0a0101-5b8a-4f4c-9d1d-8b4e3d7a1000
    SSID:    7a0a0102-5b8a-4f4c-9d1d-8b4e3d7a1000  (WRITE UTF-8)
    Password:7a0a0103-5b8a-4f4c-9d1d-8b4e3d7a1000  (WRITE UTF-8)
    Command: 7a0a0104-5b8a-4f4c-9d1d-8b4e3d7a1000  (WRITE)
             CONNECT / STATUS / CLEAR
    Status:  7a0a0105-5b8a-4f4c-9d1d-8b4e3d7a1000  (READ + NOTIFY)

  Target library:
    NimBLE-Arduino 2.x
*/

#include <Arduino.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <Preferences.h>
#include <NimBLEDevice.h>

/* ============================================================
   USER CONFIG
   ============================================================ */

/*
 * Wi-Fi credentials are provisioned from the phone over BLE and saved in
 * ESP32 NVS. Nothing is hard-coded here anymore.
 */
static const uint16_t UDP_PORT = 5005;

static const uint32_t WIFI_PROVISION_TIMEOUT_MS = 20000;
static const size_t WIFI_SSID_MAX_LEN = 32;
static const size_t WIFI_PASSWORD_MAX_LEN = 64;

/*
 * VitalSense Protocol v1 identity.
 * Change DEVICE_ID / BED_ID for each deployed bed.
 */
static const uint8_t PROTOCOL_VERSION = 1;
static const char* DEVICE_ID = "VS-BED-001";
static const uint8_t BED_ID = 1;

/* ============================================================
   FSR / MUX
   ============================================================ */

#define MUX_SIG 0
#define MUX_S0  4
#define MUX_S1  3
#define MUX_S2  2
#define MUX_INH 5

#define STATUS_LED 7

static const uint8_t FSR_COUNT = 8;
static const uint8_t PLATE_COUNT = 4;

static const uint16_t MUX_SETTLE_MS = 3;
static const uint8_t SAMPLES_PER_READ = 8;
static const uint16_t SAMPLE_DELAY_MS = 1;

static const uint32_t SENSOR_SCAN_INTERVAL_MS = 250;
static const uint32_t UDP_SEND_INTERVAL_MS = 1000;
static const uint32_t WIFI_RETRY_INTERVAL_MS = 5000;
static const uint32_t STATUS_LED_BLINK_INTERVAL_MS = 500;

static uint16_t fsrRaw[FSR_COUNT] = {0};
static uint16_t plateAverage[PLATE_COUNT] = {0};

static uint32_t lastSensorScanMs = 0;
static uint32_t lastUdpSendMs = 0;
static uint32_t lastWifiRetryMs = 0;

/* ============================================================
   BLE
   ============================================================ */

#define BLE_DEVICE_NAME "VitalSense-ESP32C3"

#define BLE_SERVICE_UUID "7a0a0001-5b8a-4f4c-9d1d-8b4e3d7a1000"
#define BLE_RX_UUID      "7a0a0002-5b8a-4f4c-9d1d-8b4e3d7a1000"
#define BLE_TX_UUID      "7a0a0003-5b8a-4f4c-9d1d-8b4e3d7a1000"

/*
 * Phone Wi-Fi provisioning service.
 *
 * The service itself does not need to be included in the advertising packet;
 * the phone can find the unit by BLE_DEVICE_NAME, connect, then discover it.
 * This keeps the legacy advertising packet small while the existing xG26
 * service UUID remains advertised.
 */
#define WIFI_PROV_SERVICE_UUID "7a0a0101-5b8a-4f4c-9d1d-8b4e3d7a1000"
#define WIFI_PROV_SSID_UUID    "7a0a0102-5b8a-4f4c-9d1d-8b4e3d7a1000"
#define WIFI_PROV_PASS_UUID    "7a0a0103-5b8a-4f4c-9d1d-8b4e3d7a1000"
#define WIFI_PROV_CMD_UUID     "7a0a0104-5b8a-4f4c-9d1d-8b4e3d7a1000"
#define WIFI_PROV_STATUS_UUID  "7a0a0105-5b8a-4f4c-9d1d-8b4e3d7a1000"

static const uint8_t BLE_CMD_REQUEST_FSR = 0x01;
static const uint8_t BLE_CMD_RISK_UPDATE = 0x02;
static const uint8_t BLE_CMD_STATE_UPDATE = 0x03;
static const uint8_t BLE_MSG_FSR_RESPONSE = 0x81;

static const uint8_t STATE_PACKET_LENGTH = 10;

static NimBLEServer* bleServer = nullptr;
static NimBLECharacteristic* bleRx = nullptr;
static NimBLECharacteristic* bleTx = nullptr;

static NimBLECharacteristic* wifiProvSsid = nullptr;
static NimBLECharacteristic* wifiProvPass = nullptr;
static NimBLECharacteristic* wifiProvCmd = nullptr;
static NimBLECharacteristic* wifiProvStatus = nullptr;

/*
 * A phone can also connect to this BLE server, so a generic server connection
 * is not the same thing as the EFR32/xG26 connection. We mark the EFR32 link
 * active only when it actually writes the VitalSense RX characteristic.
 */
static volatile bool efrBleConnected = false;
static volatile uint16_t efrConnHandle = 0xFFFFU;
static volatile bool bleFsrRequestPending = false;

/* ============================================================
   EFR RISK STATE
   ============================================================ */

struct EfrRiskState {
  uint8_t risk;
  bool avoidReturn;
  bool valid;
};

/*
 * Active risk state exposed to UDP.
 * New 0x02 packets are first staged and are committed atomically only when
 * the following 0x03 summary packet arrives. This prevents the dashboard/app
 * from seeing a mixture of old and new body risks while the four BLE writes
 * are still in progress.
 */
static EfrRiskState efrRisk[PLATE_COUNT] = {};
static EfrRiskState pendingEfrRisk[PLATE_COUNT] = {};
static uint8_t pendingRiskMask = 0U;

struct EfrSummaryState {
  uint8_t position;             // 0=CENTER, 1=LEFT, 2=RIGHT
  uint32_t positionDurationSec;
  bool riskValid;
  uint8_t highestRiskZone;      // 0=none, 1=Head, 2=Shoulders, 3=Hips, 4=Heels
  uint8_t highestRiskScore;     // 0..100
  uint8_t riskLevel;            // 0=LOW, 1=MEDIUM, 2=HIGH
  bool valid;                   // received at least one 0x03 packet
};

static EfrSummaryState efrSummary = {};

static portMUX_TYPE sharedMux = portMUX_INITIALIZER_UNLOCKED;

/* ============================================================
   WIFI / UDP
   ============================================================ */

static WiFiUDP udp;
static Preferences wifiPreferences;

static bool wifiWasConnected = false;
static volatile bool udpHasTransmitted = false;

/* Saved/active Wi-Fi credentials. */
static char wifiSsid[WIFI_SSID_MAX_LEN + 1] = {0};
static char wifiPassword[WIFI_PASSWORD_MAX_LEN + 1] = {0};
static bool wifiCredentialsAvailable = false;

/* Credentials staged by the phone over BLE. */
static char stagedWifiSsid[WIFI_SSID_MAX_LEN + 1] = {0};
static char stagedWifiPassword[WIFI_PASSWORD_MAX_LEN + 1] = {0};
static volatile bool stagedSsidReceived = false;
static volatile bool stagedPasswordReceived = false;
static volatile bool wifiConnectRequested = false;
static volatile bool wifiClearRequested = false;
static volatile bool wifiStatusRequested = false;

/* Candidate connection is tested before replacing the saved credentials. */
static bool wifiProvisionAttemptActive = false;
static uint32_t wifiProvisionStartedMs = 0;

/* ============================================================
   BASIC HELPERS
   ============================================================ */

static void setStatusLed(bool on)
{
  digitalWrite(STATUS_LED, on ? LOW : HIGH);
}

static IPAddress getSubnetBroadcastAddress()
{
  const IPAddress ip = WiFi.localIP();
  const IPAddress mask = WiFi.subnetMask();

  IPAddress broadcast;

  for (uint8_t i = 0; i < 4; i++) {
    broadcast[i] =
        (uint8_t)(ip[i] | (uint8_t)(~mask[i]));
  }

  return broadcast;
}

static const char* positionName(uint8_t position)
{
  switch (position) {
    case 1: return "LEFT";
    case 2: return "RIGHT";
    case 0:
    default:
      return "CENTER";
  }
}

static const char* zoneName(uint8_t zone)
{
  switch (zone) {
    case 1: return "HEAD";
    case 2: return "SHOULDERS";
    case 3: return "HIPS";
    case 4: return "HEELS";
    default:
      return "NONE";
  }
}

static const char* riskLevelName(uint8_t level)
{
  switch (level) {
    case 1: return "MEDIUM";
    case 2: return "HIGH";
    case 0:
    default:
      return "LOW";
  }
}

static uint32_t getU32LE(const uint8_t* src)
{
  return ((uint32_t)src[0])
      | ((uint32_t)src[1] << 8U)
      | ((uint32_t)src[2] << 16U)
      | ((uint32_t)src[3] << 24U);
}

static void selectMuxChannel(uint8_t channel)
{
  digitalWrite(MUX_S0, bitRead(channel, 0));
  digitalWrite(MUX_S1, bitRead(channel, 1));
  digitalWrite(MUX_S2, bitRead(channel, 2));
}

static uint16_t readMuxChannel()
{
  delay(MUX_SETTLE_MS);

  /* Discard first conversion after switching the MUX. */
  (void)analogRead(MUX_SIG);

  uint32_t total = 0;

  for (uint8_t i = 0; i < SAMPLES_PER_READ; i++) {
    total += (uint16_t)analogRead(MUX_SIG);

    if (SAMPLE_DELAY_MS != 0) {
      delay(SAMPLE_DELAY_MS);
    }
  }

  return (uint16_t)(total / SAMPLES_PER_READ);
}

static void scanAllSensors()
{
  for (uint8_t i = 0; i < FSR_COUNT; i++) {
    selectMuxChannel(i);
    fsrRaw[i] = readMuxChannel();
  }

  plateAverage[0] =
      (uint16_t)(((uint32_t)fsrRaw[0] + fsrRaw[1]) / 2U);

  plateAverage[1] =
      (uint16_t)(((uint32_t)fsrRaw[2] + fsrRaw[3]) / 2U);

  plateAverage[2] =
      (uint16_t)(((uint32_t)fsrRaw[4] + fsrRaw[5]) / 2U);

  plateAverage[3] =
      (uint16_t)(((uint32_t)fsrRaw[6] + fsrRaw[7]) / 2U);
}

static void putU16LE(uint8_t* dst, uint16_t value)
{
  dst[0] = (uint8_t)(value & 0xFFU);
  dst[1] = (uint8_t)((value >> 8U) & 0xFFU);
}

/* ============================================================
   WIFI CREDENTIAL STORAGE / BLE PROVISIONING HELPERS
   ============================================================ */

static void setProvisioningStatus(const char* status)
{
  if (wifiProvStatus == nullptr) {
    return;
  }

  wifiProvStatus->setValue(status);
  wifiProvStatus->notify();

  Serial.print("[WiFi Prov] ");
  Serial.println(status);
}

static void publishCurrentWifiStatus()
{
  char status[128];

  if (WiFi.status() == WL_CONNECTED) {
    snprintf(
        status,
        sizeof(status),
        "CONNECTED|%s|%s",
        WiFi.SSID().c_str(),
        WiFi.localIP().toString().c_str());
  } else if (wifiProvisionAttemptActive) {
    snprintf(
        status,
        sizeof(status),
        "CONNECTING|%s",
        stagedWifiSsid);
  } else if (wifiCredentialsAvailable) {
    snprintf(
        status,
        sizeof(status),
        "DISCONNECTED|%s",
        wifiSsid);
  } else {
    snprintf(status, sizeof(status), "NO_CREDENTIALS");
  }

  setProvisioningStatus(status);
}

static bool isValidProvisionedCredentials(const char* ssid,
                                          const char* password)
{
  const size_t ssidLen = strlen(ssid);
  const size_t passwordLen = strlen(password);

  if ((ssidLen < 1U) || (ssidLen > WIFI_SSID_MAX_LEN)) {
    return false;
  }

  /* Empty password = open network. WPA/WPA2 PSK is normally 8..63 chars;
     64 is also accepted for a raw hexadecimal PSK. */
  if ((passwordLen != 0U)
      && ((passwordLen < 8U)
          || (passwordLen > WIFI_PASSWORD_MAX_LEN))) {
    return false;
  }

  return true;
}

static void loadWifiCredentials()
{
  wifiSsid[0] = '\0';
  wifiPassword[0] = '\0';
  wifiCredentialsAvailable = false;

  if (!wifiPreferences.begin("vitalwifi", true)) {
    Serial.println("[WiFi] NVS open failed");
    return;
  }

  String storedSsid =
      wifiPreferences.getString("ssid", "");

  String storedPassword =
      wifiPreferences.getString("pass", "");

  wifiPreferences.end();

  if (!isValidProvisionedCredentials(
          storedSsid.c_str(),
          storedPassword.c_str())) {
    Serial.println("[WiFi] No valid saved credentials");
    return;
  }

  strlcpy(
      wifiSsid,
      storedSsid.c_str(),
      sizeof(wifiSsid));

  strlcpy(
      wifiPassword,
      storedPassword.c_str(),
      sizeof(wifiPassword));

  wifiCredentialsAvailable = true;

  Serial.print("[WiFi] Loaded saved SSID: ");
  Serial.println(wifiSsid);
}

static bool saveWifiCredentials(const char* ssid,
                                const char* password)
{
  if (!wifiPreferences.begin("vitalwifi", false)) {
    return false;
  }

  const size_t ssidWritten =
      wifiPreferences.putString("ssid", ssid);

  const size_t passwordWritten =
      wifiPreferences.putString("pass", password);

  wifiPreferences.end();

  if ((ssidWritten == 0U) || (passwordWritten == 0U)) {
    return false;
  }

  strlcpy(wifiSsid, ssid, sizeof(wifiSsid));
  strlcpy(wifiPassword, password, sizeof(wifiPassword));
  wifiCredentialsAvailable = true;

  return true;
}

static void clearWifiCredentials()
{
  if (wifiPreferences.begin("vitalwifi", false)) {
    wifiPreferences.clear();
    wifiPreferences.end();
  }

  wifiSsid[0] = '\0';
  wifiPassword[0] = '\0';
  stagedWifiSsid[0] = '\0';
  stagedWifiPassword[0] = '\0';

  wifiCredentialsAvailable = false;
  stagedSsidReceived = false;
  stagedPasswordReceived = false;
  wifiProvisionAttemptActive = false;

  WiFi.disconnect(true, false);
  udp.stop();
  wifiWasConnected = false;
  udpHasTransmitted = false;

  setProvisioningStatus("CLEARED");
}

static bool copyBleTextToBuffer(NimBLECharacteristic* characteristic,
                                char* destination,
                                size_t destinationSize)
{
  NimBLEAttValue value = characteristic->getValue();
  const size_t len = value.size();

  if ((destinationSize == 0U) || (len >= destinationSize)) {
    return false;
  }

  if (len != 0U) {
    memcpy(destination, value.data(), len);
  }

  destination[len] = '\0';
  return true;
}

class WifiSsidCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* characteristic,
               NimBLEConnInfo& connInfo) override
  {
    (void)connInfo;

    if (!copyBleTextToBuffer(
            characteristic,
            stagedWifiSsid,
            sizeof(stagedWifiSsid))) {
      stagedSsidReceived = false;
      setProvisioningStatus("ERROR|SSID_TOO_LONG");
      return;
    }

    stagedSsidReceived =
        (strlen(stagedWifiSsid) != 0U);

    setProvisioningStatus(
        stagedSsidReceived
        ? "SSID_RECEIVED"
        : "ERROR|SSID_EMPTY");
  }
};

class WifiPasswordCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* characteristic,
               NimBLEConnInfo& connInfo) override
  {
    (void)connInfo;

    if (!copyBleTextToBuffer(
            characteristic,
            stagedWifiPassword,
            sizeof(stagedWifiPassword))) {
      stagedPasswordReceived = false;
      setProvisioningStatus("ERROR|PASSWORD_TOO_LONG");
      return;
    }

    /* Empty is valid for an open Wi-Fi network. */
    stagedPasswordReceived = true;
    setProvisioningStatus("PASSWORD_RECEIVED");
  }
};

class WifiCommandCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* characteristic,
               NimBLEConnInfo& connInfo) override
  {
    (void)connInfo;

    char command[24];

    if (!copyBleTextToBuffer(
            characteristic,
            command,
            sizeof(command))) {
      setProvisioningStatus("ERROR|BAD_COMMAND");
      return;
    }

    if (strcmp(command, "CONNECT") == 0) {
      wifiConnectRequested = true;
      return;
    }

    if (strcmp(command, "CLEAR") == 0) {
      wifiClearRequested = true;
      return;
    }

    if (strcmp(command, "STATUS") == 0) {
      wifiStatusRequested = true;
      return;
    }

    setProvisioningStatus("ERROR|UNKNOWN_COMMAND");
  }
};

/* ============================================================
   BLE CALLBACKS
   ============================================================ */

class VitalSenseServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* server,
                 NimBLEConnInfo& connInfo) override
  {
    Serial.print("[BLE] Client connected, handle=");
    Serial.println(connInfo.getConnHandle());

    /*
     * Continue advertising so the second client (phone or EFR32) can also
     * connect. NimBLE-Arduino defaults to multiple simultaneous connections.
     */
    if (server->getConnectedCount() < 2U) {
      NimBLEDevice::getAdvertising()->start();
    }
  }

  void onDisconnect(NimBLEServer* server,
                    NimBLEConnInfo& connInfo,
                    int reason) override
  {
    (void)server;
    (void)reason;

    if (connInfo.getConnHandle() == efrConnHandle) {
      efrBleConnected = false;
      efrConnHandle = 0xFFFFU;
      udpHasTransmitted = false;

      Serial.println("[BLE] EFR32/xG26 disconnected");
    } else {
      Serial.print("[BLE] Client disconnected, handle=");
      Serial.println(connInfo.getConnHandle());
    }

    /* advertiseOnDisconnect(true) restarts advertising automatically. */
  }
};

class VitalSenseRxCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* characteristic,
               NimBLEConnInfo& connInfo) override
  {
    NimBLEAttValue value =
        characteristic->getValue();

    const size_t len = value.size();

    if (len == 0) {
      return;
    }

    const uint8_t* data =
        value.data();

    const uint8_t command =
        data[0];

    /* Only correctly shaped VitalSense protocol packets identify this peer
       as the EFR32/xG26 rather than a provisioning-phone connection. */
    const bool isEfrPacket =
        ((command == BLE_CMD_REQUEST_FSR) && (len == 1U))
        || ((command == BLE_CMD_RISK_UPDATE) && (len == 4U))
        || ((command == BLE_CMD_STATE_UPDATE)
            && (len == STATE_PACKET_LENGTH));

    if (isEfrPacket) {
      efrBleConnected = true;
      efrConnHandle = connInfo.getConnHandle();
    }

    /*
     * 0x01:
     * xG26 requests a fresh 8-FSR snapshot.
     *
     * Do not block the BLE callback with ADC scanning.
     */
    if ((command == BLE_CMD_REQUEST_FSR)
        && (len == 1)) {

      bleFsrRequestPending = true;
      return;
    }

    /*
     * 0x02 BODY RISK FLAG
     */
    if ((command == BLE_CMD_RISK_UPDATE)
        && (len == 4)) {

      const uint8_t bodyId = data[1];
      const uint8_t risk = data[2];
      const uint8_t flag = data[3];

      if ((bodyId < 1)
          || (bodyId > 4)
          || (risk > 100)
          || (flag > 1)) {

        return;
      }

      const uint8_t index =
          bodyId - 1U;

      portENTER_CRITICAL(&sharedMux);

      pendingEfrRisk[index].risk =
          risk;

      pendingEfrRisk[index].avoidReturn =
          (flag != 0);

      pendingEfrRisk[index].valid =
          true;

      pendingRiskMask |=
          (uint8_t)(1U << index);

      portEXIT_CRITICAL(&sharedMux);
      return;
    }

    /*
     * 0x03 POSITION DURATION_U32_LE RISK_VALID
     *      HIGHEST_ZONE HIGHEST_SCORE LEVEL
     *
     * Total = 10 bytes:
     *   [0] command
     *   [1] position      0=CENTER, 1=LEFT, 2=RIGHT
     *   [2..5] duration   uint32 little-endian seconds
     *   [6] riskValid     0/1
     *   [7] highestZone   0 if invalid, otherwise 1..4
     *   [8] highestScore  0..100
     *   [9] riskLevel     0=LOW, 1=MEDIUM, 2=HIGH
     */
    if ((command == BLE_CMD_STATE_UPDATE)
        && (len == STATE_PACKET_LENGTH)) {

      const uint8_t position = data[1];
      const uint32_t durationSec = getU32LE(&data[2]);
      const uint8_t riskValid = data[6];
      const uint8_t highestZone = data[7];
      const uint8_t highestScore = data[8];
      const uint8_t level = data[9];

      if ((position > 2)
          || (riskValid > 1)
          || (highestZone > 4)
          || (highestScore > 100)
          || (level > 2)) {
        return;
      }

      if ((riskValid != 0)
          && ((highestZone < 1) || (highestZone > 4))) {
        return;
      }

      portENTER_CRITICAL(&sharedMux);

      efrSummary.position = position;
      efrSummary.positionDurationSec = durationSec;
      efrSummary.valid = true;

      if (riskValid == 0U) {
        /*
         * New posture / pre-threshold state. Discard any incomplete risk
         * transaction and clear the active body-risk snapshot.
         */
        pendingRiskMask = 0U;

        for (uint8_t i = 0; i < PLATE_COUNT; i++) {
          efrRisk[i].risk = 0U;
          efrRisk[i].avoidReturn = false;
          efrRisk[i].valid = false;
        }

        efrSummary.riskValid = false;
        efrSummary.highestRiskZone = 0U;
        efrSummary.highestRiskScore = 0U;
        efrSummary.riskLevel = 0U;

      } else if (pendingRiskMask == 0x0FU) {
        /*
         * All four body risk packets arrived. Commit them together so the
         * next UDP JSON packet is a coherent single inference result.
         */
        for (uint8_t i = 0; i < PLATE_COUNT; i++) {
          efrRisk[i] = pendingEfrRisk[i];
        }

        pendingRiskMask = 0U;

        efrSummary.riskValid = true;
        efrSummary.highestRiskZone = highestZone;
        efrSummary.highestRiskScore = highestScore;
        efrSummary.riskLevel = level;

      } else {
        /*
         * A valid summary without all four 0x02 packets is incomplete.
         * Do not expose a partial inference to the app/dashboard.
         */
        efrSummary.riskValid = false;
        efrSummary.highestRiskZone = 0U;
        efrSummary.highestRiskScore = 0U;
        efrSummary.riskLevel = 0U;
      }

      portEXIT_CRITICAL(&sharedMux);
      return;
    }
  }
};

/* ============================================================
   BLE STARTUP / RESPONSE
   ============================================================ */

static void startBLE()
{
  NimBLEDevice::init(BLE_DEVICE_NAME);

  bleServer =
      NimBLEDevice::createServer();

  bleServer->setCallbacks(
      new VitalSenseServerCallbacks());

  NimBLEService* service =
      bleServer->createService(
          BLE_SERVICE_UUID);

  bleRx =
      service->createCharacteristic(
          BLE_RX_UUID,
          NIMBLE_PROPERTY::WRITE);

  bleRx->setCallbacks(
      new VitalSenseRxCallbacks());

  bleTx =
      service->createCharacteristic(
          BLE_TX_UUID,
          NIMBLE_PROPERTY::READ
          | NIMBLE_PROPERTY::NOTIFY);

  /* Phone-facing Wi-Fi provisioning GATT service. */
  NimBLEService* wifiService =
      bleServer->createService(
          WIFI_PROV_SERVICE_UUID);

  wifiProvSsid =
      wifiService->createCharacteristic(
          WIFI_PROV_SSID_UUID,
          NIMBLE_PROPERTY::WRITE);

  wifiProvSsid->setCallbacks(
      new WifiSsidCallbacks());

  wifiProvPass =
      wifiService->createCharacteristic(
          WIFI_PROV_PASS_UUID,
          NIMBLE_PROPERTY::WRITE);

  wifiProvPass->setCallbacks(
      new WifiPasswordCallbacks());

  wifiProvCmd =
      wifiService->createCharacteristic(
          WIFI_PROV_CMD_UUID,
          NIMBLE_PROPERTY::WRITE);

  wifiProvCmd->setCallbacks(
      new WifiCommandCallbacks());

  wifiProvStatus =
      wifiService->createCharacteristic(
          WIFI_PROV_STATUS_UUID,
          NIMBLE_PROPERTY::READ
          | NIMBLE_PROPERTY::NOTIFY);

  wifiProvStatus->setValue("BOOTING");

  const bool wifiServiceStarted =
      wifiService->start();

  Serial.print("[BLE] Wi-Fi provisioning service: ");
  Serial.println(wifiServiceStarted ? "OK" : "FAILED");

  /*
   * IMPORTANT:
   * Explicitly start the service before advertising.
   *
   * This is required by older NimBLE-Arduino 2.x releases and remains
   * available for compatibility in newer releases. Advertising a UUID does
   * NOT by itself guarantee that the service has been registered in the
   * remote GATT database.
   */
  const bool serviceStarted =
      service->start();

  Serial.print("[BLE] Service start: ");
  Serial.println(serviceStarted ? "OK" : "FAILED");

  /*
   * Newer NimBLE-Arduino versions register configured services when the
   * server starts. Calling this after service->start() keeps the sketch
   * compatible with that flow too.
   */
  /*
   * NimBLE-Arduino 2.3.7:
   * NimBLEServer::start() returns void, so do not assign its return value.
   */
  bleServer->start();
  bleServer->advertiseOnDisconnect(true);

  Serial.println("[BLE] Server start: CALLED");

  NimBLEAdvertising* advertising =
      NimBLEDevice::getAdvertising();

  advertising->addServiceUUID(
      BLE_SERVICE_UUID);

  advertising->setName(
      BLE_DEVICE_NAME);

  advertising->start();

  /*
   * Local sanity check: the service must exist in the ESP32 server before
   * the EFR32 can discover it over GATT.
   */
  NimBLEService* checkService =
      bleServer->getServiceByUUID(BLE_SERVICE_UUID);

  Serial.print("[BLE] Local GATT service check: ");
  Serial.println(checkService != nullptr ? "FOUND" : "NOT FOUND");

  Serial.println("[BLE] VitalSense peripheral + Wi-Fi provisioning ready");
}

static void sendFreshFsrNotification()
{
  uint8_t packet[18];

  packet[0] =
      BLE_MSG_FSR_RESPONSE;

  packet[1] =
      FSR_COUNT;

  for (uint8_t i = 0; i < FSR_COUNT; i++) {
    putU16LE(
        &packet[2U + (i * 2U)],
        fsrRaw[i]);
  }

  bleTx->setValue(
      packet,
      sizeof(packet));

  if (efrBleConnected) {
    bleTx->notify();
  }
}

/* ============================================================
   SYSTEM STATUS LED - ACTIVE LOW GPIO 7

   Behaviour:
     Blink  : Wi-Fi not connected, BLE not connected, or no
              successful UDP broadcast has occurred yet.
     Solid  : Wi-Fi connected + EFR32 BLE connected + at least
              one UDP packet successfully broadcast.

   Active-low electrical behaviour:
     GPIO LOW  = LED ON
     GPIO HIGH = LED OFF
   ============================================================ */

static void updateSystemStatusLed()
{
  const bool systemReady =
      (WiFi.status() == WL_CONNECTED)
      && efrBleConnected
      && udpHasTransmitted;

  if (systemReady) {
    setStatusLed(true);
    return;
  }

  const bool blinkOn =
      ((millis() / STATUS_LED_BLINK_INTERVAL_MS) % 2U) == 0U;

  setStatusLed(blinkOn);
}

/* ============================================================
   BLE REQUEST PROCESSING
   ============================================================ */

static void processBleRequest()
{
  if (!bleFsrRequestPending) {
    return;
  }

  bleFsrRequestPending = false;

  /*
   * Requirement: xG26 must receive a fresh sensor snapshot.
   */
  scanAllSensors();

  lastSensorScanMs =
      millis();

  sendFreshFsrNotification();

  Serial.printf(
      "[BLE TX] FSR %u,%u,%u,%u,%u,%u,%u,%u\n",
      fsrRaw[0], fsrRaw[1],
      fsrRaw[2], fsrRaw[3],
      fsrRaw[4], fsrRaw[5],
      fsrRaw[6], fsrRaw[7]);
}

/* ============================================================
   WIFI
   ============================================================ */

static void startWiFi()
{
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);

  if (!wifiCredentialsAvailable) {
    Serial.println("[WiFi] Waiting for BLE provisioning");
    setProvisioningStatus("NO_CREDENTIALS");
    return;
  }

  Serial.print("[WiFi] Connecting to saved SSID: ");
  Serial.println(wifiSsid);

  WiFi.begin(
      wifiSsid,
      wifiPassword);

  lastWifiRetryMs =
      millis();

  setProvisioningStatus("CONNECTING_SAVED");
}

static void beginProvisionedWifiAttempt()
{
  if (!stagedSsidReceived || !stagedPasswordReceived) {
    setProvisioningStatus("ERROR|SEND_SSID_AND_PASSWORD");
    return;
  }

  if (!isValidProvisionedCredentials(
          stagedWifiSsid,
          stagedWifiPassword)) {
    setProvisioningStatus("ERROR|INVALID_CREDENTIALS_FORMAT");
    return;
  }

  wifiProvisionAttemptActive = true;
  wifiProvisionStartedMs = millis();
  wifiWasConnected = false;
  udpHasTransmitted = false;

  udp.stop();
  WiFi.disconnect(true, false);
  delay(50);
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);

  Serial.print("[WiFi Prov] Testing SSID: ");
  Serial.println(stagedWifiSsid);

  WiFi.begin(
      stagedWifiSsid,
      stagedWifiPassword);

  char status[96];
  snprintf(
      status,
      sizeof(status),
      "CONNECTING|%s",
      stagedWifiSsid);
  setProvisioningStatus(status);
}

static void processWifiProvisioning()
{
  if (wifiClearRequested) {
    wifiClearRequested = false;
    clearWifiCredentials();
  }

  if (wifiStatusRequested) {
    wifiStatusRequested = false;
    publishCurrentWifiStatus();
  }

  if (wifiConnectRequested) {
    wifiConnectRequested = false;
    beginProvisionedWifiAttempt();
  }

  if (!wifiProvisionAttemptActive) {
    return;
  }

  if (WiFi.status() == WL_CONNECTED) {
    wifiProvisionAttemptActive = false;

    if (!saveWifiCredentials(
            stagedWifiSsid,
            stagedWifiPassword)) {
      setProvisioningStatus("ERROR|NVS_SAVE_FAILED");
      return;
    }

    stagedSsidReceived = false;
    stagedPasswordReceived = false;

    char status[128];
    snprintf(
        status,
        sizeof(status),
        "CONNECTED|%s|%s",
        wifiSsid,
        WiFi.localIP().toString().c_str());

    setProvisioningStatus(status);
    Serial.println("[WiFi Prov] Credentials verified and saved");
    return;
  }

  if ((millis() - wifiProvisionStartedMs)
      < WIFI_PROVISION_TIMEOUT_MS) {
    return;
  }

  wifiProvisionAttemptActive = false;
  WiFi.disconnect(true, false);

  setProvisioningStatus("FAILED|CHECK_SSID_PASSWORD");

  /* If this was a reconfiguration attempt, recover the last known-good Wi-Fi. */
  if (wifiCredentialsAvailable) {
    delay(50);
    WiFi.mode(WIFI_STA);
    WiFi.setSleep(false);
    WiFi.begin(wifiSsid, wifiPassword);
    lastWifiRetryMs = millis();
  }
}

static void maintainWiFi()
{
  /* Provisioning owns the Wi-Fi state machine while a candidate is tested. */
  if (wifiProvisionAttemptActive) {
    return;
  }

  const bool connected =
      (WiFi.status() == WL_CONNECTED);

  if (connected) {
    if (!wifiWasConnected) {
      wifiWasConnected = true;
      udpHasTransmitted = false;

      udp.stop();
      udp.begin(UDP_PORT);

      Serial.print("[WiFi] IP=");
      Serial.println(WiFi.localIP());

      Serial.print("[UDP] Broadcast=");
      Serial.print(getSubnetBroadcastAddress());
      Serial.print(":");
      Serial.println(UDP_PORT);

      publishCurrentWifiStatus();
    }

    return;
  }

  if (wifiWasConnected) {
    wifiWasConnected = false;
    udpHasTransmitted = false;
    udp.stop();

    Serial.println("[WiFi] disconnected");
    publishCurrentWifiStatus();
  }

  if (!wifiCredentialsAvailable) {
    return;
  }

  const uint32_t now =
      millis();

  if ((now - lastWifiRetryMs)
      >= WIFI_RETRY_INTERVAL_MS) {

    lastWifiRetryMs =
        now;

    WiFi.disconnect(false, false);

    WiFi.begin(
        wifiSsid,
        wifiPassword);
  }
}

/* ============================================================
   UDP - MANUAL JSON, NO ArduinoJson
   ============================================================ */

static void sendUdpState()
{
  if (WiFi.status() != WL_CONNECTED) {
    return;
  }

  EfrRiskState risk[PLATE_COUNT];
  EfrSummaryState summary;

  portENTER_CRITICAL(&sharedMux);

  for (uint8_t i = 0; i < PLATE_COUNT; i++) {
    risk[i] = efrRisk[i];
  }

  summary = efrSummary;

  portEXIT_CRITICAL(&sharedMux);

  /*
   * The per-body risks are valid for the CURRENT posture only when the
   * xG26 summary says riskValid=true. Before the threshold, or immediately
   * after a posture change, expose -1 instead of stale risk values.
   */
  const bool currentRiskValid =
      summary.valid && summary.riskValid;

  const int r0 =
      (currentRiskValid && risk[0].valid) ? risk[0].risk : -1;

  const int r1 =
      (currentRiskValid && risk[1].valid) ? risk[1].risk : -1;

  const int r2 =
      (currentRiskValid && risk[2].valid) ? risk[2].risk : -1;

  const int r3 =
      (currentRiskValid && risk[3].valid) ? risk[3].risk : -1;

  const int a0 =
      (risk[0].valid && risk[0].avoidReturn) ? 1 : 0;

  const int a1 =
      (risk[1].valid && risk[1].avoidReturn) ? 1 : 0;

  const int a2 =
      (risk[2].valid && risk[2].avoidReturn) ? 1 : 0;

  const int a3 =
      (risk[3].valid && risk[3].avoidReturn) ? 1 : 0;

  const char* position =
      summary.valid ? positionName(summary.position) : "UNKNOWN";

  const unsigned long positionDuration =
      summary.valid
      ? (unsigned long)summary.positionDurationSec
      : 0UL;

  const char* highestZone =
      currentRiskValid
      ? zoneName(summary.highestRiskZone)
      : "NONE";

  const int highestScore =
      currentRiskValid
      ? (int)summary.highestRiskScore
      : -1;

  const char* level =
      currentRiskValid
      ? riskLevelName(summary.riskLevel)
      : "WAITING";

  /*
   * VitalSense Protocol v1.
   * Manual snprintf keeps flash/RAM smaller than ArduinoJson.
   */
  char json[640];

  const int length =
      snprintf(
          json,
          sizeof(json),
          "{\"protocol\":%u,"
          "\"deviceId\":\"%s\","
          "\"bed\":%u,"
          "\"position\":\"%s\","
          "\"positionDuration\":%lu,"
          "\"plates\":{"
            "\"head\":%u,"
            "\"shoulders\":%u,"
            "\"hips\":%u,"
            "\"heels\":%u},"
          "\"fsr\":[%u,%u,%u,%u,%u,%u,%u,%u],"
          "\"riskValid\":%s,"
          "\"risk\":{"
            "\"head\":%d,"
            "\"shoulders\":%d,"
            "\"hips\":%d,"
            "\"heels\":%d},"
          "\"highestRisk\":{"
            "\"zone\":\"%s\","
            "\"score\":%d,"
            "\"level\":\"%s\"},"
          "\"avoidReturn\":{"
            "\"head\":%d,"
            "\"shoulders\":%d,"
            "\"hips\":%d,"
            "\"heels\":%d},"
          "\"uptime\":%lu}",
          PROTOCOL_VERSION,
          DEVICE_ID,
          BED_ID,
          position,
          positionDuration,
          plateAverage[0],
          plateAverage[1],
          plateAverage[2],
          plateAverage[3],
          fsrRaw[0],
          fsrRaw[1],
          fsrRaw[2],
          fsrRaw[3],
          fsrRaw[4],
          fsrRaw[5],
          fsrRaw[6],
          fsrRaw[7],
          currentRiskValid ? "true" : "false",
          r0, r1, r2, r3,
          highestZone,
          highestScore,
          level,
          a0, a1, a2, a3,
          (unsigned long)(millis() / 1000UL));

  if ((length <= 0)
      || (length >= (int)sizeof(json))) {
    return;
  }

  const IPAddress broadcastIp =
      getSubnetBroadcastAddress();

  if (!udp.beginPacket(
          broadcastIp,
          UDP_PORT)) {
    return;
  }

  udp.write(
      (const uint8_t*)json,
      (size_t)length);

  const int sendResult =
      udp.endPacket();

  if (sendResult == 1) {
    udpHasTransmitted = true;
  }
}

/* ============================================================
   SETUP
   ============================================================ */

void setup()
{
  Serial.begin(115200);

  analogReadResolution(12);

  pinMode(MUX_SIG, INPUT);
  pinMode(MUX_S0, OUTPUT);
  pinMode(MUX_S1, OUTPUT);
  pinMode(MUX_S2, OUTPUT);
  pinMode(MUX_INH, OUTPUT);

  digitalWrite(MUX_INH, LOW);

  pinMode(STATUS_LED, OUTPUT);
  setStatusLed(false);

  selectMuxChannel(0);

  /* Load the last known-good Wi-Fi settings from NVS. */
  loadWifiCredentials();

  /*
   * BLE first: xG26 and the setup phone can connect even when Wi-Fi is
   * unavailable or has never been configured.
   */
  startBLE();

  startWiFi();

  scanAllSensors();

  lastSensorScanMs =
      millis();

  lastUdpSendMs =
      millis();

  Serial.println("[BOOT] VitalSense LEAN ready");
}

/* ============================================================
   LOOP
   ============================================================ */

void loop()
{
  processWifiProvisioning();
  maintainWiFi();

  /*
   * Highest priority:
   * service the xG26 request with a fresh sensor scan.
   */
  processBleRequest();

  const uint32_t now =
      millis();

  /*
   * Keep local values fresh for UDP.
   */
  if ((now - lastSensorScanMs)
      >= SENSOR_SCAN_INTERVAL_MS) {

    lastSensorScanMs =
        now;

    scanAllSensors();

    /*
     * Update the READ value but do not send unsolicited notification.
     */
    uint8_t packet[18];

    packet[0] =
        BLE_MSG_FSR_RESPONSE;

    packet[1] =
        FSR_COUNT;

    for (uint8_t i = 0; i < FSR_COUNT; i++) {
      putU16LE(
          &packet[2U + (i * 2U)],
          fsrRaw[i]);
    }

    bleTx->setValue(
        packet,
        sizeof(packet));
  }

  if ((now - lastUdpSendMs)
      >= UDP_SEND_INTERVAL_MS) {

    lastUdpSendMs =
        now;

    sendUdpState();
  }

  updateSystemStatusLed();

  delay(2);
}
