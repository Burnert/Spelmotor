package core

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import os "core:os/os2"
import "core:reflect"
import "core:strings"
import "core:time"

/* Persistent registry of all physical assets present in the engine and the game. */

// TODO: Make unregistering assets possible eventually.

MESSAGE_ASSET_REGISTRY_IS_NOT_INITIALIZED :: "Asset registry is not initialized."

ASSET_EXT :: "asset"

Asset_Namespace :: enum {
	Engine,
	Game,
	Virtual,
}

// TODO: Maybe this should be more extensible than just an enum
Asset_Type :: enum {
	Static_Mesh,
	Texture,
}

/*
Virtual asset path used to resolve the physical assets that is also an identifier.

It has a form:

    <namespace>:<dir>/.../<name>

Examples:

    Engine:models/cube
    Game:textures/fruit/banana
    Virtual:textures/default

Internally, the string is allocated in an Intern in the asset registry.
*/
Asset_Path :: distinct string

Asset_Registry :: struct {
	path_intern: strings.Intern,
	entries: map[Asset_Path]^Asset_Entry,
	allocator: runtime.Allocator,
}

Asset_Metadata :: struct {
	type: Asset_Type,
	source: string,
}

Asset_File_Schema :: struct {
	meta: Asset_Metadata,
}

Asset_Entry :: struct #align(16) {
	path: Asset_Path,
	physical_path: string,
	namespace: Asset_Namespace,
	timestamp: time.Time,

	metadata: Asset_Metadata,
}

make_asset_path :: proc(path: string) -> Asset_Path {
	assert(g_asreg != nil, MESSAGE_ASSET_REGISTRY_IS_NOT_INITIALIZED)
	interned_path, _ := strings.intern_get(&g_asreg.path_intern, path)
	return cast(Asset_Path)interned_path
}

clone_asset_metadata :: proc(meta: Asset_Metadata, allocator := context.allocator) -> Asset_Metadata {
	meta := meta
	meta.source = strings.clone(meta.source, allocator)
	return meta
}

destroy_asset_metadata :: proc(meta: Asset_Metadata) {
	delete(meta.source, g_asreg.allocator)
}

destroy_asset_file_schema :: proc(afs: Asset_File_Schema) {
	destroy_asset_metadata(afs.meta)
}

asset_registry_init :: proc(reg: ^Asset_Registry, allocator := context.allocator) {
	assert(reg != nil)
	assert(g_asreg == nil)

	log.infof("Initializing asset registry...")

	strings.intern_init(&reg.path_intern, allocator, allocator)
	reg.entries = make(map[Asset_Path]^Asset_Entry, allocator)
	reg.allocator = allocator

	// Assign the global pointer
	g_asreg = reg

	asset_count: int
	error_count: int

	// Now, scan the filesystem for physical asset files
	engine_res := path_make_engine_resources()
	walker := os.walker_create(engine_res)
	defer os.walker_destroy(&walker)
	for f in os.walker_walk(&walker) {
		if path, err := os.walker_error(&walker); err != nil {
			log.errorf("Failed to walk '%s'.", path)
			continue
		}

		base, ext := os.split_filename(f.name)
		if ext != ASSET_EXT {
			continue
		}

		entry := asset_register_physical(f, .Engine)
		if entry != nil {
			asset_count += 1
		} else {
			error_count += 1
		}
	}

	log.infof("Asset registry has been initialized with %i assets.", asset_count)

	if error_count > 0 {
		if error_count > 1 {
			log.warnf("%i assets have failed to load!", error_count)
		} else {
			log.warn("1 asset has failed to load!")
		}
	}
}

asset_registry_destroy :: proc(reg: ^Asset_Registry) {
	assert(reg != nil)
	strings.intern_destroy(&reg.path_intern)
	for k, entry in reg.entries {
		destroy_asset_entry(entry^)
		free(entry, reg.allocator)
	}
	delete(reg.entries)
}

asset_register_virtual :: proc(name: string) -> (path: Asset_Path, entry: ^Asset_Entry) {
	assert(g_asreg != nil, MESSAGE_ASSET_REGISTRY_IS_NOT_INITIALIZED)

	path = make_asset_path(fmt.tprintf("Virtual:%s", name))
	already_exists: bool
	if entry, already_exists = g_asreg.entries[path]; already_exists {
		log.warnf("Virtual asset '%s' already exists.", name)
		return
	}

	entry = new(Asset_Entry, g_asreg.allocator)
	entry.path = path
	// Internal assets do not have a physical path, because they are created at runtime and are not stored on disk.
	entry.physical_path = ""
	entry.namespace = .Virtual
	entry.timestamp = time.now()
	map_insert(&g_asreg.entries, entry.path, entry)

	log.infof("Registered virtual asset '%s'.", name)

	return
}

asset_register_physical :: proc(file_info: os.File_Info, namespace: Asset_Namespace) -> (entry: ^Asset_Entry) {
	assert(namespace != .Virtual)

	base_dir: string
	switch namespace {
	case .Engine:
		base_dir = path_make_engine_resources(context.temp_allocator)
	case .Game:
		// TODO: Impl game namespace
		unimplemented()
	case .Virtual:
		panic("Virtual assets need to be registered using a proper function.")
	}

	err: os.Error
	base_dir, err = os.get_absolute_path(base_dir, context.temp_allocator)
	assert(err == nil)

	absolute_path, relative_path: string
	absolute_path, err = os.get_absolute_path(file_info.fullpath, context.temp_allocator)
	assert(err == nil)
	relative_path, err = os.get_relative_path(base_dir, absolute_path, context.temp_allocator)

	asset_path_str: string
	dir, filename := os.split_path(relative_path)
	filename_base, _ := os.split_filename(filename)
	if dir == "" {
		asset_path_str = fmt.tprintf("%s:%s", namespace, filename_base)
	} else {
		dir, _ := strings.replace_all(dir, os.Path_Separator_String, "/", context.temp_allocator)
		asset_path_str = fmt.tprintf("%s:%s/%s", namespace, dir, filename_base)
	}

	asset_file_bytes: []byte
	asset_file_bytes, err = os.read_entire_file(absolute_path, context.allocator)
	defer delete(asset_file_bytes)
	if err != nil {
		log.errorf("Failed to read asset file '%s'.", absolute_path)
		return
	}
	
	asset_file: Asset_File_Schema
	unmarshal_err := json.unmarshal(asset_file_bytes, &asset_file, .MJSON)
	defer destroy_asset_file_schema(asset_file)
	if unmarshal_err != nil {
		log.errorf("Failed to parse asset file '%s'.\n%v", absolute_path, unmarshal_err)
		return
	}

	entry = new(Asset_Entry, g_asreg.allocator)
	entry.path = make_asset_path(asset_path_str)
	entry.physical_path = strings.clone(file_info.fullpath, g_asreg.allocator)
	entry.namespace = namespace
	entry.timestamp = file_info.modification_time
	entry.metadata = clone_asset_metadata(asset_file.meta, g_asreg.allocator)
	map_insert(&g_asreg.entries, entry.path, entry)

	log.infof("Asset '%s' has been registered.", entry.path)

	return
}

asset_resolve :: proc(path: Asset_Path) -> ^Asset_Entry {
	assert(g_asreg != nil, MESSAGE_ASSET_REGISTRY_IS_NOT_INITIALIZED)

	entry, ok := g_asreg.entries[path]
	// If the asset is requested for the first time, it will not be registered yet.
	// It could also have been modified externally and invalidated.
	// TODO: Implement a file watcher to make this invalidation automatic
	if !ok {
		split_path := strings.split_n(cast(string)path, ":", 1, context.temp_allocator)
		if len(split_path) != 2 {
			log.errorf("'%s' is not a valid asset path.", path)
			return nil
		}

		namespace_str := split_path[0]
		relative_path_no_ext := split_path[1]

		namespace, ok_namespace := reflect.enum_from_name(Asset_Namespace, namespace_str)
		if !ok_namespace {
			log.errorf("'%s' is not a valid asset namespace.", namespace_str)
			return nil
		}

		switch namespace {
		case .Engine:
			relative_path := fmt.tprintf("%s.%s", relative_path_no_ext, ASSET_EXT)
			absolute_path := path_make_engine_resources_relative(relative_path, context.temp_allocator)
			fi, err := os.stat(absolute_path, context.temp_allocator)
			if err != nil {
				log.errorf("Could not resolve physical asset '%s'.", absolute_path)
				return nil
			}

			entry = asset_register_physical(fi, .Engine)

		case .Game:
			// TODO: Impl game namespace

		case .Virtual:
			log.errorf("Failed to resolve virtual asset '%s', as it has not been registered yet.", relative_path_no_ext)
			return nil
		}
	}

	return entry
}

destroy_asset_entry :: proc(entry: Asset_Entry) {
	delete(entry.physical_path, g_asreg.allocator)
	destroy_asset_metadata(entry.metadata)
}

// Global asset registry pointer for convenience (there is going to be only one of these)
@(private="file")
g_asreg: ^Asset_Registry
