package pager

PAGE_SIZE :: 4096

Page_ID :: distinct u32

Page :: struct {
	id:   Page_ID,
	data: [PAGE_SIZE]u8,
}
