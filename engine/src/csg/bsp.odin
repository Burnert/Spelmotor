package sm_csg

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:slice"
import "core:strings"

BSP_Node :: struct {
	front, back: BSP_Node_Ref,
	plane: Plane,
}

BSP_Leaf :: struct {
	solid: bool,
	polygons: [dynamic]BSP_Polygon,
}

BSP_Node_Ref :: union #no_nil {
	^BSP_Node,
	^BSP_Leaf,
}

BSP_Polygon :: struct {
	// TODO: Change to indices and add the unique vertices to the owning BSP tree
	vertices: [dynamic]Vec4,
}

bsp_clone_polygons :: proc(polygons: [dynamic]BSP_Polygon, allocator := context.allocator) -> [dynamic]BSP_Polygon {
	cloned_polys := slice.clone_to_dynamic(polygons[:], allocator)
	for p, i in polygons {
		cloned_polys[i].vertices = slice.clone_to_dynamic(p.vertices[:], allocator)
	}
	return cloned_polys
}

bsp_destroy_polygons :: proc(polygons: [dynamic]BSP_Polygon) {
	for p, i in polygons {
		delete(p.vertices)
	}
	delete(polygons)
}

bsp_create_leaf_node :: proc(allocator := context.allocator) -> (leaf: ^BSP_Leaf) {
	err: runtime.Allocator_Error
	leaf, err = new(BSP_Leaf, allocator)
	if err != .None {
		return
	}

	return
}

bsp_destroy_leaf_node :: proc(leaf: ^BSP_Leaf, allocator := context.allocator) {
	bsp_destroy_polygons(leaf.polygons)
	free(leaf, allocator)
}

bsp_create_from_brush :: proc(brush: Brush, allocator := context.allocator) -> (root: ^BSP_Node, ok: bool) {
	create_node :: proc(plane: Plane, vertices: []Vec4, polygon: ^Polygon, allocator: runtime.Allocator) -> (node: ^BSP_Node, ok: bool) {
		err: runtime.Allocator_Error
		node, err = new(BSP_Node, allocator)
		if err != .None {
			ok = false
			return
		}

		node.plane = plane

		leaf := bsp_create_leaf_node(allocator)
		leaf.solid = false
		// Each brush plane corresponds to just one polygon
		// Multiple polygons per empty leaf are only possible in merged BSP trees
		leaf.polygons = make_dynamic_array_len([dynamic]BSP_Polygon, 1, allocator)
		indices := get_polygon_indices(polygon)
		bsp_poly := &leaf.polygons[0]
		bsp_poly.vertices = make_dynamic_array_len_cap([dynamic]Vec4, 0, len(indices))
		for idx in indices {
			append(&bsp_poly.vertices, vertices[idx])
		}
		node.front = leaf

		ok = true
		return
	}

	node: ^BSP_Node
	// In convex brushes planes & polygons are essentially equivalent
	for poly := brush.polygons; poly != nil; poly = get_next_brush_polygon(poly) {
		plane := brush.planes[poly.plane_index]
		prev_node := node
		node, ok = create_node(plane, brush.vertices, poly, allocator)
		if !ok {
			return
		}

		if prev_node != nil {
			prev_node.back = node
		} else {
			root = node
		}
	}

	// The last node of a brush is always solid and has no polygons
	leaf := bsp_create_leaf_node(allocator)
	leaf.solid = true
	node.back = leaf

	ok = true
	return
}

bsp_destroy :: proc(root: ^BSP_Node, allocator := context.allocator) {
	assert(root != nil)

	switch v in root.front {
	case ^BSP_Node:
		bsp_destroy(v, allocator)
	case ^BSP_Leaf:
		bsp_destroy_leaf_node(v, allocator)
	}

	switch v in root.back {
	case ^BSP_Node:
		bsp_destroy(v, allocator)
	case ^BSP_Leaf:
		bsp_destroy_leaf_node(v, allocator)
	}

	free(root, allocator)
}

bsp_clone :: proc(root: ^BSP_Node, allocator := context.allocator) -> (cloned: ^BSP_Node) {
	assert(root != nil)

	cloned = new_clone(root^, allocator)

	switch &v in cloned.front {
	case ^BSP_Node:
		v = bsp_clone(v, allocator)
	case ^BSP_Leaf:
		v = new_clone(v^, allocator)
		v.polygons = bsp_clone_polygons(v.polygons, allocator)
	}

	switch &v in cloned.back {
	case ^BSP_Node:
		cloned.back = bsp_clone(v, allocator)
	case ^BSP_Leaf:
		v = new_clone(v^, allocator)
		v.polygons = bsp_clone_polygons(v.polygons, allocator)
	}

	return
}

// Inverts the tree leaves' solid values in-place
bsp_invert :: proc(root: ^BSP_Node) {
	assert(root != nil)

	switch &v in root.front {
	case ^BSP_Node:
		bsp_invert(v)
	case ^BSP_Leaf:
		v.solid = !v.solid
	}

	switch &v in root.back {
	case ^BSP_Node:
		bsp_invert(v)
	case ^BSP_Leaf:
		v.solid = !v.solid
	}
}

BSP_Merge_Mode :: enum {
	// A | B
	UNION,
	// A * B
	INTERSECT,
	// A - B   (A * ~B)
	DIFFERENCE,
}

// Modifies the A tree, clones and doesn't modify the B tree
// TODO: Bounding box checks to optimize the tree
// TODO: Clip the new polygons that were merged in
bsp_merge :: proc(a, b: ^BSP_Node, mode: BSP_Merge_Mode, allocator := context.allocator) {
	switch mode {
	// A | B  ---  replaces the non-solid leaves in A with cloned B
	case .UNION:
		switch v in a.front {
		case ^BSP_Node:
			bsp_merge(v, b, mode, allocator)
		case ^BSP_Leaf:
			if !v.solid {
				a.front = bsp_clone(b, allocator)
			}
		}

		switch v in a.back {
		case ^BSP_Node:
			bsp_merge(v, b, mode, allocator)
		case ^BSP_Leaf:
			if !v.solid {
				a.back = bsp_clone(b, allocator)
			}
		}

	// A * B  ---  replaces the solid leaves in A with cloned B
	case .INTERSECT:
		switch v in a.front {
		case ^BSP_Node:
			bsp_merge(v, b, mode, allocator)
		case ^BSP_Leaf:
			if v.solid {
				a.front = bsp_clone(b, allocator)
			}
		}

		switch v in a.back {
		case ^BSP_Node:
			bsp_merge(v, b, mode, allocator)
		case ^BSP_Leaf:
			if v.solid {
				a.back = bsp_clone(b, allocator)
			}
		}

	// A - B  ---  somewhat special case: replaces the solid leaves in A with cloned & inverted B   (eq. of A * ~B)
	case .DIFFERENCE:
		inverted := bsp_clone(b, allocator)
		defer bsp_destroy(inverted)
		bsp_invert(inverted)

		switch v in a.front {
		case ^BSP_Node:
			bsp_merge(v, b, mode, allocator)
		case ^BSP_Leaf:
			if v.solid {
				a.front = bsp_clone(inverted, allocator)
			}
		}

		switch v in a.back {
		case ^BSP_Node:
			bsp_merge(v, b, mode, allocator)
		case ^BSP_Leaf:
			if v.solid {
				a.back = bsp_clone(inverted, allocator)
			}
		}
	}
}

bsp_print :: proc(root: ^BSP_Node) {
	builder := strings.builder_make_len_cap(0, 1000, context.temp_allocator)
	bsp_print_internal(&builder, root, 0, .ROOT)

	log.info("BSP Tree Print:", strings.to_string(builder), sep = "\n")
}

_BSP_Node_Side :: enum {
	ROOT,
	FRONT,
	BACK,
}
bsp_print_internal :: proc(builder: ^strings.Builder, node: BSP_Node_Ref, depth: int, side: _BSP_Node_Side) {
	// Indent by depth
	for i in 0..<depth {
		strings.write_string(builder, "   " if i < depth-1 else "└─ ")
	}

	switch v in node {
	case ^BSP_Node:
		strings.write_string(builder, "[NODE]")
		switch side {
		case .FRONT:
			strings.write_string(builder, "(F)")
		case .BACK:
			strings.write_string(builder, "(B)")
		case .ROOT:
		}
		strings.write_string(builder, fmt.tprint(v.plane))
		strings.write_rune(builder, '\n')
		
		bsp_print_internal(builder, v.front, depth + 1, .FRONT)
		bsp_print_internal(builder, v.back,  depth + 1, .BACK)
	case ^BSP_Leaf:
		strings.write_string(builder, "[LEAF]")
		switch side {
		case .FRONT:
			strings.write_string(builder, "(F)")
		case .BACK:
			strings.write_string(builder, "(B)")
		case .ROOT:
		}
		strings.write_string(builder, " - SOLID" if v.solid else " - EMPTY")
		strings.write_string(builder, fmt.tprintf(" - n poly: %i", len(v.polygons)))
		strings.write_rune(builder, '\n')
	}
}
