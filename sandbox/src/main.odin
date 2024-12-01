package spelmotor_sandbox

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:image/png"
import "core:strings"
import "core:time"
import "vendor:cgltf"

import "sm:core"
import "sm:platform"
import "sm:rhi"
import r2im "sm:renderer/2d_immediate"
import r3d "sm:renderer/3d"

// TODO: Add more error info on each step up!

ENABLE_DRAW_EXAMPLE_TEST  :: false
ENABLE_DRAW_2D_TEST       :: false
ENABLE_DRAW_3D_DEBUG_TEST :: true

SIXTY_FPS_DT :: 1.0 / 60.0

Matrix4 :: matrix[4, 4]f32
Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32
Quat :: quaternion128
QUAT_IDENTITY :: linalg.QUATERNIONF32_IDENTITY
MATRIX4_IDENTITY :: linalg.MATRIX4F32_IDENTITY

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
		rhi.handle_error(&r.(rhi.RHI_Error))
		log.fatal(r.(rhi.RHI_Error).error_message)
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

draw_3d :: proc() {
	main_window := platform.get_main_window()
	surface_index := rhi.get_surface_index_from_window(main_window)
	swapchain_images := rhi.get_swapchain_images(surface_index)
	assert(len(swapchain_images) > 0)
	swapchain_dims := swapchain_images[0].dimensions
	aspect_ratio := cast(f32)swapchain_dims.x / cast(f32)swapchain_dims.y

	s := r3d.access_state()

	projection_matrix := linalg.matrix4_infinite_perspective_f32(g_camera.fovy, aspect_ratio, 0.1, false)
	// Convert from my preferred X-right,Y-forward,Z-up to Vulkan's clip space
	coord_system_matrix := Matrix4{
		1,0, 0,0,
		0,0,-1,0,
		0,1, 0,0,
		0,0, 0,1,
	}
	view_rotation_matrix := linalg.matrix4_inverse_f32(linalg.matrix4_from_euler_angles_zxy_f32(
		math.to_radians_f32(g_camera.angles.z),
		math.to_radians_f32(g_camera.angles.x),
		math.to_radians_f32(g_camera.angles.y),
	))
	view_matrix := view_rotation_matrix * linalg.matrix4_translate_f32(-g_camera.position)
	s.view_info = r3d.View_Info{
		view_projection_matrix = projection_matrix * coord_system_matrix * view_matrix,
		view_origin = g_camera.position,
	}

	// Coordinate system axis
	r3d.debug_draw_arrow(Vec3{0,0,0}, Vec3{1,0,0}, Vec4{1,0,0,1})
	r3d.debug_draw_arrow(Vec3{0,0,0}, Vec3{0,1,0}, Vec4{0,1,0,1})
	r3d.debug_draw_arrow(Vec3{0,0,0}, Vec3{0,0,1}, Vec4{0,0,1,1})

	// 2x2x2 Cube
	r3d.draw_debug_box(Vec3{0,0,0}, Vec3{1,1,1}, linalg.quaternion_angle_axis_f32(math.PI/2 * f32(g_time), Vec3{0,0,1}), Vec4{1,1,1,1})

	// Circumscribed sphere
	r3d.debug_draw_sphere(Vec3{0,0,0}, QUAT_IDENTITY, math.SQRT_THREE, Vec4{1,1,1,0.25}, 32)

	triangle := [3]Vec3{
		{1, -5, -1},
		{-1, -5, -1},
		{0, -5, 1},
	}
	r3d.debug_draw_filled_triangle(triangle, Vec4{1,0,0,0.01})

	shape := [?]Vec2{
		{-1,-1},
		{-1, 1},
		{ 0, 1},
		{ 1, 0},
		{ 0,-1},
	}
	shape_matrix := linalg.matrix4_translate_f32(Vec3{2, 0, -1}) * linalg.matrix4_rotate_f32(math.PI/2, Vec3{1,0,0})
	r3d.debug_draw_filled_2d_convex_shape(shape[:], shape_matrix, Vec4{0,1,0,0.1})

	r3d.draw()
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
