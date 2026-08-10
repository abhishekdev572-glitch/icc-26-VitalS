#include "tflite_micro_model_config.h"
#include "ml/tflite_micro_model/tflite_micro_model_helper.hpp"
#include "ml/compiled_model/compiled_model_interface.hpp"

namespace npu_toolkit
{


const void* compiled_model_retrieve_compilation_data(
    TfLiteContext *context
)
{
    return TfliteMicroModelHelper::get_metadata_from_tflite_flatbuffer(
        context, COMPILED_MODEL_DATA_TFLITE_TAG
    );
}


} // namespace npu_toolkit