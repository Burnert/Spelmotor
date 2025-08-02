package renderer

import "base:runtime"
import "core:fmt"
import "core:image/png"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import os "core:os/os2"
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
Result :: union { Error, rhi.Error }

QUAD_SHADER_VERT :: "3d/quad.vert"
QUAD_SHADER_FRAG :: "3d/quad.frag"

MESH_SHADER_VERT :: "3d/basic.vert"
MESH_SHADER_FRAG :: "3d/basic.frag"

INSTANCED_MESH_SHADER_VERT :: "3d/basic_instanced.vert"
INSTANCED_MESH_SHADER_FRAG :: "3d/basic_instanced.frag"

TERRAIN_SHADER_VERT :: "3d/terrain.vert"
TERRAIN_SHADER_FRAG :: "3d/terrain.frag"
TERRAIN_DEBUG_SHADER_FRAG :: "3d/terrain_dbg.frag"

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

init_scene_rhi :: proc() -> rhi.Result {
	// Make a descriptor set layout for scene uniforms
	scene_layout_desc := rhi.Descriptor_Set_Layout_Description{
		bindings = {
			// Scene binding
			rhi.Descriptor_Set_Layout_Binding{
				binding = 0,
				count = 1,
				shader_stage = {.Vertex, .Fragment},
				type = .Uniform_Buffer,
			},
		},
	}
	g_renderer.scene_descriptor_set_layout = rhi.create_descriptor_set_layout(scene_layout_desc) or_return

	// Make a descriptor set layout for scene view uniforms
	scene_view_layout_desc := rhi.Descriptor_Set_Layout_Description{
		bindings = {
			// Scene view binding
			rhi.Descriptor_Set_Layout_Binding{
				binding = 0,
				count = 1,
				shader_stage = {.Vertex, .Fragment},
				type = .Uniform_Buffer,
			},
		},
	}
	g_renderer.scene_view_descriptor_set_layout = rhi.create_descriptor_set_layout(scene_view_layout_desc) or_return

	return nil
}

shutdown_scene_rhi :: proc() {
	rhi.destroy_descriptor_set_layout(&g_renderer.scene_view_descriptor_set_layout)
	rhi.destroy_descriptor_set_layout(&g_renderer.scene_descriptor_set_layout)
}

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

Scene :: struct {
	lights: [dynamic]Light_Info,
	ambient_light: Vec3,

	uniforms: [MAX_FRAMES_IN_FLIGHT]rhi.Buffer,
	descriptor_sets: [MAX_FRAMES_IN_FLIGHT]RHI_Descriptor_Set,
}

create_scene :: proc() -> (scene: Scene, result: rhi.Result) {
	// Create scene uniform buffers
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		ub_desc := rhi.Buffer_Desc{
			memory_flags = {.Device_Local, .Host_Coherent, .Host_Visible},
		}
		ub_name := fmt.tprintf("UBO_Scene-%i", i)
		scene.uniforms[i] = rhi.create_uniform_buffer(ub_desc, Scene_Uniforms, ub_name) or_return
		
		// Create buffer descriptors
		scene_set_desc := rhi.Descriptor_Set_Desc{
			layout = g_renderer.scene_descriptor_set_layout,
			descriptors = {
				rhi.Descriptor_Desc{
					type = .Uniform_Buffer,
					binding = 0,
					count = 1,
					info = rhi.Descriptor_Buffer_Info{
						buffer = &scene.uniforms[i].rhi_buffer,
						size = size_of(Scene_Uniforms),
						offset = 0,
					},
				},
			},
		}
		ds_name := fmt.tprintf("DS_Scene-%i", i)
		scene.descriptor_sets[i] = rhi.create_descriptor_set(g_renderer.descriptor_pool, scene_set_desc, ds_name) or_return
	}

	return
}

destroy_scene :: proc(scene: ^Scene) {
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

update_scene_uniforms :: proc(scene: ^Scene) {
	assert(scene != nil)
	assert(g_rhi != nil)
	frame_in_flight := g_rhi.frame_in_flight
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

bind_scene :: proc(cb: ^RHI_Command_Buffer, scene: ^Scene, layout: RHI_Pipeline_Layout) {
	assert(cb != nil)
	assert(scene != nil)

	assert(g_rhi != nil)
	frame_in_flight := g_rhi.frame_in_flight
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

Scene_View :: struct {
	view_info: View_Info,

	uniforms: [MAX_FRAMES_IN_FLIGHT]rhi.Buffer,
	descriptor_sets: [MAX_FRAMES_IN_FLIGHT]RHI_Descriptor_Set,
}

create_scene_view :: proc(name := "") -> (scene_view: Scene_View, result: rhi.Result) {
	// Create scene view uniform buffers
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		ub_desc := rhi.Buffer_Desc{
			memory_flags = {.Device_Local, .Host_Coherent, .Host_Visible},
		}
		ub_name := fmt.tprintf("UBO_%s-%i", name, i)
		scene_view.uniforms[i] = rhi.create_uniform_buffer(ub_desc, Scene_View_Uniforms, ub_name) or_return
		
		// Create buffer descriptors
		scene_view_set_desc := rhi.Descriptor_Set_Desc{
			layout = g_renderer.scene_descriptor_set_layout,
			descriptors = {
				rhi.Descriptor_Desc{
					type = .Uniform_Buffer,
					binding = 0,
					count = 1,
					info = rhi.Descriptor_Buffer_Info{
						buffer = &scene_view.uniforms[i].rhi_buffer,
						size = size_of(Scene_View_Uniforms),
						offset = 0,
					},
				},
			},
		}
		ds_name := fmt.tprintf("DS_%s-%i", name, i)
		scene_view.descriptor_sets[i] = rhi.create_descriptor_set(g_renderer.descriptor_pool, scene_view_set_desc, ds_name) or_return
	}

	return
}

destroy_scene_view :: proc(scene_view: ^Scene_View) {
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

update_scene_view_uniforms :: proc(scene_view: ^Scene_View) {
	assert(scene_view != nil)
	assert(g_rhi != nil)
	frame_in_flight := g_rhi.frame_in_flight
	ub := &scene_view.uniforms[frame_in_flight]
	uniforms := rhi.cast_mapped_buffer_memory_single(Scene_View_Uniforms, ub.mapped_memory)

	view_info := &scene_view.view_info

	view_rotation_matrix, _, view_projection_matrix := calculate_view_matrices(view_info^)

	uniforms.vp_matrix = view_projection_matrix
	uniforms.view_origin = vec4(view_info.origin, 0)
	// Rotate a back vector because the matrix is an inverse of the actual view transform
	uniforms.view_direction = view_rotation_matrix * vec4(core.VEC3_BACKWARD, 0)
}

bind_scene_view :: proc(cb: ^RHI_Command_Buffer, scene_view: ^Scene_View, layout: RHI_Pipeline_Layout) {
	assert(cb != nil)
	assert(scene_view != nil)

	assert(g_rhi != nil)
	frame_in_flight := g_rhi.frame_in_flight
	scene_view_ds := &scene_view.descriptor_sets[frame_in_flight]
	
	rhi.cmd_bind_descriptor_set(cb, layout, scene_view_ds^, GLOBAL_SCENE_VIEW_DS_IDX)
}

// TEXTURES ---------------------------------------------------------------------------------------------------

// TODO: Automatically(?) creating & storing Descriptor Sets for different layouts
Combined_Texture_Sampler :: struct {
	texture: rhi.Texture,
	// TODO: Make a global sampler cache
	sampler: RHI_Sampler,
	// TODO: Store multiple descriptor sets
	descriptor_set: RHI_Descriptor_Set,
}

create_combined_texture_sampler :: proc(image_data: []byte, dimensions: [2]u32, format: rhi.Format, filter: rhi.Filter, address_mode: rhi.Address_Mode, descriptor_set_layout: rhi.RHI_Descriptor_Set_Layout, name := "") -> (texture: Combined_Texture_Sampler, result: rhi.Result) {
	texture.texture = rhi.create_texture_2d(image_data, dimensions, format, name) or_return

	// TODO: Make a global sampler cache
	texture.sampler = rhi.create_sampler(texture.texture.mip_levels, filter, address_mode) or_return

	descriptor_set_desc := rhi.Descriptor_Set_Desc{
		descriptors = {
			rhi.Descriptor_Desc{
				binding = 0,
				count = 1,
				type = .Combined_Image_Sampler,
				info = rhi.Descriptor_Texture_Info{
					texture = &texture.texture.rhi_texture,
					sampler = &texture.sampler,
				},
			},
		},
		layout = descriptor_set_layout,
	}
	ds_name := fmt.tprintf("DS_%s", name)
	texture.descriptor_set = rhi.create_descriptor_set(g_renderer.descriptor_pool, descriptor_set_desc, ds_name) or_return

	return
}

create_combined_texture_sampler_from_asset :: proc(asset: core.Asset_Ref(Texture_Asset), descriptor_set_layout: rhi.RHI_Descriptor_Set_Layout) -> (texture: Combined_Texture_Sampler, result: rhi.Result) {
	assert(core.asset_ref_is_valid(asset))

	import_path := core.asset_resolve_relative_path(asset.entry^, asset.data.import_path, context.temp_allocator)
	_, ext := os.split_filename(import_path)

	// TODO: All the temporary data like this png.Image could be allocated using a shared temporary scratch buffer or something when batch loading multiple assets.
	img: ^png.Image
	defer if img != nil do png.destroy(img)

	image_data: []byte
	dims: [2]u32
	format: rhi.Format

	switch ext {
	case "png":
		err: png.Error
		img, err = png.load(import_path, png.Options{.alpha_add_if_missing})

		assert(err == nil)
		assert(img.depth == 8, "PNG bit depth must be 8.")
		assert(img.channels == 4, "Loaded image channels must be 4.")

		image_data = img.pixels.buf[:]
		dims = linalg.array_cast([2]int{img.width, img.height}, u32)
		switch img.channels {
		case 1:
			if asset.data.srgb {
				panic("Unsupported texture format.")
			} else {
				format = .R8
			}
		case 3:
			if asset.data.srgb {
				format = .RGB8_Srgb
			} else {
				panic("Unsupported texture format.")
			}
		case 4:
			if asset.data.srgb {
				format = .RGBA8_Srgb
			} else {
				panic("Unsupported texture format.")
			}
		case: panic("Unsupported texture format.")
		}

	case: panic(fmt.tprintf("Texture asset source format '%s' unsupported.", ext))
	}

	return create_combined_texture_sampler(image_data, dims, format, asset.data.filter, asset.data.address_mode, descriptor_set_layout, asset.entry.path.str)
}

get_combined_texture_sampler_from_asset :: proc(asset: core.Asset_Ref(Texture_Asset), descriptor_set_layout: rhi.RHI_Descriptor_Set_Layout) -> (texture: ^Combined_Texture_Sampler, result: rhi.Result) {
	rd := core.asset_runtime_data_cast(asset.entry, Texture_Asset_Runtime_Data)
	if rd.combined_sampler.texture.rhi_texture == nil {
		// FIXME: Currently there is no way to get a texture with a different descriptor set if one has already been created with this procedure.
		rd.combined_sampler = create_combined_texture_sampler_from_asset(asset, descriptor_set_layout) or_return
	}

	texture = &rd.combined_sampler
	return
}

destroy_combined_texture_sampler :: proc(tex: ^Combined_Texture_Sampler) {
	// TODO: Release descriptors
	rhi.destroy_texture(&tex.texture)
	rhi.destroy_sampler(&tex.sampler)
}

Texture_Group :: enum {
	World,
}

Texture_Asset :: struct {
	import_path: string,
	dims: [2]u32,
	channels: u32,
	filter: rhi.Filter,
	address_mode: rhi.Address_Mode,
	srgb: bool,
	group: Texture_Group,
}

Texture_Asset_Runtime_Data :: struct {
	// FIXME: This needs to be released on shutdown before the device is destroyed
	// TODO: This also needs to eventually be streamable or at least manually unloadable.
	combined_sampler: Combined_Texture_Sampler,
}

texture_asset_deleter :: proc(data: rawptr, allocator: runtime.Allocator) {
	data := cast(^Texture_Asset)data
	delete(data.import_path)
}

// MATERIALS ---------------------------------------------------------------------------------------------------

init_material_rhi :: proc() -> rhi.Result {
	// Make a descriptor set layout for materials
	material_dsl_desc := rhi.Descriptor_Set_Layout_Description{
		bindings = {
			// Texture sampler
			rhi.Descriptor_Set_Layout_Binding{
				binding = 0,
				count = 1,
				shader_stage = {.Fragment},
				type = .Combined_Image_Sampler,
			},
			// Material uniforms
			rhi.Descriptor_Set_Layout_Binding{
				binding = 1,
				count = 1,
				shader_stage = {.Fragment},
				type = .Uniform_Buffer,
			},
		},
	}
	g_renderer.material_descriptor_set_layout = rhi.create_descriptor_set_layout(material_dsl_desc) or_return

	return nil
}

shutdown_material_rhi :: proc() {
	rhi.destroy_descriptor_set_layout(&g_renderer.material_descriptor_set_layout)
}

Material_Uniforms :: struct {
	specular: f32,
	specular_hardness: f32,
}

Material :: struct {
	texture: ^Combined_Texture_Sampler,

	specular: f32,
	specular_hardness: f32,

	uniforms: [rhi.MAX_FRAMES_IN_FLIGHT]rhi.Buffer,
	descriptor_sets: [rhi.MAX_FRAMES_IN_FLIGHT]rhi.RHI_Descriptor_Set,
}

create_material :: proc(texture: ^Combined_Texture_Sampler, name := "") -> (material: Material, result: rhi.Result) {
	assert(texture != nil)
	// TODO: Static/Dynamic material types - only dynamic needs multiple uniform buffers in flight
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		ub_desc := rhi.Buffer_Desc{
			memory_flags = {.Device_Local, .Host_Coherent, .Host_Visible},
		}
		ub_name := fmt.tprintf("UBO_%s-%i", name, i)
		material.uniforms[i] = rhi.create_uniform_buffer(ub_desc, Material_Uniforms, ub_name) or_return

		descriptor_set_desc := rhi.Descriptor_Set_Desc{
			descriptors = {
				// Texture sampler
				rhi.Descriptor_Desc{
					binding = 0,
					count = 1,
					type = .Combined_Image_Sampler,
					info = rhi.Descriptor_Texture_Info{
						texture = &texture.texture.rhi_texture,
						sampler = &texture.sampler,
					},
				},
				// Material uniforms
				rhi.Descriptor_Desc{
					binding = 1,
					count = 1,
					type = .Uniform_Buffer,
					info = rhi.Descriptor_Buffer_Info{
						buffer = &material.uniforms[i].rhi_buffer,
						size = size_of(Material_Uniforms),
						offset = 0,
					},
				},
			},
			layout = g_renderer.material_descriptor_set_layout,
		}
		ds_name := fmt.tprintf("DS_%s-%i", name, i)
		material.descriptor_sets[i] = rhi.create_descriptor_set(g_renderer.descriptor_pool, descriptor_set_desc, ds_name) or_return
	}

	return
}

create_material_from_asset :: proc(asset: core.Asset_Ref(Material_Asset)) -> (material: Material, result: rhi.Result) {
	assert(core.asset_ref_is_valid(asset))

	texture_ref := core.asset_ref_resolve(asset.data.texture, Texture_Asset)
	if !core.asset_ref_is_valid(texture_ref) {
		// TODO: Use a "missing" texture.
		result = core.error_make_as(rhi.Error, 0, "Failed to load texture '%s'.", asset.data.texture)
		return
	}

	combined_sampler := get_combined_texture_sampler_from_asset(texture_ref, g_renderer.material_descriptor_set_layout) or_return
	material = create_material(combined_sampler, asset.entry.path.str) or_return
	material.specular = asset.data.specular
	material.specular_hardness = asset.data.specular_hardness
	return
}

get_material_from_asset :: proc(asset: core.Asset_Ref(Material_Asset)) -> (material: ^Material, result: rhi.Result) {
	rd := core.asset_runtime_data_cast(asset.entry, Material_Asset_Runtime_Data)
	if !rd.is_material_valid {
		// FIXME: Currently there is no way to get a texture with a different descriptor set if one has already been created with this procedure.
		rd.material = create_material_from_asset(asset) or_return
		rd.is_material_valid = true
	}

	material = &rd.material
	return
}

destroy_material :: proc(material: ^Material) {
	// TODO: Release desc sets
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		rhi.destroy_buffer(&material.uniforms[i])
	}
}

update_material_uniforms :: proc(material: ^Material) {
	assert(material != nil)
	assert(g_rhi != nil)
	frame_in_flight := g_rhi.frame_in_flight
	ub := &material.uniforms[frame_in_flight]
	uniforms := rhi.cast_mapped_buffer_memory_single(Material_Uniforms, ub.mapped_memory)

	uniforms.specular = material.specular
	uniforms.specular_hardness = material.specular_hardness
}

// TODO: these fields are repeated multiple times everywhere
// eventually all of them would have to be dynamic based on the fields from the reflected shader
Material_Asset :: struct {
	specular: f32,
	specular_hardness: f32,

	texture: string,
}

Material_Asset_Runtime_Data :: struct {
	// FIXME: This needs to be released on shutdown before the device is destroyed
	// TODO: This also needs to eventually be streamable or at least manually unloadable.
	material: Material,
	is_material_valid: bool,
}

material_asset_deleter :: proc(data: rawptr, allocator: runtime.Allocator) {
	data := cast(^Material_Asset)data
	delete(data.texture, allocator)
}

// MESHES & MODELS ---------------------------------------------------------------------------------------------

init_mesh_rhi :: proc() -> rhi.Result {
	// Create basic 3D shaders
	g_renderer.mesh_renderer_state.vsh = rhi.create_vertex_shader(core.path_make_engine_shader_relative(MESH_SHADER_VERT)) or_return
	g_renderer.mesh_renderer_state.fsh = rhi.create_fragment_shader(core.path_make_engine_shader_relative(MESH_SHADER_FRAG)) or_return

	// Make a descriptor set layout for model uniforms
	dsl_desc := rhi.Descriptor_Set_Layout_Description{
		bindings = {
			// Model constants (per draw call)
			rhi.Descriptor_Set_Layout_Binding{
				binding = 0,
				count = 1,
				shader_stage = {.Vertex, .Fragment},
				type = .Uniform_Buffer,
			},
		},
	}
	g_renderer.mesh_renderer_state.model_descriptor_set_layout = rhi.create_descriptor_set_layout(dsl_desc) or_return

	// Make a pipeline layout for mesh rendering
	pl_desc := rhi.Pipeline_Layout_Description{
		descriptor_set_layouts = {
			// Keep in the same order as MESH_RENDERING_..._IDX constants
			&g_renderer.scene_descriptor_set_layout,
			&g_renderer.scene_view_descriptor_set_layout,
			&g_renderer.mesh_renderer_state.model_descriptor_set_layout,
			&g_renderer.material_descriptor_set_layout,
		},
		push_constants = {
			rhi.Push_Constant_Range{
				offset = 0,
				size = size_of(Model_Push_Constants),
				shader_stage = {.Vertex},
			},
		},
	}
	g_renderer.mesh_renderer_state.pipeline_layout = rhi.create_pipeline_layout(pl_desc) or_return

	return nil
}

shutdown_mesh_rhi :: proc() {
	rhi.destroy_descriptor_set_layout(&g_renderer.mesh_renderer_state.model_descriptor_set_layout)
	rhi.destroy_pipeline_layout(&g_renderer.mesh_renderer_state.pipeline_layout)
	rhi.destroy_shader(&g_renderer.mesh_renderer_state.vsh)
	rhi.destroy_shader(&g_renderer.mesh_renderer_state.fsh)
}

Mesh_Renderer_State :: struct {
	vsh: rhi.Vertex_Shader,
	fsh: rhi.Fragment_Shader,
	pipeline_layout: rhi.RHI_Pipeline_Layout,
	model_descriptor_set_layout: rhi.RHI_Descriptor_Set_Layout,
}

Mesh_Vertex :: struct {
	position:  Vec3 `gltf:"position"`,
	normal:    Vec3 `gltf:"normal"`,
	tex_coord: Vec2 `gltf:"texcoord"`,
}

Primitive :: struct {
	vertex_buffer: rhi.Buffer,
	index_buffer: rhi.Buffer,
}

// Primitive vertices format must adhere to the ones provided in pipelines that will use the created primitive
create_primitive :: proc(vertices: []$V, indices: []u32, name := "") -> (primitive: Primitive, result: rhi.Result) {
	// Create the Vertex Buffer
	vb_desc := rhi.Buffer_Desc{
		memory_flags = {.Device_Local},
	}
	vb_name := fmt.tprintf("VBO_%s", name)
	primitive.vertex_buffer = rhi.create_vertex_buffer(vb_desc, vertices, vb_name) or_return

	// Create the Index Buffer
	ib_desc := rhi.Buffer_Desc{
		memory_flags = {.Device_Local},
	}
	ib_name := fmt.tprintf("IBO_%s", name)
	primitive.index_buffer = rhi.create_index_buffer(ib_desc, indices, ib_name) or_return

	return
}

destroy_primitive :: proc(primitive: ^Primitive) {
	rhi.destroy_buffer(&primitive.vertex_buffer)
	rhi.destroy_buffer(&primitive.index_buffer)
}

Mesh :: struct {
	primitives: [dynamic]Primitive,
}

// Mesh vertices format must adhere to the ones provided in pipelines that will use the created mesh
create_mesh :: proc(primitives: []^Primitive, allocator := context.allocator) -> (mesh: Mesh, result: rhi.Result) {
	mesh.primitives = make([dynamic]Primitive, len(primitives), allocator)
	for &p, i in mesh.primitives {
		p = primitives[i]^
	}
	return
}

// Only creates the mesh render resource from the specified asset
create_mesh_from_asset :: proc(asset: core.Asset_Ref(Static_Mesh_Asset), allocator := context.allocator) -> (mesh: Mesh, result: rhi.Result) {
	assert(core.asset_ref_is_valid(asset))

	// TODO: Add more formats (mainly the optimized binary one)
	import_path := core.asset_resolve_relative_path(asset.entry^, asset.data.import_path, context.temp_allocator)
	_, ext := os.split_filename(import_path)

	primitives: []Primitive

	switch ext {
	case "glb":
		gltf_config := core.gltf_make_config_from_vertex(Mesh_Vertex)
		gltf_mesh, gltf_res := core.import_mesh_gltf(import_path, Mesh_Vertex, gltf_config)
		defer core.destroy_gltf_mesh(&gltf_mesh)
		core.result_verify(gltf_res)

		primitives = make([]Primitive, len(gltf_mesh.primitives), context.temp_allocator)
		for p, i in gltf_mesh.primitives {
			primitives[i] = create_primitive(p.vertices, p.indices, p.name) or_return
		}

	case: panic(fmt.tprintf("Static Mesh asset source format '%s' unsupported.", ext))
	}

	prim_ptrs := make([]^Primitive, len(primitives), context.temp_allocator)
	for &p, i in primitives do prim_ptrs[i] = &p

	return create_mesh(prim_ptrs, allocator)
}

// Gets a cached mesh render resource from the asset's runtime data or creates it if it doesn't exist.
// This is the preferred way to retrieve render resources from assets.
get_mesh_from_asset :: proc(asset: core.Asset_Ref(Static_Mesh_Asset)) -> (mesh: ^Mesh, result: rhi.Result) {
	rd := core.asset_runtime_data_cast(asset.entry, Static_Mesh_Asset_Runtime_Data)
	if len(rd.mesh.primitives) == 0 {
		rd.mesh = create_mesh_from_asset(asset, core.asset_registry_get_allocator()) or_return
	}

	mesh = &rd.mesh
	return
}

destroy_mesh :: proc(mesh: ^Mesh) {
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
	using trs: Transform,
}

Model :: struct {
	mesh: ^Mesh,
	data: Model_Data,
	uniforms: [rhi.MAX_FRAMES_IN_FLIGHT]rhi.Buffer,
	descriptor_sets: [rhi.MAX_FRAMES_IN_FLIGHT]rhi.RHI_Descriptor_Set,
}

create_model :: proc(mesh: ^Mesh, name := "") -> (model: Model, result: rhi.Result) {
	// Create buffers and descriptor sets
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		ub_desc := rhi.Buffer_Desc{
			memory_flags = {.Device_Local, .Host_Coherent, .Host_Visible},
		}
		ub_name := fmt.tprintf("UBO_%s-%i", name, i)
		model.uniforms[i] = rhi.create_uniform_buffer(ub_desc, Model_Uniforms, ub_name) or_return
		set_desc := rhi.Descriptor_Set_Desc{
			descriptors = {
				rhi.Descriptor_Desc{
					type = .Uniform_Buffer,
					binding = 0,
					count = 1,
					info = rhi.Descriptor_Buffer_Info{
						buffer = &model.uniforms[i].rhi_buffer,
						size = size_of(Model_Uniforms),
						offset = 0,
					},
				},
			},
			layout = g_renderer.mesh_renderer_state.model_descriptor_set_layout,
		}
		ds_name := fmt.tprintf("DS_%s-%i", name, i)
		model.descriptor_sets[i] = rhi.create_descriptor_set(g_renderer.descriptor_pool, set_desc, ds_name) or_return
	}

	// Assign the mesh
	model.mesh = mesh

	// Make sure the default scale is 1 and not 0.
	model.data.scale = core.VEC3_ONE

	return
}

destroy_model :: proc(model: ^Model) {
	for i in 0..<rhi.MAX_FRAMES_IN_FLIGHT {
		rhi.destroy_buffer(&model.uniforms[i])
	}
	// TODO: Handle descriptor sets' release
}

Static_Mesh_Group :: enum {
	Default,
	Architecture,
	Prop,
	Detail,
	Foliage,
}

Static_Mesh_Asset :: struct {
	import_path: string,
	group: Static_Mesh_Group,
}

Static_Mesh_Asset_Runtime_Data :: struct {
	// FIXME: This needs to be released on shutdown before the device is destroyed
	// FIXME: This also currently leaks memory because of the allocated dynamic primitives array
	// TODO: This also needs to eventually be streamable or at least manually unloadable.
	mesh: Mesh,
}

static_mesh_asset_deleter :: proc(data: rawptr, allocator: runtime.Allocator) {
	data := cast(^Static_Mesh_Asset)data
	delete(data.import_path, allocator)
}

// Requires a scene view that has already been updated for the current frame, otherwise the data from the previous frame will be used
// TODO: this data should be updated separately for each scene view (precalculated MVP matrix) which is kinda inconvenient
update_model_uniforms :: proc(model: ^Model) {
	assert(model != nil)

	assert(g_rhi != nil)
	frame_in_flight := g_rhi.frame_in_flight
	ub := &model.uniforms[frame_in_flight]
	uniforms := rhi.cast_mapped_buffer_memory_single(Model_Uniforms, ub.mapped_memory)

	uniforms.model_matrix = core.transform_to_matrix4(model.data.trs)
	// Normals don't need to be transformed by an inverse transpose if the scaling is uniform.
	if model.data.scale.x == model.data.scale.y && model.data.scale.x == model.data.scale.z {
		uniforms.inverse_transpose_matrix = uniforms.model_matrix
	} else {
		model_mat_3x3 := cast(Matrix3)uniforms.model_matrix
		uniforms.inverse_transpose_matrix = cast(Matrix4)linalg.matrix3_inverse_transpose_f32(model_mat_3x3)
	}
}

mesh_pipeline_layout :: proc() -> ^RHI_Pipeline_Layout {
	return &g_renderer.mesh_renderer_state.pipeline_layout
}

Mesh_Pipeline_Specializations :: struct {
	lighting_model: Lighting_Model,
}

create_mesh_pipeline :: proc(specializations: Mesh_Pipeline_Specializations) -> (pipeline: RHI_Pipeline, result: rhi.Result) {
	main_window := platform.get_main_window()
	surface_key := rhi.get_surface_key_from_window(main_window)
	swapchain_format := rhi.get_swapchain_image_format(surface_key)

	// Create the pipeline for mesh rendering
	mesh_pipeline_desc := rhi.Pipeline_Description{
		vertex_input = rhi.create_vertex_input_description({
			rhi.Vertex_Input_Type_Desc{rate = .Vertex, type = Mesh_Vertex},
		}, context.temp_allocator),
		input_assembly = {topology = .Triangle_List},
		depth_stencil = {
			depth_test = true,
			depth_write = true,
			depth_compare_op = .Less_Or_Equal,
		},
		shader_stages = {
			{type = .Vertex,   shader = &g_renderer.mesh_renderer_state.vsh.shader, specializations = specializations},
			{type = .Fragment, shader = &g_renderer.mesh_renderer_state.fsh.shader, specializations = specializations},
		},
		color_attachments = {
			rhi.Pipeline_Attachment_Desc{format = swapchain_format},
		},
		depth_stencil_attachment = rhi.Pipeline_Attachment_Desc{format = .D32FS8},
	}
	pipeline = rhi.create_graphics_pipeline(mesh_pipeline_desc, nil, g_renderer.mesh_renderer_state.pipeline_layout) or_return

	return
}

draw_model :: proc(cb: ^RHI_Command_Buffer, model: ^Model, materials: []^Material, scene_view: ^Scene_View) {
	assert(cb != nil)
	assert(model != nil)
	assert(model.mesh != nil)
	assert(len(materials) == len(model.mesh.primitives))

	assert(g_rhi != nil)
	frame_in_flight := g_rhi.frame_in_flight

	rhi.cmd_bind_descriptor_set(cb, g_renderer.mesh_renderer_state.pipeline_layout, model.descriptor_sets[frame_in_flight], MESH_RENDERING_MODEL_DS_IDX)

	// TODO: These matrices could also be stored somewhere else to be easier accessible in this scenario.
	ub := &model.uniforms[frame_in_flight]
	uniforms := rhi.cast_mapped_buffer_memory_single(Model_Uniforms, ub.mapped_memory)
	sv_uniforms := rhi.cast_mapped_buffer_memory_single(Scene_View_Uniforms, scene_view.uniforms[frame_in_flight].mapped_memory)

	model_push_constants := Model_Push_Constants{
		mvp = sv_uniforms.vp_matrix * uniforms.model_matrix,
	}
	rhi.cmd_push_constants(cb, g_renderer.mesh_renderer_state.pipeline_layout, {.Vertex}, &model_push_constants)

	for prim, i in model.mesh.primitives {
		// TODO: What if there is no texture
		rhi.cmd_bind_descriptor_set(cb, g_renderer.mesh_renderer_state.pipeline_layout, materials[i].descriptor_sets[frame_in_flight], MESH_RENDERING_MATERIAL_DS_IDX)

		rhi.cmd_bind_vertex_buffer(cb, prim.vertex_buffer)
		rhi.cmd_bind_index_buffer(cb, prim.index_buffer)
		rhi.cmd_draw_indexed(cb, prim.index_buffer.elem_count)
	}
}

// Instanced models ---------------------------------------------------------------------------------------------

init_instanced_mesh_rhi :: proc() -> rhi.Result {
	// Create basic 3D shaders
	g_renderer.instanced_mesh_renderer_state.vsh = rhi.create_vertex_shader(core.path_make_engine_shader_relative(INSTANCED_MESH_SHADER_VERT)) or_return
	g_renderer.instanced_mesh_renderer_state.fsh = rhi.create_fragment_shader(core.path_make_engine_shader_relative(INSTANCED_MESH_SHADER_FRAG)) or_return

	// Make a pipeline layout for mesh rendering
	pl_desc := rhi.Pipeline_Layout_Description{
		descriptor_set_layouts = {
			// Keep in the same order as INSTANCED_MESH_RENDERING_..._IDX constants
			&g_renderer.scene_descriptor_set_layout,
			&g_renderer.scene_view_descriptor_set_layout,
			&g_renderer.material_descriptor_set_layout,
		},
	}
	g_renderer.instanced_mesh_renderer_state.pipeline_layout = rhi.create_pipeline_layout(pl_desc) or_return

	return nil
}

shutdown_instanced_mesh_rhi :: proc() {
	rhi.destroy_pipeline_layout(&g_renderer.instanced_mesh_renderer_state.pipeline_layout)
	rhi.destroy_shader(&g_renderer.instanced_mesh_renderer_state.vsh)
	rhi.destroy_shader(&g_renderer.instanced_mesh_renderer_state.fsh)
}

Instanced_Mesh_Renderer_State :: struct {
	vsh: rhi.Vertex_Shader,
	fsh: rhi.Fragment_Shader,
	pipeline_layout: rhi.RHI_Pipeline_Layout,
}

Mesh_Instance :: struct {
	model_matrix: Matrix4,
	inverse_transpose_matrix: Matrix4,
}

Instanced_Model :: struct {
	mesh: ^Mesh,
	data: [dynamic]Model_Data,
	instance_buffers: [MAX_FRAMES_IN_FLIGHT]rhi.Buffer,
}

create_instanced_model :: proc(mesh: ^Mesh, instance_count: uint, name := "") -> (model: Instanced_Model, result: rhi.Result) {
	// Create instance buffers
	buffer_desc := rhi.Buffer_Desc{
		memory_flags = {.Host_Coherent, .Host_Visible},
	}
	for &b, i in model.instance_buffers {
		vb_name := fmt.tprintf("InstanceVBO_%s-%i", name, i)
		b = rhi.create_vertex_buffer_empty(buffer_desc, Mesh_Instance, instance_count, vb_name, map_memory=true) or_return
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

destroy_instanced_model :: proc(model: ^Instanced_Model) {
	for &buf in model.instance_buffers {
		rhi.destroy_buffer(&buf)
	}
	delete(model.data)
}

update_model_instance_buffer :: proc(model: ^Instanced_Model) {
	assert(model != nil)

	assert(g_rhi != nil)
	frame_in_flight := g_rhi.frame_in_flight
	ib := &model.instance_buffers[frame_in_flight]
	instances := rhi.cast_mapped_buffer_memory(Mesh_Instance, ib.mapped_memory)

	for d, i in model.data {
		instance := &instances[i]

		instance.model_matrix = core.transform_to_matrix4(d.trs)
		// Normals don't need to be transformed by an inverse transpose if the scaling is uniform.
		if d.scale.x == d.scale.y && d.scale.x == d.scale.z {
			instance.inverse_transpose_matrix = instance.model_matrix
		} else {
			model_mat_3x3 := cast(Matrix3)instance.model_matrix
			instance.inverse_transpose_matrix = cast(Matrix4)linalg.matrix3_inverse_transpose_f32(model_mat_3x3)
		}
	}
}

instanced_mesh_pipeline_layout :: proc() -> ^RHI_Pipeline_Layout {
	return &g_renderer.instanced_mesh_renderer_state.pipeline_layout
}

create_instanced_mesh_pipeline :: proc(specializations: Mesh_Pipeline_Specializations) -> (pipeline: RHI_Pipeline, result: rhi.Result) {
	main_window := platform.get_main_window()
	surface_key := rhi.get_surface_key_from_window(main_window)
	swapchain_format := rhi.get_swapchain_image_format(surface_key)

	// Create the pipeline for mesh rendering
	instanced_mesh_pipeline_desc := rhi.Pipeline_Description{
		vertex_input = rhi.create_vertex_input_description({
			rhi.Vertex_Input_Type_Desc{rate = .Vertex,   type = Mesh_Vertex},
			rhi.Vertex_Input_Type_Desc{rate = .Instance, type = Mesh_Instance},
		}, context.temp_allocator),
		input_assembly = {topology = .Triangle_List},
		depth_stencil = {
			depth_test = true,
			depth_write = true,
			depth_compare_op = .Less_Or_Equal,
		},
		shader_stages = {
			{type = .Vertex,   shader = &g_renderer.instanced_mesh_renderer_state.vsh.shader, specializations = specializations},
			{type = .Fragment, shader = &g_renderer.instanced_mesh_renderer_state.fsh.shader, specializations = specializations},
		},
		color_attachments = {
			rhi.Pipeline_Attachment_Desc{format = swapchain_format},
		},
		depth_stencil_attachment = rhi.Pipeline_Attachment_Desc{format = .D32FS8},
	}
	pipeline = rhi.create_graphics_pipeline(
		instanced_mesh_pipeline_desc,
		nil,
		g_renderer.instanced_mesh_renderer_state.pipeline_layout,
	) or_return

	return
}

draw_instanced_model :: proc(cb: ^RHI_Command_Buffer, model: ^Instanced_Model, materials: []^Material) {
	assert(cb != nil)
	assert(model != nil)
	assert(model.mesh != nil)
	assert(len(materials) == len(model.mesh.primitives))

	assert(g_rhi != nil)
	frame_in_flight := g_rhi.frame_in_flight

	// Model instance buffer
	rhi.cmd_bind_vertex_buffer(cb, model.instance_buffers[frame_in_flight], 1)

	for prim, i in model.mesh.primitives {
		// TODO: What if there is no texture
		rhi.cmd_bind_descriptor_set(cb, g_renderer.instanced_mesh_renderer_state.pipeline_layout, materials[i].descriptor_sets[frame_in_flight], INSTANCED_MESH_RENDERING_MATERIAL_DS_IDX)

		rhi.cmd_bind_vertex_buffer(cb, prim.vertex_buffer)
		rhi.cmd_bind_index_buffer(cb, prim.index_buffer)
		rhi.cmd_draw_indexed(cb, prim.index_buffer.elem_count, cast(u32)len(model.data))
	}
}

draw_instanced_model_primitive :: proc(cb: ^RHI_Command_Buffer, model: ^Instanced_Model, primitive_index: uint, material: ^Material) {
	assert(cb != nil)
	assert(model != nil)
	assert(model.mesh != nil)
	assert(primitive_index < len(model.mesh.primitives))

	assert(g_rhi != nil)
	frame_in_flight := g_rhi.frame_in_flight

	// Model instance buffer
	rhi.cmd_bind_vertex_buffer(cb, model.instance_buffers[frame_in_flight], 1)

	// TODO: What if there is no texture
	rhi.cmd_bind_descriptor_set(cb, g_renderer.instanced_mesh_renderer_state.pipeline_layout, material.descriptor_sets[frame_in_flight], INSTANCED_MESH_RENDERING_MATERIAL_DS_IDX)
	
	prim := &model.mesh.primitives[primitive_index]
	rhi.cmd_bind_vertex_buffer(cb, prim.vertex_buffer)
	rhi.cmd_bind_index_buffer(cb, prim.index_buffer)
	rhi.cmd_draw_indexed(cb, prim.index_buffer.elem_count, cast(u32)len(model.data))
}

// TERRAIN --------------------------------------------------------------------------------------------------------

init_terrain_rhi :: proc(color_attachment_format: rhi.Format) -> rhi.Result {
	// Create basic 3D shaders
	terrain_vsh := rhi.create_vertex_shader(core.path_make_engine_shader_relative(TERRAIN_SHADER_VERT)) or_return
	defer rhi.destroy_shader(&terrain_vsh)
	terrain_fsh := rhi.create_fragment_shader(core.path_make_engine_shader_relative(TERRAIN_SHADER_FRAG)) or_return
	defer rhi.destroy_shader(&terrain_fsh)

	// Create shaders for debug viewing
	terrain_dbg_fsh := rhi.create_fragment_shader(core.path_make_engine_shader_relative(TERRAIN_DEBUG_SHADER_FRAG)) or_return
	defer rhi.destroy_shader(&terrain_dbg_fsh)

	// Make a descriptor set layout for terrain maps
	dsl_desc := rhi.Descriptor_Set_Layout_Description{
		bindings = {
			// Height map
			rhi.Descriptor_Set_Layout_Binding{
				binding = 0,
				count = 1,
				shader_stage = {.Vertex},
				type = .Combined_Image_Sampler,
			},
		},
	}
	g_renderer.terrain_renderer_state.descriptor_set_layout = rhi.create_descriptor_set_layout(dsl_desc) or_return

	// Make a pipeline layout for terrain rendering
	pl_desc := rhi.Pipeline_Layout_Description{
		descriptor_set_layouts = {
			// Keep in the same order as TERRAIN_RENDERING_..._IDX constants
			&g_renderer.scene_descriptor_set_layout,
			&g_renderer.scene_view_descriptor_set_layout,
			&g_renderer.terrain_renderer_state.descriptor_set_layout,
			&g_renderer.material_descriptor_set_layout,
		},
		push_constants = {
			rhi.Push_Constant_Range{
				offset = 0,
				size = size_of(Terrain_Push_Constants),
				shader_stage = {.Vertex},
			},
		},
	}
	g_renderer.terrain_renderer_state.pipeline_layout = rhi.create_pipeline_layout(pl_desc) or_return

	// Create the pipeline for terrain rendering
	pipeline_desc := rhi.Pipeline_Description{
		vertex_input = rhi.create_vertex_input_description({
			rhi.Vertex_Input_Type_Desc{rate = .Vertex, type = Terrain_Vertex},
		}, context.temp_allocator),
		input_assembly = {topology = .Triangle_List},
		depth_stencil = {
			depth_test = true,
			depth_write = true,
			depth_compare_op = .Less_Or_Equal,
		},
		shader_stages = {
			{type = .Vertex,   shader = &terrain_vsh.shader},
			{type = .Fragment, shader = &terrain_fsh.shader},
		},
		color_attachments = {
			rhi.Pipeline_Attachment_Desc{format = color_attachment_format},
		},
		depth_stencil_attachment = rhi.Pipeline_Attachment_Desc{format = .D32FS8},
	}
	g_renderer.terrain_renderer_state.pipeline = rhi.create_graphics_pipeline(pipeline_desc, nil, g_renderer.terrain_renderer_state.pipeline_layout) or_return

	// Create a debug pipeline for viewing the terrain from the top
	dbg_pipeline_desc := rhi.Pipeline_Description{
		vertex_input = rhi.create_vertex_input_description({
			rhi.Vertex_Input_Type_Desc{rate = .Vertex, type = Terrain_Vertex},
		}, context.temp_allocator),
		input_assembly = {topology = .Triangle_List},
		depth_stencil = {
			depth_test = true,
			depth_write = true,
			depth_compare_op = .Less_Or_Equal,
		},
		shader_stages = {
			{type = .Vertex,   shader = &terrain_vsh.shader},
			{type = .Fragment, shader = &terrain_dbg_fsh.shader},
		},
		color_attachments = {
			rhi.Pipeline_Attachment_Desc{format = color_attachment_format},
		},
		depth_stencil_attachment = rhi.Pipeline_Attachment_Desc{format = .D32FS8},
	}
	g_renderer.terrain_renderer_state.debug_pipeline = rhi.create_graphics_pipeline(dbg_pipeline_desc, nil, g_renderer.terrain_renderer_state.pipeline_layout) or_return

	return nil
}

shutdown_terrain_rhi :: proc() {
	rhi.destroy_descriptor_set_layout(&g_renderer.terrain_renderer_state.descriptor_set_layout)
	rhi.destroy_pipeline_layout(&g_renderer.terrain_renderer_state.pipeline_layout)
	rhi.destroy_graphics_pipeline(&g_renderer.terrain_renderer_state.pipeline)
	rhi.destroy_graphics_pipeline(&g_renderer.terrain_renderer_state.debug_pipeline)
}

Terrain_Renderer_State :: struct {
	pipeline: rhi.RHI_Pipeline,
	debug_pipeline: rhi.RHI_Pipeline,
	pipeline_layout: rhi.RHI_Pipeline_Layout,
	descriptor_set_layout: rhi.RHI_Descriptor_Set_Layout,
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

Terrain :: struct {
	vertex_buffer: rhi.Buffer,
	index_buffer: rhi.Buffer,
	height_scale: f32,
	height_center: f32,
	descriptor_sets: [rhi.MAX_FRAMES_IN_FLIGHT]rhi.RHI_Descriptor_Set,
}

// TODO: Procedurally generate the plane mesh
create_terrain :: proc(vertices: []$V, indices: []u32, height_map: ^Combined_Texture_Sampler, name := "") -> (terrain: Terrain, result: rhi.Result) {
	assert(height_map != nil)

	// Create the Vertex Buffer
	vb_desc := rhi.Buffer_Desc{
		memory_flags = {.Device_Local},
	}
	vb_name := fmt.tprintf("VBO_%s", name)
	terrain.vertex_buffer = rhi.create_vertex_buffer(vb_desc, vertices, vb_name) or_return

	// Create the Index Buffer
	ib_desc := rhi.Buffer_Desc{
		memory_flags = {.Device_Local},
	}
	ib_name := fmt.tprintf("IBO_%s", name)
	terrain.index_buffer = rhi.create_index_buffer(ib_desc, indices, ib_name) or_return

	// Create buffers and descriptor sets
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		set_desc := rhi.Descriptor_Set_Desc{
			descriptors = {
				// Height map texture
				rhi.Descriptor_Desc{
					type = .Combined_Image_Sampler,
					binding = 0,
					count = 1,
					info = rhi.Descriptor_Texture_Info{
						texture = &height_map.texture.rhi_texture,
						sampler = &height_map.sampler,
					},
				},
			},
			layout = g_renderer.terrain_renderer_state.descriptor_set_layout,
		}
		ds_name := fmt.tprintf("DS_%s_HeightMap-%i", name, i)
		terrain.descriptor_sets[i] = rhi.create_descriptor_set(g_renderer.descriptor_pool, set_desc, ds_name) or_return
	}

	terrain.height_center = 0.5
	terrain.height_scale = 1

	return
}

destroy_terrain :: proc(terrain: ^Terrain) {
	rhi.destroy_buffer(&terrain.vertex_buffer)
	rhi.destroy_buffer(&terrain.index_buffer)
	// TODO: Handle descriptor sets' release
}

bind_terrain_pipeline :: proc(cb: ^RHI_Command_Buffer) {
	rhi.cmd_bind_graphics_pipeline(cb, g_renderer.terrain_renderer_state.pipeline)
}

terrain_pipeline_layout :: proc() -> ^RHI_Pipeline_Layout {
	return &g_renderer.terrain_renderer_state.pipeline_layout
}

draw_terrain :: proc(cb: ^RHI_Command_Buffer, terrain: ^Terrain, material: ^Material, debug: bool) {
	assert(cb != nil)
	assert(terrain != nil)
	assert(material != nil)

	assert(g_rhi != nil)
	frame_in_flight := g_rhi.frame_in_flight

	pipeline := &g_renderer.terrain_renderer_state.pipeline if !debug else &g_renderer.terrain_renderer_state.debug_pipeline
	rhi.cmd_bind_graphics_pipeline(cb, pipeline^)

	rhi.cmd_bind_vertex_buffer(cb, terrain.vertex_buffer)
	rhi.cmd_bind_index_buffer(cb, terrain.index_buffer)
	rhi.cmd_bind_descriptor_set(cb, g_renderer.terrain_renderer_state.pipeline_layout, terrain.descriptor_sets[frame_in_flight], TERRAIN_RENDERING_TERRAIN_DS_IDX)
	// TODO: What if there is no texture
	rhi.cmd_bind_descriptor_set(cb, g_renderer.terrain_renderer_state.pipeline_layout, material.descriptor_sets[frame_in_flight], TERRAIN_RENDERING_MATERIAL_DS_IDX)
	push_constants := Terrain_Push_Constants{
		height_scale = terrain.height_scale,
		height_center = terrain.height_center,
	}
	rhi.cmd_push_constants(cb, g_renderer.terrain_renderer_state.pipeline_layout, {.Vertex}, &push_constants)

	rhi.cmd_draw_indexed(cb, terrain.index_buffer.elem_count)
}

// FULL-SCREEN QUAD RENDERING -------------------------------------------------------------------------------------------

Quad_Renderer_State :: struct {
	pipeline: RHI_Pipeline,
	pipeline_layout: RHI_Pipeline_Layout,
	descriptor_set_layout: RHI_Descriptor_Set_Layout,
	sampler: RHI_Sampler,
}

draw_full_screen_quad :: proc(cb: ^RHI_Command_Buffer, texture: Combined_Texture_Sampler) {
	rhi.cmd_bind_graphics_pipeline(cb, g_renderer.quad_renderer_state.pipeline)
	rhi.cmd_bind_descriptor_set(cb, g_renderer.quad_renderer_state.pipeline_layout, texture.descriptor_set)
	// Draw 4 hardcoded quad vertices as a triangle strip
	rhi.cmd_draw(cb, 4)
}

// RENDERER -----------------------------------------------------------------------------------------------------------

init :: proc(renderer_s: ^State, rhi_s: ^rhi.State) -> Result {
	assert(renderer_s != nil)
	assert(rhi_s != nil)

	g_renderer = renderer_s
	g_rhi = rhi_s

	if r := init_rhi(); r != nil {
		return r.(rhi.Error)
	}

	main_window := platform.get_main_window()
	dpi := platform.get_window_dpi(main_window)
	text_init(cast(u32)dpi)

	// Register renderer specific asset types
	core.asset_type_register_with_runtime_data(Texture_Asset, Texture_Asset_Runtime_Data, texture_asset_deleter)
	core.asset_type_register_with_runtime_data(Static_Mesh_Asset, Static_Mesh_Asset_Runtime_Data, static_mesh_asset_deleter)
	core.asset_type_register_with_runtime_data(Material_Asset, Material_Asset_Runtime_Data, material_asset_deleter)

	return nil
}

shutdown :: proc() {
	text_shutdown()
	shutdown_rhi()
	delete(g_renderer.main_render_pass.framebuffers)
	g_renderer = nil
	g_rhi = nil
}

begin_frame :: proc() -> (cb: ^RHI_Command_Buffer, image_index: uint) {
	r: rhi.Result
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

	assert(g_rhi != nil)
	frame_in_flight := g_rhi.frame_in_flight
	cb = &g_renderer.cmd_buffers[frame_in_flight]

	rhi.begin_command_buffer(cb)

	return
}

end_frame :: proc(cb: ^RHI_Command_Buffer, image_index: uint) {
	rhi.end_command_buffer(cb)

	rhi.queue_submit_for_drawing(cb)

	if r := rhi.present(image_index); r != nil {
		core.error_log(r.?)
		return
	}

	// Prepare for the next frame which will use the duplicated resources
	g_rhi.frame_in_flight = (g_rhi.frame_in_flight + 1) % MAX_FRAMES_IN_FLIGHT
}

@(private)
init_rhi :: proc() -> rhi.Result {
	core.broadcaster_add_callback(&g_rhi.callbacks.on_recreate_swapchain_broadcaster, on_recreate_swapchain)

	// TODO: Presenting & swapchain framebuffers should be separated from the actual renderer
	// Get swapchain stuff
	main_window := platform.get_main_window()
	surface_key := rhi.get_surface_key_from_window(main_window)
	swapchain_format := rhi.get_swapchain_image_format(surface_key)
	swapchain_images := rhi.get_swapchain_images(surface_key)
	assert(len(swapchain_images) > 0)
	swapchain_dims := swapchain_images[0].dimensions.xy

	// Make render pass for swapchain images
	render_pass_desc := rhi.Render_Pass_Desc{
		attachments = {
			// Color
			rhi.Attachment_Desc{
				usage = .Color,
				format = swapchain_format,
				load_op = .Clear,
				store_op = .Store,
				from_layout = .Undefined,
				to_layout = .Present_Src,
			},
			// Depth-stencil
			rhi.Attachment_Desc{
				usage = .Depth_Stencil,
				format = .D32FS8,
				load_op = .Clear,
				store_op = .Irrelevant,
				from_layout = .Undefined,
				to_layout = .Depth_Stencil_Attachment,
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
	g_renderer.main_render_pass.render_pass = rhi.create_render_pass(render_pass_desc) or_return

	// Create global depth buffer
	g_renderer.depth_texture = rhi.create_depth_stencil_texture(swapchain_dims, .D32FS8, "DepthStencil") or_return

	// Make framebuffers
	fb_textures := make([]^rhi.Texture, len(swapchain_images), context.temp_allocator)
	for &im, i in swapchain_images {
		fb_textures[i] = &im
	}
	create_framebuffers(fb_textures, &g_renderer.depth_texture) or_return

	// Create a global descriptor pool
	pool_desc := rhi.Descriptor_Pool_Desc{
		pool_sizes = {
			rhi.Descriptor_Pool_Size{
				type = .Combined_Image_Sampler,
				count = MAX_SAMPLERS,
			},
			rhi.Descriptor_Pool_Size{
				type = .Uniform_Buffer,
				count = (MAX_SCENES + MAX_SCENE_VIEWS + MAX_MODELS + MAX_MATERIALS) * MAX_FRAMES_IN_FLIGHT,
			},
		},
		max_sets = MAX_SAMPLERS + MAX_TERRAINS + (MAX_SCENES + MAX_SCENE_VIEWS + MAX_MODELS + MAX_MATERIALS) * MAX_FRAMES_IN_FLIGHT,
	}
	g_renderer.descriptor_pool = rhi.create_descriptor_pool(pool_desc) or_return

	debug_init(&g_renderer.debug_renderer_state, g_renderer.main_render_pass.render_pass, swapchain_format) or_return

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
					type = .Combined_Image_Sampler,
					count = 1,
					shader_stage = {.Fragment},
				},
			},
		}
		g_renderer.quad_renderer_state.descriptor_set_layout = rhi.create_descriptor_set_layout(descriptor_set_layout_desc) or_return
	
		// Create pipeline layout
		pipeline_layout_desc := rhi.Pipeline_Layout_Description{
			descriptor_set_layouts = {
				&g_renderer.quad_renderer_state.descriptor_set_layout,
			},
		}
		g_renderer.quad_renderer_state.pipeline_layout = rhi.create_pipeline_layout(pipeline_layout_desc) or_return
	
		// Create quad graphics pipeline
		pipeline_desc := rhi.Pipeline_Description{
			shader_stages = {
				rhi.Pipeline_Shader_Stage{type = .Vertex,   shader = &vsh.shader},
				rhi.Pipeline_Shader_Stage{type = .Fragment, shader = &fsh.shader},
			},
			input_assembly = {topology = .Triangle_Strip},
			color_attachments = {
				rhi.Pipeline_Attachment_Desc{format = swapchain_format},
			},
			depth_stencil_attachment = rhi.Pipeline_Attachment_Desc{format = .D32FS8},
		}
		g_renderer.quad_renderer_state.pipeline = rhi.create_graphics_pipeline(pipeline_desc, nil, g_renderer.quad_renderer_state.pipeline_layout) or_return

		// Create a no-mipmap sampler for a "pixel-perfect" quad
		g_renderer.quad_renderer_state.sampler = rhi.create_sampler(1, .Nearest, .Repeat) or_return
	}

	init_scene_rhi() or_return
	init_material_rhi() or_return
	init_mesh_rhi() or_return
	init_instanced_mesh_rhi() or_return
	init_terrain_rhi(swapchain_format) or_return

	// Allocate global cmd buffers
	g_renderer.cmd_buffers = rhi.allocate_command_buffers(MAX_FRAMES_IN_FLIGHT) or_return

	g_renderer.base_to_debug_semaphores = rhi.create_semaphores() or_return

	return nil
}

@(private)
shutdown_rhi :: proc() {
	rhi.wait_for_device()

	shutdown_terrain_rhi()
	shutdown_instanced_mesh_rhi()
	shutdown_mesh_rhi()
	shutdown_material_rhi()
	shutdown_scene_rhi()

	debug_shutdown(&g_renderer.debug_renderer_state)

	destroy_framebuffers()
	rhi.destroy_texture(&g_renderer.depth_texture)
	rhi.destroy_render_pass(&g_renderer.main_render_pass.render_pass)
}

@(private)
create_framebuffers :: proc(images: []^rhi.Texture, depth: ^rhi.Texture) -> rhi.Result {
	for &im, i in images {
		attachments := [2]^rhi.Texture{im, depth}
		fb := rhi.create_framebuffer(g_renderer.main_render_pass.render_pass, attachments[:]) or_return
		append(&g_renderer.main_render_pass.framebuffers, fb)
	}
	return nil
}

@(private)
on_recreate_swapchain :: proc(args: rhi.Args_Recreate_Swapchain) {
	r: rhi.Result
	destroy_framebuffers()
	rhi.destroy_texture(&g_renderer.depth_texture)
	swapchain_images := rhi.get_swapchain_images(args.surface_key)
	g_renderer.depth_texture, r = rhi.create_depth_stencil_texture(args.new_dimensions, .D32FS8, "DepthStencil")
	if r != nil {
		panic("Failed to recreate the depth texture.")
	}
	fb_textures := make([]^rhi.Texture, len(swapchain_images), context.temp_allocator)
	for &im, i in swapchain_images {
		fb_textures[i] = &im
	}
	create_framebuffers(fb_textures, &g_renderer.depth_texture)
}

@(private)
destroy_framebuffers :: proc() {
	for &fb in g_renderer.main_render_pass.framebuffers {
		rhi.destroy_framebuffer(&fb)
	}
	clear(&g_renderer.main_render_pass.framebuffers)
}

Render_Pass :: struct {
	framebuffers: [dynamic]rhi.Framebuffer,
	render_pass: RHI_Render_Pass,
}

State :: struct {
	text_renderer_state: Text_Renderer_State,
	debug_renderer_state: Debug_Renderer_State,
	quad_renderer_state: Quad_Renderer_State,
	mesh_renderer_state: Mesh_Renderer_State,
	instanced_mesh_renderer_state: Instanced_Mesh_Renderer_State,
	terrain_renderer_state: Terrain_Renderer_State,

	scene_descriptor_set_layout: rhi.RHI_Descriptor_Set_Layout,
	scene_view_descriptor_set_layout: rhi.RHI_Descriptor_Set_Layout,
	material_descriptor_set_layout: rhi.RHI_Descriptor_Set_Layout,

	main_render_pass: Render_Pass,
	depth_texture: rhi.Texture,

	descriptor_pool: RHI_Descriptor_Pool,
	cmd_buffers: [MAX_FRAMES_IN_FLIGHT]RHI_Command_Buffer,

	base_to_debug_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
}

// Global Renderer state pointer for convenience
@(private)
g_renderer: ^State

// Global RHI pointer for convenience
@(private)
g_rhi: ^rhi.State
