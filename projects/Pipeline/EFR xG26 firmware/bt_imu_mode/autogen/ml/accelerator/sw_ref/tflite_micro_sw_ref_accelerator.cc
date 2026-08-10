#include "tflite_micro_model_config.h"
#include "em_device.h"
#include "ml/accelerator/sw_ref/tflite_micro_sw_ref_accelerator.hpp"


namespace npu_toolkit
{



const char* TfliteMicroSwRefAccelerator::name() const
{
  return "sw_ref";
}


const char* TfliteMicroSwRefAccelerator::description() const
{
  return "TFLM software reference kernels (no optimization)";
}


__WEAK TfliteMicroAccelerator* get_tflite_micro_accelerator()
{
  static TfliteMicroSwRefAccelerator accelerator;
  return reinterpret_cast<TfliteMicroAccelerator*>(&accelerator);
}

__WEAK TfliteMicroAccelerator* register_tflite_micro_accelerator()
{
    return register_tflite_micro_accelerator(get_tflite_micro_accelerator());
}


} // namespace npu_toolkit