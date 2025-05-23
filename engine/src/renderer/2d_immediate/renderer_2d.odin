package sm_renderer_2d_immediate

import "core:log"
import "core:image/png"
import "core:slice"
import "core:math"
import "core:math/linalg"

import "sm:core"
import "sm:platform"
import "sm:rhi"

Matrix4 :: matrix[4, 4]f32
Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32

Texture_2D :: rhi.Texture
RHI_Sampler :: rhi.RHI_Sampler
Framebuffer :: rhi.Framebuffer
MAX_FRAMES_IN_FLIGHT :: rhi.MAX_FRAMES_IN_FLIGHT
MAX_SPRITE_INSTANCES :: 10000
SPRITE_REGISTRY_CAP :: 200

Error_Type :: enum {
	Draw_Sprite_Failed_To_Load_Image,
	Draw_Sprite_Failed_To_Create_Texture,
	Draw_Sprite_Failed_To_Create_Descriptor_Set,
}

Error :: struct {
	type: Error_Type,
	message: string,
}
Result :: union { Error, rhi.Error }

log_result :: proc(result: Result) {
	switch &e in result {
	case Error:
		log.error(result.(Error).type, result.(Error).message)
	case rhi.Error:
		core.error_log(e)
	}
}

@(private)
init_rhi :: proc(rhi_s: ^rhi.State) -> rhi.Result {
	core.broadcaster_add_callback(&rhi_s.callbacks.on_recreate_swapchain_broadcaster, on_recreate_swapchain)

	// Get swapchain stuff
	main_window := platform.get_main_window()
	surface_key := rhi.get_surface_key_from_window(main_window)
	swapchain_format := rhi.get_swapchain_image_format(surface_key)
	swapchain_images := rhi.get_swapchain_images(surface_key)
	assert(len(swapchain_images) > 0)
	swapchain_dims := swapchain_images[0].dimensions.xy

	// Create shaders
	vsh := rhi.create_vertex_shader(core.path_make_engine_shader_relative("2d/sprite.vert")) or_return
	defer rhi.destroy_shader(&vsh)

	fsh := rhi.create_fragment_shader(core.path_make_engine_shader_relative("2d/sprite.frag")) or_return
	defer rhi.destroy_shader(&fsh)

	// Make render pass for swapchain images
	render_pass_desc := rhi.Render_Pass_Desc{
		attachments = {
			rhi.Attachment_Desc{
				usage = .Color,
				format = swapchain_format,
				load_op = .Clear,
				store_op = .Store,
				from_layout = .Undefined,
				to_layout = .Present_Src,
			},
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
	g_r2im_state.sprite_pipeline.render_pass = rhi.create_render_pass(render_pass_desc) or_return

	// Create descriptor set layout
	descriptor_set_layout_desc := rhi.Descriptor_Set_Layout_Description{
		bindings = {
			rhi.Descriptor_Set_Layout_Binding{
				binding = 1,
				type = .Combined_Image_Sampler,
				shader_stage = {.Fragment},
				count = 1,
			},
		},
	}
	g_r2im_state.sprite_pipeline.descriptor_set_layout = rhi.create_descriptor_set_layout(descriptor_set_layout_desc) or_return
	
	// Create pipeline layout
	layout := rhi.Pipeline_Layout_Description{
		descriptor_set_layouts = {
			&g_r2im_state.sprite_pipeline.descriptor_set_layout,
		},
		push_constants = {
			rhi.Push_Constant_Range{
				offset = 0,
				size = size_of(Sprite_Push_Constants),
				shader_stage = {.Vertex},
			},
		},
	}
	g_r2im_state.sprite_pipeline.pipeline_layout = rhi.create_pipeline_layout(layout) or_return

	// Setup vertex input for sprites
	vertex_input_types := []rhi.Vertex_Input_Type_Desc{
		rhi.Vertex_Input_Type_Desc{type = Sprite_Vertex,        rate = .Vertex},
		rhi.Vertex_Input_Type_Desc{type = Sprite_Instance_Data, rate = .Instance},
	}
	vid := rhi.create_vertex_input_description(vertex_input_types, context.temp_allocator)
	log.debug("\nSPRITE VID:", vid, "\n")

	// Create sprite graphics pipeline
	pipeline_desc := rhi.Pipeline_Description{
		shader_stages = {
			rhi.Pipeline_Shader_Stage{type = .Vertex,   shader = &vsh.shader},
			rhi.Pipeline_Shader_Stage{type = .Fragment, shader = &fsh.shader},
		},
		vertex_input = vid,
		depth_stencil = {
			depth_test = true,
			depth_write = true,
			depth_compare_op = .Less_Or_Equal,
		},
		viewport_dims = swapchain_dims,
	}
	g_r2im_state.sprite_pipeline.pipeline = rhi.create_graphics_pipeline(pipeline_desc, g_r2im_state.sprite_pipeline.render_pass, g_r2im_state.sprite_pipeline.pipeline_layout) or_return

	// Create depth buffer for layering sprites
	g_r2im_state.depth_texture = rhi.create_depth_texture(swapchain_dims, .D24S8) or_return

	// Make framebuffers
	fb_textures := make([]^Texture_2D, len(swapchain_images), context.temp_allocator)
	for &im, i in swapchain_images {
		fb_textures[i] = &im
	}
	create_framebuffers(fb_textures, &g_r2im_state.depth_texture) or_return

	// Create sprite descriptor pool
	pool_desc := rhi.Descriptor_Pool_Desc{
		pool_sizes = {
			rhi.Descriptor_Pool_Size{
				type = .Combined_Image_Sampler,
				count = rhi.MAX_FRAMES_IN_FLIGHT * MAX_SPRITE_INSTANCES,
			},
		},
		max_sets = rhi.MAX_FRAMES_IN_FLIGHT * MAX_SPRITE_INSTANCES,
	}
	g_r2im_state.descriptor_pool = rhi.create_descriptor_pool(pool_desc) or_return

	// Create sprite instance buffers
	sprite_instance_buffer_desc := rhi.Buffer_Desc{
		memory_flags = {.Host_Visible, .Host_Coherent},
	}
	for &buffer in g_r2im_state.sprite_instance_buffers {
		buffer = rhi.create_vertex_buffer_empty(sprite_instance_buffer_desc, Sprite_Instance_Data, MAX_SPRITE_INSTANCES, map_memory=true) or_return
	}

	// Create sprite vertex and index buffers
	sprite_buf_desc := rhi.Buffer_Desc{
		memory_flags = {.Device_Local},
	}
	g_r2im_state.sprite_vb = rhi.create_vertex_buffer(sprite_buf_desc, sprite_mesh.vertices[:]) or_return
	g_r2im_state.sprite_ib = rhi.create_index_buffer(sprite_buf_desc, sprite_mesh.indices[:]) or_return

	// Create sprite texture sampler
	// TODO: More mip levels are required
	g_r2im_state.sprite_sampler = rhi.create_sampler(1, .Linear, .Repeat) or_return

	// Allocate cmd buffers
	g_r2im_state.cmd_buffers = rhi.allocate_command_buffers(MAX_FRAMES_IN_FLIGHT) or_return

	return nil
}

@(private)
shutdown_rhi :: proc() {
	rhi.destroy_sampler(&g_r2im_state.sprite_sampler)
	rhi.destroy_buffer(&g_r2im_state.sprite_ib)
	rhi.destroy_buffer(&g_r2im_state.sprite_vb)
	for &buffer in g_r2im_state.sprite_instance_buffers {
		rhi.destroy_buffer(&buffer)
	}
	rhi.destroy_descriptor_pool(&g_r2im_state.descriptor_pool)
	destroy_framebuffers()
	rhi.destroy_texture(&g_r2im_state.depth_texture)
	rhi.destroy_graphics_pipeline(&g_r2im_state.sprite_pipeline.pipeline)
	rhi.destroy_pipeline_layout(&g_r2im_state.sprite_pipeline.pipeline_layout)
	rhi.destroy_descriptor_set_layout(&g_r2im_state.sprite_pipeline.descriptor_set_layout)
	rhi.destroy_render_pass(&g_r2im_state.sprite_pipeline.render_pass)
}

@(private)
create_framebuffers :: proc(images: []^Texture_2D, depth: ^Texture_2D) -> rhi.Result {
	for &im, i in images {
		attachments := [2]^Texture_2D{im, depth}
		fb := rhi.create_framebuffer(g_r2im_state.sprite_pipeline.render_pass, attachments[:]) or_return
		append(&g_r2im_state.framebuffers, fb)
	}
	return nil
}

@(private)
on_recreate_swapchain :: proc(args: rhi.Args_Recreate_Swapchain) {
	r: rhi.Result
	destroy_framebuffers()
	rhi.destroy_texture(&g_r2im_state.depth_texture)
	swapchain_images := rhi.get_swapchain_images(args.surface_key)
	g_r2im_state.depth_texture, r = rhi.create_depth_texture(args.new_dimensions, .D24S8)
	if r != nil {
		panic("Failed to recreate the depth texture.")
	}
	fb_textures := make([]^Texture_2D, len(swapchain_images), context.temp_allocator)
	for &im, i in swapchain_images {
		fb_textures[i] = &im
	}
	create_framebuffers(fb_textures, &g_r2im_state.depth_texture)
}

@(private)
destroy_framebuffers :: proc() {
	for &fb in g_r2im_state.framebuffers {
		rhi.destroy_framebuffer(&fb)
	}
	clear(&g_r2im_state.framebuffers)
}

init :: proc(rhi_s: ^rhi.State) -> Result {
	g_rhi = rhi_s
	init_state(&g_r2im_state)

	if r := init_rhi(rhi_s); r != nil {
		return r.(rhi.Error)
	}
	
	return nil
}

shutdown :: proc() {
	delete_state(&g_r2im_state)
	g_rhi = nil
}

begin_frame :: proc() -> bool {
	assert(slice.is_empty(g_r2im_state.sprites_to_render[:]))
	is_minimized := rhi.is_minimized()
	return !is_minimized
}

end_frame :: proc() {
	// log.debug(g_r2im_state.sprite_registry)
	// log.debug(g_r2im_state.sprites_to_render)

	defer clear(&g_r2im_state.sprites_to_render)

	for &sprite_inst in g_r2im_state.sprites_to_render {
		assert(sprite_inst.sprite != nil)
	}

	// Sort the sprites for easier instancing
	slice.sort_by_key(g_r2im_state.sprites_to_render[:], proc(elem: Sprite_Instance) -> ^Sprite {
		return elem.sprite
	})

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

	assert(g_rhi != nil)
	frame_in_flight := g_rhi.frame_in_flight

	cb := &g_r2im_state.cmd_buffers[frame_in_flight]
	rhi.begin_command_buffer(cb)

	fb := &g_r2im_state.framebuffers[image_index]
	rhi.cmd_begin_render_pass(cb, g_r2im_state.sprite_pipeline.render_pass, fb^)

	rhi.cmd_bind_graphics_pipeline(cb, g_r2im_state.sprite_pipeline.pipeline)
	rhi.cmd_set_viewport(cb, {0, 0}, {cast(f32) fb.dimensions.x, cast(f32) fb.dimensions.y}, 0, 1)
	rhi.cmd_set_scissor(cb, {0, 0}, fb.dimensions)

	rhi.cmd_bind_vertex_buffer(cb, g_r2im_state.sprite_vb)
	rhi.cmd_bind_index_buffer(cb, g_r2im_state.sprite_ib)

	right := f32(fb.dimensions.x) / 2.0
	left := -right
	top := f32(fb.dimensions.y) / 2.0
	bottom := -top
	// Flipping y-axis because vulkan's clip space is Y-down
	view_matrix := linalg.matrix_ortho3d_f32(left, right, top, bottom, 10, -10, true)

	constants := Sprite_Push_Constants{
		view_matrix = view_matrix,
	}
	rhi.cmd_push_constants(cb, g_r2im_state.sprite_pipeline.pipeline_layout, {.Vertex}, &constants)

	// Draw all submitted sprites
	if len(g_r2im_state.sprites_to_render) > 0 {
		current_sprite: ^Sprite
		instance_count := 0
		first_instance := 0
		for i in 0..=len(g_r2im_state.sprites_to_render) {
			end_of_sprites := i == len(g_r2im_state.sprites_to_render)

			// Draw instanced when the sprite changes
			if current_sprite != nil && (end_of_sprites || g_r2im_state.sprites_to_render[i].sprite != current_sprite) {
				instance_begin_offset := first_instance * size_of(Sprite_Instance_Data)

				// Bind and draw the whole batch
				rhi.cmd_bind_descriptor_set(cb, g_r2im_state.sprite_pipeline.pipeline_layout, current_sprite.descriptor_sets[frame_in_flight])
				rhi.cmd_bind_vertex_buffer(cb, g_r2im_state.sprite_instance_buffers[frame_in_flight], 1, cast(u32) instance_begin_offset)
				rhi.cmd_draw_indexed(cb, len(sprite_mesh.indices), cast(u32) instance_count)

				// Upload instance data
				instance_end_offset := instance_begin_offset + instance_count * size_of(Sprite_Instance_Data)
				target_memory := g_r2im_state.sprite_instance_buffers[frame_in_flight].mapped_memory[instance_begin_offset:instance_end_offset]
				target_memory_ptr := raw_data(target_memory)
				instances_slice := slice.from_ptr(cast(^Sprite_Instance_Data) target_memory_ptr, instance_count)
				for s in 0..<instance_count {
					current_inst := &g_r2im_state.sprites_to_render[first_instance + s]
					translation_matrix := linalg.matrix4_translate_f32(Vec3{current_inst.position.x, current_inst.position.y, 0})
					rotation_matrix := linalg.matrix4_rotate_f32(current_inst.rotation * math.TAU / 360.0, Vec3{0, 0, 1})
					scale_matrix := linalg.matrix4_scale_f32(Vec3{current_inst.dimensions.x, current_inst.dimensions.y, 1})
					instances_slice[s] = Sprite_Instance_Data{
						transform = translation_matrix * rotation_matrix * scale_matrix,
						color = current_inst.color,
						depth = 1 - (cast(f32) current_inst.z_index / MAX_SPRITE_INSTANCES),
					}
				}

				instance_count = 0
				first_instance = i
			}

			if !end_of_sprites {
				sprite_inst := &g_r2im_state.sprites_to_render[i]
				current_sprite = sprite_inst.sprite
				instance_count += 1
			}
		}
	}

	rhi.cmd_end_render_pass(cb)

	rhi.end_command_buffer(cb)
	
	rhi.queue_submit_for_drawing(cb)

	if r := rhi.present(image_index); r != nil {
		core.error_log(r.?)
		return
	}
}

Sprite :: struct {
	texture: Texture_2D,
	descriptor_sets: [MAX_FRAMES_IN_FLIGHT]rhi.RHI_Descriptor_Set,
	available: bool,
}

Sprite_Instance :: struct {
	sprite: ^Sprite,
	position: [2]f32,
	rotation: f32,
	dimensions: [2]f32,
	color: [4]f32,
	z_index: u32,
}

Sprite_Pipeline :: struct {
	pipeline: rhi.RHI_Pipeline,
	pipeline_layout: rhi.RHI_Pipeline_Layout,
	descriptor_set_layout: rhi.RHI_Descriptor_Set_Layout,
	render_pass: rhi.RHI_Render_Pass,
}

Sprite_Push_Constants :: struct {
	view_matrix: Matrix4,
}

Sprite_Vertex :: struct {
	position: Vec2,
	texcoord: Vec2,
}

Sprite_Instance_Data :: struct {
	transform: Matrix4,
	color: Vec4,
	depth: f32,
}

Sprite_Mesh :: struct {
	vertices: [4]Sprite_Vertex,
	indices: [6]u32,
}

sprite_mesh := Sprite_Mesh{
	vertices = {
		Sprite_Vertex{position = {-0.5,  0.5}, texcoord = {0.0, 0.0}},
		Sprite_Vertex{position = { 0.5,  0.5}, texcoord = {1.0, 0.0}},
		Sprite_Vertex{position = { 0.5, -0.5}, texcoord = {1.0, 1.0}},
		Sprite_Vertex{position = {-0.5, -0.5}, texcoord = {0.0, 1.0}},
	},
	indices = {
		0, 1, 2,
		2, 3, 0,
	},
}

create_sprite_descriptor_sets :: proc(sprite: ^Sprite) -> (result: rhi.Result) {
	for i in 0..<rhi.MAX_FRAMES_IN_FLIGHT {
		set_desc := rhi.Descriptor_Set_Desc{
			descriptors = {
				rhi.Descriptor_Desc{
					binding = 1,
					count = 1,
					type = .Combined_Image_Sampler,
					info = rhi.Descriptor_Texture_Info{
						texture = &sprite.texture.rhi_texture,
						sampler = &g_r2im_state.sprite_sampler,
					},
				},
			},
			layout = g_r2im_state.sprite_pipeline.descriptor_set_layout,
		}
		sprite.descriptor_sets[i] = rhi.create_descriptor_set(g_r2im_state.descriptor_pool, set_desc) or_return
	}
	return
}

init_sprite :: proc(image_path: string) -> (s: ^Sprite, result: Result) {
	sprite: Sprite
	s = map_insert(&g_r2im_state.sprite_registry, image_path, sprite)

	options := png.Options{.alpha_add_if_missing}
	img, err := png.load(image_path, options)
	defer png.destroy(img)

	if err != nil {
		result = Error{type = .Draw_Sprite_Failed_To_Load_Image}
		return
	}

	assert(img.channels == 4, "Loaded image channels must be 4.")
	img_dimensions := [2]u32{u32(img.width), u32(img.height)}

	texture, r := rhi.create_texture_2d(img.pixels.buf[:], img_dimensions, .RGBA8_Srgb)
	if r != nil {
		result = Error{type = .Draw_Sprite_Failed_To_Create_Texture}
		return
	}
	s.texture = texture

	if r := create_sprite_descriptor_sets(s); r != nil {
		core.error_log(r.?)
		result = Error{type = .Draw_Sprite_Failed_To_Create_Descriptor_Set}
	}

	s.available = true
	return
}

draw_sprite :: proc(position: [2]f32, rotation: f32, dimensions: [2]f32, image_path: string, color: [4]f32 = {1, 1, 1, 1}) {
	if len(g_r2im_state.sprites_to_render) >= MAX_SPRITE_INSTANCES {
		log.error("Cannot draw more sprites because the limit has been reached.")
		return
	}

	sprite, is_initialized := &g_r2im_state.sprite_registry[image_path]
	if !is_initialized {
		res: Result
		sprite, res = init_sprite(image_path)
		if res != nil {
			log.error("Failed to init sprite", image_path, "-", res)
		}
	}
	if !sprite.available {
		return
	}

	sprite_instance := Sprite_Instance{
		sprite = sprite,
		position = position,
		rotation = rotation,
		dimensions = dimensions,
		color = color,
		z_index = cast(u32) len(g_r2im_state.sprites_to_render),
	}
	append(&g_r2im_state.sprites_to_render, sprite_instance)
}

@(private)
State :: struct {
	sprite_registry: map[string]Sprite,
	sprites_to_render: [dynamic]Sprite_Instance,

	sprite_pipeline: Sprite_Pipeline,
	framebuffers: [dynamic]Framebuffer,
	cmd_buffers: [MAX_FRAMES_IN_FLIGHT]rhi.RHI_Command_Buffer,
	descriptor_pool: rhi.RHI_Descriptor_Pool,
	sprite_instance_buffers: [rhi.MAX_FRAMES_IN_FLIGHT]rhi.Buffer,
	sprite_vb: rhi.Buffer,
	sprite_ib: rhi.Buffer,
	sprite_sampler: RHI_Sampler,

	depth_texture: rhi.Texture,
}

@(private)
g_r2im_state: State

// Global RHI state pointer
@(private)
g_rhi: ^rhi.State

@(private)
init_state :: proc(s: ^State) {
	s.sprite_registry = make(map[string]Sprite, SPRITE_REGISTRY_CAP)
	s.sprites_to_render = make([dynamic]Sprite_Instance)
}

@(private)
delete_state :: proc(s: ^State) {
	delete(s.sprite_registry)
	delete(s.sprites_to_render)
	delete(s.framebuffers)
}
