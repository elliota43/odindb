package btree

import "../pager"
import "base:builtin"
import "base:intrinsics"
import "core:fmt"
import "core:mem"

/*
   B+Tree (page / pager backed)

   ORDER (N) is the maximum number of keys a node may hold.
   Inserting the Nth key causes a split.
*/

Node_Type :: enum u8 {
	Internal = 0,
	Leaf     = 1,
}

//=== META PAGE HEADER ===

META_PAGE_ID :: pager.Page_ID(0)

META_VERSION :: 1

MAGIC_NUMBER :: 0x4F44494E

META_MAGIC_OFFSET :: 0
META_MAGIC_SIZE :: 4
META_VERSION_OFFSET :: META_MAGIC_OFFSET + META_MAGIC_SIZE
META_VERSION_SIZE :: 4
META_ROOT_OFFSET :: META_VERSION_OFFSET + META_VERSION_SIZE
META_ROOT_SIZE :: 4
META_FREELIST_OFFSET :: META_ROOT_OFFSET + META_ROOT_SIZE
META_FREELIST_SIZE :: 4
META_LEN_OFFSET :: META_FREELIST_OFFSET + META_FREELIST_SIZE
META_LEN_SIZE :: 8 // u64 record count
META_PAGE_SIZE_OFFSET :: META_LEN_OFFSET + META_LEN_SIZE
META_PAGE_SIZE_SIZE :: 4
META_ORDER_OFFSET :: META_PAGE_SIZE_OFFSET + META_PAGE_SIZE_SIZE
META_ORDER_SIZE :: 4


get_meta_magic :: proc(page: ^pager.Page) -> u32 {
	ptr := (^u32)(&page.data[META_MAGIC_OFFSET])
	return ptr^
}

set_meta_magic :: proc(page: ^pager.Page, magic: u32) {
	ptr := (^u32)(&page.data[META_MAGIC_OFFSET])
	ptr^ = magic
}

get_meta_version :: proc(page: ^pager.Page) -> u32 {
	ptr := (^u32)(&page.data[META_VERSION_OFFSET])
	return ptr^
}

set_meta_version :: proc(page: ^pager.Page, version: u32) {
	ptr := (^u32)(&page.data[META_VERSION_OFFSET])
	ptr^ = version
}

get_meta_root :: proc(page: ^pager.Page) -> pager.Page_ID {
	ptr := (^u32)(&page.data[META_ROOT_OFFSET])
	return pager.Page_ID(ptr^)
}

set_meta_root :: proc(page: ^pager.Page, root_id: pager.Page_ID) {
	ptr := (^u32)(&page.data[META_ROOT_OFFSET])
	ptr^ = u32(root_id)
}

get_meta_len :: proc(page: ^pager.Page) -> u64 {
	ptr := (^u64)(&page.data[META_LEN_OFFSET])
	return ptr^
}

set_meta_len :: proc(page: ^pager.Page, len: u64) {
	ptr := (^u64)(&page.data[META_LEN_OFFSET])
	ptr^ = len
}

get_meta_freelist :: proc(page: ^pager.Page) -> pager.Page_ID {
	ptr := (^u32)(&page.data[META_FREELIST_OFFSET])
	return pager.Page_ID(ptr^)
}

set_meta_freelist :: proc(page: ^pager.Page, freelist_id: pager.Page_ID) {
	ptr := (^u32)(&page.data[META_FREELIST_OFFSET])
	ptr^ = u32(freelist_id)
}

get_meta_pagesize :: proc(page: ^pager.Page) -> u32 {
	ptr := (^u32)(&page.data[META_PAGE_SIZE_OFFSET])
	return ptr^
}

set_meta_pagesize :: proc(page: ^pager.Page, size: u32) {
	ptr := (^u32)(&page.data[META_PAGE_SIZE_OFFSET])
	ptr^ = size
}

get_meta_order :: proc(page: ^pager.Page) -> u32 {
	ptr := (^u32)(&page.data[META_ORDER_OFFSET])
	return ptr^
}

set_meta_order :: proc(page: ^pager.Page, order: u32) {
	ptr := (^u32)(&page.data[META_ORDER_OFFSET])
	ptr^ = order
}

set_tree_root :: proc(t: ^Tree($K, $V, $N), root_id: pager.Page_ID) {
	t.root_page = root_id
	meta, ok := pager.get_page(t.p, META_PAGE_ID)
	assert(ok)
	set_meta_root(meta, root_id)
}

sync_meta_len :: proc(t: ^Tree($K, $V, $N)) {
	meta, ok := pager.get_page(t.p, META_PAGE_ID)
	assert(ok)
	set_meta_len(meta, u64(t.len))
}

// === COMMON HEADERS ===

NODE_TYPE_OFFSET :: 0
NODE_TYPE_SIZE :: 1
IS_ROOT_OFFSET :: 1
IS_ROOT_SIZE :: 1
PARENT_POINTER_OFFSET :: 2
PARENT_POINTER_SIZE :: 4
COMMON_HEADER_SIZE :: NODE_TYPE_SIZE + IS_ROOT_SIZE + PARENT_POINTER_SIZE

//=== LEAF NODE HEADER ===
LEAF_NUM_CELLS_OFFSET :: COMMON_HEADER_SIZE
LEAF_NUM_CELLS_SIZE :: 4
LEAF_NEXT_LEAF_OFFSET :: LEAF_NUM_CELLS_OFFSET + LEAF_NUM_CELLS_SIZE
LEAF_NEXT_LEAF_SIZE :: 4
LEAF_HEADER_SIZE :: COMMON_HEADER_SIZE + LEAF_NUM_CELLS_SIZE + LEAF_NEXT_LEAF_SIZE

//=== INTERNAL NODE HEADER ===
INTERNAL_NUM_KEYS_OFFSET :: COMMON_HEADER_SIZE
INTERNAL_NUM_KEYS_SIZE :: 4
INTERNAL_HEADER_SIZE :: COMMON_HEADER_SIZE + INTERNAL_NUM_KEYS_SIZE

// INVALID_PAGE_ID represents a "nil" page id pointer.
INVALID_PAGE_ID :: pager.Page_ID(0xFFFF_FFFF)

Tree :: struct($K: typeid, $V: typeid, $N: int) where intrinsics.type_is_ordered_numeric(K),
	N >= 3 {
	p:         ^pager.Pager,
	root_page: pager.Page_ID,
	allocator: mem.Allocator,
	len:       int,
}

Path_Entry :: struct {
	page_id: pager.Page_ID,
	index:   int,
}

MAX_HEIGHT :: 64

//=== COMMON HELPERS ===

get_node_type :: proc(page: ^pager.Page) -> Node_Type {
	return Node_Type(page.data[NODE_TYPE_OFFSET])
}

set_node_type :: proc(page: ^pager.Page, type: Node_Type) {
	page.data[NODE_TYPE_OFFSET] = u8(type)
}

get_parent :: proc(page: ^pager.Page) -> pager.Page_ID {
	ptr := (^u32)(&page.data[PARENT_POINTER_OFFSET])
	return pager.Page_ID(ptr^)
}

set_parent :: proc(page: ^pager.Page, parent_id: pager.Page_ID) {
	ptr := (^u32)(&page.data[PARENT_POINTER_OFFSET])
	ptr^ = u32(parent_id)
}

get_is_root :: proc(page: ^pager.Page) -> bool {
	return bool(page.data[IS_ROOT_OFFSET])
}

set_is_root :: proc(page: ^pager.Page, is_root: bool) {
	page.data[IS_ROOT_OFFSET] = u8(is_root)
}

//=== LEAF HEADER ===

get_leaf_num_cells :: proc(page: ^pager.Page) -> u32 {
	ptr := (^u32)(&page.data[LEAF_NUM_CELLS_OFFSET])
	return ptr^
}

set_leaf_num_cells :: proc(page: ^pager.Page, num: u32) {
	ptr := (^u32)(&page.data[LEAF_NUM_CELLS_OFFSET])
	ptr^ = num
}

get_leaf_next_leaf :: proc(page: ^pager.Page) -> pager.Page_ID {
	ptr := (^u32)(&page.data[LEAF_NEXT_LEAF_OFFSET])
	return pager.Page_ID(ptr^)
}

set_leaf_next_leaf :: proc(page: ^pager.Page, next_leaf: pager.Page_ID) {
	ptr := (^u32)(&page.data[LEAF_NEXT_LEAF_OFFSET])
	ptr^ = u32(next_leaf)
}

//=== INTERNAL HEADER ===

get_internal_num_keys :: proc(page: ^pager.Page) -> u32 {
	ptr := (^u32)(&page.data[INTERNAL_NUM_KEYS_OFFSET])
	return ptr^
}

set_internal_num_keys :: proc(page: ^pager.Page, num: u32) {
	ptr := (^u32)(&page.data[INTERNAL_NUM_KEYS_OFFSET])
	ptr^ = num
}

//=== LEAF BODY ===
// Layout: [Header] [Keys...] [Values...]

get_leaf_key :: proc(page: ^pager.Page, index: u32, $K: typeid) -> K {
	offset := LEAF_HEADER_SIZE + (index * u32(size_of(K)))
	ptr := (^K)(&page.data[offset])
	return ptr^
}

set_leaf_key :: proc(page: ^pager.Page, index: u32, key: $K) {
	offset := LEAF_HEADER_SIZE + (index * u32(size_of(K)))
	ptr := (^K)(&page.data[offset])
	ptr^ = key
}

get_leaf_value :: proc(page: ^pager.Page, index: u32, $K: typeid, $V: typeid, $N: int) -> V {
	keys_size := u32(N * size_of(K))
	offset := LEAF_HEADER_SIZE + keys_size + (index * u32(size_of(V)))
	ptr := (^V)(&page.data[offset])
	return ptr^
}

set_leaf_value :: proc(page: ^pager.Page, index: u32, value: $V, $K: typeid, $N: int) {
	keys_size := u32(N * size_of(K))
	offset := LEAF_HEADER_SIZE + keys_size + (index * u32(size_of(V)))
	ptr := (^V)(&page.data[offset])
	ptr^ = value
}

get_leaf_keys_slice :: proc(page: ^pager.Page, $K: typeid) -> []K {
	num_cells := get_leaf_num_cells(page)
	ptr := (^K)(&page.data[LEAF_HEADER_SIZE])
	return (cast([^]K)ptr)[:num_cells]
}

get_leaf_keys_cap :: proc(page: ^pager.Page, $K: typeid, $N: int) -> []K {
	ptr := (^K)(&page.data[LEAF_HEADER_SIZE])
	return (cast([^]K)ptr)[:N]
}

get_leaf_values_cap :: proc(page: ^pager.Page, $K: typeid, $V: typeid, $N: int) -> []V {
	ptr := (^V)(&page.data[LEAF_HEADER_SIZE + N * size_of(K)])
	return (cast([^]V)ptr)[:N]
}

//=== INTERNAL BODY ===
// Layout: [Header] [Keys...] [Children Page_IDs...]

get_internal_key :: proc(page: ^pager.Page, index: u32, $K: typeid) -> K {
	offset := INTERNAL_HEADER_SIZE + (index * u32(size_of(K)))
	ptr := (^K)(&page.data[offset])
	return ptr^
}

set_internal_key :: proc(page: ^pager.Page, index: u32, key: $K) {
	offset := INTERNAL_HEADER_SIZE + (index * u32(size_of(K)))
	ptr := (^K)(&page.data[offset])
	ptr^ = key
}

get_internal_child :: proc(page: ^pager.Page, index: u32, $K: typeid, $N: int) -> pager.Page_ID {
	keys_size := u32(N * size_of(K))
	offset := INTERNAL_HEADER_SIZE + keys_size + (index * u32(size_of(pager.Page_ID)))
	ptr := (^pager.Page_ID)(&page.data[offset])
	return ptr^
}

set_internal_child :: proc(
	page: ^pager.Page,
	index: u32,
	child_id: pager.Page_ID,
	$K: typeid,
	$N: int,
) {
	keys_size := u32(N * size_of(K))
	offset := INTERNAL_HEADER_SIZE + keys_size + (index * u32(size_of(pager.Page_ID)))
	ptr := (^pager.Page_ID)(&page.data[offset])
	ptr^ = child_id
}

get_internal_keys_slice :: proc(page: ^pager.Page, $K: typeid) -> []K {
	num_keys := get_internal_num_keys(page)
	ptr := (^K)(&page.data[INTERNAL_HEADER_SIZE])
	return (cast([^]K)ptr)[:num_keys]
}

get_internal_keys_cap :: proc(page: ^pager.Page, $K: typeid, $N: int) -> []K {
	ptr := (^K)(&page.data[INTERNAL_HEADER_SIZE])
	return (cast([^]K)ptr)[:N]
}

get_internal_children_cap :: proc(page: ^pager.Page, $K: typeid, $N: int) -> []pager.Page_ID {
	ptr := (^pager.Page_ID)(&page.data[INTERNAL_HEADER_SIZE + N * size_of(K)])
	return (cast([^]pager.Page_ID)ptr)[:N + 1]
}

//=== PAGE ALLOCATION ===

alloc_leaf_page :: proc(
	t: ^Tree($K, $V, $N),
	is_root: bool,
	parent := INVALID_PAGE_ID,
) -> pager.Page_ID {
	// TODO: free-list for deleted pages
	page, new_id, ok := pager.alloc_page(t.p)
	assert(ok, "failed to allocate new page from pager")

	mem.zero_slice(page.data[:])

	set_node_type(page, .Leaf)
	set_is_root(page, is_root)
	set_parent(page, INVALID_PAGE_ID if is_root else parent)
	set_leaf_next_leaf(page, INVALID_PAGE_ID)
	set_leaf_num_cells(page, 0)

	return new_id
}

alloc_internal_page :: proc(
	t: ^Tree($K, $V, $N),
	is_root: bool,
	parent := INVALID_PAGE_ID,
) -> pager.Page_ID {
	// TODO: free-list for deleted pages
	page, new_id, ok := pager.alloc_page(t.p)
	assert(ok, "failed to allocate new page from pager")

	mem.zero_slice(page.data[:])

	set_node_type(page, .Internal)
	set_is_root(page, is_root)
	set_parent(page, INVALID_PAGE_ID if is_root else parent)
	set_internal_num_keys(page, 0)

	return new_id
}

//=== PUBLIC API ===

init :: proc(
	t: ^$T/Tree($K, $V, $N),
	p: ^pager.Pager,
	allocator := context.allocator,
) where intrinsics.type_is_ordered_numeric(K),
	N >=
	3 {
	assert(
		LEAF_HEADER_SIZE + (N * size_of(K)) + (N * size_of(V)) <= pager.PAGE_SIZE,
		"Leaf node exceeds page size",
	)
	assert(
		INTERNAL_HEADER_SIZE + (N * size_of(K)) + ((N + 1) * size_of(pager.Page_ID)) <=
		pager.PAGE_SIZE,
		"Internal node exceeds page size",
	)

	context.allocator = allocator
	t.allocator = allocator
	t.p = p

	if p.num_pages == 0 {
		// bootstrap db
		meta_page, meta_id, mok := pager.alloc_page(t.p)
		assert(mok && meta_id == META_PAGE_ID, "Meta page must be ID 0")
		mem.zero_slice(meta_page.data[:])

		set_meta_magic(meta_page, MAGIC_NUMBER)
		set_meta_version(meta_page, META_VERSION)
		set_meta_freelist(meta_page, INVALID_PAGE_ID)
		set_meta_len(meta_page, 0)
		set_meta_pagesize(meta_page, u32(pager.PAGE_SIZE))
		set_meta_order(meta_page, u32(N))

		set_tree_root(t, alloc_leaf_page(t, true))

		return
	}

	// mount existing db

	meta_page, mok := pager.get_page(t.p, META_PAGE_ID)
	assert(mok, "failed to read meta page")

	assert(get_meta_magic(meta_page) == MAGIC_NUMBER, "bad magic")
	assert(get_meta_version(meta_page) == META_VERSION, "unsupported version number")
	assert(get_meta_pagesize(meta_page) == u32(pager.PAGE_SIZE), "page size mismatch")
	assert(get_meta_order(meta_page) == u32(N), "tree order mismatch")

	t.root_page = get_meta_root(meta_page)
	t.len = int(get_meta_len(meta_page))

	assert(t.root_page != META_PAGE_ID && t.root_page != INVALID_PAGE_ID, "invalid root page")
}

// destroy clears the tree struct. Page memory is owned by the pager.
destroy :: proc(t: ^$T/Tree($K, $V, $N)) {
	t^ = {}
}

len :: proc "contextless" (t: ^$T/Tree($K, $V, $N)) -> int {
	return t.len
}

root_is_leaf :: proc(t: ^Tree($K, $V, $N)) -> bool {
	if t.p == nil || t.root_page == INVALID_PAGE_ID {
		return false
	}
	page, ok := pager.get_page(t.p, t.root_page)
	return ok && get_node_type(page) == .Leaf
}

root_is_internal :: proc(t: ^Tree($K, $V, $N)) -> bool {
	if t.p == nil || t.root_page == INVALID_PAGE_ID {
		return false
	}
	page, ok := pager.get_page(t.p, t.root_page)
	return ok && get_node_type(page) == .Internal
}

insert :: proc(t: ^$T/Tree($K, $V, $N), key: K, value: V) {
	context.allocator = t.allocator

	path: [MAX_HEIGHT]Path_Entry
	path_len := 0

	leaf := find_leaf(t, key, path[:], &path_len)
	keys := get_leaf_keys_slice(leaf, K)
	idx, found := search_key(keys, key)
	if found {
		set_leaf_value(leaf, u32(idx), value, K, N)
		return
	}

	assert(get_leaf_num_cells(leaf) < u32(N), "leaf unexpectedly full")


	leaf_insert_cell(leaf, idx, key, value, N)
	t.len += 1
	sync_meta_len(t)

	if get_leaf_num_cells(leaf) < u32(N) {
		return
	}

	right_id, promote := split_leaf(t, leaf.id)
	insert_upward(t, path[:path_len], leaf.id, right_id, promote)
}

remove :: proc(t: ^$T/Tree($K, $V, $N), key: K) -> (ok: bool) {
	context.allocator = t.allocator

	path: [MAX_HEIGHT]Path_Entry
	path_len := 0

	leaf := find_leaf(t, key, path[:], &path_len)
	keys := get_leaf_keys_slice(leaf, K)
	idx, found := search_key(keys, key)
	if !found {
		return false
	}

	leaf_remove_cell(leaf, idx, K, V, N)
	t.len -= 1
	sync_meta_len(t)

	if path_len == 0 {
		return true
	}

	if int(get_leaf_num_cells(leaf)) >= N / 2 {
		return true
	}

	remove_upward(t, path[:path_len])
	return true
}

get :: proc(t: ^$T/Tree($K, $V, $N), key: K) -> (value: V, ok: bool) {
	if t.p == nil || t.root_page == INVALID_PAGE_ID {
		return {}, false
	}

	leaf := peek_leaf(t, key)
	keys := get_leaf_keys_slice(leaf, K)
	idx, found := search_key(keys, key)
	if !found {
		return {}, false
	}

	return get_leaf_value(leaf, u32(idx), K, V, N), true
}

// iterate_leaf walks the leaf sibling chain in key order.
iterate_leaf :: proc(t: ^$T/Tree($K, $V, $N), visit: proc(key: K, value: V) -> (keep: bool)) {
	if t.p == nil || t.root_page == INVALID_PAGE_ID {
		return
	}

	curr_id := leftmost(t)
	for curr_id != INVALID_PAGE_ID {
		page, ok := pager.get_page(t.p, curr_id)
		assert(ok)
		assert(get_node_type(page) == .Leaf)

		n := get_leaf_num_cells(page)
		for i in 0 ..< n {
			if !visit(get_leaf_key(page, i, K), get_leaf_value(page, i, K, V, N)) {
				return
			}
		}
		curr_id = get_leaf_next_leaf(page)
	}
}

print :: proc(t: ^$T/Tree($K, $V, $N)) {
	if t.p == nil || t.root_page == INVALID_PAGE_ID {
		fmt.println("[empty]")
		return
	}
	print_page(t, t.root_page, "", true)
}

//==== internal helpers ====

search_key :: proc(keys: []$K, key: K) -> (index: int, found: bool) {
	i := 0
	for i < builtin.len(keys) && keys[i] < key {
		i += 1
	}
	if i < builtin.len(keys) && keys[i] == key {
		return i, true
	}
	return i, false
}

child_index :: proc(page: ^pager.Page, key: $K) -> int {
	keys := get_internal_keys_slice(page, K)
	i := 0
	for i < builtin.len(keys) && key >= keys[i] {
		i += 1
	}
	return i
}

peek_leaf :: proc(t: ^Tree($K, $V, $N), key: K) -> ^pager.Page {
	curr := t.root_page
	for {
		page, ok := pager.get_page(t.p, curr)
		assert(ok, "peek_leaf: failed to get page")

		switch get_node_type(page) {
		case .Leaf:
			return page
		case .Internal:
			idx := child_index(page, key)
			curr = get_internal_child(page, u32(idx), K, N)
		}
	}
}

find_leaf :: proc(
	t: ^Tree($K, $V, $N),
	key: K,
	path: []Path_Entry,
	path_len: ^int,
) -> ^pager.Page {
	curr := t.root_page
	path_len^ = 0

	for {
		page, ok := pager.get_page(t.p, curr)
		assert(ok, "find_leaf: failed to get page")

		switch get_node_type(page) {
		case .Leaf:
			return page
		case .Internal:
			assert(path_len^ < builtin.len(path), "tree height exceeded MAX_HEIGHT")
			idx := child_index(page, key)
			path[path_len^] = Path_Entry {
				page_id = curr,
				index   = idx,
			}
			path_len^ += 1
			curr = get_internal_child(page, u32(idx), K, N)
		}
	}
}

leftmost :: proc(t: ^Tree($K, $V, $N)) -> pager.Page_ID {
	curr := t.root_page
	for {
		page, ok := pager.get_page(t.p, curr)
		assert(ok)
		switch get_node_type(page) {
		case .Leaf:
			return curr
		case .Internal:
			curr = get_internal_child(page, 0, K, N)
		}
	}
}

leaf_insert_cell :: proc(page: ^pager.Page, idx: int, key: $K, value: $V, $N: int) {
	n := int(get_leaf_num_cells(page))
	assert(n < N, "leaf_insert_cell: leaf is full")
	assert(idx >= 0 && idx <= n)

	keys := get_leaf_keys_cap(page, K, N)
	vals := get_leaf_values_cap(page, K, V, N)
	copy(keys[idx + 1:n + 1], keys[idx:n])
	copy(vals[idx + 1:n + 1], vals[idx:n])
	keys[idx] = key
	vals[idx] = value
	set_leaf_num_cells(page, u32(n + 1))
}

// leaf_remove_cell removes the key/value at `idx` by shifting following cells left.
leaf_remove_cell :: proc(page: ^pager.Page, idx: int, $K: typeid, $V: typeid, $N: int) {
	n := int(get_leaf_num_cells(page))
	assert(idx >= 0 && idx < n)

	keys := get_leaf_keys_cap(page, K, N)
	vals := get_leaf_values_cap(page, K, V, N)
	copy(keys[idx:n - 1], keys[idx + 1:n])
	copy(vals[idx:n - 1], vals[idx + 1:n])
	set_leaf_num_cells(page, u32(n - 1))
}

internal_insert :: proc(page: ^pager.Page, idx: int, key: $K, child_id: pager.Page_ID, $N: int) {
	n := int(get_internal_num_keys(page))
	assert(n < N, "internal_insert: node is full")
	assert(idx >= 0 && idx <= n)

	keys := get_internal_keys_cap(page, K, N)
	children := get_internal_children_cap(page, K, N)
	copy(keys[idx + 1:n + 1], keys[idx:n])
	copy(children[idx + 2:n + 2], children[idx + 1:n + 1])
	keys[idx] = key
	children[idx + 1] = child_id
	set_internal_num_keys(page, u32(n + 1))
}

// internal_remove removes key at `key_idx` and child at `child_idx`.
internal_remove :: proc(page: ^pager.Page, key_idx: int, child_idx: int, $K: typeid, $N: int) {
	n := int(get_internal_num_keys(page))
	assert(key_idx >= 0 && key_idx < n)
	assert(child_idx >= 0 && child_idx <= n)

	keys := get_internal_keys_cap(page, K, N)
	children := get_internal_children_cap(page, K, N)
	copy(keys[key_idx:n - 1], keys[key_idx + 1:n])
	copy(children[child_idx:n], children[child_idx + 1:n + 1])
	set_internal_num_keys(page, u32(n - 1))
}

split_leaf :: proc(
	t: ^Tree($K, $V, $N),
	left_id: pager.Page_ID,
) -> (
	right_id: pager.Page_ID,
	promote: K,
) {
	left, ok := pager.get_page(t.p, left_id)
	assert(ok)
	assert(get_node_type(left) == .Leaf)
	assert(int(get_leaf_num_cells(left)) == N)

	mid := N / 2
	right_id = alloc_leaf_page(t, false, get_parent(left))
	right, rok := pager.get_page(t.p, right_id)
	assert(rok)

	lk := get_leaf_keys_cap(left, K, N)
	lv := get_leaf_values_cap(left, K, V, N)
	rk := get_leaf_keys_cap(right, K, N)
	rv := get_leaf_values_cap(right, K, V, N)

	n_right := N - mid
	copy(rk[:n_right], lk[mid:N])
	copy(rv[:n_right], lv[mid:N])
	set_leaf_num_cells(left, u32(mid))
	set_leaf_num_cells(right, u32(n_right))

	set_leaf_next_leaf(right, get_leaf_next_leaf(left))
	set_leaf_next_leaf(left, right_id)

	promote = rk[0]
	return
}

split_internal :: proc(
	t: ^Tree($K, $V, $N),
	left_id: pager.Page_ID,
) -> (
	right_id: pager.Page_ID,
	promote: K,
) {
	left, ok := pager.get_page(t.p, left_id)
	assert(ok)
	assert(get_node_type(left) == .Internal)
	assert(int(get_internal_num_keys(left)) == N)

	mid := N / 2
	lk := get_internal_keys_cap(left, K, N)
	lc := get_internal_children_cap(left, K, N)
	promote = lk[mid]

	right_id = alloc_internal_page(t, false, get_parent(left))
	right, rok := pager.get_page(t.p, right_id)
	assert(rok)

	rk := get_internal_keys_cap(right, K, N)
	rc := get_internal_children_cap(right, K, N)

	n_right := N - mid - 1
	copy(rk[:n_right], lk[mid + 1:N])
	copy(rc[:n_right + 1], lc[mid + 1:N + 1])
	set_internal_num_keys(left, u32(mid))
	set_internal_num_keys(right, u32(n_right))

	for i in 0 ..= n_right {
		child, cok := pager.get_page(t.p, rc[i])
		assert(cok)
		set_parent(child, right_id)
	}
	return
}

insert_upward :: proc(
	t: ^Tree($K, $V, $N),
	path: []Path_Entry,
	left_id, right_id: pager.Page_ID,
	key: K,
) {
	promote := key
	l, r := left_id, right_id

	for i := builtin.len(path) - 1; i >= 0; i -= 1 {
		parent_id := path[i].page_id
		parent, ok := pager.get_page(t.p, parent_id)
		assert(ok)

		right, rok := pager.get_page(t.p, r)
		assert(rok)
		set_parent(right, parent_id)

		internal_insert(parent, path[i].index, promote, r, N)

		if get_internal_num_keys(parent) < u32(N) {
			return
		}

		l = parent_id
		r, promote = split_internal(t, parent_id)
	}

	new_root_id := alloc_internal_page(t, true)
	new_root, ok := pager.get_page(t.p, new_root_id)
	assert(ok)

	set_internal_key(new_root, 0, promote)
	set_internal_child(new_root, 0, l, K, N)
	set_internal_child(new_root, 1, r, K, N)
	set_internal_num_keys(new_root, 1)

	left, lok := pager.get_page(t.p, l)
	right, rok := pager.get_page(t.p, r)
	assert(lok && rok)
	set_is_root(left, false)
	set_is_root(right, false)
	set_parent(left, new_root_id)
	set_parent(right, new_root_id)

	set_tree_root(t, new_root_id)
}

remove_upward :: proc(t: ^Tree($K, $V, $N), path: []Path_Entry) {
	min_keys := N / 2

	for i := builtin.len(path) - 1; i >= 0; i -= 1 {
		parent_id := path[i].page_id
		parent, ok := pager.get_page(t.p, parent_id)
		assert(ok)
		idx := path[i].index

		if try_borrow(t, parent, idx) {
			return
		}

		merge_with_sibling(t, parent, idx)

		if i == 0 {
			break
		}

		if int(get_internal_num_keys(parent)) >= min_keys {
			return
		}
	}

	shrink_root(t)
}

try_borrow :: proc(t: ^Tree($K, $V, $N), parent: ^pager.Page, idx: int) -> bool {
	child_id := get_internal_child(parent, u32(idx), K, N)
	child, ok := pager.get_page(t.p, child_id)
	assert(ok)

	switch get_node_type(child) {
	case .Leaf:
		return try_borrow_leaf(t, parent, idx)
	case .Internal:
		return try_borrow_internal(t, parent, idx)
	}
	return false
}

try_borrow_leaf :: proc(t: ^Tree($K, $V, $N), parent: ^pager.Page, idx: int) -> bool {
	min_keys := N / 2
	n_children := int(get_internal_num_keys(parent)) + 1

	curr_id := get_internal_child(parent, u32(idx), K, N)
	curr, ok := pager.get_page(t.p, curr_id)
	assert(ok)

	// right sibling
	if idx + 1 < n_children {
		right_id := get_internal_child(parent, u32(idx + 1), K, N)
		right, rok := pager.get_page(t.p, right_id)
		assert(rok)
		if int(get_leaf_num_cells(right)) > min_keys {
			rk := get_leaf_keys_cap(right, K, N)
			rv := get_leaf_values_cap(right, K, V, N)
			leaf_insert_cell(curr, int(get_leaf_num_cells(curr)), rk[0], rv[0], N)
			leaf_remove_cell(right, 0, K, V, N)
			set_internal_key(parent, u32(idx), get_leaf_key(right, 0, K))
			return true
		}
	}

	// left sibling
	if idx > 0 {
		left_id := get_internal_child(parent, u32(idx - 1), K, N)
		left, lok := pager.get_page(t.p, left_id)
		assert(lok)
		if int(get_leaf_num_cells(left)) > min_keys {
			ln := int(get_leaf_num_cells(left))
			k := get_leaf_key(left, u32(ln - 1), K)
			v := get_leaf_value(left, u32(ln - 1), K, V, N)
			leaf_remove_cell(left, ln - 1, K, V, N)
			leaf_insert_cell(curr, 0, k, v, N)
			set_internal_key(parent, u32(idx - 1), k)
			return true
		}
	}

	return false
}

try_borrow_internal :: proc(t: ^Tree($K, $V, $N), parent: ^pager.Page, idx: int) -> bool {
	min_keys := N / 2
	n_children := int(get_internal_num_keys(parent)) + 1

	curr_id := get_internal_child(parent, u32(idx), K, N)
	curr, ok := pager.get_page(t.p, curr_id)
	assert(ok)

	// right sibling
	if idx + 1 < n_children {
		right_id := get_internal_child(parent, u32(idx + 1), K, N)
		right, rok := pager.get_page(t.p, right_id)
		assert(rok)
		if int(get_internal_num_keys(right)) > min_keys {
			sep := get_internal_key(parent, u32(idx), K)
			child0 := get_internal_child(right, 0, K, N)

			cn := int(get_internal_num_keys(curr))
			ck := get_internal_keys_cap(curr, K, N)
			cc := get_internal_children_cap(curr, K, N)
			ck[cn] = sep
			cc[cn + 1] = child0
			set_internal_num_keys(curr, u32(cn + 1))

			moved, mok := pager.get_page(t.p, child0)
			assert(mok)
			set_parent(moved, curr_id)

			set_internal_key(parent, u32(idx), get_internal_key(right, 0, K))
			internal_remove(right, 0, 0, K, N)
			return true
		}
	}

	// left sibling
	if idx > 0 {
		left_id := get_internal_child(parent, u32(idx - 1), K, N)
		left, lok := pager.get_page(t.p, left_id)
		assert(lok)
		if int(get_internal_num_keys(left)) > min_keys {
			sep := get_internal_key(parent, u32(idx - 1), K)
			ln := int(get_internal_num_keys(left))
			up := get_internal_key(left, u32(ln - 1), K)
			child := get_internal_child(left, u32(ln), K, N)

			cn := int(get_internal_num_keys(curr))
			ck := get_internal_keys_cap(curr, K, N)
			cc := get_internal_children_cap(curr, K, N)
			copy(ck[1:cn + 1], ck[0:cn])
			copy(cc[1:cn + 2], cc[0:cn + 1])
			ck[0] = sep
			cc[0] = child
			set_internal_num_keys(curr, u32(cn + 1))

			moved, mok := pager.get_page(t.p, child)
			assert(mok)
			set_parent(moved, curr_id)

			set_internal_key(parent, u32(idx - 1), up)
			internal_remove(left, ln - 1, ln, K, N)
			return true
		}
	}

	return false
}

merge_with_sibling :: proc(t: ^Tree($K, $V, $N), parent: ^pager.Page, idx: int) {
	if idx > 0 {
		merge_children(t, parent, idx - 1, idx)
	} else {
		merge_children(t, parent, idx, idx + 1)
	}
}

merge_children :: proc(t: ^Tree($K, $V, $N), parent: ^pager.Page, left_idx, right_idx: int) {
	assert(right_idx == left_idx + 1)

	left_id := get_internal_child(parent, u32(left_idx), K, N)
	right_id := get_internal_child(parent, u32(right_idx), K, N)
	left, lok := pager.get_page(t.p, left_id)
	right, rok := pager.get_page(t.p, right_id)
	assert(lok && rok)

	switch get_node_type(left) {
	case .Leaf:
		assert(get_node_type(right) == .Leaf)
		rn := int(get_leaf_num_cells(right))
		rk := get_leaf_keys_cap(right, K, N)
		rv := get_leaf_values_cap(right, K, V, N)
		for i in 0 ..< rn {
			leaf_insert_cell(left, int(get_leaf_num_cells(left)), rk[i], rv[i], N)
		}
		set_leaf_next_leaf(left, get_leaf_next_leaf(right))

	case .Internal:
		assert(get_node_type(right) == .Internal)
		sep := get_internal_key(parent, u32(left_idx), K)
		ln := int(get_internal_num_keys(left))
		lk := get_internal_keys_cap(left, K, N)
		lc := get_internal_children_cap(left, K, N)
		lk[ln] = sep
		set_internal_num_keys(left, u32(ln + 1))

		rn := int(get_internal_num_keys(right))
		rk := get_internal_keys_cap(right, K, N)
		rc := get_internal_children_cap(right, K, N)

		ln = int(get_internal_num_keys(left))
		copy(lk[ln:ln + rn], rk[:rn])
		copy(lc[ln:ln + rn + 1], rc[:rn + 1])
		set_internal_num_keys(left, u32(ln + rn))

		for i in 0 ..= rn {
			child, cok := pager.get_page(t.p, rc[i])
			assert(cok)
			set_parent(child, left_id)
		}
	}

	internal_remove(parent, left_idx, right_idx, K, N)
	// TODO: return right_id to a free list
}

shrink_root :: proc(t: ^Tree($K, $V, $N)) {
	root, ok := pager.get_page(t.p, t.root_page)
	assert(ok)
	if get_node_type(root) != .Internal {
		return
	}
	if get_internal_num_keys(root) != 0 {
		return
	}

	only := get_internal_child(root, 0, K, N)
	child, cok := pager.get_page(t.p, only)
	assert(cok)

	set_is_root(child, true)
	set_parent(child, INVALID_PAGE_ID)
	set_tree_root(t, only)
	// TODO: return old root to a free list
}

print_page :: proc(t: ^Tree($K, $V, $N), page_id: pager.Page_ID, prefix: string, is_last: bool) {
	page, ok := pager.get_page(t.p, page_id)
	assert(ok)

	branch := is_last ? "└── " : "├── "
	switch get_node_type(page) {
	case .Leaf:
		fmt.printf(
			"%s%sleaf id=%v keys=%v\n",
			prefix,
			branch,
			page_id,
			get_leaf_keys_slice(page, K),
		)
	case .Internal:
		fmt.printf(
			"%s%sinternal id=%v keys=%v\n",
			prefix,
			branch,
			page_id,
			get_internal_keys_slice(page, K),
		)
		child_prefix := is_last ? prefix + "    " : prefix + "│   "
		count := int(get_internal_num_keys(page)) + 1
		for i in 0 ..< count {
			child_id := get_internal_child(page, u32(i), K, N)
			print_page(t, child_id, child_prefix, i == count - 1)
		}
	}
}
