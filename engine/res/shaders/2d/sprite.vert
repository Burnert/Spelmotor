#version 460

layout(push_constant) uniform Constants {
	mat4 view_matrix;
} constants;

layout(location = 0) in vec2 in_Position;
layout(location = 1) in vec2 in_TexCoord;

layout(location = 2) in mat4 in_InstanceTransform;
layout(location = 6) in vec4 in_Color;
layout(location = 7) in float in_Depth;

layout(location = 0) out vec4 out_FragColor;
layout(location = 1) out vec2 out_TexCoord;

void main() {
	gl_Position = constants.view_matrix * in_InstanceTransform * vec4(in_Position, in_Depth, 1.0);
	out_FragColor = in_Color;
	out_TexCoord = in_TexCoord;
}
