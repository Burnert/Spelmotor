#version 460
#extension GL_GOOGLE_include_directive : enable

#include "shaderlib.glsl"

layout(set = 2, binding = 0) uniform Model {
	mat4 model_matrix;
	mat4 inverse_transpose_matrix;
	mat4 mvp_matrix;
} u_Model;

layout(location = 0) in vec3 in_Position;
layout(location = 1) in vec3 in_Normal;
layout(location = 2) in vec2 in_TexCoord;

layout(location = 0) out vec2 out_TexCoord;
layout(location = 1) out vec3 out_WorldNormal;
layout(location = 2) out vec3 out_WorldPosition;

void main() {
	gl_Position = u_Model.mvp_matrix * vec4(in_Position, 1.0);
	out_TexCoord = in_TexCoord;
	out_WorldNormal = normalize((u_Model.inverse_transpose_matrix * vec4(in_Normal, 0.0)).xyz);
	out_WorldPosition = (u_Model.model_matrix * vec4(in_Position, 1.0)).xyz;
}
