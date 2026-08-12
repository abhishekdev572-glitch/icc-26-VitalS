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
  7. Broadcast the complete VitalSense Protocol v1 JSON over UDP.
  8. Drive active-low GPIO 7 LED when any avoidReturnFlag is active.

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

  Target library:
    NimBLE-Arduino 2.x
*/

#include <Arduino.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <NimBLEDevice.h>

/* ============================================================
   USER CONFIG
   ============================================================ */

static const char* WIFI_SSID     = "YOUR_WIFI_SSID";
static const char* WIFI_PASSWORD = "YOUR_WIFI_PASSWORD";

static const uint16_t UDP_PORT = 5005;

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

static const uint8_t BLE_CMD_REQUEST_FSR = 0x01;
static const uint8_t BLE_CMD_RISK_UPDATE = 0x02;
static const uint8_t BLE_CMD_STATE_UPDATE = 0x03;
static const uint8_t BLE_MSG_FSR_RESPONSE = 0x81;

static const uint8_t STATE_PACKET_LENGTH = 10;

static NimBLEServer* bleServer = nullptr;
static NimBLECharacteristic* bleRx = nullptr;
static NimBLECharacteristic* bleTx = nullptr;

static volatile bool bleConnected = false;
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
static bool wifiWasConnected = false;
static volatile bool udpHasTransmitted = false;

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
   BLE CALLBACKS
   ============================================================ */

class VitalSenseServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* server,
                 NimBLEConnInfo& connInfo) override
  {
    (void)server;
    (void)connInfo;

    bleConnected = true;
    udpHasTransmitted = false;

    Serial.println("[BLE] EFR32 connected");
  }

  void onDisconnect(NimBLEServer* server,
                    NimBLEConnInfo& connInfo,
                    int reason) override
  {
    (void)server;
    (void)connInfo;
    (void)reason;

    bleConnected = false;
    udpHasTransmitted = false;

    Serial.println("[BLE] EFR32 disconnected");

    /*
     * Restart advertising for the next xG26 connection.
     */
    NimBLEDevice::getAdvertising()->start();
  }
};

class VitalSenseRxCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* characteristic,
               NimBLEConnInfo& connInfo) override
  {
    (void)connInfo;

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

  Serial.println("[BLE] VitalSense peripheral ready");
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

  if (bleConnected) {
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
      && bleConnected
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

  WiFi.begin(
      WIFI_SSID,
      WIFI_PASSWORD);

  lastWifiRetryMs =
      millis();
}

static void maintainWiFi()
{
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
    }

    return;
  }

  if (wifiWasConnected) {
    wifiWasConnected = false;
    udpHasTransmitted = false;
    udp.stop();

    Serial.println("[WiFi] disconnected");
  }

  const uint32_t now =
      millis();

  if ((now - lastWifiRetryMs)
      >= WIFI_RETRY_INTERVAL_MS) {

    lastWifiRetryMs =
        now;

    WiFi.disconnect(false, false);

    WiFi.begin(
        WIFI_SSID,
        WIFI_PASSWORD);
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

  /*
   * BLE first: xG26 can connect even when Wi-Fi is unavailable.
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
