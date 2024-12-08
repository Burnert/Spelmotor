#version 460

layout(push_constant) uniform Constants {
	mat4 mvp;
} constants;

layout(location = 0) in vec2 in_Position;
layout(location = 1) in vec2 in_TexCoord;
layout(location = 2) in vec4 in_Color;

layout(location = 0) out vec2 out_TexCoord;
layout(location = 1) out vec4 out_Color;

void main() {
	gl_Position = constants.mvp * vec4(in_Position, 0, 1);
	out_TexCoord = in_TexCoord;
	out_Color = in_Color;
}
