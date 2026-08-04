package btree

import "base:builtin"
import "base:intrinsics"
import "core:container/small_array"
import "core:fmt"
import "core:mem"
/*
   B+Tree

   ORDER is the maximum number of keys a node may hold.
   Inserting the ORDERith key causes a split.
*/

Tree :: struct($K: typeid, $V: typeid, $N: int) where intrinsics.type_is_ordered_numeric(K),
	N >= 3 {
	root:      ^Node(K, V, N),
	allocator: mem.Allocator,
	len:       int,
}

Node :: union($K: typeid, $V: typeid, $N: int) {
	Leaf(K, V, N),
	Internal(K, V, N),
}

Leaf :: struct($K: typeid, $V: typeid, $N: int) {
	keys:   small_array.Small_Array(N, K),
	values: small_array.Small_Array(N, V),
	next:   ^Node(K, V, N),
}

Internal :: struct($K: typeid, $V: typeid, $N: int) {
	keys:     small_array.Small_Array(N, K),
	children: small_array.Small_Array(N + 1, ^Node(K, V, N)),
}

Path_Entry :: struct($K: typeid, $V: typeid, $N: int) {
	node:  ^Node(K, V, N),
	index: int,
}

MAX_HEIGHT :: 64

init :: proc(
	t: ^$T/Tree($K, $V, $N),
	allocator := context.allocator,
) where intrinsics.type_is_ordered_numeric(K),
	N >= 3 {
	context.allocator = allocator
	t.allocator = allocator
	t.len = 0

	root := new(Node(K, V, N))
	root^ = Leaf(K, V, N){}
	t.root = root
}

destroy :: proc(t: ^$T/Tree($K, $V, $N)) {
	if t.root == nil {
		return
	}

	context.allocator = t.allocator
	destroy_node(t.root)
	t^ = {}
}

len :: proc "contextless" (t: ^$T/Tree($K, $V, $N)) -> int {
	return t.len
}

insert :: proc(t: ^$T/Tree($K, $V, $N), key: K, value: V) {
	context.allocator = t.allocator

	path: [MAX_HEIGHT]Path_Entry(K, V, N)
	path_len := 0

	leaf := find_leaf(t, key, path[:], &path_len)

	keys := small_array.slice(&leaf.keys)
	idx, found := search_key(keys, key)
	if found {
		small_array.set(&leaf.values, idx, value)
		return
	}

	assert(small_array.space(leaf.keys) > 0, "leaf unexpectedly full")
	small_array.inject_at(&leaf.keys, key, idx)
	small_array.inject_at(&leaf.values, value, idx)
	t.len += 1

	if small_array.len(leaf.keys) < N {
		return
	}

	leaf_node := find_leaf_node(t, key)
	right_node, promote := split_leaf(leaf_node)
	insert_upward(t, path[:path_len], leaf_node, right_node, promote)
}

remove :: proc(t: ^$T/Tree($K, $V, $N), key: K) -> (ok: bool) {
	context.allocator = t.allocator

	path: [MAX_HEIGHT]Path_Entry(K, V, N)
	path_len := 0

	leaf := find_leaf(t, key, path[:], &path_len)

	keys := small_array.slice(&leaf.keys)
	idx, found := search_key(keys, key)
	if !found {
		ok = false
		return
	}

	small_array.ordered_remove(&leaf.keys, idx)
	small_array.ordered_remove(&leaf.values, idx)

	t.len -= 1

	// root can be empty / underflow
	if path_len == 0 {
		ok = true
		return
	}

	if small_array.len(&leaf.keys) >= N / 2 {
		// NOTE: Decide whether you want to update the key in the parent internal node
		// in case we just deleted the very first key/value in the leaf node.
		ok = true
		return
	}

	// underflowed
	remove_upward(t, path[:path_len])
	return true
}

get :: proc(t: ^$T/Tree($K, $V, $N), key: K) -> (value: V, ok: bool) {
	if t.root == nil {
		return {}, false
	}

	leaf := peek_leaf(t.root, key)
	keys := small_array.slice(&leaf.keys)
	idx, found := search_key(keys, key)
	if !found {
		return {}, false
	}

	return small_array.get(leaf.values, idx), true
}

// in-order walk over the leaf sibling chain
iterate_leaf :: proc(t: ^$T/Tree($K, $V, $N), visit: proc(key: K, value: V) -> (keep: bool)) {
	if t.root == nil {
		return
	}

	curr := leftmost(t.root)
	for curr != nil {
		switch &n in curr^ {
		case Leaf(K, V, N):
			for i in 0 ..< small_array.len(n.keys) {
				if !visit(small_array.get(n.keys, i), small_array.get(n.values, i)) {
					return
				}
			}
			curr = n.next

		case Internal(K, V, N):
			unreachable()
		}
	}
}

print :: proc(t: ^$T/Tree($K, $V, $N)) {
	if t.root == nil {
		fmt.println("[empty]")
		return
	}

	print_node(t.root, "", true)
}

// ==== internal helpers ====

// search_key linearly searches sorted `keys` for `key`. It returns the index where
// `key` is or should be inserted, and whether an exact match was found.
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

// child_index returns the child slot in `node` that should be followed when
// looking up `key` (the first index i such that `key < keys[i]`, or `len(keys)`).
child_index :: proc(node: ^Internal($K, $V, $N), key: K) -> int {
	keys := small_array.slice(&node.keys)
	i := 0
	for i < builtin.len(keys) && key >= keys[i] {
		i += 1
	}
	return i
}

// peek_leaf walks from root to the leaf that would hold `key` and returns a pointer
// to that leaf's payload. It does not record the descent path.
peek_leaf :: proc(root: ^Node($K, $V, $N), key: K) -> ^Leaf(K, V, N) {
	curr := root
	for {
		switch &n in curr^ {
		case Leaf(K, V, N):
			return &n
		case Internal(K, V, N):
			curr = small_array.get(n.children, child_index(&n, key))
		}
	}
}

// find_leaf_node walks the tree to the leaf that would hold `key` and returns
// the leaf as a ^Node, suitable for structural ops that require a ^Node(K, V, N)
// object, like splitting and merging.
find_leaf_node :: proc(t: ^$T/Tree($K, $V, $N), key: K) -> ^Node(K, V, N) {
	curr := t.root
	for {
		switch &n in curr^ {
		case Leaf(K, V, N):
			return curr
		case Internal(K, V, N):
			curr = small_array.get(n.children, child_index(&n, key))
		}
	}
}

// find_leaf walks the tree to the leaf that would hold `key`, records each internal parent and child
// index in `path`, and returns a ^Leaf into that node's payload for key/value access.
find_leaf :: proc(
	t: ^$T/Tree($K, $V, $N),
	key: K,
	path: []Path_Entry(K, V, N),
	path_len: ^int,
) -> ^Leaf(K, V, N) {
	curr := t.root
	path_len^ = 0

	for {
		switch &n in curr^ {
		case Leaf(K, V, N):
			return &n
		case Internal(K, V, N):
			assert(path_len^ < builtin.len(path), "tree height exceeded MAX_HEIGHT")
			idx := child_index(&n, key)
			path[path_len^] = {curr, idx}
			path_len^ += 1
			curr = small_array.get(n.children, idx)
		}
	}
}

// leftmost returns the leftmost leaf under `root` as a `^Node(K, V, N)`, following
// `children[0]` at each internal node.
leftmost :: proc(root: ^Node($K, $V, $N)) -> ^Node(K, V, N) {
	curr := root
	for {
		switch &n in curr^ {
		case Leaf(K, V, N):
			return curr
		case Internal(K, V, N):
			curr = small_array.get(n.children, 0)
		}
	}
}

// split_leaf splits a full leaf `left_node` at `mid = N / 2` into left and a new
// right sibling, links them via the leaf node's next pointers, and returns the right node
// plus the separator key to promote (the first key of the right leaf).
split_leaf :: proc(left_node: ^Node($K, $V, $N)) -> (right_node: ^Node(K, V, N), promote: K) {
	left := &left_node.(Leaf(K, V, N))
	mid := N / 2

	right_node = new(Node(K, V, N))
	right_node^ = Leaf(K, V, N){}
	right := &right_node.(Leaf(K, V, N))

	for i in mid ..< small_array.len(left.keys) {
		small_array.push(&right.keys, small_array.get(left.keys, i))
		small_array.push(&right.values, small_array.get(left.values, i))
	}

	small_array.resize(&left.keys, mid)
	small_array.resize(&left.values, mid)

	right.next = left.next
	left.next = right_node

	// copy separator into parent
	promote = small_array.get(right.keys, 0)
	return
}

// split_internal splits a full internal `left_node` at `mid = N/2`. The middle key is removed
// and returned as `promote`; keys/children after mid move to the right sibling.
// The left sibling keeps `keys[0 .. mid)` and `children[0 ..= mid]`.
split_internal :: proc(left_node: ^Node($K, $V, $N)) -> (right_node: ^Node(K, V, N), promote: K) {
	left := &left_node.(Internal(K, V, N))
	mid := N / 2
	promote = small_array.get(left.keys, mid)

	right_node = new(Node(K, V, N))
	right_node^ = Internal(K, V, N){}
	right := &right_node.(Internal(K, V, N))

	// children[mid+1 ..] move with the right node
	for i in mid + 1 ..= small_array.len(left.keys) {
		small_array.push(&right.children, small_array.get(left.children, i))
	}

	for i in mid + 1 ..< small_array.len(left.keys) {
		small_array.push(&right.keys, small_array.get(left.keys, i))
	}

	// left keeps keys[0 .. mid) and children[0 .. mid]
	small_array.resize(&left.keys, mid)
	small_array.resize(&left.children, mid + 1)
	return
}


// insert_upward inserts the separator `key` and sibling `right` into the
// parents recorded in `path`, splitting full internals as needed. If the
// ascent reaches past the old root, a new root is allocated.
insert_upward :: proc(
	t: ^$T/Tree($K, $V, $N),
	path: []Path_Entry(K, V, N),
	left, right: ^Node(K, V, N),
	key: K,
) {
	promote := key
	l, r := left, right

	for i := builtin.len(path) - 1; i >= 0; i -= 1 {
		parent_node := path[i].node
		parent := &parent_node.(Internal(K, V, N))
		idx := path[i].index

		assert(small_array.inject_at(&parent.keys, promote, idx))
		assert(small_array.inject_at(&parent.children, r, idx + 1))

		if small_array.len(parent.keys) < N {
			return
		}

		l = parent_node
		r, promote = split_internal(parent_node)
	}

	// split the root
	new_root := new(Node(K, V, N))
	new_root^ = Internal(K, V, N){}
	root := &new_root.(Internal(K, V, N))
	small_array.push(&root.keys, promote)
	small_array.push(&root.children, l, r)
	t.root = new_root
}

// remove_upward repairs underflow along `path` from the leaf's parent toward the root.
// At each level: borrow from a sibling if possible; otherwise merge. If the ascent
// empties the root of keys, shrink_root collapses it to its sole child.
remove_upward :: proc(t: ^$T/Tree($K, $V, $N), path: []Path_Entry(K, V, N)) {
	min_keys := N / 2

	for i := builtin.len(path) - 1; i >= 0; i -= 1 {
		parent_node := path[i].node
		parent := &parent_node.(Internal(K, V, N))
		idx := path[i].index

		// try borrow
		if try_borrow(parent, idx) do return

		merge_with_sibling(parent, idx)

		if i == 0 do break // falls through to shrink root

		// check if parent is in valid shape.
		if small_array.len(parent.keys) >= min_keys do return
	}

	shrink_root(t)
}

try_borrow :: proc(parent: ^Internal($K, $V, $N), idx: int) -> bool {
	child := small_array.get(parent.children, idx)
	switch child^ {
	case Leaf(K, V, N):
		return try_borrow_leaf(parent, idx)
	case Internal(K, V, N):
		return try_borrow_internal(parent, idx)
	}
	return false
}

try_borrow_leaf :: proc(parent: ^Internal($K, $V, $N), idx: int) -> bool {
	min_keys := N / 2
	curr := &small_array.get(parent.children, idx).(Leaf(K, V, N))

	// right sibling
	if idx + 1 < small_array.len(parent.children) {
		right_node := small_array.get(parent.children, idx + 1)
		right := &right_node.(Leaf(K, V, N))
		if small_array.len(right.keys) > min_keys {
			// take right's first / smallest entry
			assert(small_array.push(&curr.keys, small_array.get(right.keys, 0)))
			assert(small_array.push(&curr.values, small_array.get(right.values, 0)))

			small_array.ordered_remove(&right.keys, 0)
			small_array.ordered_remove(&right.values, 0)

			// update parent separator
			small_array.set(&parent.keys, idx, small_array.get(right.keys, 0))
			return true
		}
	}

	if idx > 0 {
		left_node := small_array.get(parent.children, idx - 1)
		left := &left_node.(Leaf(K, V, N))
		if small_array.len(left.keys) > min_keys {
			k := small_array.pop_back(&left.keys)
			v := small_array.pop_back(&left.values)
			assert(small_array.push_front(&curr.keys, k))
			assert(small_array.push_front(&curr.values, v))

			// update parent separator
			small_array.set(&parent.keys, idx - 1, k)
			return true
		}
	}

	return false
}

try_borrow_internal :: proc(parent: ^Internal($K, $V, $N), idx: int) -> bool {
	min_keys := N / 2
	curr := &small_array.get(parent.children, idx).(Internal(K, V, N))

	// right sibling
	if idx + 1 < small_array.len(parent.children) {
		right_node := small_array.get(parent.children, idx + 1)
		right := &right_node.(Internal(K, V, N))
		// check if sibling has extra key
		if small_array.len(right.keys) > min_keys {
			assert(small_array.push(&curr.keys, small_array.get(parent.keys, idx)))
			assert(small_array.push(&curr.children, small_array.get(right.children, 0)))

			// right's first key up into parent
			small_array.set(&parent.keys, idx, small_array.get(right.keys, 0))
			small_array.ordered_remove(&right.keys, 0)
			small_array.ordered_remove(&right.children, 0)
			return true
		}
	}

	// left sibling
	if idx > 0 {
		left_node := small_array.get(parent.children, idx - 1)
		left := &left_node.(Internal(K, V, N))
		if small_array.len(left.keys) > min_keys {
			sep := small_array.get(parent.keys, idx - 1)
			up := small_array.pop_back(&left.keys)
			child := small_array.pop_back(&left.children)

			assert(small_array.push_front(&curr.keys, sep))
			assert(small_array.push_front(&curr.children, child))
			small_array.set(&parent.keys, idx - 1, up)
			return true
		}
	}

	return false
}

// shrink_root replaces an internal root that has no keys (one child) with that child.
shrink_root :: proc(t: ^$T/Tree($K, $V, $N)) {
	#partial switch &n in t.root^ {
	case Internal(K, V, N):
		if small_array.len(n.keys) == 0 {
			assert(small_array.len(n.children) == 1)
			only := small_array.get(n.children, 0)
			old := t.root
			t.root = only
			free(old)
		}
	}
}

merge_with_sibling :: proc(parent: ^Internal($K, $V, $N), idx: int) {
	if idx > 0 {
		merge_children(parent, idx - 1, idx)
	} else {
		merge_children(parent, idx, idx + 1)
	}
}

merge_children :: proc(parent: ^Internal($K, $V, $N), left_idx, right_idx: int) {
	assert(right_idx == left_idx + 1)
	left_node := small_array.get(parent.children, left_idx)
	right_node := small_array.get(parent.children, right_idx)

	switch &left in left_node^ {
	case Leaf(K, V, N):
		right := &right_node.(Leaf(K, V, N))
		for i in 0 ..< small_array.len(right.keys) {
			assert(small_array.push(&left.keys, small_array.get(right.keys, i)))
			assert(small_array.push(&left.values, small_array.get(right.values, i)))
		}

		left.next = right.next

	case Internal(K, V, N):
		right := &right_node.(Internal(K, V, N))
		// the parent's separator/pointer comes down into the left node
		assert(small_array.push(&left.keys, small_array.get(parent.keys, left_idx)))
		for i in 0 ..< small_array.len(right.keys) {
			assert(small_array.push(&left.keys, small_array.get(right.keys, i)))
		}

		for i in 0 ..< small_array.len(right.children) {
			assert(small_array.push(&left.children, small_array.get(right.children, i)))
		}
	}

	small_array.ordered_remove(&parent.keys, left_idx)
	small_array.ordered_remove(&parent.children, right_idx)
	free(right_node)
}

// destroy_node recursively frees `n` and its descendants.
destroy_node :: proc(n: ^Node($K, $V, $N)) {
	if n == nil {
		return
	}

	switch &v in n^ {
	case Internal(K, V, N):
		for i in 0 ..< small_array.len(v.children) {
			destroy_node(small_array.get(v.children, i))
		}
	case Leaf(K, V, N):

	}

	free(n)
}

// print_node recursively prints the subtree at `n` as an ASCII tree.
print_node :: proc(n: ^Node($K, $V, $N), prefix: string, is_last: bool) {
	branch := is_last ? "└── " : "├── "
	switch &v in n^ {
	case Leaf(K, V, N):
		fmt.printf(
			"%s%sleaf keys=%v values=%v\n",
			prefix,
			branch,
			small_array.slice(&v.keys),
			small_array.slice(&v.values),
		)
	case Internal(K, V, N):
		fmt.printf("%s%sinternal keys=%v\n", prefix, branch, small_array.slice(&v.keys))
		child_prefix := is_last ? prefix + "    " : prefix + "│   "
		count := small_array.len(v.children)
		for i in 0 ..< count {
			print_node(small_array.get(v.children, i), child_prefix, i == count - 1)
		}
	}
}
