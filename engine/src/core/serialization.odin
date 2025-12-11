package core

import "base:intrinsics"
import "core:math/linalg"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:log"
import "core:mem"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"

// MJSON Serialization code heavily based on core:encoding/json

SERIALIZE_TYPE_NOT_IMPLEMENTED_MESSAGE :: "Type not implemented"
SERIALIZE_STRUCT_TAG :: "s"
SERIALIZE_STRUCT_TAG_COMPACT :: "compact"

Serialize_Context :: struct {
	level: int,  // logical "scope" of the structured serial
	indent: int, // actual visible indentation
	skipped_first_brace_start: bool,
	skipped_first_brace_end: bool,
}

Serialize_Flags :: distinct bit_set[Serialize_Flag]
Serialize_Flag :: enum {
	Compact,
	Allow_Unsupported_Types,
}

Serialize_Error :: enum {
	Success = 0,
	Enum_Name_Not_Found,
	Unsupported_Type,
	Unknown_Fail,
}

Serialize_Result :: union #shared_nil {
	Serialize_Error,
	io.Error,
}

serialize_init :: proc(using ctx: ^Serialize_Context) {
	mem.zero(ctx, size_of(Serialize_Context))
}

serialize_type :: proc{
	serialize_type_generic,
	serialize_type_dynamic,
}

serialize_type_generic :: proc(ctx: ^Serialize_Context, w: io.Writer, data: $T, flags: Serialize_Flags) -> Serialize_Result {
	return serialize_type_dynamic(ctx, w, data, flags)
}

serialize_type_dynamic :: proc(ctx: ^Serialize_Context, w: io.Writer, data: any, flags: Serialize_Flags) -> Serialize_Result {
	_unsupported_type :: proc(flags: Serialize_Flags) -> Serialize_Result {
		return .Success if .Allow_Unsupported_Types in flags else .Unsupported_Type
	}

	// TODO: Extract and check all collection element types
	_is_type_supported :: proc(ti: ^runtime.Type_Info) -> bool {
		#partial switch v in ti.variant {
		case runtime.Type_Info_Procedure,
			runtime.Type_Info_Parameters,
			runtime.Type_Info_Any,
			runtime.Type_Info_Pointer,
			runtime.Type_Info_Multi_Pointer,
			runtime.Type_Info_Soa_Pointer:
			return false
		}
		return true
	}

	assert(ctx != nil)
	assert(data != nil)

	ti := type_info_of(data.id)
	// supported type will be checked in the switch below
	type_name: string
	is_named: bool
	if named, ok := ti.variant.(runtime.Type_Info_Named); ok {
		is_named = true
		type_name = named.name
		ti = reflect.type_info_base(ti)
	}
	a := any{data.data, ti.id}

	switch info in ti.variant {
	case runtime.Type_Info_Named:
		unreachable()

	case runtime.Type_Info_Parameters:
		unreachable()

	case runtime.Type_Info_Integer:
		serialize_write_int(ctx, w, a) or_return

	case runtime.Type_Info_Rune:
		r := a.(rune)
		io.write_byte(w, '"')                           or_return
		io.write_escaped_rune(w, r, '"', for_json=true) or_return
		io.write_byte(w, '"')                           or_return

	case runtime.Type_Info_Float:
		serialize_write_float(ctx, w, a) or_return

	case runtime.Type_Info_Complex:
		c128: complex128
		switch c in a {
		case complex32:  c128 = complex128(c)
		case complex64:  c128 = complex128(c)
		case complex128: c128 = complex128(c)
		}

		c_as_vec := [2]f64{real(c128), imag(c128)}
		serialize_type_dynamic(ctx, w, c_as_vec, flags + {.Compact})

	case runtime.Type_Info_Quaternion:
		q256: quaternion256
		switch q in a {
		case quaternion64:  q256 = quaternion256(q)
		case quaternion128: q256 = quaternion256(q)
		case quaternion256: q256 = quaternion256(q)
		}

		q_as_vec := [4]f64{q256.x, q256.y, q256.z, q256.w}
		serialize_type_dynamic(ctx, w, q_as_vec, flags + {.Compact})

	case runtime.Type_Info_String:
		switch s in a {
		case string:  io.write_quoted_string(w, s, for_json=true)         or_return
		case cstring: io.write_quoted_string(w, string(s), for_json=true) or_return
		case: panic("Invalid string type.")
		}

	case runtime.Type_Info_Boolean:
		val: bool
		switch b in a {
		case bool: val = bool(b)
		case b8:   val = bool(b)
		case b16:  val = bool(b)
		case b32:  val = bool(b)
		case b64:  val = bool(b)
		}
		io.write_string(w, val ? "true" : "false") or_return

	case runtime.Type_Info_Any:
		return _unsupported_type(flags)

	case runtime.Type_Info_Type_Id:
		id := a.(typeid)
		// Deserializing the type will not be trivially possible, but it still may be useful to serialize it.
		// NOTE: I'm assuming types don't contain any characters that need escaping
		io.write_byte(w, '"')       or_return
		reflect.write_typeid(w, id) or_return
		io.write_byte(w, '"')       or_return

	case runtime.Type_Info_Pointer:
		return _unsupported_type(flags)

	case runtime.Type_Info_Multi_Pointer:
		return _unsupported_type(flags)

	case runtime.Type_Info_Procedure:
		return _unsupported_type(flags)

	case runtime.Type_Info_Array:
		is_compact := .Compact in flags
		serialize_write_start(ctx, w, '[', is_compact) or_return
		for i in 0..<info.count {
			serialize_write_iteration(ctx, w, i == 0, is_compact) or_return

			data := uintptr(a.data) + uintptr(i*info.elem_size)
			array_elem := any{rawptr(data), info.elem.id}
			// if a type is to be serialized with the compact flag, all inner types should also be compact
			serialize_type_dynamic(ctx, w, array_elem, flags) or_return
		}
		serialize_write_end(ctx, w, ']', is_compact) or_return

	case runtime.Type_Info_Enumerated_Array:
		is_compact := .Compact in flags
		// write enum array as json object
		serialize_write_start(ctx, w, '{', is_compact) or_return
		index_ti := runtime.type_info_base(info.index)
		enum_ti := index_ti.variant.(runtime.Type_Info_Enum)
		for i in 0..<info.count {
			value := cast(runtime.Type_Info_Enum_Value)i
			index, found := slice.linear_search(enum_ti.values, value)
			if !found {
				continue
			}

			serialize_write_iteration(ctx, w, i == 0, is_compact) or_return

			data := uintptr(a.data) + uintptr(i*info.elem_size)
			array_elem := any{rawptr(data), info.elem.id}

			// Write enum index name as key
			serialize_write_key(ctx, w, enum_ti.names[index], is_compact) or_return

			serialize_type_dynamic(ctx, w, array_elem, flags) or_return
		}
		serialize_write_end(ctx, w, '}', is_compact) or_return

	case runtime.Type_Info_Dynamic_Array:
		is_compact := .Compact in flags
		serialize_write_start(ctx, w, '[', is_compact) or_return
		array := cast(^runtime.Raw_Dynamic_Array)a.data
		for i in 0..<array.len {
			serialize_write_iteration(ctx, w, i == 0, is_compact) or_return

			data := uintptr(array.data) + uintptr(i*info.elem_size)
			array_elem := any{rawptr(data), info.elem.id}
			serialize_type_dynamic(ctx, w, array_elem, flags) or_return
		}
		serialize_write_end(ctx, w, ']', is_compact) or_return

	case runtime.Type_Info_Slice:
		is_compact := .Compact in flags
		serialize_write_start(ctx, w, '[', is_compact) or_return
		raw_slice := cast(^runtime.Raw_Slice)a.data
		for i in 0..<raw_slice.len {
			serialize_write_iteration(ctx, w, i == 0, is_compact) or_return

			data := uintptr(raw_slice.data) + uintptr(i*info.elem_size)
			slice_elem := any{rawptr(data), info.elem.id}
			serialize_type_dynamic(ctx, w, slice_elem, flags) or_return
		}
		serialize_write_end(ctx, w, ']', is_compact) or_return

	case runtime.Type_Info_Struct:
		serialize_struct_fields :: proc(ctx: ^Serialize_Context, w: io.Writer, data: any, flags: Serialize_Flags, is_anonymous_using: bool) -> Serialize_Result {
			struct_ti := reflect.type_info_base(type_info_of(data.id))
			info := struct_ti.variant.(runtime.Type_Info_Struct)
			first := true
			for field_name, i in info.names[:info.field_count] {
				field_ti := info.types[i]
				// Make sure not to write the key (field name) for unsupported types
				if !_is_type_supported(runtime.type_info_base(field_ti)) {
					if .Allow_Unsupported_Types not_in flags {
						return .Unsupported_Type
					}
					continue
				}

				field_data := rawptr(uintptr(data.data) + info.offsets[i])
				field_any := any{field_data, field_ti.id}

				is_field_compact: bool

				// Parse struct field tags
				field_tags := reflect.Struct_Tag(info.tags[i])
				if s_tags_str, ok := reflect.struct_tag_lookup(field_tags, SERIALIZE_STRUCT_TAG); ok {
					s_tags := strings.split(s_tags_str, ",", context.temp_allocator)
					for tag in s_tags {
						tag := strings.trim_space(tag)
						switch tag {
						case SERIALIZE_STRUCT_TAG_COMPACT:
							is_field_compact = true
						}
					}
				}

				is_struct_compact := .Compact in flags
				if !is_anonymous_using {
					serialize_write_iteration(ctx, w, first, is_struct_compact) or_return
				}
				first = false

				// Serialize 'using _: T' fields directly into the parent struct
				if info.usings[i] && field_name == "_" {
					serialize_struct_fields(ctx, w, field_any, flags, true) or_return
					continue
				}

				// Write field name as key
				serialize_write_key(ctx, w, field_name, is_struct_compact) or_return

				// here if the field is marked as compact, the flag should be propagated into all children
				field_flags := flags + {.Compact} if is_field_compact else flags
				serialize_type_dynamic(ctx, w, field_any, field_flags) or_return
			}
			return .Success
		}

		is_compact := .Compact in flags
		serialize_write_start(ctx, w, '{', is_compact) or_return
		serialize_struct_fields(ctx, w, data, flags, false) or_return
		serialize_write_end(ctx, w, '}', is_compact) or_return

	case runtime.Type_Info_Union:
		is_compact := .Compact in flags
		serialize_write_start(ctx, w, '{', is_compact) or_return

		serialize_write_iteration(ctx, w, true, is_compact) or_return
		// First write the union tag as a field
		serialize_write_key(ctx, w, "TAG", is_compact) or_return
		id := reflect.union_variant_typeid(a)
		reflect.write_typeid(w, id) or_return

		v := reflect.get_union_variant(a)
		if v != nil {
			serialize_write_iteration(ctx, w, false, is_compact) or_return
			serialize_write_key(ctx, w, "VARIANT", is_compact) or_return
			serialize_type_dynamic(ctx, w, v, flags) or_return
		}

		serialize_write_end(ctx, w, '}', is_compact) or_return

	case runtime.Type_Info_Enum:
		if enum_name, ok := reflect.enum_name_from_value_any(a); ok {
			io.write_quoted_string(w, enum_name, for_json=true) or_return
		} else {
			return .Enum_Name_Not_Found
		}

	case runtime.Type_Info_Map:
		is_compact := .Compact in flags
		serialize_write_start(ctx, w, '{', is_compact) or_return
		it: int
		first := true
		for k, v in reflect.iterate_map(a, &it) {
			serialize_write_iteration(ctx, w, first, is_compact) or_return
			first = false

			// Write map key
			serialize_type_dynamic(ctx, w, k, flags) or_return
			if is_compact {
				io.write_byte(w, '=') or_return
			} else {
				io.write_string(w, " = ") or_return
			}
			// Write value
			serialize_type_dynamic(ctx, w, v, flags) or_return
		}
		serialize_write_end(ctx, w, '}', is_compact) or_return

	case runtime.Type_Info_Bit_Set:
		unimplemented(SERIALIZE_TYPE_NOT_IMPLEMENTED_MESSAGE)

	case runtime.Type_Info_Simd_Vector:
		unimplemented(SERIALIZE_TYPE_NOT_IMPLEMENTED_MESSAGE)

	case runtime.Type_Info_Matrix:
		elem_ti := info.elem
		is_compact := .Compact in flags
		serialize_write_start(ctx, w, '[', is_compact) or_return
		#partial switch v in elem_ti.variant {
		case runtime.Type_Info_Integer:
			for row in 0..<info.row_count {
				serialize_write_iteration(ctx, w, row == 0, is_compact) or_return

				for col in 0..<info.column_count {
					serialize_write_iteration(ctx, w, col == 0, true) or_return

					offset: int
					switch info.layout {
					case .Column_Major: offset = (row + col*info.elem_stride)*info.elem_size
					case .Row_Major:    offset = (col + row*info.elem_stride)*info.elem_size
					}

					data := uintptr(a.data) + uintptr(offset)
					serialize_write_int(ctx, w, any{rawptr(data), info.elem.id}) or_return
				}
			}

		case runtime.Type_Info_Float:
			for row in 0..<info.row_count {
				serialize_write_iteration(ctx, w, row == 0, is_compact) or_return

				for col in 0..<info.column_count {
					serialize_write_iteration(ctx, w, col == 0, true) or_return

					offset: int
					switch info.layout {
					case .Column_Major: offset = (row + col*info.elem_stride)*info.elem_size
					case .Row_Major:    offset = (col + row*info.elem_stride)*info.elem_size
					}

					data := uintptr(a.data) + uintptr(offset)
					serialize_write_float(ctx, w, any{rawptr(data), info.elem.id}) or_return
				}
			}

		case: panic("Invalid matrix elem type.")
		}
		serialize_write_end(ctx, w, ']', is_compact) or_return

	case runtime.Type_Info_Soa_Pointer:
		return _unsupported_type(flags)

	case runtime.Type_Info_Bit_Field:
		unimplemented(SERIALIZE_TYPE_NOT_IMPLEMENTED_MESSAGE)
	}
	return .Success
}

serialize_write_indent :: proc(ctx: ^Serialize_Context, w: io.Writer) -> Serialize_Result {
	for i in 0..<ctx.indent {
		io.write_byte(w, '\t') or_return
	}
	return .Success
}

serialize_write_start :: proc(ctx: ^Serialize_Context, w: io.Writer, c: byte, compact: bool) -> Serialize_Result {
	defer ctx.level += 1
	if !ctx.skipped_first_brace_start && ctx.level == 0 && c == '{' {
		ctx.skipped_first_brace_start = true
		return .Success
	}

	io.write_byte(w, c) or_return
	if !compact {
		io.write_byte(w, '\n') or_return
		ctx.indent += 1
	}
	return .Success
}

serialize_write_end :: proc(ctx: ^Serialize_Context, w: io.Writer, c: byte, compact: bool) -> Serialize_Result {
	defer ctx.level -= 1
	if ctx.skipped_first_brace_start && !ctx.skipped_first_brace_end && ctx.level == 1 && c == '}' {
		ctx.skipped_first_brace_end = true
		return .Success
	}

	if !compact {
		io.write_byte(w, '\n')
		ctx.indent -= 1
		serialize_write_indent(ctx, w) or_return
	}
	io.write_byte(w, c) or_return
	return .Success
}

serialize_write_key :: proc(ctx: ^Serialize_Context, w: io.Writer, key: string, compact: bool) -> Serialize_Result {
	io.write_string(w, key) or_return
	if compact {
		io.write_byte(w, '=') or_return
	} else {
		io.write_string(w, " = ") or_return
	}
	return .Success
}

serialize_write_iteration :: proc(ctx: ^Serialize_Context, w: io.Writer, first: bool, compact: bool) -> Serialize_Result {
	if compact {
		if !first {
			io.write_byte(w, ' ') or_return
		}
	} else {
		if !first {
			io.write_byte(w, '\n') or_return
		}
		serialize_write_indent(ctx, w) or_return
	}
	return .Success
}

serialize_write_int :: proc(ctx: ^Serialize_Context, w: io.Writer, a: any) -> Serialize_Result {
	ti := type_info_of(a.id)
	info := ti.variant.(runtime.Type_Info_Integer)
	u := cast_any_int_to_u128(a)
	
	buf: [40]byte
	s := strconv.write_bits_128(buf[:], u, 10, info.signed, 8*ti.size, "0123456789", nil)
	io.write_string(w, s) or_return
	return .Success
}

serialize_write_float :: proc(ctx: ^Serialize_Context, w: io.Writer, a: any) -> Serialize_Result {
	assert(reflect.is_float(type_info_of(a.id)))

	f := cast_any_float_to_f64(a)
	
	buf: [386]byte
	s := strconv.write_float(buf[:], f, 'g', -1, 64)
	// Strip sign from "+<value>" but not "+Inf".
	if s[0] == '+' && s[1] != 'I' {
		s = s[1:]
	}
	io.write_string(w, s) or_return
	return .Success
}

// From core:encoding/json:marshal.odin
cast_any_int_to_u128 :: proc(any_int_value: any) -> u128 {
	u: u128 = 0
	switch i in any_int_value {
	case i8:      u = u128(i)
	case i16:     u = u128(i)
	case i32:     u = u128(i)
	case i64:     u = u128(i)
	case i128:    u = u128(i)
	case int:     u = u128(i)
	case u8:      u = u128(i)
	case u16:     u = u128(i)
	case u32:     u = u128(i)
	case u64:     u = u128(i)
	case u128:    u = u128(i)
	case uint:    u = u128(i)
	case uintptr: u = u128(i)

	case i16le:  u = u128(i)
	case i32le:  u = u128(i)
	case i64le:  u = u128(i)
	case u16le:  u = u128(i)
	case u32le:  u = u128(i)
	case u64le:  u = u128(i)
	case u128le: u = u128(i)

	case i16be:  u = u128(i)
	case i32be:  u = u128(i)
	case i64be:  u = u128(i)
	case u16be:  u = u128(i)
	case u32be:  u = u128(i)
	case u64be:  u = u128(i)
	case u128be: u = u128(i)
	}

	return u
}

cast_any_float_to_f64 :: proc(any_float_value: any) -> f64 {
	f: f64 = 0
	switch i in any_float_value {
	case f16:    f = f64(i)
	case f16le:  f = f64(i)
	case f16be:  f = f64(i)

	case f32:    f = f64(i)
	case f32le:  f = f64(i)
	case f32be:  f = f64(i)

	case f64:    f = f64(i)
	case f64le:  f = f64(i)
	case f64be:  f = f64(i)
	}

	return f
}
