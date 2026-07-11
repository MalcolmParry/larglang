const std = @import("std");
const Ramir = @import("Ramir.zig");

pub fn emit(writer: *std.Io.Writer, ramir: Ramir) !void {
    std.debug.assert(ramir.blocks.items.len == 1);

    const block = ramir.blocks.items[0];
    std.debug.assert(block.term == .not_reachable);

    try writer.print(
        \\section .text
        \\bits 64
        \\
    , .{});

    if (ramir.flags.export_) {
        try writer.print("global {s}\n", .{ramir.link_sym});
    }

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
}

fn printMem(writer: *std.Io.Writer, mem: Ramir.Mem) !void {
    try writer.print("[", .{});

    switch (mem.base) {
        .none => {},
        .reg => |reg| try writer.print("{s} + ", .{@tagName(reg)}),
        .block => |block_id| try writer.print("@{} + ", .{block_id}),
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
