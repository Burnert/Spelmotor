package core

import "core:prof/spall"

@(private)
g_spall: spall.Context
@(private)
g_spall_backing_buffer: []u8
@(private)
g_spall_buffer: spall.Buffer

@(deferred_in=_scoped_event_end)
@(no_instrumentation)
prof_scoped_event :: proc(name: string, location := #caller_location) {
	spall._buffer_begin(&g_spall, &g_spall_buffer, name, "", location)
}

@(private)
@(no_instrumentation)
_scoped_event_end :: proc(_: string, _ := #caller_location) {
	spall._buffer_end(&g_spall, &g_spall_buffer)
}

// Must be paired with an appropriate end_event call!
@(no_instrumentation)
prof_begin_event :: proc(name: string, location := #caller_location) {
	spall._buffer_begin(&g_spall, &g_spall_buffer, name, "", location)
}

@(no_instrumentation)
prof_end_event :: proc() {
	spall._buffer_end(&g_spall, &g_spall_buffer)
}

@(no_instrumentation)
prof_init :: proc() {
	g_spall = spall.context_create("spelmotor.spall")
	g_spall_backing_buffer = make([]u8, spall.BUFFER_DEFAULT_SIZE)
	g_spall_buffer = spall.buffer_create(g_spall_backing_buffer)
}

@(no_instrumentation)
prof_shutdown :: proc() {
	spall.buffer_destroy(&g_spall, &g_spall_buffer)
	delete(g_spall_backing_buffer)
	spall.context_destroy(&g_spall)
}
