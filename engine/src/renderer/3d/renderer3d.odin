package sm_renderer_3d

import "core:fmt"
import "core:image/png"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:reflect"
import "core:slice"
import "core:strings"

import "sm:core"
import "sm:platform"
import "sm:rhi"

// TODO: Remove when ready
import vk "vendor:vulkan"

Error :: struct {
	message: string, // temp string
}
Result :: union { Error, rhi.RHI_Error }

QUAD_SHADER_VERT :: "3d/quad_vert.spv"
QUAD_SHADER_FRAG :: "3d/quad_frag.spv"

MESH_SHADER_VERT :: "3d/basic_vert.spv"
MESH_SHADER_FRAG :: "3d/basic_frag.spv"

INSTANCED_MESH_SHADER_VERT :: "3d/basic_instanced_vert.spv"
INSTANCED_MESH_SHADER_FRAG :: "3d/basic_instanced_frag.spv"

TERRAIN_SHADER_VERT :: "3d/terrain_vert.spv"
TERRAIN_SHADER_FRAG :: "3d/terrain_frag.spv"
TERRAIN_DEBUG_SHADER_FRAG :: "3d/terrain_dbg_frag.spv"

MAX_SAMPLERS :: 100
MAX_SCENES :: 1
MAX_SCENE_VIEWS :: 10
MAX_MODELS :: 1000
MAX_LIGHTS :: 1000
MAX_MATERIALS :: 1000
MAX_TERRAINS :: 1

GLOBAL_SCENE_DS_IDX :: 0
GLOBAL_SCENE_VIEW_DS_IDX :: 1
MESH_RENDERING_MODEL_DS_IDX :: 2
MESH_RENDERING_MATERIAL_DS_IDX :: 3

INSTANCED_MESH_RENDERING_MATERIAL_DS_IDX :: 2

TERRAIN_RENDERING_TERRAIN_DS_IDX :: 2
TERRAIN_RENDERING_MATERIAL_DS_IDX :: 3

// COMMON -----------------------------------------------------------------------------------------------------

// Keep in sync with the constants in shaders
Lighting_Model :: enum u32 {
	Default,
	Two_Sided_Foliage,
}

// SCENE ----------------------------------------------------------------------------------------------------

Light_Uniforms :: struct #align(16) {
	// Passing as vec4s for the alignment compatibility with SPIR-V layout
	location: Vec4,
	direction: Vec4,
	color: Vec3,
	attenuation_radius: f32,
	spot_cone_angle_cos: f32,
	spot_cone_falloff: f32,
}

Scene_Uniforms :: struct {
	ambient_light: Vec4,
	lights: [MAX_LIGHTS]Light_Uniforms,
	light_num: u32,
}

Light_Info :: struct {
	location: Vec3,
	direction: Vec3, // Not used for point lights
	color: Vec3,
	intensity: f32, // Intensity at 1m distance from the light
	attenuation_radius: f32,
	spot_cone_angle: f32, // (in radians); 0 for point light
	spot_cone_falloff: f32, // Normalized falloff (0-none, 1-max); not used for point lights
}

RScene :: struct {
	lights: [dynamic]Light_Info,
	ambient_light: Vec3,

	uniforms: [MAX_FRAMES_IN_FLIGHT]rhi.Uniform_Buffer,
	descriptor_sets: [MAX_FRAMES_IN_FLIGHT]RHI_DescriptorSet,
}

create_scene :: proc() -> (scene: RScene, result: RHI_Result) {
	// Create scene uniform buffers
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		scene.uniforms[i] = rhi.create_uniform_buffer(Scene_Uniforms) or_return
		
		// Create buffer descriptors
		scene_set_desc := rhi.Descriptor_Set_Desc{
			layout = g_r3d_state.scene_descriptor_set_layout,
			descriptors = {
				rhi.Descriptor_Desc{
					type = .UNIFORM_BUFFER,
					binding = 0,
					count = 1,
					info = rhi.Descriptor_Buffer_Info{
						buffer = &scene.uniforms[i].buffer,
						size = size_of(Scene_Uniforms),
						offset = 0,
					},
				},
			},
		}
		scene.descriptor_sets[i] = rhi.create_descriptor_set(g_r3d_state.descriptor_pool, scene_set_desc) or_return
	}

	return
}

destroy_scene :: proc(scene: ^RScene) {
	if scene == nil {
		return
	}

	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		rhi.destroy_buffer(&scene.uniforms[i])
		scene.uniforms[i] = {}
		// TODO: Maybe Release back unused descriptor sets to the pool
		scene.descriptor_sets[i] = 0
	}

	delete(scene.lights)
}

update_scene_uniforms :: proc(scene: ^RScene) {
	assert(scene != nil)
	frame_in_flight := rhi.get_frame_in_flight()
	ub := &scene.uniforms[frame_in_flight]
	uniforms := rhi.cast_mapped_buffer_memory_single(Scene_Uniforms, ub.mapped_memory)
	slice.zero(uniforms.lights[:])

	uniforms.ambient_light.rgb = scene.ambient_light
	for l, i in scene.lights {
		u_light := &uniforms.lights[i]
		u_light.location = vec4(l.location, 1)
		u_light.direction = vec4(l.direction, 0)
		u_light.color = l.color * l.intensity
		u_light.attenuation_radius = l.attenuation_radius
		u_light.spot_cone_angle_cos = math.cos(l.spot_cone_angle)
		u_light.spot_cone_falloff = l.spot_cone_falloff
	}
	uniforms.light_num = cast(u32)len(scene.lights)
}

bind_scene :: proc(cb: ^RHI_CommandBuffer, scene: ^RScene, layout: RHI_PipelineLayout) {
	assert(cb != nil)
	assert(scene != nil)

	frame_in_flight := rhi.get_frame_in_flight()
	scene_ds := &scene.descriptor_sets[frame_in_flight]
	
	rhi.cmd_bind_descriptor_set(cb, layout, scene_ds^, GLOBAL_SCENE_DS_IDX)
}

// Infinite reversed-Z perspective
Perspective_Projection_Info :: struct {
	vertical_fov: f32, // in radians
	aspect_ratio: f32, // X/Y
	near_clip_plane: f32,
}

Orthographic_Projection_Info :: struct {
	view_extents: Vec2,
	far_clip_plane: f32,
}

Projection_Info :: union #no_nil{Perspective_Projection_Info, Orthographic_Projection_Info}

View_Info :: struct {
	origin: Vec3,
	angles: Vec3, // in radians
	projection: Projection_Info,
}

calculate_projection_matrix :: proc(projection_info: Projection_Info) -> Matrix4 {
	projection_matrix: Matrix4
	switch p in projection_info {
	case Perspective_Projection_Info:
		projection_matrix = linalg.matrix4_infinite_perspective_f32(p.vertical_fov, p.aspect_ratio, p.near_clip_plane, false)
	case Orthographic_Projection_Info:
		bottom_left := Vec2{-p.view_extents.x, -p.view_extents.y}
		top_right   := Vec2{ p.view_extents.x,  p.view_extents.y}
		// Near is -far, because in Vk the clip space Z is 0-1.
		projection_matrix = linalg.matrix_ortho3d_f32(bottom_left.x, top_right.x, bottom_left.y, top_right.y, -p.far_clip_plane, p.far_clip_plane, false)
	}
	return projection_matrix
}

calculate_view_matrices :: proc(view_info: View_Info) -> (view_rotation: Matrix4, view: Matrix4, view_projection: Matrix4) {
	projection_matrix := calculate_projection_matrix(view_info.projection)

	// Convert from my preferred X-right,Y-forward,Z-up to Vulkan's clip space
	coord_system_matrix := Matrix4{
		1,0, 0,0,
		0,0,-1,0,
		0,1, 0,0,
		0,0, 0,1,
	}
	view_rotation = linalg.matrix4_inverse_f32(linalg.matrix4_from_euler_angles_zxy_f32(
		view_info.angles.z,
		view_info.angles.x,
		view_info.angles.y,
	))
	view = view_rotation * linalg.matrix4_translate_f32(-view_info.origin)
	view_projection = projection_matrix * coord_system_matrix * view
	return
}

Scene_View_Uniforms :: struct {
	vp_matrix: Matrix4,
	// Passing as vec4s for the alignment compatibility with SPIR-V layout
	view_origin: Vec4,
	view_direction: Vec4,
}

RScene_View :: struct {
	view_info: View_Info,

	uniforms: [MAX_FRAMES_IN_FLIGHT]rhi.Uniform_Buffer,
	descriptor_sets: [MAX_FRAMES_IN_FLIGHT]RHI_DescriptorSet,
}

create_scene_view :: proc() -> (scene_view: RScene_View, result: RHI_Result) {
	// Create scene view uniform buffers
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		scene_view.uniforms[i] = rhi.create_uniform_buffer(Scene_View_Uniforms) or_return
		
		// Create buffer descriptors
		scene_view_set_desc := rhi.Descriptor_Set_Desc{
			layout = g_r3d_state.scene_descriptor_set_layout,
			descriptors = {
				rhi.Descriptor_Desc{
					type = .UNIFORM_BUFFER,
					binding = 0,
					count = 1,
					info = rhi.Descriptor_Buffer_Info{
						buffer = &scene_view.uniforms[i].buffer,
						size = size_of(Scene_View_Uniforms),
						offset = 0,
					},
				},
			},
		}
		scene_view.descriptor_sets[i] = rhi.create_descriptor_set(g_r3d_state.descriptor_pool, scene_view_set_desc) or_return
	}

	return
}

destroy_scene_view :: proc(scene_view: ^RScene_View) {
	if scene_view == nil {
		return
	}

	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		rhi.destroy_buffer(&scene_view.uniforms[i])
		scene_view.uniforms[i] = {}
		// TODO: Maybe Release back unused descriptor sets to the pool
		scene_view.descriptor_sets[i] = 0
	}
}

update_scene_view_uniforms :: proc(scene_view: ^RScene_View) {
	assert(scene_view != nil)
	frame_in_flight := rhi.get_frame_in_flight()
	ub := &scene_view.uniforms[frame_in_flight]
	uniforms := rhi.cast_mapped_buffer_memory_single(Scene_View_Uniforms, ub.mapped_memory)

	view_info := &scene_view.view_info

	view_rotation_matrix, _, view_projection_matrix := calculate_view_matrices(view_info^)

	uniforms.vp_matrix = view_projection_matrix
	uniforms.view_origin = vec4(view_info.origin, 0)
	// Rotate a back vector because the matrix is an inverse of the actual view transform
	uniforms.view_direction = view_rotation_matrix * vec4(core.VEC3_BACKWARD, 0)
}

bind_scene_view :: proc(cb: ^RHI_CommandBuffer, scene_view: ^RScene_View, layout: RHI_PipelineLayout) {
	assert(cb != nil)
	assert(scene_view != nil)

	frame_in_flight := rhi.get_frame_in_flight()
	scene_view_ds := &scene_view.descriptor_sets[frame_in_flight]
	
	rhi.cmd_bind_descriptor_set(cb, layout, scene_view_ds^, GLOBAL_SCENE_VIEW_DS_IDX)
}

// TEXTURES ---------------------------------------------------------------------------------------------------

// TODO: Automatically(?) creating & storing Descriptor Sets for different layouts
RTexture_2D :: struct {
	texture_2d: Texture_2D,
	// TODO: Make a global sampler cache
	sampler: RHI_Sampler,
	descriptor_set: RHI_DescriptorSet,
}

create_texture_2d :: proc(image_data: []byte, dimensions: [2]u32, format: rhi.Format, filter: rhi.Filter, address_mode: rhi.Address_Mode, descriptor_set_layout: rhi.RHI_DescriptorSetLayout, name := "") -> (texture: RTexture_2D, result: RHI_Result) {
	texture.texture_2d = rhi.create_texture_2d(image_data, dimensions, format, name) or_return

	// TODO: Make a global sampler cache
	texture.sampler = rhi.create_sampler(texture.texture_2d.mip_levels, filter, address_mode) or_return

	descriptor_set_desc := rhi.Descriptor_Set_Desc{
		descriptors = {
			rhi.Descriptor_Desc{
				binding = 0,
				count = 1,
				type = .COMBINED_IMAGE_SAMPLER,
				info = rhi.Descriptor_Texture_Info{
					texture = &texture.texture_2d.texture,
					sampler = &texture.sampler,
				},
			},
		},
		layout = descriptor_set_layout,
	}
	texture.descriptor_set = rhi.create_descriptor_set(g_r3d_state.descriptor_pool, descriptor_set_desc) or_return

	return
}

destroy_texture_2d :: proc(tex: ^RTexture_2D) {
	// TODO: Release descriptors
	rhi.destroy_texture(&tex.texture_2d)
	rhi.destroy_sampler(&tex.sampler)
}

// MATERIALS ---------------------------------------------------------------------------------------------------

Material_Uniforms :: struct {
	specular: f32,
	specular_hardness: f32,
}

RMaterial :: struct {
	texture: ^RTexture_2D,

	specular: f32,
	specular_hardness: f32,

	uniforms: [rhi.MAX_FRAMES_IN_FLIGHT]rhi.Uniform_Buffer,
	descriptor_sets: [rhi.MAX_FRAMES_IN_FLIGHT]rhi.RHI_DescriptorSet,
}

create_material :: proc(texture: ^RTexture_2D) -> (material: RMaterial, result: RHI_Result) {
	assert(texture != nil)
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		material.uniforms[i] = rhi.create_uniform_buffer(Material_Uniforms) or_return

		descriptor_set_desc := rhi.Descriptor_Set_Desc{
			descriptors = {
				// Texture sampler
				rhi.Descriptor_Desc{
					binding = 0,
					count = 1,
					type = .COMBINED_IMAGE_SAMPLER,
					info = rhi.Descriptor_Texture_Info{
						texture = &texture.texture_2d.texture,
						sampler = &texture.sampler,
					},
				},
				// Material uniforms
				rhi.Descriptor_Desc{
					binding = 1,
					count = 1,
					type = .UNIFORM_BUFFER,
					info = rhi.Descriptor_Buffer_Info{
						buffer = &material.uniforms[i].buffer,
						size = size_of(Material_Uniforms),
						offset = 0,
					},
				},
			},
			layout = g_r3d_state.material_descriptor_set_layout,
		}
		material.descriptor_sets[i] = rhi.create_descriptor_set(g_r3d_state.descriptor_pool, descriptor_set_desc) or_return
	}

	return
}

destroy_material :: proc(material: ^RMaterial) {
	// TODO: Release desc sets
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		rhi.destroy_buffer(&material.uniforms[i])
	}
}

update_material_uniforms :: proc(material: ^RMaterial) {
	assert(material != nil)
	frame_in_flight := rhi.get_frame_in_flight()
	ub := &material.uniforms[frame_in_flight]
	uniforms := rhi.cast_mapped_buffer_memory_single(Material_Uniforms, ub.mapped_memory)

	uniforms.specular = material.specular
	uniforms.specular_hardness = material.specular_hardness
}

// MESHES & MODELS ---------------------------------------------------------------------------------------------

Mesh_Renderer_State :: struct {
	vsh: rhi.Vertex_Shader,
	fsh: rhi.Fragment_Shader,
	pipeline_layout: rhi.RHI_PipelineLayout,
	model_descriptor_set_layout: rhi.RHI_DescriptorSetLayout,
}

Mesh_Vertex :: struct {
	position:  Vec3 `gltf:"position"`,
	normal:    Vec3 `gltf:"normal"`,
	tex_coord: Vec2 `gltf:"texcoord"`,
}

RPrimitive :: struct {
	vertex_buffer: Vertex_Buffer,
	index_buffer: Index_Buffer,
}

// Primitive vertices format must adhere to the ones provided in pipelines that will use the created primitive
create_primitive :: proc(vertices: []$V, indices: []u32, name := "") -> (primitive: RPrimitive, result: RHI_Result) {
	// Create the Vertex Buffer
	vb_desc := rhi.Buffer_Desc{
		memory_flags = {.DEVICE_LOCAL},
	}
	vb_name := fmt.tprintf("VBO_%s", name)
	primitive.vertex_buffer = rhi.create_vertex_buffer(vb_desc, vertices, vb_name) or_return

	// Create the Index Buffer
	ib_desc := rhi.Buffer_Desc{
		memory_flags = {.DEVICE_LOCAL},
	}
	ib_name := fmt.tprintf("IBO_%s", name)
	primitive.index_buffer = rhi.create_index_buffer(indices, ib_name) or_return

	return
}

destroy_primitive :: proc(primitive: ^RPrimitive) {
	rhi.destroy_buffer(&primitive.vertex_buffer)
	rhi.destroy_buffer(&primitive.index_buffer)
}

RMesh :: struct {
	primitives: [dynamic]RPrimitive,
}

// Mesh vertices format must adhere to the ones provided in pipelines that will use the created mesh
create_mesh :: proc(primitives: []^RPrimitive, allocator := context.allocator) -> (mesh: RMesh, result: RHI_Result) {
	mesh.primitives = make([dynamic]RPrimitive, len(primitives), allocator)
	for &p, i in mesh.primitives {
		p = primitives[i]^
	}
	return
}

destroy_mesh :: proc(mesh: ^RMesh) {
	for &p in mesh.primitives {
		destroy_primitive(&p)
	}
	delete(mesh.primitives)
}

Model_Uniforms :: struct {
	model_matrix: Matrix4,
	inverse_transpose_matrix: Matrix4, // used to transform normals
}

Model_Push_Constants :: struct {
	mvp: Matrix4,
}

Model_Data :: struct {
	location: Vec3,
	rotation: Vec3,
	scale: Vec3,
}

RModel :: struct {
	mesh: ^RMesh,
	data: Model_Data,
	uniforms: [rhi.MAX_FRAMES_IN_FLIGHT]rhi.Uniform_Buffer,
	descriptor_sets: [rhi.MAX_FRAMES_IN_FLIGHT]rhi.RHI_DescriptorSet,
}

create_model :: proc(mesh: ^RMesh, name := "") -> (model: RModel, result: RHI_Result) {
	// Create buffers and descriptor sets
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		ub_name := fmt.tprintf("UBO_%s-%i", name, i)
		model.uniforms[i] = rhi.create_uniform_buffer(Model_Uniforms, ub_name) or_return
		set_desc := rhi.Descriptor_Set_Desc{
			descriptors = {
				rhi.Descriptor_Desc{
					type = .UNIFORM_BUFFER,
					binding = 0,
					count = 1,
					info = rhi.Descriptor_Buffer_Info{
						buffer = &model.uniforms[i].buffer,
						size = size_of(Model_Uniforms),
						offset = 0,
					},
				},
			},
			layout = g_r3d_state.mesh_renderer_state.model_descriptor_set_layout,
		}
		model.descriptor_sets[i] = rhi.create_descriptor_set(g_r3d_state.descriptor_pool, set_desc) or_return
	}

	// Assign the mesh
	model.mesh = mesh

	// Make sure the default scale is 1 and not 0.
	model.data.scale = core.VEC3_ONE

	return
}

destroy_model :: proc(model: ^RModel) {
	for i in 0..<rhi.MAX_FRAMES_IN_FLIGHT {
		rhi.destroy_buffer(&model.uniforms[i])
	}
	// TODO: Handle descriptor sets' release
}

// Requires a scene view that has already been updated for the current frame, otherwise the data from the previous frame will be used
// TODO: this data should be updated separately for each scene view (precalculated MVP matrix) which is kinda inconvenient
update_model_uniforms :: proc(model: ^RModel) {
	assert(model != nil)

	frame_in_flight := rhi.get_frame_in_flight()
	ub := &model.uniforms[frame_in_flight]
	uniforms := rhi.cast_mapped_buffer_memory_single(Model_Uniforms, ub.mapped_memory)

	scale_matrix := linalg.matrix4_scale_f32(model.data.scale)
	rot := model.data.rotation
	rotation_matrix := linalg.matrix4_from_euler_angles_zxy_f32(rot.z, rot.x, rot.y)
	translation_matrix := linalg.matrix4_translate_f32(model.data.location)

	uniforms.model_matrix = translation_matrix * rotation_matrix * scale_matrix
	// Normals don't need to be transformed by an inverse transpose if the scaling is uniform.
	if model.data.scale.x == model.data.scale.y && model.data.scale.x == model.data.scale.z {
		uniforms.inverse_transpose_matrix = uniforms.model_matrix
	} else {
		model_mat_3x3 := cast(Matrix3)uniforms.model_matrix
		uniforms.inverse_transpose_matrix = cast(Matrix4)linalg.matrix3_inverse_transpose_f32(model_mat_3x3)
	}
}

mesh_pipeline_layout :: proc() -> ^RHI_PipelineLayout {
	return &g_r3d_state.mesh_renderer_state.pipeline_layout
}

Mesh_Pipeline_Specializations :: struct {
	lighting_model: Lighting_Model,
}

create_mesh_pipeline :: proc(specializations: Mesh_Pipeline_Specializations) -> (pipeline: RHI_Pipeline, result: RHI_Result) {
	// Create the pipeline for mesh rendering
	mesh_pipeline_desc := rhi.Pipeline_Description{
		vertex_input = rhi.create_vertex_input_description({
			rhi.Vertex_Input_Type_Desc{rate = .VERTEX, type = Mesh_Vertex},
		}, context.temp_allocator),
		input_assembly = {topology = .TRIANGLE_LIST},
		depth_stencil = {
			depth_test = true,
			depth_write = true,
			depth_compare_op = .LESS_OR_EQUAL,
		},
		shader_stages = {
			{type = .VERTEX,   shader = &g_r3d_state.mesh_renderer_state.vsh.shader, specializations = specializations},
			{type = .FRAGMENT, shader = &g_r3d_state.mesh_renderer_state.fsh.shader, specializations = specializations},
		},
	}
	pipeline = rhi.create_graphics_pipeline(mesh_pipeline_desc, g_r3d_state.main_render_pass.render_pass, g_r3d_state.mesh_renderer_state.pipeline_layout) or_return

	return
}

draw_model :: proc(cb: ^RHI_CommandBuffer, model: ^RModel, materials: []^RMaterial, scene_view: ^RScene_View) {
	assert(cb != nil)
	assert(model != nil)
	assert(model.mesh != nil)
	assert(len(materials) == len(model.mesh.primitives))

	frame_in_flight := rhi.get_frame_in_flight()

	rhi.cmd_bind_descriptor_set(cb, g_r3d_state.mesh_renderer_state.pipeline_layout, model.descriptor_sets[frame_in_flight], MESH_RENDERING_MODEL_DS_IDX)

	// TODO: These matrices could also be stored somewhere else to be easier accessible in this scenario.
	ub := &model.uniforms[frame_in_flight]
	uniforms := rhi.cast_mapped_buffer_memory_single(Model_Uniforms, ub.mapped_memory)
	sv_uniforms := rhi.cast_mapped_buffer_memory_single(Scene_View_Uniforms, scene_view.uniforms[frame_in_flight].mapped_memory)

	model_push_constants := Model_Push_Constants{
		mvp = sv_uniforms.vp_matrix * uniforms.model_matrix,
	}
	rhi.cmd_push_constants(cb, g_r3d_state.mesh_renderer_state.pipeline_layout, {.VERTEX}, &model_push_constants)

	for prim, i in model.mesh.primitives {
		// TODO: What if there is no texture
		rhi.cmd_bind_descriptor_set(cb, g_r3d_state.mesh_renderer_state.pipeline_layout, materials[i].descriptor_sets[frame_in_flight], MESH_RENDERING_MATERIAL_DS_IDX)

		rhi.cmd_bind_vertex_buffer(cb, prim.vertex_buffer)
		rhi.cmd_bind_index_buffer(cb, prim.index_buffer)
		rhi.cmd_draw_indexed(cb, prim.index_buffer.index_count)
	}
}

// Instanced models ---------------------------------------------------------------------------------------------

Instanced_Mesh_Renderer_State :: struct {
	vsh: rhi.Vertex_Shader,
	fsh: rhi.Fragment_Shader,
	pipeline_layout: rhi.RHI_PipelineLayout,
}

Mesh_Instance :: struct {
	model_matrix: Matrix4,
	inverse_transpose_matrix: Matrix4,
}

RInstancedModel :: struct {
	mesh: ^RMesh,
	data: [dynamic]Model_Data,
	instance_buffers: [MAX_FRAMES_IN_FLIGHT]Vertex_Buffer,
}

create_instanced_model :: proc(mesh: ^RMesh, instance_count: u32, name := "") -> (model: RInstancedModel, result: RHI_Result) {
	// Create instance buffers
	buffer_desc := rhi.Buffer_Desc{
		memory_flags = {.HOST_COHERENT, .HOST_VISIBLE},
		map_memory = true,
	}
	for &b, i in model.instance_buffers {
		vb_name := fmt.tprintf("InstanceVBO_%s-%i", name, i)
		b = rhi.create_vertex_buffer_empty(buffer_desc, Mesh_Instance, instance_count, vb_name) or_return
	}

	// Assign the mesh
	model.mesh = mesh

	// Make sure the default scale is 1 and not 0.
	model.data = make([dynamic]Model_Data, instance_count)
	for &d in model.data {
		d.scale = core.VEC3_ONE
	}

	return
}

destroy_instanced_model :: proc(model: ^RInstancedModel) {
	for &buf in model.instance_buffers {
		rhi.destroy_buffer(&buf)
	}
	delete(model.data)
}

update_model_instance_buffer :: proc(model: ^RInstancedModel) {
	assert(model != nil)

	frame_in_flight := rhi.get_frame_in_flight()
	ib := &model.instance_buffers[frame_in_flight]
	instances := rhi.cast_mapped_buffer_memory(Mesh_Instance, ib.mapped_memory)

	for d, i in model.data {
		scale_matrix := linalg.matrix4_scale_f32(d.scale)
		rot := d.rotation
		rotation_matrix := linalg.matrix4_from_euler_angles_zxy_f32(rot.z, rot.x, rot.y)
		translation_matrix := linalg.matrix4_translate_f32(d.location)

		instance := &instances[i]

		instance.model_matrix = translation_matrix * rotation_matrix * scale_matrix
		// Normals don't need to be transformed by an inverse transpose if the scaling is uniform.
		if d.scale.x == d.scale.y && d.scale.x == d.scale.z {
			instance.inverse_transpose_matrix = instance.model_matrix
		} else {
			model_mat_3x3 := cast(Matrix3)instance.model_matrix
			instance.inverse_transpose_matrix = cast(Matrix4)linalg.matrix3_inverse_transpose_f32(model_mat_3x3)
		}
	}
}

instanced_mesh_pipeline_layout :: proc() -> ^RHI_PipelineLayout {
	return &g_r3d_state.instanced_mesh_renderer_state.pipeline_layout
}

create_instanced_mesh_pipeline :: proc(specializations: Mesh_Pipeline_Specializations) -> (pipeline: RHI_Pipeline, result: RHI_Result) {
	// Create the pipeline for mesh rendering
	instanced_mesh_pipeline_desc := rhi.Pipeline_Description{
		vertex_input = rhi.create_vertex_input_description({
			rhi.Vertex_Input_Type_Desc{rate = .VERTEX,   type = Mesh_Vertex},
			rhi.Vertex_Input_Type_Desc{rate = .INSTANCE, type = Mesh_Instance},
		}, context.temp_allocator),
		input_assembly = {topology = .TRIANGLE_LIST},
		depth_stencil = {
			depth_test = true,
			depth_write = true,
			depth_compare_op = .LESS_OR_EQUAL,
		},
		shader_stages = {
			{type = .VERTEX,   shader = &g_r3d_state.instanced_mesh_renderer_state.vsh.shader, specializations = specializations},
			{type = .FRAGMENT, shader = &g_r3d_state.instanced_mesh_renderer_state.fsh.shader, specializations = specializations},
		},
	}
	pipeline = rhi.create_graphics_pipeline(
		instanced_mesh_pipeline_desc,
		g_r3d_state.main_render_pass.render_pass,
		g_r3d_state.instanced_mesh_renderer_state.pipeline_layout,
	) or_return

	return
}

draw_instanced_model :: proc(cb: ^RHI_CommandBuffer, model: ^RInstancedModel, materials: []^RMaterial) {
	assert(cb != nil)
	assert(model != nil)
	assert(model.mesh != nil)
	assert(len(materials) == len(model.mesh.primitives))

	frame_in_flight := rhi.get_frame_in_flight()

	// Model instance buffer
	rhi.cmd_bind_vertex_buffer(cb, model.instance_buffers[frame_in_flight], 1)

	for prim, i in model.mesh.primitives {
		// TODO: What if there is no texture
		rhi.cmd_bind_descriptor_set(cb, g_r3d_state.instanced_mesh_renderer_state.pipeline_layout, materials[i].descriptor_sets[frame_in_flight], INSTANCED_MESH_RENDERING_MATERIAL_DS_IDX)

		rhi.cmd_bind_vertex_buffer(cb, prim.vertex_buffer)
		rhi.cmd_bind_index_buffer(cb, prim.index_buffer)
		rhi.cmd_draw_indexed(cb, prim.index_buffer.index_count, cast(u32)len(model.data))
	}
}

draw_instanced_model_primitive :: proc(cb: ^RHI_CommandBuffer, model: ^RInstancedModel, primitive_index: uint, material: ^RMaterial) {
	assert(cb != nil)
	assert(model != nil)
	assert(model.mesh != nil)
	assert(primitive_index < len(model.mesh.primitives))

	frame_in_flight := rhi.get_frame_in_flight()

	// Model instance buffer
	rhi.cmd_bind_vertex_buffer(cb, model.instance_buffers[frame_in_flight], 1)

	// TODO: What if there is no texture
	rhi.cmd_bind_descriptor_set(cb, g_r3d_state.instanced_mesh_renderer_state.pipeline_layout, material.descriptor_sets[frame_in_flight], INSTANCED_MESH_RENDERING_MATERIAL_DS_IDX)
	
	prim := &model.mesh.primitives[primitive_index]
	rhi.cmd_bind_vertex_buffer(cb, prim.vertex_buffer)
	rhi.cmd_bind_index_buffer(cb, prim.index_buffer)
	rhi.cmd_draw_indexed(cb, prim.index_buffer.index_count, cast(u32)len(model.data))
}

// TERRAIN --------------------------------------------------------------------------------------------------------

Terrain_Renderer_State :: struct {
	pipeline: rhi.RHI_Pipeline,
	debug_pipeline: rhi.RHI_Pipeline,
	pipeline_layout: rhi.RHI_PipelineLayout,
	descriptor_set_layout: rhi.RHI_DescriptorSetLayout,
}

Terrain_Vertex :: struct {
	position:  Vec3 `gltf:"position"`,
	normal:    Vec3 `gltf:"normal"`,
	color:     Vec4 `gltf:"color"`,
	tex_coord: Vec2 `gltf:"texcoord"`,
}

Terrain_Push_Constants :: struct {
	height_scale: f32,
	height_center: f32,
}

RTerrain :: struct {
	vertex_buffer: Vertex_Buffer,
	index_buffer: Index_Buffer,
	height_scale: f32,
	height_center: f32,
	descriptor_sets: [rhi.MAX_FRAMES_IN_FLIGHT]rhi.RHI_DescriptorSet,
}

// TODO: Procedurally generate the plane mesh
create_terrain :: proc(vertices: []$V, indices: []u32, height_map: ^RTexture_2D, name := "") -> (terrain: RTerrain, result: RHI_Result) {
	assert(height_map != nil)

	// Create the Vertex Buffer
	vb_desc := rhi.Buffer_Desc{
		memory_flags = {.DEVICE_LOCAL},
	}
	vb_name := fmt.tprintf("VBO_%s", name)
	terrain.vertex_buffer = rhi.create_vertex_buffer(vb_desc, vertices, vb_name) or_return

	// Create the Index Buffer
	ib_desc := rhi.Buffer_Desc{
		memory_flags = {.DEVICE_LOCAL},
	}
	ib_name := fmt.tprintf("IBO_%s", name)
	terrain.index_buffer = rhi.create_index_buffer(indices, ib_name) or_return

	// Create buffers and descriptor sets
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		set_desc := rhi.Descriptor_Set_Desc{
			descriptors = {
				// Height map texture
				rhi.Descriptor_Desc{
					type = .COMBINED_IMAGE_SAMPLER,
					binding = 0,
					count = 1,
					info = rhi.Descriptor_Texture_Info{
						texture = &height_map.texture_2d.texture,
						sampler = &height_map.sampler,
					},
				},
			},
			layout = g_r3d_state.terrain_renderer_state.descriptor_set_layout,
		}
		terrain.descriptor_sets[i] = rhi.create_descriptor_set(g_r3d_state.descriptor_pool, set_desc) or_return
	}

	terrain.height_center = 0.5
	terrain.height_scale = 1

	return
}

destroy_terrain :: proc(terrain: ^RTerrain) {
	rhi.destroy_buffer(&terrain.vertex_buffer)
	rhi.destroy_buffer(&terrain.index_buffer)
	// TODO: Handle descriptor sets' release
}

bind_terrain_pipeline :: proc(cb: ^RHI_CommandBuffer) {
	rhi.cmd_bind_graphics_pipeline(cb, g_r3d_state.terrain_renderer_state.pipeline)
}

terrain_pipeline_layout :: proc() -> ^RHI_PipelineLayout {
	return &g_r3d_state.terrain_renderer_state.pipeline_layout
}

draw_terrain :: proc(cb: ^RHI_CommandBuffer, terrain: ^RTerrain, material: ^RMaterial, debug: bool) {
	assert(cb != nil)
	assert(terrain != nil)
	assert(material != nil)

	frame_in_flight := rhi.get_frame_in_flight()

	pipeline := &g_r3d_state.terrain_renderer_state.pipeline if !debug else &g_r3d_state.terrain_renderer_state.debug_pipeline
	rhi.cmd_bind_graphics_pipeline(cb, pipeline^)

	rhi.cmd_bind_vertex_buffer(cb, terrain.vertex_buffer)
	rhi.cmd_bind_index_buffer(cb, terrain.index_buffer)
	rhi.cmd_bind_descriptor_set(cb, g_r3d_state.terrain_renderer_state.pipeline_layout, terrain.descriptor_sets[frame_in_flight], TERRAIN_RENDERING_TERRAIN_DS_IDX)
	// TODO: What if there is no texture
	rhi.cmd_bind_descriptor_set(cb, g_r3d_state.terrain_renderer_state.pipeline_layout, material.descriptor_sets[frame_in_flight], TERRAIN_RENDERING_MATERIAL_DS_IDX)
	push_constants := Terrain_Push_Constants{
		height_scale = terrain.height_scale,
		height_center = terrain.height_center,
	}
	rhi.cmd_push_constants(cb, g_r3d_state.terrain_renderer_state.pipeline_layout, {.VERTEX}, &push_constants)

	rhi.cmd_draw_indexed(cb, terrain.index_buffer.index_count)
}

// FULL-SCREEN QUAD RENDERING -------------------------------------------------------------------------------------------

Quad_Renderer_State :: struct {
	pipeline: RHI_Pipeline,
	pipeline_layout: RHI_PipelineLayout,
	descriptor_set_layout: RHI_DescriptorSetLayout,
	sampler: RHI_Sampler,
}

draw_full_screen_quad :: proc(cb: ^RHI_CommandBuffer, texture: RTexture_2D) {
	rhi.cmd_bind_graphics_pipeline(cb, g_r3d_state.quad_renderer_state.pipeline)
	rhi.cmd_bind_descriptor_set(cb, g_r3d_state.quad_renderer_state.pipeline_layout, texture.descriptor_set)
	// Draw 4 hardcoded quad vertices as a triangle strip
	rhi.cmd_draw(cb, 4)
}

// RENDERER -----------------------------------------------------------------------------------------------------------

init :: proc() -> Result {
	if r := init_rhi(); r != nil {
		return r.(rhi.RHI_Error)
	}

	return nil
}

shutdown :: proc() {
	shutdown_rhi()
	delete(g_r3d_state.main_render_pass.framebuffers)
}

begin_frame :: proc() -> (cb: ^RHI_CommandBuffer, image_index: uint) {
	r: RHI_Result
	maybe_image_index: Maybe(uint)
	if maybe_image_index, r = rhi.wait_and_acquire_image(); r != nil {
		core.error_log(r.?)
		return
	}
	if maybe_image_index == nil {
		// No image available
		return
	}
	image_index = maybe_image_index.(uint)

	frame_in_flight := rhi.get_frame_in_flight()
	cb = &g_r3d_state.cmd_buffers[frame_in_flight]

	rhi.begin_command_buffer(cb)

	return
}

end_frame :: proc(cb: ^RHI_CommandBuffer, image_index: uint) {
	rhi.end_command_buffer(cb)

	rhi.queue_submit_for_drawing(cb)

	if r := rhi.present(image_index); r != nil {
		core.error_log(r.?)
		return
	}
}

@(private)
init_rhi :: proc() -> RHI_Result {
	core.broadcaster_add_callback(&rhi.callbacks.on_recreate_swapchain_broadcaster, on_recreate_swapchain)

	// TODO: Presenting & swapchain framebuffers should be separated from the actual renderer
	// Get swapchain stuff
	main_window := platform.get_main_window()
	surface_index := rhi.get_surface_index_from_window(main_window)
	swapchain_format := rhi.get_swapchain_image_format(surface_index)
	swapchain_images := rhi.get_swapchain_images(surface_index)
	assert(len(swapchain_images) > 0)
	swapchain_dims := swapchain_images[0].dimensions

	// Make render pass for swapchain images
	render_pass_desc := rhi.Render_Pass_Desc{
		attachments = {
			// Color
			rhi.Attachment_Desc{
				usage = .COLOR,
				format = swapchain_format,
				load_op = .CLEAR,
				store_op = .STORE,
				from_layout = .UNDEFINED,
				to_layout = .PRESENT_SRC_KHR,
			},
			// Depth-stencil
			rhi.Attachment_Desc{
				usage = .DEPTH_STENCIL,
				format = .D32FS8,
				load_op = .CLEAR,
				store_op = .IRRELEVANT,
				from_layout = .UNDEFINED,
				to_layout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
			},
		},
		src_dependency = {
			stage_mask = {.COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS},
			access_mask = {},
		},
		dst_dependency = {
			stage_mask = {.COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS},
			access_mask = {.COLOR_ATTACHMENT_WRITE, .DEPTH_STENCIL_ATTACHMENT_WRITE},
		},
	}
	g_r3d_state.main_render_pass.render_pass = rhi.create_render_pass(render_pass_desc) or_return

	// Create global depth buffer
	g_r3d_state.depth_texture = rhi.create_depth_texture(swapchain_dims, .D32FS8, "DepthBuffer") or_return

	// Make framebuffers
	fb_textures := make([]^Texture_2D, len(swapchain_images), context.temp_allocator)
	for &im, i in swapchain_images {
		fb_textures[i] = &im
	}
	create_framebuffers(fb_textures, &g_r3d_state.depth_texture) or_return

	// Create a global descriptor pool
	pool_desc := rhi.Descriptor_Pool_Desc{
		pool_sizes = {
			rhi.Descriptor_Pool_Size{
				type = .COMBINED_IMAGE_SAMPLER,
				count = MAX_SAMPLERS,
			},
			rhi.Descriptor_Pool_Size{
				type = .UNIFORM_BUFFER,
				count = (MAX_SCENES + MAX_SCENE_VIEWS + MAX_MODELS + MAX_MATERIALS) * MAX_FRAMES_IN_FLIGHT,
			},
		},
		max_sets = MAX_SAMPLERS + MAX_TERRAINS + (MAX_SCENES + MAX_SCENE_VIEWS + MAX_MODELS + MAX_MATERIALS) * MAX_FRAMES_IN_FLIGHT,
	}
	g_r3d_state.descriptor_pool = rhi.create_descriptor_pool(pool_desc) or_return

	debug_init(&g_r3d_state.debug_renderer_state, g_r3d_state.main_render_pass.render_pass, swapchain_format) or_return

	// Initialize full screen quad rendering
	{
		// Create shaders
		vsh := rhi.create_vertex_shader(core.path_make_engine_shader_relative(QUAD_SHADER_VERT)) or_return
		defer rhi.destroy_shader(&vsh)
	
		fsh := rhi.create_fragment_shader(core.path_make_engine_shader_relative(QUAD_SHADER_FRAG)) or_return
		defer rhi.destroy_shader(&fsh)

		// Create descriptor set layout
		descriptor_set_layout_desc := rhi.Descriptor_Set_Layout_Description{
			bindings = {
				rhi.Descriptor_Set_Layout_Binding{
					binding = 0,
					type = .COMBINED_IMAGE_SAMPLER,
					count = 1,
					shader_stage = {.FRAGMENT},
				},
			},
		}
		g_r3d_state.quad_renderer_state.descriptor_set_layout = rhi.create_descriptor_set_layout(descriptor_set_layout_desc) or_return
	
		// Create pipeline layout
		pipeline_layout_desc := rhi.Pipeline_Layout_Description{
			descriptor_set_layouts = {
				&g_r3d_state.quad_renderer_state.descriptor_set_layout,
			},
		}
		g_r3d_state.quad_renderer_state.pipeline_layout = rhi.create_pipeline_layout(pipeline_layout_desc) or_return
	
		// Create quad graphics pipeline
		pipeline_desc := rhi.Pipeline_Description{
			shader_stages = {
				rhi.Pipeline_Shader_Stage{type = .VERTEX,   shader = &vsh.shader},
				rhi.Pipeline_Shader_Stage{type = .FRAGMENT, shader = &fsh.shader},
			},
			input_assembly = {topology = .TRIANGLE_STRIP},
		}
		g_r3d_state.quad_renderer_state.pipeline = rhi.create_graphics_pipeline(pipeline_desc, g_r3d_state.main_render_pass.render_pass, g_r3d_state.quad_renderer_state.pipeline_layout) or_return

		// Create a no-mipmap sampler for a "pixel-perfect" quad
		g_r3d_state.quad_renderer_state.sampler = rhi.create_sampler(1, .NEAREST, .REPEAT) or_return
	}
	
	// SCENE DESCRIPTORS SETUP -----------------------------------------------------------------------------------------

	// Make a descriptor set layout for scene uniforms
	scene_layout_desc := rhi.Descriptor_Set_Layout_Description{
		bindings = {
			// Scene binding
			rhi.Descriptor_Set_Layout_Binding{
				binding = 0,
				count = 1,
				shader_stage = {.VERTEX, .FRAGMENT},
				type = .UNIFORM_BUFFER,
			},
		},
	}
	g_r3d_state.scene_descriptor_set_layout = rhi.create_descriptor_set_layout(scene_layout_desc) or_return

	// Make a descriptor set layout for scene view uniforms
	scene_view_layout_desc := rhi.Descriptor_Set_Layout_Description{
		bindings = {
			// Scene view binding
			rhi.Descriptor_Set_Layout_Binding{
				binding = 0,
				count = 1,
				shader_stage = {.VERTEX, .FRAGMENT},
				type = .UNIFORM_BUFFER,
			},
		},
	}
	g_r3d_state.scene_view_descriptor_set_layout = rhi.create_descriptor_set_layout(scene_view_layout_desc) or_return
	
	// Make a descriptor set layout for materials
	material_dsl_desc := rhi.Descriptor_Set_Layout_Description{
		bindings = {
			// Texture sampler
			rhi.Descriptor_Set_Layout_Binding{
				binding = 0,
				count = 1,
				shader_stage = {.FRAGMENT},
				type = .COMBINED_IMAGE_SAMPLER,
			},
			// Material uniforms
			rhi.Descriptor_Set_Layout_Binding{
				binding = 1,
				count = 1,
				shader_stage = {.FRAGMENT},
				type = .UNIFORM_BUFFER,
			},
		},
	}
	g_r3d_state.material_descriptor_set_layout = rhi.create_descriptor_set_layout(material_dsl_desc) or_return
	
	// SETUP MESH RENDERING ---------------------------------------------------------------------------------------------------------------------
	{
		// Create basic 3D shaders
		g_r3d_state.mesh_renderer_state.vsh = rhi.create_vertex_shader(core.path_make_engine_shader_relative(MESH_SHADER_VERT)) or_return
		g_r3d_state.mesh_renderer_state.fsh = rhi.create_fragment_shader(core.path_make_engine_shader_relative(MESH_SHADER_FRAG)) or_return
	
		// Make a descriptor set layout for model uniforms
		dsl_desc := rhi.Descriptor_Set_Layout_Description{
			bindings = {
				// Model constants (per draw call)
				rhi.Descriptor_Set_Layout_Binding{
					binding = 0,
					count = 1,
					shader_stage = {.VERTEX, .FRAGMENT},
					type = .UNIFORM_BUFFER,
				},
			},
		}
		g_r3d_state.mesh_renderer_state.model_descriptor_set_layout = rhi.create_descriptor_set_layout(dsl_desc) or_return

		// Make a pipeline layout for mesh rendering
		pipeline_layout_desc := rhi.Pipeline_Layout_Description{
			descriptor_set_layouts = {
				// Keep in the same order as MESH_RENDERING_..._IDX constants
				&g_r3d_state.scene_descriptor_set_layout,
				&g_r3d_state.scene_view_descriptor_set_layout,
				&g_r3d_state.mesh_renderer_state.model_descriptor_set_layout,
				&g_r3d_state.material_descriptor_set_layout,
			},
			push_constants = {
				rhi.Push_Constant_Range{
					offset = 0,
					size = size_of(Model_Push_Constants),
					shader_stage = {.VERTEX},
				},
			},
		}
		g_r3d_state.mesh_renderer_state.pipeline_layout = rhi.create_pipeline_layout(pipeline_layout_desc) or_return
	}

	// SETUP INSTANCED MESH RENDERING ---------------------------------------------------------------------------------------------------------------------
	{
		// Create basic 3D shaders
		g_r3d_state.instanced_mesh_renderer_state.vsh = rhi.create_vertex_shader(core.path_make_engine_shader_relative(INSTANCED_MESH_SHADER_VERT)) or_return
		g_r3d_state.instanced_mesh_renderer_state.fsh = rhi.create_fragment_shader(core.path_make_engine_shader_relative(INSTANCED_MESH_SHADER_FRAG)) or_return
	
		// Make a pipeline layout for mesh rendering
		pipeline_layout_desc := rhi.Pipeline_Layout_Description{
			descriptor_set_layouts = {
				// Keep in the same order as INSTANCED_MESH_RENDERING_..._IDX constants
				&g_r3d_state.scene_descriptor_set_layout,
				&g_r3d_state.scene_view_descriptor_set_layout,
				&g_r3d_state.material_descriptor_set_layout,
			},
		}
		g_r3d_state.instanced_mesh_renderer_state.pipeline_layout = rhi.create_pipeline_layout(pipeline_layout_desc) or_return
	}

	// SETUP TERRAIN RENDERING ---------------------------------------------------------------------------------------------------------------------
	{
		// Create basic 3D shaders
		terrain_vsh := rhi.create_vertex_shader(core.path_make_engine_shader_relative(TERRAIN_SHADER_VERT)) or_return
		defer rhi.destroy_shader(&terrain_vsh)
		terrain_fsh := rhi.create_fragment_shader(core.path_make_engine_shader_relative(TERRAIN_SHADER_FRAG)) or_return
		defer rhi.destroy_shader(&terrain_fsh)

		// Create shaders for debug viewing
		terrain_dbg_fsh := rhi.create_fragment_shader(core.path_make_engine_shader_relative(TERRAIN_DEBUG_SHADER_FRAG)) or_return
		defer rhi.destroy_shader(&terrain_dbg_fsh)
	
		dsl_desc: rhi.Descriptor_Set_Layout_Description

		// Make a descriptor set layout for terrain maps
		dsl_desc = rhi.Descriptor_Set_Layout_Description{
			bindings = {
				// Height map
				rhi.Descriptor_Set_Layout_Binding{
					binding = 0,
					count = 1,
					shader_stage = {.VERTEX},
					type = .COMBINED_IMAGE_SAMPLER,
				},
			},
		}
		g_r3d_state.terrain_renderer_state.descriptor_set_layout = rhi.create_descriptor_set_layout(dsl_desc) or_return

		// Make a pipeline layout for terrain rendering
		pipeline_layout_desc := rhi.Pipeline_Layout_Description{
			descriptor_set_layouts = {
				// Keep in the same order as TERRAIN_RENDERING_..._IDX constants
				&g_r3d_state.scene_descriptor_set_layout,
				&g_r3d_state.scene_view_descriptor_set_layout,
				&g_r3d_state.terrain_renderer_state.descriptor_set_layout,
				&g_r3d_state.material_descriptor_set_layout,
			},
			push_constants = {
				rhi.Push_Constant_Range{
					offset = 0,
					size = size_of(Terrain_Push_Constants),
					shader_stage = {.VERTEX},
				},
			},
		}
		g_r3d_state.terrain_renderer_state.pipeline_layout = rhi.create_pipeline_layout(pipeline_layout_desc) or_return
	
		// Create the pipeline for terrain rendering
		terrain_pipeline_desc := rhi.Pipeline_Description{
			vertex_input = rhi.create_vertex_input_description({
				rhi.Vertex_Input_Type_Desc{rate = .VERTEX, type = Terrain_Vertex},
			}, context.temp_allocator),
			input_assembly = {topology = .TRIANGLE_LIST},
			depth_stencil = {
				depth_test = true,
				depth_write = true,
				depth_compare_op = .LESS_OR_EQUAL,
			},
			shader_stages = {
				{type = .VERTEX,   shader = &terrain_vsh.shader},
				{type = .FRAGMENT, shader = &terrain_fsh.shader},
			},
		}
		g_r3d_state.terrain_renderer_state.pipeline = rhi.create_graphics_pipeline(terrain_pipeline_desc, g_r3d_state.main_render_pass.render_pass, g_r3d_state.terrain_renderer_state.pipeline_layout) or_return

		// Create a debug pipeline for viewing the terrain from the top
		debug_terrain_pipeline_desc := rhi.Pipeline_Description{
			vertex_input = rhi.create_vertex_input_description({
				rhi.Vertex_Input_Type_Desc{rate = .VERTEX, type = Terrain_Vertex},
			}, context.temp_allocator),
			input_assembly = {topology = .TRIANGLE_LIST},
			depth_stencil = {
				depth_test = true,
				depth_write = true,
				depth_compare_op = .LESS_OR_EQUAL,
			},
			shader_stages = {
				{type = .VERTEX,   shader = &terrain_vsh.shader},
				{type = .FRAGMENT, shader = &terrain_dbg_fsh.shader},
			},
		}
		g_r3d_state.terrain_renderer_state.debug_pipeline = rhi.create_graphics_pipeline(debug_terrain_pipeline_desc, g_r3d_state.main_render_pass.render_pass, g_r3d_state.terrain_renderer_state.pipeline_layout) or_return
	}
	
	// Allocate global cmd buffers
	g_r3d_state.cmd_buffers = rhi.allocate_command_buffers(MAX_FRAMES_IN_FLIGHT) or_return

	g_r3d_state.base_to_debug_semaphores = rhi.create_semaphores() or_return

	return nil
}

@(private)
shutdown_rhi :: proc() {
	rhi.wait_for_device()

	rhi.destroy_descriptor_set_layout(&g_r3d_state.terrain_renderer_state.descriptor_set_layout)
	rhi.destroy_pipeline_layout(&g_r3d_state.terrain_renderer_state.pipeline_layout)
	rhi.destroy_graphics_pipeline(&g_r3d_state.terrain_renderer_state.pipeline)
	rhi.destroy_graphics_pipeline(&g_r3d_state.terrain_renderer_state.debug_pipeline)

	rhi.destroy_pipeline_layout(&g_r3d_state.instanced_mesh_renderer_state.pipeline_layout)
	rhi.destroy_shader(&g_r3d_state.instanced_mesh_renderer_state.vsh)
	rhi.destroy_shader(&g_r3d_state.instanced_mesh_renderer_state.fsh)

	rhi.destroy_descriptor_set_layout(&g_r3d_state.mesh_renderer_state.model_descriptor_set_layout)
	rhi.destroy_pipeline_layout(&g_r3d_state.mesh_renderer_state.pipeline_layout)
	rhi.destroy_shader(&g_r3d_state.mesh_renderer_state.vsh)
	rhi.destroy_shader(&g_r3d_state.mesh_renderer_state.fsh)

	rhi.destroy_descriptor_set_layout(&g_r3d_state.material_descriptor_set_layout)
	rhi.destroy_descriptor_set_layout(&g_r3d_state.scene_descriptor_set_layout)

	debug_shutdown(&g_r3d_state.debug_renderer_state)

	destroy_framebuffers()
	rhi.destroy_texture(&g_r3d_state.depth_texture)
	rhi.destroy_render_pass(&g_r3d_state.main_render_pass.render_pass)
}

@(private)
create_framebuffers :: proc(images: []^Texture_2D, depth: ^Texture_2D) -> rhi.RHI_Result {
	for &im, i in images {
		attachments := [2]^Texture_2D{im, depth}
		fb := rhi.create_framebuffer(g_r3d_state.main_render_pass.render_pass, attachments[:]) or_return
		append(&g_r3d_state.main_render_pass.framebuffers, fb)
	}
	return nil
}

@(private)
on_recreate_swapchain :: proc(args: rhi.Args_Recreate_Swapchain) {
	r: rhi.RHI_Result
	destroy_framebuffers()
	rhi.destroy_texture(&g_r3d_state.depth_texture)
	swapchain_images := rhi.get_swapchain_images(args.surface_index)
	g_r3d_state.depth_texture, r = rhi.create_depth_texture(args.new_dimensions, .D32FS8)
	if r != nil {
		panic("Failed to recreate the depth texture.")
	}
	fb_textures := make([]^Texture_2D, len(swapchain_images), context.temp_allocator)
	for &im, i in swapchain_images {
		fb_textures[i] = &im
	}
	create_framebuffers(fb_textures, &g_r3d_state.depth_texture)
}

@(private)
destroy_framebuffers :: proc() {
	for &fb in g_r3d_state.main_render_pass.framebuffers {
		rhi.destroy_framebuffer(&fb)
	}
	clear(&g_r3d_state.main_render_pass.framebuffers)
}

Renderer3D_RenderPass :: struct {
	framebuffers: [dynamic]Framebuffer,
	render_pass: RHI_RenderPass,
}

Renderer3D_State :: struct {
	debug_renderer_state: Debug_Renderer_State,
	quad_renderer_state: Quad_Renderer_State,
	mesh_renderer_state: Mesh_Renderer_State,
	instanced_mesh_renderer_state: Instanced_Mesh_Renderer_State,
	terrain_renderer_state: Terrain_Renderer_State,

	scene_descriptor_set_layout: rhi.RHI_DescriptorSetLayout,
	scene_view_descriptor_set_layout: rhi.RHI_DescriptorSetLayout,
	material_descriptor_set_layout: rhi.RHI_DescriptorSetLayout,

	main_render_pass: Renderer3D_RenderPass,
	depth_texture: Texture_2D,

	descriptor_pool: RHI_DescriptorPool,
	cmd_buffers: [MAX_FRAMES_IN_FLIGHT]RHI_CommandBuffer,

	base_to_debug_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
}
// TODO: Would be better if this was passed around as a context instead of a global variable
g_r3d_state: Renderer3D_State
