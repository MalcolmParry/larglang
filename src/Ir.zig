const std = @import("std");
const Ir = @This();

funcs: std.ArrayList(Func),

pub fn deinit(ir: *Ir, alloc: std.mem.Allocator) void {
    for (ir.funcs.items) |*func| {
        func.deinit(alloc);
    }

    ir.funcs.deinit(alloc);
}

pub const Func = struct {
    link_sym: []const u8,
    blocks: std.ArrayList(Block),
    imms: std.ArrayList(u64),
    flags: Flags,

    pub const Flags = packed struct {
        export_: bool,
    };

    pub fn deinit(func: *Func, alloc: std.mem.Allocator) void {
        for (func.blocks.items) |*block| block.deinit(alloc);
        func.blocks.deinit(alloc);
        func.imms.deinit(alloc);
    }

    pub fn appendImm(func: *Func, alloc: std.mem.Allocator, val: u64) !ValueRef {
        try func.imms.append(alloc, val);
        return .{
            .tag = .imm,
            .data = @intCast(func.imms.items.len - 1),
        };
    }

    pub fn format(func: Func, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try printFunc(writer, func);
    }
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
pub const ValueRef = packed struct(u16) {
    /// instruction index when tag = .inst
    /// arg index when tag = .arg
    data: u14,
    tag: Tag,

    pub const Tag = enum(u2) {
        inst,
        arg,
        imm,
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
        equal,
        less,
        more,

        pub fn getDataKind(tag: Tag) Data.Kind {
            return switch (tag) {
                .no_op => .none,
                .add, .sub, .mul, .div, .equal, .less, .more => .bin,
            };
        }

        pub fn hasSideEffects(tag: Tag) bool {
            _ = tag;
            return false;
        }
    };

    pub const Data = union {
        bin: BinOp,

        pub const Kind = enum {
            none,
            bin,
        };
    };

    pub const BinOp = struct {
        left: ValueRef,
        right: ValueRef,
    };

    pub const noop: Inst = .{ .tag = .no_op, .data = undefined };
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

pub fn printFunc(writer: *std.Io.Writer, func: Func) !void {
    if (func.flags.export_) {
        try writer.print("export ", .{});
    }

    try writer.print("fn '{s}':\n", .{func.link_sym});

    for (func.blocks.items, 0..) |block, block_id| {
        try writer.print("@{}(", .{block_id});

        for (0..block.arg_count) |arg_id| {
            try writer.print("%{}", .{arg_id});

            if (arg_id != block.arg_count - 1)
                try writer.print(", ", .{});
        }

        try writer.print("):\n", .{});

        for (block.insts.items, 0..) |inst, inst_id| {
            try writer.print("${} = {s} ", .{ inst_id, @tagName(inst.tag) });

            switch (inst.tag.getDataKind()) {
                .none => {},
                .bin => {
                    const bin = inst.data.bin;
                    try printValRef(writer, func, bin.left);
                    try writer.print(", ", .{});
                    try printValRef(writer, func, bin.right);
                },
            }

            try writer.print("\n", .{});
        }

        switch (block.terminator) {
            .none => try writer.print("block under construction", .{}),
            .dead => try writer.print("dead block", .{}),
            .ret => |val| {
                try writer.print("ret ", .{});
                try printValRef(writer, func, val);
            },
            .jmp => |jmp| {
                try writer.print("jmp ", .{});
                try printJmp(writer, func, jmp);
            },
            .branch => |branch| {
                try writer.print("branch ", .{});
                try printValRef(writer, func, branch.condition);
                try writer.print(" ? ", .{});
                try printJmp(writer, func, branch.true_jmp);
                try writer.print(" : ", .{});
                try printJmp(writer, func, branch.false_jmp);
            },
        }

        try writer.print("\n\n", .{});
    }
}

fn printJmp(writer: *std.Io.Writer, func: Func, jmp: Terminator.Jmp) !void {
    try writer.print("@{}(", .{jmp.block_id});

    for (jmp.args.items, 0..) |arg, i| {
        try printValRef(writer, func, arg);

        if (i != jmp.args.items.len - 1)
            try writer.print(", ", .{});
    }

    try writer.print(")", .{});
}

fn printValRef(writer: *std.Io.Writer, func: Func, ref: ValueRef) !void {
    switch (ref.tag) {
        .inst => try writer.print("${}", .{ref.data}),
        .arg => try writer.print("%{}", .{ref.data}),
        .imm => try writer.print("{}", .{func.imms.items[ref.data]}),
    }
}
