package core

import "base:runtime"
import "core:fmt"
import "core:log"

import "sm:platform"

create_engine_logger :: proc() -> log.Logger {
	return log.Logger{ log_procedure, nil, .Debug, nil }
}

log_procedure :: proc(data: rawptr, level: runtime.Logger_Level, text: string, options: runtime.Logger_Options, location := #caller_location) {
	level_label: string = ---
	switch level {
	case .Debug..<.Info:
		level_label = "[DEBUG]"
	case .Info..<.Warning:
		level_label = "[INFO]"
	case .Warning..<.Error:
		level_label = "[WARNING]"
	case .Error..<.Fatal:
		level_label = "[ERROR]"
	case .Fatal:
		level_label = "[FATAL]"
	}
	text := fmt.tprintf("%s %s\n", level_label, text)
	platform.log_to_native_console(data, level, text, options, location)
}
