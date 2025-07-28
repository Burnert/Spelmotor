package game

import "base:intrinsics"
import "base:runtime"

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

// LINKED LIST NODE ---------------------------------------------------------------------------------------------------------

Node :: struct($T: typeid) {
	next: ^Node(T),
	using element: T,
}
