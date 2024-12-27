#version 460

layout(set = 0, binding = 0) uniform Scene {
	mat4 view_projection_matrix;
	vec3 view_origin;
} scene;

layout(set = 1, binding = 0) uniform Model {
	mat4 model_matrix;
	mat4 mvp_matrix;
} model;

layout(set = 2, binding = 0) uniform sampler2D u_Sampler;

layout(location = 0) in vec2 in_TexCoord;
layout(location = 1) in vec3 in_WorldNormal;
layout(location = 2) in vec3 in_WorldPosition;

layout(location = 0) out vec4 out_Color;

float fresnel(vec3 view, vec3 target, vec3 normal) {
	float bias = 0;
	float scale = 1;
	float power = 5;
	vec3 view_vector = normalize(target - view);
	return bias + scale * pow(1.0 + dot(view_vector, normal), power);
}

void main() {
	// TODO: Do something with the fresnel mask
	float fresnel_mask = fresnel(scene.view_origin, in_WorldPosition, in_WorldNormal);

	out_Color = vec4(texture(u_Sampler, in_TexCoord).rgb, 1);
}
