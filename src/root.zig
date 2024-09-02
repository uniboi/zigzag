const std = @import("std");
const dis = @import("dis_x86_64");
const Disassembler = dis.Disassembler;
const ChunkAllocator = @import("ChunkAllocator.zig");
const mem = @import("mem.zig");

const max_instruction_size = 15;
pub const trampoline_buffer_size = (max_instruction_size * 2) + @sizeOf(JMP_ABS);

pub fn getPages(target: usize) []align(std.mem.page_size) u8 {
    const pageAlignedPtr: [*]u8 = @ptrFromInt(std.mem.alignBackward(usize, target, std.mem.page_size));
    return @alignCast(pageAlignedPtr[0..std.mem.page_size]); // TODO: check if patched instructions cross page boundaries
}

const TrampolineBuffer = std.io.FixedBufferStream([]u8);
const TrampolineWriteError = error{InsufficientBufferSize} || Disassembler.Error || TrampolineBuffer.WriteError || error{CannotEncode};

/// returns amount of copied bytes
fn writeTrampolineBody(dest: usize, source: usize) TrampolineWriteError!usize {
    const dest_bytes: [*]u8 = @ptrFromInt(dest);
    const source_bytes: [*]u8 = @ptrFromInt(source);

    var trampoline_buffer = std.io.fixedBufferStream(dest_bytes[0..trampoline_buffer_size]);
    const trampoline_writer = trampoline_buffer.writer();

    const min_size = @sizeOf(JMP_ABS);

    var disassembler = Disassembler.init(source_bytes[0 .. min_size + max_instruction_size]);

    var last_pos: usize = 0;

    while (try disassembler.next()) |ins| : (last_pos = disassembler.pos) {
        if (last_pos >= min_size) {
            break;
        }

        const ins_buf = source_bytes[last_pos .. disassembler.pos + 1];
        const op = ins.encoding.data.opc[0];

        const written = written: {
            if (isAnyOpRip(ins.ops)) {
                std.debug.print("RIP operand {}\n", .{ins});
                @panic("todo");
            } else if (op & 0xFD == 0xE9) {
                std.debug.print("Relative call {}\n", .{ins});
                @panic("todo");
            } else if (op & 0xF0 == 0x70 or op & 0xFC == 0xE0 or ins.encoding.data.opc[1] & 0xF0 == 0x80) {
                std.debug.print("Relative JMP {}\n", .{ins});

                const diff: i32 = diff: {
                    const source_instruction_address = source + disassembler.pos;
                    const trampoline_instruction_address = dest + trampoline_buffer.pos;

                    if (applyOffset(trampoline_instruction_address, @intCast(ins.ops[0].imm.signed)) < trampoline_instruction_address + min_size) {
                        std.debug.print("???\n", .{});
                        break :diff ins.ops[0].imm.signed;
                    }

                    // const d = if (source_instruction_address > trampoline_instruction_address) source_instruction_address - trampoline_instruction_address else trampoline_instruction_address - source_instruction_address;
                    const d: i32 = @intCast((source_instruction_address + @as(u32, @intCast(ins.ops[0].imm.signed))) - trampoline_instruction_address);

                    std.debug.print("src: 0x{x}, dest: 0x{x}, rel: 0x{x}\n", .{ source_instruction_address, trampoline_instruction_address, applyOffset(trampoline_instruction_address, d) });
                    std.debug.print("original rel: {x} {}\n", .{ source_instruction_address + @as(u32, @intCast(ins.ops[0].imm.signed)), d < std.math.maxInt(i32) });
                    std.debug.print("diff: {}\n", .{d});

                    break :diff d;
                };

                var modified_ins = ins;
                modified_ins.ops[0].imm.signed = diff;

                try modified_ins.encode(trampoline_writer, .{});
                break :written ins_buf.len;
            } else {
                break :written try trampoline_writer.write(ins_buf);
            }
        };

        if (written < ins_buf.len) {
            return TrampolineWriteError.InsufficientBufferSize;
        }
    }

    // while (try disassembler.next()) |ins| {
    //     if (last_pos >= min_size) {
    //         break;
    //     }

    //     @memcpy(dest_bytes[last_pos..disassembler.pos], source_bytes[last_pos..disassembler.pos]);

    //     const instruction_size = disassembler.pos - last_pos;
    //     const old_instruction: usize = @intFromPtr(source_bytes) + last_pos;
    //     const op = ins.encoding.data.opc[0];

    //     _ = instruction_size;
    //     _ = old_instruction;

    //     if (isAnyOpRip(ins.ops)) {
    //         std.debug.print("RIP operand {}\n", .{ins});
    //     } else if (op == 0xE8) {
    //         std.debug.print("Relative call {}\n", .{ins});
    //     } else if (op & 0xFD == 0xE9) {
    //         // relative jmp E8 or E9
    //         std.debug.print("Relative JMP {}\n", .{ins});
    //     } else if (op & 0xF0 == 0x70 or op & 0xFC == 0xE0 or ins.encoding.data.opc[1] & 0xF0 == 0x80) {
    //         std.debug.print("(relative jcc) {}\n", .{ins});
    //         std.debug.print("ops: {any}\n", .{ins.ops});

    //         // const jcc_dest: usize =
    //         //     if (op & 0xF0 == 0x70 or op & 0xFC == 0xE0)
    //         //     applyOffset(old_instruction + instruction_size, @intCast(ins.ops[0].imm.signed))
    //         // else
    //         //     old_instruction + instruction_size + ins.ops[0].imm.unsigned;

    //         // const jcc_dest: usize = if (ins.ops[0].imm == .signed) applyOffset(old_instruction + instruction_size, @intCast(ins.ops[0].imm.signed)) else old_instruction + instruction_size + ins.ops[0].imm.unsigned;

    //         // const jcc_dest: usize = old_instruction;

    //         // if (dest <= jcc_dest and jcc_dest < dest + @sizeOf(JMP_REL) * 8) {
    //         //     std.debug.print("op is in bounds\n", .{});
    //         // } else {
    //         //     std.debug.print("rip address is not in bounds {x} {x}:{x} ins size: {d}\n", .{ jcc_dest, dest, dest + @sizeOf(JMP_REL) * 8, instruction_size });
    //         // }
    //     }

    //     last_pos = disassembler.pos;
    // }

    return last_pos;
}

fn applyOffset(n: usize, offset: isize) usize {
    return if (offset < 0) n -| @as(usize, @intCast(-offset)) else n +| @as(usize, @intCast(offset));
}

fn isAnyOpRip(ops: [4]dis.Instruction.Operand) bool {
    return (ops[0] == .mem and ops[0].mem == .rip) or (ops[1] == .mem and ops[1].mem == .rip) or (ops[2] == .mem and ops[2].mem == .rip) or (ops[3] == .mem and ops[3].mem == .rip);
}

fn writeAbsoluteJump(address: [*]u8, destination: usize) void {
    const jmp: JMP_ABS = .{ .addr = destination };
    @memcpy(address[0..@sizeOf(JMP_ABS)], @as([*]const u8, @ptrCast(&jmp)));
}

pub const Error = error{
    UnavailableNearbyPage,
} || ChunkAllocator.ReserveChunkError || Disassembler.Error || std.posix.MProtectError || TrampolineWriteError || ChunkAllocator.AllocBlockError;

/// target function body must be at least 13 bytes large
pub fn Hook(comptime T: type) type {
    return struct {
        const Self = @This();

        target: *T,
        replaced_instructions: [30]u8,
        delegate: *const T,
        allocator: ChunkAllocator,

        /// Construct a hook to change all calls for `target` to `payload`
        pub fn init(chunk_allocator: ChunkAllocator, target: *T, payload: *const T) Error!Self {
            const target_address = @intFromPtr(target);
            const target_bytes: [*]u8 = @ptrCast(target);
            const original_instructions: [30]u8 = target_bytes[0..30].*;

            // allow writing instructions in the pages that need to be patched
            const pages = getPages(target_address);
            try std.posix.mprotect(pages, std.posix.PROT.READ | std.posix.PROT.WRITE | std.posix.PROT.EXEC);

            // TODO: try to allocate a new buffer if no chunks are free
            const trampoline_buffer = try chunk_allocator.alloc(target_address);
            const trampoline_size = try writeTrampolineBody(@intFromPtr(trampoline_buffer), target_address);

            // writeAbsoluteJump(@ptrFromInt(@intFromPtr(trampoline_buffer) + trampoline_size));
            const jmp_to_resume: JMP_ABS = .{ .addr = target_address + trampoline_size };
            @memcpy(trampoline_buffer[trampoline_size .. trampoline_size + @sizeOf(JMP_ABS)], @as([*]const u8, @ptrCast(&jmp_to_resume)));

            const jmp_to_hook: JMP_ABS = .{ .addr = @intFromPtr(payload) };
            @memcpy(target_bytes[0..@sizeOf(JMP_ABS)], @as([*]const u8, @ptrCast(&jmp_to_hook)));

            // TODO: query status out of /proc/self/maps before overwriting access and revert to it here
            try std.posix.mprotect(pages, std.posix.PROT.READ | std.posix.PROT.EXEC);

            return .{
                .target = target,
                .delegate = @ptrCast(trampoline_buffer),
                .replaced_instructions = original_instructions,
                .allocator = chunk_allocator,
            };
        }

        /// revert patched instructions in the `target` body.
        /// returns `false` if memory protections cannot be updated.
        pub fn deinit(self: Self) bool {
            self.allocator.free(@ptrCast(self.delegate));

            const pages = getPages(@intFromPtr(self.target));

            std.posix.mprotect(pages, std.posix.PROT.READ | std.posix.PROT.WRITE | std.posix.PROT.EXEC) catch return false;
            const body: [*]u8 = @ptrCast(self.target);
            @memcpy(body, &self.replaced_instructions);
            std.posix.mprotect(pages, std.posix.PROT.READ | std.posix.PROT.EXEC) catch return false;

            return true;
        }

        fn initTrampoline() void {}
    };
}

/// 64 bit indirect absolute jump
const JMP_ABS = packed struct {
    op1: u8 = 0xFF,
    op2: u8 = 0x25,
    dummy: u32 = 0x0,
    addr: u64,
};

const JMP_REL = packed struct {
    opcode: u8,
    operand: u32,
};
