package sm_renderer_3d

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"

import "sm:core"
import "sm:rhi"

DEBUG_LINE_SHADER_VERT  :: "3d/dbg_line_vert.spv"
DEBUG_LINE_SHADER_FRAG  :: "3d/dbg_line_frag.spv"
DEBUG_SHAPE_SHADER_VERT :: "3d/dbg_shape_vert.spv"
DEBUG_SHAPE_SHADER_FRAG :: "3d/dbg_shape_frag.spv"

DEBUG_INIT_MAX_LINES :: 10000
DEBUG_INIT_MAX_TRIS  :: 50000

debug_draw_line :: proc(start: Vec3, end: Vec3, color: Vec4) {
	drs := &g_r3d_state.debug_renderer_state

	append(&drs.lines_state.lines, Debug_Line{
		start = start,
		end = end,
		color = color,
	})
}

// Make an arrow from a couple of lines
debug_draw_arrow :: proc(start: Vec3, end: Vec3, color: Vec4, size: f32 = 0.1) {
	debug_draw_line(start, end, color)
	cross_vec := linalg.vector_cross3(end, VEC3_UP)
	if cross_vec == VEC3_ZERO {
		cross_vec = linalg.vector_cross3(end, VEC3_FORWARD)
	}
	arrow_reverse_dir := linalg.vector_normalize0(start - end)
	arrow_end_point1 := end + linalg.vector_normalize0(arrow_reverse_dir*2 + cross_vec) * size
	arrow_end_point2 := end + linalg.vector_normalize0(arrow_reverse_dir*2 - cross_vec) * size
	debug_draw_line(end, arrow_end_point1, color)
	debug_draw_line(end, arrow_end_point2, color)
	debug_draw_line(arrow_end_point1, arrow_end_point2, color)
}

debug_draw_circle :: proc(center: Vec3, rotation: Quat, radius: f32, color: Vec4, segments: uint = 0) {
	radius := math.abs(radius)
	segments := segments
	if segments == 0 {
		segments = uint(math.log2_f32(radius + 1) * 16)
		segments = math.max(segments, 4)
	}
	transform := linalg.matrix4_translate_f32(center) * linalg.matrix4_from_quaternion_f32(rotation)
	for i in 0..<segments {
		angle1 := f32(i)/f32(segments) * math.TAU
		angle2 := f32(i+1)/f32(segments) * math.TAU
		point1 := Vec4{radius * math.sin(angle1), radius * math.cos(angle1), 0, 1}
		point2 := Vec4{radius * math.sin(angle2), radius * math.cos(angle2), 0, 1}
		transformed_point1 := transform * point1
		transformed_point2 := transform * point2
		debug_draw_line(transformed_point1.xyz, transformed_point2.xyz, color)
	}
}

debug_draw_sphere :: proc(center: Vec3, rotation: Quat, radius: f32, color: Vec4, segments: uint = 0) {
	debug_draw_circle(center, rotation, radius, color, segments)
	debug_draw_circle(center, rotation * linalg.quaternion_angle_axis_f32(math.PI/2, VEC3_RIGHT), radius, color, segments)
	debug_draw_circle(center, rotation * linalg.quaternion_angle_axis_f32(math.PI/2, VEC3_FORWARD), radius, color, segments)
}

debug_draw_box :: proc(center: Vec3, extents: Vec3, rotation: Quat, color: Vec4) {
	transform_point :: proc(point: Vec3, e: Vec3, r: Quat) -> Vec3 {
		new_point := point * e
		new_point = linalg.quaternion128_mul_vector3(r, new_point)
		return new_point
	}

	// Bottom square
	debug_draw_line(transform_point(Vec3{-1,-1,-1}, extents, rotation), transform_point(Vec3{ 1,-1,-1}, extents, rotation), Vec4{1,1,1,1})
	debug_draw_line(transform_point(Vec3{-1, 1,-1}, extents, rotation), transform_point(Vec3{ 1, 1,-1}, extents, rotation), Vec4{1,1,1,1})
	debug_draw_line(transform_point(Vec3{-1, 1,-1}, extents, rotation), transform_point(Vec3{-1,-1,-1}, extents, rotation), Vec4{1,1,1,1})
	debug_draw_line(transform_point(Vec3{ 1, 1,-1}, extents, rotation), transform_point(Vec3{ 1,-1,-1}, extents, rotation), Vec4{1,1,1,1})

	// Top square
	debug_draw_line(transform_point(Vec3{-1,-1, 1}, extents, rotation), transform_point(Vec3{ 1,-1, 1}, extents, rotation), Vec4{1,1,1,1})
	debug_draw_line(transform_point(Vec3{-1, 1, 1}, extents, rotation), transform_point(Vec3{ 1, 1, 1}, extents, rotation), Vec4{1,1,1,1})
	debug_draw_line(transform_point(Vec3{-1, 1, 1}, extents, rotation), transform_point(Vec3{-1,-1, 1}, extents, rotation), Vec4{1,1,1,1})
	debug_draw_line(transform_point(Vec3{ 1, 1, 1}, extents, rotation), transform_point(Vec3{ 1,-1, 1}, extents, rotation), Vec4{1,1,1,1})

	// Connecting lines
	debug_draw_line(transform_point(Vec3{-1,-1,-1}, extents, rotation), transform_point(Vec3{-1,-1, 1}, extents, rotation), Vec4{1,1,1,1})
	debug_draw_line(transform_point(Vec3{ 1,-1,-1}, extents, rotation), transform_point(Vec3{ 1,-1, 1}, extents, rotation), Vec4{1,1,1,1})
	debug_draw_line(transform_point(Vec3{-1, 1,-1}, extents, rotation), transform_point(Vec3{-1, 1, 1}, extents, rotation), Vec4{1,1,1,1})
	debug_draw_line(transform_point(Vec3{ 1, 1,-1}, extents, rotation), transform_point(Vec3{ 1, 1, 1}, extents, rotation), Vec4{1,1,1,1})
}

// Specify the vertices in a clockwise winding
debug_draw_filled_triangle :: proc(vertices: [3]Vec3, color: Vec4) {
	drs := &g_r3d_state.debug_renderer_state

	normal := linalg.vector_cross3(vertices[2] - vertices[0], vertices[1] - vertices[0])
	normal = linalg.vector_normalize0(normal)
	append(&drs.shapes_state.tris, Debug_Tri{
		vertices = vertices,
		color = color,
		normal = normal,
	})

	// Drawing the normal vector
	// avg: Vec3
	// for v in vertices do avg += v
	// avg /= len(vertices)
	// debug_draw_line(avg, avg + normal, Vec4{0,0,1,1})
}

// Draw a filled 2D convex shape transformed to 3D by a matrix
debug_draw_filled_2d_convex_shape :: proc(shape: []Vec2, transform: Matrix4, color: Vec4) {
	transform_and_draw_tri :: proc(tri: [3]Vec2, transform: Matrix4, color: Vec4) {
		tri_3d: [3]Vec3
		for v, i in tri {
			v_4 := Vec4{0,0,0,1}
			v_4.xy = v
			tri_3d[i] = (transform * v_4).xyz
		}
		debug_draw_filled_triangle(tri_3d, color)
	}

	vtx_count := len(shape)
	if vtx_count < 3 {
		log.error("Tried to draw a convex shape with less than 3 vertices.")
	} else if vtx_count == 3 {
		tri := cast(^[3]Vec2)&shape[0]
		transform_and_draw_tri(tri^, transform, color)
	} else {
		v0 := shape[0]
		for i in 0..<vtx_count-2 {
			v_prev := shape[i+1]
			v_curr := shape[i+2]
			tri := [3]Vec2{v0, v_prev, v_curr}
			transform_and_draw_tri(tri, transform, color)
		}
	}
}

// Draw a filled 3D convex shape
debug_draw_filled_3d_convex_shape :: proc(shape: []Vec3, color: Vec4) {
	vtx_count := len(shape)
	if vtx_count < 3 {
		log.error("Tried to draw a convex shape with less than 3 vertices.")
	} else if vtx_count == 3 {
		tri := cast(^[3]Vec3)&shape[0]
		debug_draw_filled_triangle(tri^, color)
	} else {
		v0 := shape[0]
		for i in 0..<vtx_count-2 {
			v_prev := shape[i+1]
			v_curr := shape[i+2]
			tri := [3]Vec3{v0, v_prev, v_curr}
			debug_draw_filled_triangle(tri, color)
		}
	}
}

@(private)
debug_init :: proc(drs: ^Debug_Renderer_State, main_fb_format: rhi.Format, dims: [2]u32) -> RHI_Result {
	assert(drs != nil)

	// Debug render pass - drawing primitives to the main framebuffers
	rp_desc := rhi.Render_Pass_Desc{
		attachments = {
			// Color attachment
			rhi.Attachment_Desc{
				usage = .COLOR,
				format = main_fb_format,
				load_op = .LOAD,
				store_op = .STORE,
				barrier_from = {
					layout = .UNDEFINED,
					access_mask = {},
					stage_mask = {.COLOR_ATTACHMENT_OUTPUT},
				},
				barrier_to = {
					layout = .PRESENT_SRC_KHR,
					access_mask = {.COLOR_ATTACHMENT_WRITE},
					stage_mask = {.COLOR_ATTACHMENT_OUTPUT},
				},
			},
			// Depth-stencil attachment
			rhi.Attachment_Desc{
				usage = .DEPTH_STENCIL,
				format = .D24S8,
				load_op = .CLEAR,
				store_op = .IRRELEVANT,
				barrier_from = {
					layout = .UNDEFINED,
					access_mask = {},
					stage_mask = {.EARLY_FRAGMENT_TESTS},
				},
				barrier_to = {
					layout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
					access_mask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
					stage_mask = {.EARLY_FRAGMENT_TESTS},
				},
			},
		},
	}
	drs.render_pass = rhi.create_render_pass(rp_desc) or_return

	// INIT LINES ----------------------------------------------------------------------------------------------

	{
		// Create shaders
		vsh := rhi.create_vertex_shader(core.path_make_engine_shader_relative(DEBUG_LINE_SHADER_VERT)) or_return
		defer rhi.destroy_shader(&vsh)
	
		fsh := rhi.create_fragment_shader(core.path_make_engine_shader_relative(DEBUG_LINE_SHADER_FRAG)) or_return
		defer rhi.destroy_shader(&fsh)
	
		// Create pipeline layout
		layout := rhi.Pipeline_Layout_Description{
			push_constants = {
				rhi.Push_Constant_Range{
					offset = 0,
					size = size_of(Debug_Push_Constants),
					shader_stage = {.VERTEX},
				},
			},
		}
		drs.lines_state.pipeline_layout = rhi.create_pipeline_layout(layout) or_return
	
		// Setup vertex input for lines
		vertex_input_types := []rhi.Vertex_Input_Type_Desc{
			rhi.Vertex_Input_Type_Desc{type = Debug_Line_Vertex, rate = .VERTEX},
		}
		vid := rhi.create_vertex_input_description(vertex_input_types, context.temp_allocator)
		log.debug("\nDEBUG LINE VID:", vid, "\n")
	
		// Create line renderer graphics pipeline
		pipeline_desc := rhi.Pipeline_Description{
			shader_stages = {
				rhi.Pipeline_Shader_Stage{type = .VERTEX,   shader = &vsh.shader},
				rhi.Pipeline_Shader_Stage{type = .FRAGMENT, shader = &fsh.shader},
			},
			vertex_input = vid,
			input_assembly = {
				topology = .LINE_LIST,
			},
			depth_stencil = {
				depth_test = true,
				depth_write = true,
				depth_compare_op = .LESS_OR_EQUAL,
			},
			viewport_dims = dims,
		}
		drs.lines_state.pipeline = rhi.create_graphics_pipeline(pipeline_desc, drs.render_pass, drs.lines_state.pipeline_layout) or_return
	}

	debug_create_lines_vertex_buffers(drs, DEBUG_INIT_MAX_LINES) or_return

	// INIT SHAPES ----------------------------------------------------------------------------------------------

	{
		// Create shaders
		vsh := rhi.create_vertex_shader(core.path_make_engine_shader_relative(DEBUG_SHAPE_SHADER_VERT)) or_return
		defer rhi.destroy_shader(&vsh)
	
		fsh := rhi.create_fragment_shader(core.path_make_engine_shader_relative(DEBUG_SHAPE_SHADER_FRAG)) or_return
		defer rhi.destroy_shader(&fsh)
	
		// Create pipeline layout
		layout := rhi.Pipeline_Layout_Description{
			push_constants = {
				rhi.Push_Constant_Range{
					offset = 0,
					size = size_of(Debug_Push_Constants),
					shader_stage = {.VERTEX},
				},
			},
		}
		drs.shapes_state.pipeline_layout = rhi.create_pipeline_layout(layout) or_return
	
		// Setup vertex input for lines
		vertex_input_types := []rhi.Vertex_Input_Type_Desc{
			rhi.Vertex_Input_Type_Desc{type = Debug_Tri_Vertex, rate = .VERTEX},
		}
		vid := rhi.create_vertex_input_description(vertex_input_types, context.temp_allocator)
		log.debug("\nDEBUG SHAPE VID:", vid, "\n")
	
		// Create line renderer graphics pipeline
		pipeline_desc := rhi.Pipeline_Description{
			shader_stages = {
				rhi.Pipeline_Shader_Stage{type = .VERTEX,   shader = &vsh.shader},
				rhi.Pipeline_Shader_Stage{type = .FRAGMENT, shader = &fsh.shader},
			},
			vertex_input = vid,
			input_assembly = {
				topology = .TRIANGLE_LIST,
			},
			depth_stencil = {
				depth_test = true,
				depth_write = true,
				depth_compare_op = .LESS_OR_EQUAL,
			},
			viewport_dims = dims,
		}
		drs.shapes_state.pipeline = rhi.create_graphics_pipeline(pipeline_desc, drs.render_pass, drs.shapes_state.pipeline_layout) or_return
	}

	debug_create_tris_vertex_buffers(drs, DEBUG_INIT_MAX_TRIS) or_return

	return nil
}

@(private)
debug_create_lines_vertex_buffers :: proc(drs: ^Debug_Renderer_State, max_line_count: u32) -> RHI_Result {
	assert(max_line_count < max(u32) / 2)
	lines_vb_desc := rhi.Buffer_Desc{
		memory_flags = {.HOST_COHERENT, .HOST_VISIBLE},
		map_memory = true,
	}
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		drs.lines_state.batch_vbs[i] = rhi.create_vertex_buffer_empty(lines_vb_desc, Debug_Line_Vertex, 2*max_line_count) or_return
	}
	drs.lines_state.buffer_max_line_capacity = max_line_count
	return nil
}

@(private)
debug_destroy_lines_vertex_buffers :: proc(drs: ^Debug_Renderer_State) {
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		rhi.destroy_buffer(&drs.lines_state.batch_vbs[i])
	}
}

@(private)
debug_recreate_lines_vertex_buffers :: proc(drs: ^Debug_Renderer_State, new_max_line_count: u32) -> RHI_Result {
	rhi.wait_for_device()
	debug_destroy_lines_vertex_buffers(drs)
	debug_create_lines_vertex_buffers(drs, new_max_line_count) or_return
	return nil
}

@(private)
debug_create_tris_vertex_buffers :: proc(drs: ^Debug_Renderer_State, max_tri_count: u32) -> RHI_Result {
	assert(max_tri_count < max(u32) / 3)
	tris_vb_desc := rhi.Buffer_Desc{
		memory_flags = {.HOST_COHERENT, .HOST_VISIBLE},
		map_memory = true,
	}
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		drs.shapes_state.batch_vbs[i] = rhi.create_vertex_buffer_empty(tris_vb_desc, Debug_Tri_Vertex, 3*max_tri_count) or_return
	}
	drs.shapes_state.buffer_max_tri_capacity = max_tri_count
	return nil
}

@(private)
debug_destroy_tris_vertex_buffers :: proc(drs: ^Debug_Renderer_State) {
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		rhi.destroy_buffer(&drs.shapes_state.batch_vbs[i])
	}
}

@(private)
debug_recreate_tris_vertex_buffers :: proc(drs: ^Debug_Renderer_State, new_max_tri_count: u32) -> RHI_Result {
	rhi.wait_for_device()
	debug_destroy_tris_vertex_buffers(drs)
	debug_create_tris_vertex_buffers(drs, new_max_tri_count) or_return
	return nil
}

@(private)
debug_shutdown :: proc(drs: ^Debug_Renderer_State) {
	assert(drs != nil)

	debug_destroy_tris_vertex_buffers(drs)

	rhi.destroy_graphics_pipeline(&drs.shapes_state.pipeline)
	rhi.destroy_pipeline_layout(&drs.shapes_state.pipeline_layout)

	debug_destroy_lines_vertex_buffers(drs)

	rhi.destroy_graphics_pipeline(&drs.lines_state.pipeline)
	rhi.destroy_pipeline_layout(&drs.lines_state.pipeline_layout)

	rhi.destroy_render_pass(&drs.render_pass)

	delete(drs.shapes_state.tris)
	delete(drs.lines_state.lines)
}

debug_update :: proc(drs: ^Debug_Renderer_State) -> RHI_Result {
	// Handle line VB recreation:
	line_count := cast(u32)len(drs.lines_state.lines)
	if line_count > drs.lines_state.buffer_max_line_capacity {
		new_max_line_count := drs.lines_state.buffer_max_line_capacity * 2
		if line_count > new_max_line_count {
			new_max_line_count = line_count * 2
		}
		debug_recreate_lines_vertex_buffers(drs, new_max_line_count) or_return
	}

	frame_in_flight := rhi.get_frame_in_flight()

	lines_vb := &drs.lines_state.batch_vbs[frame_in_flight]
	lines_vb_memory := rhi.cast_mapped_buffer_memory(Debug_Line_Vertex, lines_vb.mapped_memory)
	if line_count > 0 {
		for i in 0..<line_count {
			line := &drs.lines_state.lines[i]
			target_vertices := cast(^[2]Debug_Line_Vertex)&lines_vb_memory[2*i] // <-- every 2nd vertex
			target_vertices[0] = Debug_Line_Vertex{position = line.start, color = line.color}
			target_vertices[1] = Debug_Line_Vertex{position = line.end,   color = line.color}
		}
	}

	// Handle tri VB recreation:
	tri_count := cast(u32)len(drs.shapes_state.tris)
	if tri_count > drs.shapes_state.buffer_max_tri_capacity {
		new_max_tri_count := drs.shapes_state.buffer_max_tri_capacity * 2
		if tri_count > new_max_tri_count {
			new_max_tri_count = tri_count * 2
		}
		debug_recreate_tris_vertex_buffers(drs, new_max_tri_count) or_return
	}

	tris_vb := &drs.shapes_state.batch_vbs[frame_in_flight]
	tris_vb_memory := rhi.cast_mapped_buffer_memory(Debug_Tri_Vertex, tris_vb.mapped_memory)
	if tri_count > 0 {
		for i in 0..<tri_count {
			tri := &drs.shapes_state.tris[i]
			target_vertices := cast(^[3]Debug_Tri_Vertex)&tris_vb_memory[3*i] // <-- every 3rd vertex
			target_vertices[0] = Debug_Tri_Vertex{position = tri.vertices[0], color = tri.color, normal = tri.normal}
			target_vertices[1] = Debug_Tri_Vertex{position = tri.vertices[1], color = tri.color, normal = tri.normal}
			target_vertices[2] = Debug_Tri_Vertex{position = tri.vertices[2], color = tri.color, normal = tri.normal}
		}
	}

	return nil
}

add_debug_render_pass :: proc(drs: ^Debug_Renderer_State, cb: ^RHI_CommandBuffer, sv: RScene_View, fb: Framebuffer, sync: rhi.Vk_Queue_Submit_Sync = {}) {
	frame_in_flight := rhi.get_frame_in_flight()
	line_count := cast(u32)len(drs.lines_state.lines)
	lines_vb := &drs.lines_state.batch_vbs[frame_in_flight]
	tri_count := cast(u32)len(drs.shapes_state.tris)
	tris_vb := &drs.shapes_state.batch_vbs[frame_in_flight]

	rhi.cmd_begin_render_pass(cb, drs.render_pass, fb)

	rhi.cmd_set_viewport(cb, {0, 0}, {cast(f32) fb.dimensions.x, cast(f32) fb.dimensions.y}, 0, 1)
	rhi.cmd_set_scissor(cb, {0, 0}, fb.dimensions)

	if line_count > 0 {
		rhi.cmd_bind_graphics_pipeline(cb, drs.lines_state.pipeline)

		rhi.cmd_bind_vertex_buffer(cb, lines_vb^)

		constants := Debug_Push_Constants{
			view_projection_matrix = sv.view_info.view_projection_matrix,
			view_origin = sv.view_info.view_origin,
		}
		rhi.cmd_push_constants(cb, drs.lines_state.pipeline_layout, {.VERTEX}, &constants)
	
		// 2 vertices per line
		rhi.cmd_draw(cb, u32(2*line_count))
	}

	if tri_count > 0 {
		rhi.cmd_bind_graphics_pipeline(cb, drs.shapes_state.pipeline)

		rhi.cmd_bind_vertex_buffer(cb, tris_vb^)

		constants := Debug_Push_Constants{
			view_projection_matrix = sv.view_info.view_projection_matrix,
			view_origin = sv.view_info.view_origin,
		}
		rhi.cmd_push_constants(cb, drs.shapes_state.pipeline_layout, {.VERTEX}, &constants)
	
		// 3 vertices per tri
		rhi.cmd_draw(cb, u32(3*tri_count))
	}

	rhi.cmd_end_render_pass(cb)

	clear(&drs.lines_state.lines)
	clear(&drs.shapes_state.tris)
}

Debug_Push_Constants :: struct {
	view_projection_matrix: Matrix4,
	view_origin: Vec3,
}

Debug_Line_Vertex :: struct {
	position: Vec3,
	color: Vec4,
}

Debug_Line :: struct {
	start: Vec3,
	end: Vec3,
	color: Vec4,
}

Debug_Tri_Vertex :: struct {
	position: Vec3,
	color: Vec4,
	normal: Vec3,
}

Debug_Tri :: struct {
	vertices: [3]Vec3,
	color: Vec4,
	normal: Vec3,
}

Debug_Line_Renderer_State :: struct {
	pipeline: RHI_Pipeline,
	pipeline_layout: RHI_PipelineLayout,
	batch_vbs: [MAX_FRAMES_IN_FLIGHT]Vertex_Buffer,
	buffer_max_line_capacity: u32, // max vertex count / 2

	lines: [dynamic]Debug_Line,
}

Debug_Shape_Renderer_State :: struct {
	pipeline: RHI_Pipeline,
	pipeline_layout: RHI_PipelineLayout,
	batch_vbs: [MAX_FRAMES_IN_FLIGHT]Vertex_Buffer,
	buffer_max_tri_capacity: u32, // max vertex count / 3

	tris: [dynamic]Debug_Tri,
}

Debug_Renderer_State :: struct {
	descriptor_pool: RHI_DescriptorPool,
	render_pass: RHI_RenderPass,

	lines_state: Debug_Line_Renderer_State,
	shapes_state: Debug_Shape_Renderer_State,
}
