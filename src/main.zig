const std = @import("std");
const Hook = @import("root.zig").Hook;

const AddSignature = fn (c_int, c_int) callconv(.C) c_int;
const underived_add: AddSignature = undefined;

fn add_hook(a: c_int, b: c_int) callconv(.C) c_int {
    return a + b + 1;
}

pub fn main() !void {
    var lib = try std.DynLib.open("./zig-out/lib/libcExampleLib.so");
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

    // destroy the hook
    _ = hook.deinit();

    // regular call
    const r3 = add(1, 2);
    try std.testing.expect(r3 == 3);
    std.debug.print("{d}\n", .{r3});
}
