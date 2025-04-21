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

Result :: #type core.Result(u64)
Error  :: #type core.Error(u64)

RHI_Surface :: u64

Backend_Type :: enum {
	Vulkan,
}

Version :: struct {
	maj: u32,
	min: u32,
	patch: u32,
}

Args_Recreate_Swapchain :: struct {
	surface_index: uint,
	new_dimensions: [2]u32,
}

Callbacks :: struct {
	on_recreate_swapchain_broadcaster: core.Broadcaster(Args_Recreate_Swapchain),
}

State :: struct {
	main_window_handle: platform.Window_Handle,
	selected_backend: Backend_Type,
	callbacks: Callbacks,
	backend: rawptr,
	frame_in_flight: uint,
	recreate_swapchain_requested: bool,
	is_minimized: bool,
}

// Global state pointer set during initialization
// This is mainly for convenience, because it's assumed that this memory will not ever be relocated,
// so it's not necessary to always pass it as an argument. There will also only be a single instance of it at a time.
@(private)
g_rhi: ^State

cast_backend :: proc{cast_backend_to_vk}

init :: proc(s: ^State, backend_type: Backend_Type, main_window_handle: platform.Window_Handle, app_name: string, version: Version) -> Result {
	assert(s != nil)

	// Global state pointer
	g_rhi = s

	s.selected_backend = backend_type
	s.main_window_handle = main_window_handle

	switch s.selected_backend {
	case .Vulkan:
		return vk_init(s, main_window_handle, app_name, version)
	case:
		panic("Unsupported backend type selected.")
	}
}

shutdown :: proc() {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk_shutdown()
	case:
		panic("Unsupported backend type selected.")
	}

	g_rhi.selected_backend = nil

	// Global state pointer
	g_rhi = nil
}

wait_and_acquire_image :: proc() -> (image_index: Maybe(uint), result: Result) {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		return vk_wait_and_acquire_image()
	case:
		panic("Unsupported backend type selected.")
	}
}

// TODO: Add Generic Queue_Submit_Sync
queue_submit_for_drawing :: proc(command_buffer: ^RHI_Command_Buffer, sync: Vk_Queue_Submit_Sync = {}) -> Result {
	assert(g_rhi != nil)
	assert(command_buffer != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		return vk_queue_submit_for_drawing(command_buffer, sync)
	case:
		panic("Unsupported backend type selected.")
	}
}

present :: proc(image_index: uint) -> Result {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		return vk_present(image_index)
	case:
		panic("Unsupported backend type selected.")
	}
}

process_platform_events :: proc(window: platform.Window_Handle, event: platform.System_Event) {
	// When the first window is created, the RHI will not be initialized yet.
	if (g_rhi == nil) {
		return
	}

	switch g_rhi.selected_backend {
	case .Vulkan:
		vk_process_platform_events(window, event)
	case:
		panic("Unsupported backend type selected.")
	}
}

wait_for_device :: proc() -> Result {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		return vk_wait_for_device()
	case:
		panic("Unsupported backend type selected.")
	}
}

// TODO: This should be actually something like "can_draw_to_window" because that's what we actually want to check here
is_minimized :: proc() -> bool {
	assert(g_rhi != nil)
	return g_rhi.is_minimized
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

// UNION TYPE DEFINITIONS -----------------------------------------------------------------------------------------------
// NOTE: Keep the variant order in sync with RHI_Type

RHI_Buffer                :: union {Vk_Buffer}
RHI_Command_Buffer        :: union {vk.CommandBuffer}
RHI_Descriptor_Pool       :: union {vk.DescriptorPool}
RHI_Descriptor_Set        :: union {vk.DescriptorSet}
RHI_Descriptor_Set_Layout :: union {vk.DescriptorSetLayout}
RHI_Framebuffer           :: union {vk.Framebuffer}
RHI_Pipeline              :: union {vk.Pipeline}
RHI_Pipeline_Layout       :: union {vk.PipelineLayout}
RHI_Render_Pass           :: union {vk.RenderPass}
RHI_Sampler               :: union {vk.Sampler}
RHI_Semaphore             :: union {vk.Semaphore}
RHI_Shader                :: union {vk.ShaderModule}
RHI_Texture               :: union {Vk_Texture}

// SWAPCHAIN -----------------------------------------------------------------------------------------------

// TODO: Cache the textures somewhere in the internal state and just return the pointers
get_swapchain_images :: proc(surface_index: uint) -> (images: []Texture_2D) {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		assert(g_vk != nil)
		surface := &g_vk.surfaces[surface_index]
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
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		assert(g_vk != nil)
		return conv_format_from_vk(g_vk.surfaces[surface_index].swapchain_image_format)
	}
	return nil
}

get_surface_index_from_window :: proc(handle: platform.Window_Handle) -> uint {
	return cast(uint)handle
}

// FRAMEBUFFERS -----------------------------------------------------------------------------------------------

Framebuffer :: struct {
	rhi_v: RHI_Framebuffer,
	dimensions: [2]u32,
}

create_framebuffer :: proc(render_pass: RHI_Render_Pass, attachments: []^Texture_2D) -> (fb: Framebuffer, result: Result) {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		image_views := make([]vk.ImageView, len(attachments), context.temp_allocator)
		for a, i in attachments {
			texture := &a.texture.(Vk_Texture)
			fb.dimensions = a.dimensions
			image_views[i] = texture.image_view
			assert(fb.dimensions == a.dimensions || fb.dimensions == {0, 0})
		}
		fb.rhi_v = vk_create_framebuffer(render_pass.(vk.RenderPass), image_views, fb.dimensions) or_return
	}
	return
}

destroy_framebuffer :: proc(fb: ^Framebuffer) {
	assert(fb != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		assert(g_vk != nil)
		vk_destroy_framebuffer(fb.rhi_v.(vk.Framebuffer))
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

create_render_pass :: proc(desc: Render_Pass_Desc) -> (rp: RHI_Render_Pass, result: Result) {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		rp = vk_create_render_pass(desc) or_return
	}
	return
}

destroy_render_pass :: proc(rp: ^RHI_Render_Pass) {
	assert(rp != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk_destroy_render_pass(rp.(vk.RenderPass))
	}
}

cmd_begin_render_pass :: proc(cb: ^RHI_Command_Buffer, rp: RHI_Render_Pass, fb: Framebuffer) {
	assert(cb != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
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
		vk.CmdBeginRenderPass(cb.(vk.CommandBuffer), &rp_begin_info, .INLINE)
	}
}

cmd_end_render_pass :: proc(cb: ^RHI_Command_Buffer) {
	assert(cb != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk.CmdEndRenderPass(cb.(vk.CommandBuffer))
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

create_descriptor_set_layout :: proc(layout_desc: Descriptor_Set_Layout_Description) -> (dsl: RHI_Descriptor_Set_Layout, result: Result) {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		dsl = vk_create_descriptor_set_layout(layout_desc) or_return
	}
	return
}

destroy_descriptor_set_layout :: proc(dsl: ^RHI_Descriptor_Set_Layout) {
	assert(dsl != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk_destroy_descriptor_set_layout(dsl.(vk.DescriptorSetLayout))
	}
	dsl^ = nil
}

Push_Constant_Range :: struct {
	offset: u32,
	size: u32,
	shader_stage: Shader_Stage_Flags,
}

Pipeline_Layout_Description :: struct {
	descriptor_set_layouts: []^RHI_Descriptor_Set_Layout,
	push_constants: []Push_Constant_Range,
}

create_pipeline_layout :: proc(layout_desc: Pipeline_Layout_Description) -> (pl: RHI_Pipeline_Layout, result: Result) {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		pl = vk_create_pipeline_layout(layout_desc) or_return
	}
	return
}

destroy_pipeline_layout :: proc(pl: ^RHI_Pipeline_Layout) {
	assert(pl != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk_destroy_pipeline_layout(pl.(vk.PipelineLayout))
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
create_graphics_pipeline :: proc(pipeline_desc: Pipeline_Description, rp: RHI_Render_Pass, pl: RHI_Pipeline_Layout) ->(gp: RHI_Pipeline, result: Result) {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		gp = vk_create_graphics_pipeline(pipeline_desc, rp.(vk.RenderPass), pl.(vk.PipelineLayout)) or_return
	}
	return
}

destroy_graphics_pipeline :: proc(gp: ^RHI_Pipeline) {
	assert(gp != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk_destroy_graphics_pipeline(gp.(vk.Pipeline))
	}
	gp^ = nil
}

cmd_bind_graphics_pipeline :: proc(cb: ^RHI_Command_Buffer, gp: RHI_Pipeline) {
	assert(cb != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk.CmdBindPipeline(cb.(vk.CommandBuffer), .GRAPHICS, gp.(vk.Pipeline))
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

create_descriptor_pool :: proc(pool_desc: Descriptor_Pool_Desc) -> (dp: RHI_Descriptor_Pool, result: Result) {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		dp = vk_create_descriptor_pool(pool_desc) or_return
	}
	return
}

destroy_descriptor_pool :: proc(dp: ^RHI_Descriptor_Pool) {
	assert(dp != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk_destroy_descriptor_pool(dp.(vk.DescriptorPool))
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
	layout: RHI_Descriptor_Set_Layout,
}

create_descriptor_set :: proc(pool: RHI_Descriptor_Pool, set_desc: Descriptor_Set_Desc) -> (ds: RHI_Descriptor_Set, result: Result) {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		ds = vk_create_descriptor_set(pool.(vk.DescriptorPool), set_desc.layout.(vk.DescriptorSetLayout), set_desc) or_return
	}
	return
}

cmd_bind_descriptor_set :: proc(cb: ^RHI_Command_Buffer, layout: RHI_Pipeline_Layout, set: RHI_Descriptor_Set, set_index: u32 = 0) {
	assert(cb != nil)
	assert(layout != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk_set := set.(vk.DescriptorSet)
		vk.CmdBindDescriptorSets(cb.(vk.CommandBuffer), .GRAPHICS, layout.(vk.PipelineLayout), set_index, 1, &vk_set, 0, nil)
	}
}

// PUSH CONSTANTS --------------------------------------------------------------------------------------------

cmd_push_constants :: proc(cb: ^RHI_Command_Buffer, pipeline_layout: RHI_Pipeline_Layout, shader_stages: Shader_Stage_Flags, constants: ^$T) {
	assert(cb != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk.CmdPushConstants(cb.(vk.CommandBuffer), pipeline_layout.(vk.PipelineLayout), conv_shader_stages_to_vk(shader_stages), 0, size_of(T), constants)
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

create_vertex_shader :: proc(path: string) -> (vsh: Vertex_Shader, result: Result) {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vsh.shader = vk_create_shader(path) or_return
	}
	return
}

Fragment_Shader :: struct {
	shader: RHI_Shader,
}

create_fragment_shader :: proc(path: string) -> (fsh: Fragment_Shader, result: Result) {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		fsh.shader = vk_create_shader(path) or_return
	}
	return
}

destroy_shader :: proc(shader: ^$T) {
	assert(shader != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk_destroy_shader(shader.shader.(vk.ShaderModule))
	}
}

// TEXTURES -----------------------------------------------------------------------------------------------

Texture_2D :: struct {
	texture: RHI_Texture,
	dimensions: [2]u32,
	mip_levels: u32,
}

create_texture_2d :: proc(image_data: []byte, dimensions: [2]u32, format: Format, name := "") -> (tex: Texture_2D, result: Result) {
	assert(image_data == nil || len(image_data) == int(dimensions.x * dimensions.y) * cast(int)format_channel_count(format) * cast(int)format_bytes_per_channel(format))
	tex = Texture_2D{
		dimensions = dimensions,
	}
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		tex.texture = Vk_Texture{}
		vk_tex := &tex.texture.(Vk_Texture)
		vk_tex^, tex.mip_levels = vk_create_texture_image(image_data, dimensions, conv_format_to_vk(format), name) or_return
	}

	return
}

create_depth_texture :: proc(dimensions: [2]u32, format: Format, name := "") -> (tex: Texture_2D, result: Result) {
	tex = Texture_2D{
		dimensions = dimensions,
	}
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		tex.texture = Vk_Texture{}
		vk_tex := &tex.texture.(Vk_Texture)
		vk_format := conv_format_to_vk(format)

		image_name := fmt.tprintf("Image_%s", name)
		vk_tex.image, vk_tex.image_memory = vk_create_image(dimensions, 1, vk_format, .OPTIMAL, {.DEPTH_STENCIL_ATTACHMENT}, {.DEVICE_LOCAL}, image_name) or_return

		image_view_name := fmt.tprintf("ImageView_%s", name)
		vk_tex.image_view = vk_create_image_view(vk_tex.image, 1, vk_format, {.DEPTH}, image_view_name) or_return
	}

	return
}

destroy_texture :: proc(tex: ^Texture_2D) {
	assert(tex != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk_destroy_texture_image(&tex.texture.(Vk_Texture))
	}
}

// TODO: vulkan types used
Texture_Barrier_Desc :: struct {
	layout: Image_Layout,
	stage_mask: vk.PipelineStageFlags,
	access_mask: vk.AccessFlags,
}

cmd_transition_texture_layout :: proc(cb: ^RHI_Command_Buffer, tex: ^Texture_2D, from, to: Texture_Barrier_Desc) {
	assert(tex != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk_cmd_transition_image_layout(cb.(vk.CommandBuffer), tex.texture.(Vk_Texture).image, tex.mip_levels, from, to)
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

create_sampler :: proc(mip_levels: u32, filter: Filter, address_mode: Address_Mode) -> (smp: RHI_Sampler, result: Result) {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		smp = vk_create_texture_sampler(mip_levels, conv_filter_to_vk(filter), conv_address_mode_to_vk(address_mode)) or_return
	}

	return
}

destroy_sampler :: proc(smp: ^RHI_Sampler) {
	assert(smp != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk.DestroySampler(g_vk.device_data.device, smp.(vk.Sampler), nil)
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

create_vertex_buffer :: proc(buffer_desc: Buffer_Desc, vertices: []$V, name := "") -> (vb: Vertex_Buffer, result: Result) {
	size := cast(u32) len(vertices) * size_of(V)
	vb = Vertex_Buffer{
		// TODO: Consider copying if CPU access is desired
		vertices = raw_data(vertices),
		vertex_count = cast(u32) len(vertices),
		size = size,
	}
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vb.buffer = Vk_Buffer{}
		vk_buf := &vb.buffer.(Vk_Buffer)
		vk_buf.buffer, vk_buf.buffer_memory = vk_create_vertex_buffer(buffer_desc, vertices, name) or_return
		if buffer_desc.map_memory {
			vb.mapped_memory = vk_map_memory(vk_buf.buffer_memory, cast(vk.DeviceSize) size) or_return
		}
	}

	return
}

create_vertex_buffer_empty :: proc(buffer_desc: Buffer_Desc, $Element: typeid, elem_count: u32, name := "") -> (vb: Vertex_Buffer, result: Result) {
	size := cast(u32) elem_count * size_of(Element)
	vb = Vertex_Buffer{
		vertices = nil,
		vertex_count = elem_count,
		size = size,
	}
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vb.buffer = Vk_Buffer{}
		vk_buf := &vb.buffer.(Vk_Buffer)
		vk_buf.buffer, vk_buf.buffer_memory = vk_create_vertex_buffer_empty(buffer_desc, Element, elem_count, name) or_return
		if buffer_desc.map_memory {
			vb.mapped_memory = vk_map_memory(vk_buf.buffer_memory, cast(vk.DeviceSize) size) or_return
		}
	}

	return
}

cmd_bind_vertex_buffer :: proc(cb: ^RHI_Command_Buffer, vb: Vertex_Buffer, binding: u32 = 0, offset: u32 = 0) {
	assert(cb != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		buffers := [?]vk.Buffer{vb.buffer.(Vk_Buffer).buffer}
		offsets := [?]vk.DeviceSize{cast(vk.DeviceSize) offset}
		vk.CmdBindVertexBuffers(cb.(vk.CommandBuffer), binding, 1, &buffers[0], &offsets[0])
	}
}

Index_Buffer :: struct {
	buffer: RHI_Buffer,
	indices: rawptr,
	size: u32,
	index_count: u32,
	mapped_memory: []byte,
}

create_index_buffer :: proc(indices: []$I, name := "") -> (ib: Index_Buffer, result: Result) where intrinsics.type_is_integer(I) {
	ib = Index_Buffer{
		// TODO: Consider copying if CPU access is desired
		indices = raw_data(indices),
		index_count = cast(u32) len(indices),
		size = cast(u32) len(indices) * size_of(I),
	}
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		ib.buffer = Vk_Buffer{}
		vk_buf := &ib.buffer.(Vk_Buffer)
		vk_buf.buffer, vk_buf.buffer_memory = vk_create_index_buffer(indices, name) or_return
	}

	return
}

cmd_bind_index_buffer :: proc(cb: ^RHI_Command_Buffer, ib: Index_Buffer) {
	assert(cb != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk.CmdBindIndexBuffer(cb.(vk.CommandBuffer), ib.buffer.(Vk_Buffer).buffer, 0, .UINT32)
	}
}

Uniform_Buffer :: struct {
	buffer: RHI_Buffer,
	mapped_memory: []byte,
}

create_uniform_buffer :: proc($T: typeid, name := "") -> (ub: Uniform_Buffer, result: Result) {
	size := size_of(T)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		ub.buffer = Vk_Buffer{}
		vk_buf := &ub.buffer.(Vk_Buffer)
		mapped_memory: rawptr
		vk_buf.buffer, vk_buf.buffer_memory, mapped_memory = vk_create_uniform_buffer(size_of(T), name) or_return
		ub.mapped_memory = slice.from_ptr(cast(^byte) mapped_memory, size)
	}

	return
}

destroy_buffer :: proc(buffer: ^$T) {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk_buf := &buffer.buffer.(Vk_Buffer)
		vk.DestroyBuffer(g_vk.device_data.device, vk_buf.buffer, nil)
		vk.FreeMemory(g_vk.device_data.device, vk_buf.buffer_memory, nil)
	}
}

destroy_buffer_rhi :: proc(buffer: ^RHI_Buffer) {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk_buf := &buffer.(Vk_Buffer)
		vk.DestroyBuffer(g_vk.device_data.device, vk_buf.buffer, nil)
		vk.FreeMemory(g_vk.device_data.device, vk_buf.buffer_memory, nil)
	}
}

update_uniform_buffer :: proc(ub: ^Uniform_Buffer, data: ^$T) -> (result: Result) {
	assert(ub != nil)
	if ub.mapped_memory == nil {
		return core.error_make_as(Error, 0, "Failed to update uniform buffer. The buffer's memory is not mapped.")
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

allocate_command_buffers :: proc($N: uint) -> (cb: [N]RHI_Command_Buffer, result: Result) {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk_cb := vk_allocate_command_buffers(g_vk.command_pool, N) or_return
		for i in 0..<N {
			cb[i] = vk_cb[i]
		}
	}
	return
}

begin_command_buffer :: proc(cb: ^RHI_Command_Buffer) -> (result: Result) {
	assert(cb != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		cb_begin_info := vk.CommandBufferBeginInfo{
			sType = .COMMAND_BUFFER_BEGIN_INFO,
			flags = {},
			pInheritanceInfo = nil,
		}
		if result := vk.BeginCommandBuffer(cb.(vk.CommandBuffer), &cb_begin_info); result != .SUCCESS {
			return make_vk_error("Failed to begin a Command Buffer.", result)
		}
	}
	return
}

end_command_buffer :: proc(cb: ^RHI_Command_Buffer) -> (result: Result) {
	assert(cb != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		if r := vk.EndCommandBuffer(cb.(vk.CommandBuffer)); r != .SUCCESS {
			return make_vk_error("Failed to end a Command Buffer.", r)
		}
	}
	return
}

cmd_set_viewport :: proc(cb: ^RHI_Command_Buffer, position, dimensions: [2]f32, min_depth, max_depth: f32) {
	assert(cb != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		viewport := vk.Viewport{
			x = position.x,
			y = position.y,
			width = dimensions.x,
			height = dimensions.y,
			minDepth = min_depth,
			maxDepth = max_depth,
		}
		vk.CmdSetViewport(cb.(vk.CommandBuffer), 0, 1, &viewport)
	}
}

cmd_set_scissor :: proc(cb: ^RHI_Command_Buffer, position: [2]i32, dimensions: [2]u32) {
	assert(cb != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
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
		vk.CmdSetScissor(cb.(vk.CommandBuffer), 0, 1, &scissor)
	}
}

cmd_set_backface_culling :: proc(cb: ^RHI_Command_Buffer, enable: bool) {
	assert(cb != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		flags := vk.CullModeFlags{}
		if enable {
			flags += {.BACK}
		}
		vk.CmdSetCullMode(cb.(vk.CommandBuffer), flags)
	}
}

cmd_draw :: proc(cb: ^RHI_Command_Buffer, vertex_count: u32, instance_count: u32 = 1) {
	assert(cb != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk.CmdDraw(cb.(vk.CommandBuffer), vertex_count, instance_count, 0, 0)
	}
}

cmd_draw_indexed :: proc(cb: ^RHI_Command_Buffer, index_count: u32, instance_count: u32 = 1) {
	assert(cb != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk.CmdDrawIndexed(cb.(vk.CommandBuffer), index_count, instance_count, 0, 0, 0)
	}
}

cmd_clear_depth :: proc(cb: ^RHI_Command_Buffer, fb_dims: [2]u32) {
	assert(cb != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
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
		vk.CmdClearAttachments(cb.(vk.CommandBuffer), 1, &clear_attachment, 1, &clear_rect)
	}
}

// SYNCHRONIZATION -----------------------------------------------------------------------------------------------

create_semaphores :: proc() -> (semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore, result: Result) {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		semaphores = vk_create_semaphores() or_return
	}

	return
}
