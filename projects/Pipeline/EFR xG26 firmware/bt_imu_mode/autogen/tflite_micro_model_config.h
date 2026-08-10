#pragma once

#if !defined(FLATBUFFERS_LOCALE_INDEPENDENT)
#define FLATBUFFERS_LOCALE_INDEPENDENT 0
#endif

#if !defined(FLATBUFFERS_PREFER_PRINTF)
#define FLATBUFFERS_PREFER_PRINTF 1
#endif

#if !defined(FLATBUFFERS_USE_STD_OPTIONAL)
#define FLATBUFFERS_USE_STD_OPTIONAL 0
#endif

#if defined(__ICCARM__)
#pragma diag_suppress=Pa039
#endif

#if (!defined(TF_LITE_USE_RUNTIME_MEMORY_PLANNING) || (TF_LITE_USE_RUNTIME_MEMORY_PLANNING==0))
  #define TFLITE_MICRO_OFFLINE_MEMORY_PLANNING_REQUIRED
#endif

#if !defined(TF_LITE_USE_GLOBAL_ROUND)
#define TF_LITE_USE_GLOBAL_ROUND
#endif

#if !defined(TFLITE_SINGLE_ROUNDING)
#define TFLITE_SINGLE_ROUNDING 1
#endif

#if !defined(TF_LITE_STATIC_MEMORY)
#define TF_LITE_STATIC_MEMORY
#endif

#if !defined(KERNELS_OPTIMIZED_FOR_SPEED)
#define KERNELS_OPTIMIZED_FOR_SPEED
#endif

#if !defined(TFLITE_MICRO_LOGGER_ENABLED) && !defined(SL_ML_ENABLE_SILABS_PROFILER)
#define TF_LITE_STRIP_ERROR_STRINGS
#endif

#if defined(__clang__)
#pragma clang diagnostic ignored "-Wunused-variable"
#elif defined(__GNUC__)
#pragma GCC diagnostic ignored "-Wunused-variable"
#endif

#if defined(__clang__)
#pragma clang diagnostic ignored "-Wunused-parameter"
#elif defined(__GNUC__)
#pragma GCC diagnostic ignored "-Wunused-parameter"
#endif

#if defined(__clang__)
#pragma clang diagnostic ignored "-Wunused-function"
#elif defined(__GNUC__)
#pragma GCC diagnostic ignored "-Wunused-function"
#endif

#if defined(__clang__)
#pragma clang diagnostic ignored "-Wuninitialized"
#elif defined(__GNUC__)
#pragma GCC diagnostic ignored "-Wmaybe-uninitialized"
#endif

#if defined(__clang__)
#pragma clang diagnostic ignored "-Wunused-but-set-variable"
#elif defined(__GNUC__)
#pragma GCC diagnostic ignored "-Wunused-but-set-variable"
#endif

#if defined(__ICCARM__)
#pragma diag_suppress=Pa205
#pragma diag_suppress=Pe550
#pragma diag_suppress=Pe1675
#pragma diag_suppress=Pa093
#pragma diag_suppress=Pe611
#pragma diag_suppress=Pe177
#endif

