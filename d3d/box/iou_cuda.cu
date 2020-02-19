#include <d3d/box/iou.h>
#include <d3d/box/geometry.hpp>

#define _PackedAccessor(n) torch::PackedTensorAccessor32<scalar_t,n,torch::RestrictPtrTraits>
#define _packed_accessor(n) packed_accessor32<scalar_t,n,torch::RestrictPtrTraits>()

using namespace std;
using namespace torch;

template <typename scalar_t>
__global__ void rbox_2d_iou_kernel(
    const _PackedAccessor(2) boxes1,
    const _PackedAccessor(2) boxes2,
    _PackedAccessor(2) ious
)
{
    const int nm = blockIdx.x * blockDim.x + threadIdx.x;
    const int i = nm / boxes1.size(0);
    const int j = nm % boxes1.size(0);
    
    Box2 b1(boxes1[i][0], boxes1[i][1], boxes1[i][2],
        boxes1[i][3], boxes1[i][4]);
    Box2 b2(boxes2[j][0], boxes2[j][1], boxes2[j][2],
        boxes2[j][3], boxes2[j][4]);
    ious[i][j] = b1.intersect(b2).area();
}

void rbox_2d_iou_cuda(
    const Tensor boxes1, const Tensor boxes2, Tensor ious
)
{
    const int total_ops = boxes1.sizes().at(0) * boxes2.sizes().at(0);
    const int threads = 1024;
    const dim3 blocks((total_ops + threads - 1) / threads);
  
    AT_DISPATCH_FLOATING_TYPES(boxes1.type(), "rbox_2d_iou_cuda", ([&] {
        rbox_2d_iou_kernel<scalar_t><<<blocks, threads>>>(
        boxes1._packed_accessor(2),
        boxes2._packed_accessor(2),
        ious._packed_accessor(2));
    }));
}
