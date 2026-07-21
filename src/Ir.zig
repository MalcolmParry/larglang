const std = @import("std");
const CompUnit = @import("CompUnit.zig");
const Ir = @This();

pub const gen = @import("ir_gen.zig");
pub const opt = @import("ir_opt.zig");

link_sym: []const u8,
blocks: std.ArrayList(Block),
imms: std.ArrayList(CompUnit.Immediate),
extra_val_refs: std.ArrayList(ValueRef),
stack_slots: std.ArrayList(StackSlot),

pub fn deinit(func: *Ir, alloc: std.mem.Allocator) void {
    for (func.blocks.items) |*block| block.deinit(alloc);
    func.blocks.deinit(alloc);
    func.imms.deinit(alloc);
    func.extra_val_refs.deinit(alloc);
    func.stack_slots.deinit(alloc);
}

pub fn appendImm(func: *Ir, alloc: std.mem.Allocator, val: CompUnit.Immediate) !ValueRef {
    try func.imms.append(alloc, val);
    return .{
        .tag = .imm,
        .data = @intCast(func.imms.items.len - 1),
    };
}

pub const StackSlot = struct {
    size: u32,
};

pub const BlockId = u32;
pub const Block = struct {
    arg_count: u32,
    insts: std.ArrayList(Inst),
    terminator: Terminator,

    pub fn deinit(block: *Block, alloc: std.mem.Allocator) void {
        block.insts.deinit(alloc);
        block.terminator.deinit(alloc);
    }

    pub fn kill(block: *Block, alloc: std.mem.Allocator) void {
        block.deinit(alloc);
        block.* = .{
            .arg_count = 0,
            .insts = .empty,
            .terminator = .dead,
        };
    }

    pub fn isDead(block: Block) bool {
        return block.terminator == .dead;
    }

    pub fn isEmpty(block: Block) bool {
        var empty: bool = true;

        for (block.insts.items) |inst| {
            if (inst.tag != .no_op)
                empty = false;
        }

        return empty;
    }

    pub fn appendInst(block: *Block, alloc: std.mem.Allocator, inst: Inst) !ValueRef {
        try block.insts.append(alloc, inst);
        return .fromInst(@intCast(block.insts.items.len - 1));
    }
};

pub const Terminator = union(enum) {
    /// block currently under construction, not valid in final ir
    none,
    /// tombstone
    dead,
    ret: ValueRef,
    jmp: Jmp,
    branch: Branch,

    pub fn deinit(term: *Terminator, alloc: std.mem.Allocator) void {
        switch (term.*) {
            .none, .dead, .ret => {},
            .jmp => |*jmp| jmp.deinit(alloc),
            .branch => |*branch| {
                branch.true_jmp.deinit(alloc);
                branch.false_jmp.deinit(alloc);
            },
        }
    }

    pub const Jmp = struct {
        block_id: BlockId,
        args: std.ArrayList(ValueRef),

        pub fn deinit(jmp: *Jmp, alloc: std.mem.Allocator) void {
            jmp.args.deinit(alloc);
        }
    };

    pub const Branch = struct {
        condition: ValueRef,
        true_jmp: Jmp,
        false_jmp: Jmp,
    };
};

pub const ImmRef = u14;
pub const InstRef = u14;
pub const StackSlotRef = u14;
pub const ValueRef = packed struct(u16) {
    /// instruction index when tag = .inst
    /// arg index when tag = .arg
    data: u14,
    tag: Tag,

    pub const Tag = enum(u2) {
        inst,
        arg,
        imm,
        stack_addr,
    };

    pub fn fromInst(inst_id: u14) ValueRef {
        return .{ .tag = .inst, .data = inst_id };
    }

    pub fn fromArg(arg_id: u14) ValueRef {
        return .{ .tag = .arg, .data = arg_id };
    }
};

pub const Inst = struct {
    tag: Tag,
    data: Data,

    pub const Tag = enum {
        no_op,
        add,
        sub,
        mul,
        div,
        eq,
        neq,
        less,
        more,

        load,
        load_b,
        store,
        store_b,

        call,

        pub fn getDataKind(tag: Tag) Data.Kind {
            return switch (tag) {
                .no_op => .none,
                .add, .sub, .mul, .div, .eq, .neq, .less, .more, .store, .store_b => .bin,
                .load, .load_b => .unary,
                .call => .val_ref_list,
            };
        }

        pub fn hasSideEffects(tag: Tag) bool {
            return switch (tag) {
                .store, .store_b, .call => true,
                else => false,
            };
        }
    };

    pub const Data = union {
        unary: ValueRef,
        bin: BinOp,
        val_ref_list: ValRefList,

        pub const Kind = enum {
            none,
            unary,
            bin,
            val_ref_list,
        };
    };

    pub const BinOp = struct {
        left: ValueRef,
        right: ValueRef,
    };

    pub const ValRefList = struct {
        /// in extra array
        start: u16,
        len: u16,
    };

    pub const noop: Inst = .{ .tag = .no_op, .data = undefined };
    pub fn unary(tag: Tag, ref: ValueRef) Inst {
        std.debug.assert(tag.getDataKind() == .unary);
        return .{
            .tag = tag,
            .data = .{ .unary = ref },
        };
    }

    pub fn bin(tag: Tag, left: ValueRef, right: ValueRef) Inst {
        std.debug.assert(tag.getDataKind() == .bin);
        return .{
            .tag = tag,
            .data = .{ .bin = .{
                .left = left,
                .right = right,
            } },
        };
    }
};

pub fn print(ir: Ir, term: std.Io.Terminal) std.Io.Writer.Error!void {
    const writer = term.writer;
    try writer.print("fn '{s}':\n", .{ir.link_sym});

    term.setColor(.yellow) catch {};
    try writer.print("stack slots", .{});
    term.setColor(.reset) catch {};
    try writer.print(" [", .{});
    for (ir.stack_slots.items, 0..) |slot, slot_id| {
        term.setColor(.reset) catch {};
        if (slot_id != 0) try writer.print(", ", .{});
        term.setColor(.blue) catch {};
        try writer.print("0x{x}", .{slot.size});
    }

    term.setColor(.reset) catch {};
    try writer.print("]\n", .{});

    for (ir.blocks.items, 0..) |block, block_id| {
        term.setColor(.red) catch {};
        try writer.print("@{}", .{block_id});
        term.setColor(.reset) catch {};

        try writer.print("(", .{});
        for (0..block.arg_count) |arg_id| {
            term.setColor(.magenta) catch {};
            try writer.print("%{}", .{arg_id});
            term.setColor(.reset) catch {};

            if (arg_id != block.arg_count - 1)
                try writer.print(", ", .{});
        }

        try writer.print("):\n", .{});

        for (block.insts.items, 0..) |inst, inst_id| {
            term.setColor(.green) catch {};
            try writer.print("${}", .{inst_id});
            term.setColor(.reset) catch {};
            try writer.print(" = ", .{});
            term.setColor(.yellow) catch {};
            try writer.print("{s} ", .{@tagName(inst.tag)});
            term.setColor(.reset) catch {};

            switch (inst.tag.getDataKind()) {
                .none => {},
                .unary => {
                    try printValRef(term, ir, inst.data.unary);
                },
                .bin => {
                    const bin = inst.data.bin;
                    try printValRef(term, ir, bin.left);
                    try writer.print(", ", .{});
                    try printValRef(term, ir, bin.right);
                },
                .val_ref_list => {
                    const d = inst.data.val_ref_list;
                    const slice = ir.extra_val_refs.items[d.start..][0..d.len];

                    for (slice, 0..) |ref, i| {
                        if (i != 0) try writer.print(", ", .{});
                        try printValRef(term, ir, ref);
                    }
                },
            }

            try writer.print("\n", .{});
        }

        term.setColor(.yellow) catch {};
        switch (block.terminator) {
            .none => try writer.print("block under construction", .{}),
            .dead => try writer.print("dead block", .{}),
            .ret => |val| {
                try writer.print("ret ", .{});
                try printValRef(term, ir, val);
            },
            .jmp => |jmp| {
                try writer.print("jmp ", .{});
                try printJmp(term, ir, jmp);
            },
            .branch => |branch| {
                try writer.print("branch ", .{});
                try printValRef(term, ir, branch.condition);
                try writer.print(" ? ", .{});
                try printJmp(term, ir, branch.true_jmp);
                try writer.print(" : ", .{});
                try printJmp(term, ir, branch.false_jmp);
            },
        }

        term.setColor(.reset) catch {};
        try writer.print("\n\n", .{});
    }
}

fn printJmp(term: std.Io.Terminal, ir: Ir, jmp: Terminator.Jmp) !void {
    const writer = term.writer;
    term.setColor(.red) catch {};
    try writer.print("@{}", .{jmp.block_id});
    term.setColor(.reset) catch {};
    try writer.print("(", .{});

    for (jmp.args.items, 0..) |arg, i| {
        try printValRef(term, ir, arg);

        if (i != jmp.args.items.len - 1)
            try writer.print(", ", .{});
    }

    try writer.print(")", .{});
}

fn printValRef(term: std.Io.Terminal, ir: Ir, ref: ValueRef) !void {
    const writer = term.writer;
    term.setColor(switch (ref.tag) {
        .inst => .green,
        .arg => .magenta,
        .imm => .blue,
        .stack_addr => .yellow,
    }) catch {};

    switch (ref.tag) {
        .inst => try writer.print("${}", .{ref.data}),
        .arg => try writer.print("%{}", .{ref.data}),
        .imm => try ir.imms.items[ref.data].print(term),
        .stack_addr => try writer.print("^{}", .{ref.data}),
    }

    term.setColor(.reset) catch {};
}
