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

pub const Global = struct {
    initial_value: u64,

    pub const Ref = u32;
};

pub const Immediate = union(enum) {
    int: u64,
    global_addr: Global.Ref,
    data_addr: DataAddrRef,
    func_addr: FuncRef,
    label_addr: LabelRef,

    pub fn equal(left: Immediate, right: Immediate) bool {
        return std.meta.eql(left, right);
    }

    pub fn print(imm: Immediate, term: std.Io.Terminal) !void {
        const writer = term.writer;
        term.setColor(switch (imm) {
            .int => .blue,
            .global_addr => .white,
            .data_addr => .yellow,
            .func_addr, .label_addr => .red,
        }) catch {};

        switch (imm) {
            .int => |val| try writer.print("{}", .{val}),
            .global_addr => |global_ref| try writer.print("g{}", .{global_ref}),
            .data_addr => |data_addr_ref| try writer.print("d{}", .{data_addr_ref}),
            .func_addr => |x| try writer.print("f{}", .{x}),
            .label_addr => |x| try writer.print("l{}", .{x}),
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
