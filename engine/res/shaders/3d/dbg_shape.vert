#version 460

layout(push_constant) uniform Constants {
	mat4 view_projection_matrix;
	vec3 view_origin;
} constants;

layout(location = 0) in vec3 in_Position;
layout(location = 1) in vec4 in_Color;
layout(location = 2) in vec3 in_Normal;

layout(location = 0) out vec4 out_FragColor;

float fresnel(vec3 view, vec3 target, vec3 normal) {
	float bias = 0;
	float scale = 1;
	float power = 5;
	vec3 view_vector = normalize(target - view);
	return bias + scale * pow(1.0 + dot(view_vector, normal), power);
}

void main() {
	gl_Position = constants.view_projection_matrix * vec4(in_Position, 1.0);

	float fresnel_mask = fresnel(constants.view_origin, in_Position, in_Normal);
	vec4 color = vec4(in_Color.rgb, mix(in_Color.a, 1, fresnel_mask));
	out_FragColor = color;
}
