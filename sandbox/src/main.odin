package spelmotor_sandbox

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/fixed"
import "core:mem"
import "core:image/png"
import "core:strings"
import "core:time"
import "vendor:cgltf"

import "sm:core"
import "sm:csg"
import "sm:platform"
import "sm:rhi"
import r2im "sm:renderer/2d_immediate"
import r3d "sm:renderer/3d"

// TODO: Add more error info on each step up!

ENABLE_DRAW_EXAMPLE_TEST  :: false
ENABLE_DRAW_2D_TEST       :: false
ENABLE_DRAW_3D_DEBUG_TEST :: true

SIXTY_FPS_DT :: 1.0 / 60.0

Vec2 :: core.Vec2
Vec3 :: core.Vec3
Vec4 :: core.Vec4
Quat :: core.Quat
Matrix3 :: core.Matrix3
Matrix4 :: core.Matrix4

VEC2_ZERO :: core.VEC2_ZERO

VEC3_ZERO :: core.VEC3_ZERO
VEC3_ONE :: core.VEC3_ONE
VEC3_RIGHT :: core.VEC3_RIGHT
VEC3_LEFT :: core.VEC3_LEFT
VEC3_FORWARD :: core.VEC3_FORWARD
VEC3_BACKWARD :: core.VEC3_BACKWARD
VEC3_UP :: core.VEC3_UP
VEC3_DOWN :: core.VEC3_DOWN

VEC4_ZERO :: core.VEC4_ZERO

QUAT_IDENTITY :: core.QUAT_IDENTITY

MATRIX3_IDENTITY :: core.MATRIX3_IDENTITY
MATRIX4_IDENTITY :: core.MATRIX4_IDENTITY

vec3 :: core.vec3
vec4 :: core.vec4

main :: proc() {
	// For error handling
	ok: bool

	// Setup tracking allocator
	when ODIN_DEBUG {
		t: mem.Tracking_Allocator
		mem.tracking_allocator_init(&t, context.allocator)
		context.allocator = mem.tracking_allocator(&t)

		defer {
			log.debugf("Total memory allocated: %i", t.total_memory_allocated)
			log.debugf("Total memory freed: %i", t.total_memory_freed)
			if len(t.allocation_map) > 0 {
				log.fatalf("%i allocations not freed!", len(t.allocation_map))
				for _, entry in t.allocation_map {
					log.errorf(" * %m at %s", entry.size, entry.location)
				}
			}
			if len(t.bad_free_array) > 0 {
				log.fatalf("%i incorrect frees!", len(t.bad_free_array))
				for entry in t.bad_free_array {
					log.errorf(" * at %s", entry.location)
				}
			}
			mem.tracking_allocator_destroy(&t)
		}
	}

	// Setup logger
	context.logger = core.create_engine_logger()
	context.assertion_failure_proc = core.assertion_failure

	// Listen to platform events
	platform.shared_data.event_callback_proc = proc(window: platform.Window_Handle, event: platform.System_Event) {
		rhi.process_platform_events(window, event)

		#partial switch e in event {
		case platform.Key_Event:
			#partial switch e.keycode {
			case .W:
				g_input.fw = e.type != .Released
			case .S:
				g_input.bw = e.type != .Released
			case .A:
				g_input.sl = e.type != .Released
			case .D:
				g_input.sr = e.type != .Released
			case .Q:
				g_input.dn = e.type != .Released
			case .E:
				g_input.up = e.type != .Released
			case .Left_Shift:
				g_input.fast = e.type != .Released
			}
		case platform.RI_Mouse_Event:
			if e.button == .R {
				g_input.capture = e.type == .Pressed
			}
		case platform.RI_Mouse_Moved_Event:
			g_input.m_delta = Vec2{f32(e.x), f32(e.y)}
		}
	}

	// Init platform
	if !platform.init() {
		log.fatal("The main application could not initialize the platform layer.")
		return
	}
	defer platform.shutdown()

	main_window: platform.Window_Handle
	window_desc := platform.Window_Desc{
		width = 1280, height = 720,
		position = nil,
		title = "Spelmotor Sandbox",
		fixed_size = false,
	}
	if main_window, ok = platform.create_window(window_desc); !ok {
		log.fatal("The main application window could not be created.")
		return
	}

	platform.register_raw_input_devices()

	// Init the RHI
	rhi_init := rhi.RHI_Init{
		main_window_handle = main_window,
		app_name = "Spelmotor Sandbox",
		ver = {1, 0, 0},
	}
	if r := rhi.init(rhi_init); r != nil {
		core.error_panic(r.?)
		return
	}
	defer {
		rhi.wait_for_device()
		rhi.shutdown()
	}

	when ENABLE_DRAW_EXAMPLE_TEST {
		de_init_rendering(main_window)
		defer de_shutdown_rendering()
	}

	// An RHI surface will be created automatically for the main window

	when ENABLE_DRAW_2D_TEST {
		r2im_res := r2im.init()
		defer r2im.shutdown()
		if r2im_res != nil {
			r2im.log_result(r2im_res)
			return
		}
	}

	when ENABLE_DRAW_3D_DEBUG_TEST {
		r3d_res := r3d.init()
		defer r3d.shutdown()
		if r3d_res != nil {
			return
		}
	}

	// Finally, show the main window
	platform.show_window(main_window)

	dpi := platform.get_window_dpi(main_window)
	when ENABLE_DRAW_3D_DEBUG_TEST {
		r3d.text_init(cast(u32)dpi)
		defer r3d.text_shutdown()
	
		g_text_geo = r3d.create_text_geometry("BRAVO T. F. V. VA Y. tj gj aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
		defer r3d.destroy_text_geometry(&g_text_geo)

		if r := init_3d(); r != nil {
			core.error_log(r.?)
		}
		defer shutdown_3d()

		csg.init(&g_csg.state)
		defer csg.shutdown(&g_csg.state)

		g_csg.brushes[0], g_csg.handles[0] = csg.create_brush(&g_csg.state, {
			csg.Plane{ 1, 0, 0,1},
			csg.Plane{ 0, 1, 0,1},
			csg.Plane{ 0, 0, 1,1},
			csg.Plane{-1, 0, 0,1},
			csg.Plane{ 0,-1, 0,1},
			csg.Plane{ 0, 0,-1,1},
		})
		defer csg.destroy_brush(&g_csg.state, g_csg.handles[0])
		g_csg.brushes[1], g_csg.handles[1] = csg.create_brush(&g_csg.state, {
			csg.plane_transform(csg.Plane{ 1, 0, 0,1}, linalg.matrix4_translate_f32({-1.2,-1,1})),
			csg.plane_transform(csg.Plane{ 0, 1, 0,1}, linalg.matrix4_translate_f32({-1.2,-1,1})),
			csg.plane_transform(csg.Plane{ 0, 0, 1,1}, linalg.matrix4_translate_f32({-1.2,-1,1})),
			csg.plane_transform(csg.Plane{-1, 0, 0,1}, linalg.matrix4_translate_f32({-1.2,-1,1})),
			csg.plane_transform(csg.Plane{ 0,-1, 0,1}, linalg.matrix4_translate_f32({-1.2,-1,1})),
			csg.plane_transform(csg.Plane{ 0, 0,-1,1}, linalg.matrix4_translate_f32({-1.2,-1,1})),
		})
		defer csg.destroy_brush(&g_csg.state, g_csg.handles[1])

		bsp_0, bsp_0_ok := csg.bsp_create_from_brush(g_csg.brushes[0])
		defer csg.bsp_destroy(bsp_0)
		bsp_1, bsp_1_ok := csg.bsp_create_from_brush(g_csg.brushes[1])
		defer csg.bsp_destroy(bsp_1)

		csg.bsp_merge(bsp_0, bsp_1, .UNION)

		csg.bsp_print(bsp_0)
	}

	test_errors()

	// Free after initialization
	free_all(context.temp_allocator)

	g_camera.position = Vec3{0, -10, 0}
	g_camera.angles = Vec3{0, 0, 0}
	g_camera.fovy = 70

	dt := f64(SIXTY_FPS_DT)
	last_now := time.tick_now()

	// Game loop
	for platform.pump_events() {
		update(dt)
		draw()

		// Free on frame end
		free_all(context.temp_allocator)

		now := time.tick_now()
		dt = time.duration_seconds(time.tick_diff(last_now, now))
		if dt > 1 {
			dt = SIXTY_FPS_DT
		}
		last_now = now
	}

	log.info("Shutting down...")
}

g_time: f64
g_position: Vec2

g_input: struct {
	fw: bool,
	bw: bool,
	sl: bool,
	sr: bool,
	up: bool,
	dn: bool,
	fast: bool,
	capture: bool,
	m_delta: Vec2,
}

Camera :: struct {
	position: Vec3,
	angles: Vec3,
	fovy: f32,
}
g_camera: Camera

g_text_geo: r3d.Text_Geometry
g_test_3d_state: struct {
	rp: rhi.RHI_RenderPass,
	framebuffers: [rhi.MAX_FRAMES_IN_FLIGHT]rhi.Framebuffer,
	textures: [rhi.MAX_FRAMES_IN_FLIGHT]r3d.RTexture_2D,
	text_pipeline: rhi.RHI_Pipeline,

	test_mesh: r3d.RMesh,
	test_model: r3d.RModel,
	test_texture: r3d.RTexture_2D,
	test_material: r3d.RMaterial,

	test_mesh2: r3d.RMesh,
	test_model2: r3d.RModel,

	scene: r3d.RScene,
	scene_view: r3d.RScene_View,

	main_light_index: int,
}

g_csg: struct {
	state: csg.CSG_State,

	brushes: [1000]csg.Brush,
	handles: [1000]csg.Brush_Handle,
}

update :: proc(dt: f64) {
	g_time += dt
	g_position.x = cast(f32) math.sin_f64(g_time) * 1
	g_position.y = cast(f32) math.cos_f64(g_time) * 1

	if g_input.capture {
		g_camera.angles.x += -g_input.m_delta.y * 0.1
		g_camera.angles.x = math.clamp(g_camera.angles.x, -89.999, 89.999)
		g_camera.angles.z += -g_input.m_delta.x * 0.1
		g_camera.angles.z = math.mod_f32(g_camera.angles.z+540, 360)-180
		g_input.m_delta = Vec2{0,0}
	}
	local_movement_vec: Vec4
	local_movement_vec.x = (f32(int(g_input.sl)) * -1.0 + f32(int(g_input.sr)) * 1.0)
	local_movement_vec.y = (f32(int(g_input.bw)) * -1.0 + f32(int(g_input.fw)) * 1.0)
	local_movement_vec.w = 1
	camera_rotation_matrix := linalg.matrix4_from_euler_angles_zxy_f32(
		math.to_radians_f32(g_camera.angles.z),
		math.to_radians_f32(g_camera.angles.x),
		math.to_radians_f32(g_camera.angles.y),
	)
	camera_fwd_vec := camera_rotation_matrix * Vec4{0,1,0,0}
	world_movement_vec := (camera_rotation_matrix * local_movement_vec).xyz
	world_movement_vec.z += (f32(int(g_input.dn)) * -1.0 + f32(int(g_input.up)) * 1.0)
	world_movement_vec = linalg.vector_normalize0(world_movement_vec)
	g_camera.position += world_movement_vec * f32(dt) * (5 if g_input.fast else 2)

	when ENABLE_DRAW_EXAMPLE_TEST {
		de_update()
	}
}

draw_2d :: proc() {
	if r2im.begin_frame() {
		for y in -40..=40 {
			for x in -40..=40 {
				u := f32(x + 40) / 80
				v := f32(y + 40) / 80
				r2im.draw_sprite(g_position + {f32(x * 20), f32(y * 20)}, 0, {20, 20}, core.path_make_engine_textures_relative("test.png"), {u, v, 1, 1})
			}
		}
		r2im.draw_sprite({100, 100}, 0, {200, 200}, core.path_make_engine_textures_relative("test.png"), {1, 1, 1, 1})
		r2im.draw_sprite({0, 0}, 0, {20, 20}, core.path_make_engine_textures_relative("white.png"), {0, 0, 1, 1})
		r2im.draw_sprite({-100, 100}, 0, {200, 200}, core.path_make_engine_textures_relative("test.png"), {1, 1, 1, 1})
		r2im.end_frame()
	}
}

init_3d :: proc() -> rhi.RHI_Result {
	// Create an off-screen render pass for rendering a test text texture
	rp_desc := rhi.Render_Pass_Desc{
		attachments = {
			rhi.Attachment_Desc{
				format = .RGBA8_SRGB,
				usage = .COLOR,
				load_op = .CLEAR,
				store_op = .STORE,
				from_layout = .UNDEFINED,
				to_layout = .SHADER_READ_ONLY_OPTIMAL,
			},
		},
		src_dependency = {
			stage_mask = {.COLOR_ATTACHMENT_OUTPUT},
			access_mask = {.COLOR_ATTACHMENT_WRITE},
		},
		dst_dependency = {
			stage_mask = {.FRAGMENT_SHADER},
			access_mask = {.SHADER_READ},
		},
	}
	g_test_3d_state.rp = rhi.create_render_pass(rp_desc) or_return

	// Create a text pipeline associated with this render pass
	g_test_3d_state.text_pipeline = r3d.create_text_pipeline(g_test_3d_state.rp) or_return

	// Create the render targets for the render pass
	for i in 0..<rhi.MAX_FRAMES_IN_FLIGHT {
		r: rhi.RHI_Result
		if g_test_3d_state.textures[i], r = r3d.create_texture_2d(nil, {256,256}, .RGBA8_SRGB, .NEAREST, r3d.g_r3d_state.quad_renderer_state.descriptor_set_layout); r != nil {
			core.error_log(r.?)
		}
		g_test_3d_state.framebuffers[i] = rhi.create_framebuffer(g_test_3d_state.rp, {&g_test_3d_state.textures[i].texture_2d}) or_return
	}

	g_test_3d_state.scene = r3d.create_scene() or_return
	g_test_3d_state.scene_view = r3d.create_scene_view() or_return

	// Create a test plane mesh
	vertices := [?]r3d.Mesh_Vertex{
		{position = {-1, 1,0}, normal = core.VEC3_UP, tex_coord = {0,0}},
		{position = { 1, 1,0}, normal = core.VEC3_UP, tex_coord = {1,0}},
		{position = { 1,-1,0}, normal = core.VEC3_UP, tex_coord = {1,1}},
		{position = {-1,-1,0}, normal = core.VEC3_UP, tex_coord = {0,1}},
	}
	indices := [?]u32{
		0, 1, 2,
		2, 3, 0,
	}
	g_test_3d_state.test_mesh = r3d.create_mesh(vertices[:], indices[:]) or_return
	g_test_3d_state.test_model = r3d.create_model(&g_test_3d_state.test_mesh) or_return

	img, err := png.load(core.path_make_engine_textures_relative("test.png"), png.Options{.alpha_add_if_missing})
	defer png.destroy(img)
	assert(img.channels == 4, "Loaded image channels must be 4.")
	img_dimensions := [2]u32{u32(img.width), u32(img.height)}
	g_test_3d_state.test_texture = r3d.create_texture_2d(img.pixels.buf[:], img_dimensions, .RGBA8_SRGB, .LINEAR, r3d.g_r3d_state.mesh_renderer_state.material_descriptor_set_layout) or_return
	g_test_3d_state.test_material = r3d.create_material(&g_test_3d_state.test_texture) or_return

	gltf_mesh, gltf_res := r3d.import_mesh_gltf(core.path_make_engine_models_relative("Sphere.glb"), context.temp_allocator)
	core.result_verify(gltf_res)
	g_test_3d_state.test_mesh2 = r3d.create_mesh(gltf_mesh.vertices, gltf_mesh.indices) or_return
	g_test_3d_state.test_model2 = r3d.create_model(&g_test_3d_state.test_mesh2) or_return

	// Add a simple light
	append_elem(&g_test_3d_state.scene.lights, r3d.Light_Info{
		location = {0,0,2},
		color = {1,0.94,0.9},
		attenuation_radius = 10,
		intensity = 1,
	})
	g_test_3d_state.main_light_index = len(g_test_3d_state.scene.lights) - 1

	return nil
}

shutdown_3d :: proc() {
	r3d.destroy_model(&g_test_3d_state.test_model2)
	r3d.destroy_mesh(&g_test_3d_state.test_mesh2)

	r3d.destroy_material(&g_test_3d_state.test_material)
	r3d.destroy_texture_2d(&g_test_3d_state.test_texture)

	r3d.destroy_model(&g_test_3d_state.test_model)
	r3d.destroy_mesh(&g_test_3d_state.test_mesh)

	r3d.destroy_scene_view(&g_test_3d_state.scene_view)
	r3d.destroy_scene(&g_test_3d_state.scene)

	rhi.destroy_render_pass(&g_test_3d_state.rp)
	rhi.destroy_graphics_pipeline(&g_test_3d_state.text_pipeline)
	for i in 0..<rhi.MAX_FRAMES_IN_FLIGHT {
		rhi.destroy_framebuffer(&g_test_3d_state.framebuffers[i])
		r3d.destroy_texture_2d(&g_test_3d_state.textures[i])
	}
}

draw_3d :: proc() {
	main_window := platform.get_main_window()
	surface_index := rhi.get_surface_index_from_window(main_window)
	swapchain_images := rhi.get_swapchain_images(surface_index)
	assert(len(swapchain_images) > 0)
	swapchain_dims := swapchain_images[0].dimensions
	aspect_ratio := cast(f32)swapchain_dims.x / cast(f32)swapchain_dims.y

	// Update lights
	main_light := &g_test_3d_state.scene.lights[g_test_3d_state.main_light_index]
	main_light.location.x = cast(f32)math.sin(g_time * math.PI) * 2
	main_light.location.y = cast(f32)math.cos(g_time * math.PI) * 2
	r3d.debug_draw_sphere(main_light.location, core.QUAT_IDENTITY, 0.1, vec4(main_light.color, 1.0))

	// Update view (camera)
	g_test_3d_state.scene_view.view_info = r3d.View_Info{
		origin = g_camera.position,
		// Camera angles were specified in degrees here
		angles = linalg.to_radians(g_camera.angles),
		projection = r3d.Perspective_Projection_Info{
			vertical_fov = g_camera.fovy,
			aspect_ratio = aspect_ratio,
			near_clip_plane = 0.1,
		},
	}

	// Coordinate system axis
	r3d.debug_draw_arrow(Vec3{0,0,0}, Vec3{1,0,0}, Vec4{1,0,0,1})
	r3d.debug_draw_arrow(Vec3{0,0,0}, Vec3{0,1,0}, Vec4{0,1,0,1})
	r3d.debug_draw_arrow(Vec3{0,0,0}, Vec3{0,0,1}, Vec4{0,0,1,1})

	// 2x2x2 Cube
	// r3d.debug_draw_box(Vec3{0,0,0}, Vec3{1,1,1}, linalg.quaternion_angle_axis_f32(math.PI/2 * f32(g_time), Vec3{0,0,1}), Vec4{1,1,1,1})

	// Circumscribed sphere
	// r3d.debug_draw_sphere(Vec3{0,0,0}, QUAT_IDENTITY, math.SQRT_THREE, Vec4{1,1,1,0.25}, 32)

	// triangle := [3]Vec3{
	// 	{1, -5, -1},
	// 	{-1, -5, -1},
	// 	{0, -5, 1},
	// }
	// r3d.debug_draw_filled_triangle(triangle, Vec4{1,0,0,0.01})

	// shape := [?]Vec2{
	// 	{-1,-1},
	// 	{-1, 1},
	// 	{ 0, 1},
	// 	{ 1, 0},
	// 	{ 0,-1},
	// }
	// shape_matrix := linalg.matrix4_translate_f32(Vec3{2, 0, -1}) * linalg.matrix4_rotate_f32(math.PI/2, Vec3{1,0,0})
	// r3d.debug_draw_filled_2d_convex_shape(shape[:], shape_matrix, Vec4{0,1,0,0.1})

	// Update models
	g_test_3d_state.test_model.data.location = {2, 0, 0}
	g_test_3d_state.test_model.data.scale = {10, 10, 10}
	
	g_test_3d_state.test_model2.data.location = {-2, -1, 1}
	z_rot := f32(g_time * math.PI)
	g_test_3d_state.test_model2.data.rotation = {0, 0, z_rot}

	g_test_3d_state.test_material.specular = (math.sin(f32(g_time * math.PI*2)) + 1) * 0.5
	g_test_3d_state.test_material.specular_hardness = 100

	for ib in 0..<2 {
		vertices := g_csg.brushes[ib].vertices
		polygons := g_csg.brushes[ib].polygons
		for v in vertices {
			if v.w == 0 {
				continue
			}
			r3d.debug_draw_sphere(v.xyz, core.QUAT_IDENTITY, 0.1, {1,1,1,0.5})
		}
		for p := polygons; p != nil; p = csg.get_next_brush_polygon(p) {
			indices := csg.get_polygon_indices(p)
			shape := make([]Vec3, len(indices), context.temp_allocator)
			for idx, i in indices {
				shape[i] = vertices[idx].xyz
			}
			r3d.debug_draw_filled_3d_convex_shape(shape, {0,1,0,0.1})
		}
	}

	if cb, image_index := r3d.begin_frame(); cb != nil {
		frame_in_flight := rhi.get_frame_in_flight()

		// Upload all uniform data
		r3d.update_scene_uniforms(&g_test_3d_state.scene)
		r3d.update_scene_view_uniforms(&g_test_3d_state.scene_view)

		r3d.update_model_uniforms(&g_test_3d_state.scene_view, &g_test_3d_state.test_model)
		r3d.update_model_uniforms(&g_test_3d_state.scene_view, &g_test_3d_state.test_model2)

		r3d.update_material_uniforms(&g_test_3d_state.test_material)

		r3d.debug_update(&r3d.g_r3d_state.debug_renderer_state)

		// Drawing here
		main_rp := &r3d.g_r3d_state.main_render_pass
		fb := &main_rp.framebuffers[image_index]

		// Draw some text off screen
		rhi.cmd_begin_render_pass(cb, g_test_3d_state.rp, g_test_3d_state.framebuffers[frame_in_flight])
		{
			rhi.cmd_set_viewport(cb, {0, 0}, {256, 256}, 0, 1)
			rhi.cmd_set_scissor(cb, {0, 0}, {256, 256})
			r3d.bind_text_pipeline(cb, g_test_3d_state.text_pipeline)
			r3d.draw_text_geometry(cb, g_text_geo, {40, 40}, {256, 256})
		}
		rhi.cmd_end_render_pass(cb)

		// Main render pass
		rhi.cmd_begin_render_pass(cb, main_rp.render_pass, fb^)
		{
			rhi.cmd_set_viewport(cb, {0, 0}, core.array_cast(f32, fb.dimensions), 0, 1)
			rhi.cmd_set_scissor(cb, {0, 0}, fb.dimensions)

			r3d.bind_text_pipeline(cb, nil)
			r3d.draw_text_geometry(cb, g_text_geo, {20, 14}, fb.dimensions)

			r3d.draw_full_screen_quad(cb, g_test_3d_state.textures[frame_in_flight])

			// Draw the scene with meshes
			r3d.bind_scene(cb, &g_test_3d_state.scene)
			r3d.bind_scene_view(cb, &g_test_3d_state.scene_view)
			r3d.draw_model(cb, &g_test_3d_state.test_model, &g_test_3d_state.test_material)
			r3d.draw_model(cb, &g_test_3d_state.test_model2, &g_test_3d_state.test_material)

			r3d.debug_draw_primitives(&r3d.g_r3d_state.debug_renderer_state, cb, g_test_3d_state.scene_view, fb.dimensions)
		}
		rhi.cmd_end_render_pass(cb)

		r3d.end_frame(cb, image_index)
	}
}

draw :: proc() {
	when ENABLE_DRAW_3D_DEBUG_TEST {
		draw_3d()
	}

	when ENABLE_DRAW_2D_TEST {
		draw_2d()
	}

	when ENABLE_DRAW_EXAMPLE_TEST {
		de_draw()
	}
}
