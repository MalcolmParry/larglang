const std = @import("std");
const CompUnit = @import("../../CompUnit.zig");
const Mir = @This();

pub const gen = @import("mir_gen.zig");
pub const opt = @import("mir_opt.zig");

link_sym: []const u8,
blocks: std.ArrayList(Block),
imms: std.ArrayList(CompUnit.Immediate),
extra_val_refs: std.ArrayList(ValueRef),

pub fn deinit(mir: *Mir, alloc: std.mem.Allocator) void {
    for (mir.blocks.items) |*b| b.deinit(alloc);
    mir.blocks.deinit(alloc);
    mir.imms.deinit(alloc);
    mir.extra_val_refs.deinit(alloc);
}

pub const ImmId = u26;
pub const ArgId = u26;
pub const Block = struct {
    arg_count: u32,
    insts: std.MultiArrayList(Inst),
    term: Term,

    pub const Id = u32;
    pub fn deinit(block: *Block, alloc: std.mem.Allocator) void {
        block.insts.deinit(alloc);
        block.term.deinit(alloc);
    }
};

pub const Inst = struct {
    tag: Tag,
    data: Data,

    pub const Id = u26;
    pub const Tag = enum {
        no_op,

        add,
        sub,
        mul,
        udiv,

        cmp_eq,
        cmp_ult,
        cmp_ugt,

        load,
        store,

        call,

        pub fn hasSideEffects(tag: Tag) bool {
            return switch (tag) {
                .store, .call => true,
                else => false,
            };
        }

        pub fn getDataKind(tag: Tag) Data.Kind {
            return switch (tag) {
                .no_op => .none,
                .load => .unary,
                .add, .sub, .mul, .udiv, .cmp_eq, .cmp_ult, .cmp_ugt, .store => .bin,
                .call => .val_ref_list,
            };
        }
    };

    pub const Data = union {
        none: void,
        unary: ValueRef,
        bin: Bin,
        val_ref_list: ValRefList,

        pub const Bin = struct {
            left: ValueRef,
            right: ValueRef,
        };

        pub const ValRefList = struct {
            /// in extra array
            start: u16,
            len: u16,
        };

        pub const Kind = enum {
            none,
            unary,
            bin,
            val_ref_list,
        };
    };
};

pub const Term = union(enum) {
    none,
    ret: ValueRef,
    jmp: Jmp,
    branch_bool: BranchBool,
    branch_cmp: BranchCmp,

    pub const Jmp = struct {
        block_id: Block.Id,
        args: std.ArrayList(ValueRef),

        pub fn deinit(jmp: *Jmp, alloc: std.mem.Allocator) void {
            jmp.args.deinit(alloc);
        }
    };

    pub const BranchBool = struct {
        cond: ValueRef,
        then_jmp: Jmp,
        else_jmp: Jmp,
    };

    pub const BranchCmp = struct {
        cond: Cond,
        left: ValueRef,
        right: ValueRef,
        then_jmp: Jmp,
        else_jmp: Jmp,
    };

    pub fn deinit(term: *Term, alloc: std.mem.Allocator) void {
        switch (term.*) {
            .none, .ret => {},
            .jmp => |*jmp| jmp.deinit(alloc),
            .branch_bool => |*b| {
                b.then_jmp.deinit(alloc);
                b.else_jmp.deinit(alloc);
            },
            .branch_cmp => |*b| {
                b.then_jmp.deinit(alloc);
                b.else_jmp.deinit(alloc);
            },
        }
    }
};

pub const Cond = enum {
    eq,
    ult,
    ugt,
};

pub const ValueRef = packed struct(u32) {
    id: u26,
    tag: Tag,
    class: Class,

    pub const Tag = enum(u2) {
        inst,
        arg,
        imm,
    };

    pub const Class = enum(u4) {
        gp,
    };
};

pub fn print(mir: Mir, term: std.Io.Terminal) !void {
    const writer = term.writer;
    try writer.print("fn '{s}':\n", .{mir.link_sym});

    for (mir.blocks.items, 0..) |block, block_id| {
        term.setColor(.red) catch {};
        try writer.print("@{}", .{block_id});
        term.setColor(.reset) catch {};
        try writer.print("(", .{});

        for (0..block.arg_count) |arg_id| {
            if (arg_id != 0) try writer.print(", ", .{});
            term.setColor(.magenta) catch {};
            try writer.print("%{}", .{arg_id});
            term.setColor(.reset) catch {};
        }

        try writer.print("):\n", .{});

        for (0..block.insts.len) |inst_id| {
            const inst = block.insts.get(inst_id);

            term.setColor(.green) catch {};
            try writer.print("${}", .{inst_id});
            term.setColor(.reset) catch {};
            try writer.print(" = ", .{});
            term.setColor(.yellow) catch {};
            try writer.print("{s} ", .{@tagName(inst.tag)});
            term.setColor(.reset) catch {};

            switch (inst.tag) {
                .no_op => {},
                .load => try printValRef(term, mir, inst.data.unary),
                .add, .sub, .mul, .udiv, .cmp_ult, .cmp_eq, .cmp_ugt, .store => {
                    const data = inst.data.bin;
                    try printValRef(term, mir, data.left);
                    try writer.print(", ", .{});
                    try printValRef(term, mir, data.right);
                },
                .call => {
                    const data = inst.data.val_ref_list;
                    const slice = mir.extra_val_refs.items[data.start..][0..data.len];

                    for (slice, 0..) |ref, i| {
                        if (i != 0) try writer.print(", ", .{});
                        try printValRef(term, mir, ref);
                    }
                },
            }

            try writer.print("\n", .{});
        }

        term.setColor(.yellow) catch {};
        switch (block.term) {
            .none => try writer.print("no terminator", .{}),
            .jmp => |jmp| {
                try writer.print("jmp ", .{});
                try printJmp(term, mir, jmp);
            },
            .ret => |ref| {
                try writer.print("ret ", .{});
                try printValRef(term, mir, ref);
            },
            .branch_bool => |b| {
                try writer.print("branch_bool ", .{});
                try printValRef(term, mir, b.cond);
                try writer.print(" ? ", .{});
                try printJmp(term, mir, b.then_jmp);
                try writer.print(" : ", .{});
                try printJmp(term, mir, b.else_jmp);
            },
            .branch_cmp => |b| {
                try writer.print("branch_cmp", .{});
                term.setColor(.reset) catch {};
                try writer.print(" (", .{});

                try printValRef(term, mir, b.left);
                term.setColor(.yellow) catch {};
                try writer.print(" {s} ", .{@tagName(b.cond)});
                try printValRef(term, mir, b.right);
                try writer.print(") ? ", .{});
                try printJmp(term, mir, b.then_jmp);
                try writer.print(" : ", .{});
                try printJmp(term, mir, b.else_jmp);
            },
        }

        term.setColor(.reset) catch {};
        try writer.print("\n\n", .{});
    }
}

fn printJmp(term: std.Io.Terminal, mir: Mir, jmp: Term.Jmp) !void {
    const writer = term.writer;

    term.setColor(.red) catch {};
    try writer.print("@{}", .{jmp.block_id});
    term.setColor(.reset) catch {};
    try writer.print("(", .{});

    for (jmp.args.items, 0..) |ref, arg_id| {
        if (arg_id != 0) try writer.print(", ", .{});
        try printValRef(term, mir, ref);
    }
    try writer.print(")", .{});
}

fn printValRef(term: std.Io.Terminal, mir: Mir, ref: ValueRef) !void {
    const writer = term.writer;
    term.setColor(switch (ref.tag) {
        .inst => .green,
        .arg => .magenta,
        .imm => .blue,
    }) catch {};

    switch (ref.tag) {
        .inst => try writer.print("${}", .{ref.id}),
        .arg => try writer.print("%{}", .{ref.id}),
        .imm => try mir.imms.items[ref.id].print(term),
    }

    term.setColor(.reset) catch {};
}
