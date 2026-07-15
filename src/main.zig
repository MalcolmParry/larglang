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

    const stderr = std.Io.File.stderr();
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = stderr.writer(io, stderr_buffer[0..]);
    const stderr_term: std.Io.Terminal = .{
        .writer = &stderr_writer.interface,
        .mode = try .detect(io, stderr, false, false),
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, stdout_buffer[0..]);

    try compile(.{
        .alloc = alloc,
        .src = src,
        .output = &stdout_writer.interface,
        .debug = stderr_term,
        .flags = .{
            .dump_tokens = true,
            .dump_ast = true,
            .dump_ir = true,
            .dump_mir = true,
            .dump_ramir = true,
        },
    });

    try stderr_writer.flush();
    try stdout_writer.flush();
}

const CompInfo = struct {
    alloc: std.mem.Allocator,
    src: []const u8,
    output: *std.Io.Writer,
    debug: std.Io.Terminal,
    flags: Flags,

    const Flags = packed struct {
        dump_tokens: bool = false,
        dump_ast: bool = false,
        dump_ir: bool = false,
        dump_mir: bool = false,
        dump_ramir: bool = false,
    };
};

fn compile(info: CompInfo) !void {
    const alloc = info.alloc;
    const src = info.src;
    const debug = info.debug;

    var tokens = try Lexer.getTokens(alloc, src);
    defer tokens.deinit(alloc);

    if (info.flags.dump_tokens) {
        try printHeading(debug, "Tokens");
        try Lexer.dumpTokens(debug, tokens, src);
        try info.debug.writer.print("\n", .{});
    }

    var ast = try Ast.parse(alloc, src, tokens);
    defer ast.deinit(alloc);

    if (info.flags.dump_ast) {
        try printHeading(debug, "Raw AST");
        try ast.dump(debug);

        try printHeading(debug, "AST");
        try ast.print(debug);
    }

    var comp_unit = try ir_gen.compileAst(alloc, ast);
    defer comp_unit.deinit(alloc);

    for (comp_unit.funcs.values()) |*func| {
        const ir = &func.ir;

        if (info.flags.dump_ir) {
            try printHeading(debug, "IR");
            try ir.print(debug);
        }

        try ir_opt.optimize(alloc, ir);
        try ir_opt.clean(alloc, ir);

        if (info.flags.dump_ir) {
            try printHeading(debug, "IR Immediates");
            try debug.writer.print("{any}\n", .{ir.imms.items});

            try printHeading(debug, "Optimized IR");
            try ir.print(debug);
        }

        ir_opt.validate(ir.*);

        {
            var mir = try mir_gen.gen(alloc, ir.*);
            errdefer mir.deinit(alloc);

            if (info.flags.dump_mir) {
                try printHeading(debug, "Machine IR");
                try mir.print(debug);
            }

            try mir_opt.optimize(alloc, &mir);
            try mir_opt.clean(alloc, &mir);

            if (info.flags.dump_mir) {
                try printHeading(debug, "Optimized Machine IR");
                try mir.print(debug);
            }

            func.mir = mir;
        }

        {
            var ramir = try reg_alloc.emitRamir(alloc, func.mir.?);
            errdefer ramir.deinit(alloc);

            if (info.flags.dump_ramir) {
                try printHeading(debug, "Register Allocated Machine IR");
                try ramir.print(debug);
            }

            try ramir_merge.merge(alloc, &ramir);

            if (info.flags.dump_ramir) {
                try printHeading(debug, "Merged Register Allocated Machine IR");
                try ramir.print(debug);
            }

            func.ramir = ramir;
        }
    }

    try emit_asm.emit(info.output, comp_unit);
}

fn printHeading(term: std.Io.Terminal, text: []const u8) !void {
    term.setColor(.green) catch {};
    try term.writer.print("\n--// {s} \\\\--\n", .{text});
    term.setColor(.reset) catch {};
}
