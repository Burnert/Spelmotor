package spelmotor_sandbox

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:image/png"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/fixed"
import "core:mem"
import "core:prof/spall"
import "core:slice"
import "core:strings"
import "core:time"
import "vendor:cgltf"
import mu "vendor:microui"
import "core:io"
import "core:encoding/json"

import "sm:core"
import "sm:csg"
import "sm:game"
import "sm:platform"
import "sm:rhi"
import r2im "sm:renderer/2d_immediate"
import R "sm:renderer"

serialization_test :: proc() {
	serialize_string_builder: strings.Builder
	strings.builder_init(&serialize_string_builder)
	defer strings.builder_destroy(&serialize_string_builder)
	serialize_writer := strings.to_writer(&serialize_string_builder)
	serialize_context := core.Serialize_Context{}

	Serialize_Type :: struct {}
	Serialize_Empty_Enum :: enum {}
	Serialize_Data_Enum :: enum {
		Index_0,
		Index_1,
	}
	Serialize_Data_Inner_Named_Struct :: struct {
		field: int,
	}
	Serialize_Data_Inner_Using :: struct {
		using_field: int,
	}
	Serialize_Data_Array_Struct :: struct {
		field: uint,
	}
	Serialize_Data_Union :: union {
		int,
		Serialize_Data_Enum,
		Serialize_Data_Inner_Named_Struct,
	}
	Serialize_Data_Test :: struct {
		boolean: bool,
		integer: int,
		float: f32,
		character: rune,
		text: string,
		enum_value: Serialize_Data_Enum,
		int_array: [5]int        `s:"compact"`,
		empty_array: [0]int,
		simd_array: #simd[4]f32  `s:"compact"`,
		int_slice: []int         `s:"compact"`,
		empty_int_slice: []int,
		dyn_array: [dynamic]string,
		empty_dyn_array: [dynamic]int,
		enum_array: [Serialize_Data_Enum]int,
		compact_enum_array: [Serialize_Data_Enum]int  `s:"compact"`,
		empty_enum_array: [Serialize_Empty_Enum]int,
		int_str_map: map[int]string,
		empty_map: map[int]int,
		named_struct: Serialize_Data_Inner_Named_Struct,
		empty_struct: struct {},
		using _: Serialize_Data_Inner_Using,
		inner_struct: struct {
			using _: Serialize_Data_Inner_Using,
			inner_i8: i8,
			inner_u16: u16,
			inner_i128: i128,
		},
		compact_struct: struct {
			x, y: f64,
			non_compact_struct: struct {
				non_compact_field: int,
				non_compact_string: string,
			},
		}                        `s:"compact"`,
		struct_in_array: [3]Serialize_Data_Array_Struct,
		struct_in_compact_array: [3]Serialize_Data_Array_Struct  `s:"compact"`,
		unsupported_type: proc(),
		types: []typeid,
		union_field_int: Serialize_Data_Union  `s:"compact"`,
		union_field_struct: Serialize_Data_Union,
		quat: quaternion256,
		complex: complex64,
		mat4: #row_major matrix[4,4]f32,
		mat4_compact: #row_major matrix[4,4]f32  `s:"compact"`,
		mat2x4: matrix[2,4]i32,
		int_bitset: bit_set[0..<16]  `s:"compact"`,
		char_bitset: bit_set['a'..='z'],
		enum_bitset: bit_set[Serialize_Data_Enum],
		bitfield: bit_field u32 {
			field_10b: u32 | 10,
			field_22b: u32 | 22,
		},
		bitfield_array: bit_field [3]u16 {
			field_20b: u32 | 20,
			field_16b: u16 | 16,
			field_12b: i16 | 12,
		},
	}
	serialize_data := Serialize_Data_Test{
		boolean = true,
		integer = 5040,
		float = 50.75,
		character = 'F',
		text = "Serialization test string!",
		enum_value = .Index_1,
		int_array = {1, 10, 55, 2903, 10001},
		simd_array = {5, 5, 2000.12308, 1103.21232},
		int_slice = {4, 39, 222, 12032, 121111},
		dyn_array = make([dynamic]string, context.temp_allocator),
		enum_array = {.Index_0 = 5, .Index_1 = 10},
		compact_enum_array = {.Index_0 = 2, .Index_1 = 9},
		int_str_map = make(map[int]string, context.temp_allocator),
		named_struct = {
			field = 1232322,
		},
		using_field = 611023,
		inner_struct = {
			using_field = 1232323,
			inner_i8 = 24,
			inner_u16 = 22201,
			inner_i128 = 4834203029042809084748938332321409,
		},
		compact_struct = {
			x = 40.125, y = 1000.123456,
			non_compact_struct = {
				non_compact_field = 601230,
				non_compact_string = "non-compact struct inside compact struct",
			},
		},
		struct_in_array = {
			Serialize_Data_Array_Struct{field = 1000001},
			Serialize_Data_Array_Struct{field = 2000001},
			Serialize_Data_Array_Struct{field = 3000001},
		},
		struct_in_compact_array = {
			Serialize_Data_Array_Struct{field = 123},
			Serialize_Data_Array_Struct{field = 456},
			Serialize_Data_Array_Struct{field = 789},
		},
		unsupported_type = proc() {},
		types = {Serialize_Type, [1]int, f32be, map[string]Serialize_Data_Array_Struct},
		union_field_int = 10009,
		union_field_struct = Serialize_Data_Inner_Named_Struct{field = 500},
		quat = linalg.quaternion_angle_axis(math.TAU, linalg.array_cast(VEC3_UP, f64)),
		complex = complex(12, 5),
		mat4 = {
			1,0,0,4.2,
			0,1,0,4.5,
			0,0,1,4.8,
			0,0,0,1,
		},
		mat4_compact = {
			1,0,0,2.66,
			0,2,0,1.23,
			0,0,1,1.12,
			0,0,0,1,
		},
		mat2x4 = {
			1, 4, 0, 4,
			0, 1, 0, 1,
		},
		int_bitset = {0, 1, 4, 6, 10, 15},
		char_bitset = {'a', 'c', 'f', 'm', 'u', 'x', 'z'},
		enum_bitset = {.Index_0, .Index_1},
		bitfield = {
			field_10b = 1000,
			field_22b = 1250241,
		},
		bitfield_array = {
			field_20b = 1039291,
			field_16b = 12302,
			field_12b = -2041,
		},
	}
	append(&serialize_data.dyn_array, "First String")
	append(&serialize_data.dyn_array, "Second String")
	append(&serialize_data.dyn_array, "last string that's a bit longer...")
	serialize_data.int_str_map[60] = "Sixty"
	serialize_data.int_str_map[100] = "One hundred"

	serialize_result := core.serialize_type(&serialize_context, serialize_writer, serialize_data, {.Allow_Unsupported_Types})
	if serialize_result == nil {
		log.infof("Serialization test successful.\n%s", string(serialize_string_builder.buf[:]))
	} else {
		log.errorf("Serialization test failed. (%s)", serialize_result)
	}

	// json_data, err := json.marshal(serialize_data, {pretty=true, mjson_keys_use_equal_sign=true, spec=.MJSON})
	// log.infof("JSON test successful.\n%s", string(json_data))
}
