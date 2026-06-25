const std = @import("std");
const Lexer = @import("Lexer.zig");
const Token = Lexer.Token;
const Slice = Lexer.Slice;
const parser = @import("parser.zig");
const IdentMap = std.array_hash_map.String(ValueRef);

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
    blocks: std.ArrayList(Block),

    pub fn deinit(func: *Func, alloc: std.mem.Allocator) void {
        for (func.blocks.items) |*block| block.deinit(alloc);
        func.blocks.deinit(alloc);
    }

    pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (0.., this.blocks.items) |block_id, block| {
            try writer.print("@{}(", .{block_id});

            for (0..block.arg_count) |arg_id| {
                try writer.print("%{}", .{arg_id});

                if (arg_id != block.arg_count - 1)
                    try writer.print(", ", .{});
            }

            try writer.print("):\n{f}\n", .{
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
            .none => try writer.print("no terminator\n", .{}),
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
    /// only for ir gen, final ir should never have this
    none,
    ret: ValueRef,
    jmp: Jmp,
    branch: Branch,

    pub fn deinit(term: *Terminator, alloc: std.mem.Allocator) void {
        switch (term.*) {
            .none => {},
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
        };

        try func.blocks.append(gpa, .{
            .next_value_ref = @enumFromInt(0),
            .arg_count = 0,
            .instructions = .empty,
            .terminator = .none,
        });

        const thing = try compileCodeBlock(state, &func, &.empty, ast_func.block, 0);
        switch (thing) {
            .returned => {},
            .continued => |continued| gpa.free(continued.args),
        }

        try file_scope.funcs.append(gpa, func);
    }

    return file_scope;
}

pub const CompileCodeBlockResult = union(enum) {
    returned,
    continued: Continued,

    pub const Continued = struct {
        current_block_id: u32,
        args: []ValueRef,
    };
};

pub fn compileCodeBlock(state: State, func: *Func, ident_map: *const IdentMap, ast_block: parser.CodeBlock, first_block_id: u32) !CompileCodeBlockResult {
    const gpa = state.gpa;
    var new_ident_map = try ident_map.clone(gpa);
    defer new_ident_map.deinit(gpa);

    var block_id = first_block_id;
    for (ast_block.statements) |statement| {
        switch (statement) {
            .assign => |assign| {
                const val = try compileExpr(state, &func.blocks.items[block_id], &new_ident_map, assign.expr);
                try new_ident_map.put(gpa, assign.ident.get(state.lexer), val);
            },
            .ret => |expr| {
                const val = try compileExpr(state, &func.blocks.items[block_id], &new_ident_map, expr);
                func.blocks.items[block_id].terminator = .{ .ret = val };
                return .returned;
            },
            .if_ => |if_| {
                const condition = try compileExpr(state, &func.blocks.items[block_id], &new_ident_map, if_.condition);
                const has_else = if_.else_block.statements.len > 0;

                const true_block_id: u32 = @intCast(func.blocks.items.len);
                try func.blocks.append(gpa, .{
                    .arg_count = @intCast(new_ident_map.count()),
                    .next_value_ref = @enumFromInt(@as(u32, @intCast(new_ident_map.count()))),
                    .instructions = .empty,
                    .terminator = .none,
                });

                const end_block_id: u32 = @intCast(func.blocks.items.len);
                try func.blocks.append(gpa, .{
                    .arg_count = @intCast(new_ident_map.count()),
                    .next_value_ref = @enumFromInt(@as(u32, @intCast(new_ident_map.count()))),
                    .instructions = .empty,
                    .terminator = .none,
                });

                const else_block_id: u32 = if (has_else) @intCast(func.blocks.items.len) else end_block_id;
                if (has_else) try func.blocks.append(gpa, .{
                    .arg_count = @intCast(new_ident_map.count()),
                    .next_value_ref = @enumFromInt(@as(u32, @intCast(new_ident_map.count()))),
                    .instructions = .empty,
                    .terminator = .none,
                });

                func.blocks.items[block_id].terminator = .{ .branch = .{
                    .condition = condition,
                    .true_jmp = .{
                        .block_id = true_block_id,
                        .args = .fromOwnedSlice(try gpa.dupe(ValueRef, new_ident_map.values())),
                    },
                    .false_jmp = .{
                        .block_id = else_block_id,
                        .args = .fromOwnedSlice(try gpa.dupe(ValueRef, new_ident_map.values())),
                    },
                } };

                const true_block_result = try compileCodeBlock(state, func, &new_ident_map, if_.true_block, true_block_id);
                switch (true_block_result) {
                    .returned => {},
                    .continued => |continued| {
                        std.debug.assert(func.blocks.items[continued.current_block_id].terminator == .none);

                        func.blocks.items[continued.current_block_id].terminator = .{ .jmp = .{
                            .block_id = end_block_id,
                            .args = .fromOwnedSlice(continued.args),
                        } };
                    },
                }

                if (has_else) {
                    const else_block_result = try compileCodeBlock(state, func, &new_ident_map, if_.else_block, else_block_id);
                    switch (else_block_result) {
                        .returned => {},
                        .continued => |continued| {
                            std.debug.assert(func.blocks.items[continued.current_block_id].terminator == .none);

                            func.blocks.items[continued.current_block_id].terminator = .{ .jmp = .{
                                .block_id = end_block_id,
                                .args = .fromOwnedSlice(continued.args),
                            } };
                        },
                    }

                    if (true_block_result == .returned and else_block_result == .returned) return .returned;
                }

                block_id = end_block_id;
                for (new_ident_map.values(), 0..) |*val, i| {
                    val.* = @enumFromInt(@as(u32, @intCast(i)));
                }
            },
        }
    }

    var args: std.ArrayList(ValueRef) = try .initCapacity(gpa, ident_map.count());
    for (ident_map.keys()) |ident| {
        args.appendAssumeCapacity(new_ident_map.get(ident) orelse unreachable);
    }

    return .{ .continued = .{
        .current_block_id = block_id,
        .args = try args.toOwnedSlice(gpa),
    } };
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
