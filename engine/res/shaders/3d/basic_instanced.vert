#version 460
#extension GL_GOOGLE_include_directive : enable

#include "shaderlib.glsl"

layout(set = 1, binding = 0) uniform Scene_View {
	mat4 view_projection_matrix;
	vec3 view_origin;
	vec3 view_direction;
} u_Scene_View;

layout(location = 0) in vec3 in_Position;
layout(location = 1) in vec3 in_Normal;
layout(location = 2) in vec2 in_TexCoord;

layout(location = 3) in mat4 in_InstanceTransform;
layout(location = 7) in mat4 in_InstanceInverseTranspose;

layout(location = 0) out vec2 out_TexCoord;
layout(location = 1) out vec3 out_WorldNormal;
layout(location = 2) out vec3 out_WorldPosition;

void main() {
	mat4 mvp = u_Scene_View.view_projection_matrix * in_InstanceTransform;
	gl_Position = mvp * vec4(in_Position, 1.0);
	out_TexCoord = in_TexCoord;
	out_WorldNormal = normalize((in_InstanceInverseTranspose * vec4(in_Normal, 0.0)).xyz);
	out_WorldPosition = (in_InstanceTransform * vec4(in_Position, 1.0)).xyz;
}
