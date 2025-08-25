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

    pub const everything: Protection = .{ .read = true, .write = true, .execute = true };

    fn flags(prot: Protection) u32 {
        return switch (target) {
            .windows => prot.winapiFlags(),
            .linux => prot.posixFlags(),
            else => unreachable,
        };
    }

    fn posixFlags(p: Protection) u32 {
        var f: u32 = 0;
        f |= if (p.read) PROT.READ else PROT.NONE;
        f |= if (p.write) PROT.WRITE else PROT.NONE;
        f |= if (p.execute) PROT.EXEC else PROT.NONE;

        return f;
    }

    fn winapiFlags(p: Protection) u32 {
        // TODO: this could just be a switch on a packed struct once it's in the langauge
        if (p == Protection{}) return windows.PAGE_NOACCESS;
        if (p == Protection{ .read = true }) return windows.PAGE_READONLY;
        if (p == Protection{ .read = true, .write = true }) return windows.PAGE_READWRITE;
        if (p == Protection{ .execute = true }) return windows.PAGE_EXECUTE;
        if (p == Protection{ .read = true, .execute = true }) return windows.PAGE_EXECUTE_READ;
        if (p == Protection{ .read = true, .write = true, .execute = true }) return windows.PAGE_EXECUTE_READWRITE;

        // +w -r is not allowed
        unreachable;
    }

    fn fromWinapi(f: u32) Protection {
        return switch (f) {
            windows.PAGE_READONLY => .{ .read = true },
            windows.PAGE_READWRITE, windows.PAGE_WRITECOPY => .{ .read = true, .write = true },
            windows.PAGE_EXECUTE => .{ .execute = true },
            windows.PAGE_EXECUTE_READ => .{ .execute = true },
            windows.PAGE_EXECUTE_READWRITE, windows.PAGE_EXECUTE_WRITECOPY => .{ .execute = true, .read = true, .write = true },
            else => .{},
        };
    }

    fn fromPosix(f: u32) Protection {
        return .{
            .read = f & PROT.READ != 0,
            .write = f & PROT.WRITE != 0,
            .execute = f & PROT.EXEC != 0,
        };
    }

    test {
        const a: Protection = .everything;
        try std.testing.expect(a.flagsLinux() == PROT.WRITE | PROT.READ | PROT.EXEC);

        const b: Protection = .{ .read = true };
        try std.testing.expect(b.flagsLinux() == PROT.READ);

        const c: Protection = .{ .write = true };
        try std.testing.expect(c.flagsLinux() == PROT.WRITE);

        const d: Protection = .{ .execute = true };
        try std.testing.expect(d.flagsLinux() == PROT.EXEC);

        const e: Protection = .{};
        try std.testing.expect(e.flagsLinux() == PROT.NONE);
    }
};

pub const MapError = switch (target) {
    .windows => windows.VirtualAllocError,
    else => std.posix.MMapError,
};

pub const ProtectError = switch (target) {
    .windows => error{ AccessDenied, Unexpected },
    .linux => error{ AccessDenied, OutOfMemory, Unexpected } || procmap.ProcmapQuery.QueryError,
    else => unreachable,
};

pub fn map(addr: ?*anyopaque, size: usize, prot: Protection) MapError![]align(std.heap.page_size_min) u8 {
    return switch (target) {
        .windows => @alignCast(@as([*]u8, @ptrCast(try windows.VirtualAlloc(addr, size, windows.MEM_COMMIT | windows.MEM_RESERVE, prot.flags())))[0..size]),
        else => std.posix.mmap(@ptrCast(@alignCast(addr)), size, prot.flags(), .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0),
    };
}

pub fn unmap(mem: []align(std.heap.page_size_min) u8) void {
    return switch (target) {
        .windows => windows.VirtualFree(mem.ptr, 0, windows.MEM_RELEASE),
        .linux => std.posix.munmap(mem),
        else => unreachable,
    };
}

pub fn protect(mem: []align(std.heap.page_size_min) u8, prot: Protection) ProtectError!Protection {
    switch (target) {
        .windows => {
            var prev: windows.DWORD = undefined;
            windows.VirtualProtect(mem.ptr, mem.len, prot.winapiFlags(), &prev) catch |err| switch (err) {
                error.InvalidAddress => return error.AccessDenied,
                error.Unexpected => return error.Unexpected,
            };

            return .fromWinapi(prev);
        },
        .linux => {
            var q: procmap.ProcmapQuery = .{ .query_addr = @intFromPtr(mem.ptr), .query_flags = .{} };
            try q.query();

            try std.posix.mprotect(mem, prot.posixFlags());
            return q.vma_flags.prot();
        },
        else => unreachable,
    }
}

var mmap_min_addr: usize = undefined;
var allocation_granularity: usize = undefined; // windows only
var page_size: usize = undefined;

fn loadMemStats() void {
    switch(target) {
        .windows => {
            var system_info: std.os.windows.SYSTEM_INFO = undefined;
            kernel32.GetSystemInfo(&system_info);
            mmap_min_addr = @intFromPtr(system_info.lpMinimumApplicationAddress);
            allocation_granularity = system_info.dwAllocationGranularity;
        },
        .linux => {
            const min_addr_path = "/proc/sys/vm/mmap_min_addr";
            var buf: [32]u8 = @splat(0);
            const fd = std.fs.openFileAbsolute(min_addr_path, .{}) catch @panic("cannot open " ++ min_addr_path);
            defer fd.close();

            const size = fd.read(&buf) catch @panic("cannot read " ++ min_addr_path);
            mmap_min_addr = std.fmt.parseInt(usize, buf[0 .. size - 1], 10) catch @panic("could not parse " ++ min_addr_path);
            // allocation_granularity = std.heap.pageSize();
            page_size = std.heap.pageSize();
        },
        else => unreachable,
    }
}

var mem_stats_once = std.once(loadMemStats);

pub const Range = struct {
    /// inclusive
    from: usize,
    /// inclusive
    to: usize,

    pub fn contains(r: Range, addr: usize) bool {
        return r.from >= addr and r.to <= addr;
    }

    pub fn intersects(a: Range, b: Range) bool {
        return a.from >= b.from or a.to <= b.to;
    }

    /// Construct the range [origin - x; origin + x]
    pub fn symmetric(origin: usize, x: u32) Range {
        return .{
            .from = origin - x,
            .to = origin + x,
        };
    }

    /// Calculate max and min possible addresses for the trampoline relative to the target address
    pub fn rip(addr: usize) Range {
        const to = b: {
            if (addr > std.math.maxInt(usize) - std.math.maxInt(i32)) break :b std.math.maxInt(usize);
            break :b addr + std.math.maxInt(i32);
        };

        if (addr < std.math.maxInt(i32) + 1) {
            return .{
                .from = mmap_min_addr,
                .to = to,
            };
        }

        const from: usize = addr - std.math.maxInt(u32) / 2;
        return .{
            .from = if (from < mmap_min_addr) mmap_min_addr else from,
            .to = to,
        };
    }

    test {
        {
            const a: Range = .{ .from = 0, .to = 10 };
            const b: Range = .{ .from = 5, .to = 15 };
            try std.testing.expect(a.intersects(b));
            try std.testing.expect(b.intersects(a));
        }

        {
            const a: Range = .{ .from = 5, .to = 10 };
            const b: Range = .{ .from = 4, .to = 6 };
            try std.testing.expect(b.intersects(a));
        }
    }
};

pub const QueryError = switch (target) {
    .windows => windows.VirtualQueryError,
    .linux => procmap.ProcmapQuery.QueryError,
    else => unreachable,
};

fn vmaGapSize(addr: usize) QueryError!usize {
    var q: procmap.ProcmapQuery = .{
        .query_addr = addr,
        .query_flags = .{ .covering_or_next_vma = true },
    };
    try q.query();

    // no further VMAs are mapped
    if (q.query_addr >= q.vma_end) {
        return std.math.maxInt(usize) - addr;
    }

    return q.vma_start - addr;
}

/// Returns the starting address of a page that starts within the range
fn findUnmappedAreaWithinLinux(bounds: Range, gap_size: usize) QueryError!?usize {
    var q: procmap.ProcmapQuery = .{
        .query_addr = bounds.from,
        .query_flags = .{ .covering_or_next_vma = true },
    };

    try q.query();
    while (q.vma_end <= bounds.to) {
        // no further VMAs are mapped
        if (q.query_addr >= q.vma_end) {
            return q.vma_end;
        }

        // we found a gap between VMAs
        if (q.vma_start > q.query_addr and try vmaGapSize(std.mem.alignBackward(usize, q.query_addr, page_size)) >= gap_size) {
            return std.mem.alignBackward(usize, q.query_addr, page_size);
        }

        q.query_addr = q.vma_end;
        try q.query();
    }

    return null;
}

/// Returns an address contained within a page that starts within the provided range
fn findUnmappedAreaWithinWindows(bounds: Range, gap_size: usize) QueryError!?usize {
    var probe_address = std.mem.alignBackward(usize, bounds.from, allocation_granularity);
    while (probe_address < bounds.to) {
        var memory_info: std.os.windows.MEMORY_BASIC_INFORMATION = undefined;
        const info_size = try std.os.windows.VirtualQuery(@ptrFromInt(probe_address), &memory_info, @sizeOf(@TypeOf(memory_info)));

        if (info_size == 0) {
            break;
        }

        if (memory_info.State == std.os.windows.MEM_FREE and memory_info.RegionSize >= gap_size) {
            return probe_address;
        }

        probe_address = @intFromPtr(memory_info.BaseAddress) + memory_info.RegionSize;
        probe_address += allocation_granularity - 1;
        probe_address = std.mem.alignBackward(usize, probe_address, allocation_granularity);
    }

    return null;
}

/// bounds: min & max address where we're looking for an unallocated vma
/// size: minimum size of the vma required
pub fn findUnmappedAreaWithin(bounds: Range, size: usize) QueryError!?usize {
    mem_stats_once.call();
    return switch (target) {
        .windows => findUnmappedAreaWithinWindows(bounds, size),
        .linux => findUnmappedAreaWithinLinux(bounds, size),
        else => unreachable,
    };
}

pub fn delta(a: usize, b: usize) isize {
    return switch (a > b) {
        true => @intCast(a - b),
        false => @as(isize, @intCast(b - a)) * -1,
    };
}
