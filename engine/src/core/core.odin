package core

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:slice"
import "core:path/filepath"
import "core:math/linalg"

import "sm:platform"

// TYPES & CONSTANTS ---------------------------------------------------------------------------------------------------------

Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32
Quat :: quaternion128
Matrix3 :: matrix[3,3]f32
Matrix4 :: matrix[4,4]f32

VEC2_ZERO :: Vec2{0,0}

VEC3_ZERO :: Vec3{0,0,0}
VEC3_ONE :: Vec3{1,1,1}
VEC3_RIGHT :: Vec3{1,0,0}
VEC3_LEFT :: Vec3{-1,0,0}
VEC3_FORWARD :: Vec3{0,1,0}
VEC3_BACKWARD :: Vec3{0,-1,0}
VEC3_UP :: Vec3{0,0,1}
VEC3_DOWN :: Vec3{0,0,-1}

VEC4_ZERO :: Vec4{0,0,0,0}

QUAT_IDENTITY :: linalg.QUATERNIONF32_IDENTITY

MATRIX3_IDENTITY :: linalg.MATRIX3F32_IDENTITY
MATRIX4_IDENTITY :: linalg.MATRIX4F32_IDENTITY

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

// ARRAYS ---------------------------------------------------------------------------------------------------------

array_cast :: proc($T: typeid, array: [$I]$E) -> (ret: [I]T) {
	when I == 1 {
		ret[0] = cast(T) array[0]
	} else when I == 2 {
		ret[0] = cast(T) array[0]
		ret[1] = cast(T) array[1]
	} else when I == 3 {
		ret[0] = cast(T) array[0]
		ret[1] = cast(T) array[1]
		ret[2] = cast(T) array[2]
	} else when I == 4 {
		ret[0] = cast(T) array[0]
		ret[1] = cast(T) array[1]
		ret[2] = cast(T) array[2]
		ret[3] = cast(T) array[3]
	} else {
		for i in 0..<I {
			ret[i] = cast(T) array[i]
		}
	}
	return
}

vec3 :: proc{
	vec3_from_vec2_and_scalar,
	vec3_from_scalar_and_vec2,
}

vec3_from_vec2_and_scalar :: proc(v: [2]$E, s: E) -> [3]E {
	return {v.x, v.y, s}
}
vec3_from_scalar_and_vec2 :: proc(s: $E, v: [2]E) -> [3]E {
	return {s, v.x, v.y}
}

vec4 :: proc{
	vec4_from_vec2_and_two_scalars,
	vec4_from_scalar_vec2_and_scalar,
	vec4_from_two_scalars_and_vec2,
	vec4_from_two_vec2s,
	vec4_from_vec3_and_scalar,
	vec4_from_scalar_and_vec3,
}

vec4_from_vec2_and_two_scalars :: proc(v: [2]$E, s1, s2: E) -> [4]E {
	return {v.x, v.y, s1, s2}
}
vec4_from_scalar_vec2_and_scalar :: proc(s1: $E, v: [2]E, s2: E) -> [4]E {
	return {s1, v.x, v.y, s2}
}
vec4_from_two_scalars_and_vec2 :: proc(s1, s2: $E, v: [2]E) -> [4]E {
	return {s1, s2, v.x, v.y}
}
vec4_from_two_vec2s :: proc(v1, v2: [2]$E) -> [4]E {
	return {v1.x, v1.y, v2.x, v2.y}
}
vec4_from_vec3_and_scalar :: proc(v: [3]$E, s: E) -> [4]E {
	return {v.x, v.y, v.z, s}
}
vec4_from_scalar_and_vec3 :: proc(s: $E, v: [3]E) -> [4]E {
	return {s, v.x, v.y, v.z}
}
