package sm_csg

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:prof/spall"

import "sm:core"

clone    :: core.clone
clone_sa :: core.clone_sa

BSP_Prof :: struct {
	spall_ctx: spall.Context,
	spall_buffer: spall.Buffer,
}
g_bsp_prof: BSP_Prof

@(deferred_in=_bsp_prof_scoped_event_end)
bsp_prof_scoped_event :: proc(name: string, args: string = "", location := #caller_location) {
	if g_bsp_prof.spall_buffer.data != nil {
		spall._buffer_begin(&g_bsp_prof.spall_ctx, &g_bsp_prof.spall_buffer, name, args, location)
	}
}
_bsp_prof_scoped_event_end :: proc(_, _: string, _ := #caller_location) {
	if g_bsp_prof.spall_buffer.data != nil {
		spall._buffer_end(&g_bsp_prof.spall_ctx, &g_bsp_prof.spall_buffer)
	}
}

// TYPES -----------------------------------------------------------------------------------------------------

BSP_Tree :: struct {
	root: ^BSP_Node,
	aabb: AABB,
}

BSP_Node_Side :: enum u8 {
	FRONT,
	BACK,
}

BSP_Node_Base :: struct {
	parent: ^BSP_Node,
	debug_name: string,
	side: BSP_Node_Side,
}

BSP_Node :: struct {
	using base: BSP_Node_Base,
	children: [BSP_Node_Side]BSP_Node_Slot,
	plane: Plane,
}

BSP_Leaf :: struct {
	using base: BSP_Node_Base,
	polygons: [dynamic]BSP_Polygon,
	solid: bool,
}

BSP_Node_Slot :: union #no_nil {
	^BSP_Node,
	^BSP_Leaf,
}

BSP_Polygon :: struct {
	// TODO: Change to indices and add the unique vertices to the owning BSP tree
	// or actually this might be annoying with all the index remapping...
	// This might be beneficial in the optimization/baking stage.
	vertices: [dynamic]Vec3,
	plane: Plane,
}

BSP_Merge_Mode :: enum {
	// A | B
	UNION,
	// A & B
	INTERSECT,
	// A - B   (A & ~B)
	DIFFERENCE,
}

// NODE SIDE UTILS -----------------------------------------------------------------------------------------------------

bsp_invert_side :: proc(side: BSP_Node_Side) -> BSP_Node_Side {
	switch side {
	case .BACK: return .FRONT
	case .FRONT: return .BACK
	case: panic("Invalid BSP node side.")
	}
}

// POLYGONS UTILS -----------------------------------------------------------------------------------------------------

bsp_clone_sa_polygon :: proc(polygon: BSP_Polygon) -> (cloned: BSP_Polygon) {
	cloned = polygon
	cloned.vertices = clone_sa(polygon.vertices)
	return
}

bsp_clone_polygon :: proc(polygon: BSP_Polygon, allocator := context.allocator) -> (cloned: BSP_Polygon) {
	// POD Mem copy:
	cloned = polygon

	// Deep clone:
	cloned.vertices = clone(polygon.vertices, allocator)

	return
}

// Deep clone BSP_Polygon dynamic array
bsp_clone_sa_polygons :: proc(polygons: [dynamic]BSP_Polygon) -> (out_polygons: [dynamic]BSP_Polygon) {
	if polygons == nil || len(polygons) == 0 {
		return
	}

	out_polygons = clone_sa(polygons)
	for &p in out_polygons {
		p = bsp_clone_sa_polygon(p)
	}
	return
}

// Deep clone BSP_Polygon dynamic array
bsp_clone_polygons :: proc(polygons: []BSP_Polygon, allocator := context.allocator) -> (out_polygons: [dynamic]BSP_Polygon) {
	if polygons == nil || len(polygons) == 0 {
		return
	}

	out_polygons = slice.clone_to_dynamic(polygons, allocator)
	for &p in out_polygons {
		p = bsp_clone_polygon(p, allocator)
	}
	return
}

// Deep clone BSP_Polygon slice into an existing polygon dynamic array
bsp_clone_sa_polygons_into :: proc(into: ^[dynamic]BSP_Polygon, polygons: []BSP_Polygon) {
	assert(into != nil)
	assert(polygons != nil)

	for p in polygons {
		p_cloned := bsp_clone_sa_polygon(p)
		append(into, p_cloned)
	}
}

bsp_destroy_polygon :: proc(polygon: BSP_Polygon) {
	delete(polygon.vertices)
}

bsp_clear_polygons :: proc(polygons: ^[dynamic]BSP_Polygon) {
	for p, i in polygons {
		bsp_destroy_polygon(p)
	}
	clear(polygons)
}

bsp_destroy_polygons :: proc(polygons: [dynamic]BSP_Polygon) {
	for p, i in polygons {
		bsp_destroy_polygon(p)
	}
	delete(polygons)
}

bsp_create_polygon :: proc(allocator := context.allocator) -> (out_poly: BSP_Polygon) {
	out_poly.vertices = make_dynamic_array_len_cap([dynamic]Vec3, 0, 4, allocator)
	return
}

// LEAVES UTILS ------------------------------------------------------------------------------------------------------

bsp_create_leaf :: proc(allocator := context.allocator) -> (leaf: ^BSP_Leaf) {
	err: runtime.Allocator_Error
	leaf, err = new(BSP_Leaf, allocator)
	if err != .None {
		return
	}

	return
}

bsp_destroy_leaf :: proc(leaf: ^BSP_Leaf, allocator := context.allocator) {
	bsp_destroy_polygons(leaf.polygons)
	free(leaf, allocator)
}

bsp_clone_leaf :: proc(leaf: ^BSP_Leaf, allocator := context.allocator) -> (cloned: ^BSP_Leaf) {
	bsp_prof_scoped_event(#procedure)

	cloned = new_clone(leaf^, allocator)
	cloned.polygons = bsp_clone_polygons(cloned.polygons[:], allocator)
	return
}

// TREE UTILS ------------------------------------------------------------------------------------------------------

bsp_destroy_tree :: proc(tree: ^BSP_Tree, allocator := context.allocator) {
	bsp_destroy(tree.root, allocator)
	tree.root = nil
}

bsp_destroy :: proc(root: ^BSP_Node, allocator := context.allocator) {
	assert(root != nil)

	for c in root.children {
		switch v in c {
		case ^BSP_Node:
			bsp_destroy(v, allocator)
		case ^BSP_Leaf:
			bsp_destroy_leaf(v, allocator)
		}
	}

	free(root, allocator)
}

// Remember to change the parent of the cloned root node when inserting it as a subtree into a different tree
bsp_clone_tree :: proc(root: ^BSP_Node, allocator := context.allocator) -> (cloned: ^BSP_Node) {
	bsp_prof_scoped_event(#procedure)

	assert(root != nil)

	cloned = new_clone(root^, allocator)

	for &c in cloned.children {
		switch &v in c {
		case ^BSP_Node:
			v = bsp_clone_tree(v, allocator)
			v.parent = cloned
		case ^BSP_Leaf:
			v = bsp_clone_leaf(v, allocator)
			v.parent = cloned
		}
	}

	return
}

// Inverts the tree leaves' solid values in-place
// TODO: Planes should also be inverted I think
bsp_invert_tree :: proc(root: ^BSP_Node) {
	assert(root != nil)

	for &c in root.children {
		switch &v in c {
		case ^BSP_Node:
			bsp_invert_tree(v)
		case ^BSP_Leaf:
			v.solid = !v.solid
		}
	}
}

// Creates a new BSP tree from the specified convex brush
bsp_create_from_brush :: proc(brush: Brush, allocator := context.allocator) -> (tree: BSP_Tree, ok: bool) {
	create_brush_node :: proc(plane: Plane, vertices: []Vec4, brush_polygon: ^Polygon, allocator: runtime.Allocator) -> (node: ^BSP_Node, ok: bool) {
		err: runtime.Allocator_Error
		node, err = new(BSP_Node, allocator)
		if err != .None {
			ok = false
			return
		}

		node.plane = plane

		// One non-solid leaf per brush plane
		leaf := bsp_create_leaf(allocator)
		leaf.solid = false
		// Each brush plane corresponds to just one polygon
		// Multiple polygons per empty leaf are only possible in merged BSP trees
		leaf.polygons = make_dynamic_array_len([dynamic]BSP_Polygon, 1, allocator)
		brush_poly_indices := get_polygon_indices(brush_polygon)
		bsp_poly := &leaf.polygons[0]
		bsp_poly.vertices = make_dynamic_array_len_cap([dynamic]Vec3, 0, len(brush_poly_indices), allocator)
		bsp_poly.plane = plane
		// Vertices in brush's polygons are stored per brush - the polygon only stores indices.
		// In BSPs there's no such thing by default because it's less flexible.
		for idx in brush_poly_indices {
			append(&bsp_poly.vertices, vertices[idx].xyz)
		}
		// Non-solid leaves should always end up on nodes' front
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
		// Create one node per brush plane - each of the brush's planes splits the consecutive subspace in half
		node, ok = create_brush_node(plane, brush.vertices, poly, allocator)
		if !ok {
			return
		}

		node.debug_name, _ = strings.substring(node_debug_name_str, node_index, node_index + 1)
		node_index += 1
		node.parent = prev_node
		if prev_node != nil {
			// Each consecutive plane will split the space on the previous node's back.
			prev_node.children[.BACK] = node
			node.side = .BACK
		} else {
			tree.root = node
		}
	}

	tree.aabb = brush.aabb

	// The last node of a brush is always solid and has no polygons
	leaf := bsp_create_leaf(allocator)
	leaf.solid = true
	leaf.parent = node
	node.children[.BACK] = leaf
	leaf.side = .BACK

	ok = true
	return
}

// Will return nil if a leaf with no parent was passed in
bsp_find_root :: proc(node: BSP_Node_Slot) -> (root: ^BSP_Node) {
	base := bsp_slot_to_base(node)
	if base.parent == nil {
		root, _ = node.(^BSP_Node)
		return
	}
	return bsp_find_root(base.parent)
}

// NODE SLOT UTILS ------------------------------------------------------------------------------------------------------

bsp_slot_to_base :: proc(slot: BSP_Node_Slot) -> ^BSP_Node_Base {
	switch v in slot {
	case ^BSP_Node: return &v.base
	case ^BSP_Leaf: return &v.base
	case: panic("Invalid node slot type.")
	}
}

bsp_clone_slot :: proc(slot: BSP_Node_Slot, allocator := context.allocator) -> (cloned: BSP_Node_Slot) {
	switch v in slot {
	case ^BSP_Node:
		cloned = bsp_clone_tree(v, allocator)
	case ^BSP_Leaf:
		cloned = bsp_clone_leaf(v, allocator)
	}
	return
}

bsp_destroy_slot :: proc(slot: BSP_Node_Slot, allocator := context.allocator) {
	switch v in slot {
	case ^BSP_Node:
		bsp_destroy(v, allocator)
	case ^BSP_Leaf:
		bsp_destroy_leaf(v, allocator)
	}
}

// Replaces "this" with "with", cloning "with" and destroying "this"
bsp_replace_subtree :: proc(this: ^BSP_Node_Slot, with: BSP_Node_Slot, allocator := context.allocator) {
	bsp_prof_scoped_event(#procedure)

	base := bsp_slot_to_base(this^)
	parent, side := base.parent, base.side

	// Clone "with" first, because it might be a part of "this", which is going to be destroyed before replacement
	with_cloned := bsp_clone_slot(with, allocator)
	bsp_destroy_slot(this^, allocator)
	this^ = with_cloned

	base = bsp_slot_to_base(this^)
	base.parent, base.side = parent, side
}

// POLYGON CLIPPING -------------------------------------------------------------------------------------------------

// Clips the polygon by the provided BSP tree.
// This might result in 0 or more output polygons.
clip_poly_by_bsp_tree :: proc(root: ^BSP_Node, poly_vertices: []Vec3, poly_plane: Plane, out_polys: ^[dynamic]BSP_Polygon, allocator := context.allocator) {
	bsp_prof_scoped_event(#procedure)

	assert(root != nil)
	assert(out_polys != nil)

	plane := root.plane
	inv_plane := plane_invert(plane)

	// First, split the poly by the root node
	temp_vertices: [BSP_Node_Side][dynamic]Vec3
	temp_vertices[.FRONT] = make([dynamic]Vec3, context.temp_allocator)
	temp_vertices[.BACK]  = make([dynamic]Vec3, context.temp_allocator)

	// Clipping by a coplanar plane needs to be special cased because just using clip_poly_by_plane won't yield correct results
	if plane_is_coplanar_abs_normalized_epsilon(plane, poly_plane) {
		for v in poly_vertices {
			append(&temp_vertices[.BACK], v)
		}
	} else {
		clip_poly_by_plane(poly_vertices, inv_plane, &temp_vertices[.FRONT])
		clip_poly_by_plane(poly_vertices, plane,     &temp_vertices[.BACK])
	}

	for c, side in root.children {
		switch v in c {
		case ^BSP_Node:
			if len(temp_vertices[side]) >= 3 {
				// Recursively clip by the rest of the tree
				clip_poly_by_bsp_tree(v, temp_vertices[side][:], poly_plane, out_polys)
			}
		case ^BSP_Leaf:
			// Solid leaves don't contain polygons
			if !v.solid {
				if len(temp_vertices[side]) >= 3 {
					new_poly: BSP_Polygon
					new_poly.vertices = clone(temp_vertices[side], allocator)
					append(out_polys, new_poly)
				}
			}
		}
	}
}

// Clip the polygon with the BSP nodes up until the root - reverse clip
// NOTE: This works only because BSP leaves are always convex, so it doesn't really matter from which side the clipping starts
clip_poly_by_bsp_tree_reverse :: proc(start_node: ^BSP_Node, poly: ^BSP_Polygon, poly_side_in_node: BSP_Node_Side) -> (valid_after_clip: bool) {
	bsp_prof_scoped_event(#procedure)

	clip_plane := start_node.plane if poly_side_in_node == .BACK else plane_invert(start_node.plane)
	// Don't clip if coplanar - TODO: This may be different for inversely coplanar nodes
	if !plane_is_coplanar_abs_normalized_epsilon(poly.plane, clip_plane) {
		if clip_poly_by_plane_in_place(&poly.vertices, clip_plane) == false {
			// If the polygon is not at least a triangle, all vertices must have been clipped
			return false
		}
	}

	if start_node.parent != nil {
		return clip_poly_by_bsp_tree_reverse(start_node.parent, poly, start_node.side)
	}
	return len(poly.vertices) >= 3
}

// Clip the polygon with the BSP nodes up until the root - reverse clip - leaf version
// NOTE: This works only because BSP leaves are always convex, so it doesn't really matter from which side the clipping starts
clip_poly_by_bsp_leaf_reverse :: proc(start_leaf: ^BSP_Leaf, poly: ^BSP_Polygon) -> (valid_after_clip: bool) {
	if start_leaf.parent == nil {
		return len(poly.vertices) >= 3
	}

	return clip_poly_by_bsp_tree_reverse(start_leaf.parent, poly, start_leaf.side)
}

remove_invalid_polygons :: proc(polygons: ^[dynamic]BSP_Polygon) {
	for i := 0; i < len(polygons); {
		if len(polygons[i].vertices) < 3 {
			bsp_destroy_polygon(polygons[i])
			unordered_remove(polygons, i)
		} else {
			i += 1
		}
	}
}

// TREE MERGING -------------------------------------------------------------------------------------------------

bsp_merge_trees :: proc(a, b: ^BSP_Tree, mode: BSP_Merge_Mode, allocator := context.allocator) {
	bsp_merge(a.root, b.root, mode, a.aabb, b.aabb, allocator)
}

// Modifies the A tree, clones and doesn't modify the B tree
// TODO: Bounding box checks to optimize the tree
bsp_merge :: proc(a, b: ^BSP_Node, mode: BSP_Merge_Mode, a_aabb, b_aabb: Maybe(AABB), allocator := context.allocator) {
	bsp_prof_scoped_event(#procedure)

	switch mode {
	// A | B  ---  replaces the non-solid leaves in A with cloned B
	case .UNION:
		for &c, side in a.children {
			switch v in c {
			case ^BSP_Node:
				bsp_merge(v, b, mode, a_aabb, b_aabb, allocator)
			case ^BSP_Leaf:
				if !v.solid {
					{
						bsp_prof_scoped_event("bsp_merge - AABB optimization")
	
						should_merge_aabb :: proc(a: BSP_Node, side: BSP_Node_Side, aabb: AABB) -> bool {
							b_dist_to_plane := find_aabb_distance_to_plane(aabb, a.plane)
							if b_dist_to_plane < 0 if side == .FRONT else b_dist_to_plane > 0 {
								return false
							}
	
							// return true
							if a.parent != nil {
								return should_merge_aabb(a.parent^, a.side, aabb)
							} else {
								return true
							}
						}
	
						// Do this optimization only on front leaves, which, by definition, should be empty (TODO: needs to be enforced)
						if b_aabb != nil && side == .FRONT {
							if !should_merge_aabb(a^, .FRONT, b_aabb.?) {
								continue
							}
						}
					}

					// B will be reused a lot so it's safest to just clone it
					b := bsp_clone_tree(b, allocator)

					// TODO: Optimize the subtree (remove redundant branches - all leaves empty/solid)

					union_process_subtree_insertion :: proc(subtree_slot: ^BSP_Node_Slot, insert_at_leaf: ^BSP_Leaf, allocator := context.allocator) {
						bsp_prof_scoped_event(#procedure)

						assert(subtree_slot != nil)
						assert(insert_at_leaf != nil)

						find_coplanar_reverse :: proc(to_plane: Plane, find_in: BSP_Node_Slot) -> (out_node: ^BSP_Node, out_side: BSP_Node_Side) {
							find_in_base := bsp_slot_to_base(find_in)
							if find_in_base.parent == nil {
								return
							}
							if plane_is_coplanar_normalized_epsilon(to_plane, find_in_base.parent.plane) {
								return find_in_base.parent, find_in_base.side
							}
							return find_coplanar_reverse(to_plane, find_in_base.parent)
						}

						subnode, is_node := subtree_slot.(^BSP_Node)
						if !is_node {
							bsp_prof_scoped_event("union_process_subtree_insertion - leaf clipping")

							// Leaves' polygons need some more clipping
							subleaf := subtree_slot.(^BSP_Leaf)
							if !subleaf.solid && len(subleaf.polygons) > 0 {
								// 1. Reverse clip B subleaf's polys by insert_at_leaf
								for &p in subleaf.polygons {
									clip_poly_by_bsp_leaf_reverse(insert_at_leaf, &p)
								}
								remove_invalid_polygons(&subleaf.polygons)

								if len(subleaf.polygons) > 0 {
									// 2. Clip remaining B subleaf's polys by the whole A tree
									// TODO: This will be slow as hell on large trees, AABB and different optimizations are needed
									// TODO: Also this should probably use a cloned A tree because it will keep being modified along the way.
									a_root := bsp_find_root(insert_at_leaf)
									clipped_polys := make([dynamic]BSP_Polygon, 0, len(subleaf.polygons), allocator)
									for p in subleaf.polygons {
										clip_poly_by_bsp_tree(a_root, p.vertices[:], p.plane, &clipped_polys, allocator)
									}
									remove_invalid_polygons(&clipped_polys)
	
									// 3. Replace original polys with clipped ones
									bsp_destroy_polygons(subleaf.polygons)
									subleaf.polygons = clipped_polys
								}
							}
							if subleaf.side == .FRONT {
								subleaf.solid = false
							}
							return
						}

						coplanar_node, coplanar_side := find_coplanar_reverse(subnode.plane, find_in=insert_at_leaf)
						if coplanar_node != nil {
							// Discard the current node and replace with the child that's on the same side
							// (opposite if inversely coplanar) as the insert_at_leaf is in terms of that coplanar node.
							bsp_replace_subtree(/*this*/subtree_slot, /*with*/subnode.children[coplanar_side], allocator)
							union_process_subtree_insertion(subtree_slot, insert_at_leaf, allocator)
							return
						}

						back_node,  is_back_node  := subnode.children[.BACK].(^BSP_Node)
						front_node, is_front_node := subnode.children[.FRONT].(^BSP_Node)

						// If there are no leaves - first, try to collapse the front tree to a leaf
						if is_back_node && is_front_node {
							// verify if this works
							union_process_subtree_insertion(&subnode.children[.FRONT], insert_at_leaf, allocator)
							front_node, is_front_node = subnode.children[.FRONT].(^BSP_Node)
						}

						// Still no leaves - just recurse on the back node - also verify if this works
						if is_back_node && is_front_node {
							union_process_subtree_insertion(&subnode.children[.BACK], insert_at_leaf, allocator)
							return
						}

						// Assume the front leaf is the empty one - TODO: maybe this should actually be enforced (solid BSP tree style), but then hints could be problematic(or not?).
						// Obviously this will go off is the constraint is not met
						assert(!is_front_node)
						if !is_front_node {
							front_leaf := subnode.children[.FRONT].(^BSP_Leaf)
							if !front_leaf.solid {
								// Reverse clip B by insert_at_leaf
								for &poly in front_leaf.polygons {
									clip_poly_by_bsp_tree_reverse(insert_at_leaf.parent, &poly, .FRONT)
								}
								remove_invalid_polygons(&front_leaf.polygons)
								// If there are no polygons left it means the split(node) is not necessary in this subtree.
								// Discard the current node, replace with the back child and recurse.
								if len(front_leaf.polygons) == 0 {
									bsp_replace_subtree(subtree_slot, subnode.children[.BACK], allocator)
									union_process_subtree_insertion(subtree_slot, insert_at_leaf, allocator)
									return
								}
							}

							// Now, transfer the polys from the insert_at_leaf to the subtree
							clipped_poly: BSP_Polygon
							for &p in insert_at_leaf.polygons {
								clipped_poly = bsp_clone_polygon(p, allocator)
								// Take only what should be a part of the current subleaf
								if clip_poly_by_bsp_tree_reverse(subnode, &clipped_poly, .FRONT) {
									append(&front_leaf.polygons, clipped_poly)
								} else {
									bsp_destroy_polygon(clipped_poly)
								}
							}

							// And continue processing on the back child
							union_process_subtree_insertion(&subnode.children[.BACK], insert_at_leaf, allocator)
						}
					}

					b_slot := BSP_Node_Slot(b)
					union_process_subtree_insertion(&b_slot, v, allocator)

					// Before inserting a subleaf, the polygons from the insert leaf need to be cloned into that subleaf, otherwise they will get discarded.
					if b_leaf, is_leaf := b_slot.(^BSP_Leaf); is_leaf {
						bsp_clone_sa_polygons_into(&b_leaf.polygons, v.polygons[:])
					}

					b_base := bsp_slot_to_base(b_slot)
					b_base.parent = a
					b_base.side = side

					// The old leaf node needs to be destroyed before inserting the subtree
					bsp_destroy_leaf(v, allocator)
					c = b_slot
				}
			}
		}

	// A & B  ---  replaces the solid leaves in A with cloned B
	case .INTERSECT:
		for c, side in a.children {
			switch v in c {
			case ^BSP_Node:
				bsp_merge(v, b, mode, a_aabb, b_aabb, allocator)
			case ^BSP_Leaf:
				if v.solid {
					subtree := bsp_clone_tree(b, allocator)
					subtree.parent = a
					a.children[side] = subtree
				}
			}
		}

	// A - B  ---  somewhat special case: replaces the solid leaves in A with cloned & inverted B   (eq. of A & ~B)
	case .DIFFERENCE:
		inverted := bsp_clone_tree(b, allocator)
		defer bsp_destroy(inverted)
		bsp_invert_tree(inverted)

		for c, side in a.children {
			switch v in c {
			case ^BSP_Node:
				bsp_merge(v, b, mode, a_aabb, b_aabb, allocator)
			case ^BSP_Leaf:
				if v.solid {
					subtree := bsp_clone_tree(inverted, allocator)
					subtree.parent = a
					a.children[side] = subtree
				}
			}
		}
	}
}

// TREE PRINTING -------------------------------------------------------------------------------------------------

bsp_print :: proc(root: ^BSP_Node) {
	builder := strings.builder_make_len_cap(0, 1000, context.temp_allocator)
	bsp_print_internal(&builder, root, 0, nil)

	log.info("BSP Tree Print:", strings.to_string(builder), sep = "\n")
}

bsp_print_internal :: proc(builder: ^strings.Builder, node: BSP_Node_Slot, depth: int, side: Maybe(BSP_Node_Side)) {
	// Indent by depth
	for i in 0..<depth {
		strings.write_string(builder, "   " if i < depth-1 else "└─ ")
	}

	switch v in node {
	case ^BSP_Node:
		if side != nil do switch side {
		case .FRONT:
			strings.write_string(builder, "(F)")
		case .BACK:
			strings.write_string(builder, "(B)")
		}
		strings.write_string(builder, "[NODE=")
		strings.write_string(builder, v.debug_name)
		strings.write_string(builder, "]")
		strings.write_string(builder, fmt.tprint(v.plane))
		strings.write_rune(builder, '\n')
		
		bsp_print_internal(builder, v.children[.FRONT], depth + 1, .FRONT)
		bsp_print_internal(builder, v.children[.BACK],  depth + 1, .BACK)
	case ^BSP_Leaf:
		if side != nil do switch side {
		case .FRONT:
			strings.write_string(builder, "(F)")
		case .BACK:
			strings.write_string(builder, "(B)")
		}
		strings.write_string(builder, "[LEAF]")
		strings.write_string(builder, " - SOLID" if v.solid else " - EMPTY")
		strings.write_string(builder, fmt.tprintf(" - n poly: %i", len(v.polygons)))
		strings.write_rune(builder, '\n')
	}
}
