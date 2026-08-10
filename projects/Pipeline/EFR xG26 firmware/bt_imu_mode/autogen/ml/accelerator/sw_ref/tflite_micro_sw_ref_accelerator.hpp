#include "tflite_micro_model_config.h"
#pragma once

#include <cstdint>
#include <cstdarg>

#include "ml/tflite_micro_model/tflite_micro_accelerator.hpp"

namespace npu_toolkit
{

/**
 * @addtogroup tflite_micro_model
 * @defgroup tflite_micro_accelerator_swf_ref
 * @{
 */


 /**
  * Software reference accelerator implementation
  */
class TfliteMicroSwRefAccelerator : public TfliteMicroAccelerator
{
public:
  const char* name() const override;
  const char* description() const override;

protected:
  TfliteMicroSwRefAccelerator() = default;
  friend TfliteMicroAccelerator* get_tflite_micro_accelerator();
};

/**
 * @}
 */

} // namespace npu_toolkit