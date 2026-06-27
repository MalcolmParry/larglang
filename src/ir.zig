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
    insts: std.ArrayList(Inst),
    terminator: Terminator,

    pub fn deinit(block: *Block, alloc: std.mem.Allocator) void {
        block.insts.deinit(alloc);
        block.terminator.deinit(alloc);
    }

    pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (this.insts.items, 0..) |inst, inst_id| {
            switch (inst) {
                .imm => |val| try writer.print("${} = {}\n", .{ inst_id, val }),
                .add, .sub, .mul, .div, .equal => |bin| try writer.print("${} = {s} {f}, {f}\n", .{
                    inst_id,
                    @tagName(inst),
                    bin.left,
                    bin.right,
                }),
            }
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
            .jmp => |*jmp| jmp.deinit(alloc),
            .branch => |*branch| {
                branch.true_jmp.deinit(alloc);
                branch.false_jmp.deinit(alloc);
            },
        }
    }

    pub const Jmp = struct {
        block_id: u32,
        args: std.ArrayList(ValueRef),

        pub fn deinit(jmp: *Jmp, alloc: std.mem.Allocator) void {
            jmp.args.deinit(alloc);
        }

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

pub const ValueRef = packed struct(u32) {
    /// instruction index when tag = .inst
    /// arg index when tag = .arg
    data: u31,
    tag: Tag,

    pub const Tag = enum(u1) {
        inst,
        arg,
    };

    pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (this.tag) {
            .inst => try writer.print("${}", .{this.data}),
            .arg => try writer.print("%{}", .{this.data}),
        }
    }
};

pub const Inst = union(enum) {
    imm: u64,
    add: BinOp,
    sub: BinOp,
    mul: BinOp,
    div: BinOp,

    equal: BinOp,

    pub const BinOp = struct {
        left: ValueRef,
        right: ValueRef,
    };
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
            .arg_count = 0,
            .insts = .empty,
            .terminator = .none,
        });

        const compiled_block_result = try compileCodeBlock(state, &func, &.empty, ast_func.block, 0);
        switch (compiled_block_result) {
            .returned => {},
            .continued => |continued| {
                gpa.free(continued.args);
                const block = &func.blocks.items[continued.current_block_id];

                try block.insts.append(gpa, .{ .imm = 0 });
                block.terminator = .{ .ret = .{
                    .tag = .inst,
                    .data = @intCast(block.insts.items.len - 1),
                } };
            },
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
                const args: std.ArrayList(ValueRef) = .fromOwnedSlice(try gpa.dupe(ValueRef, new_ident_map.values()));

                for (new_ident_map.values(), 0..) |*val, i| {
                    val.* = .{
                        .tag = .arg,
                        .data = @intCast(i),
                    };
                }

                const true_block_id: u32 = @intCast(func.blocks.items.len);
                try func.blocks.append(gpa, .{
                    .arg_count = @intCast(new_ident_map.count()),
                    .insts = .empty,
                    .terminator = .none,
                });

                const end_block_id: u32 = @intCast(func.blocks.items.len);
                try func.blocks.append(gpa, .{
                    .arg_count = @intCast(new_ident_map.count()),
                    .insts = .empty,
                    .terminator = .none,
                });

                const else_block_id: u32 = if (has_else) @intCast(func.blocks.items.len) else end_block_id;
                if (has_else) try func.blocks.append(gpa, .{
                    .arg_count = @intCast(new_ident_map.count()),
                    .insts = .empty,
                    .terminator = .none,
                });

                func.blocks.items[block_id].terminator = .{ .branch = .{
                    .condition = condition,
                    .true_jmp = .{
                        .block_id = true_block_id,
                        .args = args,
                    },
                    .false_jmp = .{
                        .block_id = else_block_id,
                        .args = try args.clone(gpa),
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
            try block.insts.append(gpa, .{ .imm = val });
            return .{
                .tag = .inst,
                .data = @intCast(block.insts.items.len - 1),
            };
        },
        .bin => |bin| {
            const left_dest = try compileExpr(state, block, ident_map, bin.left);
            const right_dest = try compileExpr(state, block, ident_map, bin.right);
            const bin_op: Inst.BinOp = .{
                .left = left_dest,
                .right = right_dest,
            };

            const inst: Inst = switch (bin.op) {
                .add => .{ .add = bin_op },
                .sub => .{ .sub = bin_op },
                .mul => .{ .mul = bin_op },
                .div => .{ .div = bin_op },
                .equal => .{ .equal = bin_op },
            };

            try block.insts.append(gpa, inst);
            return .{
                .tag = .inst,
                .data = @intCast(block.insts.items.len - 1),
            };
        },
        .ident => |ident| {
            return ident_map.get(ident.get(state.lexer)) orelse error.CompileFailed;
        },
    }
}

// pub fn removeUnusedValues(alloc: std.mem.Allocator, block: *Block) !bool {
//     var dirty: bool = false;
//
//     const val_count = @intFromEnum(block.next_value_ref);
//     var unused: std.DynamicBitSetUnmanaged = try .initEmpty(alloc, val_count);
//     defer unused.deinit(alloc);
//
//     for (block.instructions.items) |inst| {
//         switch (inst) {
//             .imm => |imm| unused.set(@intFromEnum(imm.dest)),
//             .add, .sub, .mul, .div, .equal => |bin| unused.set(@intFromEnum(bin.dest)),
//         }
//     }
//
//     for (block.instructions.items) |inst| {
//         switch (inst) {
//             .imm => {},
//             .add, .sub, .mul, .div, .equal => |bin| {
//                 unused.unset(@intFromEnum(bin.left));
//                 unused.unset(@intFromEnum(bin.right));
//             },
//         }
//     }
//
//     switch (block.terminator) {
//         .none => {},
//         .jmp => |jmp| {
//             for (jmp.args.items) |arg| unused.unset(@intFromEnum(arg));
//         },
//         .branch => |branch| {
//             unused.unset(@intFromEnum(branch.condition));
//             for (branch.true_jmp.args.items) |arg| unused.unset(@intFromEnum(arg));
//             for (branch.false_jmp.args.items) |arg| unused.unset(@intFromEnum(arg));
//         },
//         .ret => |val| unused.unset(@intFromEnum(val)),
//     }
//
//     while (unused.findFirstSet()) |i_ref| {
//         unused.unset(i_ref);
//         dirty = true;
//         const ref: ValueRef = @enumFromInt(i_ref);
//
//         var i: usize = 0;
//         while (i < block.instructions.items.len) {
//             const inst = block.instructions.items[i];
//             const dest: ValueRef = switch (inst) {
//                 .imm => |imm| imm.dest,
//                 .add, .sub, .mul, .div, .equal => |bin| bin.dest,
//             };
//
//             if (dest == ref) {
//                 _ = block.instructions.orderedRemove(i);
//             } else {
//                 i += 1;
//             }
//         }
//     }
//
//     return dirty;
// }
//
// pub fn foldConstants(alloc: std.mem.Allocator, block: *Block) !bool {
//     var dirty: bool = false;
//
//     for (block.instructions.items) |*instruction| {
//         switch (instruction.*) {
//             .imm => {},
//             .add, .sub, .mul, .div, .equal => |bin| {
//                 const left = getImmediate(block, bin.left) orelse continue;
//                 const right = getImmediate(block, bin.right) orelse continue;
//
//                 const result: u64 = switch (instruction.*) {
//                     .add => left +% right,
//                     .sub => left -% right,
//                     .mul => left *% right,
//                     .div => try std.math.divTrunc(u64, left, right),
//                     .equal => @intFromBool(left == right),
//                     else => unreachable,
//                 };
//
//                 dirty = true;
//                 instruction.* = .{ .imm = .{
//                     .dest = bin.dest,
//                     .value = result,
//                 } };
//             },
//         }
//     }
//
//     blk: switch (block.terminator) {
//         .none, .jmp, .ret => {},
//         .branch => |*branch| {
//             const val = getImmediate(block, branch.condition) orelse break :blk;
//             const jmp = if (val != 0) branch.true_jmp else branch.false_jmp;
//             const other = if (val != 0) &branch.false_jmp else &branch.true_jmp;
//
//             dirty = true;
//             other.deinit(alloc);
//             block.terminator = .{ .jmp = jmp };
//         },
//     }
//
//     return dirty;
// }
//
// pub fn getImmediate(block: *const Block, ref: ValueRef) ?u64 {
//     for (block.instructions.items) |instruction| {
//         const imm = if (instruction == .imm) instruction.imm else continue;
//
//         if (imm.dest == ref) return imm.value;
//     }
//
//     return null;
// }
//
// pub fn removeUnreachableBlocks(alloc: std.mem.Allocator, func: *Func) !void {
//     var unused: std.DynamicBitSetUnmanaged = try .initFull(alloc, func.blocks.items.len);
//     defer unused.deinit(alloc);
//     markBlockRefs(func, &unused, 0);
//
//     while (unused.findFirstSet()) |block_id_usize| {
//         const block_id: u32 = @intCast(block_id_usize);
//         unused.unset(block_id);
//
//         func.blocks.items[block_id].deinit(alloc);
//         _ = func.blocks.swapRemove(block_id);
//
//         const last: u32 = @intCast(func.blocks.items.len);
//         if (block_id == last) continue;
//         unused.setValue(block_id, unused.isSet(last));
//         unused.unset(last);
//
//         for (func.blocks.items) |*block| {
//             switch (block.terminator) {
//                 .none, .ret => {},
//                 .jmp => |*jmp| {
//                     if (jmp.block_id == last) jmp.block_id = block_id;
//                 },
//                 .branch => |*branch| {
//                     if (branch.true_jmp.block_id == last) branch.true_jmp.block_id = block_id;
//                     if (branch.false_jmp.block_id == last) branch.false_jmp.block_id = block_id;
//                 },
//             }
//         }
//     }
// }
//
// fn markBlockRefs(func: *const Func, unused: *std.DynamicBitSetUnmanaged, block_id: u32) void {
//     if (!unused.isSet(block_id)) return;
//     unused.unset(block_id);
//
//     const block = &func.blocks.items[block_id];
//     switch (block.terminator) {
//         .none, .ret => {},
//         .jmp => |jmp| {
//             markBlockRefs(func, unused, jmp.block_id);
//         },
//         .branch => |branch| {
//             markBlockRefs(func, unused, branch.true_jmp.block_id);
//             markBlockRefs(func, unused, branch.false_jmp.block_id);
//         },
//     }
// }
//
// pub fn mergeBlocks(alloc: std.mem.Allocator, func: *Func) !bool {
//     var dirty: bool = false;
//
//     for (func.blocks.items, 0..) |*block, block_id| {
//         if (block.terminator != .jmp) continue;
//         const other_id = block.terminator.jmp.block_id;
//         if (other_id == block_id) continue;
//         const other = &func.blocks.items[other_id];
//
//         var ref_count: usize = 0;
//         for (func.blocks.items) |x| {
//             switch (x.terminator) {
//                 .none, .ret => {},
//                 .jmp => |jmp| {
//                     if (jmp.block_id == other_id) ref_count += 1;
//                 },
//                 .branch => |branch| {
//                     if (branch.true_jmp.block_id == other_id) ref_count += 1;
//                     if (branch.false_jmp.block_id == other_id) ref_count += 1;
//                 },
//             }
//         }
//
//         if (ref_count != 1) continue;
//
//         dirty = true;
//         var old_to_new_val: std.hash_map.AutoHashMapUnmanaged(ValueRef, ValueRef) = .empty;
//         defer old_to_new_val.deinit(alloc);
//
//         for (block.terminator.jmp.args.items, 0..) |val, arg| {
//             try old_to_new_val.put(alloc, @enumFromInt(arg), val);
//         }
//
//         for (other.instructions.items) |inst| {
//             switch (inst) {
//                 .imm => |imm| {
//                     const new = block.allocValueRef();
//                     try old_to_new_val.put(alloc, imm.dest, new);
//                     try block.instructions.append(alloc, .{ .imm = .{
//                         .dest = new,
//                         .value = imm.value,
//                     } });
//                 },
//                 .add, .sub, .mul, .div, .equal => |bin| {
//                     const new_dest = block.allocValueRef();
//                     const new_left = old_to_new_val.get(bin.left) orelse return error.BadIr;
//                     const new_right = old_to_new_val.get(bin.right) orelse return error.BadIr;
//                     try old_to_new_val.put(alloc, bin.dest, new_dest);
//
//                     const new: Inst.BinOp = .{
//                         .dest = new_dest,
//                         .left = new_left,
//                         .right = new_right,
//                     };
//
//                     const new_inst: Inst = switch (inst) {
//                         .add => .{ .add = new },
//                         .sub => .{ .sub = new },
//                         .mul => .{ .mul = new },
//                         .div => .{ .div = new },
//                         .equal => .{ .equal = new },
//                         else => unreachable,
//                     };
//
//                     try block.instructions.append(alloc, new_inst);
//                 },
//             }
//         }
//
//         block.terminator.deinit(alloc);
//         block.terminator = other.terminator;
//
//         switch (block.terminator) {
//             .none => {},
//             .ret => |*val| {
//                 val.* = old_to_new_val.get(val.*) orelse return error.BadIr;
//             },
//             .jmp => |jmp| {
//                 for (jmp.args.items) |*arg| {
//                     arg.* = old_to_new_val.get(arg.*) orelse return error.BadIr;
//                 }
//             },
//             .branch => |*branch| {
//                 branch.condition = old_to_new_val.get(branch.condition) orelse return error.BadIr;
//
//                 for (branch.true_jmp.args.items) |*arg| {
//                     arg.* = old_to_new_val.get(arg.*) orelse return error.BadIr;
//                 }
//
//                 for (branch.false_jmp.args.items) |*arg| {
//                     arg.* = old_to_new_val.get(arg.*) orelse return error.BadIr;
//                 }
//             },
//         }
//
//         other.terminator = .none;
//         other.instructions.clearAndFree(alloc);
//         other.arg_count = 0;
//         other.next_value_ref = @enumFromInt(0);
//     }
//
//     return dirty;
// }

pub fn optimize(alloc: std.mem.Allocator, func: *Func) !void {
    _ = alloc;
    _ = func;

    // while (true) {
    //     var dirty: bool = false;
    //
    //     for (func.blocks.items) |*block| {
    //         if (try foldConstants(alloc, block)) dirty = true;
    //         if (try removeUnusedValues(alloc, block)) dirty = true;
    //     }
    //
    //     if (try mergeBlocks(alloc, func)) dirty = true;
    //     try removeUnreachableBlocks(alloc, func);
    //
    //     if (!dirty) break;
    // }
}
