//! Lowering of e7s expressions, statements, and blocks to Slang.
//!
//! This is a syntax-directed translation.  Semantics follow Slang rather than
//! e7 where the two differ: values are mutable by default in Slang (`var`),
//! block tail expressions become `return`, and e7's scalar type names become
//! Slang scalar names.

const std = @import("std");
const compiler = @import("compiler");
const ast = compiler.ast;
const astx = @import("astx.zig");
const model = @import("model.zig");
const types = @import("types.zig");
const session_mod = @import("session.zig");

const Session = session_mod.Session;
const Error = session_mod.Error;

pub const Scope = struct {
    parent: ?*Scope,
    vars: std.StringHashMapUnmanaged(*ast.Type) = .empty,

    pub fn lookup(self: *const Scope, name: []const u8) ?*ast.Type {
        var current: ?*const Scope = self;
        while (current) |scope| {
            if (scope.vars.get(name)) |ty| return ty;
            current = scope.parent;
        }
        return null;
    }
};

pub const Lower = struct {
    s: *Session,
    module: *const ast.Module,
    result_type: ?*ast.Type = null,
    scope: ?*Scope = null,

    pub fn init(s: *Session, module: *const ast.Module) Lower {
        return .{ .s = s, .module = module };
    }

    fn newScope(self: *Lower, parent: ?*Scope) !*Scope {
        const scope = try self.s.scratch().create(Scope);
        scope.* = .{ .parent = parent };
        return scope;
    }

    // ------------------------------------------------------------------
    // Functions and blocks
    // ------------------------------------------------------------------

    pub fn lowerFunctionBody(self: *Lower, body: ast.FunctionBody, result_ty: *ast.Type) Error!void {
        const old_result = self.result_type;
        const old_scope = self.scope;
        self.result_type = result_ty;
        defer {
            self.result_type = old_result;
            self.scope = old_scope;
        }

        switch (body) {
            .expr => |expression| {
                if (types.isVoidResult(self.s, result_ty)) {
                    try self.lowerExpr(expression, result_ty);
                    try self.s.out.line(";", .{});
                } else {
                    try self.s.out.raw("return ", .{});
                    try self.lowerExpr(expression, result_ty);
                    try self.s.out.line(";", .{});
                }
            },
            .block => |block| {
                const scope = try self.newScope(old_scope);
                self.scope = scope;
                try self.lowerBlockEntries(block, result_ty, .function_body);
            },
        }
    }

    const BlockMode = enum { statements, function_body };

    fn lowerBlockEntries(self: *Lower, block: *const ast.Block, result_ty: ?*ast.Type, mode: BlockMode) Error!void {
        for (block.entries, 0..) |entry, index| {
            const is_last = index + 1 == block.entries.len;
            switch (entry) {
                .item => |item| {
                    self.s.setSpan(self.module, item);
                    return self.s.fail("items inside blocks are not supported in e7s", .{});
                },
                .stmt => |statement| {
                    self.s.setSpan(self.module, statement);
                    if (is_last and mode == .function_body) {
                        if (statement.* == .expr and statement.expr.* != .match_expr) {
                            if (result_ty) |ty| {
                                if (!types.isVoidResult(self.s, ty)) {
                                    try self.s.out.raw("return ", .{});
                                    try self.lowerExpr(statement.expr, ty);
                                    try self.s.out.line(";", .{});
                                    continue;
                                }
                            }
                        }
                    }
                    try self.lowerStmt(statement);
                },
            }
        }
    }

    /// Body of a nested control-flow block.  Returns a value only through an
    /// explicit `ret`; a tail expression is emitted as a plain statement.
    fn lowerNestedBlock(self: *Lower, block: *const ast.Block) Error!void {
        const old_scope = self.scope;
        self.scope = try self.newScope(old_scope);
        defer self.scope = old_scope;
        try self.lowerBlockEntries(block, null, .statements);
    }

    fn lowerNestedBlockWithVar(
        self: *Lower,
        block: *const ast.Block,
        name: []const u8,
        ty: *ast.Type,
    ) Error!void {
        const old_scope = self.scope;
        const scope = try self.newScope(old_scope);
        try scope.vars.put(self.s.scratch(), name, ty);
        self.scope = scope;
        defer self.scope = old_scope;
        try self.lowerBlockEntries(block, null, .statements);
    }

    // ------------------------------------------------------------------
    // Statements
    // ------------------------------------------------------------------

    fn lowerStmt(self: *Lower, statement: *const ast.Stmt) Error!void {
        switch (statement.*) {
            .binding => |binding| try self.lowerBinding(binding),
            .uninitialized => |decl| {
                try types.writeType(self.s, decl.ty);
                try self.s.out.line(" {s};", .{decl.name});
                if (self.scope) |scope| try scope.vars.put(self.s.scratch(), decl.name, decl.ty);
            },
            .ret => |value| {
                if (value) |expression| {
                    try self.s.out.raw("return ", .{});
                    const expected = self.result_type;
                    try self.lowerExpr(expression, expected);
                    try self.s.out.line(";", .{});
                } else {
                    try self.s.out.line("return;", .{});
                }
            },
            .break_stmt => try self.s.out.line("break;", .{}),
            .cont => try self.s.out.line("continue;", .{}),
            .while_stmt => |while_stmt| {
                try self.s.out.raw("while (", .{});
                try self.lowerExpr(while_stmt.condition, self.s.program.ty_bool);
                try self.s.out.line(") {{", .{});
                self.s.out.indent();
                try self.lowerNestedBlock(while_stmt.body);
                self.s.out.dedent();
                try self.s.out.line("}}", .{});
            },
            .loop_stmt => |loop_stmt| {
                try self.s.out.line("for (;;) {{", .{});
                self.s.out.indent();
                try self.lowerNestedBlock(loop_stmt.body);
                self.s.out.dedent();
                try self.s.out.line("}}", .{});
            },
            .for_stmt => |for_stmt| try self.lowerFor(for_stmt),
            .assign => |assign| {
                const target_ty = self.inferType(assign.target);
                try self.lowerExpr(assign.target, target_ty);
                try self.s.out.raw(" {s} ", .{assignOpText(assign.op)});
                try self.lowerExpr(assign.value, target_ty);
                try self.s.out.line(";", .{});
            },
            .expr => |expression| try self.lowerStatementExpression(expression),
            .unsafe_block => return self.s.fail("`unsafe` blocks are not supported in e7s", .{}),
            .disown => return self.s.fail("`disown` is not supported in e7s", .{}),
        }
    }

    fn lowerBinding(self: *Lower, binding: ast.Binding) Error!void {
        const inferred = if (binding.ty == null) self.inferType(binding.value) else null;
        if (binding.ty) |ty| {
            try types.writeType(self.s, ty);
        } else if (inferred) |ty| {
            if (binding.mutable) {
                try self.s.out.raw("var ", .{});
            } else {
                try self.s.out.raw("let ", .{});
            }
            try self.s.out.raw("{s} = ", .{binding.name});
            try self.lowerExpr(binding.value, ty);
            try self.s.out.line(";", .{});
            if (self.scope) |scope| try scope.vars.put(self.s.scratch(), binding.name, ty);
            return;
        } else {
            if (binding.mutable) {
                try self.s.out.raw("var ", .{});
            } else {
                try self.s.out.raw("let ", .{});
            }
            try self.s.out.raw("{s} = ", .{binding.name});
            try self.lowerExpr(binding.value, null);
            try self.s.out.line(";", .{});
            return;
        }

        try self.s.out.raw(" {s} = ", .{binding.name});
        try self.lowerExpr(binding.value, binding.ty);
        try self.s.out.line(";", .{});
        if (self.scope) |scope| try scope.vars.put(self.s.scratch(), binding.name, binding.ty.?);
    }

    fn lowerFor(self: *Lower, for_stmt: ast.ForStmt) Error!void {
        const name = switch (for_stmt.pattern.*) {
            .binding => |name| name,
            else => return self.s.fail("e7s `for` loops only bind a single loop variable", .{}),
        };

        const range = switch (for_stmt.iterable.*) {
            .range => |range| range,
            else => return self.s.fail("e7s `for` loops only iterate integer ranges (`start..end`)", .{}),
        };

        const end = range.end orelse
            return self.s.fail("open-ended ranges are not supported in e7s `for` loops", .{});

        const loop_ty = blk: {
            if (range.start) |start| {
                if (self.inferType(start)) |ty| {
                    if (astx.typeName(ty)) |name_ty| {
                        if (std.mem.eql(u8, name_ty, "i64")) break :blk self.s.program.ty_i32;
                    }
                }
            }
            break :blk self.s.program.ty_i32;
        };

        try self.s.out.raw("for (int {s} = ", .{name});
        if (range.start) |start| {
            try self.lowerExpr(start, loop_ty);
        } else {
            try self.s.out.raw("0", .{});
        }
        try self.s.out.raw("; {s} {s} ", .{ name, if (range.inclusive) "<=" else "<" });
        try self.lowerExpr(end, loop_ty);
        try self.s.out.line("; {s} += 1) {{", .{name});
        self.s.out.indent();
        try self.lowerNestedBlockWithVar(for_stmt.body, name, loop_ty);
        self.s.out.dedent();
        try self.s.out.line("}}", .{});
    }

    fn lowerStatementExpression(self: *Lower, expression: *ast.Expr) Error!void {
        switch (expression.*) {
            .if_expr => |if_expr| try self.lowerIfStatement(if_expr),
            .match_expr => |match_expr| try self.lowerMatchStatement(match_expr),
            .block => |block| try self.lowerNestedBlock(block),
            else => {
                try self.lowerExpr(expression, null);
                try self.s.out.line(";", .{});
            },
        }
    }

    fn lowerIfStatement(self: *Lower, if_expr: ast.IfExpr) Error!void {
        for (if_expr.branches, 0..) |branch, index| {
            if (index == 0) {
                try self.s.out.raw("if (", .{});
            } else {
                try self.s.out.raw("else if (", .{});
            }
            try self.lowerExpr(branch.condition, self.s.program.ty_bool);
            try self.s.out.line(") {{", .{});
            self.s.out.indent();
            try self.lowerNestedBlock(branch.body);
            self.s.out.dedent();
            try self.s.out.line("}}", .{});
        }
        if (if_expr.else_body) |else_body| {
            try self.s.out.line("else {{", .{});
            self.s.out.indent();
            try self.lowerNestedBlock(else_body);
            self.s.out.dedent();
            try self.s.out.line("}}", .{});
        }
    }

    fn lowerMatchStatement(self: *Lower, match_expr: ast.MatchExpr) Error!void {
        try self.s.out.raw("switch (", .{});
        try self.lowerExpr(match_expr.scrutinee, null);
        try self.s.out.line(") {{", .{});
        self.s.out.indent();
        var saw_default = false;
        for (match_expr.arms, 0..) |arm, index| {
            const is_last = index + 1 == match_expr.arms.len;
            if (arm.guard != null) {
                return self.s.fail("match guards are not supported in e7s", .{});
            }
            switch (arm.pattern.*) {
                .wildcard => {
                    if (!is_last) return self.s.fail("match wildcard must be the last arm", .{});
                    try self.s.out.line("default:", .{});
                    saw_default = true;
                },
                .or_pattern => |patterns| {
                    for (patterns) |pattern| try self.lowerCaseLabel(pattern);
                },
                else => try self.lowerCaseLabel(arm.pattern),
            }
            self.s.out.indent();
            try self.lowerNestedBlock(arm.body);
            if (!blockEndsWithControlFlow(arm.body)) try self.s.out.line("break;", .{});
            self.s.out.dedent();
        }
        if (!saw_default and match_expr.arms.len == 0) {
            try self.s.out.line("default:", .{});
            try self.s.out.line("    break;", .{});
        }
        self.s.out.dedent();
        try self.s.out.line("}}", .{});
    }

    fn lowerCaseLabel(self: *Lower, pattern: *const ast.Pattern) Error!void {
        switch (pattern.*) {
            .literal => |literal| {
                try self.s.out.raw("case ", .{});
                try self.lowerLiteralPattern(literal);
                try self.s.out.line(":", .{});
            },
            .path => |path| {
                try self.s.out.raw("case ", .{});
                try types.writePathSegments(self.s, path, .value);
                try self.s.out.line(":", .{});
            },
            else => return self.s.fail("only literal and enum-variant match patterns are supported in e7s", .{}),
        }
    }

    fn lowerLiteralPattern(self: *Lower, literal: ast.Literal) Error!void {
        switch (literal) {
            .int => |value| try self.s.out.raw("{d}", .{value}),
            .float => |value| try writeFloat(self.s.out, value),
            .boolean => |value| try self.s.out.raw("{s}", .{if (value) "true" else "false"}),
            .nil => return self.s.fail("`nil` patterns are not supported in e7s", .{}),
            .string => return self.s.fail("string patterns are not supported in e7s", .{}),
        }
    }

    fn blockEndsWithControlFlow(block: *const ast.Block) bool {
        if (block.entries.len == 0) return false;
        const last = block.entries[block.entries.len - 1];
        return switch (last) {
            .stmt => |statement| switch (statement.*) {
                .ret, .break_stmt, .cont => true,
                .expr => |expression| switch (expression.*) {
                    .if_expr => true,
                    else => false,
                },
                else => false,
            },
            else => false,
        };
    }

    fn assignOpText(op: ast.AssignOp) []const u8 {
        return switch (op) {
            .assign => "=",
            .add => "+=",
            .sub => "-=",
            .mul => "*=",
            .div => "/=",
            .mod => "%=",
        };
    }

    // ------------------------------------------------------------------
    // Expressions
    // ------------------------------------------------------------------

    pub fn lowerExpr(self: *Lower, expression: *const ast.Expr, expected: ?*const ast.Type) Error!void {
        switch (expression.*) {
            .int => |value| try self.s.out.raw("{d}", .{value}),
            .float => |value| try writeFloat(self.s.out, value),
            .boolean => |value| try self.s.out.raw("{s}", .{if (value) "true" else "false"}),
            .string => return self.s.fail("string literals are not supported in e7s", .{}),
            .nil => return self.s.fail("`nil` is not a Slang value", .{}),
            .error_literal => return self.s.fail("error literals are not supported in e7s", .{}),
            .path => |path| try self.lowerValuePath(path),
            .struct_literal => |literal| try self.lowerStructLiteral(literal, expected),
            .list => |elements| try self.lowerListLiteral(elements, expected),
            .call => |call| try self.lowerCall(call, expected),
            .field => |field| {
                try self.lowerExpr(field.target, null);
                try self.s.out.raw(".{s}", .{field.name});
            },
            .index => |index| {
                try self.lowerExpr(index.target, null);
                for (index.indices) |subscript| {
                    try self.s.out.raw("[", .{});
                    try self.lowerExpr(subscript, null);
                    try self.s.out.raw("]", .{});
                }
            },
            .unary => |unary| try self.lowerUnary(unary, expected),
            .binary => |binary| try self.lowerBinary(binary, expected),
            .cast => |cast| {
                // A cast supplies the expected type for a literal on its
                // right-hand side, so `[1.0, 2.0] as [f32; 2]` works.  For
                // literal construction the cast is the constructor context
                // itself and emitting it twice would be redundant.
                switch (cast.expr.*) {
                    .list, .struct_literal => try self.lowerExpr(cast.expr, cast.ty),
                    else => {
                        try types.writeType(self.s, cast.ty);
                        try self.s.out.raw("(", .{});
                        try self.lowerExpr(cast.expr, cast.ty);
                        try self.s.out.raw(")", .{});
                    },
                }
            },
            .if_expr => |if_expr| try self.lowerIfExpression(if_expr, expected),
            .match_expr => return self.s.fail("`match` is only supported as a statement in e7s", .{}),
            .block => |block| {
                const tail = astx.blockTailExpression(block) orelse
                    return self.s.fail("a block used as a value must end in an expression", .{});
                if (block.entries.len != 1) {
                    return self.s.fail("a block used as a value must contain a single expression in e7s", .{});
                }
                try self.s.out.raw("(", .{});
                try self.lowerExpr(tail, expected);
                try self.s.out.raw(")", .{});
            },
            .function => return self.s.fail("anonymous functions are not supported in e7s", .{}),
            .map_literal => return self.s.fail("map literals are not supported in e7s", .{}),
            .row_literal => return self.s.fail("row literals are not supported in e7s", .{}),
            .query => return self.s.fail("`query` expressions are not supported in e7s", .{}),
            .try_expr => return self.s.fail("`?` propagation is not supported in e7s", .{}),
            .range => return self.s.fail("ranges are only supported as `for` loop iterables in e7s", .{}),
            .prefix => return self.s.fail("`await`/`spawn`/`detach`/`cancel` are not supported in e7s", .{}),
        }
    }

    fn lowerValuePath(self: *Lower, path: ast.Path) Error!void {
        // A bare zero-field struct name is e7's unit-struct value: emit a
        // Slang constructor call instead of a type name.
        const last = astx.pathLast(path);
        const shadowed = if (self.scope) |scope| scope.lookup(last) != null else false;
        if (!shadowed) {
            if (self.s.program.findStructByPath(path)) |info| {
                if (info.decl.fields.len == 0) {
                    try types.writePathSegments(self.s, path, .value);
                    try self.s.out.raw("()", .{});
                    return;
                }
            }
        }
        try types.writePathSegments(self.s, path, .value);
    }

    fn lowerUnary(self: *Lower, unary: ast.Unary, expected: ?*const ast.Type) Error!void {
        switch (unary.op) {
            .negative => {
                try self.s.out.raw("(-", .{});
                try self.lowerExpr(unary.operand, expected);
                try self.s.out.raw(")", .{});
            },
            .not => {
                try self.s.out.raw("(!", .{});
                try self.lowerExpr(unary.operand, self.s.program.ty_bool);
                try self.s.out.raw(")", .{});
            },
            .borrow_shared, .borrow_mut => return self.s.fail("`&` borrow expressions are not supported in e7s", .{}),
            .deref => return self.s.fail("`*` dereference expressions are not supported in e7s", .{}),
        }
    }

    fn lowerBinary(self: *Lower, binary: ast.Binary, expected: ?*const ast.Type) Error!void {
        if (binary.op == .mul and self.shouldUseMul(binary)) {
            try self.s.out.raw("mul(", .{});
            try self.lowerExpr(binary.lhs, null);
            try self.s.out.raw(", ", .{});
            try self.lowerExpr(binary.rhs, null);
            try self.s.out.raw(")", .{});
            return;
        }

        if (binary.op == .xor_) {
            try self.s.out.raw("(", .{});
            try self.lowerExpr(binary.lhs, self.s.program.ty_bool);
            try self.s.out.raw(" != ", .{});
            try self.lowerExpr(binary.rhs, self.s.program.ty_bool);
            try self.s.out.raw(")", .{});
            return;
        }

        if (binary.op == .and_ or binary.op == .or_) {
            try self.s.out.raw("(", .{});
            try self.lowerExpr(binary.lhs, self.s.program.ty_bool);
            try self.s.out.raw(" {s} ", .{if (binary.op == .and_) "&&" else "||"});
            try self.lowerExpr(binary.rhs, self.s.program.ty_bool);
            try self.s.out.raw(")", .{});
            return;
        }

        const is_comparison = switch (binary.op) {
            .eq, .ne, .lt, .le, .gt, .ge => true,
            else => false,
        };
        const operand_expected: ?*const ast.Type = blk: {
            if (!is_comparison) {
                if (expected) |ty| break :blk ty;
            }
            if (self.inferType(binary.lhs)) |ty| break :blk ty;
            if (self.inferType(binary.rhs)) |ty| break :blk ty;
            break :blk null;
        };

        try self.s.out.raw("(", .{});
        try self.lowerExpr(binary.lhs, operand_expected);
        try self.s.out.raw(" {s} ", .{binaryOpText(binary.op)});
        try self.lowerExpr(binary.rhs, operand_expected);
        try self.s.out.raw(")", .{});
    }

    fn binaryOpText(op: ast.BinaryOp) []const u8 {
        return switch (op) {
            .or_ => "||",
            .xor_ => "!=",
            .and_ => "&&",
            .eq => "==",
            .ne => "!=",
            .lt => "<",
            .le => "<=",
            .gt => ">",
            .ge => ">=",
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .mod => "%",
        };
    }

    fn shouldUseMul(self: *Lower, binary: ast.Binary) bool {
        const lhs_kind = self.classifyType(self.inferType(binary.lhs));
        const rhs_kind = self.classifyType(self.inferType(binary.rhs));
        return switch (lhs_kind) {
            .matrix => rhs_kind == .matrix or rhs_kind == .vector,
            .vector => rhs_kind == .matrix,
            else => false,
        };
    }

    const TypeKind = enum { scalar, vector, matrix, unknown };

    fn classifyType(self: *Lower, ty: ?*ast.Type) TypeKind {
        _ = self;
        const resolved = ty orelse return .unknown;
        return switch (resolved.*) {
            .path => |path| blk: {
                if (path.segments.len != 1) break :blk .unknown;
                if (astx.scalarSlangName(path.segments[0].name) != null) break :blk .scalar;
                break :blk .unknown;
            },
            .array => |array| if (array.columns != null) .matrix else .vector,
            else => .unknown,
        };
    }

    fn lowerCall(self: *Lower, call: ast.Call, expected: ?*const ast.Type) Error!void {
        _ = expected;
        var params: ?[]ast.Param = null;
        if (call.callee.* == .path) {
            if (self.s.program.findFunctionByPath(call.callee.path)) |info| {
                params = info.decl.params;
            }
        }

        try self.lowerExpr(call.callee, null);
        try self.s.out.raw("(", .{});
        for (call.args, 0..) |argument, index| {
            if (index != 0) try self.s.out.raw(", ", .{});
            const expected_arg: ?*const ast.Type = if (params) |list|
                if (index < list.len) unwrapReferences(list[index].ty) else null
            else
                null;
            try self.lowerExpr(argument, expected_arg);
        }
        try self.s.out.raw(")", .{});
    }

    fn lowerStructLiteral(self: *Lower, literal: ast.StructLiteral, expected: ?*const ast.Type) Error!void {
        _ = expected;
        const info = self.s.program.findStructByPath(literal.path) orelse {
            return self.s.fail("unknown struct type in literal (e7s needs the struct declared in this program)", .{});
        };

        var subst = try self.s.program.substitutionFor(info, literal.path);
        defer subst.deinit(self.s.program.allocator);

        const fields = info.decl.fields;
        const values = try self.s.scratch().alloc(?*const ast.Expr, fields.len);
        @memset(values, null);

        for (literal.fields) |field_init| {
            var found: ?usize = null;
            for (fields, 0..) |field, i| {
                if (std.mem.eql(u8, field.name, field_init.name)) {
                    found = i;
                    break;
                }
            }
            const index = found orelse {
                return self.s.fail("struct literal has unknown field `{s}`", .{field_init.name});
            };
            if (values[index] != null) {
                return self.s.fail("duplicate field `{s}` in struct literal", .{field_init.name});
            }
            values[index] = field_init.value;
        }

        try types.writePathSegments(self.s, literal.path, .type);
        try self.s.out.raw("(", .{});
        for (fields, 0..) |field, i| {
            if (i != 0) try self.s.out.raw(", ", .{});
            const value = values[i] orelse {
                return self.s.fail("struct literal is missing field `{s}`", .{field.name});
            };
            const field_ty = try self.s.program.substituteType(field.ty, &subst);
            try self.lowerExpr(value, field_ty);
        }
        try self.s.out.raw(")", .{});
    }

    fn lowerListLiteral(self: *Lower, elements: []*ast.Expr, expected: ?*const ast.Type) Error!void {
        const ty = expected orelse {
            return self.s.fail("cannot infer the element type of a list literal; annotate the binding or parameter", .{});
        };
        const array = switch (ty.*) {
            .array => |array| array,
            else => return self.s.fail("list literal requires a vector or matrix type context", .{}),
        };

        if (array.columns) |columns_expr| {
            const rows = astx.intValue(array.length orelse {
                return self.s.fail("matrix type is missing its row count", .{});
            }) orelse return self.s.fail("matrix row count must be an integer literal", .{});
            const columns = astx.intValue(columns_expr) orelse
                return self.s.fail("matrix column count must be an integer literal", .{});

            const flattened = try self.s.scratch().alloc(*ast.Expr, @intCast(rows * columns));
            if (elements.len == rows and allLists(elements)) {
                var index: usize = 0;
                for (elements) |row| {
                    const row_elements = row.list;
                    if (row_elements.len != columns) {
                        return self.s.fail("matrix row has {d} elements, expected {d}", .{ row_elements.len, columns });
                    }
                    for (row_elements) |element| {
                        flattened[index] = element;
                        index += 1;
                    }
                }
            } else if (elements.len == rows * columns) {
                for (elements, 0..) |element, i| flattened[i] = element;
            } else {
                return self.s.fail("matrix literal must have {d} rows of {d} elements", .{ rows, columns });
            }

            try types.writeType(self.s, ty);
            try self.s.out.raw("(", .{});
            for (flattened, 0..) |element, i| {
                if (i != 0) try self.s.out.raw(", ", .{});
                try self.lowerExpr(element, array.element);
            }
            try self.s.out.raw(")", .{});
            return;
        }

        const length = astx.intValue(array.length orelse {
            return self.s.fail("vector type is missing its length", .{});
        }) orelse return self.s.fail("vector length must be an integer literal", .{});
        if (elements.len != length) {
            return self.s.fail("vector literal has {d} elements, expected {d}", .{ elements.len, length });
        }
        try types.writeType(self.s, ty);
        try self.s.out.raw("(", .{});
        for (elements, 0..) |element, i| {
            if (i != 0) try self.s.out.raw(", ", .{});
            try self.lowerExpr(element, array.element);
        }
        try self.s.out.raw(")", .{});
    }

    fn allLists(elements: []*ast.Expr) bool {
        for (elements) |element| {
            if (element.* != .list) return false;
        }
        return true;
    }

    fn lowerIfExpression(self: *Lower, if_expr: ast.IfExpr, expected: ?*const ast.Type) Error!void {
        if (if_expr.else_body == null) {
            return self.s.fail("`if` used as a value needs an `else` branch in e7s", .{});
        }
        try self.s.out.raw("(", .{});
        try self.lowerIfExpressionBranch(if_expr, 0, expected);
        try self.s.out.raw(")", .{});
    }

    fn lowerIfExpressionBranch(
        self: *Lower,
        if_expr: ast.IfExpr,
        index: usize,
        expected: ?*const ast.Type,
    ) Error!void {
        if (index >= if_expr.branches.len) {
            const else_body = if_expr.else_body.?;
            const tail = astx.blockTailExpression(else_body) orelse
                return self.s.fail("an `else` block used as a value must end in an expression", .{});
            if (else_body.entries.len != 1) {
                return self.s.fail("`if` branches used as values must contain a single expression in e7s", .{});
            }
            try self.lowerExpr(tail, expected);
            return;
        }

        const branch = if_expr.branches[index];
        const tail = astx.blockTailExpression(branch.body) orelse
            return self.s.fail("`if` branches used as values must end in an expression", .{});
        if (branch.body.entries.len != 1) {
            return self.s.fail("`if` branches used as values must contain a single expression in e7s", .{});
        }
        try self.lowerExpr(branch.condition, self.s.program.ty_bool);
        try self.s.out.raw(" ? ", .{});
        try self.lowerExpr(tail, expected);
        try self.s.out.raw(" : ", .{});
        try self.lowerIfExpressionBranch(if_expr, index + 1, expected);
    }

    // ------------------------------------------------------------------
    // Type inference (just enough for local bindings and literals)
    // ------------------------------------------------------------------

    pub fn inferType(self: *Lower, expression: *const ast.Expr) ?*ast.Type {
        return switch (expression.*) {
            .int => self.s.program.ty_i32,
            .float => self.s.program.ty_f32,
            .boolean => self.s.program.ty_bool,
            .path => |path| self.inferPath(path),
            .struct_literal => |literal| self.s.program.makePathTypeFromPath(literal.path) catch null,
            .list => |elements| self.inferList(elements),
            .call => |call| self.inferCall(call),
            .field => |field| self.inferField(field),
            .index => |index| self.inferIndex(index),
            .cast => |cast| cast.ty,
            .unary => |unary| switch (unary.op) {
                .negative => self.inferType(unary.operand),
                .not => self.s.program.ty_bool,
                else => null,
            },
            .binary => |binary| switch (binary.op) {
                .and_, .or_, .xor_, .eq, .ne, .lt, .le, .gt, .ge => self.s.program.ty_bool,
                else => self.inferType(binary.lhs) orelse self.inferType(binary.rhs),
            },
            .if_expr => |if_expr| blk: {
                if (if_expr.branches.len == 0) break :blk null;
                const tail = astx.blockTailExpression(if_expr.branches[0].body) orelse break :blk null;
                break :blk self.inferType(tail);
            },
            .block => |block| if (astx.blockTailExpression(block)) |tail| self.inferType(tail) else null,
            else => null,
        };
    }

    fn inferPath(self: *Lower, path: ast.Path) ?*ast.Type {
        if (path.segments.len == 0) return null;
        if (path.segments.len == 1) {
            const name = path.segments[0].name;
            if (self.scope) |scope| {
                if (scope.lookup(name)) |ty| return ty;
            }
            if (astx.scalarSlangName(name) != null) return self.s.program.makePathType(name) catch null;
            if (self.s.program.findStruct(name) != null) {
                return self.s.program.makePathTypeFromPath(path) catch null;
            }
            return null;
        }
        // Enum variants are written `Enum::Variant`; their value type is the
        // enum, not the variant path.
        if (self.s.program.findEnum(path.segments[0].name) != null) {
            return self.s.program.makePathType(path.segments[0].name) catch null;
        }
        return null;
    }

    fn inferList(self: *Lower, elements: []*ast.Expr) ?*ast.Type {
        if (elements.len == 0) return null;
        if (elements[0].* == .list) {
            const rows: i64 = @intCast(elements.len);
            const first_row = elements[0].list;
            const columns: i64 = @intCast(first_row.len);
            if (columns == 0) return null;
            const element = self.inferType(first_row[0]) orelse return null;
            return self.s.program.makeMatrixType(element, rows, columns) catch null;
        }
        const element = self.inferType(elements[0]) orelse return null;
        return self.s.program.makeVectorType(element, @intCast(elements.len)) catch null;
    }

    fn inferCall(self: *Lower, call: ast.Call) ?*ast.Type {
        if (call.callee.* != .path) return null;
        const info = self.s.program.findFunctionByPath(call.callee.path) orelse return null;
        const result = info.decl.result;
        if (info.decl.generics.len == 0) return result;

        var subst: std.StringHashMapUnmanaged(*ast.Type) = .empty;
        defer subst.deinit(self.s.program.allocator);
        for (info.decl.params, 0..) |param, i| {
            if (i >= call.args.len) break;
            const param_path = astx.typePath(param.ty) orelse continue;
            if (param_path.segments.len != 1) continue;
            var is_generic = false;
            for (info.decl.generics) |generic| {
                if (std.mem.eql(u8, generic.name, param_path.segments[0].name)) is_generic = true;
            }
            if (!is_generic) continue;
            const argument_ty = self.inferType(call.args[i]) orelse continue;
            subst.put(self.s.program.allocator, param_path.segments[0].name, argument_ty) catch return null;
        }
        return self.s.program.substituteType(result, &subst) catch null;
    }

    fn inferField(self: *Lower, field: ast.FieldAccess) ?*ast.Type {
        const raw_ty = self.inferType(field.target) orelse return null;
        const target_ty = unwrapReferences(raw_ty);
        const path = astx.typePath(target_ty) orelse return null;
        const info = self.s.program.findStructByPath(path.*) orelse return null;
        var subst = self.s.program.substitutionFor(info, path.*) catch return null;
        defer subst.deinit(self.s.program.allocator);
        for (info.decl.fields) |decl_field| {
            if (!std.mem.eql(u8, decl_field.name, field.name)) continue;
            return self.s.program.substituteType(decl_field.ty, &subst) catch null;
        }
        return null;
    }

    fn inferIndex(self: *Lower, index: ast.Index) ?*ast.Type {
        const raw_ty = self.inferType(index.target) orelse return null;
        const target_ty = unwrapReferences(raw_ty);
        return switch (target_ty.*) {
            .array => |array| blk: {
                if (array.columns != null and index.indices.len == 1) {
                    const columns = astx.intValue(array.columns.?) orelse break :blk array.element;
                    break :blk self.s.program.makeVectorType(array.element, columns) catch array.element;
                }
                break :blk array.element;
            },
            .path => |path| blk: {
                if (path.segments.len == 0) break :blk null;
                const segment = path.segments[path.segments.len - 1];
                if (segment.args.len == 0) break :blk null;
                const name = segment.name;
                const buffer_like = std.mem.eql(u8, name, "StructuredBuffer") or
                    std.mem.eql(u8, name, "RWStructuredBuffer") or
                    std.mem.eql(u8, name, "Buffer") or
                    std.mem.eql(u8, name, "RWBuffer") or
                    std.mem.eql(u8, name, "AppendStructuredBuffer") or
                    std.mem.eql(u8, name, "ConsumeStructuredBuffer") or
                    std.mem.eql(u8, name, "Texture1D") or
                    std.mem.eql(u8, name, "Texture1DArray") or
                    std.mem.eql(u8, name, "Texture2D") or
                    std.mem.eql(u8, name, "Texture2DArray") or
                    std.mem.eql(u8, name, "Texture3D") or
                    std.mem.eql(u8, name, "TextureCube") or
                    std.mem.eql(u8, name, "TextureCubeArray") or
                    std.mem.eql(u8, name, "RWTexture1D") or
                    std.mem.eql(u8, name, "RWTexture2D") or
                    std.mem.eql(u8, name, "RWTexture3D");
                break :blk if (buffer_like) segment.args[0] else null;
            },
            else => null,
        };
    }
};

fn unwrapReferences(ty: *ast.Type) *ast.Type {
    var current = ty;
    while (current.* == .reference) current = current.reference.child;
    return current;
}

pub fn writeFloat(out: anytype, value: f64) !void {
    var buffer: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return error.OutOfMemory;
    if (std.mem.indexOfAny(u8, text, ".eE") != null) {
        try out.raw("{s}", .{text});
    } else {
        try out.raw("{s}.0", .{text});
    }
}
