package sm_renderer_3d

import "core:log"
import "core:mem"
import "core:reflect"
import "core:strings"
import "vendor:cgltf"

import "sm:core"

GLTF_Err_Data :: cgltf.result
GLTF_Result   :: #type core.Result(GLTF_Err_Data)
GLTF_Error    :: #type core.Error(GLTF_Err_Data)

GLTF_Primitive :: struct($V: typeid) {
	name: string,
	vertices: []V,
	indices: []u32,
}

GLTF_Mesh :: struct($V: typeid) {
	primitives: [dynamic]GLTF_Primitive(V),
}

GLTF_Import_Config :: struct {
	// GLTF attribute type to offset in vertex struct mapping
	attribute_mapping: [cgltf.attribute_type]int,
}
gltf_make_default_config :: proc() -> (config: GLTF_Import_Config) {
	for &attr in config.attribute_mapping {
		attr = -1
	}
	return
}
gltf_make_config_from_vertex :: proc($V: typeid) -> (config: GLTF_Import_Config) {
	config = gltf_make_default_config()
	vertex_type_info := type_info_of(V)
	fields := reflect.struct_fields_zipped(V)
	for f in fields {
		gltf_attr := reflect.struct_tag_get(f.tag, "gltf")
		if gltf_attr_type, ok := reflect.enum_from_name(cgltf.attribute_type, gltf_attr); ok {
			config.attribute_mapping[gltf_attr_type] = cast(int)f.offset
		}
	}
	return
}

import_mesh_gltf :: proc(path: string, $V: typeid, config: GLTF_Import_Config, allocator := context.allocator) -> (gltf_mesh: GLTF_Mesh(V), result: GLTF_Result) {
	r: cgltf.result

	data: ^cgltf.data
	defer if data != nil do cgltf.free(data)

	options: cgltf.options
	c_path := strings.clone_to_cstring(path, context.temp_allocator)
	if data, r = cgltf.parse_file(options, c_path); r != .success {
		result = core.error_make_as(GLTF_Error, r, "Could not parse the glTF file '%s'.", path)
		return
	}

	if r = cgltf.load_buffers(options, data, c_path); r !=.success {
		result = core.error_make_as(GLTF_Error, r, "Could not load buffers from the glTF file '%s'.", path)
		return
	}

	when ODIN_DEBUG {
		if r = cgltf.validate(data); r != .success {
			result = core.error_make_as(GLTF_Error, r, "Could not validate the data from the glTF file '%s'.", path)
			return
		}
	}

	if len(data.meshes) != 1 {
		result = core.error_make_as(GLTF_Error, cgltf.result.success, "Only one mesh per glTF file is supported '%s'.", path)
		return
	}

	mesh := &data.meshes[0]
	if len(mesh.primitives) < 1 {
		result = core.error_make_as(GLTF_Error, cgltf.result.success, "No primitives found in glTF mesh '%s'.", path)
		return
	}

	gltf_mesh.primitives = make([dynamic]GLTF_Primitive(V), allocator)
	for &primitive in mesh.primitives {
		index_count := primitive.indices.count
		if index_count < 1 {
			return
		}

		append(&gltf_mesh.primitives, GLTF_Primitive(V){})
		gltf_primitive := &gltf_mesh.primitives[len(gltf_mesh.primitives)-1]

		if primitive.material != nil && primitive.material.name != nil && len(primitive.material.name) > 0 {
			gltf_primitive.name = strings.clone_from_cstring(primitive.material.name, allocator)
		}

		gltf_primitive.indices = make([]u32, index_count, allocator)
		invert_winding := true
		assert(!invert_winding || index_count % 3 == 0)
		for i in 0..<int(index_count) {
			v_in_tri := i % 3
			v_offset := v_in_tri if v_in_tri < 2 else -1
			gltf_primitive.indices[i+v_offset] = cast(u32)cgltf.accessor_read_index(primitive.indices, cast(uint)i)
		}

		cond_init_vertex_buffer :: proc(buffer: ^[]V, count: uint, allocator := context.allocator) {
			assert(buffer != nil)
			if buffer^ != nil {
				return
			}

			buffer^ = make([]V, count, allocator)
		}
	
		for attribute in primitive.attributes {
			num_components := cgltf.num_components(attribute.data.type)
			attribute_offset := config.attribute_mapping[attribute.type]
			// Attribute is unsupported by the vertex type
			if attribute_offset == -1 {
				continue
			}

			vertex_count := attribute.data.count
			cond_init_vertex_buffer(&gltf_primitive.vertices, vertex_count, allocator)
			for i in 0..<vertex_count {
				vertex := &gltf_primitive.vertices[i]
				vertex_bytes := mem.ptr_to_bytes(vertex)
				attribute_ptr := &vertex_bytes[attribute_offset]
				if !cgltf.accessor_read_float(attribute.data, i, transmute(^f32)attribute_ptr, num_components) {
					log.warn("Failed to read attribute", attribute.type, "of vertex", i, "from primitive.")
				}
			}
		}
	}

	return
}

destroy_gltf_mesh :: proc(gltf_mesh: ^GLTF_Mesh, allocator := context.allocator) {
	assert(gltf_mesh != nil)
	for &p in gltf_mesh.primitives {
		if p.vertices != nil {
			delete(p.vertices, allocator)
			p.vertices = nil
		}
		if p.indices != nil {
			delete(p.indices, allocator)
			p.indices = nil
		}
	}
	delete(gltf_mesh.primitives)
}
