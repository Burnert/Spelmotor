package game

import "base:runtime"
import "core:log"
import "core:mem"
import "core:reflect"
import "core:slice"
import "core:strings"

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
}

Entity_Procs :: struct {
	// Called when the entity is spawned
	spawn_proc: proc(entity: ^Entity_Data),
	destroy_proc: proc(entity: ^Entity_Data),
	update_proc: proc(entity: ^Entity_Data, dt: f32),
}

// Do not keep pointers to this!
Entity_Data :: struct {
	index: u32,
	serial: u32,
	flags: Entity_Flags,
	name: string,

	using trs: Transform,

	mesh: ^R.Mesh, // TODO: Use asset handles
	materials: [16]^R.Material, // TODO: Use asset handles

	world: ^World,

	using procs: Entity_Procs,
	subtype_data: any,
}

ENTITY_BUFFER_BLOCK_SIZE :: 5000

entity_allocate :: proc(world: ^World) -> (entity: Entity, data: ^Entity_Data) {
	assert(world != nil)

	if free_idx, ok := pop_safe(&world.entity_free_list); ok {
		entity_data: ^Entity_Data = chunked_array_get_element(&world.entities, uint(free_idx))
		prev_serial := entity_data.serial

		mem.zero_item(entity_data)

		entity_data.index = free_idx
		entity_data.serial = prev_serial + 1

		entity = Entity{free_idx, entity_data.serial}
		data = entity_data

		return
	}

	assert(world.entities.length <= uint(max(u32)))
	index := u32(world.entities.length)
	entity = Entity{index, 0}
	data = chunked_array_alloc_next_element(&world.entities)
	data.index = index
	data.serial = 0

	return
}

// TODO: The Procs should probably be default per type and optionally overridable per instance
entity_spawn :: proc(world: ^World, $T: typeid, trs: Transform = {}, procs: ^Entity_Procs = nil, name: string = "") -> (entity: Entity, data: ^Entity_Data, subtype_data: ^T) {
	subtype_raw: rawptr
	entity, data, subtype_raw = entity_spawn_internal(world, trs, procs, typeid_of(T), name)
	subtype_data = cast(^T)subtype_raw
	return
}

entity_spawn_internal :: proc(world: ^World, trs: Transform, procs: ^Entity_Procs, subtype: Maybe(typeid), name: string) -> (entity: Entity, data: ^Entity_Data, subtype_data: rawptr) {
	assert(world != nil)

	entity, data = entity_allocate(world)

	data.trs = trs
	data.world = world
	if procs != nil {
		data.procs = procs^
	}
	if subtype != nil {
		subtype := subtype.(typeid)
		ti := type_info_of(subtype)
		// FIXME: Figure out a better way to do subtypes because this will silently leak memory when the entity gets freed. (User defined pools?)
		subtype_data, _ = mem.alloc(ti.size, ti.align, world.entity_allocator)
		data.subtype_data = any{subtype_data, subtype}

		if base_ptr_field := reflect.struct_field_by_name(subtype, "_entity"); base_ptr_field.type != nil {
			assert(base_ptr_field.type.id == typeid_of(^Entity_Data))
			assert(base_ptr_field.offset == 0)
			(^^Entity_Data)(subtype_data)^ = data
		}
	}
	if name != "" {
		data.name = strings.clone(name, world.entity_allocator)
	}

	// TODO: I guess this should not happen right here, but more so when this entity is processed for the first time in the loop? (more predictable)
	if data.spawn_proc != nil {
		data->spawn_proc()
	}

	log.infof("Entity %q has been spawned.", data.name)

	return
}

entity_destroy :: proc(e: ^Entity_Data) {
	e.flags += {.Destroyed}
	append(&e.world.entity_free_list, e.index)

	if e.subtype_data != nil {
		mem.free(e.subtype_data.data, e.world.entity_allocator)
	}

	// TODO: And this should probably be deferred to the end of a frame.
	if e.destroy_proc != nil {
		e->destroy_proc()
	}
}

entity_update :: proc(e: ^Entity_Data, dt: f32) {
	assert(e != nil)
	assert(e.world != nil)

	// TODO: I think it might be better if the game implemented its own entire loop
	if e.update_proc != nil {
		e->update_proc(dt)
	}
}

entity_deref :: proc(world: ^World, entity: Entity) -> ^Entity_Data {
	assert(world != nil)
	data := chunked_array_get_element(&world.entities, uint(entity.index))

	if data.serial != entity.serial {
		return nil
	}
	if .Destroyed in data.flags {
		return nil
	}
	return data
}

entity_deref_typed :: proc(world: ^World, entity: Entity, $T: typeid) -> ^T {
	data := entity_deref(world, entity)
	return &data.subtype_data.(T)
}

entity_is_valid :: proc(world: ^World, entity: Entity) -> bool {
	return entity_deref(world, entity) != nil
}
