#version 460
#extension GL_GOOGLE_include_directive : enable

#include "shaderlib.glsl"

layout(set = 0, binding = 0) uniform Scene {
	vec3 ambient_light;
	Light_Data lights[MAX_LIGHTS];
	uint light_num;
} u_Scene;

layout(set = 1, binding = 0) uniform Scene_View {
	mat4 view_projection_matrix;
	vec3 view_origin;
	vec3 view_direction;
} u_Scene_View;

layout(set = 2, binding = 0) uniform Model {
	mat4 model_matrix;
	mat4 inverse_transpose_matrix;
	mat4 mvp_matrix;
} u_Model;

layout(set = 3, binding = 0) uniform sampler2D u_Sampler;
layout(set = 3, binding = 1) uniform Material {
	Material_Data material;
} u_Material;

layout(location = 0) in vec2 in_TexCoord;
layout(location = 1) in vec3 in_WorldNormal;
layout(location = 2) in vec3 in_WorldPosition;

layout(location = 0) out vec4 out_Color;

void main() {
	// Renormalize normals after interpolation
	vec3 world_normal = normalize(in_WorldNormal);
	vec3 view_vector = normalize(u_Scene_View.view_origin - in_WorldPosition);

	vec4 sampled_color = texture(u_Sampler, in_TexCoord);
	float alpha = sampled_color.a;
	if (alpha < 1e-4) {
		discard;
	}

	vec3 surface_color = sampled_color.rgb;

	// Constant ambient light - nothing will be darker than this
	vec3 final_color = surface_color * u_Scene.ambient_light;

	// Calculate lights
	for (int i = 0; i < u_Scene.light_num; ++i) {
		vec3 c = calc_lit_surface(surface_color, u_Material.material, world_normal, u_Scene.lights[i], in_WorldPosition, view_vector);
		final_color += c;
	}

	out_Color = vec4(final_color, alpha);
}
