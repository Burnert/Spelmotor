#version 460

layout(push_constant) uniform Constants {
	mat4 view_matrix;
} constants;

layout(location = 0) in vec4 in_Color;
layout(location = 1) in vec2 in_Position;

layout(location = 0) out vec4 out_FragColor;

void main() {
	gl_Position = constants.view_matrix * vec4(in_Position, 0.0, 1.0);
	out_FragColor = in_Color;
}
