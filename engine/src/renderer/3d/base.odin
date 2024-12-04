package sm_renderer_3d

import "sm:rhi"

MAX_FRAMES_IN_FLIGHT :: rhi.MAX_FRAMES_IN_FLIGHT

RHI_Result :: rhi.RHI_Result

RHI_Buffer          :: rhi.RHI_Buffer
RHI_Texture         :: rhi.RHI_Texture
RHI_Sampler         :: rhi.RHI_Sampler
RHI_Framebuffer     :: rhi.RHI_Framebuffer
RHI_RenderPass      :: rhi.RHI_RenderPass
RHI_Pipeline        :: rhi.RHI_Pipeline
RHI_PipelineLayout  :: rhi.RHI_PipelineLayout
RHI_DescriptorPool  :: rhi.RHI_DescriptorPool
RHI_DescriptorSet   :: rhi.RHI_DescriptorSet
RHI_Shader          :: rhi.RHI_Shader
RHI_CommandBuffer   :: rhi.RHI_CommandBuffer

Framebuffer :: rhi.Framebuffer
Texture_2D :: rhi.Texture_2D
Vertex_Buffer :: rhi.Vertex_Buffer
Index_Buffer :: rhi.Index_Buffer

Matrix4 :: matrix[4, 4]f32
Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32
Quat :: quaternion128

ZERO_VEC3 :: Vec3{0,0,0}