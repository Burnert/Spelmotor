#version 460

layout(location = 0) in vec4 in_FragColor;

layout(location = 0) out vec4 out_Color;

void main() {
	out_Color = in_FragColor;
}
