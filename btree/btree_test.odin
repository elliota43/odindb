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

expect_keys :: proc(t: ^testing.T, tree: ^Tree($K, $V, $N), want: []K) {
	got := make([dynamic]K, context.temp_allocator)
	context.user_ptr = &got
	iterate_leaf(tree, proc(key: K, value: V) -> bool {
		keys := cast(^[dynamic]K)context.user_ptr
		append(keys, key)
		_ = value
		return true
	})

	testing.expect_value(t, builtin.len(got), builtin.len(want))
	testing.expect_value(t, len(tree), builtin.len(want))
	for i in 0 ..< builtin.len(want) {
		testing.expectf(t, i < builtin.len(got), "missing iterated key at %d", i)
		if i < builtin.len(got) {
			testing.expect_value(t, got[i], want[i])
		}
		v, ok := get(tree, want[i])
		testing.expectf(t, ok, "missing key %v after mutation", want[i])
		_ = v
	}
}

@(test)
test_remove_missing_key :: proc(t: ^testing.T) {
	tree: Tree(int, string, ORDER)
	init(&tree)
	defer destroy(&tree)

	insert(&tree, 1, "a")
	ok := remove(&tree, 99)
	testing.expect(t, !ok)
	testing.expect_value(t, len(&tree), 1)
	v, found := get(&tree, 1)
	testing.expect(t, found)
	testing.expect_value(t, v, "a")
}

@(test)
test_remove_from_leaf_root :: proc(t: ^testing.T) {
	tree: Tree(int, string, ORDER)
	init(&tree)
	defer destroy(&tree)

	insert(&tree, 1, "a")
	insert(&tree, 2, "b")
	testing.expect(t, is_leaf(tree.root))

	ok := remove(&tree, 1)
	testing.expect(t, ok)
	testing.expect_value(t, len(&tree), 1)
	testing.expect(t, is_leaf(tree.root), "root should remain a leaf")
	expect_keys(t, &tree, []int{2})

	ok = remove(&tree, 2)
	testing.expect(t, ok)
	testing.expect_value(t, len(&tree), 0)
	testing.expect(t, is_leaf(tree.root), "empty tree keeps a leaf root")
	_, found := get(&tree, 2)
	testing.expect(t, !found)
}

@(test)
test_remove_without_underflow :: proc(t: ^testing.T) {
	tree: Tree(int, string, ORDER)
	init(&tree)
	defer destroy(&tree)

	// 1,2,3 splits into leaves [1] | [2,3]; removing 3 leaves right with 1 key (min).
	insert(&tree, 1, "a")
	insert(&tree, 2, "b")
	insert(&tree, 3, "c")
	testing.expect(t, is_internal(tree.root))

	ok := remove(&tree, 3)
	testing.expect(t, ok)
	testing.expect(t, is_internal(tree.root), "no merge/borrow needed; height unchanged")
	expect_keys(t, &tree, []int{1, 2})
}

@(test)
test_remove_leaf_borrow_from_right :: proc(t: ^testing.T) {
	tree: Tree(int, int, ORDER)
	init(&tree)
	defer destroy(&tree)

	// After split: left [1], right [2,3]. Removing 1 underflows left; right can donate 2.
	insert(&tree, 1, 1)
	insert(&tree, 2, 2)
	insert(&tree, 3, 3)

	ok := remove(&tree, 1)
	testing.expect(t, ok)
	testing.expect(t, is_internal(tree.root), "borrow should not shrink height")
	expect_keys(t, &tree, []int{2, 3})
}

@(test)
test_remove_leaf_borrow_from_left :: proc(t: ^testing.T) {
	tree: Tree(int, int, ORDER)
	init(&tree)
	defer destroy(&tree)

	// Build [1,2] | [3] by inserting then deleting from the right until right is minimal,
	// then give left spare keys and underflow the right leaf.
	insert(&tree, 1, 1)
	insert(&tree, 2, 2)
	insert(&tree, 3, 3)
	insert(&tree, 4, 4)
	// Typical shape after 4 inserts with ORDER=3 still has spare on some sibling.
	// Delete from a right-side leaf that can borrow leftward.
	ok := remove(&tree, 4)
	testing.expect(t, ok)
	expect_keys(t, &tree, []int{1, 2, 3})

	// Force rightmost underflow after left has > min keys.
	// Re-insert to create left-heavy siblings, then remove from the right leaf.
	insert(&tree, 4, 4)
	insert(&tree, 5, 5)
	ok = remove(&tree, 5)
	testing.expect(t, ok)
	// Removing a key that underflows a right leaf should leave all remaining keys findable.
	for k in ([]int{1, 2, 3, 4}) {
		_, found := get(&tree, k)
		testing.expectf(t, found, "missing key %d", k)
	}
	testing.expect_value(t, len(&tree), 4)
}

@(test)
test_remove_leaf_merge_and_shrink_root :: proc(t: ^testing.T) {
	tree: Tree(int, string, ORDER)
	init(&tree)
	defer destroy(&tree)

	insert(&tree, 1, "a")
	insert(&tree, 2, "b")
	insert(&tree, 3, "c")
	testing.expect(t, is_internal(tree.root))

	// left [1], right [2,3] → remove 3 → right [2]; both sides at min (1).
	testing.expect(t, remove(&tree, 3))
	// remove 1 → left empty, right at min → merge → root has one child → shrink to leaf.
	testing.expect(t, remove(&tree, 1))
	testing.expect(t, is_leaf(tree.root), "merged sole child should become the new root")
	expect_keys(t, &tree, []int{2})
}

@(test)
test_remove_all_sequential :: proc(t: ^testing.T) {
	tree: Tree(int, int, ORDER)
	init(&tree)
	defer destroy(&tree)

	n :: 20
	for i in 1 ..= n {
		insert(&tree, i, i)
	}
	testing.expect_value(t, len(&tree), n)

	for i in 1 ..= n {
		ok := remove(&tree, i)
		testing.expectf(t, ok, "failed to remove %d", i)
		testing.expect_value(t, len(&tree), n - i)
		_, found := get(&tree, i)
		testing.expectf(t, !found, "key %d should be gone", i)
		for j in i + 1 ..= n {
			v, okj := get(&tree, j)
			testing.expectf(t, okj, "key %d missing after removing %d", j, i)
			testing.expect_value(t, v, j)
		}
	}

	testing.expect_value(t, len(&tree), 0)
	testing.expect(t, is_leaf(tree.root), "empty tree should finish as a leaf root")
}

@(test)
test_remove_all_reverse :: proc(t: ^testing.T) {
	tree: Tree(int, int, ORDER)
	init(&tree)
	defer destroy(&tree)

	n :: 20
	for i in 1 ..= n {
		insert(&tree, i, i * 10)
	}

	for i := n; i >= 1; i -= 1 {
		ok := remove(&tree, i)
		testing.expectf(t, ok, "failed to remove %d", i)
		_, found := get(&tree, i)
		testing.expect(t, !found)
	}

	testing.expect_value(t, len(&tree), 0)
	expect_keys(t, &tree, []int{})
}

@(test)
test_remove_shuffled :: proc(t: ^testing.T) {
	tree: Tree(int, int, ORDER)
	init(&tree)
	defer destroy(&tree)

	keys := []int{5, 1, 9, 3, 7, 2, 8, 4, 6, 0, 10}
	for k in keys {
		insert(&tree, k, k)
	}

	order := []int{3, 10, 1, 7, 0, 5, 9, 2, 8, 4, 6}
	remaining := make(map[int]bool, context.temp_allocator)
	for k in keys {
		remaining[k] = true
	}

	for k in order {
		ok := remove(&tree, k)
		testing.expectf(t, ok, "failed to remove %d", k)
		delete_key(&remaining, k)
		testing.expect_value(t, len(&tree), builtin.len(remaining))

		_, gone := get(&tree, k)
		testing.expect(t, !gone)
		for rk in remaining {
			v, found := get(&tree, rk)
			testing.expectf(t, found, "missing remaining key %d after removing %d", rk, k)
			testing.expect_value(t, v, rk)
		}
	}

	testing.expect_value(t, len(&tree), 0)
}

@(test)
test_remove_then_reinsert :: proc(t: ^testing.T) {
	tree: Tree(int, string, ORDER)
	init(&tree)
	defer destroy(&tree)

	for i in 1 ..= 12 {
		insert(&tree, i, "old")
	}
	for i in 1 ..= 12 {
		testing.expect(t, remove(&tree, i))
	}
	testing.expect_value(t, len(&tree), 0)

	for i in 1 ..= 12 {
		insert(&tree, i, "new")
	}
	testing.expect_value(t, len(&tree), 12)
	for i in 1 ..= 12 {
		v, ok := get(&tree, i)
		testing.expect(t, ok)
		testing.expect_value(t, v, "new")
	}
	expect_keys(t, &tree, []int{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12})
}

@(test)
test_remove_preserves_leaf_chain_order :: proc(t: ^testing.T) {
	tree: Tree(int, int, ORDER)
	init(&tree)
	defer destroy(&tree)

	for i in 1 ..= 25 {
		insert(&tree, i, i)
	}
	for i := 1; i <= 25; i += 2 {
		testing.expect(t, remove(&tree, i))
	}

	want := make([dynamic]int, context.temp_allocator)
	for i := 2; i <= 25; i += 2 {
		append(&want, i)
	}
	expect_keys(t, &tree, want[:])

	curr := leftmost(tree.root)
	prev_max := min(int)
	for curr != nil {
		leaf := &curr.(Leaf(int, int, ORDER))
		keys := small_array.slice(&leaf.keys)
		testing.expect(t, slice.is_sorted(keys))
		if builtin.len(keys) > 0 {
			testing.expect(t, keys[0] > prev_max, "leaf chain should be globally increasing")
			prev_max = keys[builtin.len(keys) - 1]
		}
		curr = leaf.next
	}
}
