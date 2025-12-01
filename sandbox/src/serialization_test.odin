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

	Serialize_Data_Inner_Using :: struct {
		inner_field: int,
	}
	Serialize_Data_Array_Struct :: struct {
		field: uint,
	}
	Serialize_Data_Test :: struct {
		boolean: bool,
		integer: int,
		float: f32,
		character: rune,
		text: string,
		int_array: [5]int        `s:"compact"`,
		int_slice: []int         `s:"compact"`,
		dyn_array: [dynamic]string,
		using _: Serialize_Data_Inner_Using,
		inner_struct: struct {
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
	}
	serialize_data := Serialize_Data_Test{
		boolean = true,
		integer = 5040,
		float = 50.75,
		character = 'F',
		text = "Serialization test string!",
		int_array = {1, 10, 55, 2903, 10001},
		int_slice = {4, 39, 222, 12032, 121111},
		dyn_array = make([dynamic]string, context.temp_allocator),
		inner_field = 611023,
		inner_struct = {
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
	}
	append(&serialize_data.dyn_array, "First String")
	append(&serialize_data.dyn_array, "Second String")
	append(&serialize_data.dyn_array, "last string that's a bit longer...")

	serialize_result := core.serialize_type(&serialize_context, serialize_writer, serialize_data, {.Allow_Unsupported_Types})
	if serialize_result == nil {
		log.infof("Serialization test successful.\n%s", string(serialize_string_builder.buf[:]))
	} else {
		log.errorf("Serialization test failed. (%s)", serialize_result)
	}
}
