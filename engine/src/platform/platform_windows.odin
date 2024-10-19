package platform

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:reflect"
import "core:slice"
import "core:time"
import w "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	ConvertFiberToThread :: proc() -> w.BOOL ---
}

// CONFIG
USE_MESSAGE_FIBER :: true

_init :: proc() {
	windows_data.hinstance = w.HINSTANCE(w.GetModuleHandleW(nil))
	windows_data.wnd_class_name = w.utf8_to_wstring("SMWindow")

	perf_freq: w.LARGE_INTEGER
	w.QueryPerformanceFrequency(&perf_freq)

	when USE_MESSAGE_FIBER {
		windows_fiber_data.main_fiber = w.ConvertThreadToFiber(nil)
		windows_fiber_data.message_fiber = w.CreateFiber(0, message_fiber, nil)
	}
}

_shutdown :: proc() {
	windows_data.hinstance = nil
	windows_data.wnd_class_name = nil

	when USE_MESSAGE_FIBER {
		w.DeleteFiber(windows_fiber_data.message_fiber)
		ConvertFiberToThread()
	}

	delete(windows_data.window_handles)
}

_register_raw_input_devices :: proc() -> bool {
	devices := [?]w.RAWINPUTDEVICE{
		// Mouse
		w.RAWINPUTDEVICE{
			usUsagePage = w.HID_USAGE_PAGE_GENERIC,
			usUsage = w.HID_USAGE_GENERIC_MOUSE,
			dwFlags = 0,
			hwndTarget = nil,
		},
		// Keyboard
		w.RAWINPUTDEVICE{
			usUsagePage = w.HID_USAGE_PAGE_GENERIC,
			usUsage = w.HID_USAGE_GENERIC_KEYBOARD,
			dwFlags = 0,
			hwndTarget = nil,
		},
	}
	if w.RegisterRawInputDevices(raw_data(devices[:]), len(devices), size_of(devices[0])) != w.TRUE {
		log_windows_error()
		return false
	}
	return true
}

_create_window :: proc(window_desc: Window_Desc) -> (handle: Window_Handle, ok: bool) {
	if !windows_data.is_class_registered {
		register_window_class() or_return
	}

	window_style_ex: u32 =
		w.WS_EX_APPWINDOW |
		w.WS_EX_WINDOWEDGE
	window_style: u32 =
		w.WS_CAPTION |
		w.WS_MINIMIZEBOX |
		w.WS_SYSMENU
	if !window_desc.fixed_size {
		window_style |= w.WS_MAXIMIZEBOX | w.WS_SIZEBOX
	}

	window_width: i32 = cast(i32)window_desc.width
	window_height: i32 = cast(i32)window_desc.height
	window_rect := w.RECT{}
	if !w.AdjustWindowRectEx(&window_rect, window_style, false, window_style_ex) {
		log.error("Could not create a Win32 window. AdjustWindowRectEx has failed.")
		log_windows_error()
		return INVALID_WINDOW_HANDLE, false
	}
	window_width += window_rect.right - window_rect.left
	window_height += window_rect.bottom - window_rect.top

	hwnd := w.CreateWindowExW(
		window_style_ex,
		windows_data.wnd_class_name,
		w.utf8_to_wstring(window_desc.title),
		window_style,
		w.CW_USEDEFAULT,
		w.CW_USEDEFAULT,
		window_width,
		window_height,
		nil,
		nil,
		windows_data.hinstance,
		nil,
	)
	if hwnd == nil {
		log.error("Could not create a Win32 window. CreateWindowExW has failed.")
		log_windows_error()
		return INVALID_WINDOW_HANDLE, false
	}

	return make_window_handle(hwnd), true
}

_destroy_window :: proc(handle: Window_Handle) -> bool {
	if !w.DestroyWindow(handle_to_hwnd(handle)) {
		log.errorf("Could not destroy a Win32 window (%x). DestroyWindow has failed.", cast(rawptr)handle_to_hwnd(handle))
		log_windows_error()
		return false
	}
	windows_data.window_handles[handle] = nil

	// All windows being destroyed means the app is exiting
	if !slice.any_of_proc(windows_data.window_handles[:], proc(h: w.HWND) -> bool {
		return h != nil
	}) {
		unregister_window_class()
	}

	return true
}

_show_window :: proc(handle: Window_Handle) {
	w.ShowWindow(handle_to_hwnd(handle), w.SW_SHOW)
}

_hide_window :: proc(handle: Window_Handle) {
	w.ShowWindow(handle_to_hwnd(handle), w.SW_HIDE)
}

_get_window_client_size :: proc(handle: Window_Handle) -> (width: u32, height: u32) {
	client_rect := w.RECT{}
	w.GetClientRect(handle_to_hwnd(handle), &client_rect)
	return u32(client_rect.right), u32(client_rect.bottom)
}

_get_native_window_handle :: proc(handle: Window_Handle) -> rawptr {
	return win32_get_hwnd(handle)
}

when USE_MESSAGE_FIBER {
	@(private="file")
	message_fiber :: proc "stdcall" (param: rawptr) {
		context = runtime.default_context()
		for {
			run_message_loop()
			w.SwitchToFiber(windows_fiber_data.main_fiber)
		}
	}
}

run_message_loop :: proc() {
	msg: w.MSG
	for (w.PeekMessageW(&msg, nil, 0, 0, w.PM_REMOVE)) {
		if msg.message == w.WM_QUIT {
			windows_data.quit_message_received = true
			break
		}
		w.TranslateMessage(&msg)
		w.DispatchMessageW(&msg)
	}
}

_pump_events :: proc() -> bool {
	// The current context needs to be stored in the extra memory of window class,
	// so it can be retrieved later in the stdcall window_proc
	c := context
	set_window_class_context(&c)

	when USE_MESSAGE_FIBER {
		w.SwitchToFiber(windows_fiber_data.message_fiber)
	} else {
		run_message_loop()
	}

	return !windows_data.quit_message_received
}

_log_to_native_console :: proc(data: rawptr, level: runtime.Logger_Level, text: string, options: runtime.Logger_Options, location := #caller_location) {
	default_attributes: u16 = w.FOREGROUND_RED | w.FOREGROUND_GREEN | w.FOREGROUND_BLUE

	console_handle: w.HANDLE = ---
	attributes: u16 = ---

	switch level {
	case .Debug..<.Info:
		attributes = w.FOREGROUND_BLUE | w.FOREGROUND_INTENSITY
		console_handle = w.GetStdHandle(w.STD_OUTPUT_HANDLE)
	case .Info..<.Warning:
		attributes = w.FOREGROUND_RED | w.FOREGROUND_GREEN | w.FOREGROUND_BLUE | w.FOREGROUND_INTENSITY
		console_handle = w.GetStdHandle(w.STD_OUTPUT_HANDLE)
	case .Warning..<.Error:
		attributes = w.FOREGROUND_RED | w.FOREGROUND_GREEN
		console_handle = w.GetStdHandle(w.STD_OUTPUT_HANDLE)
	case .Error..<.Fatal:
		attributes = w.FOREGROUND_RED
		console_handle = w.GetStdHandle(w.STD_ERROR_HANDLE)
	case .Fatal:
		attributes = w.FOREGROUND_RED | w.FOREGROUND_GREEN | w.FOREGROUND_BLUE | w.FOREGROUND_INTENSITY | w.BACKGROUND_RED | w.COMMON_LVB_UNDERSCORE
		console_handle = w.GetStdHandle(w.STD_ERROR_HANDLE)
	}

	w.SetConsoleTextAttribute(console_handle, attributes)

	bytes_written: w.DWORD = ---
	buffer: []u16 = w.utf8_to_utf16(text)
	assert(len(buffer) <= cast(int)max(u32))
	w.WriteConsoleW(console_handle, &buffer[0], cast(u32)len(buffer), &bytes_written, nil)

	w.SetConsoleTextAttribute(console_handle, default_attributes)
}

_show_message_box :: proc(title, message: string) {
	w.MessageBoxW(nil, w.utf8_to_wstring(message), w.utf8_to_wstring(title), w.MB_ICONERROR)
}

win32_get_hwnd :: proc(handle: Window_Handle) -> w.HWND {
	return handle_to_hwnd(handle)
}

win32_get_hinstance :: proc() -> w.HINSTANCE {
	return windows_data.hinstance
}

@(private)
RI_KEY_E0 :: 2

@(private)
RI_KEY_E1 :: 4

@(private)
LOBYTE :: proc(x: w.WORD) -> u8 {
	return cast(u8) x & 0xFF
}

@(private)
HIBYTE :: proc(x: w.WORD) -> u8 {
	return cast(u8) (x >> 8) & 0xFF
}

@(private)
Move_Loop_Hack_Data :: struct {
	clicked_caption: bool,
	clicked_lparam: w.LPARAM,
}

@(private)
Windows_Data :: struct {
	hinstance: w.HINSTANCE,
	wnd_class_name: [^]w.WCHAR,
	window_handles: [dynamic]w.HWND,
	event_callback_proc: proc(window: Window_Handle, event: System_Event),
	is_class_registered: bool,
	quit_message_received: bool,

	mlh: Move_Loop_Hack_Data,

	perf_freq: w.LARGE_INTEGER,
}

@(private)
windows_data: Windows_Data

when USE_MESSAGE_FIBER {
	@(private)
	Windows_Fiber_Data :: struct {
		main_fiber: rawptr,
		message_fiber: rawptr,
	}

	@(private)
	windows_fiber_data: Windows_Fiber_Data
}

@(private)
log_windows_error :: proc() {
	error_code: w.DWORD = w.GetLastError()
	flags: w.DWORD = w.FORMAT_MESSAGE_FROM_SYSTEM | w.FORMAT_MESSAGE_ALLOCATE_BUFFER | w.FORMAT_MESSAGE_IGNORE_INSERTS
	message_buf: [^]w.WCHAR = ---
	message_length: w.DWORD = w.FormatMessageW(flags, nil, error_code, 0, cast(w.LPWSTR) &message_buf, 0, nil)
	log.error("(Windows Error)", w.wstring_to_utf8(message_buf, cast(int) message_length))
	w.LocalFree(message_buf)
}

@(private)
make_window_handle :: proc(hwnd: w.HWND) -> Window_Handle {
	// FIXME: a handle will not become invalid when a new window takes place of an old one
	for existing_hwnd, i in windows_data.window_handles {
		if existing_hwnd == nil {
			windows_data.window_handles[i] = hwnd
			return Window_Handle(i)
		}
	}
	append(&windows_data.window_handles, hwnd)
	return Window_Handle(len(windows_data.window_handles) - 1)
}

@(private)
handle_to_hwnd :: proc(handle: Window_Handle) -> w.HWND {
	if uint(handle) >= len(windows_data.window_handles) {
		return nil
	}
	#no_bounds_check { return windows_data.window_handles[handle] }
}

// Linear search for the platform agnostic handle
@(private)
hwnd_to_handle :: proc (hwnd: w.HWND) -> Window_Handle {
	for cached_hwnd, i in windows_data.window_handles {
		if hwnd == cached_hwnd {
			return Window_Handle(i)
		}
	}
	return INVALID_WINDOW_HANDLE
}

@(private)
Win32_Class_Extra_Data :: struct {
	// Context is not passed to the WindowProc, so it is set in the window class
	// in the set_window_class_context procedure, from where it can be retrieved later.
	context_ptr: rawptr,
}

@(private)
set_window_class_context :: proc(c: ^runtime.Context) {
	assert(len(windows_data.window_handles) > 0)
	main_hwnd: w.HWND = windows_data.window_handles[0]
	w.SetClassLongPtrW(main_hwnd, cast(i32) offset_of(Win32_Class_Extra_Data, context_ptr), cast(int) cast(uintptr) c)
}

@(private)
get_window_class_context :: proc "contextless" () -> ^runtime.Context {
	if len(windows_data.window_handles) > 0 {
		main_hwnd: w.HWND = windows_data.window_handles[0]
		return cast(^runtime.Context) cast(uintptr) w.GetClassLongPtrW(main_hwnd, cast(i32) offset_of(Win32_Class_Extra_Data, context_ptr))
	} else {
		return nil
	}
}

@(private)
register_window_class :: proc() -> bool {
	assert(shared_data.event_callback_proc != nil)
	wc := w.WNDCLASSW{
		style = w.CS_DBLCLKS | w.CS_OWNDC,
		lpfnWndProc = window_proc,
		cbClsExtra = size_of(Win32_Class_Extra_Data),
		cbWndExtra = 0,
		hInstance = windows_data.hinstance,
		hIcon = nil,
		hCursor = w.LoadCursorW(nil, cast([^]u16)w._IDC_ARROW),
		hbrBackground = nil,
		lpszMenuName = nil,
		lpszClassName = windows_data.wnd_class_name,
	}
	if w.RegisterClassW(&wc) == 0 {
		log.error("Could not register a Win32 window class. RegisterClassW has failed.")
		log_windows_error()
		return false
	}
	windows_data.is_class_registered = true
	return true
}

@(private)
unregister_window_class :: proc() -> bool {
	if !w.UnregisterClassW(windows_data.wnd_class_name, windows_data.hinstance) {
		log.error("Could not unregister a Win32 window class. UnregisterClassW has failed.")
		log_windows_error()
		return false
	}
	return true
}

@(private)
convert_msg_to_mouse_button :: proc(msg: w.UINT, wParam: w.WPARAM) -> Mouse_Button {
	switch msg {
	case w.WM_LBUTTONDOWN, w.WM_LBUTTONUP, w.WM_LBUTTONDBLCLK:
		return .L
	case w.WM_RBUTTONDOWN, w.WM_RBUTTONUP, w.WM_RBUTTONDBLCLK:
		return .R
	case w.WM_MBUTTONDOWN, w.WM_MBUTTONUP, w.WM_MBUTTONDBLCLK:
		return .M
	case w.WM_XBUTTONDOWN, w.WM_XBUTTONUP, w.WM_XBUTTONDBLCLK:
		if w.GET_XBUTTON_WPARAM(wParam) == w.XBUTTON1 {
			return .B4
		} else {
			return .B5
		}
	case:
		panic("Invalid msg parameter passed to convert_msg_to_mouse_button.")
	}
}

@(private)
convert_windows_keycode_to_engine_keycode :: proc(native_keycode: u16) -> (keycode: Key_Code, ok: bool) {
	// Not all Windows keycodes are implemented
	enum_values: []reflect.Type_Info_Enum_Value = reflect.enum_field_values(typeid_of(Key_Code))
	if !slice.contains(enum_values, cast(reflect.Type_Info_Enum_Value) native_keycode) {
		ok = false
		return
	}

	// On Windows, the key codes are a 1:1 mapping (except for modifiers - this is resolved later).
	keycode = cast(Key_Code) native_keycode
	ok = true
	return
}

@(private)
delete_raw_input_buffer :: proc(buffer: []byte) {
	delete(buffer)
}

@(private, deferred_out=delete_raw_input_buffer)
get_raw_input_buffer_from_lparam :: proc(lParam: w.LPARAM) -> []byte {
	data_size: u32 = ---
	raw_input_handle := cast(w.HRAWINPUT) lParam
	w.GetRawInputData(raw_input_handle, w.RID_INPUT, nil, &data_size, size_of(w.RAWINPUTHEADER))
	buffer := make([]byte, data_size)

	data_size_check := w.GetRawInputData(raw_input_handle, w.RID_INPUT, raw_data(buffer), &data_size, size_of(w.RAWINPUTHEADER))
	if data_size_check == max(u32) {
		log.error("An error occured in GetRawInputData.")
		log_windows_error()
		return nil
	}
	assert(data_size_check == data_size, "GetRawInputData did not return correct size.")

	return buffer
}

@(private)
make_scancode_from_raw_input :: proc(data: ^w.RAWKEYBOARD) -> u16 {
	assert(data != nil)
	e0 := data.Flags & RI_KEY_E0 != 0
	e1 := data.Flags & RI_KEY_E1 != 0
	assert(!(e0 && e1), "A scancode with both prefixes is invalid.")
	return data.MakeCode | (0xE000 * u16(e0)) | (0xE100 * u16(e1))
}

@(private)
convert_scancode_to_engine_keycode :: proc(hwnd: w.HWND, scancode: u16) -> (keycode: Key_Code, ok: bool) {
	key: Maybe(Key_Code) = nil
	switch scancode {
	case 0x000B: key = .Digit_0
	case 0x0002: key = .Digit_1
	case 0x0003: key = .Digit_2
	case 0x0004: key = .Digit_3
	case 0x0005: key = .Digit_4
	case 0x0006: key = .Digit_5
	case 0x0007: key = .Digit_6
	case 0x0008: key = .Digit_7
	case 0x0009: key = .Digit_8
	case 0x000A: key = .Digit_9

	case 0x001E: key = .A
	case 0x0030: key = .B
	case 0x002E: key = .C
	case 0x0020: key = .D
	case 0x0012: key = .E
	case 0x0021: key = .F
	case 0x0022: key = .G
	case 0x0023: key = .H
	case 0x0017: key = .I
	case 0x0024: key = .J
	case 0x0025: key = .K
	case 0x0026: key = .L
	case 0x0032: key = .M
	case 0x0031: key = .N
	case 0x0018: key = .O
	case 0x0019: key = .P
	case 0x0010: key = .Q
	case 0x0013: key = .R
	case 0x001F: key = .S
	case 0x0014: key = .T
	case 0x0016: key = .U
	case 0x002F: key = .V
	case 0x0011: key = .W
	case 0x002D: key = .X
	case 0x0015: key = .Y
	case 0x002C: key = .Z

	case 0x003B: key = .F1
	case 0x003C: key = .F2
	case 0x003D: key = .F3
	case 0x003E: key = .F4
	case 0x003F: key = .F5
	case 0x0040: key = .F6
	case 0x0041: key = .F7
	case 0x0042: key = .F8
	case 0x0043: key = .F9
	case 0x0044: key = .F10
	case 0x0057: key = .F11
	case 0x0058: key = .F12
	case 0x0064: key = .F13
	case 0x0065: key = .F14
	case 0x0066: key = .F15
	case 0x0067: key = .F16
	case 0x0068: key = .F17
	case 0x0069: key = .F18
	case 0x006A: key = .F19
	case 0x006B: key = .F20
	case 0x006C: key = .F21
	case 0x006D: key = .F22
	case 0x006E: key = .F23
	case 0x0076: key = .F24

	case 0x0052: key = .Numpad_0
	case 0x004F: key = .Numpad_1
	case 0x0050: key = .Numpad_2
	case 0x0051: key = .Numpad_3
	case 0x004B: key = .Numpad_4
	case 0x004C: key = .Numpad_5
	case 0x004D: key = .Numpad_6
	case 0x0047: key = .Numpad_7
	case 0x0048: key = .Numpad_8
	case 0x0049: key = .Numpad_9

	case 0x0037: key = .Numpad_Multiply
	case 0x004E: key = .Numpad_Add
	case 0x007E: key = .Numpad_Separator
	case 0x004A: key = .Numpad_Subtract
	case 0x0053: key = .Numpad_Decimal
	case 0x0059: key = .Numpad_Equals
	case 0xE035: key = .Numpad_Divide
	case 0xE01C: key = .Numpad_Enter
	
	case 0xE052: key = .Insert
	case 0xE053: key = .Delete
	case 0xE047: key = .Home
	case 0xE04F: key = .End
	case 0xE049: key = .Page_Up
	case 0xE051: key = .Page_Down
	case 0xE04B: key = .Left
	case 0xE050: key = .Down
	case 0xE04D: key = .Right
	case 0xE048: key = .Up

	case 0x0029: key = .Grave
	case 0x000C: key = .Minus
	case 0x000D: key = .Equals
	case 0x001A: key = .Left_Brace
	case 0x001B: key = .Right_Brace
	case 0x002B: key = .Backslash
	case 0x0027: key = .Semicolon
	case 0x0028: key = .Apostrophe
	case 0x0033: key = .Comma
	case 0x0034: key = .Period
	case 0x0035: key = .Slash

	case 0x000E: key = .Backspace
	case 0x000F: key = .Tab
	case 0x001C: key = .Enter
	case 0x0001: key = .Escape
	case 0x0039: key = .Space
	// Alt+PrtSc produces a different scancode
	case 0xE037, 0x54: key = .Print_Screen

	// PauseBreak is a special one - the scancode is too long to be passed in a single message (E1 1D 45)
	case 0xE11D:
		msg: w.MSG = ---
		if w.PeekMessageW(&msg, hwnd, w.WM_INPUT, w.WM_INPUT, w.PM_REMOVE) {
			assert(msg.message == w.WM_INPUT)
			raw_input := cast(^w.RAWINPUT) raw_data(get_raw_input_buffer_from_lparam(msg.lParam))
			assert(raw_input.header.dwType == w.RIM_TYPEKEYBOARD)
			data: ^w.RAWKEYBOARD = &raw_input.data.keyboard
			scancode := make_scancode_from_raw_input(data)
			if scancode == 0x45 {
				key = .Pause_Break
			}
		}
	// However, Ctrl+PauseBreak has a different, much more sane, scancode
	case 0xE046: key = .Pause_Break

	case 0x003A: key = .Caps_Lock
	case 0x0045: key = .Num_Lock
	case 0x0046: key = .Scroll_Lock

	case 0x002A: key = .Left_Shift
	case 0x0036: key = .Right_Shift
	case 0x001D: key = .Left_Control
	case 0xE01D: key = .Right_Control
	case 0x0038: key = .Left_Alt
	case 0xE038: key = .Right_Alt

	case 0xE05B: key = .Left_Win
	case 0xE05C: key = .Right_Win
	case 0xE05D: key = .Apps
	}

	ok = key != nil
	if ok {
		keycode = key.(Key_Code)
	}
	return
}

@(private)
TIMERID_MODAL_UNBLOCK :: 1

@(private)
window_proc :: proc "stdcall" (hwnd: w.HWND, msg: w.UINT, wParam: w.WPARAM, lParam: w.LPARAM) -> w.LRESULT {
	context_ptr := get_window_class_context()
	context = context_ptr^ if context_ptr != nil else runtime.default_context()

	assert(shared_data.event_callback_proc != nil, "Window Proc - event callback procedure not set.")

	window_handle := hwnd_to_handle(hwnd)

	msg_switch: switch msg {
	case w.WM_DESTROY:
		w.PostQuitMessage(0)
		return 0

	case w.WM_KEYDOWN, w.WM_KEYUP, w.WM_SYSKEYDOWN, w.WM_SYSKEYUP:
		native_keycode := w.LOWORD(cast(w.DWORD) wParam)
		key_flags := w.HIWORD(cast(w.DWORD) lParam)
		scancode := LOBYTE(key_flags)
		is_extended := bool(key_flags & w.KF_EXTENDED)
		if keycode, ok := convert_windows_keycode_to_engine_keycode(native_keycode); ok {
			is_up := bool(key_flags & w.KF_UP)
			is_repeated := bool(key_flags & w.KF_REPEAT)
			repeat_count := w.LOWORD(cast(w.DWORD) lParam)

			event_type: Key_Event_Type = ---
			if is_up {
				event_type = .Released
			} else if is_repeated {
				event_type = .Repeated
			} else {
				event_type = .Pressed
			}

			// Fix up some Windows quirks
			#partial switch keycode {
			// Modifier keys should send a proper event for right/left keys
			case .Control:
				// NOTE:
				// RAlt key also sends a LControl message on certain layouts
				// and then the actual Alt one.
				// Because the Windows input handling is so clunky, the event system
				// should have an additional raw input codepath to resolve all these weird cases.
				keycode = .Right_Control if is_extended else .Left_Control
			case .Shift:
				// R/L shift is not differentiated by the extended flag
				keycode = .Right_Shift if scancode == 0x36 else .Left_Shift
			case .Alt:
				keycode = .Right_Alt if is_extended else .Left_Alt
			// There isn't a dedicated VK code for numpad enter in Windows
			case .Enter:
				if is_extended {
					keycode = .Numpad_Enter
				}
			// Print screen does not fire a pressed event
			case .Print_Screen:
				print_screen_pressed_event := Key_Event{ 1, .Print_Screen, .Pressed, scancode }
				shared_data.event_callback_proc(window_handle, print_screen_pressed_event)
			}

			event := Key_Event{ repeat_count, keycode, event_type, scancode }
			shared_data.event_callback_proc(window_handle, event)
			return 0
		}

	case w.WM_LBUTTONDOWN, w.WM_LBUTTONUP, w.WM_LBUTTONDBLCLK,
		w.WM_RBUTTONDOWN, w.WM_RBUTTONUP, w.WM_RBUTTONDBLCLK,
		w.WM_MBUTTONDOWN, w.WM_MBUTTONUP, w.WM_MBUTTONDBLCLK,
		w.WM_XBUTTONDOWN, w.WM_XBUTTONUP, w.WM_XBUTTONDBLCLK:
		keycode: Mouse_Button = convert_msg_to_mouse_button(msg, wParam)

		down := msg == w.WM_LBUTTONDOWN || msg == w.WM_RBUTTONDOWN || msg == w.WM_MBUTTONDOWN || msg == w.WM_XBUTTONDOWN
		dbl_click := msg == w.WM_LBUTTONDBLCLK || msg == w.WM_RBUTTONDBLCLK || msg == w.WM_MBUTTONDBLCLK || msg == w.WM_XBUTTONDBLCLK
		event_type: Mouse_Event_Type = .Pressed if down || dbl_click else .Released
		
		event := Mouse_Event{ keycode, event_type }
		shared_data.event_callback_proc(window_handle, event)

		// In Windows, double click triggers *instead* of press, so it's called separately here to simplify the events
		if dbl_click {
			dbl_click_event := Mouse_Event{ keycode, .Double_Click }
			shared_data.event_callback_proc(window_handle, dbl_click_event)
		}
		return 0

	case w.WM_MOUSEMOVE:
		client_rect: w.RECT
		w.GetClientRect(hwnd, &client_rect)

		x: i32 = w.GET_X_LPARAM(lParam)
		y: i32 = w.GET_Y_LPARAM(lParam)
		x_norm: f32 = cast(f32) x / cast(f32) client_rect.right
		y_norm: f32 = cast(f32) y / cast(f32) client_rect.bottom

		event := Mouse_Moved_Event{ x, y, x_norm, y_norm }
		shared_data.event_callback_proc(window_handle, event)
		return 0

	case w.WM_INPUT:
		raw_input := cast(^w.RAWINPUT) raw_data(get_raw_input_buffer_from_lparam(lParam))
		if raw_input == nil {
			break
		}

		// Mouse Input
		switch raw_input.header.dwType {
		case w.RIM_TYPEMOUSE:
			data: ^w.RAWMOUSE = &raw_input.data.mouse
			button_flags := data.DUMMYUNIONNAME.DUMMYSTRUCTNAME.usButtonFlags
			button_data := data.DUMMYUNIONNAME.DUMMYSTRUCTNAME.usButtonData

			// Note: Literally every input action can be packed
			// as a single event so everything here has to be checked
			// each time to make sure not to miss anything

			// Post RawInputMouseMoveEvent if the mouse actually moved on this message
			if data.lLastX != 0 || data.lLastY != 0 {
				event := RI_Mouse_Moved_Event{ data.lLastX, data.lLastY }
				shared_data.event_callback_proc(window_handle, event)
			}

			// Mouse Scrolled Event
			if bool(button_flags & w.RI_MOUSE_WHEEL) {
				event := RI_Mouse_Scroll_Event{ cast(f32) button_data }
				shared_data.event_callback_proc(window_handle, event)
			}

			// Mouse Button Pressed Event
			// 0x0155 - combined mouse pressed button flags
			if bool(button_flags & 0x0155) {
				// There can be multiple presses in one message, so they have to be
				// looped through, so everything is sent as an event.
				for flag: u16 = 1 << 0; flag != 1 << 10; flag <<= 2 {
					button_flag: u16 = button_flags & flag
					if (button_flag != 0) {
						button: Mouse_Button = ---
						switch button_flag {
						case w.RI_MOUSE_BUTTON_1_DOWN:
							button = Mouse_Button.L
						case w.RI_MOUSE_BUTTON_2_DOWN:
							button = Mouse_Button.R
						case w.RI_MOUSE_BUTTON_3_DOWN:
							button = Mouse_Button.M
						case w.RI_MOUSE_BUTTON_4_DOWN:
							button = Mouse_Button.B4
						case w.RI_MOUSE_BUTTON_5_DOWN:
							button = Mouse_Button.B5
						}

						event := RI_Mouse_Event{ button, .Pressed }
						shared_data.event_callback_proc(window_handle, event)
					}
				}
			}

			// Mouse Button Released Event
			// 0x02AA - mouse released button flags combined
			if bool(button_flags & 0x02AA) {
				// Similar loop for button releases
				for flag: u16 = 1 << 1; flag != 1 << 11; flag <<= 2 {
					button_flag: u16 = button_flags & flag
					if (button_flag != 0) {
						button: Mouse_Button = ---
						switch button_flag {
						case w.RI_MOUSE_BUTTON_1_UP:
							button = Mouse_Button.L
						case w.RI_MOUSE_BUTTON_2_UP:
							button = Mouse_Button.R
						case w.RI_MOUSE_BUTTON_3_UP:
							button = Mouse_Button.M
						case w.RI_MOUSE_BUTTON_4_UP:
							button = Mouse_Button.B4
						case w.RI_MOUSE_BUTTON_5_UP:
							button = Mouse_Button.B5
						}

						event := RI_Mouse_Event{ button, .Released }
						shared_data.event_callback_proc(window_handle, event)
					}
				}
			}
		case w.RIM_TYPEKEYBOARD:
			data: ^w.RAWKEYBOARD = &raw_input.data.keyboard
			scancode := make_scancode_from_raw_input(data)
			// log.debug("RI Key: 0x%x, flags: 0x%x", scancode, data.Flags)
			is_up := data.Flags & 1 != 0
			if keycode, ok := convert_scancode_to_engine_keycode(hwnd, scancode); ok {
				event := RI_Key_Event{ 1, keycode, .Released if is_up else .Pressed, cast(u8) data.MakeCode }
				shared_data.event_callback_proc(window_handle, event)
			}
		}
		return 0

	case w.WM_SIZE:
		type: Window_Resized_Event_Type = .Normal
		switch wParam {
		case w.SIZE_MINIMIZED:
			type = .Minimize
		case w.SIZE_MAXIMIZED:
			type = .Maximize
		}

		event := Window_Resized_Event {
			width = cast(u32) w.LOWORD(cast(w.DWORD) lParam),
			height = cast(u32) w.HIWORD(cast(w.DWORD) lParam),
			type = type,
		}
		shared_data.event_callback_proc(window_handle, event)

		return 0

	case w.WM_MOVE:
		event := Window_Moved_Event {
			x = cast(i32) w.LOWORD(cast(w.DWORD) lParam),
			y = cast(i32) w.HIWORD(cast(w.DWORD) lParam),
		}
		shared_data.event_callback_proc(window_handle, event)

		return 0

	case w.WM_NCLBUTTONDOWN:
		if wParam == w.HTCAPTION {
			windows_data.mlh.clicked_caption = true
			windows_data.mlh.clicked_lparam = lParam
			// Enters the move modal loop immediately when clicking on the title bar.
			// Normally, there's some weird delay unless the mouse moves further.
			// TODO: Fix maximizing by dragging the window to the top
			w.DefWindowProcW(hwnd, w.WM_SYSCOMMAND, w.SC_MOVE, lParam)
			return 0
		}

	case w.WM_ENTERSIZEMOVE, w.WM_ENTERMENULOOP:
		if windows_data.mlh.clicked_caption {
			// Move the cursor to the place it was on click because
			// WM_SYSCOMMAND moves it to the middle of the title bar.
			// TODO: Fix DPI issues
			w.SetCursorPos(w.GET_X_LPARAM(windows_data.mlh.clicked_lparam), w.GET_Y_LPARAM(windows_data.mlh.clicked_lparam))
			windows_data.mlh.clicked_caption = false
		}
		w.SetTimer(hwnd, TIMERID_MODAL_UNBLOCK, w.USER_TIMER_MINIMUM, nil)

	case w.WM_EXITSIZEMOVE, w.WM_EXITMENULOOP:
		w.KillTimer(hwnd, TIMERID_MODAL_UNBLOCK)

	case w.WM_TIMER:
		switch wParam {
		case TIMERID_MODAL_UNBLOCK:
			when USE_MESSAGE_FIBER {
				// This will switch back to the _pump_events proc
				w.SwitchToFiber(windows_fiber_data.main_fiber)
			}
		}
	}

	return w.DefWindowProcW(hwnd, msg, wParam, lParam)
}
