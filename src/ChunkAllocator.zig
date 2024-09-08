const std = @import("std");
const trampoline_buffer_size = @import("hooks.zig").trampoline_buffer_size;
const Allocator = @This();

const mem = @import("mem.zig");

pub const Chunk = [trampoline_buffer_size]u8;
pub const ReserveChunkError = error{OutOfChunks};
pub const AllocBlockError = mem.MapError || error{UnavailableNearbyPage} || mem.QueryError || std.posix.MProtectError;
pub const Error = ReserveChunkError || AllocBlockError;
/// type erased implementation
ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    alloc: *const fn (ctx: *anyopaque, origin: usize) Error!*Chunk,
    free: *const fn (ctx: *anyopaque, ptr: *const Chunk) void,
};

pub fn alloc(self: Allocator, origin: usize) Error!*Chunk {
    return self.vtable.alloc(self.ptr, origin);
}

pub fn free(self: Allocator, ptr: *const Chunk) void {
    self.vtable.free(self.ptr, ptr);
}
