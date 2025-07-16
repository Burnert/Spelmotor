package core

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:image/png"
import "core:log"
import "core:mem"
import os "core:os/os2"
import "core:reflect"
import "core:slice"
import "core:strings"
import "core:time"

/* Persistent registry of all physical assets present in the engine and the game. */

// TODO: Make unregistering assets possible eventually.

MESSAGE_ASSET_REGISTRY_IS_NOT_INITIALIZED :: "Asset registry is not initialized."

ASSET_EXT :: "asset"

EMPTY_ASSET_PATH :: Asset_Path{""}

Asset_Namespace :: enum {
	Engine,
	Game,
	Virtual,
}

// Data loaded from the asset file
Asset_Shared_Data :: struct {
	type: string, // asset type - key to the registered types map
	comment: string,
	source: string,
}

clone_asset_shared_data :: proc(asd: Asset_Shared_Data, allocator := context.allocator) -> (out_asd: Asset_Shared_Data) {
	out_asd.type    = strings.clone(asd.type, allocator)
	out_asd.comment = strings.clone(asd.comment, allocator)
	out_asd.source  = strings.clone(asd.source, allocator)
	return
}

destroy_asset_shared_data :: proc(asd: Asset_Shared_Data, allocator := context.allocator) {
	delete(asd.type, allocator)
	delete(asd.comment, allocator)
	delete(asd.source, allocator)
}

asset_data_cast :: proc(asset: ^Asset_Entry, $T: typeid) -> ^T {
	assert(asset != nil)
	type_id := typeid_of(^T)
	assert(asset._data_ptr_type == type_id)
	data := transmute(^T)&asset._data[0]
	return data
}

asset_type_data_raw :: proc(asset: ^Asset_Entry) -> rawptr {
	assert(asset != nil)
	return rawptr(&asset._data[0])
}

/*
Virtual asset path used to resolve the physical assets that is also an identifier.

It should only be created using make_asset_path.

Internally, the string is allocated in an Intern in the asset registry.

It has a form:

	<namespace>:<dir>/.../<name>

Examples:

	Engine:models/cube
	Game:textures/fruit/banana
	Virtual:textures/default
*/
Asset_Path :: struct {
	str: string,
}

make_asset_path :: proc(path: string) -> Asset_Path {
	assert(g_asreg != nil, MESSAGE_ASSET_REGISTRY_IS_NOT_INITIALIZED)
	interned_path, _ := strings.intern_get(&g_asreg.path_intern, path)
	return Asset_Path{interned_path}
}

// Resolved a path that's relative to the provided asset
asset_resolve_relative_path :: proc(asset: Asset_Entry, path: string, allocator := context.allocator) -> string {
	dir, _ := os.split_path(asset.physical_path)
	resolved_path, err := os.join_path([]string{dir, path}, allocator)
	assert(err == nil)
	return resolved_path
}

Asset_Type_Entry :: struct {
	type: typeid,
	ptr_type: typeid,
}

Asset_Registry :: struct {
	path_intern: strings.Intern,
	entries: map[Asset_Path]^Asset_Entry,
	types: map[string]Asset_Type_Entry,
	allocator: runtime.Allocator,
}

Asset_Entry :: struct #align(16) {
	path: Asset_Path,
	physical_path: string,
	namespace: Asset_Namespace,
	timestamp: time.Time,

	using shared_data: Asset_Shared_Data,

	_data_ptr_type: typeid, // for convenience when casting
	_data: [1]uintptr, // allocated inline when registering the asset (type info as pointer in _data_ptr_type)
}

// ASSET PERSISTENT REF ------------------------------------------------------------------------------------------------
// This is meant to be stored in various structures which are then serialized

Asset_Persistent_Ref :: struct($T: typeid) {
	path: Asset_Path,
	entry: ^Asset_Entry,
	data: ^T,
}

// Resolves the asset pointed by the ref and caches the pointer in the ref
asset_persistent_ref_load :: proc(ref: ^Asset_Persistent_Ref($T)) -> bool {
	assert(ref != nil)

	// Already loaded
	if ref.entry != nil {
		assert(ref.entry.path == ref.path)
		assert(ref.data != nil)
		return true
	}

	if ref.path == EMPTY_ASSET_PATH {
		log.error("Invalid ref passed in. Null path.")
		return false
	}

	ref.entry = asset_resolve(ref.path)
	if ref.entry == nil {
		log.errorf("Failed to load persistent asset reference '%s'.", ref.path)
		return false
	}

	ref.data = asset_data_cast(ref.entry, T)

	return true
}

asset_is_persistent_ref_loaded :: proc(ref: Asset_Persistent_Ref($T)) -> bool {
	return ref.entry != nil && ref.data != nil
}

asset_is_persistent_ref_valid :: proc(ref: Asset_Persistent_Ref($T)) -> bool {
	return ref.path != EMPTY_ASSET_PATH
}

asset_make_persistent_ref_from_entry :: proc(entry: ^Asset_Entry, $T: typeid) -> (ref: Asset_Persistent_Ref(T)) {
	ref.entry = entry
	if entry != nil {
		ref.path = entry.path
		ref.data = asset_data_cast(entry, T)
	}
	return
}

asset_make_persistent_ref_from_ref :: proc(ref: Asset_Ref($T)) -> (pref: Asset_Persistent_Ref(T)) {
	pref.entry = ref.entry
	pref.data = ref.data
	if ref.entry != nil {
		pref.path = ref.entry.path
	}
	return
}

asset_make_persistent_ref :: proc{
	asset_make_persistent_ref_from_entry,
	asset_make_persistent_ref_from_ref,
}

// ASSET REF ------------------------------------------------------------------------------------------------
// This is a ref that's valid only at runtime and is not meant to be serialized

Asset_Ref :: struct($T: typeid) {
	entry: ^Asset_Entry,
	data: ^T,
}

asset_make_ref :: proc(entry: ^Asset_Entry, $T: typeid) -> (ref: Asset_Ref(T)) {
	assert(entry != nil)
	ref.entry = entry
	ref.data = asset_data_cast(entry, T)
	return
}

asset_ref_is_valid :: proc(ref: Asset_Ref($T)) -> bool {
	return ref.entry != nil && ref.data != nil
}

asset_resolve_ref :: proc(path: string, $T: typeid) -> (ref: Asset_Ref(T)) {
	path := make_asset_path(path)
	entry := asset_resolve(path)
	return asset_make_ref(entry, T)
}

// ASSET REGISTRY ------------------------------------------------------------------------------------------------

asset_registry_init :: proc(reg: ^Asset_Registry, allocator := context.allocator) {
	assert(reg != nil)
	assert(g_asreg == nil)

	log.infof("Initializing asset registry...")

	strings.intern_init(&reg.path_intern, allocator, allocator)
	reg.entries = make(map[Asset_Path]^Asset_Entry, allocator)
	reg.allocator = allocator

	// Assign the global pointer
	g_asreg = reg

	log.info("Asset registry has been initialized.")
}

asset_registry_destroy :: proc(reg: ^Asset_Registry) {
	assert(reg != nil)

	strings.intern_destroy(&reg.path_intern)

	for k, entry in reg.entries {
		destroy_asset_entry(entry^)
		free(entry, reg.allocator)
	}
	delete(reg.entries)

	for k, _ in reg.types {
		delete(k)
	}
	delete(reg.types)
}

asset_register_type :: proc($T: typeid) {
	assert(g_asreg != nil, MESSAGE_ASSET_REGISTRY_IS_NOT_INITIALIZED)

	ti := type_info_of(T)
	ti_named := ti.variant.(runtime.Type_Info_Named)
	name := fmt.tprintf("%s.%s", ti_named.pkg, ti_named.name)

	if _, exists := g_asreg.types[name]; exists {
		panic(fmt.tprintf("Type %v has already been registered as %s.", typeid_of(T), name))
	}

	key := strings.clone(name, g_asreg.allocator)
	type_entry := map_insert(&g_asreg.types, key, Asset_Type_Entry{})
	type_entry.type = ti.id
	ptr_ti := type_info_of(^T)
	type_entry.ptr_type = ptr_ti.id

	log.infof("Type %s (%v) has been registered.", key, ti.id)
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
	// Virtual assets do not have a physical path, because they are created at runtime and are not stored on disk.
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

	// The asset files are split in two parts: 1. shared data, 2. type specific data
	// These parts are split with a delimiter "/* -||- */".
	asset_file_str := string(asset_file_bytes)
	asset_file_str_split := strings.split_n(asset_file_str, "/* -||- */", 2, context.temp_allocator)
	shared_str := strings.trim_space(asset_file_str_split[0])
	type_specific_str := strings.trim_space(asset_file_str_split[1])
	
	asset_shared_data: Asset_Shared_Data
	// TODO: Validate the data
	unmarshal_err := json.unmarshal_string(shared_str, &asset_shared_data, .MJSON)
	defer destroy_asset_shared_data(asset_shared_data, g_asreg.allocator)
	if unmarshal_err != nil {
		log.errorf("Failed to parse asset file '%s'.\n%v", absolute_path, unmarshal_err)
		return
	}

	asset_type_entry, type_ok := g_asreg.types[asset_shared_data.type]
	if !type_ok {
		log.errorf("Failed to load asset '%s' of an unregistered type '%s'.", absolute_path, asset_shared_data.type)
		return nil
	}

	asset_ti := type_info_of(asset_type_entry.type)
	assert(asset_ti.align <= 8)
	base_asset_entry_size := cast(int)offset_of(Asset_Entry, _data)
	asset_type_size := asset_ti.size
	asset_entry_size := base_asset_entry_size + asset_type_size

	// The asset data will be allocated inline with the entry to avoid indirections
	block, _ := mem.alloc(asset_entry_size, align_of(Asset_Entry), g_asreg.allocator)
	defer if unmarshal_err != nil do mem.free(block, g_asreg.allocator)

	entry = transmute(^Asset_Entry)block
	entry.path = make_asset_path(asset_path_str)
	entry.physical_path = strings.clone(file_info.fullpath, g_asreg.allocator)
	entry.namespace = namespace
	entry.timestamp = file_info.modification_time

	entry.shared_data = clone_asset_shared_data(asset_shared_data)

	entry._data_ptr_type = asset_type_entry.ptr_type
	asset_type_data_raw := asset_type_data_raw(entry)
	// double ptr situation because unmarshal needs a pointer to the data, but any also expects a pointer to the element.
	asset_type_data_any := any{&asset_type_data_raw, entry._data_ptr_type}
	// Parse the type specific data independently of the shared data.
	// It's way easier to implement correctly, because name collisions are not a thing this way.
	// TODO: Validate the data
	unmarshal_err = json.unmarshal_any(transmute([]byte)type_specific_str, asset_type_data_any, .MJSON)
	if unmarshal_err != nil {
		log.errorf("Failed to parse type specific data from asset file '%s'.\n%v", absolute_path, unmarshal_err)
		return
	}

	map_insert(&g_asreg.entries, entry.path, entry)

	log.infof("Asset '%s' has been registered.", entry.path.str)

	return
}

asset_register_all_from_filesystem :: proc() {
	asset_count: int
	error_count: int

	// Now, scan the filesystem for physical asset files
	// NOTE: This could be separated to a different function
	engine_res := path_make_engine_resources()
	walker := os.walker_create(engine_res)
	defer os.walker_destroy(&walker)
	for fi in os.walker_walk(&walker) {
		if path, err := os.walker_error(&walker); err != nil {
			log.errorf("Failed to walk '%s'.", path)
			continue
		}

		base, ext := os.split_filename(fi.name)
		if ext != ASSET_EXT {
			continue
		}

		entry := asset_register_physical(fi, .Engine)
		if entry != nil {
			asset_count += 1
		} else {
			error_count += 1
		}
	}

	log.infof("Registered %i assets from the filesystem.", asset_count)

	if error_count > 0 {
		if error_count > 1 {
			log.warnf("%i assets have failed to load!", error_count)
		} else {
			log.warn("1 asset has failed to load!")
		}
	}
}

asset_resolve :: proc(path: Asset_Path) -> ^Asset_Entry {
	assert(g_asreg != nil, MESSAGE_ASSET_REGISTRY_IS_NOT_INITIALIZED)

	entry, ok := g_asreg.entries[path]
	// If the asset is requested for the first time, it will not be registered yet.
	// It could also have been modified externally and invalidated.
	// TODO: Implement a file watcher to make this invalidation automatic
	if !ok {
		split_path := strings.split_n(cast(string)path.str, ":", 1, context.temp_allocator)
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
	destroy_asset_shared_data(entry.shared_data)
	// FIXME: destroy the type specific data
}

// Global asset registry pointer for convenience (there is going to be only one of these)
@(private="file")
g_asreg: ^Asset_Registry
