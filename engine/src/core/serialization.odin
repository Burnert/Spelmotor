package core

import "base:runtime"
import "core:encoding/json"
import "core:io"
import "core:log"
import "core:reflect"
import "core:strconv"
import "core:strings"

SERIALIZE_TYPE_NOT_IMPLEMENTED_MESSAGE :: "Type not implemented"
SERIALIZE_STRUCT_TAG :: "s"
SERIALIZE_STRUCT_TAG_COMPACT :: "compact"

Serialize_Context :: struct {
	indent: int,
}

Serialize_Flags :: distinct bit_set[Serialize_Flag]
Serialize_Flag :: enum {
	Compact,
}

Serialize_Error :: enum {
	Success = 0,
	Unsupported_Type,
	Unknown_Fail,
}

Serialize_Result :: union #shared_nil {
	Serialize_Error,
	io.Error,
}

serialize_init :: proc(using ctx: ^Serialize_Context) {
	indent = 0
}

serialize_type :: proc{
	serialize_type_generic,
	serialize_type_dynamic,
}

serialize_type_generic :: proc(ctx: ^Serialize_Context, w: io.Writer, data: $T, flags: Serialize_Flags) -> Serialize_Result {
	return serialize_type_dynamic(ctx, w, data, flags)
}

serialize_type_dynamic :: proc(ctx: ^Serialize_Context, w: io.Writer, data: any, flags: Serialize_Flags) -> Serialize_Result {
	assert(ctx != nil)
	assert(data != nil)

	ti := type_info_of(data.id)
	type_name: string
	if named, ok := ti.variant.(runtime.Type_Info_Named); ok {
		type_name = named.name
		ti = reflect.type_info_base(ti)
	}
	a := any{data.data, ti.id}

	switch info in ti.variant {
	case runtime.Type_Info_Named:
		unreachable()

	case runtime.Type_Info_Integer:
		buf: [40]byte
		u := cast_any_int_to_u128(a)

		s := strconv.write_bits_128(buf[:], u, 10, info.signed, 8*ti.size, "0123456789", nil)
		io.write_string(w, s) or_return

	case runtime.Type_Info_Rune:
		r := a.(rune)
		io.write_byte(w, '"')            or_return
		io.write_escaped_rune(w, r, '"') or_return
		io.write_byte(w, '"')            or_return

	case runtime.Type_Info_Float:
		switch f in a {
		case f16: io.write_f16(w, f) or_return
		case f32: io.write_f32(w, f) or_return
		case f64: io.write_f64(w, f) or_return
		case:
			log.error("Serialize unsupported type. (%s)", type_name)
			return .Unsupported_Type
		}

	case runtime.Type_Info_Complex:
		unimplemented(SERIALIZE_TYPE_NOT_IMPLEMENTED_MESSAGE)

	case runtime.Type_Info_Quaternion:
		unimplemented(SERIALIZE_TYPE_NOT_IMPLEMENTED_MESSAGE)

	case runtime.Type_Info_String:
		switch s in a {
		case string:  io.write_quoted_string(w, s, '"', nil, true)         or_return
		case cstring: io.write_quoted_string(w, string(s), '"', nil, true) or_return
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
		unimplemented(SERIALIZE_TYPE_NOT_IMPLEMENTED_MESSAGE)

	case runtime.Type_Info_Type_Id:
		unimplemented(SERIALIZE_TYPE_NOT_IMPLEMENTED_MESSAGE)

	case runtime.Type_Info_Pointer:
		unimplemented(SERIALIZE_TYPE_NOT_IMPLEMENTED_MESSAGE)

	case runtime.Type_Info_Multi_Pointer:
		unimplemented(SERIALIZE_TYPE_NOT_IMPLEMENTED_MESSAGE)

	case runtime.Type_Info_Procedure:
		unimplemented(SERIALIZE_TYPE_NOT_IMPLEMENTED_MESSAGE)

	case runtime.Type_Info_Array:
		is_compact := .Compact in flags
		serialize_write_start(ctx, w, '[', is_compact) or_return
		for i in 0..<info.count {
			if is_compact {
				if i > 0 {
					io.write_byte(w, ' ') or_return
				}
			} else {
				serialize_write_indent(ctx, w)
			}
			data := uintptr(a.data) + uintptr(i*info.elem_size)
			array_elem := any{rawptr(data), info.elem.id}
			// if a type is to be serialized with the compact flag, all inner types should also be compact
			serialize_type_dynamic(ctx, w, array_elem, flags) or_return
			if !is_compact {
				io.write_byte(w, '\n') or_return
			}
		}
		serialize_write_end(ctx, w, ']', is_compact) or_return

	case runtime.Type_Info_Enumerated_Array:
		unimplemented(SERIALIZE_TYPE_NOT_IMPLEMENTED_MESSAGE)

	case runtime.Type_Info_Dynamic_Array:
		is_compact := .Compact in flags
		serialize_write_start(ctx, w, '[', is_compact) or_return
		array := cast(^runtime.Raw_Dynamic_Array)a.data
		for i in 0..<array.len {
			if is_compact {
				if i > 0 {
					io.write_byte(w, ' ') or_return
				}
			} else {
				serialize_write_indent(ctx, w)
			}
			data := uintptr(array.data) + uintptr(i*info.elem_size)
			array_elem := any{rawptr(data), info.elem.id}
			serialize_type_dynamic(ctx, w, array_elem, flags) or_return
			if !is_compact {
				io.write_byte(w, '\n') or_return
			}
		}
		serialize_write_end(ctx, w, ']', is_compact) or_return

	case runtime.Type_Info_Slice:
		is_compact := .Compact in flags
		serialize_write_start(ctx, w, '[', is_compact) or_return
		raw_slice := cast(^runtime.Raw_Slice)a.data
		for i in 0..<raw_slice.len {
			if is_compact {
				if i > 0 {
					io.write_byte(w, ' ') or_return
				}
			} else {
				serialize_write_indent(ctx, w)
			}
			data := uintptr(raw_slice.data) + uintptr(i*info.elem_size)
			slice_elem := any{rawptr(data), info.elem.id}
			serialize_type_dynamic(ctx, w, slice_elem, flags) or_return
			if !is_compact {
				io.write_byte(w, '\n') or_return
			}
		}
		serialize_write_end(ctx, w, ']', is_compact) or_return

	case runtime.Type_Info_Parameters:
		unimplemented(SERIALIZE_TYPE_NOT_IMPLEMENTED_MESSAGE)

	case runtime.Type_Info_Struct:
		serialize_struct_fields :: proc(ctx: ^Serialize_Context, w: io.Writer, data: any, flags: Serialize_Flags) -> Serialize_Result {
			struct_ti := reflect.type_info_base(type_info_of(data.id))
			info := struct_ti.variant.(runtime.Type_Info_Struct)
			for field_name, i in info.names[:info.field_count] {
				field_ti := info.types[i]
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

				// Serialize 'using _: T' fields directly into the parent struct
				if info.usings[i] && field_name == "_" {
					serialize_struct_fields(ctx, w, field_any, flags) or_return
					continue
				}

				is_struct_compact := .Compact in flags
				if is_struct_compact {
					if i > 0 {
						io.write_byte(w, ' ') or_return
					}
				} else {
					serialize_write_indent(ctx, w)
				}

				// Write field name as key
				io.write_string(w, field_name) or_return

				if is_struct_compact {
					io.write_byte(w, '=') or_return
					// if a struct is to be serialized with the compact flag, all inner types should also be compact
					field_flags := flags + {.Compact}
					serialize_type_dynamic(ctx, w, field_any, field_flags) or_return
				} else {
					io.write_string(w, " = ") or_return
					// here if the field is marked as compact, the flag should be propagated into all children
					field_flags := flags + {.Compact} if is_field_compact else flags
					serialize_type_dynamic(ctx, w, field_any, field_flags) or_return
					io.write_byte(w, '\n') or_return
				}
			}
			return .Success
		}

		is_compact := .Compact in flags
		serialize_write_start(ctx, w, '{', is_compact) or_return
		serialize_struct_fields(ctx, w, data, flags) or_return
		serialize_write_end(ctx, w, '}', is_compact) or_return

	case runtime.Type_Info_Union:
		unimplemented(SERIALIZE_TYPE_NOT_IMPLEMENTED_MESSAGE)

	case runtime.Type_Info_Enum:
		unimplemented(SERIALIZE_TYPE_NOT_IMPLEMENTED_MESSAGE)

	case runtime.Type_Info_Map:
		unimplemented(SERIALIZE_TYPE_NOT_IMPLEMENTED_MESSAGE)

	case runtime.Type_Info_Bit_Set:
		unimplemented(SERIALIZE_TYPE_NOT_IMPLEMENTED_MESSAGE)

	case runtime.Type_Info_Simd_Vector:
		unimplemented(SERIALIZE_TYPE_NOT_IMPLEMENTED_MESSAGE)

	case runtime.Type_Info_Matrix:
		unimplemented(SERIALIZE_TYPE_NOT_IMPLEMENTED_MESSAGE)

	case runtime.Type_Info_Soa_Pointer:
		unimplemented(SERIALIZE_TYPE_NOT_IMPLEMENTED_MESSAGE)

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
	io.write_byte(w, c) or_return
	if !compact {
		io.write_byte(w, '\n') or_return
		ctx.indent += 1
	}
	return .Success
}

serialize_write_end :: proc(ctx: ^Serialize_Context, w: io.Writer, c: byte, compact: bool) -> Serialize_Result {
	if !compact {
		ctx.indent -= 1
		serialize_write_indent(ctx, w) or_return
	}
	io.write_byte(w, c) or_return
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
