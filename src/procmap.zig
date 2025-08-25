/// see linux/fs.h UAPI struct procmap_query
/// Input/output argument passed into ioctl() call.
pub const ProcmapQuery = extern struct {
    /// in
    size: u64 = @sizeOf(ProcmapQuery),
    /// in
    query_flags: QueryFlags,
    /// in
    query_addr: u64,

    /// out
    vma_start: u64 = 0,
    /// out
    vma_end: u64 = 0,
    /// out
    vma_flags: VmaFlags = .{},
    /// out
    vma_page_size: u64 = 0,
    /// out
    vma_offset: u64 = 0,

    /// out
    inode: u64 = 0,
    /// out
    dev_major: u32 = 0,
    /// out
    dev_minor: u32 = 0,

    /// in/out
    vma_name_size: u32 = 0,
    /// in/out
    build_id_size: u32 = 0,
    /// in
    vma_name_addr: u64 = 0,
    /// in
    build_id_addr: u64 = 0,

    pub const QueryFlags = packed struct(u64) {
        vma_readable: bool = false,
        vma_writable: bool = false,
        vma_executable: bool = false,
        vma_shared: bool = false,

        covering_or_next_vma: bool = false,
        file_backed_vma: bool = false,
        _: u58 = 0,
    };

    pub const VmaFlags = packed struct(u64) {
        readable: bool = false,
        writable: bool = false,
        executable: bool = false,
        shared: bool = false,
        _: u60 = 0,

        pub fn prot(f: VmaFlags) mem.Protection {
            return .{ .read = f.readable, .write = f.writable, .execute = f.executable };
        }
    };

    pub const QueryError = error{
        /// EBADF
        BadFileDescriptor,
        /// ENOTTY
        BadProcmapHandle,
        /// EFAULT
        BadAddress,
        /// EINVAL
        InvalidArgument,
        /// E2BIG
        /// provided vma_name or build_id buffer is too small
        BufferExceeded,
        /// ESRCH
        NoSuchProcess,
        /// ENOENT
        NotFound,
    } || std.fs.File.OpenError;

    pub fn query(q: *ProcmapQuery) QueryError!void {
        const fd = try std.fs.openFileAbsolute("/proc/self/maps", .{});
        defer fd.close();

        const err = std.os.linux.ioctl(fd.handle, procmap_query, @intFromPtr(q));
        if (err < 0) return switch (std.posix.errno(err)) {
            .BADF => return QueryError.BadFileDescriptor,
            .NOTTY => return QueryError.BadProcmapHandle,
            .FAULT => return QueryError.BadAddress,
            .INVAL => return QueryError.InvalidArgument,
            .@"2BIG" => return QueryError.BufferExceeded,
            .SRCH => return QueryError.NoSuchProcess,
            .NOENT => return QueryError.NotFound,
            else => unreachable,
        };
    }
};

const procfs_ioctl_magic = 'f';
const procmap_query = std.os.linux.IOCTL.IOWR(procfs_ioctl_magic, 17, ProcmapQuery);

const std = @import("std");
const mem = @import("mem.zig");

test {
    var q: ProcmapQuery = .{
        .query_addr = 0,
        .query_flags = .{ .covering_or_next_vma = true },
    };

    for(0..20) |_| {
        std.debug.print("{x}\n", .{q.query_addr});
        try q.query();
        std.debug.print("{x}-{x}\n", .{q.vma_start, q.vma_end});
        if(q.query_addr == q.vma_end) break;
        q.query_addr = q.vma_end + 1;
    }
}
