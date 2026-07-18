const std = @import("std");
const CompUnit = @import("../../CompUnit.zig");
const Ramir = @This();

link_sym: []const u8,
blocks: std.ArrayList(Block),
imms: std.ArrayList(CompUnit.Immediate),

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
        label,

        mov,
        push,
        pop,
        cmp,
        xor,

        add,
        sub,
        mul,
        div,

        setcc,
        ret,
        jmp,
        jcc,
        call,
    };

    pub const Data = union {
        none: void,
        u16: u16,
        c_u16: C_U16,
        r: Reg,
        rr: Rr,
        ri: Ri,
        rm: Rm,
        m: Mem,
        cr: Cr,
        cm: Cm,

        pub const C_U16 = struct {
            cond: Cond,
            int: u16,
        };

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
            u16,
            c_u16,
            r,
            rr,
            ri,
            rm,
            mr,
            m,
            cr,
            cm,
        };
    };
};

pub const Term = union(enum) {
    none,
    not_reachable,
    jmp: Block.Id,
    branch: Branch,

    pub const Branch = struct {
        cond: Cond,
        then_jmp: Block.Id,
        else_jmp: Block.Id,
    };
};

pub const Cond = enum {
    eq,
    neq,
    ult,
    ule,
    ugt,
    uge,

    pub fn opposite(cond: Cond) Cond {
        return switch (cond) {
            .eq => .neq,
            .neq => .eq,
            .ult => .uge,
            .ule => .ugt,
            .ugt => .ule,
            .uge => .ult,
        };
    }
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
        global: CompUnit.Global.Ref,
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

        pub fn toFactor(scale: Scale) usize {
            return switch (scale) {
                .@"1" => 1,
                .@"2" => 2,
                .@"4" => 4,
                .@"8" => 8,
            };
        }
    };
};

pub fn print(ramir: Ramir, term: std.Io.Terminal) !void {
    const writer = term.writer;
    try writer.print("fn '{s}':\n", .{ramir.link_sym});

    for (ramir.blocks.items, 0..) |block, block_id| {
        term.setColor(.red) catch {};
        try writer.print("@{}", .{block_id});
        term.setColor(.reset) catch {};
        try writer.print(":\n", .{});

        for (0..block.insts.len) |inst_id| {
            const inst = block.insts.get(inst_id);

            term.setColor(.yellow) catch {};
            try writer.print("{s} ", .{@tagName(inst.tag)});
            term.setColor(.reset) catch {};

            switch (inst.data_kind) {
                .none => {},
                .u16 => try writer.print("{}", .{inst.data.u16}),
                .c_u16 => {
                    term.setColor(.yellow) catch {};
                    try writer.print("{s}", .{@tagName(inst.data.c_u16.cond)});
                    term.setColor(.reset) catch {};
                    try writer.print(" {}", .{inst.data.c_u16.int});
                },
                .r => {
                    term.setColor(.cyan) catch {};
                    try writer.print("{s}", .{@tagName(inst.data.r)});
                },
                .rr => {
                    const d = inst.data.rr;

                    term.setColor(.cyan) catch {};
                    try writer.print("{s}", .{@tagName(d.r1)});
                    term.setColor(.reset) catch {};
                    try writer.print(", ", .{});
                    term.setColor(.cyan) catch {};
                    try writer.print("{s}", .{@tagName(d.r2)});
                },
                .ri => {
                    const d = inst.data.ri;

                    term.setColor(.cyan) catch {};
                    try writer.print("{s}", .{@tagName(d.r)});
                    term.setColor(.reset) catch {};
                    try writer.print(", ", .{});
                    try ramir.imms.items[d.i].print(term);
                },
                .m => try printMem(term, inst.data.m),
                .rm => {
                    const d = inst.data.rm;

                    term.setColor(.cyan) catch {};
                    try writer.print("{s}", .{@tagName(d.r)});
                    term.setColor(.reset) catch {};
                    try writer.print(", ", .{});
                    try printMem(term, d.m);
                },
                .mr => {
                    const d = inst.data.rm;

                    try printMem(term, d.m);
                    try writer.print(", ", .{});
                    term.setColor(.cyan) catch {};
                    try writer.print("{s}", .{@tagName(d.r)});
                },
                .cr => {
                    const d = inst.data.cr;
                    try writer.print("{s} ? {s}", .{ @tagName(d.c), @tagName(d.r) });
                },
                .cm => {
                    const d = inst.data.cm;
                    try writer.print("{s} ? ", .{@tagName(d.c)});
                    try printMem(term, d.m);
                },
            }

            term.setColor(.reset) catch {};
            try writer.print("\n", .{});
        }

        term.setColor(.yellow) catch {};
        switch (block.term) {
            .none => try writer.print("no terminator", .{}),
            .not_reachable => try writer.print("unreachable", .{}),
            .jmp => |target| {
                try writer.print("jmp ", .{});
                term.setColor(.red) catch {};
                try writer.print("@{}", .{target});
            },
            .branch => |b| {
                try writer.print("branch {s}", .{@tagName(b.cond)});
                term.setColor(.reset) catch {};
                try writer.print(" ? ", .{});
                term.setColor(.red) catch {};
                try writer.print("@{}", .{b.then_jmp});
                term.setColor(.reset) catch {};
                try writer.print(" : ", .{});
                term.setColor(.red) catch {};
                try writer.print("@{}", .{b.else_jmp});
            },
        }

        term.setColor(.reset) catch {};
        try writer.print("\n\n", .{});
    }
}

fn printMem(term: std.Io.Terminal, mem: Mem) !void {
    const writer = term.writer;
    term.setColor(.reset) catch {};
    try writer.print("[", .{});

    switch (mem.base) {
        .none => {},
        .reg => |reg| {
            term.setColor(.cyan) catch {};
            try writer.print("{s}", .{@tagName(reg)});
            term.setColor(.reset) catch {};
            try writer.print(" + ", .{});
        },
        .global => |global_id| {
            try CompUnit.Immediate.print(.{ .global_addr = global_id }, term);
            term.setColor(.reset) catch {};
            try writer.print(" + ", .{});
        },
    }

    switch (mem.mod) {
        .off => |off| {
            term.setColor(.blue) catch {};
            try writer.print("0x{x}", .{off});
        },
        .rm => |rm| {
            term.setColor(.cyan) catch {};
            try writer.print("{s}", .{@tagName(rm.index)});

            if (rm.scale != .@"1") {
                term.setColor(.reset) catch {};
                try writer.print(" * ", .{});
                term.setColor(.blue) catch {};
                try writer.print(" * {}", .{rm.scale.toFactor()});
            }

            term.setColor(.reset) catch {};
            if (rm.disp > 0) {
                try writer.print(" + ", .{});
            } else if (rm.disp < 0) {
                try writer.print(" - ", .{});
            }

            term.setColor(.blue) catch {};
            try writer.print("0x{x}", .{@abs(rm.disp)});
        },
    }

    term.setColor(.reset) catch {};
    try writer.print("]", .{});
}
