package spelmotor_sandbox

import "base:runtime"
import "core:fmt"
import "core:image/png"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/fixed"
import "core:mem"
import "core:prof/spall"
import "core:slice"
import "core:strings"
import "core:time"
import "vendor:cgltf"

import "sm:core"
import "sm:csg"
import "sm:platform"
import "sm:rhi"
import r2im "sm:renderer/2d_immediate"
import R "sm:renderer"

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
			fmt.printfln("Total memory allocated: %i", t.total_memory_allocated)
			fmt.printfln("Total memory freed: %i", t.total_memory_freed)
			if len(t.allocation_map) > 0 {
				fmt.printfln("%i allocations not freed!", len(t.allocation_map))
				for _, entry in t.allocation_map {
					fmt.printfln(" * %m at %s", entry.size, entry.location)
				}
			}
			if len(t.bad_free_array) > 0 {
				fmt.printfln("%i incorrect frees!", len(t.bad_free_array))
				for entry in t.bad_free_array {
					fmt.printfln(" * at %s", entry.location)
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

			case .Right_Brace:
				if e.type == .Pressed {
					if g_bsp.debug_show_node != nil {
						if front_node, ok := g_bsp.debug_show_node.children[.FRONT].(^csg.BSP_Node); ok {
							g_bsp.debug_show_node = front_node
						}
					}
				}
			case .Left_Brace:
				if e.type == .Pressed {
					if g_bsp.debug_show_node != nil {
						if back_node, ok := g_bsp.debug_show_node.children[.BACK].(^csg.BSP_Node); ok {
							g_bsp.debug_show_node = back_node
						}
					}
				}
			case .Backslash:
				if e.type == .Pressed {
					g_bsp.debug_show_node = g_bsp.debug_show_node.parent if g_bsp.debug_show_node != nil else g_bsp.root
				}
			case .Apostrophe:
				if e.type == .Pressed {
					g_bsp.debug_show_planes = !g_bsp.debug_show_planes
				}
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
	if r := rhi.init(&g_rhi, .Vulkan, main_window, "Spelmotor Sandbox", {1,0,0}); r != nil {
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
		r2im_res := r2im.init(&g_rhi)
		defer r2im.shutdown()
		if r2im_res != nil {
			r2im.log_result(r2im_res)
			return
		}
	}

	when ENABLE_DRAW_3D_DEBUG_TEST {
		r3d_res := R.init(&g_renderer, &g_rhi)
		defer R.shutdown()
		if r3d_res != nil {
			return
		}
	}

	// Finally, show the main window
	platform.show_window(main_window)

	dpi := platform.get_window_dpi(main_window)
	when ENABLE_DRAW_3D_DEBUG_TEST {
		g_text_geo = R.create_text_geometry("BRAVO T. F. V. VA Y. tj gj aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
		defer R.destroy_text_geometry(&g_text_geo)

		if r := init_3d(); r != nil {
			core.error_log(r.?)
		}
		defer shutdown_3d()

		csg.init(&g_csg.state)
		defer csg.shutdown(&g_csg.state)

		csg.g_bsp_prof.spall_ctx = spall.context_create("bsp_prof.spall")
		defer spall.context_destroy(&csg.g_bsp_prof.spall_ctx)

		buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
		defer delete(buffer_backing)

		csg.g_bsp_prof.spall_buffer = spall.buffer_create(buffer_backing)
		defer spall.buffer_destroy(&csg.g_bsp_prof.spall_ctx, &csg.g_bsp_prof.spall_buffer)

		// CSG BRUSHES CREATION -----------------------------------------------------------------------------------------

		brush0_transform := linalg.matrix4_translate_f32({0,0,0})// * linalg.matrix4_scale_f32({1.125,1.125,1.125})
		g_csg.brushes[0], g_csg.handles[0] = csg.create_brush(&g_csg.state, {
			csg.plane_transform(csg.Plane{ 1, 0, 0,1}, brush0_transform),
			csg.plane_transform(csg.Plane{ 0, 1, 0,1}, brush0_transform),
			csg.plane_transform(csg.Plane{ 0,-1, 0,1}, brush0_transform),
			csg.plane_transform(csg.Plane{-1, 0, 0,1}, brush0_transform),
			csg.plane_transform(csg.Plane{ 0, 0, 1,1}, brush0_transform),
			csg.plane_transform(csg.Plane{ 0, 0,-1,1}, brush0_transform),
		})
		defer csg.destroy_brush(&g_csg.state, g_csg.handles[0])

		brush1_transform := linalg.matrix4_translate_f32({-1,-1,3})// * linalg.matrix4_scale_f32({1.5,1.5,1.5})
		g_csg.brushes[1], g_csg.handles[1] = csg.create_brush(&g_csg.state, {
			csg.plane_transform(csg.Plane{ 1, 0, 0,1}, brush1_transform),
			csg.plane_transform(csg.Plane{ 0, 1, 0,1}, brush1_transform),
			csg.plane_transform(csg.Plane{ 0,-1, 0,1}, brush1_transform),
			csg.plane_transform(csg.Plane{-1, 0, 0,1}, brush1_transform),
			csg.plane_transform(csg.Plane{ 0, 0, 1,1}, brush1_transform),
			csg.plane_transform(csg.Plane{ 0, 0,-1,1}, brush1_transform),
		})
		defer csg.destroy_brush(&g_csg.state, g_csg.handles[1])

		brush2_transform := linalg.matrix4_translate_f32({-0.5,-0.5,1.5})// * linalg.matrix4_scale_f32({1,1,1.5})
		g_csg.brushes[2], g_csg.handles[2] = csg.create_brush(&g_csg.state, {
			csg.plane_transform(csg.Plane{ 1, 0, 0,1}, brush2_transform),
			csg.plane_transform(csg.Plane{ 0, 1, 0,1}, brush2_transform),
			csg.plane_transform(csg.Plane{ 0,-1, 0,1}, brush2_transform),
			csg.plane_transform(csg.Plane{-1, 0, 0,1}, brush2_transform),
			csg.plane_transform(csg.Plane{ 0, 0, 1,1}, brush2_transform),
			csg.plane_transform(csg.Plane{ 0, 0,-1,1}, brush2_transform),
		})
		defer csg.destroy_brush(&g_csg.state, g_csg.handles[2])

		brush3_transform := linalg.matrix4_translate_f32({2,0,0})// * linalg.matrix4_scale_f32({1.125,1.125,1.125})
		g_csg.brushes[3], g_csg.handles[3] = csg.create_brush(&g_csg.state, {
			csg.plane_transform(csg.Plane{ 1, 0, 0,1},   brush3_transform),
			csg.plane_transform(csg.Plane{ 0, 1, 0,1},   brush3_transform),
			csg.plane_transform(csg.Plane{ 0,-1, 0,1},   brush3_transform),
			csg.plane_transform(csg.Plane{-1, 0, 0,1},   brush3_transform),
			csg.plane_transform(csg.Plane{ 0, 0, 1,0.6}, brush3_transform),
			csg.plane_transform(csg.Plane{ 0, 0,-1,1},   brush3_transform),
		})
		defer csg.destroy_brush(&g_csg.state, g_csg.handles[3])

		brush4_transform := linalg.matrix4_translate_f32({3,0,0})// * linalg.matrix4_scale_f32({1.125,1.125,1.125})
		g_csg.brushes[4], g_csg.handles[4] = csg.create_brush(&g_csg.state, {
			csg.plane_transform(csg.Plane{ 1, 0, 0,1},   brush4_transform),
			csg.plane_transform(csg.Plane{ 0, 1, 0,1},   brush4_transform),
			csg.plane_transform(csg.Plane{ 0,-1, 0,1},   brush4_transform),
			csg.plane_transform(csg.Plane{-1, 0, 0,1},   brush4_transform),
			csg.plane_transform(csg.Plane{ 0, 0, 1,0.4}, brush4_transform),
			csg.plane_transform(csg.Plane{ 0, 0,-1,1},   brush4_transform),
		})
		defer csg.destroy_brush(&g_csg.state, g_csg.handles[4])

		// Setup BSP allocators --------------------------------------------------------------------------------------

		bsp_allocators: csg.BSP_Allocators

		node_arena: mem.Arena
		mem.arena_init(&node_arena, make([]byte, 10 * mem.Megabyte))
		defer delete(node_arena.data)
		bsp_allocators.node_allocator = mem.arena_allocator(&node_arena)
		defer mem.arena_free_all(&node_arena)

		polygon_array_arena: mem.Arena
		mem.arena_init(&polygon_array_arena, make([]byte, 10 * mem.Megabyte))
		defer delete(polygon_array_arena.data)
		bsp_allocators.polygon_array_allocator = mem.arena_allocator(&polygon_array_arena)
		defer mem.arena_free_all(&polygon_array_arena)

		vertex_array_arena: mem.Arena
		mem.arena_init(&vertex_array_arena, make([]byte, 10 * mem.Megabyte))
		defer delete(vertex_array_arena.data)
		bsp_allocators.vertex_array_allocator = mem.arena_allocator(&vertex_array_arena)
		defer mem.arena_free_all(&vertex_array_arena)

		bsp_allocators.temp_allocator = context.temp_allocator

		// BSP Benchmark -----------------------------------------------------------------------------------------------

		for i in 0..<10 {
			bsp_0, _ := csg.bsp_create_from_brush(g_csg.brushes[0], bsp_allocators)
			defer csg.bsp_destroy_tree(&bsp_0, bsp_allocators)
			bsp_1, _ := csg.bsp_create_from_brush(g_csg.brushes[1], bsp_allocators)
			defer csg.bsp_destroy_tree(&bsp_1, bsp_allocators)
			bsp_2, _ := csg.bsp_create_from_brush(g_csg.brushes[2], bsp_allocators)
			defer csg.bsp_destroy_tree(&bsp_2, bsp_allocators)
			bsp_3, _ := csg.bsp_create_from_brush(g_csg.brushes[3], bsp_allocators)
			defer csg.bsp_destroy_tree(&bsp_3, bsp_allocators)
			bsp_4, _ := csg.bsp_create_from_brush(g_csg.brushes[4], bsp_allocators)
			defer csg.bsp_destroy_tree(&bsp_4, bsp_allocators)

			sw_bsp_merge: time.Stopwatch
			time.stopwatch_start(&sw_bsp_merge)

			csg.bsp_merge_trees(&bsp_0, &bsp_2, .UNION)
			csg.bsp_merge_trees(&bsp_0, &bsp_1, .UNION)
			csg.bsp_merge_trees(&bsp_0, &bsp_3, .UNION)
			csg.bsp_merge_trees(&bsp_0, &bsp_4, .UNION)

			time.stopwatch_stop(&sw_bsp_merge)
			bsp_merge_dur := time.stopwatch_duration(sw_bsp_merge)
			bsp_merge_ms := time.duration_milliseconds(bsp_merge_dur)
			log.infof("BSP MERGE %i DURATION: %.3fms", i, bsp_merge_ms)
		}

		// BSP FROM CSG CREATION -----------------------------------------------------------------------------------------

		bsp_0, _ := csg.bsp_create_from_brush(g_csg.brushes[0], bsp_allocators)
		defer csg.bsp_destroy_tree(&bsp_0, bsp_allocators)
		bsp_1, _ := csg.bsp_create_from_brush(g_csg.brushes[1], bsp_allocators)
		defer csg.bsp_destroy_tree(&bsp_1, bsp_allocators)
		bsp_2, _ := csg.bsp_create_from_brush(g_csg.brushes[2], bsp_allocators)
		defer csg.bsp_destroy_tree(&bsp_2, bsp_allocators)
		bsp_3, _ := csg.bsp_create_from_brush(g_csg.brushes[3], bsp_allocators)
		defer csg.bsp_destroy_tree(&bsp_3, bsp_allocators)
		bsp_4, _ := csg.bsp_create_from_brush(g_csg.brushes[4], bsp_allocators)
		defer csg.bsp_destroy_tree(&bsp_4, bsp_allocators)

		// FIXME: merging (0|1)|2 will generate a hollow space inside the 2 brush.
		csg.bsp_merge_trees(&bsp_0, &bsp_2, .UNION)
		csg.bsp_merge_trees(&bsp_0, &bsp_1, .UNION)
		csg.bsp_merge_trees(&bsp_0, &bsp_3, .UNION)
		csg.bsp_merge_trees(&bsp_0, &bsp_4, .UNION)

		csg.bsp_print(bsp_0.root)

		g_bsp.root = bsp_0.root
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

g_rhi: rhi.State
g_renderer: R.State

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

g_text_geo: R.Text_Geometry
g_test_3d_state: struct {
	rp: rhi.RHI_Render_Pass,
	framebuffers: [rhi.MAX_FRAMES_IN_FLIGHT]rhi.Framebuffer,
	textures: [rhi.MAX_FRAMES_IN_FLIGHT]R.RTexture_2D,
	text_pipeline: rhi.RHI_Pipeline,
	mesh_pipeline: rhi.RHI_Pipeline,

	test_mesh: R.RMesh,
	test_model: R.RModel,
	test_texture: R.RTexture_2D,
	test_material: R.RMaterial,
	test_texture2: R.RTexture_2D,
	test_material2: R.RMaterial,

	test_mesh2: R.RMesh,
	test_model2: R.RModel,

	test_mesh3: R.RMesh,
	test_model3: R.RModel,

	test_terrain: R.RTerrain,

	scene: R.RScene,
	scene_view: R.RScene_View,

	main_light_index: int,
}

g_csg: struct {
	state: csg.CSG_State,

	brushes: [1000]csg.Brush,
	handles: [1000]csg.Brush_Handle,
}

g_bsp: struct {
	root: ^csg.BSP_Node,

	show_node: int,
	debug_show_node: ^csg.BSP_Node,
	debug_show_planes: bool,
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

init_3d :: proc() -> rhi.Result {
	g_test_3d_state.mesh_pipeline = R.create_mesh_pipeline(R.Mesh_Pipeline_Specializations{}) or_return

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
	g_test_3d_state.text_pipeline = R.create_text_pipeline(g_test_3d_state.rp) or_return

	// Create the render targets for the render pass
	for i in 0..<rhi.MAX_FRAMES_IN_FLIGHT {
		r: rhi.Result
		if g_test_3d_state.textures[i], r = R.create_texture_2d(nil, {256,256}, .RGBA8_SRGB, .NEAREST, .REPEAT, g_renderer.quad_renderer_state.descriptor_set_layout); r != nil {
			core.error_log(r.?)
		}
		g_test_3d_state.framebuffers[i] = rhi.create_framebuffer(g_test_3d_state.rp, {&g_test_3d_state.textures[i].texture_2d}) or_return
	}

	g_test_3d_state.scene = R.create_scene() or_return
	g_test_3d_state.scene_view = R.create_scene_view() or_return

	// Create a test plane mesh
	vertices := [?]R.Mesh_Vertex{
		{position = {-1, 1,0}, normal = core.VEC3_UP, tex_coord = {0,0}},
		{position = { 1, 1,0}, normal = core.VEC3_UP, tex_coord = {1,0}},
		{position = { 1,-1,0}, normal = core.VEC3_UP, tex_coord = {1,1}},
		{position = {-1,-1,0}, normal = core.VEC3_UP, tex_coord = {0,1}},
	}
	indices := [?]u32{
		0, 1, 2,
		2, 3, 0,
	}
	test_primitive := R.create_primitive(vertices[:], indices[:]) or_return
	g_test_3d_state.test_mesh = R.create_mesh({&test_primitive}) or_return
	g_test_3d_state.test_model = R.create_model(&g_test_3d_state.test_mesh) or_return

	img, err := png.load(core.path_make_engine_textures_relative("test.png"), png.Options{.alpha_add_if_missing})
	defer png.destroy(img)
	assert(img.channels == 4, "Loaded image channels must be 4.")
	img_dimensions := [2]u32{u32(img.width), u32(img.height)}
	g_test_3d_state.test_texture = R.create_texture_2d(img.pixels.buf[:], img_dimensions, .RGBA8_SRGB, .LINEAR, .REPEAT, g_renderer.material_descriptor_set_layout) or_return
	g_test_3d_state.test_material = R.create_material(&g_test_3d_state.test_texture) or_return

	img2, err2 := png.load(core.path_make_engine_textures_relative("test2.png"), png.Options{.alpha_add_if_missing})
	defer png.destroy(img2)
	assert(img2.channels == 4, "Loaded image channels must be 4.")
	img_dimensions2 := [2]u32{u32(img2.width), u32(img2.height)}
	g_test_3d_state.test_texture2 = R.create_texture_2d(img2.pixels.buf[:], img_dimensions2, .RGBA8_SRGB, .LINEAR, .REPEAT, g_renderer.material_descriptor_set_layout) or_return
	g_test_3d_state.test_material2 = R.create_material(&g_test_3d_state.test_texture2) or_return

	gltf_config := R.gltf_make_config_from_vertex(R.Mesh_Vertex)
	gltf_mesh, gltf_res := R.import_mesh_gltf(core.path_make_engine_models_relative("Sphere.glb"), R.Mesh_Vertex, gltf_config, context.temp_allocator)
	core.result_verify(gltf_res)
	test_primitive2 := R.create_primitive(gltf_mesh.primitives[0].vertices, gltf_mesh.primitives[0].indices) or_return
	g_test_3d_state.test_mesh2 = R.create_mesh({&test_primitive2}) or_return
	g_test_3d_state.test_model2 = R.create_model(&g_test_3d_state.test_mesh2) or_return

	gltf_double_sphere_mesh, gltf_res3 := R.import_mesh_gltf(core.path_make_engine_models_relative("double_sphere.glb"), R.Mesh_Vertex, gltf_config, context.temp_allocator)
	core.result_verify(gltf_res3)
	gltf_double_sphere_prim1 := R.create_primitive(gltf_double_sphere_mesh.primitives[0].vertices, gltf_double_sphere_mesh.primitives[0].indices) or_return
	gltf_double_sphere_prim2 := R.create_primitive(gltf_double_sphere_mesh.primitives[1].vertices, gltf_double_sphere_mesh.primitives[1].indices) or_return
	g_test_3d_state.test_mesh3 = R.create_mesh({&gltf_double_sphere_prim1, &gltf_double_sphere_prim2}) or_return
	g_test_3d_state.test_model3 = R.create_model(&g_test_3d_state.test_mesh3) or_return

	g_test_3d_state.scene.ambient_light = {0.005, 0.006, 0.007}
	// Add a simple light
	append_elem(&g_test_3d_state.scene.lights, R.Light_Info{
		location = {0,0,2},
		color = {1,0.94,0.9},
		attenuation_radius = 10,
		intensity = 1,
	})
	g_test_3d_state.main_light_index = len(g_test_3d_state.scene.lights) - 1

	gltf_terrain_config := R.gltf_make_config_from_vertex(R.Terrain_Vertex)
	gltf_terrain, gltf_res2 := R.import_mesh_gltf(core.path_make_engine_models_relative("terrain2m.glb"), R.Terrain_Vertex, gltf_terrain_config, context.temp_allocator)
	core.result_verify(gltf_res2)
	g_test_3d_state.test_terrain = R.create_terrain(gltf_terrain.primitives[0].vertices, gltf_terrain.primitives[0].indices, &g_test_3d_state.test_texture) or_return
	g_test_3d_state.test_terrain.height_scale = 5

	return nil
}

shutdown_3d :: proc() {
	R.destroy_terrain(&g_test_3d_state.test_terrain)

	R.destroy_model(&g_test_3d_state.test_model3)
	R.destroy_mesh(&g_test_3d_state.test_mesh3)

	R.destroy_model(&g_test_3d_state.test_model2)
	R.destroy_mesh(&g_test_3d_state.test_mesh2)

	R.destroy_material(&g_test_3d_state.test_material)
	R.destroy_texture_2d(&g_test_3d_state.test_texture)

	R.destroy_material(&g_test_3d_state.test_material2)
	R.destroy_texture_2d(&g_test_3d_state.test_texture2)

	R.destroy_model(&g_test_3d_state.test_model)
	R.destroy_mesh(&g_test_3d_state.test_mesh)

	R.destroy_scene_view(&g_test_3d_state.scene_view)
	R.destroy_scene(&g_test_3d_state.scene)

	rhi.destroy_render_pass(&g_test_3d_state.rp)
	rhi.destroy_graphics_pipeline(&g_test_3d_state.text_pipeline)
	for i in 0..<rhi.MAX_FRAMES_IN_FLIGHT {
		rhi.destroy_framebuffer(&g_test_3d_state.framebuffers[i])
		R.destroy_texture_2d(&g_test_3d_state.textures[i])
	}

	rhi.destroy_graphics_pipeline(&g_test_3d_state.mesh_pipeline)
}

draw_3d :: proc() {
	main_window := platform.get_main_window()
	surface_key := rhi.get_surface_key_from_window(main_window)
	swapchain_images := rhi.get_swapchain_images(surface_key)
	assert(len(swapchain_images) > 0)
	swapchain_dims := swapchain_images[0].dimensions
	aspect_ratio := cast(f32)swapchain_dims.x / cast(f32)swapchain_dims.y

	// Update lights
	main_light := &g_test_3d_state.scene.lights[g_test_3d_state.main_light_index]
	main_light.location.x = cast(f32)math.sin(g_time * math.PI) * 2
	main_light.location.y = cast(f32)math.cos(g_time * math.PI) * 2
	R.debug_draw_sphere(main_light.location, core.QUAT_IDENTITY, 0.1, vec4(main_light.color, 1.0))

	// Update view (camera)
	g_test_3d_state.scene_view.view_info = R.View_Info{
		origin = g_camera.position,
		// Camera angles were specified in degrees here
		angles = linalg.to_radians(g_camera.angles),
		projection = R.Perspective_Projection_Info{
			vertical_fov = g_camera.fovy,
			aspect_ratio = aspect_ratio,
			near_clip_plane = 0.1,
		},
	}

	// Coordinate system axis
	R.debug_draw_arrow(Vec3{0,0,0}, Vec3{1,0,0}, Vec4{1,0,0,1})
	R.debug_draw_arrow(Vec3{0,0,0}, Vec3{0,1,0}, Vec4{0,1,0,1})
	R.debug_draw_arrow(Vec3{0,0,0}, Vec3{0,0,1}, Vec4{0,0,1,1})

	// 2x2x2 Cube
	// R.debug_draw_box(Vec3{0,0,0}, Vec3{1,1,1}, linalg.quaternion_angle_axis_f32(math.PI/2 * f32(g_time), Vec3{0,0,1}), Vec4{1,1,1,1})

	// Circumscribed sphere
	// R.debug_draw_sphere(Vec3{0,0,0}, QUAT_IDENTITY, math.SQRT_THREE, Vec4{1,1,1,0.25}, 32)

	// triangle := [3]Vec3{
	// 	{1, -5, -1},
	// 	{-1, -5, -1},
	// 	{0, -5, 1},
	// }
	// R.debug_draw_filled_triangle(triangle, Vec4{1,0,0,0.01})

	// shape := [?]Vec2{
	// 	{-1,-1},
	// 	{-1, 1},
	// 	{ 0, 1},
	// 	{ 1, 0},
	// 	{ 0,-1},
	// }
	// shape_matrix := linalg.matrix4_translate_f32(Vec3{2, 0, -1}) * linalg.matrix4_rotate_f32(math.PI/2, Vec3{1,0,0})
	// R.debug_draw_filled_2d_convex_shape(shape[:], shape_matrix, Vec4{0,1,0,0.1})

	// Update models
	g_test_3d_state.test_model.data.location = {2, 0, 0}
	g_test_3d_state.test_model.data.scale = {10, 10, 10}
	
	g_test_3d_state.test_model2.data.location = {-2, -1, 1}
	z_rot := f32(g_time * math.PI)
	g_test_3d_state.test_model2.data.rotation = {0, 0, z_rot}

	g_test_3d_state.test_material.specular = (math.sin(f32(g_time * math.PI*2)) + 1) * 0.5
	g_test_3d_state.test_material.specular_hardness = 100

	g_test_3d_state.test_model3.data.location = {0, 0, 5}

	// Brushes debug drawing
	// for ib in 0..<2 {
	// 	vertices := g_csg.brushes[ib].vertices
	// 	polygons := g_csg.brushes[ib].polygons
	// 	for v in vertices {
	// 		if v.w == 0 {
	// 			continue
	// 		}
	// 		R.debug_draw_sphere(v.xyz, core.QUAT_IDENTITY, 0.1, {1,1,1,0.5})
	// 	}
	// 	for p := polygons; p != nil; p = csg.get_next_brush_polygon(p) {
	// 		indices := csg.get_polygon_indices(p)
	// 		shape := make([]Vec3, len(indices), context.temp_allocator)
	// 		for idx, i in indices {
	// 			shape[i] = vertices[idx].xyz
	// 		}
	// 		R.debug_draw_filled_3d_convex_shape(shape, {0,1,0,0.1})
	// 		for i in 0..<len(shape) {
	// 			p0 := shape[i]
	// 			p1 := shape[(i+1)%len(shape)]
	// 			// The line will be drawn twice because it's shared by two
	// 			// polygons but it doesn't matter for this visualization.
	// 			R.debug_draw_line(p0, p1, Vec4{1,1,1,0.1})
	// 		}
	// 	}
	// }

	draw_bsp_node_debug :: proc(node: ^csg.BSP_Node) {
		if node == nil {
			return
		}
		plane := csg.plane_normalize(node.plane)
		square_verts := [4]Vec2{
			{-10000, -10000},
			{-10000,  10000},
			{ 10000,  10000},
			{ 10000, -10000},
		}
		// Transform the infinite square to the 3D plane's surface
		poly_vertices := make([dynamic]Vec3, 4, context.temp_allocator)
		p_dot_up := linalg.vector_dot(plane.xyz, VEC3_UP)
		for v, i in square_verts {
			if 1 - p_dot_up < csg.EPSILON {
				poly_vertices[i] = vec3(v, plane.w)
			} else if 1 + p_dot_up < csg.EPSILON {
				poly_vertices[i] = {-v.x, v.y, -plane.w}
			} else {
				orientation := linalg.matrix4_orientation_f32(plane.xyz, VEC3_UP)
				poly_vertices[i] = (orientation * vec4(v, plane.w, 1)).xyz
			}
		}
		
		clip_poly_reverse :: proc(node: ^csg.BSP_Node, poly_vertices: ^[dynamic]Vec3) {
			parent := node.parent
			if parent == nil {
				return
			}
		
			plane := parent.plane if node.side == .BACK else csg.plane_invert(parent.plane)
			csg.clip_poly_by_plane_in_place(poly_vertices, plane)
			// If the polygon is not at least a triangle, all vertices must have been clipped
			if len(poly_vertices) < 3 {
				return
			}
		
			clip_poly_reverse(node.parent, poly_vertices)
		}
		clip_poly_reverse(node, &poly_vertices)

		// Invalid polygons may be produced by clipping
		if len(poly_vertices) < 3 {
			return
		}

		if g_bsp.debug_show_planes {
			// Blue from the front
			R.debug_draw_filled_3d_convex_shape(poly_vertices[:], Vec4{0,0,1,0.1})
			// Red from the back
			R.debug_draw_filled_3d_convex_shape(poly_vertices[:], Vec4{1,0,0,0.1}, invert=true)
		}

		for c, side in node.children {
			switch v in c {
			case ^csg.BSP_Leaf:
				for p in v.polygons {
					if len(p.vertices) < 3 do continue
					// polygons on the back side shouldn't be a thing
					color := Vec4{0,1,1,0.1} if side == .FRONT else Vec4{1,1,0,0.1}
					R.debug_draw_filled_3d_convex_shape(p.vertices[:], color)
					R.debug_draw_filled_3d_convex_shape(p.vertices[:], color, invert=true)
				}
			case ^csg.BSP_Node:
			}
		}
	}
	draw_bsp_debug :: proc(node: ^csg.BSP_Node, node_counter: ^int) {
		assert(node != nil)
		assert(node_counter != nil)
		node_counter^ += 1
		if node_counter^ == g_bsp.show_node {
			draw_bsp_node_debug(node)
		} else {
			for c in node.children {
				switch v in c {
				case ^csg.BSP_Node:
					draw_bsp_debug(v, node_counter)
				case ^csg.BSP_Leaf:
				}
			}
		}
	}
	// node_counter := 0
	// draw_bsp_debug(g_bsp.root, &node_counter)
	draw_bsp_node_debug(g_bsp.debug_show_node)

	draw_bsp_polygons_debug :: proc(root: ^csg.BSP_Node) {
		assert(root != nil)
		
		for c in root.children {
			switch v in c {
			case ^csg.BSP_Node:
				draw_bsp_polygons_debug(v)
			case ^csg.BSP_Leaf:
				for poly in v.polygons {
					if len(poly.vertices) < 3 {
						continue
					}
					shape := make([]Vec3, len(poly.vertices), context.temp_allocator)
					for v, i in poly.vertices {
						shape[i] = v.xyz
					}
					R.debug_draw_filled_3d_convex_shape(shape, Vec4{0,1,0,0.1})
					for i in 0..<len(shape) {
						p0 := shape[i]
						p1 := shape[(i+1)%len(shape)]
						// The lines will be overlaid on top of each other,
						// but it doesn't matter for this visualization.
						R.debug_draw_line(p0, p1, Vec4{1,1,1,0.1})
					}
				}
			}
		}
	}
	draw_bsp_polygons_debug(g_bsp.root)

	if cb, image_index := R.begin_frame(); cb != nil {
		frame_in_flight := g_rhi.frame_in_flight

		// Upload all uniform data
		R.update_scene_uniforms(&g_test_3d_state.scene)
		R.update_scene_view_uniforms(&g_test_3d_state.scene_view)

		R.update_model_uniforms(&g_test_3d_state.test_model)
		R.update_model_uniforms(&g_test_3d_state.test_model2)
		R.update_model_uniforms(&g_test_3d_state.test_model3)

		R.update_material_uniforms(&g_test_3d_state.test_material)
		R.update_material_uniforms(&g_test_3d_state.test_material2)

		R.debug_update(&g_renderer.debug_renderer_state)

		// Drawing here
		main_rp := &g_renderer.main_render_pass
		fb := &main_rp.framebuffers[image_index]

		// Draw some text off screen
		rhi.cmd_begin_render_pass(cb, g_test_3d_state.rp, g_test_3d_state.framebuffers[frame_in_flight])
		{
			rhi.cmd_set_viewport(cb, {0, 0}, {256, 256}, 0, 1)
			rhi.cmd_set_scissor(cb, {0, 0}, {256, 256})
			R.bind_text_pipeline(cb, g_test_3d_state.text_pipeline)
			R.draw_text_geometry(cb, g_text_geo, {40, 40}, {256, 256})
		}
		rhi.cmd_end_render_pass(cb)

		// Main render pass
		rhi.cmd_begin_render_pass(cb, main_rp.render_pass, fb^)
		{
			rhi.cmd_set_viewport(cb, {0, 0}, core.array_cast(f32, fb.dimensions), 0, 1)
			rhi.cmd_set_scissor(cb, {0, 0}, fb.dimensions)
			rhi.cmd_set_backface_culling(cb, true)

			// R.bind_text_pipeline(cb, nil)
			R.draw_text_geometry(cb, g_text_geo, {20, 14}, fb.dimensions)

			R.draw_full_screen_quad(cb, g_test_3d_state.textures[frame_in_flight])

			// Draw the scene with meshes
			rhi.cmd_bind_graphics_pipeline(cb, g_test_3d_state.mesh_pipeline)
			R.bind_scene(cb, &g_test_3d_state.scene, R.mesh_pipeline_layout()^)
			R.bind_scene_view(cb, &g_test_3d_state.scene_view, R.mesh_pipeline_layout()^)
			// R.draw_model(cb, &g_test_3d_state.test_model, &g_test_3d_state.test_material, &g_test_3d_state.scene_view)
			R.draw_model(cb, &g_test_3d_state.test_model2, {&g_test_3d_state.test_material}, &g_test_3d_state.scene_view)
			R.draw_model(cb, &g_test_3d_state.test_model3, {&g_test_3d_state.test_material, &g_test_3d_state.test_material2}, &g_test_3d_state.scene_view)

			R.bind_terrain_pipeline(cb)
			R.bind_scene(cb, &g_test_3d_state.scene, R.terrain_pipeline_layout()^)
			R.bind_scene_view(cb, &g_test_3d_state.scene_view, R.terrain_pipeline_layout()^)
			R.draw_terrain(cb, &g_test_3d_state.test_terrain, &g_test_3d_state.test_material, false)

			R.debug_draw_primitives(&g_renderer.debug_renderer_state, cb, g_test_3d_state.scene_view, fb.dimensions)
		}
		rhi.cmd_end_render_pass(cb)

		R.end_frame(cb, image_index)
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
