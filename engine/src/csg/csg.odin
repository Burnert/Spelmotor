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

Matrix4 :: core.Matrix4
Vec4 :: core.Vec4
Vec3 :: core.Vec3
Vec2 :: core.Vec2
vec3 :: core.vec3
vec4 :: core.vec4

dot :: linalg.dot
cross :: linalg.cross

// Normally the planes are specified as:
// xyz - the plane's normal vector
// w - the plane's distance from the origin (0,0,0)
// but unnormalized coefficients should also work fine.
// Can be normalized using plane_normalize
Plane :: distinct Vec4

// Brush's surface polygon
// Specified as a plane + vertices that lie on that plane
Polygon :: struct {
	index_count: u32,
	plane_index: u32, // the index of the plane on which the polygon lies
	offset_to_next: u32, // offset to the next polygon from the beginning of this polygon struct
	// This could be omitted because it would just be equal to size_of(u32)+index_count*size_of(u32) which can be calculated

	// The Index array will be aligned to size_of(u32)
	// indices: [Ni]u32, - Ni=index_count - not known at compile time
}

// A representation of a convex CSG brush composed of N planes
// Unsafe to store in data structures - the pointers might become invalid
Brush :: struct {
	planes: []Plane,
	vertices: []Vec4,
	polygons: ^Polygon, // linked list
	polygon_count: u32,
}

// Brush data allocated on the arena
_Brush_Block :: struct #align(BRUSH_BLOCK_ALIGNMENT) {
	plane_count: u32,
	vertex_count: u32,
	polygon_count: u32,
	polygons_size: u32,
	serial: u32, // for handle validity checking

	// The Plane array will be aligned to size_of(Plane)=16
	// planes: [?]Plane, - N=plane_count - not known at compile time
	
	// The Vertex array will be aligned to size_of(Vec4)=16
	// vertices: [?]Vec4, - N depends on planes - not known at compile time
	
	// The Polygon array will be aligned to size_of(u32)=4
	// polygons: [?]Polygon(?), - their count and individual sizes are not known at compile time
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
	polygons := make([dynamic]byte, context.temp_allocator) // stores dynamically sized Polygon-s one after another without padding

	if !init_brush_vertices_from_planes(planes, &vertices) {
		return
	}
	polygon_count := init_brush_polygons_from_planes_and_vertices(planes, vertices[:], &polygons)
	if polygon_count == 0 {
		return
	}

	vertex_count := len(vertices)
	polygons_size := len(polygons)

	brush, handle = alloc_brush(c, cast(u32)plane_count, cast(u32)vertex_count, cast(u32)polygon_count, cast(u32)polygons_size)
	mem.copy_non_overlapping(&brush.planes[0], &planes[0], plane_count*size_of(Plane))
	mem.copy_non_overlapping(&brush.vertices[0], &vertices[0], vertex_count*size_of(Vec4))
	mem.copy_non_overlapping(brush.polygons, &polygons[0], polygons_size)
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

get_next_brush_polygon :: proc(polygon: ^Polygon) -> ^Polygon {
	if polygon == nil {
		return nil
	}

	if polygon.offset_to_next == 0 {
		return nil
	}

	next_ptr := cast(uintptr)polygon + cast(uintptr)polygon.offset_to_next
	next_polygon := cast(^Polygon)next_ptr
	return next_polygon
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

// Returns the count of polygons created
init_brush_polygons_from_planes_and_vertices :: proc(planes: []Plane, vertices: []Vec4, out_polygons: ^[dynamic]byte) -> int {
	// Let's assume the minimum number of primitives
	if len(planes) < 4 {
		return 0
	}
	if len(vertices) < 4 {
		return 0
	}

	curr_polygon_offset := 0
	get_curr_polygon :: proc(polygons: []byte, curr_offset: int) -> ^Polygon {
		if curr_offset + size_of(Polygon) <= len(polygons) {
			return cast(^Polygon)(cast(uintptr)&polygons[0] + cast(uintptr)curr_offset)
		} else {
			return nil
		}
	}
	append_polygon :: proc(polygons: ^[dynamic]byte) {
		// Append a new polygon with 3 vertices
		new_size := len(polygons) + size_of(Polygon) + 3*size_of(u32)
		if new_size > cap(polygons) {
			reserve_dynamic_array(polygons, new_size*2)
		}
		resize_dynamic_array(polygons, new_size)
	}
	append_index :: proc(polygons: ^[dynamic]byte) {
		new_size := len(polygons) + size_of(u32)
		if new_size > cap(polygons) {
			reserve_dynamic_array(polygons, new_size*2)
		}
		resize_dynamic_array(polygons, new_size)
	}

	// A polygon must have at least 3 vertices
	// This array is here to put the first 2 intersecting ones into in case the 3rd is not found
	stored_vertices: [2]u32
	p_num: int
	for p, ip in planes {
		v_num := 0
		for v, iv in vertices {
			if math.abs(linalg.vector_dot(p.xyz, v.xyz) - p.w) > EPSILON {
			// If the point does not intersect the current plane it does not belong to the polygon
				continue
			}

			if v_num < 2 {
				stored_vertices[v_num] = u32(iv)
			} else if v_num == 2 {
				curr_polygon := get_curr_polygon(out_polygons[:], curr_polygon_offset)
				offset_to_next := 0
				if curr_polygon != nil {
					curr_polygon.offset_to_next = size_of(Polygon) + curr_polygon.index_count*size_of(u32)
					offset_to_next = cast(int)curr_polygon.offset_to_next
				}
				append_polygon(out_polygons)
				p_num += 1
				curr_polygon_offset += offset_to_next
				curr_polygon = get_curr_polygon(out_polygons[:], curr_polygon_offset)
				curr_polygon.index_count = 3
				curr_polygon.plane_index = u32(ip)
				indices := get_polygon_indices(curr_polygon)
				indices[0] = stored_vertices[0]
				indices[1] = stored_vertices[1]
				indices[2] = u32(iv)
			} else {
				append_index(out_polygons)
				curr_polygon := get_curr_polygon(out_polygons[:], curr_polygon_offset)
				assert(curr_polygon != nil)
				curr_polygon.index_count += 1
				indices := get_polygon_indices(curr_polygon)
				indices[curr_polygon.index_count-1] = u32(iv)
			}
			v_num += 1
		}

		// The polygon was not created if there are not at least 3 vertices
		if v_num < 3 {
			continue
		}

		curr_polygon := get_curr_polygon(out_polygons[:], curr_polygon_offset)

		// Vertex indices that lie on the current polygon
		vert_indices_on_polygon := get_polygon_indices(curr_polygon)
		
		// Vertices of the current polygon
		// The brush vertex indices (vert_indices_on_polygon) will not map to those!
		// Use the *index_remap_to_poly* map to get the polygon vertex indices.
		poly_vertices := make([]Vec2, len(vert_indices_on_polygon), context.temp_allocator)

		// Map of brush vertex index -> polygon vertex index; -1 if no mapping exists
		index_remap_to_poly := make([]int, len(vertices), context.temp_allocator)
		slice.fill(index_remap_to_poly, -1)
		for ib, is in vert_indices_on_polygon {
			index_remap_to_poly[ib] = is
		}

		plane_normal := linalg.normalize(p.xyz)
		UP :: Vec3{0,0,1}
		// Inverse transform the polygon's vertices so that the plane's normal ends up pointing up.
		// Essentially, the vertices need to be transformed to the plane's 2D coordinate system.
		p_dot_up := linalg.vector_dot(plane_normal, UP)
		// TODO: not necessary if trivial case
		transform_to_2d: Matrix4
		has_calculated_transform := false
		for &idx, i in vert_indices_on_polygon {
			v_3d := vertices[idx].xyz
			// Two special cases are trivial, but necessary because equal or opposite vectors don't have a cross product.
			if 1 - p_dot_up < EPSILON {
				poly_vertices[i] = v_3d.xy
			} else if 1 + p_dot_up < EPSILON {
				poly_vertices[i] = {-v_3d.x, v_3d.y}
			} else {
				if !has_calculated_transform {
					transform_to_2d = linalg.matrix4_inverse_f32(linalg.matrix4_orientation_f32(plane_normal, UP))
				}
				v_2d := (transform_to_2d * vec4(v_3d, 1.0)).xy
				poly_vertices[i] = v_2d
			}
		}

		// Sort the vertices clockwise
		{
			// First transform the vertices to an averaged center point
			center: Vec2
			for v in poly_vertices {
				center += v
			}
			center /= cast(f32)len(poly_vertices)
			centered_vertices := make([]Vec2, len(vertices), context.temp_allocator)
			for v, i in poly_vertices {
				centered_vertices[i] = v - center
			}

			Sort_Data :: struct {
				centered_vertices: []Vec2,
				remap: []int,
			}
			sort_data: Sort_Data
			sort_data.centered_vertices = centered_vertices
			sort_data.remap = index_remap_to_poly
			// Then sort by angle from the (1,0) vector
			context.user_ptr = &sort_data
			slice.sort_by(vert_indices_on_polygon, proc(lhs, rhs: u32) -> bool {
				sort_data := cast(^Sort_Data)context.user_ptr
				remap := sort_data.remap
				vertices := sort_data.centered_vertices
				// Assume all the indices will map to the ones on the polygon
				v_lhs := vertices[remap[lhs]]
				v_rhs := vertices[remap[rhs]]
				angle_lhs := math.atan2(v_lhs.y, v_lhs.x)
				angle_rhs := math.atan2(v_rhs.y, v_rhs.x)
				// gt because atan2 goes counter-clockwise
				return angle_lhs > angle_rhs
			})
		}

		log.debugf("Plane %i vertices:", ip)
		for idx in vert_indices_on_polygon {
			v := vertices[idx]
			log.debugf("V(%i) = %v", idx, v)
		}
	}

	return p_num
}

// POLYGON CLIPPING -----------------------------------------------------------------------------------------------------

// Returns vertices that are on the back of the specified plane
clip_poly_by_plane_in_place :: proc(poly_vertices: ^[dynamic]Vec3, plane: Plane) -> (valid_after_clip: bool) {
	// There's no reason to clip an invalid polygon
	if (len(poly_vertices) < 3) {
		clear(poly_vertices)
		return false
	}

	verts_temp := make([]Vec3, len(poly_vertices), context.temp_allocator)
	copy_slice(verts_temp, poly_vertices[:])
	clear(poly_vertices)

	// Assemble a new polygon by clipping the lines formed by two adjacent points
	for i in 0..<len(verts_temp) {
		p0, p1: Vec3
		p0 = verts_temp[i]
		p1 = verts_temp[(i+1)%len(verts_temp)]
		if point, ok := find_line_plane_intersection(p0, p1, plane); ok {
			det0 := dot(plane.xyz, p0.xyz) - plane.w
			det1 := dot(plane.xyz, p1.xyz) - plane.w
			if det0 > EPSILON && det1 > EPSILON {
				continue
			} else if det0 < EPSILON && det1 > EPSILON {
				append(poly_vertices, p0)
				if det0 < -EPSILON {
					append(poly_vertices, point)
				}
			} else if det0 > EPSILON && det1 < EPSILON {
				if det1 < -EPSILON {
					append(poly_vertices, point)
				}
			} else {
				append(poly_vertices, p0)
			}
		} else { // This means the line is parallel to the plane
			det := dot(plane.xyz, p0.xyz) - plane.w
			if det < EPSILON {
				append(poly_vertices, p0)
			}
		}
	}

	if (len(poly_vertices) < 3) {
		// If the polygon is not at least a triangle, all vertices must have been clipped
		clear(poly_vertices)
		return false
	}
	return true
}

// Returns vertices that are on the back of the specified plane
clip_poly_by_plane :: proc(poly_vertices: []Vec3, plane: Plane, out_poly_vertices: ^[dynamic]Vec3) -> (valid_after_clip: bool) {
	// There's no reason to clip an invalid polygon
	if (len(poly_vertices) < 3) {
		return false
	}

	// Assemble a new polygon by clipping the lines formed by two adjacent points
	for i in 0..<len(poly_vertices) {
		p0, p1: Vec3
		p0 = poly_vertices[i]
		p1 = poly_vertices[(i+1)%len(poly_vertices)]
		if point, ok := find_line_plane_intersection(p0, p1, plane); ok {
			det0 := dot(plane.xyz, p0.xyz) - plane.w
			det1 := dot(plane.xyz, p1.xyz) - plane.w
			if det0 > EPSILON && det1 > EPSILON {
				continue
			} else if det0 < EPSILON && det1 > EPSILON {
				append(out_poly_vertices, p0)
				if det0 < -EPSILON {
					append(out_poly_vertices, point)
				}
			} else if det0 > EPSILON && det1 < EPSILON {
				if det1 < -EPSILON {
					append(out_poly_vertices, point)
				}
			} else {
				append(out_poly_vertices, p0)
			}
		} else { // This means the line is parallel to the plane
			det := dot(plane.xyz, p0.xyz) - plane.w
			if det < EPSILON {
				append(out_poly_vertices, p0)
			}
		}
	}

	if (len(out_poly_vertices) < 3) {
		// If the polygon is not at least a triangle, all vertices must have been clipped
		clear(out_poly_vertices)
		return false
	}
	return true
}

// MATH UTILITIES -----------------------------------------------------------------------------------------------------------------------

plane_normalize :: proc(plane: Plane) -> Plane {
	length := linalg.length(plane.xyz)
	normalized := plane / length
	return normalized
}

plane_invert :: proc(plane: Plane) -> Plane {
	return -plane.xyzw
}

find_plane_intersection_point :: proc(p1, p2, p3: Plane) -> (v: Vec4, ok: bool) {
	cross_1_2 := cross(p1.xyz, p2.xyz)
	denominator := dot(cross_1_2, p3.xyz)

	if abs(denominator) < EPSILON {
		ok = false
		return
	}

	cross_2_3 := cross(p2.xyz, p3.xyz)
	cross_3_1 := cross(p3.xyz, p1.xyz)
	intersection := (p1.w * cross_2_3 + p2.w * cross_3_1 + p3.w * cross_1_2) / denominator

	v = vec4(intersection, 1.0)
	ok = true
	return
}

find_line_plane_intersection :: proc(p0, p1: Vec3, plane: Plane) -> (v: Vec3, ok: bool) {
	u := p1 - p0
	plane_dot_u := dot(plane.xyz, u)

	if abs(plane_dot_u) < EPSILON {
		ok = false
		return
	}

	p := plane.xyz * plane.w
	w := p0 - p
	fac := -dot(plane.xyz, w) / plane_dot_u
	u = u * fac

	v = p0 + u
	ok = true
	return
}

plane_transform :: proc(plane: Plane, transform: Matrix4) -> Plane {
	normalized := plane_normalize(plane)
	transformed := plane_transform_normalized(normalized, transform)
	return transformed
}

plane_transform_normalized :: proc(plane: Plane, transform: Matrix4) -> Plane {
	n := plane.xyz
	d := plane.w
	v := n * d
	rotated_n := (transform * vec4(n, 0)).xyz
	transformed_v := (transform * vec4(v, 1)).xyz
	v_dot_n := dot(transformed_v, rotated_n)
	transformed_plane := cast(Plane)vec4(rotated_n, v_dot_n)
	transformed_plane = plane_normalize(transformed_plane)
	return transformed_plane
}

// Are normalized planes coplanar (within epsilon fp error)
plane_is_coplanar_normalized_epsilon :: proc(plane0, plane1: Plane) -> bool {
	plane_dot := dot(plane0.xyz, plane1.xyz)
	det := abs(plane0.w - plane1.w)
	return (1 - plane_dot) < EPSILON && det < EPSILON
}

// Are normalized planes coplanar or inversely coplanar (within epsilon fp error)
plane_is_coplanar_abs_normalized_epsilon :: proc(plane0, plane1: Plane) -> bool {
	plane_dot := dot(plane0.xyz, plane1.xyz)
	det := abs(plane0.w - plane1.w)
	return (1 - abs(plane_dot)) < EPSILON && det < EPSILON
}

// BRUSH ALLOCATION & MEMORY MANAGEMENT --------------------------------------------------------------------------------------------

get_brush_alloc_size :: proc(plane_count, vertex_count, polygons_size: u32) -> int {
	brush_block_base_size := size_of(_Brush_Block)
	planes_array_size := cast(int)plane_count * size_of(Plane)
	vertices_array_size := cast(int)vertex_count * size_of(Vec4)
	polygons_size := cast(int)polygons_size
	assert(mem.align_forward_int(polygons_size, size_of(u32)) == polygons_size)
	// Alignment: 16 -------------------- 16 ---------------- 16 ------------------ 4 -----------
	alloc_size := brush_block_base_size + planes_array_size + vertices_array_size + polygons_size
	// Make sure the whole thing is aligned to 16
	alloc_size = mem.align_forward_int(alloc_size, BRUSH_BLOCK_ALIGNMENT)
	return alloc_size
}

get_brush_block_size :: proc(block: ^_Brush_Block) -> int {
	assert(block != nil)
	alloc_size := get_brush_alloc_size(block.plane_count, block.vertex_count, block.polygons_size)
	return alloc_size
}

make_brush_from_block :: proc(block: ^_Brush_Block) -> (brush: Brush) {
	planes_ptr := cast([^]Plane)mem.ptr_offset(block, 1)
	vertices_ptr := cast([^]Vec4)mem.ptr_offset(planes_ptr, block.plane_count)
	polygons_ptr := cast(^Polygon)mem.ptr_offset(vertices_ptr, block.vertex_count)

	brush.planes = slice.from_ptr(planes_ptr, cast(int)block.plane_count)
	brush.vertices = slice.from_ptr(vertices_ptr, cast(int)block.vertex_count)
	brush.polygons = polygons_ptr
	brush.polygon_count = block.polygon_count

	return
}

get_polygon_indices :: proc(polygon: ^Polygon) -> []u32 {
	assert(polygon != nil)
	if polygon.index_count == 0 {
		return nil
	}
	indices_ptr := cast([^]u32)mem.ptr_offset(polygon, 1)
	indices_slice := slice.from_ptr(indices_ptr, cast(int)polygon.index_count)
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

alloc_brush :: proc(c: ^CSG_State, plane_count, vertex_count, polygon_count, polygons_size: u32) -> (brush: Brush, handle: Brush_Handle) {
	assert(c != nil)

	block_size := get_brush_alloc_size(plane_count, vertex_count, polygons_size)

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
	block.polygons_size = polygons_size
	block.polygon_count = polygon_count

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
