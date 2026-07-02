const std = @import("std");
const Ir = @import("Ir.zig");
const Func = Ir.Func;
const Block = Ir.Block;
const ValueRef = Ir.ValueRef;
const Terminator = Ir.Terminator;
const ImmRef = Ir.ImmRef;
const InstRef = Ir.InstRef;
const BlockId = Ir.BlockId;
const Inst = Ir.Inst;

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
            .imm => succ_arg,
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
