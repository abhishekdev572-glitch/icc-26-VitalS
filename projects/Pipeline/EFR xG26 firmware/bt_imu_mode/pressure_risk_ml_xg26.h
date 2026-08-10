#ifndef PRESSURE_RISK_ML_XG26_H
#define PRESSURE_RISK_ML_XG26_H

#include "sl_status.h"

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
  PRESSURE_POSITION_CENTER = 0,
  PRESSURE_POSITION_LEFT = 1,
  PRESSURE_POSITION_RIGHT = 2
} pressure_position_t;

typedef enum {
  PRESSURE_ZONE_HEAD = 0,
  PRESSURE_ZONE_SHOULDERS = 1,
  PRESSURE_ZONE_HIPS = 2,
  PRESSURE_ZONE_HEELS = 3
} pressure_zone_t;

typedef enum {
  PRESSURE_RISK_LOW = 0,
  PRESSURE_RISK_MEDIUM = 1,
  PRESSURE_RISK_HIGH = 2
} pressure_risk_level_t;

typedef struct {
  float head_risk;
  float shoulders_risk;
  float hips_risk;
  float heels_risk;

  pressure_zone_t highest_risk_zone;
  pressure_risk_level_t highest_risk_level;
  float highest_risk_score;
} pressure_risk_result_t;

/*
 * Initialize the generated Silicon Labs ML model once during application
 * startup.
 */
sl_status_t pressure_risk_ml_init(void);

/*
 * Run one prediction.
 *
 * ADC order:
 *   head, shoulders, hips, heels
 *
 * ADC values should be the fresh averaged values from the four plates.
 *
 * Duration is the uninterrupted number of seconds in the current posture.
 */
sl_status_t pressure_risk_ml_predict(
    pressure_position_t position,
    uint32_t duration_sec,
    uint16_t head_adc,
    uint16_t shoulders_adc,
    uint16_t hips_adc,
    uint16_t heels_adc,
    pressure_risk_result_t *result);

const char *pressure_risk_zone_to_string(
    pressure_zone_t zone);

const char *pressure_risk_level_to_string(
    pressure_risk_level_t level);

#ifdef __cplusplus
}
#endif

#endif
