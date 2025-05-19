package game

import "base:runtime"
import "core:mem"
import "core:slice"

import R "sm:renderer"

// 4 billion entities should be enough.
Entity :: struct { index: u32, serial: u32 }
INVALID_ENTITY_INDEX :: 0xffffffff
INVALID_ENTITY :: Entity{INVALID_ENTITY_INDEX, 0}

Entity_Flags :: distinct bit_set[Entity_Flag]
Entity_Flag :: enum {
	Destroyed,
}

// Do not keep pointers to this!
Entity_Hot :: struct {
	using trs: Transform,
}

Entity_Methods :: struct {
	on_spawn_fn: proc(entity: ^Entity_Data, world: ^World),
	on_destroy_fn: proc(entity: ^Entity_Data, world: ^World),
	tick_fn: proc(entity: ^Entity_Data, world: ^World, dt: f32),
}

// Do not keep pointers to this!
Entity_Data :: struct {
	index: u32,
	serial: u32,
	flags: Entity_Flags,

	hot_data: Entity_Hot_Ptr,

	mesh: ^R.Mesh, // TODO: Use asset handles
	materials: [16]^R.Material, // TODO: Use asset handles

	world: ^World,

	using methods: Entity_Methods,
}

ENTITY_BUFFER_BLOCK_SIZE :: 1000

Entity_Buffer :: [ENTITY_BUFFER_BLOCK_SIZE]Entity_Data
Entity_Buffer_Block :: #type Buffer_Block(Entity_Buffer)

Entity_Hot_Buffer :: #soa[ENTITY_BUFFER_BLOCK_SIZE]Entity_Hot
Entity_Hot_Buffer_Block :: #type Buffer_Block(Entity_Hot_Buffer)
Entity_Hot_Ptr :: #soa^Entity_Hot_Buffer

entity_allocate :: proc(world: ^World) -> (entity: Entity, data: ^Entity_Data) {
	assert(world != nil)

	if free_idx, ok := pop_safe(&world.entity_free_list); ok {
		entity_data: ^Entity_Data = &world.entities.data[free_idx]
		serial := entity_data.serial

		mem.zero_item(entity_data)

		entity_data.index = free_idx
		entity_data.serial = serial + 1
		entity_data.hot_data = &world.entities_hot.data[free_idx]
		entity_data.hot_data^ = {}

		entity = Entity{free_idx, entity_data.serial}
		data = &world.entities.data[free_idx]

		return
	}

	// TODO: In this case, allocate a next block
	assert(world.next_entity_index < ENTITY_BUFFER_BLOCK_SIZE)
	
	entity = Entity{world.next_entity_index, 0}
	data = &world.entities.data[world.next_entity_index]
	data.index = world.next_entity_index
	data.serial = 0
	data.hot_data = &world.entities_hot.data[world.next_entity_index]
	
	world.next_entity_index += 1

	return
}

entity_spawn :: proc(world: ^World, trs: Transform, methods: Entity_Methods) -> (entity: Entity, data: ^Entity_Data) {
	assert(world != nil)

	entity, data = entity_allocate(world)

	data.hot_data.trs = trs
	data.methods = methods
	data.world = world

	if data.on_spawn_fn != nil {
		data->on_spawn_fn(world)
	}

	return
}

entity_destroy :: proc(e: ^Entity_Data) {
	e.flags += {.Destroyed}
	append(&e.world.entity_free_list, e.index)

	if e.on_destroy_fn != nil {
		e->on_destroy_fn(e.world)
	}
}

entity_tick :: proc(e: ^Entity_Data, dt: f32) {
	assert(e != nil)
	assert(e.world != nil)

	if e.tick_fn != nil {
		e->tick_fn(e.world, dt)
	}
}

entity_deref :: proc(world: ^World, entity: Entity) -> ^Entity_Data {
	assert(world != nil)
	data := &world.entities.data[entity.index]

	if data.serial != entity.serial {
		return nil
	}
	if .Destroyed in data.flags {
		return nil
	}
	return data
}

entity_is_valid :: proc(world: ^World, entity: Entity) -> bool {
	return entity_deref(world, entity) != nil
}
