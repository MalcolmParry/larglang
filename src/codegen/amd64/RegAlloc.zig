const std = @import("std");
const Mir = @import("Mir.zig");
const Ramir = @import("Ramir.zig");

const sysv_arg_order = [_]Ramir.Reg{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 };
const GlobalValRef = union(enum) {
    imm: Mir.ImmId,
    inst: Local,
    arg: Local,
    stack_addr: Mir.StackSlotId,

    pub const Local = struct {
        id: Mir.Inst.Id,
        block: Mir.Block.Id,
    };
};

const Alloc = union(enum) {
    reg: Ramir.Reg,
    stack: u32,

    pub const Map = std.AutoHashMapUnmanaged(GlobalValRef, Alloc);
};

const State = struct {
    alloc: std.mem.Allocator,
    mir: *const Mir,
    alloc_map: *Alloc.Map,
    stack_slot_offsets: []i32,
    ramir: *Ramir,
};

pub fn emitRamir(alloc: std.mem.Allocator, mir: Mir) !Ramir {
    var alloc_result = try allocRegs(alloc, mir);
    const map = &alloc_result.map;
    defer map.deinit(alloc);

    var stack_top: u31 = @intCast(alloc_result.stack_top);
    const stack_slot_offsets = try alloc.alloc(i32, mir.stack_slots.items.len);
    defer alloc.free(stack_slot_offsets);

    for (mir.stack_slots.items, 0..) |slot, slot_id| {
        stack_top += @intCast(slot.size);
        stack_slot_offsets[slot_id] = -@as(i32, stack_top);
    }

    stack_top = std.mem.alignForward(u31, stack_top, 16);

    var ramir: Ramir = .{
        .link_sym = mir.link_sym,
        .blocks = try .initCapacity(alloc, mir.blocks.items.len),
        .imms = try mir.imms.clone(alloc),
    };
    errdefer ramir.deinit(alloc);

    const state: State = .{
        .alloc = alloc,
        .mir = &mir,
        .alloc_map = map,
        .stack_slot_offsets = stack_slot_offsets,
        .ramir = &ramir,
    };

    for (mir.blocks.items, 0..) |block, block_id| {
        const ra_block = ramir.blocks.addOneAssumeCapacity();
        ra_block.* = .{
            .insts = try .initCapacity(alloc, block.insts.len),
            .term = .none,
        };

        if (block_id == 0) {
            try ra_block.insts.append(alloc, .{
                .tag = .push,
                .data_kind = .r,
                .data = .{ .r = .rbp },
            });

            try ra_block.insts.append(alloc, .{
                .tag = .mov,
                .data_kind = .rr,
                .data = .{ .rr = .{ .r1 = .rbp, .r2 = .rsp } },
            });

            try ramir.imms.append(alloc, .{ .int = stack_top });
            try ra_block.insts.append(alloc, .{
                .tag = .sub,
                .data_kind = .ri,
                .data = .{ .ri = .{ .r = .rsp, .i = @intCast(ramir.imms.items.len - 1) } },
            });

            if (block.arg_count > sysv_arg_order.len) return error.TooManyParameters;

            for (0..block.arg_count) |arg_id| {
                try storeRegInAlloc(alloc, ra_block, sysv_arg_order[arg_id], map.get(.{
                    .arg = .{
                        .block = @intCast(block_id),
                        .id = @intCast(arg_id),
                    },
                }) orelse unreachable);
            }
        }

        for (0..block.insts.len) |inst_id| {
            const inst = block.insts.get(inst_id);

            switch (inst.tag) {
                .no_op => continue,
                .load => {
                    const ref = inst.data.unary;
                    std.debug.assert(ref.tag == .imm);

                    try ra_block.insts.append(alloc, .{
                        .tag = .mov,
                        .data_kind = .rm,
                        .data = .{ .rm = .{
                            .r = .rax,
                            .m = .{
                                .base = .{ .global = mir.imms.items[ref.id].global_addr },
                                .mod = .{ .off = 0 },
                            },
                        } },
                    });

                    try storeRegInAlloc(alloc, ra_block, .rax, map.get(.{
                        .inst = .{
                            .block = @intCast(block_id),
                            .id = @intCast(inst_id),
                        },
                    }) orelse unreachable);
                },
                .store => {
                    const bin = inst.data.bin;
                    try putGlobalRefInReg(state, ra_block, .rax, globalRefFromLocal(@intCast(block_id), bin.right));

                    std.debug.assert(bin.left.tag == .imm);
                    try ra_block.insts.append(alloc, .{
                        .tag = .mov,
                        .data_kind = .mr,
                        .data = .{ .rm = .{
                            .r = .rax,
                            .m = .{
                                .base = .{ .global = mir.imms.items[bin.left.id].global_addr },
                                .mod = .{ .off = 0 },
                            },
                        } },
                    });
                },
                .add, .sub, .mul, .udiv, .cmp_eq, .cmp_ult, .cmp_ugt => {
                    const bin = inst.data.bin;
                    try putGlobalRefInReg(state, ra_block, .rax, globalRefFromLocal(@intCast(block_id), bin.left));
                    try putGlobalRefInReg(state, ra_block, .rcx, globalRefFromLocal(@intCast(block_id), bin.right));

                    switch (inst.tag) {
                        .udiv => {
                            try ra_block.insts.append(alloc, .{
                                .tag = .xor,
                                .data_kind = .rr,
                                .data = .{ .rr = .{
                                    .r1 = .edx,
                                    .r2 = .edx,
                                } },
                            });

                            try ra_block.insts.append(alloc, .{
                                .tag = .div,
                                .data_kind = .r,
                                .data = .{ .r = .rcx },
                            });

                            try storeRegInAlloc(alloc, ra_block, .rax, map.get(.{
                                .inst = .{
                                    .block = @intCast(block_id),
                                    .id = @intCast(inst_id),
                                },
                            }) orelse unreachable);
                        },
                        .add, .sub, .mul => {
                            const tag: Ramir.Inst.Tag = switch (inst.tag) {
                                .add => .add,
                                .sub => .sub,
                                .mul => .mul,
                                else => unreachable,
                            };

                            try ra_block.insts.append(alloc, .{
                                .tag = tag,
                                .data_kind = .rr,
                                .data = .{
                                    .rr = .{ .r1 = .rax, .r2 = .rcx },
                                },
                            });

                            try storeRegInAlloc(alloc, ra_block, .rax, map.get(.{
                                .inst = .{
                                    .block = @intCast(block_id),
                                    .id = @intCast(inst_id),
                                },
                            }) orelse unreachable);
                        },
                        else => unreachable,
                    }
                },
                .call => {
                    const data = inst.data.val_ref_list;
                    const ref_slice = mir.extra_val_refs.items[data.start..][0..data.len];

                    try putGlobalRefInReg(state, ra_block, .rax, globalRefFromLocal(@intCast(block_id), ref_slice[0]));

                    const args = ref_slice[1..];
                    if (args.len > sysv_arg_order.len) return error.TooManyArgs;

                    for (args, 0..) |ref, arg_id| {
                        try putGlobalRefInReg(state, ra_block, sysv_arg_order[arg_id], globalRefFromLocal(@intCast(block_id), ref));
                    }

                    try ra_block.insts.append(alloc, .{
                        .tag = .call,
                        .data_kind = .r,
                        .data = .{ .r = .rax },
                    });

                    try storeRegInAlloc(alloc, ra_block, .rax, map.get(.{
                        .inst = .{
                            .block = @intCast(block_id),
                            .id = @intCast(inst_id),
                        },
                    }) orelse unreachable);
                },
            }
        }

        ra_block.term = switch (block.term) {
            .none => unreachable,
            .ret => |ref| blk: {
                try putGlobalRefInReg(
                    state,
                    ra_block,
                    .rax,
                    globalRefFromLocal(@intCast(block_id), ref),
                );

                try ra_block.insts.append(alloc, .{
                    .tag = .mov,
                    .data_kind = .rr,
                    .data = .{ .rr = .{ .r1 = .rsp, .r2 = .rbp } },
                });

                try ra_block.insts.append(alloc, .{
                    .tag = .pop,
                    .data_kind = .r,
                    .data = .{ .r = .rbp },
                });

                try ra_block.insts.append(alloc, .{
                    .tag = .ret,
                    .data_kind = .none,
                    .data = .{ .none = {} },
                });

                break :blk .not_reachable;
            },
            .jmp => |jmp| blk: {
                try storeJmpArgs(state, @intCast(block_id), jmp);
                break :blk .{ .jmp = @intCast(jmp.block_id) };
            },
            .branch_bool => |b| blk: {
                try storeJmpArgs(state, @intCast(block_id), b.then_jmp);
                try storeJmpArgs(state, @intCast(block_id), b.else_jmp);

                try putGlobalRefInReg(state, ra_block, .rax, globalRefFromLocal(@intCast(block_id), b.cond));
                try ramir.imms.append(alloc, .{ .int = 0 });
                try ra_block.insts.append(alloc, .{
                    .tag = .cmp,
                    .data_kind = .ri,
                    .data = .{ .ri = .{ .r = .rax, .i = @intCast(ramir.imms.items.len - 1) } },
                });

                break :blk .{ .branch = .{
                    .cond = .eq,
                    .then_jmp = @intCast(b.then_jmp.block_id),
                    .else_jmp = @intCast(b.else_jmp.block_id),
                } };
            },
            .branch_cmp => |b| blk: {
                try storeJmpArgs(state, @intCast(block_id), b.then_jmp);
                try storeJmpArgs(state, @intCast(block_id), b.else_jmp);

                try putGlobalRefInReg(state, ra_block, .rax, globalRefFromLocal(@intCast(block_id), b.left));
                try putGlobalRefInReg(state, ra_block, .rcx, globalRefFromLocal(@intCast(block_id), b.right));
                try ra_block.insts.append(alloc, .{
                    .tag = .cmp,
                    .data_kind = .rr,
                    .data = .{ .rr = .{ .r1 = .rax, .r2 = .rcx } },
                });

                break :blk .{ .branch = .{
                    .cond = switch (b.cond) {
                        .eq => .eq,
                        .ult => .ult,
                        .ugt => .ugt,
                    },
                    .then_jmp = @intCast(b.then_jmp.block_id),
                    .else_jmp = @intCast(b.else_jmp.block_id),
                } };
            },
        };
    }

    return ramir;
}

fn storeJmpArgs(state: State, block_id: Ramir.Block.Id, jmp: Mir.Term.Jmp) !void {
    const alloc = state.alloc;
    const block = &state.ramir.blocks.items[block_id];

    for (jmp.args.items, 0..) |ref, arg_id| {
        const global = globalRefFromLocal(block_id, ref);
        try putGlobalRefInReg(state, block, .rax, global);
        try storeRegInAlloc(alloc, block, .rax, state.alloc_map.get(.{ .arg = .{
            .block = @intCast(jmp.block_id),
            .id = @intCast(arg_id),
        } }) orelse unreachable);
    }
}

fn globalRefFromLocal(block_id: Mir.Block.Id, ref: Mir.ValueRef) GlobalValRef {
    const local: GlobalValRef.Local = .{
        .block = block_id,
        .id = ref.id,
    };

    return switch (ref.tag) {
        .inst => .{ .inst = local },
        .arg => .{ .arg = local },
        .stack_addr => .{ .stack_addr = ref.id },
        .imm => .{ .imm = ref.id },
    };
}

fn putGlobalRefInReg(state: State, block: *Ramir.Block, reg: Ramir.Reg, ref: GlobalValRef) !void {
    const alloc = state.alloc;
    const map = state.alloc_map;

    switch (ref) {
        .inst, .arg => try putAllocInReg(alloc, block, reg, map.get(ref) orelse unreachable),
        .imm => |imm| try block.insts.append(alloc, .{
            .tag = .mov,
            .data_kind = .ri,
            .data = .{ .ri = .{
                .r = reg,
                .i = @intCast(imm),
            } },
        }),
        .stack_addr => |id| try block.insts.append(alloc, .{
            .tag = .lea,
            .data_kind = .rm,
            .data = .{ .rm = .{
                .r = reg,
                .m = .{
                    .base = .{ .reg = .rbp },
                    .mod = .{ .rm = .{
                        .index = .none,
                        .scale = .@"1",
                        .disp = state.stack_slot_offsets[id],
                    } },
                },
            } },
        }),
    }
}

fn putAllocInReg(alloc: std.mem.Allocator, block: *Ramir.Block, reg: Ramir.Reg, allocation: Alloc) !void {
    switch (allocation) {
        .reg => |areg| {
            if (areg == reg) return;

            try block.insts.append(alloc, .{
                .tag = .mov,
                .data_kind = .rr,
                .data = .{ .rr = .{
                    .r1 = reg,
                    .r2 = areg,
                } },
            });
        },
        .stack => |stack| {
            try block.insts.append(alloc, .{
                .tag = .mov,
                .data_kind = .rm,
                .data = .{ .rm = .{
                    .r = reg,
                    .m = .{
                        .base = .{ .reg = .rbp },
                        .mod = .{ .rm = .{
                            .index = .none,
                            .scale = .@"1",
                            .disp = -@as(i32, @intCast(stack)) - 8,
                        } },
                    },
                } },
            });
        },
    }
}

fn storeRegInAlloc(alloc: std.mem.Allocator, block: *Ramir.Block, reg: Ramir.Reg, allocation: Alloc) !void {
    switch (allocation) {
        .reg => |areg| {
            if (areg == reg) return;

            try block.insts.append(alloc, .{
                .tag = .mov,
                .data_kind = .rr,
                .data = .{ .rr = .{
                    .r1 = areg,
                    .r2 = reg,
                } },
            });
        },
        .stack => |stack| {
            try block.insts.append(alloc, .{
                .tag = .mov,
                .data_kind = .mr,
                .data = .{ .rm = .{
                    .m = .{
                        .base = .{ .reg = .rbp },
                        .mod = .{ .rm = .{
                            .index = .none,
                            .scale = .@"1",
                            .disp = -@as(i32, @intCast(stack)) - 8,
                        } },
                    },
                    .r = reg,
                } },
            });
        },
    }
}

const AllocRegsResult = struct {
    map: Alloc.Map,
    stack_top: u32,
};

fn allocRegs(alloc: std.mem.Allocator, mir: Mir) !AllocRegsResult {
    var map: Alloc.Map = .empty;
    errdefer map.deinit(alloc);

    var stack_top: u32 = 0;
    for (mir.blocks.items, 0..) |block, block_id| {
        for (0..block.arg_count) |arg_id| {
            try map.put(
                alloc,
                .{ .arg = .{ .block = @intCast(block_id), .id = @intCast(arg_id) } },
                .{ .stack = @intCast(stack_top + arg_id * 8) },
            );
        }
        stack_top += block.arg_count * 8;

        for (0..block.insts.len) |inst_id| {
            try map.put(
                alloc,
                .{ .inst = .{ .block = @intCast(block_id), .id = @intCast(inst_id) } },
                .{ .stack = @intCast(stack_top + inst_id * 8) },
            );
        }
        stack_top += @intCast(block.insts.len * 8);
    }

    return .{
        .map = map,
        .stack_top = stack_top,
    };
}
