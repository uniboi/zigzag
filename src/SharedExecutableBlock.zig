const std = @import("std");
const mem = @import("mem.zig");
const builtin = @import("builtin");
const kernel32 = @import("kernel32.zig");
const memory_block_size = @import("PageChunkAllocator.zig").memory_block_size;
const SharedExecutableBlock = @This();

const ChunkAllocator = @import("ChunkAllocator.zig");
const Chunk = ChunkAllocator.Chunk;
const ReserveChunkError = ChunkAllocator.ReserveChunkError;
const AllocBlockError = ChunkAllocator.AllocBlockError;
const Error = ChunkAllocator.Error;

const Hook = @import("hooks.zig");
const trampoline_buffer_size = Hook.trampoline_buffer_size;
const getPages = Hook.getPages;

var mmap_min_address: ?usize = null;
var allocation_granularity: ?usize = switch (builtin.os.tag) {
    .windows => null,
    else => std.mem.page_size,
};

pub const CacheMinAddressError = switch (builtin.os.tag) {
    .windows => error{},
    else => std.fs.File.OpenError || std.fs.File.ReadError || std.fmt.ParseIntError,
};

// TODO: Use std.once
pub fn cacheMinAddressAndGranularity() CacheMinAddressError!void {
    switch (builtin.os.tag) {
        .windows => {
            var system_info: std.os.windows.SYSTEM_INFO = undefined;
            kernel32.GetSystemInfo(&system_info);
            mmap_min_address = @intFromPtr(system_info.lpMinimumApplicationAddress);
            allocation_granularity = system_info.dwAllocationGranularity;
        },
        else => {
            if (mmap_min_address != null) {
                return;
            }

            var buf: [16]u8 = .{0} ** 16;
            const fd = try std.fs.openFileAbsolute("/proc/sys/vm/mmap_min_addr", .{});
            defer fd.close();

            const size = try fd.read(&buf);
            mmap_min_address = try std.fmt.parseInt(usize, buf[0 .. size - 1], 10);
        },
    }
}

const chunk_amount = n: {
    const n = (memory_block_size - @sizeOf(?*SharedExecutableBlock)) / (@sizeOf(Chunk) + (1 / 8));
    // if (n + @sizeOf(std.PackedIntArray(u1, n)) > memory_block_size) {
    if (n + @sizeOf(std.bit_set.StaticBitSet(n)) > memory_block_size) {
        break :n n - @sizeOf(Chunk);
    }

    break :n n;
};

const InitNearbyError = error{UnavailableNearbyPage};

// const ChunkState = std.PackedIntArray(u1, chunk_amount);
const ChunkState = std.bit_set.StaticBitSet(chunk_amount);

comptime {
    std.debug.assert(@sizeOf(SharedExecutableBlock) <= memory_block_size);
}

const Head = struct {
    reserved_chunks: ChunkState,
    next: ?*SharedExecutableBlock,
};

head: Head,
chunks: [chunk_amount]Chunk,

pub fn init(address: usize) AllocBlockError!*SharedExecutableBlock {
    const blob: *SharedExecutableBlock = @ptrCast(@alignCast(try mem.map(@ptrFromInt(address), memory_block_size, .{ .read = true, .write = true, .execute = true })));

    if (builtin.mode == .Debug) {
        @memset(@as(*[memory_block_size]u8, @ptrCast(blob)), 0xCC);
    }

    blob.head.next = null;
    // blob.head.reserved_chunks = ChunkState.initAllTo(0);
    blob.head.reserved_chunks = ChunkState.initEmpty();

    const pages = getPages(@intFromPtr(blob));
    try std.posix.mprotect(pages, std.posix.PROT.READ | std.posix.PROT.WRITE | std.posix.PROT.EXEC);

    return blob;
}

pub fn initNearAddress(address: usize) AllocBlockError!*SharedExecutableBlock {
    const region = try mem.findUnmappedAreaWithin(.rip(address), memory_block_size) orelse return AllocBlockError.UnavailableNearbyPage;
    return init(region);
}

pub fn deinit(self: *SharedExecutableBlock) void {
    const buf: *[@sizeOf(SharedExecutableBlock)]u8 = @ptrCast(self);
    mem.unmap(@alignCast(buf));
}

pub fn reserveChunk(self: *SharedExecutableBlock) ReserveChunkError!*Chunk {
    for (0..chunk_amount) |i| {
        if (self.head.reserved_chunks.isSet(i)) {
            continue;
        }

        self.head.reserved_chunks.set(i);
        return @ptrFromInt(@intFromPtr(&self.chunks) + (i * trampoline_buffer_size));
    }

    return ReserveChunkError.OutOfChunks;
}

/// release a chunk acquired from this buffer
pub fn releaseChunk(self: *SharedExecutableBlock, chunk: *const Chunk) void {
    const chunk_addr = @intFromPtr(chunk);
    const chunks_addr = @intFromPtr(&self.chunks);

    std.debug.assert(chunk_addr >= chunks_addr);
    const chunk_index = (chunk_addr - chunks_addr) / @sizeOf(Chunk);
    std.debug.assert(chunk_index < chunk_amount);

    self.head.reserved_chunks.unset(chunk_index);
}

pub fn contains(self: *const SharedExecutableBlock, chunk: *const Chunk) bool {
    const block_addr: usize = @intFromPtr(self);
    const chunk_addr: usize = @intFromPtr(chunk);

    return chunk_addr > block_addr and
        chunk_addr - block_addr >= @sizeOf(Head) and
        (chunk_addr - block_addr) / @sizeOf(Chunk) < memory_block_size;
}

pub fn chunksRange(block: *const SharedExecutableBlock) mem.Range {
    return .{
        .from = @intFromPtr(&block.chunks),
        .to = @intFromPtr(block) + @sizeOf(SharedExecutableBlock),
    };
}
