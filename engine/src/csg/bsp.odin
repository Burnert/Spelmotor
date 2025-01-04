package sm_csg

import "base:runtime"

BSP_Node :: struct {
	front, back: BSP_Node_Ref,
	plane: Plane,
}

BSP_Leaf :: struct {
	solid: bool,
}

BSP_Node_Ref :: union #no_nil {
	^BSP_Node,
	BSP_Leaf,
}

bsp_create_from_brush :: proc(brush: Brush, allocator := context.allocator) -> (root: ^BSP_Node, ok: bool) {
	create_node_from_plane :: proc(plane: Plane, allocator: runtime.Allocator) -> (node: ^BSP_Node, ok: bool) {
		err: runtime.Allocator_Error
		node, err = new(BSP_Node, allocator)
		if err != .None {
			ok = false
			return
		}

		node.plane = plane
		node.front = BSP_Leaf{solid = false}
		ok = true
		return
	}

	node: ^BSP_Node
	for p in brush.planes {
		prev_node := node
		node, ok = create_node_from_plane(p, allocator)
		if !ok {
			return
		}

		if prev_node != nil {
			prev_node.back = node
		} else {
			root = node
		}
	}

	// The last node of a brush is always solid
	node.back = BSP_Leaf{solid = true}
	ok = true
	return
}

bsp_destroy :: proc(root: ^BSP_Node, allocator := context.allocator) {
	assert(root != nil)

	switch v in root.front {
	case ^BSP_Node:
		bsp_destroy(v, allocator)
	case BSP_Leaf:
	}

	switch v in root.back {
	case ^BSP_Node:
		bsp_destroy(v, allocator)
	case BSP_Leaf:
	}

	free(root, allocator)
}

bsp_clone :: proc(root: ^BSP_Node, allocator := context.allocator) -> (cloned: ^BSP_Node) {
	assert(root != nil)

	cloned = new_clone(root^, allocator)

	switch v in root.front {
	case ^BSP_Node:
		cloned.front = bsp_clone(v, allocator)
	case BSP_Leaf:
	}

	switch v in root.back {
	case ^BSP_Node:
		cloned.back = bsp_clone(v, allocator)
	case BSP_Leaf:
	}

	return
}

// Inverts the tree leaves' solid values in-place
bsp_invert :: proc(root: ^BSP_Node) {
	assert(root != nil)

	switch &v in root.front {
	case ^BSP_Node:
		bsp_invert(v)
	case BSP_Leaf:
		v.solid = !v.solid
	}

	switch &v in root.back {
	case ^BSP_Node:
		bsp_invert(v)
	case BSP_Leaf:
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
bsp_merge :: proc(a, b: ^BSP_Node, mode: BSP_Merge_Mode, allocator := context.allocator) {
	switch mode {
	// A | B  ---  replaces the non-solid leaves in A with cloned B
	case .UNION:
		switch v in a.front {
		case ^BSP_Node:
			bsp_merge(v, b, mode, allocator)
		case BSP_Leaf:
			if !v.solid {
				a.front = bsp_clone(b, allocator)
			}
		}

		switch v in a.back {
		case ^BSP_Node:
			bsp_merge(v, b, mode, allocator)
		case BSP_Leaf:
			if !v.solid {
				a.back = bsp_clone(b, allocator)
			}
		}

	// A * B  ---  replaces the solid leaves in A with cloned B
	case .INTERSECT:
		switch v in a.front {
		case ^BSP_Node:
			bsp_merge(v, b, mode, allocator)
		case BSP_Leaf:
			if v.solid {
				a.front = bsp_clone(b, allocator)
			}
		}

		switch v in a.back {
		case ^BSP_Node:
			bsp_merge(v, b, mode, allocator)
		case BSP_Leaf:
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
		case BSP_Leaf:
			if v.solid {
				a.front = bsp_clone(inverted, allocator)
			}
		}

		switch v in a.back {
		case ^BSP_Node:
			bsp_merge(v, b, mode, allocator)
		case BSP_Leaf:
			if v.solid {
				a.back = bsp_clone(inverted, allocator)
			}
		}
	}
}
