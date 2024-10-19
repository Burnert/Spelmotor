#version 460

layout(binding = 0) uniform UBO {
	mat4 mvp;
} ubo;

layout(location = 0) in vec3 in_Position;
layout(location = 1) in vec3 in_Color;
layout(location = 2) in vec2 in_TexCoord;

layout(location = 0) out vec3 out_FragColor;
layout(location = 1) out vec2 out_TexCoord;

void main() {
	gl_Position = ubo.mvp * vec4(in_Position, 1.0);
	out_FragColor = in_Color;
	out_TexCoord = in_TexCoord;
}
