#include "tflite_micro_model_config.h"
#include <cassert>
#include "ml/third_party/tflm/micro_context.h"
#include "tflite_micro_model.hpp"


namespace npu_toolkit
{


TfliteMicroModelContext* TfliteMicroModelContext::create(TfLiteContext *context)
{
  auto buffer = context->AllocatePersistentBuffer(
    context,
    sizeof(TfliteMicroModelContext)
  );

  if(buffer == nullptr)
  {
    return nullptr;
  }

  return new(buffer)TfliteMicroModelContext();
}

bool TfliteMicroModelContext::init(TfliteMicroModel* model)
{
  _model = model;
  auto micro_context = tflite::GetMicroContext(model->tflite_context());
  assert(micro_context != nullptr);
  micro_context->set_external_context(this);
  return true;
}

void TfliteMicroModelContext::deinit()
{
  auto micro_context = tflite::GetMicroContext(_model->tflite_context());
  assert(micro_context != nullptr);
  micro_context->set_external_context(nullptr);
  _model = nullptr;
}


bool TfliteMicroModelContext::load()
{
  return true;
}

TfliteMicroModel* TfliteMicroModelContext::model() const
{
  assert(_model != nullptr);
  return _model;
}

TfliteMicroModelContext* TfliteMicroModelContext::get(TfLiteContext* context)
{
  auto micro_context = tflite::GetMicroContext(context);
  assert(micro_context != nullptr);
  auto model_context = reinterpret_cast<TfliteMicroModelContext*>(micro_context->external_context());
  assert(model_context != nullptr);
  return model_context;
}


} // namespace npu_toolkit