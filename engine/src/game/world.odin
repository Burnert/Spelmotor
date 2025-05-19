package game

import "base:runtime"
import "core:mem"
import "core:slice"

import "sm:core"
import R "sm:renderer"
import "sm:rhi"

STATIC_OBJECT_MAX_MATERIAL_COUNT :: 16

Static_Object :: struct {
	// NOTE: Theoretically, this should be static, but then dynamic editing will not be possible
	instances: R.Instanced_Model,
	// TODO: Convert to asset handles
	materials: [STATIC_OBJECT_MAX_MATERIAL_COUNT]^R.Material,
}

Static_Object_Desc :: struct {
	mesh: ^R.Mesh,
	trs_array: []Transform,
	materials: [STATIC_OBJECT_MAX_MATERIAL_COUNT]^R.Material,
	name: string,
}

STATIC_OBJECTS_BUFFER_BLOCK_SIZE :: 5000

// TODO: Consider simplifying this to a dynamic array
Static_Objects_Buffer :: [STATIC_OBJECTS_BUFFER_BLOCK_SIZE]Static_Object
Static_Objects_Buffer_Block :: #type Buffer_Block(Static_Objects_Buffer)

World :: struct {
	allocator: runtime.Allocator,

	entities_hot: ^Entity_Hot_Buffer_Block,
	entities: ^Entity_Buffer_Block,
	entity_free_list: [dynamic]u32, // entities that have been destroyed and can be reused
	next_entity_index: u32, // acts as a cursor in the entity buffer block list, not an actual entity count

	static_objects: ^Static_Objects_Buffer_Block,
	next_static_object_index: u32,

	time: f32, // World time in seconds
}

world_init :: proc(world: ^World) {
	assert(world != nil)

	world.allocator = context.allocator
	world.entities = new(Entity_Buffer_Block)
	world.entities_hot = new(Entity_Hot_Buffer_Block)
	world.entity_free_list = make([dynamic]u32)
	world.static_objects = new(Static_Objects_Buffer_Block)
}

world_destroy :: proc(world: ^World) {
	assert(world != nil)

	for i in 0..<world.next_static_object_index {
		obj := &world.static_objects.data[i]
		R.destroy_instanced_model(&obj.instances)
	}

	context.allocator = world.allocator

	// TODO: Verify if entities should be destroyed explicitly here

	free(world.entities)
	free(world.entities_hot)
	delete(world.entity_free_list)
	free(world.static_objects)
}

world_tick :: proc(world: ^World, dt: f32) {
	assert(world != nil)

	world.time += dt

	// TODO: In-game this should actually be static, so some Game/Edit mode separation mechanism (flag?) needs to be added
	// TODO: Also, this should probably not happen on world tick but post tick in the draw function before acquiring the next image
	for i in 0..<world.next_static_object_index {
		static_object := &world.static_objects.data[i]
		R.update_model_instance_buffer(&static_object.instances)
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
	// Not supported for now
	assert(world.next_static_object_index < STATIC_OBJECTS_BUFFER_BLOCK_SIZE)

	result: rhi.Result
	instance_count := len(desc.trs_array)
	static_object := &world.static_objects.data[world.next_static_object_index]
	static_object.instances, result = R.create_instanced_model(desc.mesh, cast(uint)instance_count, desc.name)
	core.result_verify(result)

	assert(len(static_object.instances.data) == instance_count)
	for trs, i in desc.trs_array {
		// TODO: Instance transforms should be specified using the Transform struct
		static_object.instances.data[i].location = trs.translation.xyz
		static_object.instances.data[i].rotation = trs.rotation.xyz
		static_object.instances.data[i].scale = trs.scale.xyz
	}

	static_object.materials = desc.materials

	world.next_static_object_index += 1
}

world_draw_static_objects :: proc(cb: ^rhi.RHI_Command_Buffer, world: ^World) {
	for i in 0..<world.next_static_object_index {
		obj := &world.static_objects.data[i]
		// Assume the same material count as primitive count
		prim_count := len(obj.instances.mesh.primitives)
		assert(prim_count <= STATIC_OBJECT_MAX_MATERIAL_COUNT)
		R.draw_instanced_model(cb, &obj.instances, obj.materials[:prim_count])
	}
}
