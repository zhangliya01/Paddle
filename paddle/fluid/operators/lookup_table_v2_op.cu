/* Copyright (c) 2019 PaddlePaddle Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. */

#include "paddle/fluid/framework/eigen.h"
#include "paddle/fluid/framework/op_registry.h"
#include "paddle/fluid/operators/lookup_table_v2_op.h"
#include "paddle/fluid/platform/device/gpu/gpu_primitives.h"
#include "paddle/fluid/platform/float16.h"

namespace paddle {
namespace operators {

template <typename T, int BlockDimX, int BlockDimY, int GridDimX,
          bool PaddingFlag>
__global__ void LookupTableV2(T *output, const T *table, const int64_t *ids,
                              const int64_t N, const int64_t K, const int64_t D,
                              const int64_t padding_idx) {
  int idx = threadIdx.x;
  int idy = blockIdx.x + threadIdx.y * GridDimX;

  while (idy < K) {
    int64_t id = ids[idy];
    T *out = output + idy * D;
    const T *tab = table + id * D;
    for (int i = idx; i < D; i += BlockDimX) {
      if (PaddingFlag) {
        if (id == padding_idx)
          out[i] = static_cast<T>(0);
        else
          out[i] = tab[i];
      } else {
        out[i] = tab[i];
      }
    }
    idy += BlockDimY * GridDimX;
  }
}

template <typename T, int BlockDimX, int BlockDimY, int GridDimX>
__global__ void LookupTableV2Grad(T *table, const T *output, const int64_t *ids,
                                  const int64_t N, const int64_t K,
                                  const int64_t D) {
  int idx = threadIdx.x;
  int idy = blockIdx.x + threadIdx.y * GridDimX;

  while (idy < K) {
    int64_t id = ids[idy];
    const T *out = output + idy * D;
    T *tab = table + id * D;
    for (int i = idx; i < D; i += BlockDimX) {
      paddle::platform::CudaAtomicAdd(&tab[i], out[i]);
    }
    idy += BlockDimY * GridDimX;
  }
}

template <typename T>
__global__ void InputTypeCovert(const T *in_ids, const int64_t K,
                                int64_t *out_ids) {
  for (int i = 0; i < K; i++) {
    out_ids[i] = (int64_t)(in_ids[i]);
  }
}

template <typename T>
class LookupTableV2CUDAKernel : public framework::OpKernel<T> {
 public:
  void Compute(const framework::ExecutionContext &context) const override {
    auto *table_t = context.Input<LoDTensor>("W");
    auto *ids_t = context.Input<LoDTensor>("Ids");
    auto *output_t = context.Output<LoDTensor>("Out");
    int64_t padding_idx = context.Attr<int64_t>("padding_idx");

    auto id_name = context.InputNames("Ids").front();
    auto out_name = context.OutputNames("Out").front();

    size_t N = table_t->dims()[0];
    size_t D = table_t->dims()[1];
    size_t K = ids_t->numel();

    dim3 threads(256, 4);
    dim3 grids(80, 1);

    // copy GPU memory to CPU pinned memory
    framework::Vector<int64_t> ids;
    ids.resize(K);

    const int64_t *ids_p = nullptr;

    if (ids_t->type() == framework::proto::VarType::INT32) {
      InputTypeCovert<
          int><<<grids, threads, 0, context.cuda_device_context().stream()>>>(
          ids_t->data<int>(), K, ids.MutableData(context.GetPlace()));
      ids_p = ids.MutableData(context.GetPlace());
    } else {
      ids_p = ids_t->data<int64_t>();
    }

    for (int64_t i = 0; i < K; ++i) {
      PADDLE_ENFORCE_GE(
          ids[i], 0,
          platform::errors::InvalidArgument(
              "Variable value (input) of OP(paddle.nn.embedding) "
              "expected >= 0 and < %ld, but got %ld. Please check input value.",
              N, ids[i]));
      PADDLE_ENFORCE_LT(
          ids[i], N,
          platform::errors::InvalidArgument(
              "Variable value (input) of OP(paddle.nn.embedding) "
              "expected >= 0 and < %ld, but got %ld. Please check input value.",
              N, ids[i]));
    }

    auto *table = table_t->data<T>();
    auto *output = output_t->mutable_data<T>(context.GetPlace());

    if (padding_idx == -1)
      LookupTableV2<
          T, 256, 4, 80,
          false><<<grids, threads, 0, context.cuda_device_context().stream()>>>(
          output, table, ids_p, N, K, D, padding_idx);
    else
      LookupTableV2<
          T, 256, 4, 80,
          true><<<grids, threads, 0, context.cuda_device_context().stream()>>>(
          output, table, ids_p, N, K, D, padding_idx);
  }
};

template <typename T>
class LookupTableV2GradCUDAKernel : public framework::OpKernel<T> {
 public:
  void Compute(const framework::ExecutionContext &context) const override {
    auto &dev_ctx =
        context.template device_context<platform::CUDADeviceContext>();
    bool is_sparse = context.Attr<bool>("is_sparse");

    // Since paddings are not trainable and fixed in forward, the gradient of
    // paddings makes no sense and we don't deal with it in backward.
    if (is_sparse) {
      auto *ids = context.Input<LoDTensor>("Ids");
      auto *table = context.Input<LoDTensor>("W");
      auto *d_output = context.Input<LoDTensor>(framework::GradVarName("Out"));
      auto *d_table = context.Output<SelectedRows>(framework::GradVarName("W"));

      auto *ids_data = ids->data<int64_t>();
      int64_t ids_num = ids->numel();
      dim3 threads(128, 8);
      dim3 grids(8, 1);
      auto stream = dev_ctx.stream();
      // copy GPU memory to CPU pinned memory
      framework::Vector<int64_t> new_rows;
      new_rows.resize(ids_num);
      auto gpu_place = BOOST_GET_CONST(platform::CUDAPlace, context.GetPlace());

      if (ids->type() == framework::proto::VarType::INT32) {
        InputTypeCovert<
            int><<<grids, threads, 0, context.cuda_device_context().stream()>>>(
            ids->data<int>(), ids_num,
            new_rows.MutableData(context.GetPlace()));
      } else {
        memory::Copy(gpu_place, new_rows.CUDAMutableData(context.GetPlace()),
                     gpu_place, ids_data, ids_num * sizeof(int64_t), stream);
      }

      d_table->set_rows(new_rows);

      auto *d_table_value = d_table->mutable_value();
      d_table_value->Resize({ids_num, table->dims()[1]});
      d_table_value->mutable_data<T>(context.GetPlace());

      auto *d_table_data = d_table_value->data<T>();
      auto *d_output_data = d_output->data<T>();
      auto d_output_dims = d_output->dims();
      auto d_output_dims_2d =
          framework::flatten_to_2d(d_output_dims, d_output_dims.size() - 1);
      PADDLE_ENFORCE_EQ(d_table_value->dims(), d_output_dims_2d,
                        platform::errors::InvalidArgument(
                            "ShapeError: The shape of lookup_table@Grad and "
                            "output@Grad should be same. "
                            "But received lookup_table@Grad's shape = [%s], "
                            "output@Grad's shape = [%s].",
                            d_table_value->dims(), d_output_dims_2d));
      memory::Copy(gpu_place, d_table_data, gpu_place, d_output_data,
                   d_output->numel() * sizeof(T), stream);

    } else {
      auto ids_t = context.Input<LoDTensor>("Ids");
      auto d_output_t = context.Input<LoDTensor>(framework::GradVarName("Out"));
      auto d_table_t = context.Output<LoDTensor>(framework::GradVarName("W"));

      int N = d_table_t->dims()[0];
      int D = d_table_t->dims()[1];
      int K = ids_t->numel();

      dim3 threads(128, 8);
      dim3 grids(8, 1);
      // copy GPU memory to CPU pinned memory
      framework::Vector<int64_t> ids;
      ids.resize(K);

      const int64_t *ids_p = nullptr;

      if (ids_t->type() == framework::proto::VarType::INT32) {
        InputTypeCovert<
            int><<<grids, threads, 0, context.cuda_device_context().stream()>>>(
            ids_t->data<int>(), K, ids.MutableData(context.GetPlace()));
        ids_p = ids.MutableData(context.GetPlace());
      } else {
        ids_p = ids_t->data<int64_t>();
      }

      const T *d_output = d_output_t->data<T>();
      T *d_table = d_table_t->mutable_data<T>(context.GetPlace());

      auto t = framework::EigenVector<T>::Flatten(*d_table_t);
      t.device(*dev_ctx.eigen_device()) = t.constant(static_cast<T>(0));

      LookupTableV2Grad<T, 128, 8, 8><<<grids, threads, 0, dev_ctx.stream()>>>(
          d_table, d_output, ids_p, N, K, D);
    }
  }
};

}  // namespace operators
}  // namespace paddle

namespace ops = paddle::operators;
namespace plat = paddle::platform;
REGISTER_OP_CUDA_KERNEL(lookup_table_v2, ops::LookupTableV2CUDAKernel<float>,
                        ops::LookupTableV2CUDAKernel<double>,
                        ops::LookupTableV2CUDAKernel<plat::float16>);
REGISTER_OP_CUDA_KERNEL(lookup_table_v2_grad,
                        ops::LookupTableV2GradCUDAKernel<float>,
                        ops::LookupTableV2GradCUDAKernel<double>,
                        ops::LookupTableV2GradCUDAKernel<plat::float16>);
