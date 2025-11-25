package game

import "core:math/linalg"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import os "core:os/os2"
import "core:slice"
import "core:strconv"
import "core:strings"

import "sm:core"
import R "sm:renderer"
import "sm:rhi"

STATIC_OBJECT_MAX_MATERIAL_COUNT :: 16

Static_Object :: struct {
	mesh: core.Asset_Ref(R.Static_Mesh_Asset),
	// NOTE: Theoretically, this should be static, but then dynamic editing will not be possible
	instances: R.Instanced_Model,
	material_assets: [STATIC_OBJECT_MAX_MATERIAL_COUNT]core.Asset_Ref(R.Material_Asset),
	materials: [STATIC_OBJECT_MAX_MATERIAL_COUNT]^R.Material,
	name: string,
	destroyed: bool,
}

Static_Object_Desc :: struct {
	mesh: core.Asset_Ref(R.Static_Mesh_Asset),
	trs_array: []Transform,
	materials: [STATIC_OBJECT_MAX_MATERIAL_COUNT]core.Asset_Ref(R.Material_Asset),
	name: string,
}

STATIC_OBJECTS_BUFFER_BLOCK_SIZE :: 5000

World :: struct {
	static_objects_arena: virtual.Arena,
	static_objects_allocator: runtime.Allocator,
	static_objects: Chunked_Array(Static_Object, STATIC_OBJECTS_BUFFER_BLOCK_SIZE),
	static_objects_free_list: ^Node(Static_Object),

	entity_arrays: Entity_Arrays,

	time: f32, // World time in seconds

	scene: R.Scene,
	static_objects_base_pass_pipeline: rhi.Backend_Pipeline,
}

world_init :: proc(world: ^World) {
	core.prof_scoped_event(#procedure)

	assert(world != nil)

	err: runtime.Allocator_Error

	err = virtual.arena_init_growing(&world.static_objects_arena)
	if err != nil do panic("Failed to initialize Static Object arena.")
	world.static_objects_allocator = virtual.arena_allocator(&world.static_objects_arena)
	world.static_objects = chunked_array_make(Static_Object, STATIC_OBJECTS_BUFFER_BLOCK_SIZE, world.static_objects_allocator)

	entity_arrays_init(&world.entity_arrays)

	// Register world related assets
	core.asset_type_register(World_Asset)

	rhi_result := world_rendering_init(world)
	core.result_verify(rhi_result)
}

world_destroy :: proc(world: ^World) {
	core.prof_scoped_event(#procedure)

	assert(world != nil)

	{
		context.allocator = world.static_objects_allocator

		for i in 0..<world.static_objects.length {
			obj := chunked_array_get_element(&world.static_objects, i)
			R.destroy_instanced_model(&obj.instances)
			delete(obj.name)
		}
		// chunked_array_delete(&world.static_objects)
		virtual.arena_destroy(&world.static_objects_arena)
		world.static_objects_allocator.procedure = nil
	}

	entity_arrays_destroy(&world.entity_arrays)

	world_rendering_shutdown(world)
}

world_rendering_init :: proc(world: ^World) -> (result: rhi.Result) {
	world.scene = R.create_scene() or_return
	world.static_objects_base_pass_pipeline = R.create_instanced_mesh_pipeline(R.Mesh_Pipeline_Specializations{lighting_model = .Default}) or_return
	return
}

world_rendering_shutdown :: proc(world: ^World) {
	rhi.destroy_graphics_pipeline(&world.static_objects_base_pass_pipeline)
	R.destroy_scene(&world.scene)
}

World_Asset :: struct {
	// TODO: populate with world specific global data
}

// TODO: Again, all this is repeated multiple times (Static_Object, Static_Object_Desc, World_Map_Static_Object) and it bothers me
World_Map_Static_Object :: struct {
	name: string,
	mesh: string, // static mesh asset path string
	instances: []Transform,
	materials: [STATIC_OBJECT_MAX_MATERIAL_COUNT]string `json:"materials,omitempty"`, // material asset path string
}

World_Map_Data :: struct {
	static_objects: []World_Map_Static_Object,
}

// The resulting string is allocated using the temporary allocator
world_asset_get_map_filepath :: proc(asset: core.Asset_Ref(World_Asset)) -> string {
	filename, fileext := os.split_filename(asset.entry.physical_path)
	map_path, _ := os.join_filename(filename, "map", context.temp_allocator)
	return map_path
}

world_load_from_asset :: proc(world: ^World, asset: core.Asset_Ref(World_Asset)) {
	core.prof_scoped_event(#procedure)

	assert(world != nil)
	assert(core.asset_ref_is_valid(asset))

	world_load_arena: virtual.Arena
	_ = virtual.arena_init_growing(&world_load_arena)
	world_load_allocator := virtual.arena_allocator(&world_load_arena)
	defer virtual.arena_destroy(&world_load_arena)

	context.allocator = world_load_allocator

	map_data_path := world_asset_get_map_filepath(asset)
	map_data_bytes, err := os.read_entire_file_from_path(map_data_path, context.allocator)
	defer delete(map_data_bytes)
	if err != nil {
		log.errorf("Failed to load world from asset '%s'. Failed to read the map file.\n%v", asset.entry.path.str, err)
		return
	}

	world_map_data: World_Map_Data
	unmarshal_err := json.unmarshal(map_data_bytes, &world_map_data, .MJSON)
	if unmarshal_err != nil {
		log.errorf("Failed to load world from asset '%s'. Failed to parse the map file.\n%v", asset.entry.path.str, unmarshal_err)
		return
	}

	// Load static objects
	for so in world_map_data.static_objects {
		mesh_asset := core.asset_ref_resolve(so.mesh, R.Static_Mesh_Asset)
		if !core.asset_ref_is_valid(mesh_asset) {
			log.errorf("Failed to load mesh '%s' in static object '%s'.", mesh_asset.entry.path.str, so.name)
			continue
		}

		so_desc: Static_Object_Desc
		so_desc.name = so.name
		so_desc.mesh = mesh_asset
		so_desc.trs_array = so.instances[:]

		for m, i in so.materials {
			if m == "" {
				continue
			}

			mat_asset := core.asset_ref_resolve(m, R.Material_Asset)
			so_desc.materials[i] = mat_asset
			if !core.asset_ref_is_valid(mat_asset) {
				log.errorf("Failed to load material '%s' in static object '%s'.", mat_asset.entry.path.str, so.name)
				continue
			}
		}

		world_add_static_object(world, so_desc)
	}
}

world_save_to_asset :: proc(world: ^World, asset: core.Asset_Ref(World_Asset)) {
	core.prof_scoped_event(#procedure)

	assert(world != nil)
	assert(core.asset_ref_is_valid(asset))

	world_save_arena: virtual.Arena
	_ = virtual.arena_init_growing(&world_save_arena)
	world_save_allocator := virtual.arena_allocator(&world_save_arena)
	defer virtual.arena_destroy(&world_save_arena)

	context.allocator = world_save_allocator

	map_data_path := world_asset_get_map_filepath(asset)
	assert(map_data_path != "")

	b: strings.Builder
	strings.builder_init(&b)

	strings.write_string(&b, "static_objects = [\n")
	for i in 0..<world.static_objects.length {
		obj := chunked_array_get_element(&world.static_objects, i)
		if obj.destroyed {
			continue
		}

		strings.write_string(&b, "\t{\n")

		strings.write_string(&b, "\t\tname = ")
		strings.write_quoted_string(&b, obj.name)
		strings.write_string(&b, "\n")

		strings.write_string(&b, "\t\tmesh = ")
		strings.write_quoted_string(&b, obj.mesh.entry.path.str)
		strings.write_string(&b, "\n")

		strings.write_string(&b, "\t\tinstances = [\n")
		for inst in obj.instances.data {
			strings.write_string(&b, "\t\t\t{\n")
			core.write_transform(&b, inst, "\t\t\t\t")
			strings.write_string(&b, "\t\t\t}\n")
		}
		strings.write_string(&b, "\t\t]\n")

		strings.write_string(&b, "\t\tmaterials = [\n")
		for mat in obj.material_assets {
			// FIXME: technically, some slots in the middle could be left empty, so it's not correct to 
			if !core.asset_ref_is_valid(mat) {
				continue
			}

			strings.write_string(&b, "\t\t\t")
			strings.write_quoted_string(&b, mat.entry.path.str)
			strings.write_string(&b, "\n")
		}
		strings.write_string(&b, "\t\t]\n")

		strings.write_string(&b, "\t}\n")
	}
	strings.write_string(&b, "]\n")

	write_err := os.write_entire_file(map_data_path, b.buf[:])
	if write_err != nil {
		log.errorf("Failed to save world to asset '%s'. Failed to write the map file.\n%v", asset.entry.path.str, write_err)
		return
	}
}

world_update :: proc(world: ^World, dt: f32) {
	assert(world != nil)

	world.time += dt

	// TODO: In-game this should actually be static, so some Game/Edit mode separation mechanism (flag?) needs to be added
	// TODO: Also, this should probably not happen on world tick but post tick in the draw function before acquiring the next image
	for i in 0..<world.static_objects.length {
		obj := chunked_array_get_element(&world.static_objects, i)
		R.update_model_instance_buffer(&obj.instances)
	}

	entity_arrays_update(&world.entity_arrays, dt)
}

world_add_static_object :: proc(world: ^World, desc: Static_Object_Desc) {
	context.allocator = world.static_objects_allocator

	log.infof("Adding static object '%s' to world.", desc.name)

	result: rhi.Result

	mesh: ^R.Mesh
	mesh, result = R.get_mesh_from_asset(desc.mesh)
	if result != nil {
		log.errorf("Cannot add static object '%s' to world. Failed to get a mesh from asset '%s'.", desc.name, desc.mesh.entry.path)
		core.result_log(result)
		return
	}

	instance_count := len(desc.trs_array)

	static_object := chunked_array_alloc_next_element(&world.static_objects)
	static_object.mesh = desc.mesh
	static_object.instances, result = R.create_instanced_model(mesh, cast(uint)instance_count, desc.name)
	static_object.material_assets = desc.materials
	for m, i in static_object.material_assets {
		if !core.asset_ref_is_valid(m) {
			continue
		}
		static_object.materials[i], result = R.get_material_from_asset(m)
		if result != nil {
			log.errorf("Failed to get material from asset '%s'.", m.entry.path.str)
			core.result_log(result)
		}
	}
	static_object.name = strings.clone(desc.name)

	assert(len(static_object.instances.data) == instance_count)
	for trs, i in desc.trs_array {
		static_object.instances.data[i].trs = trs
	}
}

// TODO: So this function should actually also take a view info so it can be used with multiple cameras/viewports
world_draw :: proc(cb: ^rhi.Backend_Command_Buffer, world: ^World, viewport_dims: Vec2) {
	assert(cb != nil)
	assert(world != nil)

	rhi_state := rhi.get_state()
	frame_in_flight := rhi_state.frame_in_flight

	scene_view: ^R.Scene_View
	scene_uniforms := rhi.cast_mapped_buffer_memory_single(R.Scene_Uniforms, world.scene.uniforms[frame_in_flight].mapped_memory)
	cur_light_index := 0
	for &array, t in world.entity_arrays.array_map {
		for i in 0..<array.array.length {
			entity := cast(^Entity_Data)dynamic_chunked_array_get_element(&array.array, i)
			switch entity.subtype {
			case .Light:
				light := cast(^E_Light)entity
				assert(cur_light_index < R.MAX_LIGHTS)
				u_light := &scene_uniforms.lights[cur_light_index]
				// TODO: Extract to a "convert light props to uniform" proc
				u_light.location = vec4(light.translation, 1)
				rotation_rads := linalg.to_radians(light.rotation)
				quat := linalg.quaternion_from_euler_angles(rotation_rads.x, rotation_rads.y, rotation_rads.z, .ZXY)
				u_light.direction = vec4(linalg.quaternion_mul_vector3(quat, VEC3_FORWARD), 0)
				u_light.color = light.color * light.intensity
				u_light.attenuation_radius = light.attenuation_radius
				u_light.spot_cone_angle_cos = math.cos(light.spot_cone_angle)
				u_light.spot_cone_falloff = light.spot_cone_falloff
				cur_light_index += 1
			
			case .Camera:
				camera := cast(^E_Camera)entity
				// NOTE: Only one scene view is allowed to be selected
				if scene_view == nil {
					scene_view = &camera.scene_view
					scene_view_uniforms := rhi.cast_mapped_buffer_memory_single(R.Scene_View_Uniforms, scene_view.uniforms[frame_in_flight].mapped_memory)
					
					view_info := R.View_Info{
						origin = camera.translation,
						// Camera angles were specified in degrees here
						angles = linalg.to_radians(camera.rotation),
						projection = R.Perspective_Projection_Info{
							vertical_fov = camera.fovy,
							aspect_ratio = viewport_dims.x / viewport_dims.y,
							near_clip_plane = 0.1,
						},
					}
	
					view_rotation_matrix, _, view_projection_matrix := R.calculate_view_matrices(view_info)
					scene_view_uniforms.vp_matrix = view_projection_matrix
					scene_view_uniforms.view_origin = vec4(view_info.origin, 0)
					// Rotate a back vector because the matrix is an inverse of the actual view transform
					scene_view_uniforms.view_direction = view_rotation_matrix * vec4(core.VEC3_BACKWARD, 0)
				}
			}
		}
	}
	scene_uniforms.light_num = cast(u32)cur_light_index
	slice.zero(scene_uniforms.lights[cur_light_index:R.MAX_LIGHTS])

	if scene_view == nil {
		log.errorf("Cannot draw the world, because no camera was found.")
		return
	}

	rhi.cmd_bind_graphics_pipeline(cb, world.static_objects_base_pass_pipeline)
	R.bind_scene(cb, &world.scene, R.instanced_mesh_pipeline_layout()^)
	R.bind_scene_view(cb, scene_view, R.instanced_mesh_pipeline_layout()^)

	// Draw static objects
	for i in 0..<world.static_objects.length {
		obj := chunked_array_get_element(&world.static_objects, i)

		if obj.destroyed {
			continue
		}

		// Assume the same material count as primitive count
		prim_count := len(obj.instances.mesh.primitives)
		assert(prim_count <= STATIC_OBJECT_MAX_MATERIAL_COUNT)
		R.draw_instanced_model(cb, &obj.instances, obj.materials[:prim_count])
	}
}
