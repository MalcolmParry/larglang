const std = @import("std");
const Lexer = @import("Lexer.zig");
const Ast = @import("Ast.zig");
// const ir_gen = @import("ir.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    const src_file = try std.Io.Dir.cwd().openFile(io, "test.larg", .{});
    defer src_file.close(io);

    var src_reader_buffer: [1024]u8 = undefined;
    var src_reader = src_file.reader(io, src_reader_buffer[0..]);
    const src_len = try src_reader.getSize();
    const src = try alloc.alloc(u8, src_len);
    defer alloc.free(src);

    try src_reader.interface.readSliceAll(src);

    var tokens = try Lexer.getTokens(alloc, src);
    defer tokens.deinit(alloc);
    Lexer.dumpTokens(tokens, src);

    var ast = try Ast.parse(alloc, src, tokens);
    defer ast.nodes.deinit(alloc);

    ast.dump();
    std.log.info("{f}", .{ast});

    // var ir = try ir_gen.compileAst(.{ .gpa = alloc, .lexer = &lexer }, &ast);
    // defer ir.deinit(alloc);
    //
    // for (ir.funcs.items) |*func| {
    //     std.log.info("\nfn {s}:\n{f}", .{
    //         func.name.get(&lexer),
    //         func,
    //     });
    //     std.log.info("{any}", .{func.imms.items});
    //
    //     try ir_gen.optimize(alloc, func);
    //     std.log.info("{any}", .{func.imms.items});
    //     try ir_gen.clean(alloc, func);
    //
    //     std.log.info("\nfn {s}:\n{f}", .{
    //         func.name.get(&lexer),
    //         func,
    //     });
    //
    //     ir_gen.validate(func.*);
    // }
}
