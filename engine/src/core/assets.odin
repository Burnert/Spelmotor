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

Asset_Static_Mesh_Group :: enum {
	Default,
	Architecture,
	Prop,
	Detail,
	Foliage,
}

// This data will be loaded from the asset files
Asset_Data_Static_Mesh :: struct {
	group: Asset_Static_Mesh_Group,
}

Asset_Loaded_Data_Static_Mesh_Primitive :: struct($V: typeid) {
	name: string,
	vertices: []V,
	indices: []u32,
}

Asset_Loaded_Data_Static_Mesh :: struct($V: typeid) {
	using asset_data: ^Asset_Data_Static_Mesh,
	primitives: []Asset_Loaded_Data_Static_Mesh_Primitive(V),
}

asset_load_static_mesh :: proc($V: typeid, entry: ^Asset_Entry, allocator := context.allocator) -> (ld: Asset_Loaded_Data_Static_Mesh(V)) {
	assert(entry != nil)
	assert(entry.data.type == .Static_Mesh)
	
	source_path := asset_resolve_relative_path(entry^, entry.data.source, context.temp_allocator)
	_, ext := os.split_filename(entry.data.source)

	switch ext {
	case "glb":
		gltf_config := gltf_make_config_from_vertex(V)
		gltf_mesh, gltf_res := import_mesh_gltf(source_path, V, gltf_config)
		defer destroy_gltf_mesh(&gltf_mesh)
		result_verify(gltf_res)

		// TODO: It would be a good idea to merge the GLTF and generic mesh/primitive structs, because they are essentially identical
		ld.primitives = make([]Asset_Loaded_Data_Static_Mesh_Primitive(V), len(gltf_mesh.primitives), allocator)
		for prim, i in gltf_mesh.primitives {
			ld.primitives[i].name = strings.clone(prim.name, allocator)
			ld.primitives[i].vertices = slice.clone(prim.vertices, allocator)
			ld.primitives[i].indices = slice.clone(prim.indices, allocator)
		}

	case: panic(fmt.tprintf("Static Mesh asset source format '%s' unsupported.", ext))
	}

	ld.asset_data = &entry.data._type_data.(Asset_Data_Static_Mesh)

	return
}

// TODO: Return errors
asset_load_static_mesh_into_buffer :: proc(entry: ^Asset_Entry, buffer: []byte) {
	assert(entry != nil)
	assert(entry.data.type == .Static_Mesh)

	data := asset_data_cast(entry, Asset_Data_Static_Mesh)
}

asset_destroy_loaded_static_mesh_data :: proc(ld: Asset_Loaded_Data_Static_Mesh($V), allocator := context.allocator) {
	for p in ld.primitives {
		delete(p.name, allocator)
		delete(p.vertices, allocator)
		delete(p.indices, allocator)
	}
	delete(ld.primitives, allocator)
}

Asset_Texture_Group :: enum {
	World,
}

// TODO: These should be unified with the ones from rhi

// Synced with rhi.Filter
Asset_Texture_Filter :: enum {
	Nearest,
	Linear,
}

// Synced with rhi.Address_Mode
Asset_Texture_Address_Mode :: enum {
	Repeat,
	Clamp,
}

// This data will be loaded from the asset files
Asset_Data_Texture :: struct {
	dims: [2]u32,
	channels: u32,
	filter: Asset_Texture_Filter,
	address_mode: Asset_Texture_Address_Mode,
	srgb: bool,
	group: Asset_Texture_Group,
}

Asset_Loaded_Data_Texture :: struct {
	using asset_data: ^Asset_Data_Texture,
	requested_size: uint,
	image_data: union {
		^png.Image,
	},
}

// TODO: Return errors
asset_load_texture :: proc(entry: ^Asset_Entry, allocator := context.allocator) -> (ld: Asset_Loaded_Data_Texture) {
	assert(entry != nil)
	assert(entry.data.type == .Texture)
	
	source_path := asset_resolve_relative_path(entry^, entry.data.source, context.temp_allocator)
	_, ext := os.split_filename(entry.data.source)

	switch ext {
	case "png":
		img, err := png.load(source_path, png.Options{.alpha_add_if_missing}, allocator)
		assert(err == nil)
		assert(img.channels == 4, "Loaded image channels must be 4.")
		ld.image_data = img
		ld.requested_size = len(img.pixels.buf)

	case: panic(fmt.tprintf("Texture asset source format '%s' unsupported.", ext))
	}

	ld.asset_data = &entry.data._type_data.(Asset_Data_Texture)

	return
}

// Loading is split into two steps, because a buffer length needs to be known to allocate it.
asset_load_texture_into_buffer :: proc(ld: Asset_Loaded_Data_Texture, buffer: []byte) {
	assert(ld.requested_size <= len(buffer))
	switch img_data in ld.image_data {
	case ^png.Image:
		mem.copy_non_overlapping(&buffer[0], &img_data.pixels.buf[0], cast(int)ld.requested_size)
	}
}

asset_destroy_loaded_texture_data :: proc(ld: Asset_Loaded_Data_Texture, allocator := context.allocator) {
	png.destroy(ld.image_data.(^png.Image))
}

Asset_Data_Union :: union{
	Asset_Data_Static_Mesh,
	Asset_Data_Texture,
}

Asset_Data :: struct {
	comment: string,
	type: Asset_Type,
	source: string,

	_type_data: Asset_Data_Union,
}

clone_asset_data :: proc(in_ad: Asset_Data, allocator := context.allocator) -> (ad: Asset_Data) {
	ad = in_ad
	ad.comment = strings.clone(in_ad.comment, allocator)
	ad.source = strings.clone(in_ad.source, allocator)
	return
}

destroy_asset_data :: proc(ad: Asset_Data, allocator := context.allocator) {
	delete(ad.comment, allocator)
	delete(ad.source, allocator)
}

asset_data_cast :: proc(asset: ^Asset_Entry, $T: typeid) -> ^T {
	return &asset.data._type_data.(T)
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

Asset_Registry :: struct {
	path_intern: strings.Intern,
	entries: map[Asset_Path]^Asset_Entry,
	allocator: runtime.Allocator,
}

Asset_Entry :: struct #align(16) {
	path: Asset_Path,
	physical_path: string,
	namespace: Asset_Namespace,
	timestamp: time.Time,

	data: Asset_Data,
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
	
	asset_data: Asset_Data
	// TODO: Validate the data
	unmarshal_err := json.unmarshal_string(shared_str, &asset_data, .MJSON)
	defer destroy_asset_data(asset_data, g_asreg.allocator)
	if unmarshal_err != nil {
		log.errorf("Failed to parse asset file '%s'.\n%v", absolute_path, unmarshal_err)
		return
	}

	entry = new(Asset_Entry, g_asreg.allocator)
	entry.path = make_asset_path(asset_path_str)
	entry.physical_path = strings.clone(file_info.fullpath, g_asreg.allocator)
	entry.namespace = namespace
	entry.timestamp = file_info.modification_time
	entry.data = clone_asset_data(asset_data, g_asreg.allocator)

	// Parse the type specific data independently of the shared data.
	// It's way easier to implement correctly, because name collisions are not a thing this way.
	switch entry.data.type {
	case .Static_Mesh:
		entry.data._type_data = Asset_Data_Static_Mesh{}
		static_mesh_data := &entry.data._type_data.(Asset_Data_Static_Mesh)
		// TODO: Validate the data
		err := json.unmarshal_string(type_specific_str, static_mesh_data, .MJSON)
		assert(err == nil)

	case .Texture:
		entry.data._type_data = Asset_Data_Texture{}
		texture_data := &entry.data._type_data.(Asset_Data_Texture)
		// TODO: Validate the data
		err := json.unmarshal_string(type_specific_str, texture_data, .MJSON)
		assert(err == nil)
	}

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
	destroy_asset_data(entry.data)
}

// Global asset registry pointer for convenience (there is going to be only one of these)
@(private="file")
g_asreg: ^Asset_Registry
