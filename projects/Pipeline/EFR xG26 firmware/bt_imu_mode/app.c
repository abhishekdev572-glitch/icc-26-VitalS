/***************************************************************************//**
 * VitalSense EFR32xG26 Firmware
 *
 * Firmware: VITALSENSE_XG26_IMU_BLE_ML_V1
 *
 * xG26 responsibilities
 * ----------------------
 * 1. Calibrate and classify CENTER / LEFT / RIGHT using ICM-40627.
 * 2. Track uninterrupted time in the current posture at ~60 Hz.
 * 3. Operate as BLE central / GATT client for VitalSense-ESP32C3.
 * 4. After the posture-time threshold is crossed, request a fresh 8-FSR
 *    array from the ESP32 once per second.
 * 5. Decode the 18-byte ESP32 response:
 *       [0x81, 0x08, FSR0_L, FSR0_H, ... FSR7_L, FSR7_H]
 * 6. Average the 8 FSR values into:
 *       Head, Shoulders, Hips, Heels.
 * 7. Run the deployed pressure_risk_mlp model using:
 *       posture + uninterrupted duration + four plate ADC averages.
 * 8. Send all four ML risk scores back to the ESP32 as:
 *       [0x02, bodyPartId, risk0to100, avoidReturnFlag]
 *
 * ESP32 protocol
 * --------------
 * BLE device name:
 *   VitalSense-ESP32C3
 *
 * Service:
 *   7a0a0001-5b8a-4f4c-9d1d-8b4e3d7a1000
 *
 * RX characteristic (EFR32 -> ESP32):
 *   7a0a0002-5b8a-4f4c-9d1d-8b4e3d7a1000
 *
 * TX characteristic (ESP32 -> EFR32):
 *   7a0a0003-5b8a-4f4c-9d1d-8b4e3d7a1000
 *
 * Commands:
 *   0x01                         request fresh FSR array
 *   0x02 BODY RISK FLAG         send ML risk update
 *   0x03 POSITION DURATION...   send posture + summary state
 *
 * Response:
 *   0x81 0x08 <8 x uint16 little-endian>
 *
 * Body IDs:
 *   1 Head
 *   2 Shoulders
 *   3 Hips
 *   4 Heels
 *
 * IMPORTANT ABOUT avoidReturnFlag
 * -------------------------------
 * The current ESP32 protocol contains the field, but no command/configuration
 * has been defined that tells the EFR32 which posture is "forbidden".
 * Therefore this first integrated firmware sends avoidReturnFlag = 0.
 * The field is isolated in build_risk_packets() so the forbidden-position
 * state machine can be added later without changing the BLE packet format.
 *
 * Buttons
 * -------
 * BTN0:
 *   During calibration:
 *     CENTER -> LEFT -> RIGHT.
 *   After calibration:
 *     restart calibration.
 *
 * BTN1:
 *   Toggle awake / standby.
 *
 * RGB
 * ---
 * OFF     : standby
 * YELLOW  : calibration required
 * RED     : IMU/ML/BLE error
 * BLUE    : scanning for ESP32
 * PURPLE  : connecting / discovering GATT
 * CYAN    : ESP32 link ready
 * GREEN   : waiting for fresh FSR response
 *
 ******************************************************************************/

#include "sl_common.h"
#include "sl_bluetooth.h"

#include "sl_button.h"
#include "sl_simple_button_instances.h"

#include "sl_led.h"
#include "sl_simple_rgb_pwm_led.h"
#include "sl_simple_rgb_pwm_led_instances.h"

#include "sl_icm40627.h"
#include "sl_sleeptimer.h"

#include "em_gpio.h"

#include "pressure_risk_ml_xg26.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/*******************************************************************************
 ******************************* DEFINITIONS ***********************************
 ******************************************************************************/

#define FIRMWARE_VERSION                    "VITALSENSE_XG26_IMU_BLE_ML_V1"

/* ------------------------------------------------------------------------- */
/* General handles                                                           */
/* ------------------------------------------------------------------------- */

#define INVALID_CONNECTION_HANDLE           0xFFU
#define INVALID_CHARACTERISTIC_HANDLE       0xFFFFU
#define INVALID_SERVICE_HANDLE              0xFFFFFFFFUL

/* ------------------------------------------------------------------------- */
/* Position                                                                  */
/* ------------------------------------------------------------------------- */

#define POSITION_CENTER                     0U
#define POSITION_LEFT                       1U
#define POSITION_RIGHT                      2U

#define CALIBRATION_WAIT_CENTER             0U
#define CALIBRATION_WAIT_LEFT               1U
#define CALIBRATION_WAIT_RIGHT              2U
#define CALIBRATION_COMPLETE                3U

/* ------------------------------------------------------------------------- */
/* IMU                                                                       */
/* ------------------------------------------------------------------------- */

#define IMU_ENABLE_PORT                     gpioPortA
#define IMU_ENABLE_PIN                      10U

#define POSITION_SAMPLE_RATE_HZ             60U
#define ACCEL_SENSOR_RATE_HZ                100.0f

#define CALIBRATION_SAMPLE_COUNT            120U
#define CALIBRATION_SAMPLE_DELAY_MS         10U
#define CALIBRATION_SETTLE_DELAY_MS         400U

#define ACCEL_FILTER_ALPHA                  0.25f
#define POSITION_CONFIRMATION_SAMPLES       4U

#define IMU_RETRY_SAMPLE_COUNT              120U
#define MAX_CONSECUTIVE_READ_FAILURES       5U

/* ------------------------------------------------------------------------- */
/* Risk timing                                                               */
/* ------------------------------------------------------------------------- */

/*
 * DEVELOPMENT VALUE.
 *
 * The model will NOT be called before this uninterrupted posture time.
 * After this threshold, the EFR32 requests a fresh FSR snapshot and predicts
 * once per second while the same posture continues.
 *
 * Change this one value later when the approved application threshold is
 * decided.
 */
#define RISK_PREDICTION_THRESHOLD_SECONDS   60U

#define RISK_PREDICTION_THRESHOLD_SAMPLES   \
  (RISK_PREDICTION_THRESHOLD_SECONDS * POSITION_SAMPLE_RATE_HZ)

#define RISK_PREDICTION_INTERVAL_SECONDS    1U

#define RISK_PREDICTION_INTERVAL_SAMPLES    \
  (RISK_PREDICTION_INTERVAL_SECONDS * POSITION_SAMPLE_RATE_HZ)

/* ------------------------------------------------------------------------- */
/* ESP32 packet protocol                                                     */
/* ------------------------------------------------------------------------- */

#define FSR_SENSOR_COUNT                    8U
#define PLATE_COUNT                         4U

#define BLE_CMD_REQUEST_FSR                 0x01U
#define BLE_CMD_RISK_UPDATE                 0x02U
#define BLE_CMD_STATE_UPDATE                0x03U
#define BLE_MSG_FSR_RESPONSE                0x81U

#define FSR_RESPONSE_SENSOR_COUNT_BYTE      0x08U
#define FSR_RESPONSE_LENGTH                 18U

#define RISK_PACKET_LENGTH                  4U
#define RISK_PACKET_COUNT                   4U

/*
 * State packet:
 * [0]    0x03
 * [1]    position: 0=CENTER, 1=LEFT, 2=RIGHT
 * [2..5] uninterrupted duration seconds, uint32 little-endian
 * [6]    riskValid: 0/1
 * [7]    highest risk zone: 0=none, 1=Head, 2=Shoulders, 3=Hips, 4=Heels
 * [8]    highest risk score: 0..100
 * [9]    risk level: 0=LOW, 1=MEDIUM, 2=HIGH
 */
#define STATE_PACKET_LENGTH                 10U

#define BODY_ID_HEAD                        1U
#define BODY_ID_SHOULDERS                   2U
#define BODY_ID_HIPS                        3U
#define BODY_ID_HEELS                       4U

/*
 * No forbidden-position configuration exists yet in the supplied protocol.
 */
#define DEFAULT_AVOID_RETURN_FLAG           0U

/* ------------------------------------------------------------------------- */
/* FSR response timeout                                                      */
/* ------------------------------------------------------------------------- */

#define FSR_RESPONSE_TIMEOUT_SECONDS        3U

#define FSR_RESPONSE_TIMEOUT_SAMPLES        \
  (FSR_RESPONSE_TIMEOUT_SECONDS * POSITION_SAMPLE_RATE_HZ)

/* ------------------------------------------------------------------------- */
/* BLE scanner / connection timing                                           */
/* ------------------------------------------------------------------------- */

/*
 * Scan units = 0.625 ms.
 * interval 80 = 50 ms
 * window   40 = 25 ms
 */
#define BLE_SCAN_INTERVAL_UNITS             80U
#define BLE_SCAN_WINDOW_UNITS               40U

/*
 * Connection interval units = 1.25 ms.
 * 24 = 30 ms.
 */
#define BLE_CONNECTION_INTERVAL_UNITS       24U
#define BLE_CONNECTION_LATENCY              0U
#define BLE_SUPERVISION_TIMEOUT_UNITS       400U

#define VITALSENSE_DEVICE_NAME              "VitalSense-ESP32C3"

/* ------------------------------------------------------------------------- */
/* RGB                                                                       */
/* ------------------------------------------------------------------------- */

#define RGB_LOW                             1800U
#define RGB_MEDIUM                          4500U
#define RGB_HIGH                            7000U

/* ------------------------------------------------------------------------- */
/* VitalSense UUIDs                                                          */
/* ------------------------------------------------------------------------- */

/*
 * Silicon Labs GATT-client APIs expect 128-bit UUID byte arrays in
 * little-endian order.
 *
 * Canonical:
 *   Service 7a0a0001-5b8a-4f4c-9d1d-8b4e3d7a1000
 *   RX      7a0a0002-5b8a-4f4c-9d1d-8b4e3d7a1000
 *   TX      7a0a0003-5b8a-4f4c-9d1d-8b4e3d7a1000
 */

static const uint8_t vitalsense_service_uuid[16] = {
  0x00, 0x10, 0x7A, 0x3D,
  0x4E, 0x8B,
  0x1D, 0x9D,
  0x4C, 0x4F,
  0x8A, 0x5B,
  0x01, 0x00, 0x0A, 0x7A
};

static const uint8_t vitalsense_rx_uuid[16] = {
  0x00, 0x10, 0x7A, 0x3D,
  0x4E, 0x8B,
  0x1D, 0x9D,
  0x4C, 0x4F,
  0x8A, 0x5B,
  0x02, 0x00, 0x0A, 0x7A
};

static const uint8_t vitalsense_tx_uuid[16] = {
  0x00, 0x10, 0x7A, 0x3D,
  0x4E, 0x8B,
  0x1D, 0x9D,
  0x4C, 0x4F,
  0x8A, 0x5B,
  0x03, 0x00, 0x0A, 0x7A
};

/*******************************************************************************
 ******************************** ENUMS ****************************************
 ******************************************************************************/

typedef enum {
  ESP_BLE_OFF = 0,
  ESP_BLE_SCANNING,
  ESP_BLE_CONNECTING,
  ESP_BLE_DISCOVERING_SERVICE,
  ESP_BLE_DISCOVERING_RX_CHAR,
  ESP_BLE_DISCOVERING_TX_CHAR,
  ESP_BLE_ENABLING_TX_NOTIFY,
  ESP_BLE_READY,
  ESP_BLE_ERROR
} esp_ble_state_t;

typedef enum {
  GATT_RUNTIME_NONE = 0,
  GATT_RUNTIME_FSR_REQUEST_WRITE,
  GATT_RUNTIME_RISK_WRITE,
  GATT_RUNTIME_STATE_WRITE
} gatt_runtime_op_t;

/*******************************************************************************
 *************************** LOCAL VARIABLES ***********************************
 ******************************************************************************/

/* ------------------------------------------------------------------------- */
/* Application / hardware                                                    */
/* ------------------------------------------------------------------------- */

static bool device_awake = true;
static bool imu_ready = false;
static bool ml_ready = false;
static bool sample_timer_started = false;

static volatile bool btn0_press_pending = false;
static volatile bool btn1_press_pending = false;

static volatile uint32_t sample_tick_count = 0U;
static uint32_t last_processed_tick = 0U;
static uint32_t missed_application_ticks = 0U;

static sl_sleeptimer_timer_handle_t sample_timer;
static uint32_t sample_timer_ticks = 0U;

/* ------------------------------------------------------------------------- */
/* IMU                                                                       */
/* ------------------------------------------------------------------------- */

static float raw_accel_g[3] = { 0.0f, 0.0f, 0.0f };
static float filtered_accel_g[3] = { 0.0f, 0.0f, 0.0f };
static bool filter_initialized = false;

static float center_reference_g[3] = { 0.0f, 0.0f, 0.0f };
static float left_reference_g[3] = { 0.0f, 0.0f, 0.0f };
static float right_reference_g[3] = { 0.0f, 0.0f, 0.0f };

static uint8_t calibration_stage = CALIBRATION_WAIT_CENTER;

static uint8_t current_position = POSITION_CENTER;
static uint8_t pending_position = POSITION_CENTER;
static uint8_t pending_position_count = 0U;

static uint32_t position_hold_samples = 0U;

static uint32_t imu_retry_counter = 0U;
static uint32_t accel_read_failure_count = 0U;

static float distance_center_g2 = 0.0f;
static float distance_left_g2 = 0.0f;
static float distance_right_g2 = 0.0f;

/* ------------------------------------------------------------------------- */
/* Prediction schedule                                                       */
/* ------------------------------------------------------------------------- */

static uint32_t next_fsr_request_sample =
    RISK_PREDICTION_THRESHOLD_SAMPLES;

static bool fsr_request_due = false;
static bool fsr_response_pending = false;
static uint32_t fsr_response_wait_samples = 0U;

static uint8_t fsr_request_position = POSITION_CENTER;

/* ------------------------------------------------------------------------- */
/* BLE                                                                       */
/* ------------------------------------------------------------------------- */

static esp_ble_state_t esp_ble_state = ESP_BLE_OFF;
static bool scanner_active = false;

static uint8_t esp_connection_handle = INVALID_CONNECTION_HANDLE;
static uint32_t vitalsense_service_handle = INVALID_SERVICE_HANDLE;
static uint16_t vitalsense_rx_characteristic =
    INVALID_CHARACTERISTIC_HANDLE;
static uint16_t vitalsense_tx_characteristic =
    INVALID_CHARACTERISTIC_HANDLE;

static gatt_runtime_op_t gatt_runtime_op = GATT_RUNTIME_NONE;

/* ------------------------------------------------------------------------- */
/* Latest FSR data                                                           */
/* ------------------------------------------------------------------------- */

static uint16_t latest_fsr[FSR_SENSOR_COUNT] = { 0U };
static uint16_t latest_plate_adc[PLATE_COUNT] = { 0U };

/* ------------------------------------------------------------------------- */
/* Risk TX sequence                                                          */
/* ------------------------------------------------------------------------- */

/*
 * The ESP32 RX characteristic has PROPERTY_WRITE, so writes are performed
 * with response. Only one GATT procedure can be active at a time.
 *
 * Four risk packets are therefore sent sequentially.
 */
static uint8_t risk_tx_packets[RISK_PACKET_COUNT][RISK_PACKET_LENGTH];
static uint8_t risk_tx_index = 0U;
static bool risk_tx_sequence_pending = false;

/*
 * Current posture / ML summary sent to the ESP32 as command 0x03.
 * risk_valid is cleared immediately on a confirmed posture change and is
 * set again only after a new ML prediction for that posture.
 */
static bool status_tx_due = true;
static bool latest_risk_valid = false;
static uint8_t latest_highest_zone_id = 0U;
static uint8_t latest_highest_score = 0U;
static uint8_t latest_risk_level_id = 0U;

static uint8_t state_tx_packet[STATE_PACKET_LENGTH];

/*******************************************************************************
 ************************ LOCAL FUNCTION PROTOTYPES *****************************
 ******************************************************************************/

/* RGB */
static void set_status_rgb(uint16_t red, uint16_t green, uint16_t blue);
static void update_status_rgb(void);

/* Helpers */
static int32_t g_to_mg(float value_g);
static const char *position_to_string(uint8_t position);
static pressure_position_t position_to_ml_position(uint8_t position);

static float squared_distance_3d(const float value_g[3],
                                 const float reference_g[3]);

static uint8_t risk_score_to_u8(float score);
static uint32_t risk_score_to_hundredths(float score);

/* IMU / power */
static void initialize_imu(void);
static void power_down_imu(void);
static void initialize_ml(void);

static void wake_device(void);
static void enter_standby(const char *reason);

/* Timer */
static void start_sample_timer(void);
static void stop_sample_timer(void);
static void sample_timer_callback(sl_sleeptimer_timer_handle_t *handle,
                                  void *data);

/* Calibration */
static bool capture_position_reference(float reference_g[3],
                                       const char *position_name);
static void capture_next_calibration_reference(void);
static void restart_calibration(void);

/* Buttons */
static void handle_btn0_press(void);
static void handle_btn1_press(void);

/* Position */
static void update_filter(const float input_g[3]);
static uint8_t detect_nearest_position(const float sample_g[3]);
static uint8_t confirm_position(uint8_t detected_position);
static void reset_position_risk_schedule(void);
static void process_accel_sample(void);

/* BLE advertisement / connection */
static bool advertisement_contains_service(const uint8_t *data,
                                           uint8_t data_len);
static bool advertisement_contains_device_name(const uint8_t *data,
                                               uint8_t data_len);

static void reset_esp_ble_handles(void);
static void reset_runtime_ble_operations(void);

static void start_esp32_scan(void);
static void stop_esp32_scan(void);
static void close_esp32_connection(void);
static void restart_esp32_discovery(void);

/* GATT */
static void handle_gatt_procedure_completed(sl_status_t result);

static void send_fsr_request_if_due(void);
static void handle_fsr_notification(const uint8_t *data, size_t length);

static void build_risk_packets(const pressure_risk_result_t *result);
static void send_next_risk_update(void);

static void build_state_packet(void);
static void send_state_update_if_due(void);

static void run_model_with_latest_plates(void);

/*******************************************************************************
 ******************************* RGB STATUS ************************************
 ******************************************************************************/

static void set_status_rgb(uint16_t red, uint16_t green, uint16_t blue)
{
  void *context =
      (void *)sl_simple_rgb_pwm_led_status_rgb.led_common.context;

  if ((red == 0U) && (green == 0U) && (blue == 0U)) {
    sl_simple_rgb_pwm_led_turn_off(context);
    return;
  }

  sl_simple_rgb_pwm_led_set_color(context, red, green, blue);
  sl_simple_rgb_pwm_led_turn_on(context);
}

static void update_status_rgb(void)
{
  if (!device_awake) {
    set_status_rgb(0U, 0U, 0U);
    return;
  }

  if (!imu_ready || !ml_ready) {
    set_status_rgb(RGB_HIGH, 0U, 0U);
    return;
  }

  if (calibration_stage != CALIBRATION_COMPLETE) {
    set_status_rgb(RGB_MEDIUM, RGB_LOW, 0U);
    return;
  }

  if (fsr_response_pending) {
    set_status_rgb(0U, RGB_HIGH, 0U);
    return;
  }

  switch (esp_ble_state) {
    case ESP_BLE_SCANNING:
      set_status_rgb(0U, 0U, RGB_MEDIUM);
      break;

    case ESP_BLE_CONNECTING:
    case ESP_BLE_DISCOVERING_SERVICE:
    case ESP_BLE_DISCOVERING_RX_CHAR:
    case ESP_BLE_DISCOVERING_TX_CHAR:
    case ESP_BLE_ENABLING_TX_NOTIFY:
      set_status_rgb(RGB_LOW, 0U, RGB_MEDIUM);
      break;

    case ESP_BLE_READY:
      set_status_rgb(0U, RGB_MEDIUM, RGB_MEDIUM);
      break;

    case ESP_BLE_ERROR:
      set_status_rgb(RGB_HIGH, 0U, 0U);
      break;

    case ESP_BLE_OFF:
    default:
      set_status_rgb(0U, 0U, RGB_LOW);
      break;
  }
}

/*******************************************************************************
 ******************************** HELPERS **************************************
 ******************************************************************************/

static int32_t g_to_mg(float value_g)
{
  if (value_g >= 0.0f) {
    return (int32_t)((value_g * 1000.0f) + 0.5f);
  }

  return (int32_t)((value_g * 1000.0f) - 0.5f);
}

static const char *position_to_string(uint8_t position)
{
  switch (position) {
    case POSITION_LEFT:
      return "LEFT";

    case POSITION_RIGHT:
      return "RIGHT";

    case POSITION_CENTER:
    default:
      return "CENTER";
  }
}

static pressure_position_t position_to_ml_position(uint8_t position)
{
  switch (position) {
    case POSITION_LEFT:
      return PRESSURE_POSITION_LEFT;

    case POSITION_RIGHT:
      return PRESSURE_POSITION_RIGHT;

    case POSITION_CENTER:
    default:
      return PRESSURE_POSITION_CENTER;
  }
}

static float squared_distance_3d(const float value_g[3],
                                 const float reference_g[3])
{
  float dx = value_g[0] - reference_g[0];
  float dy = value_g[1] - reference_g[1];
  float dz = value_g[2] - reference_g[2];

  return (dx * dx) + (dy * dy) + (dz * dz);
}

static uint8_t risk_score_to_u8(float score)
{
  if (score <= 0.0f) {
    return 0U;
  }

  if (score >= 100.0f) {
    return 100U;
  }

  return (uint8_t)(score + 0.5f);
}

static uint32_t risk_score_to_hundredths(float score)
{
  if (score <= 0.0f) {
    return 0U;
  }

  if (score >= 100.0f) {
    return 10000U;
  }

  return (uint32_t)((score * 100.0f) + 0.5f);
}

static void put_u32_le(uint8_t *dst, uint32_t value)
{
  dst[0] = (uint8_t)(value & 0xFFU);
  dst[1] = (uint8_t)((value >> 8U) & 0xFFU);
  dst[2] = (uint8_t)((value >> 16U) & 0xFFU);
  dst[3] = (uint8_t)((value >> 24U) & 0xFFU);
}

/*******************************************************************************
 **************************** IMU AND ML INIT **********************************
 ******************************************************************************/

static void initialize_imu(void)
{
  sl_status_t status;
  uint8_t device_id = 0U;
  float actual_sample_rate;

  imu_ready = false;
  accel_read_failure_count = 0U;

  GPIO_PinModeSet(IMU_ENABLE_PORT,
                  IMU_ENABLE_PIN,
                  gpioModePushPull,
                  1);

  sl_sleeptimer_delay_millisecond(200U);

  status = sl_icm40627_init();

  if (status != SL_STATUS_OK) {
    printf("[IMU] Initialization failed: 0x%08lx\r\n",
           (unsigned long)status);
    update_status_rgb();
    return;
  }

  status = sl_icm40627_get_device_id(&device_id);

  if (status != SL_STATUS_OK) {
    printf("[IMU] Device ID read failed: 0x%08lx\r\n",
           (unsigned long)status);
    update_status_rgb();
    return;
  }

  status = sl_icm40627_enable_sensor(true, false, false);

  if (status != SL_STATUS_OK) {
    printf("[IMU] Accelerometer enable failed: 0x%08lx\r\n",
           (unsigned long)status);
    update_status_rgb();
    return;
  }

  actual_sample_rate =
      sl_icm40627_set_sample_rate(ACCEL_SENSOR_RATE_HZ);

  sl_sleeptimer_delay_millisecond(300U);

  status = sl_icm40627_accel_read_data(raw_accel_g);

  if (status != SL_STATUS_OK) {
    printf("[IMU] First read failed: 0x%08lx\r\n",
           (unsigned long)status);
    update_status_rgb();
    return;
  }

  imu_ready = true;
  imu_retry_counter = 0U;
  filter_initialized = false;

  printf("[IMU] Ready. ID=0x%02X actual_rate=%ld Hz\r\n",
         device_id,
         (long)actual_sample_rate);

  printf("[IMU] Initial mg: X=%ld Y=%ld Z=%ld\r\n",
         (long)g_to_mg(raw_accel_g[0]),
         (long)g_to_mg(raw_accel_g[1]),
         (long)g_to_mg(raw_accel_g[2]));

  update_status_rgb();
}

static void power_down_imu(void)
{
  if (imu_ready) {
    (void)sl_icm40627_enable_sensor(false, false, false);
  }

  imu_ready = false;
  filter_initialized = false;

  GPIO_PinModeSet(IMU_ENABLE_PORT,
                  IMU_ENABLE_PIN,
                  gpioModePushPull,
                  0);
}

static void initialize_ml(void)
{
  sl_status_t status;

  ml_ready = false;

  printf("[ML] Initializing pressure_risk_mlp...\r\n");

  status = pressure_risk_ml_init();

  if (status != SL_STATUS_OK) {
    printf("[ML] Initialization failed: 0x%08lx\r\n",
           (unsigned long)status);
    update_status_rgb();
    return;
  }

  ml_ready = true;

  printf("[ML] Model ready\r\n");
  printf("[ML] Prediction gate = %u s uninterrupted posture\r\n",
         (unsigned int)RISK_PREDICTION_THRESHOLD_SECONDS);
  printf("[ML] After gate: fresh FSR + inference every %u s\r\n",
         (unsigned int)RISK_PREDICTION_INTERVAL_SECONDS);

  update_status_rgb();
}

/*******************************************************************************
 ******************************* POWER *****************************************
 ******************************************************************************/

static void wake_device(void)
{
  if (device_awake) {
    return;
  }

  device_awake = true;

  printf("\r\n[POWER] AWAKE\r\n");

  initialize_imu();
  start_sample_timer();

  if (calibration_stage == CALIBRATION_COMPLETE) {
    start_esp32_scan();
  } else {
    printf("[CAL] Press BTN0 to capture the requested posture\r\n");
  }

  update_status_rgb();
}

static void enter_standby(const char *reason)
{
  if (!device_awake) {
    return;
  }

  printf("\r\n[POWER] STANDBY: %s\r\n", reason);

  stop_esp32_scan();
  close_esp32_connection();

  stop_sample_timer();
  power_down_imu();

  device_awake = false;
  esp_ble_state = ESP_BLE_OFF;

  fsr_request_due = false;
  fsr_response_pending = false;
  fsr_response_wait_samples = 0U;

  reset_runtime_ble_operations();

  update_status_rgb();

  printf("[POWER] IMU, sample timer, BLE scan/connection and RGB are OFF\r\n");
  printf("[POWER] Press BTN1 to wake\r\n");
}

/*******************************************************************************
 ***************************** SAMPLE TIMER ************************************
 ******************************************************************************/

static void start_sample_timer(void)
{
  sl_status_t status;
  uint32_t timer_frequency;

  if (sample_timer_started) {
    return;
  }

  timer_frequency = sl_sleeptimer_get_timer_frequency();

  sample_timer_ticks =
      (timer_frequency + (POSITION_SAMPLE_RATE_HZ / 2U))
      / POSITION_SAMPLE_RATE_HZ;

  if (sample_timer_ticks == 0U) {
    sample_timer_ticks = 1U;
  }

  sample_tick_count = 0U;
  last_processed_tick = 0U;

  status = sl_sleeptimer_start_periodic_timer(
      &sample_timer,
      sample_timer_ticks,
      sample_timer_callback,
      NULL,
      0U,
      0U);

  if (status == SL_STATUS_OK) {
    sample_timer_started = true;

    printf("[TIMER] Position sampling started at approximately %u Hz\r\n",
           (unsigned int)POSITION_SAMPLE_RATE_HZ);
  } else {
    printf("[TIMER] Start failed: 0x%08lx\r\n",
           (unsigned long)status);
  }
}

static void stop_sample_timer(void)
{
  sl_status_t status;

  if (!sample_timer_started) {
    return;
  }

  status = sl_sleeptimer_stop_timer(&sample_timer);

  if (status != SL_STATUS_OK) {
    printf("[TIMER] Stop returned: 0x%08lx\r\n",
           (unsigned long)status);
  }

  sample_timer_started = false;
  last_processed_tick = sample_tick_count;
}

static void sample_timer_callback(sl_sleeptimer_timer_handle_t *handle,
                                  void *data)
{
  (void)handle;
  (void)data;

  sample_tick_count++;
}

/*******************************************************************************
 ***************************** CALIBRATION *************************************
 ******************************************************************************/

static bool capture_position_reference(float reference_g[3],
                                       const char *position_name)
{
  sl_status_t status;
  float sample_g[3];
  float sum_x = 0.0f;
  float sum_y = 0.0f;
  float sum_z = 0.0f;
  uint32_t sample_number;

  if (!device_awake || !imu_ready) {
    printf("[CAL] Cannot calibrate: IMU is not ready\r\n");
    return false;
  }

  printf("\r\n[CAL] Capturing %s. Keep still.\r\n", position_name);

  set_status_rgb(RGB_LOW, RGB_LOW, RGB_LOW);

  sl_sleeptimer_delay_millisecond(
      CALIBRATION_SETTLE_DELAY_MS);

  for (sample_number = 0U;
       sample_number < CALIBRATION_SAMPLE_COUNT;
       sample_number++) {

    status = sl_icm40627_accel_read_data(sample_g);

    if (status != SL_STATUS_OK) {
      printf("[CAL] Read failed: 0x%08lx\r\n",
             (unsigned long)status);
      update_status_rgb();
      return false;
    }

    sum_x += sample_g[0];
    sum_y += sample_g[1];
    sum_z += sample_g[2];

    sl_sleeptimer_delay_millisecond(
        CALIBRATION_SAMPLE_DELAY_MS);
  }

  reference_g[0] =
      sum_x / (float)CALIBRATION_SAMPLE_COUNT;

  reference_g[1] =
      sum_y / (float)CALIBRATION_SAMPLE_COUNT;

  reference_g[2] =
      sum_z / (float)CALIBRATION_SAMPLE_COUNT;

  printf("[CAL] %s reference mg: X=%ld Y=%ld Z=%ld\r\n",
         position_name,
         (long)g_to_mg(reference_g[0]),
         (long)g_to_mg(reference_g[1]),
         (long)g_to_mg(reference_g[2]));

  return true;
}

static void reset_position_risk_schedule(void)
{
  position_hold_samples = 0U;

  next_fsr_request_sample =
      RISK_PREDICTION_THRESHOLD_SAMPLES;

  fsr_request_due = false;
  fsr_response_pending = false;
  fsr_response_wait_samples = 0U;

  risk_tx_sequence_pending = false;
  risk_tx_index = 0U;

  /*
   * Risk from the previous posture must never be presented as current.
   */
  latest_risk_valid = false;
  latest_highest_zone_id = 0U;
  latest_highest_score = 0U;
  latest_risk_level_id = 0U;

  /*
   * Push the new posture / zero-duration state to the ESP32 as soon as the
   * GATT client is free.
   */
  status_tx_due = true;
}

static void restart_calibration(void)
{
  if (!device_awake) {
    wake_device();
  }

  stop_esp32_scan();
  close_esp32_connection();

  calibration_stage = CALIBRATION_WAIT_CENTER;

  current_position = POSITION_CENTER;
  pending_position = POSITION_CENTER;
  pending_position_count = 0U;

  reset_position_risk_schedule();

  filter_initialized = false;

  printf("\r\n[CAL] RESTARTED: hold CENTER and press BTN0\r\n");

  update_status_rgb();
}

static void capture_next_calibration_reference(void)
{
  bool success = false;

  switch (calibration_stage) {
    case CALIBRATION_WAIT_CENTER:
      success =
          capture_position_reference(
              center_reference_g,
              "CENTER");

      if (success) {
        calibration_stage = CALIBRATION_WAIT_LEFT;

        printf("[CAL] CENTER saved. Hold LEFT and press BTN0\r\n");
      }
      break;

    case CALIBRATION_WAIT_LEFT:
      success =
          capture_position_reference(
              left_reference_g,
              "LEFT");

      if (success) {
        calibration_stage = CALIBRATION_WAIT_RIGHT;

        printf("[CAL] LEFT saved. Hold RIGHT and press BTN0\r\n");
      }
      break;

    case CALIBRATION_WAIT_RIGHT:
      success =
          capture_position_reference(
              right_reference_g,
              "RIGHT");

      if (success) {
        calibration_stage = CALIBRATION_COMPLETE;

        current_position = POSITION_CENTER;
        pending_position = POSITION_CENTER;
        pending_position_count = 0U;

        reset_position_risk_schedule();

        filter_initialized = false;

        printf("\r\n[CAL] COMPLETE\r\n");
        printf("[BLE] Starting scan for %s\r\n",
               VITALSENSE_DEVICE_NAME);

        start_esp32_scan();
      }
      break;

    case CALIBRATION_COMPLETE:
    default:
      restart_calibration();
      return;
  }

  update_status_rgb();
}

/*******************************************************************************
 *************************** BUTTON ACTIONS ************************************
 ******************************************************************************/

static void handle_btn0_press(void)
{
  if (!device_awake) {
    printf("[BUTTON] BTN0 ignored in standby; press BTN1 to wake\r\n");
    return;
  }

  if (calibration_stage == CALIBRATION_COMPLETE) {
    restart_calibration();
    return;
  }

  capture_next_calibration_reference();
}

static void handle_btn1_press(void)
{
  if (device_awake) {
    enter_standby("BTN1");
  } else {
    wake_device();
  }
}

/*******************************************************************************
 *************************** POSITION DETECTION ********************************
 ******************************************************************************/

static void update_filter(const float input_g[3])
{
  if (!filter_initialized) {
    filtered_accel_g[0] = input_g[0];
    filtered_accel_g[1] = input_g[1];
    filtered_accel_g[2] = input_g[2];

    filter_initialized = true;
    return;
  }

  filtered_accel_g[0] =
      (ACCEL_FILTER_ALPHA * input_g[0])
      + ((1.0f - ACCEL_FILTER_ALPHA)
         * filtered_accel_g[0]);

  filtered_accel_g[1] =
      (ACCEL_FILTER_ALPHA * input_g[1])
      + ((1.0f - ACCEL_FILTER_ALPHA)
         * filtered_accel_g[1]);

  filtered_accel_g[2] =
      (ACCEL_FILTER_ALPHA * input_g[2])
      + ((1.0f - ACCEL_FILTER_ALPHA)
         * filtered_accel_g[2]);
}

static uint8_t detect_nearest_position(
    const float sample_g[3])
{
  distance_center_g2 =
      squared_distance_3d(
          sample_g,
          center_reference_g);

  distance_left_g2 =
      squared_distance_3d(
          sample_g,
          left_reference_g);

  distance_right_g2 =
      squared_distance_3d(
          sample_g,
          right_reference_g);

  if ((distance_center_g2 <= distance_left_g2)
      && (distance_center_g2 <= distance_right_g2)) {

    return POSITION_CENTER;
  }

  if (distance_left_g2 <= distance_right_g2) {
    return POSITION_LEFT;
  }

  return POSITION_RIGHT;
}

static uint8_t confirm_position(
    uint8_t detected_position)
{
  if (detected_position != pending_position) {
    pending_position = detected_position;
    pending_position_count = 1U;

  } else if (pending_position_count
             < POSITION_CONFIRMATION_SAMPLES) {

    pending_position_count++;
  }

  if (pending_position_count
      >= POSITION_CONFIRMATION_SAMPLES) {

    return pending_position;
  }

  return current_position;
}

static void process_accel_sample(void)
{
  sl_status_t status;
  uint8_t detected_position;
  uint8_t confirmed_position;

  if (!device_awake) {
    return;
  }

  if (!imu_ready) {
    imu_retry_counter++;

    if (imu_retry_counter
        >= IMU_RETRY_SAMPLE_COUNT) {

      imu_retry_counter = 0U;

      printf("[IMU] Retrying initialization\r\n");

      initialize_imu();
    }

    return;
  }

  status =
      sl_icm40627_accel_read_data(
          raw_accel_g);

  if (status != SL_STATUS_OK) {
    accel_read_failure_count++;

    if ((accel_read_failure_count % 10U) == 1U) {
      printf("[IMU] Read failed: 0x%08lx count=%lu\r\n",
             (unsigned long)status,
             (unsigned long)accel_read_failure_count);
    }

    if (accel_read_failure_count
        >= MAX_CONSECUTIVE_READ_FAILURES) {

      imu_ready = false;
      imu_retry_counter = 0U;
      accel_read_failure_count = 0U;

      update_status_rgb();
    }

    return;
  }

  accel_read_failure_count = 0U;

  update_filter(raw_accel_g);

  if (calibration_stage
      != CALIBRATION_COMPLETE) {

    return;
  }

  detected_position =
      detect_nearest_position(
          filtered_accel_g);

  confirmed_position =
      confirm_position(
          detected_position);

  if (confirmed_position != current_position) {
    uint8_t old_position =
        current_position;

    uint32_t old_hold_samples =
        position_hold_samples;

    current_position =
        confirmed_position;

    reset_position_risk_schedule();

    /*
     * If a GATT write was already in flight it cannot be cancelled,
     * but the pending FSR response is invalidated and no new inference
     * is accepted until the new posture crosses the threshold again.
     */
    printf("[POSITION] %s -> %s | previous=%lu ms\r\n",
           position_to_string(old_position),
           position_to_string(current_position),
           (unsigned long)(
               (old_hold_samples * 1000UL)
               / POSITION_SAMPLE_RATE_HZ));

    update_status_rgb();

  } else {
    if (position_hold_samples < UINT32_MAX) {
      position_hold_samples++;
    }
  }

  /*
   * Prediction scheduler.
   *
   * Before threshold:
   *   no FSR request and no ML inference.
   *
   * At threshold and every one second afterwards:
   *   mark a fresh FSR request as due.
   */
  if (!fsr_response_pending
      && !risk_tx_sequence_pending
      && (position_hold_samples
          >= next_fsr_request_sample)) {

    fsr_request_due = true;
  }

  /*
   * Timeout applies only after a request was successfully started.
   */
  if (fsr_response_pending) {
    fsr_response_wait_samples++;

    if (fsr_response_wait_samples
        >= FSR_RESPONSE_TIMEOUT_SAMPLES) {

      fsr_response_pending = false;
      fsr_response_wait_samples = 0U;

      /*
       * Retry the current fresh-data request.
       */
      fsr_request_due = true;

      printf("[FSR] Response timeout after %u seconds; retry scheduled\r\n",
             (unsigned int)FSR_RESPONSE_TIMEOUT_SECONDS);

      update_status_rgb();
    }
  }

  /*
   * Publish current posture + uninterrupted duration once per second.
   * This runs even before ML inference starts so the app/dashboard always
   * knows CENTER / LEFT / RIGHT and the live position duration.
   */
  if ((position_hold_samples > 0U)
      && ((position_hold_samples
           % POSITION_SAMPLE_RATE_HZ) == 0U)) {

    status_tx_due = true;
  }

  /*
   * Once each second, print the posture-duration gate status before risk
   * prediction starts. This keeps VCOM useful without 60-Hz print traffic.
   */
  if ((position_hold_samples > 0U)
      && ((position_hold_samples
           % POSITION_SAMPLE_RATE_HZ) == 0U)
      && (position_hold_samples
          < RISK_PREDICTION_THRESHOLD_SAMPLES)) {

    printf("RISK_WAIT,%s,%lu,%u\r\n",
           position_to_string(current_position),
           (unsigned long)(
               position_hold_samples
               / POSITION_SAMPLE_RATE_HZ),
           (unsigned int)
               RISK_PREDICTION_THRESHOLD_SECONDS);
  }
}

/*******************************************************************************
 *************************** ADVERTISEMENT PARSING ******************************
 ******************************************************************************/

static bool advertisement_contains_service(
    const uint8_t *data,
    uint8_t data_len)
{
  uint8_t index = 0U;

  while (index < data_len) {
    uint8_t field_length =
        data[index];

    if (field_length == 0U) {
      break;
    }

    /*
     * field_length excludes the length byte itself,
     * but includes the AD type byte.
     */
    if (((uint16_t)index
         + (uint16_t)field_length)
        >= data_len) {

      break;
    }

    if (field_length >= 17U) {
      uint8_t ad_type =
          data[index + 1U];

      /*
       * 0x06 incomplete 128-bit UUID list
       * 0x07 complete   128-bit UUID list
       */
      if ((ad_type == 0x06U)
          || (ad_type == 0x07U)) {

        uint8_t payload_length =
            field_length - 1U;

        uint8_t offset = 0U;

        const uint8_t *payload =
            &data[index + 2U];

        while (((uint16_t)offset + 16U)
               <= payload_length) {

          if (memcmp(
                  &payload[offset],
                  vitalsense_service_uuid,
                  16U) == 0) {

            return true;
          }

          offset =
              (uint8_t)(offset + 16U);
        }
      }
    }

    index =
        (uint8_t)(
            index
            + field_length
            + 1U);
  }

  return false;
}

static bool advertisement_contains_device_name(
    const uint8_t *data,
    uint8_t data_len)
{
  uint8_t index = 0U;

  const size_t expected_length =
      strlen(VITALSENSE_DEVICE_NAME);

  while (index < data_len) {
    uint8_t field_length =
        data[index];

    if (field_length == 0U) {
      break;
    }

    if (((uint16_t)index
         + (uint16_t)field_length)
        >= data_len) {

      break;
    }

    /*
     * 0x09 = Complete Local Name
     */
    if ((field_length >= 2U)
        && (data[index + 1U] == 0x09U)) {

      size_t name_length =
          (size_t)field_length - 1U;

      if ((name_length == expected_length)
          && (memcmp(
                  &data[index + 2U],
                  VITALSENSE_DEVICE_NAME,
                  expected_length) == 0)) {

        return true;
      }
    }

    index =
        (uint8_t)(
            index
            + field_length
            + 1U);
  }

  return false;
}

/*******************************************************************************
 **************************** BLE CLIENT CORE **********************************
 ******************************************************************************/

static void reset_esp_ble_handles(void)
{
  vitalsense_service_handle =
      INVALID_SERVICE_HANDLE;

  vitalsense_rx_characteristic =
      INVALID_CHARACTERISTIC_HANDLE;

  vitalsense_tx_characteristic =
      INVALID_CHARACTERISTIC_HANDLE;
}

static void reset_runtime_ble_operations(void)
{
  gatt_runtime_op = GATT_RUNTIME_NONE;

  risk_tx_sequence_pending = false;
  risk_tx_index = 0U;
}

static void start_esp32_scan(void)
{
  sl_status_t status;

  if (!device_awake
      || (calibration_stage
          != CALIBRATION_COMPLETE)
      || scanner_active
      || (esp_connection_handle
          != INVALID_CONNECTION_HANDLE)) {

    return;
  }

  reset_esp_ble_handles();
  reset_runtime_ble_operations();

  /*
   * Active scan is used because the ESP32 sketch enables scan response.
   * This allows us to match either the service UUID or the complete name.
   */
  status =
      sl_bt_scanner_set_parameters(
          sl_bt_scanner_scan_mode_active,
          BLE_SCAN_INTERVAL_UNITS,
          BLE_SCAN_WINDOW_UNITS);

  if (status != SL_STATUS_OK) {
    printf("[BLE] Scanner parameter error: 0x%08lx\r\n",
           (unsigned long)status);

    esp_ble_state = ESP_BLE_ERROR;

    update_status_rgb();

    return;
  }

  status =
      sl_bt_scanner_start(
          sl_bt_scanner_scan_phy_1m,
          sl_bt_scanner_discover_generic);

  if (status == SL_STATUS_OK) {
    scanner_active = true;
    esp_ble_state = ESP_BLE_SCANNING;

    printf("[BLE] Scanning for %s\r\n",
           VITALSENSE_DEVICE_NAME);

  } else {
    printf("[BLE] Scan start failed: 0x%08lx\r\n",
           (unsigned long)status);

    esp_ble_state = ESP_BLE_ERROR;
  }

  update_status_rgb();
}

static void stop_esp32_scan(void)
{
  sl_status_t status;

  if (!scanner_active) {
    return;
  }

  status =
      sl_bt_scanner_stop();

  if ((status != SL_STATUS_OK)
      && (status != SL_STATUS_INVALID_STATE)) {

    printf("[BLE] Scanner stop returned: 0x%08lx\r\n",
           (unsigned long)status);
  }

  scanner_active = false;
}

static void close_esp32_connection(void)
{
  if (esp_connection_handle
      != INVALID_CONNECTION_HANDLE) {

    (void)sl_bt_connection_close(
        esp_connection_handle);
  }
}

static void restart_esp32_discovery(void)
{
  scanner_active = false;

  esp_connection_handle =
      INVALID_CONNECTION_HANDLE;

  reset_esp_ble_handles();
  reset_runtime_ble_operations();

  status_tx_due = true;

  fsr_response_pending = false;
  fsr_response_wait_samples = 0U;

  /*
   * Preserve fsr_request_due. If the posture is already beyond the
   * threshold, the request will be sent after reconnection.
   */
  if (position_hold_samples
      >= RISK_PREDICTION_THRESHOLD_SAMPLES) {

    fsr_request_due = true;
  }

  if (device_awake
      && (calibration_stage
          == CALIBRATION_COMPLETE)) {

    start_esp32_scan();

  } else {
    esp_ble_state = ESP_BLE_OFF;

    update_status_rgb();
  }
}

/*******************************************************************************
 ******************************* RISK TX ***************************************
 ******************************************************************************/

static void build_risk_packets(
    const pressure_risk_result_t *result)
{
  uint8_t scores[PLATE_COUNT];

  scores[0] =
      risk_score_to_u8(
          result->head_risk);

  scores[1] =
      risk_score_to_u8(
          result->shoulders_risk);

  scores[2] =
      risk_score_to_u8(
          result->hips_risk);

  scores[3] =
      risk_score_to_u8(
          result->heels_risk);

  for (uint8_t i = 0U;
       i < RISK_PACKET_COUNT;
       i++) {

    risk_tx_packets[i][0] =
        BLE_CMD_RISK_UPDATE;

    /*
     * Protocol body IDs are 1..4 in the same order:
     * Head, Shoulders, Hips, Heels.
     */
    risk_tx_packets[i][1] =
        (uint8_t)(i + 1U);

    risk_tx_packets[i][2] =
        scores[i];

    /*
     * TODO:
     * Replace this with the forbidden-position state machine after a
     * requirement exists for how the EFR32 learns which posture is forbidden.
     */
    risk_tx_packets[i][3] =
        DEFAULT_AVOID_RETURN_FLAG;
  }

  risk_tx_index = 0U;
  risk_tx_sequence_pending = true;
}

static void send_next_risk_update(void)
{
  sl_status_t status;

  if (!risk_tx_sequence_pending
      || (risk_tx_index
          >= RISK_PACKET_COUNT)
      || (gatt_runtime_op
          != GATT_RUNTIME_NONE)
      || (esp_ble_state
          != ESP_BLE_READY)
      || (esp_connection_handle
          == INVALID_CONNECTION_HANDLE)
      || (vitalsense_rx_characteristic
          == INVALID_CHARACTERISTIC_HANDLE)) {

    return;
  }

  status =
      sl_bt_gatt_write_characteristic_value(
          esp_connection_handle,
          vitalsense_rx_characteristic,
          RISK_PACKET_LENGTH,
          risk_tx_packets[risk_tx_index]);

  if (status == SL_STATUS_OK) {
    gatt_runtime_op =
        GATT_RUNTIME_RISK_WRITE;

  } else {
    printf("[BLE] Risk write start failed: 0x%08lx body=%u\r\n",
           (unsigned long)status,
           (unsigned int)(
               risk_tx_index + 1U));

    /*
     * Connection-level recovery is safer than silently dropping
     * a partial four-body update.
     */
    risk_tx_sequence_pending = false;
    gatt_runtime_op = GATT_RUNTIME_NONE;

    close_esp32_connection();
  }
}

/*******************************************************************************
 ***************************** STATE TX ***************************************
 ******************************************************************************/

static void build_state_packet(void)
{
  uint32_t duration_sec =
      position_hold_samples
      / POSITION_SAMPLE_RATE_HZ;

  state_tx_packet[0] =
      BLE_CMD_STATE_UPDATE;

  state_tx_packet[1] =
      current_position;

  put_u32_le(
      &state_tx_packet[2],
      duration_sec);

  state_tx_packet[6] =
      latest_risk_valid ? 1U : 0U;

  state_tx_packet[7] =
      latest_risk_valid
      ? latest_highest_zone_id
      : 0U;

  state_tx_packet[8] =
      latest_risk_valid
      ? latest_highest_score
      : 0U;

  state_tx_packet[9] =
      latest_risk_valid
      ? latest_risk_level_id
      : 0U;
}

static void send_state_update_if_due(void)
{
  sl_status_t status;

  if (!status_tx_due
      || fsr_response_pending
      || risk_tx_sequence_pending
      || (gatt_runtime_op
          != GATT_RUNTIME_NONE)
      || (esp_ble_state
          != ESP_BLE_READY)
      || (esp_connection_handle
          == INVALID_CONNECTION_HANDLE)
      || (vitalsense_rx_characteristic
          == INVALID_CHARACTERISTIC_HANDLE)) {

    return;
  }

  build_state_packet();

  status =
      sl_bt_gatt_write_characteristic_value(
          esp_connection_handle,
          vitalsense_rx_characteristic,
          STATE_PACKET_LENGTH,
          state_tx_packet);

  if (status == SL_STATUS_OK) {
    status_tx_due = false;

    gatt_runtime_op =
        GATT_RUNTIME_STATE_WRITE;

  } else {
    printf("[BLE] State write start failed: 0x%08lx\r\n",
           (unsigned long)status);

    /*
     * Keep status_tx_due=true so it can retry.
     */
  }
}

/*******************************************************************************
 ***************************** FSR REQUEST *************************************
 ******************************************************************************/

static void send_fsr_request_if_due(void)
{
  sl_status_t status;
  uint8_t command =
      BLE_CMD_REQUEST_FSR;

  if (!ml_ready
      || !fsr_request_due
      || fsr_response_pending
      || risk_tx_sequence_pending
      || (gatt_runtime_op
          != GATT_RUNTIME_NONE)
      || (esp_ble_state
          != ESP_BLE_READY)
      || (esp_connection_handle
          == INVALID_CONNECTION_HANDLE)
      || (vitalsense_rx_characteristic
          == INVALID_CHARACTERISTIC_HANDLE)) {

    return;
  }

  /*
   * ESP32 RX was created with PROPERTY_WRITE.
   * Use a write request (with response), not Write Without Response.
   */
  status =
      sl_bt_gatt_write_characteristic_value(
          esp_connection_handle,
          vitalsense_rx_characteristic,
          1U,
          &command);

  if (status == SL_STATUS_OK) {
    gatt_runtime_op =
        GATT_RUNTIME_FSR_REQUEST_WRITE;

    fsr_request_due = false;
    fsr_response_pending = true;
    fsr_response_wait_samples = 0U;

    fsr_request_position =
        current_position;

    /*
     * Schedule the next nominal one-second request.
     */
    if (next_fsr_request_sample
        <= (UINT32_MAX
            - RISK_PREDICTION_INTERVAL_SAMPLES)) {

      next_fsr_request_sample +=
          RISK_PREDICTION_INTERVAL_SAMPLES;
    }

    printf("[FSR] Request sent | position=%s duration=%lu s\r\n",
           position_to_string(current_position),
           (unsigned long)(
               position_hold_samples
               / POSITION_SAMPLE_RATE_HZ));

    update_status_rgb();

  } else {
    printf("[FSR] Request write start failed: 0x%08lx\r\n",
           (unsigned long)status);

    gatt_runtime_op =
        GATT_RUNTIME_NONE;

    /*
     * Keep it due so app_process_action() can retry.
     */
    fsr_request_due = true;
  }
}

/*******************************************************************************
 **************************** MODEL EXECUTION **********************************
 ******************************************************************************/

static void run_model_with_latest_plates(void)
{
  pressure_risk_result_t result;
  sl_status_t status;

  uint32_t duration_sec;

  uint32_t head_x100;
  uint32_t shoulders_x100;
  uint32_t hips_x100;
  uint32_t heels_x100;
  uint32_t max_x100;

  if (!ml_ready) {
    printf("[ML] Prediction skipped: model is not ready\r\n");
    return;
  }

  /*
   * Do not accept a stale FSR result after posture changed.
   */
  if (current_position != fsr_request_position) {
    printf("[ML] Stale FSR snapshot ignored because posture changed\r\n");
    return;
  }

  if (position_hold_samples
      < RISK_PREDICTION_THRESHOLD_SAMPLES) {

    printf("[ML] FSR snapshot ignored because duration dropped below threshold\r\n");
    return;
  }

  duration_sec =
      position_hold_samples
      / POSITION_SAMPLE_RATE_HZ;

  status =
      pressure_risk_ml_predict(
          position_to_ml_position(
              current_position),
          duration_sec,
          latest_plate_adc[0],
          latest_plate_adc[1],
          latest_plate_adc[2],
          latest_plate_adc[3],
          &result);

  if (status != SL_STATUS_OK) {
    printf("[ML] Prediction failed: 0x%08lx\r\n",
           (unsigned long)status);

    return;
  }

  head_x100 =
      risk_score_to_hundredths(
          result.head_risk);

  shoulders_x100 =
      risk_score_to_hundredths(
          result.shoulders_risk);

  hips_x100 =
      risk_score_to_hundredths(
          result.hips_risk);

  heels_x100 =
      risk_score_to_hundredths(
          result.heels_risk);

  max_x100 =
      risk_score_to_hundredths(
          result.highest_risk_score);

  /*
   * Avoid %f so floating-point printf support is not required.
   */
  printf(
      "RISK,%s,%lu,%u,%u,%u,%u,"
      "%lu.%02lu,%lu.%02lu,%lu.%02lu,%lu.%02lu,"
      "%s,%lu.%02lu,%s\r\n",

      position_to_string(
          current_position),

      (unsigned long)duration_sec,

      latest_plate_adc[0],
      latest_plate_adc[1],
      latest_plate_adc[2],
      latest_plate_adc[3],

      (unsigned long)(
          head_x100 / 100U),
      (unsigned long)(
          head_x100 % 100U),

      (unsigned long)(
          shoulders_x100 / 100U),
      (unsigned long)(
          shoulders_x100 % 100U),

      (unsigned long)(
          hips_x100 / 100U),
      (unsigned long)(
          hips_x100 % 100U),

      (unsigned long)(
          heels_x100 / 100U),
      (unsigned long)(
          heels_x100 % 100U),

      pressure_risk_zone_to_string(
          result.highest_risk_zone),

      (unsigned long)(
          max_x100 / 100U),
      (unsigned long)(
          max_x100 % 100U),

      pressure_risk_level_to_string(
          result.highest_risk_level));

  /*
   * Save the summary for VitalSense Protocol v1. The per-body 0x02 packets
   * are sent first; the 0x03 summary follows after all four have completed.
   */
  latest_risk_valid = true;

  latest_highest_zone_id =
      (uint8_t)result.highest_risk_zone + 1U;

  latest_highest_score =
      risk_score_to_u8(
          result.highest_risk_score);

  latest_risk_level_id =
      (uint8_t)result.highest_risk_level;

  status_tx_due = true;

  /*
   * Queue all four risk values for transmission back to the ESP32.
   */
  build_risk_packets(&result);

  /*
   * If the 0x01 GATT write procedure has already completed,
   * this starts immediately.
   *
   * If its procedure-completed event has not arrived yet, the queue stays
   * pending and starts from handle_gatt_procedure_completed().
   */
  send_next_risk_update();
}

/*******************************************************************************
 **************************** FSR NOTIFICATION *********************************
 ******************************************************************************/

static void handle_fsr_notification(
    const uint8_t *data,
    size_t length)
{
  if (!fsr_response_pending) {
    printf("[FSR] Unexpected notification ignored\r\n");
    return;
  }

  if (length != FSR_RESPONSE_LENGTH) {
    printf("[FSR] Invalid packet length: %u expected=%u\r\n",
           (unsigned int)length,
           (unsigned int)FSR_RESPONSE_LENGTH);

    fsr_response_pending = false;
    fsr_response_wait_samples = 0U;
    fsr_request_due = true;

    update_status_rgb();

    return;
  }

  if ((data[0] != BLE_MSG_FSR_RESPONSE)
      || (data[1]
          != FSR_RESPONSE_SENSOR_COUNT_BYTE)) {

    printf("[FSR] Invalid header: %02X %02X\r\n",
           data[0],
           data[1]);

    fsr_response_pending = false;
    fsr_response_wait_samples = 0U;
    fsr_request_due = true;

    update_status_rgb();

    return;
  }

  for (uint8_t i = 0U;
       i < FSR_SENSOR_COUNT;
       i++) {

    size_t offset =
        2U + ((size_t)i * 2U);

    latest_fsr[i] =
        (uint16_t)data[offset]
        | ((uint16_t)data[offset + 1U]
           << 8U);
  }

  /*
   * Two physical FSR sensors per body region.
   *
   * 0,1 -> Head
   * 2,3 -> Shoulders
   * 4,5 -> Hips
   * 6,7 -> Heels
   */
  latest_plate_adc[0] =
      (uint16_t)(
          ((uint32_t)latest_fsr[0]
           + (uint32_t)latest_fsr[1])
          / 2U);

  latest_plate_adc[1] =
      (uint16_t)(
          ((uint32_t)latest_fsr[2]
           + (uint32_t)latest_fsr[3])
          / 2U);

  latest_plate_adc[2] =
      (uint16_t)(
          ((uint32_t)latest_fsr[4]
           + (uint32_t)latest_fsr[5])
          / 2U);

  latest_plate_adc[3] =
      (uint16_t)(
          ((uint32_t)latest_fsr[6]
           + (uint32_t)latest_fsr[7])
          / 2U);

  fsr_response_pending = false;
  fsr_response_wait_samples = 0U;

  printf(
      "FSR8,%s,%lu,"
      "%u,%u,%u,%u,%u,%u,%u,%u\r\n",

      position_to_string(
          current_position),

      (unsigned long)(
          position_hold_samples
          / POSITION_SAMPLE_RATE_HZ),

      latest_fsr[0],
      latest_fsr[1],
      latest_fsr[2],
      latest_fsr[3],
      latest_fsr[4],
      latest_fsr[5],
      latest_fsr[6],
      latest_fsr[7]);

  printf(
      "PLATES,%s,%lu,%u,%u,%u,%u\r\n",

      position_to_string(
          current_position),

      (unsigned long)(
          position_hold_samples
          / POSITION_SAMPLE_RATE_HZ),

      latest_plate_adc[0],
      latest_plate_adc[1],
      latest_plate_adc[2],
      latest_plate_adc[3]);

  update_status_rgb();

  run_model_with_latest_plates();
}

/*******************************************************************************
 *********************** GATT PROCEDURE COMPLETION *****************************
 ******************************************************************************/

static void handle_gatt_procedure_completed(
    sl_status_t result)
{
  sl_status_t status;

  /*
   * Discovery / notification setup procedures.
   */
  if (esp_ble_state
      != ESP_BLE_READY) {

    if (result != SL_STATUS_OK) {
      printf("[BLE] GATT discovery/setup failed: 0x%08lx state=%u\r\n",
             (unsigned long)result,
             (unsigned int)esp_ble_state);

      esp_ble_state = ESP_BLE_ERROR;

      update_status_rgb();
      close_esp32_connection();

      return;
    }

    switch (esp_ble_state) {
      case ESP_BLE_DISCOVERING_SERVICE:
        if (vitalsense_service_handle
            == INVALID_SERVICE_HANDLE) {

          printf("[BLE] VitalSense service not found\r\n");

          close_esp32_connection();

          return;
        }

        esp_ble_state =
            ESP_BLE_DISCOVERING_RX_CHAR;

        status =
            sl_bt_gatt_discover_characteristics_by_uuid(
                esp_connection_handle,
                vitalsense_service_handle,
                sizeof(vitalsense_rx_uuid),
                vitalsense_rx_uuid);

        if (status != SL_STATUS_OK) {
          printf("[BLE] RX characteristic discovery start failed: 0x%08lx\r\n",
                 (unsigned long)status);

          close_esp32_connection();
        }
        break;

      case ESP_BLE_DISCOVERING_RX_CHAR:
        if (vitalsense_rx_characteristic
            == INVALID_CHARACTERISTIC_HANDLE) {

          printf("[BLE] VitalSense RX characteristic not found\r\n");

          close_esp32_connection();

          return;
        }

        esp_ble_state =
            ESP_BLE_DISCOVERING_TX_CHAR;

        status =
            sl_bt_gatt_discover_characteristics_by_uuid(
                esp_connection_handle,
                vitalsense_service_handle,
                sizeof(vitalsense_tx_uuid),
                vitalsense_tx_uuid);

        if (status != SL_STATUS_OK) {
          printf("[BLE] TX characteristic discovery start failed: 0x%08lx\r\n",
                 (unsigned long)status);

          close_esp32_connection();
        }
        break;

      case ESP_BLE_DISCOVERING_TX_CHAR:
        if (vitalsense_tx_characteristic
            == INVALID_CHARACTERISTIC_HANDLE) {

          printf("[BLE] VitalSense TX characteristic not found\r\n");

          close_esp32_connection();

          return;
        }

        esp_ble_state =
            ESP_BLE_ENABLING_TX_NOTIFY;

        status =
            sl_bt_gatt_set_characteristic_notification(
                esp_connection_handle,
                vitalsense_tx_characteristic,
                sl_bt_gatt_notification);

        if (status != SL_STATUS_OK) {
          printf("[BLE] TX notification enable start failed: 0x%08lx\r\n",
                 (unsigned long)status);

          close_esp32_connection();
        }
        break;

      case ESP_BLE_ENABLING_TX_NOTIFY:
        esp_ble_state =
            ESP_BLE_READY;

        printf("[BLE] VitalSense link READY\r\n");
        printf("[BLE] RX/TX discovered; TX notifications enabled\r\n");

        update_status_rgb();

        send_state_update_if_due();
        send_fsr_request_if_due();
        break;

      default:
        break;
    }

    return;
  }

  /*
   * Runtime GATT write procedures.
   */
  if (gatt_runtime_op
      == GATT_RUNTIME_NONE) {

    /*
     * Nothing owned by this application is waiting for completion.
     */
    return;
  }

  if (result != SL_STATUS_OK) {
    printf("[BLE] Runtime GATT write failed: 0x%08lx op=%u\r\n",
           (unsigned long)result,
           (unsigned int)gatt_runtime_op);

    if (gatt_runtime_op
        == GATT_RUNTIME_FSR_REQUEST_WRITE) {

      fsr_response_pending = false;
      fsr_response_wait_samples = 0U;
      fsr_request_due = true;
    }

    if (gatt_runtime_op
        == GATT_RUNTIME_STATE_WRITE) {

      status_tx_due = true;
    }

    risk_tx_sequence_pending = false;
    risk_tx_index = 0U;

    gatt_runtime_op =
        GATT_RUNTIME_NONE;

    /*
     * Reconnect to recover a clean GATT client state.
     */
    close_esp32_connection();

    return;
  }

  if (gatt_runtime_op
      == GATT_RUNTIME_FSR_REQUEST_WRITE) {

    gatt_runtime_op =
        GATT_RUNTIME_NONE;

    /*
     * The fresh FSR notification may already have arrived and queued risk
     * packets. If so, start them now.
     */
    send_next_risk_update();

    return;
  }

  if (gatt_runtime_op
      == GATT_RUNTIME_RISK_WRITE) {

    /*
     * A posture change can invalidate the remaining risk sequence while
     * one write is already on the air. That write cannot be cancelled, but
     * after it completes we must not continue sending stale packets.
     */
    if (!risk_tx_sequence_pending) {
      gatt_runtime_op = GATT_RUNTIME_NONE;
      risk_tx_index = 0U;

      send_fsr_request_if_due();
      return;
    }

    {
      uint8_t completed_body =
          (uint8_t)(risk_tx_index + 1U);

      printf("[BLE] Risk packet sent body=%u risk=%u flag=%u\r\n",
             (unsigned int)completed_body,
             (unsigned int)
                 risk_tx_packets[risk_tx_index][2],
             (unsigned int)
                 risk_tx_packets[risk_tx_index][3]);
    }

    gatt_runtime_op =
        GATT_RUNTIME_NONE;

    risk_tx_index++;

    if (risk_tx_index
        >= RISK_PACKET_COUNT) {

      risk_tx_sequence_pending = false;
      risk_tx_index = 0U;

      printf("[BLE] Four-body ML risk update complete\r\n");

      /*
       * Publish summary only after the four per-body risk values are stored
       * by the ESP32. This keeps one UDP snapshot internally consistent.
       */
      send_state_update_if_due();

      /*
       * A new one-second FSR request may have become due while the
       * writes were being serialized.
       */
      send_fsr_request_if_due();

    } else {
      send_next_risk_update();
    }

    return;
  }

  if (gatt_runtime_op
      == GATT_RUNTIME_STATE_WRITE) {

    gatt_runtime_op =
        GATT_RUNTIME_NONE;

    printf("[BLE] State update sent | position=%s duration=%lu riskValid=%u\r\n",
           position_to_string(current_position),
           (unsigned long)(
               position_hold_samples
               / POSITION_SAMPLE_RATE_HZ),
           latest_risk_valid ? 1U : 0U);

    /*
     * If another one-second inference became due while this write was in
     * flight, allow it to start now.
     */
    send_fsr_request_if_due();
  }
}

/*******************************************************************************
 ************************** APPLICATION FUNCTIONS ******************************
 ******************************************************************************/

void app_init(void)
{
  printf("\r\n\r\n");
  printf("============================================================\r\n");
  printf("FIRMWARE: %s\r\n", FIRMWARE_VERSION);
  printf("xG26 IMU + BLE CENTRAL + PRESSURE RISK ML\r\n");
  printf("ESP32 target: %s\r\n", VITALSENSE_DEVICE_NAME);
  printf("============================================================\r\n");

  device_awake = true;
  imu_ready = false;
  ml_ready = false;
  sample_timer_started = false;

  btn0_press_pending = false;
  btn1_press_pending = false;

  sample_tick_count = 0U;
  last_processed_tick = 0U;
  missed_application_ticks = 0U;

  calibration_stage =
      CALIBRATION_WAIT_CENTER;

  current_position =
      POSITION_CENTER;

  pending_position =
      POSITION_CENTER;

  pending_position_count = 0U;

  position_hold_samples = 0U;

  next_fsr_request_sample =
      RISK_PREDICTION_THRESHOLD_SAMPLES;

  fsr_request_due = false;
  fsr_response_pending = false;
  fsr_response_wait_samples = 0U;
  fsr_request_position = POSITION_CENTER;

  status_tx_due = true;
  latest_risk_valid = false;
  latest_highest_zone_id = 0U;
  latest_highest_score = 0U;
  latest_risk_level_id = 0U;

  memset(state_tx_packet, 0, sizeof(state_tx_packet));

  imu_retry_counter = 0U;
  accel_read_failure_count = 0U;

  scanner_active = false;

  esp_connection_handle =
      INVALID_CONNECTION_HANDLE;

  reset_esp_ble_handles();
  reset_runtime_ble_operations();

  esp_ble_state = ESP_BLE_OFF;

  filter_initialized = false;

  memset(latest_fsr, 0, sizeof(latest_fsr));
  memset(latest_plate_adc, 0, sizeof(latest_plate_adc));
  memset(risk_tx_packets, 0, sizeof(risk_tx_packets));

  set_status_rgb(0U, 0U, 0U);

  /*
   * Bluetooth stack boot event performs ML/IMU/timer initialization.
   */
}

void app_process_action(void)
{
  uint32_t current_tick;

  if (btn0_press_pending) {
    btn0_press_pending = false;

    handle_btn0_press();
  }

  if (btn1_press_pending) {
    btn1_press_pending = false;

    handle_btn1_press();
  }

  if (!device_awake
      || !sample_timer_started) {

    return;
  }

  current_tick =
      sample_tick_count;

  if (current_tick
      != last_processed_tick) {

    uint32_t elapsed_ticks =
        current_tick
        - last_processed_tick;

    if (elapsed_ticks > 1U) {
      missed_application_ticks +=
          elapsed_ticks - 1U;
    }

    last_processed_tick =
        current_tick;

    process_accel_sample();

    /*
     * Request is only actually sent when BLE is ready and no other GATT
     * procedure / risk TX sequence is active.
     */
    send_fsr_request_if_due();

    /*
     * If risk packets were queued while another write was active,
     * this starts them as soon as the client is free.
     */
    send_next_risk_update();

    /*
     * Before the ML threshold this is the once-per-second posture update.
     * After inference it is sent after the four risk packets complete.
     */
    send_state_update_if_due();
  }
}

/*******************************************************************************
 ************************** BUTTON CALLBACK ************************************
 ******************************************************************************/

void sl_button_on_change(
    const sl_button_t *handle)
{
  if (sl_button_get_state(handle)
      != SL_SIMPLE_BUTTON_PRESSED) {

    return;
  }

  if (handle == &sl_button_btn0) {
    btn0_press_pending = true;

    return;
  }

  if (handle == &sl_button_btn1) {
    btn1_press_pending = true;
  }
}

/*******************************************************************************
 ************************** BLUETOOTH EVENTS ***********************************
 ******************************************************************************/

void sl_bt_on_event(sl_bt_msg_t *evt)
{
  sl_status_t status;

  switch (SL_BT_MSG_ID(evt->header)) {

    case sl_bt_evt_system_boot_id:
      printf("[BLE] Stack booted in central/client mode\r\n");

      status =
          sl_bt_connection_set_default_parameters(
              BLE_CONNECTION_INTERVAL_UNITS,
              BLE_CONNECTION_INTERVAL_UNITS,
              BLE_CONNECTION_LATENCY,
              BLE_SUPERVISION_TIMEOUT_UNITS,
              0U,
              0xFFFFU);

      printf("[BLE] Default 30 ms connection parameters: 0x%08lx\r\n",
             (unsigned long)status);

      initialize_ml();
      initialize_imu();
      start_sample_timer();

      printf("[CAL] Fit the board in final belt orientation\r\n");
      printf("[CAL] Hold CENTER and press BTN0\r\n");

      update_status_rgb();
      break;

    case sl_bt_evt_scanner_legacy_advertisement_report_id:
      if (scanner_active
          && (esp_ble_state
              == ESP_BLE_SCANNING)) {

        const sl_bt_evt_scanner_legacy_advertisement_report_t *report =
            &evt->data.evt_scanner_legacy_advertisement_report;

        bool service_match =
            advertisement_contains_service(
                report->data.data,
                report->data.len);

        bool name_match =
            advertisement_contains_device_name(
                report->data.data,
                report->data.len);

        if (service_match
            || name_match) {

          uint8_t provisional_connection =
              INVALID_CONNECTION_HANDLE;

          printf("[BLE] VitalSense ESP32 advertisement found (%s)\r\n",
                 service_match
                 ? "service UUID"
                 : "device name");

          stop_esp32_scan();

          esp_ble_state =
              ESP_BLE_CONNECTING;

          update_status_rgb();

          status =
              sl_bt_connection_open(
                  report->address,
                  report->address_type,
                  sl_bt_gap_phy_1m,
                  &provisional_connection);

          if (status == SL_STATUS_OK) {
            esp_connection_handle =
                provisional_connection;

            printf("[BLE] Connection opening. Handle=%u\r\n",
                   esp_connection_handle);

          } else {
            printf("[BLE] Connection open failed: 0x%08lx\r\n",
                   (unsigned long)status);

            esp_connection_handle =
                INVALID_CONNECTION_HANDLE;

            start_esp32_scan();
          }
        }
      }
      break;

    case sl_bt_evt_connection_opened_id:
      esp_connection_handle =
          evt->data.evt_connection_opened.connection;

      scanner_active = false;

      reset_esp_ble_handles();
      reset_runtime_ble_operations();

      printf("[BLE] Connected to ESP32. Handle=%u\r\n",
             esp_connection_handle);

      esp_ble_state =
          ESP_BLE_DISCOVERING_SERVICE;

      update_status_rgb();

      status =
          sl_bt_gatt_discover_primary_services_by_uuid(
              esp_connection_handle,
              sizeof(vitalsense_service_uuid),
              vitalsense_service_uuid);

      if (status != SL_STATUS_OK) {
        printf("[BLE] Service discovery start failed: 0x%08lx\r\n",
               (unsigned long)status);

        close_esp32_connection();
      }
      break;

    case sl_bt_evt_gatt_service_id:
      if (esp_ble_state
          == ESP_BLE_DISCOVERING_SERVICE) {

        vitalsense_service_handle =
            evt->data.evt_gatt_service.service;
      }
      break;

    case sl_bt_evt_gatt_characteristic_id:
      if (esp_ble_state
          == ESP_BLE_DISCOVERING_RX_CHAR) {

        vitalsense_rx_characteristic =
            evt->data.evt_gatt_characteristic.characteristic;

      } else if (esp_ble_state
                 == ESP_BLE_DISCOVERING_TX_CHAR) {

        vitalsense_tx_characteristic =
            evt->data.evt_gatt_characteristic.characteristic;
      }
      break;

    case sl_bt_evt_gatt_procedure_completed_id:
      if (evt->data.evt_gatt_procedure_completed.connection
          == esp_connection_handle) {

        handle_gatt_procedure_completed(
            evt->data.evt_gatt_procedure_completed.result);
      }
      break;

    case sl_bt_evt_gatt_characteristic_value_id:
      if ((evt->data.evt_gatt_characteristic_value.connection
           == esp_connection_handle)
          && (evt->data.evt_gatt_characteristic_value.characteristic
              == vitalsense_tx_characteristic)) {

        handle_fsr_notification(
            evt->data.evt_gatt_characteristic_value.value.data,
            evt->data.evt_gatt_characteristic_value.value.len);
      }
      break;

    case sl_bt_evt_connection_closed_id:
      if (evt->data.evt_connection_closed.connection
          == esp_connection_handle) {

        printf("[BLE] ESP32 disconnected. reason=0x%04x\r\n",
               evt->data.evt_connection_closed.reason);

        /*
         * Any in-flight FSR transaction must be retried after reconnection
         * if this posture is still past the prediction threshold.
         */
        fsr_response_pending = false;
        fsr_response_wait_samples = 0U;

        risk_tx_sequence_pending = false;
        risk_tx_index = 0U;
        gatt_runtime_op = GATT_RUNTIME_NONE;

        restart_esp32_discovery();
      }
      break;

    default:
      break;
  }
}
