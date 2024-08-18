const std = @import("std");
const Disassembler = @import("dis_x86_64").Disassembler;
const ChunkAllocator = @import("ChunkAllocator.zig");
const mem = @import("mem.zig");

const max_instruction_size = 15;
pub const trampoline_buffer_size = (max_instruction_size * 2) + @sizeOf(JMP_ABS);

pub fn getPages(target: usize) []align(std.mem.page_size) u8 {
    const pageAlignedPtr: [*]u8 = @ptrFromInt(std.mem.alignBackward(usize, target, std.mem.page_size));
    return @alignCast(pageAlignedPtr[0..std.mem.page_size]); // TODO: check if patched instructions cross page boundaries
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

pub const Error = error{
    UnavailableNearbyPage,
} || ChunkAllocator.ReserveChunkError || Disassembler.Error || mem.MapError || std.posix.MProtectError || std.os.windows.VirtualQueryError;

/// target function body must be at least 13 bytes large
pub fn Hook(comptime T: type) type {
    return struct {
        const Self = @This();

        target: *T,
        replaced_instructions: [30]u8,
        delegate: *const T,
        allocator: ChunkAllocator,

        /// Construct a hook to change all calls for `target` to `payload`
        pub fn init(chunk_allocator: ChunkAllocator, target: *T, payload: *const T) Error!Self {
            const target_address = @intFromPtr(target);
            const target_bytes: [*]u8 = @ptrCast(target);
            const original_instructions: [30]u8 = target_bytes[0..30].*;

            // allow writing instructions in the pages that need to be patched
            const pages = getPages(target_address);
            try std.posix.mprotect(pages, std.posix.PROT.READ | std.posix.PROT.WRITE | std.posix.PROT.EXEC);

            // TODO: try to allocate a new buffer if no chunks are free
            const trampoline_buffer = try chunk_allocator.alloc(target_address);
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
                .replaced_instructions = original_instructions,
                .allocator = chunk_allocator,
            };
        }

        /// revert patched instructions in the `target` body.
        /// returns `false` if memory protections cannot be updated.
        pub fn deinit(self: Self) bool {
            self.allocator.free(@ptrCast(self.delegate));

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

/// 64 bit indirect absolute jump
const JMP_ABS = packed struct {
    op1: u8 = 0xFF,
    op2: u8 = 0x25,
    dummy: u32 = 0x0,
    addr: u64,
};
