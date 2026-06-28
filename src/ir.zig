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

    pub fn appendInst(block: *Block, alloc: std.mem.Allocator, inst: Inst) !ValueRef {
        try block.insts.append(alloc, inst);
        return .fromInst(@intCast(block.insts.items.len - 1));
    }

    pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (this.insts.items, 0..) |inst, inst_id| {
            switch (inst.tag) {
                .no_op => try writer.print("${} = noop\n", .{inst_id}),
                .imm => try writer.print("${} = {}\n", .{ inst_id, inst.data.imm }),
                .add, .sub, .mul, .div, .equal => try writer.print("${} = {s} {f}, {f}\n", .{
                    inst_id,
                    @tagName(inst.tag),
                    inst.data.bin.left,
                    inst.data.bin.right,
                }),
            }
        }

        switch (this.terminator) {
            .none => try writer.print("block under construction\n", .{}),
            .dead => try writer.print("dead block\n", .{}),
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
    data: InstRef,
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

    pub fn fromInst(inst_id: u31) ValueRef {
        return .{ .tag = .inst, .data = inst_id };
    }

    pub fn fromArg(arg_id: u31) ValueRef {
        return .{ .tag = .arg, .data = arg_id };
    }
};

pub const InstRef = u31;
pub const Inst = struct {
    tag: Tag,
    data: Data,

    pub const Tag = enum {
        no_op,
        imm,
        add,
        sub,
        mul,
        div,
        equal,

        pub fn getDataKind(tag: Tag) Data.Kind {
            return switch (tag) {
                .no_op => .none,
                .imm => .imm,
                .add, .sub, .mul, .div, .equal => .bin,
            };
        }

        pub fn isPure(tag: Tag) bool {
            _ = tag;
            return true;
        }
    };

    pub const Data = union {
        imm: u64,
        bin: BinOp,

        pub const Kind = enum {
            none,
            imm,
            bin,
        };
    };

    pub const BinOp = struct {
        left: ValueRef,
        right: ValueRef,
    };

    pub const noop: Inst = .{ .tag = .no_op, .data = undefined };
    pub fn imm(val: u64) Inst {
        return .{ .tag = .imm, .data = .{ .imm = val } };
    }

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

                block.terminator = .{
                    .ret = try block.appendInst(gpa, .imm(0)),
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
            return block.appendInst(gpa, .imm(val));
        },
        .bin => |bin| {
            const left_ref = try compileExpr(state, block, ident_map, bin.left);
            const right_ref = try compileExpr(state, block, ident_map, bin.right);

            const tag: Inst.Tag = switch (bin.op) {
                .add => .add,
                .sub => .sub,
                .mul => .mul,
                .div => .div,
                .equal => .equal,
            };

            return block.appendInst(gpa, .bin(tag, left_ref, right_ref));
        },
        .ident => |ident| {
            return ident_map.get(ident.get(state.lexer)) orelse error.CompileFailed;
        },
    }
}

pub fn foldConstants(alloc: std.mem.Allocator, block: *Block) !bool {
    var dirty: bool = false;

    for (block.insts.items) |*inst| {
        switch (inst.tag) {
            .add, .sub, .mul, .div, .equal => {
                const bin = inst.data.bin;
                const left = getImmediate(block, bin.left) orelse continue;
                const right = getImmediate(block, bin.right) orelse continue;

                const result: u64 = switch (inst.tag) {
                    .add => left +% right,
                    .sub => left -% right,
                    .mul => left *% right,
                    .div => try std.math.divTrunc(u64, left, right),
                    .equal => @intFromBool(left == right),
                    else => unreachable,
                };

                dirty = true;
                inst.* = .imm(result);
            },
            else => {},
        }
    }

    blk: switch (block.terminator) {
        .none, .dead, .jmp, .ret => {},
        .branch => |*branch| {
            const val = getImmediate(block, branch.condition) orelse break :blk;
            const jmp = if (val != 0) branch.true_jmp else branch.false_jmp;
            const other = if (val != 0) &branch.false_jmp else &branch.true_jmp;

            dirty = true;
            other.deinit(alloc);
            block.terminator = .{ .jmp = jmp };
        },
    }

    return dirty;
}

pub fn getImmediate(block: *const Block, ref: ValueRef) ?u64 {
    return switch (ref.tag) {
        .arg => null,
        .inst => {
            const inst = block.insts.items[ref.data];
            if (inst.tag == .imm) return inst.data.imm;
            return null;
        },
    };
}

pub fn removeUnusedPureInsts(alloc: std.mem.Allocator, block: *Block) !bool {
    var dirty: bool = false;

    var unused: std.DynamicBitSetUnmanaged = try .initFull(alloc, block.insts.items.len);
    defer unused.deinit(alloc);

    for (block.insts.items) |inst| {
        switch (inst.tag.getDataKind()) {
            .none, .imm => {},
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
        if (!inst.tag.isPure() or inst.tag == .no_op) continue;
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
        var old_to_new_val: std.hash_map.AutoHashMapUnmanaged(ValueRef, ValueRef) = .empty;
        defer old_to_new_val.deinit(alloc);

        for (block.terminator.jmp.args.items, 0..) |val, arg_id| {
            try old_to_new_val.put(alloc, .fromArg(@intCast(arg_id)), val);
        }

        for (other.insts.items, 0..) |inst, inst_id| {
            const old: ValueRef = .fromInst(@intCast(inst_id));

            switch (inst.tag.getDataKind()) {
                .none => {},
                .imm => {
                    const new = try block.appendInst(alloc, .imm(inst.data.imm));
                    try old_to_new_val.put(alloc, old, new);
                },
                .bin => {
                    const bin = inst.data.bin;
                    const new_left = old_to_new_val.get(bin.left) orelse unreachable;
                    const new_right = old_to_new_val.get(bin.right) orelse unreachable;
                    const new = try block.appendInst(alloc, .bin(inst.tag, new_left, new_right));
                    try old_to_new_val.put(alloc, old, new);
                },
            }
        }

        block.terminator.deinit(alloc);
        block.terminator = other.terminator;
        other.terminator = .none;
        other.kill(alloc);

        switch (block.terminator) {
            .none, .dead => unreachable,
            .ret => |*val| {
                val.* = old_to_new_val.get(val.*) orelse unreachable;
            },
            .jmp => |jmp| {
                for (jmp.args.items) |*arg| {
                    arg.* = old_to_new_val.get(arg.*) orelse unreachable;
                }
            },
            .branch => |*branch| {
                branch.condition = old_to_new_val.get(branch.condition) orelse unreachable;

                for (branch.true_jmp.args.items) |*arg| {
                    arg.* = old_to_new_val.get(arg.*) orelse unreachable;
                }

                for (branch.false_jmp.args.items) |*arg| {
                    arg.* = old_to_new_val.get(arg.*) orelse unreachable;
                }
            },
        }
    }

    return dirty;
}

pub fn optimize(alloc: std.mem.Allocator, func: *Func) !void {
    while (true) {
        var dirty: bool = false;

        for (func.blocks.items) |*block| {
            if (block.isDead()) continue;

            dirty = try foldConstants(alloc, block) or dirty;
            dirty = try removeUnusedPureInsts(alloc, block) or dirty;
        }

        dirty = try mergeBlocks(alloc, func) or dirty;
        dirty = try killUnreachableBlocks(alloc, func) or dirty;

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

        for (old_insts.items, 0..) |old_inst, old_inst_id| {
            const old_ref: ValueRef = .fromInst(@intCast(old_inst_id));

            switch (old_inst.tag) {
                .no_op => {},
                .imm => {
                    const new_ref = try block.appendInst(alloc, old_inst);
                    try old_to_new_refs.put(alloc, old_ref, new_ref);
                },
                .add, .sub, .mul, .div, .equal => {
                    const old_bin = old_inst.data.bin;
                    const new_ref = try block.appendInst(alloc, .bin(
                        old_inst.tag,
                        old_to_new_refs.get(old_bin.left) orelse unreachable,
                        old_to_new_refs.get(old_bin.right) orelse unreachable,
                    ));

                    try old_to_new_refs.put(alloc, old_ref, new_ref);
                },
            }
        }

        switch (block.terminator) {
            .none, .dead => unreachable,
            .ret => |*ret| ret.* = old_to_new_refs.get(ret.*) orelse unreachable,
            .jmp => |jmp| {
                for (jmp.args.items) |*arg| arg.* = old_to_new_refs.get(arg.*) orelse unreachable;
            },
            .branch => |*branch| {
                branch.condition = old_to_new_refs.get(branch.condition) orelse unreachable;
                for (branch.true_jmp.args.items) |*arg| arg.* = old_to_new_refs.get(arg.*) orelse unreachable;
                for (branch.false_jmp.args.items) |*arg| arg.* = old_to_new_refs.get(arg.*) orelse unreachable;
            },
        }
    }
}

pub fn validate(func: Func) void {
    for (func.blocks.items) |block| {
        for (block.insts.items, 0..) |inst, inst_id| {
            switch (inst.tag) {
                .no_op => unreachable,
                .imm => {},
                .add, .sub, .mul, .div, .equal => {
                    const bin = inst.data.bin;
                    validateRef(block, bin.left, @intCast(inst_id));
                    validateRef(block, bin.right, @intCast(inst_id));
                },
            }
        }

        switch (block.terminator) {
            .none, .dead => unreachable,
            .ret => |ref| validateRef(block, ref, null),
            .jmp => |jmp| validateJmp(func, block, jmp),
            .branch => |branch| {
                validateRef(block, branch.condition, null);
                validateJmp(func, block, branch.true_jmp);
                validateJmp(func, block, branch.false_jmp);
            },
        }
    }
}

fn validateRef(block: Block, ref: ValueRef, maybe_current_inst_ref: ?InstRef) void {
    const inst_ref = maybe_current_inst_ref orelse block.insts.items.len;

    switch (ref.tag) {
        .inst => std.debug.assert(ref.data < inst_ref),
        .arg => std.debug.assert(ref.data < block.arg_count),
    }
}

fn validateJmp(func: Func, current: Block, jmp: Terminator.Jmp) void {
    std.debug.assert(jmp.block_id < func.blocks.items.len);
    std.debug.assert(jmp.args.items.len == func.blocks.items[jmp.block_id].arg_count);
    for (jmp.args.items) |arg| validateRef(current, arg, null);
}
