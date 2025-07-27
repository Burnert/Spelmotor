package game

import "core:mem/virtual"
import "base:runtime"
import "core:mem"
import "core:slice"
import "core:strings"

import "sm:core"
import R "sm:renderer"
import "sm:rhi"

STATIC_OBJECT_MAX_MATERIAL_COUNT :: 16

Static_Object :: struct {
	mesh: core.Asset_Persistent_Ref(R.Static_Mesh_Asset),
	// NOTE: Theoretically, this should be static, but then dynamic editing will not be possible
	instances: R.Instanced_Model,
	// TODO: Convert to asset handles
	materials: [STATIC_OBJECT_MAX_MATERIAL_COUNT]^R.Material,
	name: string,
	destroyed: bool,
}

Static_Object_Desc :: struct {
	rmesh: ^R.Mesh,
	mesh: core.Asset_Ref(R.Static_Mesh_Asset),
	trs_array: []Transform,
	materials: [STATIC_OBJECT_MAX_MATERIAL_COUNT]^R.Material,
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

	result: rhi.Result
	instance_count := len(desc.trs_array)

	static_object := chunked_array_alloc_next_element(&world.static_objects)
	static_object.mesh = core.asset_make_persistent_ref(desc.mesh)
	static_object.instances, result = R.create_instanced_model(desc.rmesh, cast(uint)instance_count, desc.name)
	static_object.materials = desc.materials
	static_object.name = strings.clone(desc.name)
	core.result_verify(result)

	assert(len(static_object.instances.data) == instance_count)
	for trs, i in desc.trs_array {
		// TODO: Instance transforms should be specified using the Transform struct
		static_object.instances.data[i].location = trs.translation.xyz
		static_object.instances.data[i].rotation = trs.rotation.xyz
		static_object.instances.data[i].scale = trs.scale.xyz
	}
}

world_draw_static_objects :: proc(cb: ^rhi.RHI_Command_Buffer, world: ^World) {
	for i in 0..<world.static_objects.length {
		obj := chunked_array_get_element(&world.static_objects, i)
		// Assume the same material count as primitive count
		prim_count := len(obj.instances.mesh.primitives)
		assert(prim_count <= STATIC_OBJECT_MAX_MATERIAL_COUNT)
		R.draw_instanced_model(cb, &obj.instances, obj.materials[:prim_count])
	}
}
