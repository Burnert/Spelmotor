#version 460

layout(binding = 1) uniform sampler2D u_Sampler;

layout(location = 0) in vec3 in_FragColor;
layout(location = 1) in vec2 in_TexCoord;

layout(location = 0) out vec4 out_Color;

void main() {
	vec4 color = texture(u_Sampler, in_TexCoord);
	out_Color = vec4(color.rgb, 1.0);
}
