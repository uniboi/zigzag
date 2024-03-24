const Hook = @This();

target: usize,
payload: usize,

// TODO: implement different kind of hook with a relay function for a smaller footprint
pub fn init(comptime T: type, target: *T, payload: *const T) Hook {
    return Hook{
        .target = @intFromPtr(target),
        .payload = @intFromPtr(payload),
    };
}

pub fn deinit(self: Hook) void {
    _ = self;
}
