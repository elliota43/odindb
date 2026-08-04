package pager

import "core:os"

PAGE_SIZE :: 4096

Page_ID :: distinct u32

Page :: struct {
	id:   Page_ID,
	data: [PAGE_SIZE]u8,
}

Pager :: struct {
	file:      ^os.File,
	num_pages: u32,
	pages:     [dynamic]^Page,
}

// pager_open opens the database file (or creates it if it doesn't exist), creates
// the `Pager` struct, initializes the dynamic `^Page` array, and calculates the number
// of pages.
// Note: As of the design right now, the page number should always be a cleanly divisible
// integer based on the file size / `PAGE_SIZE`.
pager_open :: proc(filename: string, allocator := context.allocator) -> (pager: ^Pager, ok: bool) {
	context.allocator = allocator

	pager = new(Pager)

	f, oerr := os.open(
		filename,
		{.Read, .Create, .Write},
		{.Read_User, .Write_User, .Read_Other, .Write_Other},
	)
	if oerr != nil {
		return nil, false
	}

	pager.file = f

	file_size, serr := os.seek(f, 0, .End)
	if serr != nil {
		return nil, false
	}

	num_pages := file_size / PAGE_SIZE
	pager.pages = make([dynamic]^Page, num_pages)

	// NOTE: casting i64->u32 here
	pager.num_pages = u32(num_pages)

	return pager, true
}

get_page :: proc(
	pager: ^Pager,
	id: Page_ID,
	allocator := context.allocator,
) -> (
	page: ^Page,
	ok: bool,
) {
	context.allocator = allocator

	idx := int(id)

	if idx >= len(pager.pages) {
		resize(&pager.pages, idx + 1)
	}

	if pager.pages[idx] != nil {
		return pager.pages[idx], true
	}

	new_page := new(Page)
	new_page.id = id

	// if the page exists on disk, read. otherwise, just add the page
	// to the cache and return it.

	if u32(idx) < pager.num_pages {
		n, rerr := os.read_at(pager.file, new_page.data[:], i64(idx * PAGE_SIZE))
		if rerr != nil {
			free(new_page)
			return nil, false
		}
	}


	pager.pages[idx] = new_page

	return new_page, true
}

// pager_flush flushes the page specified by `id` to disk.
// TODO: it does not sync currently.
pager_flush :: proc(pager: ^Pager, id: Page_ID) -> (ok: bool) {
	idx := int(id)

	if idx >= len(pager.pages) {
		return false
	}

	page := pager.pages[idx]

	if page == nil {
		return false
	}

	n, werr := os.write_at(pager.file, page.data[:], i64(idx * PAGE_SIZE))
	if werr != nil {
		return false
	}

	return true
}

// pager_close cleans up `pager`'s page data, closes the file and free's `pager` itself.
pager_close :: proc(pager: ^Pager) {

	for &page, i in pager.pages {
		if page != nil {
			pager_flush(pager, Page_ID(i))
			free(page)
		}
	}

	delete(pager.pages)
	os.close(pager.file)
	free(pager)
}
