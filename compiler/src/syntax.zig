//! Lexical model for the surface language in `../../grammar.ebnf`.

const std = @import("std");

pub const TokenKind = enum {
    eof,
    newline,
    indent,
    dedent,

    identifier,
    int_lit,
    float_lit,
    string_lit,

    kw_if,
    kw_elif,
    kw_else,
    kw_match,
    kw_loop,
    kw_break,
    kw_cont,
    kw_for,
    kw_in,
    kw_while,
    kw_ret,
    kw_use,
    kw_mod,
    kw_pub,
    kw_struct,
    kw_enum,
    kw_table,
    kw_trigger,
    kw_sys,
    kw_impl,
    kw_trait,
    kw_async,
    kw_unsafe,
    kw_await,
    kw_spawn,
    kw_detach,
    kw_cancel,
    kw_select,
    kw_from,
    kw_where,
    kw_res,
    kw_as,
    kw_not,
    kw_and,
    kw_or,
    kw_xor,
    kw_true,
    kw_false,
    kw_nil,
    kw_mut,
    kw_raw,
    kw_crate,
    kw_self,
    kw_super,

    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace,
    rbrace,
    comma,
    colon,
    semicolon,
    dot,
    at,
    question,
    amp,
    pipe,

    assign,
    bind_immutable,
    bind_mutable,
    arrow,

    plus,
    minus,
    star,
    slash,
    percent,

    plus_assign,
    minus_assign,
    star_assign,
    slash_assign,
    percent_assign,

    eq_eq,
    bang_eq,
    lt,
    le,
    gt,
    ge,
    dotdot,
    dotdot_eq,
    ellipsis,
    colon_colon,
    bang,
};

pub const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,
    line: usize,
    column: usize,
    offset: usize,
};

pub const Diagnostic = struct {
    offset: usize = 0,
    line: usize = 1,
    column: usize = 1,
    message: []const u8,
};

pub const keywords = .{
    .{ "if", TokenKind.kw_if },
    .{ "elif", TokenKind.kw_elif },
    .{ "else", TokenKind.kw_else },
    .{ "match", TokenKind.kw_match },
    .{ "loop", TokenKind.kw_loop },
    .{ "break", TokenKind.kw_break },
    .{ "cont", TokenKind.kw_cont },
    .{ "for", TokenKind.kw_for },
    .{ "in", TokenKind.kw_in },
    .{ "while", TokenKind.kw_while },
    .{ "ret", TokenKind.kw_ret },
    .{ "use", TokenKind.kw_use },
    .{ "mod", TokenKind.kw_mod },
    .{ "pub", TokenKind.kw_pub },
    .{ "struct", TokenKind.kw_struct },
    .{ "enum", TokenKind.kw_enum },
    .{ "table", TokenKind.kw_table },
    .{ "trigger", TokenKind.kw_trigger },
    .{ "sys", TokenKind.kw_sys },
    .{ "impl", TokenKind.kw_impl },
    .{ "trait", TokenKind.kw_trait },
    .{ "async", TokenKind.kw_async },
    .{ "unsafe", TokenKind.kw_unsafe },
    .{ "await", TokenKind.kw_await },
    .{ "spawn", TokenKind.kw_spawn },
    .{ "detach", TokenKind.kw_detach },
    .{ "cancel", TokenKind.kw_cancel },
    .{ "select", TokenKind.kw_select },
    .{ "from", TokenKind.kw_from },
    .{ "where", TokenKind.kw_where },
    .{ "res", TokenKind.kw_res },
    .{ "as", TokenKind.kw_as },
    .{ "not", TokenKind.kw_not },
    .{ "and", TokenKind.kw_and },
    .{ "or", TokenKind.kw_or },
    .{ "xor", TokenKind.kw_xor },
    .{ "true", TokenKind.kw_true },
    .{ "false", TokenKind.kw_false },
    .{ "nil", TokenKind.kw_nil },
    .{ "mut", TokenKind.kw_mut },
    .{ "raw", TokenKind.kw_raw },
    .{ "crate", TokenKind.kw_crate },
    .{ "self", TokenKind.kw_self },
    .{ "super", TokenKind.kw_super },
};

pub const keyword_map = std.StaticStringMap(TokenKind).initComptime(keywords);

pub const MultiOperator = struct {
    text: []const u8,
    kind: TokenKind,
};

/// Longest-match first in the lexer.  Single-character operators are handled
/// by the lexer switch so brackets can maintain nesting depth.
pub const multi_operators = [_]MultiOperator{
    .{ .text = "...", .kind = .ellipsis },
    .{ .text = "..=", .kind = .dotdot_eq },
    .{ .text = "<-", .kind = .bind_immutable },
    .{ .text = ":=", .kind = .bind_mutable },
    .{ .text = "+=", .kind = .plus_assign },
    .{ .text = "-=", .kind = .minus_assign },
    .{ .text = "*=", .kind = .star_assign },
    .{ .text = "/=", .kind = .slash_assign },
    .{ .text = "%=", .kind = .percent_assign },
    .{ .text = "->", .kind = .arrow },
    .{ .text = "::", .kind = .colon_colon },
    .{ .text = "..", .kind = .dotdot },
    .{ .text = "==", .kind = .eq_eq },
    .{ .text = "!=", .kind = .bang_eq },
    .{ .text = "<=", .kind = .le },
    .{ .text = ">=", .kind = .ge },
};

pub const multi_operator_map = blk: {
    var entries: [multi_operators.len]struct { []const u8, MultiOperator } = undefined;
    for (multi_operators, 0..) |op, i| entries[i] = .{ op.text, op };
    break :blk std.StaticStringMap(MultiOperator).initComptime(entries);
};

pub const max_multi_operator_len = blk: {
    var n: usize = 0;
    for (multi_operators) |op| n = @max(n, op.text.len);
    break :blk n;
};

pub fn tokenName(kind: TokenKind) []const u8 {
    return @tagName(kind);
}

pub fn isKeywordKind(kind: TokenKind) bool {
    return std.mem.startsWith(u8, @tagName(kind), "kw_");
}
