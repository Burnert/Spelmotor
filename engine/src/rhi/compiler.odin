package sm_rhi

import "base:runtime"
import "core:c"
import "core:log"
import "core:mem"
import os "core:os/os2"
import "core:slice"
import "core:strings"
import xxh "core:hash/xxhash"

import "sm:core"
import "smv:shaderc"

// TODO: All of this compiler code should only be included in dev builds and needs to be stripped in dist.

SHADER_BYTE_CODE_FILE_EXT :: ".spv"
SHADER_SOURCE_HASH_FILE_EXT :: ".xxh"

Shader_Source_Hash :: xxh.XXH3_128_hash

Shader_Bytecode :: []byte

Shader_Type :: enum {
	Vertex,
	Fragment,
}

conv_shader_type_to_shaderc :: proc(type: Shader_Type) -> shaderc.shaderKind {
	switch type {
	case .Vertex:
		return .VertexShader
	case .Fragment:
		return .FragmentShader
	case:
		panic("Invalid shader type.")
	}
}

compile_shader :: proc(source: string, source_name: string, shader_type: Shader_Type, entry_point: string, allocator := context.allocator) -> (bytecode: Shader_Bytecode, ok: bool) {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		bytecode, ok = shaderc_compile_shader(source, source_name, shader_type, entry_point, allocator)
		if !ok {
			return
		}
	}

	return
}

free_shader_bytecode :: proc(bytecode: Shader_Bytecode, allocator := context.allocator) {
	delete(bytecode, allocator)
}

hash_shader_source :: proc(source: string) -> Shader_Source_Hash {
	source_hash := xxh.XXH3_128(transmute([]byte)source)
	return source_hash
}

format_cached_shader_filename :: proc(source_name: string, extension: string, allocator := context.allocator) -> string {
	dir, filename := os.split_path(source_name)
	shaders_root := core.path_make_engine_shader_relative("", context.temp_allocator)
	shaders_root_abs, abs_err := os.get_absolute_path(shaders_root, context.temp_allocator)
	assert(abs_err == nil)
	rel_dir, err := os.get_relative_path(shaders_root_abs, dir, context.temp_allocator)
	assert(err == nil)

	b := strings.builder_make(context.temp_allocator)
	if len(rel_dir) > 0 {
		rel_dir_name, was_alloc := strings.replace(rel_dir, os.Path_Separator_String, ".", -1)
		assert(!was_alloc)
		strings.write_string(&b, rel_dir_name)
		strings.write_rune(&b, '.')
	}
	strings.write_string(&b, filename)
	strings.write_string(&b, extension)

	cache_filename := strings.to_string(b)

	return core.path_make_engine_shader_cache_relative(cache_filename, allocator)
}

cache_shader_bytecode :: proc(bytecode: Shader_Bytecode, source_name: string, source_hash: Shader_Source_Hash) -> (ok: bool) {
	cache_filepath := format_cached_shader_filename(source_name, SHADER_BYTE_CODE_FILE_EXT, context.temp_allocator)
	cache_dir, _ := os.split_path(cache_filepath)
	os.mkdir_all(cache_dir)
	write_err := os.write_entire_file(cache_filepath, bytecode)
	if write_err != nil {
		log.errorf("Failed to write shader bytecode cache file %s.", cache_filepath)
		return false
	}

	// Also save a hash of the source code to allow for content-based invalidation.
	cache_hash_filepath := format_cached_shader_filename(source_name, SHADER_SOURCE_HASH_FILE_EXT, context.temp_allocator)
	source_hash_bytes := slice.to_bytes([]Shader_Source_Hash{source_hash})
	write_err = os.write_entire_file(cache_hash_filepath, source_hash_bytes)
	if write_err != nil {
		log.warnf("Failed to write shader source hash file %s.", cache_filepath)
	}

	_, cache_filename := os.split_path(cache_filepath)
	log.infof("Bytecode for shader %s has been cached as %s.", source_name, cache_filename)
	return true
}

resolve_cached_shader_bytecode :: proc(source_name: string, source_hash: Shader_Source_Hash, allocator := context.allocator) -> (bytecode: Shader_Bytecode, ok: bool) {
	cache_hash_filepath := format_cached_shader_filename(source_name, SHADER_SOURCE_HASH_FILE_EXT, context.temp_allocator)
	hash_bytes, hash_err := os.read_entire_file(cache_hash_filepath, context.temp_allocator)
	// If the hash file can't be read it's best not to read the bytecode from the cache because it might me outdated.
	if hash_err != nil {
		ok = false
		return
	}

	hash := slice.to_type(hash_bytes, Shader_Source_Hash)
	// This means the source code has changed and will most likely compile to a different bytecode.
	if source_hash != hash {
		ok = false
		return
	}

	cache_filepath := format_cached_shader_filename(source_name, SHADER_BYTE_CODE_FILE_EXT, context.temp_allocator)
	err: os.Error
	bytecode, err = os.read_entire_file(cache_filepath, allocator)
	// The bytecode file reading might fail.
	ok = err == nil
	return
}

@(private)
shaderc_compile_shader :: proc(source: string, source_name: string, shader_type: Shader_Type, entry_point: string, allocator := context.allocator) -> (bytecode: Shader_Bytecode, ok: bool) {
	compiler := shaderc.compiler_initialize()
	defer shaderc.compiler_release(compiler)

	options := shaderc.compile_options_initialize()
	defer shaderc.compile_options_release(options)

	// TODO: Make a dedicated constant/flag for shader debugging
	when ODIN_DEBUG {
		shaderc_add_shader_macro_definition(options, "DEBUG", "1")
		shaderc.compile_options_set_generate_debug_info(options)
		shaderc.compile_options_set_optimization_level(options, .Zero)
	} else {
		shaderc.compile_options_set_optimization_level(options, .Performance)
	}

	Include_User_Data :: struct {
		ctx: runtime.Context,
	}
	include_user_data: Include_User_Data
	include_user_data.ctx = context

	include_resolve_fn :: proc "c" (user_data: rawptr, requested_source: cstring, type: c.int, requesting_source: cstring, include_depth: c.size_t) -> (include_result: ^shaderc.includeResult) {
		include_user_data := cast(^Include_User_Data)user_data
		context = include_user_data.ctx

		type := cast(shaderc.includeType)type
		requested_source := string(requested_source)
		requesting_source := string(requesting_source)

		included_file: string
		switch type {
		case .Relative:
			dir, filename := os.split_path(requesting_source)
			join_err: os.Error
			included_file, join_err = os.join_path({dir, requested_source}, context.allocator)
			assert(join_err == nil)
		case .Standard:
			included_file = strings.clone(requested_source)
		}
		
		content, read_err := os.read_entire_file(included_file, context.allocator)
		assert(read_err == nil)

		include_result = new(shaderc.includeResult)
		include_result.sourceName = strings.unsafe_string_to_cstring(included_file)
		include_result.sourceNameLength = len(included_file)
		include_result.content = strings.unsafe_string_to_cstring(string(content))
		include_result.contentLength = len(content)
		return
	}

	include_result_release_fn :: proc "c" (user_data: rawptr, include_result: ^shaderc.includeResult) {
		include_user_data := cast(^Include_User_Data)user_data
		context = include_user_data.ctx

		delete(include_result.content)
		delete(include_result.sourceName)
		free(include_result)
	}

	shaderc.compile_options_set_include_callbacks(options, include_resolve_fn, include_result_release_fn, &include_user_data)

	c_source := strings.unsafe_string_to_cstring(source)
	shaderc_shader_type := conv_shader_type_to_shaderc(shader_type)
	c_source_name := strings.clone_to_cstring(source_name, context.temp_allocator)
	c_entry_point := strings.clone_to_cstring(entry_point, context.temp_allocator)

	compilation_result := shaderc.compile_into_spv(compiler, c_source, len(source), shaderc_shader_type, c_source_name, c_entry_point, options)
	defer shaderc.result_release(compilation_result)

	compilation_status := shaderc.result_get_compilation_status(compilation_result)
	if compilation_status == .Success {
		log.infof("Shader %s has been compiled successfully.", source_name)
	} else {
		log.errorf("Shader %s compilation has failed.", source_name)
	}

	num_errors := shaderc.result_get_num_errors(compilation_result)
	num_warnings := shaderc.result_get_num_warnings(compilation_result)
	if num_errors > 0 || num_warnings > 0 {
		error_message := shaderc.result_get_error_message(compilation_result)
		log.error("Shader compilation messages:", error_message, sep="\n")
	}

	if compilation_status != .Success {
		ok = false
		return
	}

	bytecode_len := shaderc.result_get_length(compilation_result)
	bytecode_bytes := shaderc.result_get_bytes(compilation_result)

	// This duplicates memory allocations and requires copying blobs but it's way more convenient
	// to just return a byte slice instead of this clunky compilation result handle.
	// Aligned because SPIR-V requires the code to be castable to a u32 pointer
	bytes, err := mem.make_aligned([]byte, bytecode_len, size_of(u32), allocator)
	assert(err == .None)

	mem.copy_non_overlapping(&bytes[0], bytecode_bytes, cast(int)bytecode_len)

	bytecode = bytes
	ok = true

	return
}

@(private)
shaderc_add_shader_macro_definition :: proc(options: shaderc.compileOptionsT, name: string, value: string) {
	c_name := strings.unsafe_string_to_cstring(name)
	c_value := strings.unsafe_string_to_cstring(value)
	shaderc.compile_options_add_macro_definition(options, c_name, len(name), c_value, len(value))
}
