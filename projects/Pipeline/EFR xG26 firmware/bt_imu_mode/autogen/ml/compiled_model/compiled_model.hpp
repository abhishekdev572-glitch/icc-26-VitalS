#include "tflite_micro_model_config.h"
#pragma once

#include <functional>
#include "ml/third_party/tflm/tlmk-kernel_util.h"
#include "ml/compiled_model/compiled_model_paging_interface.hpp"


namespace npu_toolkit
{


/**
 * @defgroup compiled_model Compiled Model
 * @{
 */

/**
 * Retrieve the compilation data from the .tflite model's metadata
*/
const void* compiled_model_retrieve_compilation_data(
    TfLiteContext *context
);


/**
 * Execute the pre-compiled data for the current model layer on the accelerator.
 *
 * This is called by each accelerator kernel's "compiled" implementation.
 * It iterates through the pre-compiled data for the current ML model layer.

 * @param context TF-Lite context
 * @param program_callback Optional callback to be invoked for each accelerator program used by current layer
 *                         This callback is invoked BEFORE the accelerator registers are populated for the current program
*/
TfLiteStatus compiled_model_process_layer_with_accelerator(
    TfLiteContext *context,
    void (*program_callback)(void*, int) = nullptr,
    void* program_callback_arg = nullptr
);

/**
 * @}
 */


} // namespace npu_toolkit