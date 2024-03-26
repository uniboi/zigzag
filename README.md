# Zigzag

Zigzag is a cross platform x86_64 hooking library for Windows and Linux.

## API

### Basic Hooks

```zig
const std = @import("std");
const Hook = @import("root.zig").Hook;

// this is the target function to hook
fn add(a: i32, b: i32) i32 {
    return a + b;
}

// this is the hook that replaces `add`
fn add_hook(a: i32, b: i32) i32 {
    return a + b + 1;
}

fn main() !void {
    std.testing.expect(add(1, 2), 3);

    const hook = Hook(@TypeOf(add)).init(
        @constCast(&add), // get a mutable pointer to the target
        add_hook,
    );
    defer _ = hook.deinit();

    std.testing.expect(add(1, 2), 4);
);
}
```

### Hooking functions from a library

You can hook any address you have access to.

```c
// this is the function in another library we want to hook
int add(int a, int b) {
    return a + b;
}
```

```zig
const std = @import("std");
const Hook = @import("root.zig").Hook;

fn add_hook(a: c_int, b: c_int) c_int {
    return a + b + 1;
}

const AddSignature = fn (c_int, c_int) callconv(.C) c_int;

pub fn main() !void {
    // load the library with the target
    var lib = try std.DynLib.open("/some/math/lib.so");
    defer lib.close();

    // get a pointer to the function you want to hook
    const add = lib.lookup(*AddSignature, "add").?; 
    try std.testing.expect(add(1, 2), 3);

    // install hook
    const hook = Hook(AddSignature).init(add, add_hook); 
    // defer _ = hook.deinit(); // uninstall hook when scope ends

    // expect result to be 4 because of the hook
    try std.testing.expect(add(1, 2), 4);

    _ = hook.deinit(); // uninstall the hook and restore the previous function
                       // returns false when the hook cannot be uninstalled because memory page permissions could not be updated

    try std.testing.expect(add(1, 2), 3); // function is unmodified again
}
```
