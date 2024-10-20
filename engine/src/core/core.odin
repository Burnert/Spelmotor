package core

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:slice"
import "core:path/filepath"

import "sm:platform"

// PATHS ---------------------------------------------------------------------------------------------------------

Engine_Paths :: struct {
	engine_root: string,
	engine_resources_root: string,
	engine_shaders_root: string,
	engine_textures_root: string,
	engine_models_root: string,
}
g_engine_paths: Engine_Paths = {
	engine_root = "engine",
	engine_resources_root = "engine/res",
	engine_shaders_root = "engine/res/shaders",
	engine_textures_root = "engine/res/textures",
	engine_models_root = "engine/res/models",
}
g_root_dir: string = "."

path_make_engine_relative :: proc(relative_path: string, allocator := context.temp_allocator) -> string {
	return filepath.join({g_root_dir, g_engine_paths.engine_root, relative_path}, allocator)
}

path_make_engine_resources_relative :: proc(relative_path: string, allocator := context.temp_allocator) -> string {
	return filepath.join({g_root_dir, g_engine_paths.engine_resources_root, relative_path}, allocator)
}

path_make_engine_shader_relative :: proc(relative_path: string, allocator := context.temp_allocator) -> string {
	return filepath.join({g_root_dir, g_engine_paths.engine_shaders_root, relative_path}, allocator)
}

path_make_engine_textures_relative :: proc(relative_path: string, allocator := context.temp_allocator) -> string {
	return filepath.join({g_root_dir, g_engine_paths.engine_textures_root, relative_path}, allocator)
}

path_make_engine_models_relative :: proc(relative_path: string, allocator := context.temp_allocator) -> string {
	return filepath.join({g_root_dir, g_engine_paths.engine_models_root, relative_path}, allocator)
}

// BROADCASTER ---------------------------------------------------------------------------------------------------------

Broadcaster :: struct($A: typeid) where intrinsics.type_is_struct(A) {
	callbacks: [dynamic]proc(args: A),
}

broadcaster_add_callback :: proc(broadcaster: ^$B/Broadcaster($A), callback: proc(args: A)) {
	assert(broadcaster != nil)
	if !slice.contains(broadcaster.callbacks[:], callback) {
		append(&broadcaster.callbacks, callback)
	}
}

broadcaster_remove_callback :: proc(broadcaster: ^$B/Broadcaster($A), callback: proc(args: A)) {
	assert(broadcaster != nil)
	if i, ok := slice.linear_search(broadcaster.callbacks[:], callback); ok {
		ordered_remove(&broadcaster.callbacks, callback)
	}
}

broadcaster_broadcast :: proc(broadcaster: ^$B/Broadcaster($A), args: A) {
	assert(broadcaster != nil)
	for cb in broadcaster.callbacks {
		assert(cb != nil)
		cb(args)
	}
}

broadcaster_delete :: proc(broadcaster: ^$B/Broadcaster($A)) {
	assert(broadcaster != nil)
	delete(broadcaster.callbacks)
}

// ASSERTS ---------------------------------------------------------------------------------------------------------

assertion_failure :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	message := fmt.tprintf("%s\n%s at %s(%i:%i)", message, loc.procedure, loc.file_path, loc.line, loc.column)
	platform.show_message_box("Assertion failure.", message)
	runtime.default_assertion_failure_proc(prefix, message, loc)
}

// STRINGS ---------------------------------------------------------------------------------------------------------

string_from_array :: proc(array: ^$T/[$I]$E) -> string {
	return strings.string_from_null_terminated_ptr(raw_data(array[:]), len(array))
}
