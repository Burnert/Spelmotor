package game

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:reflect"
import "core:slice"
import "core:strings"

import "sm:core"
import R "sm:renderer"
import "sm:rhi"

// 4 billion entities should be enough.
Entity_Handle :: struct { index: u32, serial: u32 }
Entity :: struct { using h: Entity_Handle, type: Entity_Type }
TEntity :: struct($T: typeid) { using h: Entity_Handle }
INVALID_ENTITY_INDEX :: 0xffffffff
INVALID_ENTITY :: Entity{h = {INVALID_ENTITY_INDEX, 0}}
invalid_t_entity :: proc($T: typeid) -> TEntity(T) { return {h = {INVALID_ENTITY_INDEX, 0}} }

Entity_Flags :: distinct bit_set[Entity_Flag]
Entity_Flag :: enum {
	Destroyed,
}

Entity_VTable :: struct {
	update_proc: proc(entity: ^Entity_Data, dt: f32),
}

// Do not keep pointers to this!
Entity_Data :: struct {
	using vtable: ^Entity_VTable,

	index: u32,
	serial: u32,
	subtype: Entity_Type,
	flags: Entity_Flags,
	name: string,

	using trs: Transform,

	world: ^World,
}

// Entity Arrays -----------------------------------------------------------------------------------------------

ENTITY_BUFFER_BLOCK_SIZE :: 1000

Entity_Array :: struct {
	arena: virtual.Arena,
	allocator: runtime.Allocator,
	array: Dynamic_Chunked_Array,
	free_list: [dynamic]u32, // entities that have been destroyed and can be reused
}

Entity_Arrays :: struct {
	array_map: [Entity_Type]Entity_Array,
}

entity_arrays_init :: proc(arrays: ^Entity_Arrays) {
	for &array, t in arrays.array_map {
		err := virtual.arena_init_growing(&array.arena)
		ensure(err == nil, fmt.tprintf("Failed to allocate an entity array for entities of type %v.", t))

		array.allocator = virtual.arena_allocator(&array.arena)
		array.array = dynamic_chunked_array_make(entity_conv_type_to_typeid(t), ENTITY_BUFFER_BLOCK_SIZE, array.allocator)
	}
}

entity_arrays_destroy :: proc(arrays: ^Entity_Arrays) {
	for &array in arrays.array_map {
		// TODO: Verify if entities should be destroyed explicitly here
		for i in 0..<array.array.length {
			entity := cast(^Entity_Data)dynamic_chunked_array_get_element(&array.array, i)
			if .Destroyed not_in entity.flags {
				entity_destroy_internal(entity)
			}
		}
		virtual.arena_destroy(&array.arena)
	}
}

entity_arrays_update :: proc(arrays: ^Entity_Arrays, dt: f32) {
	// TODO: Destroying a bunch of entities will fragment the list and it might become a problem eventually
	for &array, t in arrays.array_map {
		for i in 0..<array.array.length {
			data := cast(^Entity_Data)dynamic_chunked_array_get_element(&array.array, i)
			if .Destroyed in data.flags {
				continue
			}
	
			entity_update(data, dt)
		}
	}
}

// Entity Types -----------------------------------------------------------------------------------------------

Entity_Type :: enum {
	Camera,
	Light,
}

entity_conv_typeid_to_type :: proc(t: typeid) -> Entity_Type {
	switch t {
	case E_Camera: return .Camera
	case E_Light:  return .Light
	case: panic(fmt.tprintf("Invalid entity type %v.", t))
	}
}

entity_conv_type_to_typeid :: proc(t: Entity_Type) -> typeid {
	switch t {
	case .Camera: return E_Camera
	case .Light:  return E_Light
	case: panic(fmt.tprintf("Invalid entity type %v.", t))
	}
}

E_Camera :: struct {
	using _entity: Entity_Data,
	fovy: f32,

	scene_view: R.Scene_View,
}

E_Light :: struct {
	using _entity: Entity_Data,
	using light_props: R.Light_Props,
}

entity_allocate :: proc(world: ^World, type: Entity_Type) -> (entity: ^Entity_Data) {
	assert(world != nil)

	entity_array := &world.entity_arrays.array_map[type]

	if free_idx, ok := pop_safe(&entity_array.free_list); ok {
		raw_entity := dynamic_chunked_array_get_element(&entity_array.array, uint(free_idx))
		entity_data := cast(^Entity_Data)raw_entity
		prev_serial := entity_data.serial

		mem.zero_item(entity_data)

		entity_data.index = free_idx
		entity_data.serial = prev_serial + 1
		entity_data.subtype = type

		entity = entity_data

		return
	}

	assert(entity_array.array.length <= uint(max(u32)))
	index := u32(entity_array.array.length)
	entity = cast(^Entity_Data)dynamic_chunked_array_alloc_next_element(&entity_array.array)
	entity.index = index
	entity.serial = 0
	entity.subtype = type

	return
}

// TODO: The Procs should probably be default per type and optionally overridable per instance
entity_spawn :: proc(world: ^World, $T: typeid, trs: Transform = {}, vtable: ^Entity_VTable = nil, name: string = "") -> (entity: TEntity(T), data: ^T) {
	core.prof_scoped_event(#procedure)

	assert(world != nil)

	type := entity_conv_typeid_to_type(T)
	data = cast(^T)entity_allocate(world, type)

	data.trs = trs
	data.world = world
	data.vtable = vtable

	// Initialize the entity subtype
	switch data.subtype {
	case .Camera:
		camera := cast(^E_Camera)data
		result: rhi.Result
		camera.scene_view, result = R.create_scene_view(fmt.tprintf("SceneView_%s", name))
		core.result_verify(result)

	case .Light:
	}

	if name != "" {
		data.name = strings.clone(name, world.entity_arrays.array_map[data.subtype].allocator)
	}

	log.infof("Entity %q has been spawned.", data.name)

	return
}

entity_destroy :: proc(e: ^Entity_Data) {
	assert(.Destroyed not_in e.flags)

	e.flags += {.Destroyed}
	append(&e.world.entity_arrays.array_map[e.subtype].free_list, e.index)

	entity_destroy_internal(e)
}

entity_destroy_internal :: proc(e: ^Entity_Data) {
	switch e.subtype {
	case .Camera:
		camera := cast(^E_Camera)e
		// FIXME: This needs to be deferred until the resources are no longer used by the GPU.
		R.destroy_scene_view(&camera.scene_view)

	case .Light:
	}
}

entity_update :: proc(e: ^Entity_Data, dt: f32) {
	assert(e != nil)
	assert(e.world != nil)

	// TODO: I think it might be better if the game implemented its own entire loop
	if e.vtable != nil && e.update_proc != nil {
		e->update_proc(dt)
	}
}

deref :: proc{
	entity_deref,
	t_entity_deref,
}

entity_deref :: proc(world: ^World, entity: Entity) -> ^Entity_Data {
	assert(world != nil)
	
	data := cast(^Entity_Data)dynamic_chunked_array_get_element(&world.entity_arrays.array_map[entity.type].array, uint(entity.index))
	if data.serial != entity.serial {
		return nil
	}
	if .Destroyed in data.flags {
		return nil
	}
	return data
}

t_entity_deref :: proc(world: ^World, entity: TEntity($T)) -> ^T {
	type := entity_conv_typeid_to_type(T)
	data := entity_deref(world, Entity{h = entity, type = type})
	return cast(^T)data
}

is_valid :: proc{
	entity_is_valid,
	t_entity_is_valid,
}

entity_is_valid :: proc(world: ^World, entity: Entity) -> bool {
	return entity_deref(world, entity) != nil
}

t_entity_is_valid :: proc(world: ^World, entity: TEntity($T)) -> bool {
	return t_entity_deref(world, entity) != nil
}
