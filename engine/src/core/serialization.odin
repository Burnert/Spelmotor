package core

import "base:intrinsics"
import "core:math/linalg"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:log"
import "core:math/bits"
import "core:mem"
import "core:mem/virtual"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "core:unicode/utf16"

// MJSON Serialization code heavily based on core:encoding/json

SERIALIZE_TYPE_NOT_IMPLEMENTED_MESSAGE :: "Type not implemented"
SERIALIZE_STRUCT_TAG :: "s"
SERIALIZE_STRUCT_TAG_COMPACT :: "compact"

// SERIALIZATION ----------------------------------------------------------------------------------------------------------------------

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
	Unsupported_Map_Key,
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

	case runtime.Type_Info_Any:
		return _unsupported_type(flags)

	case runtime.Type_Info_Pointer:
		return _unsupported_type(flags)

	case runtime.Type_Info_Multi_Pointer:
		return _unsupported_type(flags)

	case runtime.Type_Info_Procedure:
		return _unsupported_type(flags)

	case runtime.Type_Info_Soa_Pointer:
		return _unsupported_type(flags)

	case runtime.Type_Info_Rune:
		r := a.(rune)
		io.write_byte(w, '"')                           or_return
		io.write_escaped_rune(w, r, '"', for_json=true) or_return
		io.write_byte(w, '"')                           or_return

	case runtime.Type_Info_Integer:
		serialize_write_int(ctx, w, a) or_return

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

	case runtime.Type_Info_Type_Id:
		id := a.(typeid)
		// Deserializing the type will not be trivially possible, but it still may be useful to serialize it.
		// NOTE: I'm assuming types don't contain any characters that need escaping
		io.write_byte(w, '"')       or_return
		reflect.write_typeid(w, id) or_return
		io.write_byte(w, '"')       or_return


	case runtime.Type_Info_Array:
		// Weird case but it compiles fine...
		if info.count == 0 {
			io.write_string(w, "[]") or_return
			return .Success
		}

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

	case runtime.Type_Info_Simd_Vector:
		assert(info.count > 0)

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
		if info.count == 0 {
			io.write_string(w, "{}") or_return
			return .Success
		}

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
		array := cast(^runtime.Raw_Dynamic_Array)a.data
		if array.len == 0 {
			io.write_string(w, "[]") or_return
			return .Success
		}

		is_compact := .Compact in flags
		serialize_write_start(ctx, w, '[', is_compact) or_return
		for i in 0..<array.len {
			serialize_write_iteration(ctx, w, i == 0, is_compact) or_return

			data := uintptr(array.data) + uintptr(i*info.elem_size)
			array_elem := any{rawptr(data), info.elem.id}
			serialize_type_dynamic(ctx, w, array_elem, flags) or_return
		}
		serialize_write_end(ctx, w, ']', is_compact) or_return

	case runtime.Type_Info_Slice:
		raw_slice := cast(^runtime.Raw_Slice)a.data
		if raw_slice.len == 0 {
			io.write_string(w, "[]") or_return
			return .Success
		}

		is_compact := .Compact in flags
		serialize_write_start(ctx, w, '[', is_compact) or_return
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
			for field in reflect.struct_fields_zipped(data.id) {
				// Make sure not to write the key (field name) for unsupported types
				if !_is_type_supported(runtime.type_info_base(field.type)) {
					if .Allow_Unsupported_Types not_in flags {
						return .Unsupported_Type
					}
					continue
				}

				field_data := rawptr(uintptr(data.data) + field.offset)
				field_any := any{field_data, field.type.id}

				is_field_compact: bool

				// Parse struct field tags
				field_tags := reflect.Struct_Tag(field.tag)
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
				if !is_anonymous_using || !first {
					serialize_write_iteration(ctx, w, first, is_struct_compact) or_return
				}
				first = false

				// Serialize 'using _: T' fields directly into the parent struct
				if field.is_using && field.name == "_" {
					serialize_struct_fields(ctx, w, field_any, flags, true) or_return
					continue
				}

				// Write field name as key
				serialize_write_key(ctx, w, field.name, is_struct_compact) or_return

				// here if the field is marked as compact, the flag should be propagated into all children
				field_flags := flags + {.Compact} if is_field_compact else flags
				serialize_type_dynamic(ctx, w, field_any, field_flags) or_return
			}
			return .Success
		}

		if info.field_count == 0 {
			io.write_string(w, "{}") or_return
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
		io.write_byte(w, '"') or_return
		reflect.write_typeid(w, id) or_return
		io.write_byte(w, '"') or_return

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
		raw_map := cast(^runtime.Raw_Map)a.data
		map_len := runtime.map_len(raw_map^)
		if map_len == 0 {
			io.write_string(w, "{}") or_return
			return .Success
		}

		is_compact := .Compact in flags
		serialize_write_start(ctx, w, '{', is_compact) or_return
		it: int
		first := true
		for k, v in reflect.iterate_map(a, &it) {
			serialize_write_iteration(ctx, w, first, is_compact) or_return
			first = false

			// Write map key
			#partial switch v in runtime.type_info_base(type_info_of(k.id)).variant {
			case runtime.Type_Info_Integer:
				io.write_byte(w, '"') or_return
				serialize_write_int(ctx, w, k) or_return
				io.write_byte(w, '"') or_return

			case runtime.Type_Info_String:
				switch v in k {
				case string:
					r, _ := utf8.decode_rune_in_string(v)
					write_quotes := unicode.is_number(r)
					if write_quotes {
						io.write_quoted_string(w, v) or_return
					} else {
						io.write_string(w, v) or_return
					}
				case string16:
					r, _ := utf16.decode_rune_in_string(v)
					write_quotes := unicode.is_number(r)
					if write_quotes {
						io.write_quoted_string16(w, v) or_return
					} else {
						io.write_string16(w, v) or_return
					}
				case cstring:
					r, _ := utf8.decode_rune_in_string(string(v))
					write_quotes := unicode.is_number(r)
					if write_quotes {
						io.write_quoted_string(w, string(v)) or_return
					} else {
						io.write_string(w, string(v)) or_return
					}
				case cstring16:
					r, _ := utf16.decode_rune_in_string(string16(v))
					write_quotes := unicode.is_number(r)
					if write_quotes {
						io.write_quoted_string16(w, string16(v)) or_return
					} else {
						io.write_string16(w, string16(v)) or_return
					}
				}
			
			case:
				return .Unsupported_Map_Key
			}
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
		elem_ti := runtime.type_info_base(info.elem)
		bit_size := uint(8*elem_ti.size)

		value: u64
		switch bit_size {
		case 0:
			io.write_string(w, "[]") or_return
			return .Success

		case 8:
			data := cast(^u8)a.data
			value = u64(data^)

		case 16:
			data := cast(^u16)a.data
			value = u64(data^)

		case 32:
			data := cast(^u32)a.data
			value = u64(data^)

		case 64:
			data := cast(^u64)a.data
			value = u64(data^)

		case: panic("Invalid bit set size.")
		}

		// upper is inclusive
		elem_count := info.upper+1 - info.lower
		assert(elem_count > 0)
		assert(uint(elem_count) <= bit_size)

		// It seems like there may be garbage in the unused bits.
		mask := ~(~u64(1) << uint(elem_count))
		masked_value := value & mask
		if masked_value == 0 {
			io.write_string(w, "[]") or_return
			return .Success
		}

		is_compact := .Compact in flags
		#partial switch v in elem_ti.variant {
		case runtime.Type_Info_Integer:
			serialize_write_start(ctx, w, '[', is_compact) or_return
			first := true
			for i in 0..<uint(elem_count) {
				bit := u64(1)<<i
				if masked_value & bit == bit {
					serialize_write_iteration(ctx, w, first, is_compact) or_return
					first = false

					elem_value := info.lower + i64(i)
					serialize_write_int(ctx, w, elem_value) or_return
				}
			}
			serialize_write_end(ctx, w, ']', is_compact) or_return

		case runtime.Type_Info_Rune:
			serialize_write_start(ctx, w, '[', is_compact) or_return
			first := true
			for i in 0..<uint(elem_count) {
				bit := u64(1)<<i
				if masked_value & bit == bit {
					serialize_write_iteration(ctx, w, first, is_compact) or_return
					first = false

					elem_value := rune(info.lower + i64(i))
					io.write_byte(w, '"') or_return
					io.write_escaped_rune(w, elem_value, '"', for_json=true) or_return
					io.write_byte(w, '"') or_return
				}
			}
			serialize_write_end(ctx, w, ']', is_compact) or_return

		case runtime.Type_Info_Enum:
			if len(v.values) == 0 {
				// There are values in the bit set, but the enum has no values, so it can be safely assumed that the name won't be found.
				// This is an invalid state, but handling it is basically free.
				return .Enum_Name_Not_Found
			}

			serialize_write_start(ctx, w, '[', is_compact) or_return
			first := true
			bit_loop: for i in 0..<uint(elem_count) {
				bit := u64(1)<<i
				if masked_value & bit == bit {
					serialize_write_iteration(ctx, w, first, is_compact) or_return
					first = false

					// Not using reflect.enum_name_from_value_any here because I'm not sure if constructing an any with a wrong underlying type will be an issue.
					enum_value := runtime.Type_Info_Enum_Value(info.lower + i64(i))
					for val, idx in v.values {
						if val == enum_value {
							enum_name := v.names[idx]
							io.write_quoted_string(w, enum_name, for_json=true) or_return
							continue bit_loop
						}
					}
					return .Enum_Name_Not_Found
				}
			}
			serialize_write_end(ctx, w, ']', is_compact) or_return

		case: panic("Invalid bit set element type.")
		}

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

	case runtime.Type_Info_Bit_Field:
		// from fmt_bit_field
		read_bits :: proc(ptr: [^]byte, offset, size: uintptr) -> (res: u64) {
			// read one bit at a time
			for b in 0..<size {
				bit := b + offset
				byte_offset := bit/8
				B := ptr[byte_offset]
				k := bit % 8
				if B & (u8(1)<<k) != 0 {
					res |= u64(1)<<u64(b)
				}
			}
			return
		}

		if info.field_count == 0 {
			io.write_string(w, "{}") or_return
			return .Success
		}

		is_compact := .Compact in flags
		serialize_write_start(ctx, w, '{', is_compact) or_return
		for field, i in reflect.bit_fields_zipped(a.id) {
			serialize_write_iteration(ctx, w, i == 0, is_compact) or_return

			data := cast([^]u8)a.data
			field_value := read_bits(data, field.offset, field.size)

			if !reflect.is_unsigned(runtime.type_info_core(field.type)) {
				// Sign Extension
				m := u64(1<<(field.size-1))
				field_value = (field_value ~ m) - m
			}

			serialize_write_key(ctx, w, field.name, is_compact) or_return
			serialize_write_int(ctx, w, any{&field_value, field.type.id}) or_return
		}
		serialize_write_end(ctx, w, '}', is_compact) or_return
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
	r, _ := utf8.decode_rune_in_string(key)
	write_quotes := unicode.is_number(r)
	if write_quotes {
		io.write_quoted_string(w, key, for_json=true) or_return
	} else {
		io.write_string(w, key) or_return
	}

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

// DESERIALIZATION ---------------------------------------------------------------------------------------------------------------------

Deserialize_Context :: struct {
	unmarshal_error: json.Unmarshal_Error,
}

Deserialize_Error :: enum {
	Success = 0,
	Invalid_Parameter,
	Non_Pointer_Parameter,
	Invalid_Data,
	Unmarshal_Error,
	Unsupported_Type,
	Multiple_Used_Fields,
	Invalid_Rune_Format,
	Invalid_Integer_Format,
	Invalid_Float_Format,
}

Deserialize_Result :: union #shared_nil {
	Deserialize_Error,
	io.Error,
	runtime.Allocator_Error,
	json.Error,
}

deserialize_type :: proc{
	deserialize_type_generic,
	deserialize_type_dynamic,
}

deserialize_type_generic :: proc(ctx: ^Deserialize_Context, r: io.Reader, out: ^$T) -> Deserialize_Result {
	return deserialize_type_dynamic(ctx, r, out)
}

deserialize_type_dynamic :: proc(ctx: ^Deserialize_Context, r: io.Reader, out: any) -> Deserialize_Result {
	out := out
	if out == nil || out.id == nil || out.data == nil {
		return .Invalid_Parameter
	}

	out = reflect.any_base(out)
	ti := type_info_of(out.id)
	if !reflect.is_pointer(ti) || ti.id == rawptr {
		return .Non_Pointer_Parameter
	}

	stream_size := io.size(r) or_return
	serial := make([]byte, stream_size, context.allocator) or_return
	defer delete(serial)
	io.read_full(r, serial) or_return

	PARSE_INTEGERS :: true
	if !json.is_valid(serial, .MJSON, PARSE_INTEGERS) {
		return .Invalid_Data
	}

	parser_arena: virtual.Arena
	virtual.arena_init_growing(&parser_arena) or_return
	defer virtual.arena_destroy(&parser_arena)
	parser_allocator := virtual.arena_allocator(&parser_arena)
	p := json.make_parser(serial, .MJSON, PARSE_INTEGERS, parser_allocator)

	out_value_ptr := (cast(^rawptr)(out.data))^
	out_value_id := ti.variant.(reflect.Type_Info_Pointer).elem.id
	data := any{out_value_ptr, out_value_id}
	
	context.allocator = parser_allocator
	
	#partial switch p.curr_token.kind {
	case .Ident, .String:
		return deserialize_object(ctx, &p, data, .EOF)
	case:
		return deserialize_value(ctx, &p, data)
	}
}

deserialize_object :: proc(ctx: ^Deserialize_Context, p: ^json.Parser, value: any, end_token: json.Token_Kind) -> Deserialize_Result {
	if end_token == .Close_Brace {
		json.expect_token(p, .Open_Brace) or_return
	}

	ti := reflect.type_info_base(type_info_of(value.id))
	#partial switch v in ti.variant {
	case runtime.Type_Info_Struct:
		if .raw_union in v.flags {
			return .Unsupported_Type
		}

		Struct_Fields :: #soa[]reflect.Struct_Field
		fields := reflect.struct_fields_zipped(ti.id)

		count_embedded_struct_fields :: proc(t: typeid) -> int {
			ti := runtime.type_info_base(type_info_of(t))
			s := ti.variant.(runtime.Type_Info_Struct)
			count := int(s.field_count)
			for field in reflect.struct_fields_zipped(t) {
				if field.is_using && field.name == "_" {
					count -= 1 // remove the field itself
					count += count_embedded_struct_fields(field.type.id)
				}
			}
			return count
		}

		embedded_field_count := count_embedded_struct_fields(ti.id)
		used_fields_bytes := intrinsics.alloca(embedded_field_count, 1)
		intrinsics.mem_zero(used_fields_bytes, embedded_field_count)
		used_fields := mem.slice_data_cast([]bool, slice.from_ptr(used_fields_bytes, embedded_field_count))

		struct_loop: for p.curr_token.kind != end_token {
			key := json.parse_object_key(p, p.allocator) or_return
			defer delete(key, p.allocator)
			
			json.expect_token(p, .Colon) or_return

			find_embedded_struct_field :: proc(key: string, parent: typeid, inner_field_count: ^int = nil) -> (offset: uintptr, type: ^reflect.Type_Info, index: int, found: bool) {
				for field in reflect.struct_fields_zipped(parent) {
					if field.is_using && field.name == "_" {
						inner_index: int
						inner_field_count: int
						offset, type, inner_index, found = find_embedded_struct_field(key, field.type.id, &inner_field_count)
						if found {
							index += inner_index
							offset += field.offset
							return
						}
						index += inner_field_count
						continue
					}

					if field.name == key {
						offset = field.offset
						type = field.type
						found = true
						return
					}
					index += 1
				}
				inner_field_count^ = index
				return
			}

			field_offset, field_type, field_index, field_found := find_embedded_struct_field(key, ti.id)
			if field_found {
				if used_fields[field_index] {
					return .Multiple_Used_Fields
				}
				used_fields[field_index] = true
				
				field_ptr := rawptr(uintptr(value.data) + field_offset)
				field := any{field_ptr, field_type.id}
				deserialize_value(ctx, p, field) or_return

				if json.parse_comma(p) {
					break struct_loop
				}
				continue struct_loop
			} else {
				// allows skipping unused struct fields

				// NOTE(bill): prevent possible memory leak if a string is unquoted
				allocator := p.allocator
				defer p.allocator = allocator
				p.allocator = mem.nil_allocator()

				json.parse_value(p) or_return
				if json.parse_comma(p) {
					break struct_loop
				}
				continue struct_loop
			}
		}

	case runtime.Type_Info_Map:
	case runtime.Type_Info_Enumerated_Array:
	case runtime.Type_Info_Union:
	case runtime.Type_Info_Bit_Field:
	}
	// switch p.curr_token.kind {
	// case .Invalid:
	// case .EOF:
	// case .Null:
	// case .False:
	// case .True:
	// case .Infinity:
	// case .NaN:
	// case .Ident:
	// case .Integer:
	// case .Float:
	// case .String:
	// case .Colon:
	// case .Comma:
	// case .Open_Brace:
	// case .Close_Brace:
	// case .Open_Bracket:
	// case .Close_Bracket:
	// }

	if end_token == .Close_Brace {
		json.expect_token(p, .Close_Brace) or_return
	}

	return .Success
}

deserialize_value :: proc(ctx: ^Deserialize_Context, p: ^json.Parser, value: any) -> Deserialize_Result {
	ti := runtime.type_info_base(type_info_of(value.id))
	switch ti_v in ti.variant {
	case runtime.Type_Info_Named:
		unreachable()

	case runtime.Type_Info_Parameters:
		unreachable()

	case runtime.Type_Info_Any:
		return .Unsupported_Type

	case runtime.Type_Info_Pointer:
		return .Unsupported_Type

	case runtime.Type_Info_Multi_Pointer:
		return .Unsupported_Type

	case runtime.Type_Info_Procedure:
		return .Unsupported_Type

	case runtime.Type_Info_Soa_Pointer:
		return .Unsupported_Type

	case runtime.Type_Info_Rune:
		t := p.curr_token
		json.expect_token(p, .String) or_return

		text := t.text[1:len(t.text)-1]
		r, n := utf8.decode_rune(text)
		if n != len(text) {
			return .Invalid_Rune_Format
		}

		v := &value.(rune)
		v^ = r

		return .Success

	case runtime.Type_Info_Integer:
		t := p.curr_token
		json.expect_token(p, .Integer) or_return

		ok: bool
		parsed_i128: i128
		parsed_u128: u128
		if ti_v.signed {
			parsed_i128, ok = strconv.parse_i128_maybe_prefixed(t.text)
		} else {
			parsed_u128, ok = strconv.parse_u128_maybe_prefixed(t.text)
		}
		if !ok {
			return .Invalid_Integer_Format
		}

		switch &v in value {
		case int:   v =  int(parsed_i128)
		case i8:    v =   i8(parsed_i128)
		case i16:   v =  i16(parsed_i128)
		case i32:   v =  i32(parsed_i128)
		case i64:   v =  i64(parsed_i128)
		case i128:  v = i128(parsed_i128)

		case uint:  v = uint(parsed_u128)
		case u8:    v =   u8(parsed_u128)
		case u16:   v =  u16(parsed_u128)
		case u32:   v =  u32(parsed_u128)
		case u64:   v =  u64(parsed_u128)
		case u128:  v = u128(parsed_u128)

		case uintptr:  v = uintptr(parsed_u128)

		case i16le:   v =  i16le(parsed_i128)
		case i32le:   v =  i32le(parsed_i128)
		case i64le:   v =  i64le(parsed_i128)
		case i128le:  v = i128le(parsed_i128)
		case u16le:   v =  u16le(parsed_u128)
		case u32le:   v =  u32le(parsed_u128)
		case u64le:   v =  u64le(parsed_u128)
		case u128le:  v = u128le(parsed_u128)

		case i16be:   v =  i16be(parsed_i128)
		case i32be:   v =  i32be(parsed_i128)
		case i64be:   v =  i64be(parsed_i128)
		case i128be:  v = i128be(parsed_i128)
		case u16be:   v =  u16be(parsed_i128)
		case u32be:   v =  u32be(parsed_i128)
		case u64be:   v =  u64be(parsed_i128)
		case u128be:  v = u128be(parsed_i128)
		}

		return .Success

	case runtime.Type_Info_Float:
		t := json.advance_token(p) or_return
		#partial switch t.kind {
		case .Integer, .Float, .Infinity, .NaN:
			parsed_f64, ok := strconv.parse_f64(t.text)
			if !ok {
				return .Invalid_Float_Format
			}

			switch &v in value {
			case f16:    v =   f16(parsed_f64)
			case f16le:  v = f16le(parsed_f64)
			case f16be:  v = f16be(parsed_f64)

			case f32:    v =   f32(parsed_f64)
			case f32le:  v = f32le(parsed_f64)
			case f32be:  v = f32be(parsed_f64)

			case f64:    v =   f64(parsed_f64)
			case f64le:  v = f64le(parsed_f64)
			case f64be:  v = f64be(parsed_f64)
			}

			return .Success

		case:
			return .Unexpected_Token
		}

	case runtime.Type_Info_Complex:

	case runtime.Type_Info_Quaternion:

	case runtime.Type_Info_String:

	case runtime.Type_Info_Boolean:

	case runtime.Type_Info_Type_Id:

	case runtime.Type_Info_Array:

	case runtime.Type_Info_Enumerated_Array:

	case runtime.Type_Info_Dynamic_Array:

	case runtime.Type_Info_Slice:

	case runtime.Type_Info_Struct:

	case runtime.Type_Info_Union:

	case runtime.Type_Info_Enum:

	case runtime.Type_Info_Map:

	case runtime.Type_Info_Bit_Set:

	case runtime.Type_Info_Simd_Vector:

	case runtime.Type_Info_Matrix:

	case runtime.Type_Info_Bit_Field:

	}

	allocator := p.allocator
	defer p.allocator = allocator
	p.allocator = mem.nil_allocator()

	json.parse_value(p) or_return

	return .Success
}

// UTILS ---------------------------------------------------------------------------------------------------------------------

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
	case i128le: u = u128(i)
	case u16le:  u = u128(i)
	case u32le:  u = u128(i)
	case u64le:  u = u128(i)
	case u128le: u = u128(i)

	case i16be:  u = u128(i)
	case i32be:  u = u128(i)
	case i64be:  u = u128(i)
	case i128be: u = u128(i)
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
