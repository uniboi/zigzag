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

pub fn _main() !void {
    const fd = try std.fs.openFileAbsolute("/proc/sys/vm/mmap_min_addr", .{});
    defer fd.close();

    var buf: [16]u8 = .{0} ** 16;
    const size = try fd.read(&buf);
    std.debug.print("mmap_min_addr {d}\n", .{try std.fmt.parseInt(u64, buf[0 .. size - 1], 10)});
}

pub fn main() !void {
    var lib = try std.DynLib.open("./zig-out/bin/cExampleLib.dll");
    defer lib.close();

    const add = lib.lookup(*AddSignature, "add").?;
    const square = lib.lookup(*SquareSignature, "square").?;
    const n_or_default = lib.lookup(*NOrDefaultSignature, "n_or_default").?;

    // regular call
    const r1 = add(1, 2);
    try std.testing.expect(r1 == 3);
    std.debug.print("{d}\n", .{r1});

    // var tr: SharedBlocks = .{};
    // defer tr.deinit();
    var pga = try PageChunkAllocator.init();
    defer pga.deinit();
    const chunk_allocator = pga.allocator();

    const hook = try Hook(AddSignature).init(chunk_allocator, add, &add_detour);

    // expect hooked result
    const r2 = add(1, 2);
    try std.testing.expect(r2 == 4);
    std.debug.print("{d}\n", .{r2});

    const rt = hook.delegate(1, 2);
    try std.testing.expect(rt == 3);
    std.debug.print("{d}\n", .{rt});

    // destroy the hook
    _ = hook.deinit();

    // regular call
    const r3 = add(1, 2);
    try std.testing.expect(r3 == 3);
    std.debug.print("{d}\n", .{r3});

    const sq_a = square(2);
    try std.testing.expect(sq_a == 4);

    const square_hook = try Hook(SquareSignature).init(chunk_allocator, square, &square_detour);
    defer _ = square_hook.deinit();
    const sq_b = square(2);
    try std.testing.expect(sq_b == 5);

    // const n_or_default_hook = try Hook(NOrDefaultSignature).init(chunk_allocator, n_or_default, &n_or_default_detour);
    // defer _ = n_or_default_hook.deinit();
    // const n_a = n_or_default(1);
    // try std.testing.expect(n_a == 20);
    // const n_b = n_or_default_hook.delegate(0);
    // try std.testing.expect(n_b == 10);

    const b: [*]u8 = @ptrCast(n_or_default);
    var dis = Disassembler.init(b[0..48]);
    while (try dis.next()) |ins| {
        if (ins.ops[1] == .mem and ins.ops[1].mem == .rip) {
            std.debug.print("{}\n", .{ins});
        }
    }
}
