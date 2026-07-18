const std = @import("std");
const Mir = @import("Mir.zig");

pub fn branchBoolToCond(mir: *Mir) !bool {
    var dirty: bool = false;

    for (mir.blocks.items) |*block| {
        if (block.term != .branch_bool) continue;
        const b = block.term.branch_bool;
        if (b.cond.tag != .inst) continue;
        const cond_inst = block.insts.get(b.cond.id);

        switch (cond_inst.tag) {
            .cmp_eq, .cmp_ult, .cmp_ugt => {
                const bin = cond_inst.data.bin;

                dirty = true;
                block.term = .{ .branch_cmp = .{
                    .cond = switch (cond_inst.tag) {
                        .cmp_eq => .eq,
                        .cmp_ult => .ult,
                        .cmp_ugt => .ugt,
                        else => unreachable,
                    },
                    .left = bin.left,
                    .right = bin.right,
                    .then_jmp = b.then_jmp,
                    .else_jmp = b.else_jmp,
                } };
            },
            else => {},
        }
    }

    return dirty;
}

pub fn killUnusedInsts(alloc: std.mem.Allocator, mir: *Mir) !bool {
    var dirty: bool = false;

    for (mir.blocks.items) |*block| {
        var unused_set: std.DynamicBitSetUnmanaged = try .initFull(alloc, block.insts.len);
        defer unused_set.deinit(alloc);

        for (0..block.insts.len) |inst_id| {
            const inst = block.insts.get(inst_id);

            switch (inst.tag.getDataKind()) {
                .none => {},
                .unary => markValRefUsed(&unused_set, inst.data.unary),
                .bin => {
                    const bin = inst.data.bin;
                    markValRefUsed(&unused_set, bin.left);
                    markValRefUsed(&unused_set, bin.right);
                },
                .val_ref_list => {
                    const data = inst.data.val_ref_list;
                    const slice = mir.extra_val_refs.items[data.start..][0..data.len];

                    for (slice) |ref| markValRefUsed(&unused_set, ref);
                },
            }
        }

        switch (block.term) {
            .none => {},
            .ret => |ref| markValRefUsed(&unused_set, ref),
            .jmp => |jmp| {
                for (jmp.args.items) |ref| markValRefUsed(&unused_set, ref);
            },
            .branch_bool => |b| {
                markValRefUsed(&unused_set, b.cond);
                for (b.then_jmp.args.items) |ref| markValRefUsed(&unused_set, ref);
                for (b.else_jmp.args.items) |ref| markValRefUsed(&unused_set, ref);
            },
            .branch_cmp => |b| {
                markValRefUsed(&unused_set, b.left);
                markValRefUsed(&unused_set, b.right);
                for (b.then_jmp.args.items) |ref| markValRefUsed(&unused_set, ref);
                for (b.else_jmp.args.items) |ref| markValRefUsed(&unused_set, ref);
            },
        }

        while (unused_set.findFirstSet()) |inst_id| {
            unused_set.unset(inst_id);
            const inst = block.insts.get(inst_id);

            if (inst.tag == .no_op) continue;
            if (inst.tag.hasSideEffects()) continue;

            dirty = true;
            block.insts.set(inst_id, .{
                .tag = .no_op,
                .data = .{ .none = {} },
            });
        }
    }

    return dirty;
}

fn markValRefUsed(unused_set: *std.DynamicBitSetUnmanaged, ref: Mir.ValueRef) void {
    if (ref.tag == .inst)
        unused_set.unset(ref.id);
}

pub fn optimize(alloc: std.mem.Allocator, mir: *Mir) !void {
    var dirty: bool = true;

    while (dirty) {
        dirty = false;

        dirty = try branchBoolToCond(mir) or dirty;
        dirty = try killUnusedInsts(alloc, mir) or dirty;
    }
}

pub fn clean(alloc: std.mem.Allocator, mir: *Mir) !void {
    _ = alloc;

    // remove no_ops
    for (mir.blocks.items) |*block| {
        var inst_id: usize = 0;
        while (inst_id < block.insts.len) {
            if (block.insts.items(.tag)[inst_id] != .no_op) {
                inst_id += 1;
                continue;
            }

            block.insts.orderedRemove(inst_id);
            for (inst_id..block.insts.len) |inner_id| {
                const inst = block.insts.get(inner_id);

                switch (inst.tag.getDataKind()) {
                    .none => {},
                    .unary => {
                        var ref = inst.data.unary;
                        if (ref.tag == .inst and ref.id >= inst_id) ref.id -= 1;
                        block.insts.items(.data)[inner_id] = .{ .unary = ref };
                    },
                    .bin => {
                        var bin = inst.data.bin;
                        if (bin.left.tag == .inst and bin.left.id >= inst_id) bin.left.id -= 1;
                        if (bin.right.tag == .inst and bin.right.id >= inst_id) bin.right.id -= 1;
                        block.insts.set(inner_id, .{
                            .tag = inst.tag,
                            .data = .{ .bin = bin },
                        });
                    },
                    .val_ref_list => {
                        const data = inst.data.val_ref_list;
                        const slice = mir.extra_val_refs.items[data.start..][0..data.len];

                        for (slice) |*ref| {
                            if (ref.tag == .inst and ref.id >= inst_id) ref.id -= 1;
                        }
                    },
                }
            }
        }
    }
}
