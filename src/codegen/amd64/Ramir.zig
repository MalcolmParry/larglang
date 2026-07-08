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
        push,
        pop,
        cmp,
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
        r: Reg,
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
    ult,
    ugt,
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

pub fn format(ramir: Ramir, writer: *std.Io.Writer) !void {
    try writer.print("fn '{s}':\n", .{ramir.link_sym});

    for (ramir.blocks.items, 0..) |block, block_id| {
        try writer.print("@{}:\n", .{block_id});

        for (0..block.insts.len) |inst_id| {
            const inst = block.insts.get(inst_id);

            try writer.print("{s} ", .{@tagName(inst.tag)});

            switch (inst.data_kind) {
                .none => {},
                .r => try writer.print("{s}", .{@tagName(inst.data.r)}),
                .rr => try writer.print("{s}, {s}", .{ @tagName(inst.data.rr.r1), @tagName(inst.data.rr.r2) }),
                .ri => try writer.print("{s}, {}", .{ @tagName(inst.data.ri.r), ramir.imms.items[inst.data.ri.i] }),
                .m => try printMem(writer, inst.data.m),
                .rm => {
                    const d = inst.data.rm;
                    try writer.print("{s}, ", .{@tagName(d.r)});
                    try printMem(writer, d.m);
                },
                .mr => {
                    const d = inst.data.rm;
                    try printMem(writer, d.m);
                    try writer.print(", {s}", .{@tagName(d.r)});
                },
                .cr => {
                    const d = inst.data.cr;
                    try writer.print("{s} ? {s}", .{ @tagName(d.c), @tagName(d.r) });
                },
                .cm => {
                    const d = inst.data.cm;
                    try writer.print("{s} ? ", .{@tagName(d.c)});
                    try printMem(writer, d.m);
                },
            }

            try writer.print("\n", .{});
        }

        switch (block.term) {
            .none => try writer.print("no terminator", .{}),
            .not_reachable => try writer.print("unreachable", .{}),
            .jmp => |target| try writer.print("jmp [@{}]", .{target}),
            .branch => |b| try writer.print("branch {s} ? @{} : @{}", .{ @tagName(b.cond), b.then_jmp, b.else_jmp }),
        }

        try writer.print("\n\n", .{});
    }
}

fn printMem(writer: *std.Io.Writer, mem: Mem) !void {
    try writer.print("[", .{});

    switch (mem.base) {
        .none => {},
        .reg => |reg| try writer.print("{s} + ", .{@tagName(reg)}),
        .block => |block_id| try writer.print("@{} + ", .{block_id}),
    }

    switch (mem.mod) {
        .off => |off| try writer.print("0x{x}", .{off}),
        .rm => |rm| {
            try writer.print("{s}", .{@tagName(rm.index)});

            if (rm.scale != .@"1") try writer.print(" * {}", .{rm.scale.toFactor()});

            if (rm.disp > 0) {
                try writer.print(" + 0x{x}", .{rm.disp});
            } else if (rm.disp < 0) {
                try writer.print(" - 0x{x}", .{-rm.disp});
            }
        },
    }

    try writer.print("]", .{});
}
