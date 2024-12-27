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
} scene_view;

layout(set = 2, binding = 0) uniform Model {
	mat4 model_matrix;
	mat4 inverse_transpose_matrix;
	mat4 mvp_matrix;
} model;

layout(set = 3, binding = 0) uniform sampler2D u_Sampler;

layout(location = 0) in vec2 in_TexCoord;
layout(location = 1) in vec3 in_WorldNormal;
layout(location = 2) in vec3 in_WorldPosition;
vec3 g_WorldNormal;

layout(location = 0) out vec4 out_Color;

float fresnel(vec3 view, vec3 target, vec3 normal) {
	float bias = 0;
	float scale = 1;
	float power = 5;
	vec3 view_vector = normalize(target - view);
	return bias + scale * pow(1.0 + dot(view_vector, normal), power);
}

vec3 calc_light_color(Light_Info light) {
	vec3 d = light.location - in_WorldPosition;
	float r = sqrt(dot(d, d));
	vec3 l = d / r;
	float s = max(dot(l, g_WorldNormal), 0);
	float a = (INVERSE_SQUARE_REF_DIST * INVERSE_SQUARE_REF_DIST) / (r * r + INVERSE_SQUARE_EPSILON);
	float w = max(1 - pow(r / light.attenuation_radius, 4), 0);
	w = w * w;
	return light.color * s * a * w;
}

void main() {
	// Renormalize normals after interpolation
	g_WorldNormal = normalize(in_WorldNormal);

	float fresnel_mask = fresnel(scene_view.view_origin, in_WorldPosition, g_WorldNormal);
	vec3 color = texture(u_Sampler, in_TexCoord).rgb;
	// Just to visualize the fresnel
	vec3 surface_color = color * (1 - fresnel_mask);

	// Calculate lights
	vec3 light_color_sum = vec3(0, 0, 0);
	for (int i = 0; i < scene.light_num; ++i) {
		light_color_sum += calc_light_color(scene.lights[i]);
	}

	vec3 final_color = surface_color * light_color_sum;
	out_Color = vec4(final_color, 1.0);
}
