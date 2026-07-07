const std = @import("std");
const Ramir = @This();

link_sym: []const u8,
blocks: std.ArrayList(Block),
imms: std.ArrayList(u64),

pub fn deinit(ramir: *Ramir, alloc: std.mem.Allocator) void {
    for (ramir.blocks.items) |*b| b.deinit(alloc);
    ramir.blocks.deinit(alloc);
    ramir.imms.deinit(alloc);
}

pub const ImmId = u16;
pub const Block = struct {
    insts: std.MultiArrayList(Inst),
    term: Term,

    pub const Id = u16;
    pub fn deinit(block: *Block, alloc: std.mem.Allocator) void {
        block.insts.deinit(alloc);
    }
};

pub const Inst = struct {
    tag: Tag,
    data: Data,
    data_kind: Data.Kind,

    pub const Tag = enum {
        no_op,

        mov,
        xor,

        add,
        sub,
        mul,
        udiv,

        setcc,
        // jmp,
        // jcc,
        ret,
    };

    pub const Data = union {
        none: void,
        rr: Rr,
        ri: Ri,
        rm: Rm,
        m: Mem,
        cr: Cr,
        cm: Cm,

        pub const Rr = struct {
            r1: Reg,
            r2: Reg,
        };

        pub const Ri = struct {
            r: Reg,
            i: ImmId,
        };

        pub const Rm = struct {
            r: Reg,
            m: Mem,
        };

        pub const Cr = struct {
            c: Cond,
            r: Reg,
        };

        pub const Cm = struct {
            c: Cond,
            m: Mem,
        };

        pub const Kind = enum {
            none,
            rr,
            ri,
            cr,
        };
    };
};

pub const Term = union(enum) {
    none,
    not_reachable,
    jmp: Block.Id,
    branch_bool: BranchBool,
    branch_cmp: BranchCmp,

    pub const BranchBool = struct {
        cond: Operand,
        then_jmp: Block.Id,
        else_jmp: Block.Id,
    };

    pub const BranchCmp = struct {
        cond: Cond,
        left: Operand,
        right: Operand,
        then_jmp: Block.Id,
        else_jmp: Block.Id,
    };
};

pub const Cond = enum {
    eq,
    ult,
    ugt,
};

pub const Operand = union(enum) {
    reg: Reg,
    imm: ImmId,
};

pub const Reg = enum {
    // zig fmt: off
    rax, rbx, rcx, rdx, rdi, rsi, rsp, rbp,
    r8, r9, r10, r11, r12, r13, r14, r15,

    eax, ebx, ecx, edx, edi, esi, esp, ebp,
    r8d, r9d, r10d, r11d, r12d, r13d, r14d, r15d,

    ax, bx, cx, dx, di, si, sp, bp,
    r8w, r9w, r10w, r11w, r12w, r13w, r14w, r15w,

    al, bl, cl, dl, dil, sil, spl, bpl,
    r8b, r9b, r10b, r11b, r12b, r13b, r14b, r15b,
    // zig fmt: on

    pub const Class = enum(u4) {
        gp,
    };
};

pub const Mem = struct {
    base: Base,
    mod: Mod,

    pub const Base = union(enum) {
        none,
        reg: Reg,
        block: Block.Id,
    };

    pub const Mod = union(enum) {
        rm: Rm,
        off: u64,

        pub const Rm = struct {
            index: Reg,
            scale: Scale,
            disp: i32,
        };
    };

    pub const Scale = enum {
        @"1",
        @"2",
        @"4",
        @"8",
    };
};
