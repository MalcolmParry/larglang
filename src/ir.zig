const std = @import("std");
const Lexer = @import("Lexer.zig");
const Token = Lexer.Token;
const Slice = Lexer.Slice;
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
    imms: std.ArrayList(u64),

    pub fn deinit(func: *Func, alloc: std.mem.Allocator) void {
        for (func.blocks.items) |*block| block.deinit(alloc);
        func.blocks.deinit(alloc);
        func.imms.deinit(alloc);
    }

    pub fn appendImm(func: *Func, alloc: std.mem.Allocator, val: u64) !ValueRef {
        try func.imms.append(alloc, val);
        return .{
            .tag = .imm,
            .data = @intCast(func.imms.items.len - 1),
        };
    }

    pub fn format(func: Func, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try printFunc(writer, func);
    }
};

pub const BlockId = u32;
pub const Block = struct {
    arg_count: u32,
    insts: std.ArrayList(Inst),
    terminator: Terminator,

    pub fn deinit(block: *Block, alloc: std.mem.Allocator) void {
        block.insts.deinit(alloc);
        block.terminator.deinit(alloc);
    }

    pub fn kill(block: *Block, alloc: std.mem.Allocator) void {
        block.deinit(alloc);
        block.* = .{
            .arg_count = 0,
            .insts = .empty,
            .terminator = .dead,
        };
    }

    pub fn isDead(block: Block) bool {
        return block.terminator == .dead;
    }

    pub fn isEmpty(block: Block) bool {
        var empty: bool = true;

        for (block.insts.items) |inst| {
            if (inst.tag != .no_op)
                empty = false;
        }

        return empty;
    }

    pub fn appendInst(block: *Block, alloc: std.mem.Allocator, inst: Inst) !ValueRef {
        try block.insts.append(alloc, inst);
        return .fromInst(@intCast(block.insts.items.len - 1));
    }
};

pub const Terminator = union(enum) {
    /// block currently under construction, not valid in final ir
    none,
    /// tombstone
    dead,
    ret: ValueRef,
    jmp: Jmp,
    branch: Branch,

    pub fn deinit(term: *Terminator, alloc: std.mem.Allocator) void {
        switch (term.*) {
            .none, .dead, .ret => {},
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
    };

    pub const Branch = struct {
        condition: ValueRef,
        true_jmp: Jmp,
        false_jmp: Jmp,
    };
};

pub const ValueRef = packed struct(u16) {
    /// instruction index when tag = .inst
    /// arg index when tag = .arg
    data: u14,
    tag: Tag,

    pub const Tag = enum(u2) {
        inst,
        arg,
        imm,
    };

    pub fn fromInst(inst_id: u14) ValueRef {
        return .{ .tag = .inst, .data = inst_id };
    }

    pub fn fromArg(arg_id: u14) ValueRef {
        return .{ .tag = .arg, .data = arg_id };
    }
};

pub const ImmRef = u14;
pub const InstRef = u14;

/// instructions are ordered except for .imm
pub const Inst = struct {
    tag: Tag,
    data: Data,

    pub const Tag = enum {
        no_op,
        add,
        sub,
        mul,
        div,
        equal,
        less,
        more,

        pub fn getDataKind(tag: Tag) Data.Kind {
            return switch (tag) {
                .no_op => .none,
                .add, .sub, .mul, .div, .equal, .less, .more => .bin,
            };
        }

        pub fn hasSideEffects(tag: Tag) bool {
            _ = tag;
            return false;
        }
    };

    pub const Data = union {
        bin: BinOp,

        pub const Kind = enum {
            none,
            bin,
        };
    };

    pub const BinOp = struct {
        left: ValueRef,
        right: ValueRef,
    };

    pub const noop: Inst = .{ .tag = .no_op, .data = undefined };
    pub fn bin(tag: Tag, left: ValueRef, right: ValueRef) Inst {
        std.debug.assert(tag.getDataKind() == .bin);
        return .{
            .tag = tag,
            .data = .{ .bin = .{
                .left = left,
                .right = right,
            } },
        };
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
            .imms = .empty,
            .name = ast_func.name,
        };
        errdefer func.deinit(gpa);

        var ident_map: IdentMap = .empty;
        defer ident_map.deinit(gpa);

        try ident_map.ensureUnusedCapacity(gpa, ast_func.params.len);
        for (ast_func.params, 0..) |param, arg_id| {
            ident_map.putAssumeCapacity(param.get(state.lexer), .fromArg(@intCast(arg_id)));
        }

        try func.blocks.append(gpa, .{
            .arg_count = @intCast(ast_func.params.len),
            .insts = .empty,
            .terminator = .none,
        });

        const compiled_block_result = try compileCodeBlock(state, &func, &ident_map, ast_func.block, 0);
        switch (compiled_block_result) {
            .returned => {},
            .continued => |continued| {
                gpa.free(continued.args);
                const block = &func.blocks.items[continued.current_block_id];

                block.terminator = .{
                    .ret = try func.appendImm(gpa, 0),
                };
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
        current_block_id: BlockId,
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
                const val = try compileExpr(state, func, &func.blocks.items[block_id], &new_ident_map, assign.expr);
                try new_ident_map.put(gpa, assign.ident.get(state.lexer), val);
            },
            .ret => |expr| {
                const val = try compileExpr(state, func, &func.blocks.items[block_id], &new_ident_map, expr);
                func.blocks.items[block_id].terminator = .{ .ret = val };
                return .returned;
            },
            .if_ => |if_| {
                const condition = try compileExpr(state, func, &func.blocks.items[block_id], &new_ident_map, if_.condition);
                const args: std.ArrayList(ValueRef) = .fromOwnedSlice(try gpa.dupe(ValueRef, new_ident_map.values()));

                for (new_ident_map.values(), 0..) |*val, i| {
                    val.* = .fromArg(@intCast(i));
                }

                const then_block_id: u32 = @intCast(func.blocks.items.len);
                try func.blocks.append(gpa, .{
                    .arg_count = @intCast(new_ident_map.count()),
                    .insts = .empty,
                    .terminator = .none,
                });
                const then_block_result = try compileCodeBlock(state, func, &new_ident_map, if_.true_block, then_block_id);

                const else_block_id: u32 = @intCast(func.blocks.items.len);
                try func.blocks.append(gpa, .{
                    .arg_count = @intCast(new_ident_map.count()),
                    .insts = .empty,
                    .terminator = .none,
                });
                const else_block_result = try compileCodeBlock(state, func, &new_ident_map, if_.else_block, else_block_id);

                const end_block_id: u32 = @intCast(func.blocks.items.len);
                try func.blocks.append(gpa, .{
                    .arg_count = @intCast(new_ident_map.count()),
                    .insts = .empty,
                    .terminator = .none,
                });

                func.blocks.items[block_id].terminator = .{ .branch = .{
                    .condition = condition,
                    .true_jmp = .{
                        .block_id = then_block_id,
                        .args = args,
                    },
                    .false_jmp = .{
                        .block_id = else_block_id,
                        .args = try args.clone(gpa),
                    },
                } };

                switch (then_block_result) {
                    .returned => {},
                    .continued => |continued| {
                        std.debug.assert(func.blocks.items[continued.current_block_id].terminator == .none);

                        func.blocks.items[continued.current_block_id].terminator = .{ .jmp = .{
                            .block_id = end_block_id,
                            .args = .fromOwnedSlice(continued.args),
                        } };
                    },
                }

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

                if (then_block_result == .returned and else_block_result == .returned) return .returned;

                block_id = end_block_id;
            },
            .while_ => |while_| {
                var jmp_args: std.ArrayList(ValueRef) = .fromOwnedSlice(try gpa.dupe(ValueRef, new_ident_map.values()));
                errdefer jmp_args.deinit(gpa);

                for (new_ident_map.values(), 0..) |*val, i| {
                    val.* = .fromArg(@intCast(i));
                }

                const cond_id: BlockId = @intCast(func.blocks.items.len);
                try func.blocks.append(gpa, .{
                    .arg_count = @intCast(new_ident_map.count()),
                    .insts = .empty,
                    .terminator = .none,
                });
                const cond_val_ref = try compileExpr(state, func, &func.blocks.items[cond_id], &new_ident_map, while_.condition);

                const body_id: BlockId = @intCast(func.blocks.items.len);
                try func.blocks.append(gpa, .{
                    .arg_count = @intCast(new_ident_map.count()),
                    .insts = .empty,
                    .terminator = .none,
                });
                const body_res = try compileCodeBlock(state, func, &new_ident_map, while_.block, body_id);

                const end_id: BlockId = @intCast(func.blocks.items.len);
                try func.blocks.append(gpa, .{
                    .arg_count = @intCast(new_ident_map.count()),
                    .insts = .empty,
                    .terminator = .none,
                });

                func.blocks.items[block_id].terminator = .{ .jmp = .{
                    .block_id = cond_id,
                    .args = jmp_args,
                } };

                var true_jmp_args: std.ArrayList(ValueRef) = .fromOwnedSlice(try gpa.dupe(ValueRef, new_ident_map.values()));
                errdefer true_jmp_args.deinit(gpa);

                var false_jmp_args = try true_jmp_args.clone(gpa);
                errdefer false_jmp_args.deinit(gpa);

                func.blocks.items[cond_id].terminator = .{ .branch = .{
                    .condition = cond_val_ref,
                    .true_jmp = .{
                        .block_id = body_id,
                        .args = true_jmp_args,
                    },
                    .false_jmp = .{
                        .block_id = end_id,
                        .args = false_jmp_args,
                    },
                } };

                switch (body_res) {
                    .returned => {},
                    .continued => |continued| {
                        std.debug.assert(func.blocks.items[continued.current_block_id].terminator == .none);

                        func.blocks.items[continued.current_block_id].terminator = .{ .jmp = .{
                            .block_id = cond_id,
                            .args = .fromOwnedSlice(continued.args),
                        } };
                    },
                }

                block_id = end_id;
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

pub fn compileExpr(state: State, func: *Func, block: *Block, ident_map: *IdentMap, expr: *const parser.Expression) !ValueRef {
    const gpa = state.gpa;

    switch (expr.*) {
        .int_lit => |val| {
            return func.appendImm(gpa, val);
        },
        .bin => |bin| {
            const left_ref = try compileExpr(state, func, block, ident_map, bin.left);
            const right_ref = try compileExpr(state, func, block, ident_map, bin.right);

            const tag: Inst.Tag = switch (bin.op) {
                .add => .add,
                .sub => .sub,
                .mul => .mul,
                .div => .div,
                .equal => .equal,
                .less => .less,
                .more => .more,
            };

            return block.appendInst(gpa, .bin(tag, left_ref, right_ref));
        },
        .ident => |ident| {
            return ident_map.get(ident.get(state.lexer)) orelse error.CompileFailed;
        },
    }
}

pub fn foldConstants(alloc: std.mem.Allocator, func: *Func, block: *Block) !bool {
    var dirty: bool = false;

    for (block.insts.items, 0..) |*inst, inst_id| {
        switch (inst.tag) {
            .add, .sub, .mul, .div, .equal, .less, .more => {
                const bin = inst.data.bin;
                const left = getImmediate(func, bin.left) orelse continue;
                const right = getImmediate(func, bin.right) orelse continue;

                const result: u64 = switch (inst.tag) {
                    .add => left +% right,
                    .sub => left -% right,
                    .mul => left *% right,
                    .div => try std.math.divTrunc(u64, left, right),
                    .equal => @intFromBool(left == right),
                    .less => @intFromBool(left < right),
                    .more => @intFromBool(left > right),
                    else => unreachable,
                };

                dirty = true;
                inst.* = .noop;
                remapValueRef(
                    block,
                    .fromInst(@intCast(inst_id)),
                    try func.appendImm(alloc, result),
                );
            },
            else => {},
        }
    }

    blk: switch (block.terminator) {
        .none, .dead, .jmp, .ret => {},
        .branch => |*branch| {
            const val = getImmediate(func, branch.condition) orelse break :blk;
            const jmp = if (val != 0) branch.true_jmp else branch.false_jmp;
            const other = if (val != 0) &branch.false_jmp else &branch.true_jmp;

            dirty = true;
            other.deinit(alloc);
            block.terminator = .{ .jmp = jmp };
        },
    }

    return dirty;
}

pub fn getImmediate(func: *const Func, ref: ValueRef) ?u64 {
    return switch (ref.tag) {
        .inst, .arg => null,
        .imm => func.imms.items[ref.data],
    };
}

pub fn killUnusedInsts(alloc: std.mem.Allocator, block: *Block) !bool {
    var dirty: bool = false;

    var unused: std.DynamicBitSetUnmanaged = try .initFull(alloc, block.insts.items.len);
    defer unused.deinit(alloc);

    for (block.insts.items) |inst| {
        switch (inst.tag.getDataKind()) {
            .none => {},
            .bin => {
                const bin = inst.data.bin;
                markValueRefUsed(&unused, bin.left);
                markValueRefUsed(&unused, bin.right);
            },
        }
    }

    switch (block.terminator) {
        .none => unreachable,
        .dead => {},
        .jmp => |jmp| {
            for (jmp.args.items) |arg| markValueRefUsed(&unused, arg);
        },
        .branch => |branch| {
            markValueRefUsed(&unused, branch.condition);
            for (branch.true_jmp.args.items) |arg| markValueRefUsed(&unused, arg);
            for (branch.false_jmp.args.items) |arg| markValueRefUsed(&unused, arg);
        },
        .ret => |ref| markValueRefUsed(&unused, ref),
    }

    while (unused.findFirstSet()) |inst_id| {
        unused.unset(inst_id);
        const inst = &block.insts.items[inst_id];
        if (inst.tag.hasSideEffects() or inst.tag == .no_op) continue;
        inst.* = .noop;
        dirty = true;
    }

    return dirty;
}

fn markValueRefUsed(unused: *std.DynamicBitSetUnmanaged, ref: ValueRef) void {
    if (ref.tag == .inst) unused.unset(ref.data);
}

pub fn killUnreachableBlocks(alloc: std.mem.Allocator, func: *Func) !bool {
    var dirty: bool = false;
    var unused: std.DynamicBitSetUnmanaged = try .initFull(alloc, func.blocks.items.len);
    defer unused.deinit(alloc);
    markBlockRefs(func, &unused, 0);

    while (unused.findFirstSet()) |block_id_usize| {
        const block_id: u32 = @intCast(block_id_usize);
        unused.unset(block_id);

        const block = &func.blocks.items[block_id];
        if (block.isDead()) continue;
        block.kill(alloc);
        dirty = true;
    }

    return dirty;
}

fn markBlockRefs(func: *const Func, unused: *std.DynamicBitSetUnmanaged, block_id: u32) void {
    if (!unused.isSet(block_id)) return;
    unused.unset(block_id);

    const block = &func.blocks.items[block_id];
    switch (block.terminator) {
        .none => unreachable,
        .dead, .ret => {},
        .jmp => |jmp| {
            markBlockRefs(func, unused, jmp.block_id);
        },
        .branch => |branch| {
            markBlockRefs(func, unused, branch.true_jmp.block_id);
            markBlockRefs(func, unused, branch.false_jmp.block_id);
        },
    }
}

pub fn mergeBlocks(alloc: std.mem.Allocator, func: *Func) !bool {
    var dirty: bool = false;

    var old_to_new_val: std.hash_map.AutoHashMapUnmanaged(ValueRef, ValueRef) = .empty;
    defer old_to_new_val.deinit(alloc);

    for (func.blocks.items, 0..) |*block, block_id| {
        if (block.terminator != .jmp) continue;
        const other_id = block.terminator.jmp.block_id;
        if (other_id == block_id) continue;
        const other = &func.blocks.items[other_id];

        var ref_count: usize = 0;
        for (func.blocks.items) |x| {
            switch (x.terminator) {
                .none => unreachable,
                .dead, .ret => {},
                .jmp => |jmp| {
                    if (jmp.block_id == other_id) ref_count += 1;
                },
                .branch => |branch| {
                    if (branch.true_jmp.block_id == other_id) ref_count += 1;
                    if (branch.false_jmp.block_id == other_id) ref_count += 1;
                },
            }
        }

        if (ref_count != 1) continue;

        dirty = true;
        old_to_new_val.clearRetainingCapacity();

        for (block.terminator.jmp.args.items, 0..) |val, arg_id| {
            try old_to_new_val.put(alloc, .fromArg(@intCast(arg_id)), val);
        }

        try appendAndRemapInsts(alloc, other.insts.items, block, &old_to_new_val);

        block.terminator.deinit(alloc);
        block.terminator = other.terminator;
        other.terminator = .none;
        other.kill(alloc);

        remapTerminatorValRefs(&block.terminator, &old_to_new_val);
    }

    return dirty;
}

pub fn appendAndRemapInsts(alloc: std.mem.Allocator, src: []const Inst, dst: *Block, val_map: *std.hash_map.AutoHashMapUnmanaged(ValueRef, ValueRef)) !void {
    try dst.insts.ensureUnusedCapacity(alloc, src.len);

    for (src, 0..) |inst, inst_id| {
        if (inst.tag == .no_op) continue;
        const old: ValueRef = .fromInst(@intCast(inst_id));

        const new = switch (inst.tag.getDataKind()) {
            .none => try dst.appendInst(alloc, inst),
            .bin => blk: {
                const bin = inst.data.bin;
                const new_left = getValRefFromMap(val_map, bin.left);
                const new_right = getValRefFromMap(val_map, bin.right);
                break :blk try dst.appendInst(alloc, .bin(inst.tag, new_left, new_right));
            },
        };

        try val_map.put(alloc, old, new);
    }
}

pub fn remapTerminatorValRefs(term: *Terminator, val_map: *const std.hash_map.AutoHashMapUnmanaged(ValueRef, ValueRef)) void {
    switch (term.*) {
        .none, .dead => unreachable,
        .ret => |*ref| ref.* = getValRefFromMap(val_map, ref.*),
        .jmp => |jmp| {
            for (jmp.args.items) |*arg| arg.* = getValRefFromMap(val_map, arg.*);
        },
        .branch => |*branch| {
            branch.condition = getValRefFromMap(val_map, branch.condition);
            for (branch.true_jmp.args.items) |*arg| arg.* = getValRefFromMap(val_map, arg.*);
            for (branch.false_jmp.args.items) |*arg| arg.* = getValRefFromMap(val_map, arg.*);
        },
    }
}

fn getValRefFromMap(map: *const std.hash_map.AutoHashMapUnmanaged(ValueRef, ValueRef), ref: ValueRef) ValueRef {
    if (ref.tag == .imm) return ref;
    return map.get(ref) orelse unreachable;
}

pub fn remapValueRef(block: *Block, old: ValueRef, new: ValueRef) void {
    std.debug.assert(old.tag != .imm);

    for (block.insts.items) |*inst| {
        switch (inst.tag.getDataKind()) {
            .none => {},
            .bin => {
                const bin = &inst.data.bin;
                if (bin.left == old) bin.left = new;
                if (bin.right == old) bin.right = new;
            },
        }
    }

    switch (block.terminator) {
        .none, .dead => unreachable,
        .ret => |*ret| {
            if (ret.* == old) ret.* = new;
        },
        .jmp => |jmp| {
            for (jmp.args.items) |*ref| {
                if (ref.* == old) ref.* = new;
            }
        },
        .branch => |*branch| {
            if (branch.condition == old) branch.condition = new;

            for (branch.true_jmp.args.items) |*ref| {
                if (ref.* == old) ref.* = new;
            }

            for (branch.false_jmp.args.items) |*ref| {
                if (ref.* == old) ref.* = new;
            }
        },
    }
}

pub fn removeUnusedArgs(alloc: std.mem.Allocator, func: *Func, block_id: BlockId) !bool {
    // args to the first block are function parameters and cant be removed
    if (block_id == 0) return false;

    var dirty: bool = false;
    const block = &func.blocks.items[block_id];
    var unused: std.DynamicBitSetUnmanaged = try .initFull(alloc, block.arg_count);
    defer unused.deinit(alloc);

    for (block.insts.items) |inst| {
        switch (inst.tag.getDataKind()) {
            .none => {},
            .bin => {
                const bin = inst.data.bin;
                markArgRefUsed(&unused, bin.left);
                markArgRefUsed(&unused, bin.right);
            },
        }
    }

    switch (block.terminator) {
        .none, .dead => unreachable,
        .ret => |ref| markArgRefUsed(&unused, ref),
        .jmp => |jmp| {
            for (jmp.args.items) |ref| markArgRefUsed(&unused, ref);
        },
        .branch => |branch| {
            markArgRefUsed(&unused, branch.condition);
            for (branch.true_jmp.args.items) |ref| markArgRefUsed(&unused, ref);
            for (branch.false_jmp.args.items) |ref| markArgRefUsed(&unused, ref);
        },
    }

    while (unused.findFirstSet()) |arg_id| {
        dirty = true;
        unused.unset(arg_id);
        // const ref: ValueRef = .fromArg(@intCast(arg_id));

        block.arg_count -= 1;
        const last = block.arg_count;
        if (arg_id != last) {
            unused.setValue(arg_id, unused.isSet(last));
            unused.unset(last);
            remapValueRef(block, .fromArg(@intCast(last)), .fromArg(@intCast(arg_id)));
        }

        for (func.blocks.items) |*other| {
            switch (other.terminator) {
                .none => unreachable,
                .dead, .ret => {},
                .jmp => |*jmp| {
                    if (jmp.block_id == block_id)
                        _ = jmp.args.swapRemove(arg_id);
                },
                .branch => |*branch| {
                    if (branch.true_jmp.block_id == block_id)
                        _ = branch.true_jmp.args.swapRemove(arg_id);

                    if (branch.false_jmp.block_id == block_id)
                        _ = branch.false_jmp.args.swapRemove(arg_id);
                },
            }
        }
    }

    return dirty;
}

const ArgImmState = union(enum) {
    unknown,
    overdefined,
    imm: ImmRef,

    fn merge(a: ArgImmState, b: ArgImmState, func: *const Func) ArgImmState {
        return switch (a) {
            .unknown => b,
            .overdefined => .overdefined,
            .imm => |x| switch (b) {
                .unknown => a,
                .overdefined => .overdefined,
                .imm => |y| if (func.imms.items[x] == func.imms.items[y]) a else .overdefined,
            },
        };
    }
};

fn setArgImmStateFromJmp(func: *const Func, jmp: Terminator.Jmp, pred_block_id: usize, arg_imm_states: []const []ArgImmState) bool {
    var dirty: bool = false;
    const block_arg_imm_states = arg_imm_states[jmp.block_id][0..];

    for (jmp.args.items, 0..) |ref, arg_id| {
        const local_state: ArgImmState = switch (ref.tag) {
            .arg => arg_imm_states[pred_block_id][ref.data],
            .inst => .overdefined,
            .imm => .{ .imm = ref.data },
        };

        const state = &block_arg_imm_states[arg_id];
        const old = state.*;
        state.* = state.merge(local_state, func);

        dirty = dirty or (std.meta.activeTag(state.*) != old);
    }

    return dirty;
}

pub fn forwardImmediates(alloc: std.mem.Allocator, func: *Func) !bool {
    const dirty: bool = false;

    const imm_states = try alloc.alloc([]ArgImmState, func.blocks.items.len);
    defer alloc.free(imm_states);

    for (imm_states, func.blocks.items) |*block_imm_states, block| {
        block_imm_states.* = try alloc.alloc(ArgImmState, block.arg_count);
        @memset(block_imm_states.*, .unknown);
    }
    defer for (imm_states) |block_imm_states| alloc.free(block_imm_states);

    var imm_state_dirty: bool = true;
    while (imm_state_dirty) {
        imm_state_dirty = false;

        for (func.blocks.items, 0..) |*block, block_id| {
            switch (block.terminator) {
                .none => unreachable,
                .dead, .ret => {},
                .jmp => |jmp| {
                    imm_state_dirty = setArgImmStateFromJmp(func, jmp, block_id, imm_states) or imm_state_dirty;
                },
                .branch => |branch| {
                    imm_state_dirty = setArgImmStateFromJmp(func, branch.true_jmp, block_id, imm_states) or imm_state_dirty;
                    imm_state_dirty = setArgImmStateFromJmp(func, branch.false_jmp, block_id, imm_states) or imm_state_dirty;
                },
            }
        }
    }

    for (func.blocks.items, imm_states) |*block, block_imm_states| {
        for (block_imm_states, 0..) |imm_state, arg_id| {
            const imm_ref = if (imm_state == .imm) imm_state.imm else continue;
            remapValueRef(
                block,
                .fromArg(@intCast(arg_id)),
                .{ .tag = .imm, .data = imm_ref },
            );
        }
    }

    return dirty;
}

fn bypassJmpsToEmptyBlocks(alloc: std.mem.Allocator, func: *Func) !bool {
    var dirty: bool = false;

    for (func.blocks.items, 0..) |*succ, succ_id| {
        if (succ.isDead()) continue;
        if (!succ.isEmpty()) continue;
        if (succ.terminator != .jmp) continue;

        for (func.blocks.items) |*pred| {
            switch (pred.terminator) {
                .none => unreachable,
                .dead, .ret => {},
                .jmp => |*jmp| {
                    dirty = try remapJmpToEmptyBlock(alloc, jmp, succ.*, succ_id) or dirty;
                },
                .branch => |*branch| {
                    dirty = try remapJmpToEmptyBlock(alloc, &branch.true_jmp, succ.*, succ_id) or dirty;
                    dirty = try remapJmpToEmptyBlock(alloc, &branch.false_jmp, succ.*, succ_id) or dirty;
                },
            }
        }
    }

    return dirty;
}

fn remapJmpToEmptyBlock(alloc: std.mem.Allocator, pred_jmp: *Terminator.Jmp, succ: Block, succ_id: usize) !bool {
    if (succ_id != pred_jmp.block_id) return false;
    std.debug.assert(succ.terminator == .jmp);

    const succ_jmp = succ.terminator.jmp;
    const new_args = try alloc.alloc(ValueRef, succ_jmp.args.items.len);
    errdefer alloc.free(new_args);

    for (new_args, succ_jmp.args.items) |*new, succ_arg| {
        new.* = switch (succ_arg.tag) {
            .inst => unreachable,
            .inst => succ_arg,
            .arg => pred_jmp.args.items[succ_arg.data],
        };
    }

    pred_jmp.args.deinit(alloc);
    pred_jmp.args = .fromOwnedSlice(new_args);
    pred_jmp.block_id = succ_jmp.block_id;
    return true;
}

fn markArgRefUsed(unused: *std.DynamicBitSetUnmanaged, ref: ValueRef) void {
    if (ref.tag == .arg) unused.unset(ref.data);
}

pub fn optimize(alloc: std.mem.Allocator, func: *Func) !void {
    while (true) {
        var dirty: bool = false;

        for (func.blocks.items, 0..) |*block, block_id| {
            if (block.isDead()) continue;

            dirty = try removeUnusedArgs(alloc, func, @intCast(block_id)) or dirty;
            dirty = try foldConstants(alloc, func, block) or dirty;
            dirty = try killUnusedInsts(alloc, block) or dirty;
        }

        dirty = try forwardImmediates(alloc, func) or dirty;
        dirty = try mergeBlocks(alloc, func) or dirty;
        dirty = try killUnreachableBlocks(alloc, func) or dirty;
        dirty = try bypassJmpsToEmptyBlocks(alloc, func) or dirty;

        if (!dirty) break;
    }
}

pub fn clean(alloc: std.mem.Allocator, func: *Func) !void {
    // remove dead blocks
    var block_id: BlockId = 0;
    while (block_id < func.blocks.items.len) {
        const block = &func.blocks.items[block_id];
        if (!block.isDead()) {
            block_id += 1;
            continue;
        }

        const last_id: BlockId = @intCast(func.blocks.items.len - 1);
        _ = func.blocks.swapRemove(block_id);
        if (block_id == last_id) continue;

        for (func.blocks.items) |*b| {
            switch (b.terminator) {
                .none => unreachable,
                .dead, .ret => {},
                .jmp => |*jmp| {
                    if (jmp.block_id == last_id) jmp.block_id = block_id;
                },
                .branch => |*branch| {
                    if (branch.true_jmp.block_id == last_id) branch.true_jmp.block_id = block_id;
                    if (branch.false_jmp.block_id == last_id) branch.false_jmp.block_id = block_id;
                },
            }
        }
    }

    // remove no ops
    for (func.blocks.items) |*block| {
        var old_to_new_refs: std.AutoHashMapUnmanaged(ValueRef, ValueRef) = .empty;
        defer old_to_new_refs.deinit(alloc);

        var old_insts = block.insts;
        defer old_insts.deinit(alloc);

        block.insts = try .initCapacity(alloc, old_insts.items.len);

        for (0..block.arg_count) |arg_id| {
            const ref: ValueRef = .fromArg(@intCast(arg_id));
            try old_to_new_refs.put(alloc, ref, ref);
        }

        try appendAndRemapInsts(alloc, old_insts.items, block, &old_to_new_refs);
        remapTerminatorValRefs(&block.terminator, &old_to_new_refs);
    }
}

pub fn validate(func: Func) void {
    for (func.blocks.items) |block| {
        for (block.insts.items, 0..) |inst, inst_id| {
            switch (inst.tag) {
                .no_op => unreachable,
                .add, .sub, .mul, .div, .equal, .less, .more => {
                    const bin = inst.data.bin;
                    validateRef(func, block, bin.left, @intCast(inst_id));
                    validateRef(func, block, bin.right, @intCast(inst_id));
                },
            }
        }

        switch (block.terminator) {
            .none, .dead => unreachable,
            .ret => |ref| validateRef(func, block, ref, null),
            .jmp => |jmp| validateJmp(func, block, jmp),
            .branch => |branch| {
                validateRef(func, block, branch.condition, null);
                validateJmp(func, block, branch.true_jmp);
                validateJmp(func, block, branch.false_jmp);
            },
        }
    }
}

fn validateRef(func: Func, block: Block, ref: ValueRef, maybe_current_inst_ref: ?InstRef) void {
    const inst_ref = maybe_current_inst_ref orelse block.insts.items.len;

    switch (ref.tag) {
        .inst => std.debug.assert(ref.data < inst_ref),
        .arg => std.debug.assert(ref.data < block.arg_count),
        .imm => std.debug.assert(ref.data < func.imms.items.len),
    }
}

fn validateJmp(func: Func, current: Block, jmp: Terminator.Jmp) void {
    std.debug.assert(jmp.block_id < func.blocks.items.len);
    std.debug.assert(jmp.args.items.len == func.blocks.items[jmp.block_id].arg_count);
    for (jmp.args.items) |arg| validateRef(func, current, arg, null);
}

pub fn printFunc(writer: *std.Io.Writer, func: Func) !void {
    for (func.blocks.items, 0..) |block, block_id| {
        try writer.print("@{}(", .{block_id});

        for (0..block.arg_count) |arg_id| {
            try writer.print("%{}", .{arg_id});

            if (arg_id != block.arg_count - 1)
                try writer.print(", ", .{});
        }

        try writer.print("):\n", .{});

        for (block.insts.items, 0..) |inst, inst_id| {
            try writer.print("${} = {s} ", .{ inst_id, @tagName(inst.tag) });

            switch (inst.tag.getDataKind()) {
                .none => {},
                .bin => {
                    const bin = inst.data.bin;
                    try printValRef(writer, func, bin.left);
                    try writer.print(", ", .{});
                    try printValRef(writer, func, bin.right);
                },
            }

            try writer.print("\n", .{});
        }

        switch (block.terminator) {
            .none => try writer.print("block under construction", .{}),
            .dead => try writer.print("dead block", .{}),
            .ret => |val| {
                try writer.print("ret ", .{});
                try printValRef(writer, func, val);
            },
            .jmp => |jmp| {
                try writer.print("jmp ", .{});
                try printJmp(writer, func, jmp);
            },
            .branch => |branch| {
                try writer.print("branch ", .{});
                try printValRef(writer, func, branch.condition);
                try writer.print(" ? ", .{});
                try printJmp(writer, func, branch.true_jmp);
                try writer.print(" : ", .{});
                try printJmp(writer, func, branch.false_jmp);
            },
        }

        try writer.print("\n\n", .{});
    }
}

fn printJmp(writer: *std.Io.Writer, func: Func, jmp: Terminator.Jmp) !void {
    try writer.print("@{}(", .{jmp.block_id});

    for (jmp.args.items, 0..) |arg, i| {
        try printValRef(writer, func, arg);

        if (i != jmp.args.items.len - 1)
            try writer.print(", ", .{});
    }

    try writer.print(")", .{});
}

fn printValRef(writer: *std.Io.Writer, func: Func, ref: ValueRef) !void {
    switch (ref.tag) {
        .inst => try writer.print("${}", .{ref.data}),
        .arg => try writer.print("%{}", .{ref.data}),
        .imm => try writer.print("{}", .{func.imms.items[ref.data]}),
    }
}
