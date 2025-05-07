#define MAX_LIGHTS 1000

#define INVERSE_SQUARE_EPSILON 0.001
#define INVERSE_SQUARE_REF_DIST 1
#define SPOT_FALLOFF_EPSILON 0.001

// Keep in sync with renderer/3d.Lighting_Model
#define LIGHTING_MODEL_DEFAULT 0
#define LIGHTING_MODEL_TWO_SIDED_FOLIAGE 1

layout(constant_id = 0) const uint c_LightingModel = 0;

struct Light_Data {
	vec3 location;
	vec3 direction;
	vec3 color;
	float attenuation_radius;
	float spot_cone_angle_cos;
	float spot_cone_falloff;
};

struct Material_Data {
	float specular;
	float specular_hardness;
};

// Phong reflection model
// Assumes normalized vectors
float phong(vec3 v, vec3 l, vec3 n) {
	vec3 r = reflect(-l, n);
	float s = 0;
	switch (c_LightingModel) {
	case LIGHTING_MODEL_DEFAULT:
		s = max(dot(r, v), 0);
		break;
	case LIGHTING_MODEL_TWO_SIDED_FOLIAGE:
		s = abs(dot(r, v));
		break;
	}
	return s;
}

// Blinn-Phong reflection model
// Assumes normalized vectors
float blinn_phong(vec3 v, vec3 l, vec3 n) {
	vec3 h = normalize(v + l);
	float s = 0;
	switch (c_LightingModel) {
	case LIGHTING_MODEL_DEFAULT:
		s = max(dot(n, h), 0);
		break;
	case LIGHTING_MODEL_TWO_SIDED_FOLIAGE:
		s = abs(dot(n, h));
		break;
	}
	return s;
}

// Calculates lighting for one light hitting a surface
vec3 calc_lit_surface(vec3 unlit_color, Material_Data material, vec3 surface_normal, Light_Data light, vec3 world_pos, vec3 view_vec) {
	vec3 light_vector = light.location - world_pos;
	float light_dist = length(light_vector);
	vec3 light_dir = light_vector / light_dist;

	float n_dot_l = 0;
	switch (c_LightingModel) {
	case LIGHTING_MODEL_DEFAULT:
		n_dot_l = max(dot(surface_normal, light_dir), 0);
		break;
	case LIGHTING_MODEL_TWO_SIDED_FOLIAGE:
		n_dot_l = abs(dot(surface_normal, light_dir));
		break;
	}

	// TODO: Custom falloff functions
	// Inverse squared falloff
	float falloff = (INVERSE_SQUARE_REF_DIST * INVERSE_SQUARE_REF_DIST) / (light_dist * light_dist + INVERSE_SQUARE_EPSILON);

	// Window function - smoothly fades out the intensity until attenuation radius is reached
	float window = max(1 - pow(light_dist / light.attenuation_radius, 4), 0);
	window = window * window;

	float attenuation = n_dot_l * falloff * window;

	// Calculate Spotlight cone attenuation
	// A cos of 1 would mean it's a spotlight with a 0 deg cone, which would result in no light,
	// therefore it's treated as a special case, which means the light is a normal point light.
	if (light.spot_cone_angle_cos < 1) {
		float d_dot_nl = dot(light.direction, -light_dir);
		float spot_mask = (d_dot_nl - light.spot_cone_angle_cos);
		// Normalize the range - 1 at the center; 0 on the edges
		spot_mask /= light.spot_cone_angle_cos;
		spot_mask /= light.spot_cone_falloff + SPOT_FALLOFF_EPSILON;
		spot_mask = clamp(spot_mask, 0, 1);
		attenuation *= spot_mask;
	}

	// TODO: Custom reflection models
	float spec = blinn_phong(view_vec, light_dir, surface_normal);
	spec = pow(spec, material.specular_hardness);

	vec3 spec_color = light.color * 2.0; // arbitrary value
	spec_color *= spec * material.specular;
	vec3 lit_color = unlit_color * light.color;
	vec3 final_color = attenuation * (lit_color + spec_color);

	return final_color;
}

// Extracts a slope from a height map sample at tex_coord as a normal vector
vec3 normal_from_height(sampler2D height_map, float scale, vec2 tex_coord) {
	ivec2 heightmap_size = textureSize(height_map, 0);
	vec2 inv_size = 1 / vec2(heightmap_size);
	float l = texture(height_map, vec2(tex_coord.x - inv_size.x, tex_coord.y)).r * scale;
	float r = texture(height_map, vec2(tex_coord.x + inv_size.x, tex_coord.y)).r * scale;
	// Invert green because in texture space 0 is top and in world space it means bottom.
	float t = texture(height_map, vec2(tex_coord.x, tex_coord.y + inv_size.y)).r * scale;
	float b = texture(height_map, vec2(tex_coord.x, tex_coord.y - inv_size.y)).r * scale;
	// Central difference approximation
	vec3 normal = -normalize(vec3(2*(r-l), 2*(b-t), -4));
	return normal;
}
