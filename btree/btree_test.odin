package btree

import "base:builtin"
import "core:container/small_array"
import "core:fmt"
import "core:slice"
import "core:testing"

ORDER :: 3

is_internal :: proc(n: ^Node($K, $V, $N)) -> bool {
	_, ok := n^.(Internal(K, V, N))
	return ok
}

is_leaf :: proc(n: ^Node($K, $V, $N)) -> bool {
	_, ok := n^.(Leaf(K, V, N))
	return ok
}

@(test)
test_init_empty :: proc(t: ^testing.T) {
	tree: Tree(int, string, ORDER)
	init(&tree)
	defer destroy(&tree)

	testing.expect(t, tree.root != nil, "root should be allocated")
	testing.expect(t, is_leaf(tree.root), "fresh tree root should be a leaf")
	testing.expect_value(t, len(&tree), 0)

	_, ok := get(&tree, 1)
	testing.expect(t, !ok, "get on empty tree should miss")
}

@(test)
test_destroy_nil_root :: proc(t: ^testing.T) {
	tree: Tree(int, string, ORDER)
	destroy(&tree) // should be a no-op
	testing.expect(t, tree.root == nil)
}

@(test)
test_single_insert_and_get :: proc(t: ^testing.T) {
	tree: Tree(int, string, ORDER)
	init(&tree)
	defer destroy(&tree)

	insert(&tree, 42, "answer")
	testing.expect_value(t, len(&tree), 1)
	testing.expect(t, is_leaf(tree.root), "single insert should keep a leaf root")

	v, ok := get(&tree, 42)
	testing.expect(t, ok)
	testing.expect_value(t, v, "answer")

	_, miss := get(&tree, 7)
	testing.expect(t, !miss)
}

@(test)
test_update_existing_key :: proc(t: ^testing.T) {
	tree: Tree(int, string, ORDER)
	init(&tree)
	defer destroy(&tree)

	insert(&tree, 1, "one")
	insert(&tree, 1, "uno")

	testing.expect_value(t, len(&tree), 1)
	v, ok := get(&tree, 1)
	testing.expect(t, ok)
	testing.expect_value(t, v, "uno")
}

@(test)
test_insert_until_leaf_splits :: proc(t: ^testing.T) {
	tree: Tree(int, string, ORDER)
	init(&tree)
	defer destroy(&tree)

	// ORDER keys fit in one leaf; the ORDER-th insert triggers a split.
	insert(&tree, 1, "a")
	insert(&tree, 2, "b")
	testing.expect(t, is_leaf(tree.root), "root should still be a leaf before capacity is hit")

	insert(&tree, 3, "c")
	testing.expect(t, is_internal(tree.root), "root should split into an internal node")
	testing.expect_value(t, len(&tree), 3)

	v1, ok1 := get(&tree, 1)
	testing.expect(t, ok1)
	testing.expect_value(t, v1, "a")
	v2, ok2 := get(&tree, 2)
	testing.expect(t, ok2)
	testing.expect_value(t, v2, "b")
	v3, ok3 := get(&tree, 3)
	testing.expect(t, ok3)
	testing.expect_value(t, v3, "c")
}

@(test)
test_sequential_insertion :: proc(t: ^testing.T) {
	tree: Tree(int, string, ORDER)
	init(&tree)
	defer destroy(&tree)

	for i in 1 ..= 15 {
		insert(&tree, i, fmt.tprintf("val-%d", i))
	}

	testing.expect(t, tree.root != nil, "tree root is nil after insertion")
	testing.expect(
		t,
		is_internal(tree.root),
		"root should be internal after capacity was exceeded",
	)
	testing.expect_value(t, len(&tree), 15)

	for i in 1 ..= 15 {
		v, ok := get(&tree, i)
		testing.expectf(t, ok, "missing key %d", i)
		testing.expect_value(t, v, fmt.tprintf("val-%d", i))
	}
}

@(test)
test_reverse_insertion :: proc(t: ^testing.T) {
	tree: Tree(int, int, ORDER)
	init(&tree)
	defer destroy(&tree)

	for i := 20; i >= 1; i -= 1 {
		insert(&tree, i, i * 10)
	}

	testing.expect_value(t, len(&tree), 20)
	for i in 1 ..= 20 {
		v, ok := get(&tree, i)
		testing.expectf(t, ok, "missing key %d", i)
		testing.expect_value(t, v, i * 10)
	}
}

@(test)
test_shuffled_insertion :: proc(t: ^testing.T) {
	tree: Tree(int, int, ORDER)
	init(&tree)
	defer destroy(&tree)

	keys := []int{5, 1, 9, 3, 7, 2, 8, 4, 6, 0, 10}
	for k in keys {
		insert(&tree, k, k)
	}

	testing.expect_value(t, len(&tree), builtin.len(keys))
	for k in keys {
		v, ok := get(&tree, k)
		testing.expectf(t, ok, "missing key %d", k)
		testing.expect_value(t, v, k)
	}
}

@(test)
test_iterate_leaf_in_order :: proc(t: ^testing.T) {
	tree: Tree(int, string, ORDER)
	init(&tree)
	defer destroy(&tree)

	input := []int{4, 1, 3, 2, 8, 5, 7, 6}
	for k in input {
		insert(&tree, k, fmt.tprintf("v%d", k))
	}

	got_keys := make([dynamic]int, context.temp_allocator)
	got_vals := make([dynamic]string, context.temp_allocator)

	State :: struct {
		keys:   ^[dynamic]int,
		values: ^[dynamic]string,
	}
	state := State{&got_keys, &got_vals}

	context.user_ptr = &state
	iterate_leaf(&tree, proc(key: int, value: string) -> bool {
		state := cast(^State)context.user_ptr
		append(state.keys, key)
		append(state.values, value)
		return true
	})

	testing.expect_value(t, builtin.len(got_keys), builtin.len(input))
	for i in 0 ..< builtin.len(got_keys) {
		testing.expect_value(t, got_keys[i], i + 1)
		testing.expect_value(t, got_vals[i], fmt.tprintf("v%d", i + 1))
	}
}

@(test)
test_iterate_leaf_early_stop :: proc(t: ^testing.T) {
	tree: Tree(int, int, ORDER)
	init(&tree)
	defer destroy(&tree)

	for i in 1 ..= 10 {
		insert(&tree, i, i)
	}

	count := 0
	context.user_ptr = &count
	iterate_leaf(&tree, proc(key: int, value: int) -> bool {
		c := cast(^int)context.user_ptr
		c^ += 1
		_ = key
		_ = value
		return c^ < 3
	})

	testing.expect_value(t, count, 3)
}

@(test)
test_update_after_splits :: proc(t: ^testing.T) {
	tree: Tree(int, string, ORDER)
	init(&tree)
	defer destroy(&tree)

	for i in 1 ..= 12 {
		insert(&tree, i, "old")
	}
	for i in 1 ..= 12 {
		insert(&tree, i, "new")
	}

	testing.expect_value(t, len(&tree), 12)
	for i in 1 ..= 12 {
		v, ok := get(&tree, i)
		testing.expect(t, ok)
		testing.expect_value(t, v, "new")
	}
}

@(test)
test_leaf_sibling_chain_covers_all_keys :: proc(t: ^testing.T) {
	tree: Tree(int, int, ORDER)
	init(&tree)
	defer destroy(&tree)

	for i in 1 ..= 25 {
		insert(&tree, i, i)
	}

	seen := 0
	curr := leftmost(tree.root)
	for curr != nil {
		leaf := &curr.(Leaf(int, int, ORDER))
		seen += small_array.len(leaf.keys)

		// keys within a leaf are sorted
		keys := small_array.slice(&leaf.keys)
		testing.expect(t, slice.is_sorted(keys), "leaf keys should be sorted")

		curr = leaf.next
	}

	testing.expect_value(t, seen, 25)
	testing.expect_value(t, seen, len(&tree))
}
