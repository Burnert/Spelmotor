package core

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:slice"

import "sm:platform"

// BROADCASTER ---------------------------------------------------------------------------------------------------------

Broadcaster :: struct($A: typeid) where intrinsics.type_is_struct(A) {
	callbacks: [dynamic]proc(args: A),
}

broadcaster_add_callback :: proc(broadcaster: ^$B/Broadcaster($A), callback: proc(args: A)) {
	assert(broadcaster != nil)
	if !slice.contains(broadcaster.callbacks[:], callback) {
		append(&broadcaster.callbacks, callback)
	}
}

broadcaster_remove_callback :: proc(broadcaster: ^$B/Broadcaster($A), callback: proc(args: A)) {
	assert(broadcaster != nil)
	if i, ok := slice.linear_search(broadcaster.callbacks[:], callback); ok {
		ordered_remove(&broadcaster.callbacks, callback)
	}
}

broadcaster_broadcast :: proc(broadcaster: ^$B/Broadcaster($A), args: A) {
	assert(broadcaster != nil)
	for cb in broadcaster.callbacks {
		assert(cb != nil)
		cb(args)
	}
}

broadcaster_delete :: proc(broadcaster: ^$B/Broadcaster($A)) {
	assert(broadcaster != nil)
	delete(broadcaster.callbacks)
}

// ASSERTS ---------------------------------------------------------------------------------------------------------

assertion_failure :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	message := fmt.tprintf("%s\n%s at %s(%i:%i)", message, loc.procedure, loc.file_path, loc.line, loc.column)
	platform.show_message_box("Assertion failure.", message)
	runtime.default_assertion_failure_proc(prefix, message, loc)
}

// STRINGS ---------------------------------------------------------------------------------------------------------

string_from_array :: proc(array: ^$T/[$I]$E) -> string {
	return strings.string_from_null_terminated_ptr(raw_data(array[:]), len(array))
}
