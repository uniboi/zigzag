const std = @import("std");
const zds = @import("dis_x86_64");
const Disassembler = zds.Disassembler;
const Operand = zds.Instruction.Operand;

const zz = @import("root.zig");
const Hook = zz.Hook;
const TrampolineBuffer = zz.SharedExecutableBlock;
// const SharedBlocks = zz.SharedBlocks;
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

    const add = lib.lookup(*AddSignature, "add").?;
    const add_hook = try Hook(AddSignature).init(chunk_allocator, add, add_detour);
    defer _ = add_hook.deinit();
    std.debug.print("delegate: {}\n", .{add_hook.delegate});
    try std.testing.expect(add_hook.delegate(1, 2) == 3);
    // try std.testing.expect(add(1, 2) == 4);

    // const hello = lib.lookup(*HelloSignature, "hello").?;
    // const hello_hook = try Hook(HelloSignature).init(chunk_allocator, hello, &hello_detour);
    // hello_hook.delegate();
}
