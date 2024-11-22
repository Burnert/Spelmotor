package sm_renderer_3d

import "core:log"
import "core:math/linalg"
import "core:slice"

import "sm:core"
import "sm:rhi"

DEBUG_LINE_SHADER_VERT :: "3d/dbg_line.vert"
DEBUG_LINE_SHADER_FRAG :: "3d/dbg_line.frag"

DEBUG_MAX_LINES :: 10000

debug_draw_line :: proc(start: Vec3, end: Vec3, color: Vec4) {
	drs := &g_r3d_state.debug_renderer_state

	if len(drs.lines_state.lines) >= DEBUG_MAX_LINES {
		log.error("Max lines has been reached.")
		return
	}

	append(&drs.lines_state.lines, Debug_Line{
		start = start,
		end = end,
		color = color,
	})
}

@(private)
debug_init :: proc(drs: ^Debug_Renderer_State, render_pass: RHI_RenderPass, dims: [2]u32) -> RHI_Result {
	assert(drs != nil)

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
				size = size_of(Debug_Line_Push_Constants),
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
			depth_compare_op = .ALWAYS,
		},
		viewport_dims = dims,
	}
	drs.lines_state.pipeline = rhi.create_graphics_pipeline(pipeline_desc, render_pass, drs.lines_state.pipeline_layout) or_return

	// Create sprite vertex and index buffers
	lines_vb_desc := rhi.Buffer_Desc{
		memory_flags = {.HOST_COHERENT, .HOST_VISIBLE},
		map_memory = true,
	}
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		drs.lines_state.batch_vbs[i] = rhi.create_vertex_buffer_empty(lines_vb_desc, Debug_Line_Vertex, 2*DEBUG_MAX_LINES) or_return
	}

	// Allocate cmd buffers
	drs.cmd_buffers = rhi.allocate_command_buffers(MAX_FRAMES_IN_FLIGHT) or_return

	return nil
}

@(private)
debug_shutdown :: proc(drs: ^Debug_Renderer_State) {
	assert(drs != nil)

	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		rhi.destroy_buffer(&drs.lines_state.batch_vbs[i])
	}
	rhi.destroy_graphics_pipeline(&drs.lines_state.pipeline)
	rhi.destroy_pipeline_layout(&drs.lines_state.pipeline_layout)

	delete(drs.lines_state.lines)
}

@(private)
debug_submit_commands :: proc(drs: ^Debug_Renderer_State, fb: Framebuffer, render_pass: RHI_RenderPass, frame_in_flight: uint) {
	vb := &drs.lines_state.batch_vbs[frame_in_flight]
	line_count := len(drs.lines_state.lines)

	if line_count > 0 {
		for i in 0..<line_count {
			line := &drs.lines_state.lines[i]
			vertex_size := size_of(Debug_Line_Vertex)
			target_memory := vb.mapped_memory[2*i*vertex_size:(2*i+1)*vertex_size]
			target_vertices := cast(^[2]Debug_Line_Vertex) raw_data(target_memory)
			target_vertices[0] = Debug_Line_Vertex{position = line.start, color = line.color}
			target_vertices[1] = Debug_Line_Vertex{position = line.end,   color = line.color}
		}
	}

	cb := &g_r3d_state.debug_renderer_state.cmd_buffers[frame_in_flight]
	rhi.begin_command_buffer(cb)

	rhi.cmd_begin_render_pass(cb, render_pass, fb)

	rhi.cmd_bind_graphics_pipeline(cb, drs.lines_state.pipeline)
	rhi.cmd_set_viewport(cb, {0, 0}, {cast(f32) fb.dimensions.x, cast(f32) fb.dimensions.y}, 0, 1)
	rhi.cmd_set_scissor(cb, {0, 0}, fb.dimensions)

	
	if line_count > 0 {
		rhi.cmd_bind_vertex_buffer(cb, vb^)
	
		right := f32(fb.dimensions.x) / 2.0
		left := -right
		top := f32(fb.dimensions.y) / 2.0
		bottom := -top
		// Flipping y-axis because vulkan's clip space is Y-down
		view_matrix := linalg.matrix_ortho3d_f32(left, right, top, bottom, 10, -10, true)
	
		constants := Debug_Line_Push_Constants{
			view_projection_matrix = view_matrix,
		}
		rhi.cmd_push_constants(cb, drs.lines_state.pipeline_layout, {.VERTEX}, &constants)
	
		// 2 vertices per line
		rhi.cmd_draw(cb, u32(2*line_count))
	}

	rhi.cmd_end_render_pass(cb)

	rhi.end_command_buffer(cb)

	rhi.queue_submit_for_drawing(cb)

	clear(&drs.lines_state.lines)
}

Debug_Line_Vertex :: struct {
	position: Vec3,
	color: Vec4,
}

Debug_Line_Push_Constants :: struct {
	view_projection_matrix: Matrix4,
}

Debug_Line :: struct {
	start: Vec3,
	end: Vec3,
	color: Vec4,
}

Debug_Line_Renderer_State :: struct {
	pipeline: RHI_Pipeline,
	pipeline_layout: RHI_PipelineLayout,
	batch_vbs: [MAX_FRAMES_IN_FLIGHT]Vertex_Buffer,
	line_counts: [MAX_FRAMES_IN_FLIGHT]u32,

	lines: [dynamic]Debug_Line,
}

Debug_Renderer_State :: struct {
	cmd_buffers: [MAX_FRAMES_IN_FLIGHT]RHI_CommandBuffer,
	descriptor_pool: RHI_DescriptorPool,

	lines_state: Debug_Line_Renderer_State,
}
