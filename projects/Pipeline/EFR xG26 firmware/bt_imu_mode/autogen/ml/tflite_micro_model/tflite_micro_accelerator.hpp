#include "tflite_micro_model_config.h"
#pragma once

#include <functional>
#include <vector>
#include <string>
#include "ml/third_party/tflm/micro_allocator.h"
#include "ml/tflite_micro_model/tflite_micro_model_context.hpp"


namespace npu_toolkit
{

/**
 * @addtogroup tflite_micro_model
 * @defgroup tflite_micro_accelerator
 * @{
 */

/**
 * This is the base class for accelerator-specific implementations
 */
class TfliteMicroAccelerator
{
public:

  /**
   * The name of the accelerator
   */
  virtual const char* name() const;

  /**
   * A description of the accelerator
   */
  virtual const char* description() const;

  /**
   * Initialize the accelerator
   *
   * @return true if successful, false else
   */
  virtual bool init(){ return true; }

  /**
   * De-initialize the accelerator
   */
  virtual void deinit(TfLiteContext *context){}

  /**
   * Create the context associated with accelerator
   */
  virtual TfliteMicroModelContext* create_context(
    TfLiteContext *context
  )
  {
    return TfliteMicroModelContext::create(context);
  }

};


/**
 * Register the accelerator that was built into the app.
 * This effectively links the accelerator into the binary.
 * Each accelerator implementation should define this separately.
 *
 * Each app must call this so that the accelerator implementation
 * is linked into the app.
 *
 * @return A reference to the registered accelerator.
 */
TfliteMicroAccelerator* register_tflite_micro_accelerator();

/**
 * Return the accelerator built into the app
 */
TfliteMicroAccelerator* get_tflite_micro_accelerator();

/**
 * Return the registered accelerator.
 * @see @ref register_tflite_micro_accelerator()
 */
TfliteMicroAccelerator*  get_registered_tflite_micro_accelerator();

/**
 * Register a specific accelerator
 * @see @ref register_tflite_micro_accelerator()
 */
TfliteMicroAccelerator*  register_tflite_micro_accelerator(TfliteMicroAccelerator* accelerator);


/**
 * @}
 */


} // namespace npu_toolkit