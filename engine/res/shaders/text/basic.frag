#version 460

layout(binding = 0) uniform sampler2D u_Sampler;

layout(location = 0) in vec2 in_TexCoord;
layout(location = 1) in vec4 in_Color;

layout(location = 0, index = 0) out vec4 out_Color;
layout(location = 0, index = 1) out vec4 out_BlendMask;

void main() {
	vec4 sampled_blend_mask = texture(u_Sampler, in_TexCoord);
	out_Color = in_Color;
	out_BlendMask = sampled_blend_mask;
}
