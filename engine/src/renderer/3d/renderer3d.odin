package sm_renderer_3d

import "core:log"
import "core:image/png"
import "core:slice"
import "core:math"
import "core:math/linalg"

import "sm:core"
import "sm:platform"
import "sm:rhi"

// TODO: Remove when ready
import vk "vendor:vulkan"

Error :: struct {
	message: string, // temp string
}
Result :: union { Error, rhi.RHI_Error }

QUAD_SHADER_VERT :: "3d/quad_vert.spv"
QUAD_SHADER_FRAG :: "3d/quad_frag.spv"

MAX_SAMPLERS :: 100

RTexture_2D :: struct {
	texture_2d: Texture_2D,
	// TODO: Make a global sampler cache
	sampler: RHI_Sampler,
	descriptor_set: RHI_DescriptorSet,
}

draw_full_screen_quad :: proc(cb: ^RHI_CommandBuffer, texture: RTexture_2D) {
	rhi.cmd_bind_graphics_pipeline(cb, g_r3d_state.quad_renderer_state.pipeline)
	rhi.cmd_bind_descriptor_set(cb, g_r3d_state.quad_renderer_state.pipeline_layout, texture.descriptor_set)
	rhi.cmd_bind_vertex_buffer(cb, g_r3d_state.quad_renderer_state.vb)
	rhi.cmd_draw(cb, len(g_quad_vb_data))
}

create_texture_2d :: proc(image_data: []byte, dimensions: [2]u32, format: rhi.Format, filter: rhi.Filter, pipeline_layout: rhi.RHI_PipelineLayout) -> (texture: RTexture_2D, result: Result) {
	rhi_result: RHI_Result
	texture.texture_2d, rhi_result = rhi.create_texture_2d(image_data, dimensions, format)
	if rhi_result != nil {
		result = rhi_result.(rhi.RHI_Error)
		return
	}

	// TODO: Make a global sampler cache
	texture.sampler, rhi_result = rhi.create_sampler(texture.texture_2d.mip_levels, filter)
	if rhi_result != nil {
		result = rhi_result.(rhi.RHI_Error)
		return
	}

	descriptor_set_desc := rhi.Descriptor_Set_Desc{
		descriptors = {
			rhi.Descriptor_Desc{
				binding = 0,
				count = 1,
				type = .COMBINED_IMAGE_SAMPLER,
				info = rhi.Descriptor_Texture_Info{
					texture = &texture.texture_2d.texture,
					sampler = &texture.sampler,
				},
			},
		},
		// TODO: This is painful that is has to be specified for the descriptor set 
		// - separate the descriptor set layout from the pipeline layout
		layout = pipeline_layout,
	}
	texture.descriptor_set, rhi_result = rhi.create_descriptor_set(g_r3d_state.descriptor_pool, descriptor_set_desc)
	if rhi_result != nil {
		result = rhi_result.(rhi.RHI_Error)
		return
	}

	return texture, nil
}

init :: proc() -> Result {
	if r := init_rhi(); r != nil {
		return r.(rhi.RHI_Error)
	}

	return nil
}

shutdown :: proc() {
	shutdown_rhi()
	delete(g_r3d_state.main_render_pass.framebuffers)
}

draw :: proc(user_data: rawptr = nil) {
	maybe_image_index, acquire_res := rhi.wait_and_acquire_image()
	if acquire_res != nil {
		rhi.handle_error(&acquire_res.(rhi.RHI_Error))
		return
	}
	if maybe_image_index == nil {
		// No image available
		return
	}
	image_index := maybe_image_index.(uint)

	fb := &g_r3d_state.main_render_pass.framebuffers[image_index]
	rp := &g_r3d_state.main_render_pass.render_pass

	frame_in_flight := rhi.get_frame_in_flight()
	cb := &g_r3d_state.cmd_buffers[frame_in_flight]

	// BASE PASS
	{
		rhi.begin_command_buffer(cb)
		
		rhi.cmd_begin_render_pass(cb, rp^, fb^)
		
		rhi.cmd_set_viewport(cb, {0, 0}, {cast(f32) fb.dimensions.x, cast(f32) fb.dimensions.y}, 0, 1)
		rhi.cmd_set_scissor(cb, {0, 0}, fb.dimensions)
		
		if g_r3d_state.draw_proc != nil {
			g_r3d_state.draw_proc(user_data, cb, fb.dimensions)
		}
	
		rhi.cmd_end_render_pass(cb)
	
		rhi.end_command_buffer(cb)
	
		// sync := rhi.Vk_Queue_Submit_Sync{
		// 	signal = g_r3d_state.base_to_debug_semaphores[frame_in_flight],
		// }
		rhi.queue_submit_for_drawing(cb/*, sync*/)
	}

	// DEBUG PASS
	// debug_update(&g_r3d_state.debug_renderer_state)
	// sync := rhi.Vk_Queue_Submit_Sync{
	// 	wait = g_r3d_state.base_to_debug_semaphores[frame_in_flight],
	// }
	// debug_submit_commands(&g_r3d_state.debug_renderer_state, fb^, rp^, sync)

	if r := rhi.present(image_index); r != nil {
		rhi.handle_error(&r.(rhi.RHI_Error))
		return
	}
}

access_state :: proc() -> ^Renderer3D_Public_State {
	return &g_r3d_state.public_state
}

// TODO: ok get rid of this private shit
get_main_render_pass :: proc() -> ^Renderer3D_RenderPass {
	return &g_r3d_state.main_render_pass
}

@(private)
init_rhi :: proc() -> RHI_Result {
	core.broadcaster_add_callback(&rhi.callbacks.on_recreate_swapchain_broadcaster, on_recreate_swapchain)

	// TODO: Presenting & swapchain framebuffers should be separated from the actual renderer
	// Get swapchain stuff
	main_window := platform.get_main_window()
	surface_index := rhi.get_surface_index_from_window(main_window)
	swapchain_format := rhi.get_swapchain_image_format(surface_index)
	swapchain_images := rhi.get_swapchain_images(surface_index)
	assert(len(swapchain_images) > 0)
	swapchain_dims := swapchain_images[0].dimensions

	// Make render pass for swapchain images
	g_r3d_state.main_render_pass.render_pass = rhi.create_render_pass(swapchain_format) or_return

	// Create global depth buffer
	g_r3d_state.depth_texture = rhi.create_depth_texture(swapchain_dims, .D24S8) or_return

	// Make framebuffers
	fb_textures := make([]^Texture_2D, len(swapchain_images), context.temp_allocator)
	for &im, i in swapchain_images {
		fb_textures[i] = &im
	}
	create_framebuffers(fb_textures, &g_r3d_state.depth_texture) or_return

	// Create a global descriptor pool
	pool_desc := rhi.Descriptor_Pool_Desc{
		pool_sizes = {
			rhi.Descriptor_Pool_Size{
				type = .COMBINED_IMAGE_SAMPLER,
				count = MAX_SAMPLERS,
			},
		},
		max_sets = MAX_SAMPLERS,
	}
	g_r3d_state.descriptor_pool = rhi.create_descriptor_pool(pool_desc) or_return

	debug_init(&g_r3d_state.debug_renderer_state, g_r3d_state.main_render_pass.render_pass, swapchain_dims) or_return

	// Initialize full screen quad rendering
	{
		// Create shaders
		vsh := rhi.create_vertex_shader(core.path_make_engine_shader_relative(QUAD_SHADER_VERT)) or_return
		defer rhi.destroy_shader(&vsh)
	
		fsh := rhi.create_fragment_shader(core.path_make_engine_shader_relative(QUAD_SHADER_FRAG)) or_return
		defer rhi.destroy_shader(&fsh)
	
		// Create pipeline layout
		layout := rhi.Pipeline_Layout_Description{
			bindings = {
				rhi.Descriptor_Set_Layout_Binding{
					binding = 0,
					type = .COMBINED_IMAGE_SAMPLER,
					count = 1,
					shader_stage = {.FRAGMENT},
				},
			},
		}
		g_r3d_state.quad_renderer_state.pipeline_layout = rhi.create_pipeline_layout(layout) or_return
	
		// Setup vertex input
		vertex_input_types := []rhi.Vertex_Input_Type_Desc{
			rhi.Vertex_Input_Type_Desc{type = Quad_Vertex, rate = .VERTEX},
		}
		vid := rhi.create_vertex_input_description(vertex_input_types, context.temp_allocator)
		log.debug("\nQUAD VID:", vid, "\n")
	
		// Create quad graphics pipeline
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
				depth_compare_op = .ALWAYS,
			},
			viewport_dims = swapchain_dims,
		}
		g_r3d_state.quad_renderer_state.pipeline = rhi.create_graphics_pipeline(pipeline_desc, g_r3d_state.main_render_pass.render_pass, g_r3d_state.quad_renderer_state.pipeline_layout) or_return

		// Create a static quad vertex buffer
		quad_vb_desc := rhi.Buffer_Desc{
			memory_flags = {.DEVICE_LOCAL},
		}
		g_r3d_state.quad_renderer_state.vb = rhi.create_vertex_buffer(quad_vb_desc, g_quad_vb_data[:]) or_return

		// Create a no-mipmap sampler for a "pixel-perfect" quad
		g_r3d_state.quad_renderer_state.sampler = rhi.create_sampler(1, .NEAREST) or_return
	}

	// Allocate global cmd buffers
	g_r3d_state.cmd_buffers = rhi.allocate_command_buffers(MAX_FRAMES_IN_FLIGHT) or_return

	g_r3d_state.base_to_debug_semaphores = rhi.create_semaphores() or_return

	return nil
}

@(private)
shutdown_rhi :: proc() {
	rhi.wait_for_device()

	debug_shutdown(&g_r3d_state.debug_renderer_state)

	destroy_framebuffers()
	rhi.destroy_texture(&g_r3d_state.depth_texture)
	rhi.destroy_render_pass(&g_r3d_state.main_render_pass.render_pass)
}

@(private)
create_framebuffers :: proc(images: []^Texture_2D, depth: ^Texture_2D) -> rhi.RHI_Result {
	for &im, i in images {
		attachments := [2]^Texture_2D{im, depth}
		fb := rhi.create_framebuffer(g_r3d_state.main_render_pass.render_pass, attachments[:]) or_return
		append(&g_r3d_state.main_render_pass.framebuffers, fb)
	}
	return nil
}

@(private)
on_recreate_swapchain :: proc(args: rhi.Args_Recreate_Swapchain) {
	r: rhi.RHI_Result
	destroy_framebuffers()
	rhi.destroy_texture(&g_r3d_state.depth_texture)
	swapchain_images := rhi.get_swapchain_images(args.surface_index)
	g_r3d_state.depth_texture, r = rhi.create_depth_texture(args.new_dimensions, .D24S8)
	if r != nil {
		panic("Failed to recreate the depth texture.")
	}
	fb_textures := make([]^Texture_2D, len(swapchain_images), context.temp_allocator)
	for &im, i in swapchain_images {
		fb_textures[i] = &im
	}
	create_framebuffers(fb_textures, &g_r3d_state.depth_texture)
}

@(private)
destroy_framebuffers :: proc() {
	for &fb in g_r3d_state.main_render_pass.framebuffers {
		rhi.destroy_framebuffer(&fb)
	}
	clear(&g_r3d_state.main_render_pass.framebuffers)
}

View_Info :: struct {
	view_projection_matrix: Matrix4,
	view_origin: Vec3,
}

Quad_Vertex :: struct {
	position: Vec2,
	tex_coord: Vec2,
}

// Quad vertices specified in clip-space
@(private)
g_quad_vb_data := [6]Quad_Vertex{
	{{-1,-1}, {0,0}},
	{{ 1, 1}, {1,1}},
	{{-1, 1}, {0,1}},
	{{-1,-1}, {0,0}},
	{{ 1,-1}, {1,0}},
	{{ 1, 1}, {1,1}},
}

Quad_Renderer_State :: struct {
	pipeline: RHI_Pipeline,
	pipeline_layout: RHI_PipelineLayout,
	vb: Vertex_Buffer,
	sampler: RHI_Sampler,
}

Renderer3D_RenderPass :: struct {
	framebuffers: [dynamic]Framebuffer,
	render_pass: RHI_RenderPass,
}

Renderer3D_Public_State :: struct {
	view_info: View_Info,
	draw_proc: proc(user_data: rawptr, cb: ^RHI_CommandBuffer, fb_dims: [2]u32),
}

Renderer3D_State :: struct {
	using public_state: Renderer3D_Public_State,
	debug_renderer_state: Debug_Renderer_State,
	quad_renderer_state: Quad_Renderer_State,
	main_render_pass: Renderer3D_RenderPass,
	depth_texture: Texture_2D,

	descriptor_pool: RHI_DescriptorPool,
	cmd_buffers: [MAX_FRAMES_IN_FLIGHT]RHI_CommandBuffer,

	base_to_debug_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
}
@(private)
g_r3d_state: Renderer3D_State
