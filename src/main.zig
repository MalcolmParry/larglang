const std = @import("std");
const Lexer = @import("Lexer.zig");
const Ast = @import("Ast.zig");
const Ir = @import("Ir.zig");
const Mir = @import("codegen/amd64/Mir.zig");
const reg_alloc = @import("codegen/amd64/RegAlloc.zig");
const ramir_gen = @import("codegen/amd64/ramir_gen.zig");
const ramir_merge = @import("codegen/amd64/ramir_merge.zig");
const emit_asm = @import("codegen/amd64/emit_asm.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var arg_iter = try init.minimal.args.iterateAllocator(alloc);
    defer arg_iter.deinit();

    var maybe_src_file_name: ?[]const u8 = null;
    var maybe_out_file_name: ?[]const u8 = null;
    var maybe_debug_func: ?[]const u8 = null;
    var flags: CompInfo.Flags = .{};

    _ = arg_iter.skip();
    while (arg_iter.next()) |arg| {
        if (arg.len == 0) continue;

        if (arg[0] == '-') {
            const hash = std.hash.Wyhash.hash;

            switch (hash(0, arg)) {
                hash(0, "-o") => {
                    if (maybe_out_file_name) |_| {
                        std.log.err("cannot specify 2 output files", .{});
                        std.process.exit(1);
                    }

                    const output_file = arg_iter.next() orelse {
                        std.log.err("-o option expects file", .{});
                        std.process.exit(1);
                    };

                    maybe_out_file_name = output_file;
                },
                hash(0, "-debug-func") => {
                    if (maybe_debug_func) |_| {
                        std.log.err("cannot specify 2 debug function symbols", .{});
                        std.process.exit(1);
                    }

                    const symbol_name = arg_iter.next() orelse {
                        std.log.err("-debug-func option expects symbol name", .{});
                        std.process.exit(1);
                    };

                    maybe_debug_func = symbol_name;
                },
                hash(0, "-dump-tokens") => flags.dump_tokens = true,
                hash(0, "-dump-ast") => flags.dump_ast = true,
                hash(0, "-dump-ir") => flags.dump_ir = true,
                hash(0, "-dump-mir") => flags.dump_mir = true,
                hash(0, "-dump-ramir") => flags.dump_ramir = true,
                hash(0, "-no-emit") => flags.no_emit = true,
                hash(0, "-emit-rig-dot") => {
                    flags.no_emit = true;
                    flags.emit_rig_dot = true;
                },
                else => {
                    std.log.err("invalid option '{s}'", .{arg});
                    std.process.exit(1);
                },
            }

            continue;
        }

        if (maybe_src_file_name) |_| {
            std.log.err("cannot compile 2 source files at once", .{});
            std.process.exit(1);
        }

        maybe_src_file_name = arg;
    }

    const src_file_name = maybe_src_file_name orelse {
        std.log.err("no source file specified", .{});
        std.process.exit(1);
    };

    const src_file = try std.Io.Dir.cwd().openFile(io, src_file_name, .{});
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

    const out_file: std.Io.File = if (maybe_out_file_name) |out_file_name|
        try std.Io.Dir.cwd().createFile(io, out_file_name, .{})
    else
        std.Io.File.stdout();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = out_file.writer(io, stdout_buffer[0..]);

    try compile(.{
        .alloc = alloc,
        .src = src,
        .output = &stdout_writer.interface,
        .debug = stderr_term,
        .flags = flags,
        .maybe_debug_func = maybe_debug_func,
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
    maybe_debug_func: ?[]const u8,

    const Flags = packed struct {
        dump_tokens: bool = false,
        dump_ast: bool = false,
        dump_ir: bool = false,
        dump_mir: bool = false,
        dump_ramir: bool = false,
        no_emit: bool = false,
        emit_rig_dot: bool = false,
    };
};

fn compile(info: CompInfo) !void {
    const alloc = info.alloc;
    const src = info.src;
    const debug = info.debug;
    errdefer info.debug.writer.flush() catch {};

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
        try debug.writer.flush();

        try printHeading(debug, "AST");
        try ast.print(debug);
        try debug.writer.flush();
    }

    var comp_unit = try Ir.gen.compileAst(alloc, ast);
    defer comp_unit.deinit(alloc);

    for (comp_unit.funcs.values()) |*func| {
        const ir = &func.ir;
        const debug_info = if (info.maybe_debug_func) |debug_func|
            std.mem.eql(u8, debug_func, ir.link_sym)
        else
            true;

        if (debug_info and info.flags.dump_ir) {
            try printHeading(debug, "IR");
            try ir.print(debug);
            try debug.writer.flush();
        }

        try Ir.opt.optimize(alloc, ir);
        try Ir.opt.clean(alloc, ir);

        if (debug_info and info.flags.dump_ir) {
            try printHeading(debug, "IR Immediates");
            try debug.writer.print("{any}\n", .{ir.imms.items});

            try printHeading(debug, "Optimized IR");
            try ir.print(debug);
            try debug.writer.flush();
        }

        Ir.opt.validate(ir.*);

        {
            var mir = try Mir.gen.gen(alloc, ir.*);
            errdefer mir.deinit(alloc);

            if (debug_info and info.flags.dump_mir) {
                try printHeading(debug, "Machine IR");
                try mir.print(debug);
                try debug.writer.flush();
            }

            try Mir.opt.optimize(alloc, &mir);
            try Mir.opt.clean(alloc, &mir);

            if (debug_info and info.flags.dump_mir) {
                try printHeading(debug, "Optimized Machine IR");
                try mir.print(debug);
                try debug.writer.flush();
            }

            func.mir = mir;
        }

        {
            var rig = try ramir_gen.buildRig(alloc, func.mir.?);
            defer rig.deinit(alloc);

            if (debug_info and info.flags.emit_rig_dot)
                try ramir_gen.dumpDot(rig, func.mir.?.link_sym, info.output);
        }

        {
            var ramir = try reg_alloc.emitRamir(alloc, func.mir.?);
            errdefer ramir.deinit(alloc);

            if (debug_info and info.flags.dump_ramir) {
                try printHeading(debug, "Register Allocated Machine IR");
                try ramir.print(debug);
                try debug.writer.flush();
            }

            try ramir_merge.merge(alloc, &ramir);

            if (debug_info and info.flags.dump_ramir) {
                try printHeading(debug, "Merged Register Allocated Machine IR");
                try ramir.print(debug);
                try debug.writer.flush();
            }

            func.ramir = ramir;
        }
    }

    if (!info.flags.no_emit)
        try emit_asm.emit(info.output, comp_unit);
}

fn printHeading(term: std.Io.Terminal, text: []const u8) !void {
    term.setColor(.green) catch {};
    try term.writer.print("\n--// {s} \\\\--\n", .{text});
    term.setColor(.reset) catch {};
}
