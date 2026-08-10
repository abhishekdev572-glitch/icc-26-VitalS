#include "tflite_micro_model_config.h"
/* Copyright 2023 The TensorFlow Authors. All Rights Reserved.

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

#include <cstdio>
#include "ml/third_party/tflm/debug_log.h"

// See:
// https://github.com/tensorflow/tflite-micro/blob/main/tensorflow/lite/micro/docs/new_platform_support.md#step-2-customize-logging-and-timing-function-for-your-platform

extern "C" void DebugLog(const char* format, va_list args) {
#ifndef TF_LITE_STRIP_ERROR_STRINGS
  vprintf(format, args);
#endif  // TF_LITE_STRIP_ERROR_STRINGS
}

#ifndef TF_LITE_STRIP_ERROR_STRINGS
// Only called from MicroVsnprintf (micro_log.h)
extern "C" int DebugVsnprintf(char* buffer, size_t buf_size, const char* format,
                              va_list vlist) {
  return vsnprintf(buffer, buf_size, format, vlist);
}
#endif
