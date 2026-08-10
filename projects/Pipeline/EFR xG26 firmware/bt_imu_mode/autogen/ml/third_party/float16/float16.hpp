#include "tflite_micro_model_config.h"
#pragma once


// Embedded must use build flag: -mfp16-format=ieee
#if (defined(__ARM_FP16_FORMAT_IEEE) || defined(__ARM_FP16_FORMAT_ALTERNATIVE)) && !(defined(__APPLE__) && defined(__MACH__))
typedef __fp16 float16_t;

#else

#error "float16 support is not available on this platform. Please compile with -mfp16-format=ieee"

#endif