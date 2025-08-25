const std = @import("std");
const SYSTEM_INFO = std.os.windows.SYSTEM_INFO;

pub extern "kernel32" fn GetSystemInfo(lpSystemInfo: *SYSTEM_INFO) callconv(.winapi) void;
