const std = @import("std");
const zds = @import("dis_x86_64");
const Disassembler = zds.Disassembler;

const Hook = @import("root.zig").Hook;
const Trampoline = @import("root.zig").Trampoline;
const JMP_ABS = @import("root.zig").JMP_ABS;
const findPreviousFreeRegion = @import("root.zig").findPreviousFreeRegion;

const AddSignature = fn (c_int, c_int) callconv(.C) c_int;

fn add_hook(a: c_int, b: c_int) callconv(.C) c_int {
    return a + b + 1;
}

pub fn main() !void {
    var lib = try std.DynLib.open("./zig-out/bin/cExampleLib.dll");
    defer lib.close();

    const add = lib.lookup(*AddSignature, "add").?;

    // regular call
    const r1 = add(1, 2);
    try std.testing.expect(r1 == 3);
    std.debug.print("{d}\n", .{r1});

    // create a hook
    const hook = try Hook(AddSignature).init(add, &add_hook);

    // expect hooked result
    const r2 = add(1, 2);
    try std.testing.expect(r2 == 4);
    std.debug.print("{d}\n", .{r2});

    const rt = hook.delegate(1, 2);
    try std.testing.expect(rt == 3);
    std.debug.print("{d}\n", .{rt});

    // destroy the hook
    _ = hook.deinit();

    // regular call
    const r3 = add(1, 2);
    try std.testing.expect(r3 == 3);
    std.debug.print("{d}\n", .{r3});
}
