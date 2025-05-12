const std = @import("std");
const windows = std.os.windows;
const PROT = std.posix.PROT;
const target = @import("builtin").os.tag;
const kernel32 = @import("kernel32.zig");
const SharedBlock = @import("SharedExecutableBlock.zig");
const procmap = switch (target) {
    .windows => void,
    else => @import("procmap.zig"),
};

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

pub fn map(addr: ?*anyopaque, size: usize, prot: Protection) MapError![]align(std.heap.page_size_min) u8 {
    return switch (target) {
        .windows => @alignCast(@as([*]u8, @ptrCast(try windows.VirtualAlloc(addr, size, windows.MEM_COMMIT | windows.MEM_RESERVE, prot.flags())))[0..size]),
        else => std.posix.mmap(@alignCast(@ptrCast(addr)), size, prot.flags(), .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0),
    };
}

pub fn unmap(mem: []align(std.heap.page_size_min) u8) void {
    return switch (target) {
        .windows => windows.VirtualFree(mem.ptr, 0, windows.MEM_RELEASE),
        else => std.posix.munmap(mem),
    };
}

var mmap_min_addr: usize = undefined;
var allocation_granularity: usize = undefined;

fn loadMinAddr() void {
    switch (target) {
        .windows => {
            var system_info: std.os.windows.SYSTEM_INFO = undefined;
            kernel32.GetSystemInfo(&system_info);
            mmap_min_addr = @intFromPtr(system_info.lpMinimumApplicationAddress);
        },
        else => {
            const min_addr_path = "/proc/sys/vm/mmap_min_addr";
            var buf: [16]u8 = .{0} ** 16;
            const fd = std.fs.openFileAbsolute(min_addr_path, .{}) catch @panic("cannot open " ++ min_addr_path);
            defer fd.close();

            const size = fd.read(&buf) catch @panic("cannot read " ++ min_addr_path);
            mmap_min_addr = std.fmt.parseInt(usize, buf[0 .. size - 1], 10) catch @panic("could not parse " ++ min_addr_path);
        },
    }
}

fn loadGranularity() void {
    switch (target) {
        .windows => {
            var system_info: std.os.windows.SYSTEM_INFO = undefined;
            kernel32.GetSystemInfo(&system_info);
            allocation_granularity = system_info.dwAllocationGranularity;
        },
        else => allocation_granularity = std.heap.page_size_min,
    }
}

var mmap_min_addr_once = std.once(loadMinAddr);
var allocation_granularity_once = std.once(loadGranularity);

pub const QueryError = switch (target) {
    .windows => windows.VirtualQueryError,
    else => procmap.ProcmapQuery.QueryError,
};

pub fn unmapped_area_near(addr: usize) QueryError!?usize {
    mmap_min_addr_once.call();
    allocation_granularity_once.call();

    const max_memory_range = std.math.maxInt(i32) / 2;

    switch (target) {
        .windows => {
            var probe_address: usize = if (max_memory_range > addr) mmap_min_addr else addr - max_memory_range;

            while (probe_address < addr + max_memory_range) {
                var memory_info: std.os.windows.MEMORY_BASIC_INFORMATION = undefined;
                const info_size = try std.os.windows.VirtualQuery(@ptrFromInt(probe_address), &memory_info, @sizeOf(std.os.windows.MEMORY_BASIC_INFORMATION));

                if (info_size == 0) {
                    break;
                }

                if (memory_info.State == std.os.windows.MEM_FREE) {
                    return probe_address;
                }

                probe_address += @intFromPtr(memory_info.AllocationBase) - 1;
                probe_address -= probe_address % allocation_granularity;
            }

            return null;
        },
        else => {
            var q: procmap.ProcmapQuery = .{
                .query_addr = if (max_memory_range > addr) mmap_min_addr else addr - max_memory_range + std.heap.page_size_min,
                .query_flags = .{ .vma_readable = true, .covering_or_next_vma = true },
            };

            q.query() catch |err| {
                switch (err) {
                    procmap.ProcmapQuery.QueryError.NotFound => return null,
                    else => return err,
                }
            };

            while (q.vma_start < q.query_addr) : (q.query() catch |err| {
                switch (err) {
                    procmap.ProcmapQuery.QueryError.NotFound => return null,
                    else => return err,
                }
            }) {
                if (q.vma_start >= addr + max_memory_range or q.vma_end > addr + max_memory_range)
                    return null;
                q.query_addr = q.vma_end;
            }

            return q.vma_end;
        },
    }
}

pub fn delta(a: usize, b: usize) isize {
    return switch (a > b) {
        true => @intCast(a - b),
        false => @as(isize, @intCast(b - a)) * -1,
    };
}
