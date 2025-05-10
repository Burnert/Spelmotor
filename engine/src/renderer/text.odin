package sm_renderer_3d

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:strings"
import ft "smv:freetype"

import "sm:core"
import "sm:platform"
import "sm:rhi"

// Static Text ------------------------------------------------------------------------------------------------

Text_Geometry :: struct {
	text_vb: rhi.Buffer,
	text_ib: rhi.Buffer,
}

create_text_geometry :: proc(text: string, font: string = DEFAULT_FONT) -> (geo: Text_Geometry) {
	if len(text) == 0 {
		return
	}

	requirements := calc_text_buffer_requirements(text)

	vertices := make([]Text_Vertex, requirements.vertex_count)
	defer delete(vertices)
	indices := make([]u32, requirements.index_count)
	defer delete(indices)

	visible_character_count, text_ok := fill_text_geometry(text, {0,0}, 0, vertices, indices, font)
	if !text_ok {
		return
	}

	rhi_result: rhi.Result
	buffer_desc := rhi.Buffer_Desc{
		memory_flags = {.Device_Local},
	}
	geo.text_vb, rhi_result = rhi.create_vertex_buffer(buffer_desc, vertices[:visible_character_count*TEXT_VERTICES_PER_GLYPH])
	geo.text_ib, rhi_result = rhi.create_index_buffer(buffer_desc, indices[:visible_character_count*TEXT_INDICES_PER_GLYPH])

	return
}

destroy_text_geometry :: proc(geo: ^Text_Geometry) {
	rhi.destroy_buffer(&geo.text_vb)
	rhi.destroy_buffer(&geo.text_ib)
}

draw_text_geometry :: proc(cb: ^rhi.RHI_Command_Buffer, geo: Text_Geometry, pos: Vec2, fb_dims: [2]u32) {
	// X+right, Y+up, Z+intoscreen ortho matrix
	ortho_matrix := linalg.matrix_ortho3d_f32(0, f32(fb_dims.x), 0, f32(fb_dims.y), -1, 1, false)
	model_matrix := linalg.matrix4_translate_f32(vec3(pos, 0))
	constants := Text_Push_Constants{
		mvp_matrix = ortho_matrix * model_matrix,
	}
	rhi.cmd_push_constants(cb, g_renderer.text_renderer_state.pipeline_layout, {.Vertex}, &constants)
	rhi.cmd_bind_vertex_buffer(cb, geo.text_vb)
	rhi.cmd_bind_index_buffer(cb, geo.text_ib)
	rhi.cmd_draw_indexed(cb, geo.text_ib.elem_count)
}

// Dynamic Text ------------------------------------------------------------------------------------------------

Dynamic_Text_Geometry :: struct {
	vb: ^rhi.Buffer,
	ib: ^rhi.Buffer,
	vb_offset: uint,
	ib_offset: uint,
	index_count: uint,
}

Dynamic_Text_Buffers :: struct {
	vbs: [MAX_FRAMES_IN_FLIGHT]rhi.Buffer,
	ibs: [MAX_FRAMES_IN_FLIGHT]rhi.Buffer,
	vb_cursor: [MAX_FRAMES_IN_FLIGHT]int,
	ib_cursor: [MAX_FRAMES_IN_FLIGHT]int,
}

create_dynamic_text_buffers :: proc(max_glyph_count: uint) -> (dtb: Dynamic_Text_Buffers, result: rhi.Result) {
	text_buf_desc := rhi.Buffer_Desc{
		memory_flags = {.Device_Local, .Host_Visible, .Host_Coherent},
	}
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		dtb.vbs[i] = rhi.create_vertex_buffer_empty(text_buf_desc, Text_Vertex, max_glyph_count*TEXT_VERTICES_PER_GLYPH, map_memory=true) or_return
		dtb.ibs[i] = rhi.create_index_buffer_empty(text_buf_desc, u32, max_glyph_count*TEXT_INDICES_PER_GLYPH, map_memory=true) or_return
	}
	return
}

destroy_dynamic_text_buffers :: proc(dtb: ^Dynamic_Text_Buffers) {
	for i in 0..<MAX_FRAMES_IN_FLIGHT {
		rhi.destroy_buffer(&dtb.ibs[i])
		rhi.destroy_buffer(&dtb.vbs[i])
	}
}

reset_dynamic_text_buffers :: proc(dtb: ^Dynamic_Text_Buffers) {
	dtb.vb_cursor[g_rhi.frame_in_flight] = 0
	dtb.ib_cursor[g_rhi.frame_in_flight] = 0
}

print_to_dynamic_text_buffers :: proc(dtb: ^Dynamic_Text_Buffers, text: string, position: Vec2) {
	f := g_rhi.frame_in_flight

	text_vb_memory := rhi.cast_mapped_buffer_memory(Text_Vertex, dtb.vbs[f].mapped_memory)
	text_ib_memory := rhi.cast_mapped_buffer_memory(u32,         dtb.ibs[f].mapped_memory)

	text_buf_reqs := calc_text_buffer_requirements(text)

	target_vb_memory := text_vb_memory[dtb.vb_cursor[f] : dtb.vb_cursor[f]+text_buf_reqs.vertex_count]
	target_ib_memory := text_ib_memory[dtb.ib_cursor[f] : dtb.ib_cursor[f]+text_buf_reqs.index_count]

	char_count, _ := fill_text_geometry(text, position, cast(uint)dtb.vb_cursor[f], target_vb_memory, target_ib_memory)
	dtb.vb_cursor[f] += char_count * TEXT_VERTICES_PER_GLYPH
	dtb.ib_cursor[f] += char_count * TEXT_INDICES_PER_GLYPH
}

make_dynamic_text_geo_from_entire_buffers :: proc(dtb: ^Dynamic_Text_Buffers) -> Dynamic_Text_Geometry {
	f := g_rhi.frame_in_flight
	dyn_text_geo := Dynamic_Text_Geometry{
		vb = &dtb.vbs[f],
		ib = &dtb.ibs[f],
		vb_offset = 0,
		ib_offset = 0,
		index_count = cast(uint)dtb.ib_cursor[f],
	}
	return dyn_text_geo
}

draw_dynamic_text_geometry :: proc(cb: ^rhi.RHI_Command_Buffer, geo: Dynamic_Text_Geometry, pos: Vec2, fb_dims: [2]u32) {
	// X+right, Y+up, Z+intoscreen ortho matrix
	ortho_matrix := linalg.matrix_ortho3d_f32(0, f32(fb_dims.x), 0, f32(fb_dims.y), -1, 1, false)
	model_matrix := linalg.matrix4_translate_f32(vec3(pos, 0))
	constants := Text_Push_Constants{
		mvp_matrix = ortho_matrix * model_matrix,
	}
	rhi.cmd_push_constants(cb, g_renderer.text_renderer_state.pipeline_layout, {.Vertex}, &constants)
	rhi.cmd_bind_vertex_buffer(cb, geo.vb^, cast(u32)geo.vb_offset)
	rhi.cmd_bind_index_buffer(cb, geo.ib^, geo.ib_offset)
	rhi.cmd_draw_indexed(cb, geo.index_count)
}

// Fonts ----------------------------------------------------------------------------------------------------------

// TODO: Integrate text rendering with HarfBuzz - https://github.com/harfbuzz/harfbuzz

DEFAULT_FONT :: "NotoSans-Regular"
DEFAULT_FONT_PATH :: "fonts/NotoSans/NotoSans-Regular.ttf"

Font_Glyph_Data :: struct {
	bearing: [2]uint,
	advance: uint,
	// Glyph dims without margin
	dims: [2]uint,

	// FreeType glyph index
	index: u32,

	// top-left corner (including margin)
	tex_coord_min: Vec2,
	// bottom-right corner (including margin)
	tex_coord_max: Vec2,
}

Font_Face_Data :: struct {
	rune_to_glyph_index: map[rune]int,
	glyph_cache: [dynamic]Font_Glyph_Data,
	atlas_texture: Combined_Texture_Sampler,
	glyph_margin: [2]uint,
	ascent: uint,
	descent: uint,
	linegap: uint,

	// Used for data that was not cached - mainly kerning
	ft_face: ft.Face,
}

@(private)
g_font_face_cache: map[string]Font_Face_Data

render_font_atlas :: proc(font: string, font_path: string, size: u32, dpi: u32) {
	assert(font not_in g_font_face_cache)

	Pixel_RGBA :: [4]byte
	Pixel_RGB  :: [3]byte

	ft_result: ft.Error

	// TODO: Atlas texture dimensions will need to be somehow automatically approximated based on char ranges, font size & DPI.
	font_texture_dims := [2]u32{1024, 1024}
	font_texture_pixel_count := font_texture_dims.x * font_texture_dims.y
	font_bitmap := make([]Pixel_RGBA, font_texture_pixel_count) // RGBA/BGRA texture
	defer delete(font_bitmap)

	font_cloned := strings.clone(font)
	font_face_data := map_insert(&g_font_face_cache, font_cloned, Font_Face_Data{})

	ft_face: ft.Face
	font_path_c := strings.clone_to_cstring(font_path, context.temp_allocator)
	ft_result = ft.new_face(g_ft_library, font_path_c, 0, &ft_face)
	assert(ft_result == .Ok)

	font_face_data.ft_face = ft_face

	size_f26dot6: ft.F26Dot6 = auto_cast size << 6
	ft_result = ft.set_char_size(ft_face, 0, size_f26dot6, dpi, dpi)
	assert(ft_result == .Ok)

	char_ranges := [?][2]rune{
		{32, 126}, // ASCII
		{160,255}, // Latin-1 Supplement
	}

	glyph_margin := [2]u32{1,1}
	font_face_data.glyph_margin = core.array_cast(uint, glyph_margin)
	font_face_data.ascent = uint(ft_face.ascender >> 6)
	font_face_data.descent = uint(-ft_face.descender >> 6)

	font_bitmap_cur: [2]u32

	// TODO: This is not the best way to pack rectangles
	max_height_in_line: u32
	for range in char_ranges do for c in range[0]..=range[1] {
		ft_result = ft.load_char(ft_face, cast(u32)c, {})
		assert(ft_result == .Ok)

		ft_result = ft.render_glyph(ft_face.glyph, .LCD)
		assert(ft_result == .Ok)

		split_glyph_width := ft_face.glyph.bitmap.width
		unsplit_glyph_width := split_glyph_width/3 // <-- RGB channels are split into multiple pixels in FreeType
		glyph_height := ft_face.glyph.bitmap.rows

		if font_bitmap_cur.x + unsplit_glyph_width + glyph_margin.x*2 > font_texture_dims.x {
			font_bitmap_cur.x = 0
			font_bitmap_cur.y += max_height_in_line + glyph_margin.y*2
		}

		// Cache the glyph metrics for rendering from the atlas later
		glyph_data: Font_Glyph_Data
		glyph_data.index = ft_face.glyph.glyph_index
		glyph_data.advance = uint(ft_face.glyph.metrics.hori_advance >> 6)
		glyph_data.dims.x = uint(ft_face.glyph.metrics.width >> 6)
		glyph_data.dims.y = uint(ft_face.glyph.metrics.height >> 6)
		glyph_data.bearing.x = uint(ft_face.glyph.metrics.hori_bearing_x >> 6)
		glyph_data.bearing.y = uint(ft_face.glyph.metrics.hori_bearing_y >> 6)
		glyph_dims_with_margin := core.array_cast(f32, glyph_data.dims) + core.array_cast(f32, glyph_margin*2)
		glyph_data.tex_coord_min = core.array_cast(f32, font_bitmap_cur) / core.array_cast(f32, font_texture_dims)
		glyph_data.tex_coord_max = glyph_data.tex_coord_min + (glyph_dims_with_margin / core.array_cast(f32, font_texture_dims))
		append(&font_face_data.glyph_cache, glyph_data)
		font_face_data.rune_to_glyph_index[c] = len(font_face_data.glyph_cache)-1

		if (ft_face.glyph.bitmap.buffer != nil) {
			abs_glyph_pitch := cast(u32)math.abs(ft_face.glyph.bitmap.pitch)
			glyph_buffer := mem.slice_ptr(ft_face.glyph.bitmap.buffer, int(glyph_height * abs_glyph_pitch))
			
			for gy in 0..<glyph_height {
				glyph_row_pixels := mem.slice_data_cast([]Pixel_RGB, glyph_buffer[gy*abs_glyph_pitch : gy*abs_glyph_pitch+split_glyph_width])
				for gx in 0..<unsplit_glyph_width {
					ax := font_bitmap_cur.x + glyph_margin.x + gx
					ay := font_bitmap_cur.y + glyph_margin.y + gy
					assert(ax >= 0 && ay >= 0 && ax < font_texture_dims.x && ay < font_texture_dims.y)
					atlas_idx := ax + ay * font_texture_dims.x

					font_bitmap[atlas_idx].rgb = glyph_row_pixels[gx]
					// TODO: Make it transparent?
					font_bitmap[atlas_idx].a = 0xFF
				}
			}
			font_bitmap_cur.x += unsplit_glyph_width + glyph_margin.x*2
			if glyph_height > max_height_in_line {
				max_height_in_line = glyph_height
			}
		}
	}

	font_face_data.atlas_texture, _ = create_combined_texture_sampler(mem.slice_data_cast([]byte, font_bitmap), font_texture_dims, .RGBA8_Srgb, .Nearest, .Clamp, g_renderer.text_renderer_state.descriptor_set_layout)
}

bind_font :: proc(cb: ^rhi.RHI_Command_Buffer, font: string = DEFAULT_FONT) {
	rhi.cmd_bind_descriptor_set(cb, g_renderer.text_renderer_state.pipeline_layout, g_font_face_cache[font].atlas_texture.descriptor_set)
}

// RHI ----------------------------------------------------------------------------------------------------------

TEXT_SHADER_VERT :: "text/basic.vert"
TEXT_SHADER_FRAG :: "text/basic.frag"

Text_Vertex :: struct {
	position: Vec2,
	tex_coord: Vec2,
	color: Vec4,
}

Text_Push_Constants :: struct {
	mvp_matrix: Matrix4,
}

Text_Renderer_State :: struct {
	main_pipeline: rhi.RHI_Pipeline,
	pipeline_layout: rhi.RHI_Pipeline_Layout,
	descriptor_set_layout: rhi.RHI_Descriptor_Set_Layout,
}

@(private)
text_init_rhi :: proc() -> rhi.Result {
	// Create descriptor set layout
	descriptor_set_layout_desc := rhi.Descriptor_Set_Layout_Description{
		bindings = {
			rhi.Descriptor_Set_Layout_Binding{
				binding = 0,
				count = 1,
				shader_stage = {.Fragment},
				type = .Combined_Image_Sampler,
			},
		},
	}
	g_renderer.text_renderer_state.descriptor_set_layout = rhi.create_descriptor_set_layout(descriptor_set_layout_desc) or_return
	
	// Create pipeline layout
	layout := rhi.Pipeline_Layout_Description{
		descriptor_set_layouts = {
			&g_renderer.text_renderer_state.descriptor_set_layout,
		},
		push_constants = {
			rhi.Push_Constant_Range{
				offset = 0,
				size = size_of(Text_Push_Constants),
				shader_stage = {.Vertex},
			},
		},
	}
	g_renderer.text_renderer_state.pipeline_layout = rhi.create_pipeline_layout(layout) or_return

	g_renderer.text_renderer_state.main_pipeline = create_text_pipeline(g_renderer.main_render_pass.render_pass) or_return

	return nil
}

@(private)
text_shutdown_rhi :: proc() {
	for name, &face in g_font_face_cache {
		destroy_combined_texture_sampler(&face.atlas_texture)
	}
	rhi.destroy_graphics_pipeline(&g_renderer.text_renderer_state.main_pipeline)
	rhi.destroy_pipeline_layout(&g_renderer.text_renderer_state.pipeline_layout)
	rhi.destroy_descriptor_set_layout(&g_renderer.text_renderer_state.descriptor_set_layout)
}

create_text_pipeline :: proc(render_pass: rhi.RHI_Render_Pass) -> (pipeline: rhi.RHI_Pipeline, result: rhi.Result) {
	// TODO: Creating shaders and VIDs each time a new pipeline is needed is kinda wasteful

	// Create shaders
	vsh := rhi.create_vertex_shader(core.path_make_engine_shader_relative(TEXT_SHADER_VERT)) or_return
	defer rhi.destroy_shader(&vsh)
	fsh := rhi.create_fragment_shader(core.path_make_engine_shader_relative(TEXT_SHADER_FRAG)) or_return
	defer rhi.destroy_shader(&fsh)

	// Setup vertex input for text
	vertex_input_types := []rhi.Vertex_Input_Type_Desc{
		rhi.Vertex_Input_Type_Desc{type = Text_Vertex, rate = .Vertex},
	}
	vid := rhi.create_vertex_input_description(vertex_input_types, context.temp_allocator)

	// Create text renderer graphics pipeline
	pipeline_desc := rhi.Pipeline_Description{
		shader_stages = {
			rhi.Pipeline_Shader_Stage{type = .Vertex,   shader = &vsh.shader},
			rhi.Pipeline_Shader_Stage{type = .Fragment, shader = &fsh.shader},
		},
		vertex_input = vid,
		input_assembly = {
			topology = .Triangle_List,
		},
	}
	pipeline = rhi.create_graphics_pipeline(pipeline_desc, render_pass, g_renderer.text_renderer_state.pipeline_layout) or_return

	return
}

// nil pipeline will use the main pipeline
bind_text_pipeline :: proc(cb: ^rhi.RHI_Command_Buffer, pipeline: rhi.RHI_Pipeline) {
	rhi.cmd_bind_graphics_pipeline(cb, pipeline if pipeline != nil else g_renderer.text_renderer_state.main_pipeline)
}

// Buffer Utils ----------------------------------------------------------------------------------------------------------

TEXT_VERTICES_PER_GLYPH :: 4
TEXT_INDICES_PER_GLYPH :: 6

Text_Buffer_Requirements :: struct {
	vertex_count: int,
	index_count: int,
}

// Length (in runes) of a UTF-8 text
calc_text_len :: proc(text: string) -> int {
	return strings.rune_count(text)
}

calc_text_buffer_requirements :: proc(text: string) -> Text_Buffer_Requirements {
	text_len := calc_text_len(text)
	// NOTE: This will also count spaces in, which are not going to be inserted as geometry, so some memory may be wasted.
	return Text_Buffer_Requirements{
		vertex_count = text_len * TEXT_VERTICES_PER_GLYPH,
		index_count  = text_len * TEXT_INDICES_PER_GLYPH,
	}
}

// Assumes the buffers have enough space for the text
// @see: calc_text_buffer_requirements
fill_text_geometry :: proc(text: string, position: Vec2, index_offset: uint, out_vertices: []Text_Vertex, out_indices: []u32, font: string = DEFAULT_FONT) -> (visible_character_count: int, ok: bool) {
	assert(out_vertices != nil)
	assert(out_indices != nil)

	font_face_data, font_ok := &g_font_face_cache[font]
	if !font_ok {
		log.errorf("Failed to find font %s.", font)
		return 0, false
	}

	assert(font_face_data.ft_face != nil)

	visible_character_count = 0

	glyph_margin := core.array_cast(int, font_face_data.glyph_margin)

	pen: [2]int
	prev_char: rune
	prev_ft_glyph_index: u32
	for c in text {
		glyph_data: ^Font_Glyph_Data
		if i, glyph_ok := font_face_data.rune_to_glyph_index[c]; glyph_ok {
			glyph_data = &font_face_data.glyph_cache[i]
		}
		if glyph_data == nil {
			log.errorf("Could not find glyph data for glyph %v(%U).", c, c)
			continue
		}

		kerning: ft.Vector
		if r := ft.get_kerning(font_face_data.ft_face, prev_ft_glyph_index, glyph_data.index, .DEFAULT, &kerning); r != .Ok {
			log.errorf("Failed to get kerning for characters '%v(%U)' -> '%v(%U)'.", prev_char, prev_char, c, c)
			kerning = {0,0}
		}

		pen.x += cast(int)kerning.x >> 6
		// log.debugf("KERNING FOR '%v'->'%v': %v", prev_char, c, kerning)
		// There definitely should not be any vertical kerning in left-to-right text.
		assert(kerning.y == 0)

		// Skip space and other invisible characters
		if glyph_data.dims.x > 0 && glyph_data.dims.y > 0 {
			i := visible_character_count

			bearing := core.array_cast(int, glyph_data.bearing)
			dims := core.array_cast(int, glyph_data.dims)
	
			glyph_vertices := out_vertices[i*4:(i+1)*4]
			glyph_indices := out_indices[i*6:(i+1)*6]
	
			// Vertex positions assume X+ right, Y+ down ; top-left corner = (0,0)
			v0, v1, v2, v3: [2]int
			v0 = {pen.x + bearing.x, pen.y - bearing.y} - glyph_margin
			v1 = v0 + {dims.x + glyph_margin.x*2, 0}
			v2 = v0 + dims + glyph_margin*2
			v3 = v0 + {0, dims.y + glyph_margin.y*2}
	
			t0, t1, t2, t3: Vec2
			t0 = glyph_data.tex_coord_min
			t1 = {glyph_data.tex_coord_max.x, glyph_data.tex_coord_min.y}
			t2 = glyph_data.tex_coord_max
			t3 = {glyph_data.tex_coord_min.x, glyph_data.tex_coord_max.y}
	
			glyph_vertices[0] = Text_Vertex{position = core.array_cast(f32, v0) + position, tex_coord = t0, color = Vec4{1,1,1,1}}
			glyph_vertices[1] = Text_Vertex{position = core.array_cast(f32, v1) + position, tex_coord = t1, color = Vec4{1,1,1,1}}
			glyph_vertices[2] = Text_Vertex{position = core.array_cast(f32, v2) + position, tex_coord = t2, color = Vec4{1,1,1,1}}
			glyph_vertices[3] = Text_Vertex{position = core.array_cast(f32, v3) + position, tex_coord = t3, color = Vec4{1,1,1,1}}
	
			glyph_indices[0] = cast(u32)index_offset + cast(u32)i*4
			glyph_indices[1] = cast(u32)index_offset + cast(u32)i*4+1
			glyph_indices[2] = cast(u32)index_offset + cast(u32)i*4+2
			glyph_indices[3] = cast(u32)index_offset + cast(u32)i*4
			glyph_indices[4] = cast(u32)index_offset + cast(u32)i*4+2
			glyph_indices[5] = cast(u32)index_offset + cast(u32)i*4+3

			visible_character_count += 1
		}

		pen.x += cast(int)glyph_data.advance

		prev_char = c
		prev_ft_glyph_index = glyph_data.index
	}

	return visible_character_count, true
}

// Internals ----------------------------------------------------------------------------------------------------------

g_ft_library: ft.Library

@(private)
text_init :: proc(dpi: u32) {
	ft_result := ft.init_free_type(&g_ft_library)
	if ft_result != .Ok {
		log.fatal("Failed to load the FreeType library.")
		return
	}

	if r := text_init_rhi(); r != nil {
		core.error_log(r.?)
		return
	}

	font_path := core.path_make_engine_resources_relative(DEFAULT_FONT_PATH)
	render_font_atlas(DEFAULT_FONT, font_path, 9, dpi)
}

@(private)
text_shutdown :: proc() {
	text_shutdown_rhi()

	for k, face_data in g_font_face_cache {
		ft.done_face(face_data.ft_face)

		delete(face_data.rune_to_glyph_index)
		delete(face_data.glyph_cache)
		delete(k)
	}

	delete(g_font_face_cache)
	ft.done_free_type(g_ft_library)
}
