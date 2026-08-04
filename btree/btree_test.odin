package btree

import "../pager"
import "base:builtin"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"

ORDER :: 3

open_tree_int_string :: proc(
	t: ^testing.T,
	filename: string,
) -> (
	p: ^pager.Pager,
	tree: Tree(int, string, ORDER),
) {
	_ = os.remove(filename)
	ok: bool
	p, ok = pager.pager_open(filename)
	testing.expect(t, ok, "pager_open failed")
	init(&tree, p)
	return
}

open_tree_int_int :: proc(
	t: ^testing.T,
	filename: string,
) -> (
	p: ^pager.Pager,
	tree: Tree(int, int, ORDER),
) {
	_ = os.remove(filename)
	ok: bool
	p, ok = pager.pager_open(filename)
	testing.expect(t, ok, "pager_open failed")
	init(&tree, p)
	return
}

close_tree :: proc(p: ^pager.Pager, filename: string) {
	pager.pager_close(p)
	_ = os.remove(filename)
}

@(test)
test_init_empty :: proc(t: ^testing.T) {
	filename := "test_btree_init_empty.db"
	p, tree := open_tree_int_string(t, filename)
	defer close_tree(p, filename)
	defer destroy(&tree)

	testing.expect(t, tree.root_page != INVALID_PAGE_ID, "root should be allocated")
	testing.expect(t, root_is_leaf(&tree), "fresh tree root should be a leaf")
	testing.expect_value(t, len(&tree), 0)

	_, ok := get(&tree, 1)
	testing.expect(t, !ok, "get on empty tree should miss")
}

@(test)
test_destroy_clears_tree :: proc(t: ^testing.T) {
	tree: Tree(int, string, ORDER)
	destroy(&tree) // no-op on zero value
	testing.expect(t, tree.p == nil)
	testing.expect_value(t, tree.root_page, pager.Page_ID(0))
}

@(test)
test_single_insert_and_get :: proc(t: ^testing.T) {
	filename := "test_btree_single.db"
	p, tree := open_tree_int_string(t, filename)
	defer close_tree(p, filename)
	defer destroy(&tree)

	insert(&tree, 42, "answer")
	testing.expect_value(t, len(&tree), 1)
	testing.expect(t, root_is_leaf(&tree), "single insert should keep a leaf root")

	v, ok := get(&tree, 42)
	testing.expect(t, ok)
	testing.expect_value(t, v, "answer")

	_, miss := get(&tree, 7)
	testing.expect(t, !miss)
}

@(test)
test_update_existing_key :: proc(t: ^testing.T) {
	filename := "test_btree_update.db"
	p, tree := open_tree_int_string(t, filename)
	defer close_tree(p, filename)
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
	filename := "test_btree_split.db"
	p, tree := open_tree_int_string(t, filename)
	defer close_tree(p, filename)
	defer destroy(&tree)

	insert(&tree, 1, "a")
	insert(&tree, 2, "b")
	testing.expect(t, root_is_leaf(&tree), "root should still be a leaf before capacity is hit")

	insert(&tree, 3, "c")
	testing.expect(t, root_is_internal(&tree), "root should split into an internal node")
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
	filename := "test_btree_seq.db"
	p, tree := open_tree_int_string(t, filename)
	defer close_tree(p, filename)
	defer destroy(&tree)

	for i in 1 ..= 15 {
		insert(&tree, i, fmt.tprintf("val-%d", i))
	}

	testing.expect(t, tree.root_page != INVALID_PAGE_ID)
	testing.expect(t, root_is_internal(&tree), "root should be internal after capacity was exceeded")
	testing.expect_value(t, len(&tree), 15)

	for i in 1 ..= 15 {
		v, ok := get(&tree, i)
		testing.expectf(t, ok, "missing key %d", i)
		testing.expect_value(t, v, fmt.tprintf("val-%d", i))
	}
}

@(test)
test_reverse_insertion :: proc(t: ^testing.T) {
	filename := "test_btree_rev.db"
	p, tree := open_tree_int_int(t, filename)
	defer close_tree(p, filename)
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
	filename := "test_btree_shuf.db"
	p, tree := open_tree_int_int(t, filename)
	defer close_tree(p, filename)
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
	filename := "test_btree_iter.db"
	p, tree := open_tree_int_string(t, filename)
	defer close_tree(p, filename)
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
	filename := "test_btree_iter_stop.db"
	p, tree := open_tree_int_int(t, filename)
	defer close_tree(p, filename)
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
	filename := "test_btree_update_split.db"
	p, tree := open_tree_int_string(t, filename)
	defer close_tree(p, filename)
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
	filename := "test_btree_chain.db"
	p, tree := open_tree_int_int(t, filename)
	defer close_tree(p, filename)
	defer destroy(&tree)

	for i in 1 ..= 25 {
		insert(&tree, i, i)
	}

	seen := 0
	curr := leftmost(&tree)
	for curr != INVALID_PAGE_ID {
		page, ok := pager.get_page(tree.p, curr)
		testing.expect(t, ok)
		keys := get_leaf_keys_slice(page, int)
		seen += builtin.len(keys)
		testing.expect(t, slice.is_sorted(keys), "leaf keys should be sorted")
		curr = get_leaf_next_leaf(page)
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
		_, ok := get(tree, want[i])
		testing.expectf(t, ok, "missing key %v after mutation", want[i])
	}
}

@(test)
test_remove_missing_key :: proc(t: ^testing.T) {
	filename := "test_btree_rm_miss.db"
	p, tree := open_tree_int_string(t, filename)
	defer close_tree(p, filename)
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
	filename := "test_btree_rm_leaf.db"
	p, tree := open_tree_int_string(t, filename)
	defer close_tree(p, filename)
	defer destroy(&tree)

	insert(&tree, 1, "a")
	insert(&tree, 2, "b")
	testing.expect(t, root_is_leaf(&tree))

	ok := remove(&tree, 1)
	testing.expect(t, ok)
	testing.expect_value(t, len(&tree), 1)
	testing.expect(t, root_is_leaf(&tree), "root should remain a leaf")
	expect_keys(t, &tree, []int{2})

	ok = remove(&tree, 2)
	testing.expect(t, ok)
	testing.expect_value(t, len(&tree), 0)
	testing.expect(t, root_is_leaf(&tree), "empty tree keeps a leaf root")
	_, found := get(&tree, 2)
	testing.expect(t, !found)
}

@(test)
test_remove_without_underflow :: proc(t: ^testing.T) {
	filename := "test_btree_rm_nounder.db"
	p, tree := open_tree_int_string(t, filename)
	defer close_tree(p, filename)
	defer destroy(&tree)

	insert(&tree, 1, "a")
	insert(&tree, 2, "b")
	insert(&tree, 3, "c")
	testing.expect(t, root_is_internal(&tree))

	ok := remove(&tree, 3)
	testing.expect(t, ok)
	testing.expect(t, root_is_internal(&tree), "no merge/borrow needed; height unchanged")
	expect_keys(t, &tree, []int{1, 2})
}

@(test)
test_remove_leaf_borrow_from_right :: proc(t: ^testing.T) {
	filename := "test_btree_rm_borrow_r.db"
	p, tree := open_tree_int_int(t, filename)
	defer close_tree(p, filename)
	defer destroy(&tree)

	insert(&tree, 1, 1)
	insert(&tree, 2, 2)
	insert(&tree, 3, 3)

	ok := remove(&tree, 1)
	testing.expect(t, ok)
	testing.expect(t, root_is_internal(&tree), "borrow should not shrink height")
	expect_keys(t, &tree, []int{2, 3})
}

@(test)
test_remove_leaf_borrow_from_left :: proc(t: ^testing.T) {
	filename := "test_btree_rm_borrow_l.db"
	p, tree := open_tree_int_int(t, filename)
	defer close_tree(p, filename)
	defer destroy(&tree)

	insert(&tree, 1, 1)
	insert(&tree, 2, 2)
	insert(&tree, 3, 3)
	insert(&tree, 4, 4)

	ok := remove(&tree, 4)
	testing.expect(t, ok)
	expect_keys(t, &tree, []int{1, 2, 3})

	insert(&tree, 4, 4)
	insert(&tree, 5, 5)
	ok = remove(&tree, 5)
	testing.expect(t, ok)
	for k in ([]int{1, 2, 3, 4}) {
		_, found := get(&tree, k)
		testing.expectf(t, found, "missing key %d", k)
	}
	testing.expect_value(t, len(&tree), 4)
}

@(test)
test_remove_leaf_merge_and_shrink_root :: proc(t: ^testing.T) {
	filename := "test_btree_rm_merge.db"
	p, tree := open_tree_int_string(t, filename)
	defer close_tree(p, filename)
	defer destroy(&tree)

	insert(&tree, 1, "a")
	insert(&tree, 2, "b")
	insert(&tree, 3, "c")
	testing.expect(t, root_is_internal(&tree))

	testing.expect(t, remove(&tree, 3))
	testing.expect(t, remove(&tree, 1))
	testing.expect(t, root_is_leaf(&tree), "merged sole child should become the new root")
	expect_keys(t, &tree, []int{2})
}

@(test)
test_remove_all_sequential :: proc(t: ^testing.T) {
	filename := "test_btree_rm_all_seq.db"
	p, tree := open_tree_int_int(t, filename)
	defer close_tree(p, filename)
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
	testing.expect(t, root_is_leaf(&tree), "empty tree should finish as a leaf root")
}

@(test)
test_remove_all_reverse :: proc(t: ^testing.T) {
	filename := "test_btree_rm_all_rev.db"
	p, tree := open_tree_int_int(t, filename)
	defer close_tree(p, filename)
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
	filename := "test_btree_rm_shuf.db"
	p, tree := open_tree_int_int(t, filename)
	defer close_tree(p, filename)
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
	filename := "test_btree_rm_reins.db"
	p, tree := open_tree_int_string(t, filename)
	defer close_tree(p, filename)
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
	filename := "test_btree_rm_chain.db"
	p, tree := open_tree_int_int(t, filename)
	defer close_tree(p, filename)
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

	curr := leftmost(&tree)
	prev_max := min(int)
	for curr != INVALID_PAGE_ID {
		page, ok := pager.get_page(tree.p, curr)
		testing.expect(t, ok)
		keys := get_leaf_keys_slice(page, int)
		testing.expect(t, slice.is_sorted(keys))
		if builtin.len(keys) > 0 {
			testing.expect(t, keys[0] > prev_max, "leaf chain should be globally increasing")
			prev_max = keys[builtin.len(keys) - 1]
		}
		curr = get_leaf_next_leaf(page)
	}
}
