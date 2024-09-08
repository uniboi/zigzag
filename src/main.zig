const std = @import("std");
const zds = @import("dis_x86_64");
const Disassembler = zds.Disassembler;
const Operand = zds.Instruction.Operand;

const pmparse = @import("pmparse");

const zz = @import("root.zig");
const Hook = zz.Hook;
const TrampolineBuffer = zz.SharedExecutableBlock;
const PageChunkAllocator = @import("PageChunkAllocator.zig");

const AddSignature = fn (c_int, c_int) callconv(.C) c_int;
const SquareSignature = fn (c_int) callconv(.C) c_int;
const NOrDefaultSignature = fn (c_int) callconv(.C) c_int;
const HelloSignature = fn () callconv(.C) void;

const target = @import("builtin").target.os.tag;

fn add_detour(a: c_int, b: c_int) callconv(.C) c_int {
    return a + b + 1;
}

fn square_detour(n: c_int) callconv(.C) c_int {
    return n * n + 1;
}

fn n_or_default_detour(n: c_int) callconv(.C) c_int {
    _ = n;
    return 20;
}

fn hello_detour() callconv(.C) void {
    std.debug.print("Hello World 2!\n", .{});
}

fn add2(a: i32, b: i32) i32 {
    return a + b;
}

fn add2_detour(a: i32, b: i32) i32 {
    return a + b + 1;
}

const Add2Signature = fn (i32, i32) i32;

pub fn main() !void {
    const lib_path = switch (target) {
        .windows => "./zig-out/bin/cExampleLib.dll",
        else => "./zig-out/lib/libcExampleLib.so",
    };

    var pca = try PageChunkAllocator.init();
    defer pca.deinit();
    const chunk_allocator = pca.allocator();

    var lib = try std.DynLib.open(lib_path);
    defer lib.close();

    const hello = lib.lookup(*HelloSignature, "hello").?;
    hello();

    const hello_hook = try Hook(HelloSignature).init(chunk_allocator, hello, hello_detour);
    defer _ = hello_hook.deinit();

    hello();
    hello_hook.delegate();

    const add = lib.lookup(*AddSignature, "add").?;
    const add_hook = try Hook(AddSignature).init(chunk_allocator, add, add_detour);
    defer _ = add_hook.deinit();
    const r1 = add(1, 2);
    const r2 = add_hook.delegate(1, 2);
    try std.testing.expect(r1 == 4);
    try std.testing.expect(r2 == 3);

    const n_or_default = lib.lookup(*NOrDefaultSignature, "n_or_default").?;
    const n1 = n_or_default(1);
    const n_or_default_hook = try Hook(NOrDefaultSignature).init(chunk_allocator, n_or_default, n_or_default_detour);
    defer _ = n_or_default_hook.deinit();

    const n2 = n_or_default(0);
    const n3 = n_or_default_hook.delegate(0);

    try std.testing.expect(n1 == 1);
    try std.testing.expect(n2 == 20);
    try std.testing.expect(n3 == 10);

    const nn1 = add2(1, 2);
    const add2_hook = try Hook(Add2Signature).init(chunk_allocator, @constCast(&add2), add2_detour);
    defer _ = add2_hook.deinit();

    const nn2 = add2(1, 2);
    const nn3 = add2_hook.delegate(1, 2);
    try std.testing.expect(nn1 == 3);
    try std.testing.expect(nn2 == 4);
    try std.testing.expect(nn3 == 3);
}
