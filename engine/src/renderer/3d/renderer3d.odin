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

MESH_SHADER_VERT :: "3d/basic_vert.spv"
MESH_SHADER_FRAG :: "3d/basic_frag.spv"

MAX_SAMPLERS :: 100
MAX_SCENE_VIEWS :: 10
MAX_MODELS :: 1000

// SCENE ----------------------------------------------------------------------------------------------------

View_Info :: struct {
	view_projection_matrix: Matrix4,
	view_origin: Vec3,
}

Scene_View_Uniforms :: struct {
	vp_matrix: Matrix4,
	view_origin: Vec3,
}

RScene :: struct {
	view_info: View_Info,
	uniforms: [MAX_FRAMES_IN_FLIGHT]rhi.Uniform_Buffer,
	descriptor_sets: [MAX_FRAMES_IN_FLIGHT]RHI_DescriptorSet,
}

create_scene :: proc() -> (scene: RScene, result: RHI_Result) {
	// Create scene uniform buffers
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		scene.uniforms[i] = rhi.create_uniform_buffer(Scene_View_Uniforms) or_return
		
		// Create buffer descriptors
		scene_set_desc := rhi.Descriptor_Set_Desc{
			layout = g_r3d_state.scene_descriptor_set_layout,
			descriptors = {
				rhi.Descriptor_Desc{
					type = .UNIFORM_BUFFER,
					binding = 0,
					count = 1,
					info = rhi.Descriptor_Buffer_Info{
						buffer = &scene.uniforms[i].buffer,
						size = size_of(Scene_View_Uniforms),
						offset = 0,
					},
				},
			},
		}
		scene.descriptor_sets[i] = rhi.create_descriptor_set(g_r3d_state.descriptor_pool, scene_set_desc) or_return
	}

	return
}

destroy_scene :: proc(scene: ^RScene) {
	if scene == nil {
		return
	}

	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		rhi.destroy_buffer(&scene.uniforms[i])
		scene.uniforms[i] = {}
		// TODO: Maybe Release back unused descriptor sets to the pool
		scene.descriptor_sets[i] = 0
	}
}

get_scene_uniforms :: proc(scene: ^RScene) -> ^Scene_View_Uniforms {
	assert(scene != nil)
	frame_in_flight := rhi.get_frame_in_flight()
	ub := &scene.uniforms[frame_in_flight]
	return rhi.cast_mapped_buffer_memory_single(Scene_View_Uniforms, ub.mapped_memory)
}

update_scene_uniforms :: proc(scene: ^RScene) {
	uniforms := get_scene_uniforms(scene)
	uniforms.vp_matrix = scene.view_info.view_projection_matrix
	uniforms.view_origin = scene.view_info.view_origin
}

bind_scene :: proc(cb: ^RHI_CommandBuffer) {
	assert(cb != nil)

	frame_in_flight := rhi.get_frame_in_flight()
	scene_ds := &g_r3d_state.scene.descriptor_sets[frame_in_flight]
	
	rhi.cmd_bind_graphics_pipeline(cb, g_r3d_state.mesh_renderer_state.pipeline)
	rhi.cmd_bind_descriptor_set(cb, g_r3d_state.mesh_renderer_state.pipeline_layout, scene_ds^, 0)
}

// TEXTURES ---------------------------------------------------------------------------------------------------

RTexture_2D :: struct {
	texture_2d: Texture_2D,
	// TODO: Make a global sampler cache
	sampler: RHI_Sampler,
	descriptor_set: RHI_DescriptorSet,
}

create_texture_2d :: proc(image_data: []byte, dimensions: [2]u32, format: rhi.Format, filter: rhi.Filter, descriptor_set_layout: rhi.RHI_DescriptorSetLayout) -> (texture: RTexture_2D, result: RHI_Result) {
	texture.texture_2d = rhi.create_texture_2d(image_data, dimensions, format) or_return

	// TODO: Make a global sampler cache
	texture.sampler = rhi.create_sampler(texture.texture_2d.mip_levels, filter) or_return

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
		layout = descriptor_set_layout,
	}
	texture.descriptor_set = rhi.create_descriptor_set(g_r3d_state.descriptor_pool, descriptor_set_desc) or_return

	return
}

destroy_texture_2d :: proc(tex: ^RTexture_2D) {
	rhi.destroy_texture(&tex.texture_2d)
	rhi.destroy_sampler(&tex.sampler)
}

// MESHES & MODELS ---------------------------------------------------------------------------------------------

Mesh_Renderer_State :: struct {
	pipeline: rhi.RHI_Pipeline,
	pipeline_layout: rhi.RHI_PipelineLayout,
	model_descriptor_set_layout: rhi.RHI_DescriptorSetLayout,
	material_descriptor_set_layout: rhi.RHI_DescriptorSetLayout,
}

Mesh_Vertex :: struct {
	position: Vec3,
	normal: Vec3,
	tex_coord: Vec2,
}

RMesh :: struct {
	vertex_buffer: Vertex_Buffer,
	index_buffer: Index_Buffer,
}

// Mesh vertices format must adhere to the ones provided in pipelines that will use the created mesh
create_mesh :: proc(vertices: []$V, indices: []u32) -> (mesh: RMesh, result: RHI_Result) {
	// Create the Vertex Buffer
	vb_desc := rhi.Buffer_Desc{
		memory_flags = {.DEVICE_LOCAL},
	}
	mesh.vertex_buffer = rhi.create_vertex_buffer(vb_desc, vertices) or_return

	// Create the Index Buffer
	ib_desc := rhi.Buffer_Desc{
		memory_flags = {.DEVICE_LOCAL},
	}
	mesh.index_buffer = rhi.create_index_buffer(indices) or_return

	return
}

destroy_mesh :: proc(mesh: ^RMesh) {
	rhi.destroy_buffer(&mesh.vertex_buffer)
	rhi.destroy_buffer(&mesh.index_buffer)
}

Model_Uniforms :: struct {
	model_matrix: Matrix4,
	inverse_transpose_matrix: Matrix4,
	mvp_matrix: Matrix4,
}

Model_Data :: struct {
	location: Vec3,
	rotation: Vec3,
	scale: Vec3,
}

RModel :: struct {
	mesh: ^RMesh,
	data: Model_Data,
	uniforms: [rhi.MAX_FRAMES_IN_FLIGHT]rhi.Uniform_Buffer,
	descriptor_sets: [rhi.MAX_FRAMES_IN_FLIGHT]rhi.RHI_DescriptorSet,
}

create_model :: proc(mesh: ^RMesh) -> (model: RModel, result: RHI_Result) {
	// Create buffers and descriptor sets
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		model.uniforms[i] = rhi.create_uniform_buffer(Model_Uniforms) or_return
		set_desc := rhi.Descriptor_Set_Desc{
			descriptors = {
				rhi.Descriptor_Desc{
					type = .UNIFORM_BUFFER,
					binding = 0,
					count = 1,
					info = rhi.Descriptor_Buffer_Info{
						buffer = &model.uniforms[i].buffer,
						size = size_of(Model_Uniforms),
						offset = 0,
					},
				},
			},
			layout = g_r3d_state.mesh_renderer_state.model_descriptor_set_layout,
		}
		model.descriptor_sets[i] = rhi.create_descriptor_set(g_r3d_state.descriptor_pool, set_desc) or_return
	}

	// Assign the mesh
	model.mesh = mesh

	// Make sure the default scale is 1 and not 0.
	model.data.scale = core.VEC3_ONE

	return
}

destroy_model :: proc(model: ^RModel) {
	for i in 0..<rhi.MAX_FRAMES_IN_FLIGHT {
		rhi.destroy_buffer(&model.uniforms[i])
	}
	// TODO: Handle descriptor sets' release
}

// Requires a scene with the current frame data filled in, otherwise the data from the previous frame will be used
update_model_uniforms :: proc(scene: ^RScene, model: ^RModel) {
	assert(scene != nil)
	assert(model != nil)

	frame_in_flight := rhi.get_frame_in_flight()
	ub := &model.uniforms[frame_in_flight]
	uniforms := rhi.cast_mapped_buffer_memory_single(Model_Uniforms, ub.mapped_memory)

	scale_matrix := linalg.matrix4_scale_f32(model.data.scale)
	rot := model.data.rotation
	rotation_matrix := linalg.matrix4_from_euler_angles_zxy_f32(rot.x, rot.y, rot.z)
	translation_matrix := linalg.matrix4_translate_f32(model.data.location)

	uniforms.model_matrix = translation_matrix * rotation_matrix * scale_matrix
	if model.data.scale.x == model.data.scale.y && model.data.scale.x == model.data.scale.z {
		uniforms.inverse_transpose_matrix = uniforms.model_matrix
	} else {
		model_mat_3x3 := cast(Matrix3)uniforms.model_matrix
		uniforms.inverse_transpose_matrix = cast(Matrix4)linalg.matrix3_inverse_transpose_f32(model_mat_3x3)
	}
	uniforms.mvp_matrix = scene.view_info.view_projection_matrix * uniforms.model_matrix
}

draw_model :: proc(cb: ^RHI_CommandBuffer, model: ^RModel, texture: ^RTexture_2D) {
	assert(cb != nil)
	assert(model != nil)
	assert(model.mesh != nil)
	// Scene must be setup to render meshes
	assert(g_r3d_state.scene != nil)

	frame_in_flight := rhi.get_frame_in_flight()

	rhi.cmd_bind_vertex_buffer(cb, model.mesh.vertex_buffer)
	rhi.cmd_bind_index_buffer(cb, model.mesh.index_buffer)
	rhi.cmd_bind_descriptor_set(cb, g_r3d_state.mesh_renderer_state.pipeline_layout, model.descriptor_sets[frame_in_flight], 1)
	// TODO: What if there is no texture
	rhi.cmd_bind_descriptor_set(cb, g_r3d_state.mesh_renderer_state.pipeline_layout, texture.descriptor_set, 2)

	rhi.cmd_draw_indexed(cb, model.mesh.index_buffer.index_count)
}

// FULL-SCREEN QUAD RENDERING -------------------------------------------------------------------------------------------

Quad_Renderer_State :: struct {
	pipeline: RHI_Pipeline,
	pipeline_layout: RHI_PipelineLayout,
	descriptor_set_layout: RHI_DescriptorSetLayout,
	vb: Vertex_Buffer,
	sampler: RHI_Sampler,
}

Quad_Vertex :: struct {
	position: Vec2,
	tex_coord: Vec2,
}

// TODO: Hard-code this into the shader
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

draw_full_screen_quad :: proc(cb: ^RHI_CommandBuffer, texture: RTexture_2D) {
	rhi.cmd_bind_graphics_pipeline(cb, g_r3d_state.quad_renderer_state.pipeline)
	rhi.cmd_bind_descriptor_set(cb, g_r3d_state.quad_renderer_state.pipeline_layout, texture.descriptor_set)
	rhi.cmd_bind_vertex_buffer(cb, g_r3d_state.quad_renderer_state.vb)
	rhi.cmd_draw(cb, len(g_quad_vb_data))
}

// RENDERER -----------------------------------------------------------------------------------------------------------

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

begin_frame :: proc() -> (cb: ^RHI_CommandBuffer, image_index: uint) {
	r: RHI_Result
	maybe_image_index: Maybe(uint)
	if maybe_image_index, r = rhi.wait_and_acquire_image(); r != nil {
		core.error_log(r.?)
		return
	}
	if maybe_image_index == nil {
		// No image available
		return
	}
	image_index = maybe_image_index.(uint)

	frame_in_flight := rhi.get_frame_in_flight()
	cb = &g_r3d_state.cmd_buffers[frame_in_flight]

	rhi.begin_command_buffer(cb)

	return
}

end_frame :: proc(cb: ^RHI_CommandBuffer, image_index: uint) {
	rhi.end_command_buffer(cb)

	rhi.queue_submit_for_drawing(cb)

	if r := rhi.present(image_index); r != nil {
		core.error_log(r.?)
		return
	}
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
	render_pass_desc := rhi.Render_Pass_Desc{
		attachments = {
			// Color
			rhi.Attachment_Desc{
				usage = .COLOR,
				format = swapchain_format,
				load_op = .CLEAR,
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
			// Depth-stencil
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
	g_r3d_state.main_render_pass.render_pass = rhi.create_render_pass(render_pass_desc) or_return

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
			rhi.Descriptor_Pool_Size{
				type = .UNIFORM_BUFFER,
				count = (MAX_SCENE_VIEWS + MAX_MODELS) * MAX_FRAMES_IN_FLIGHT,
			},
		},
		max_sets = MAX_SAMPLERS + (MAX_SCENE_VIEWS + MAX_MODELS) * MAX_FRAMES_IN_FLIGHT,
	}
	g_r3d_state.descriptor_pool = rhi.create_descriptor_pool(pool_desc) or_return

	debug_init(&g_r3d_state.debug_renderer_state, swapchain_format, swapchain_dims) or_return

	// Initialize full screen quad rendering
	{
		// Create shaders
		vsh := rhi.create_vertex_shader(core.path_make_engine_shader_relative(QUAD_SHADER_VERT)) or_return
		defer rhi.destroy_shader(&vsh)
	
		fsh := rhi.create_fragment_shader(core.path_make_engine_shader_relative(QUAD_SHADER_FRAG)) or_return
		defer rhi.destroy_shader(&fsh)

		// Create descriptor set layout
		descriptor_set_layout_desc := rhi.Descriptor_Set_Layout_Description{
			bindings = {
				rhi.Descriptor_Set_Layout_Binding{
					binding = 0,
					type = .COMBINED_IMAGE_SAMPLER,
					count = 1,
					shader_stage = {.FRAGMENT},
				},
			},
		}
		g_r3d_state.quad_renderer_state.descriptor_set_layout = rhi.create_descriptor_set_layout(descriptor_set_layout_desc) or_return
	
		// Create pipeline layout
		pipeline_layout_desc := rhi.Pipeline_Layout_Description{
			descriptor_set_layouts = {
				&g_r3d_state.quad_renderer_state.descriptor_set_layout,
			},
		}
		g_r3d_state.quad_renderer_state.pipeline_layout = rhi.create_pipeline_layout(pipeline_layout_desc) or_return
	
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
	
	// Scene objects setup -----------------------------------------------------------------------------------------

	// Make a descriptor set layout for scene uniforms
	scene_layout_desc := rhi.Descriptor_Set_Layout_Description{
		bindings = {
			// Scene constants (per frame)
			rhi.Descriptor_Set_Layout_Binding{
				binding = 0,
				count = 1,
				shader_stage = {.VERTEX, .FRAGMENT},
				type = .UNIFORM_BUFFER,
			},
		},
	}
	g_r3d_state.scene_descriptor_set_layout = rhi.create_descriptor_set_layout(scene_layout_desc) or_return

	// SETUP MESH RENDERING ---------------------------------------------------------------------------------------------------------------------
	{
		// Create basic 3D shaders
		basic_vsh := rhi.create_vertex_shader(core.path_make_engine_shader_relative(MESH_SHADER_VERT)) or_return
		defer rhi.destroy_shader(&basic_vsh)
		basic_fsh := rhi.create_vertex_shader(core.path_make_engine_shader_relative(MESH_SHADER_FRAG)) or_return
		defer rhi.destroy_shader(&basic_fsh)
	
		dsl_desc: rhi.Descriptor_Set_Layout_Description

		// Make a descriptor set layout for model uniforms
		dsl_desc = rhi.Descriptor_Set_Layout_Description{
			bindings = {
				// Model constants (per draw call)
				rhi.Descriptor_Set_Layout_Binding{
					binding = 0,
					count = 1,
					shader_stage = {.VERTEX, .FRAGMENT},
					type = .UNIFORM_BUFFER,
				},
			},
		}
		g_r3d_state.mesh_renderer_state.model_descriptor_set_layout = rhi.create_descriptor_set_layout(dsl_desc) or_return
	
		// Make a descriptor set layout for mesh materials
		dsl_desc = rhi.Descriptor_Set_Layout_Description{
			bindings = {
				// Texture sampler
				rhi.Descriptor_Set_Layout_Binding{
					binding = 0,
					count = 1,
					shader_stage = {.FRAGMENT},
					type = .COMBINED_IMAGE_SAMPLER,
				},
			},
		}
		g_r3d_state.mesh_renderer_state.material_descriptor_set_layout = rhi.create_descriptor_set_layout(dsl_desc) or_return
	
		// Make a pipeline layout for mesh rendering
		test_pipeline_layout_desc := rhi.Pipeline_Layout_Description{
			descriptor_set_layouts = {
				&g_r3d_state.scene_descriptor_set_layout,
				&g_r3d_state.mesh_renderer_state.model_descriptor_set_layout,
				&g_r3d_state.mesh_renderer_state.material_descriptor_set_layout,
			},
		}
		g_r3d_state.mesh_renderer_state.pipeline_layout = rhi.create_pipeline_layout(test_pipeline_layout_desc) or_return
	
		// Create the pipeline for displaying the test mesh
		mesh_pipeline_desc := rhi.Pipeline_Description{
			vertex_input = rhi.create_vertex_input_description({
				rhi.Vertex_Input_Type_Desc{rate = .VERTEX, type = Mesh_Vertex},
			}, context.temp_allocator),
			input_assembly = {topology = .TRIANGLE_LIST},
			depth_stencil = {
				depth_test = true,
				depth_write = true,
				depth_compare_op = .LESS_OR_EQUAL,
			},
			shader_stages = {
				{type = .VERTEX,   shader = &basic_vsh.shader},
				{type = .FRAGMENT, shader = &basic_fsh.shader},
			},
		}
		g_r3d_state.mesh_renderer_state.pipeline = rhi.create_graphics_pipeline(mesh_pipeline_desc, g_r3d_state.main_render_pass.render_pass, g_r3d_state.mesh_renderer_state.pipeline_layout) or_return
	}

	// Allocate global cmd buffers
	g_r3d_state.cmd_buffers = rhi.allocate_command_buffers(MAX_FRAMES_IN_FLIGHT) or_return

	g_r3d_state.base_to_debug_semaphores = rhi.create_semaphores() or_return

	return nil
}

@(private)
shutdown_rhi :: proc() {
	rhi.wait_for_device()

	// Destroy mesh rendering
	rhi.destroy_graphics_pipeline(&g_r3d_state.mesh_renderer_state.pipeline)
	rhi.destroy_pipeline_layout(&g_r3d_state.mesh_renderer_state.pipeline_layout)
	rhi.destroy_descriptor_set_layout(&g_r3d_state.mesh_renderer_state.material_descriptor_set_layout)
	rhi.destroy_descriptor_set_layout(&g_r3d_state.mesh_renderer_state.model_descriptor_set_layout)
	rhi.destroy_descriptor_set_layout(&g_r3d_state.scene_descriptor_set_layout)

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

Renderer3D_RenderPass :: struct {
	framebuffers: [dynamic]Framebuffer,
	render_pass: RHI_RenderPass,
}

Renderer3D_State :: struct {
	debug_renderer_state: Debug_Renderer_State,
	quad_renderer_state: Quad_Renderer_State,
	mesh_renderer_state: Mesh_Renderer_State,

	scene_descriptor_set_layout: rhi.RHI_DescriptorSetLayout,
	scene: ^RScene,

	main_render_pass: Renderer3D_RenderPass,
	depth_texture: Texture_2D,

	descriptor_pool: RHI_DescriptorPool,
	cmd_buffers: [MAX_FRAMES_IN_FLIGHT]RHI_CommandBuffer,

	base_to_debug_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
}
// TODO: Would be better if this was passed around as a context instead of a global variable
g_r3d_state: Renderer3D_State
