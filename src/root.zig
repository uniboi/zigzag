const std = @import("std");
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
    std.mem.writeInt(u64, mvToR10[2..], payloadAddress, endianness); // write destination arg

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

/// target function body must be at least 13 bytes large
pub fn Hook(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Error = error{} || std.posix.MProtectError;

        target: *T,
        // payload: *const T,
        oldInstructions: [13]u8,

        /// Construct a hook to change all calls for `target` to `payload`
        pub fn init(target: *T, payload: *const T) Error!Self {
            // allow writing instructions in the pages that need to be patched
            const pages = getPages(@intFromPtr(target));
            try std.posix.mprotect(pages, std.posix.PROT.READ | std.posix.PROT.WRITE | std.posix.PROT.EXEC);

            const oldInstructions = writeJumpToPayload(@ptrCast(target), @intFromPtr(payload));

            // TODO: query status out of /proc/self/maps before overwriting access and revert to it here
            try std.posix.mprotect(pages, std.posix.PROT.READ | std.posix.PROT.EXEC);

            return .{
                .target = target,
                // .payload = payload,
                .oldInstructions = oldInstructions,
            };
        }

        /// revert patched instructions in the `target` body.
        /// returns `false` if memory protections cannot be updated.
        pub fn deinit(self: Self) bool {
            const pages = getPages(@intFromPtr(self.target));

            std.posix.mprotect(pages, std.posix.PROT.READ | std.posix.PROT.WRITE | std.posix.PROT.EXEC) catch return false;
            const body: [*]u8 = @ptrCast(self.target);
            _ = body;
            @memcpy(@as([*]u8, @ptrCast(self.target)), &self.oldInstructions);
            std.posix.mprotect(pages, std.posix.PROT.READ | std.posix.PROT.EXEC) catch return false;

            return true;
        }
    };
}
