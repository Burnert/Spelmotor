package sm_rhi

import w "core:sys/windows"
import vk "vendor:vulkan"

import "sm:platform"

@(private)
VULKAN_DLL :: "vulkan-1.dll"

@(private)
vk_lib: w.HMODULE = nil

@(private)
platform_load_vulkan_lib :: proc() -> Result {
	vk_lib = w.LoadLibraryW(w.utf8_to_wstring(VULKAN_DLL))
	if vk_lib == nil {
		return make_vk_error("Vulkan library not found.")
	}
	g_vk.instance_data.get_instance_proc_addr = cast(vk.ProcGetInstanceProcAddr) w.GetProcAddress(vk_lib, "vkGetInstanceProcAddr")
	if g_vk.instance_data.get_instance_proc_addr == nil {
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
platform_create_surface :: proc(instance: vk.Instance, window_handle: platform.Window_Handle) -> (surface: vk.SurfaceKHR, result: Result) {
	win32_surface_create_info := vk.Win32SurfaceCreateInfoKHR{
		sType = .WIN32_SURFACE_CREATE_INFO_KHR,
		hwnd = platform.win32_get_hwnd(window_handle),
		hinstance = platform.win32_get_hinstance(),
	}

	if r := vk.CreateWin32SurfaceKHR(instance, &win32_surface_create_info, nil, &surface); r != .SUCCESS {
		result = make_vk_error("Failed to create Win32 Vulkan surface.", r)
		return
	}

	return surface, nil
}
