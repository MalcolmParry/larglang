const std = @import("std");
const Ast = @import("Ast.zig");
const Ir = @import("Ir.zig");
const ValueRef = Ir.ValueRef;
const IdentMap = std.array_hash_map.String(ValueRef);
const Func = Ir.Func;
const BlockId = Ir.BlockId;
const Block = Ir.Block;
const Inst = Ir.Inst;

pub fn compileAst(alloc: std.mem.Allocator, ast: Ast) !Ir {
    var ir: Ir = .{
        .funcs = .empty,
    };
    errdefer ir.deinit(alloc);

    const root_node = ast.nodes.get(0);
    const tl_slice = root_node.data.node_slice;
    const tl_end = tl_slice.first_node + tl_slice.len;

    var tl_i: usize = tl_slice.first_node;
    while (tl_i < tl_end) {
        const fn_node = ast.nodes.get(tl_i);
        std.debug.assert(fn_node.kind == .func);
        tl_i += 1;

        const fn_data = fn_node.data.token_extra;
        const ast_func: *Ast.Node.Func = @ptrCast(ast.extra_data.ptr + fn_data.extra);

        var ident_map: IdentMap = .empty;
        defer ident_map.deinit(alloc);

        const first_param = fn_data.extra + Ast.sizeInExtraData(Ast.Node.Func);
        for (0..ast_func.param_count) |param_id| {
            const param: *Ast.Node.Param = @ptrCast(ast.extra_data.ptr + first_param + param_id);

            try ident_map.put(
                alloc,
                ast.tokens.get(param.token).loc.get(ast.src),
                .fromArg(@intCast(param_id)),
            );
        }

        var func: Func = .{
            .link_sym = ast.tokens.get(fn_data.token).loc.get(ast.src),
            .blocks = .empty,
            .imms = .empty,
            .flags = .{
                .export_ = ast_func.flags.export_,
            },
        };
        errdefer func.deinit(alloc);

        try func.blocks.append(alloc, .{
            .arg_count = ast_func.param_count,
            .insts = .empty,
            .terminator = .none,
        });

        const block_node = ast.nodes.get(ast_func.block);
        const block_state = try compileCodeBlock(alloc, ast, block_node.data.node_slice, &func, ident_map, 0);
        switch (block_state) {
            .returned => {},
            .continued => |cont| {
                alloc.free(cont.args);
                const block = &func.blocks.items[cont.block_id];

                block.terminator = .{
                    .ret = try func.appendImm(alloc, 0),
                };
            },
        }

        try ir.funcs.append(alloc, func);
    }

    return ir;
}

const CompiledBlockState = union(enum) {
    returned,
    continued: Continued,

    const Continued = struct {
        block_id: BlockId,
        args: []ValueRef,
    };
};

fn compileCodeBlock(
    alloc: std.mem.Allocator,
    ast: Ast,
    block_slice: Ast.Node.Data.NodeSlice,
    func: *Func,
    ident_map: IdentMap,
    starting_block_id: BlockId,
) !CompiledBlockState {
    var new_ident_map = try ident_map.clone(alloc);
    defer new_ident_map.deinit(alloc);

    var block_id = starting_block_id;
    var node_i: usize = block_slice.first_node;
    const node_end = block_slice.first_node + block_slice.len;
    while (node_i < node_end) : (node_i += 1) {
        const node = ast.nodes.get(node_i);

        switch (node.kind) {
            .stat_assign => {
                const data = node.data.token_node;
                const ref = try compileExpr(
                    alloc,
                    ast,
                    func,
                    &func.blocks.items[block_id],
                    &new_ident_map,
                    data.node,
                );

                try new_ident_map.put(alloc, ast.tokens.get(data.token).loc.get(ast.src), ref);
            },
            .stat_ret => {
                const ref = try compileExpr(
                    alloc,
                    ast,
                    func,
                    &func.blocks.items[block_id],
                    &new_ident_map,
                    node.data.node,
                );

                func.blocks.items[block_id].terminator = .{ .ret = ref };
                return .returned;
            },
            .stat_if => {
                node_i += 1;
                const data = node.data.node_opt_node;
                const cond = try compileExpr(alloc, ast, func, &func.blocks.items[block_id], &new_ident_map, data.left);
                const then_slice = ast.nodes.get(node_i).data.node_slice;
                const else_slice: Ast.Node.Data.NodeSlice = if (data.right.unwrap()) |id|
                    ast.nodes.get(id).data.node_slice
                else
                    .{ .first_node = 0, .len = 0 };

                const then_args = try alloc.dupe(ValueRef, new_ident_map.values());
                errdefer alloc.free(then_args);

                const else_args = try alloc.dupe(ValueRef, then_args);
                errdefer alloc.free(else_args);

                for (new_ident_map.values(), 0..) |*val, i| {
                    val.* = .fromArg(@intCast(i));
                }

                const then_block_id: u32 = @intCast(func.blocks.items.len);
                try func.blocks.append(alloc, .{
                    .arg_count = @intCast(then_args.len),
                    .insts = .empty,
                    .terminator = .none,
                });
                const then_block_state = try compileCodeBlock(alloc, ast, then_slice, func, new_ident_map, then_block_id);

                const else_block_id: u32 = @intCast(func.blocks.items.len);
                try func.blocks.append(alloc, .{
                    .arg_count = @intCast(else_args.len),
                    .insts = .empty,
                    .terminator = .none,
                });
                const else_block_state = try compileCodeBlock(alloc, ast, else_slice, func, new_ident_map, else_block_id);

                const end_block_id: u32 = @intCast(func.blocks.items.len);
                try func.blocks.append(alloc, .{
                    .arg_count = @intCast(then_args.len),
                    .insts = .empty,
                    .terminator = .none,
                });

                func.blocks.items[block_id].terminator = .{
                    .branch = .{
                        .condition = cond,
                        .true_jmp = .{
                            .block_id = then_block_id,
                            .args = .fromOwnedSlice(then_args),
                        },
                        .false_jmp = .{
                            .block_id = else_block_id,
                            .args = .fromOwnedSlice(else_args),
                        },
                    },
                };

                switch (then_block_state) {
                    .returned => {},
                    .continued => |cont| {
                        func.blocks.items[cont.block_id].terminator = .{ .jmp = .{
                            .block_id = end_block_id,
                            .args = .fromOwnedSlice(cont.args),
                        } };
                    },
                }

                switch (else_block_state) {
                    .returned => {},
                    .continued => |cont| {
                        func.blocks.items[cont.block_id].terminator = .{ .jmp = .{
                            .block_id = end_block_id,
                            .args = .fromOwnedSlice(cont.args),
                        } };
                    },
                }

                if (then_block_state == .returned and else_block_state == .returned) return .returned;
                block_id = end_block_id;
            },
            .stat_while => {
                const data = node.data.node_node;
                const jmp_args = try alloc.dupe(ValueRef, new_ident_map.values());
                errdefer alloc.free(jmp_args);

                for (new_ident_map.values(), 0..) |*val, i| {
                    val.* = .fromArg(@intCast(i));
                }

                const cond_id: BlockId = @intCast(func.blocks.items.len);
                try func.blocks.append(alloc, .{
                    .arg_count = @intCast(jmp_args.len),
                    .insts = .empty,
                    .terminator = .none,
                });
                const cond_ref = try compileExpr(alloc, ast, func, &func.blocks.items[cond_id], &new_ident_map, data.left);

                const body_id: BlockId = @intCast(func.blocks.items.len);
                try func.blocks.append(alloc, .{
                    .arg_count = @intCast(jmp_args.len),
                    .insts = .empty,
                    .terminator = .none,
                });
                const body_block_state = try compileCodeBlock(alloc, ast, ast.nodes.get(data.right).data.node_slice, func, new_ident_map, body_id);

                const end_id: BlockId = @intCast(func.blocks.items.len);
                try func.blocks.append(alloc, .{
                    .arg_count = @intCast(jmp_args.len),
                    .insts = .empty,
                    .terminator = .none,
                });

                func.blocks.items[block_id].terminator = .{ .jmp = .{
                    .block_id = cond_id,
                    .args = .fromOwnedSlice(jmp_args),
                } };

                func.blocks.items[cond_id].terminator = .{ .branch = .{
                    .condition = cond_ref,
                    .true_jmp = .{
                        .block_id = body_id,
                        .args = .fromOwnedSlice(try alloc.dupe(ValueRef, new_ident_map.values())),
                    },
                    .false_jmp = .{
                        .block_id = end_id,
                        .args = .fromOwnedSlice(try alloc.dupe(ValueRef, new_ident_map.values())),
                    },
                } };

                switch (body_block_state) {
                    .returned => {},
                    .continued => |cont| {
                        func.blocks.items[cont.block_id].terminator = .{ .jmp = .{
                            .block_id = cond_id,
                            .args = .fromOwnedSlice(cont.args),
                        } };
                    },
                }

                block_id = end_id;
            },
            else => unreachable,
        }
    }

    const args = try alloc.alloc(ValueRef, ident_map.count());
    errdefer alloc.free(args);

    for (ident_map.keys(), 0..) |ident, i| {
        args[i] = new_ident_map.get(ident) orelse unreachable;
    }

    return .{ .continued = .{
        .block_id = block_id,
        .args = args,
    } };
}

pub fn compileExpr(alloc: std.mem.Allocator, ast: Ast, func: *Func, block: *Block, ident_map: *IdentMap, node_id: Ast.Node.Index) !ValueRef {
    const node = ast.nodes.get(node_id);
    switch (node.kind) {
        .expr_ident => {
            return ident_map.get(ast.tokens.get(node.main_token_id).loc.get(ast.src)) orelse error.CompileFailed;
        },
        .expr_lit_int => {
            return func.appendImm(alloc, node.data.int);
        },
        .expr_add,
        .expr_sub,
        .expr_mul,
        .expr_div,
        .expr_equal,
        .expr_less,
        .expr_more,
        => {
            const data = node.data.node_node;
            const left = try compileExpr(alloc, ast, func, block, ident_map, data.left);
            const right = try compileExpr(alloc, ast, func, block, ident_map, data.right);

            const tag: Inst.Tag = switch (node.kind) {
                .expr_add => .add,
                .expr_sub => .sub,
                .expr_mul => .mul,
                .expr_div => .div,
                .expr_equal => .equal,
                .expr_less => .less,
                .expr_more => .more,
                else => unreachable,
            };

            return block.appendInst(alloc, .bin(tag, left, right));
        },
        else => unreachable,
    }
}
