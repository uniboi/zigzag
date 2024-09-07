const std = @import("std");
const builtin = @import("builtin");
const ChunkAllocator = @import("ChunkAllocator.zig");
const Chunk = ChunkAllocator.Chunk;
const ReserveChunkError = ChunkAllocator.ReserveChunkError;
const AllocBlockError = ChunkAllocator.AllocBlockError;
const Error = ChunkAllocator.Error;

const SharedExecutableBlock = @import("SharedExecutableBlock.zig");

const Hook = @import("root.zig");
const trampoline_buffer_size = Hook.trampoline_buffer_size;
const getPages = Hook.getPages;

const Allocator = @This();
pub const memory_block_size = 0x1000;

first_block: ?*SharedExecutableBlock,

pub fn init() SharedExecutableBlock.CacheMinAddressError!Allocator {
    try SharedExecutableBlock.cacheMinAddressAndGranularity();
    return .{
        .first_block = null,
    };
}

fn alloc(ctx: *anyopaque, origin: usize) Error!*Chunk {
    // TODO: refactor distance calculations everywhere in this file
    const max_distance = std.math.maxInt(i32);
    const self: *Allocator = @ptrCast(@alignCast(ctx));

    var current_block = self.first_block;
    while (current_block) |block| : (current_block = block.head.next) {
        const block_address = @intFromPtr(block);
        if ((block_address < origin) and (origin - block_address <= max_distance)) {
            return block.reserveChunk() catch continue;
        }
    }

    self.first_block = try SharedExecutableBlock.initNearAddress(origin);
    const chunk = try self.first_block.?.reserveChunk();
    return chunk;
}

fn free(ctx: *anyopaque, ptr: *const Chunk) void {
    const self: *Allocator = @ptrCast(@alignCast(ctx));
    const ptr_address = @intFromPtr(ptr);

    var current_block = self.first_block;
    while (current_block) |block| : (current_block = block.head.next) {
        const block_address = @intFromPtr(block);
        if (ptr_address > block_address and (ptr_address - block_address) / @sizeOf(Chunk) < memory_block_size) {
            block.releaseChunk(ptr);
            return;
        }
    }

    // TODO: error handling when freeing a pointer not allocated by this allocator
    unreachable;
}

/// free all pages allocated by this allocator.
/// make sure to deinitialize all hooks that use Chunks from this allocator before freeing.
pub fn deinit(self: *Allocator) void {
    var current_block = self.first_block;
    while (current_block) |block| {
        current_block = block.head.next;
        block.deinit();
    }

    self.first_block = null;
}

pub fn allocator(self: *Allocator) ChunkAllocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .free = free,
        },
    };
}
