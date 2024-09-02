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

const Hook = @import("root.zig");
const trampoline_buffer_size = Hook.trampoline_buffer_size;

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
    if (n + @sizeOf(std.PackedIntArray(u1, n)) > memory_block_size) {
        break :n n - @sizeOf(Chunk);
    }

    break :n n;
};

const InitNearbyError = error{UnavailableNearbyPage};

const ChunkState = std.PackedIntArray(u1, chunk_amount);

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
    const blob: *SharedExecutableBlock = @alignCast(@ptrCast(try mem.map(@ptrFromInt(address), memory_block_size, .{ .read = true, .write = true, .execute = true })));

    if (builtin.mode == .Debug) {
        @memset(@as(*[memory_block_size]u8, @ptrCast(blob)), 0xCC);
    }

    blob.head.next = null;
    blob.head.reserved_chunks = ChunkState.initAllTo(0);
    std.debug.print("chunks: {x}\n", .{@intFromPtr(&blob.chunks)});
    return blob;
}

pub fn initNearAddress(address: usize) AllocBlockError!*SharedExecutableBlock {
    // const region = try findPreviousFreeRegion(address) orelse return AllocBlockError.UnavailableNearbyPage;
    const region = try mem.unmapped_area_near(address) orelse return AllocBlockError.UnavailableNearbyPage;
    return init(region);
}

pub fn deinit(self: *SharedExecutableBlock) void {
    const buf: *[@sizeOf(SharedExecutableBlock)]u8 = @ptrCast(self);
    mem.unmap(@alignCast(buf));
}

pub fn reserveChunk(self: *SharedExecutableBlock) ReserveChunkError!*Chunk {
    for (0..chunk_amount) |i| {
        if (self.head.reserved_chunks.get(i) == 1) {
            continue;
        }

        self.head.reserved_chunks.set(i, 1);
        return @ptrFromInt(@intFromPtr(&self.chunks) + (i * trampoline_buffer_size));
    }

    return ReserveChunkError.OutOfChunks;
}

/// release a chunk acquired from this buffer
pub fn releaseChunk(self: *SharedExecutableBlock, chunk: *const Chunk) void {
    const chunk_addr = @intFromPtr(chunk);
    const chunks_addr = @intFromPtr(&self.chunks);

    std.debug.assert(chunk_addr >= chunks_addr);
    std.debug.assert((chunk_addr - chunks_addr) < chunk_amount);

    const index = chunk_addr - chunks_addr;
    self.head.reserved_chunks.set(index, 0);
}

// TODO: search in address += 512mb
fn findPreviousFreeRegion(address: usize) std.os.windows.VirtualQueryError!?usize {
    const min_address = if (std.math.maxInt(i32) > address)
        // @intFromPtr(system_info.lpMinimumApplicationAddress)
        mmap_min_address.?
    else
        address - std.math.maxInt(i32);

    var probe_address = address;

    // TODO: this is from minhook, not quite sure if allat is required
    probe_address -= probe_address % allocation_granularity.?;
    probe_address -= allocation_granularity.?;

    while (probe_address > min_address) {
        var memory_info: std.os.windows.MEMORY_BASIC_INFORMATION = undefined;
        const info_size = try std.os.windows.VirtualQuery(@ptrFromInt(probe_address), &memory_info, @sizeOf(std.os.windows.MEMORY_BASIC_INFORMATION));

        if (info_size == 0) {
            break;
        }

        if (memory_info.State == std.os.windows.MEM_FREE) {
            return probe_address;
        }

        probe_address -= @intFromPtr(memory_info.AllocationBase) - allocation_granularity.?;
    }

    return null;
}
