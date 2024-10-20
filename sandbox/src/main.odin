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

ENABLE_DRAW_EXAMPLE_TEST :: false

SIXTY_FPS_DT :: 1.0 / 60.0

Matrix4 :: matrix[4, 4]f32
Vec2 :: [2]f32
Vec3 :: [3]f32

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

	r2im_res := r2im.init()
	defer r2im.shutdown()
	if r2im_res != nil {
		r2im.log_result(r2im_res)
		return
	}

	// Finally, show the main window
	platform.show_window(main_window)

	// Free after initialization
	free_all(context.temp_allocator)

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
}

now_seconds :: proc() -> f64 {
	return f64(time.tick_now()._nsec) * 0.000001
}

g_time: f64
g_position: Vec2

update :: proc(dt: f64) {
	g_time += dt
	g_position.x = cast(f32) math.sin_f64(g_time) * 50
	g_position.y = cast(f32) math.cos_f64(g_time) * 50

	when ENABLE_DRAW_EXAMPLE_TEST {
		de_update()
	}
}

draw :: proc() {
	if r2im.begin_frame() {
		for y in -40..=40 {
			for x in -40..=40 {
				u := f32(x + 40) / 80
				v := f32(y + 40) / 80
				r2im.draw_sprite(g_position + {f32(x * 20), f32(y * 20)}, 0, {20, 20}, core.path_make_engine_textures_relative("test.png"), {u, v, 1, 1})
			}
		}
		// r2im.draw_sprite({0, 100}, 0, {200, 200}, core.path_make_engine_textures_relative("test.png"), {1, 1, 1, 1})
		// r2im.draw_sprite({200, 0}, 0, {20, 20}, core.path_make_engine_textures_relative("test.png"), {0, 0, 1, 1})
		r2im.end_frame()
	}

	when ENABLE_DRAW_EXAMPLE_TEST {
		de_draw()
	}
}
