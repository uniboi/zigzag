const std = @import("std");
const endianness = @import("builtin").target.cpu.arch.endian();

fn claimAddressSpace() void {}

fn writeJumpToPayload(target: [*]u8, payloadAddress: usize) void {
    // NOTE: cmov?
    var mvToR10 = [10]u8{
        0x49, // mov
        0xBA, // %r10
        // destination is written later
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
    };
    // std.mem.writeInt(u64, mvToR10[2..][0..@sizeOf(u64)], n, endianness);
    std.mem.writeInt(u64, mvToR10[2..], payloadAddress, endianness); // write destination arg

    const jmpToR10 = [3]u8{ 0x41, 0xFF, 0xE2 }; // jmp r10

    // mov %r10 destination
    // jmp %r10
    const middleman = mvToR10 ++ jmpToR10;
    @memcpy(target, &middleman);
}

pub fn Hook(comptime T: type) type {
    return struct {
        const Self = @This();

        target: *T,
        payload: *const T,

        pub fn init(target: *T, payload: *const T) Self {
            return .{
                .target = target,
                .payload = payload,
            };
        }

        pub fn deinit(self: Self) void {
            _ = self;
        }
    };
}
