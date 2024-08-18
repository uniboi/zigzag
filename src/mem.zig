const std = @import("std");
const windows = std.os.windows;
const PROT = std.posix.PROT;
const page_size = std.mem.page_size;
const target = @import("builtin").os.tag;

pub const Protection = packed struct {
    execute: bool = false,
    write: bool = false,
    read: bool = false,

    fn flags(prot: Protection) u32 {
        // TODO: the compiler can't derive that comptime_int should resolve to u32 for some reason
        return switch (target) {
            .windows => {
                if (prot.execute and prot.write and prot.read) {
                    return windows.PAGE_EXECUTE_READWRITE;
                }

                if (prot.write and prot.read) {
                    return windows.PAGE_READWRITE;
                }

                if (prot.read) {
                    return windows.PAGE_READONLY;
                }

                return windows.PAGE_NOACCESS;
            },
            else => if (!prot.execute and !prot.write and !prot.read) @as(u32, PROT.NONE) else if (prot.execute) @as(u32, PROT.WRITE) else 0 |
                if (prot.write) @as(u32, PROT.WRITE) else 0 |
                if (prot.read) @as(u32, PROT.READ) else 0,
        };
    }
};

pub const MapError = switch (target) {
    .windows => windows.VirtualAllocError,
    else => std.posix.MMapError,
};

pub fn map(addr: ?*anyopaque, size: usize, prot: Protection) MapError![]align(page_size) u8 {
    return switch (target) {
        .windows => @alignCast(@as([*]u8, @ptrCast(try windows.VirtualAlloc(addr, size, windows.MEM_COMMIT | windows.MEM_RESERVE, prot.flags())))[0..size]),
        else => std.posix.mmap(@alignCast(@ptrCast(addr)), size, prot.flags(), .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0),
    };
}

pub fn unmap(mem: []align(page_size) u8) void {
    return switch (target) {
        .windows => windows.VirtualFree(mem.ptr, 0, windows.MEM_RELEASE),
        else => std.posix.munmap(mem),
    };
}
