const std = @import("std");
const Ir = @import("Ir.zig");
const Mir = @import("codegen/amd64/Mir.zig");
const Ramir = @import("codegen/amd64/Ramir.zig");
const CompUnit = @This();

funcs: std.StringArrayHashMapUnmanaged(Func),
globals: std.StringArrayHashMapUnmanaged(Global),
export_symbols: std.StringHashMapUnmanaged(void),

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

pub const Global = struct {
    initial_value: u64,

    pub const Ref = u32;
};

pub const Immediate = union(enum) {
    int: u64,
    global_addr: Global.Ref,

    pub fn equal(left: Immediate, right: Immediate) bool {
        return switch (left) {
            .int => |lval| switch (right) {
                .int => |rval| lval == rval,
                .global_addr => false,
            },
            .global_addr => |lval| switch (left) {
                .int => false,
                .global_addr => |rval| lval == rval,
            },
        };
    }

    pub fn format(imm: Immediate, writer: *std.Io.Writer) !void {
        switch (imm) {
            .int => |val| try writer.print("{}", .{val}),
            .global_addr => |global_ref| try writer.print("g{}", .{global_ref}),
        }
    }
};

pub fn deinit(unit: *CompUnit, alloc: std.mem.Allocator) void {
    for (unit.funcs.values()) |*func| func.deinit(alloc);

    unit.funcs.deinit(alloc);
    unit.globals.deinit(alloc);
    unit.export_symbols.deinit(alloc);
}
