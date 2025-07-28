package core

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:slice"
import "core:path/filepath"
import "core:math/linalg"
import "core:mem"

// PLATFORM INTERFACE ---------------------------------------------------------------------------------------------------------

// These fields should be set by the platform module init if the particular feature is supported
Platform_Interface :: struct {
	show_message_box: proc(title, message: string),
	log_to_console: proc(data: rawptr, level: runtime.Logger_Level, text: string, options: runtime.Logger_Options, location := #caller_location),
}
g_platform_interface: Platform_Interface

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
	engine_shader_cache: string,
	engine_textures_root: string,
	engine_models_root: string,
}
g_engine_paths: Engine_Paths = {
	engine_root = "engine",
	engine_resources_root = "engine/res",
	engine_shaders_root = "engine/res/shaders",
	engine_shader_cache = "engine/res/shaders/cache",
	engine_textures_root = "engine/res/textures",
	engine_models_root = "engine/res/models",
}
g_root_dir: string = "."

path_make_engine_relative :: proc(relative_path: string, allocator := context.temp_allocator) -> string {
	return filepath.join({g_root_dir, g_engine_paths.engine_root, relative_path}, allocator)
}

path_make_engine_resources :: proc(allocator := context.temp_allocator) -> string {
	return filepath.join({g_root_dir, g_engine_paths.engine_resources_root}, allocator)
}

path_make_engine_resources_relative :: proc(relative_path: string, allocator := context.temp_allocator) -> string {
	return filepath.join({g_root_dir, g_engine_paths.engine_resources_root, relative_path}, allocator)
}

path_make_engine_shader_relative :: proc(relative_path: string, allocator := context.temp_allocator) -> string {
	return filepath.join({g_root_dir, g_engine_paths.engine_shaders_root, relative_path}, allocator)
}

path_make_engine_shader_cache_relative :: proc(relative_path: string, allocator := context.temp_allocator) -> string {
	return filepath.join({g_root_dir, g_engine_paths.engine_shader_cache, relative_path}, allocator)
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
	if g_platform_interface.show_message_box != nil {
		g_platform_interface.show_message_box("Assertion failure.", message)
	}
	runtime.default_assertion_failure_proc(prefix, message, loc)
}

// ERROR HANDLING ---------------------------------------------------------------------------------------------------------

// Generic error type with custom data
Error :: struct($D: typeid) {
	message: string,
	location: runtime.Source_Code_Location,
	depth: uint,
	data: D,
}

Result :: union($D: typeid) { Error(D) }

Error_Dynamic  :: #type Error(any)
Result_Dynamic :: #type Result(any)

// Makes an inline value based error
error_make :: proc(data: $D, format: string, fmt_args: ..any, loc := #caller_location) -> (err: Error(D)) {
	err.message = fmt.tprintf(format, ..fmt_args)
	err.location = loc
	err.depth = 0
	err.data = data

	return
}

// Makes an inline value based error and casts it to type
error_make_as :: proc($As: typeid/Error($OutD), data: $D, format: string, fmt_args: ..any, loc := #caller_location) -> (err: As) {
	#assert(!intrinsics.type_is_any(OutD), "The target error type should not have a data of type any. Use error_make_dynamic instead.")

	err.message = fmt.tprintf(format, ..fmt_args)
	err.location = loc
	err.depth = 0
	err.data = auto_cast data

	return
}

// Makes a dynamic error with data of any type allocated using context's temporary allocator
error_make_dynamic :: proc(data: $D, format: string, fmt_args: ..any, loc := #caller_location) -> (err: Error_Dynamic) {
	err.message = fmt.tprintf(format, ..fmt_args)
	err.location = loc
	err.depth = 0

	// The error data has to be copied to a persistent storage
	// because the Error structure will be returned from a function.
	copied_data := new(Err, context.temp_allocator)
	copied_data^ = data
	err.data = copied_data^

	return
}

error_cast :: proc($To: typeid/Error($OutD), err: Error($D)) -> (out_err: To) {
	out_err.message = err.message
	out_err.location = err.location
	out_err.depth = err.depth

	when intrinsics.type_is_union(type_of(err.data)) || intrinsics.type_is_any(type_of(err.data)) {
		out_err.data = err.data.?
	} else {
		out_err.data = err.data
	}

	return
}

error_log :: proc(err: Error($D)) {
	log.errorf("An error has occurred!\n%s", err.message, location = err.location)
}

error_panic :: proc(err: Error($D)) {
	panic(fmt.tprintf("An unrecoverable error has occurred and the application must exit!\n%s", err.message), loc = err.location)
}

// Augments the passed in Result with a higher level message allocated using context's temporary allocator
result_augment :: proc(res: Result($D), format: string, fmt_args: ..any) -> Result(D) {
	// The passed in Result must be an Error variant.
	// This is for convenience, so that a cast of the Result is not needed in user's code.
	err := res.(Error(D))
	top_message := fmt.tprintf(format, ..fmt_args)
	err.message = fmt.tprintf("%s\n(%i) %s", top_message, err.depth, err.message)
	err.depth += 1

	return err
}

result_cast :: proc($To: typeid/Result($OutD), res: Result($D)) -> (out_res: To) {
	if res != nil {
		return error_cast(Error(OutD), res.?)
	} else {
		return nil
	}
}

// Logs the error if the passed in Result is an Error variant
result_log :: proc(res: Result($D)) {
	if res != nil {
		err := res.(Error(D))
		error_log(err)
	}
}

// Panics if the passed in Result is an Error variant
result_verify :: proc(res: Result($D)) {
	if res != nil {
		err := res.(Error(D))
		error_panic(err)
	}
}

// STRINGS ---------------------------------------------------------------------------------------------------------

string_from_array :: proc(array: ^$T/[$I]$E) -> string {
	return strings.string_from_null_terminated_ptr(raw_data(array[:]), len(array))
}

// ARRAYS ---------------------------------------------------------------------------------------------------------

@(require_results)
array_cast :: proc "contextless" ($T: typeid, array: [$I]$E) -> (ret: [I]T) #no_bounds_check {
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
	vec3_from_three_scalars,
	vec3_from_vec2_and_scalar,
	vec3_from_scalar_and_vec2,
}

@(require_results)
vec3_from_three_scalars :: proc "contextless" (s1, s2, s3: $E) -> [3]E #no_bounds_check {
	return {s1, s2, s3}
}
@(require_results)
vec3_from_vec2_and_scalar :: proc "contextless" (v: [2]$E, s: E) -> [3]E #no_bounds_check {
	return {v.x, v.y, s}
}
@(require_results)
vec3_from_scalar_and_vec2 :: proc "contextless" (s: $E, v: [2]E) -> [3]E #no_bounds_check {
	return {s, v.x, v.y}
}

vec4 :: proc{
	vec4_from_four_scalars,
	vec4_from_vec2_and_two_scalars,
	vec4_from_scalar_vec2_and_scalar,
	vec4_from_two_scalars_and_vec2,
	vec4_from_two_vec2s,
	vec4_from_vec3_and_scalar,
	vec4_from_scalar_and_vec3,
}

@(require_results)
vec4_from_four_scalars :: proc "contextless" (s1, s2, s3, s4: $E) -> [4]E #no_bounds_check {
	return {s1, s2, s3, s4}
}
@(require_results)
vec4_from_vec2_and_two_scalars :: proc "contextless" (v: [2]$E, s1, s2: E) -> [4]E #no_bounds_check {
	return {v.x, v.y, s1, s2}
}
@(require_results)
vec4_from_scalar_vec2_and_scalar :: proc "contextless" (s1: $E, v: [2]E, s2: E) -> [4]E #no_bounds_check {
	return {s1, v.x, v.y, s2}
}
@(require_results)
vec4_from_two_scalars_and_vec2 :: proc "contextless" (s1, s2: $E, v: [2]E) -> [4]E #no_bounds_check {
	return {s1, s2, v.x, v.y}
}
@(require_results)
vec4_from_two_vec2s :: proc "contextless" (v1, v2: [2]$E) -> [4]E #no_bounds_check {
	return {v1.x, v1.y, v2.x, v2.y}
}
@(require_results)
vec4_from_vec3_and_scalar :: proc "contextless" (v: [3]$E, s: E) -> [4]E #no_bounds_check {
	return {v.x, v.y, v.z, s}
}
@(require_results)
vec4_from_scalar_and_vec3 :: proc "contextless" (s: $E, v: [3]E) -> [4]E #no_bounds_check {
	return {s, v.x, v.y, v.z}
}

@(require_results)
is_nearly_zero :: proc "contextless" (v: $T/[$I]$E, epsilon := 1e-8) -> bool {
	is_element_zero: [I]bool
	for e, i in v {
		is_element_zero[i] = abs(e) < cast(E)epsilon
	}
	return linalg.all(is_element_zero)
}

@(require_results)
is_nearly_equal :: proc "contextless" (v1, v2: $T/[$I]$E, epsilon := 1e-8) -> bool {
	is_element_equal: [I]bool
	for e1, i in v1 {
		e2 := v2[i]
		is_element_equal[i] = abs(e1 - e2) < cast(E)epsilon
	}
	return linalg.all(is_element_equal)
}

// TRANSFORM ---------------------------------------------------------------------------------------------------------

Transform :: struct #align(16) {
	translation: Vec3, // align(16) position / location - in meters
	_: f32,            // -- padding --
	rotation: Vec3,    // align(16) orientation - angle in degrees - x:pitch, y:roll, z:yaw
	_: f32,            // -- padding --
	scale: Vec3,       // align(16) scale - default: {1, 1, 1}
	inverted: bool,    // whether this transform's components should be applied in reverse
}

make_transform :: proc(t: Vec3 = {0,0,0}, r: Vec3 = {0,0,0}, s: Vec3 = {1,1,1}, inverted := false) -> (transform: Transform) {
	transform.translation = t
	transform.rotation = r
	transform.scale = s
	transform.inverted = inverted
	return
}

transform_to_matrix4 :: proc(trs: Transform) -> Matrix4 {
	scale_matrix := linalg.matrix4_scale_f32(trs.scale)
	rotation_matrix := linalg.matrix4_from_euler_angles_zxy_f32(trs.rotation.z, trs.rotation.x, trs.rotation.y)
	translation_matrix := linalg.matrix4_translate_f32(trs.translation)
	transform_matrix: Matrix4
	if !trs.inverted {
		transform_matrix = translation_matrix * rotation_matrix * scale_matrix
	} else {
		transform_matrix = scale_matrix * rotation_matrix * translation_matrix
	}
	return transform_matrix
}

transform_from_matrix4 :: proc(transform_matrix: Matrix4, inverted := false) -> Transform {
	unimplemented("TODO: Implement matrix decomposition to Transform's components")
}

// INTERSECTIONS ---------------------------------------------------------------------------------------------

// 2D intersection of two lines
@(require_results)
intersect_line_line :: proc "contextless" (a1, a2, b1, b2: [2]$E) -> (p: [2]E, ok: bool) {
	orient :: proc "contextless" (a, b, c: [2]E) -> E {
		return linalg.cross(b-a, c-a)
	}

	oa1 := orient(b1,b2,a1)
	oa2 := orient(b1,b2,a2)
	ob1 := orient(a1,a2,b1)
	ob2 := orient(a1,a2,b2)
	if oa1 * oa2 < 0 && ob1 * ob2 < 0 {
		p = (a1 * oa2 - a2 * oa1) / (oa2 - oa1)
		ok = true
	}
	return
}

// DISTANCES --------------------------------------------------------------------------------------------------

Line_Segment_Part :: enum { A, Between, B, }

// Returns a distance between a point and a line segment
@(require_results)
distance_point_line_segment :: proc "contextless" (p, a, b: [$I]$E) -> (d: E, within_segment_part: Line_Segment_Part) {
	line_vec := b-a
	inv_line_vec := a-b

	p_rel_to_line := p-a

	det1 := linalg.dot(p_rel_to_line, line_vec)
	if det1 <= 0 {
		return linalg.distance(p, a), .A
	}

	det2 := linalg.dot(p-b, inv_line_vec)
	if det2 <= 0 {
		return linalg.distance(p, b), .B
	}

	line_norm := linalg.normalize0(line_vec)
	p_dot_line := linalg.dot(p_rel_to_line, line_norm)
	p_proj := p_dot_line * line_norm
	return linalg.distance(p_proj, p_rel_to_line), .Between
}

// DYNAMIC ARRAY UTILS ----------------------------------------------------------------------------------------

clone_dynamic_array_in_place :: proc "contextless" (array: ^$T/[dynamic]$E) {
	allocator := array.allocator
	array^ = slice.clone_to_dynamic(array[:], allocator)
}

// MEMORY UTILS ----------------------------------------------------------------------------------------------

// Clone self-allocated - using its own allocator
clone_sa :: proc{
	clone_dynamic_array_sa,
}

// Clones the dynamic array using its own allocator
clone_dynamic_array_sa :: proc(array: $T/[dynamic]$E) -> [dynamic]E {
	allocator := array.allocator
	return clone_dynamic_array(array, allocator)
}

// Clone using the provided allocator
clone :: proc{
	clone_dynamic_array,
}

// Clones the dynamic array using the provided allocator
clone_dynamic_array :: proc(array: $T/[dynamic]$E, allocator := context.allocator) -> [dynamic]E {
	cloned_array := slice.clone_to_dynamic(array[:], allocator)
	return cloned_array
}

partition_memory :: proc(types: [$I]typeid, out_offsets: ^[I]uintptr) -> (size: int, align: int) {
	assert(len(types) == len(out_offsets))
	cur: int
	for t, i in types {
		if t == nil {
			// setting this to max will make sure any read/write on this memory crashes if not caught in time
			out_offsets[i] = max(uintptr)
			continue
		}
		ti := type_info_of(t)
		align = max(ti.align, align)
		cur = mem.align_forward_int(cur, ti.align)
		out_offsets[i] = uintptr(cur)
		cur += ti.size
	}
	return cur, align
}
