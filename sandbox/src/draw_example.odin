package spelmotor_sandbox

import "core:image/png"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "core:time"
import "vendor:cgltf"

import "sm:core"
import "sm:platform"
import "sm:rhi"

De_Rendering_Data :: struct {
	render_pass: rhi.RHI_RenderPass,
	pipeline: rhi.RHI_Pipeline,
	pipeline_layout: rhi.RHI_PipelineLayout,
	framebuffers: [dynamic]rhi.Framebuffer,
	depth_texture: rhi.Texture_2D,
	mesh_texture: rhi.Texture_2D,
	mesh_tex_sampler: rhi.RHI_Sampler,
	vertex_buffer: rhi.Vertex_Buffer,
	index_buffer: rhi.Index_Buffer,
	uniform_buffers: [rhi.MAX_FRAMES_IN_FLIGHT]rhi.Uniform_Buffer,
	descriptor_pool: rhi.RHI_DescriptorPool,
	descriptor_sets: [rhi.MAX_FRAMES_IN_FLIGHT]rhi.RHI_DescriptorSet,
	cmd_buffers: [rhi.MAX_FRAMES_IN_FLIGHT]rhi.RHI_CommandBuffer,
	frame_number: uint,
	uniforms: Uniforms,
}
de_rendering_data: De_Rendering_Data

Vertex :: struct {
	position: Vec3,
	color: Vec3,
	tex_coord: Vec2,
}

Uniforms :: struct {
	mvp: Matrix4,
}

de_load_model :: proc(path: string) -> (vertices: []Vertex, indices: []u32, ok: bool) {
	ok = false

	options := cgltf.options{}
	c_path := strings.clone_to_cstring(path, context.temp_allocator)
	data, r := cgltf.parse_file(options, c_path)
	if r != .success {
		return
	}

	if r = cgltf.load_buffers(options, data, c_path); r !=.success {
		return
	}

	when ODIN_DEBUG {
		if r = cgltf.validate(data); r !=.success {
			return
		}
	}

	if len(data.meshes) != 1 {
		return
	}

	mesh := &data.meshes[0]
	if len(mesh.primitives) != 1 {
		return
	}

	primitive := &mesh.primitives[0]
	if primitive.indices.count < 1 {
		return
	}

	indices = make([]u32, primitive.indices.count)
	defer if !ok do delete(indices)
	for i in 0..<len(indices) {
		indices[i] = cast(u32) cgltf.accessor_read_index(primitive.indices, cast(uint) i)
	}

	for attribute in primitive.attributes {
		// Find position
		#partial switch attribute.type {
		case .position:
			if vertices == nil {
				vertices = make([]Vertex, attribute.data.count)
			}
			for i in 0..<len(vertices) {
				vertex := &vertices[i]
				if !cgltf.accessor_read_float(attribute.data, cast(uint) i, &vertex.position[0], len(vertex.position)) {
					log.warn("Failed to read the position of vertex", i, "from the model.")
				}
			}
		case .texcoord:
			if vertices == nil {
				vertices = make([]Vertex, attribute.data.count)
			}
			for i in 0..<len(vertices) {
				vertex := &vertices[i]
				if !cgltf.accessor_read_float(attribute.data, cast(uint) i, &vertex.tex_coord[0], len(vertex.tex_coord)) {
					log.warn("Failed to read the tex coord of vertex", i, "from the model.")
				}
			}
		}
	}
	defer if !ok && vertices != nil do delete(vertices)

	cgltf.free(data)

	ok = true
	return
}

de_free_model :: proc(vertices: []Vertex, indices: []u32) {
	delete(vertices)
	delete(indices)
}

de_init_rhi :: proc(main_window: platform.Window_Handle, vertices: []Vertex, indices: []u32, img_pixels: []byte, img_dimensions: [2]u32) -> rhi.RHI_Result {
	core.broadcaster_add_callback(&rhi.callbacks.on_recreate_swapchain_broadcaster, de_on_recreate_swapchain)

	surface_index := rhi.get_surface_index_from_window(main_window)
	swapchain_format := rhi.get_swapchain_image_format(surface_index)
	swapchain_images := rhi.get_swapchain_images(surface_index)
	assert(len(swapchain_images) > 0)
	swapchain_dims := swapchain_images[0].dimensions

	vsh := rhi.create_vertex_shader(core.path_make_engine_shader_relative("test_vert.spv")) or_return
	defer rhi.destroy_shader(&vsh)

	fsh := rhi.create_fragment_shader(core.path_make_engine_shader_relative("test_frag.spv")) or_return
	defer rhi.destroy_shader(&fsh)

	de_rendering_data.render_pass =  rhi.create_render_pass(swapchain_format) or_return

	layout_desc := rhi.Pipeline_Layout_Description{
		bindings = {
			rhi.Descriptor_Set_Layout_Binding{
				binding = 0,
				type = .UNIFORM_BUFFER,
				shader_stage = {.VERTEX},
				count = 1,
			},
			rhi.Descriptor_Set_Layout_Binding{
				binding = 1,
				type = .COMBINED_IMAGE_SAMPLER,
				shader_stage = {.FRAGMENT},
				count = 1,
			},
		},
	}
	de_rendering_data.pipeline_layout = rhi.create_pipeline_layout(layout_desc) or_return
	vertex_input_types := []rhi.Vertex_Input_Type_Desc{
		rhi.Vertex_Input_Type_Desc{type = Vertex, rate = .VERTEX},
	}
	vid := rhi.create_vertex_input_description(vertex_input_types, context.temp_allocator)
	pipeline_desc := rhi.Pipeline_Description{
		shader_stages = {
			rhi.Pipeline_Shader_Stage{
				type = .VERTEX,
				shader = &vsh.shader,
			},
			rhi.Pipeline_Shader_Stage{
				type = .FRAGMENT,
				shader = &fsh.shader,
			},
		},
		vertex_input = vid,
		depth_stencil = {
			depth_compare_op = .LESS,
		},
		viewport_dims = swapchain_dims,
	}
	de_rendering_data.pipeline = rhi.create_graphics_pipeline(pipeline_desc, de_rendering_data.render_pass, de_rendering_data.pipeline_layout) or_return

	de_rendering_data.depth_texture = rhi.create_depth_texture(swapchain_dims, .D24S8) or_return

	de_create_framebuffers(swapchain_images, &de_rendering_data.depth_texture) or_return

	de_rendering_data.mesh_texture = rhi.create_texture_2d(img_pixels, img_dimensions) or_return
	de_rendering_data.mesh_tex_sampler = rhi.create_sampler(de_rendering_data.mesh_texture.mip_levels) or_return

	vb_desc := rhi.Buffer_Desc{memory_flags = {.DEVICE_LOCAL}}
	de_rendering_data.vertex_buffer = rhi.create_vertex_buffer(vb_desc, vertices) or_return
	de_rendering_data.index_buffer = rhi.create_index_buffer(indices) or_return
	for i in 0..<rhi.MAX_FRAMES_IN_FLIGHT {
		de_rendering_data.uniform_buffers[i] = rhi.create_uniform_buffer(Uniforms) or_return
	}

	pool_desc := rhi.Descriptor_Pool_Desc{
		pool_sizes = {
			rhi.Descriptor_Pool_Size{
				type = .UNIFORM_BUFFER,
				count = rhi.MAX_FRAMES_IN_FLIGHT,
			},
			rhi.Descriptor_Pool_Size{
				type = .COMBINED_IMAGE_SAMPLER,
				count = rhi.MAX_FRAMES_IN_FLIGHT,
			},
		},
		max_sets = rhi.MAX_FRAMES_IN_FLIGHT,
	}
	de_rendering_data.descriptor_pool = rhi.create_descriptor_pool(pool_desc) or_return
	for i in 0..<rhi.MAX_FRAMES_IN_FLIGHT {
		set_desc := rhi.Descriptor_Set_Desc{
			descriptors = {
				rhi.Descriptor_Desc{
					binding = 0,
					count = 1,
					type = .UNIFORM_BUFFER,
					info = rhi.Descriptor_Buffer_Info{
						buffer = &de_rendering_data.uniform_buffers[i].buffer,
						size = size_of(Uniforms),
						offset = 0,
					},
				},
				rhi.Descriptor_Desc{
					binding = 1,
					count = 1,
					type = .COMBINED_IMAGE_SAMPLER,
					info = rhi.Descriptor_Texture_Info{
						texture = &de_rendering_data.mesh_texture.texture,
						sampler = &de_rendering_data.mesh_tex_sampler,
					},
				},
			},
			layout = de_rendering_data.pipeline_layout,
		}
		de_rendering_data.descriptor_sets[i] = rhi.create_descriptor_set(de_rendering_data.descriptor_pool, set_desc) or_return
	}

	de_rendering_data.cmd_buffers = rhi.allocate_command_buffers(rhi.MAX_FRAMES_IN_FLIGHT) or_return

	return nil
}

de_init_rendering :: proc(main_window: platform.Window_Handle) {
	options := png.Options{.alpha_add_if_missing}
	img, img_err := png.load(core.path_make_engine_textures_relative("test.png"), options)
	defer png.destroy(img)

	if img_err != nil {
		log.error("Failed to load an image.")
		return
	}

	assert(img.channels == 4, "Loaded image channels must be 4.")
	img_dimensions := [2]u32{u32(img.width), u32(img.height)}

	vertices, indices, load_result := de_load_model(core.path_make_engine_models_relative("Cube.glb"))
	if !load_result {
		log.error("Failed to load the model.")
		return
	}
	index_count := len(indices)
	defer de_free_model(vertices, indices)

	if rhi_res := de_init_rhi(main_window, vertices, indices, img.pixels.buf[:], img_dimensions); rhi_res != nil {
		rhi.handle_error(&rhi_res.(rhi.RHI_Error))
		return
	}
}

de_shutdown_rendering :: proc() {
	for i in 0..<rhi.MAX_FRAMES_IN_FLIGHT {
		rhi.destroy_buffer(&de_rendering_data.uniform_buffers[i])
	}
	rhi.destroy_buffer(&de_rendering_data.vertex_buffer)
	rhi.destroy_buffer(&de_rendering_data.index_buffer)
	rhi.destroy_sampler(&de_rendering_data.mesh_tex_sampler)
	rhi.destroy_texture(&de_rendering_data.mesh_texture)
	de_destroy_framebuffers()
	rhi.destroy_texture(&de_rendering_data.depth_texture)
	rhi.destroy_render_pass(&de_rendering_data.render_pass)
	rhi.destroy_graphics_pipeline(&de_rendering_data.pipeline)
	rhi.destroy_descriptor_pool(&de_rendering_data.descriptor_pool)

	delete(de_rendering_data.framebuffers)
}

de_create_framebuffers :: proc(images: []rhi.Texture_2D, depth_texture: ^rhi.Texture_2D) -> rhi.RHI_Result {
	for &im, i in images {
		attachments := [2]^rhi.Texture_2D{&im, depth_texture}
		fb := rhi.create_framebuffer(de_rendering_data.render_pass, attachments[:]) or_return
		append(&de_rendering_data.framebuffers, fb)
	}

	return nil
}

de_destroy_framebuffers :: proc() {
	for &fb in de_rendering_data.framebuffers {
		rhi.destroy_framebuffer(&fb)
	}
	clear(&de_rendering_data.framebuffers)
}

de_on_recreate_swapchain :: proc(args: rhi.Args_Recreate_Swapchain) {
	r: rhi.RHI_Result
	de_destroy_framebuffers()
	rhi.destroy_texture(&de_rendering_data.depth_texture)
	swapchain_images := rhi.get_swapchain_images(args.surface_index)
	de_rendering_data.depth_texture, r = rhi.create_depth_texture(args.new_dimensions, .D24S8)
	if r != nil {
		panic("Failed to recreate the depth texture.")
	}
	de_create_framebuffers(swapchain_images, &de_rendering_data.depth_texture)
}

de_update :: proc() {
	@(static) start_time: time.Time
	if time.time_to_unix_nano(start_time) == 0 {
		start_time = time.now()
	}

	current_time := time.now()
	duration := time.diff(start_time, current_time)
	t: f64 = time.duration_seconds(duration)

	model_matrix := linalg.matrix4_from_euler_angles_xyz_f32(0, 0, f32(t) * math.to_radians_f32(90))
	view_matrix := linalg.matrix4_look_at_f32([3]f32{0.0, 2.0, 2.0}, [3]f32{0.0, 0.0, 0.0}, [3]f32{0.0, 1.0, 0.0})

	dimensions := de_rendering_data.framebuffers[0].dimensions
	hfov := math.to_radians_f32(90.0)
	aspect_ratio := f32(dimensions.x) / f32(dimensions.y)
	vfov := hfov / aspect_ratio
	proj_matrix := linalg.matrix4_perspective_f32(vfov, aspect_ratio, 0.1, 10.0)

	de_rendering_data.uniforms.mvp = proj_matrix * view_matrix * model_matrix
}

de_draw :: proc() {
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

	frame_in_flight := rhi.get_frame_in_flight()

	cb := &de_rendering_data.cmd_buffers[frame_in_flight]
	rhi.begin_command_buffer(cb)
	fb := &de_rendering_data.framebuffers[image_index]
	rhi.cmd_begin_render_pass(cb, de_rendering_data.render_pass, fb^)
	rhi.cmd_bind_graphics_pipeline(cb, de_rendering_data.pipeline)
	rhi.cmd_set_viewport(cb, {0, 0}, {cast(f32) fb.dimensions.x, cast(f32) fb.dimensions.y}, 0, 1)
	rhi.cmd_set_scissor(cb, {0, 0}, fb.dimensions)
	rhi.cmd_bind_vertex_buffer(cb, de_rendering_data.vertex_buffer)
	rhi.cmd_bind_index_buffer(cb, de_rendering_data.index_buffer)
	rhi.cmd_bind_descriptor_set(cb, de_rendering_data.pipeline_layout, de_rendering_data.descriptor_sets[frame_in_flight])
	rhi.cmd_draw_indexed(cb, de_rendering_data.index_buffer.index_count)
	rhi.cmd_end_render_pass(cb)
	rhi.end_command_buffer(cb)
	
	rhi.update_uniform_buffer(&de_rendering_data.uniform_buffers[frame_in_flight], &de_rendering_data.uniforms)

	rhi.queue_submit_for_drawing(cb)

	if r := rhi.present(image_index); r != nil {
		rhi.handle_error(&r.(rhi.RHI_Error))
		return
	}
}
