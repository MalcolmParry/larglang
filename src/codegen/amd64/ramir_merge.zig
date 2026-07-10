const std = @import("std");
const Ramir = @import("Ramir.zig");

pub fn merge(alloc: std.mem.Allocator, ramir: *Ramir) !void {
    var uniblock: Ramir.Block = .{
        .insts = .empty,
        .term = .not_reachable,
    };
    errdefer uniblock.deinit(alloc);

    for (ramir.blocks.items, 0..) |*block, block_id| {
        defer block.insts.clearAndFree(alloc);

        try uniblock.insts.append(alloc, .{
            .tag = .label,
            .data_kind = .u16,
            .data = .{ .u16 = @intCast(block_id) },
        });

        try appendInsts(alloc, &uniblock, block.insts.slice());

        switch (block.term) {
            .none => unreachable,
            .not_reachable => {},
            .jmp => |target| try uniblock.insts.append(alloc, .{
                .tag = .jmp,
                .data_kind = .u16,
                .data = .{ .u16 = @intCast(target) },
            }),
            .branch => |b| {
                try uniblock.insts.append(alloc, .{
                    .tag = .jcc,
                    .data_kind = .c_u16,
                    .data = .{ .c_u16 = .{
                        .cond = b.cond,
                        .int = @intCast(b.then_jmp),
                    } },
                });

                try uniblock.insts.append(alloc, .{
                    .tag = .jmp,
                    .data_kind = .u16,
                    .data = .{ .u16 = @intCast(b.else_jmp) },
                });
            },
        }
    }

    ramir.blocks.resize(alloc, 1) catch unreachable;
    ramir.blocks.items[0] = uniblock;
}

pub fn appendInsts(alloc: std.mem.Allocator, block: *Ramir.Block, src: std.MultiArrayList(Ramir.Inst).Slice) !void {
    const old_len = block.insts.len;
    try block.insts.resize(alloc, old_len + src.len);
    var dst = block.insts.slice().subslice(old_len, src.len);

    inline for (@typeInfo(Ramir.Inst).@"struct".fields) |field| {
        const name = @field(std.meta.FieldEnum(Ramir.Inst), field.name);
        @memcpy(dst.items(name), src.items(name));
    }
}
