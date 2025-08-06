package renderer

import "sm:core"
import "sm:rhi"

// Definitions from sm:rhi ----------------------------------------------------------------

MAX_FRAMES_IN_FLIGHT :: rhi.MAX_FRAMES_IN_FLIGHT

Backend_Buffer                :: rhi.Backend_Buffer
Backend_Texture               :: rhi.Backend_Texture
Backend_Sampler               :: rhi.Backend_Sampler
Backend_Framebuffer           :: rhi.Backend_Framebuffer
Backend_Render_Pass           :: rhi.Backend_Render_Pass
Backend_Pipeline              :: rhi.Backend_Pipeline
Backend_Pipeline_Layout       :: rhi.Backend_Pipeline_Layout
Backend_Descriptor_Pool       :: rhi.Backend_Descriptor_Pool
Backend_Descriptor_Set        :: rhi.Backend_Descriptor_Set
Backend_Descriptor_Set_Layout :: rhi.Backend_Descriptor_Set_Layout
Backend_Shader                :: rhi.Backend_Shader
Backend_Command_Buffer        :: rhi.Backend_Command_Buffer

// Definitions from sm:core ----------------------------------------------------------------

Vec2 :: core.Vec2
Vec3 :: core.Vec3
Vec4 :: core.Vec4
Quat :: core.Quat
Matrix3 :: core.Matrix3
Matrix4 :: core.Matrix4
Transform :: core.Transform

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
