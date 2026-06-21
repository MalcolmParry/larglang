const std = @import("std");
const Lexer = @import("Lexer.zig");

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

    var lexer: Lexer = .{
        .src = src,
        .head = 0,
    };

    while (true) {
        const token = lexer.getToken();
        std.log.info("{f}", .{token.format(&lexer)});
        if (token == .eof) break;
    }
}
