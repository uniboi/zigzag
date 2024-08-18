const std = @import("std");
const builtin = @import("builtin");
const VirtualAllocator = @import("VirtualAllocator.zig");
const mem = std.mem;
const maxInt = std.math.maxInt;
const assert = std.debug.assert;
const native_os = builtin.os.tag;
const windows = std.os.windows;
const posix = std.posix;

const vtable = VirtualAllocator.VTable{
    .alloc = alloc,
    .free = free,
};

fn alloc(_: *anyopaque, hint: [*]align(std.mem.page_size) u8, n: usize, log2_align: u8, ra: usize) ?[*]u8 {
    _ = ra;
    _ = log2_align;
    assert(n > 0);
    if (n > maxInt(usize) - (mem.page_size - 1)) return null;
    const aligned_len = mem.alignForward(usize, n, mem.page_size);

    if (native_os == .windows) {
        const addr = windows.VirtualAlloc(
            null,
            aligned_len,
            windows.MEM_COMMIT | windows.MEM_RESERVE,
            windows.PAGE_READWRITE,
        ) catch return null;
        return @ptrCast(addr);
    }

    // const hint = @atomicLoad(@TypeOf(std.heap.next_mmap_addr_hint), &std.heap.next_mmap_addr_hint, .unordered);
    const slice = posix.mmap(
        hint,
        aligned_len,
        posix.PROT.READ | posix.PROT.WRITE,
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    ) catch return null;
    assert(mem.isAligned(@intFromPtr(slice.ptr), mem.page_size));
    const new_hint: [*]align(mem.page_size) u8 = @alignCast(slice.ptr + aligned_len);
    _ = @cmpxchgStrong(@TypeOf(std.heap.next_mmap_addr_hint), &std.heap.next_mmap_addr_hint, hint, new_hint, .monotonic, .monotonic);
    return slice.ptr;
}

fn free(_: *anyopaque, slice: []u8, log2_buf_align: u8, return_address: usize) void {
    _ = log2_buf_align;
    _ = return_address;

    if (native_os == .windows) {
        windows.VirtualFree(slice.ptr, 0, windows.MEM_RELEASE);
    } else {
        const buf_aligned_len = mem.alignForward(usize, slice.len, mem.page_size);
        posix.munmap(@alignCast(slice.ptr[0..buf_aligned_len]));
    }
}

pub fn allocator() VirtualAllocator {
    return .{
        .ptr = null,
        .vtable = &.{
            .alloc = alloc,
            .free = free,
        },
    };
}
