const std = @import("std");
const Lexer = @import("Lexer.zig");
const Token = Lexer.Token;
const TokenList = Lexer.TokenList;
const Loc = Lexer.Loc;
const TokenIndex = u32;
const Ast = @This();

src: []const u8,
tokens: TokenList,
nodes: NodeList,
extra_data: []u32,

pub const NodeList = std.MultiArrayList(Node).Slice;
pub const Node = struct {
    kind: Kind,
    main_token_id: TokenIndex,
    data: Data,

    pub const Index = u32;
    pub const OptIndex = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn wrap(x: ?Index) OptIndex {
            return if (x) |y| @enumFromInt(y) else .none;
        }

        pub fn unwrap(x: OptIndex) ?Index {
            if (x == .none) return null;
            return @intFromEnum(x);
        }
    };

    pub const Kind = enum {
        /// uses data.node_slice
        root,
        /// uses data.token_extra, stores name and func struct
        func,
        /// uses data.node_slice
        block,

        /// uses data.token_node
        stat_assign,
        /// uses data.node
        stat_ret,
        /// uses data.node_opt_node
        /// stores condition, optional node id to else block
        /// always has then block directly after
        stat_if,
        /// uses data.node_node
        /// stores condition, block
        stat_while,

        /// uses data.none, name is stored in node.main_token_id
        expr_ident,
        /// uses data.int
        expr_lit_int,

        // binary expressions, all use data.node_node
        expr_add,
        expr_sub,
        expr_mul,
        expr_div,
        expr_equal,
        expr_less,
        expr_more,
    };

    pub const Data = union {
        none: void,
        node_slice: NodeSlice,
        token_node: TokenAndNode,
        node: Index,
        node_node: NodeAndNode,
        int: u64,
        token: TokenIndex,
        node_opt_node: NodeAndOptNode,
        token_extra: TokenAndExtra,

        pub const NodeSlice = struct {
            first_node: Index,
            len: u32,
        };

        pub const TokenAndNode = struct {
            token: TokenIndex,
            node: Index,
        };

        pub const NodeAndNode = struct {
            left: Index,
            right: Index,
        };

        pub const NodeAndOptNode = struct {
            left: Index,
            right: OptIndex,
        };

        pub const TokenAndExtra = struct {
            token: TokenIndex,
            extra: u32,
        };
    };

    /// in extra array
    /// always has param_count instances of Param struct after it in extra array
    pub const Func = struct {
        flags: Flags,
        param_count: u16,
        block: Index,

        pub const Flags = packed struct {
            export_: bool = false,
        };
    };

    pub const Param = struct {
        token: TokenIndex,
    };
};

pub fn deinit(ast: *Ast, alloc: std.mem.Allocator) void {
    ast.nodes.deinit(alloc);
    alloc.free(ast.extra_data);
}

pub fn parse(alloc: std.mem.Allocator, src: []const u8, tokens: TokenList) !Ast {
    var nodes: std.MultiArrayList(Node) = .empty;
    errdefer nodes.deinit(alloc);

    var extra: std.ArrayList(u32) = .empty;
    errdefer extra.deinit(alloc);

    try nodes.ensureTotalCapacity(alloc, src.len / 5);
    nodes.appendAssumeCapacity(.{
        .kind = .root,
        .main_token_id = 0,
        .data = undefined,
    });

    var parser: Parser = .{
        .alloc = alloc,
        .src = src,
        .tokens = tokens,
        .nodes = &nodes,
        .extra = &extra,
        .head = 0,
    };

    var tl_nodes: std.MultiArrayList(Node) = .empty;
    defer tl_nodes.deinit(alloc);

    while (true) {
        const token = parser.peekToken(0);

        switch (token.kind) {
            .kw_fn, .kw_export => try parser.parseFunc(&tl_nodes),
            .eof => break,
            else => return error.ParserFailed,
        }
    }

    const first_tl_node = parser.nodes.len;
    try parser.nodes.ensureUnusedCapacity(alloc, tl_nodes.len);
    for (0..tl_nodes.len) |i| {
        parser.nodes.appendAssumeCapacity(tl_nodes.get(i));
    }

    parser.nodes.items(.data)[0] = .{ .node_slice = .{
        .first_node = @intCast(first_tl_node),
        .len = @intCast(tl_nodes.len),
    } };

    return .{
        .src = src,
        .tokens = tokens,
        .nodes = nodes.slice(),
        .extra_data = try extra.toOwnedSlice(alloc),
    };
}

pub const Parser = struct {
    alloc: std.mem.Allocator,
    src: []const u8,
    tokens: TokenList,
    nodes: *std.MultiArrayList(Node),
    extra: *std.ArrayList(u32),
    head: TokenIndex,

    const Error = error{ ParserFailed, Overflow, OutOfMemory };

    fn parseFunc(parser: *Parser, tl_nodes: *std.MultiArrayList(Node)) !void {
        const alloc = parser.alloc;

        var flags: Node.Func.Flags = .{};
        while (true) {
            const token = parser.popToken();

            switch (token.kind) {
                .kw_export => flags.export_ = true,
                .kw_fn => break,
                else => try parser.expectToken(token, .kw_fn),
            }
        }

        const main_token_id = parser.head - 1;
        _ = try parser.popExpectToken(.ident);

        const func_extra_index = parser.extra.items.len;
        _ = try parser.addExtra(Node.Func);

        var param_count: u16 = 0;
        if (parser.popToken().kind == .lparen) {
            const State = enum {
                after_comma,
                expect_comma,
            };

            state: switch (State.after_comma) {
                .after_comma => {
                    const token_id = parser.head;
                    const token = parser.popToken();

                    switch (token.kind) {
                        .ident => {
                            param_count += 1;
                            const param_data = try parser.addExtra(Node.Param);
                            param_data.* = .{
                                .token = token_id,
                            };

                            continue :state .expect_comma;
                        },
                        .rparen => break :state,
                        else => return error.ParserFailed,
                    }
                },
                .expect_comma => {
                    const token = parser.popToken();

                    switch (token.kind) {
                        .comma => continue :state .after_comma,
                        .rparen => break :state,
                        else => return error.ParserFailed,
                    }
                },
            }
        }

        const block_node = try parser.parseBlock();
        const block_id = parser.nodes.len;
        try parser.nodes.append(alloc, block_node);

        const func: *Node.Func = @ptrCast(parser.extra.items.ptr + func_extra_index);

        func.* = .{
            .flags = flags,
            .param_count = param_count,
            .block = @intCast(block_id),
        };

        try tl_nodes.append(alloc, .{
            .kind = .func,
            .main_token_id = main_token_id,
            .data = .{
                .token_extra = .{
                    .token = main_token_id + 1,
                    .extra = @intCast(func_extra_index),
                },
            },
        });
    }

    fn parseBlock(parser: *Parser) Error!Node {
        const alloc = parser.alloc;
        const main_node_id = parser.head;
        _ = try parser.popExpectToken(.lbrace);

        var statements: std.MultiArrayList(Node) = .empty;
        defer statements.deinit(alloc);

        while (parser.peekToken(0).kind != .rbrace) {
            try parser.parseStatement(&statements);
        }

        // pop the ending }
        _ = parser.popToken();

        const first_statement = parser.nodes.len;
        try parser.nodes.ensureUnusedCapacity(alloc, statements.len);
        for (0..statements.len) |i| {
            parser.nodes.appendAssumeCapacity(statements.get(i));
        }

        return .{
            .kind = .block,
            .main_token_id = main_node_id,
            .data = .{ .node_slice = .{
                .first_node = @intCast(first_statement),
                .len = @intCast(statements.len),
            } },
        };
    }

    fn parseStatement(parser: *Parser, statements: *std.MultiArrayList(Node)) Error!void {
        const alloc = parser.alloc;
        const first_id = parser.head;
        const first = parser.popToken();

        switch (first.kind) {
            .kw_if => {
                _ = try parser.popExpectToken(.lparen);
                const cond = try parser.parseExpr(0);
                _ = try parser.popExpectToken(.rparen);

                try statements.ensureUnusedCapacity(alloc, 2);
                const if_id = statements.addOneAssumeCapacity();
                statements.appendAssumeCapacity(try parser.parseBlock());

                const else_block: Node.OptIndex = if (parser.peekToken(0).kind == .kw_else) blk: {
                    _ = parser.popToken();
                    const block_id = try parser.nodes.addOne(alloc);
                    parser.nodes.set(block_id, try parser.parseBlock());
                    break :blk .wrap(@intCast(block_id));
                } else .none;

                statements.set(if_id, .{
                    .kind = .stat_if,
                    .main_token_id = first_id,
                    .data = .{ .node_opt_node = .{
                        .left = cond,
                        .right = else_block,
                    } },
                });
            },
            .kw_while => {
                _ = try parser.popExpectToken(.lparen);
                const cond = try parser.parseExpr(0);
                _ = try parser.popExpectToken(.rparen);
                const block = try parser.parseBlock();
                const block_id = parser.nodes.len;
                try parser.nodes.append(alloc, block);

                try statements.append(alloc, .{
                    .kind = .stat_while,
                    .main_token_id = first_id,
                    .data = .{ .node_node = .{
                        .left = cond,
                        .right = @intCast(block_id),
                    } },
                });
            },
            .ident => {
                _ = try parser.popExpectToken(.equal);
                const expr = try parser.parseExpr(0);
                _ = try parser.popExpectToken(.semicolon);

                try statements.append(alloc, .{
                    .kind = .stat_assign,
                    .main_token_id = first_id,
                    .data = .{ .token_node = .{
                        .token = first_id,
                        .node = expr,
                    } },
                });
            },
            .kw_ret => {
                const expr = try parser.parseExpr(0);
                _ = try parser.popExpectToken(.semicolon);

                try statements.append(alloc, .{
                    .kind = .stat_ret,
                    .main_token_id = first_id,
                    .data = .{ .node = expr },
                });
            },
            else => return error.ParserFailed,
        }
    }

    const ops = [_][]const Node.Kind{
        &.{ .expr_equal, .expr_less, .expr_more },
        &.{ .expr_add, .expr_sub },
        &.{ .expr_mul, .expr_div },
    };

    fn parseExpr(parser: *Parser, prec: usize) Error!Node.Index {
        if (prec >= ops.len) return try parser.parseTerm();

        const alloc = parser.alloc;
        var left = try parser.parseExpr(prec + 1);
        while (true) {
            const op_token_id = parser.head;
            const op_token = parser.peekToken(0);
            const node_kind: Node.Kind = switch (op_token.kind) {
                .equal_equal => .expr_equal,
                .langle => .expr_less,
                .rangle => .expr_more,
                .asterisk => .expr_mul,
                .slash => .expr_div,
                .plus => .expr_add,
                .minus => .expr_sub,
                else => break,
            };

            if (std.mem.findScalar(Node.Kind, ops[prec][0..], node_kind) == null) break;
            _ = parser.popToken();

            const right = try parser.parseExpr(prec + 1);

            const new_left: Node = .{
                .kind = node_kind,
                .main_token_id = op_token_id,
                .data = .{ .node_node = .{
                    .left = left,
                    .right = right,
                } },
            };

            left = @intCast(parser.nodes.len);
            try parser.nodes.append(alloc, new_left);
        }

        return left;
    }

    fn parseTerm(parser: *Parser) Error!Node.Index {
        const alloc = parser.alloc;
        const first_id = parser.head;
        const first = parser.popToken();

        const node: Node = switch (first.kind) {
            .int => .{
                .kind = .expr_lit_int,
                .main_token_id = first_id,
                .data = .{
                    .int = std.fmt.parseInt(u64, first.loc.get(parser.src), 10) catch |err| switch (err) {
                        error.InvalidCharacter => unreachable,
                        error.Overflow => return error.Overflow,
                    },
                },
            },
            .ident => .{
                .kind = .expr_ident,
                .main_token_id = first_id,
                .data = .{ .none = {} },
            },
            .lparen => {
                const expr = try parser.parseExpr(0);
                _ = try parser.popExpectToken(.rparen);
                return expr;
            },
            else => return error.ParserFailed,
        };

        const node_id = parser.nodes.len;
        try parser.nodes.append(alloc, node);
        return @intCast(node_id);
    }

    fn popExpectToken(parser: *Parser, expected: Token.Kind) !Token {
        const token = parser.popToken();
        try parser.expectToken(token, expected);
        return token;
    }

    fn expectToken(parser: Parser, got: Token, expected: Token.Kind) !void {
        _ = parser;

        if (got.kind != expected) {
            return error.ParserFailed;
        }
    }

    fn popToken(parser: *Parser) Token {
        const token = parser.peekToken(0);
        parser.head += 1;
        return token;
    }

    fn peekToken(parser: Parser, offset: isize) Token {
        const i = parser.head + offset;
        if (i < 0 or i >= parser.tokens.len) return .{
            .kind = .eof,
            .loc = .{
                .start = @intCast(parser.src.len - 1),
                .len = 1,
            },
        };

        return parser.tokens.get(@intCast(parser.head));
    }

    fn addExtra(parser: *Parser, T: type) !*T {
        const item_count = sizeInExtraData(T);

        const old_count = parser.extra.items.len;
        try parser.extra.resize(parser.alloc, old_count + item_count);

        return @ptrCast(parser.extra.items.ptr + old_count);
    }
};

pub fn sizeInExtraData(T: type) usize {
    std.debug.assert(@alignOf(T) <= @alignOf(u32));
    return comptime std.math.divCeil(usize, @sizeOf(T), @sizeOf(u32)) catch unreachable;
}

pub fn format(ast: Ast, writer: *std.Io.Writer) !void {
    try writer.print("AST:\n", .{});

    const root = ast.nodes.get(0);
    const tl_slice = root.data.node_slice;
    const tl_end = tl_slice.first_node + tl_slice.len;

    var i: usize = tl_slice.first_node;
    while (i < tl_end) : (i += 1) {
        const node = ast.nodes.get(i);
        std.debug.assert(node.kind == .func);

        const node_d = node.data.token_extra;
        const func: *Node.Func = @ptrCast(ast.extra_data.ptr + node_d.extra);

        if (func.flags.export_) {
            try writer.print("export ", .{});
        }

        try writer.print("fn {s}(", .{
            ast.tokens.get(node_d.token).loc.get(ast.src),
        });

        const first_param = node_d.extra + sizeInExtraData(Node.Func);
        for (0..func.param_count) |param_id| {
            const param: *Node.Param = @ptrCast(ast.extra_data.ptr + first_param + param_id);

            if (param_id != 0) try writer.print(", ", .{});
            try writer.print("{s}", .{
                ast.tokens.get(param.token).loc.get(ast.src),
            });
        }

        try writer.print("):\n", .{});
        try printBlock(writer, ast, ast.nodes.get(func.block), 1);
        try writer.print("\n", .{});
    }
}

fn printBlock(writer: *std.Io.Writer, ast: Ast, block: Node, indent: usize) !void {
    const slice = block.data.node_slice;
    const end = slice.first_node + slice.len;

    var i: usize = slice.first_node;
    while (i < end) : (i += 1) {
        const stat = ast.nodes.get(i);

        for (0..indent) |_| try writer.print("    ", .{});
        switch (stat.kind) {
            .stat_assign => {
                const data = stat.data.token_node;
                try writer.print("assign {s} = ", .{
                    ast.tokens.get(data.token).loc.get(ast.src),
                });
                try printExpr(writer, ast, ast.nodes.get(data.node));
                try writer.print("\n", .{});
            },
            .stat_ret => {
                try writer.print("return ", .{});
                try printExpr(writer, ast, ast.nodes.get(stat.data.node));
                try writer.print("\n", .{});
            },
            .stat_if => {
                i += 1;
                const then_block = ast.nodes.get(i);
                const data = stat.data.node_opt_node;

                try writer.print("if ", .{});
                try printExpr(writer, ast, ast.nodes.get(data.left));
                try writer.print(":\n", .{});
                try printBlock(writer, ast, then_block, indent + 1);

                if (data.right.unwrap()) |else_block| {
                    for (0..indent) |_| try writer.print("    ", .{});
                    try writer.print("else:\n", .{});
                    try printBlock(writer, ast, ast.nodes.get(else_block), indent + 1);
                }
            },
            .stat_while => {
                const data = stat.data.node_node;
                const body = ast.nodes.get(data.right);

                try writer.print("while ", .{});
                try printExpr(writer, ast, ast.nodes.get(data.left));
                try writer.print(":\n", .{});
                try printBlock(writer, ast, body, indent + 1);
            },
            else => unreachable,
        }
    }
}

fn printExpr(writer: *std.Io.Writer, ast: Ast, node: Node) !void {
    switch (node.kind) {
        .expr_ident => try writer.print("{s}", .{
            ast.tokens.get(node.main_token_id).loc.get(ast.src),
        }),
        .expr_lit_int => try writer.print("{}", .{node.data.int}),
        .expr_add, .expr_sub, .expr_mul, .expr_div, .expr_equal, .expr_less, .expr_more => {
            const data = node.data.node_node;
            try writer.print("(", .{});
            try printExpr(writer, ast, ast.nodes.get(data.left));

            try writer.print(" {s} ", .{switch (node.kind) {
                .expr_add => "+",
                .expr_sub => "-",
                .expr_mul => "*",
                .expr_div => "/",
                .expr_equal => "==",
                .expr_less => "<",
                .expr_more => ">",
                else => unreachable,
            }});

            try printExpr(writer, ast, ast.nodes.get(data.right));
            try writer.print(")", .{});
        },
        else => unreachable,
    }
}

pub fn dump(ast: Ast) void {
    std.debug.print("\n", .{});
    for (0..ast.nodes.len) |i| {
        const node = ast.nodes.get(i);

        std.debug.print("{}: {s} ", .{
            i,
            @tagName(node.kind),
        });

        switch (node.kind) {
            .root, .block => {
                const slice = node.data.node_slice;
                std.debug.print("nodes[{}..][0..{}]", .{ slice.first_node, slice.len });
            },
            .stat_assign => {
                const data = node.data.token_node;
                std.debug.print("tokens[{}], node[{}]", .{ data.token, data.node });
            },
            .stat_ret => {
                std.debug.print("nodes[{}]", .{node.data.node});
            },
            .expr_lit_int => {
                std.debug.print("int({})", .{node.data.int});
            },
            .expr_add, .expr_sub, .expr_mul, .expr_div, .expr_equal, .expr_less, .expr_more, .stat_while => {
                const data = node.data.node_node;
                std.debug.print("nodes[{}], nodes[{}]", .{ data.left, data.right });
            },
            .expr_ident => {
                std.debug.print("tokens[{}]", .{node.main_token_id});
            },
            .func => {
                const d = node.data.token_extra;
                const func: *Node.Func = @ptrCast(ast.extra_data.ptr + d.extra);
                std.debug.print("tokens[{}], {any}, param tokens: ", .{ d.token, func });

                const first_param = d.extra + sizeInExtraData(Node.Func);
                for (0..func.param_count) |param_id| {
                    const param: *Node.Param = @ptrCast(ast.extra_data.ptr + first_param + param_id);
                    std.debug.print("{}, ", .{param.token});
                }
            },
            .stat_if => {
                std.debug.print("nodes[{}], ", .{node.data.node_opt_node.left});
                if (node.data.node_opt_node.right.unwrap()) |x| {
                    std.debug.print("nodes[{}]", .{x});
                } else {
                    std.debug.print("null", .{});
                }
            },
        }

        std.debug.print("\n", .{});
    }
}
