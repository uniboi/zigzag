const std = @import("std");
const zz = @import("zigzag");

fn add(a: i32, b: i32) i32 {
    return a + b + 1;
}

fn add_detour(a: i32, b: i32) i32 {
    return a + b;
}

pub fn main() !void {
    var pca = try zz.PageChunkAllocator.init();
    defer pca.deinit();
    const chunk_allocator = pca.allocator();

    try std.testing.expect(add(1, 2) == 4);

    {
        const add_hook = try zz.Hook(fn (i32, i32) i32).init(chunk_allocator, @constCast(&add), add_detour);
        defer _ = add_hook.deinit(chunk_allocator);

        try std.testing.expect(add(1, 2) == 3);
        try std.testing.expect(add_hook.delegate(1, 2) == 4);
    }

    try std.testing.expect(add(1, 2) == 4);
}
