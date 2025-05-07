package sm_renderer_3d

import "sm:core"
import "sm:rhi"

// Definitions from sm:rhi ----------------------------------------------------------------

MAX_FRAMES_IN_FLIGHT :: rhi.MAX_FRAMES_IN_FLIGHT

RHI_Buffer                :: rhi.RHI_Buffer
RHI_Texture               :: rhi.RHI_Texture
RHI_Sampler               :: rhi.RHI_Sampler
RHI_Framebuffer           :: rhi.RHI_Framebuffer
RHI_Render_Pass           :: rhi.RHI_Render_Pass
RHI_Pipeline              :: rhi.RHI_Pipeline
RHI_Pipeline_Layout       :: rhi.RHI_Pipeline_Layout
RHI_Descriptor_Pool       :: rhi.RHI_Descriptor_Pool
RHI_Descriptor_Set        :: rhi.RHI_Descriptor_Set
RHI_Descriptor_Set_Layout :: rhi.RHI_Descriptor_Set_Layout
RHI_Shader                :: rhi.RHI_Shader
RHI_Command_Buffer        :: rhi.RHI_Command_Buffer

// Definitions from sm:core ----------------------------------------------------------------

Vec2 :: core.Vec2
Vec3 :: core.Vec3
Vec4 :: core.Vec4
Quat :: core.Quat
Matrix3 :: core.Matrix3
Matrix4 :: core.Matrix4

VEC2_ZERO :: core.VEC2_ZERO

VEC3_ZERO :: core.VEC3_ZERO
VEC3_ONE :: core.VEC3_ONE
VEC3_RIGHT :: core.VEC3_RIGHT
VEC3_LEFT :: core.VEC3_LEFT
VEC3_FORWARD :: core.VEC3_FORWARD
VEC3_BACKWARD :: core.VEC3_BACKWARD
VEC3_UP :: core.VEC3_UP
VEC3_DOWN :: core.VEC3_DOWN

VEC4_ZERO :: core.VEC4_ZERO

QUAT_IDENTITY :: core.QUAT_IDENTITY

MATRIX3_IDENTITY :: core.MATRIX3_IDENTITY
MATRIX4_IDENTITY :: core.MATRIX4_IDENTITY

vec3 :: core.vec3
vec4 :: core.vec4
