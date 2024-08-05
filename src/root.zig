const std = @import("std");
const Disassembler = @import("dis_x86_64").Disassembler;
const endianness = @import("builtin").target.cpu.arch.endian();

const max_instruction_size = 15;
const trampoline_buffer_size = (max_instruction_size * 2) + @sizeOf(JMP_ABS);

fn getPages(target: usize) []align(std.mem.page_size) u8 {
    const pageAlignedPtr: [*]u8 = @ptrFromInt(std.mem.alignBackward(usize, target, std.mem.page_size));
    return @alignCast(pageAlignedPtr[0..std.mem.page_size]); // TODO: check if patched instructions cross page boundaries
}

// TODO: RIP should be able to handle regions after address as well
/// seek within 32 bit range
fn findPreviousFreeRegion(address: usize) std.os.windows.VirtualQueryError!?usize {
    var system_info: std.os.windows.SYSTEM_INFO = undefined;
    std.os.windows.kernel32.GetSystemInfo(&system_info);

    const min_address = if (std.math.maxInt(u32) > address)
        @intFromPtr(system_info.lpMinimumApplicationAddress)
    else
        address - std.math.maxInt(u32);

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

/// returns amount of copied bytes
fn writeTrampolineBody(dest: usize, source: usize) Disassembler.Error!usize {
    const dest_bytes: [*]u8 = @ptrFromInt(dest);
    const source_bytes: [*]u8 = @ptrFromInt(source);

    const min_size = @sizeOf(JMP_ABS);

    var disassembler = Disassembler.init(source_bytes[0 .. min_size + max_instruction_size]);
    var last_pos: usize = 0;

    while (try disassembler.next()) |ins| {
        if (last_pos >= min_size) {
            break;
        }

        @memcpy(dest_bytes[last_pos..disassembler.pos], source_bytes[last_pos..disassembler.pos]);
        // TODO: patch RIP operands
        _ = ins;

        last_pos = disassembler.pos;
    }

    return last_pos;
}

fn writeAbsoluteJump(address: [*]u8, destination: usize) void {
    const jmp: JMP_ABS = .{ .addr = destination };
    @memcpy(address[0..@sizeOf(JMP_ABS)], @as([*]const u8, @ptrCast(&jmp)));
}

/// target function body must be at least 13 bytes large
pub fn Hook(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Error = error{
            UnavailableNearbyPage,
        } || SharedExecutableBlock.ReserveChunkError || Disassembler.Error || std.posix.MProtectError || std.os.windows.VirtualQueryError;

        target: *T,
        replaced_instructions: [30]u8,
        delegate: *const T,
        block: *SharedExecutableBlock,

        /// Construct a hook to change all calls for `target` to `payload`
        pub fn init(target: *T, payload: *const T, blocks: *SharedBlocks) Error!Self {
            const target_address = @intFromPtr(target);
            const target_bytes: [*]u8 = @ptrCast(target);
            const original_instructions: [30]u8 = target_bytes[0..30].*;

            // allow writing instructions in the pages that need to be patched
            const pages = getPages(target_address);
            try std.posix.mprotect(pages, std.posix.PROT.READ | std.posix.PROT.WRITE | std.posix.PROT.EXEC);

            // TODO: try to allocate a new buffer if no chunks are free
            const block, const trampoline_buffer = try blocks.reserveChunk(target_address);
            const trampoline_size = try writeTrampolineBody(@intFromPtr(trampoline_buffer), target_address);

            // writeAbsoluteJump(@ptrFromInt(@intFromPtr(trampoline_buffer) + trampoline_size));
            const jmp_to_resume: JMP_ABS = .{ .addr = target_address + trampoline_size };
            @memcpy(trampoline_buffer[trampoline_size .. trampoline_size + @sizeOf(JMP_ABS)], @as([*]const u8, @ptrCast(&jmp_to_resume)));

            const jmp_to_hook: JMP_ABS = .{ .addr = @intFromPtr(payload) };
            @memcpy(target_bytes[0..@sizeOf(JMP_ABS)], @as([*]const u8, @ptrCast(&jmp_to_hook)));

            // TODO: query status out of /proc/self/maps before overwriting access and revert to it here
            try std.posix.mprotect(pages, std.posix.PROT.READ | std.posix.PROT.EXEC);

            return .{
                .target = target,
                .delegate = @ptrCast(trampoline_buffer),
                .block = block,
                .replaced_instructions = original_instructions,
            };
        }

        /// revert patched instructions in the `target` body.
        /// returns `false` if memory protections cannot be updated.
        pub fn deinit(self: Self) bool {
            self.block.releaseChunk(@ptrCast(self.delegate));

            const pages = getPages(@intFromPtr(self.target));

            std.posix.mprotect(pages, std.posix.PROT.READ | std.posix.PROT.WRITE | std.posix.PROT.EXEC) catch return false;
            const body: [*]u8 = @ptrCast(self.target);
            @memcpy(body, &self.replaced_instructions);
            std.posix.mprotect(pages, std.posix.PROT.READ | std.posix.PROT.EXEC) catch return false;

            return true;
        }

        fn initTrampoline() void {}
    };
}

pub const SharedBlocks = struct {
    const Error = SharedExecutableBlock.InitNearbyError || SharedExecutableBlock.AllocBlockError || SharedExecutableBlock.ReserveChunkError;
    first: ?*SharedExecutableBlock,

    pub fn init() SharedBlocks {
        return .{ .first = null };
    }

    pub fn deinit(self: SharedBlocks) void {
        var current = self.first;
        while (current) |block| {
            current = block.head.next;
            _ = block.deinit();
        }
    }

    pub fn reserveChunk(self: *SharedBlocks, addr: usize) Error!struct { *SharedExecutableBlock, *SharedExecutableBlock.Chunk } {
        const max_distance = std.math.maxInt(u32);

        var current = self.first;
        while (current) |block| : (current = block.head.next) {
            const block_address = @intFromPtr(block);
            if ((block_address < addr) and (addr - block_address <= max_distance)) {
                return .{ block, block.reserveChunk() catch continue };
            }
        }

        self.first = try SharedExecutableBlock.initNearAddress(addr);
        const chunk = try self.first.?.reserveChunk();
        return .{ self.first.?, chunk };
    }
};

pub const SharedExecutableBlock = struct {
    const memory_block_size = 0x1000;
    // const chunk_amount = memory_block_size / (@sizeOf(Chunk) + (1 / 8));

    const chunk_amount = n: {
        const n = (memory_block_size - @sizeOf(?*SharedExecutableBlock)) / (@sizeOf(Chunk) + (1 / 8));
        if (n + @sizeOf(std.PackedIntArray(u1, n)) > memory_block_size) {
            break :n n - @sizeOf(Chunk);
        }

        break :n n;
    };

    const InitNearbyError = error{UnavailableNearbyPage};
    const AllocBlockError = std.os.windows.VirtualAllocError || std.posix.MProtectError;
    const ReserveChunkError = error{NoAvailableChunk};

    const ChunkState = std.PackedIntArray(u1, chunk_amount);
    const Chunk = [trampoline_buffer_size]u8;

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

    pub fn initNearAddress(address: usize) (InitNearbyError || AllocBlockError)!*SharedExecutableBlock {
        const region = try findPreviousFreeRegion(address) orelse return InitNearbyError.UnavailableNearbyPage;
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

        return ReserveChunkError.NoAvailableChunk;
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

/// 64 bit indirect absolute jump
const JMP_ABS = packed struct {
    op1: u8 = 0xFF,
    op2: u8 = 0x25,
    dummy: u32 = 0x0,
    addr: u64,
};
