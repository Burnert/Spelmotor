package sm_rhi

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:reflect"
import "core:slice"
import vk "vendor:vulkan"

import "sm:core"
import "sm:platform"

// RENDERER CORE -----------------------------------------------------------------------------------------------

RHI_Result :: #type core.Result(u64)
RHI_Error  :: #type core.Error(u64)

RHI_Type :: enum {
	Vulkan,
}

RHI_Init :: struct {
	main_window_handle: platform.Window_Handle,
	app_name: string,
	ver: RHI_Ver,
}

RHI_Ver :: struct {
	app_maj_ver: u32,
	app_min_ver: u32,
	app_patch_ver: u32,
}

init :: proc(rhi_init: RHI_Init) -> RHI_Result {
	state.selected_rhi = .Vulkan
	return _init(rhi_init)
}

shutdown :: proc() {
	_shutdown()
	state.selected_rhi = nil
}

RHI_Surface :: u64

create_surface :: proc(window: platform.Window_Handle) -> (surface: RHI_Surface, result: RHI_Result) {
	surface = _create_surface(window) or_return
	return
}

wait_and_acquire_image :: proc() -> (image_index: Maybe(uint), result: RHI_Result) {
	return _wait_and_acquire_image()
}

// TODO: Add Generic Queue_Submit_Sync
queue_submit_for_drawing :: proc(command_buffer: ^RHI_CommandBuffer, sync: Vk_Queue_Submit_Sync = {}) -> RHI_Result {
	assert(command_buffer != nil)
	return _queue_submit_for_drawing(command_buffer, sync)
}

present :: proc(image_index: uint) -> RHI_Result {
	return _present(image_index)
}

process_platform_events :: proc(window: platform.Window_Handle, event: platform.System_Event) {
	_process_platform_events(window, event)
}

wait_for_device :: proc() -> RHI_Result {
	return _wait_for_device()
}

Format :: enum {
	R8,
	RGB8_SRGB,
	RGBA8_SRGB,
	BGRA8_SRGB,
	D24S8,
	D32FS8,
	R32F,
	RG32F,
	RGB32F,
	RGBA32F,
}

format_channel_count :: proc(format: Format) -> uint {
	switch format {
	case .R8, .R32F:
		return 1
	case .D24S8, .D32FS8, .RG32F:
		return 2
	case .RGB8_SRGB, .RGB32F:
		return 3
	case .RGBA8_SRGB, .BGRA8_SRGB, .RGBA32F:
		return 4
	case:
		return 0
	}
}

format_bytes_per_channel :: proc(format: Format) -> uint {
	switch format {
	case .R8, .BGRA8_SRGB, .RGB8_SRGB, .RGBA8_SRGB:
		return 1
	case .R32F, .RG32F, .RGB32F, .RGBA32F:
		return 4
	case .D24S8, .D32FS8:
		// different counts for each channel
		return 0
	case: panic("Invalid format.")
	}
}

get_frame_in_flight :: proc() -> uint {
	return _get_frame_in_flight()
}

// TODO: This should be actually something like "can_draw_to_window" because that's what we actually want to check here
is_minimized :: proc() -> bool {
	return vk_data.is_minimized
}

// COMMON TYPES -----------------------------------------------------------------------------------------------

Compare_Op :: enum {
	NEVER,
	LESS,
	EQUAL,
	LESS_OR_EQUAL,
	GREATER,
	NOT_EQUAL,
	GREATER_OR_EQUAL,
	ALWAYS,
}

Image_Layout :: enum {
	UNDEFINED = 0,
	GENERAL,
	COLOR_ATTACHMENT_OPTIMAL,
	DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
	DEPTH_STENCIL_READ_ONLY_OPTIMAL,
	SHADER_READ_ONLY_OPTIMAL,
	TRANSFER_SRC_OPTIMAL,
	TRANSFER_DST_OPTIMAL,
	PREINITIALIZED,
	DEPTH_READ_ONLY_STENCIL_ATTACHMENT_OPTIMAL,
	DEPTH_ATTACHMENT_STENCIL_READ_ONLY_OPTIMAL,
	DEPTH_ATTACHMENT_OPTIMAL,
	DEPTH_READ_ONLY_OPTIMAL,
	STENCIL_ATTACHMENT_OPTIMAL,
	STENCIL_READ_ONLY_OPTIMAL,
	READ_ONLY_OPTIMAL,
	ATTACHMENT_OPTIMAL,
	PRESENT_SRC_KHR,
	VIDEO_DECODE_DST_KHR,
	VIDEO_DECODE_SRC_KHR,
	VIDEO_DECODE_DPB_KHR,
	SHARED_PRESENT_KHR,
	FRAGMENT_DENSITY_MAP_OPTIMAL_EXT,
	FRAGMENT_SHADING_RATE_ATTACHMENT_OPTIMAL_KHR,
	RENDERING_LOCAL_READ_KHR,
	VIDEO_ENCODE_DST_KHR,
	VIDEO_ENCODE_SRC_KHR,
	VIDEO_ENCODE_DPB_KHR,
	ATTACHMENT_FEEDBACK_LOOP_OPTIMAL_EXT,
}

// UNION TYPE DEFINITIONS -----------------------------------------------------------------------------------------------
// NOTE: Keep the variant order in sync with RHI_Type

RHI_Buffer              :: union {Vk_Buffer}
RHI_CommandBuffer       :: union {Vk_CommandBuffer}
RHI_DescriptorPool      :: union {vk.DescriptorPool}
RHI_DescriptorSet       :: union {vk.DescriptorSet}
RHI_DescriptorSetLayout :: union {vk.DescriptorSetLayout}
RHI_Framebuffer         :: union {vk.Framebuffer}
RHI_Pipeline            :: union {vk.Pipeline}
RHI_PipelineLayout      :: union {vk.PipelineLayout}
RHI_RenderPass          :: union {vk.RenderPass}
RHI_Sampler             :: union {vk.Sampler}
RHI_Semaphore           :: union {vk.Semaphore}
RHI_Shader              :: union {vk.ShaderModule}
RHI_Texture             :: union {Vk_Texture}

// SWAPCHAIN -----------------------------------------------------------------------------------------------

// TODO: Cache the textures somewhere in the internal state and just return the pointers
get_swapchain_images :: proc(surface_index: uint) -> (images: []Texture_2D) {
	switch state.selected_rhi {
	case .Vulkan:
		surface := &vk_data.surfaces[surface_index]
		image_count := len(surface.swapchain_images)
		images = make([]Texture_2D, image_count, context.temp_allocator)
		for i in 0..<image_count {
			images[i] = Texture_2D{
				texture = Vk_Texture{
					image = surface.swapchain_images[i],
					image_memory = {},
					image_view = surface.swapchain_image_views[i],
				},
				dimensions = {surface.swapchain_extent.width, surface.swapchain_extent.height},
				mip_levels = 1,
			}
		}
		return
	}
	return
}

get_swapchain_image_format :: proc(surface_index: uint) -> Format {
	switch state.selected_rhi {
	case .Vulkan:
		return conv_format_from_vk(vk_data.surfaces[surface_index].swapchain_image_format)
	}
	return nil
}

get_surface_index_from_window :: proc(handle: platform.Window_Handle) -> uint {
	return cast(uint) handle
}

// FRAMEBUFFERS -----------------------------------------------------------------------------------------------

Framebuffer :: struct {
	rhi_v: RHI_Framebuffer,
	dimensions: [2]u32,
}

create_framebuffer :: proc(render_pass: RHI_RenderPass, attachments: []^Texture_2D) -> (fb: Framebuffer, result: RHI_Result) {
	switch state.selected_rhi {
	case .Vulkan:
		image_views := make([]vk.ImageView, len(attachments), context.temp_allocator)
		for a, i in attachments {
			texture := &a.texture.(Vk_Texture)
			fb.dimensions = a.dimensions
			image_views[i] = texture.image_view
			assert(fb.dimensions == a.dimensions || fb.dimensions == {0, 0})
		}
		fb.rhi_v = vk_create_framebuffer(vk_data.device_data.device, render_pass.(vk.RenderPass), image_views, fb.dimensions) or_return
	}
	return
}

destroy_framebuffer :: proc(fb: ^Framebuffer) {
	assert(fb != nil)
	switch state.selected_rhi {
	case .Vulkan:
		vk_destroy_framebuffer(vk_data.device_data.device, fb.rhi_v.(vk.Framebuffer))
	}
}

// RENDER PASSES -----------------------------------------------------------------------------------------------

Attachment_Load_Op :: enum {
	IRRELEVANT,
	CLEAR,
	LOAD,
}

Attachment_Store_Op :: enum {
	IRRELEVANT,
	STORE,
}

Attachment_Usage :: enum {
	COLOR,
	DEPTH_STENCIL,
}

Attachment_Desc :: struct {
	usage: Attachment_Usage,
	format: Format,
	load_op: Attachment_Load_Op,
	store_op: Attachment_Store_Op,
	stencil_load_op: Attachment_Load_Op,
	stencil_store_op: Attachment_Store_Op,
	from_layout: Image_Layout,
	to_layout: Image_Layout,
}

Render_Pass_Dependency :: struct {
	stage_mask: vk.PipelineStageFlags,
	access_mask: vk.AccessFlags,
}

Render_Pass_Desc :: struct {
	attachments: []Attachment_Desc,
	src_dependency: Render_Pass_Dependency,
	dst_dependency: Render_Pass_Dependency,
}

create_render_pass :: proc(desc: Render_Pass_Desc) -> (rp: RHI_RenderPass, result: RHI_Result) {
	switch state.selected_rhi {
	case .Vulkan:
		rp = vk_create_render_pass(vk_data.device_data.device, desc) or_return
	}
	return
}

destroy_render_pass :: proc(rp: ^RHI_RenderPass) {
	assert(rp != nil)
	switch state.selected_rhi {
	case .Vulkan:
		vk_destroy_render_pass(vk_data.device_data.device, rp.(vk.RenderPass))
	}
}

cmd_begin_render_pass :: proc(cb: ^RHI_CommandBuffer, rp: RHI_RenderPass, fb: Framebuffer) {
	assert(cb != nil)
	switch state.selected_rhi {
	case .Vulkan:
		clear_values := [?]vk.ClearValue{
			vk.ClearValue{color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
			vk.ClearValue{depthStencil = {1.0, 0}},
		}
		rp_begin_info := vk.RenderPassBeginInfo{
			sType = .RENDER_PASS_BEGIN_INFO,
			renderPass = rp.(vk.RenderPass),
			framebuffer = fb.rhi_v.(vk.Framebuffer),
			renderArea = {
				offset = {0, 0},
				extent = {
					width = fb.dimensions.x,
					height = fb.dimensions.y,
				},
			},
			clearValueCount = len(clear_values),
			pClearValues = &clear_values[0],
		}
		vk.CmdBeginRenderPass(cb.(Vk_CommandBuffer).command_buffer, &rp_begin_info, .INLINE)
	}
}

cmd_end_render_pass :: proc(cb: ^RHI_CommandBuffer) {
	assert(cb != nil)
	switch state.selected_rhi {
	case .Vulkan:
		vk.CmdEndRenderPass(cb.(Vk_CommandBuffer).command_buffer)
	}
}

// PIPELINES & LAYOUTS -----------------------------------------------------------------------------------------------

Descriptor_Set_Layout_Binding :: struct {
	binding: u32,
	type: Descriptor_Type,
	shader_stage: Shader_Stage_Flags,
	count: u32,
}

Descriptor_Set_Layout_Description :: struct {
	// NOTE: In VK: keep the most frequently changing bindings last
	bindings: []Descriptor_Set_Layout_Binding,
}

create_descriptor_set_layout :: proc(layout_desc: Descriptor_Set_Layout_Description) -> (dsl: RHI_DescriptorSetLayout, result: RHI_Result) {
	switch state.selected_rhi {
	case .Vulkan:
		dsl = vk_create_descriptor_set_layout(vk_data.device_data.device, layout_desc) or_return
	}
	return
}

destroy_descriptor_set_layout :: proc(dsl: ^RHI_DescriptorSetLayout) {
	assert(dsl != nil)
	switch state.selected_rhi {
	case .Vulkan:
		vk_destroy_descriptor_set_layout(vk_data.device_data.device, dsl.(vk.DescriptorSetLayout))
	}
	dsl^ = nil
}

Push_Constant_Range :: struct {
	offset: u32,
	size: u32,
	shader_stage: Shader_Stage_Flags,
}

Pipeline_Layout_Description :: struct {
	descriptor_set_layouts: []^RHI_DescriptorSetLayout,
	push_constants: []Push_Constant_Range,
}

create_pipeline_layout :: proc(layout_desc: Pipeline_Layout_Description) -> (pl: RHI_PipelineLayout, result: RHI_Result) {
	switch state.selected_rhi {
	case .Vulkan:
		pl = vk_create_pipeline_layout(vk_data.device_data.device, layout_desc) or_return
	}
	return
}

destroy_pipeline_layout :: proc(pl: ^RHI_PipelineLayout) {
	assert(pl != nil)
	switch state.selected_rhi {
	case .Vulkan:
		vk_destroy_pipeline_layout(vk_data.device_data.device, pl.(vk.PipelineLayout))
	}
	pl^ = nil
}

Vertex_Attribute :: struct {
	format: Format,
	offset: u32,
	binding: u32,
}

Vertex_Input_Rate :: enum {
	VERTEX,
	INSTANCE,
}

Vertex_Binding :: struct {
	input_rate: Vertex_Input_Rate,
	stride: u32,
	binding: u32,
}

Vertex_Input_Description :: struct {
	attributes: []Vertex_Attribute,
	bindings: []Vertex_Binding,
}

Vertex_Input_Type_Desc :: struct {
	type: typeid,
	rate: Vertex_Input_Rate,
}

create_vertex_input_description :: proc(vertex_types: []Vertex_Input_Type_Desc, allocator := context.allocator) -> (vid: Vertex_Input_Description) {
	vid.bindings = make([]Vertex_Binding, len(vertex_types), allocator)

	// First gather the actual number of all attributes
	all_attribute_count := 0
	for vertex_type, i in vertex_types {
		assert(reflect.is_struct(type_info_of(vertex_type.type)))

		vid.bindings[i] = Vertex_Binding{
			stride = cast(u32) reflect.size_of_typeid(vertex_type.type),
			binding = cast(u32) i,
			input_rate = vertex_type.rate,
		}

		fields := reflect.struct_fields_zipped(vertex_type.type)
		all_attribute_count += len(fields)

		// Matrices need to be stored as COLUMN_COUNT vectors
		for f in fields {
			#partial switch v in runtime.type_info_base(f.type).variant {
			case runtime.Type_Info_Matrix:
				all_attribute_count += (v.column_count - 1)
			}
		}
	}

	vid.attributes = make([]Vertex_Attribute, all_attribute_count, allocator)

	attr_index := 0
	for vertex_type, i in vertex_types {
		fields := reflect.struct_fields_zipped(vertex_type.type)
		field_loop: for f, j in fields {
			format: Format
			#partial switch v in f.type.variant {
			case runtime.Type_Info_Float:
				switch f.type.id {
				case f32: format = .R32F
				case: panic("Unsupported float vertex attribute type used.")
				}
			case runtime.Type_Info_Array:
				switch v.elem.id {
				case f32:
					switch v.count {
					case 1: format = .R32F
					case 2: format = .RG32F
					case 3: format = .RGB32F
					case 4: format = .RGBA32F
					case: panic("Unsupported float array vertex attribute element count used.")
					}
				case: panic("Unsupported array vertex attribute type used.")
				}
			case runtime.Type_Info_Matrix:
				switch v.elem.id {
				case f32:
					switch v.row_count {
					case 1: format = .R32F
					case 2: format = .RG32F
					case 3: format = .RGB32F
					case 4: format = .RGBA32F
					case: panic("Unsupported float matrix vertex attribute row count used.")
					}
				case: panic("Unsupported matrix vertex attribute type used.")
				}
				// Dedicated matrix attribute loop
				for col in 0..<v.column_count {
					attribute := &vid.attributes[attr_index]
					attribute.format = format
					attribute.offset = u32(int(f.offset) + col * v.row_count * v.elem_stride)
					attribute.binding = cast(u32) i
					attr_index += 1
				}
				continue field_loop
			case: panic("Unsupported vertex attribute type used.")
			}
	
			attribute := &vid.attributes[attr_index]
			attribute.format = format
			attribute.offset = cast(u32) f.offset
			attribute.binding = cast(u32) i
			attr_index += 1
		}
	}

	return
}

Pipeline_Shader_Stage :: struct {
	type: Shader_Stage_Flag,
	shader: ^RHI_Shader,
	specializations: any, // struct with constants as fields
}

Pipeline_Depth_Stencil_State :: struct {
	depth_test: bool,
	depth_write: bool,
	depth_compare_op: Compare_Op,
}

Primitive_Topology :: enum {
	TRIANGLE_LIST = 0,
	TRIANGLE_STRIP,
	LINE_LIST,
}

Pipeline_Input_Assembly_State :: struct {
	topology: Primitive_Topology,
}

Pipeline_Description :: struct {
	shader_stages: []Pipeline_Shader_Stage,
	vertex_input: Vertex_Input_Description,
	input_assembly: Pipeline_Input_Assembly_State,
	depth_stencil: Pipeline_Depth_Stencil_State,
	viewport_dims: [2]u32,
}

// Render pass is specified to make the pipeline compatible with all render passes with the same format
// see: https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html#renderpass-compatibility
create_graphics_pipeline :: proc(pipeline_desc: Pipeline_Description, rp: RHI_RenderPass, pl: RHI_PipelineLayout) ->(gp: RHI_Pipeline, result: RHI_Result) {
	switch state.selected_rhi {
	case .Vulkan:
		gp = vk_create_graphics_pipeline(vk_data.device_data.device, pipeline_desc, rp.(vk.RenderPass), pl.(vk.PipelineLayout)) or_return
	}
	return
}

destroy_graphics_pipeline :: proc(gp: ^RHI_Pipeline) {
	assert(gp != nil)
	switch state.selected_rhi {
	case .Vulkan:
		vk_destroy_graphics_pipeline(vk_data.device_data.device, gp.(vk.Pipeline))
	}
	gp^ = nil
}

cmd_bind_graphics_pipeline :: proc(cb: ^RHI_CommandBuffer, gp: RHI_Pipeline) {
	assert(cb != nil)
	switch state.selected_rhi {
	case .Vulkan:
		vk.CmdBindPipeline(cb.(Vk_CommandBuffer).command_buffer, .GRAPHICS, gp.(vk.Pipeline))
	}
}

// DESCRIPTOR SETS -----------------------------------------------------------------------------------------------

Descriptor_Type :: enum {
	UNIFORM_BUFFER,
	COMBINED_IMAGE_SAMPLER,
}

Descriptor_Pool_Size :: struct {
	type: Descriptor_Type,
	count: uint,
}

Descriptor_Pool_Desc :: struct {
	pool_sizes: []Descriptor_Pool_Size,
	max_sets: uint,
}

create_descriptor_pool :: proc(pool_desc: Descriptor_Pool_Desc) -> (dp: RHI_DescriptorPool, result: RHI_Result) {
	switch state.selected_rhi {
	case .Vulkan:
		dp = vk_create_descriptor_pool(vk_data.device_data.device, pool_desc) or_return
	}
	return
}

destroy_descriptor_pool :: proc(dp: ^RHI_DescriptorPool) {
	assert(dp != nil)
	switch state.selected_rhi {
	case .Vulkan:
		vk_destroy_descriptor_pool(vk_data.device_data.device, dp.(vk.DescriptorPool))
	}
	dp^ = nil
}

Descriptor_Buffer_Info :: struct {
	buffer: ^RHI_Buffer,
	size: uint,
	offset: uint,
}
Descriptor_Texture_Info :: struct {
	texture: ^RHI_Texture,
	sampler: ^RHI_Sampler,
}
Descriptor_Info :: union {Descriptor_Buffer_Info, Descriptor_Texture_Info}

Descriptor_Desc :: struct {
	type: Descriptor_Type,
	binding: u32,
	count: u32,
	info: Descriptor_Info,
}

Descriptor_Set_Desc :: struct {
	descriptors: []Descriptor_Desc,
	layout: RHI_DescriptorSetLayout,
}

create_descriptor_set :: proc(pool: RHI_DescriptorPool, set_desc: Descriptor_Set_Desc) -> (ds: RHI_DescriptorSet, result: RHI_Result) {
	switch state.selected_rhi {
	case .Vulkan:
		ds = vk_create_descriptor_set(vk_data.device_data.device, pool.(vk.DescriptorPool), set_desc.layout.(vk.DescriptorSetLayout), set_desc) or_return
	}
	return
}

cmd_bind_descriptor_set :: proc(cb: ^RHI_CommandBuffer, layout: RHI_PipelineLayout, set: RHI_DescriptorSet, set_index: u32 = 0) {
	assert(cb != nil)
	assert(layout != nil)
	switch state.selected_rhi {
	case .Vulkan:
		vk_set := set.(vk.DescriptorSet)
		vk.CmdBindDescriptorSets(cb.(Vk_CommandBuffer).command_buffer, .GRAPHICS, layout.(vk.PipelineLayout), set_index, 1, &vk_set, 0, nil)
	}
}

// PUSH CONSTANTS --------------------------------------------------------------------------------------------

cmd_push_constants :: proc(cb: ^RHI_CommandBuffer, pipeline_layout: RHI_PipelineLayout, shader_stages: Shader_Stage_Flags, constants: ^$T) {
	assert(cb != nil)
	switch state.selected_rhi {
	case .Vulkan:
		vk.CmdPushConstants(cb.(Vk_CommandBuffer).command_buffer, pipeline_layout.(vk.PipelineLayout), conv_shader_stages_to_vk(shader_stages), 0, size_of(T), constants)
	}
}

// SHADERS -----------------------------------------------------------------------------------------------

Shader_Stage_Flags :: distinct bit_set[Shader_Stage_Flag]
Shader_Stage_Flag :: enum {
	VERTEX = 0,
	FRAGMENT = 4,
}

Vertex_Shader :: struct {
	shader: RHI_Shader,
}

create_vertex_shader :: proc(path: string) -> (vsh: Vertex_Shader, result: RHI_Result) {
	switch state.selected_rhi {
	case .Vulkan:
		vsh.shader = vk_create_shader(vk_data.device_data.device, path) or_return
	}
	return
}

Fragment_Shader :: struct {
	shader: RHI_Shader,
}

create_fragment_shader :: proc(path: string) -> (fsh: Fragment_Shader, result: RHI_Result) {
	switch state.selected_rhi {
	case .Vulkan:
		fsh.shader = vk_create_shader(vk_data.device_data.device, path) or_return
	}
	return
}

destroy_shader :: proc(shader: ^$T) {
	assert(shader != nil)
	switch state.selected_rhi {
	case .Vulkan:
		vk_destroy_shader(vk_data.device_data.device, shader.shader.(vk.ShaderModule))
	}
}

// TEXTURES -----------------------------------------------------------------------------------------------

Texture_2D :: struct {
	texture: RHI_Texture,
	dimensions: [2]u32,
	mip_levels: u32,
}

create_texture_2d :: proc(image_data: []byte, dimensions: [2]u32, format: Format, name := "") -> (tex: Texture_2D, result: RHI_Result) {
	assert(image_data == nil || len(image_data) == int(dimensions.x * dimensions.y) * cast(int)format_channel_count(format) * cast(int)format_bytes_per_channel(format))
	tex = Texture_2D{
		dimensions = dimensions,
	}
	switch state.selected_rhi {
	case .Vulkan:
		tex.texture = Vk_Texture{}
		vk_tex := &tex.texture.(Vk_Texture)
		vk_tex^, tex.mip_levels = vk_create_texture_image(vk_data.device_data.device, vk_data.device_data.physical_device, image_data, dimensions, conv_format_to_vk(format), name) or_return
	}

	return
}

create_depth_texture :: proc(dimensions: [2]u32, format: Format, name := "") -> (tex: Texture_2D, result: RHI_Result) {
	tex = Texture_2D{
		dimensions = dimensions,
	}
	switch state.selected_rhi {
	case .Vulkan:
		tex.texture = Vk_Texture{}
		vk_tex := &tex.texture.(Vk_Texture)
		vk_format := conv_format_to_vk(format)

		image_name := fmt.tprintf("Image_%s", name)
		vk_tex.image, vk_tex.image_memory = vk_create_image(vk_data.device_data.device, vk_data.device_data.physical_device, dimensions, 1, vk_format, .OPTIMAL, {.DEPTH_STENCIL_ATTACHMENT}, {.DEVICE_LOCAL}, image_name) or_return

		image_view_name := fmt.tprintf("ImageView_%s", name)
		vk_tex.image_view = vk_create_image_view(vk_data.device_data.device, vk_tex.image, 1, vk_format, {.DEPTH}, image_view_name) or_return
	}

	return
}

destroy_texture :: proc(tex: ^Texture_2D) {
	assert(tex != nil)
	switch state.selected_rhi {
	case .Vulkan:
		vk_destroy_texture_image(vk_data.device_data.device, &tex.texture.(Vk_Texture))
	}
}

// TODO: vulkan types used
Texture_Barrier_Desc :: struct {
	layout: Image_Layout,
	stage_mask: vk.PipelineStageFlags,
	access_mask: vk.AccessFlags,
}

cmd_transition_texture_layout :: proc(cb: ^RHI_CommandBuffer, tex: ^Texture_2D, from, to: Texture_Barrier_Desc) {
	assert(tex != nil)
	switch state.selected_rhi {
	case .Vulkan:
		vk_cmd_transition_image_layout(cb.(Vk_CommandBuffer).command_buffer, tex.texture.(Vk_Texture).image, tex.mip_levels, from, to)
	}
}

// SAMPLERS -----------------------------------------------------------------------------------------------

Filter :: enum {
	NEAREST,
	LINEAR,
}

Address_Mode :: enum {
	REPEAT,
	CLAMP,
}

create_sampler :: proc(mip_levels: u32, filter: Filter, address_mode: Address_Mode) -> (smp: RHI_Sampler, result: RHI_Result) {
	switch state.selected_rhi {
	case .Vulkan:
		smp = vk_create_texture_sampler(vk_data.device_data.device, vk_data.device_data.physical_device, mip_levels, conv_filter_to_vk(filter), conv_address_mode_to_vk(address_mode)) or_return
	}

	return
}

destroy_sampler :: proc(smp: ^RHI_Sampler) {
	assert(smp != nil)
	switch state.selected_rhi {
	case .Vulkan:
		vk.DestroySampler(vk_data.device_data.device, smp.(vk.Sampler), nil)
	}
}

// BUFFERS -----------------------------------------------------------------------------------------------

Buffer_Memory_Flags :: distinct bit_set[Buffer_Memory_Flag]
Buffer_Memory_Flag :: enum {
	DEVICE_LOCAL,
	HOST_VISIBLE,
	HOST_COHERENT,
}

Buffer_Desc :: struct {
	memory_flags: Buffer_Memory_Flags,
	map_memory: bool,
}

Vertex_Buffer :: struct {
	buffer: RHI_Buffer,
	vertices: rawptr,
	size: u32,
	vertex_count: u32,
	mapped_memory: []byte,
}

create_vertex_buffer :: proc(buffer_desc: Buffer_Desc, vertices: []$V, name := "") -> (vb: Vertex_Buffer, result: RHI_Result) {
	size := cast(u32) len(vertices) * size_of(V)
	vb = Vertex_Buffer{
		// TODO: Consider copying if CPU access is desired
		vertices = raw_data(vertices),
		vertex_count = cast(u32) len(vertices),
		size = size,
	}
	switch state.selected_rhi {
	case .Vulkan:
		vb.buffer = Vk_Buffer{}
		vk_buf := &vb.buffer.(Vk_Buffer)
		vk_buf.buffer, vk_buf.buffer_memory = vk_create_vertex_buffer(vk_data.device_data.device, vk_data.device_data.physical_device, buffer_desc, vertices, name) or_return
		if buffer_desc.map_memory {
			vb.mapped_memory = vk_map_memory(vk_data.device_data.device, vk_buf.buffer_memory, cast(vk.DeviceSize) size) or_return
		}
	}

	return
}

create_vertex_buffer_empty :: proc(buffer_desc: Buffer_Desc, $Element: typeid, elem_count: u32, name := "") -> (vb: Vertex_Buffer, result: RHI_Result) {
	size := cast(u32) elem_count * size_of(Element)
	vb = Vertex_Buffer{
		vertices = nil,
		vertex_count = elem_count,
		size = size,
	}
	switch state.selected_rhi {
	case .Vulkan:
		vb.buffer = Vk_Buffer{}
		vk_buf := &vb.buffer.(Vk_Buffer)
		vk_buf.buffer, vk_buf.buffer_memory = vk_create_vertex_buffer_empty(vk_data.device_data.device, vk_data.device_data.physical_device, buffer_desc, Element, elem_count, name) or_return
		if buffer_desc.map_memory {
			vb.mapped_memory = vk_map_memory(vk_data.device_data.device, vk_buf.buffer_memory, cast(vk.DeviceSize) size) or_return
		}
	}

	return
}

cmd_bind_vertex_buffer :: proc(cb: ^RHI_CommandBuffer, vb: Vertex_Buffer, binding: u32 = 0, offset: u32 = 0) {
	assert(cb != nil)
	switch state.selected_rhi {
	case .Vulkan:
		buffers := [?]vk.Buffer{vb.buffer.(Vk_Buffer).buffer}
		offsets := [?]vk.DeviceSize{cast(vk.DeviceSize) offset}
		vk.CmdBindVertexBuffers(cb.(Vk_CommandBuffer).command_buffer, binding, 1, &buffers[0], &offsets[0])
	}
}

Index_Buffer :: struct {
	buffer: RHI_Buffer,
	indices: rawptr,
	size: u32,
	index_count: u32,
	mapped_memory: []byte,
}

create_index_buffer :: proc(indices: []$I, name := "") -> (ib: Index_Buffer, result: RHI_Result) where intrinsics.type_is_integer(I) {
	ib = Index_Buffer{
		// TODO: Consider copying if CPU access is desired
		indices = raw_data(indices),
		index_count = cast(u32) len(indices),
		size = cast(u32) len(indices) * size_of(I),
	}
	switch state.selected_rhi {
	case .Vulkan:
		ib.buffer = Vk_Buffer{}
		vk_buf := &ib.buffer.(Vk_Buffer)
		vk_buf.buffer, vk_buf.buffer_memory = vk_create_index_buffer(vk_data.device_data.device, vk_data.device_data.physical_device, indices, name) or_return
	}

	return
}

cmd_bind_index_buffer :: proc(cb: ^RHI_CommandBuffer, ib: Index_Buffer) {
	assert(cb != nil)
	switch state.selected_rhi {
	case .Vulkan:
		vk.CmdBindIndexBuffer(cb.(Vk_CommandBuffer).command_buffer, ib.buffer.(Vk_Buffer).buffer, 0, .UINT32)
	}
}

Uniform_Buffer :: struct {
	buffer: RHI_Buffer,
	mapped_memory: []byte,
}

create_uniform_buffer :: proc($T: typeid, name := "") -> (ub: Uniform_Buffer, result: RHI_Result) {
	size := size_of(T)
	switch state.selected_rhi {
	case .Vulkan:
		ub.buffer = Vk_Buffer{}
		vk_buf := &ub.buffer.(Vk_Buffer)
		mapped_memory: rawptr
		vk_buf.buffer, vk_buf.buffer_memory, mapped_memory = vk_create_uniform_buffer(vk_data.device_data.device, vk_data.device_data.physical_device, size_of(T), name) or_return
		ub.mapped_memory = slice.from_ptr(cast(^byte) mapped_memory, size)
	}

	return
}

destroy_buffer :: proc(buffer: ^$T) {
	switch state.selected_rhi {
	case .Vulkan:
		vk_buf := &buffer.buffer.(Vk_Buffer)
		vk.DestroyBuffer(vk_data.device_data.device, vk_buf.buffer, nil)
		vk.FreeMemory(vk_data.device_data.device, vk_buf.buffer_memory, nil)
	}
}

destroy_buffer_rhi :: proc(buffer: ^RHI_Buffer) {
	switch state.selected_rhi {
	case .Vulkan:
		vk_buf := &buffer.(Vk_Buffer)
		vk.DestroyBuffer(vk_data.device_data.device, vk_buf.buffer, nil)
		vk.FreeMemory(vk_data.device_data.device, vk_buf.buffer_memory, nil)
	}
}

update_uniform_buffer :: proc(ub: ^Uniform_Buffer, data: ^$T) -> (result: RHI_Result) {
	assert(ub != nil)
	if ub.mapped_memory == nil {
		return core.error_make_as(RHI_Error, 0, "Failed to update uniform buffer. The buffer's memory is not mapped.")
	}

	assert(size_of(T) <= len(ub.mapped_memory))
	mem.copy_non_overlapping(raw_data(ub.mapped_memory), data, size_of(T))

	return nil
}

cast_mapped_buffer_memory :: proc($Element: typeid, memory: []byte) -> []Element {
	assert(memory != nil)
	elem_size := size_of(Element)
	memory_size := len(memory)
	assert(memory_size % elem_size == 0)
	elem_count := memory_size / elem_size
	cast_memory_ptr := cast(^Element) raw_data(memory)
	elem_slice := slice.from_ptr(cast_memory_ptr, elem_count)
	return elem_slice
}

cast_mapped_buffer_memory_single :: proc($Element: typeid, memory: []byte, index: uint = 0) -> ^Element {
	return &cast_mapped_buffer_memory(Element, memory)[index]
}

// COMMAND POOLS & BUFFERS -----------------------------------------------------------------------------------------------

allocate_command_buffers :: proc($N: uint) -> (cb: [N]RHI_CommandBuffer, result: RHI_Result) {
	switch state.selected_rhi {
	case .Vulkan:
		vk_cb := vk_allocate_command_buffers(vk_data.device_data.device, vk_data.command_pool, N) or_return
		for i in 0..<N {
			cb[i] = vk_cb[i]
		}
	}
	return
}

begin_command_buffer :: proc(cb: ^RHI_CommandBuffer) -> (result: RHI_Result) {
	assert(cb != nil)
	switch state.selected_rhi {
	case .Vulkan:
		cb_begin_info := vk.CommandBufferBeginInfo{
			sType = .COMMAND_BUFFER_BEGIN_INFO,
			flags = {},
			pInheritanceInfo = nil,
		}
		if result := vk.BeginCommandBuffer(cb.(Vk_CommandBuffer).command_buffer, &cb_begin_info); result != .SUCCESS {
			return make_vk_error("Failed to begin a Command Buffer.", result)
		}
	}
	return
}

end_command_buffer :: proc(cb: ^RHI_CommandBuffer) -> (result: RHI_Result) {
	assert(cb != nil)
	switch state.selected_rhi {
	case .Vulkan:
		if r := vk.EndCommandBuffer(cb.(Vk_CommandBuffer).command_buffer); r != .SUCCESS {
			return make_vk_error("Failed to end a Command Buffer.", r)
		}
	}
	return
}

cmd_set_viewport :: proc(cb: ^RHI_CommandBuffer, position, dimensions: [2]f32, min_depth, max_depth: f32) {
	assert(cb != nil)
	switch state.selected_rhi {
	case .Vulkan:
		viewport := vk.Viewport{
			x = position.x,
			y = position.y,
			width = dimensions.x,
			height = dimensions.y,
			minDepth = min_depth,
			maxDepth = max_depth,
		}
		vk.CmdSetViewport(cb.(Vk_CommandBuffer).command_buffer, 0, 1, &viewport)
	}
}

cmd_set_scissor :: proc(cb: ^RHI_CommandBuffer, position: [2]i32, dimensions: [2]u32) {
	assert(cb != nil)
	switch state.selected_rhi {
	case .Vulkan:
		scissor := vk.Rect2D{
			offset = {
				x = position.x,
				y = position.y,
			},
			extent = {
				width = dimensions.x,
				height = dimensions.y,
			},
		}
		vk.CmdSetScissor(cb.(Vk_CommandBuffer).command_buffer, 0, 1, &scissor)
	}
}

cmd_set_backface_culling :: proc(cb: ^RHI_CommandBuffer, enable: bool) {
	assert(cb != nil)
	switch state.selected_rhi {
	case .Vulkan:
		flags := vk.CullModeFlags{}
		if enable {
			flags += {.BACK}
		}
		vk.CmdSetCullMode(cb.(Vk_CommandBuffer).command_buffer, flags)
	}
}

cmd_draw :: proc(cb: ^RHI_CommandBuffer, vertex_count: u32, instance_count: u32 = 1) {
	assert(cb != nil)
	switch state.selected_rhi {
	case .Vulkan:
		vk.CmdDraw(cb.(Vk_CommandBuffer).command_buffer, vertex_count, instance_count, 0, 0)
	}
}

cmd_draw_indexed :: proc(cb: ^RHI_CommandBuffer, index_count: u32, instance_count: u32 = 1) {
	assert(cb != nil)
	switch state.selected_rhi {
	case .Vulkan:
		vk.CmdDrawIndexed(cb.(Vk_CommandBuffer).command_buffer, index_count, instance_count, 0, 0, 0)
	}
}

cmd_clear_depth :: proc(cb: ^RHI_CommandBuffer, fb_dims: [2]u32) {
	assert(cb != nil)
	switch state.selected_rhi {
	case .Vulkan:
		clear_attachment := vk.ClearAttachment{
			aspectMask = {.DEPTH},
			clearValue = vk.ClearValue{depthStencil = {depth = 1.0}},
		}
		clear_rect := vk.ClearRect{
			layerCount = 1,
			baseArrayLayer = 0,
			rect = {offset = {0,0}, extent = {width = fb_dims.x, height = fb_dims.y}},
		}
		vk.CmdClearAttachments(cb.(Vk_CommandBuffer).command_buffer, 1, &clear_attachment, 1, &clear_rect)
	}
}

// SYNCHRONIZATION -----------------------------------------------------------------------------------------------

create_semaphores :: proc() -> (semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore, result: RHI_Result) {
	switch state.selected_rhi {
	case .Vulkan:
		semaphores = vk_create_semaphores(vk_data.device_data.device) or_return
	}

	return
}

// INTERNAL RHI STATE -----------------------------------------------------------------------------------------------

@(private)
RHI_State :: struct {
	selected_rhi: RHI_Type,
}

@(private)
state: RHI_State

Args_Recreate_Swapchain :: struct {
	surface_index: uint,
	new_dimensions: [2]u32,
}

Callbacks :: struct {
	on_recreate_swapchain_broadcaster: core.Broadcaster(Args_Recreate_Swapchain),
}
callbacks: Callbacks
