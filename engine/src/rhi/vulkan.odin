/*

Tips & Tricks:
https://www.youtube.com/watch?v=6NWfznwFnMs
- 10:58 - Staying under the memory limits - VK_EXT_memory_budget can help
- 20:53 - Ring buffer for dynamic data
- 22:49 - Task system (w/ dependency graph)
- 24:24 - Async compute tips
- 25:37 - Transfer copy on graphics queue
- 25:48 - Example queue pipeline
- 30:45 - Frame graph

Memory heaps & types (AMD)
https://gpuopen.com/learn/vulkan-device-memory/
* RDNA 4 (9070 XT) with resizable BAR doesn't have the 256 MB HOST_VISIBLE+DEVICE_LOCAL heap,
  but the entire DEVICE_LOCAL heap is also HOST_VISIBLE instead.

*/

package sm_rhi

import "base:runtime"
import "core:fmt"
import "core:image/png"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:slice"
import "core:time"
import "vendor:cgltf"
import vk "vendor:vulkan"

import "sm:platform"
import "sm:core"

// CONFIG
FORCE_VALIDATION_LAYERS :: true

make_vk_error :: proc(message: string, result: Maybe(vk.Result) = nil) -> Error {
	data := result.? or_else .SUCCESS
	return core.error_make_as(Error, data, message)
}

cast_backend_to_vk :: proc(s: ^State) -> ^Vk_State {
	assert(s != nil)
	assert(s.selected_backend == .Vulkan)
	return cast(^Vk_State)s.backend
}

// CONVERSION UTILITIES ----------------------------------------------------------------------------------------------

conv_format_to_vk :: proc(format: Format) -> vk.Format {
	switch format {
	case .R8: return .R8_UNORM
	case .RGB8_Srgb: return .R8G8B8_SRGB
	case .RGBA8_Srgb: return .R8G8B8A8_SRGB
	case .BGRA8_Srgb: return .B8G8R8A8_SRGB
	case .D24S8: return .D24_UNORM_S8_UINT
	case .D32FS8: return .D32_SFLOAT_S8_UINT
	case .R32F: return .R32_SFLOAT
	case .RG32F: return .R32G32_SFLOAT
	case .RGB32F: return .R32G32B32_SFLOAT
	case .RGBA32F: return .R32G32B32A32_SFLOAT
	case: panic("Invalid format.")
	}
}

conv_format_from_vk :: proc(vk_format: vk.Format) -> Format {
	// Keep in sync with conv_format_to_vk
	#partial switch vk_format {
	case .R8_UNORM: return .R8
	case .R8G8B8_SRGB: return .RGB8_Srgb
	case .R8G8B8A8_SRGB: return .RGBA8_Srgb
	case .B8G8R8A8_SRGB: return .BGRA8_Srgb
	case .D24_UNORM_S8_UINT: return .D24S8
	case .D32_SFLOAT_S8_UINT: return .D32FS8
	case .R32_SFLOAT: return .R32F
	case .R32G32_SFLOAT: return .RG32F
	case .R32G32B32_SFLOAT: return .RGB32F
	case .R32G32B32A32_SFLOAT: return .RGBA32F
	case: return nil
	}
}

conv_descriptor_type_to_vk :: proc(type: Descriptor_Type) -> vk.DescriptorType {
	switch type {
	case .Uniform_Buffer:         return .UNIFORM_BUFFER
	case .Combined_Image_Sampler: return .COMBINED_IMAGE_SAMPLER
	case: panic("Invalid descriptor type.")
	}
}

conv_shader_stages_to_vk :: proc(stages: Shader_Stage_Flags) -> vk.ShaderStageFlags {
	vk_stage: vk.ShaderStageFlags
	if .Vertex in stages   do vk_stage += {.VERTEX}
	if .Fragment in stages do vk_stage += {.FRAGMENT}
	return vk_stage
}

conv_compare_op_to_vk :: proc(op: Compare_Op) -> vk.CompareOp {
	switch op {
	case .Never:            return .NEVER
	case .Less:             return .LESS
	case .Equal:            return .EQUAL
	case .Less_Or_Equal:    return .LESS_OR_EQUAL
	case .Greater:          return .GREATER
	case .Not_Equal:        return .NOT_EQUAL
	case .Greater_Or_Equal: return .GREATER_OR_EQUAL
	case .Always:           return .ALWAYS
	case: panic("Invalid compare op.")
	}
}

conv_memory_flags_to_vk :: proc(flags: Memory_Property_Flags) -> vk.MemoryPropertyFlags {
	vk_flags: vk.MemoryPropertyFlags
	if .Device_Local  in flags do vk_flags += {.DEVICE_LOCAL}
	if .Host_Visible  in flags do vk_flags += {.HOST_VISIBLE}
	if .Host_Coherent in flags do vk_flags += {.HOST_COHERENT}
	return vk_flags
}

conv_vertex_input_rate_to_vk :: proc(rate: Vertex_Input_Rate) -> vk.VertexInputRate {
	switch rate {
	case .Vertex:   return .VERTEX
	case .Instance: return .INSTANCE
	case: panic("Invalid vertex input rate.")
	}
}

conv_primitive_topology_to_vk :: proc(topology: Primitive_Topology) -> vk.PrimitiveTopology {
	switch topology {
	case .Triangle_List:  return .TRIANGLE_LIST
	case .Triangle_Strip: return .TRIANGLE_STRIP
	case .Line_List:      return .LINE_LIST
	case: panic("Invalid primitive topology.")
	}
}

conv_filter_to_vk :: proc(filter: Filter) -> vk.Filter {
	switch filter {
	case .Nearest: return .NEAREST
	case .Linear:  return .LINEAR
	case: panic("Invalid filter.")
	}
}

conv_address_mode_to_vk :: proc(address_mode: Address_Mode) -> vk.SamplerAddressMode {
	switch address_mode {
	case .Repeat: return .REPEAT
	case .Clamp:  return .CLAMP_TO_EDGE
	case: panic("Invalid address mode.")
	}
}

conv_load_op_to_vk :: proc(load_op: Attachment_Load_Op) -> vk.AttachmentLoadOp {
	switch load_op {
	case .Clear:      return .CLEAR
	case .Load:       return .LOAD
	case .Irrelevant: return .DONT_CARE
	case: panic("Invalid load op.")
	}
}

conv_store_op_to_vk :: proc(store_op: Attachment_Store_Op) -> vk.AttachmentStoreOp {
	switch store_op {
	case .Store:      return .STORE
	case .Irrelevant: return .DONT_CARE
	case: panic("Invalid store op.")
	}
}

conv_image_layout_to_vk :: proc(layout: Image_Layout) -> vk.ImageLayout {
	switch layout {
	case .Undefined: return .UNDEFINED
	case .General: return .GENERAL
	case .Color_Attachment: return .COLOR_ATTACHMENT_OPTIMAL
	case .Depth_Stencil_Attachment: return .DEPTH_STENCIL_ATTACHMENT_OPTIMAL
	case .Shader_Read_Only: return .SHADER_READ_ONLY_OPTIMAL
	case .Transfer_Src: return .TRANSFER_SRC_OPTIMAL
	case .Transfer_Dst: return .TRANSFER_DST_OPTIMAL
	case .Present_Src: return .PRESENT_SRC_KHR
	case: panic("Invalid image layout.")
	}
}

MAX_FRAMES_IN_FLIGHT :: 2

ENGINE_NAME :: "Spelmotor"
KHRONOS_VALIDATION_LAYER_NAME :: "VK_LAYER_KHRONOS_validation"

Vk_Instance :: struct {
	get_instance_proc_addr: vk.ProcGetInstanceProcAddr,
	supported_extensions: []vk.ExtensionProperties,
	extensions: [dynamic]cstring,
	instance: vk.Instance,
}

vk_init :: proc(s: ^State, main_window_handle: platform.Window_Handle, app_name: string, version: Version) -> Result {
	g_vk = new(Vk_State)
	s.backend = g_vk

	platform_load_vulkan_lib() or_return

	instance_data := &g_vk.instance_data

	vk.load_proc_addresses_global(rawptr(instance_data.get_instance_proc_addr))
	
	supported_extension_count: u32 = ---
	vk.EnumerateInstanceExtensionProperties(nil, &supported_extension_count, nil)
	log.info(supported_extension_count, "vk extensions supported.")

	instance_data.supported_extensions = make([]vk.ExtensionProperties, int(supported_extension_count))
	vk.EnumerateInstanceExtensionProperties(nil, &supported_extension_count, raw_data(instance_data.supported_extensions))

	reserve(&instance_data.extensions, 3)
	platform_get_required_extensions(&instance_data.extensions)
	when VK_ENABLE_VALIDATION_LAYERS {
		append(&instance_data.extensions, cstring(vk.EXT_DEBUG_UTILS_EXTENSION_NAME))

		layer_count: u32 = ---
		vk.EnumerateInstanceLayerProperties(&layer_count, nil)
		log.info(layer_count, "vk layers supported.")

		layers := make([]vk.LayerProperties, layer_count)
		defer delete(layers)
		vk.EnumerateInstanceLayerProperties(&layer_count, raw_data(layers))

		for &l in layers {
			if strings.compare(core.string_from_array(&l.layerName), KHRONOS_VALIDATION_LAYER_NAME) == 0 {
				log.debug("Appending Vk validation layer.")
				append(&vk_debug_data.validation_layers, cstring(KHRONOS_VALIDATION_LAYER_NAME))
				break
			}
		}
	}

	app_info := vk.ApplicationInfo{
		sType = .APPLICATION_INFO,
		pApplicationName = strings.clone_to_cstring(app_name, context.temp_allocator),
		applicationVersion = vk.MAKE_VERSION(version.maj, version.min, version.patch),
		pEngineName = cstring(ENGINE_NAME),
		engineVersion = vk.MAKE_VERSION(1, 0, 0),
		apiVersion = vk.API_VERSION_1_3,
	}

	instance_create_info := vk.InstanceCreateInfo{
		sType = .INSTANCE_CREATE_INFO,
		pApplicationInfo = &app_info,
		enabledExtensionCount = cast(u32) len(instance_data.extensions),
		ppEnabledExtensionNames = raw_data(instance_data.extensions),
		enabledLayerCount = 0,
		ppEnabledLayerNames = nil,
		pNext = nil,
	}

	when VK_ENABLE_VALIDATION_LAYERS {
		instance_create_info.enabledLayerCount = cast(u32) len(vk_debug_data.validation_layers)
		instance_create_info.ppEnabledLayerNames = raw_data(vk_debug_data.validation_layers)

		debug_create_info := make_debug_utils_messenger_create_info()
		instance_create_info.pNext = &debug_create_info
	}

	if result := vk.CreateInstance(&instance_create_info, nil, &instance_data.instance); result != .SUCCESS {
		return make_vk_error("Failed to create Vulkan instance.", result)
	}

	vk.load_proc_addresses_instance(instance_data.instance)

	when VK_ENABLE_VALIDATION_LAYERS {
		init_debug_messenger() or_return
	}

	// At least one surface will need to be created to fully initialize Vulkan
	main_surface := create_surface_internal(instance_data.instance, s.main_window_handle) or_return

	g_vk.device_data = create_device(instance_data.instance, main_surface^) or_return
	device_data := &g_vk.device_data

	create_swapchain(main_surface) or_return
	create_swapchain_image_views(main_surface) or_return

	g_vk.command_pool = vk_create_command_pool(device_data.queue_family_list.graphics) or_return

	g_vk.sync_objects = vk_create_main_sync_objects() or_return

	s.frame_in_flight = 0
	s.recreate_swapchain_requested = false

	return nil
}

vk_init_window :: proc(handle: platform.Window_Handle) -> Result {
	assert(g_vk != nil)
	vk_surface := create_surface_internal(g_vk.instance_data.instance, handle) or_return
	create_swapchain(vk_surface) or_return
	create_swapchain_image_views(vk_surface) or_return

	return nil
}

vk_shutdown :: proc() {
	assert(g_vk != nil)
	assert(g_rhi != nil)

	device := g_vk.device_data.device

	vk_destroy_main_sync_objects(g_vk.sync_objects)

	vk.DestroyCommandPool(device, g_vk.command_pool, nil)

	assert(len(g_vk.surfaces) > 0)

	for k, &surface in g_vk.surfaces {
		if surface.surface != 0 {
			destroy_surface_and_swapchain(g_vk.instance_data.instance, device, &surface)
		}
	}

	vk.DestroyDevice(device, nil)

	g_vk.device_data.device = nil
	g_vk.device_data.physical_device = nil

	when VK_ENABLE_VALIDATION_LAYERS {
		shutdown_debug_messenger()
	}
	
	vk.DestroyInstance(g_vk.instance_data.instance, nil)

	// Free memory:

	for k, &surface in g_vk.surfaces {
		delete(surface.swapchain_images)
		delete(surface.swapchain_image_views)
	}

	delete(g_vk.instance_data.supported_extensions)
	delete(g_vk.instance_data.extensions)
	delete(g_vk.surfaces)

	when VK_ENABLE_VALIDATION_LAYERS {
		delete(vk_debug_data.validation_layers)
	}

	core.broadcaster_delete(&g_rhi.callbacks.on_recreate_swapchain_broadcaster)

	vk_memory_shutdown()

	free(g_rhi.backend)
	g_rhi.backend = nil

	// Global state pointer
	g_vk = nil
}

vk_wait_and_acquire_image :: proc() -> (image_index: Maybe(uint), result: Result) {
	assert(g_rhi != nil)
	assert(g_vk != nil)

	device := g_vk.device_data.device
	surface := &g_vk.surfaces[0]
	swapchain := surface.swapchain

	vk.WaitForFences(device, 1, &g_vk.sync_objects[g_rhi.frame_in_flight].in_flight_fence, true, max(u64))

	if g_rhi.is_minimized {
		return nil, nil
	}

	if g_rhi.recreate_swapchain_requested {
		recreate_swapchain(surface)
		vk.DeviceWaitIdle(g_vk.device_data.device)
		surface = &g_vk.surfaces[0]
		swapchain = surface.swapchain
	}

	vk_image_index: u32
	if result := vk.AcquireNextImageKHR(device, swapchain, max(u64), g_vk.sync_objects[g_rhi.frame_in_flight].image_available_semaphore, 0, &vk_image_index); result != .SUCCESS {
		if result == .ERROR_OUT_OF_DATE_KHR {
			recreate_swapchain(surface)
			return cast(uint) vk_image_index, nil
		} else if result != .SUBOPTIMAL_KHR {
			return nil, make_vk_error("Failed to acquire the next image.", result)
		}
	}

	vk.ResetFences(device, 1, &g_vk.sync_objects[g_rhi.frame_in_flight].in_flight_fence)

	return cast(uint) vk_image_index, nil
}

Vk_Queue_Submit_Sync :: struct {
	wait: Maybe(vk.Semaphore),
	signal: Maybe(vk.Semaphore),
}

vk_queue_submit_for_drawing :: proc(command_buffer: ^RHI_Command_Buffer, sync: Vk_Queue_Submit_Sync = {}) -> Result {
	wait_stages := [?]vk.PipelineStageFlags{
		{.COLOR_ATTACHMENT_OUTPUT},
	}

	wait_semaphore := sync.wait.? or_else g_vk.sync_objects[g_rhi.frame_in_flight].image_available_semaphore
	signal_semaphore := sync.signal.? or_else g_vk.sync_objects[g_rhi.frame_in_flight].draw_finished_semaphore

	is_draw_finished := sync.signal == nil

	cmd_buffer := command_buffer.(vk.CommandBuffer)
	submit_info := vk.SubmitInfo{
		sType = .SUBMIT_INFO,
		waitSemaphoreCount = 1,
		pWaitSemaphores = &wait_semaphore,
		pWaitDstStageMask = &wait_stages[0],
		commandBufferCount = 1,
		pCommandBuffers = &cmd_buffer,
		signalSemaphoreCount = 1,
		pSignalSemaphores = &signal_semaphore,
	}

	signal_fence := g_vk.sync_objects[g_rhi.frame_in_flight].in_flight_fence if is_draw_finished else 0
	if result := vk.QueueSubmit(g_vk.device_data.queue_list.graphics, 1, &submit_info, signal_fence); result != .SUCCESS {
		return make_vk_error("Failed to submit a Queue.", result)
	}

	return nil
}

vk_present :: proc(image_index: uint) -> Result {
	vk_image_index := cast(u32) image_index
	surface := &g_vk.surfaces[0]
	swapchain := surface.swapchain

	present_info := vk.PresentInfoKHR{
		sType = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores = &g_vk.sync_objects[g_rhi.frame_in_flight].draw_finished_semaphore,
		swapchainCount = 1,
		pSwapchains = &swapchain,
		pImageIndices = &vk_image_index,
	}

	if r := vk.QueuePresentKHR(g_vk.device_data.queue_list.present, &present_info); r != .SUCCESS {
		if r == .ERROR_OUT_OF_DATE_KHR || r == .SUBOPTIMAL_KHR || g_rhi.recreate_swapchain_requested {
			recreate_swapchain(surface)
			return nil
		}
		return make_vk_error("Failed to present a Queue.", r)
	}

	return nil
}

vk_process_platform_events :: proc(window: platform.Window_Handle, event: platform.System_Event) {
	#partial switch e in event {
	case platform.Window_Resized_Event:
		minimized := e.type == .Minimize || e.width == 0 || e.height == 0
		request_recreate_swapchain(minimized)
	}
}

vk_wait_for_device :: proc() -> Result {
	if result := vk.DeviceWaitIdle(g_vk.device_data.device); result != .SUCCESS {
		return make_vk_error("Failed to wait for a device.", result)
	}

	return nil
}

// SURFACE ------------------------------------------------------------------------------------------------------------------------------------

Vk_Surface :: struct {
	surface: vk.SurfaceKHR,
	swapchain: vk.SwapchainKHR,
	swapchain_images: [dynamic]vk.Image,
	swapchain_image_views: [dynamic]vk.ImageView,
	swapchain_image_format: vk.Format,
	swapchain_extent: vk.Extent2D,
}

vk_get_window_surface :: proc(handle: platform.Window_Handle) -> ^Vk_Surface {
	assert(g_vk != nil)
	if s, ok := &g_vk.surfaces[handle]; ok {
		return s
	}
	return nil
}

@(private)
create_surface_internal :: proc(instance: vk.Instance, window_handle: platform.Window_Handle) -> (vk_surface: ^Vk_Surface, result: Result) {
	surface: vk.SurfaceKHR = platform_create_surface(instance, window_handle) or_return
	return register_surface(window_handle, surface), nil
}

@(private)
destroy_surface_and_swapchain :: proc(instance: vk.Instance, device: vk.Device, vk_surface: ^Vk_Surface) {
	assert(instance != nil)
	assert(vk_surface != nil)
	assert(device != nil)

	for image_view in vk_surface.swapchain_image_views {
		vk.DestroyImageView(device, image_view, nil)
	}
	vk.DestroySwapchainKHR(device, vk_surface.swapchain, nil)
	vk.DestroySurfaceKHR(instance, vk_surface.surface, nil)
	vk_surface.swapchain = 0
	vk_surface.surface = 0
}

@(private)
register_surface :: proc(window_handle: platform.Window_Handle, surface: vk.SurfaceKHR) -> ^Vk_Surface {
	assert(g_vk != nil)
	if s, ok := &g_vk.surfaces[window_handle]; ok {
		return s
	}
	return map_insert(&g_vk.surfaces, window_handle, Vk_Surface{surface = surface})
}

// DEVICE ------------------------------------------------------------------------------------------------------------------------------------

Vk_Queue_Family_List :: struct {
	graphics: u32,
	present: u32,
}

Vk_Queue_List :: struct {
	graphics: vk.Queue,
	present: vk.Queue,
}

Vk_Device :: struct {
	physical_device: vk.PhysicalDevice,
	device: vk.Device,
	queue_family_list: Vk_Queue_Family_List,
	queue_list: Vk_Queue_List,
}

vk_find_proper_memory_type :: proc(type_bits: u32, property_flags: vk.MemoryPropertyFlags) -> (index: u32, result: Result) {		
	memory_properties: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(g_vk.device_data.physical_device, &memory_properties)

	for i: u32 = 0; i < memory_properties.memoryTypeCount; i += 1 {
		if type_bits & (1 << i) != 0 && memory_properties.memoryTypes[i].propertyFlags & property_flags == property_flags {
			index = i
			return
		}
	}
	result = make_vk_error("Could not find a proper memory type for a Buffer.")
	return
}

@(private)
create_device :: proc(instance: vk.Instance, vk_surface: Vk_Surface) -> (vk_device: Vk_Device, result: Result) {
	vk_device = {}
	vk_device.physical_device = create_physical_device(instance, vk_surface.surface, &vk_device.queue_family_list) or_return
	create_logical_device(&vk_device) or_return

	return vk_device, nil
}

@(private)
create_physical_device :: proc(instance: vk.Instance, surface: vk.SurfaceKHR, out_queue_family_list: ^Vk_Queue_Family_List) -> (physical_device: vk.PhysicalDevice, result: Result) {
	assert(out_queue_family_list != nil)

	device_count: u32 = ---
	vk.EnumeratePhysicalDevices(instance, &device_count, nil)
	devices := make([]vk.PhysicalDevice, device_count, context.temp_allocator)
	defer delete(devices, context.temp_allocator)
	vk.EnumeratePhysicalDevices(instance, &device_count, raw_data(devices))

	for device in devices {
		out_queue_family_list^ = {}
		properties: vk.PhysicalDeviceProperties = ---
		features: vk.PhysicalDeviceFeatures = ---
		vk.GetPhysicalDeviceProperties(device, &properties)
		vk.GetPhysicalDeviceFeatures(device, &features)

		if properties.deviceType != .DISCRETE_GPU {
			continue
		}
		if !find_device_queue_families(device, surface, out_queue_family_list) {
			continue
		}
		if !check_device_required_extension_support(device) {
			continue
		}
		swapchain_support := get_swapchain_support(surface, device)
		defer free_swapchain_support(&swapchain_support)
		if len(swapchain_support.formats) == 0 || len(swapchain_support.present_modes) == 0 {
			continue
		}
		if !features.samplerAnisotropy {
			continue
		}
		physical_device = device
		log.infof("Vulkan Selected device: %s\n", properties.deviceName)
		return
	}

	result = make_vk_error("Failed to find a suitable physical device.")
	return
}

@(private)
find_device_queue_families :: proc(physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR, out_queue_family_list: ^Vk_Queue_Family_List) -> bool {
	assert(physical_device != nil)
	assert(surface != 0)
	assert(out_queue_family_list != nil)

	queue_family_count: u32 = ---
	vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, nil)
	queue_families := make([]vk.QueueFamilyProperties, queue_family_count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, raw_data(queue_families))

	DESIRED_QUEUE_FAMILY_NUMBER :: 2
	found_queue_families := 0
	for queue_family, i in queue_families {
		if .GRAPHICS in queue_family.queueFlags {
			out_queue_family_list.graphics = u32(i)
			found_queue_families += 1
		}

		supports_present: b32 = ---
		vk.GetPhysicalDeviceSurfaceSupportKHR(physical_device, u32(i), surface, &supports_present)
		if supports_present {
			out_queue_family_list.present = u32(i)
			found_queue_families += 1
		}

		if found_queue_families >= DESIRED_QUEUE_FAMILY_NUMBER {
			return true
		}
	}

	return false
}

@(private)
VK_REQUIRED_EXTENSIONS := [?]cstring{
	vk.KHR_SWAPCHAIN_EXTENSION_NAME,
}

@(private)
check_device_required_extension_support :: proc(device: vk.PhysicalDevice) -> bool {
	extension_count: u32 = ---
	vk.EnumerateDeviceExtensionProperties(device, nil, &extension_count, nil)
	extensions := make([]vk.ExtensionProperties, extension_count, context.temp_allocator)
	defer delete(extensions, context.temp_allocator)
	vk.EnumerateDeviceExtensionProperties(device, nil, &extension_count, raw_data(extensions))

	found_extensions_count := 0
	for &extension in extensions {
		for required_extension in VK_REQUIRED_EXTENSIONS {
			if cast(cstring) &extension.extensionName[0] == required_extension {
				found_extensions_count += 1
			}
		}
	}

	return found_extensions_count >= len(VK_REQUIRED_EXTENSIONS)
}

@(private)
create_logical_device :: proc(vk_device: ^Vk_Device) -> Result {
	assert(vk_device.device == nil)
	assert(vk_device.queue_family_list.graphics != VK_INVALID_QUEUE_FAMILY_INDEX, "Graphics queue family has not been selected.")

	Empty :: struct{}
	unique_queue_families: [2]u32
	unique_queue_families[0] = vk_device.queue_family_list.graphics
	queue_family_count := 1
	if vk_device.queue_family_list.graphics != vk_device.queue_family_list.present {
		unique_queue_families[1] = vk_device.queue_family_list.present
		queue_family_count += 1
	}

	queue_priority: f32 = 1.0
	queue_create_infos := [dynamic]vk.DeviceQueueCreateInfo{}
	defer delete(queue_create_infos)
	for i in 0..<queue_family_count {
		queue_family := unique_queue_families[i]
		append(&queue_create_infos, vk.DeviceQueueCreateInfo{
			sType = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = queue_family,
			queueCount = 1,
			pQueuePriorities = &queue_priority,
		})
	}

	device_features := vk.PhysicalDeviceFeatures{}
	device_features.samplerAnisotropy = true

	device_create_info := vk.DeviceCreateInfo{
		sType = .DEVICE_CREATE_INFO,
		pQueueCreateInfos = raw_data(queue_create_infos),
		queueCreateInfoCount = cast(u32)len(queue_create_infos),
		pEnabledFeatures = &device_features,
		enabledExtensionCount = len(VK_REQUIRED_EXTENSIONS),
		ppEnabledExtensionNames = &VK_REQUIRED_EXTENSIONS[0],
		enabledLayerCount = 0,
	}

	when VK_ENABLE_VALIDATION_LAYERS {
		device_create_info.enabledLayerCount = cast(u32)len(vk_debug_data.validation_layers)
		device_create_info.ppEnabledLayerNames = raw_data(vk_debug_data.validation_layers)
	}

	if result := vk.CreateDevice(vk_device.physical_device, &device_create_info, nil, &vk_device.device); result != .SUCCESS {
		return make_vk_error("Failed to create a Vulkan logical device.", result)
	}

	vk.GetDeviceQueue(vk_device.device, vk_device.queue_family_list.graphics, 0, &vk_device.queue_list.graphics)
	vk.GetDeviceQueue(vk_device.device, vk_device.queue_family_list.present, 0, &vk_device.queue_list.present)

	return nil
}

@(private)
VK_INVALID_QUEUE_FAMILY_INDEX :: max(u32)

// SWAPCHAIN ------------------------------------------------------------------------------------------------------------------------------------

Vk_Swap_Chain_Support_Details :: struct {
	capabilities: vk.SurfaceCapabilitiesKHR,
	formats: []vk.SurfaceFormatKHR,
	present_modes: []vk.PresentModeKHR,
}

@(private)
get_swapchain_support :: proc(surface: vk.SurfaceKHR, physical_device: vk.PhysicalDevice) -> Vk_Swap_Chain_Support_Details {
	swapchain_support_details := Vk_Swap_Chain_Support_Details{}
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, &swapchain_support_details.capabilities)

	format_count: u32 = ---
	vk.GetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, nil)
	if format_count > 0 {
		swapchain_support_details.formats = make([]vk.SurfaceFormatKHR, int(format_count))
		vk.GetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, raw_data(swapchain_support_details.formats))
	}

	present_mode_count: u32 = ---
	vk.GetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &present_mode_count, nil)
	if present_mode_count > 0 {
		swapchain_support_details.present_modes = make([]vk.PresentModeKHR, int(present_mode_count))
		vk.GetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &present_mode_count, raw_data(swapchain_support_details.present_modes))
	}

	return swapchain_support_details
}

@(private)
free_swapchain_support :: proc(data: ^Vk_Swap_Chain_Support_Details) {
	if data.formats != nil {
		delete(data.formats)
	}
	if data.present_modes != nil {
		delete(data.present_modes)
	}
}

@(private)
choose_swapchain_surface_format :: proc(formats: []vk.SurfaceFormatKHR) -> vk.SurfaceFormatKHR {
	assert(len(formats) > 0)
	for format in formats {
		if format.format == .B8G8R8A8_SRGB && format.colorSpace == .SRGB_NONLINEAR {
			return format
		}
	}
	return formats[0]
}

@(private)
choose_swapchain_present_mode :: proc(present_modes: []vk.PresentModeKHR) -> vk.PresentModeKHR {
	// TODO: This should be up to the user to decide
	// has_immediate := false
	// for present_mode in present_modes {
	// 	if present_mode == .MAILBOX {
	// 		return .MAILBOX
	// 	} else if present_mode == .IMMEDIATE {
	// 		has_immediate = true
	// 	}
	// }
	// if has_immediate {
	// 	return .IMMEDIATE
	// }
	return .FIFO
}

@(private)
choose_swapchain_extent :: proc(surface_capabilities: vk.SurfaceCapabilitiesKHR) -> vk.Extent2D {
	if surface_capabilities.currentExtent.width != max(u32) {
		return surface_capabilities.currentExtent
	}

	// TODO: Select the correct window
	width, height := platform.get_window_client_size(0)
	return vk.Extent2D{
		width = clamp(width, surface_capabilities.minImageExtent.width, surface_capabilities.maxImageExtent.width),
		height = clamp(height, surface_capabilities.minImageExtent.height, surface_capabilities.maxImageExtent.height),
	}
}

@(private)
create_swapchain :: proc(vk_surface: ^Vk_Surface) -> Result {
	assert(vk_surface.swapchain == 0, "Swapchain has already been created for this surface.")

	swapchain_support := get_swapchain_support(vk_surface.surface, g_vk.device_data.physical_device)
	defer free_swapchain_support(&swapchain_support)
	surface_format := choose_swapchain_surface_format(swapchain_support.formats[:])
	present_mode := choose_swapchain_present_mode(swapchain_support.present_modes[:])
	extent := choose_swapchain_extent(swapchain_support.capabilities)
	image_count := swapchain_support.capabilities.minImageCount + 1
	// 0 means there is no maximum, so there's no need to clamp the count
	if swapchain_support.capabilities.maxImageCount > 0 {
		image_count = min(image_count, swapchain_support.capabilities.maxImageCount)
	}

	swapchain_create_info := vk.SwapchainCreateInfoKHR{
		sType = .SWAPCHAIN_CREATE_INFO_KHR,
		surface = vk_surface.surface,
		minImageCount = image_count,
		imageFormat = surface_format.format,
		imageColorSpace = surface_format.colorSpace,
		imageExtent = extent,
		imageArrayLayers = 1,
		imageUsage = {.COLOR_ATTACHMENT},
		preTransform = swapchain_support.capabilities.currentTransform,
		compositeAlpha = {.OPAQUE},
		presentMode = present_mode,
		clipped = true,
		oldSwapchain = 0,
		imageSharingMode = .EXCLUSIVE,
	}

	queue_indices := [2]u32{}
	if g_vk.device_data.queue_family_list.graphics != g_vk.device_data.queue_family_list.present {
		queue_indices = {
			g_vk.device_data.queue_family_list.graphics,
			g_vk.device_data.queue_family_list.present,
		}
		swapchain_create_info.imageSharingMode = .CONCURRENT
		swapchain_create_info.queueFamilyIndexCount = 2
		swapchain_create_info.pQueueFamilyIndices = &queue_indices[0]
	}

	if result := vk.CreateSwapchainKHR(g_vk.device_data.device, &swapchain_create_info, nil, &vk_surface.swapchain); result != .SUCCESS {
		return make_vk_error("Failed to create the Swapchain.", result)
	}

	vk.GetSwapchainImagesKHR(g_vk.device_data.device, vk_surface.swapchain, &image_count, nil)
	resize(&vk_surface.swapchain_images, int(image_count))
	vk.GetSwapchainImagesKHR(g_vk.device_data.device, vk_surface.swapchain, &image_count, raw_data(vk_surface.swapchain_images))

	vk_surface.swapchain_image_format = surface_format.format
	vk_surface.swapchain_extent = extent

	return nil
}

@(private)
create_swapchain_image_views :: proc(vk_surface: ^Vk_Surface) -> Result {
	assert(vk_surface != nil)

	resize(&vk_surface.swapchain_image_views, len(vk_surface.swapchain_images))
	for image, i in vk_surface.swapchain_images {
		vk_surface.swapchain_image_views[i] = vk_create_image_view(image, 1, vk_surface.swapchain_image_format, {.COLOR}) or_return
	}
	
	return nil
}

@(private)
request_recreate_swapchain :: proc(is_minimized: bool) {
	assert(g_rhi != nil)
	g_rhi.recreate_swapchain_requested = true
	g_rhi.is_minimized = is_minimized
}

@(private)
destroy_swapchain :: proc(vk_surface: ^Vk_Surface) {
	for iv in vk_surface.swapchain_image_views {
		vk.DestroyImageView(g_vk.device_data.device, iv, nil)
	}
	clear(&vk_surface.swapchain_image_views)

	vk.DestroySwapchainKHR(g_vk.device_data.device, vk_surface.swapchain, nil)
	vk_surface.swapchain = 0
}

@(private)
recreate_swapchain :: proc(vk_surface: ^Vk_Surface) -> Result {
	assert(g_rhi != nil)
	g_rhi.recreate_swapchain_requested = false

	vk.DeviceWaitIdle(g_vk.device_data.device)

	destroy_swapchain(vk_surface)

	create_swapchain(vk_surface) or_return
	create_swapchain_image_views(vk_surface) or_return
	dimensions: [2]u32 = {vk_surface.swapchain_extent.width, vk_surface.swapchain_extent.height}

	core.broadcaster_broadcast(&g_rhi.callbacks.on_recreate_swapchain_broadcaster, Args_Recreate_Swapchain{0, dimensions})

	return nil
}

// FRAMEBUFFERS ------------------------------------------------------------------------------------------------------------------------------------

vk_create_framebuffer :: proc(render_pass: vk.RenderPass, attachments: []vk.ImageView, dimensions: [2]u32) -> (framebuffer: vk.Framebuffer, result: Result) {
	framebuffer_create_info := vk.FramebufferCreateInfo{
		sType = .FRAMEBUFFER_CREATE_INFO,
		renderPass = render_pass,
		attachmentCount = cast(u32) len(attachments),
		pAttachments = raw_data(attachments),
		width = dimensions.x,
		height = dimensions.y,
		layers = 1,
	}

	if r := vk.CreateFramebuffer(g_vk.device_data.device, &framebuffer_create_info, nil, &framebuffer); r != .SUCCESS {
		result = make_vk_error("Failed to create a Framebuffer.", r)
		return
	}

	return
}

vk_destroy_framebuffer :: proc(framebuffer: vk.Framebuffer) {
	vk.DestroyFramebuffer(g_vk.device_data.device, framebuffer, nil)
}

// RENDER PASSES ------------------------------------------------------------------------------------------------------------------------------------

vk_create_render_pass :: proc(desc: Render_Pass_Desc) -> (render_pass: vk.RenderPass, result: Result) {
	if len(desc.attachments) == 0 {
		result = make_vk_error("Invalid attachment count specified when creating a render pass.")
		return
	}

	has_color_attachment: bool
	color_attachment_references := make([dynamic]vk.AttachmentReference, context.temp_allocator)
	reserve(&color_attachment_references, 8)

	has_depth_attachment: bool
	depth_attachment_reference := vk.AttachmentReference{
		layout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
	}

	attachments := make([]vk.AttachmentDescription, len(desc.attachments), context.temp_allocator)
	for a, i in desc.attachments {
		attachments[i] = vk.AttachmentDescription{
			format = conv_format_to_vk(a.format),
			samples = {._1},
			loadOp = conv_load_op_to_vk(a.load_op),
			storeOp = conv_store_op_to_vk(a.store_op),
			initialLayout = conv_image_layout_to_vk(a.from_layout),
			finalLayout = conv_image_layout_to_vk(a.to_layout),
		}

		switch a.usage {
		case .Color:
			attachments[i].stencilLoadOp = .DONT_CARE
			attachments[i].stencilStoreOp = .DONT_CARE

			ref := vk.AttachmentReference{
				attachment = cast(u32)i,
				layout = .COLOR_ATTACHMENT_OPTIMAL,
			}
			append(&color_attachment_references, ref)
			has_color_attachment = true

		case .Depth_Stencil:
			attachments[i].stencilLoadOp = conv_load_op_to_vk(a.stencil_load_op)
			attachments[i].stencilStoreOp = conv_store_op_to_vk(a.stencil_store_op)

			if has_depth_attachment {
				log.error("Render pass already has a depth-stencil attachment.")
			} else {
				depth_attachment_reference.attachment = cast(u32)i
				has_depth_attachment = true
			}
		}
	}

	subpass_description := vk.SubpassDescription{
		pipelineBindPoint = .GRAPHICS,
	}
	if has_color_attachment {
		subpass_description.colorAttachmentCount = cast(u32)len(color_attachment_references)
		subpass_description.pColorAttachments = &color_attachment_references[0]
	}
	if has_depth_attachment {
		subpass_description.pDepthStencilAttachment = &depth_attachment_reference
	}

	subpass_dependency := vk.SubpassDependency{
		srcSubpass = vk.SUBPASS_EXTERNAL,
		dstSubpass = 0,
		srcStageMask = desc.src_dependency.stage_mask,
		srcAccessMask = desc.src_dependency.access_mask,
		dstStageMask = desc.dst_dependency.stage_mask,
		dstAccessMask = desc.dst_dependency.access_mask,
	}

	render_pass_create_info := vk.RenderPassCreateInfo{
		sType = .RENDER_PASS_CREATE_INFO,
		attachmentCount = cast(u32)len(attachments),
		pAttachments = &attachments[0],
		subpassCount = 1,
		pSubpasses = &subpass_description,
		dependencyCount = 1,
		pDependencies = &subpass_dependency,
	}

	if r := vk.CreateRenderPass(g_vk.device_data.device, &render_pass_create_info, nil, &render_pass); r != .SUCCESS {
		result = make_vk_error("Failed to create a Render Pass.", r)
		return
	}

	return render_pass, nil
}

vk_destroy_render_pass :: proc(render_pass: vk.RenderPass) {
	vk.DestroyRenderPass(g_vk.device_data.device, render_pass, nil)
}

// SHADERS ------------------------------------------------------------------------------------------------------------------------------------

vk_create_shader_from_source_file :: proc(source_path: string, shader_type: Shader_Type, entry_point: string) -> (shader: vk.ShaderModule, result: Result) {
	source_bytes, read_ok := os.read_entire_file_from_filename(source_path)
	defer delete(source_bytes)
	if !read_ok {
		result = make_vk_error(fmt.tprintf("Failed to load the Shader source code from %s file.", source_path))
		return
	}

	source := string(source_bytes)
	bytecode, compile_ok := compile_shader(source, source_path, shader_type, entry_point)
	defer free_shader_bytecode(bytecode)
	if !compile_ok {
		result = make_vk_error(fmt.tprintf("Failed to compile the Shader byte code from %s.", source_path))
		return
	}

	return vk_create_shader(bytecode)
}

vk_create_shader_from_source :: proc(source: string, source_name: string, shader_type: Shader_Type, entry_point: string) -> (shader: vk.ShaderModule, result: Result) {
	bytecode, ok := compile_shader(source, source_name, shader_type, entry_point)
	defer free_shader_bytecode(bytecode)
	if !ok {
		result = make_vk_error(fmt.tprintf("Failed to compile the Shader byte code from %s.", source_name))
		return
	}

	return vk_create_shader(bytecode)
}

vk_create_shader_from_spv_file :: proc(spv_path: string) -> (shader: vk.ShaderModule, result: Result) {
	bytecode, ok := os.read_entire_file_from_filename(spv_path)
	defer delete(bytecode)
	if !ok {
		result = make_vk_error(fmt.tprintf("Failed to load the Shader byte code from %s file.", spv_path))
		return
	}

	return vk_create_shader(bytecode)
}

vk_create_shader :: proc(bytecode: Shader_Bytecode) -> (shader: vk.ShaderModule, result: Result) {
	shader_module_create_info := vk.ShaderModuleCreateInfo{
		sType = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(bytecode),
		pCode = cast(^u32)&bytecode[0],
	}

	if r := vk.CreateShaderModule(g_vk.device_data.device, &shader_module_create_info, nil, &shader); r != .SUCCESS {
		result = make_vk_error("Failed to create a Shader Module", r)
		return
	}

	return
}

vk_destroy_shader :: proc(shader: vk.ShaderModule) {
	vk.DestroyShaderModule(g_vk.device_data.device, shader, nil)
}

// PIPELINES ------------------------------------------------------------------------------------------------------------------------------------

vk_create_pipeline_layout :: proc(layout_desc: Pipeline_Layout_Description) -> (layout: vk.PipelineLayout, result: Result) {
	layout_create_info := vk.PipelineLayoutCreateInfo{
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
	}

	descriptor_set_layout_count := len(layout_desc.descriptor_set_layouts)
	if descriptor_set_layout_count > 0 {
		set_layouts := make([]vk.DescriptorSetLayout, descriptor_set_layout_count, context.temp_allocator)
		for &l, i in layout_desc.descriptor_set_layouts {
			assert(l != nil)
			set_layouts[i] = l.(vk.DescriptorSetLayout)
		}
		layout_create_info.setLayoutCount = cast(u32)descriptor_set_layout_count
		layout_create_info.pSetLayouts = &set_layouts[0]
	}

	if len(layout_desc.push_constants) > 0 {
		push_constant_ranges := make([]vk.PushConstantRange, len(layout_desc.push_constants), context.temp_allocator)
		for range, i in layout_desc.push_constants {
			push_constant_ranges[i] = vk.PushConstantRange{
				offset = range.offset,
				size = range.size,
				stageFlags = conv_shader_stages_to_vk(range.shader_stage),
			}
		}
		layout_create_info.pPushConstantRanges = raw_data(push_constant_ranges)
		layout_create_info.pushConstantRangeCount = cast(u32) len(push_constant_ranges)
	}

	if r := vk.CreatePipelineLayout(g_vk.device_data.device, &layout_create_info, nil, &layout); r != .SUCCESS {
		result = make_vk_error("Failed to create a Pipeline Layout.", r)
		return
	}

	return
}

vk_destroy_pipeline_layout :: proc(layout: vk.PipelineLayout) {
	vk.DestroyPipelineLayout(g_vk.device_data.device, layout, nil)
}

vk_create_graphics_pipeline :: proc(pipeline_desc: Pipeline_Description, render_pass: vk.RenderPass, layout: vk.PipelineLayout) -> (pipeline: vk.Pipeline, result: Result) {
	shader_stages := make([]vk.PipelineShaderStageCreateInfo, len(pipeline_desc.shader_stages), context.temp_allocator)
	specialization_infos := make([]vk.SpecializationInfo, len(pipeline_desc.shader_stages), context.temp_allocator)

	for stage, i in pipeline_desc.shader_stages {
		if stage.specializations != nil {
			specialization_info := &specialization_infos[i]
			specializations_data, specializations_type := reflect.any_data(stage.specializations)
			specializations_size := reflect.size_of_typeid(specializations_type)
			specialization_fields := reflect.struct_fields_zipped(specializations_type)
			specialization_map_entries := make([]vk.SpecializationMapEntry, len(specialization_fields), context.temp_allocator)
			specialization_info^ = vk.SpecializationInfo{
				mapEntryCount = cast(u32)len(specialization_fields),
				pMapEntries = &specialization_map_entries[0],
				dataSize = specializations_size,
				pData = specializations_data,
			}
			for field, i in specialization_fields {
				entry := &specialization_map_entries[i]
				entry^ = vk.SpecializationMapEntry{
					constantID = u32(i),
					offset = u32(field.offset),
					size = field.type.size,
				}
			}
		}

		shader_stages[i] = vk.PipelineShaderStageCreateInfo{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = conv_shader_stages_to_vk({stage.type}),
			module = stage.shader.(vk.ShaderModule),
			pName = "main",
		}
		if stage.specializations != nil {
			shader_stages[i].pSpecializationInfo = &specialization_infos[i]
		}
	}

	dynamic_states := [?]vk.DynamicState{
		.VIEWPORT,
		.SCISSOR,
		.CULL_MODE,
	}
	dynamic_state_create_info := vk.PipelineDynamicStateCreateInfo{
		sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = len(dynamic_states),
		pDynamicStates = &dynamic_states[0],
	}

	vertex_input_state_create_info := vk.PipelineVertexInputStateCreateInfo{
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}
	if len(pipeline_desc.vertex_input.bindings) > 0 {
		vertex_input_binding_descriptions := make([]vk.VertexInputBindingDescription, len(pipeline_desc.vertex_input.bindings), context.temp_allocator)
		for binding, i in pipeline_desc.vertex_input.bindings {
			vertex_input_binding_descriptions[i] = vk.VertexInputBindingDescription{
				binding = binding.binding,
				stride = binding.stride,
				inputRate = conv_vertex_input_rate_to_vk(binding.input_rate),
			}
		}
		vertex_input_attribute_descriptions := make([]vk.VertexInputAttributeDescription, len(pipeline_desc.vertex_input.attributes), context.temp_allocator)
		for attr, i in pipeline_desc.vertex_input.attributes {
			vk_format := conv_format_to_vk(attr.format)
			vertex_input_attribute_descriptions[i] = vk.VertexInputAttributeDescription{
				binding = attr.binding,
				format = vk_format,
				location = cast(u32) i,
				offset = attr.offset,
			}
		}

		vertex_input_state_create_info.vertexBindingDescriptionCount = cast(u32)len(vertex_input_binding_descriptions)
		vertex_input_state_create_info.pVertexBindingDescriptions = &vertex_input_binding_descriptions[0]
		vertex_input_state_create_info.vertexAttributeDescriptionCount = cast(u32)len(vertex_input_attribute_descriptions)
		vertex_input_state_create_info.pVertexAttributeDescriptions = &vertex_input_attribute_descriptions[0]
	}

	input_assembly_state_create_info := vk.PipelineInputAssemblyStateCreateInfo{
		sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = conv_primitive_topology_to_vk(pipeline_desc.input_assembly.topology),
		primitiveRestartEnable = b32(false),
	}

	// TODO: With dynamic viewport/scissor state, the state set up here is ignored
	viewport := vk.Viewport{
		x = 0.0,
		y = 0.0,
		width = cast(f32) pipeline_desc.viewport_dims.x,
		height = cast(f32) pipeline_desc.viewport_dims.y,
		minDepth = 0.0,
		maxDepth = 1.0,
	}
	scissor := vk.Rect2D{
		offset = {0, 0},
		extent = {
			width = pipeline_desc.viewport_dims.x,
			height = pipeline_desc.viewport_dims.y,
		},
	}
	viewport_state_create_info := vk.PipelineViewportStateCreateInfo{
		sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		pViewports = &viewport,
		scissorCount = 1,
		pScissors = &scissor,
	}

	rasterization_state_create_info := vk.PipelineRasterizationStateCreateInfo{
		sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		depthClampEnable = false,
		rasterizerDiscardEnable = false,
		polygonMode = .FILL,
		lineWidth = 1.0,
		cullMode = {.BACK},
		frontFace = .CLOCKWISE,
		depthBiasEnable = false,
	}

	multisample_state_create_info := vk.PipelineMultisampleStateCreateInfo{
		sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		sampleShadingEnable = false,
		rasterizationSamples = {._1},
	}

	color_blend_attachment_state := vk.PipelineColorBlendAttachmentState{
		colorWriteMask = {.R, .G, .B, .A},
		blendEnable = true,
		// TODO: Extract the hardcoded blending from here
		srcColorBlendFactor = .SRC_ALPHA,
		dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
		colorBlendOp = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ZERO,
		alphaBlendOp = .ADD,
	}

	color_blend_state_create_info := vk.PipelineColorBlendStateCreateInfo{
		sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		logicOpEnable = false,
		logicOp = .COPY,
		attachmentCount = 1,
		pAttachments = &color_blend_attachment_state,
		blendConstants = {0.0, 0.0, 0.0, 0.0},
	}

	depth_stencil_state_create_info := vk.PipelineDepthStencilStateCreateInfo{
		sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable = cast(b32)pipeline_desc.depth_stencil.depth_test,
		depthWriteEnable = cast(b32)pipeline_desc.depth_stencil.depth_write,
		depthCompareOp = conv_compare_op_to_vk(pipeline_desc.depth_stencil.depth_compare_op),
		depthBoundsTestEnable = false,
		minDepthBounds = 0.0,
		maxDepthBounds = 1.0,
		stencilTestEnable = false,
		front = {},
		back = {},
	}

	pipeline_create_info := vk.GraphicsPipelineCreateInfo{
		sType = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount = cast(u32) len(pipeline_desc.shader_stages),
		pStages = &shader_stages[0],
		pVertexInputState = &vertex_input_state_create_info,
		pInputAssemblyState = &input_assembly_state_create_info,
		pViewportState = &viewport_state_create_info,
		pRasterizationState = &rasterization_state_create_info,
		pMultisampleState = &multisample_state_create_info,
		pDepthStencilState = &depth_stencil_state_create_info,
		pColorBlendState = &color_blend_state_create_info,
		pDynamicState = &dynamic_state_create_info,
		layout = layout,
		renderPass = render_pass, // <-- referenced for compatibility only
		subpass = 0,
		basePipelineHandle = 0,
		basePipelineIndex = -1,
	}

	if r := vk.CreateGraphicsPipelines(g_vk.device_data.device, 0, 1, &pipeline_create_info, nil, &pipeline); r != .SUCCESS {
		result = make_vk_error("Failed to create a Graphics Pipeline.", r)
		return
	}

	return
}

vk_destroy_graphics_pipeline :: proc(pipeline: vk.Pipeline) {
	vk.DestroyPipeline(g_vk.device_data.device, pipeline, nil)
}

// COMMAND BUFFERS & POOLS ------------------------------------------------------------------------------------------------------------------------------------

vk_create_command_pool :: proc(queue_family_index: u32) -> (command_pool: vk.CommandPool, result: Result) {
	create_info := vk.CommandPoolCreateInfo{
		sType = .COMMAND_POOL_CREATE_INFO,
		flags = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = queue_family_index,
	}

	if r := vk.CreateCommandPool(g_vk.device_data.device, &create_info, nil, &command_pool); r != .SUCCESS {
		result = make_vk_error("Failed to create a Command Pool.", r)
		return
	}

	return command_pool, nil
}

vk_begin_one_time_cmd_buffer :: proc() -> (cmd_buffer: vk.CommandBuffer, result: Result) {
	cmd_buffer_alloc_info := vk.CommandBufferAllocateInfo{
		sType = .COMMAND_BUFFER_ALLOCATE_INFO,
		level = .PRIMARY,
		commandPool = g_vk.command_pool,
		commandBufferCount = 1,
	}
	if r := vk.AllocateCommandBuffers(g_vk.device_data.device, &cmd_buffer_alloc_info, &cmd_buffer); r != .SUCCESS {
		result = make_vk_error("Failed to allocate a command buffer to copy a buffer.", r)
		return
	}

	cmd_buffer_begin_info := vk.CommandBufferBeginInfo{
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	if r := vk.BeginCommandBuffer(cmd_buffer, &cmd_buffer_begin_info); r != .SUCCESS {
		result = make_vk_error("Failed to begin a command buffer.", r)
		return
	}

	return
}

vk_end_one_time_cmd_buffer :: proc(cmd_buffer: vk.CommandBuffer) -> Result {
	cmd_buffer := cmd_buffer

	if r := vk.EndCommandBuffer(cmd_buffer); r != .SUCCESS {
		return make_vk_error("Failed to end a command buffer.", r)
	}

	submit_info := vk.SubmitInfo{
		sType = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers = &cmd_buffer,
	}
	// TODO: Can be a dedicated transfer queue
	if r := vk.QueueSubmit(g_vk.device_data.queue_list.graphics, 1, &submit_info, 0); r != .SUCCESS {
		return make_vk_error("Failed to submit a command buffer.", r)
	}
	if r := vk.QueueWaitIdle(g_vk.device_data.queue_list.graphics); r != .SUCCESS {
		return make_vk_error("Failed to wait for a queue to idle.", r)
	}

	vk.FreeCommandBuffers(g_vk.device_data.device, g_vk.command_pool, 1, &cmd_buffer)

	return nil
}

vk_allocate_command_buffers :: proc(command_pool: vk.CommandPool, $N: uint) -> (cb: [N]vk.CommandBuffer, result: Result) {
	allocate_info := vk.CommandBufferAllocateInfo{
		sType = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool = command_pool,
		level = .PRIMARY,
		commandBufferCount = cast(u32) N,
	}

	if r := vk.AllocateCommandBuffers(g_vk.device_data.device, &allocate_info, &cb[0]); r != .SUCCESS {
		result = make_vk_error("Failed to allocate Command Buffers.", r)
		return
	}

	return
}

// DESCRIPTORS ------------------------------------------------------------------------------------------------------------------------------------

vk_create_descriptor_pool :: proc(pool_desc: Descriptor_Pool_Desc) -> (pool: vk.DescriptorPool, result: Result) {
	pool_sizes := make([]vk.DescriptorPoolSize, len(pool_desc.pool_sizes), context.temp_allocator)
	for pool_size, i in pool_desc.pool_sizes {
		pool_sizes[i] = vk.DescriptorPoolSize{
			type = conv_descriptor_type_to_vk(pool_size.type),
			descriptorCount = cast(u32) pool_size.count,
		}
	}

	create_info := vk.DescriptorPoolCreateInfo{
		sType = .DESCRIPTOR_POOL_CREATE_INFO,
		poolSizeCount = cast(u32) len(pool_sizes),
		pPoolSizes = &pool_sizes[0],
		maxSets = cast(u32) pool_desc.max_sets,
	}

	if r := vk.CreateDescriptorPool(g_vk.device_data.device, &create_info, nil, &pool); r != .SUCCESS {
		result = make_vk_error("Failed to create a Descriptor Pool.", r)
		return
	}

	return
}

vk_destroy_descriptor_pool :: proc(pool: vk.DescriptorPool) {
	vk.DestroyDescriptorPool(g_vk.device_data.device, pool, nil)
}

vk_create_descriptor_set :: proc(
	descriptor_pool: vk.DescriptorPool,
	descriptor_set_layout: vk.DescriptorSetLayout,
	descriptor_set_desc: Descriptor_Set_Desc,
	name := "",
) -> (set: vk.DescriptorSet, result: Result) {
	layout := descriptor_set_layout

	alloc_info := vk.DescriptorSetAllocateInfo{
		sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool = descriptor_pool,
		descriptorSetCount = 1,
		pSetLayouts = &layout,
	}
	if r := vk.AllocateDescriptorSets(g_vk.device_data.device, &alloc_info, &set); r != .SUCCESS {
		result = make_vk_error("Failed to allocate Descriptor Sets.", r)
		return
	}

	descriptor_writes := make([]vk.WriteDescriptorSet, len(descriptor_set_desc.descriptors), context.temp_allocator)
	for d, i in descriptor_set_desc.descriptors {
		descriptor_writes[i] = vk.WriteDescriptorSet{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = set,
			dstBinding = d.binding,
			dstArrayElement = 0,
			descriptorType = conv_descriptor_type_to_vk(d.type),
			descriptorCount = d.count,
			pBufferInfo = nil,
			pImageInfo = nil,
			pTexelBufferView = nil,
		}
		switch info in d.info {
		case Descriptor_Buffer_Info:
			assert(info.buffer != nil)
			buffer_info := new(vk.DescriptorBufferInfo, context.temp_allocator)
			buffer_info^ = vk.DescriptorBufferInfo{
				buffer = info.buffer.(Vk_Buffer).buffer,
				offset = cast(vk.DeviceSize) info.offset,
				range = cast(vk.DeviceSize) info.size,
			}
			descriptor_writes[i].pBufferInfo = buffer_info
		case Descriptor_Texture_Info:
			assert(info.texture != nil)
			assert(info.sampler != nil)
			image_info := new(vk.DescriptorImageInfo, context.temp_allocator)
			image_info^ = vk.DescriptorImageInfo{
				imageLayout = .SHADER_READ_ONLY_OPTIMAL,
				imageView = info.texture.(Vk_Texture).image_view,
				sampler = info.sampler.(vk.Sampler),
			}
			descriptor_writes[i].pImageInfo = image_info
		}
	}

	vk.UpdateDescriptorSets(g_vk.device_data.device, cast(u32) len(descriptor_writes), &descriptor_writes[0], 0, nil)

	vk_set_debug_object_name(set, .DESCRIPTOR_SET, name)

	return
}

vk_create_descriptor_set_layout :: proc(layout_description: Descriptor_Set_Layout_Description) -> (layout: vk.DescriptorSetLayout, result: Result) {
	bindings := make([]vk.DescriptorSetLayoutBinding, len(layout_description.bindings), context.temp_allocator)
	for b, i in layout_description.bindings {
		type := conv_descriptor_type_to_vk(b.type)
		stages := conv_shader_stages_to_vk(b.shader_stage)

		bindings[i] = vk.DescriptorSetLayoutBinding{
			binding = b.binding,
			descriptorType = type,
			descriptorCount = b.count,
			stageFlags = stages,
			pImmutableSamplers = nil,
		}
	}

	layout_info := vk.DescriptorSetLayoutCreateInfo{
		sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = cast(u32) len(bindings),
		pBindings = &bindings[0],
	}

	if r := vk.CreateDescriptorSetLayout(g_vk.device_data.device, &layout_info, nil, &layout); r != .SUCCESS {
		result = make_vk_error("Failed to create a Descriptor Set Layout.", r)
		return
	}

	return
}

vk_destroy_descriptor_set_layout :: proc(layout: vk.DescriptorSetLayout) {
	vk.DestroyDescriptorSetLayout(g_vk.device_data.device, layout, nil)
}

// BUFFERS ------------------------------------------------------------------------------------------------------------------------------------

Vk_Buffer :: struct {
	buffer: vk.Buffer,
	allocation: Vk_Memory_Allocation,
}

vk_create_buffer :: proc(size: vk.DeviceSize, usage: vk.BufferUsageFlags, property_flags: vk.MemoryPropertyFlags, name := "") -> (buffer: vk.Buffer, allocation: Vk_Memory_Allocation, result: Result) {
	create_info := vk.BufferCreateInfo{
		sType = .BUFFER_CREATE_INFO,
		size = size,
		usage = usage,
		sharingMode = .EXCLUSIVE,
	}
	if r := vk.CreateBuffer(g_vk.device_data.device, &create_info, nil, &buffer); r != .SUCCESS {
		result = make_vk_error("Failed to create a Buffer.", r)
		return
	}

	memory_requirements: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(g_vk.device_data.device, buffer, &memory_requirements)

	memory_type := vk_find_proper_memory_type(memory_requirements.memoryTypeBits, property_flags) or_return
	allocation = vk_allocate_memory(memory_requirements.size, memory_type) or_return

	if r := vk.BindBufferMemory(g_vk.device_data.device, buffer, allocation.block.device_memory, allocation.offset); r != .SUCCESS {
		result = make_vk_error("Failed to bind Buffer memory.", r)
		return
	}

	vk_set_debug_object_name(buffer, .BUFFER, name) or_return

	return
}

// TODO: Create one (or more) BIG staging ring buffer(s) for generic data uploads
vk_create_staging_buffer :: proc(size: vk.DeviceSize, name := "") -> (buffer: vk.Buffer, memory: vk.DeviceMemory, result: Result) {
	create_info := vk.BufferCreateInfo{
		sType = .BUFFER_CREATE_INFO,
		size = size,
		usage = {.TRANSFER_SRC},
		sharingMode = .EXCLUSIVE,
	}
	if r := vk.CreateBuffer(g_vk.device_data.device, &create_info, nil, &buffer); r != .SUCCESS {
		result = make_vk_error("Failed to create a Staging Buffer.", r)
		return
	}

	memory_requirements: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(g_vk.device_data.device, buffer, &memory_requirements)

	memory_type := vk_find_proper_memory_type(memory_requirements.memoryTypeBits, {.HOST_COHERENT, .HOST_VISIBLE}) or_return
	alloc_info := vk.MemoryAllocateInfo{
		sType = .MEMORY_ALLOCATE_INFO,
		allocationSize = memory_requirements.size,
		memoryTypeIndex = memory_type,
	}

	if r := vk.AllocateMemory(g_vk.device_data.device, &alloc_info, nil, &memory); r != .SUCCESS {
		result = make_vk_error("Failed to allocate memory for a Staging Buffer.", r)
		return
	}

	if r := vk.BindBufferMemory(g_vk.device_data.device, buffer, memory, 0); r != .SUCCESS {
		result = make_vk_error("Failed to bind Staging Buffer memory.", r)
		return
	}

	vk_set_debug_object_name(buffer, .BUFFER, name) or_return

	return
}

vk_destroy_buffer :: proc(buffer: Vk_Buffer) {
	vk.DestroyBuffer(g_vk.device_data.device, buffer.buffer, nil)
	vk_free_memory(buffer.allocation)
}

vk_create_vertex_buffer :: proc(buffer_desc: Buffer_Desc, vertices: []$V, name := "", map_memory := false) -> (buffer: vk.Buffer, allocation: Vk_Memory_Allocation, result: Result) {
	vertices := vertices

	buffer_size := cast(vk.DeviceSize) (size_of(V) * len(vertices))
	staging_buffer_name := fmt.tprintf("%s_STAGING", name)
	staging_buffer, staging_buffer_memory := vk_create_staging_buffer(buffer_size, staging_buffer_name) or_return

	data: rawptr
	if r := vk.MapMemory(g_vk.device_data.device, staging_buffer_memory, 0, buffer_size, {}, &data); r != .SUCCESS {
		result = make_vk_error("Failed to map the Staging Buffer's memory.", r)
		return
	}

	mem.copy_non_overlapping(data, raw_data(vertices), cast(int) buffer_size)

	vk.UnmapMemory(g_vk.device_data.device, staging_buffer_memory)

	memory_flags := conv_memory_flags_to_vk(buffer_desc.memory_flags)
	buffer, allocation = vk_create_buffer(buffer_size, {.VERTEX_BUFFER, .TRANSFER_DST}, memory_flags, name) or_return

	vk_copy_buffer(staging_buffer, buffer, buffer_size) or_return

	vk.DestroyBuffer(g_vk.device_data.device, staging_buffer, nil)
	vk.FreeMemory(g_vk.device_data.device, staging_buffer_memory, nil)

	if map_memory {
		vk_map_memory(&allocation) or_return
	}

	return
}

vk_create_vertex_buffer_empty :: proc(buffer_desc: Buffer_Desc, $Element: typeid, elem_count: u32, name := "", map_memory := true) -> (buffer: vk.Buffer, allocation: Vk_Memory_Allocation, result: Result) {
	buffer_size := cast(vk.DeviceSize) (size_of(Element) * elem_count)
	memory_flags := conv_memory_flags_to_vk(buffer_desc.memory_flags)
	buffer, allocation = vk_create_buffer(buffer_size, {.VERTEX_BUFFER}, memory_flags, name) or_return

	if map_memory {
		vk_map_memory(&allocation) or_return
	}

	return
}

vk_create_index_buffer :: proc(buffer_desc: Buffer_Desc, indices: []u32, name := "", map_memory := false) -> (buffer: vk.Buffer, allocation: Vk_Memory_Allocation, result: Result) {
	indices := indices

	buffer_size := cast(vk.DeviceSize) (size_of(u32) * len(indices))
	staging_buffer_name := fmt.tprintf("%s_STAGING", name)
	staging_buffer, staging_buffer_memory := vk_create_staging_buffer(buffer_size, staging_buffer_name) or_return

	data: rawptr
	if r := vk.MapMemory(g_vk.device_data.device, staging_buffer_memory, 0, buffer_size, {}, &data); r != .SUCCESS {
		result = make_vk_error("Failed to map the Staging Buffer's memory.", r)
		return
	}

	mem.copy_non_overlapping(data, raw_data(indices), cast(int) buffer_size)

	vk.UnmapMemory(g_vk.device_data.device, staging_buffer_memory)

	memory_flags := conv_memory_flags_to_vk(buffer_desc.memory_flags)
	buffer, allocation = vk_create_buffer(buffer_size, {.INDEX_BUFFER, .TRANSFER_DST}, memory_flags, name) or_return

	vk_copy_buffer(staging_buffer, buffer, buffer_size) or_return

	vk.DestroyBuffer(g_vk.device_data.device, staging_buffer, nil)
	vk.FreeMemory(g_vk.device_data.device, staging_buffer_memory, nil)

	if map_memory {
		vk_map_memory(&allocation) or_return
	}

	return
}

vk_create_index_buffer_empty :: proc(buffer_desc: Buffer_Desc, $Element: typeid, elem_count: u32, name := "", map_memory := true) -> (buffer: vk.Buffer, allocation: Vk_Memory_Allocation, result: Result) {
	buffer_size := cast(vk.DeviceSize) (size_of(Element) * elem_count)
	memory_flags := conv_memory_flags_to_vk(buffer_desc.memory_flags)
	buffer, allocation = vk_create_buffer(buffer_size, {.INDEX_BUFFER}, memory_flags, name) or_return

	if map_memory {
		vk_map_memory(&allocation) or_return
	}

	return
}

vk_create_uniform_buffer :: proc(buffer_desc: Buffer_Desc, size: uint, name := "") -> (buffer: vk.Buffer, allocation: Vk_Memory_Allocation, result: Result) {
	device_size := cast(vk.DeviceSize)size
	memory_flags := conv_memory_flags_to_vk(buffer_desc.memory_flags)
	buffer, allocation = vk_create_buffer(device_size, {.UNIFORM_BUFFER}, memory_flags, name) or_return
	vk_map_memory(&allocation) or_return

	return
}

vk_copy_buffer :: proc(src_buffer: vk.Buffer, dst_buffer: vk.Buffer, size: vk.DeviceSize) -> Result {
	command_buffer := vk_begin_one_time_cmd_buffer() or_return

	copy_region := vk.BufferCopy{
		srcOffset = 0,
		dstOffset = 0,
		size = size,
	}
	vk.CmdCopyBuffer(command_buffer, src_buffer, dst_buffer, 1, &copy_region)

	vk_end_one_time_cmd_buffer(command_buffer) or_return

	return nil
}

// IMAGES ------------------------------------------------------------------------------------------------------------------------------------

Vk_Depth :: struct {
	using Vk_Texture,
}

Vk_Texture :: struct {
	image: vk.Image,
	image_view: vk.ImageView,
	allocation: Vk_Memory_Allocation,
}

vk_cmd_transition_image_layout :: proc(cb: vk.CommandBuffer, image: vk.Image, mip_levels: u32, from, to: Texture_Barrier_Desc) {
	barrier := vk.ImageMemoryBarrier{
		sType = .IMAGE_MEMORY_BARRIER,
		oldLayout = conv_image_layout_to_vk(from.layout),
		newLayout = conv_image_layout_to_vk(to.layout),
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image,
		subresourceRange = {
			aspectMask = {.COLOR},
			baseMipLevel = 0,
			levelCount = mip_levels,
			baseArrayLayer = 0,
			layerCount = 1,
		},
		srcAccessMask = from.access_mask,
		dstAccessMask = to.access_mask,
	}

	vk.CmdPipelineBarrier(cb, from.stage_mask, to.stage_mask, {}, 0, nil, 0, nil, 1, &barrier)
}

vk_transition_image_layout :: proc(image: vk.Image, mip_levels: u32, from_layout: vk.ImageLayout, to_layout: vk.ImageLayout) -> Result {
	cmd_buffer := vk_begin_one_time_cmd_buffer() or_return

	src_stage, dst_stage: vk.PipelineStageFlags
	src_access, dst_access: vk.AccessFlags

	if from_layout == .UNDEFINED && to_layout == .TRANSFER_DST_OPTIMAL {
		src_access = {}
		dst_access = {.TRANSFER_WRITE}
		src_stage = {.TOP_OF_PIPE}
		dst_stage = {.TRANSFER}
	} else if from_layout == .UNDEFINED && to_layout == .SHADER_READ_ONLY_OPTIMAL {
		src_access = {}
		dst_access = {.SHADER_READ}
		src_stage = {.TOP_OF_PIPE}
		dst_stage = {.FRAGMENT_SHADER}
	} else if from_layout == .TRANSFER_DST_OPTIMAL && to_layout == .SHADER_READ_ONLY_OPTIMAL {
		src_access = {.TRANSFER_WRITE}
		dst_access = {.SHADER_READ}
		src_stage = {.TRANSFER}
		dst_stage = {.FRAGMENT_SHADER}
	} else {
		return make_vk_error("Unsupported image layout transition.")
	}

	barrier := vk.ImageMemoryBarrier{
		sType = .IMAGE_MEMORY_BARRIER,
		oldLayout = from_layout,
		newLayout = to_layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image,
		subresourceRange = {
			aspectMask = {.COLOR},
			baseMipLevel = 0,
			levelCount = mip_levels,
			baseArrayLayer = 0,
			layerCount = 1,
		},
		srcAccessMask = src_access,
		dstAccessMask = dst_access,
	}

	vk.CmdPipelineBarrier(cmd_buffer, src_stage, dst_stage, {}, 0, nil, 0, nil, 1, &barrier)

	vk_end_one_time_cmd_buffer(cmd_buffer) or_return

	return nil
}

vk_copy_buffer_to_image :: proc(src_buffer: vk.Buffer, dst_image: vk.Image, dimensions: [2]u32) -> Result {
	cmd_buffer := vk_begin_one_time_cmd_buffer() or_return

	region := vk.BufferImageCopy{
		bufferOffset = 0,
		bufferRowLength = 0,
		bufferImageHeight = 0,
		imageSubresource = {
			aspectMask = {.COLOR},
			mipLevel = 0,
			baseArrayLayer = 0,
			layerCount = 1,
		},
		imageOffset = {0, 0, 0},
		imageExtent = {
			width = dimensions.x,
			height = dimensions.y,
			depth = 1,
		},
	}

	vk.CmdCopyBufferToImage(cmd_buffer, src_buffer, dst_image, .TRANSFER_DST_OPTIMAL, 1, &region)

	vk_end_one_time_cmd_buffer(cmd_buffer) or_return

	return nil
}

vk_create_image :: proc(
	dimensions: [2]u32,
	mip_levels: u32,
	format: vk.Format,
	tiling: vk.ImageTiling,
	usage: vk.ImageUsageFlags,
	properties: vk.MemoryPropertyFlags,
	name := "",
) -> (image: vk.Image, allocation: Vk_Memory_Allocation, result: Result) {
	image_info := vk.ImageCreateInfo{
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		extent = {
			width = dimensions.x,
			height = dimensions.y,
			depth = 1,
		},
		mipLevels = mip_levels,
		arrayLayers = 1,
		format = format,
		tiling = tiling,
		initialLayout = .UNDEFINED,
		usage = usage,
		sharingMode = .EXCLUSIVE,
		samples = {._1},
		flags = {},
	}

	if r := vk.CreateImage(g_vk.device_data.device, &image_info, nil, &image); r != .SUCCESS {
		result = make_vk_error("Failed to create an Image.", r)
		return
	}

	memory_requirements: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(g_vk.device_data.device, image, &memory_requirements)

	memory_type := vk_find_proper_memory_type(memory_requirements.memoryTypeBits, properties) or_return
	allocation = vk_allocate_memory(memory_requirements.size, memory_type, memory_requirements.alignment) or_return
	
	if r := vk.BindImageMemory(g_vk.device_data.device, image, allocation.block.device_memory, allocation.offset); r != .SUCCESS {
		result = make_vk_error("Failed to bind Image memory.", r)
		return
	}

	vk_set_debug_object_name(image, .IMAGE, name) or_return

	return
}

vk_create_image_view :: proc(image: vk.Image, mip_levels: u32, format: vk.Format, aspect_mask: vk.ImageAspectFlags, name := "") -> (image_view: vk.ImageView, result: Result) {
	image_view_info := vk.ImageViewCreateInfo{
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = image,
		viewType = .D2,
		format = format,
		subresourceRange = {
			aspectMask = aspect_mask,
			baseMipLevel = 0,
			levelCount = mip_levels,
			baseArrayLayer = 0,
			layerCount = 1,
		},
		components = {
			r = .IDENTITY,
			g = .IDENTITY,
			b = .IDENTITY,
			a = .IDENTITY,
		},
	}

	if r := vk.CreateImageView(g_vk.device_data.device, &image_view_info, nil, &image_view); r != .SUCCESS {
		result = make_vk_error("Failed to create an Image View.", r)
		return
	}

	vk_set_debug_object_name(image_view, .IMAGE_VIEW, name) or_return

	return
}

vk_create_depth_image_resources :: proc(dimensions: [2]u32) -> (depth_resources: Vk_Depth, result: Result) {
	// TODO: Find a suitable supported format
	format: vk.Format = .D24_UNORM_S8_UINT
	depth_resources.image, depth_resources.allocation = vk_create_image(dimensions, 1, format, .OPTIMAL, {.DEPTH_STENCIL_ATTACHMENT}, {.DEVICE_LOCAL}) or_return
	depth_resources.image_view = vk_create_image_view(depth_resources.image, 1, format, {.DEPTH}) or_return

	return
}

vk_destroy_depth_image_resources :: proc(depth_resources: ^Vk_Depth) {
	vk.DestroyImageView(g_vk.device_data.device, depth_resources.image_view, nil)
	vk.DestroyImage(g_vk.device_data.device, depth_resources.image, nil)
	vk_free_memory(depth_resources.allocation)

	mem.zero_item(depth_resources)
}

vk_create_texture_image :: proc(image_buffer: []byte, dimensions: [2]u32, format: vk.Format, name := "") -> (texture: Vk_Texture, mip_levels: u32, result: Result) {
	max_dim := cast(f32) linalg.max(dimensions)
	mip_levels = cast(u32) math.floor(math.log2(max_dim)) + 1
	
	image_name := fmt.tprintf("Image_%s", name)
	texture.image, texture.allocation = vk_create_image(dimensions, mip_levels, format, .OPTIMAL, {.TRANSFER_SRC, .TRANSFER_DST, .SAMPLED, .COLOR_ATTACHMENT}, {.DEVICE_LOCAL}, image_name) or_return
	
	if image_buffer != nil {
		image_size := cast(vk.DeviceSize) len(image_buffer)

		staging_buffer_name := fmt.tprintf("Image_%s_STAGING", name)
		staging_buffer, staging_buffer_memory := vk_create_staging_buffer(image_size, staging_buffer_name) or_return
		defer {
			vk.DestroyBuffer(g_vk.device_data.device, staging_buffer, nil)
			vk.FreeMemory(g_vk.device_data.device, staging_buffer_memory, nil)
		}
	
		data: rawptr
		if r := vk.MapMemory(g_vk.device_data.device, staging_buffer_memory, 0, image_size, {}, &data); r != .SUCCESS {
			result = make_vk_error("Failed to map the Staging Buffer's memory.", r)
		}
	
		mem.copy_non_overlapping(data, raw_data(image_buffer), cast(int) image_size)
	
		vk.UnmapMemory(g_vk.device_data.device, staging_buffer_memory)
	
		vk_transition_image_layout(texture.image, mip_levels, .UNDEFINED, .TRANSFER_DST_OPTIMAL) or_return
		vk_copy_buffer_to_image(staging_buffer, texture.image, dimensions) or_return
		
		// Generate mipmaps
		
		cmd_buffer := vk_begin_one_time_cmd_buffer() or_return
		barrier := vk.ImageMemoryBarrier{
			sType = .IMAGE_MEMORY_BARRIER,
			image = texture.image,
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			subresourceRange = {
				aspectMask = {.COLOR},
				baseArrayLayer = 0,
				layerCount = 1,
				levelCount = 1,
			},
		}
	
		src_mip_dims := dimensions
		for dst_level in 1..<mip_levels {
			src_level := dst_level - 1
			dst_mip_dims := src_mip_dims
			if dst_mip_dims.x > 1 do dst_mip_dims.x /= 2
			if dst_mip_dims.y > 1 do dst_mip_dims.y /= 2
		
			barrier.subresourceRange.baseMipLevel = src_level
			barrier.oldLayout = .TRANSFER_DST_OPTIMAL
			barrier.newLayout = .TRANSFER_SRC_OPTIMAL
			barrier.srcAccessMask = {.TRANSFER_WRITE}
			barrier.dstAccessMask = {.TRANSFER_READ}
			vk.CmdPipelineBarrier(cmd_buffer, {.TRANSFER}, {.TRANSFER}, {}, 0, nil, 0, nil, 1, &barrier)
	
			blit := vk.ImageBlit{
				srcOffsets = {{0, 0, 0}, {cast(i32) src_mip_dims.x, cast(i32) src_mip_dims.y, 1}},
				srcSubresource = {
					aspectMask = {.COLOR},
					mipLevel = src_level,
					baseArrayLayer = 0,
					layerCount = 1,
				},
				dstOffsets = {{0, 0, 0}, {cast(i32) dst_mip_dims.x, cast(i32) dst_mip_dims.y, 1}},
				dstSubresource = {
					aspectMask = {.COLOR},
					mipLevel = dst_level,
					baseArrayLayer = 0,
					layerCount = 1,
				},
			}
			// Assumes the device supports linear blitting for the image's format
			vk.CmdBlitImage(cmd_buffer, texture.image, .TRANSFER_SRC_OPTIMAL, texture.image, .TRANSFER_DST_OPTIMAL, 1, &blit, .LINEAR)
	
			// Transition the current src mip, as it won't be used during generation anymore
			barrier.oldLayout = .TRANSFER_SRC_OPTIMAL
			barrier.newLayout = .SHADER_READ_ONLY_OPTIMAL
			barrier.srcAccessMask = {.TRANSFER_READ}
			barrier.dstAccessMask = {.SHADER_READ}
			vk.CmdPipelineBarrier(cmd_buffer, {.TRANSFER}, {.FRAGMENT_SHADER}, {}, 0, nil, 0, nil, 1, &barrier)
	
			if src_mip_dims.x > 1 do src_mip_dims.x /= 2
			if src_mip_dims.y > 1 do src_mip_dims.y /= 2
		}
		// Transition the last mip
		barrier.subresourceRange.baseMipLevel = mip_levels - 1
		barrier.oldLayout = .TRANSFER_DST_OPTIMAL
		barrier.newLayout = .SHADER_READ_ONLY_OPTIMAL
		barrier.srcAccessMask = {.TRANSFER_READ}
		barrier.dstAccessMask = {.SHADER_READ}
		vk.CmdPipelineBarrier(cmd_buffer, {.TRANSFER}, {.FRAGMENT_SHADER}, {}, 0, nil, 0, nil, 1, &barrier)
	
		vk_end_one_time_cmd_buffer(cmd_buffer) or_return
	} else {
		vk_transition_image_layout(texture.image, mip_levels, .UNDEFINED, .SHADER_READ_ONLY_OPTIMAL) or_return
	}

	image_view_name := fmt.tprintf("ImageView_%s", name)
	texture.image_view = vk_create_image_view(texture.image, mip_levels, format, {.COLOR}, image_view_name) or_return

	return
}

vk_destroy_texture_image :: proc(texture: ^Vk_Texture) {
	assert(texture != nil)
	vk.DestroyImageView(g_vk.device_data.device, texture.image_view, nil)
	vk.DestroyImage(g_vk.device_data.device, texture.image, nil)
	vk_free_memory(texture.allocation)
}

// SAMPLERS ------------------------------------------------------------------------------------------------------------------------------------

vk_create_texture_sampler :: proc(mip_levels: u32, filter: vk.Filter, address_mode: vk.SamplerAddressMode) -> (sampler: vk.Sampler, result: Result) {
	device_properties: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(g_vk.device_data.physical_device, &device_properties)

	sampler_info := vk.SamplerCreateInfo{
		sType = .SAMPLER_CREATE_INFO,
		magFilter = filter,
		minFilter = filter,
		addressModeU = address_mode,
		addressModeV = address_mode,
		addressModeW = address_mode,
		anisotropyEnable = true,
		maxAnisotropy = device_properties.limits.maxSamplerAnisotropy,
		borderColor = .INT_OPAQUE_BLACK,
		unnormalizedCoordinates = false,
		compareEnable = false,
		compareOp = .ALWAYS,
		mipmapMode = .LINEAR,
		mipLodBias = 0.0,
		minLod = 0.0,
		maxLod = cast(f32) mip_levels,
	}

	if r := vk.CreateSampler(g_vk.device_data.device, &sampler_info, nil, &sampler); r != .SUCCESS {
		result = make_vk_error("Failed to create a Sampler.", r)
		return
	}

	return
}

// SYNCHRONIZATION ------------------------------------------------------------------------------------------------------------------------------------

Vk_Sync :: struct {
	image_available_semaphore: vk.Semaphore,
	draw_finished_semaphore: vk.Semaphore,
	in_flight_fence: vk.Fence,
}

@(private)
vk_create_main_sync_objects :: proc() -> (sync_objects: [MAX_FRAMES_IN_FLIGHT]Vk_Sync, result: Result) {
	semaphore_create_info := vk.SemaphoreCreateInfo{
		sType = .SEMAPHORE_CREATE_INFO,
	}

	fence_create_info := vk.FenceCreateInfo{
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}

	for &frame_sync_objects in sync_objects {
		if r := vk.CreateSemaphore(g_vk.device_data.device, &semaphore_create_info, nil, &frame_sync_objects.draw_finished_semaphore); r != .SUCCESS {
			result = make_vk_error("Failed to create a Semaphore.", r)
			return
		}
		if r := vk.CreateSemaphore(g_vk.device_data.device, &semaphore_create_info, nil, &frame_sync_objects.image_available_semaphore); r != .SUCCESS {
			result = make_vk_error("Failed to create a Semaphore.", r)
			return
		}
		if r := vk.CreateFence(g_vk.device_data.device, &fence_create_info, nil, &frame_sync_objects.in_flight_fence); r != .SUCCESS {
			result = make_vk_error("Failed to create a Fence.", r)
			return
		}
	}

	return
}

vk_create_semaphores :: proc() -> (semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore, result: Result) {
	semaphore_create_info := vk.SemaphoreCreateInfo{
		sType = .SEMAPHORE_CREATE_INFO,
	}

	for &semaphore in semaphores {
		if r := vk.CreateSemaphore(g_vk.device_data.device, &semaphore_create_info, nil, &semaphore); r != .SUCCESS {
			result = make_vk_error("Failed to create a Semaphore.", r)
			return
		}
	}

	return
}

@(private)
vk_destroy_main_sync_objects :: proc(sync_objects: [MAX_FRAMES_IN_FLIGHT]Vk_Sync) {
	for frame_sync_objects in sync_objects {
		vk.DestroySemaphore(g_vk.device_data.device, frame_sync_objects.draw_finished_semaphore, nil)
		vk.DestroySemaphore(g_vk.device_data.device, frame_sync_objects.image_available_semaphore, nil)
		vk.DestroyFence(g_vk.device_data.device, frame_sync_objects.in_flight_fence, nil)
	}
}

// MEMORY ------------------------------------------------------------------------------------------------------------------------------------

VK_DEFAULT_MEMORY_BLOCK_SIZE :: 128 * mem.Megabyte
VK_DEFAULT_MEMORY_ALIGNMENT :: 256

Vk_Memory_Allocation :: struct {
	block: ^Vk_Memory_Block,
	offset: vk.DeviceSize,
	size: vk.DeviceSize,
	mapped_memory: []byte,
}

Vk_Memory_Type_State :: struct {
	blocks: map[vk.DeviceMemory]^Vk_Memory_Block,
}

Vk_Memory_State :: struct {
	types: [vk.MAX_MEMORY_TYPES]Vk_Memory_Type_State,
}

Vk_Memory_Block :: struct {
	device_memory: vk.DeviceMemory,
	size: vk.DeviceSize,
	memory_type: u32,

	mapped_memory: rawptr,

	// Current bump allocator offset
	// TODO: Implement more allocators
	cursor_offset: vk.DeviceSize,
}

vk_memory_shutdown :: proc() {
	for &mt in g_vk.memory_state.types {
		for _, b in mt.blocks {
			free(b)
		}
		delete(mt.blocks)
	}
}

vk_allocate_memory_block :: proc(size: vk.DeviceSize, memory_type: u32) -> (block: ^Vk_Memory_Block, result: Result) {
	alloc_info := vk.MemoryAllocateInfo{
		sType = .MEMORY_ALLOCATE_INFO,
		allocationSize = size,
		memoryTypeIndex = memory_type,
	}

	device_memory: vk.DeviceMemory
	if r := vk.AllocateMemory(g_vk.device_data.device, &alloc_info, nil, &device_memory); r != nil {
		result = make_vk_error("Failed to allocate memory", r)
		return
	}

	block = new(Vk_Memory_Block)
	block.device_memory = device_memory
	block.size = size
	block.memory_type = memory_type
	
	mem_type_state := &g_vk.memory_state.types[memory_type]
	map_insert(&mem_type_state.blocks, block.device_memory, block)

	return
}

vk_free_memory_block :: proc(block: ^Vk_Memory_Block) {
	assert(block != nil)

	vk.FreeMemory(g_vk.device_data.device, block.device_memory, nil)

	mem_type_state := &g_vk.memory_state.types[block.memory_type]
	delete_key(&mem_type_state.blocks, block.device_memory)

	free(block)
}

vk_find_proper_memory_block :: proc(size: vk.DeviceSize, memory_type: u32) -> ^Vk_Memory_Block {
	mem_type_state := &g_vk.memory_state.types[memory_type]
	for k, block in mem_type_state.blocks {
		free_bytes := vk_calc_block_free_bytes(block^)
		if size <= free_bytes {
			return block
		}
	}
	return nil
}

vk_get_block_used_bytes :: proc(block: Vk_Memory_Block) -> vk.DeviceSize {
	return block.cursor_offset
}

vk_calc_block_free_bytes :: proc(block: Vk_Memory_Block) -> vk.DeviceSize {
	return block.size - block.cursor_offset
}

vk_map_memory_block :: proc(block: ^Vk_Memory_Block) -> (mapped_memory: []byte, result: Result) {
	assert(block != nil)
	assert(block.device_memory != 0)
	assert(block.size > 0)
	if block.mapped_memory == nil {
		if r := vk.MapMemory(g_vk.device_data.device, block.device_memory, 0, block.size, {}, &block.mapped_memory); r != nil {
			result = make_vk_error(fmt.tprintf("Failed to map memory block vk.DeviceMemory{%x}", block.device_memory), r)
			return
		}
	}
	mapped_memory = slice.bytes_from_ptr(block.mapped_memory, cast(int)block.size)
	return
}

vk_allocate_memory :: proc(size: vk.DeviceSize, memory_type: u32, alignment: vk.DeviceSize = VK_DEFAULT_MEMORY_ALIGNMENT) -> (allocation: Vk_Memory_Allocation, result: Result) {
	assert(size > 0)
	aligned_size := cast(vk.DeviceSize)mem.align_forward_uintptr(cast(uintptr)size, cast(uintptr)alignment)
	assert(aligned_size <= VK_DEFAULT_MEMORY_BLOCK_SIZE)

	block := vk_find_proper_memory_block(size, memory_type)
	if block == nil {
		block = vk_allocate_memory_block(VK_DEFAULT_MEMORY_BLOCK_SIZE, memory_type) or_return
	}

	aligned_cursor_offset := cast(vk.DeviceSize)mem.align_forward_uint(cast(uint)block.cursor_offset, cast(uint)alignment)
	padding := aligned_cursor_offset - block.cursor_offset

	free_bytes_in_block := vk_calc_block_free_bytes(block^)
	if aligned_size > (free_bytes_in_block - padding) {
		block = vk_allocate_memory_block(VK_DEFAULT_MEMORY_BLOCK_SIZE, memory_type) or_return
	}

	assert(block != nil)

	allocation.block = block
	allocation.offset = aligned_cursor_offset
	allocation.size = aligned_size

	block.cursor_offset = aligned_cursor_offset + aligned_size

	return
}

vk_allocate_buffer_memory :: proc(buffer: vk.Buffer, memory_properties: Memory_Property_Flags) -> (allocation: Vk_Memory_Allocation, result: Result) {
	memory_properties := conv_memory_flags_to_vk(memory_properties)

	memory_requirements: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(g_vk.device_data.device, buffer, &memory_requirements)

	memory_type := vk_find_proper_memory_type(memory_requirements.memoryTypeBits, memory_properties) or_return

	allocation = vk_allocate_memory(memory_requirements.size, memory_type) or_return

	return
}

vk_free_memory :: proc(allocation: Vk_Memory_Allocation) {
	// NOTE: For now, allocations are done in a bump allocator like manner, so it's not possible to free individual allocations.
}

vk_map_memory :: proc(allocation: ^Vk_Memory_Allocation) -> (result: Result) {
	assert(allocation != nil)
	memory := vk_map_memory_block(allocation.block) or_return
	allocation.mapped_memory = memory[allocation.offset : allocation.offset+allocation.size]
	return
}

// VULKAN RHI STATE ------------------------------------------------------------------------------------------------------------------------------------

Vk_State :: struct {
	instance_data: Vk_Instance,
	device_data: Vk_Device,
	surfaces: map[Surface_Key]Vk_Surface,
	command_pool: vk.CommandPool,
	sync_objects: [MAX_FRAMES_IN_FLIGHT]Vk_Sync,
	memory_state: Vk_Memory_State,
}

// Global state pointer set during initialization for convenience (like g_rhi)
@(private)
g_vk: ^Vk_State

// DEBUG ------------------------------------------------------------------------------------------------------------------------------------

vk_set_debug_object_name :: proc(object: $T/u64, type: vk.ObjectType, name: string) -> Result {
	if len(name) > 0 {
		name_cstring := strings.clone_to_cstring(name, context.temp_allocator)
		name_info := vk.DebugUtilsObjectNameInfoEXT{
			sType = .DEBUG_UTILS_OBJECT_NAME_INFO_EXT,
			pNext = nil,
			objectType  = type,
			objectHandle = cast(u64)object,
			pObjectName = name_cstring,
		}
		if r := vk.SetDebugUtilsObjectNameEXT(g_vk.device_data.device, &name_info); r != .SUCCESS {
			return make_vk_error("Failed to set debug object name.", r)
		}
	}
	return nil
}

VK_ENABLE_VALIDATION_LAYERS :: ODIN_DEBUG when !FORCE_VALIDATION_LAYERS else true

when VK_ENABLE_VALIDATION_LAYERS {
	@(private)
	make_debug_utils_messenger_create_info :: proc() -> vk.DebugUtilsMessengerCreateInfoEXT {
		return vk.DebugUtilsMessengerCreateInfoEXT{
			sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			messageSeverity = {
				.VERBOSE,
				.INFO,
				.WARNING,
				.ERROR,
			},
			messageType = {
				.GENERAL,
				.VALIDATION,
				.PERFORMANCE,
			},
			pfnUserCallback = debug_message_callback,
			pUserData = nil,
		}
	}

	@(private)
	init_debug_messenger :: proc() -> Result {
		create_info := make_debug_utils_messenger_create_info()
		if result := vk.CreateDebugUtilsMessengerEXT(g_vk.instance_data.instance, &create_info, nil, &vk_debug_data.debug_messenger); result != .SUCCESS {
			return make_vk_error("Failed to create Vulkan Debug Utils Messenger.", result)
		}
		return nil
	}

	@(private)
	shutdown_debug_messenger :: proc() {
		vk.DestroyDebugUtilsMessengerEXT(g_vk.instance_data.instance, vk_debug_data.debug_messenger, nil)
	}

	@(private)
	debug_message_callback :: proc "system" (
		message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
		message_types: vk.DebugUtilsMessageTypeFlagsEXT,
		callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
		user_data: rawptr,
	) -> b32 {
		context = runtime.default_context()

		message_severity_value := transmute(vk.DebugUtilsMessageSeverityFlagEXT) message_severity

		level: runtime.Logger_Level
		level_string: string
		if uint(message_severity_value) >= 1<<uint(vk.DebugUtilsMessageSeverityFlagEXT.VERBOSE) {
			level = .Debug
			level_string = "Verbose"
		}
		if uint(message_severity_value) >= 1<<uint(vk.DebugUtilsMessageSeverityFlagEXT.INFO) {
			level = .Info
			level_string = "Info"
		}
		if uint(message_severity_value) >= 1<<uint(vk.DebugUtilsMessageSeverityFlagEXT.WARNING) {
			level = .Warning
			level_string = "Warning"
		}
		if uint(message_severity_value) >= 1<<uint(vk.DebugUtilsMessageSeverityFlagEXT.ERROR) {
			level = .Error
			level_string = "Error"
		}

		text := fmt.tprintf("[Vulkan][%s] %s\n", level_string, callback_data.pMessage)

		platform.log_to_native_console(nil, level, text, {})
		return false
	}

	@(private)
	Vk_Debug :: struct {
		validation_layers: [dynamic]cstring,
		debug_messenger: vk.DebugUtilsMessengerEXT,
	}

	@(private)
	vk_debug_data: Vk_Debug
}
