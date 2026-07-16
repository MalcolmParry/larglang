const std = @import("std");
const CompUnit = @import("../../CompUnit.zig");
const Ramir = @import("Ramir.zig");

pub fn emit(writer: *std.Io.Writer, comp_unit: CompUnit) !void {
    try writer.print(
        \\.intel_syntax noprefix
        \\.code64
        \\
    , .{});

    var export_iter = comp_unit.export_symbols.keyIterator();
    while (export_iter.next()) |sym| {
        try writer.print(
            \\.global {s}
            \\
        , .{sym.*});
    }

    try writer.print(
        \\.section .text
        \\
    , .{});

    for (comp_unit.funcs.values()) |func| {
        try emitFunc(writer, comp_unit, func.ramir.?);

        try writer.print("\n", .{});
    }

    try writer.print(
        \\.section .data
        \\
    , .{});

    var global_iter = comp_unit.globals.iterator();
    while (global_iter.next()) |kv| {
        try writer.print(
            \\{s}:
            \\    .quad {}
            \\
        , .{ kv.key_ptr.*, kv.value_ptr.initial_value });
    }

    for (comp_unit.data.items, 0..) |data, id| {
        try writer.print(
            \\D{}:
            \\    .ascii "{s}"
            \\
        , .{ id, data });
    }

    for (comp_unit.global_asm.items) |str| {
        try writer.print("\n{s}\n", .{str});
    }
}

pub fn emitFunc(writer: *std.Io.Writer, comp_unit: CompUnit, ramir: Ramir) !void {
    std.debug.assert(ramir.blocks.items.len == 1);

    const block = ramir.blocks.items[0];
    std.debug.assert(block.term == .not_reachable);

    try writer.print("{s}:\n", .{ramir.link_sym});
    for (0..block.insts.len) |inst_id| {
        const inst = block.insts.get(inst_id);

        const tab = "    ";
        switch (inst.tag) {
            .label => {
                try writer.print(".L{}:\n", .{inst.data.u16});
                continue;
            },
            .jmp => {
                try writer.print(tab ++ "jmp .L{}\n", .{inst.data.u16});
                continue;
            },
            .jcc => {
                const d = inst.data.c_u16;
                const cond_ext: []const u8 = switch (d.cond) {
                    .eq => "e",
                    .neq => "ne",
                    .ult => "l",
                    .ule => "le",
                    .ugt => "g",
                    .uge => "ge",
                };

                try writer.print(tab ++ "j{s} .L{}\n", .{ cond_ext, d.int });
                continue;
            },
            else => {},
        }

        try writer.print(tab ++ "{s} ", .{@tagName(inst.tag)});
        switch (inst.data_kind) {
            .none => {},
            .u16 => try writer.print("{}", .{inst.data.u16}),
            .c_u16 => try writer.print("{s} {}", .{ @tagName(inst.data.c_u16.cond), inst.data.c_u16.int }),
            .r => try writer.print("{s}", .{@tagName(inst.data.r)}),
            .rr => try writer.print("{s}, {s}", .{ @tagName(inst.data.rr.r1), @tagName(inst.data.rr.r2) }),
            .ri => {
                try writer.print("{s}, ", .{@tagName(inst.data.ri.r)});
                try printImm(writer, comp_unit, ramir, inst.data.ri.i);
            },
            .m => try printMem(writer, comp_unit, inst.data.m),
            .rm => {
                const d = inst.data.rm;
                try writer.print("{s}, ", .{@tagName(d.r)});
                try printMem(writer, comp_unit, d.m);
            },
            .mr => {
                const d = inst.data.rm;
                try printMem(writer, comp_unit, d.m);
                try writer.print(", {s}", .{@tagName(d.r)});
            },
            else => unreachable,
        }

        try writer.print("\n", .{});
    }
}

fn printImm(writer: *std.Io.Writer, comp_unit: CompUnit, ramir: Ramir, imm: Ramir.ImmId) !void {
    const val = ramir.imms.items[imm];

    switch (val) {
        .int => |int| try writer.print("{}", .{int}),
        .global_addr => |global_ref| try writer.print("{s}", .{comp_unit.globals.keys()[global_ref]}),
        .data_addr => |data_addr| try writer.print("offset D{}", .{data_addr}),
    }
}

fn printMem(writer: *std.Io.Writer, comp_unit: CompUnit, mem: Ramir.Mem) !void {
    try writer.print("[", .{});

    switch (mem.base) {
        .none => {},
        .reg => |reg| try writer.print("{s} + ", .{@tagName(reg)}),
        .global => |global_ref| try writer.print("{s} + ", .{comp_unit.globals.keys()[global_ref]}),
    }

    switch (mem.mod) {
        .off => |off| try writer.print("{}", .{off}),
        .rm => |rm| {
            try writer.print("{s}", .{@tagName(rm.index)});

            if (rm.scale != .@"1") try writer.print(" * {}", .{rm.scale.toFactor()});

            if (rm.disp > 0) {
                try writer.print(" + {}", .{rm.disp});
            } else if (rm.disp < 0) {
                try writer.print(" - {}", .{-rm.disp});
            }
        },
    }

    try writer.print("]", .{});
}
