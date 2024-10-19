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
import "core:strings"
import "core:slice"
import "core:time"
import "vendor:cgltf"
import vk "vendor:vulkan"
// TODO: Remove windows from here
import w "core:sys/windows"

import "sm:platform"
import "sm:core"

// CONFIG
FORCE_VALIDATION_LAYERS :: true

make_vk_error :: proc(message: string, result: Maybe(vk.Result) = nil) -> RHI_Error {
	error := RHI_Error{
		error_message = message,
	}
	if result != nil {
		error.rhi_data = cast(u64) result.(vk.Result)
	}
	return error
}

conv_format_to_vk :: proc(format: Format) -> vk.Format {
	switch format {
	case .RGBA8_SRGB: return .R8G8B8A8_SRGB
	case .BGRA8_SRGB: return .B8G8R8A8_SRGB
	case .D24S8: return .D24_UNORM_S8_UINT
	case .R32F: return .R32_SFLOAT
	case .RG32F: return .R32G32_SFLOAT
	case .RGB32F: return .R32G32B32_SFLOAT
	case .RGBA32F: return .R32G32B32A32_SFLOAT
	case: return .UNDEFINED
	}
}

conv_format_from_vk :: proc(vk_format: vk.Format) -> Format {
	// Keep in sync with conv_format_to_vk
	#partial switch vk_format {
	case .R8G8B8A8_SRGB: return .RGBA8_SRGB
	case .B8G8R8A8_SRGB: return .BGRA8_SRGB
	case .D24_UNORM_S8_UINT: return .D24S8
	case .R32_SFLOAT: return .R32F
	case .R32G32_SFLOAT: return .RG32F
	case .R32G32B32_SFLOAT: return .RGB32F
	case .R32G32B32A32_SFLOAT: return .RGBA32F
	case: return nil
	}
}

conv_descriptor_type_to_vk :: proc(type: Descriptor_Type) -> vk.DescriptorType {
	switch type {
	case .UNIFORM_BUFFER:         return .UNIFORM_BUFFER
	case .COMBINED_IMAGE_SAMPLER: return .COMBINED_IMAGE_SAMPLER
	case: panic("Invalid descriptor type.")
	}
}

conv_shader_stages_to_vk :: proc(stages: Shader_Stage_Flags) -> vk.ShaderStageFlags {
	vk_stage: vk.ShaderStageFlags
	if .VERTEX in stages   do vk_stage += {.VERTEX}
	if .FRAGMENT in stages do vk_stage += {.FRAGMENT}
	return vk_stage
}

conv_compare_op_to_vk :: proc(op: Compare_Op) -> vk.CompareOp {
	switch op {
	case .NEVER:            return .NEVER
	case .LESS:             return .LESS
	case .EQUAL:            return .EQUAL
	case .LESS_OR_EQUAL:    return .LESS_OR_EQUAL
	case .GREATER:          return .GREATER
	case .NOT_EQUAL:        return .NOT_EQUAL
	case .GREATER_OR_EQUAL: return .GREATER_OR_EQUAL
	case .ALWAYS:           return .ALWAYS
	case: panic("Invalid compare op.")
	}
}

conv_memory_flags_to_vk :: proc(flags: Buffer_Memory_Flags) -> vk.MemoryPropertyFlags {
	vk_flags: vk.MemoryPropertyFlags
	if .DEVICE_LOCAL  in flags do vk_flags += {.DEVICE_LOCAL}
	if .HOST_VISIBLE  in flags do vk_flags += {.HOST_VISIBLE}
	if .HOST_COHERENT in flags do vk_flags += {.HOST_COHERENT}
	return vk_flags
}

conv_vertex_input_rate_to_vk :: proc(rate: Vertex_Input_Rate) -> vk.VertexInputRate {
	switch rate {
	case .VERTEX:   return .VERTEX
	case .INSTANCE: return .INSTANCE
	case: panic("Invalid vertex input rate.")
	}
}

MAX_FRAMES_IN_FLIGHT :: 2

ENGINE_NAME :: "Spelmotor"
KHRONOS_VALIDATION_LAYER_NAME :: "VK_LAYER_KHRONOS_validation"

@(private)
_init :: proc(rhi_init: RHI_Init) -> RHI_Result {
	vk_data.main_window_handle = rhi_init.main_window_handle

	platform_load_vulkan_lib() or_return

	instance_data: ^Vk_Instance = &vk_data.instance_data

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
		pApplicationName = strings.clone_to_cstring(rhi_init.app_name, context.temp_allocator),
		applicationVersion = vk.MAKE_VERSION(rhi_init.ver.app_maj_ver, rhi_init.ver.app_min_ver, rhi_init.ver.app_patch_ver),
		pEngineName = cstring(ENGINE_NAME),
		engineVersion = vk.MAKE_VERSION(1, 0, 0),
		apiVersion = vk.API_VERSION_1_0,
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

	// At least one surface will need to be created to initialize the RHI
	main_surface: ^Vk_Surface = create_surface_internal(vk_data.main_window_handle) or_return

	vk_data.device_data = create_device(instance_data.instance, main_surface^) or_return
	device_data := &vk_data.device_data

	create_swapchain(device_data^, main_surface) or_return
	create_swapchain_image_views(device_data^, main_surface) or_return

	vk_data.command_pool = vk_create_command_pool(device_data.device, device_data.queue_family_list.graphics) or_return

	vk_data.sync_objects = vk_create_main_sync_objects(device_data.device) or_return

	vk_data.current_frame = 0
	vk_data.recreate_swapchain_requested = false

	return nil
}

init_window :: proc(handle: platform.Window_Handle) -> RHI_Result {
	vk_surface := create_surface_internal(handle) or_return
	create_swapchain(vk_data.device_data, vk_surface) or_return
	create_swapchain_image_views(vk_data.device_data, vk_surface) or_return

	return nil
}

@(private)
_shutdown :: proc() {
	device: vk.Device = vk_data.device_data.device

	vk_destroy_main_sync_objects(device, vk_data.sync_objects)

	vk.DestroyCommandPool(device, vk_data.command_pool, nil)

	assert(len(vk_data.surfaces) > 0)

	for &surface, index in vk_data.surfaces {
		if surface.surface != 0 {
			destroy_surface_and_swapchain(vk_data.instance_data.instance, device, &surface)
		}
	}

	vk.DestroyDevice(device, nil)

	vk_data.device_data.device = nil
	vk_data.device_data.physical_device = nil

	when VK_ENABLE_VALIDATION_LAYERS {
		shutdown_debug_messenger()
	}
	
	vk.DestroyInstance(vk_data.instance_data.instance, nil)

	// Free memory:

	for surface in vk_data.surfaces {
		delete(surface.swapchain_images)
		delete(surface.swapchain_image_views)
	}

	delete(vk_data.instance_data.supported_extensions)
	delete(vk_data.instance_data.extensions)
	delete(vk_data.surfaces)

	when VK_ENABLE_VALIDATION_LAYERS {
		delete(vk_debug_data.validation_layers)
	}

	core.broadcaster_delete(&callbacks.on_recreate_swapchain_broadcaster)
}

@(private)
_create_surface :: proc(window: platform.Window_Handle) -> (surface: RHI_Surface, result: RHI_Result) {
	create_surface_internal(window) or_return
	surface = cast(RHI_Surface) window
	return
}

@(private)
_wait_and_acquire_image :: proc() -> (image_index: Maybe(uint), result: RHI_Result) {
	device := vk_data.device_data.device
	surface := &vk_data.surfaces[0]
	swapchain := surface.swapchain

	vk.WaitForFences(device, 1, &vk_data.sync_objects[vk_data.current_frame].in_flight_fence, true, max(u64))

	if vk_data.is_minimized {
		return nil, nil
	}

	if vk_data.recreate_swapchain_requested {
		recreate_swapchain(vk_data.device_data, surface)
		vk.DeviceWaitIdle(vk_data.device_data.device)
		surface = &vk_data.surfaces[0]
		swapchain = surface.swapchain
	}

	vk_image_index: u32
	if result := vk.AcquireNextImageKHR(device, swapchain, max(u64), vk_data.sync_objects[vk_data.current_frame].image_available_semaphore, 0, &vk_image_index); result != .SUCCESS {
		if result == .ERROR_OUT_OF_DATE_KHR {
			recreate_swapchain(vk_data.device_data, surface)
			return cast(uint) vk_image_index, nil
		} else if result != .SUBOPTIMAL_KHR {
			return nil, make_vk_error("Failed to acquire the next image.", result)
		}
	}

	vk.ResetFences(device, 1, &vk_data.sync_objects[vk_data.current_frame].in_flight_fence)

	return cast(uint) vk_image_index, nil
}

@(private)
_queue_submit_for_drawing :: proc(command_buffer: ^RHI_CommandBuffer) -> RHI_Result {
	wait_stages := [?]vk.PipelineStageFlags{
		{.COLOR_ATTACHMENT_OUTPUT},
	}

	cmd_buffer := command_buffer.(Vk_CommandBuffer).command_buffer
	submit_info := vk.SubmitInfo{
		sType = .SUBMIT_INFO,
		waitSemaphoreCount = 1,
		pWaitSemaphores = &vk_data.sync_objects[vk_data.current_frame].image_available_semaphore,
		pWaitDstStageMask = &wait_stages[0],
		commandBufferCount = 1,
		pCommandBuffers = &cmd_buffer,
		signalSemaphoreCount = 1,
		pSignalSemaphores = &vk_data.sync_objects[vk_data.current_frame].draw_finished_semaphore,
	}

	if result := vk.QueueSubmit(vk_data.device_data.queue_list.graphics, 1, &submit_info, vk_data.sync_objects[vk_data.current_frame].in_flight_fence); result != .SUCCESS {
		return make_vk_error("Failed to submit a Queue.", result)
	}

	return nil
}

@(private)
_present :: proc(image_index: uint) -> RHI_Result {
	vk_image_index := cast(u32) image_index
	surface := &vk_data.surfaces[0]
	swapchain := surface.swapchain

	present_info := vk.PresentInfoKHR{
		sType = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores = &vk_data.sync_objects[vk_data.current_frame].draw_finished_semaphore,
		swapchainCount = 1,
		pSwapchains = &swapchain,
		pImageIndices = &vk_image_index,
	}

	if r := vk.QueuePresentKHR(vk_data.device_data.queue_list.present, &present_info); r != .SUCCESS {
		if r == .ERROR_OUT_OF_DATE_KHR || r == .SUBOPTIMAL_KHR || vk_data.recreate_swapchain_requested {
			recreate_swapchain(vk_data.device_data, surface)
			return nil
		}
		return make_vk_error("Failed to present a Queue.", r)
	}

	return nil
}

_get_frame_in_flight :: proc() -> uint {
	return cast(uint) vk_data.current_frame
}

@(private)
_process_platform_events :: proc(window: platform.Window_Handle, event: platform.System_Event) {
	#partial switch e in event {
	case platform.Window_Resized_Event:
		is_minimized := e.type == .Minimize || e.width == 0 || e.height == 0
		request_recreate_swapchain(is_minimized)
	}
}

@(private)
_wait_for_device :: proc() -> RHI_Result {
	if result := vk.DeviceWaitIdle(vk_data.device_data.device); result != .SUCCESS {
		return make_vk_error("Failed to wait for a device.", result)
	}

	return nil
}

@(private)
request_recreate_swapchain :: proc(is_minimized: bool) {
	vk_data.recreate_swapchain_requested = true
	vk_data.is_minimized = is_minimized
}

@(private)
create_surface_internal :: proc(window_handle: platform.Window_Handle) -> (vk_surface: ^Vk_Surface, result: RHI_Result) {
	surface: vk.SurfaceKHR = platform_create_surface(window_handle) or_return
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
create_device :: proc(instance: vk.Instance, vk_surface: Vk_Surface) -> (vk_device: Vk_Device, result: RHI_Result) {
	vk_device = {}
	vk_device.physical_device = create_physical_device(instance, vk_surface.surface, &vk_device.queue_family_list) or_return
	create_logical_device(&vk_device) or_return

	return vk_device, nil
}

@(private)
create_physical_device :: proc(instance: vk.Instance, surface: vk.SurfaceKHR, out_queue_family_list: ^Vk_Queue_Family_List) -> (physical_device: vk.PhysicalDevice, result: RHI_Result) {
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
	for present_mode in present_modes {
		if present_mode == .MAILBOX {
			return present_mode
		}
	}
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
create_swapchain :: proc(vk_device: Vk_Device, vk_surface: ^Vk_Surface) -> RHI_Result {
	assert(vk_surface.swapchain == 0, "Swapchain has already been created for this surface.")

	swapchain_support := get_swapchain_support(vk_surface.surface, vk_device.physical_device)
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
	if vk_device.queue_family_list.graphics != vk_device.queue_family_list.present {
		queue_indices = {
			vk_device.queue_family_list.graphics,
			vk_device.queue_family_list.present,
		}
		swapchain_create_info.imageSharingMode = .CONCURRENT
		swapchain_create_info.queueFamilyIndexCount = 2
		swapchain_create_info.pQueueFamilyIndices = &queue_indices[0]
	}

	if result := vk.CreateSwapchainKHR(vk_device.device, &swapchain_create_info, nil, &vk_surface.swapchain); result != .SUCCESS {
		return make_vk_error("Failed to create the Swapchain.", result)
	}

	vk.GetSwapchainImagesKHR(vk_device.device, vk_surface.swapchain, &image_count, nil)
	resize(&vk_surface.swapchain_images, int(image_count))
	vk.GetSwapchainImagesKHR(vk_device.device, vk_surface.swapchain, &image_count, raw_data(vk_surface.swapchain_images))

	vk_surface.swapchain_image_format = surface_format.format
	vk_surface.swapchain_extent = extent

	return nil
}

@(private)
create_swapchain_image_views :: proc(vk_device: Vk_Device, vk_surface: ^Vk_Surface) -> RHI_Result {
	assert(vk_surface != nil)

	resize(&vk_surface.swapchain_image_views, len(vk_surface.swapchain_images))
	for image, i in vk_surface.swapchain_images {
		vk_surface.swapchain_image_views[i] = vk_create_image_view(vk_device.device, image, 1, vk_surface.swapchain_image_format, {.COLOR}) or_return
	}
	
	return nil
}

@(private)
create_logical_device :: proc(vk_device: ^Vk_Device) -> RHI_Result {
	assert(vk_device.device == nil)
	assert(vk_device.queue_family_list.graphics != VK_INVALID_QUEUE_FAMILY_INDEX, "Graphics queue family has not been selected.")

	Empty :: struct{}
	unique_queue_families := map[u32]Empty{
		vk_device.queue_family_list.graphics = {},
		vk_device.queue_family_list.present = {},
	}
	defer delete(unique_queue_families)

	queue_priority: f32 = 1.0
	queue_create_infos := [dynamic]vk.DeviceQueueCreateInfo{}
	defer delete(queue_create_infos)
	for queue_family in unique_queue_families {
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

vk_create_render_pass :: proc(device: vk.Device, color_attachment_format: vk.Format) -> (render_pass: Vk_RenderPass, result: RHI_Result) {
	attachments := [?]vk.AttachmentDescription{
		// Color attachment
		vk.AttachmentDescription{
			format = color_attachment_format,
			samples = {._1},
			loadOp = .CLEAR,
			storeOp = .STORE,
			stencilLoadOp = .DONT_CARE,
			stencilStoreOp = .DONT_CARE,
			initialLayout = .UNDEFINED,
			finalLayout = .PRESENT_SRC_KHR,
		},
		// Depth attachment
		vk.AttachmentDescription{
			format = .D24_UNORM_S8_UINT,
			samples = {._1},
			loadOp = .CLEAR,
			storeOp = .DONT_CARE,
			stencilLoadOp = .DONT_CARE,
			stencilStoreOp = .DONT_CARE,
			initialLayout = .UNDEFINED,
			finalLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
		},
	}

	color_attachment_reference := vk.AttachmentReference{
		attachment = 0,
		layout = .COLOR_ATTACHMENT_OPTIMAL,
	}

	depth_attachment_reference := vk.AttachmentReference{
		attachment = 1,
		layout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
	}

	subpass_description := vk.SubpassDescription{
		pipelineBindPoint = .GRAPHICS,
		colorAttachmentCount = 1,
		pColorAttachments = &color_attachment_reference,
		pDepthStencilAttachment = &depth_attachment_reference,
	}

	subpass_dependency := vk.SubpassDependency{
		srcSubpass = vk.SUBPASS_EXTERNAL,
		dstSubpass = 0,
		srcStageMask = {.COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS},
		srcAccessMask = {},
		dstStageMask = {.COLOR_ATTACHMENT_OUTPUT, .EARLY_FRAGMENT_TESTS},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE, .DEPTH_STENCIL_ATTACHMENT_WRITE},
	}

	render_pass_create_info := vk.RenderPassCreateInfo{
		sType = .RENDER_PASS_CREATE_INFO,
		attachmentCount = len(attachments),
		pAttachments = &attachments[0],
		subpassCount = 1,
		pSubpasses = &subpass_description,
		dependencyCount = 1,
		pDependencies = &subpass_dependency,
	}

	if r := vk.CreateRenderPass(device, &render_pass_create_info, nil, &render_pass.render_pass); r != .SUCCESS {
		result = make_vk_error("Failed to create a Render Pass.", r)
		return
	}

	return render_pass, nil
}

vk_destroy_render_pass :: proc(device: vk.Device, render_pass: ^Vk_RenderPass) {
	vk.DestroyRenderPass(device, render_pass.render_pass, nil)
}

vk_create_shader :: proc(device: vk.Device, spv_path: string) -> (shader: Vk_Shader, result: RHI_Result) {
	byte_code, ok := os.read_entire_file_from_filename(spv_path)
	if !ok {
		result = make_vk_error(fmt.tprintf("Failed to load the Shader byte code from %s.", spv_path))
		return
	}

	shader.byte_code = byte_code

	shader_module_create_info := vk.ShaderModuleCreateInfo{
		sType = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(shader.byte_code),
		pCode = transmute(^u32)&shader.byte_code[0],
	}

	if r := vk.CreateShaderModule(device, &shader_module_create_info, nil, &shader.module); r != .SUCCESS {
		result = make_vk_error("Failed to create a Shader Module", r)
		return
	}

	return
}

vk_destroy_shader :: proc(device: vk.Device, shader: ^Vk_Shader) {
	vk.DestroyShaderModule(device, shader.module, nil)
	shader.module = {}
	delete(shader.byte_code)
}

vk_create_pipeline_layout :: proc(device: vk.Device, layout_description: Pipeline_Layout_Description) -> (layout: Vk_PipelineLayout, result: RHI_Result) {
	layout.descriptor_set_layout = vk_create_descriptor_set_layout(device, layout_description) or_return

	layout_create_info := vk.PipelineLayoutCreateInfo{
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = 1,
		pSetLayouts = &layout.descriptor_set_layout,
	}

	if len(layout_description.push_constants) > 0 {
		push_constant_ranges := make([]vk.PushConstantRange, len(layout_description.push_constants), context.temp_allocator)
		for range, i in layout_description.push_constants {
			push_constant_ranges[i] = vk.PushConstantRange{
				offset = range.offset,
				size = range.size,
				stageFlags = conv_shader_stages_to_vk(range.shader_stage),
			}
		}
		layout_create_info.pPushConstantRanges = raw_data(push_constant_ranges)
		layout_create_info.pushConstantRangeCount = cast(u32) len(push_constant_ranges)
	}

	if r := vk.CreatePipelineLayout(device, &layout_create_info, nil, &layout.layout); r != .SUCCESS {
		result = make_vk_error("Failed to create a Pipeline Layout.", r)
		return
	}

	return
}

vk_destroy_pipeline_layout :: proc(device: vk.Device, pipeline: ^Vk_PipelineLayout) {
	vk.DestroyPipelineLayout(device, pipeline.layout, nil)
	vk.DestroyDescriptorSetLayout(device, pipeline.descriptor_set_layout, nil)
}

vk_create_graphics_pipeline :: proc(device: vk.Device, pipeline_desc: Pipeline_Description, render_pass: vk.RenderPass, layout: Vk_PipelineLayout) -> (vk_pipeline: Vk_Pipeline, result: RHI_Result) {
	shader_stages := make([]vk.PipelineShaderStageCreateInfo, len(pipeline_desc.shader_stages), context.temp_allocator)
	for stage, i in pipeline_desc.shader_stages {
		shader_stages[i] = vk.PipelineShaderStageCreateInfo{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = conv_shader_stages_to_vk({stage.type}),
			module = stage.shader.(Vk_Shader).module,
			pName = "main",
		}
	}

	dynamic_states := [?]vk.DynamicState{
		.VIEWPORT,
		.SCISSOR,
	}
	dynamic_state_create_info := vk.PipelineDynamicStateCreateInfo{
		sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = len(dynamic_states),
		pDynamicStates = &dynamic_states[0],
	}

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

	vertex_input_state_create_info := vk.PipelineVertexInputStateCreateInfo{
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		pVertexBindingDescriptions = &vertex_input_binding_descriptions[0],
		vertexBindingDescriptionCount = cast(u32) len(vertex_input_binding_descriptions),
		pVertexAttributeDescriptions = &vertex_input_attribute_descriptions[0],
		vertexAttributeDescriptionCount = cast(u32) len(vertex_input_attribute_descriptions),
	}

	input_assembly_state_create_info := vk.PipelineInputAssemblyStateCreateInfo{
		sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
		primitiveRestartEnable = b32(false),
	}

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
		depthTestEnable = true,
		depthWriteEnable = true,
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
		layout = layout.layout,
		renderPass = render_pass,
		subpass = 0,
		basePipelineHandle = 0,
		basePipelineIndex = -1,
	}

	if r := vk.CreateGraphicsPipelines(device, 0, 1, &pipeline_create_info, nil, &vk_pipeline.pipeline); r != .SUCCESS {
		result = make_vk_error("Failed to create a Graphics Pipeline.", r)
		return
	}

	return
}

vk_destroy_graphics_pipeline :: proc(device: vk.Device, pipeline: ^Vk_Pipeline) {
	vk.DestroyPipeline(device, pipeline.pipeline, nil)
}

vk_create_framebuffer :: proc(device: vk.Device, render_pass: vk.RenderPass, attachments: []vk.ImageView, dimensions: [2]u32) -> (framebuffer: Vk_Framebuffer, result: RHI_Result) {
	framebuffer_create_info := vk.FramebufferCreateInfo{
		sType = .FRAMEBUFFER_CREATE_INFO,
		renderPass = render_pass,
		attachmentCount = cast(u32) len(attachments),
		pAttachments = raw_data(attachments),
		width = dimensions.x,
		height = dimensions.y,
		layers = 1,
	}

	if r := vk.CreateFramebuffer(device, &framebuffer_create_info, nil, &framebuffer.framebuffer); r != .SUCCESS {
		result = make_vk_error("Failed to create a Framebuffer.", r)
		return
	}

	return
}

vk_destroy_framebuffer :: proc(device: vk.Device, framebuffer: ^Vk_Framebuffer) {
	vk.DestroyFramebuffer(device, framebuffer.framebuffer, nil)
}

vk_create_command_pool :: proc(device: vk.Device, queue_family_index: u32) -> (command_pool: vk.CommandPool, result: RHI_Result) {
	create_info := vk.CommandPoolCreateInfo{
		sType = .COMMAND_POOL_CREATE_INFO,
		flags = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = queue_family_index,
	}

	if r := vk.CreateCommandPool(device, &create_info, nil, &command_pool); r != .SUCCESS {
		result = make_vk_error("Failed to create a Command Pool.", r)
		return
	}

	return command_pool, nil
}

vk_create_descriptor_pool :: proc(device: vk.Device, pool_desc: Descriptor_Pool_Desc) -> (pool: Vk_DescriptorPool, result: RHI_Result) {
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

	if r := vk.CreateDescriptorPool(device, &create_info, nil, &pool.pool); r != .SUCCESS {
		result = make_vk_error("Failed to create a Descriptor Pool.", r)
		return
	}

	return
}

vk_destroy_descriptor_pool :: proc(device: vk.Device, pool: ^Vk_DescriptorPool) {
	assert(pool != nil)
	vk.DestroyDescriptorPool(device, pool.pool, nil)
}

vk_create_descriptor_set :: proc(
	device: vk.Device,
	descriptor_pool: vk.DescriptorPool,
	descriptor_set_layout: vk.DescriptorSetLayout,
	descriptor_set_desc: Descriptor_Set_Desc,
) -> (set: Vk_DescriptorSet, result: RHI_Result) {
	layout := descriptor_set_layout

	alloc_info := vk.DescriptorSetAllocateInfo{
		sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool = descriptor_pool,
		descriptorSetCount = 1,
		pSetLayouts = &layout,
	}
	if r := vk.AllocateDescriptorSets(device, &alloc_info, &set.set); r != .SUCCESS {
		result = make_vk_error("Failed to allocate Desctiptor Sets.", r)
		return
	}

	descriptor_writes := make([]vk.WriteDescriptorSet, len(descriptor_set_desc.descriptors), context.temp_allocator)
	for d, i in descriptor_set_desc.descriptors {
		descriptor_writes[i] = vk.WriteDescriptorSet{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = set.set,
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
				sampler = info.sampler.(Vk_Sampler).sampler,
			}
			descriptor_writes[i].pImageInfo = image_info
		}
	}

	vk.UpdateDescriptorSets(device, cast(u32) len(descriptor_writes), &descriptor_writes[0], 0, nil)

	return
}

vk_create_descriptor_set_layout :: proc(device: vk.Device, layout_description: Pipeline_Layout_Description) -> (layout: vk.DescriptorSetLayout, result: RHI_Result) {
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

	if r := vk.CreateDescriptorSetLayout(device, &layout_info, nil, &layout); r != .SUCCESS {
		result = make_vk_error("Failed to create a Descriptor Set Layout.", r)
		return
	}

	return
}

find_proper_memory_type :: proc(physical_device: vk.PhysicalDevice, type_bits: u32, property_flags: vk.MemoryPropertyFlags) -> (index: u32, result: RHI_Result) {		
	memory_properties: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(physical_device, &memory_properties)

	for i: u32 = 0; i < memory_properties.memoryTypeCount; i += 1 {
		if type_bits & (1 << i) != 0 && memory_properties.memoryTypes[i].propertyFlags & property_flags == property_flags {
			index = i
			return
		}
	}
	result = make_vk_error("Could not find a proper memory type for a Buffer.")
	return
}

create_buffer :: proc(device: vk.Device, physical_device: vk.PhysicalDevice, size: vk.DeviceSize, usage: vk.BufferUsageFlags, property_flags: vk.MemoryPropertyFlags) -> (buffer: vk.Buffer, buffer_memory: vk.DeviceMemory, result: RHI_Result) {
	create_info := vk.BufferCreateInfo{
		sType = .BUFFER_CREATE_INFO,
		size = size,
		usage = usage,
		sharingMode = .EXCLUSIVE,
	}
	if r := vk.CreateBuffer(device, &create_info, nil, &buffer); r != .SUCCESS {
		result = make_vk_error("Failed to create a Buffer.", r)
		return
	}

	memory_requirements: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(device, buffer, &memory_requirements)

	alloc_info := vk.MemoryAllocateInfo{
		sType = .MEMORY_ALLOCATE_INFO,
		allocationSize = memory_requirements.size,
		memoryTypeIndex = find_proper_memory_type(physical_device, memory_requirements.memoryTypeBits, property_flags) or_return,
	}
	
	if r := vk.AllocateMemory(device, &alloc_info, nil, &buffer_memory); r != .SUCCESS {
		result = make_vk_error("Failed to allocate memory for a Buffer.", r)
		return
	}

	if r := vk.BindBufferMemory(device, buffer, buffer_memory, 0); r != .SUCCESS {
		result = make_vk_error("Failed to bind Buffer memory.", r)
		return
	}

	return
}

transition_image_layout :: proc(device: vk.Device, image: vk.Image, mip_levels: u32, format: vk.Format, from_layout: vk.ImageLayout, to_layout: vk.ImageLayout) -> RHI_Result {
	cmd_buffer := begin_one_time_cmd_buffer(device) or_return

	src_stage, dst_stage: vk.PipelineStageFlags
	src_access, dst_access: vk.AccessFlags

	if from_layout == .UNDEFINED && to_layout == .TRANSFER_DST_OPTIMAL {
		src_access = {}
		dst_access = {.TRANSFER_WRITE}
		src_stage = {.TOP_OF_PIPE}
		dst_stage = {.TRANSFER}
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

	end_one_time_cmd_buffer(device, cmd_buffer) or_return

	return nil
}

copy_buffer_to_image :: proc(device: vk.Device, src_buffer: vk.Buffer, dst_image: vk.Image, dimensions: [2]u32) -> RHI_Result {
	cmd_buffer := begin_one_time_cmd_buffer(device) or_return

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

	end_one_time_cmd_buffer(device, cmd_buffer) or_return

	return nil
}

vk_create_image :: proc(
	device: vk.Device,
	physical_device: vk.PhysicalDevice,
	dimensions: [2]u32,
	mip_levels: u32,
	format: vk.Format,
	tiling: vk.ImageTiling,
	usage: vk.ImageUsageFlags,
	properties: vk.MemoryPropertyFlags,
) -> (image: vk.Image, image_memory: vk.DeviceMemory, result: RHI_Result) {
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

	if r := vk.CreateImage(device, &image_info, nil, &image); r != .SUCCESS {
		result = make_vk_error("Failed to create an Image.", r)
		return
	}

	memory_requirements: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(device, image, &memory_requirements)

	alloc_info := vk.MemoryAllocateInfo{
		sType = .MEMORY_ALLOCATE_INFO,
		allocationSize = memory_requirements.size,
		memoryTypeIndex = find_proper_memory_type(physical_device, memory_requirements.memoryTypeBits, properties) or_return,
	}
	
	if r := vk.AllocateMemory(device, &alloc_info, nil, &image_memory); r != .SUCCESS {
		result = make_vk_error("Failed to allocate memory for an Image.", r)
		return
	}

	if r := vk.BindImageMemory(device, image, image_memory, 0); r != .SUCCESS {
		result = make_vk_error("Failed to bind Image memory.", r)
		return
	}

	return
}

vk_create_image_view :: proc(device: vk.Device, image: vk.Image, mip_levels: u32, format: vk.Format, aspect_mask: vk.ImageAspectFlags) -> (image_view: vk.ImageView, result: RHI_Result) {
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

	if r := vk.CreateImageView(device, &image_view_info, nil, &image_view); r != .SUCCESS {
		result = make_vk_error("Failed to create an Image View.", r)
		return
	}

	return
}

create_depth_image_resources :: proc(device: vk.Device, physical_device: vk.PhysicalDevice, dimensions: [2]u32) -> (depth_resources: Vk_Depth, result: RHI_Result) {
	// TODO: Find a suitable supported format
	format: vk.Format = .D24_UNORM_S8_UINT
	depth_resources.image, depth_resources.image_memory = vk_create_image(device, physical_device, dimensions, 1, format, .OPTIMAL, {.DEPTH_STENCIL_ATTACHMENT}, {.DEVICE_LOCAL}) or_return
	depth_resources.image_view = vk_create_image_view(device, depth_resources.image, 1, format, {.DEPTH}) or_return

	return
}

destroy_depth_image_resources :: proc(device: vk.Device, depth_resources: ^Vk_Depth) {
	vk.DestroyImageView(device, depth_resources.image_view, nil)
	vk.DestroyImage(device, depth_resources.image, nil)
	vk.FreeMemory(device, depth_resources.image_memory, nil)

	mem.zero_item(depth_resources)
}

vk_create_texture_image :: proc(device: vk.Device, physical_device: vk.PhysicalDevice, image_buffer: []byte, dimensions: [2]u32) -> (texture: Vk_Texture, mip_levels: u32, result: RHI_Result) {
	channel_count: u32 = 4
	image_size := cast(vk.DeviceSize) len(image_buffer)

	max_dim := cast(f32) linalg.max(dimensions)
	texture.mip_levels = cast(u32) math.floor(math.log2(max_dim)) + 1
	mip_levels = texture.mip_levels

	staging_buffer, staging_buffer_memory := create_buffer(device, physical_device, image_size, {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT}) or_return
	defer {
		vk.DestroyBuffer(device, staging_buffer, nil)
		vk.FreeMemory(device, staging_buffer_memory, nil)
	}

	data: rawptr
	if r := vk.MapMemory(device, staging_buffer_memory, 0, image_size, {}, &data); r != .SUCCESS {
		result = make_vk_error("Failed to map the Staging Buffer's memory.", r)
	}

	mem.copy_non_overlapping(data, raw_data(image_buffer), cast(int) image_size)

	vk.UnmapMemory(device, staging_buffer_memory)

	texture.image, texture.image_memory = vk_create_image(device, physical_device, dimensions, texture.mip_levels, .R8G8B8A8_SRGB, .OPTIMAL, {.TRANSFER_SRC, .TRANSFER_DST, .SAMPLED}, {.DEVICE_LOCAL}) or_return

	transition_image_layout(device, texture.image, texture.mip_levels, .R8G8B8A8_SRGB, .UNDEFINED, .TRANSFER_DST_OPTIMAL) or_return
	copy_buffer_to_image(device, staging_buffer, texture.image, dimensions) or_return

	// Generate mipmaps
	
	cmd_buffer := begin_one_time_cmd_buffer(device) or_return
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
	for dst_level in 1..<texture.mip_levels {
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
	barrier.subresourceRange.baseMipLevel = texture.mip_levels - 1
	barrier.oldLayout = .TRANSFER_SRC_OPTIMAL
	barrier.newLayout = .SHADER_READ_ONLY_OPTIMAL
	barrier.srcAccessMask = {.TRANSFER_READ}
	barrier.dstAccessMask = {.SHADER_READ}
	vk.CmdPipelineBarrier(cmd_buffer, {.TRANSFER}, {.FRAGMENT_SHADER}, {}, 0, nil, 0, nil, 1, &barrier)

	end_one_time_cmd_buffer(device, cmd_buffer) or_return

	// Already transitioned during mipmap generation
	// transition_image_layout(device, image, mip_levels, .R8G8B8A8_SRGB, .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL) or_return

	texture.image_view = vk_create_image_view(device, texture.image, texture.mip_levels, .R8G8B8A8_SRGB, {.COLOR}) or_return

	return
}

vk_destroy_texture_image :: proc(device: vk.Device, texture: ^Vk_Texture) {
	assert(texture != nil)
	vk.DestroyImageView(device, texture.image_view, nil)
	vk.DestroyImage(device, texture.image, nil)
	vk.FreeMemory(device, texture.image_memory, nil)
}

vk_create_texture_sampler :: proc(device: vk.Device, physical_device: vk.PhysicalDevice, mip_levels: u32) -> (sampler: Vk_Sampler, result: RHI_Result) {
	device_properties: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(physical_device, &device_properties)

	sampler_info := vk.SamplerCreateInfo{
		sType = .SAMPLER_CREATE_INFO,
		magFilter = .LINEAR,
		minFilter = .LINEAR,
		addressModeU = .REPEAT,
		addressModeV = .REPEAT,
		addressModeW = .REPEAT,
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

	if r := vk.CreateSampler(device, &sampler_info, nil, &sampler.sampler); r != .SUCCESS {
		result = make_vk_error("Failed to create a Sampler.", r)
		return
	}

	return
}

vk_create_vertex_buffer :: proc(device: vk.Device, physical_device: vk.PhysicalDevice, buffer_desc: Buffer_Desc, vertices: []$V) -> (buffer: vk.Buffer, buffer_memory: vk.DeviceMemory, result: RHI_Result) {
	vertices := vertices

	buffer_size := cast(vk.DeviceSize) (size_of(V) * len(vertices))
	staging_buffer, staging_buffer_memory := create_buffer(device, physical_device, buffer_size, {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT}) or_return

	data: rawptr
	if r := vk.MapMemory(device, staging_buffer_memory, 0, buffer_size, {}, &data); r != .SUCCESS {
		result = make_vk_error("Failed to map the Staging Buffer's memory.", r)
		return
	}

	mem.copy_non_overlapping(data, raw_data(vertices), cast(int) buffer_size)

	vk.UnmapMemory(device, staging_buffer_memory)

	memory_flags := conv_memory_flags_to_vk(buffer_desc.memory_flags)
	buffer, buffer_memory = create_buffer(device, physical_device, buffer_size, {.VERTEX_BUFFER, .TRANSFER_DST}, memory_flags) or_return

	copy_buffer(device, staging_buffer, buffer, buffer_size) or_return

	vk.DestroyBuffer(device, staging_buffer, nil)
	vk.FreeMemory(device, staging_buffer_memory, nil)

	return
}

vk_create_vertex_buffer_empty :: proc(device: vk.Device, physical_device: vk.PhysicalDevice, buffer_desc: Buffer_Desc, $Element: typeid, elem_count: u32) -> (buffer: vk.Buffer, buffer_memory: vk.DeviceMemory, result: RHI_Result) {
	buffer_size := cast(vk.DeviceSize) (size_of(Element) * elem_count)
	memory_flags := conv_memory_flags_to_vk(buffer_desc.memory_flags)
	buffer, buffer_memory = create_buffer(device, physical_device, buffer_size, {.VERTEX_BUFFER}, memory_flags) or_return

	return
}

vk_create_index_buffer :: proc(device: vk.Device, physical_device: vk.PhysicalDevice, indices: []u32) -> (buffer: vk.Buffer, buffer_memory: vk.DeviceMemory, result: RHI_Result) {
	indices := indices

	buffer_size := cast(vk.DeviceSize) (size_of(u32) * len(indices))
	staging_buffer, staging_buffer_memory := create_buffer(device, physical_device, buffer_size, {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT}) or_return

	data: rawptr
	if r := vk.MapMemory(device, staging_buffer_memory, 0, buffer_size, {}, &data); r != .SUCCESS {
		result = make_vk_error("Failed to map the Staging Buffer's memory.", r)
		return
	}

	mem.copy_non_overlapping(data, raw_data(indices), cast(int) buffer_size)

	vk.UnmapMemory(device, staging_buffer_memory)

	buffer, buffer_memory = create_buffer(device, physical_device, buffer_size, {.INDEX_BUFFER, .TRANSFER_DST}, {.DEVICE_LOCAL}) or_return

	copy_buffer(device, staging_buffer, buffer, buffer_size) or_return

	vk.DestroyBuffer(device, staging_buffer, nil)
	vk.FreeMemory(device, staging_buffer_memory, nil)

	return
}

vk_create_uniform_buffer :: proc(device: vk.Device, physical_device: vk.PhysicalDevice, $SIZE: uint) -> (buffer: vk.Buffer, buffer_memory: vk.DeviceMemory, mapped_memory: rawptr, result: RHI_Result) {
	size := cast(vk.DeviceSize) SIZE

	buffer, buffer_memory = create_buffer(device, physical_device, size, {.UNIFORM_BUFFER}, {.HOST_VISIBLE, .HOST_COHERENT}) or_return
	if r := vk.MapMemory(device, buffer_memory, 0, size, {}, &mapped_memory); r != .SUCCESS {
		result = make_vk_error("Failed to map Uniform Buffer's memory.", r)
		return
	}

	return
}

vk_map_memory :: proc(device: vk.Device, memory: vk.DeviceMemory, size: vk.DeviceSize) -> (mapped_memory: []byte, result: RHI_Result) {
	mapped_memory_addr: rawptr
	if r := vk.MapMemory(device, memory, 0, size, {}, &mapped_memory_addr); r != .SUCCESS {
		result = make_vk_error("Failed to map Uniform Buffer's memory.", r)
		return
	}

	mapped_memory = slice.from_ptr(cast(^byte) mapped_memory_addr, cast(int) size)

	return
}

begin_one_time_cmd_buffer :: proc(device: vk.Device) -> (cmd_buffer: vk.CommandBuffer, result: RHI_Result) {
	cmd_buffer_alloc_info := vk.CommandBufferAllocateInfo{
		sType = .COMMAND_BUFFER_ALLOCATE_INFO,
		level = .PRIMARY,
		commandPool = vk_data.command_pool,
		commandBufferCount = 1,
	}
	if r := vk.AllocateCommandBuffers(device, &cmd_buffer_alloc_info, &cmd_buffer); r != .SUCCESS {
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

end_one_time_cmd_buffer :: proc(device: vk.Device, cmd_buffer: vk.CommandBuffer) -> RHI_Result {
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
	if r := vk.QueueSubmit(vk_data.device_data.queue_list.graphics, 1, &submit_info, 0); r != .SUCCESS {
		return make_vk_error("Failed to submit a command buffer.", r)
	}
	if r := vk.QueueWaitIdle(vk_data.device_data.queue_list.graphics); r != .SUCCESS {
		return make_vk_error("Failed to wait for a queue to idle.", r)
	}

	vk.FreeCommandBuffers(device, vk_data.command_pool, 1, &cmd_buffer)

	return nil
}

copy_buffer :: proc(device: vk.Device, src_buffer: vk.Buffer, dst_buffer: vk.Buffer, size: vk.DeviceSize) -> RHI_Result {
	command_buffer := begin_one_time_cmd_buffer(device) or_return

	copy_region := vk.BufferCopy{
		srcOffset = 0,
		dstOffset = 0,
		size = size,
	}
	vk.CmdCopyBuffer(command_buffer, src_buffer, dst_buffer, 1, &copy_region)

	end_one_time_cmd_buffer(device, command_buffer) or_return

	return nil
}

vk_allocate_command_buffers :: proc(device: vk.Device, command_pool: vk.CommandPool, $N: uint) -> (cb: [N]Vk_CommandBuffer, result: RHI_Result) {
	allocate_info := vk.CommandBufferAllocateInfo{
		sType = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool = command_pool,
		level = .PRIMARY,
		commandBufferCount = cast(u32) N,
	}

	command_buffers: [N]vk.CommandBuffer
	if r := vk.AllocateCommandBuffers(device, &allocate_info, &command_buffers[0]); r != .SUCCESS {
		result = make_vk_error("Failed to allocate Command Buffers.", r)
		return
	}

	for i in 0..<N {
		cb[i].command_buffer = command_buffers[i]
	}

	return
}

@(private)
vk_create_main_sync_objects :: proc(device: vk.Device) -> (sync_objects: [MAX_FRAMES_IN_FLIGHT]Vk_Sync, result: RHI_Result) {
	semaphore_create_info := vk.SemaphoreCreateInfo{
		sType = .SEMAPHORE_CREATE_INFO,
	}

	fence_create_info := vk.FenceCreateInfo{
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}

	for &frame_sync_objects in sync_objects {
		if r := vk.CreateSemaphore(device, &semaphore_create_info, nil, &frame_sync_objects.draw_finished_semaphore); r != .SUCCESS {
			result = make_vk_error("Failed to create a Semaphore.", r)
			return
		}
		if r := vk.CreateSemaphore(device, &semaphore_create_info, nil, &frame_sync_objects.image_available_semaphore); r != .SUCCESS {
			result = make_vk_error("Failed to create a Semaphore.", r)
			return
		}
		if r := vk.CreateFence(device, &fence_create_info, nil, &frame_sync_objects.in_flight_fence); r != .SUCCESS {
			result = make_vk_error("Failed to create a Fence.", r)
			return
		}
	}

	return
}

@(private)
vk_destroy_main_sync_objects :: proc(device: vk.Device, sync_objects: [MAX_FRAMES_IN_FLIGHT]Vk_Sync) {
	for frame_sync_objects in sync_objects {
		vk.DestroySemaphore(device, frame_sync_objects.draw_finished_semaphore, nil)
		vk.DestroySemaphore(device, frame_sync_objects.image_available_semaphore, nil)
		vk.DestroyFence(device, frame_sync_objects.in_flight_fence, nil)
	}
}

@(private)
destroy_swapchain :: proc(vk_device: Vk_Device, vk_surface: ^Vk_Surface) {
	for iv in vk_surface.swapchain_image_views {
		vk.DestroyImageView(vk_device.device, iv, nil)
	}
	clear(&vk_surface.swapchain_image_views)

	vk.DestroySwapchainKHR(vk_device.device, vk_surface.swapchain, nil)
	vk_surface.swapchain = 0
}

@(private)
recreate_swapchain :: proc(vk_device: Vk_Device, vk_surface: ^Vk_Surface) -> RHI_Result {
	vk_data.recreate_swapchain_requested = false

	vk.DeviceWaitIdle(vk_device.device)

	destroy_swapchain(vk_device, vk_surface)

	create_swapchain(vk_device, vk_surface) or_return
	create_swapchain_image_views(vk_device, vk_surface) or_return
	dimensions: [2]u32 = {vk_surface.swapchain_extent.width, vk_surface.swapchain_extent.height}

	core.broadcaster_broadcast(&callbacks.on_recreate_swapchain_broadcaster, Args_Recreate_Swapchain{0, dimensions})

	return nil
}

@(private)
VK_INVALID_QUEUE_FAMILY_INDEX :: max(u32)

@(private)
Vk_Queue_Family_List :: struct {
	graphics: u32,
	present: u32,
}

@(private)
Vk_Queue_List :: struct {
	graphics: vk.Queue,
	present: vk.Queue,
}

@(private)
Vk_Device :: struct {
	physical_device: vk.PhysicalDevice,
	device: vk.Device,
	queue_family_list: Vk_Queue_Family_List,
	queue_list: Vk_Queue_List,
}

@(private)
Vk_Surface :: struct {
	surface: vk.SurfaceKHR,
	swapchain: vk.SwapchainKHR,
	swapchain_images: [dynamic]vk.Image,
	swapchain_image_views: [dynamic]vk.ImageView,
	swapchain_image_format: vk.Format,
	swapchain_extent: vk.Extent2D,
}

@(private)
Vk_Framebuffer :: struct {
	framebuffer: vk.Framebuffer,
}

@(private)
Vk_PipelineLayout :: struct {
	descriptor_set_layout: vk.DescriptorSetLayout,
	layout: vk.PipelineLayout,
}

@(private)
Vk_Pipeline :: struct {
	pipeline: vk.Pipeline,
}

@(private)
Vk_RenderPass :: struct {
	render_pass: vk.RenderPass,
}

@(private)
Vk_DescriptorPool :: struct {
	pool: vk.DescriptorPool,
}

@(private)
Vk_DescriptorSet :: struct {
	set: vk.DescriptorSet,
}

@(private)
Vk_Shader :: struct {
	byte_code: []byte,
	module: vk.ShaderModule,
}

@(private)
Vk_Sync :: struct {
	image_available_semaphore: vk.Semaphore,
	draw_finished_semaphore: vk.Semaphore,
	in_flight_fence: vk.Fence,
}

@(private)
Vk_Depth :: struct {
	using Vk_Texture,
}

@(private)
Vk_Buffer :: struct {
	buffer: vk.Buffer,
	buffer_memory: vk.DeviceMemory,
}

@(private)
Vk_Texture :: struct {
	image: vk.Image,
	image_memory: vk.DeviceMemory,
	image_view: vk.ImageView,
	mip_levels: u32,
}

@(private)
Vk_Sampler :: struct {
	sampler: vk.Sampler,
}

@(private)
Vk_CommandBuffer :: struct {
	command_buffer: vk.CommandBuffer,
}

@(private)
Vk_Instance :: struct {
	get_instance_proc_addr: vk.ProcGetInstanceProcAddr,
	supported_extensions: []vk.ExtensionProperties,
	extensions: [dynamic]cstring,
	instance: vk.Instance,
}

@(private)
VkRHI :: struct {
	instance_data: Vk_Instance,
	main_window_handle: platform.Window_Handle,
	device_data: Vk_Device,
	surfaces: [dynamic]Vk_Surface,
	command_pool: vk.CommandPool,
	sync_objects: [MAX_FRAMES_IN_FLIGHT]Vk_Sync,
	current_frame: u32,
	recreate_swapchain_requested: bool,
	is_minimized: bool,
}

@(private)
vk_data: VkRHI

get_window_surface :: proc(handle: platform.Window_Handle) -> ^Vk_Surface {
	if int(handle) >= len(vk_data.surfaces) {
		return nil
	}
	#no_bounds_check { return &vk_data.surfaces[handle] }
}

@(private)
register_surface :: proc(window_handle: platform.Window_Handle, surface: vk.SurfaceKHR) -> ^Vk_Surface {
	is_handle_in_bounds := int(window_handle) < len(vk_data.surfaces)
	if !is_handle_in_bounds {
		append(&vk_data.surfaces, Vk_Surface{
			surface = surface,
		})
		return &vk_data.surfaces[len(vk_data.surfaces) - 1]
	} else {
		is_index_unregistered := vk_data.surfaces[int(window_handle)].surface == 0
		assert(is_index_unregistered)
		vk_data.surfaces[int(window_handle)] = Vk_Surface{
			surface = surface,
		}
		return &vk_data.surfaces[int(window_handle)]
	}
}

// TODO: There should probably also be an option to enable validation layers in non-debug mode
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
	init_debug_messenger :: proc() -> RHI_Result {
		create_info := make_debug_utils_messenger_create_info()
		if result := vk.CreateDebugUtilsMessengerEXT(vk_data.instance_data.instance, &create_info, nil, &vk_debug_data.debug_messenger); result != .SUCCESS {
			return make_vk_error("Failed to create Vulkan Debug Utils Messenger.", result)
		}
		return nil
	}

	@(private)
	shutdown_debug_messenger :: proc() {
		vk.DestroyDebugUtilsMessengerEXT(vk_data.instance_data.instance, vk_debug_data.debug_messenger, nil)
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
		text := fmt.tprintf("Vk Validation Layer: %s\n", callback_data.pMessage)

		level: runtime.Logger_Level
		switch (message_severity_value) {
		case .VERBOSE..<.INFO:
			level = .Debug
		case .INFO..<.WARNING:
			level = .Info
		case .WARNING..<.ERROR:
			level = .Warning
		case .ERROR:
			level = .Error
		}

		platform.log_to_native_console(nil, level, text, {})
		if message_severity_value >= .WARNING {
		}
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

/* ------------------------------------------- PLATFORM SPECIFIC ---------------------------------------------- */

when ODIN_OS == .Windows {
	@(private)
	VULKAN_DLL :: "vulkan-1.dll"

	@(private)
	vk_lib: w.HMODULE = nil

	@(private)
	platform_load_vulkan_lib :: proc() -> RHI_Result {
		vk_lib = w.LoadLibraryW(w.utf8_to_wstring(VULKAN_DLL))
		if vk_lib == nil {
			return make_vk_error("Vulkan library not found.")
		}
		vk_data.instance_data.get_instance_proc_addr = cast(vk.ProcGetInstanceProcAddr) w.GetProcAddress(vk_lib, "vkGetInstanceProcAddr")
		if vk_data.instance_data.get_instance_proc_addr == nil {
			return make_vk_error("Failed to find vkGetInstanceProcAddr in the Vulkan lib.")
		}

		return nil
	}

	@(private)
	platform_get_required_extensions :: proc(extensions: ^[dynamic]cstring) {
		append(extensions, cstring(vk.KHR_SURFACE_EXTENSION_NAME))
		append(extensions, cstring(vk.KHR_WIN32_SURFACE_EXTENSION_NAME))
	}

	@(private)
	platform_create_surface :: proc(window_handle: platform.Window_Handle) -> (surface: vk.SurfaceKHR, result: RHI_Result) {
		win32_surface_create_info := vk.Win32SurfaceCreateInfoKHR{
			sType = .WIN32_SURFACE_CREATE_INFO_KHR,
			hwnd = platform.win32_get_hwnd(window_handle),
			hinstance = platform.win32_get_hinstance(),
		}

		if r := vk.CreateWin32SurfaceKHR(vk_data.instance_data.instance, &win32_surface_create_info, nil, &surface); r != .SUCCESS {
			result = make_vk_error("Failed to create Win32 Vulkan surface.", r)
			return
		}

		return surface, nil
	}
}
