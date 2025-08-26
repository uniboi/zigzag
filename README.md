# Zigzag

A simple x64 hooking library for Windows and Linux.

Trampolines are allocated near the hooked site and any relative instructions are patched in order to effective address is the same.

If the provided `ChunkAllocator` interface does not suit your needs, you can write your own implementation similar how you'd write a custom std allocator implementation.

## Usage

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
    // deinitializing a hook may fail because page permissions can't be revoked
    defer sqr_hook.deinit(ca) catch @panic("could not uninstall hook");

    try std.testing.expect(sqr(2) == 5);
    try std.testing.expect(sqr_hook.delegate(2) == 4);
}
```

## Examples

Run `zig build example.<name>` to run a specific example.

For example `zig build example.basic`.
