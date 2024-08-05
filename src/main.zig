const std = @import("std");
const zds = @import("dis_x86_64");
const Disassembler = zds.Disassembler;

const zz = @import("root.zig");
const Hook = zz.Hook;
const TrampolineBuffer = zz.SharedExecutableBlock;
const SharedBlocks = zz.SharedBlocks;

const AddSignature = fn (c_int, c_int) callconv(.C) c_int;
const SquareSignature = fn (c_int) callconv(.C) c_int;

fn add_detour(a: c_int, b: c_int) callconv(.C) c_int {
    return a + b + 1;
}

fn square_detour(n: c_int) callconv(.C) c_int {
    return n * n + 1;
}

pub fn main() !void {
    var lib = try std.DynLib.open("./zig-out/bin/cExampleLib.dll");
    defer lib.close();

    const add = lib.lookup(*AddSignature, "add").?;
    const square = lib.lookup(*SquareSignature, "square").?;

    // regular call
    const r1 = add(1, 2);
    try std.testing.expect(r1 == 3);
    std.debug.print("{d}\n", .{r1});

    // create a hook
    //var tr = try TrampolineBuffer.initNearAddress(@intFromPtr(add));
    //defer _ = tr.deinit();
    var tr = SharedBlocks.init();
    defer tr.deinit();

    const hook = try Hook(AddSignature).init(add, &add_detour, &tr);

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

    const sq_a = square(2);
    try std.testing.expect(sq_a == 4);

    const square_hook = try Hook(SquareSignature).init(square, &square_detour, &tr);
    defer _ = square_hook.deinit();
    const sq_b = square(2);
    try std.testing.expect(sq_b == 5);
}
