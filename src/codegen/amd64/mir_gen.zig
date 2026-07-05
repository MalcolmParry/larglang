const std = @import("std");
const Ir = @import("../../Ir.zig");
const Mir = @import("Mir.zig");

const ValMap = std.hash_map.AutoHashMapUnmanaged(Ir.ValueRef, Mir.ValueRef);

pub fn gen(alloc: std.mem.Allocator, ir: Ir.Func) !Mir {
    var mir: Mir = .{
        .link_sym = ir.link_sym,
        .blocks = try .initCapacity(alloc, ir.blocks.items.len),
        .imms = try ir.imms.clone(alloc),
    };
    errdefer mir.deinit(alloc);

    var val_map: ValMap = .empty;
    defer val_map.deinit(alloc);

    for (ir.blocks.items) |ir_block| {
        var mir_block: Mir.Block = .{
            .arg_count = ir_block.arg_count,
            .insts = try .initCapacity(alloc, ir_block.insts.items.len),
            .term = .none,
        };
        errdefer mir_block.deinit(alloc);

        val_map.clearRetainingCapacity();
        try val_map.ensureUnusedCapacity(alloc, @intCast(ir_block.insts.items.len));

        for (ir_block.insts.items, 0..) |ir_inst, ir_inst_id| {
            switch (ir_inst.tag) {
                .no_op => {},
                .add, .sub, .mul, .div, .less, .equal, .more => {
                    const mir_inst_id = mir_block.insts.len;
                    const ir_data = ir_inst.data.bin;
                    const mir_data: Mir.Inst.Data.Bin = .{
                        .left = translateValRef(val_map, ir_data.left),
                        .right = translateValRef(val_map, ir_data.right),
                    };

                    const mir_tag: Mir.Inst.Tag = switch (ir_inst.tag) {
                        .add => .add,
                        .sub => .sub,
                        .mul => .mul,
                        .div => .udiv,
                        .less => .cmp_ult,
                        .equal => .cmp_eq,
                        .more => .cmp_ugt,
                        else => unreachable,
                    };

                    mir_block.insts.appendAssumeCapacity(.{
                        .tag = mir_tag,
                        .data = .{ .bin = mir_data },
                    });

                    val_map.putAssumeCapacity(.{
                        .tag = .inst,
                        .data = @intCast(ir_inst_id),
                    }, .{
                        .tag = .inst,
                        .class = .gp,
                        .id = @intCast(mir_inst_id),
                    });
                },
            }
        }

        mir_block.term = switch (ir_block.terminator) {
            .none, .dead => unreachable,
            .ret => |ref| .{ .ret = translateValRef(val_map, ref) },
            .jmp => |jmp| .{ .jmp = try translateJmp(alloc, val_map, jmp) },
            .branch => |b| blk: {
                var then_jmp = try translateJmp(alloc, val_map, b.true_jmp);
                errdefer then_jmp.deinit(alloc);

                var else_jmp = try translateJmp(alloc, val_map, b.true_jmp);
                errdefer else_jmp.deinit(alloc);

                break :blk .{ .branch_bool = .{
                    .cond = translateValRef(val_map, b.condition),
                    .then_jmp = then_jmp,
                    .else_jmp = else_jmp,
                } };
            },
        };

        mir.blocks.appendAssumeCapacity(mir_block);
    }

    return mir;
}

fn translateJmp(alloc: std.mem.Allocator, val_map: ValMap, jmp: Ir.Terminator.Jmp) !Mir.Term.Jmp {
    const args = try alloc.alloc(Mir.ValueRef, jmp.args.items.len);
    errdefer alloc.free(args);

    for (jmp.args.items, args) |ir_arg, *mir_arg| {
        mir_arg.* = translateValRef(val_map, ir_arg);
    }

    return .{
        .block_id = jmp.block_id,
        .args = .fromOwnedSlice(args),
    };
}

fn translateValRef(map: ValMap, ir_ref: Ir.ValueRef) Mir.ValueRef {
    return switch (ir_ref.tag) {
        .inst => map.get(ir_ref) orelse unreachable,
        .arg => .{
            .tag = .arg,
            .class = .gp,
            .id = ir_ref.data,
        },
        .imm => .{
            .tag = .imm,
            .class = .gp,
            .id = ir_ref.data,
        },
    };
}
