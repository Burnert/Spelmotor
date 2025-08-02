package sm_rhi

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strings"
import vk "vendor:vulkan"

import "sm:core"
import "sm:platform"

// RENDERER CORE -----------------------------------------------------------------------------------------------

Result :: #type core.Result(u64)
Error  :: #type core.Error(u64)

Surface_Key :: platform.Window_Handle

Backend_Type :: enum {
	Vulkan,
}

Version :: struct {
	maj: u32,
	min: u32,
	patch: u32,
}

Args_Recreate_Swapchain :: struct {
	surface_key: Surface_Key,
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
	Never,
	Less,
	Equal,
	Less_Or_Equal,
	Greater,
	Not_Equal,
	Greater_Or_Equal,
	Always,
}

Image_Layout :: enum {
	Undefined = 0,
	General,
	Color_Attachment,
	Depth_Stencil_Attachment,
	Shader_Read_Only,
	Transfer_Src,
	Transfer_Dst,
	Present_Src,
}

Format :: enum {
	R8,
	RGB8_Srgb,
	RGBA8_Srgb,
	BGRA8_Srgb,
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
	case .RGB8_Srgb, .RGB32F:
		return 3
	case .RGBA8_Srgb, .BGRA8_Srgb, .RGBA32F:
		return 4
	case:
		return 0
	}
}

format_bytes_per_channel :: proc(format: Format) -> uint {
	switch format {
	case .R8, .BGRA8_Srgb, .RGB8_Srgb, .RGBA8_Srgb:
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
RHI_Memory_Allocation     :: union {Vk_Memory_Allocation}
RHI_Pipeline              :: union {vk.Pipeline}
RHI_Pipeline_Layout       :: union {vk.PipelineLayout}
RHI_Render_Pass           :: union {vk.RenderPass}
RHI_Sampler               :: union {vk.Sampler}
RHI_Semaphore             :: union {vk.Semaphore}
RHI_Shader                :: union {vk.ShaderModule}
RHI_Texture               :: union {Vk_Texture}

// SWAPCHAIN -----------------------------------------------------------------------------------------------

// TODO: Cache the textures somewhere in the internal state and just return the pointers
get_swapchain_images :: proc(surface_key: Surface_Key) -> (images: []Texture) {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		assert(g_vk != nil)
		surface, ok := &g_vk.surfaces[surface_key]
		if !ok {
			return
		}
		image_count := len(surface.swapchain_images)
		images = make([]Texture, image_count, context.temp_allocator)
		for i in 0..<image_count {
			images[i] = Texture{
				rhi_texture = Vk_Texture{
					image = surface.swapchain_images[i],
					image_view = surface.swapchain_image_views[i],
				},
				dimensions = {surface.swapchain_extent.width, surface.swapchain_extent.height, 1},
				mip_levels = 1,
				aspect_mask = {.COLOR},
			}
		}
		return
	}
	return
}

get_swapchain_image_format :: proc(surface_key: Surface_Key) -> Format {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		assert(g_vk != nil)
		surface, ok := &g_vk.surfaces[surface_key]
		if !ok {
			return nil
		}
		return conv_format_from_vk(surface.swapchain_image_format)
	}
	return nil
}

get_surface_key_from_window :: proc(handle: platform.Window_Handle) -> Surface_Key {
	return cast(Surface_Key)handle
}

// FRAMEBUFFERS -----------------------------------------------------------------------------------------------

Framebuffer :: struct {
	rhi_v: RHI_Framebuffer,
	dimensions: [2]u32,
}

create_framebuffer :: proc(render_pass: RHI_Render_Pass, attachments: []^Texture) -> (fb: Framebuffer, result: Result) {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		image_views := make([]vk.ImageView, len(attachments), context.temp_allocator)
		for a, i in attachments {
			texture := &a.rhi_texture.(Vk_Texture)
			fb.dimensions = a.dimensions.xy
			image_views[i] = texture.image_view
			assert(fb.dimensions == a.dimensions.xy || fb.dimensions == {0, 0})
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
	Irrelevant,
	Clear,
	Load,
}

Attachment_Store_Op :: enum {
	Irrelevant,
	Store,
}

Attachment_Usage :: enum {
	Color,
	Depth_Stencil,
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

// TODO: Remove vk types
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

Rendering_Attachment_Desc :: struct {
	texture: ^Texture,
	load_op: Attachment_Load_Op,
	store_op: Attachment_Store_Op,
}

Rendering_Desc :: struct {
}

cmd_begin_rendering :: proc(cb: ^RHI_Command_Buffer, desc: Rendering_Desc, color_attachments: []Rendering_Attachment_Desc, depth_stencil_attachment: ^Rendering_Attachment_Desc) {
	assert(cb != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		dimensions: [2]u32
		vk_color_attachments: []vk.RenderingAttachmentInfo
		has_color_attachments := color_attachments != nil && len(color_attachments) > 0
		if has_color_attachments {
			vk_color_attachments = make([]vk.RenderingAttachmentInfo, len(color_attachments), context.temp_allocator)
			for a, i in color_attachments {
				assert(a.texture != nil)
				if dimensions == {0, 0} {
					dimensions = a.texture.dimensions.xy
				}
				vk_color_attachments[i] = vk.RenderingAttachmentInfo{
					sType = .RENDERING_ATTACHMENT_INFO,
					imageView = a.texture.rhi_texture.(Vk_Texture).image_view,
					imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
					loadOp = conv_load_op_to_vk(a.load_op),
					storeOp = conv_store_op_to_vk(a.store_op),
					clearValue = {color = {float32 = {0, 0, 0, 0}}},
				}
			}
		}
		vk_depth_stencil_attachment: vk.RenderingAttachmentInfo
		if depth_stencil_attachment != nil {
			vk_depth_stencil_attachment = vk.RenderingAttachmentInfo{
				sType = .RENDERING_ATTACHMENT_INFO,
				imageView = depth_stencil_attachment.texture.rhi_texture.(Vk_Texture).image_view,
				imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
				loadOp = conv_load_op_to_vk(depth_stencil_attachment.load_op),
				storeOp = conv_store_op_to_vk(depth_stencil_attachment.store_op),
				clearValue = {depthStencil = {depth = 1, stencil = 0}},
			}
		}
		rendering_info := vk.RenderingInfo{
			sType = .RENDERING_INFO,
			layerCount = 1,
			viewMask = 0,
			colorAttachmentCount = cast(u32)len(vk_color_attachments),
			pColorAttachments = &vk_color_attachments[0] if has_color_attachments else nil,
			pDepthAttachment = &vk_depth_stencil_attachment if depth_stencil_attachment != nil else nil,
			pStencilAttachment = &vk_depth_stencil_attachment if depth_stencil_attachment != nil else nil,
			// NOTE: I assume this is like a scissor rect, but for some reason specified here instead of a separate render command??
			renderArea = {
				offset = {0, 0},
				extent = {
					width = dimensions.x,
					height = dimensions.y,
				},
			},
		}
		vk.CmdBeginRendering(cb.(vk.CommandBuffer), &rendering_info)
	}
}

cmd_end_rendering :: proc(cb: ^RHI_Command_Buffer) {
	assert(cb != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk.CmdEndRendering(cb.(vk.CommandBuffer))
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
	Vertex,
	Instance,
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
	Triangle_List = 0,
	Triangle_Strip,
	Line_List,
}

Pipeline_Input_Assembly_State :: struct {
	topology: Primitive_Topology,
}

Pipeline_Attachment_Desc :: struct {
	format: Format,
}

Pipeline_Description :: struct {
	shader_stages: []Pipeline_Shader_Stage,
	vertex_input: Vertex_Input_Description,
	input_assembly: Pipeline_Input_Assembly_State,
	depth_stencil: Pipeline_Depth_Stencil_State,
	color_attachments: []Pipeline_Attachment_Desc,
	depth_stencil_attachment: Pipeline_Attachment_Desc,
}

// Render pass is specified to make the pipeline compatible with all render passes with the same format
// see: https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html#renderpass-compatibility
create_graphics_pipeline :: proc(pipeline_desc: Pipeline_Description, rp: RHI_Render_Pass, pl: RHI_Pipeline_Layout) ->(gp: RHI_Pipeline, result: Result) {
	assert(g_rhi != nil)
	// Specifying a render pass AND attachments for dynamic rendering is not allowed.
	assert((rp == nil) ~ (len(pipeline_desc.color_attachments) == 0))
	switch g_rhi.selected_backend {
	case .Vulkan:
		rp := rp.(vk.RenderPass) if rp != nil else 0
		pl := pl.(vk.PipelineLayout)
		gp = vk_create_graphics_pipeline(pipeline_desc, rp, pl) or_return
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
	Uniform_Buffer,
	Combined_Image_Sampler,
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

create_descriptor_set :: proc(pool: RHI_Descriptor_Pool, set_desc: Descriptor_Set_Desc, name := "") -> (ds: RHI_Descriptor_Set, result: Result) {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		ds = vk_create_descriptor_set(pool.(vk.DescriptorPool), set_desc.layout.(vk.DescriptorSetLayout), set_desc, name) or_return
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

SHADER_ENTRY_POINT :: "main"

Shader_Stage_Flags :: distinct bit_set[Shader_Stage_Flag]
Shader_Stage_Flag :: enum {
	Vertex = 0,
	Fragment = 4,
}

Vertex_Shader :: struct {
	shader: RHI_Shader,
}

create_vertex_shader :: proc(path: string) -> (vsh: Vertex_Shader, result: Result) {
	vsh.shader = create_shader(path, .Vertex) or_return
	return
}

Fragment_Shader :: struct {
	shader: RHI_Shader,
}

create_fragment_shader :: proc(path: string) -> (fsh: Fragment_Shader, result: Result) {
	fsh.shader = create_shader(path, .Fragment) or_return
	return
}

create_shader :: proc(source_path: string, type: Shader_Type) -> (shader: RHI_Shader, result: Result) {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		// Content of the provided file is interpreted as bytecode if it has a .spv extension.
		if strings.ends_with(source_path, SHADER_BYTE_CODE_FILE_EXT) {
			bytecode, ok := os.read_entire_file(source_path)
			defer delete(bytecode)
			if !ok {
				result = make_vk_error(fmt.tprintf("Failed to load the Shader byte code from %s file.", source_path))
				return
			}

			shader = vk_create_shader(bytecode) or_return
			return
		}

		// TODO: Hash checking should only happen in development builds
		source_bytes, read_ok := os.read_entire_file(source_path)
		defer delete(source_bytes)
		if !read_ok {
			result = make_vk_error(fmt.tprintf("Failed to load the Shader source code from %s file.", source_path))
			return
		}

		source := string(source_bytes)
		shader_source_hash := hash_shader_source(source)

		// Try to find the compiled shader bytecode in cache first.
		if bytecode, ok := resolve_cached_shader_bytecode(source_path, shader_source_hash); ok {
			defer free_shader_bytecode(bytecode)
			log.infof("Cached bytecode has been resolved for shader %s.", source_path)
			res: Result
			if shader, res = vk_create_shader(bytecode); res == nil {
				return
			}
			log.errorf("Failed to create a shader from a cached bytecode %s.", source_path)
		}

		// If there is no cached bytecode, it needs to be compiled and cached.
		bytecode, ok := compile_shader(source, source_path, type, SHADER_ENTRY_POINT)
		defer free_shader_bytecode(bytecode)
		if !ok {
			result = make_vk_error(fmt.tprintf("Failed to compile the Shader byte code from %s.", source_path))
			return
		}

		cache_shader_bytecode(bytecode, source_path, shader_source_hash)

		shader = vk_create_shader(bytecode) or_return
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

Texture :: struct {
	rhi_texture: RHI_Texture,
	dimensions: [3]u32,
	// TODO: Make a generic enum
	aspect_mask: vk.ImageAspectFlags,
	mip_levels: u32,
}

create_texture_2d :: proc(image_data: []byte, dimensions: [2]u32, format: Format, name := "") -> (tex: Texture, result: Result) {
	assert(image_data == nil || len(image_data) == int(dimensions.x * dimensions.y) * cast(int)format_channel_count(format) * cast(int)format_bytes_per_channel(format))
	tex.dimensions.xy = dimensions
	tex.dimensions.z = 1
	tex.aspect_mask = {.COLOR}

	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		tex.rhi_texture = Vk_Texture{}
		vk_tex := &tex.rhi_texture.(Vk_Texture)

		vk_tex^, tex.mip_levels = vk_create_texture_image(image_data, dimensions, conv_format_to_vk(format), name) or_return
	}

	return
}

create_depth_stencil_texture :: proc(dimensions: [2]u32, format: Format, name := "") -> (tex: Texture, result: Result) {
	tex.dimensions.xy = dimensions
	tex.dimensions.z = 1
	tex.aspect_mask = {.DEPTH, .STENCIL}
	tex.mip_levels = 1

	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		tex.rhi_texture = Vk_Texture{}
		vk_tex := &tex.rhi_texture.(Vk_Texture)
		vk_format := conv_format_to_vk(format)

		image_name := fmt.tprintf("Image_%s", name)
		vk_tex.image, vk_tex.allocation = vk_create_image(dimensions, 1, vk_format, .OPTIMAL, {.DEPTH_STENCIL_ATTACHMENT}, {.DEVICE_LOCAL}, image_name) or_return

		image_view_name := fmt.tprintf("ImageView_%s", name)
		vk_tex.image_view = vk_create_image_view(vk_tex.image, 1, vk_format, {.DEPTH}, image_view_name) or_return
	}

	return
}

destroy_texture :: proc(tex: ^Texture) {
	assert(tex != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk_destroy_texture_image(&tex.rhi_texture.(Vk_Texture))
	}
}

// TODO: vulkan types used
Texture_Barrier_Desc :: struct {
	texture: ^Texture,
	from_layout: Image_Layout,
	to_layout: Image_Layout,
	src_access_mask: vk.AccessFlags,
	dst_access_mask: vk.AccessFlags,
}

Texture_Transition_Desc :: struct {
	barriers: []Texture_Barrier_Desc,
	src_stages: vk.PipelineStageFlags,
	dst_stages: vk.PipelineStageFlags,
}

// Transitions the texture from a specified layout to a different one and places a memory barrier
// Memory operations (specified by access masks) in src stages that happen before the transition will be made visible to the
// memory operations (specified by access masks) in dst stages that happen after the transition.
cmd_transition_texture_layout :: proc(cb: ^RHI_Command_Buffer, desc: Texture_Transition_Desc) {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk_cmd_transition_image_layout(cb.(vk.CommandBuffer), desc)
	}
}

// SAMPLERS -----------------------------------------------------------------------------------------------

Filter :: enum {
	Nearest,
	Linear,
}

Address_Mode :: enum {
	Repeat,
	Clamp,
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

Buffer_Desc :: struct {
	memory_flags: Memory_Property_Flags,
}

// Read-only struct
Buffer :: struct {
	buffer_desc: Buffer_Desc,
	rhi_buffer: RHI_Buffer,
	elem_type: typeid,
	elem_count: uint,
	size: uint,
	mapped_memory: []byte,
	// TODO: Add usage field
}

create_vertex_buffer :: proc(buffer_desc: Buffer_Desc, vertices: []$V, name := "", map_memory := false) -> (vb: Buffer, result: Result) {
	vb.buffer_desc = buffer_desc
	vb.elem_type = typeid_of(V)
	vb.elem_count = len(vertices)
	vb.size = len(vertices) * size_of(V)

	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vb.rhi_buffer = Vk_Buffer{}
		vk_buf := &vb.rhi_buffer.(Vk_Buffer)

		vk_buf.buffer, vk_buf.allocation = vk_create_vertex_buffer(buffer_desc, vertices, name, map_memory) or_return
		if vk_buf.allocation.mapped_memory != nil {
			vb.mapped_memory = vk_buf.allocation.mapped_memory[:vb.size]
		}
	}

	return
}

create_vertex_buffer_empty :: proc(buffer_desc: Buffer_Desc, $Element: typeid, elem_count: uint, name := "", map_memory := true) -> (vb: Buffer, result: Result) {
	vb.buffer_desc = buffer_desc
	vb.elem_type = Element
	vb.elem_count = elem_count
	vb.size = elem_count * size_of(Element)

	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vb.rhi_buffer = Vk_Buffer{}
		vk_buf := &vb.rhi_buffer.(Vk_Buffer)

		assert(elem_count < cast(uint)max(u32))
		vk_buf.buffer, vk_buf.allocation = vk_create_vertex_buffer_empty(buffer_desc, Element, cast(u32)elem_count, name, map_memory) or_return
		if vk_buf.allocation.mapped_memory != nil {
			vb.mapped_memory = vk_buf.allocation.mapped_memory[:vb.size]
		}
	}

	return
}

cmd_bind_vertex_buffer :: proc(cb: ^RHI_Command_Buffer, vb: Buffer, binding: u32 = 0, offset: u32 = 0) {
	assert(cb != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		buffer := vb.rhi_buffer.(Vk_Buffer).buffer
		offset := cast(vk.DeviceSize)offset
		vk.CmdBindVertexBuffers(cb.(vk.CommandBuffer), binding, 1, &buffer, &offset)
	}
}

create_index_buffer :: proc(buffer_desc: Buffer_Desc, indices: []$I, name := "", map_memory := false) -> (ib: Buffer, result: Result) where intrinsics.type_is_integer(I) {
	ib.buffer_desc = buffer_desc
	ib.elem_type = typeid_of(I)
	ib.elem_count = len(indices)
	ib.size = len(indices) * size_of(I)

	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		ib.rhi_buffer = Vk_Buffer{}
		vk_buf := &ib.rhi_buffer.(Vk_Buffer)

		vk_buf.buffer, vk_buf.allocation = vk_create_index_buffer(buffer_desc, indices, name, map_memory) or_return
		if vk_buf.allocation.mapped_memory != nil {
			ib.mapped_memory = vk_buf.allocation.mapped_memory[:ib.size]
		}
	}

	return
}

create_index_buffer_empty :: proc(buffer_desc: Buffer_Desc, $Element: typeid, elem_count: uint, name := "", map_memory := true) -> (ib: Buffer, result: Result) {
	ib.buffer_desc = buffer_desc
	ib.elem_type = Element
	ib.elem_count = elem_count
	ib.size = elem_count * size_of(Element)

	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		ib.rhi_buffer = Vk_Buffer{}
		vk_buf := &ib.rhi_buffer.(Vk_Buffer)

		assert(elem_count < cast(uint)max(u32))
		vk_buf.buffer, vk_buf.allocation = vk_create_index_buffer_empty(buffer_desc, Element, cast(u32)elem_count, name, map_memory) or_return
		if vk_buf.allocation.mapped_memory != nil {
			ib.mapped_memory = vk_buf.allocation.mapped_memory[:ib.size]
		}
	}

	return
}

cmd_bind_index_buffer :: proc(cb: ^RHI_Command_Buffer, ib: Buffer, offset: uint = 0) {
	assert(cb != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk.CmdBindIndexBuffer(cb.(vk.CommandBuffer), ib.rhi_buffer.(Vk_Buffer).buffer, cast(vk.DeviceSize)offset, .UINT32)
	}
}

create_uniform_buffer :: proc(buffer_desc: Buffer_Desc, $T: typeid, name := "") -> (ub: Buffer, result: Result) {
	ub.buffer_desc = buffer_desc
	ub.elem_type = typeid_of(T)
	ub.elem_count = 1
	ub.size = size_of(T)

	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		ub.rhi_buffer = Vk_Buffer{}
		vk_buf := &ub.rhi_buffer.(Vk_Buffer)

		vk_buf.buffer, vk_buf.allocation = vk_create_uniform_buffer(buffer_desc, cast(uint)ub.size, name) or_return
		assert(vk_buf.allocation.mapped_memory != nil)
		ub.mapped_memory = vk_buf.allocation.mapped_memory[:ub.size]
	}

	return
}

destroy_buffer :: proc(buffer: ^$T) {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk_buf := &buffer.rhi_buffer.(Vk_Buffer)
		vk_destroy_buffer(vk_buf^)
	}
}

destroy_buffer_rhi :: proc(buffer: ^RHI_Buffer) {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		vk_buf := &buffer.(Vk_Buffer)
		vk.DestroyBuffer(g_vk.device_data.device, vk_buf.buffer, nil)
		vk_free_memory(vk_buf.allocation)
	}
}

update_uniform_buffer :: proc(ub: ^Buffer, data: ^$T) -> (result: Result) {
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
		// vk.CmdSetViewportWithCount(cb.(vk.CommandBuffer), 1, &viewport)
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
		// vk.CmdSetScissorWithCount(cb.(vk.CommandBuffer), 1, &scissor)
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

cmd_draw :: proc(cb: ^RHI_Command_Buffer, vertex_count: uint, instance_count: u32 = 1) {
	assert(cb != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		assert(vertex_count < cast(uint)max(u32))
		vk.CmdDraw(cb.(vk.CommandBuffer), cast(u32)vertex_count, instance_count, 0, 0)
	}
}

cmd_draw_indexed :: proc(cb: ^RHI_Command_Buffer, index_count: uint, instance_count: u32 = 1) {
	assert(cb != nil)
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		assert(index_count < cast(uint)max(u32))
		vk.CmdDrawIndexed(cb.(vk.CommandBuffer), cast(u32)index_count, instance_count, 0, 0, 0)
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

// MEMORY -----------------------------------------------------------------------------------------------------

Memory_Property_Flags :: distinct bit_set[Memory_Property_Flag]
Memory_Property_Flag :: enum {
	Device_Local,
	Host_Visible,
	Host_Coherent,
}

allocate_buffer_memory :: proc(buffer: RHI_Buffer, memory_properties: Memory_Property_Flags) -> (allocation: RHI_Memory_Allocation, result: Result) {
	assert(g_rhi != nil)
	switch g_rhi.selected_backend {
	case .Vulkan:
		allocation = vk_allocate_buffer_memory(buffer.(Vk_Buffer).buffer, memory_properties) or_return
	}
	return
}
