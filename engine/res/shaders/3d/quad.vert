#version 460

layout(location = 0) out vec2 out_TexCoord;

struct Quad_Vertex {
	vec2 position;
	vec2 tex_coord;
} g_Quad[4] = {
	{{-1,-1}, {0,0}},
	{{ 1,-1}, {1,0}},
	{{-1, 1}, {0,1}},
	{{ 1, 1}, {1,1}},
};

void main() {
	Quad_Vertex vertex = g_Quad[gl_VertexIndex];
	gl_Position = vec4(vertex.position, 0, 1);
	out_TexCoord = vertex.tex_coord;
}
