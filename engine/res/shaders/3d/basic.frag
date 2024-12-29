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

layout(set = 3, binding = 0) uniform sampler2D u_Sampler;
layout(set = 3, binding = 1) uniform Material {
	float specular;
	float specular_hardness;
} u_Material;

layout(location = 0) in vec2 in_TexCoord;
layout(location = 1) in vec3 in_WorldNormal;
layout(location = 2) in vec3 in_WorldPosition;
vec3 g_WorldNormal;
vec3 g_ViewVector;
vec3 g_SurfaceColor;

layout(location = 0) out vec4 out_Color;

float fresnel(vec3 view, vec3 target, vec3 normal) {
	float bias = 0;
	float scale = 1;
	float power = 5;
	vec3 view_vector = normalize(target - view);
	return bias + scale * pow(1.0 + dot(view_vector, normal), power);
}

vec3 calc_lit_surface(Light_Info light) {
	vec3 light_vector = light.location - in_WorldPosition;
	float light_dist = length(light_vector);
	vec3 light_dir = light_vector / light_dist;
	float n_dot_l = max(dot(g_WorldNormal, light_dir), 0);
	float falloff = (INVERSE_SQUARE_REF_DIST * INVERSE_SQUARE_REF_DIST) / (light_dist * light_dist + INVERSE_SQUARE_EPSILON);
	float window = max(1 - pow(light_dist / light.attenuation_radius, 4), 0);
	window = window * window;
	float attenuation = falloff * window;
	vec3 attenuated_light_color = light.color * attenuation;

	// Phong reflection model
	// vec3 refl_vec = reflect(-light_dir, g_WorldNormal);
	// float spec = max(dot(refl_vec, g_ViewVector), 0);

	// Blinn-Phong reflection model
	vec3 h = normalize(g_ViewVector + light_dir);
	float spec = max(dot(g_WorldNormal, h), 0);

	spec = pow(spec, u_Material.specular_hardness);

	vec3 spec_color = light.color * 2.0;
	vec3 color = n_dot_l * attenuated_light_color * (g_SurfaceColor + spec_color * spec * u_Material.specular);

	return color;
}

void main() {
	// Renormalize normals after interpolation
	g_WorldNormal = normalize(in_WorldNormal);
	g_ViewVector = normalize(scene_view.view_origin - in_WorldPosition);

	float fresnel_mask = fresnel(scene_view.view_origin, in_WorldPosition, g_WorldNormal);
	vec3 color = texture(u_Sampler, in_TexCoord).rgb;
	// Just to visualize the fresnel
	g_SurfaceColor = color * (1 - fresnel_mask);

	vec3 final_color = vec3(0,0,0);

	// Calculate lights
	for (int i = 0; i < scene.light_num; ++i) {
		vec3 c = calc_lit_surface(scene.lights[i]);
		final_color += c;
	}

	out_Color = vec4(final_color, 1.0);
}
