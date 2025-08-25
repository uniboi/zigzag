const std = @import("std");
const zz = @import("zigzag");

const SquareSignature = fn (i32) i32;
var square_delegate: *const SquareSignature = undefined;

fn square(n: i32) i32 {
    return n * n;
}

fn square_detour(n: i32) i32 {
    const r = square_delegate(n);
    std.debug.print("square({d}) = {d}\n", .{ n, r });
    return r;
}

pub fn main() !void {
    var pca = try zz.PageChunkAllocator.init();
    defer pca.deinit();
    const chunk_allocator = pca.allocator();

    const square_hook = try zz.Hook(SquareSignature).init(chunk_allocator, @constCast(&square), square_detour);
    defer _ = square_hook.deinit(chunk_allocator);
    square_delegate = square_hook.delegate;

    try std.testing.expect(square(2) == 4);
}
