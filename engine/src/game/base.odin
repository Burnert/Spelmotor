package game

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:slice"

Buffer_Block :: struct($Buf: typeid) {
	next: ^Buffer_Block(Buf),
	data: Buf,
}

// CHUNKED ARRAY ---------------------------------------------------------------------------------------------------------

Chunked_Array_Block :: struct($T: typeid, $N: uint) {
	next: ^Chunked_Array_Block(T, N),
	elements: [N]T,
}

Chunked_Array :: struct($T: typeid, $N: uint) {
	first_block: ^Chunked_Array_Block(T, N),
	last_block: ^Chunked_Array_Block(T, N),
	length: uint,
	allocator: runtime.Allocator,
}

chunked_array_make :: proc($T: typeid, $N: uint, allocator: runtime.Allocator) -> (ca: Chunked_Array(T, N)) {
	ca.allocator = allocator
	return ca
}

chunked_array_append :: proc(ca: ^Chunked_Array($T, $N), element: T) {
	assert(ca != nil)
	assert(ca.allocator.procedure != nil)

	context.allocator = ca.allocator

	ptr := chunked_array_alloc_next_element(ca)
	ptr^ = element
}

chunked_array_alloc_next_element :: proc(ca: ^Chunked_Array($T, $N)) -> ^T {
	assert(ca != nil)
	assert(ca.allocator.procedure != nil)

	context.allocator = ca.allocator

	if ca.first_block == nil {
		assert(ca.length == 0)
		assert(ca.last_block == nil)
		ca.first_block = new(Chunked_Array_Block(T, N))
		ca.last_block = ca.first_block
	}

	index_in_block := ca.length % N
	if index_in_block == N {
		new_block := new(Chunked_Array_Block(T, N))
		ca.last_block.next = new_block
		ca.last_block = new_block
	}

	ca.length += 1

	ptr := &ca.last_block.elements[index_in_block]
	return ptr
}

chunked_array_get_element :: proc(ca: ^Chunked_Array($T, $N), index: uint) -> ^T {
	assert(ca != nil)
	assert(index < ca.length)

	block_index := index / N
	index_in_block := index % N
	block := ca.first_block
	for i := uint(0); i < block_index; i += 1 {
		block = block.next
	}
	assert(block != nil)
	
	elem := &block.elements[index_in_block]
	return elem
}

// DYNAMIC CHUNKED ARRAY ---------------------------------------------------------------------------------------------------------

Dynamic_Chunked_Array_Block :: struct {
	next: ^Dynamic_Chunked_Array_Block,
	// elements: [?]byte,  <----- dynamically allocated inline with the block
}

Dynamic_Chunked_Array :: struct {
	block_element_count: uint,
	type: typeid,

	first_block: ^Dynamic_Chunked_Array_Block,
	last_block: ^Dynamic_Chunked_Array_Block,
	length: uint,

	allocator: runtime.Allocator,
}

dynamic_chunked_array_make :: proc(t: typeid, n: uint, allocator: runtime.Allocator) -> (dca: Dynamic_Chunked_Array) {
	dca.allocator = allocator
	dca.type = t
	dca.block_element_count = n
	return dca
}

dynamic_chunked_array_append :: proc(dca: ^Dynamic_Chunked_Array, element: any) {
	assert(dca != nil)
	assert(dca.allocator.procedure != nil)
	assert(element.id == dca.type)

	context.allocator = dca.allocator

	ptr := dynamic_chunked_array_alloc_next_element(dca)
	size := size_of(element.id)
	mem.copy_non_overlapping(ptr, element.data, size)
}

dynamic_chunked_array_calc_block_size_and_align :: proc(dca: ^Dynamic_Chunked_Array) -> (size: int, align: int) {
	assert(dca != nil)
	assert(dca.block_element_count > 0)

	block_size := size_of(Dynamic_Chunked_Array_Block)
	block_align := align_of(Dynamic_Chunked_Array_Block)
	assert(mem.align_forward_int(block_size, block_align) == block_size)

	elem_size := size_of(dca.type)
	elem_align := align_of(dca.type)
	assert(mem.align_forward_int(elem_size, elem_align) == elem_size)

	array_size := elem_size * int(dca.block_element_count)
	size = block_size
	size = mem.align_forward_int(size, elem_align)
	size += array_size
	align = max(block_align, elem_align)
	return
}

dynamic_chunked_array_alloc_next_element :: proc(dca: ^Dynamic_Chunked_Array) -> rawptr {
	assert(dca != nil)
	assert(dca.allocator.procedure != nil)

	context.allocator = dca.allocator

	if dca.first_block == nil {
		assert(dca.length == 0)
		assert(dca.last_block == nil)
		size, align := dynamic_chunked_array_calc_block_size_and_align(dca)
		block_ptr, err := mem.alloc(size, align)
		ensure(err == nil, fmt.tprintf("Failed to allocate the next dynamic chunked array block."))
		dca.first_block = cast(^Dynamic_Chunked_Array_Block)block_ptr
		dca.last_block = dca.first_block
	}

	index_in_block := dca.length % dca.block_element_count
	if index_in_block == dca.block_element_count {
		size, align := dynamic_chunked_array_calc_block_size_and_align(dca)
		block_ptr, err := mem.alloc(size, align)
		ensure(err == nil, fmt.tprintf("Failed to allocate the next dynamic chunked array block."))
		new_block := cast(^Dynamic_Chunked_Array_Block)block_ptr
		dca.last_block.next = new_block
		dca.last_block = new_block
	}

	dca.length += 1

	element_array := dynamic_chunked_array_get_element_array(dca^, dca.last_block)
	elem_size := size_of(dca.type)
	ptr := &element_array[int(index_in_block)*elem_size]
	return ptr
}

dynamic_chunked_array_get_element_array :: proc(dca: Dynamic_Chunked_Array, dcab: ^Dynamic_Chunked_Array_Block) -> []byte {
	elem_align := align_of(dca.type)
	block_size := size_of(Dynamic_Chunked_Array_Block)
	array_offset := mem.align_forward_int(block_size, elem_align)
	array_ptr := (^byte)(uintptr(dcab) + uintptr(array_offset))
	return slice.from_ptr(array_ptr, int(dca.block_element_count))
}

dynamic_chunked_array_get_element :: proc(dca: ^Dynamic_Chunked_Array, index: uint) -> rawptr {
	assert(dca != nil)
	assert(index < dca.length)

	block_index := index / dca.block_element_count
	index_in_block := index % dca.block_element_count
	block := dca.first_block
	for i := uint(0); i < block_index; i += 1 {
		block = block.next
	}
	assert(block != nil)
	
	elem_array := dynamic_chunked_array_get_element_array(dca^, block)
	elem_size := size_of(dca.type)
	elem := &elem_array[int(index_in_block)*elem_size]
	return elem
}

// LINKED LIST NODE ---------------------------------------------------------------------------------------------------------

Node :: struct($T: typeid) {
	next: ^Node(T),
	using element: T,
}
