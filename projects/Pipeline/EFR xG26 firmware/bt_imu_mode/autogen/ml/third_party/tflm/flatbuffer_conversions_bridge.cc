#include "tflite_micro_model_config.h"
/* Copyright 2021 The TensorFlow Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
==============================================================================*/
#include "ml/third_party/tflm/flatbuffer_conversions_bridge.h"

#include "ml/third_party/tflm/c_api_types.h"
#include "ml/third_party/tflm/tlca-error_reporter.h"
#include "ml/third_party/tflm/flatbuffer_conversions.h"
#include "ml/third_party/tflm/micro_error_reporter.h"
#include "ml/third_party/tflm/tls-schema_generated.h"

namespace tflite {
TfLiteStatus ConvertTensorType(TensorType tensor_type, TfLiteType* type) {
  return ConvertTensorType(tensor_type, type, tflite::GetMicroErrorReporter());
}

TfLiteStatus CallBuiltinParseFunction(TfLiteBridgeBuiltinParseFunction parser,
                                      const Operator* op,
                                      BuiltinDataAllocator* allocator,
                                      void** builtin_data) {
  return parser(op, tflite::GetMicroErrorReporter(), allocator, builtin_data);
}
}  // namespace tflite
