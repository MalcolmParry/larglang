const std = @import("std");
const Ir = @import("Ir.zig");
const Mir = @import("codegen/amd64/Mir.zig");
const Ramir = @import("codegen/amd64/Ramir.zig");
const CompUnit = @This();

funcs: std.StringArrayHashMapUnmanaged(Func),
globals: std.StringArrayHashMapUnmanaged(Global),
export_symbols: std.StringHashMapUnmanaged(void),
global_asm: std.ArrayList([]u8),
global_constants: std.StringHashMapUnmanaged(Immediate),
data: std.ArrayList([]const u8),
extern_labels: std.StringArrayHashMapUnmanaged(void),

pub const DataAddrRef = u32;
pub const LabelRef = u32;
pub const FuncRef = u32;
pub const Func = struct {
    ir: Ir,
    mir: ?Mir,
    ramir: ?Ramir,

    pub fn deinit(func: *Func, alloc: std.mem.Allocator) void {
        func.ir.deinit(alloc);
        if (func.mir) |*x| x.deinit(alloc);
        if (func.ramir) |*x| x.deinit(alloc);
    }
};

pub const Label = packed struct(u32) {
    data: u30,
    tag: Tag,

    pub const Tag = enum(u2) {
        global,
        data,
        func,
        extern_label,
    };
};

pub const LabelAndOffset = struct {
    label: Label,
    offset: i32,
};

pub const Global = struct {
    initial_value: u64,

    pub const Ref = u32;
};

pub const Immediate = union(enum) {
    int: u64,
    label: LabelAndOffset,

    pub fn equal(left: Immediate, right: Immediate) bool {
        return std.meta.eql(left, right);
    }

    pub fn print(imm: Immediate, term: std.Io.Terminal) !void {
        const writer = term.writer;

        switch (imm) {
            .int => |val| {
                term.setColor(.blue) catch {};
                try writer.print("{}", .{val});
            },
            .label => |lo| {
                const l = lo.label;

                term.setColor(.reset) catch {};
                if (lo.offset != 0) {
                    try writer.print("(", .{});
                }

                switch (l.tag) {
                    .global => {
                        term.setColor(.white) catch {};
                        try writer.print("g{}", .{l.data});
                    },
                    .data => {
                        term.setColor(.yellow) catch {};
                        try writer.print("d{}", .{l.data});
                    },
                    .func => {
                        term.setColor(.red) catch {};
                        try writer.print("f{}", .{l.data});
                    },
                    .extern_label => {
                        term.setColor(.red) catch {};
                        try writer.print("l{}", .{l.data});
                    },
                }

                if (lo.offset != 0) {
                    term.setColor(.reset) catch {};
                    if (lo.offset > 0) {
                        try writer.print(" + ", .{});
                    } else {
                        try writer.print(" - ", .{});
                    }

                    term.setColor(.blue) catch {};
                    try writer.print("{}", .{@abs(lo.offset)});
                    term.setColor(.reset) catch {};
                    try writer.print(")", .{});
                }
            },
        }

        term.setColor(.reset) catch {};
    }
};

pub fn deinit(unit: *CompUnit, alloc: std.mem.Allocator) void {
    for (unit.funcs.values()) |*func| func.deinit(alloc);

    unit.funcs.deinit(alloc);
    unit.globals.deinit(alloc);
    unit.export_symbols.deinit(alloc);
    unit.global_asm.deinit(alloc);
    unit.global_constants.deinit(alloc);
    unit.data.deinit(alloc);
    unit.extern_labels.deinit(alloc);
}
