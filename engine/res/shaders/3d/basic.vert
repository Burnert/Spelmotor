#version 460

#define MAX_LIGHTS 1000

#define INVERSE_SQUARE_EPSILON 0.001
#define INVERSE_SQUARE_REF_DIST 1

struct Light_Info {
	vec3 location;
	vec3 direction;
	vec3 color;
	float attenuation_radius;
};

layout(set = 0, binding = 0) uniform Scene {
	Light_Info lights[MAX_LIGHTS];
	uint light_num;
} scene;

layout(set = 1, binding = 0) uniform Scene_View {
	mat4 view_projection_matrix;
	vec3 view_origin;
	vec3 view_direction;
} scene_view;

layout(set = 2, binding = 0) uniform Model {
	mat4 model_matrix;
	mat4 inverse_transpose_matrix;
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
	out_WorldNormal = normalize((model.inverse_transpose_matrix * vec4(in_Normal, 0.0)).xyz);
	out_WorldPosition = (model.model_matrix * vec4(in_Position, 1.0)).xyz;
}
