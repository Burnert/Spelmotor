package game

import "base:runtime"
import "core:encoding/json"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import os "core:os/os2"
import "core:slice"
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
	allocator: runtime.Allocator,

	entities_hot: ^Entity_Hot_Buffer_Block,
	entities: ^Entity_Buffer_Block,
	entity_free_list: [dynamic]u32, // entities that have been destroyed and can be reused
	next_entity_index: u32, // acts as a cursor in the entity buffer block list, not an actual entity count

	static_objects_arena: virtual.Arena,
	static_objects_allocator: runtime.Allocator,
	static_objects: Chunked_Array(Static_Object, STATIC_OBJECTS_BUFFER_BLOCK_SIZE),
	static_objects_free_list: ^Node(Static_Object),

	time: f32, // World time in seconds
}

world_init :: proc(world: ^World) {
	assert(world != nil)

	world.allocator = context.allocator
	world.entities = new(Entity_Buffer_Block)
	world.entities_hot = new(Entity_Hot_Buffer_Block)
	world.entity_free_list = make([dynamic]u32)

	err: runtime.Allocator_Error
	err = virtual.arena_init_growing(&world.static_objects_arena)
	if err != nil do panic("Failed to initialize Static Object arena.")
	world.static_objects_allocator = virtual.arena_allocator(&world.static_objects_arena)
	world.static_objects = chunked_array_make(Static_Object, STATIC_OBJECTS_BUFFER_BLOCK_SIZE, world.static_objects_allocator)
}

world_destroy :: proc(world: ^World) {
	assert(world != nil)

	context.allocator = world.static_objects_allocator

	for i in 0..<world.static_objects.length {
		obj := chunked_array_get_element(&world.static_objects, i)
		R.destroy_instanced_model(&obj.instances)
		delete(obj.name)
	}
	// chunked_array_delete(&world.static_objects)
	virtual.arena_destroy(&world.static_objects_arena)
	world.static_objects_allocator.procedure = nil

	context.allocator = world.allocator

	// TODO: Verify if entities should be destroyed explicitly here

	free(world.entities)
	free(world.entities_hot)
	delete(world.entity_free_list)
}

World_Asset :: struct {
	// TODO: populate with world specific global data
}

// TODO: Again, all this is repeated multiple times (Static_Object, Static_Object_Desc, World_Map_Static_Object) and it bothers me
World_Map_Static_Object :: struct {
	name: string,
	mesh: string, // static mesh asset path string
	trs_array: []Transform,
	materials: [STATIC_OBJECT_MAX_MATERIAL_COUNT]string, // material asset path string
}

World_Map_Data :: struct {
	static_objects: []World_Map_Static_Object,
}

world_load_from_asset :: proc(world: ^World, asset: core.Asset_Ref(World_Asset)) {
	assert(world != nil)
	assert(core.asset_ref_is_valid(asset))

	map_data_path := core.asset_resolve_relative_path(asset.entry^, asset.entry.source, context.temp_allocator)
	map_data_bytes, err := os.read_entire_file_from_path(map_data_path, context.allocator)
	defer delete(map_data_bytes)
	if err != nil {
		log.errorf("Failed to load world from asset '%s'. Failed to read the map file.\n%v", asset.entry.path.str, err)
		return
	}

	world_load_arena: virtual.Arena
	_ = virtual.arena_init_growing(&world_load_arena)
	world_load_allocator := virtual.arena_allocator(&world_load_arena)
	defer virtual.arena_destroy(&world_load_arena)

	world_map_data: World_Map_Data
	unmarshal_err := json.unmarshal(map_data_bytes, &world_map_data, .MJSON, world_load_allocator)
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
		so_desc.trs_array = so.trs_array[:]

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

world_tick :: proc(world: ^World, dt: f32) {
	assert(world != nil)

	world.time += dt

	// TODO: In-game this should actually be static, so some Game/Edit mode separation mechanism (flag?) needs to be added
	// TODO: Also, this should probably not happen on world tick but post tick in the draw function before acquiring the next image
	for i in 0..<world.static_objects.length {
		obj := chunked_array_get_element(&world.static_objects, i)
		R.update_model_instance_buffer(&obj.instances)
	}

	// TODO: Destroying a bunch of entities will fragment the list and it might become a problem eventually
	count := world.next_entity_index
	assert(count <= ENTITY_BUFFER_BLOCK_SIZE)
	for i in 0..<count {
		data := &world.entities.data[i]
		if .Destroyed in data.flags {
			continue
		}

		hot := &world.entities_hot.data[i]
		entity_tick(data, dt)
	}
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
		// TODO: Instance transforms should be specified using the Transform struct
		static_object.instances.data[i].location = trs.translation
		static_object.instances.data[i].rotation = trs.rotation
		static_object.instances.data[i].scale = trs.scale
	}
}

world_draw_static_objects :: proc(cb: ^rhi.RHI_Command_Buffer, world: ^World) {
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
