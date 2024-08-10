# Zigzag

Zigzag is a cross platform x86_64 hooking library for Windows and Linux.

### Usage

```zig
const std = @import("std");
const zz = @import("zigzag");

fn sqr(n: u32) u64 {
    return n * n;
}

fn sqr_detour(n: u32) u64 {
    return n * n + 1;
}

pub fn main() !void {
    var pca: zz.PageChunkAllocator = .{};
    defer pca.deinit();
    const ca = pca.allocator();

    try std.testing.expect(sqr(2) == 4);

    const sqr_hook = try zz.Hook(@TypeOf(sqr)).init(ca, @constCast(&sqr), sqr_detour);
    // deinitializing a hook may fail when the page execute permission can't be removed
    defer _ = sqr_hook.deinit();

    try std.testing.expect(sqr(2) == 5);
    try std.testing.expect(sqr_hook.delegate(2) == 4);
}
```
