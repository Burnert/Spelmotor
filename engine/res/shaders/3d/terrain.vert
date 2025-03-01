#version 460

layout(push_constant) uniform Constants {
	float height_scale;
	float height_center;
} constants;

layout(set = 1, binding = 0) uniform Scene_View {
	mat4 view_projection_matrix;
	vec3 view_origin;
	vec3 view_direction;
} u_Scene_View;

layout(set = 2, binding = 0) uniform sampler2D u_HeightMap;

layout(location = 0) in vec3 in_Position;
layout(location = 1) in vec3 in_Normal;
layout(location = 2) in vec4 in_Color;
layout(location = 3) in vec2 in_TexCoord;

layout(location = 0) out vec2 out_TexCoord;
layout(location = 1) out vec3 out_WorldNormal;
layout(location = 2) out vec3 out_WorldPosition;
layout(location = 3) out vec4 out_Color;

void main() {
	float height = texture(u_HeightMap, in_TexCoord).r;
	height -= constants.height_center;
	height *= constants.height_scale;

	vec3 world_pos = vec3(in_Position.xy, height);
	gl_Position = u_Scene_View.view_projection_matrix * vec4(world_pos, 1.0);
	out_TexCoord = in_TexCoord;
	out_WorldNormal = in_Normal;
	out_WorldPosition = world_pos;
	out_Color = in_Color;
}
