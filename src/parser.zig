const std = @import("std");
const Lexer = @import("Lexer.zig");
const Token = Lexer.Token;
const Slice = Lexer.Slice;

pub const FileScope = struct {
    func_decls: []const FuncDecl,

    pub fn format(file_scope: FileScope, lexer: *const Lexer) Formatter {
        return .{ .scope = file_scope, .lexer = lexer };
    }

    pub const Formatter = struct {
        scope: FileScope,
        lexer: *const Lexer,

        pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            for (this.scope.func_decls) |func| {
                try writer.print("{f}\n", .{func.format(this.lexer)});
            }
        }
    };
};

pub const FuncDecl = struct {
    name: Slice,
    statements: []const Statement,

    pub fn format(func_decl: FuncDecl, lexer: *const Lexer) Formatter {
        return .{ .func_decl = func_decl, .lexer = lexer };
    }

    pub const Formatter = struct {
        func_decl: FuncDecl,
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
    add: BinOp,

    pub const BinOp = struct {
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
                .add => |bin| try writer.print("({f} + {f})", .{
                    bin.left.format(this.lexer),
                    bin.right.format(this.lexer),
                }),
            }
        }
    };
};

pub const State = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    lexer: *Lexer,
};

pub fn parse(state: State) !?FileScope {
    var func_decls: std.ArrayList(FuncDecl) = .empty;
    defer func_decls.deinit(state.gpa);

    while (true) {
        const token = state.lexer.peekToken();
        if (token.isError()) return null;

        switch (token) {
            .func => {
                const func_decl = try parseFuncDecl(state) orelse return null;
                try func_decls.append(state.gpa, func_decl);
            },
            .eof => break,
            else => return null,
        }
    }

    return .{
        .func_decls = try state.arena.dupe(FuncDecl, func_decls.items),
    };
}

pub fn parseFuncDecl(state: State) !?FuncDecl {
    if (state.lexer.popToken() != .func) return null;
    const name_token = state.lexer.popToken();
    if (name_token != .ident) return null;

    if (state.lexer.popToken() != .lparen) return null;
    if (state.lexer.popToken() != .rparen) return null;
    if (state.lexer.popToken() != .lbrace) return null;

    var statements: std.ArrayList(Statement) = .empty;
    defer statements.deinit(state.gpa);

    while (true) {
        const token = state.lexer.peekToken();
        if (token == .rbrace) break;

        const statement = try parseStatement(state) orelse return null;
        try statements.append(state.gpa, statement);
    }

    _ = state.lexer.popToken();

    return .{
        .name = name_token.ident,
        .statements = try state.arena.dupe(Statement, statements.items),
    };
}

pub fn parseStatement(state: State) !?Statement {
    const token = state.lexer.peekToken();

    switch (token) {
        .ident => {
            const ident = state.lexer.popToken();
            if (state.lexer.popToken() != .assign) return null;
            const expr = try parseExpr(state) orelse return null;
            if (state.lexer.popToken() != .semicolon) return null;

            return .{ .assign = .{
                .ident = ident.ident,
                .expr = expr,
            } };
        },
        .ret => {
            _ = state.lexer.popToken();
            const expr = try parseExpr(state) orelse return null;
            if (state.lexer.popToken() != .semicolon) return null;

            return .{ .ret = expr };
        },
        else => return null,
    }
}

pub fn parseExpr(state: State) !?*Expression {
    var left: *Expression = try parseTerm(state) orelse return null;
    while (true) {
        const op = state.lexer.peekToken();
        if (op != .plus) break;

        _ = state.lexer.popToken();
        const right = try parseExpr(state) orelse return null;
        const new = try state.arena.create(Expression);
        new.* = .{ .add = .{
            .left = left,
            .right = right,
        } };
        left = new;
    }

    return left;
}

pub fn parseTerm(state: State) !?*Expression {
    const val = try parseTermVal(state) orelse return null;
    const ptr = try state.arena.create(Expression);
    ptr.* = val;
    return ptr;
}

pub fn parseTermVal(state: State) !?Expression {
    const token = state.lexer.popToken();
    return switch (token) {
        .int => |val| .{ .int_lit = val },
        .ident => |ident| .{ .ident = ident },
        else => null,
    };
}
