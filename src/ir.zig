const std = @import("std");
const Lexer = @import("Lexer.zig");
const Token = Lexer.Token;
const Slice = Lexer.Slice;
const parser = @import("parser.zig");
const IdentMap = std.StringHashMapUnmanaged(ValueRef);

pub const FileScope = struct {
    funcs: std.ArrayList(Func),

    pub fn deinit(file_scope: *FileScope, alloc: std.mem.Allocator) void {
        for (file_scope.funcs.items) |*func| {
            func.deinit(alloc);
        }

        file_scope.funcs.deinit(alloc);
    }
};

pub const Func = struct {
    name: Slice,
    block: Block,

    pub fn deinit(func: *Func, alloc: std.mem.Allocator) void {
        func.block.deinit(alloc);
    }
};

pub const Block = struct {
    next_value_ref: ValueRef,
    instructions: std.ArrayList(Instruction),
    terminator: Terminator,

    pub fn deinit(block: *Block, alloc: std.mem.Allocator) void {
        block.instructions.deinit(alloc);
    }

    fn allocValueRef(block: *Block) ValueRef {
        const result = block.next_value_ref;
        block.next_value_ref = @enumFromInt(@intFromEnum(block.next_value_ref) + 1);
        return result;
    }

    pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (this.instructions.items) |instruction| {
            try writer.print("{f}\n", .{instruction});
        }

        if (this.terminator.ret == .none) {
            try writer.print("ret undefined\n", .{});
        } else {
            try writer.print("ret %{}\n", .{@intFromEnum(this.terminator.ret)});
        }
    }
};

pub const Terminator = struct {
    ret: ValueRef,
};

pub const ValueRef = enum(u32) {
    none = std.math.maxInt(u32),
    _,
};

pub const Instruction = union(enum) {
    imm: Immediate,
    add: BinOp,
    sub: BinOp,
    mul: BinOp,
    div: BinOp,

    pub const Immediate = struct {
        dest: ValueRef,
        value: u64,
    };

    pub const BinOp = struct {
        dest: ValueRef,
        left: ValueRef,
        right: ValueRef,
    };

    pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (this) {
            .imm => |imm| try writer.print("%{} = {}", .{ @intFromEnum(imm.dest), imm.value }),
            .add, .sub, .mul, .div => |bin| {
                try writer.print("%{} = {s} %{}, %{}", .{
                    @intFromEnum(bin.dest),
                    @tagName(this),
                    @intFromEnum(bin.left),
                    @intFromEnum(bin.right),
                });
            },
        }
    }
};

pub const State = struct {
    gpa: std.mem.Allocator,
    lexer: *const Lexer,
};

pub fn compileAst(state: State, ast: *const parser.FileScope) !FileScope {
    const gpa = state.gpa;
    var file_scope: FileScope = .{
        .funcs = try .initCapacity(gpa, ast.funcs.len),
    };
    errdefer file_scope.deinit(gpa);

    for (ast.funcs) |ast_func| {
        var ident_map: IdentMap = .empty;
        defer ident_map.deinit(gpa);

        var block: Block = .{
            .next_value_ref = @enumFromInt(0),
            .instructions = .empty,
            .terminator = .{
                .ret = .none,
            },
        };
        errdefer block.deinit(gpa);

        for (ast_func.statements) |statement| {
            switch (statement) {
                .assign => |assign| {
                    const val = try compileExpr(state, &block, &ident_map, assign.expr);
                    try ident_map.put(gpa, assign.ident.get(state.lexer), val);
                },
                .ret => |expr| {
                    const val = try compileExpr(state, &block, &ident_map, expr);
                    block.terminator.ret = val;
                    break;
                },
            }
        }

        try file_scope.funcs.append(gpa, .{
            .name = ast_func.name,
            .block = block,
        });
    }

    return file_scope;
}

pub fn compileExpr(state: State, block: *Block, ident_map: *IdentMap, expr: *const parser.Expression) !ValueRef {
    const gpa = state.gpa;

    switch (expr.*) {
        .int_lit => |val| {
            const dest = block.allocValueRef();
            try block.instructions.append(gpa, .{ .imm = .{
                .dest = dest,
                .value = val,
            } });
            return dest;
        },
        .bin => |bin| {
            const left_dest = try compileExpr(state, block, ident_map, bin.left);
            const right_dest = try compileExpr(state, block, ident_map, bin.right);
            const dest = block.allocValueRef();
            const bin_op: Instruction.BinOp = .{
                .dest = dest,
                .left = left_dest,
                .right = right_dest,
            };

            const inst: Instruction = switch (bin.op) {
                .add => .{ .add = bin_op },
                .sub => .{ .sub = bin_op },
                .mul => .{ .mul = bin_op },
                .div => .{ .div = bin_op },
            };

            try block.instructions.append(gpa, inst);
            return dest;
        },
        .ident => |ident| {
            return ident_map.get(ident.get(state.lexer)) orelse error.CompileFailed;
        },
    }
}
