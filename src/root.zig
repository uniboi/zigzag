const std = @import("std");
const Disassembler = @import("dis_x86_64").Disassembler;
const endianness = @import("builtin").target.cpu.arch.endian();

fn writeJumpToPayload(target: [*]u8, payloadAddress: usize) [13]u8 {
    var mvToR10 = [_]u8{
        0x49, // mov
        0xBA, // %r10
        // destination address
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
    };
    std.mem.writeInt(u64, mvToR10[2..], payloadAddress, .little); // write destination arg

    const jmpToR10 = [_]u8{ 0x41, 0xFF, 0xE2 }; // jmp r10

    // mov %r10 destination
    // jmp %r10
    const middleman = mvToR10 ++ jmpToR10;
    var prevInstructions = [_]u8{0} ** middleman.len;
    @memcpy(&prevInstructions, target[0..middleman.len]);
    @memcpy(target, &middleman);

    return prevInstructions;
}

fn getPages(target: usize) []align(std.mem.page_size) u8 {
    const pageAlignedPtr: [*]u8 = @ptrFromInt(std.mem.alignBackward(usize, target, std.mem.page_size));
    return @alignCast(pageAlignedPtr[0..std.mem.page_size]); // TODO: check if patched instructions cross page boundaries
}

// TODO: RIP should be able to handle regions after address as well
/// seek within 32 bit range
pub fn findPreviousFreeRegion(address: usize) std.os.windows.VirtualQueryError!?usize {
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
fn copyInstructions(dest: usize, source: usize) Disassembler.Error!usize {
    const dest_bytes: [*]u8 = @ptrFromInt(dest);
    const source_bytes: [*]u8 = @ptrFromInt(source);

    const min_size = @sizeOf(JMP_ABS);
    const max_instruction_size = 15;

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
        } || Trampoline.Error || Disassembler.Error || std.posix.MProtectError || std.os.windows.VirtualQueryError;

        target: *T,
        replaced_instructions: [32]u8,
        delegate: *const T,

        /// Construct a hook to change all calls for `target` to `payload`
        pub fn init(target: *T, payload: *const T) Error!Self {
            const target_address = @intFromPtr(target);
            const target_bytes: [*]u8 = @ptrCast(target);
            const original_instructions: [32]u8 = target_bytes[0..32].*;

            // allow writing instructions in the pages that need to be patched
            const pages = getPages(target_address);
            try std.posix.mprotect(pages, std.posix.PROT.READ | std.posix.PROT.WRITE | std.posix.PROT.EXEC);

            // const oldInstructions = writeJumpToPayload(@ptrCast(target), @intFromPtr(payload));
            const region = try findPreviousFreeRegion(target_address) orelse return Error.UnavailableNearbyPage;
            // TODO: reuse pages for multiple simultaneous pages
            const trampoline_buffer = try Trampoline.init(region);
            const trampoline_bytes: [*]u8 = @ptrCast(trampoline_buffer);
            const trampoline_size = try copyInstructions(@intFromPtr(trampoline_buffer), target_address);

            // writeAbsoluteJump(@ptrFromInt(@intFromPtr(trampoline_buffer) + trampoline_size));
            const jmp_to_resume: JMP_ABS = .{ .addr = target_address + trampoline_size };
            @memcpy(trampoline_bytes[trampoline_size .. trampoline_size + @sizeOf(JMP_ABS)], @as([*]const u8, @ptrCast(&jmp_to_resume)));

            const jmp_to_hook: JMP_ABS = .{ .addr = @intFromPtr(payload) };
            @memcpy(target_bytes[0..@sizeOf(JMP_ABS)], @as([*]const u8, @ptrCast(&jmp_to_hook)));

            // TODO: query status out of /proc/self/maps before overwriting access and revert to it here
            try std.posix.mprotect(pages, std.posix.PROT.READ | std.posix.PROT.EXEC);

            return .{
                .target = target,
                .delegate = @ptrCast(trampoline_buffer),
                .replaced_instructions = original_instructions,
            };
        }

        /// revert patched instructions in the `target` body.
        /// returns `false` if memory protections cannot be updated.
        pub fn deinit(self: Self) bool {
            const pages = getPages(@intFromPtr(self.target));

            std.posix.mprotect(pages, std.posix.PROT.READ | std.posix.PROT.WRITE | std.posix.PROT.EXEC) catch return false;
            const body: [*]u8 = @ptrCast(self.target);
            @memcpy(body, &self.replaced_instructions);
            std.posix.mprotect(pages, std.posix.PROT.READ | std.posix.PROT.EXEC) catch return false;

            const trampoline: *Trampoline = @constCast(@ptrCast(self.delegate));
            return trampoline.deinit();
        }

        fn initTrampoline() void {}
    };
}

// TODO: VirtualAlloc always allocates blocks of granular size
// implement an allocator that allows multiple smaller blocks for trampolines in a block allocated by VirtualAlloc
pub const Trampoline = opaque {
    const Error = std.os.windows.VirtualAllocError || std.posix.MProtectError;
    const memory_block_size = 0x1000;

    pub fn init(address: usize) Error!*Trampoline {
        const blob: *Trampoline = @ptrCast(try std.os.windows.VirtualAlloc(@ptrFromInt(address), memory_block_size, std.os.windows.MEM_COMMIT | std.os.windows.MEM_RESERVE, std.os.windows.PAGE_EXECUTE_READWRITE));
        const pages = getPages(@intFromPtr(blob));
        try std.posix.mprotect(pages, std.posix.PROT.READ | std.posix.PROT.WRITE | std.posix.PROT.EXEC);
        return blob;
    }

    pub fn deinit(buf: *Trampoline) bool {
        const pages = getPages(@intFromPtr(buf));
        std.posix.mprotect(pages, std.posix.PROT.READ | std.posix.PROT.WRITE) catch return false; // TODO: does virtualfree reset protection itself?

        std.os.windows.VirtualFree(buf, 0, std.os.windows.MEM_RELEASE);
        return true;
    }
};

/// 64 bit indirect absolute jump
pub const JMP_ABS = packed struct {
    op1: u8 = 0xFF,
    op2: u8 = 0x25,
    dummy: u32 = 0x0,
    addr: u64,
};
