#include "tflite_micro_model_config.h"
#include <stdio.h>
#include <assert.h>
#include "em_cmu.h"
#include "ml/platform/ml_clock_helper.h"
#include "sl_clock_manager.h"


extern uint32_t __bss_start__;
extern int sl_sleeptimer_init();
extern void _assert_write(const char *s);
extern void sl_iostream_eusart_init_vcom();
extern int sli_clock_manager_hal_set_sysclk_source(sl_oscillator_t);




bool ml_configure_clocks_to_max_rate()
{
  return ml_set_cpu_clock_rate(80*1000*1000);
}


uint32_t ml_get_cpu_clock_frequency()
{
  uint32_t hz;
  sl_clock_manager_get_clock_branch_frequency(SL_CLOCK_BRANCH_SYSCLK, &hz);

  return hz;
}


void ml_set_accelerator_clock_enabled(bool enabled)
{
  if(enabled)
  {
    sl_clock_manager_enable_bus_clock(SL_BUS_CLOCK_MVP);
  }
  else
  {
    sl_clock_manager_disable_bus_clock(SL_BUS_CLOCK_MVP);
  }
}


bool ml_set_cpu_clock_rate(uint32_t hz)
{
    const uint32_t supported_clocks[14] = {
        1,2,4,7,13,16,19,26,32,38,48,56,64,80
    };

    int is_valid = 0;
    for(int i = 0; i < 14; ++i)
    {
        if(supported_clocks[i] * 1000*1000 == hz)
        {
            is_valid = 1;
            break;
        }
    }

    if(!is_valid)
    {
        return 0;
    }

    if(sli_clock_manager_hal_set_sysclk_source(SL_OSCILLATOR_HFRCODPLL) != 0)
    {
        return 0;
    }

    CMU_HFRCODPLLBandSet(hz);

    sl_iostream_eusart_init_vcom();

    bool* is_sleeptimer_initialized = (bool*)&__bss_start__;
    *is_sleeptimer_initialized = false;
    sl_sleeptimer_init();

    return 1;
}


