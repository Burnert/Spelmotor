#version 460

layout(binding = 0) uniform sampler2D u_Sampler;

layout(location = 0) in vec2 in_TexCoord;

layout(location = 0) out vec4 out_Color;

void main() {
	out_Color = vec4(texture(u_Sampler, in_TexCoord).rgb, 1);
}
