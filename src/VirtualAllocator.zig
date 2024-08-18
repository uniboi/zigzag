const std = @import("std");
pub const Error = error{};

// The type erased pointer to the allocator implementation
ptr: ?*anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    alloc: *const fn (ctx: *anyopaque, hint: [*]align(std.mem.page_size) u8, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8,
    free: *const fn (ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void,
};
