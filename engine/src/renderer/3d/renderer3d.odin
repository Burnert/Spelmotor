package sm_renderer_3d

import "core:image/png"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import "vendor:cgltf"

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

MAX_SAMPLERS :: 100
MAX_SCENES :: 1
MAX_SCENE_VIEWS :: 10
MAX_MODELS :: 1000
MAX_LIGHTS :: 1000
MAX_MATERIALS :: 1000

MESH_RENDERING_SCENE_DS_IDX :: 0
MESH_RENDERING_SCENE_VIEW_DS_IDX :: 1
MESH_RENDERING_MODEL_DS_IDX :: 2
MESH_RENDERING_MATERIAL_DS_IDX :: 3

// SCENE ----------------------------------------------------------------------------------------------------

Light_Uniforms :: struct #align(16) {
	// Passing as vec4s for the alignment compatibility with SPIR-V layout
	location: Vec4,
	direction: Vec4,
	color: Vec3,
	attenuation_radius: f32,
}

Scene_Uniforms :: struct {
	lights: [MAX_LIGHTS]Light_Uniforms,
	light_num: u32,
}

Light_Info :: struct {
	location: Vec3,
	direction: Vec3, // Not used for point lights
	color: Vec3,
	intensity: f32, // Intensity at 1m distance from the light
	attenuation_radius: f32,
}

RScene :: struct {
	lights: [dynamic]Light_Info,

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
	for l, i in scene.lights {
		u_light := &uniforms.lights[i]
		u_light.location = vec4(l.location, 1)
		u_light.direction = vec4(l.direction, 0)
		u_light.color = l.color * l.intensity
		u_light.attenuation_radius = l.attenuation_radius
	}
	uniforms.light_num = cast(u32)len(scene.lights)
}

bind_scene :: proc(cb: ^RHI_CommandBuffer, scene: ^RScene) {
	assert(cb != nil)
	assert(scene != nil)

	frame_in_flight := rhi.get_frame_in_flight()
	scene_ds := &scene.descriptor_sets[frame_in_flight]
	
	rhi.cmd_bind_graphics_pipeline(cb, g_r3d_state.mesh_renderer_state.pipeline)
	rhi.cmd_bind_descriptor_set(cb, g_r3d_state.mesh_renderer_state.pipeline_layout, scene_ds^, MESH_RENDERING_SCENE_DS_IDX)
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

	projection_matrix: Matrix4
	switch p in view_info.projection {
	case Perspective_Projection_Info:
		projection_matrix = linalg.matrix4_infinite_perspective_f32(p.vertical_fov, p.aspect_ratio, p.near_clip_plane, false)
	case Orthographic_Projection_Info:
		bottom_left := view_info.origin.xy - p.view_extents
		top_right   := view_info.origin.xy + p.view_extents
		projection_matrix = linalg.matrix_ortho3d_f32(bottom_left.x, top_right.x, bottom_left.y, top_right.y, 0, p.far_clip_plane, true)
	}

	// Convert from my preferred X-right,Y-forward,Z-up to Vulkan's clip space
	coord_system_matrix := Matrix4{
		1,0, 0,0,
		0,0,-1,0,
		0,1, 0,0,
		0,0, 0,1,
	}
	view_rotation_matrix := linalg.matrix4_inverse_f32(linalg.matrix4_from_euler_angles_zxy_f32(
		view_info.angles.z,
		view_info.angles.x,
		view_info.angles.y,
	))
	view_matrix := view_rotation_matrix * linalg.matrix4_translate_f32(-view_info.origin)
	view_projection_matrix := projection_matrix * coord_system_matrix * view_matrix

	uniforms.vp_matrix = view_projection_matrix
	uniforms.view_origin = vec4(view_info.origin, 0)
	// Rotate a back vector because the matrix is an inverse of the actual view transform
	uniforms.view_direction = view_rotation_matrix * vec4(core.VEC3_BACKWARD, 0)
}

bind_scene_view :: proc(cb: ^RHI_CommandBuffer, scene_view: ^RScene_View) {
	assert(cb != nil)
	assert(scene_view != nil)

	frame_in_flight := rhi.get_frame_in_flight()
	scene_view_ds := &scene_view.descriptor_sets[frame_in_flight]
	
	rhi.cmd_bind_descriptor_set(cb, g_r3d_state.mesh_renderer_state.pipeline_layout, scene_view_ds^, MESH_RENDERING_SCENE_VIEW_DS_IDX)
}

// TEXTURES ---------------------------------------------------------------------------------------------------

// TODO: Automatically(?) creating & storing Descriptor Sets for different layouts
RTexture_2D :: struct {
	texture_2d: Texture_2D,
	// TODO: Make a global sampler cache
	sampler: RHI_Sampler,
	descriptor_set: RHI_DescriptorSet,
}

create_texture_2d :: proc(image_data: []byte, dimensions: [2]u32, format: rhi.Format, filter: rhi.Filter, descriptor_set_layout: rhi.RHI_DescriptorSetLayout) -> (texture: RTexture_2D, result: RHI_Result) {
	texture.texture_2d = rhi.create_texture_2d(image_data, dimensions, format) or_return

	// TODO: Make a global sampler cache
	texture.sampler = rhi.create_sampler(texture.texture_2d.mip_levels, filter) or_return

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
			layout = g_r3d_state.mesh_renderer_state.material_descriptor_set_layout,
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
	pipeline: rhi.RHI_Pipeline,
	pipeline_layout: rhi.RHI_PipelineLayout,
	model_descriptor_set_layout: rhi.RHI_DescriptorSetLayout,
	material_descriptor_set_layout: rhi.RHI_DescriptorSetLayout,
}

Mesh_Vertex :: struct {
	position: Vec3,
	normal: Vec3,
	tex_coord: Vec2,
}

RMesh :: struct {
	vertex_buffer: Vertex_Buffer,
	index_buffer: Index_Buffer,
}

// Mesh vertices format must adhere to the ones provided in pipelines that will use the created mesh
create_mesh :: proc(vertices: []$V, indices: []u32) -> (mesh: RMesh, result: RHI_Result) {
	// Create the Vertex Buffer
	vb_desc := rhi.Buffer_Desc{
		memory_flags = {.DEVICE_LOCAL},
	}
	mesh.vertex_buffer = rhi.create_vertex_buffer(vb_desc, vertices) or_return

	// Create the Index Buffer
	ib_desc := rhi.Buffer_Desc{
		memory_flags = {.DEVICE_LOCAL},
	}
	mesh.index_buffer = rhi.create_index_buffer(indices) or_return

	return
}

destroy_mesh :: proc(mesh: ^RMesh) {
	rhi.destroy_buffer(&mesh.vertex_buffer)
	rhi.destroy_buffer(&mesh.index_buffer)
}

GLTF_Err_Data :: cgltf.result
GLTF_Result   :: #type core.Result(GLTF_Err_Data)
GLTF_Error    :: #type core.Error(GLTF_Err_Data)

GLTF_Mesh :: struct {
	vertices: []Mesh_Vertex,
	indices: []u32,
}

import_mesh_gltf :: proc(path: string, allocator := context.allocator) -> (gltf_mesh: GLTF_Mesh, result: GLTF_Result) {
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
		if r = cgltf.validate(data); r !=.success {
			result = core.error_make_as(GLTF_Error, r, "Could not validate the data from the glTF file '%s'.", path)
			return
		}
	}

	if len(data.meshes) != 1 {
		return
	}

	mesh := &data.meshes[0]
	if len(mesh.primitives) != 1 {
		return
	}

	primitive := &mesh.primitives[0]
	index_count := primitive.indices.count
	if index_count < 1 {
		return
	}

	gltf_mesh.indices = make([]u32, index_count, allocator)
	invert_winding := true
	assert(!invert_winding || index_count % 3 == 0)
	for i in 0..<int(index_count) {
		v_in_tri := i % 3
		v_offset := v_in_tri if v_in_tri < 2 else -1
		gltf_mesh.indices[i+v_offset] = cast(u32)cgltf.accessor_read_index(primitive.indices, cast(uint)i)
	}

	vertex_count: uint
	for attribute in primitive.attributes {
		// Find position
		#partial switch attribute.type {
		case .position:
			if gltf_mesh.vertices == nil {
				vertex_count = attribute.data.count
				// TODO: Support for different vertex formats
				gltf_mesh.vertices = make([]Mesh_Vertex, vertex_count, allocator)
			}
			for i in 0..<vertex_count {
				vertex := &gltf_mesh.vertices[i]
				if !cgltf.accessor_read_float(attribute.data, i, &vertex.position[0], len(vertex.position)) {
					log.warn("Failed to read the position of vertex", i, "from the model.")
				}
			}
		case .normal:
			if gltf_mesh.vertices == nil {
				vertex_count = attribute.data.count
				gltf_mesh.vertices = make([]Mesh_Vertex, vertex_count, allocator)
			}
			for i in 0..<vertex_count {
				vertex := &gltf_mesh.vertices[i]
				if !cgltf.accessor_read_float(attribute.data, i, &vertex.normal[0], len(vertex.normal)) {
					log.warn("Failed to read the normal of vertex", i, "from the model.")
				}
			}
		case .texcoord:
			if gltf_mesh.vertices == nil {
				vertex_count = attribute.data.count
				gltf_mesh.vertices = make([]Mesh_Vertex, vertex_count, allocator)
			}
			for i in 0..<vertex_count {
				vertex := &gltf_mesh.vertices[i]
				if !cgltf.accessor_read_float(attribute.data, i, &vertex.tex_coord[0], len(vertex.tex_coord)) {
					log.warn("Failed to read the tex coord of vertex", i, "from the model.")
				}
			}
		}
	}

	return
}

destroy_gltf_mesh :: proc(gltf_mesh: ^GLTF_Mesh, allocator := context.allocator) {
	assert(gltf_mesh != nil)
	if gltf_mesh.vertices != nil {
		delete(gltf_mesh.vertices, allocator)
	}
	if gltf_mesh.indices != nil {
		delete(gltf_mesh.indices, allocator)
	}
}

Model_Uniforms :: struct {
	model_matrix: Matrix4,
	inverse_transpose_matrix: Matrix4,
	mvp_matrix: Matrix4,
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

create_model :: proc(mesh: ^RMesh) -> (model: RModel, result: RHI_Result) {
	// Create buffers and descriptor sets
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		model.uniforms[i] = rhi.create_uniform_buffer(Model_Uniforms) or_return
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
update_model_uniforms :: proc(scene_view: ^RScene_View, model: ^RModel) {
	assert(scene_view != nil)
	assert(model != nil)

	frame_in_flight := rhi.get_frame_in_flight()
	ub := &model.uniforms[frame_in_flight]
	uniforms := rhi.cast_mapped_buffer_memory_single(Model_Uniforms, ub.mapped_memory)

	scale_matrix := linalg.matrix4_scale_f32(model.data.scale)
	rot := model.data.rotation
	rotation_matrix := linalg.matrix4_from_euler_angles_zxy_f32(rot.z, rot.x, rot.y)
	translation_matrix := linalg.matrix4_translate_f32(model.data.location)

	uniforms.model_matrix = translation_matrix * rotation_matrix * scale_matrix
	if model.data.scale.x == model.data.scale.y && model.data.scale.x == model.data.scale.z {
		uniforms.inverse_transpose_matrix = uniforms.model_matrix
	} else {
		model_mat_3x3 := cast(Matrix3)uniforms.model_matrix
		uniforms.inverse_transpose_matrix = cast(Matrix4)linalg.matrix3_inverse_transpose_f32(model_mat_3x3)
	}

	sv_uniforms := rhi.cast_mapped_buffer_memory_single(Scene_View_Uniforms, scene_view.uniforms[frame_in_flight].mapped_memory)
	uniforms.mvp_matrix = sv_uniforms.vp_matrix * uniforms.model_matrix
}

draw_model :: proc(cb: ^RHI_CommandBuffer, model: ^RModel, material: ^RMaterial) {
	assert(cb != nil)
	assert(model != nil)
	assert(model.mesh != nil)

	frame_in_flight := rhi.get_frame_in_flight()

	rhi.cmd_bind_vertex_buffer(cb, model.mesh.vertex_buffer)
	rhi.cmd_bind_index_buffer(cb, model.mesh.index_buffer)
	rhi.cmd_bind_descriptor_set(cb, g_r3d_state.mesh_renderer_state.pipeline_layout, model.descriptor_sets[frame_in_flight], MESH_RENDERING_MODEL_DS_IDX)
	// TODO: What if there is no texture
	rhi.cmd_bind_descriptor_set(cb, g_r3d_state.mesh_renderer_state.pipeline_layout, material.descriptor_sets[frame_in_flight], MESH_RENDERING_MATERIAL_DS_IDX)

	rhi.cmd_draw_indexed(cb, model.mesh.index_buffer.index_count)
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
				format = .D24S8,
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
	g_r3d_state.depth_texture = rhi.create_depth_texture(swapchain_dims, .D24S8) or_return

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
		max_sets = MAX_SAMPLERS + (MAX_SCENES + MAX_SCENE_VIEWS + MAX_MODELS + MAX_MATERIALS) * MAX_FRAMES_IN_FLIGHT,
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
		g_r3d_state.quad_renderer_state.sampler = rhi.create_sampler(1, .NEAREST) or_return
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

	// SETUP MESH RENDERING ---------------------------------------------------------------------------------------------------------------------
	{
		// Create basic 3D shaders
		basic_vsh := rhi.create_vertex_shader(core.path_make_engine_shader_relative(MESH_SHADER_VERT)) or_return
		defer rhi.destroy_shader(&basic_vsh)
		basic_fsh := rhi.create_vertex_shader(core.path_make_engine_shader_relative(MESH_SHADER_FRAG)) or_return
		defer rhi.destroy_shader(&basic_fsh)
	
		dsl_desc: rhi.Descriptor_Set_Layout_Description

		// Make a descriptor set layout for model uniforms
		dsl_desc = rhi.Descriptor_Set_Layout_Description{
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
	
		// Make a descriptor set layout for mesh materials
		dsl_desc = rhi.Descriptor_Set_Layout_Description{
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
		g_r3d_state.mesh_renderer_state.material_descriptor_set_layout = rhi.create_descriptor_set_layout(dsl_desc) or_return
	
		// Make a pipeline layout for mesh rendering
		test_pipeline_layout_desc := rhi.Pipeline_Layout_Description{
			descriptor_set_layouts = {
				// Keep in the same order as MESH_RENDERING_..._IDX constants
				&g_r3d_state.scene_descriptor_set_layout,
				&g_r3d_state.scene_view_descriptor_set_layout,
				&g_r3d_state.mesh_renderer_state.model_descriptor_set_layout,
				&g_r3d_state.mesh_renderer_state.material_descriptor_set_layout,
			},
		}
		g_r3d_state.mesh_renderer_state.pipeline_layout = rhi.create_pipeline_layout(test_pipeline_layout_desc) or_return
	
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
				{type = .VERTEX,   shader = &basic_vsh.shader},
				{type = .FRAGMENT, shader = &basic_fsh.shader},
			},
		}
		g_r3d_state.mesh_renderer_state.pipeline = rhi.create_graphics_pipeline(mesh_pipeline_desc, g_r3d_state.main_render_pass.render_pass, g_r3d_state.mesh_renderer_state.pipeline_layout) or_return
	}

	// Allocate global cmd buffers
	g_r3d_state.cmd_buffers = rhi.allocate_command_buffers(MAX_FRAMES_IN_FLIGHT) or_return

	g_r3d_state.base_to_debug_semaphores = rhi.create_semaphores() or_return

	return nil
}

@(private)
shutdown_rhi :: proc() {
	rhi.wait_for_device()

	// Destroy mesh rendering
	rhi.destroy_graphics_pipeline(&g_r3d_state.mesh_renderer_state.pipeline)
	rhi.destroy_pipeline_layout(&g_r3d_state.mesh_renderer_state.pipeline_layout)
	rhi.destroy_descriptor_set_layout(&g_r3d_state.mesh_renderer_state.material_descriptor_set_layout)
	rhi.destroy_descriptor_set_layout(&g_r3d_state.mesh_renderer_state.model_descriptor_set_layout)
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
	g_r3d_state.depth_texture, r = rhi.create_depth_texture(args.new_dimensions, .D24S8)
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

	scene_descriptor_set_layout: rhi.RHI_DescriptorSetLayout,
	scene_view_descriptor_set_layout: rhi.RHI_DescriptorSetLayout,

	main_render_pass: Renderer3D_RenderPass,
	depth_texture: Texture_2D,

	descriptor_pool: RHI_DescriptorPool,
	cmd_buffers: [MAX_FRAMES_IN_FLIGHT]RHI_CommandBuffer,

	base_to_debug_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
}
// TODO: Would be better if this was passed around as a context instead of a global variable
g_r3d_state: Renderer3D_State
