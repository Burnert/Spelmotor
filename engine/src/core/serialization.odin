package core

import "sm:core"
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

// JSON Serialization code heavily based on core:encoding/json

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
	prof_scoped_event(fmt.tprint(#procedure, data.id))

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
		case string:    io.write_quoted_string(w, s, for_json=true)             or_return
		case cstring:   io.write_quoted_string(w, string(s), for_json=true)     or_return
		case string16:  io.write_quoted_string16(w, s, for_json=true)           or_return
		case cstring16: io.write_quoted_string16(w, string16(s), for_json=true) or_return
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
		raw_array := cast(^runtime.Raw_Dynamic_Array)a.data
		if raw_array.len == 0 {
			io.write_string(w, "[]") or_return
			return .Success
		}

		is_compact := .Compact in flags
		serialize_write_start(ctx, w, '[', is_compact) or_return
		for i in 0..<raw_array.len {
			serialize_write_iteration(ctx, w, i == 0, is_compact) or_return

			data := uintptr(raw_array.data) + uintptr(i*info.elem_size)
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
				contains_space :: proc(s: $T) -> bool {
					for r in s {
						if strings.is_space(r) {
							return true
						}
					}
					return false
				}

				switch v in k {
				case string:
					r, _ := utf8.decode_rune_in_string(v)
					write_quotes := unicode.is_number(r) || contains_space(v)
					if write_quotes {
						io.write_quoted_string(w, v) or_return
					} else {
						io.write_string(w, v) or_return
					}
				case string16:
					r, _ := utf16.decode_rune_in_string(v)
					write_quotes := unicode.is_number(r) || contains_space(v)
					if write_quotes {
						io.write_quoted_string16(w, v) or_return
					} else {
						io.write_string16(w, v) or_return
					}
				case cstring:
					r, _ := utf8.decode_rune_in_string(string(v))
					write_quotes := unicode.is_number(r) || contains_space(string(v))
					if write_quotes {
						io.write_quoted_string(w, string(v)) or_return
					} else {
						io.write_string(w, string(v)) or_return
					}
				case cstring16:
					r, _ := utf16.decode_rune_in_string(string16(v))
					write_quotes := unicode.is_number(r) || contains_space(string16(v))
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
	value_allocator: runtime.Allocator,
	temp_allocator: runtime.Allocator,
	temp_arena: virtual.Arena,
	unmarshal_error: json.Unmarshal_Error,
}

Deserialize_Error :: enum {
	Success = 0,
	Invalid_Parameter,
	Non_Pointer_Parameter,
	Invalid_Data,
	Unmarshal_Error,
	Unsupported_Type,
	Multiple_Struct_Fields,
	Multiple_Map_Fields,
	Invalid_Rune_Format,
	Invalid_Integer_Format,
	Invalid_Float_Format,
	Invalid_Boolean_Format,
	Invalid_Enum_Name,
	Invalid_Array_Size,
	Invalid_Union_Format,
	Invalid_Union_Tag,
}

Deserialize_Result :: union #shared_nil {
	Deserialize_Error,
	io.Error,
	runtime.Allocator_Error,
	json.Error,
}

deserialize_init :: proc(ctx: ^Deserialize_Context, value_allocator := context.allocator) -> Deserialize_Result {
	mem.zero(ctx, size_of(Deserialize_Context))
	ctx.value_allocator = value_allocator

	virtual.arena_init_growing(&ctx.temp_arena) or_return
	ctx.temp_allocator = virtual.arena_allocator(&ctx.temp_arena)

	return .Success
}

deserialize_cleanup :: proc(ctx: ^Deserialize_Context) {
	virtual.arena_destroy(&ctx.temp_arena)
}

deserialize_type :: proc{
	deserialize_type_generic,
	deserialize_type_dynamic,
}

deserialize_type_generic :: proc(ctx: ^Deserialize_Context, r: io.Reader, out: ^$T) -> Deserialize_Result {
	return deserialize_type_dynamic(ctx, r, out)
}

deserialize_type_dynamic :: proc(ctx: ^Deserialize_Context, r: io.Reader, out: any) -> Deserialize_Result {
	prof_scoped_event(fmt.tprint(#procedure, out.id))

	out := out
	if out == nil || out.id == nil || out.data == nil {
		return .Invalid_Parameter
	}

	out = reflect.any_base(out)
	ti := type_info_of(out.id)
	if !reflect.is_pointer(ti) || ti.id == rawptr {
		return .Non_Pointer_Parameter
	}

	// TODO: Fix allocator choices
	serial: []byte
	{
		prof_scoped_event("Read full serial")

		stream_size := io.size(r) or_return
		serial = make([]byte, stream_size, ctx.temp_allocator) or_return
		defer delete(serial, ctx.temp_allocator)
		io.read_full(r, serial) or_return
	}

	PARSE_INTEGERS :: true
	if !json.is_valid(serial, .SJSON, PARSE_INTEGERS) {
		return .Invalid_Data
	}

	parser_arena: virtual.Arena
	virtual.arena_init_growing(&parser_arena) or_return
	defer virtual.arena_destroy(&parser_arena)
	parser_allocator := virtual.arena_allocator(&parser_arena)
	p := json.make_parser(serial, .SJSON, PARSE_INTEGERS, parser_allocator)

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
	prof_scoped_event(fmt.tprint(#procedure, value.id))

	if end_token == .Close_Brace {
		json.expect_token(p, .Open_Brace) or_return
	}

	ti := reflect.type_info_base(type_info_of(value.id))
	#partial switch ti_v in ti.variant {
	case runtime.Type_Info_Struct:
		if .raw_union in ti_v.flags {
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
					return .Multiple_Struct_Fields
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
		raw_map := cast(^runtime.Raw_Map)value.data
		raw_map.allocator = ctx.value_allocator

		map_info := ti_v.map_info
		key_ti := runtime.type_info_base(ti_v.key)
		value_ti := runtime.type_info_base(ti_v.value)

		map_loop: for p.curr_token.kind != end_token {
			key_token := p.curr_token
			key := json.parse_object_key(p, p.allocator) or_return
			defer delete(key, p.allocator)
			
			json.expect_token(p, .Colon) or_return

			// Max size of the supported keys (i128, string16)
			key_buf: [16]byte
			key_ptr := rawptr(&key_buf[0])

			#partial switch v in key_ti.variant {
			case runtime.Type_Info_Integer:
				key_value := any{key_ptr, key_ti.id}
				if !deserialize_parse_int(key_value, key) {
					return .Invalid_Integer_Format
				}

			case runtime.Type_Info_String:
				switch key_ti.id {
				case string:
					s := cast(^string)key_ptr
					s^ = strings.clone(key, ctx.value_allocator) or_return

				case cstring:
					cs := cast(^cstring)key_ptr
					cs^ = strings.clone_to_cstring(key, ctx.value_allocator) or_return

				case string16:
					s16 := cast(^string16)key_ptr
					buf := make([]u16, len(key), ctx.value_allocator)
					utf16.encode_string(buf, key)
					s16^ = string16(buf)
					
				case cstring16:
					cs16 := cast(^cstring16)key_ptr
					buf := make([]u16, len(key)+1, ctx.value_allocator)
					utf16.encode_string(buf, key)
					cs16^ = cstring16(&buf[0])
				}
			}

			if runtime.map_exists_dynamic(raw_map^, map_info, uintptr(key_ptr)) {
				return .Multiple_Map_Fields
			}

			// The value must be deserialized before insertion because the hash is needed to insert
			value_buf := runtime.mem_alloc_bytes(value_ti.size, value_ti.align, ctx.temp_allocator) or_return
			value_ptr := rawptr(&value_buf[0])
			value_value := any{value_ptr, value_ti.id}
			deserialize_value(ctx, p, value_value) or_return

			// Key and value are shallow copied into the map
			runtime.__dynamic_map_set_without_hash(raw_map, map_info, key_ptr, value_ptr)

			json.parse_comma(p)
		}

	case runtime.Type_Info_Enumerated_Array:
		enum_ti := runtime.type_info_base(ti_v.index)
		fields := reflect.enum_fields_zipped(enum_ti.id)

		for p.curr_token.kind != end_token {
			name := json.parse_object_key(p, p.allocator) or_return
			defer delete(name)

			json.parse_colon(p) or_return

			enum_value, ok := reflect.enum_from_name_any(enum_ti.id, name)
			if !ok {
				return .Invalid_Enum_Name
			}

			index := int(enum_value - ti_v.min_value)
			elem_value := reflect.index(value, index)

			deserialize_value(ctx, p, elem_value) or_return

			json.parse_comma(p)
		}

	case runtime.Type_Info_Union:
		t: json.Token

		// Parse TAG identifier
		t = p.curr_token
		json.expect_token(p, .Ident) or_return
		if t.text != "TAG" {
			return .Invalid_Union_Format
		}

		json.parse_colon(p) or_return

		// Parse tag type string
		t = p.curr_token
		json.expect_token(p, .String) or_return
		type_string := t.text[1:len(t.text)-1]
		builder: strings.Builder
		strings.builder_init(&builder, ctx.temp_allocator) or_return
		tag_index := -1
		tag: i64
		for variant, i in ti_v.variants {
			strings.builder_reset(&builder)
			reflect.write_type(&builder, variant)
			if type_string == strings.to_string(builder) {
				tag_index = i
				tag = i64(i if ti_v.no_nil else i+1)
				break
			}
		}
		if tag_index == -1 {
			return .Invalid_Union_Tag
		}

		reflect.set_union_variant_raw_tag(value, tag)

		json.parse_comma(p)

		// Parse VARIANT identifier
		t = p.curr_token
		json.expect_token(p, .Ident)
		if t.text != "VARIANT" {
			return .Invalid_Union_Format
		}

		json.parse_colon(p) or_return

		// Parse variant value
		variant_value := any{value.data, ti_v.variants[tag_index].id}
		deserialize_value(ctx, p, variant_value) or_return

		json.parse_comma(p)

	case runtime.Type_Info_Bit_Field:
		write_bits :: proc(ptr: [^]byte, offset, size: uintptr, value: u64) {
			// write one bit at a time
			for b in 0..<size {
				bit := b + offset
				byte_offset := bit/8
				B := &ptr[byte_offset]
				k := bit%8
				if value & (u64(1)<<u64(b)) != 0 {
					B^ |= u8(1)<<k
				}
			}
		}

		if ti_v.field_count == 0 {
			json.expect_token(p, end_token) or_return
			return .Success
		}

		for p.curr_token.kind != end_token {
			t := p.curr_token
			json.expect_token(p, .Ident) or_return

			json.parse_colon(p) or_return

			found: bool
			for field, i in reflect.bit_fields_zipped(value.id) {
				if field.name != t.text {
					continue
				}

				int_token := p.curr_token
				json.expect_token(p, .Integer) or_return

				int_value: u64
				int_any := any{&int_value, field.type.id}
				if !deserialize_parse_int(int_any, int_token.text) {
					return .Invalid_Integer_Format
				}

				data := cast([^]u8)value.data
				write_bits(data, field.offset, field.size, int_value)

				json.parse_comma(p)
			}
		}
	}

	if end_token == .Close_Brace {
		json.expect_token(p, .Close_Brace) or_return
	}

	return .Success
}

deserialize_value :: proc(ctx: ^Deserialize_Context, p: ^json.Parser, value: any) -> Deserialize_Result {
	prof_scoped_event(fmt.tprint(#procedure, value.id))

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

		if !deserialize_parse_int(value, t.text) {
			return .Invalid_Integer_Format
		}
		return .Success

	case runtime.Type_Info_Float:
		t := json.advance_token(p) or_return

		#partial switch t.kind {
		case .Integer, .Float, .Infinity, .NaN:
			if !deserialize_parse_float(value, t.text) {
				return .Invalid_Float_Format
			}

		case:
			return .Unexpected_Token
		}
		return .Success

	case runtime.Type_Info_Complex:
		// Complex format: [x y] / [real, imag]
		switch &c in value {
		case complex32:
			c_as_vec: [2]f16
			deserialize_value(ctx, p, c_as_vec) or_return
			c = complex(c_as_vec.x, c_as_vec.y)

		case complex64:
			c_as_vec: [2]f32
			deserialize_value(ctx, p, c_as_vec) or_return
			c = complex(c_as_vec.x, c_as_vec.y)

		case complex128:
			c_as_vec: [2]f64
			deserialize_value(ctx, p, c_as_vec) or_return
			c = complex(c_as_vec.x, c_as_vec.y)
		}
		return .Success

	case runtime.Type_Info_Quaternion:
		// Quaternion format: [x y z w] / [imag, jmag, kmag, real]
		switch &q in value {
		case quaternion64:
			q_as_vec: [4]f16
			deserialize_value(ctx, p, q_as_vec) or_return
			q = quaternion(w=q_as_vec.w, x=q_as_vec.x, y=q_as_vec.y, z=q_as_vec.z)

		case quaternion128:
			q_as_vec: [4]f32
			deserialize_value(ctx, p, q_as_vec) or_return
			q = quaternion(w=q_as_vec.w, x=q_as_vec.x, y=q_as_vec.y, z=q_as_vec.z)

		case quaternion256:
			q_as_vec: [4]f64
			deserialize_value(ctx, p, q_as_vec) or_return
			q = quaternion(w=q_as_vec.w, x=q_as_vec.x, y=q_as_vec.y, z=q_as_vec.z)
		}
		return .Success

	case runtime.Type_Info_String:
		t := p.curr_token
		json.expect_token(p, .String) or_return

		switch &v in value {
		case string:
			v = json.unquote_string(t, .SJSON, ctx.value_allocator) or_return

		case cstring:
			// unquote_string always allocates a null byte at the end of the string
			s := json.unquote_string(t, .SJSON, ctx.value_allocator) or_return
			v = cstring(raw_data(s))

		case string16:
			s := json.unquote_string(t, .SJSON, ctx.temp_allocator) or_return
			buf := make([]u16, len(s), ctx.value_allocator)
			n := utf16.encode_string(buf, s)
			v = string16(buf[:n])

		case cstring16:
			s := json.unquote_string(t, .SJSON, ctx.temp_allocator) or_return
			buf := make([]u16, len(s)+1, ctx.value_allocator)
			utf16.encode_string(buf, s)
			v = cstring16(&buf[0])
		}
		return .Success

	case runtime.Type_Info_Boolean:
		t := json.advance_token(p) or_return
		#partial switch t.kind {
		case .True, .False:
			b, ok := strconv.parse_bool(t.text)
			if !ok {
				return .Invalid_Boolean_Format
			}

			switch &v in value {
			case b8:    v =   b8(b)
			case b16:   v =  b16(b)
			case b32:   v =  b32(b)
			case b64:   v =  b64(b)
			case bool:  v = bool(b)
			}
		case:
			return .Unexpected_Token
		}
		return .Success

	case runtime.Type_Info_Type_Id:
		// I don't think it is possible to resolve a string to a typeid...
		// but I'm not sure if it will ever be actually needed.

	case runtime.Type_Info_Array:
		elem := ti_v.elem

		json.expect_token(p, .Open_Bracket) or_return
		for i in 0..<ti_v.count {
			if p.curr_token.kind == .Close_Bracket {
				return .Invalid_Array_Size
			}
			
			elem_ptr := rawptr(uintptr(value.data) + uintptr(i*elem.size))
			elem_value := any{elem_ptr, elem.id}
			deserialize_value(ctx, p, elem_value) or_return

			json.parse_comma(p)
		}
		json.expect_token(p, .Close_Bracket) or_return
		return .Success

	case runtime.Type_Info_Simd_Vector:
		elem := ti_v.elem

		json.expect_token(p, .Open_Bracket) or_return
		assert(ti_v.count > 0)
		for i in 0..<ti_v.count {
			if p.curr_token.kind == .Close_Bracket {
				return .Invalid_Array_Size
			}
			
			elem_ptr := rawptr(uintptr(value.data) + uintptr(i*elem.size))
			elem_value := any{elem_ptr, elem.id}
			deserialize_value(ctx, p, elem_value) or_return

			json.parse_comma(p)
		}
		json.expect_token(p, .Close_Bracket) or_return
		return .Success

	case runtime.Type_Info_Enumerated_Array:
		return deserialize_object(ctx, p, value, .Close_Brace)

	case runtime.Type_Info_Dynamic_Array:
		elem := ti_v.elem

		json.expect_token(p, .Open_Bracket) or_return

		raw_array := cast(^runtime.Raw_Dynamic_Array)value.data
		raw_array.allocator = ctx.value_allocator

		index: int
		for p.curr_token.kind != .Close_Bracket {
			runtime.__dynamic_array_append_nothing(raw_array, elem.size, elem.align)
			elem_ptr := rawptr(uintptr(raw_array.data) + uintptr(index*elem.size))
			elem_value := any{elem_ptr, elem.id}
			deserialize_value(ctx, p, elem_value) or_return

			json.parse_comma(p)

			index += 1
		}
		json.expect_token(p, .Close_Bracket) or_return
		return .Success

	case runtime.Type_Info_Slice:
		elem := ti_v.elem

		json.expect_token(p, .Open_Bracket) or_return
		
		raw_slice := cast(^runtime.Raw_Slice)value.data

		// Temporary array to append the items to
		raw_array: runtime.Raw_Dynamic_Array
		raw_array.allocator = ctx.temp_allocator
		runtime.__dynamic_array_make(&raw_array, elem.size, elem.align, 0, 0)
		defer runtime.mem_free_with_size(raw_array.data, raw_array.cap*elem.size, ctx.temp_allocator)

		// The other way would be to parse in two passes:
		// 1. Check how many elements there are in the slice
		// 2. Allocate the slice and then parse each element

		index: int
		for p.curr_token.kind != .Close_Bracket {
			runtime.__dynamic_array_append_nothing(&raw_array, elem.size, elem.align)
			elem_ptr := rawptr(uintptr(raw_array.data) + uintptr(index*elem.size))
			elem_value := any{elem_ptr, elem.id}
			deserialize_value(ctx, p, elem_value) or_return

			json.parse_comma(p)

			index += 1
		}

		// Clone the temp array to slice
		runtime._make_aligned_type_erased(raw_slice, elem.size, raw_array.len, elem.align, ctx.value_allocator) or_return
		n := runtime.copy_slice_raw(raw_slice.data, raw_array.data, raw_slice.len, raw_array.len, elem.size)
		assert(n == raw_slice.len)
		
		json.expect_token(p, .Close_Bracket) or_return
		return .Success

	case runtime.Type_Info_Struct:
		return deserialize_object(ctx, p, value, .Close_Brace)

	case runtime.Type_Info_Union:
		return deserialize_object(ctx, p, value, .Close_Brace)

	case runtime.Type_Info_Enum:
		t := p.curr_token
		json.expect_token(p, .String) or_return

		s := json.unquote_string(t, .SJSON, ctx.temp_allocator) or_return
		for field in reflect.enum_fields_zipped(ti.id) {
			if field.name == s {
				core_ti := runtime.type_info_core(ti)
				out_enum_value := any{value.data, core_ti.id}
				assign_int_to_any(out_enum_value, field.value)
				return .Success
			}
		}
		return .Invalid_Enum_Name

	case runtime.Type_Info_Map:
		return deserialize_object(ctx, p, value, .Close_Brace)

	case runtime.Type_Info_Bit_Set:
		elem_ti := runtime.type_info_base(ti_v.elem)
		bit_size := uint(8*elem_ti.size)

		// upper is inclusive
		elem_count := ti_v.upper+1 - ti_v.lower
		assert(elem_count > 0)
		assert(uint(elem_count) <= bit_size)

		json.expect_token(p, .Open_Bracket) or_return

		parsed_value: u128
		#partial switch v in elem_ti.variant {
		case runtime.Type_Info_Integer:
			for p.curr_token.kind != .Close_Bracket {
				t := p.curr_token
				json.expect_token(p, .Integer) or_return

				int_value: i64
				int_any := any{&int_value, elem_ti.id}
				if !deserialize_parse_int(int_any, t.text) {
					return .Invalid_Integer_Format
				}

				bit_n := u64(int_value - ti_v.lower)
				assert(bit_n < 128)
				bit := u128(1)<<bit_n
				parsed_value |= bit
				
				json.parse_comma(p)
			}

		case runtime.Type_Info_Rune:
			for p.curr_token.kind != .Close_Bracket {
				t := p.curr_token
				json.expect_token(p, .String) or_return

				s := json.unquote_string(t, .SJSON, ctx.temp_allocator) or_return
				r, n := utf8.decode_rune(s)
				if n != len(s) {
					return .Invalid_Rune_Format
				}

				bit_n := u64(i64(r) - ti_v.lower)
				assert(bit_n < 128)
				bit := u128(1)<<bit_n
				parsed_value |= bit

				json.parse_comma(p)
			}

		case runtime.Type_Info_Enum:
			if len(v.values) == 0 {
				json.expect_token(p, .Close_Bracket) or_return
				return .Success
			}

			for p.curr_token.kind != .Close_Bracket {
				t := p.curr_token
				json.expect_token(p, .String) or_return
				
				s := json.unquote_string(t, .SJSON, ctx.temp_allocator) or_return
				enum_value, ok := reflect.enum_from_name_any(elem_ti.id, s)
				if !ok {
					return .Invalid_Enum_Name
				}

				bit_n := u64(i64(enum_value) - ti_v.lower)
				assert(bit_n < 128)
				bit := u128(1)<<bit_n
				parsed_value |= bit

				json.parse_comma(p)
			}

		case: panic("Invalid bit set element type.")
		}

		switch bit_size {
		case 0:
			json.expect_token(p, .Close_Bracket) or_return
			return .Success

		case 8:
			ptr := cast(^u8)value.data
			ptr^ = u8(parsed_value)

		case 16:
			ptr := cast(^u16)value.data
			ptr^ = u16(parsed_value)

		case 32:
			ptr := cast(^u32)value.data
			ptr^ = u32(parsed_value)

		case 64:
			ptr := cast(^u64)value.data
			ptr^ = u64(parsed_value)

		case 128:
			ptr := cast(^u128)value.data
			ptr^ = u128(parsed_value)

		case: panic("Invalid bit set size.")
		}

		json.expect_token(p, .Close_Bracket) or_return
		return .Success

	case runtime.Type_Info_Matrix:
		elem_ti := ti_v.elem

		json.expect_token(p, .Open_Bracket) or_return

		#partial switch v in elem_ti.variant {
		case runtime.Type_Info_Integer:
			for row in 0..<ti_v.row_count {
				for col in 0..<ti_v.column_count {
					offset: int
					switch ti_v.layout {
					case .Column_Major: offset = (row + col*ti_v.elem_stride)*ti_v.elem_size
					case .Row_Major:    offset = (col + row*ti_v.elem_stride)*ti_v.elem_size
					}

					t := p.curr_token
					json.expect_token(p, .Integer) or_return

					data := uintptr(value.data) + uintptr(offset)
					int_value := any{rawptr(data), ti_v.elem.id}
					if !deserialize_parse_int(int_value, t.text) {
						return .Invalid_Integer_Format
					}

					json.parse_comma(p)
				}
			}

		case runtime.Type_Info_Float:
			for row in 0..<ti_v.row_count {
				for col in 0..<ti_v.column_count {
					offset: int
					switch ti_v.layout {
					case .Column_Major: offset = (row + col*ti_v.elem_stride)*ti_v.elem_size
					case .Row_Major:    offset = (col + row*ti_v.elem_stride)*ti_v.elem_size
					}

					t := json.advance_token(p) or_return

					#partial switch t.kind {
					case .Integer, .Float, .Infinity, .NaN:
						data := uintptr(value.data) + uintptr(offset)
						float_value := any{rawptr(data), ti_v.elem.id}
						if !deserialize_parse_float(float_value, t.text) {
							return .Invalid_Float_Format
						}

					case: return .Unexpected_Token
					}

					json.parse_comma(p)
				}
			}

		case: panic("Invalid matrix elem type.")
		}

		json.expect_token(p, .Close_Bracket) or_return
		return .Success

	case runtime.Type_Info_Bit_Field:
		return deserialize_object(ctx, p, value, .Close_Brace)
	}

	// Fallback for ignored types
	allocator := p.allocator
	defer p.allocator = allocator
	p.allocator = mem.nil_allocator()
	json.parse_value(p) or_return

	return .Success
}

deserialize_parse_int :: proc(value: any, s: string) -> (ok: bool) {
	ti := runtime.type_info_base(type_info_of(value.id)).variant.(runtime.Type_Info_Integer)
	if ti.signed {
		if parsed_i128, ok := strconv.parse_i128_maybe_prefixed(s); ok {
			assign_int_to_any(value, parsed_i128)
			return true
		}
	} else {
		if parsed_u128, ok := strconv.parse_u128_maybe_prefixed(s); ok {
			assign_int_to_any(value, parsed_u128)
			return true
		}
	}
	return false
}

deserialize_parse_float :: proc(value: any, s: string) -> (ok: bool) {
	parsed_f64, pok := strconv.parse_f64(s)
	if !pok {
		return false
	}

	assign_float_to_any(value, parsed_f64)
	return true
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

	case i16le:   u = u128(i)
	case i32le:   u = u128(i)
	case i64le:   u = u128(i)
	case i128le:  u = u128(i)
	case u16le:   u = u128(i)
	case u32le:   u = u128(i)
	case u64le:   u = u128(i)
	case u128le:  u = u128(i)

	case i16be:   u = u128(i)
	case i32be:   u = u128(i)
	case i64be:   u = u128(i)
	case i128be:  u = u128(i)
	case u16be:   u = u128(i)
	case u32be:   u = u128(i)
	case u64be:   u = u128(i)
	case u128be:  u = u128(i)
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

assign_int_to_any :: proc(value: any, i: $T) -> (ok: bool) {
	switch &v in value {
	case int:      v =     int(i)
	case i8:       v =      i8(i)
	case i16:      v =     i16(i)
	case i32:      v =     i32(i)
	case i64:      v =     i64(i)
	case i128:     v =    i128(i)

	case uint:     v =    uint(i)
	case u8:       v =      u8(i)
	case u16:      v =     u16(i)
	case u32:      v =     u32(i)
	case u64:      v =     u64(i)
	case u128:     v =    u128(i)

	case uintptr:  v = uintptr(i)

	case i16le:    v =   i16le(i)
	case i32le:    v =   i32le(i)
	case i64le:    v =   i64le(i)
	case i128le:   v =  i128le(i)
	case u16le:    v =   u16le(i)
	case u32le:    v =   u32le(i)
	case u64le:    v =   u64le(i)
	case u128le:   v =  u128le(i)

	case i16be:    v =   i16be(i)
	case i32be:    v =   i32be(i)
	case i64be:    v =   i64be(i)
	case i128be:   v =  i128be(i)
	case u16be:    v =   u16be(i)
	case u32be:    v =   u32be(i)
	case u64be:    v =   u64be(i)
	case u128be:   v =  u128be(i)

	case: return false
	}
	return true
}

assign_float_to_any :: proc(value: any, i: $T) -> (ok: bool) {
	switch &v in value {
	case f16:    v =   f16(i)
	case f16le:  v = f16le(i)
	case f16be:  v = f16be(i)

	case f32:    v =   f32(i)
	case f32le:  v = f32le(i)
	case f32be:  v = f32be(i)

	case f64:    v =   f64(i)
	case f64le:  v = f64le(i)
	case f64be:  v = f64be(i)

	case: return false
	}
	return true
}
