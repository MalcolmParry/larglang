const std = @import("std");
const Lexer = @import("Lexer.zig");
const Ast = @import("Ast.zig");
const ir_gen = @import("ir_gen.zig");
const ir_opt = @import("ir_opt.zig");
const mir_gen = @import("codegen/amd64/mir_gen.zig");
const mir_opt = @import("codegen/amd64/mir_opt.zig");
const reg_alloc = @import("codegen/amd64/RegAlloc.zig");
const ramir_merge = @import("codegen/amd64/ramir_merge.zig");
const emit_asm = @import("codegen/amd64/emit_asm.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    const src_file = try std.Io.Dir.cwd().openFile(io, "test.larg", .{});
    defer src_file.close(io);

    var src_reader = src_file.reader(io, &.{});
    const src_len = try src_reader.getSize();
    const src = try alloc.alloc(u8, src_len);
    defer alloc.free(src);

    try src_reader.interface.readSliceAll(src);

    var tokens = try Lexer.getTokens(alloc, src);
    defer tokens.deinit(alloc);
    Lexer.dumpTokens(tokens, src);

    var ast = try Ast.parse(alloc, src, tokens);
    defer ast.deinit(alloc);

    ast.dump();
    std.log.info("{f}", .{ast});

    var ir = try ir_gen.compileAst(alloc, ast);
    defer ir.deinit(alloc);

    for (ir.funcs.items) |*func| {
        std.log.info("\n{f}", .{func});

        try ir_opt.optimize(alloc, func);
        std.log.info("{any}", .{func.imms.items});
        try ir_opt.clean(alloc, func);

        std.log.info("\n{f}", .{func});

        ir_opt.validate(func.*);

        var mir = try mir_gen.gen(alloc, func.*);
        defer mir.deinit(alloc);
        std.log.info("machine ir:\n{f}", .{mir});

        try mir_opt.optimize(alloc, &mir);
        try mir_opt.clean(alloc, &mir);
        std.log.info("optimized machine ir:\n{f}", .{mir});

        var ramir = try reg_alloc.emitRamir(alloc, mir);
        defer ramir.deinit(alloc);
        std.log.info("register allocated machine ir:\n{f}", .{ramir});

        try ramir_merge.merge(alloc, &ramir);
        std.log.info("merged ramir:\n{f}", .{ramir});

        var stdout_buffer: [512]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(init.io, stdout_buffer[0..]);

        try emit_asm.emit(&stdout_writer.interface, ramir);
        try stdout_writer.flush();
    }
}
