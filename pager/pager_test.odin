package pager

import "core:mem"
import "core:os"
import "core:testing"

setup_tracking_allocator :: proc() -> mem.Tracking_Allocator {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	return track
}

check_leaks :: proc(t: ^testing.T, track: ^mem.Tracking_Allocator) {

	defer mem.tracking_allocator_destroy(track)

	testing.expectf(
		t,
		len(track.allocation_map) == 0,
		"Memory leak detected: %v allocations not freed",
		len(track.allocation_map),
	)

	for _, entry in track.allocation_map {
		testing.expectf(t, false, "- %v bytes leaked at %v", entry.size, entry.location)
	}
}

@(test)
test_pager_create_and_close :: proc(t: ^testing.T) {
	track := setup_tracking_allocator()
	context.allocator = mem.tracking_allocator(&track)
	defer check_leaks(t, &track)

	filename := "test_db_empty.db"
	_ = os.remove(filename)
	defer os.remove(filename)

	pager, ok := pager_open(filename)
	testing.expect(t, ok, "Pager should open successfully.")
	testing.expect(t, pager != nil, "Pager pointer should not be nil.")
	testing.expect_value(t, pager.num_pages, u32(0))

	pager_close(pager)
}

@(test)
test_pager_read_write_persistence :: proc(t: ^testing.T) {
	track := setup_tracking_allocator()
	context.allocator = mem.tracking_allocator(&track)
	defer check_leaks(t, &track)

	filename := "test_db_persistence.db"
	_ = os.remove(filename)
	defer os.remove(filename)

	pager, ok := pager_open(filename)
	testing.expect(t, ok, "Failed to open pager")

	page0, ok0 := get_page(pager, Page_ID(0))
	testing.expect(t, ok0, "Failed to get Page 0")

	page0.data[0] = 42
	page0.data[100] = 255
	page0.data[PAGE_SIZE - 1] = 99

	pager_close(pager)

	pager_read, ok_read := pager_open(filename)
	testing.expect(t, ok_read, "Failed to re-open pager")
	testing.expect_value(t, pager_read.num_pages, u32(1))


	page0_read, ok0_read := get_page(pager_read, Page_ID(0))
	testing.expect(t, ok0_read, "Failed to read Page 0 from disk")

	testing.expect_value(t, page0_read.data[0], u8(42))
	testing.expect_value(t, page0_read.data[100], u8(255))
	testing.expect_value(t, page0_read.data[PAGE_SIZE - 1], u8(99))

	pager_close(pager_read)
}

@(test)
test_pager_out_of_bounds_flush :: proc(t: ^testing.T) {
	track := setup_tracking_allocator()
	context.allocator = mem.tracking_allocator(&track)
	defer check_leaks(t, &track)
	filename := "test_db_bounds.db"
	_ = os.remove(filename)
	defer os.remove(filename)
	pager, ok := pager_open(filename)
	testing.expect(t, ok)
	ok_flush := pager_flush(pager, Page_ID(999))
	testing.expect(t, !ok_flush, "Flushing an unallocated page should return false")
	pager_close(pager)
}
