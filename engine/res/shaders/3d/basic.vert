#version 460

layout(set = 0, binding = 0) uniform Scene {
	mat4 view_projection_matrix;
	vec3 view_origin;
} scene;

layout(set = 1, binding = 0) uniform Model {
	mat4 model_matrix;
	mat4 mvp_matrix;
} model;

layout(location = 0) in vec3 in_Position;
layout(location = 1) in vec3 in_Normal;
layout(location = 2) in vec2 in_TexCoord;

layout(location = 0) out vec2 out_TexCoord;
layout(location = 1) out vec3 out_WorldNormal;
layout(location = 2) out vec3 out_WorldPosition;

void main() {
	gl_Position = model.mvp_matrix * vec4(in_Position, 1.0);
	out_TexCoord = in_TexCoord;
	// TODO: Transform normal by the adjoint
	out_WorldNormal = (model.model_matrix * vec4(in_Normal, 0.0)).xyz;
	out_WorldPosition = (model.model_matrix * vec4(in_Position, 1.0)).xyz;
}