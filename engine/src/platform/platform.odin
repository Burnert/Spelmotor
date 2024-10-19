package platform

import "base:runtime"
import "core:log"

Window_Handle :: distinct uint
INVALID_WINDOW_HANDLE :: max(Window_Handle)

Window_Desc :: struct {
	width: u32,
	height: u32,
	position: Maybe([2]i32),
	title: string,

	fixed_size: bool,
}

// Based on Windows VK codes
Key_Code :: enum(u8) {
	Digit_0          = '0',
	Digit_1          = '1',
	Digit_2          = '2',
	Digit_3          = '3',
	Digit_4          = '4',
	Digit_5          = '5',
	Digit_6          = '6',
	Digit_7          = '7',
	Digit_8          = '8',
	Digit_9          = '9',

	A                = 'A',
	B                = 'B',
	C                = 'C',
	D                = 'D',
	E                = 'E',
	F                = 'F',
	G                = 'G',
	H                = 'H',
	I                = 'I',
	J                = 'J',
	K                = 'K',
	L                = 'L',
	M                = 'M',
	N                = 'N',
	O                = 'O',
	P                = 'P',
	Q                = 'Q',
	R                = 'R',
	S                = 'S',
	T                = 'T',
	U                = 'U',
	V                = 'V',
	W                = 'W',
	X                = 'X',
	Y                = 'Y',
	Z                = 'Z',

	Shift            = 0x10,
	Control          = 0x11,
	Alt              = 0x12,

	Left_Shift       = 0xA0,
	Right_Shift      = 0xA1,
	Left_Control     = 0xA2,
	Right_Control    = 0xA3,
	Left_Alt         = 0xA4,
	Right_Alt        = 0xA5,

	Backspace        = 0x08,
	Tab              = 0x09,
	Enter            = 0x0D,
	Pause_Break      = 0x13,
	Escape           = 0x1B,
	Space            = 0x20,
	Page_Up          = 0x21,
	Page_Down        = 0x22,
	End              = 0x23,
	Home             = 0x24,
	Left             = 0x25,
	Up               = 0x26,
	Right            = 0x27,
	Down             = 0x28,
	Print_Screen     = 0x2C,
	Insert           = 0x2D,
	Delete           = 0x2E,

	Left_Win         = 0x5B,
	Right_Win        = 0x5C,
	Apps             = 0x5D,

	Numpad_0         = 0x60,
	Numpad_1         = 0x61,
	Numpad_2         = 0x62,
	Numpad_3         = 0x63,
	Numpad_4         = 0x64,
	Numpad_5         = 0x65,
	Numpad_6         = 0x66,
	Numpad_7         = 0x67,
	Numpad_8         = 0x68,
	Numpad_9         = 0x69,

	Numpad_Multiply  = 0x6A,
	Numpad_Add       = 0x6B,
	Numpad_Separator = 0x6C,
	Numpad_Subtract  = 0x6D,
	Numpad_Decimal   = 0x6E,
	Numpad_Divide    = 0x6F,
	Numpad_Equals    = 0x92,
	Numpad_Enter     = 0x97,

	F1               = 0x70,
	F2               = 0x71,
	F3               = 0x72,
	F4               = 0x73,
	F5               = 0x74,
	F6               = 0x75,
	F7               = 0x76,
	F8               = 0x77,
	F9               = 0x78,
	F10              = 0x79,
	F11              = 0x7A,
	F12              = 0x7B,
	F13              = 0x7C,
	F14              = 0x7D,
	F15              = 0x7E,
	F16              = 0x7F,
	F17              = 0x80,
	F18              = 0x81,
	F19              = 0x82,
	F20              = 0x83,
	F21              = 0x84,
	F22              = 0x85,
	F23              = 0x86,
	F24              = 0x87,

	Caps_Lock        = 0x14,
	Num_Lock         = 0x90,
	Scroll_Lock      = 0x91,

	Semicolon        = 0xBA,
	Equals           = 0xBB,
	Comma            = 0xBC,
	Minus            = 0xBD,
	Period           = 0xBE,
	Slash            = 0xBF,
	Grave            = 0xC0,
	Left_Brace       = 0xDB,
	Right_Brace      = 0xDD,
	Backslash        = 0xDC,
	Apostrophe       = 0xDE,
}

Key_Event_Type :: enum(u8) {
	Pressed,
	Released,
	Repeated,
}

Key_Event :: struct {
	repeat_count: u16,
	keycode: Key_Code,
	type: Key_Event_Type,
	scancode: u8,
}

RI_Key_Event :: struct {
	repeat_count: u16,
	keycode: Key_Code,
	type: Key_Event_Type,
	scancode: u8,
}

// Based on Windows key codes
Mouse_Button :: enum(u8) {
	L  = 0x01,
	R  = 0x02,
	M  = 0x04,
	B4 = 0x05,
	B5 = 0x06,
}

Mouse_Event_Type :: enum {
	Pressed,
	Released,
	Double_Click,
}

Mouse_Event :: struct {
	button: Mouse_Button,
	type: Mouse_Event_Type,
}

Mouse_Moved_Event :: struct {
	x: i32,
	y: i32,
	x_norm: f32,
	y_norm: f32,
}

RI_Mouse_Event :: struct {
	button: Mouse_Button,
	type: Mouse_Event_Type,
}

RI_Mouse_Moved_Event :: struct {
	x: i32,
	y: i32,
}

RI_Mouse_Scroll_Event :: struct {
	value: f32,
}

Window_Resized_Event_Type :: enum {
	Normal,
	Minimize,
	Maximize,
}

Window_Resized_Event :: struct {
	width: u32,
	height: u32,
	type: Window_Resized_Event_Type,
}

Window_Moved_Event :: struct {
	x: i32,
	y: i32,
}

System_Event :: union {
	Key_Event,
	RI_Key_Event,

	Mouse_Event,
	Mouse_Moved_Event,
	RI_Mouse_Event,
	RI_Mouse_Moved_Event,
	RI_Mouse_Scroll_Event,

	Window_Resized_Event,
	Window_Moved_Event,
}

Shared_Data :: struct {
	event_callback_proc: proc(window: Window_Handle, event: System_Event),
}

shared_data := Shared_Data{}

init :: proc() -> bool {
	if shared_data.event_callback_proc == nil {
		log.error("Cannot initialize the platform layer if the event callback is not set.")
		return false
	}
	_init()
	return true
}

shutdown :: proc() {
	_shutdown()
	shared_data.event_callback_proc = nil
}

register_raw_input_devices :: proc() -> bool {
	return _register_raw_input_devices()
}

create_window :: proc(window_desc: Window_Desc) -> (handle: Window_Handle, ok: bool) {
	return _create_window(window_desc)
}

destroy_window :: proc(handle: Window_Handle) -> bool {
	return _destroy_window(handle)
}

show_window :: proc(handle: Window_Handle) {
	_show_window(handle)
}

hide_window :: proc(handle: Window_Handle) {
	_hide_window(handle)
}

get_window_client_size :: proc(handle: Window_Handle) -> (width: u32, height: u32) {
	return _get_window_client_size(handle)
}

get_native_window_handle :: proc(handle: Window_Handle) -> rawptr {
	return _get_native_window_handle(handle)
}

// The handle might be invalid if the application has not created any windows
get_main_window :: proc() -> Window_Handle {
	return Window_Handle(0)
}

pump_events :: proc() -> bool {
	return _pump_events()
}

log_to_native_console :: proc(data: rawptr, level: runtime.Logger_Level, text: string, options: runtime.Logger_Options, location := #caller_location) {
	_log_to_native_console(data, level, text, options, location)
}

show_message_box :: proc(title, message: string) {
	_show_message_box(title, message)
}
