const std = @import("std");
const ChunkAllocator = @import("ChunkAllocator.zig");
const Chunk = ChunkAllocator.Chunk;
const ReserveChunkError = ChunkAllocator.ReserveChunkError;
const AllocBlockError = ChunkAllocator.AllocBlockError;
const Error = ChunkAllocator.Error;

const Hook = @import("root.zig");
const trampoline_buffer_size = Hook.trampoline_buffer_size;
const getPages = Hook.getPages;

const Allocator = @This();
const memory_block_size = 0x1000;

first_block: ?*SharedExecutableBlock = null,

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
        if (ptr_address > block_address and ptr_address - block_address < memory_block_size) {
            block.releaseChunk(ptr);
            return;
        }
    }

    // TODO: error handling when freeing a pointer not allocated by this allocator
    unreachable;
}

/// Returns `true` if all blocks have been freed
pub fn deinit(self: Allocator) void {
    var current_block = self.first_block;
    while (current_block) |block| {
        current_block = block.head.next;
        // TODO: error handling page permissions
        _ = block.deinit();
    }
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

pub const SharedExecutableBlock = struct {
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
        const blob: *SharedExecutableBlock = @alignCast(@ptrCast(try std.os.windows.VirtualAlloc(@ptrFromInt(address), memory_block_size, std.os.windows.MEM_COMMIT | std.os.windows.MEM_RESERVE, std.os.windows.PAGE_EXECUTE_READWRITE)));
        const pages = getPages(@intFromPtr(blob));
        try std.posix.mprotect(pages, std.posix.PROT.READ | std.posix.PROT.WRITE | std.posix.PROT.EXEC);

        blob.head.next = null;
        blob.head.reserved_chunks = ChunkState.initAllTo(0);
        return blob;
    }

    pub fn initNearAddress(address: usize) AllocBlockError!*SharedExecutableBlock {
        const region = try findPreviousFreeRegion(address) orelse return AllocBlockError.UnavailableNearbyPage;
        return init(region);
    }

    pub fn deinit(self: *SharedExecutableBlock) bool {
        // return self.chunks.deinit();
        const buf: *anyopaque = @ptrCast(self);
        const pages = getPages(@intFromPtr(buf));
        std.posix.mprotect(pages, std.posix.PROT.READ | std.posix.PROT.WRITE) catch return false; // TODO: does virtualfree reset protection itself?

        std.os.windows.VirtualFree(buf, 0, std.os.windows.MEM_RELEASE);
        return true;
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
};

fn findPreviousFreeRegion(address: usize) std.os.windows.VirtualQueryError!?usize {
    var system_info: std.os.windows.SYSTEM_INFO = undefined;
    std.os.windows.kernel32.GetSystemInfo(&system_info);

    const min_address = if (std.math.maxInt(i32) > address)
        @intFromPtr(system_info.lpMinimumApplicationAddress)
    else
        address - std.math.maxInt(i32);

    var probe_address = address;

    // TODO: this is from minhook, not quite sure if allat is required
    probe_address -= probe_address % system_info.dwAllocationGranularity;
    probe_address -= system_info.dwAllocationGranularity;

    while (probe_address > min_address) {
        var memory_info: std.os.windows.MEMORY_BASIC_INFORMATION = undefined;
        const info_size = try std.os.windows.VirtualQuery(@ptrFromInt(probe_address), &memory_info, @sizeOf(std.os.windows.MEMORY_BASIC_INFORMATION));

        if (info_size == 0) {
            break;
        }

        if (memory_info.State == std.os.windows.MEM_FREE) {
            return probe_address;
        }

        probe_address -= @intFromPtr(memory_info.AllocationBase) - system_info.dwAllocationGranularity;
    }

    return null;
}
