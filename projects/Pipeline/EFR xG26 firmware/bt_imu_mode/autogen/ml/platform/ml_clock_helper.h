#include "tflite_micro_model_config.h"
#pragma once

#include <stdint.h>
#include <stdbool.h>


#ifdef __cplusplus
extern "C" {
#endif


/**
 * Configure the CPU and QSPI clocks
 * to the maximum supported rate
 */
bool ml_configure_clocks_to_max_rate();

bool ml_set_cpu_clock_rate(uint32_t hz);

/**
 * Return the CPU clock frequency in hertz
 */
uint32_t ml_get_cpu_clock_frequency();


/**
 * Enable/disable the ML accelerator clock
 */
void ml_set_accelerator_clock_enabled(bool enabled);



#ifdef __cplusplus
}
#endif