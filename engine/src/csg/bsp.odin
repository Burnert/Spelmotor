package sm_csg

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:slice"
import "core:strings"

import "sm:core"

clone :: core.clone

BSP_Node_Side :: enum u8 {
	FRONT,
	BACK,
}

BSP_Node :: struct {
	// front, back: BSP_Node_Ref,
	children: [BSP_Node_Side]BSP_Node_Ref,
	parent: ^BSP_Node,
	debug_name: string,
	plane: Plane,
	side: BSP_Node_Side,
}

BSP_Leaf :: struct {
	parent: ^BSP_Node,
	polygons: [dynamic]BSP_Polygon,
	solid: bool,
	side: BSP_Node_Side,
}

BSP_Node_Ref :: union #no_nil {
	^BSP_Node,
	^BSP_Leaf,
}

BSP_Polygon :: struct {
	// TODO: Change to indices and add the unique vertices to the owning BSP tree
	// or actually this might be annoying with all the index remapping...
	// This might be beneficial in the optimization/baking stage.
	vertices: [dynamic]Vec3,
}

// Deep clone BSP_Polygon dynamic array
bsp_clone_polygons :: proc(polygons: [dynamic]BSP_Polygon) -> (out_polygons: [dynamic]BSP_Polygon) {
	if polygons == nil || len(polygons) == 0 {
		return
	}

	out_polygons = clone(polygons)
	for &p in out_polygons {
		p.vertices = clone(p.vertices)
	}
	return
}

// Deep clone BSP_Polygon slice into an existing polygon dynamic array
bsp_clone_polygons_into :: proc(into: ^[dynamic]BSP_Polygon, polygons: []BSP_Polygon) {
	assert(into != nil)
	assert(polygons != nil)

	for p in polygons {
		append(into, p)
		poly := &into[len(into)-1]
		poly.vertices = clone(poly.vertices)
	}
}

bsp_destroy_polygon :: proc(polygon: BSP_Polygon) {
	delete(polygon.vertices)
}

bsp_destroy_polygons :: proc(polygons: [dynamic]BSP_Polygon) {
	for p, i in polygons {
		bsp_destroy_polygon(p)
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
		bsp_poly.vertices = make_dynamic_array_len_cap([dynamic]Vec3, 0, len(indices), allocator)
		for idx in indices {
			append(&bsp_poly.vertices, vertices[idx].xyz)
		}
		node.children[.FRONT] = leaf
		leaf.parent = node
		leaf.side = .FRONT

		ok = true
		return
	}

	node: ^BSP_Node
	node_index := 0
	@static node_debug_name_str := "ABCDEFGHIJKLMNOPQRSTUVWXYZ?"
	// In convex brushes planes & polygons are essentially equivalent
	for poly := brush.polygons; poly != nil; poly = get_next_brush_polygon(poly) {
		plane := brush.planes[poly.plane_index]
		prev_node := node
		node, ok = create_node(plane, brush.vertices, poly, allocator)
		if !ok {
			return
		}

		node.debug_name, _ = strings.substring(node_debug_name_str, node_index, node_index + 1)
		node_index += 1
		node.parent = prev_node
		if prev_node != nil {
			prev_node.children[.BACK] = node
			node.side = .BACK
		} else {
			root = node
		}
	}

	// The last node of a brush is always solid and has no polygons
	leaf := bsp_create_leaf_node(allocator)
	leaf.solid = true
	leaf.parent = node
	node.children[.BACK] = leaf
	leaf.side = .BACK

	ok = true
	return
}

bsp_destroy :: proc(root: ^BSP_Node, allocator := context.allocator) {
	assert(root != nil)

	for c in root.children {
		switch v in c {
		case ^BSP_Node:
			bsp_destroy(v, allocator)
		case ^BSP_Leaf:
			bsp_destroy_leaf_node(v, allocator)
		}
	}

	free(root, allocator)
}

// Remember to change the parent of the cloned root node when inserting it as a subtree into a different tree
bsp_clone :: proc(root: ^BSP_Node, allocator := context.allocator) -> (cloned: ^BSP_Node) {
	assert(root != nil)

	cloned = new_clone(root^, allocator)

	for &c in cloned.children {
		switch &v in c {
		case ^BSP_Node:
			v = bsp_clone(v, allocator)
			v.parent = cloned
		case ^BSP_Leaf:
			v = new_clone(v^, allocator)
			v.parent = cloned
			v.polygons = bsp_clone_polygons(v.polygons)
		}
	}

	return
}

// Inverts the tree leaves' solid values in-place
// TODO: Planes should also be inverted I think
bsp_invert :: proc(root: ^BSP_Node) {
	assert(root != nil)

	for &c in root.children {
		switch &v in c {
		case ^BSP_Node:
			bsp_invert(v)
		case ^BSP_Leaf:
			v.solid = !v.solid
		}
	}
}

clip_poly_by_bsp_reverse_internal :: proc(node: ^BSP_Node, poly_vertices: ^[dynamic]Vec3, side: BSP_Node_Side) {
	plane := node.plane if side == .BACK else plane_invert(node.plane)
	clip_poly_with_plane_in_place(poly_vertices, plane)
	// If the polygon is not at least a triangle, all vertices must have been clipped
	if len(poly_vertices) < 3 {
		return
	}

	if node.parent != nil {
		clip_poly_by_bsp_reverse_internal(node.parent, poly_vertices, node.side)
	}
}

// Clip the polygon with the BSP nodes up until the root - reverse clip
clip_poly_by_bsp_reverse :: proc(leaf: ^BSP_Leaf, poly_vertices: ^[dynamic]Vec3) {
	if leaf.parent == nil {
		return
	}

	clip_poly_by_bsp_reverse_internal(leaf.parent, poly_vertices, leaf.side)
}

BSP_Merge_Mode :: enum {
	// A | B
	UNION,
	// A & B
	INTERSECT,
	// A - B   (A & ~B)
	DIFFERENCE,
}

// Modifies the A tree, clones and doesn't modify the B tree
// TODO: Bounding box checks to optimize the tree
// TODO: Clip the new polygons that were merged in
bsp_merge :: proc(a, b: ^BSP_Node, mode: BSP_Merge_Mode, allocator := context.allocator) {
	switch mode {
	// A | B  ---  replaces the non-solid leaves in A with cloned B
	case .UNION:
		for &c, side in a.children {
			switch v in c {
			case ^BSP_Node:
				bsp_merge(v, b, mode, allocator)
			case ^BSP_Leaf:
				if !v.solid {
					subtree := bsp_clone(b, allocator)
					union_clip_subtree :: proc(subtree: ^BSP_Node, insert_at: ^BSP_Leaf) {
						for &sub_c in subtree.children {
							switch &sub_v in sub_c {
							case ^BSP_Node:
								union_clip_subtree(sub_v, insert_at)
							case ^BSP_Leaf:
								if !sub_v.solid {
									// Clip the polygons in the subtree by the parent nodes
									for &sub_poly in sub_v.polygons {
										clip_poly_by_bsp_reverse(insert_at, &sub_poly.vertices)
									}
									sub_poly_count := len(sub_v.polygons)
									// Add and clip the polygons from the leaf we're inserting at
									bsp_clone_polygons_into(&sub_v.polygons, insert_at.polygons[:])
									for &parent_in_sub_poly in sub_v.polygons[sub_poly_count:] {
										clip_poly_by_bsp_reverse(sub_v, &parent_in_sub_poly.vertices)
									}
									// Remove invalid polygons
									for i := 0; i < len(sub_v.polygons); {
										if len(sub_v.polygons[i].vertices) == 0 {
											bsp_destroy_polygon(sub_v.polygons[i])
											unordered_remove(&sub_v.polygons, i)
										} else {
											i += 1
										}
									}
								}
							}
						}
					}
					// Clip polys by an unmerged subtree first
					union_clip_subtree(subtree, v)

					subtree.parent = a
					subtree.side = side

					// The old leaf node needs to be destroyed before inserting the subtree
					bsp_destroy_leaf_node(v, allocator)
					c = subtree
				}
			}
		}

	// A & B  ---  replaces the solid leaves in A with cloned B
	case .INTERSECT:
		for c, side in a.children {
			switch v in c {
			case ^BSP_Node:
				bsp_merge(v, b, mode, allocator)
			case ^BSP_Leaf:
				if v.solid {
					subtree := bsp_clone(b, allocator)
					subtree.parent = a
					a.children[side] = subtree
				}
			}
		}

	// A - B  ---  somewhat special case: replaces the solid leaves in A with cloned & inverted B   (eq. of A & ~B)
	case .DIFFERENCE:
		inverted := bsp_clone(b, allocator)
		defer bsp_destroy(inverted)
		bsp_invert(inverted)

		for c, side in a.children {
			switch v in c {
			case ^BSP_Node:
				bsp_merge(v, b, mode, allocator)
			case ^BSP_Leaf:
				if v.solid {
					subtree := bsp_clone(inverted, allocator)
					subtree.parent = a
					a.children[side] = subtree
				}
			}
		}
	}
}

bsp_print :: proc(root: ^BSP_Node) {
	builder := strings.builder_make_len_cap(0, 1000, context.temp_allocator)
	bsp_print_internal(&builder, root, 0, nil)

	log.info("BSP Tree Print:", strings.to_string(builder), sep = "\n")
}

bsp_print_internal :: proc(builder: ^strings.Builder, node: BSP_Node_Ref, depth: int, side: Maybe(BSP_Node_Side)) {
	// Indent by depth
	for i in 0..<depth {
		strings.write_string(builder, "   " if i < depth-1 else "└─ ")
	}

	switch v in node {
	case ^BSP_Node:
		strings.write_string(builder, "[NODE]")
		if side != nil do switch side {
		case .FRONT:
			strings.write_string(builder, "(F)")
		case .BACK:
			strings.write_string(builder, "(B)")
		}
		strings.write_string(builder, fmt.tprint(v.plane))
		strings.write_rune(builder, '\n')
		
		bsp_print_internal(builder, v.children[.FRONT], depth + 1, .FRONT)
		bsp_print_internal(builder, v.children[.BACK],  depth + 1, .BACK)
	case ^BSP_Leaf:
		strings.write_string(builder, "[LEAF]")
		if side != nil do switch side {
		case .FRONT:
			strings.write_string(builder, "(F)")
		case .BACK:
			strings.write_string(builder, "(B)")
		}
		strings.write_string(builder, " - SOLID" if v.solid else " - EMPTY")
		strings.write_string(builder, fmt.tprintf(" - n poly: %i", len(v.polygons)))
		strings.write_rune(builder, '\n')
	}
}
