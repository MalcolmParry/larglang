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
    entry_block_id: u32,
    blocks: std.ArrayList(Block),

    pub fn deinit(func: *Func, alloc: std.mem.Allocator) void {
        for (func.blocks.items) |*block| block.deinit(alloc);
        func.blocks.deinit(alloc);
    }

    pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (0.., this.blocks.items) |block_id, block| {
            try writer.print("@{}({})\n{f}\n", .{
                block_id,
                block.arg_count,
                block,
            });
        }
    }
};

pub const Block = struct {
    arg_count: u32,
    next_value_ref: ValueRef,
    instructions: std.ArrayList(Instruction),
    terminator: Terminator,

    pub fn deinit(block: *Block, alloc: std.mem.Allocator) void {
        block.instructions.deinit(alloc);
        block.terminator.deinit(alloc);
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

        switch (this.terminator) {
            .ret => |val| try writer.print("ret {f}\n", .{val}),
            .jmp => |jmp| try writer.print("jmp {f}\n", .{jmp}),
            .branch => |branch| try writer.print("branch {f} ? {f} : {f}\n", .{
                branch.condition,
                branch.true_jmp,
                branch.false_jmp,
            }),
        }
    }
};

pub const Terminator = union(enum) {
    ret: ValueRef,
    jmp: Jmp,
    branch: Branch,

    pub fn deinit(term: *Terminator, alloc: std.mem.Allocator) void {
        switch (term.*) {
            .ret => {},
            .jmp => |*jmp| jmp.args.deinit(alloc),
            .branch => |*branch| {
                branch.true_jmp.args.deinit(alloc);
                branch.false_jmp.args.deinit(alloc);
            },
        }
    }

    pub const Jmp = struct {
        block_id: u32,
        args: std.ArrayList(ValueRef),

        pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("@{}(", .{this.block_id});

            for (this.args.items, 0..) |arg, i| {
                try writer.print("{f}", .{arg});

                if (i != this.args.items.len - 1)
                    try writer.print(", ", .{});
            }

            try writer.print(")", .{});
        }
    };

    pub const Branch = struct {
        condition: ValueRef,
        true_jmp: Jmp,
        false_jmp: Jmp,
    };
};

pub const ValueRef = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (this == .none) {
            try writer.print("%none", .{});
        } else {
            try writer.print("%{}", .{@intFromEnum(this)});
        }
    }
};

pub const Instruction = union(enum) {
    imm: Immediate,
    add: BinOp,
    sub: BinOp,
    mul: BinOp,
    div: BinOp,

    equal: BinOp,

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
            .imm => |imm| try writer.print("{f} = {}", .{ imm.dest, imm.value }),
            .add, .sub, .mul, .div, .equal => |bin| {
                try writer.print("{f} = {s} {f}, {f}", .{
                    bin.dest,
                    @tagName(this),
                    bin.left,
                    bin.right,
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
        var func: Func = .{
            .blocks = .empty,
            .name = ast_func.name,
            .entry_block_id = 0,
        };

        try func.blocks.append(gpa, .{
            .next_value_ref = @enumFromInt(0),
            .arg_count = 0,
            .instructions = .empty,
            .terminator = .{
                .ret = .none,
            },
        });

        func.entry_block_id = try compileCodeBlock(state, &func, &.{}, ast_func.block, 0);
        try file_scope.funcs.append(gpa, func);
    }

    return file_scope;
}

pub fn compileCodeBlock(state: State, func: *Func, vars: []const []const u8, ast_block: parser.CodeBlock, ret_block_id: u32) !u32 {
    const gpa = state.gpa;
    var ident_map: IdentMap = .empty;
    defer ident_map.deinit(gpa);

    const first_block_id: u32 = @intCast(func.blocks.items.len);
    try func.blocks.append(gpa, .{
        .arg_count = @intCast(vars.len),
        .next_value_ref = @enumFromInt(@as(u32, @intCast(vars.len))),
        .instructions = .empty,
        .terminator = undefined,
    });

    for (0.., vars) |arg_id, ident| {
        try ident_map.put(gpa, ident, @enumFromInt(arg_id));
    }

    var block_id: u32 = first_block_id;
    for (ast_block.statements) |statement| {
        switch (statement) {
            .assign => |assign| {
                const val = try compileExpr(state, &func.blocks.items[block_id], &ident_map, assign.expr);
                try ident_map.put(gpa, assign.ident.get(state.lexer), val);
            },
            .ret => |expr| {
                const val = try compileExpr(state, &func.blocks.items[block_id], &ident_map, expr);
                func.blocks.items[block_id].terminator = .{ .ret = val };
                return block_id;
            },
            .if_ => |if_| {
                const condition = try compileExpr(state, &func.blocks.items[block_id], &ident_map, if_.condition);
                const new_vars = try gpa.alloc([]const u8, ident_map.count());
                defer gpa.free(new_vars);

                var ident_iter = ident_map.iterator();
                var i: usize = 0;
                while (ident_iter.next()) |ident| : (i += 1) {
                    new_vars[i] = ident.key_ptr.*;
                }

                const new_block_id: u32 = @intCast(func.blocks.items.len);
                try func.blocks.append(gpa, .{
                    .arg_count = @intCast(new_vars.len),
                    .next_value_ref = @enumFromInt(@as(u32, @intCast(new_vars.len))),
                    .instructions = .empty,
                    .terminator = undefined,
                });

                const true_block_id = try compileCodeBlock(state, func, new_vars, if_.block, new_block_id);
                var true_jmp: Terminator.Jmp = .{
                    .block_id = true_block_id,
                    .args = try .initCapacity(gpa, new_vars.len),
                };

                for (new_vars) |ident| {
                    true_jmp.args.appendAssumeCapacity(ident_map.get(ident) orelse unreachable);
                }

                func.blocks.items[block_id].terminator = .{ .branch = .{
                    .condition = condition,
                    .true_jmp = true_jmp,
                    .false_jmp = .{
                        .block_id = new_block_id,
                        .args = try true_jmp.args.clone(gpa),
                    },
                } };

                block_id = new_block_id;
                ident_map.clearRetainingCapacity();
                for (0.., new_vars) |arg_id, ident| {
                    try ident_map.put(gpa, ident, @enumFromInt(arg_id));
                }
            },
        }
    }

    var jmp: Terminator.Jmp = .{
        .block_id = ret_block_id,
        .args = try .initCapacity(gpa, vars.len),
    };

    for (vars) |ident| {
        jmp.args.appendAssumeCapacity(ident_map.get(ident) orelse unreachable);
    }

    func.blocks.items[block_id].terminator = .{ .jmp = jmp };
    return first_block_id;
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
                .equal => .{ .equal = bin_op },
            };

            try block.instructions.append(gpa, inst);
            return dest;
        },
        .ident => |ident| {
            return ident_map.get(ident.get(state.lexer)) orelse error.CompileFailed;
        },
    }
}
