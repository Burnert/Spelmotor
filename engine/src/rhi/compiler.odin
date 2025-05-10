package sm_rhi

import "base:runtime"
import "core:c"
import "core:log"
import "core:mem"
import os "core:os/os2"
import "core:strings"

import "smv:shaderc"

// TODO: All of this compiler code should only be included in dev builds and needs to be stripped in dist.

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
		return shaderc_compile_shader(source, source_name, shader_type, entry_point, allocator)
	}
	return
}

free_shader_bytecode :: proc(bytecode: Shader_Bytecode, allocator := context.allocator) {
	delete(bytecode, allocator)
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
		log.infof("Shader %s has compiled successfully.", source_name)
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
