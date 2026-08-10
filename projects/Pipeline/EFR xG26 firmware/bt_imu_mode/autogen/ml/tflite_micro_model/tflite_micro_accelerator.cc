#include "tflite_micro_model_config.h"
#include "ml/tflite_micro_model/tflite_micro_accelerator.hpp"
#include "ml/tflite_micro_model/tflite_micro_model_helper.hpp"
#include "tflite_micro_model.hpp"


namespace npu_toolkit
{

const char* TfliteMicroAccelerator::name() const
{
    return "unknown";
}

const char* TfliteMicroAccelerator::description() const
{
    return "unknown";
}

static TfliteMicroAccelerator* _registered_accelerator = nullptr;
TfliteMicroAccelerator* register_tflite_micro_accelerator(TfliteMicroAccelerator* accelerator)
{
    _registered_accelerator = accelerator;
    return accelerator;
}

TfliteMicroAccelerator* get_registered_tflite_micro_accelerator()
{
    return _registered_accelerator;
}


} // namespace npu_toolkit