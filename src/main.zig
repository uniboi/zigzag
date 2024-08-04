const std = @import("std");
const zds = @import("dis_x86_64");
const Disassembler = zds.Disassembler;

const Hook = @import("root.zig").Hook;
const Trampoline = @import("root.zig").Trampoline;

const AddSignature = fn (c_int, c_int) callconv(.C) c_int;

fn add_hook(a: c_int, b: c_int) callconv(.C) c_int {
    return a + b + 1;
}

pub fn main() !void {
    var lib = try std.DynLib.open("./zig-out/bin/cExampleLib.dll");
    defer lib.close();

    const add = lib.lookup(*AddSignature, "add").?;

    // regular call
    const r1 = add(1, 2);
    try std.testing.expect(r1 == 3);
    std.debug.print("{d}\n", .{r1});

    // create a hook
    const hook = try Hook(AddSignature).init(add, &add_hook);

    // expect hooked result
    const r2 = add(1, 2);
    try std.testing.expect(r2 == 4);
    std.debug.print("{d}\n", .{r2});

    // destroy the hook
    _ = hook.deinit();

    // regular call
    const r3 = add(1, 2);
    try std.testing.expect(r3 == 3);
    std.debug.print("{d}\n", .{r3});

    const addr = try findPreviousFreeRegion(@intFromPtr(add));
    std.debug.print("add: {}; address: {?x}\n", .{ add, addr });
    if (addr) |address| {
        const buf = try Trampoline.init(address, 32);
        defer _ = buf.deinit();
        std.debug.print("buf1: {}\n", .{buf});

        var memory_info: std.os.windows.MEMORY_BASIC_INFORMATION = undefined;
        _ = try std.os.windows.VirtualQuery(buf, &memory_info, @sizeOf(std.os.windows.MEMORY_BASIC_INFORMATION));
        std.debug.print("protection of trampoline page: {}\n", .{memory_info.Protect & std.os.windows.PAGE_EXECUTE_READWRITE});

        const mut_add: [*]u8 = @ptrCast(add);
        const buf_bytes: [*]u8 = @ptrCast(buf);

        var disassembler = Disassembler.init(mut_add[0..32]);
        var last_pos: usize = 0;

        while (try disassembler.next()) |ins| {
            if (last_pos >= @sizeOf(JMP_ABS)) {
                break;
            }

            // std.debug.print("copy instruction from {} to {} ({})\n", .{ last_pos, disassembler.pos, disassembler.pos - last_pos });
            std.debug.print("{}\n", .{ins});
            // _ = ins;

            @memcpy(buf_bytes[last_pos..disassembler.pos], mut_add[last_pos..disassembler.pos]);
            last_pos = disassembler.pos;

            // TODO: patch RIP operands
        }

        //const jmp_to_trampoline: JMP_ABS = .{ .addr = @intFromPtr(buf) };
        //@memset(mut_add[0..disassembler.pos], 0x90);
        //@memcpy(mut_add[0..@sizeOf(JMP_ABS)], @as([*]const u8, @ptrCast(&jmp_to_trampoline)));

        const jmp_resume: JMP_ABS = .{ .addr = @intFromPtr(mut_add + last_pos) };
        @memcpy(buf_bytes[last_pos .. last_pos + @sizeOf(JMP_ABS)], @as([*]const u8, @ptrCast(&jmp_resume)));

        std.debug.print("abs jmp size: {}, last pos: {}\n", .{ @sizeOf(JMP_ABS), last_pos });

        const jmp_to_hook: JMP_ABS = .{ .addr = @intFromPtr(&add_hook) };
        @memcpy(mut_add[0..@sizeOf(JMP_ABS)], @as([*]const u8, @ptrCast(&jmp_to_hook)));

        const t_add: *const AddSignature = @ptrCast(buf);
        const r = t_add(1, 3);
        std.debug.print("tramp: {}\n", .{r});

        const rh = add(1, 4);
        std.debug.print("h result: {}\n", .{rh});
    }

    // _ = add(1, 1);

    // var disassembler = Disassembler.init(@as([*]const u8, @ptrCast(add))[0..128]);

    // var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    // const gpa = general_purpose_allocator.allocator();
    // var text = std.ArrayList(u8).init(gpa);
    // defer text.deinit();

    // for (0..9) |_| {
    //     const ins = try disassembler.next();
    //     try text.writer().print("{?}\n", .{ins});
    // }

    // std.debug.print("{s}\n", .{text.items});
}

/// 64 bit indirect absolute jump
const JMP_ABS = packed struct {
    op1: u8 = 0xFF,
    op2: u8 = 0x25,
    dummy: u32 = 0x0,
    addr: u64,
};

/// seek within 32 bit range
fn findPreviousFreeRegion(address: usize) std.os.windows.VirtualQueryError!?usize {
    var system_info: std.os.windows.SYSTEM_INFO = undefined;
    std.os.windows.kernel32.GetSystemInfo(&system_info);

    // std.debug.print("page size: {}\n", .{system_info.dwAllocationGranularity});

    const min_address = if (std.math.maxInt(u32) > address)
        @intFromPtr(system_info.lpMinimumApplicationAddress)
    else
        address - std.math.maxInt(u32);

    var probe_address = address;

    // TODO: this is from minhook, not quite sure if allat is required
    probe_address -= probe_address % system_info.dwAllocationGranularity;
    probe_address -= system_info.dwAllocationGranularity;

    while (probe_address > min_address) {
        var memory_info: std.os.windows.MEMORY_BASIC_INFORMATION = undefined;
        const info_size = try std.os.windows.VirtualQuery(@ptrFromInt(probe_address), &memory_info, @sizeOf(std.os.windows.MEMORY_BASIC_INFORMATION));

        if (info_size == 0) {
            break;
        }

        if (memory_info.State == std.os.windows.MEM_FREE) {
            return probe_address;
        }

        probe_address -= @intFromPtr(memory_info.AllocationBase) - system_info.dwAllocationGranularity;
    }

    return null;
}

fn createTrampolineBuffer() std.os.windows.VirtualQueryError!void {
    var mem_info: std.os.windows.MEMORY_BASIC_INFORMATION = undefined;
    const info_size = try std.os.windows.VirtualQuery(@ptrFromInt(0), &mem_info, @sizeOf(std.os.windows.MEMORY_BASIC_INFORMATION));
    _ = info_size;
}
