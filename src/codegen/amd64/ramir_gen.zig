const std = @import("std");
const Mir = @import("Mir.zig");
const Ramir = @import("Ramir.zig");

pub fn buildRig(alloc: std.mem.Allocator, mir: Mir) !Rig {
    var rig: Rig = .{ .nodes = .empty };
    errdefer rig.deinit(alloc);

    try rig.nodes.ensureUnusedCapacity(alloc, blk: {
        var max_node_count: usize = 0;
        for (mir.blocks.items) |block| {
            max_node_count += block.arg_count;
            max_node_count += block.insts.len;
        }

        break :blk max_node_count;
    });

    for (mir.blocks.items, 0..) |block, block_id| {
        for (0..block.arg_count) |arg_id| {
            rig.nodes.putAssumeCapacityNoClobber(.{
                .block_id = @intCast(block_id),
                .tag = .arg,
                .data = @intCast(arg_id),
            }, .{
                .color = .none,
                .i_edges = .empty,
                .possible_colors = .initFull(),
            });
        }

        for (0..block.insts.len) |inst_id| {
            rig.nodes.putAssumeCapacityNoClobber(.{
                .block_id = @intCast(block_id),
                .tag = .inst,
                .data = @intCast(inst_id),
            }, .{
                .color = .none,
                .i_edges = .empty,
                .possible_colors = .initFull(),
            });
        }
    }

    const last_usages = try alloc.alloc(LastUsage, rig.nodes.count());
    defer alloc.free(last_usages);
    @memset(last_usages, .never);

    for (mir.blocks.items, 0..) |block, block_id| {
        for (0..block.insts.len) |inst_id| {
            const inst = block.insts.get(inst_id);

            const this_usage: LastUsage = .{ .inst = @intCast(inst_id) };
            switch (inst.tag.getDataKind()) {
                .none => {},
                .unary => updateLastUsage(&rig, last_usages, @intCast(block_id), inst.data.unary, this_usage),
                .bin => {
                    const bin = inst.data.bin;
                    updateLastUsage(&rig, last_usages, @intCast(block_id), bin.left, this_usage);
                    updateLastUsage(&rig, last_usages, @intCast(block_id), bin.right, this_usage);
                },
                .val_ref_list => {
                    const d = inst.data.val_ref_list;
                    const slice = mir.extra_val_refs.items[d.start..][0..d.len];

                    for (slice) |ref| {
                        updateLastUsage(&rig, last_usages, @intCast(block_id), ref, this_usage);
                    }
                },
            }
        }

        switch (block.term) {
            .none => unreachable,
            .ret => |ref| updateLastUsage(&rig, last_usages, @intCast(block_id), ref, .term),
            .jmp => |jmp| {
                for (jmp.args.items) |ref| {
                    updateLastUsage(&rig, last_usages, @intCast(block_id), ref, .term);
                }
            },
            .branch_bool => |b| {
                updateLastUsage(&rig, last_usages, @intCast(block_id), b.cond, .term);

                for (b.then_jmp.args.items) |ref| {
                    updateLastUsage(&rig, last_usages, @intCast(block_id), ref, .term);
                }

                for (b.else_jmp.args.items) |ref| {
                    updateLastUsage(&rig, last_usages, @intCast(block_id), ref, .term);
                }
            },
            .branch_cmp => |b| {
                updateLastUsage(&rig, last_usages, @intCast(block_id), b.left, .term);
                updateLastUsage(&rig, last_usages, @intCast(block_id), b.right, .term);

                for (b.then_jmp.args.items) |ref| {
                    updateLastUsage(&rig, last_usages, @intCast(block_id), ref, .term);
                }

                for (b.else_jmp.args.items) |ref| {
                    updateLastUsage(&rig, last_usages, @intCast(block_id), ref, .term);
                }
            },
        }
    }

    for (rig.nodes.keys(), rig.nodes.values(), 0.., last_usages) |ref, *node, node_id, last_usage| {
        const last_used_inst_id = switch (last_usage) {
            .never => continue,
            .inst => |x| x,
            .term => std.math.maxInt(Mir.Inst.Id),
        };

        for (rig.nodes.keys(), rig.nodes.values(), 0.., last_usages) |other_ref, *other, other_id, other_usage| {
            if (ref.block_id != other_ref.block_id) continue;
            if (other_id <= node_id) continue;
            if (other_usage == .never) continue;
            if (other_ref.tag == .inst and other_ref.data <= last_used_inst_id) continue;

            try node.i_edges.append(alloc, @intCast(other_id));
            try other.i_edges.append(alloc, @intCast(node_id));
        }
    }

    return rig;
}

fn updateLastUsage(rig: *Rig, last_usages: []LastUsage, block_id: Mir.Block.Id, ref: Mir.ValueRef, usage: LastUsage) void {
    const global = GlobalRef.fromLocal(block_id, ref) orelse return;
    last_usages[rig.nodes.getIndex(global) orelse unreachable] = usage;
}

const LastUsage = union(enum) {
    never,
    term,
    inst: Mir.Inst.Id,
};

const Rig = struct {
    nodes: std.array_hash_map.Auto(GlobalRef, Node),

    const NodeId = u32;
    const Node = struct {
        color: Ramir.OptReg,
        i_edges: std.ArrayList(NodeId),
        possible_colors: Ramir.Reg.Set,
    };

    pub fn deinit(rig: *Rig, alloc: std.mem.Allocator) void {
        for (rig.nodes.values()) |*node| {
            node.i_edges.deinit(alloc);
        }

        rig.nodes.deinit(alloc);
    }
};

const GlobalRef = packed struct(u64) {
    block_id: Mir.Block.Id,
    tag: Tag,
    data: u30,

    const Tag = enum(u2) {
        inst,
        arg,
    };

    fn fromLocal(block_id: Mir.Block.Id, local: Mir.ValueRef) ?GlobalRef {
        return switch (local.tag) {
            .imm, .stack_addr => null,
            .inst => .{
                .block_id = block_id,
                .tag = .inst,
                .data = local.id,
            },
            .arg => .{
                .block_id = block_id,
                .tag = .arg,
                .data = local.id,
            },
        };
    }

    pub fn format(ref: GlobalRef, writer: *std.Io.Writer) !void {
        const tag_str: []const u8 = switch (ref.tag) {
            .inst => "i",
            .arg => "a",
        };

        try writer.print("b{}{s}{}", .{
            ref.block_id,
            tag_str,
            ref.data,
        });
    }
};

const sysv_arg_order = [_]Ramir.Reg{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 };
const sysv_clobbers = [_]Ramir.Reg{ .rax, .rdi, .rsi, .rdx, .rcx, .r8, .r9, .r10, .r11 };
const sysv_clobber_inv_set = blk: {
    var result: Ramir.Reg.Set = .initFull();

    for (sysv_clobbers) |reg| {
        result.unset(@intFromEnum(reg));
    }

    break :blk result;
};

pub fn dumpDot(rig: Rig, func_name: []const u8, writer: *std.Io.Writer) !void {
    try writer.print("graph Rig_{s} {{\n", .{func_name});

    const tab = "    ";
    for (rig.nodes.keys(), rig.nodes.values()) |ref, _| {
        try writer.print(tab ++ "{f};\n", .{ref});
    }

    for (rig.nodes.keys(), rig.nodes.values(), 0..) |ref, node, id| {
        for (node.i_edges.items) |other_id| {
            if (id > other_id) continue;
            const other_ref = rig.nodes.keys()[other_id];

            try writer.print(tab ++ "{f} -- {f} [style=dashed,color=red];\n", .{
                ref,
                other_ref,
            });
        }
    }

    try writer.print("}}\n", .{});
}
