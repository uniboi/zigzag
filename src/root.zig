const std = @import("std");
const dis = @import("dis_x86_64");
const Disassembler = dis.Disassembler;
const ChunkAllocator = @import("ChunkAllocator.zig");
const mem = @import("mem.zig");

const max_instruction_size = 15;
pub const trampoline_buffer_size = (max_instruction_size * 2) + @sizeOf(JMP_ABS);

// TODO: Move to mem
pub fn getPages(target: usize) []align(std.mem.page_size) u8 {
    const pageAlignedPtr: [*]u8 = @ptrFromInt(std.mem.alignBackward(usize, target, std.mem.page_size));
    return @alignCast(pageAlignedPtr[0..std.mem.page_size]); // TODO: check if patched instructions cross page boundaries
}

const TrampolineBuffer = std.io.FixedBufferStream([]u8);
const TrampolineWriteError = error{InsufficientBufferSize} || Disassembler.Error || TrampolineBuffer.WriteError || error{CannotEncode};

/// returns amount of copied bytes
fn writeTrampolineBody(dest: usize, source: usize) TrampolineWriteError!usize {
    const min_size = @sizeOf(JMP_ABS);
    const dest_bytes: [*]u8 = @ptrFromInt(dest);
    const source_bytes: [*]u8 = @ptrFromInt(source);

    var trampoline_buffer = std.io.fixedBufferStream(dest_bytes[0..trampoline_buffer_size]);
    const trampoline_writer = trampoline_buffer.writer();

    var disassembler = Disassembler.init(source_bytes[0 .. min_size + max_instruction_size]);

    var last_pos: usize = 0;

    while (try disassembler.next()) |ins| : (last_pos = disassembler.pos) {
        if (last_pos >= min_size) {
            break;
        }

        std.debug.assert(ins.encoding.data.opc.len > 0);
        // std.debug.print("{}\n", .{ins});

        const ins_buf = source_bytes[last_pos..disassembler.pos];
        const opcode = ins.encoding.data.opc[0];
        const cpy_ins_addr = dest + trampoline_buffer.pos;
        const ins_addr = @intFromPtr(ins_buf.ptr);

        if (ripOpIndex(ins.ops)) |op_index| {
            // instruction contains a %rip operand

            const abs_ins_diff: isize = if (ins_addr > cpy_ins_addr) @intCast(ins_addr - cpy_ins_addr) else @as(isize, @intCast(cpy_ins_addr - ins_addr)) - 1;
            const new_disp = abs_ins_diff + ins.ops[op_index].mem.rip.disp;

            const rip_dest = applyOffset(ins_addr, ins.ops[op_index].mem.rip.disp); // omitted instruction len because it's irrelevant for the calculation
            const new_dest = applyOffset(cpy_ins_addr, new_disp);
            std.debug.assert(rip_dest == new_dest);

            var cpy_ins = ins;
            cpy_ins.ops[op_index].mem.rip.disp = @intCast(new_disp);

            try cpy_ins.encode(trampoline_writer, .{});
        } else if (opcode == 0xE8 or opcode == 0xE9) {
            // TODO: verify that this works for 0xE9
            // relative call / uncoditional jmp

            const diff: i32 = @intCast(mem.delta(ins_addr, cpy_ins_addr));
            const new_disp = diff + ins.ops[0].imm.signed;

            const original_dest = applyOffset(ins_addr, ins.ops[0].imm.signed);

            if (applyOffset(ins_addr, new_disp) + ins_buf.len > dest + min_size) {
                const new_dest = applyOffset(cpy_ins_addr, new_disp);
                std.debug.assert(original_dest == new_dest);

                var cpy_ins = ins;
                cpy_ins.ops[0].imm.signed = new_disp;
                try cpy_ins.encode(trampoline_writer, .{});
            } else {
                // copy an internal jump
                try trampoline_writer.writeAll(ins_buf);
            }
        } else if (opcode & 0xF0 == 0x70 or opcode & 0xFC == 0xE0 or ins.encoding.data.opc[1] & 0xF0 == 0x80) {
            // relative conditional jump
            const diff: i32 = @intCast(mem.delta(ins_addr, cpy_ins_addr));
            const new_disp = diff + ins.ops[0].imm.signed;

            // FIXME: Handle edge cases like loops, intern jmps, etc.

            var cpy_ins = ins;
            cpy_ins.ops[0].imm.signed = new_disp;
            try cpy_ins.encode(trampoline_writer, .{});

            // @panic("todo: relative conditional jmp");
        } else {
            // instruction without positional properties
            // simply copy the exact instruction. No need to reencode
            try trampoline_writer.writeAll(ins_buf);
        }
    }

    return last_pos;
}

fn applyOffset(n: usize, offset: isize) usize {
    return if (offset < 0) n -| @as(usize, @intCast(-offset)) else n +| @as(usize, @intCast(offset));
}

fn ripOpIndex(ops: [4]dis.Instruction.Operand) ?usize {
    for (ops, 0..) |op, i| {
        if (op == .mem and op.mem == .rip) {
            return i;
        }
    }

    return null;
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
