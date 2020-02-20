#include <d3d/common.h>
#include <d3d/box/nms.h>
#include <d3d/box/geometry.hpp>

using namespace torch;

constexpr int ThreadsPerBlock = sizeof(int64_t) * 8;

// FIXME: Is there any reason to cut blocks like this? Why not directly calculate?
// FIXME: Should have quicker solution, directly compare each pair boxes and suppress the box with
//        lower score if they have overlap greater than threshold.
//        This should be only considered if it takes too much time with respect to whole process.

template <typename scalar_t>
__global__ void rbox_2d_nms_kernel(
    const _PackedAccessor(2) boxes,
    const _PackedAccessorT(int64_t, 1) order,
    const scalar_t threshold,
    _PackedAccessorT(int64_t, 2) mask
) {
    const int row_start = blockIdx.y;
    const int col_start = blockIdx.x;
    if (row_start > col_start) return; // calculate only upper part

    const int row_size = min(boxes.size(0) - row_start * ThreadsPerBlock, ThreadsPerBlock);
    const int col_size = min(boxes.size(0) - col_start * ThreadsPerBlock, ThreadsPerBlock);

    __shared__ scalar_t block_boxes[ThreadsPerBlock][5];
    if (threadIdx.x < col_size)
    {
        #pragma unroll
        for (int i = 0; i < 5; ++i)
        {
            int boxi = order[ThreadsPerBlock * col_start + threadIdx.x];
            block_boxes[threadIdx.x][i] = boxes[boxi][i];
        }
    }
    __syncthreads();

    if (threadIdx.x < row_size)
    {
        const int bcur_idx = order[ThreadsPerBlock * row_start + threadIdx.x];
        Box2 bcur(boxes[bcur_idx][0], boxes[bcur_idx][1], boxes[bcur_idx][2],
            boxes[bcur_idx][3], boxes[bcur_idx][4]);

        int64_t flag = 0;
        int start = (row_start == col_start) ? threadIdx.x + 1 : 0;
        for (int i = start; i < col_size; i++)
        {
            Box2 bcomp(block_boxes[i][0], block_boxes[i][1], block_boxes[i][2],
                block_boxes[i][3], block_boxes[i][4]);
            if (bcur.iou(bcomp) > threshold)
                flag |= 1ULL << i;
        }
        mask[bcur_idx][col_start] = flag;
    }
}

__global__ void nms_collect(
    const _PackedAccessorT(int64_t, 1) order,
    const _PackedAccessorT(int64_t, 2) mask,
    _PackedAccessorT(int64_t, 1) remv,
    _PackedAccessorT(bool, 1) suppressed // already filled by false
) {
    const int nboxes = mask.size(0);
    const int nblocks = mask.size(1);

    for (int i = 0; i < nboxes; i++)
    {
        int block_idx = i / ThreadsPerBlock;
        int thread_idx = i % ThreadsPerBlock;

        if (!(remv[block_idx] & (1ULL << thread_idx)))
        {
            for (int j = block_idx; j < nblocks; j++)
                remv[j] |= mask[i * nblocks][j];
        }
        else
            suppressed[order[i]] = true;
    }
}

void rbox_2d_nms_cuda(
  const Tensor boxes, const Tensor order,
  float threshold,
  Tensor suppressed
) {

    const int nboxes = boxes.sizes().at(0);
    const int nblocks = DivUp(nboxes, ThreadsPerBlock);
    auto long_options = torch::TensorOptions().device(torch::kCUDA).dtype(torch::kLong);

    // This tensor store pairwise IOU result, rows are continuous while cols are divided by ThreadsPerBlock
    // It has type int64, but it can act as uint64 in terms of bit operation
    auto mask = torch::empty({nboxes, nblocks}, long_options);

    dim3 blocks(nblocks, nblocks);
    dim3 threads(ThreadsPerBlock);

    AT_DISPATCH_FLOATING_TYPES(boxes.type(), "rbox_2d_nms_kernel", ([&] {
        rbox_2d_nms_kernel<<<blocks, threads>>>(
            boxes._packed_accessor(2),
            order._packed_accessor_typed(int64_t, 1),
            (scalar_t) threshold,
            mask._packed_accessor_typed(int64_t, 2));
    }));

    auto remv = torch::zeros({nblocks}, long_options);
    nms_collect<<<1, 1>>>(
        order._packed_accessor_typed(int64_t, 1),
        mask._packed_accessor_typed(int64_t, 2),
        remv._packed_accessor_typed(int64_t, 1),
        suppressed._packed_accessor_typed(bool, 1));
}
