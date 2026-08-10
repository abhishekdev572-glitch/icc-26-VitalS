/*
 * Exact feature preparation and inference wrapper for:
 *
 *   12 -> 16 ReLU -> 8 ReLU -> 4 Sigmoid
 *
 * Simplicity Studio generated model name:
 *
 *   pressure_risk_mlp
 *
 * Expected generated model header and handle:
 *
 *   #include "sl_ml_model_pressure_risk_mlp.h"
 *   sl_ml_pressure_risk_mlp_model_handle
 *
 * These names are confirmed from the generated Silicon Labs header.
 */

#include "pressure_risk_ml_xg26.h"

#include "sl_ml_model_pressure_risk_mlp.h"
#include "sl_ml_tflite_micro_model.h"

#include <math.h>
#include <stddef.h>

namespace {

constexpr size_t kInputCount = 12U;
constexpr size_t kOutputCount = 4U;

constexpr float kMaximumTrainingDurationSec = 21600.0f;
constexpr float kReferenceDurationSec = 7200.0f;
constexpr float kReliefFloor = 0.10f;
constexpr float kPressureExponent = 1.50f;

constexpr float kLowMediumThreshold = 35.0f;
constexpr float kMediumHighThreshold = 70.0f;

/*
 * Dataset-relative plate calibration from the supplied metadata.
 *
 * Replace these values with physical per-plate calibration once available.
 */
constexpr float kAdcLow[4] = {
  3119.0f,  /* Head */
  3537.0f,  /* Shoulders */
  3007.0f,  /* Hips */
  3222.0f   /* Heels */
};

constexpr float kAdcHigh[4] = {
  3932.0f,  /* Head */
  3994.0f,  /* Shoulders */
  3909.0f,  /* Hips */
  4021.0f   /* Heels */
};

bool model_initialized = false;

float clamp_float(
    float value,
    float minimum,
    float maximum)
{
  if (value < minimum) {
    return minimum;
  }

  if (value > maximum) {
    return maximum;
  }

  return value;
}

size_t tensor_element_count(
    const TfLiteTensor *tensor)
{
  if ((tensor == nullptr)
      || (tensor->dims == nullptr)) {
    return 0U;
  }

  size_t count = 1U;

  for (int index = 0;
       index < tensor->dims->size;
       ++index) {
    count *=
        static_cast<size_t>(
            tensor->dims->data[index]);
  }

  return count;
}

float normalize_adc(
    uint16_t adc,
    size_t zone_index)
{
  const float denominator =
      kAdcHigh[zone_index]
      - kAdcLow[zone_index];

  const float normalized =
      (static_cast<float>(adc)
       - kAdcLow[zone_index])
      / denominator;

  return clamp_float(normalized, 0.0f, 1.0f);
}

float calculate_exposure_scaled(
    float normalized_load,
    float duration_sec)
{
  const float effective_load =
      clamp_float(
          (normalized_load - kReliefFloor)
          / (1.0f - kReliefFloor),
          0.0f,
          1.0f);

  const float exposure =
      powf(effective_load, kPressureExponent)
      * duration_sec
      / kReferenceDurationSec;

  return clamp_float(exposure, 0.0f, 3.0f)
         / 3.0f;
}

pressure_risk_level_t score_to_level(
    float score)
{
  if (score >= kMediumHighThreshold) {
    return PRESSURE_RISK_HIGH;
  }

  if (score >= kLowMediumThreshold) {
    return PRESSURE_RISK_MEDIUM;
  }

  return PRESSURE_RISK_LOW;
}

}  // namespace


extern "C" sl_status_t pressure_risk_ml_init(void)
{
  const sl_status_t status =
      sl_ml_model_init(
          &sl_ml_pressure_risk_mlp_model_handle);

  model_initialized = (status == SL_STATUS_OK);

  return status;
}


extern "C" sl_status_t pressure_risk_ml_predict(
    pressure_position_t position,
    uint32_t duration_sec,
    uint16_t head_adc,
    uint16_t shoulders_adc,
    uint16_t hips_adc,
    uint16_t heels_adc,
    pressure_risk_result_t *result)
{
  if (!model_initialized) {
    return SL_STATUS_NOT_INITIALIZED;
  }

  if (result == nullptr) {
    return SL_STATUS_NULL_POINTER;
  }

  if (position > PRESSURE_POSITION_RIGHT) {
    return SL_STATUS_INVALID_PARAMETER;
  }

  TfLiteTensor *input =
      sl_ml_pressure_risk_mlp_model_handle
          .input_tensor(0);

  TfLiteTensor *output =
      sl_ml_pressure_risk_mlp_model_handle
          .output_tensor(0);

  if ((input == nullptr)
      || (output == nullptr)) {
    return SL_STATUS_FAIL;
  }

  if ((input->type != kTfLiteFloat32)
      || (output->type != kTfLiteFloat32)) {
    return SL_STATUS_NOT_SUPPORTED;
  }

  if ((tensor_element_count(input) != kInputCount)
      || (tensor_element_count(output) != kOutputCount)) {
    return SL_STATUS_INVALID_CONFIGURATION;
  }

  const float duration_for_model =
      clamp_float(
          static_cast<float>(duration_sec),
          0.0f,
          kMaximumTrainingDurationSec);

  float loads[4];

  loads[0] = normalize_adc(head_adc, 0U);
  loads[1] = normalize_adc(shoulders_adc, 1U);
  loads[2] = normalize_adc(hips_adc, 2U);
  loads[3] = normalize_adc(heels_adc, 3U);

  float features[kInputCount];

  features[0] =
      (position == PRESSURE_POSITION_CENTER)
      ? 1.0f : 0.0f;

  features[1] =
      (position == PRESSURE_POSITION_LEFT)
      ? 1.0f : 0.0f;

  features[2] =
      (position == PRESSURE_POSITION_RIGHT)
      ? 1.0f : 0.0f;

  features[3] =
      log1pf(duration_for_model)
      / log1pf(kMaximumTrainingDurationSec);

  features[4] = loads[0];
  features[5] = loads[1];
  features[6] = loads[2];
  features[7] = loads[3];

  features[8] =
      calculate_exposure_scaled(
          loads[0],
          duration_for_model);

  features[9] =
      calculate_exposure_scaled(
          loads[1],
          duration_for_model);

  features[10] =
      calculate_exposure_scaled(
          loads[2],
          duration_for_model);

  features[11] =
      calculate_exposure_scaled(
          loads[3],
          duration_for_model);

  for (size_t index = 0U;
       index < kInputCount;
       ++index) {
    input->data.f[index] = features[index];
  }

  const sl_status_t run_status =
      sl_ml_model_run(
          &sl_ml_pressure_risk_mlp_model_handle);

  if (run_status != SL_STATUS_OK) {
    return run_status;
  }

  float scores[4];

  for (size_t index = 0U;
       index < kOutputCount;
       ++index) {
    scores[index] =
        100.0f
        * clamp_float(
            output->data.f[index],
            0.0f,
            1.0f);
  }

  result->head_risk = scores[0];
  result->shoulders_risk = scores[1];
  result->hips_risk = scores[2];
  result->heels_risk = scores[3];

  size_t highest_index = 0U;

  for (size_t index = 1U;
       index < kOutputCount;
       ++index) {
    if (scores[index] > scores[highest_index]) {
      highest_index = index;
    }
  }

  result->highest_risk_zone =
      static_cast<pressure_zone_t>(
          highest_index);

  result->highest_risk_score =
      scores[highest_index];

  result->highest_risk_level =
      score_to_level(
          result->highest_risk_score);

  return SL_STATUS_OK;
}


extern "C" const char *pressure_risk_zone_to_string(
    pressure_zone_t zone)
{
  switch (zone) {
    case PRESSURE_ZONE_HEAD:
      return "HEAD";

    case PRESSURE_ZONE_SHOULDERS:
      return "SHOULDERS";

    case PRESSURE_ZONE_HIPS:
      return "HIPS";

    case PRESSURE_ZONE_HEELS:
      return "HEELS";

    default:
      return "UNKNOWN";
  }
}


extern "C" const char *pressure_risk_level_to_string(
    pressure_risk_level_t level)
{
  switch (level) {
    case PRESSURE_RISK_LOW:
      return "LOW";

    case PRESSURE_RISK_MEDIUM:
      return "MEDIUM";

    case PRESSURE_RISK_HIGH:
      return "HIGH";

    default:
      return "UNKNOWN";
  }
}
