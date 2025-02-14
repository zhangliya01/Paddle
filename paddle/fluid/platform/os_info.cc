/* Copyright (c) 2021 PaddlePaddle Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. */

#include "paddle/fluid/platform/os_info.h"
#include <sstream>
#include "paddle/fluid/platform/device_tracer.h"

namespace paddle {
namespace platform {

ThreadId::ThreadId() {
  std_tid_ = std::hash<std::thread::id>()(std::this_thread::get_id());
  std::stringstream ss;
  ss << std::this_thread::get_id();
  cupti_tid_ = static_cast<uint32_t>(std::stoull(ss.str()));
  RecoreCurThreadId(MainTid());  // For DeviceTracer
}

ThreadIdRegistry::~ThreadIdRegistry() {
  std::lock_guard<std::mutex> lock(lock_);
  for (auto id_pair : id_map_) {
    delete id_pair.second;
  }
}

}  // namespace platform
}  // namespace paddle
