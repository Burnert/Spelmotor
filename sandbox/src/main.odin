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
import "sm:game"
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
	platform.g_platform.event_callback_proc = proc(window: platform.Window_Handle, event: platform.System_Event) {
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
						if front_node, ok := g_bsp.debug_show_node.children[.Front].(^csg.BSP_Node); ok {
							g_bsp.debug_show_node = front_node
						}
					}
				}
			case .Left_Brace:
				if e.type == .Pressed {
					if g_bsp.debug_show_node != nil {
						if back_node, ok := g_bsp.debug_show_node.children[.Back].(^csg.BSP_Node); ok {
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
			if g_input.capture {
				g_input.m_delta += Vec2{f32(e.x), f32(e.y)}
			}
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

	core.asset_registry_init(&g_asset_registry)
	defer core.asset_registry_shutdown(&g_asset_registry)
	
	core.asset_type_register_with_runtime_data(R.Texture_Asset, R.Texture_Asset_Runtime_Data)
	core.asset_type_register_with_runtime_data(R.Static_Mesh_Asset, R.Static_Mesh_Asset_Runtime_Data)
	core.asset_type_register(R.Material_Asset, R.material_asset_deleter)

	core.asset_register_all_from_filesystem()

	test_asset_path, test_asset := core.asset_register_virtual("test_asset")

	cube := core.asset_path_make("Engine:models/Cube")
	cube_asset := core.asset_resolve(cube)

	sphere := core.asset_path_make("Engine:models/Sphere")
	sphere_asset := core.asset_resolve(sphere)

	test_tex := core.asset_path_make("Engine:textures/test")
	test_tex_asset := core.asset_resolve(test_tex)

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

	game.world_init(&g_world)
	defer game.world_destroy(&g_world)

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

			csg.bsp_merge_trees(&bsp_0, &bsp_2, .Union)
			csg.bsp_merge_trees(&bsp_0, &bsp_1, .Union)
			csg.bsp_merge_trees(&bsp_0, &bsp_3, .Union)
			csg.bsp_merge_trees(&bsp_0, &bsp_4, .Union)

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
		csg.bsp_merge_trees(&bsp_0, &bsp_2, .Union)
		csg.bsp_merge_trees(&bsp_0, &bsp_1, .Union)
		csg.bsp_merge_trees(&bsp_0, &bsp_3, .Union)
		csg.bsp_merge_trees(&bsp_0, &bsp_4, .Union)

		csg.bsp_print(bsp_0.root)

		g_bsp.root = bsp_0.root
	}

	test_errors()

	entity,  entity_data  := game.entity_spawn(&g_world, game.make_transform(), {})
	entity2, entity_data2 := game.entity_spawn(&g_world, game.make_transform(), {})
	game.entity_destroy(entity_data)
	entity3, entity_data3 := game.entity_spawn(&g_world, game.make_transform(), {})
	game.entity_destroy(entity_data2)
	game.entity_destroy(entity_data3)

	sphere_asset_ref := core.asset_ref_resolve("Engine:models/Sphere", R.Static_Mesh_Asset)
	sod := game.Static_Object_Desc{
		mesh = sphere_asset_ref,
		trs_array = {
			game.make_transform(t={5,5,5}),
			game.make_transform(t={-5,-5,-5}),
		},
		name = "TestStaticObject",
	}
	sod.materials[0] = &g_test_3d_state.test_material
	game.world_add_static_object(&g_world, sod)

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
		draw(dt)

		// Free on frame end
		free_all(context.temp_allocator)

		now := time.tick_now()
		dt = time.duration_seconds(time.tick_diff(last_now, now))
		if dt > 1 {
			dt = SIXTY_FPS_DT
		}
		last_now = now

		g_frame += 1
	}

	log.info("Shutting down...")
}

g_asset_registry: core.Asset_Registry

g_rhi: rhi.State
g_renderer: R.State

g_time: f64
g_frame: uint
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
	textures: [rhi.MAX_FRAMES_IN_FLIGHT]R.Combined_Texture_Sampler,
	text_pipeline: rhi.RHI_Pipeline,
	mesh_pipeline: rhi.RHI_Pipeline,
	instanced_mesh_pipeline: rhi.RHI_Pipeline,

	dyn_text: R.Dynamic_Text_Buffers,

	test_mesh: R.Mesh,
	test_model: R.Model,
	test_texture: ^R.Combined_Texture_Sampler,
	test_material: R.Material,
	test_texture2: ^R.Combined_Texture_Sampler,
	test_material2: R.Material,

	test_mesh2: R.Mesh,
	test_model2: R.Model,

	test_mesh3: R.Mesh,
	test_model3: R.Model,

	test_terrain: R.Terrain,

	scene: R.Scene,
	scene_view: R.Scene_View,

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

g_world: game.World

update :: proc(dt: f64) {
	game.world_tick(&g_world, cast(f32)dt)

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
	g_test_3d_state.instanced_mesh_pipeline = R.create_instanced_mesh_pipeline(R.Mesh_Pipeline_Specializations{}) or_return

	// Create an off-screen render pass for rendering a test text texture
	rp_desc := rhi.Render_Pass_Desc{
		attachments = {
			rhi.Attachment_Desc{
				format = .RGBA8_Srgb,
				usage = .Color,
				load_op = .Clear,
				store_op = .Store,
				from_layout = .Undefined,
				to_layout = .Shader_Read_Only,
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
		if g_test_3d_state.textures[i], r = R.create_combined_texture_sampler(nil, {256,256}, .RGBA8_Srgb, .Nearest, .Repeat, g_renderer.quad_renderer_state.descriptor_set_layout); r != nil {
			core.error_log(r.?)
		}
		g_test_3d_state.framebuffers[i] = rhi.create_framebuffer(g_test_3d_state.rp, {&g_test_3d_state.textures[i].texture}) or_return
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

	// Load the test texture using the asset system
	test_tex_asset_ref := core.asset_ref_resolve("Engine:textures/test", R.Texture_Asset)
	g_test_3d_state.test_texture = R.get_combined_texture_sampler_from_asset(test_tex_asset_ref, g_renderer.material_descriptor_set_layout) or_return
	g_test_3d_state.test_material = R.create_material(g_test_3d_state.test_texture) or_return

	test2_tex_asset_ref := core.asset_ref_resolve("Engine:textures/test2", R.Texture_Asset)
	g_test_3d_state.test_texture2 = R.get_combined_texture_sampler_from_asset(test2_tex_asset_ref, g_renderer.material_descriptor_set_layout) or_return

	test2_mat_asset_ref := core.asset_ref_resolve("Engine:materials/test2", R.Material_Asset)
	g_test_3d_state.test_material2 = R.create_material_from_asset(test2_mat_asset_ref) or_return

	// Load the test mesh using the asset system
	sphere_asset_ref := core.asset_ref_resolve("Engine:models/Sphere", R.Static_Mesh_Asset)
	g_test_3d_state.test_mesh2 = R.create_mesh_from_asset(sphere_asset_ref) or_return
	g_test_3d_state.test_model2 = R.create_model(&g_test_3d_state.test_mesh2) or_return

	double_sphere_asset_ref := core.asset_ref_resolve("Engine:models/double_sphere", R.Static_Mesh_Asset)
	g_test_3d_state.test_mesh3 = R.create_mesh_from_asset(double_sphere_asset_ref) or_return
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

	terrain_asset_ref := core.asset_ref_resolve("Engine:models/terrain2m", R.Static_Mesh_Asset)

	gltf_terrain_config := core.gltf_make_config_from_vertex(R.Terrain_Vertex)
	gltf_terrain, gltf_res2 := core.import_mesh_gltf(core.path_make_engine_models_relative("terrain2m.glb"), R.Terrain_Vertex, gltf_terrain_config, context.temp_allocator)
	core.result_verify(gltf_res2)
	g_test_3d_state.test_terrain = R.create_terrain(gltf_terrain.primitives[0].vertices, gltf_terrain.primitives[0].indices, g_test_3d_state.test_texture) or_return
	g_test_3d_state.test_terrain.height_scale = 5

	g_test_3d_state.dyn_text = R.create_dynamic_text_buffers(10000) or_return

	return nil
}

shutdown_3d :: proc() {
	rhi.wait_for_device()

	R.destroy_dynamic_text_buffers(&g_test_3d_state.dyn_text)

	R.destroy_terrain(&g_test_3d_state.test_terrain)

	R.destroy_model(&g_test_3d_state.test_model3)
	R.destroy_mesh(&g_test_3d_state.test_mesh3)

	R.destroy_model(&g_test_3d_state.test_model2)
	R.destroy_mesh(&g_test_3d_state.test_mesh2)

	R.destroy_material(&g_test_3d_state.test_material)
	g_test_3d_state.test_texture = nil

	R.destroy_material(&g_test_3d_state.test_material2)
	g_test_3d_state.test_texture2 = nil

	R.destroy_model(&g_test_3d_state.test_model)
	R.destroy_mesh(&g_test_3d_state.test_mesh)

	R.destroy_scene_view(&g_test_3d_state.scene_view)
	R.destroy_scene(&g_test_3d_state.scene)

	rhi.destroy_render_pass(&g_test_3d_state.rp)
	rhi.destroy_graphics_pipeline(&g_test_3d_state.text_pipeline)
	for i in 0..<rhi.MAX_FRAMES_IN_FLIGHT {
		rhi.destroy_framebuffer(&g_test_3d_state.framebuffers[i])
		R.destroy_combined_texture_sampler(&g_test_3d_state.textures[i])
	}

	rhi.destroy_graphics_pipeline(&g_test_3d_state.instanced_mesh_pipeline)
	rhi.destroy_graphics_pipeline(&g_test_3d_state.mesh_pipeline)
}

draw_3d :: proc(dt: f64) {
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
		
			plane := parent.plane if node.side == .Back else csg.plane_invert(parent.plane)
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
					color := Vec4{0,1,1,0.1} if side == .Front else Vec4{1,1,0,0.1}
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

		// Update dynamic text buffers
		R.reset_dynamic_text_buffers(&g_test_3d_state.dyn_text)

		frame_num_text := fmt.tprint(g_frame)
		R.print_to_dynamic_text_buffers(&g_test_3d_state.dyn_text, frame_num_text, {0,14})

		fps := 1.0/dt
		fps_text := fmt.tprintf("%.2f FPS", fps)
		R.print_to_dynamic_text_buffers(&g_test_3d_state.dyn_text, fps_text, {0,28})

		// Drawing here
		main_rp := &g_renderer.main_render_pass
		fb := &main_rp.framebuffers[image_index]

		// Draw some text off screen
		rhi.cmd_begin_render_pass(cb, g_test_3d_state.rp, g_test_3d_state.framebuffers[frame_in_flight])
		{
			rhi.cmd_set_viewport(cb, {0, 0}, {256, 256}, 0, 1)
			rhi.cmd_set_scissor(cb, {0, 0}, {256, 256})
			rhi.cmd_set_backface_culling(cb, true)
			R.bind_text_pipeline(cb, g_test_3d_state.text_pipeline)
			R.bind_font(cb)
			R.draw_text_geometry(cb, g_text_geo, {40, 40}, {256, 256})
		}
		rhi.cmd_end_render_pass(cb)

		// Main render pass
		rhi.cmd_begin_render_pass(cb, main_rp.render_pass, fb^)
		{
			rhi.cmd_set_viewport(cb, {0, 0}, core.array_cast(f32, fb.dimensions), 0, 1)
			rhi.cmd_set_scissor(cb, {0, 0}, fb.dimensions)
			rhi.cmd_set_backface_culling(cb, true)

			R.draw_full_screen_quad(cb, g_test_3d_state.textures[frame_in_flight])

			// Draw the scene with meshes
			rhi.cmd_bind_graphics_pipeline(cb, g_test_3d_state.mesh_pipeline)
			R.bind_scene(cb, &g_test_3d_state.scene, R.mesh_pipeline_layout()^)
			R.bind_scene_view(cb, &g_test_3d_state.scene_view, R.mesh_pipeline_layout()^)
			// R.draw_model(cb, &g_test_3d_state.test_model, &g_test_3d_state.test_material, &g_test_3d_state.scene_view)
			R.draw_model(cb, &g_test_3d_state.test_model2, {&g_test_3d_state.test_material}, &g_test_3d_state.scene_view)
			R.draw_model(cb, &g_test_3d_state.test_model3, {&g_test_3d_state.test_material, &g_test_3d_state.test_material2}, &g_test_3d_state.scene_view)

			rhi.cmd_bind_graphics_pipeline(cb, g_test_3d_state.instanced_mesh_pipeline)
			R.bind_scene(cb, &g_test_3d_state.scene, R.instanced_mesh_pipeline_layout()^)
			R.bind_scene_view(cb, &g_test_3d_state.scene_view, R.instanced_mesh_pipeline_layout()^)
			game.world_draw_static_objects(cb, &g_world)

			R.bind_terrain_pipeline(cb)
			R.bind_scene(cb, &g_test_3d_state.scene, R.terrain_pipeline_layout()^)
			R.bind_scene_view(cb, &g_test_3d_state.scene_view, R.terrain_pipeline_layout()^)
			R.draw_terrain(cb, &g_test_3d_state.test_terrain, &g_test_3d_state.test_material, false)

			R.debug_draw_primitives(&g_renderer.debug_renderer_state, cb, g_test_3d_state.scene_view, fb.dimensions)

			R.bind_text_pipeline(cb, nil)
			R.bind_font(cb)
			R.draw_text_geometry(cb, g_text_geo, {20, 14}, fb.dimensions)
			dyn_text_geo := R.make_dynamic_text_geo_from_entire_buffers(&g_test_3d_state.dyn_text)
			R.draw_dynamic_text_geometry(cb, dyn_text_geo, {0,0}, fb.dimensions)
		}
		rhi.cmd_end_render_pass(cb)

		R.end_frame(cb, image_index)
	}
}

draw :: proc(dt: f64) {
	when ENABLE_DRAW_3D_DEBUG_TEST {
		draw_3d(dt)
	}

	when ENABLE_DRAW_2D_TEST {
		draw_2d()
	}

	when ENABLE_DRAW_EXAMPLE_TEST {
		de_draw()
	}
}
