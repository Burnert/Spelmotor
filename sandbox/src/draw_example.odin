package spelmotor_sandbox

import "core:fmt"
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
	render_pass: rhi.Backend_Render_Pass,
	pipeline: rhi.Backend_Pipeline,
	pipeline_layout: rhi.Backend_Pipeline_Layout,
	descriptor_set_layout: rhi.Backend_Descriptor_Set_Layout,
	framebuffers: [dynamic]rhi.Framebuffer,
	depth_texture: rhi.Texture,
	mesh_texture: rhi.Texture,
	mesh_tex_sampler: rhi.Backend_Sampler,
	vertex_buffer: rhi.Buffer,
	index_buffer: rhi.Buffer,
	uniform_buffers: [rhi.MAX_FRAMES_IN_FLIGHT]rhi.Buffer,
	descriptor_pool: rhi.Descriptor_Pool,
	descriptor_sets: [rhi.MAX_FRAMES_IN_FLIGHT]rhi.Backend_Descriptor_Set,
	cmd_buffers: [rhi.MAX_FRAMES_IN_FLIGHT]rhi.Backend_Command_Buffer,
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

de_init_rhi :: proc(rhi_s: ^rhi.State, main_window: platform.Window_Handle, vertices: []Vertex, indices: []u32, img_pixels: []byte, img_dimensions: [2]u32) -> rhi.Result {
	core.broadcaster_add_callback(&rhi_s.callbacks.on_recreate_swapchain_broadcaster, de_on_recreate_swapchain)

	surface_key := rhi.get_surface_key_from_window(main_window)
	swapchain_format := rhi.get_swapchain_image_format(surface_key)
	swapchain_images := rhi.get_swapchain_images(surface_key)
	assert(len(swapchain_images) > 0)
	swapchain_dims := swapchain_images[0].dimensions.xy

	vsh := rhi.create_vertex_shader(core.path_make_engine_shader_relative("test.vert")) or_return
	defer rhi.destroy_shader(&vsh)

	fsh := rhi.create_fragment_shader(core.path_make_engine_shader_relative("test.frag")) or_return
	defer rhi.destroy_shader(&fsh)

	render_pass_desc := rhi.Render_Pass_Desc{
		attachments = {
			// Color
			rhi.Attachment_Desc{
				usage = .Color,
				format = swapchain_format,
				load_op = .Clear,
				store_op = .Store,
				from_layout = .Undefined,
				to_layout = .Present_Src,
			},
			// Depth-stencil
			rhi.Attachment_Desc{
				usage = .Depth_Stencil,
				format = .D24S8,
				load_op = .Clear,
				store_op = .Irrelevant,
				from_layout = .Undefined,
				to_layout = .Depth_Stencil_Attachment,
			},
		},
		src_dependency = {
			stage_mask = {.COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS},
			access_mask = {},
		},
		dst_dependency = {
			stage_mask = {.COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS},
			access_mask = {.COLOR_ATTACHMENT_WRITE, .DEPTH_STENCIL_ATTACHMENT_WRITE},
		},
	}
	de_rendering_data.render_pass =  rhi.create_render_pass(render_pass_desc) or_return

	descriptor_layout_desc := rhi.Descriptor_Set_Layout_Description{
		bindings = {
			rhi.Descriptor_Set_Layout_Binding{
				binding = 0,
				type = .Uniform_Buffer,
				shader_stage = {.Vertex},
				count = 1,
			},
			rhi.Descriptor_Set_Layout_Binding{
				binding = 1,
				type = .Combined_Image_Sampler,
				shader_stage = {.Fragment},
				count = 1,
			},
		},
	}
	de_rendering_data.descriptor_set_layout = rhi.create_descriptor_set_layout(descriptor_layout_desc, "DSL_DrawExample") or_return

	layout_desc := rhi.Pipeline_Layout_Description{
		descriptor_set_layouts = {
			&de_rendering_data.descriptor_set_layout,
		},
	}
	de_rendering_data.pipeline_layout = rhi.create_pipeline_layout(layout_desc) or_return

	vertex_input_types := []rhi.Vertex_Input_Type_Desc{
		rhi.Vertex_Input_Type_Desc{type = Vertex, rate = .Vertex},
	}
	vid := rhi.create_vertex_input_description(vertex_input_types, context.temp_allocator)

	pipeline_desc := rhi.Pipeline_Description{
		shader_stages = {
			rhi.Pipeline_Shader_Stage{
				type = .Vertex,
				shader = &vsh.shader,
			},
			rhi.Pipeline_Shader_Stage{
				type = .Fragment,
				shader = &fsh.shader,
			},
		},
		vertex_input = vid,
		depth_stencil = {
			depth_compare_op = .Less,
		},
		blend_state = rhi.DEFAULT_BLEND_STATE,
	}
	de_rendering_data.pipeline = rhi.create_graphics_pipeline(pipeline_desc, nil, de_rendering_data.pipeline_layout, "GPipeline_DrawExample") or_return
	
	de_rendering_data.depth_texture = rhi.create_depth_stencil_texture(swapchain_dims, .D24S8, "DepthStencil") or_return

	de_create_framebuffers(swapchain_images, &de_rendering_data.depth_texture) or_return

	de_rendering_data.mesh_texture = rhi.create_texture_2d(img_pixels, img_dimensions, .RGBA8_Srgb, "MeshTexture") or_return
	de_rendering_data.mesh_tex_sampler = rhi.create_sampler(de_rendering_data.mesh_texture.mip_levels, .Linear, .Repeat, "MeshTexSampler") or_return

	buf_desc := rhi.Buffer_Desc{memory_flags = {.Device_Local}}
	de_rendering_data.vertex_buffer = rhi.create_vertex_buffer(buf_desc, vertices, "VB_Mesh") or_return
	de_rendering_data.index_buffer = rhi.create_index_buffer(buf_desc, indices, "IB_Mesh") or_return
	for i in 0..<rhi.MAX_FRAMES_IN_FLIGHT {
		ub_desc := rhi.Buffer_Desc{memory_flags = {.Device_Local, .Host_Coherent, .Host_Visible}}
		de_rendering_data.uniform_buffers[i] = rhi.create_uniform_buffer(ub_desc, Uniforms, "UB_Mesh") or_return
	}

	pool_desc := rhi.Descriptor_Pool_Desc{
		pool_sizes = {
			rhi.Descriptor_Pool_Size{
				type = .Uniform_Buffer,
				count = rhi.MAX_FRAMES_IN_FLIGHT,
			},
			rhi.Descriptor_Pool_Size{
				type = .Combined_Image_Sampler,
				count = rhi.MAX_FRAMES_IN_FLIGHT,
			},
		},
		max_sets = rhi.MAX_FRAMES_IN_FLIGHT,
	}
	de_rendering_data.descriptor_pool = rhi.create_descriptor_pool(pool_desc, "DP_DrawExample") or_return
	for i in 0..<rhi.MAX_FRAMES_IN_FLIGHT {
		set_desc := rhi.Descriptor_Set_Desc{
			descriptors = {
				rhi.Descriptor_Desc{
					binding = 0,
					count = 1,
					type = .Uniform_Buffer,
					info = rhi.Descriptor_Buffer_Info{
						buffer = &de_rendering_data.uniform_buffers[i].rhi_buffer,
						size = size_of(Uniforms),
						offset = 0,
					},
				},
				rhi.Descriptor_Desc{
					binding = 1,
					count = 1,
					type = .Combined_Image_Sampler,
					info = rhi.Descriptor_Texture_Info{
						texture = &de_rendering_data.mesh_texture.rhi_texture,
						sampler = &de_rendering_data.mesh_tex_sampler,
					},
				},
			},
			layout = de_rendering_data.descriptor_set_layout,
		}
		name := fmt.tprintf("DS_DrawExample-%i", i)
		de_rendering_data.descriptor_sets[i] = rhi.create_descriptor_set(de_rendering_data.descriptor_pool, set_desc, name) or_return
	}

	de_rendering_data.cmd_buffers = rhi.allocate_command_buffers(rhi.MAX_FRAMES_IN_FLIGHT, "DrawExample") or_return

	return nil
}

de_init_rendering :: proc(rhi_s: ^rhi.State, main_window: platform.Window_Handle) {
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

	if r := de_init_rhi(rhi_s, main_window, vertices, indices, img.pixels.buf[:], img_dimensions); r != nil {
		core.error_log(r.?)
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
	rhi.destroy_pipeline_layout(&de_rendering_data.pipeline_layout)
	rhi.destroy_descriptor_set_layout(&de_rendering_data.descriptor_set_layout)
	rhi.destroy_descriptor_pool(&de_rendering_data.descriptor_pool)

	delete(de_rendering_data.framebuffers)
}

de_create_framebuffers :: proc(images: []rhi.Texture, depth_texture: ^rhi.Texture) -> rhi.Result {
	for &im, i in images {
		attachments := [2]^rhi.Texture{&im, depth_texture}
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
	r: rhi.Result
	de_destroy_framebuffers()
	rhi.destroy_texture(&de_rendering_data.depth_texture)
	swapchain_images := rhi.get_swapchain_images(args.surface_key)
	if r != nil {
		de_rendering_data.depth_texture, r = rhi.create_depth_stencil_texture(args.new_dimensions, .D24S8, "DepthStencil")
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
	r: rhi.Result
	maybe_image_index: Maybe(uint)
	if maybe_image_index, r = rhi.wait_and_acquire_image(); r != nil {
		core.error_log(r.?)
		return
	}
	if maybe_image_index == nil {
		// No image available
		return
	}
	image_index := maybe_image_index.(uint)

	frame_in_flight := g_rhi.frame_in_flight

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
	rhi.cmd_draw_indexed(cb, de_rendering_data.index_buffer.elem_count)
	rhi.cmd_end_render_pass(cb)
	rhi.end_command_buffer(cb)
	
	rhi.update_uniform_buffer(&de_rendering_data.uniform_buffers[frame_in_flight], &de_rendering_data.uniforms)

	rhi.queue_submit_for_drawing(cb)

	if r := rhi.present(image_index); r != nil {
		core.error_log(r.?)
		return
	}
}
