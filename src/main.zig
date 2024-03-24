const std = @import("std");
const endianness = @import("builtin").target.cpu.arch.endian();

// const Hook = @import("hook.zig");
const Hook = @import("root.zig").Hook;

fn add_hook(a: c_int, b: c_int) callconv(.C) c_int {
    _ = b;
    _ = a;
    return 99;
}

//fn hook_relay(a: c_int, b: c_int) callconv(.Naked) c_int {
//    return add_hook(a, b);
//}

fn protect(lib: std.DynLib) !void {
    var pages = lib.memory;
    pages.len = std.mem.alignForward(usize, pages.len, std.mem.page_size);
    try std.os.mprotect(pages, std.os.PROT.READ | std.os.PROT.WRITE | std.os.PROT.EXEC);
}

fn writeAbsoluteJump64(location: [*]u8, destination: u64) void {
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
    std.mem.writeInt(u64, mvToR10[2..], destination, endianness); // write destination arg

    const jmpToR10 = [3]u8{ 0x41, 0xFF, 0xE2 }; // jmp r10

    // mov %r10 destination
    // jmp %r10
    const middleman = mvToR10 ++ jmpToR10;
    @memcpy(location, &middleman);
}

fn installHook(comptime T: type, target: *T, payload: *const T) void {
    writeAbsoluteJump64(@ptrCast(target), @intFromPtr(payload));
}

pub fn main() !void {
    var lib = try std.DynLib.open("./zig-out/lib/libcExampleLib.so");
    defer lib.close();

    const add = lib.lookup(*fn (c_int, c_int) callconv(.C) c_int, "add").?;

    const r1 = add(1, 2);
    try std.testing.expect(r1 == 3);
    std.debug.print("add(1, 2) = {d}\n", .{r1});

    try protect(lib);
    installHook(@TypeOf(add_hook), add, &add_hook);

    const r2 = add(1, 2);
    try std.testing.expect(r2 == 99);
    std.debug.print("add(1, 2) = {d}\n", .{r2});

    const hook = Hook(@TypeOf(add_hook)).init(add, &add_hook);
    defer hook.deinit();
}
