package sm_csg

import "base:runtime"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:mem/virtual"
import "core:slice"

import "sm:core"
import "sm:rhi"
import r3d "sm:renderer/3d"

BRUSH_BLOCK_ALIGNMENT :: 16
BRUSH_ARENA_MINIMUM_BLOCK_SIZE :: virtual.DEFAULT_ARENA_GROWING_MINIMUM_BLOCK_SIZE
// Global precision of the CSG system to mitigate the floating-point error
EPSILON :: 1e-4

Vec4 :: core.Vec4
Vec3 :: core.Vec3
Vec2 :: core.Vec2
vec3 :: core.vec3
vec4 :: core.vec4

// Normally the planes are specified as:
// xyz - the plane's normal vector
// w - the plane's distance from the origin (0,0,0)
// but unnormalized coefficients should also work fine.
// Can be normalized using plane_normalize
Plane :: distinct Vec4

// Brush's surface polygon
// Specified as a plane + vertices that lie on that plane
Surface :: struct {
	index_count: u32,
	plane_index: u32, // the index of the plane on which the surface lies
	offset_to_next: u32, // offset to the next surface from the beginning of this surface struct
	// This could be omitted because it would just be equal to size_of(u32)+index_count*size_of(u32) which can be calculated

	// The Index array will be aligned to size_of(u32)
	// indices: [Ni]u32, - Ni=index_count - not known at compile time
}

// A representation of a convex CSG brush composed of N planes
// Unsafe to store in data structures - the pointers might become invalid
Brush :: struct {
	planes: []Plane,
	vertices: []Vec4,
	surfaces: ^Surface, // linked list
}

// Brush data allocated on the arena
_Brush_Block :: struct #align(BRUSH_BLOCK_ALIGNMENT) {
	plane_count: u32,
	vertex_count: u32,
	surfaces_size: u32,
	serial: u32, // for handle validity checking

	// The Plane array will be aligned to size_of(Plane)=16
	// planes: [?]Plane, - N=plane_count - not known at compile time
	
	// The Vertex array will be aligned to size_of(Vec4)=16
	// vertices: [?]Vec4, - N depends on planes - not known at compile time
	
	// The Surface array will be aligned to size_of(u32)=4
	// surfaces: [?]Surface(?), - their count and individual sizes are not known at compile time
}

_Free_Block :: struct {
	block: ^_Brush_Block,
	size: int,
}

// This handle can be safely stored in data structures unlike Brush
Brush_Handle :: struct {
	block: ^_Brush_Block,
	serial: u32,
}

CSG_State :: struct {
	brush_arena: virtual.Arena,
	brush_allocator: runtime.Allocator,
	free_blocks: [dynamic]_Free_Block,
}

// SYSTEM LIFETIME ------------------------------------------------------------------------------------------------

init :: proc(c: ^CSG_State) {
	assert(c != nil)

	if err := virtual.arena_init_growing(&c.brush_arena, BRUSH_ARENA_MINIMUM_BLOCK_SIZE); err != .None {
		panic("Could not allocate the CSG Brush arena.")
	}

	c.brush_allocator = virtual.arena_allocator(&c.brush_arena)
}

shutdown :: proc(c: ^CSG_State) {
	assert(c != nil)

	virtual.arena_destroy(&c.brush_arena)
	c.brush_allocator = {}
	delete(c.free_blocks)
}

// BASIC FUNCTIONALITY ---------------------------------------------------------------------------------------------

create_brush :: proc(c: ^CSG_State, planes: []Plane) -> (brush: Brush, handle: Brush_Handle) {
	plane_count := len(planes)
	assert(plane_count >= 4)

	
	vertices := make([dynamic]Vec4, context.temp_allocator)
	surfaces := make([dynamic]byte, context.temp_allocator) // stores dynamically sized Surface-s one after another without padding

	if !init_brush_vertices_from_planes(planes, &vertices) {
		return
	}
	if !init_brush_surfaces_from_planes_and_vertices(planes, vertices[:], &surfaces) {
		return
	}

	vertex_count := len(vertices)
	surfaces_size := len(surfaces)

	brush, handle = alloc_brush(c, cast(u32)plane_count, cast(u32)vertex_count, cast(u32)surfaces_size)
	mem.copy_non_overlapping(&brush.planes[0], &planes[0], plane_count*size_of(Plane))
	mem.copy_non_overlapping(&brush.vertices[0], &vertices[0], vertex_count*size_of(Vec4))
	mem.copy_non_overlapping(brush.surfaces, &surfaces[0], surfaces_size)
	return
}

destroy_brush :: free_brush

deref_brush_handle :: proc(c: ^CSG_State, handle: Brush_Handle) -> (brush: Brush, ok: bool) {
	ok = false
	if handle.block == nil {
		return
	}

	if handle.block.serial != handle.serial {
		return
	}

	brush = make_brush_from_block(handle.block)
	ok = true
	return
}

get_next_brush_surface :: proc(surface: ^Surface) -> ^Surface {
	if surface == nil {
		return nil
	}

	if surface.offset_to_next == 0 {
		return nil
	}

	next_ptr := cast(uintptr)surface + cast(uintptr)surface.offset_to_next
	next_surface := cast(^Surface)next_ptr
	return next_surface
}

init_brush_vertices_from_planes :: proc(planes: []Plane, out_vertices: ^[dynamic]Vec4) -> bool {
	assert(out_vertices != nil)

	plane_count := len(planes)

	// At least 3 planes are required to produce any vertices
	if plane_count < 3 {
		return false
	}

	// For each plane, try to intersect all the other planes with it
	for p1, i1 in planes {
		for i2 in 1..<plane_count {
			if i2 <= i1 {
				continue
			}
			
			p2 := planes[i2]
			for i3 in 2..<plane_count {
				if i3 <= i2 || i3 <= i1 {
					continue
				}

				p3 := planes[i3]
				if v, ok := find_plane_intersection_point(p1, p2, p3); ok {
					append(out_vertices, v)
				}
			}
		}
	}

	// Now clip any points that are in front of any plane - they don't belong to the brush
	for p in planes {
		for i := 0; i < len(out_vertices); {
			v := out_vertices[i]
			// Clip
			if linalg.vector_dot(p.xyz, v.xyz) - p.w > EPSILON {
				unordered_remove(out_vertices, i)
			} else {
				i += 1
			}
		}
	}

	return true
}

init_brush_surfaces_from_planes_and_vertices :: proc(planes: []Plane, vertices: []Vec4, out_surfaces: ^[dynamic]byte) -> bool {
	// Let's assume the minimum number of primitives
	if len(planes) < 4 {
		return false
	}
	if len(vertices) < 4 {
		return false
	}

	curr_surface_offset := 0
	get_curr_surface :: proc(surfaces: []byte, curr_offset: int) -> ^Surface {
		if curr_offset + size_of(Surface) <= len(surfaces) {
			return cast(^Surface)(cast(uintptr)&surfaces[0] + cast(uintptr)curr_offset)
		} else {
			return nil
		}
	}
	append_surface :: proc(surfaces: ^[dynamic]byte) {
		// Append a new surface with 3 vertices
		new_size := len(surfaces) + size_of(Surface) + 3*size_of(u32)
		if new_size > cap(surfaces) {
			reserve_dynamic_array(surfaces, new_size*2)
		}
		resize_dynamic_array(surfaces, new_size)
	}
	append_index :: proc(surfaces: ^[dynamic]byte) {
		new_size := len(surfaces) + size_of(u32)
		if new_size > cap(surfaces) {
			reserve_dynamic_array(surfaces, new_size*2)
		}
		resize_dynamic_array(surfaces, new_size)
	}

	// A surface must have at least 3 vertices
	// This array is here to put the first 2 intersecting ones into in case the 3rd is not found
	stored_vertices: [2]u32
	for p, ip in planes {
		v_num := 0
		for v, iv in vertices {
			// If the point does not intersect the current plane it does not belong to the surface polygon
			if math.abs(linalg.vector_dot(p.xyz, v.xyz) - p.w) > EPSILON {
				continue
			}

			if v_num < 2 {
				stored_vertices[v_num] = u32(iv)
			} else if v_num == 2 {
				curr_surface := get_curr_surface(out_surfaces[:], curr_surface_offset)
				offset_to_next := 0
				if curr_surface != nil {
					curr_surface.offset_to_next = size_of(Surface) + curr_surface.index_count*size_of(u32)
					offset_to_next = cast(int)curr_surface.offset_to_next
				}
				append_surface(out_surfaces)
				curr_surface_offset += offset_to_next
				curr_surface = get_curr_surface(out_surfaces[:], curr_surface_offset)
				curr_surface.index_count = 3
				curr_surface.plane_index = u32(ip)
				indices := get_surface_indices(curr_surface)
				indices[0] = stored_vertices[0]
				indices[1] = stored_vertices[1]
				indices[2] = u32(iv)
			} else {
				append_index(out_surfaces)
				curr_surface := get_curr_surface(out_surfaces[:], curr_surface_offset)
				assert(curr_surface != nil)
				curr_surface.index_count += 1
				indices := get_surface_indices(curr_surface)
				indices[curr_surface.index_count-1] = u32(iv)
			}
			v_num += 1
		}

		// The surface was not created if there are not at least 3 vertices
		if v_num < 3 {
			continue
		}

		curr_surface := get_curr_surface(out_surfaces[:], curr_surface_offset)

		// Vertex indices that lie on the current surface
		vert_indices_on_surface := get_surface_indices(curr_surface)
		
		// Vertices of the current surface
		// The brush vertex indices (vert_indices_on_surface) will not map to those!
		// Use the *index_remap_to_surf* map to get the surface vertex indices.
		surf_vertices := make([]Vec2, len(vert_indices_on_surface), context.temp_allocator)

		// Map of brush vertex index -> surface vertex index; -1 if no mapping exists
		index_remap_to_surf := make([]int, len(vertices), context.temp_allocator)
		slice.fill(index_remap_to_surf, -1)
		for ib, is in vert_indices_on_surface {
			index_remap_to_surf[ib] = is
		}

		// Inverse transform the surface's vertices so that the plane's normal ends up pointing up
		// Essentially, the vertices need to be transformed to the plane's 2D coordinate system
		p_dot_with_up := linalg.vector_dot(p.xyz, Vec3{0,0,1})
		// TODO: not necessary if trivial case
		// Inverted up vector because an inverted matrix is needed
		transform := linalg.matrix4_orientation_f32(p.xyz, Vec3{0,0,-1})
		for &idx, i in vert_indices_on_surface {
			v_3d := vertices[idx].xyz
			// Two special cases are trivial:
			if 1 - p_dot_with_up < EPSILON {
				surf_vertices[i] = v_3d.xy
			} else if 1 + p_dot_with_up < EPSILON {
				surf_vertices[i] = {-v_3d.x, v_3d.y}
			} else {
				v_2d := (transform * vec4(v_3d, 1.0)).xy
				surf_vertices[i] = v_2d
			}
		}

		// Sort the vertices clockwise
		{
			// First transform the vertices to an averaged center point
			center: Vec2
			for v in surf_vertices {
				center += v
			}
			center /= cast(f32)len(surf_vertices)
			centered_vertices := make([]Vec2, len(vertices), context.temp_allocator)
			for v, i in surf_vertices {
				centered_vertices[i] = v - center
			}

			Sort_Data :: struct {
				centered_vertices: []Vec2,
				remap: []int,
			}
			sort_data: Sort_Data
			sort_data.centered_vertices = centered_vertices
			sort_data.remap = index_remap_to_surf
			// Then sort by angle from the (1,0) vector
			context.user_ptr = &sort_data
			slice.sort_by(vert_indices_on_surface, proc(lhs, rhs: u32) -> bool {
				sort_data := cast(^Sort_Data)context.user_ptr
				remap := sort_data.remap
				vertices := sort_data.centered_vertices
				// Assume all the indices will map to the ones on the surface
				v_lhs := vertices[remap[lhs]]
				v_rhs := vertices[remap[rhs]]
				angle_lhs := math.atan2(v_lhs.y, v_lhs.x)
				angle_rhs := math.atan2(v_rhs.y, v_rhs.x)
				// gt because atan2 goes counter-clockwise
				return angle_lhs > angle_rhs
			})
		}

		log.debugf("Plane %i vertices:", ip)
		for idx in vert_indices_on_surface {
			v := vertices[idx]
			log.debugf("V(%i) = %v", idx, v)
		}
	}

	return true
}

// MATH UTILITIES -----------------------------------------------------------------------------------------------------------------------

plane_normalize :: proc(plane: Plane) -> Plane {
	length := linalg.length(plane.xyz)
	normalized := plane / length
	return normalized
}

find_plane_intersection_point :: proc(p1, p2, p3: Plane) -> (v: Vec4, ok: bool) {
	cross_1_2 := linalg.vector_cross3(p1.xyz, p2.xyz)
	denominator := linalg.vector_dot(cross_1_2, p3.xyz)

	if linalg.abs(denominator) < EPSILON {
		ok = false
		return
	}

	cross_2_3 := linalg.vector_cross3(p2.xyz, p3.xyz)
	cross_3_1 := linalg.vector_cross3(p3.xyz, p1.xyz)
	intersection := (p1.w * cross_2_3 + p2.w * cross_3_1 + p3.w * cross_1_2) / denominator

	v = core.vec4(intersection, 1.0)
	ok = true
	return
}

// BRUSH ALLOCATION & MEMORY MANAGEMENT --------------------------------------------------------------------------------------------

get_brush_alloc_size :: proc(plane_count, vertex_count, surfaces_size: u32) -> int {
	brush_block_base_size := size_of(_Brush_Block)
	planes_array_size := cast(int)plane_count * size_of(Plane)
	vertices_array_size := cast(int)vertex_count * size_of(Vec4)
	surfaces_size := cast(int)surfaces_size
	assert(mem.align_forward_int(surfaces_size, size_of(u32)) == surfaces_size)
	// Alignment: 16 -------------------- 16 ---------------- 16 ------------------ 4 -----------
	alloc_size := brush_block_base_size + planes_array_size + vertices_array_size + surfaces_size
	// Make sure the whole thing is aligned to 16
	alloc_size = mem.align_forward_int(alloc_size, BRUSH_BLOCK_ALIGNMENT)
	return alloc_size
}

get_brush_block_size :: proc(block: ^_Brush_Block) -> int {
	assert(block != nil)
	alloc_size := get_brush_alloc_size(block.plane_count, block.vertex_count, block.surfaces_size)
	return alloc_size
}

make_brush_from_block :: proc(block: ^_Brush_Block) -> (brush: Brush) {
	planes_ptr := cast([^]Plane)mem.ptr_offset(block, 1)
	vertices_ptr := cast([^]Vec4)mem.ptr_offset(planes_ptr, block.plane_count)
	surfaces_ptr := cast(^Surface)mem.ptr_offset(vertices_ptr, block.vertex_count)

	brush.planes = slice.from_ptr(planes_ptr, cast(int)block.plane_count)
	brush.vertices = slice.from_ptr(vertices_ptr, cast(int)block.vertex_count)
	brush.surfaces = surfaces_ptr

	return
}

get_surface_indices :: proc(surface: ^Surface) -> []u32 {
	assert(surface != nil)
	if surface.index_count == 0 {
		return nil
	}
	indices_ptr := cast([^]u32)mem.ptr_offset(surface, 1)
	indices_slice := slice.from_ptr(indices_ptr, cast(int)surface.index_count)
	return indices_slice
}

find_free_brush_block :: proc(c: ^CSG_State, size: int) -> (block: ^_Brush_Block) {
	assert(c != nil)
	size := size
	context.user_index = size
	// TODO: This will be pretty slow when there are lots of brushes
	if index, ok := slice.linear_search_proc(c.free_blocks[:], proc(fb: _Free_Block) -> bool {
		return fb.size == context.user_index
	}); ok {
		block = c.free_blocks[index].block
		unordered_remove(&c.free_blocks, index)
	}
	return
}

alloc_brush :: proc(c: ^CSG_State, plane_count, vertex_count, surfaces_size: u32) -> (brush: Brush, handle: Brush_Handle) {
	assert(c != nil)

	block_size := get_brush_alloc_size(plane_count, vertex_count, surfaces_size)

	block: ^_Brush_Block
	block = find_free_brush_block(c, block_size)

	if block == nil {
		data, err := mem.make_aligned([]byte, block_size, BRUSH_BLOCK_ALIGNMENT, c.brush_allocator)
		if err != .None {
			panic("Could not allocate a CSG Brush.")
		}
		block = cast(^_Brush_Block)&data[0]
	} else {
		serial := block.serial
		mem.zero(block, block_size)
		block.serial = serial
	}

	block.plane_count = plane_count
	block.vertex_count = vertex_count
	block.surfaces_size = surfaces_size

	brush = make_brush_from_block(block)

	handle.block = block
	handle.serial = block.serial

	return
}

free_brush :: proc(c: ^CSG_State, handle: Brush_Handle) {
	assert(c != nil)

	if handle.block == nil {
		return
	}

	// This will invalidate the handles
	handle.block.serial += 1

	free_block := _Free_Block {
		block = handle.block,
		size = get_brush_block_size(handle.block),
	}
	append(&c.free_blocks, free_block)
}
