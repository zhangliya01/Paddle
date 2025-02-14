// Copyright (c) 2021 PaddlePaddle Authors. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#pragma once

#include <memory>
#include <vector>

namespace paddle {
namespace distributed {

class TaskLoop;
class TaskLoopThread;

class TaskLoopThreadPool {
 public:
  TaskLoopThreadPool();
  explicit TaskLoopThreadPool(int thread_num);
  ~TaskLoopThreadPool();

  void SetThreadNum(int thread_num) { thread_num_ = thread_num; }

  void Start();

  TaskLoop* GetLoop(int tid);
  std::vector<TaskLoop*> GetAllLoops();

 private:
  bool start_;
  int thread_num_;
  std::vector<std::unique_ptr<TaskLoopThread>> threads_;
  std::vector<TaskLoop*> loops_;
};

}  // namespace distributed
}  // namespace paddle
