const std = @import("std");
const Lexer = @import("Lexer.zig");
const Token = Lexer.Token;
const Slice = Lexer.Slice;

pub const Error = error{ OutOfMemory, ParseFailed };

pub const FileScope = struct {
    funcs: []const Func,

    pub fn format(file_scope: FileScope, lexer: *const Lexer) Formatter {
        return .{ .scope = file_scope, .lexer = lexer };
    }

    pub const Formatter = struct {
        scope: FileScope,
        lexer: *const Lexer,

        pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            for (this.scope.funcs) |func| {
                try writer.print("{f}\n", .{func.format(this.lexer)});
            }
        }
    };
};

pub const Func = struct {
    name: Slice,
    statements: []const Statement,

    pub fn format(func: Func, lexer: *const Lexer) Formatter {
        return .{ .func_decl = func, .lexer = lexer };
    }

    pub const Formatter = struct {
        func_decl: Func,
        lexer: *const Lexer,

        pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("func '{s}':\n", .{this.func_decl.name.get(this.lexer)});

            for (this.func_decl.statements) |statement| {
                try writer.print("\t{f}", .{statement.format(this.lexer)});
            }
        }
    };
};

pub const Statement = union(enum) {
    assign: Assign,
    ret: *const Expression,

    pub const Assign = struct {
        ident: Slice,
        expr: *const Expression,
    };

    pub fn format(statement: Statement, lexer: *const Lexer) Formatter {
        return .{ .statement = statement, .lexer = lexer };
    }

    pub const Formatter = struct {
        statement: Statement,
        lexer: *const Lexer,

        pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (this.statement) {
                .assign => |assign| try writer.print("assign {s} = {f}\n", .{
                    assign.ident.get(this.lexer),
                    assign.expr.format(this.lexer),
                }),
                .ret => |expr| try writer.print("ret {f}\n", .{
                    expr.format(this.lexer),
                }),
            }
        }
    };
};

pub const Expression = union(enum) {
    int_lit: u64,
    ident: Slice,
    bin: BinOp,

    pub const BinOp = struct {
        pub const Op = enum {
            add,
            sub,
            mul,
            div,

            pub fn getStr(op: Op) []const u8 {
                return switch (op) {
                    .add => "+",
                    .sub => "-",
                    .mul => "*",
                    .div => "/",
                };
            }
        };

        op: Op,
        left: *const Expression,
        right: *const Expression,
    };

    pub fn format(expr: Expression, lexer: *const Lexer) Formatter {
        return .{ .expr = expr, .lexer = lexer };
    }

    pub const Formatter = struct {
        expr: Expression,
        lexer: *const Lexer,

        pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (this.expr) {
                .int_lit => |val| try writer.print("{}", .{val}),
                .ident => |ident| try writer.print("{s}", .{ident.get(this.lexer)}),
                .bin => |bin| {
                    try writer.print("({f} {s} {f})", .{
                        bin.left.format(this.lexer),
                        bin.op.getStr(),
                        bin.right.format(this.lexer),
                    });
                },
            }
        }
    };
};

pub const State = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    lexer: *Lexer,
};

fn expectToken(token: Token, expected: Token.Kind) !void {
    if (token != expected) return error.ParseFailed;
}

fn popExpectToken(state: State, expected: Token.Kind) !Token {
    const token = state.lexer.popToken();
    try expectToken(token, expected);
    return token;
}

pub fn parse(state: State) !FileScope {
    var funcs: std.ArrayList(Func) = .empty;
    defer funcs.deinit(state.gpa);

    while (true) {
        const token = state.lexer.peekToken();

        switch (token) {
            .func => {
                const func = try parseFunc(state);
                try funcs.append(state.gpa, func);
            },
            .eof => break,
            else => return error.ParseFailed,
        }
    }

    return .{
        .funcs = try state.arena.dupe(Func, funcs.items),
    };
}

pub fn parseFunc(state: State) !Func {
    _ = try popExpectToken(state, .func);
    const name_token = state.lexer.popToken();
    try expectToken(name_token, .ident);
    _ = try popExpectToken(state, .lbrace);

    var statements: std.ArrayList(Statement) = .empty;
    defer statements.deinit(state.gpa);

    while (true) {
        const token = state.lexer.peekToken();
        if (token == .rbrace) break;

        const statement = try parseStatement(state);
        try statements.append(state.gpa, statement);
    }

    _ = state.lexer.popToken();

    return .{
        .name = name_token.ident,
        .statements = try state.arena.dupe(Statement, statements.items),
    };
}

pub fn parseStatement(state: State) !Statement {
    const token = state.lexer.peekToken();

    switch (token) {
        .ident => {
            const ident = state.lexer.popToken();
            _ = try popExpectToken(state, .assign);
            const expr = try parseExpr(state);
            _ = try popExpectToken(state, .semicolon);

            return .{ .assign = .{
                .ident = ident.ident,
                .expr = expr,
            } };
        },
        .ret => {
            _ = state.lexer.popToken();
            const expr = try parseExpr(state);
            _ = try popExpectToken(state, .semicolon);

            return .{ .ret = expr };
        },
        else => return error.ParseFailed,
    }
}

pub fn parseExpr(state: State) !*Expression {
    var left: *Expression = try parseTerm(state);
    while (true) {
        const op = state.lexer.peekToken();
        switch (op) {
            .add, .sub, .mul, .div => {},
            else => break,
        }

        _ = state.lexer.popToken();
        const right = try parseTerm(state);
        const new = try state.arena.create(Expression);

        new.* = .{ .bin = .{
            .op = switch (op) {
                .add => .add,
                .sub => .sub,
                .mul => .mul,
                .div => .div,
                else => unreachable,
            },
            .left = left,
            .right = right,
        } };

        left = new;
    }

    return left;
}

pub fn parseTerm(state: State) Error!*Expression {
    const token = state.lexer.popToken();

    const val: Expression = switch (token) {
        .int => |val| .{ .int_lit = val },
        .ident => |ident| .{ .ident = ident },
        .lparen => {
            const expr = try parseExpr(state);
            _ = try popExpectToken(state, .rparen);
            return expr;
        },
        else => return error.ParseFailed,
    };

    const expr = try state.arena.create(Expression);
    expr.* = val;
    return expr;
}
