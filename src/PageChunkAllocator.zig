const std = @import("std");
const builtin = @import("builtin");
const ChunkAllocator = @import("ChunkAllocator.zig");
const Chunk = ChunkAllocator.Chunk;
const ReserveChunkError = ChunkAllocator.ReserveChunkError;
const AllocBlockError = ChunkAllocator.AllocBlockError;
const Error = ChunkAllocator.Error;

const SharedExecutableBlock = @import("SharedExecutableBlock.zig");

const Hook = @import("hooks.zig");
const trampoline_buffer_size = Hook.trampoline_buffer_size;
const getPages = Hook.getPages;

const mem = @import("mem.zig");
const Range = mem.Range;

const Allocator = @This();
pub const memory_block_size = 0x1000;

first_block: ?*SharedExecutableBlock,

pub fn init() SharedExecutableBlock.CacheMinAddressError!Allocator {
    try SharedExecutableBlock.cacheMinAddressAndGranularity();
    return .{
        .first_block = null,
    };
}

/// Try to allocate a chunk near origin
fn alloc(ctx: *anyopaque, origin: usize) Error!*Chunk {
    const self: *Allocator = @ptrCast(@alignCast(ctx));
    var next_block = self.first_block;
    while (next_block) |block| {
        if(block.chunksRange().intersects(.rip(origin))) {
            return block.reserveChunk() catch continue;
        }
        next_block = block.head.next;
    }

    const prev = self.first_block;
    self.first_block = try SharedExecutableBlock.initNearAddress(origin);
    self.first_block.?.head.next = prev;
    const chunk = try self.first_block.?.reserveChunk();
    return chunk;
}

fn free(ctx: *anyopaque, chunk: *const Chunk) void {
    const self: *Allocator = @ptrCast(@alignCast(ctx));
    var current_block = self.first_block;
    while (current_block) |block| {
        if (block.contains(chunk)) {
            block.releaseChunk(chunk);
            return;
        }

        current_block = block.head.next;
    }

    @panic("chunk has not been allocated with this instance");
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
