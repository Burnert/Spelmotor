package spelmotor_sandbox

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/fixed"
import "core:mem"
import "core:image/png"
import "core:strings"
import "core:time"
import "vendor:cgltf"
import "smvendor:freetype"

import "sm:core"
import "sm:platform"
import "sm:rhi"
import r2im "sm:renderer/2d_immediate"
import r3d "sm:renderer/3d"

DEFAULT_FONT :: "engine/res/fonts/NotoSans/NotoSans-Regular.ttf"

TEXT_SHADER_VERT :: "text/basic_vert.spv"
TEXT_SHADER_FRAG :: "text/basic_frag.spv"

text_init :: proc(dpi: u32) {
	if r := text_init_rhi(); r != nil {
		rhi.handle_error(&r.(rhi.RHI_Error))
	}

	render_font_atlas(dpi, DEFAULT_FONT)
}

text_shutdown :: proc() {
	for k, v in g_font_face_cache {
		delete(v.rune_to_glyph_index)
		delete(v.glyph_cache)
	}
	delete(g_font_face_cache)
	freetype.done_free_type(g_ft_library)

	text_shutdown_rhi()
}

render_font_atlas :: proc(dpi: u32, font: string) {
	Pixel_RGBA :: [4]byte
	Pixel_RGB  :: [3]byte

	// TODO: Atlas texture dimensions will need to be somehow automatically approximated based on char ranges, font size & DPI.
	font_texture_dims := [2]u32{256, 256}
	font_texture_pixel_count := font_texture_dims.x * font_texture_dims.y
	font_bitmap := make([]Pixel_RGBA, font_texture_pixel_count) // RGBA/BGRA texture
	defer delete(font_bitmap)

	font_path_c := strings.clone_to_cstring(font, context.temp_allocator)
	g_font_face_cache[font] = {}
	font_face_data := &g_font_face_cache[font]

	ft_result := freetype.init_free_type(&g_ft_library)
	if ft_result != .Ok {
		log.error("Failed to load the FreeType library.")
		for &b in font_bitmap do b = 0xFF
	}
	if ft_result == .Ok {
		ft_face: freetype.Face
		ft_result = freetype.new_face(g_ft_library, font_path_c, 0, &ft_face)
		assert(ft_result == .Ok)

		font_height := 8
		ft_result = freetype.set_char_size(ft_face, 0, freetype.F26Dot6(font_height << 6), dpi, dpi)
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
			ft_result = freetype.load_char(ft_face, cast(u32)c, {})
			assert(ft_result == .Ok)

			ft_result = freetype.render_glyph(ft_face.glyph, .LCD)
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
	} else do return

	font_face_data.atlas_texture, _ = r3d.create_texture_2d(mem.slice_data_cast([]byte, font_bitmap), font_texture_dims, .RGBA8_SRGB, .NEAREST, g_text_rhi.pipeline_layout)
}

text_init_rhi :: proc() -> rhi.RHI_Result {
	// Create shaders
	vsh := rhi.create_vertex_shader(core.path_make_engine_shader_relative(TEXT_SHADER_VERT)) or_return
	defer rhi.destroy_shader(&vsh)
	fsh := rhi.create_fragment_shader(core.path_make_engine_shader_relative(TEXT_SHADER_FRAG)) or_return
	defer rhi.destroy_shader(&fsh)

	// Create pipeline layout
	layout := rhi.Pipeline_Layout_Description{
		bindings = {
			rhi.Descriptor_Set_Layout_Binding{
				binding = 0,
				count = 1,
				shader_stage = {.FRAGMENT},
				type = .COMBINED_IMAGE_SAMPLER,
			},
		},
		push_constants = {
			rhi.Push_Constant_Range{
				offset = 0,
				size = size_of(Text_Push_Constants),
				shader_stage = {.VERTEX},
			},
		},
	}
	g_text_rhi.pipeline_layout = rhi.create_pipeline_layout(layout) or_return

	// Setup vertex input for text
	vertex_input_types := []rhi.Vertex_Input_Type_Desc{
		rhi.Vertex_Input_Type_Desc{type = Text_Vertex, rate = .VERTEX},
	}
	vid := rhi.create_vertex_input_description(vertex_input_types, context.temp_allocator)

	// Create text renderer graphics pipeline
	pipeline_desc := rhi.Pipeline_Description{
		shader_stages = {
			rhi.Pipeline_Shader_Stage{type = .VERTEX,   shader = &vsh.shader},
			rhi.Pipeline_Shader_Stage{type = .FRAGMENT, shader = &fsh.shader},
		},
		vertex_input = vid,
		input_assembly = {
			topology = .TRIANGLE_LIST,
		},
		depth_stencil = {
			depth_compare_op = .ALWAYS,
		},
	}
	rp := r3d.get_main_render_pass()
	g_text_rhi.pipeline = rhi.create_graphics_pipeline(pipeline_desc, rp.render_pass, g_text_rhi.pipeline_layout) or_return

	return nil
}

text_shutdown_rhi :: proc() {
	rhi.destroy_graphics_pipeline(&g_text_rhi.pipeline)
	rhi.destroy_pipeline_layout(&g_text_rhi.pipeline_layout)
}

create_text_geometry :: proc(text: string, font: string = DEFAULT_FONT) -> (geo: Text_Geometry) {
	font_face_data, ok := &g_font_face_cache[font]
	if !ok {
		return {}
	}

	vertices := make([]Text_Vertex, len(text) * 4)
	defer delete(vertices)
	indices := make([]u32, len(text) * 6)
	defer delete(indices)

	visible_character_count := 0

	glyph_margin := core.array_cast(int, font_face_data.glyph_margin)

	pen: [2]int
	for c in text {
		glyph_data: ^Font_Glyph_Data
		if glyph_index, ok := font_face_data.rune_to_glyph_index[c]; ok {
			glyph_data = &font_face_data.glyph_cache[glyph_index]
		}
		if glyph_data == nil {
			log.errorf("Could not find glyph data for glyph %v(%U).", c, c)
			continue
		}

		// Skip space and other invisible characters
		if glyph_data.dims.x > 0 && glyph_data.dims.y > 0 {
			i := visible_character_count

			bearing := core.array_cast(int, glyph_data.bearing)
			dims := core.array_cast(int, glyph_data.dims)
	
			glyph_vertices := vertices[i*4:(i+1)*4]
			glyph_indices := indices[i*6:(i+1)*6]
	
			// Vertex positions assume X+ right, Y+ down ; top-left corner = (0,0)
			v0, v1, v2, v3: [2]int
			v0 = {pen.x + bearing.x, pen.y - bearing.y}
			v1 = v0 + {dims.x + glyph_margin.x*2, 0}
			v2 = v0 + dims + glyph_margin*2
			v3 = v0 + {0, dims.y + glyph_margin.y*2}
	
			t0, t1, t2, t3: Vec2
			t0 = glyph_data.tex_coord_min
			t1 = {glyph_data.tex_coord_max.x, glyph_data.tex_coord_min.y}
			t2 = glyph_data.tex_coord_max
			t3 = {glyph_data.tex_coord_min.x, glyph_data.tex_coord_max.y}
	
			glyph_vertices[0] = Text_Vertex{position = core.array_cast(f32, v0), tex_coord = t0, color = Vec4{1,1,1,1}}
			glyph_vertices[1] = Text_Vertex{position = core.array_cast(f32, v1), tex_coord = t1, color = Vec4{1,1,1,1}}
			glyph_vertices[2] = Text_Vertex{position = core.array_cast(f32, v2), tex_coord = t2, color = Vec4{1,1,1,1}}
			glyph_vertices[3] = Text_Vertex{position = core.array_cast(f32, v3), tex_coord = t3, color = Vec4{1,1,1,1}}
	
			glyph_indices[0] = cast(u32)i*4
			glyph_indices[1] = cast(u32)i*4+1
			glyph_indices[2] = cast(u32)i*4+2
			glyph_indices[3] = cast(u32)i*4
			glyph_indices[4] = cast(u32)i*4+2
			glyph_indices[5] = cast(u32)i*4+3

			visible_character_count += 1
		}

		pen.x += cast(int)glyph_data.advance
	}

	rhi_result: rhi.RHI_Result
	buffer_desc := rhi.Buffer_Desc{
		memory_flags = {.DEVICE_LOCAL},
	}
	geo.text_vb, rhi_result = rhi.create_vertex_buffer(buffer_desc, vertices[:visible_character_count*4])
	geo.text_ib, rhi_result = rhi.create_index_buffer(indices[:visible_character_count*6])

	return
}

destroy_text_geometry :: proc(geo: ^Text_Geometry) {
	rhi.destroy_buffer(&geo.text_vb)
	rhi.destroy_buffer(&geo.text_ib)
}

bind_text_pipeline :: proc(cb: ^rhi.RHI_CommandBuffer) {
	rhi.cmd_bind_graphics_pipeline(cb, g_text_rhi.pipeline)
	rhi.cmd_bind_descriptor_set(cb, g_text_rhi.pipeline_layout, g_font_face_cache[DEFAULT_FONT].atlas_texture.descriptor_set)
}

draw_text_geometry :: proc(cb: ^rhi.RHI_CommandBuffer, geo: Text_Geometry, fb_dims: [2]u32) {
	right := f32(fb_dims.x)/2
	left := -right
	top := f32(fb_dims.y)/2
	bottom := -top
	// X-right, Y-down, Z-intoscreen ortho matrix
	ortho_matrix := linalg.matrix_ortho3d_f32(left, right, bottom, top, 0, 1, false)
	constants := Text_Push_Constants{
		vp_matrix = ortho_matrix,
	}
	rhi.cmd_push_constants(cb, g_text_rhi.pipeline_layout, {.VERTEX}, &constants)
	rhi.cmd_bind_vertex_buffer(cb, geo.text_vb)
	rhi.cmd_bind_index_buffer(cb, geo.text_ib)
	rhi.cmd_draw_indexed(cb, geo.text_ib.index_count)
}

g_ft_library: freetype.Library

Font_Glyph_Data :: struct {
	bearing: [2]uint,
	advance: uint,
	// Glyph dims without margin
	dims: [2]uint,

	// top-left corner (including margin)
	tex_coord_min: Vec2,
	// bottom-right corner (including margin)
	tex_coord_max: Vec2,
}

Font_Face_Data :: struct {
	rune_to_glyph_index: map[rune]int,
	glyph_cache: [dynamic]Font_Glyph_Data,
	atlas_texture: r3d.RTexture_2D,
	glyph_margin: [2]uint,
	ascent: uint,
	descent: uint,
	linegap: uint,
}

g_font_face_cache: map[string]Font_Face_Data

Text_Vertex :: struct {
	position: Vec2,
	tex_coord: Vec2,
	color: Vec4,
}

Text_Geometry :: struct {
	text_vb: rhi.Vertex_Buffer,
	text_ib: rhi.Index_Buffer,
}

Text_Push_Constants :: struct {
	vp_matrix: Matrix4,
}

Text_RHI :: struct {
	pipeline: rhi.RHI_Pipeline,
	pipeline_layout: rhi.RHI_PipelineLayout,
}
g_text_rhi: Text_RHI