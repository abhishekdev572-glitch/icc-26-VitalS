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

#ifndef TENSORFLOW_LITE_MICRO_MEMORY_PLANNER_NON_PERSISTENT_MEMORY_PLANNER_SHIM_H__
#define TENSORFLOW_LITE_MICRO_MEMORY_PLANNER_NON_PERSISTENT_MEMORY_PLANNER_SHIM_H__

#include "ml/third_party/tflm/tlm-compatibility.h"
#include "ml/third_party/tflm/memory_plan_struct.h"
#include "ml/third_party/tflm/micro_memory_planner.h"

namespace tflite {

/*   This is an experimental feature and subjected to change.
 *
The NonPersistentMemoryPlannerShim enables TFLM to work with an external tooling
that can plan the offset of each non persistent buffer for the Model within the
TFLM arena.

If the NonPersistentMemoryPlannerShim is used, then the final binary does not
have any of the symbols associated with the GreedyMemoryPlanner which results in
a reduced memory footprint.

Additionally, the offline planning of the non-persistent buffers can be used to
have a more efficient utilization compared to the GreedyMemoryPlanner.

For example, consider the following hypothetical model:

A1(400)                    A2(401)
──┬─────────┐    ┌───────────
  │         │    │
  │         │    │
  │         ▼    ▼
  │       ┌────────┐
  │       │  OP1   │
  │       └───┬────┘       A4(201)
  │   A3(10)  │              │
  │           │              │
  │           │              │
  │       ┌───┴────┐         │
  │       │  OP2   │◄────────┤
  │       └───┬────┘         │
  │   A5(11)  │      A6(202) │
  │           │       │      │
  │           ▼       │      │
  │       ┌────────┐  │      │
  │       │  OP3   │◄─┘      │
  │       └───┬────┘         │
  │           │      A8(200) │
  │   A7(12)  │        │     │
  │           │        │     │
  │       ┌───┴────┐◄──┘     │
  └──────►│  OP4   │         │
          └───┬────┘◄────────┘
              │
      A9(13)  │
              ▼

The GreedyMemoryPlanner will give the following memory layout that requires 1012
bytes of scratch arena size:

┌─────────────────────────────────────────┬──────────────────────────┬────────┬───────┐
│  A2(401)                                │          A1(400)         │ A4(201)│
A3(10)│
└─────────────────────────────────────────┴──────────────────────────┴────────┴───────┘

┌───────────┬──────┬──────┐
│ A6(202)   │A5(11)│A7(12)│
└───────────┴──────┴──────┘

┌──────────┬───────┐
│ A8(200)  │A9(13) │
└──────────┴───────┘

But a more efficient offline memory plan that requires only 826 bytes of scratch
arena size can be

┌──────────────────────────────────────┬─────────────────────────────┬───────┬──────┐
│      A1(400)                         │         A2(401)             │
A3(10)│A5(11)│
└──────────────────────────────────────┴─────────────────────────────┴───────┴──────┘

                                       ┌────────────────┬────────────┬────────┬───────┐
                                       │A4(201)         │  A8(200)   │A9(13)
│A7(12) │ └────────────────┴────────────┴────────┴───────┘

                                                        ┌─────────────┐
                                                        │  A6(202)    │
                                                        └─────────────┘

*/
class NonPersistentMemoryPlannerShim : public MicroMemoryPlanner {
 public:
  // Does not take ownership of buffer_plan, which must refer to a valid
  // BufferPlan that outlives this object.
  explicit NonPersistentMemoryPlannerShim(const BufferPlan* buffer_plan);
  ~NonPersistentMemoryPlannerShim() override;

  TfLiteStatus GetOffsetForBuffer(int buffer_request_index,
                                  int* offset) override;

  TfLiteStatus AddBuffer(int size, int first_time_used,
                         int last_time_used) override;
  size_t GetMaximumMemorySize() override;
  int GetBufferCount() override;

  // Returns False because the NonPersistentMemoryPlannerShim doesn't preserves
  // all tensors after invocation.
  bool preserves_all_tensors() const override { return false; }

 private:
  const BufferPlan* buffer_plan_;  // not owned, can't be null

  // The number of buffers requested so far. Used for error checking.
  int buffer_request_count_;

  TF_LITE_REMOVE_VIRTUAL_DELETE
};

}  // namespace tflite

#endif  // TENSORFLOW_LITE_MICRO_MEMORY_PLANNER_NON_PERSISTENT_MEMORY_PLANNER_SHIM_H__
