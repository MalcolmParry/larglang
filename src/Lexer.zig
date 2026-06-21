const std = @import("std");
const Lexer = @This();

src: []const u8,
head: usize,

pub const Slice = struct {
    start: u32,
    len: u32,
};

pub const Token = union(enum) {
    eof,
    ident: Slice,
    int: u64,

    // symbols
    lparen,
    rparen,
    lbrace,
    rbrace,
    colon,
    assign,
    semicolon,
    plus,

    // keywords
    func,
    const_,
    ret,

    // errors
    err_invalid_char: u32,
    err_overflow: Slice,

    pub fn isError(token: Token) bool {
        return switch (token) {
            .err_invalid_char,
            .err_overflow,
            => true,
            else => false,
        };
    }

    pub fn format(token: Token, lexer: *const Lexer) Formatter {
        return .{
            .src = lexer.src,
            .token = token,
        };
    }

    pub const Formatter = struct {
        src: []const u8,
        token: Token,

        pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("{s}", .{@tagName(this.token)});

            switch (this.token) {
                .ident => |slice| try writer.print(" {s}", .{this.src[slice.start..][0..slice.len]}),
                .int => |val| try writer.print(" {}", .{val}),
                else => {},
            }
        }
    };
};

pub fn getToken(lexer: *Lexer) Token {
    while (true) {
        const c = lexer.peekChar() orelse return .eof;
        if (std.ascii.isWhitespace(c)) {
            lexer.head += 1;
            continue;
        }

        if (std.ascii.isAlphabetic(c) or c == '_') return handleIdent(lexer);
        if (std.ascii.isDigit(c)) return handleInt(lexer);

        const token: Token = switch (c) {
            '(' => .lparen,
            ')' => .rparen,
            '{' => .lbrace,
            '}' => .rbrace,
            ':' => .colon,
            '=' => .assign,
            ';' => .semicolon,
            '+' => .plus,
            else => .{ .err_invalid_char = @intCast(lexer.head) },
        };

        lexer.head += 1;
        return token;
    }
}

fn handleIdent(lexer: *Lexer) Token {
    const start = lexer.head;

    while (lexer.peekChar()) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) break;
        lexer.head += 1;
    }

    const ident = lexer.src[start..lexer.head];
    if (std.mem.eql(u8, ident, "fn")) return .func;
    if (std.mem.eql(u8, ident, "const")) return .const_;
    if (std.mem.eql(u8, ident, "return")) return .ret;

    return .{ .ident = .{
        .start = @intCast(start),
        .len = @intCast(lexer.head - start),
    } };
}

fn handleInt(lexer: *Lexer) Token {
    const start = lexer.head;

    while (lexer.peekChar()) |c| {
        if (!std.ascii.isDigit(c)) break;
        lexer.head += 1;
    }

    const src = lexer.src[start..lexer.head];
    const val = std.fmt.parseInt(u64, src, 10) catch |err| switch (err) {
        error.InvalidCharacter => unreachable,
        error.Overflow => return .{ .err_overflow = .{
            .start = @intCast(start),
            .len = @intCast(lexer.head - start),
        } },
    };

    return .{ .int = val };
}

fn peekChar(lexer: *Lexer) ?u8 {
    if (lexer.head >= lexer.src.len) return null;
    return lexer.src[lexer.head];
}
