const std = @import("std");
const Lexer = @This();

src: []const u8,
head: u32,

pub const Loc = struct {
    start: u32,
    len: u32,

    pub fn get(loc: Loc, src: []const u8) []const u8 {
        return src[loc.start..][0..loc.len];
    }
};

pub const TokenList = std.MultiArrayList(Token).Slice;
pub const Token = struct {
    kind: Kind,
    loc: Loc,

    pub const Kind = enum {
        eof,
        ident,
        int,

        lparen,
        rparen,
        lbrace,
        rbrace,
        comma,
        semicolon,
        equal,
        equal_equal,
        langle,
        rangle,
        plus,
        minus,
        asterisk,
        slash,

        kw_fn,
        kw_ret,
        kw_if,
        kw_else,
        kw_while,
        kw_export,
        kw_asm,

        multi_line_str,

        err_invalid_char,

        pub fn isError(kind: Kind) bool {
            return switch (kind) {
                .err_invalid_char => true,
                else => false,
            };
        }
    };
};

const keywords: std.static_string_map.StaticStringMap(Token.Kind) = .initComptime(.{
    .{ "fn", .kw_fn },
    .{ "return", .kw_ret },
    .{ "if", .kw_if },
    .{ "else", .kw_else },
    .{ "while", .kw_while },
    .{ "export", .kw_export },
    .{ "asm", .kw_asm },
});

pub fn getTokens(alloc: std.mem.Allocator, src: []const u8) !TokenList {
    var tokens: std.MultiArrayList(Token) = .empty;
    errdefer tokens.deinit(alloc);

    var lexer: Lexer = .{
        .src = src,
        .head = 0,
    };

    while (true) {
        const token = lexer.nextToken();

        if (token.kind == .eof) break;
        if (token.kind.isError()) {
            std.log.err("{s}: {s}", .{
                @tagName(token.kind),
                token.loc.get(src),
            });

            return error.LexerFailed;
        }

        try tokens.append(alloc, token);
    }

    return tokens.slice();
}

pub fn dumpTokens(tokens: TokenList, src: []const u8) void {
    for (tokens.items(.kind), tokens.items(.loc)) |kind, loc| {
        std.log.info("{s}: '{s}'", .{
            @tagName(kind),
            loc.get(src),
        });
    }
}

const State = enum {
    start,
    eof,
    ident,
    num,
    equal,
    slash,
    back_slash,
    comment,
    multi_line_str,
};

pub fn nextToken(lexer: *Lexer) Token {
    var result: Token = .{
        .kind = undefined,
        .loc = .{
            .start = undefined,
            .len = undefined,
        },
    };

    state: switch (State.start) {
        .start => {
            result.loc.start = lexer.head;

            const kind: Token.Kind = switch (lexer.peekChar(0)) {
                0 => continue :state .eof,
                'a'...'z', 'A'...'Z', '_' => continue :state .ident,
                '0'...'9' => continue :state .num,
                '(' => .lparen,
                ')' => .rparen,
                '{' => .lbrace,
                '}' => .rbrace,
                ',' => .comma,
                ';' => .semicolon,
                '=' => continue :state .equal,
                '<' => .langle,
                '>' => .rangle,
                '+' => .plus,
                '-' => .minus,
                '*' => .asterisk,
                '/' => continue :state .slash,
                '\\' => continue :state .back_slash,
                ' ', '\n', '\r', '\t' => {
                    lexer.head += 1;
                    continue :state .start;
                },
                else => .err_invalid_char,
            };

            result.kind = kind;
            result.loc.len = 1;
            lexer.head += 1;
            return result;
        },
        .eof => {
            return .{
                .kind = .eof,
                .loc = .{
                    .start = @intCast(lexer.src.len - 1),
                    .len = 1,
                },
            };
        },
        .ident => {
            lexer.head += 1;

            switch (lexer.peekChar(0)) {
                'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :state .ident,
                else => {
                    const str = lexer.src[result.loc.start..lexer.head];

                    result.kind = if (keywords.get(str)) |kind| kind else .ident;
                    result.loc.len = lexer.head - result.loc.start;
                    return result;
                },
            }
        },
        .num => {
            lexer.head += 1;

            switch (lexer.peekChar(0)) {
                '0'...'9' => continue :state .num,
                else => {
                    result.kind = .int;
                    result.loc.len = lexer.head - result.loc.start;
                    return result;
                },
            }
        },
        .equal => {
            lexer.head += 1;

            switch (lexer.peekChar(0)) {
                '=' => {
                    result.kind = .equal_equal;
                    result.loc.len = 2;
                    lexer.head += 1;
                    return result;
                },
                else => {
                    result.kind = .equal;
                    result.loc.len = 1;
                    return result;
                },
            }
        },
        .slash => {
            lexer.head += 1;

            switch (lexer.peekChar(0)) {
                '/' => continue :state .comment,
                else => {
                    result.kind = .slash;
                    result.loc.len = 1;
                    return result;
                },
            }
        },
        .back_slash => {
            lexer.head += 1;

            switch (lexer.peekChar(0)) {
                '\\' => {
                    result.loc.start += 2;
                    continue :state .multi_line_str;
                },
                else => {
                    result.kind = .err_invalid_char;
                    result.loc.len = 1;
                    return result;
                },
            }
        },
        .comment => {
            lexer.head += 1;

            switch (lexer.peekChar(0)) {
                0 => continue :state .eof,
                '\n' => {
                    lexer.head += 1;
                    continue :state .start;
                },
                else => continue :state .comment,
            }
        },
        .multi_line_str => {
            lexer.head += 1;
            switch (lexer.peekChar(0)) {
                0, '\n' => {
                    result.kind = .multi_line_str;
                    result.loc.len = lexer.head - result.loc.start;
                    return result;
                },
                else => continue :state .multi_line_str,
            }
        },
    }
}

fn peekChar(lexer: *const Lexer, offset: isize) u8 {
    const pos: isize = @as(isize, @intCast(lexer.head)) + offset;
    if (pos < 0 or pos >= lexer.src.len) return 0;
    return lexer.src[@as(usize, @intCast(pos))];
}
