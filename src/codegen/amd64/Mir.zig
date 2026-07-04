const std = @import("std");
const Mir = @This();

link_sym: []const u8,
blocks: std.ArrayList(Block),
imms: std.ArrayList(u64),

pub const ImmId = u26;
pub const ArgId = u26;
pub const Block = struct {
    arg_count: u32,
    insts: std.MultiArrayList(Inst),
    term: Term,

    pub const Id = u32;
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
    };

    pub const Data = union {
        none: void,
        bin: Bin,

        pub const Bin = struct {
            left: ValueRef,
            right: ValueRef,
        };
    };
};

pub const Term = union(enum) {
    none: void,
    ret: ValueRef,
    jmp: Jmp,
    branch_bool: BranchBool,
    branch_cmp: BranchCmp,

    pub const Jmp = struct {
        block_id: Block.Id,
        args: std.ArrayList(ValueRef),
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
