package renderer

import "core:log"
import "core:math/linalg"
import "core:strings"
import "core:fmt"

import "sm:core"
import "sm:platform"
import "sm:rhi"

R2D_MAX_VERTEX_COUNT :: 200000
R2D_MAX_INDEX_COUNT  :: 300000
R2D_MAX_TEXTURE_DESCRIPTOR_SETS :: 1000

R2D_SHADER_VERT :: "2d/2d.vert"
R2D_SHADER_FRAG :: "2d/2d.frag"

r2d_begin_frame :: proc() {
	assert(g_r2ds != nil)
	assert(g_rhi != nil)

	frame_in_flight := g_rhi.frame_in_flight
	vb := g_r2ds.vb_mapped[frame_in_flight]
	ib := g_r2ds.ib_mapped[frame_in_flight]
	vb_offset := &g_r2ds.vb_offsets[frame_in_flight]
	ib_offset := &g_r2ds.ib_offsets[frame_in_flight]

	// vb_offset^ = g_r2ds.vb_cursor % R2D_MAX_VERTEX_COUNT
	// ib_offset^ = g_r2ds.ib_cursor % R2D_MAX_INDEX_COUNT
	g_r2ds.vb_cursor = vb_offset^
	g_r2ds.ib_cursor = ib_offset^
}

r2d_push_rect :: proc(cb: ^rhi.Backend_Command_Buffer, rect: Renderer2D_Rect, color: Vec4, texcoord_rect: Renderer2D_Rect = {0,0,0,0}) {
	assert(g_r2ds != nil)
	assert(g_rhi != nil)

	frame_in_flight := g_rhi.frame_in_flight
	vb := g_r2ds.vb_mapped[frame_in_flight]
	ib := g_r2ds.ib_mapped[frame_in_flight]
	vb_offset := g_r2ds.vb_offsets[frame_in_flight]
	ib_offset := g_r2ds.ib_offsets[frame_in_flight]

	vb_index := g_r2ds.vb_cursor
	// This flush is not strictly necessary, but it's easier to just not worry about wrapping indices
	if vb_index+4 > R2D_MAX_VERTEX_COUNT {
		r2d_flush(cb)
		r2d_push_rect(cb, rect, color, texcoord_rect)
		return
	}
	vb[vb_index+0] = {color = color, pos = {rect.x,          rect.y},          texcoord = {texcoord_rect.x,                   texcoord_rect.y}}
	vb[vb_index+1] = {color = color, pos = {rect.x + rect.w, rect.y},          texcoord = {texcoord_rect.x + texcoord_rect.w, texcoord_rect.y}}
	vb[vb_index+2] = {color = color, pos = {rect.x + rect.w, rect.y + rect.h}, texcoord = {texcoord_rect.x + texcoord_rect.w, texcoord_rect.y + texcoord_rect.h}}
	vb[vb_index+3] = {color = color, pos = {rect.x,          rect.y + rect.h}, texcoord = {texcoord_rect.x,                   texcoord_rect.y + texcoord_rect.h}}
	
	// NOTE: If this index would go out of bounds and wraps, there is literally no way to actually draw this rect because it would be split in the middle.
	// Theoretically, vertices can be wrapped across one rect, but indices/triangles can't.
	//
	// For example:
	// buffer start --> |------CURRENT-INDICES--------|_____PREVIOUS_INDICES_________cursor_start_-->_|-----CURRENT-INDICES-----| <-- wrapping point
	//
	// Draw call would have to start at 0, and end at MAX, but have a hole in the middle, which is not possible to do.
	// Therefore, flushing if over the limit is the simplest thing to do.
	ib_index := g_r2ds.ib_cursor
	if ib_index+6 > R2D_MAX_INDEX_COUNT {
		r2d_flush(cb)
		r2d_push_rect(cb, rect, color, texcoord_rect)
		return
	}
	// VB will be bound at vb_offset, so the offset has to be subtracted from the cursor to start at 0.
	local_vb_index := vb_index - vb_offset
	ib[ib_index+0] = u32(local_vb_index+0)
	ib[ib_index+1] = u32(local_vb_index+1)
	ib[ib_index+2] = u32(local_vb_index+2)
	ib[ib_index+3] = u32(local_vb_index+2)
	ib[ib_index+4] = u32(local_vb_index+3)
	ib[ib_index+5] = u32(local_vb_index+0)

	g_r2ds.vb_cursor += 4
	g_r2ds.ib_cursor += 6
}

r2d_flush :: proc(cb: ^rhi.Backend_Command_Buffer) {
	assert(g_r2ds != nil)
	assert(g_rhi != nil)

	frame_in_flight := g_rhi.frame_in_flight
	vb := &g_r2ds.vbs[frame_in_flight]
	ib := &g_r2ds.ibs[frame_in_flight]
	vb_offset := &g_r2ds.vb_offsets[frame_in_flight]
	ib_offset := &g_r2ds.ib_offsets[frame_in_flight]
	// NOTE: There should have already been a flush before going out of bounds.
	assert(ib_offset^ <= g_r2ds.ib_cursor)

	index_count := g_r2ds.ib_cursor - ib_offset^
	// Nothing was drawn after the last flush
	if index_count == 0 {
		return
	}

	main_window := platform.get_main_window()
	surface_key := rhi.get_surface_key_from_window(main_window)
	swapchain_images := rhi.get_swapchain_images(surface_key)
	swapchain_dims := &swapchain_images[0].dimensions

	rhi.cmd_bind_graphics_pipeline(cb, g_r2ds.pipeline)
	// X+right, Y+up, Z+intoscreen ortho matrix
	ortho_matrix := linalg.matrix_ortho3d_f32(0, f32(swapchain_dims.x), 0, f32(swapchain_dims.y), -1, 1, false)
	constants := Renderer2D_Push_Constants{
		view_matrix = ortho_matrix,
	}
	rhi.cmd_push_constants(cb, g_r2ds.pipeline_layout, {.Vertex}, &constants)
	rhi.cmd_bind_vertex_buffer(cb, vb^, 0, u32(vb_offset^ * size_of(Renderer2D_Vertex)))
	rhi.cmd_bind_index_buffer(cb, ib^, ib_offset^ * size_of(u32))
	rhi.cmd_draw_indexed(cb, index_count)

	vb_offset^ = g_r2ds.vb_cursor % R2D_MAX_VERTEX_COUNT
	ib_offset^ = g_r2ds.ib_cursor % R2D_MAX_INDEX_COUNT
	g_r2ds.vb_cursor = vb_offset^
	g_r2ds.ib_cursor = ib_offset^
}

r2d_print_state :: proc() {
	frame_in_flight := g_rhi.frame_in_flight

	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	w := strings.to_writer(&b)
	fmt.wprintln(w, "Renderer2D state:")
	fmt.wprintfln(w, "Frame in flight: %i", frame_in_flight)
	fmt.wprintfln(w, "VB-offset: %i", g_r2ds.vb_offsets[frame_in_flight])
	fmt.wprintfln(w, "VB-cursor: %i", g_r2ds.vb_cursor)
	fmt.wprintfln(w, "IB-offset: %i", g_r2ds.ib_offsets[frame_in_flight])
	fmt.wprintfln(w, "IB-cursor: %i", g_r2ds.ib_cursor)

	log.info(strings.to_string(b))
}

r2d_init :: proc() -> Result {
	g_r2ds = &g_renderer.renderer2d_state
	if r := r2d_init_rhi(); r != nil {
		core.error_log(r.?)
		return r.?
	}

	return nil
}

r2d_shutdown :: proc() {
	r2d_shutdown_rhi()
}

r2d_create_pipeline :: proc(render_pass: rhi.Backend_Render_Pass, color_attachment_format: rhi.Format) -> (pipeline: rhi.Backend_Pipeline, result: rhi.Result) {
	// TODO: Creating shaders and VIDs each time a new pipeline is needed is kinda wasteful

	// Create shaders
	vsh := rhi.create_vertex_shader(core.path_make_engine_shader_relative(R2D_SHADER_VERT)) or_return
	defer rhi.destroy_shader(&vsh)
	fsh := rhi.create_fragment_shader(core.path_make_engine_shader_relative(R2D_SHADER_FRAG)) or_return
	defer rhi.destroy_shader(&fsh)

	// Setup vertex input for the 2D ring buffer
	vertex_input_types := []rhi.Vertex_Input_Type_Desc{
		rhi.Vertex_Input_Type_Desc{type = Renderer2D_Vertex, rate = .Vertex},
	}
	vid := rhi.create_vertex_input_description(vertex_input_types, context.temp_allocator)

	// Create 2D renderer graphics pipeline
	pipeline_desc := rhi.Pipeline_Description{
		shader_stages = {
			rhi.Pipeline_Shader_Stage{type = .Vertex,   shader = &vsh.shader},
			rhi.Pipeline_Shader_Stage{type = .Fragment, shader = &fsh.shader},
		},
		vertex_input = vid,
		input_assembly = {
			topology = .Triangle_List,
		},
		color_attachments = {
			rhi.Pipeline_Attachment_Desc{format = color_attachment_format},
		},
		depth_stencil_attachment = rhi.Pipeline_Attachment_Desc{format = .D32FS8},
		blend_state = rhi.DEFAULT_BLEND_STATE,
	}
	pipeline = rhi.create_graphics_pipeline(pipeline_desc, render_pass, g_r2ds.pipeline_layout, "GPipeline_Renderer2D") or_return

	return
}

@(private)
r2d_init_rhi :: proc() -> rhi.Result {
	assert(g_r2ds != nil)

	main_window := platform.get_main_window()
	surface_key := rhi.get_surface_key_from_window(main_window)
	swapchain_format := rhi.get_swapchain_image_format(surface_key)

	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		vb_desc := rhi.Buffer_Desc{
			memory_flags = {.Device_Local, .Host_Coherent, .Host_Visible},
		}
		vb_name := fmt.tprintf("VB_R2D_Global-%i", i)
		ib_name := fmt.tprintf("IB_R2D_Global-%i", i)
		g_r2ds.vbs[i] = rhi.create_vertex_buffer_empty(vb_desc, Renderer2D_Vertex, R2D_MAX_VERTEX_COUNT, vb_name) or_return
		g_r2ds.ibs[i] = rhi.create_index_buffer_empty(vb_desc, u32, R2D_MAX_INDEX_COUNT, ib_name) or_return
		g_r2ds.vb_mapped[i] = rhi.cast_mapped_buffer_memory(Renderer2D_Vertex, g_r2ds.vbs[i].mapped_memory)
		g_r2ds.ib_mapped[i] = rhi.cast_mapped_buffer_memory(u32, g_r2ds.ibs[i].mapped_memory)
	}

	sampler_dsl_desc := rhi.Descriptor_Set_Layout_Description{
		bindings = {
			rhi.Descriptor_Set_Layout_Binding{
				binding = 0,
				count = 1,
				shader_stage = {.Fragment},
				type = .Combined_Image_Sampler,
			},
		},
	}
	g_r2ds.sampler_dsl = rhi.create_descriptor_set_layout(sampler_dsl_desc, "DSL_R2D_Sampler") or_return

	// Create pipeline layout
	layout := rhi.Pipeline_Layout_Description{
		descriptor_set_layouts = {
			&g_r2ds.sampler_dsl,
		},
		push_constants = {
			rhi.Push_Constant_Range{
				offset = 0,
				size = size_of(Renderer2D_Push_Constants),
				shader_stage = {.Vertex},
			},
		},
	}
	g_r2ds.pipeline_layout = rhi.create_pipeline_layout(layout) or_return
	g_r2ds.pipeline = r2d_create_pipeline(nil, swapchain_format) or_return

	// Descriptor pool for 2D renderer related resources
	descriptor_pool_desc := rhi.Descriptor_Pool_Desc{
		pool_sizes = {
			rhi.Descriptor_Pool_Size{
				type = .Combined_Image_Sampler,
				count = R2D_MAX_TEXTURE_DESCRIPTOR_SETS,
			},
		},
		max_sets = R2D_MAX_TEXTURE_DESCRIPTOR_SETS,
	}
	g_r2ds.descriptor_pool = rhi.create_descriptor_pool(descriptor_pool_desc, "DP_Renderer2D") or_return

	wt_dsl := rhi.Descriptor_Set_Desc{
		descriptors = {
			create_combined_texture_sampler_descriptor_desc(&g_renderer.white_texture, 0),
		},
		layout = g_r2ds.sampler_dsl,
	}
	g_r2ds.white_texture_descriptor_set = rhi.create_descriptor_set(g_r2ds.descriptor_pool, wt_dsl, "DS_R2D_WhiteTexture") or_return

	return nil
}

@(private)
r2d_shutdown_rhi :: proc() {
	assert(g_r2ds != nil)

	rhi.destroy_descriptor_pool(&g_r2ds.descriptor_pool)

	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		rhi.destroy_buffer(&g_r2ds.vbs[i])
		rhi.destroy_buffer(&g_r2ds.ibs[i])
	}

	rhi.destroy_descriptor_set_layout(&g_r2ds.sampler_dsl)

	rhi.destroy_graphics_pipeline(&g_r2ds.pipeline)
	rhi.destroy_pipeline_layout(&g_r2ds.pipeline_layout)
}

Renderer2D_Rect :: struct {
	x, y: f32,
	w, h: f32,
}

Renderer2D_Push_Constants :: struct {
	view_matrix: Matrix4,
}

Renderer2D_Vertex :: struct {
	color: Vec4,
	pos: Vec2,
	texcoord: Vec2,
}

Renderer2D_State :: struct {
	vbs: [MAX_FRAMES_IN_FLIGHT]rhi.Buffer,
	ibs: [MAX_FRAMES_IN_FLIGHT]rhi.Buffer,
	// Mapped ring buffers
	vb_mapped: [MAX_FRAMES_IN_FLIGHT][]Renderer2D_Vertex,
	ib_mapped: [MAX_FRAMES_IN_FLIGHT][]u32,
	// Buffer offsets to draw for each frame in flight (specified in n of elements)
	vb_offsets: [MAX_FRAMES_IN_FLIGHT]uint,
	ib_offsets: [MAX_FRAMES_IN_FLIGHT]uint,
	// Cursors for the current frame (start from 0 at the beginning of each frame, specified in n of elements)
	vb_cursor: uint,
	ib_cursor: uint,

	sampler_dsl: rhi.Backend_Descriptor_Set_Layout,
	white_texture_descriptor_set: rhi.Backend_Descriptor_Set,
	pipeline_layout: rhi.Backend_Pipeline_Layout,
	pipeline: rhi.Backend_Pipeline,
	descriptor_pool: rhi.Descriptor_Pool,
}

@(private)
g_r2ds: ^Renderer2D_State
