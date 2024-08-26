const std = @import("std");
const SYSTEM_INFO = std.os.windows.SYSTEM_INFO;
const WINAPI = std.os.windows.WINAPI;

pub extern "kernel32" fn GetSystemInfo(lpSystemInfo: *SYSTEM_INFO) callconv(WINAPI) void;
