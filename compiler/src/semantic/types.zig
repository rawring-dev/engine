//! Shared type representation, unification, substitution, and formatting for
//! the semantic analyzer.
//!
//! The same representation is used for declared types, inferred expression
//! types, and generic instantiation.  Keeping unification and formatting in
//! one place is what lets each AST checker stay focused on syntax.

const std = @import("std");

pub const IntKind = enum {
    i8,
    i16,
    i32,
    i64,
    i128,
    isize,
    u8,
    u16,
    u32,
    u64,
    u128,
    usize,
};

pub const FloatKind = enum { f16, f32, f64, f128 };

pub const Generic = struct {
    index: usize,
    name: []const u8,
};

pub const Reference = struct {
    mutable: bool,
    child: *Type,
};

pub const ErrorUnion = struct {
    error_type: *Type,
    value_type: *Type,
};

pub const Function = struct {
    params: []*Type,
    result: *Type,
};

pub const Array = struct {
    element: *Type,
    /// `null` means a dynamically sized `[T]` vector.
    length: ?usize,
    /// Non-null makes this a matrix with `length` rows and `columns` columns.
    columns: ?usize = null,
};

pub const Map = struct {
    key: *Type,
    value: *Type,
};

pub const Named = struct {
    name: []const u8,
    args: []*Type,
};

pub const Query = struct {
    element: *Type,
};

pub const VarKind = enum { any, integer, float };

pub const Var = struct {
    id: usize,
    kind: VarKind,
    binding: ?*Type = null,
};

pub const Type = union(enum) {
    unit,
    bool,
    string,
    never,
    unknown,
    int: IntKind,
    float: FloatKind,
    variable: *Var,
    named: Named,
    reference: Reference,
    box: *Type,
    raw_pointer: *Type,
    optional: *Type,
    error_union: ErrorUnion,
    /// A constructed error value such as `!MyError::Variant`.
    error_value: []const u8,
    function: Function,
    tuple: []*Type,
    array: Array,
    map: Map,
    range: *Type,
    query: Query,
    resource: *Type,
    generic: Generic,
};

pub const UnifyError = error{ TypeMismatch, Occurs, OutOfMemory };

pub const TypeStore = struct {
    allocator: std.mem.Allocator,
    next_var: usize = 0,

    pub fn init(allocator: std.mem.Allocator) TypeStore {
        return .{ .allocator = allocator };
    }

    pub fn make(self: *TypeStore, value: Type) !*Type {
        const node = try self.allocator.create(Type);
        node.* = value;
        return node;
    }

    pub fn freshVar(self: *TypeStore, kind: VarKind) !*Type {
        const variable = try self.allocator.create(Var);
        variable.* = .{ .id = self.next_var, .kind = kind };
        self.next_var += 1;
        return self.make(.{ .variable = variable });
    }

    pub fn integerVar(self: *TypeStore) !*Type {
        return self.freshVar(.integer);
    }

    pub fn floatVar(self: *TypeStore) !*Type {
        return self.freshVar(.float);
    }

    pub fn resolve(self: *const TypeStore, ty: *Type) *Type {
        _ = self;
        var current = ty;
        while (current.* == .variable) {
            const binding = current.variable.binding orelse return current;
            current = binding;
        }
        return current;
    }

    pub fn unify(self: *TypeStore, left: *Type, right: *Type) UnifyError!void {
        const a = self.resolve(left);
        const b = self.resolve(right);

        if (a == b) return;

        if (a.* == .unknown or b.* == .unknown) return;
        if (a.* == .never or b.* == .never) return;

        if (a.* == .variable and b.* == .variable) {
            try self.linkVars(a.variable, b.variable);
            return;
        }
        if (a.* == .variable) {
            try self.bindVar(a.variable, b);
            return;
        }
        if (b.* == .variable) {
            try self.bindVar(b.variable, a);
            return;
        }

        switch (a.*) {
            .unit => if (b.* != .unit) return error.TypeMismatch,
            .bool => if (b.* != .bool) return error.TypeMismatch,
            .string => if (b.* != .string) return error.TypeMismatch,
            .int => |ak| {
                if (b.* != .int or b.int != ak) return error.TypeMismatch;
            },
            .float => |ak| {
                if (b.* != .float or b.float != ak) return error.TypeMismatch;
            },
            .named => |an| {
                if (b.* != .named or !std.mem.eql(u8, an.name, b.named.name) or
                    an.args.len != b.named.args.len)
                {
                    return error.TypeMismatch;
                }
                for (an.args, b.named.args) |x, y| try self.unify(x, y);
            },
            .reference => |ar| {
                if (b.* != .reference or ar.mutable != b.reference.mutable) {
                    return error.TypeMismatch;
                }
                try self.unify(ar.child, b.reference.child);
            },
            .box => |child| {
                if (b.* != .box) return error.TypeMismatch;
                try self.unify(child, b.box);
            },
            .raw_pointer => |child| {
                if (b.* != .raw_pointer) return error.TypeMismatch;
                try self.unify(child, b.raw_pointer);
            },
            .optional => |child| {
                if (b.* != .optional) return error.TypeMismatch;
                try self.unify(child, b.optional);
            },
            .error_union => |ae| {
                if (b.* != .error_union) return error.TypeMismatch;
                try self.unify(ae.error_type, b.error_union.error_type);
                try self.unify(ae.value_type, b.error_union.value_type);
            },
            .error_value => |name| {
                if (b.* != .error_value or !std.mem.eql(u8, name, b.error_value)) {
                    return error.TypeMismatch;
                }
            },
            .function => |af| {
                if (b.* != .function or af.params.len != b.function.params.len) {
                    return error.TypeMismatch;
                }
                for (af.params, b.function.params) |x, y| try self.unify(x, y);
                try self.unify(af.result, b.function.result);
            },
            .tuple => |items| {
                if (b.* != .tuple or items.len != b.tuple.len) return error.TypeMismatch;
                for (items, b.tuple) |x, y| try self.unify(x, y);
            },
            .array => |aa| {
                if (b.* != .array) return error.TypeMismatch;
                if (aa.length != null and b.array.length != null and aa.length.? != b.array.length.?) {
                    return error.TypeMismatch;
                }
                if (aa.columns != null and b.array.columns != null and aa.columns.? != b.array.columns.?) {
                    return error.TypeMismatch;
                }
                try self.unify(aa.element, b.array.element);
            },
            .map => |am| {
                if (b.* != .map) return error.TypeMismatch;
                try self.unify(am.key, b.map.key);
                try self.unify(am.value, b.map.value);
            },
            .range => |child| {
                if (b.* != .range) return error.TypeMismatch;
                try self.unify(child, b.range);
            },
            .query => |q| {
                if (b.* != .query) return error.TypeMismatch;
                try self.unify(q.element, b.query.element);
            },
            .resource => |child| {
                if (b.* != .resource) return error.TypeMismatch;
                try self.unify(child, b.resource);
            },
            .generic => |ag| {
                if (b.* != .generic or ag.index != b.generic.index or
                    !std.mem.eql(u8, ag.name, b.generic.name))
                {
                    return error.TypeMismatch;
                }
            },
            .unknown, .never => unreachable,
            .variable => unreachable,
        }
    }

    fn linkVars(self: *TypeStore, a: *Var, b: *Var) UnifyError!void {
        if (a == b) return;
        if (!kindsCompatible(a.kind, b.kind)) return error.TypeMismatch;
        if (a.kind == .any and b.kind != .any) {
            a.binding = try self.make(.{ .variable = b });
        } else if (b.kind == .any and a.kind != .any) {
            b.binding = try self.make(.{ .variable = a });
        } else {
            a.binding = try self.make(.{ .variable = b });
        }
    }

    fn kindsCompatible(a: VarKind, b: VarKind) bool {
        if (a == .any or b == .any) return true;
        return a == b;
    }

    fn bindVar(self: *TypeStore, variable: *Var, value: *Type) UnifyError!void {
        if (value.* == .variable) {
            if (value.variable == variable) return;
            return self.linkVars(variable, value.variable);
        }
        if (!kindAccepts(variable.kind, value)) return error.TypeMismatch;
        if (self.occurs(variable, value)) return error.Occurs;
        variable.binding = value;
    }

    fn kindAccepts(kind: VarKind, value: *Type) bool {
        const resolved = value;
        return switch (kind) {
            .any => true,
            .integer => switch (resolved.*) {
                .int => true,
                .variable => resolved.variable.kind != .float,
                .unknown, .never => true,
                else => false,
            },
            .float => switch (resolved.*) {
                .float => true,
                .variable => resolved.variable.kind != .integer,
                .unknown, .never => true,
                else => false,
            },
        };
    }

    fn occurs(self: *TypeStore, variable: *Var, value: *Type) bool {
        const ty = self.resolve(value);
        return switch (ty.*) {
            .variable => |other| other == variable or
                (other.binding != null and self.occurs(variable, other.binding.?)),
            .reference => |r| self.occurs(variable, r.child),
            .box, .raw_pointer, .optional, .range, .resource => |child| self.occurs(variable, child),
            .error_union => |e| self.occurs(variable, e.error_type) or self.occurs(variable, e.value_type),
            .function => |f| blk: {
                for (f.params) |param| if (self.occurs(variable, param)) break :blk true;
                break :blk self.occurs(variable, f.result);
            },
            .tuple => |items| blk: {
                for (items) |item| if (self.occurs(variable, item)) break :blk true;
                break :blk false;
            },
            .array => |a| self.occurs(variable, a.element),
            .map => |m| self.occurs(variable, m.key) or self.occurs(variable, m.value),
            .query => |q| self.occurs(variable, q.element),
            .named => |n| blk: {
                for (n.args) |arg| if (self.occurs(variable, arg)) break :blk true;
                break :blk false;
            },
            else => false,
        };
    }

    /// Directional check used for assignment, arguments, and returns.
    pub fn assignable(self: *TypeStore, expected: *Type, actual: *Type) UnifyError!void {
        const e = self.resolve(expected);
        const a = self.resolve(actual);
        if (e.* == .unknown or a.* == .unknown or a.* == .never) return;
        if (e.* == .reference and a.* == .reference) {
            if (e.reference.mutable and !a.reference.mutable) return error.TypeMismatch;
            return self.assignable(e.reference.child, a.reference.child);
        }
        if (e.* == .optional and a.* == .optional) {
            return self.assignable(e.optional, a.optional);
        }
        if (e.* == .error_union and a.* == .error_value) {
            const error_type = self.resolve(e.error_union.error_type);
            return switch (error_type.*) {
                .unknown => {},
                .named => |n| if (!std.mem.startsWith(u8, a.error_value, n.name)) return error.TypeMismatch,
                .error_value => |n| if (!std.mem.eql(u8, n, a.error_value)) return error.TypeMismatch,
                else => return error.TypeMismatch,
            };
        }
        return self.unify(e, a);
    }

    pub fn substitute(self: *TypeStore, ty: *Type, args: []?*Type) UnifyError!*Type {
        const resolved = self.resolve(ty);
        return switch (resolved.*) {
            .generic => |g| blk: {
                if (g.index < args.len and args[g.index] != null) break :blk args[g.index].?;
                break :blk resolved;
            },
            .reference => |r| self.make(.{ .reference = .{
                .mutable = r.mutable,
                .child = try self.substitute(r.child, args),
            } }),
            .box => |child| self.make(.{ .box = try self.substitute(child, args) }),
            .raw_pointer => |child| self.make(.{ .raw_pointer = try self.substitute(child, args) }),
            .optional => |child| self.make(.{ .optional = try self.substitute(child, args) }),
            .error_union => |e| self.make(.{ .error_union = .{
                .error_type = try self.substitute(e.error_type, args),
                .value_type = try self.substitute(e.value_type, args),
            } }),
            .function => |f| blk: {
                const params = try self.allocator.alloc(*Type, f.params.len);
                for (f.params, 0..) |param, i| params[i] = try self.substitute(param, args);
                break :blk self.make(.{ .function = .{
                    .params = params,
                    .result = try self.substitute(f.result, args),
                } });
            },
            .tuple => |items| blk: {
                const out = try self.allocator.alloc(*Type, items.len);
                for (items, 0..) |item, i| out[i] = try self.substitute(item, args);
                break :blk self.make(.{ .tuple = out });
            },
            .array => |a| self.make(.{ .array = .{
                .element = try self.substitute(a.element, args),
                .length = a.length,
                .columns = a.columns,
            } }),
            .map => |m| self.make(.{ .map = .{
                .key = try self.substitute(m.key, args),
                .value = try self.substitute(m.value, args),
            } }),
            .range => |child| self.make(.{ .range = try self.substitute(child, args) }),
            .query => |q| self.make(.{ .query = .{
                .element = try self.substitute(q.element, args),
            } }),
            .resource => |child| self.make(.{ .resource = try self.substitute(child, args) }),
            .named => |n| blk: {
                const out = try self.allocator.alloc(*Type, n.args.len);
                for (n.args, 0..) |arg, i| out[i] = try self.substitute(arg, args);
                break :blk self.make(.{ .named = .{ .name = n.name, .args = out } });
            },
            else => resolved,
        };
    }

    pub fn typeName(self: *TypeStore, ty: *Type) ![]const u8 {
        var out = std.ArrayList(u8).empty;
        try self.formatType(&out, ty);
        return out.toOwnedSlice(self.allocator);
    }

    fn formatType(self: *TypeStore, out: *std.ArrayList(u8), ty: *Type) !void {
        const resolved = self.resolve(ty);
        switch (resolved.*) {
            .unit => try out.appendSlice(self.allocator, "()"),
            .bool => try out.appendSlice(self.allocator, "bool"),
            .string => try out.appendSlice(self.allocator, "str"),
            .never => try out.appendSlice(self.allocator, "!"),
            .unknown => try out.appendSlice(self.allocator, "_"),
            .int => |k| try out.appendSlice(self.allocator, @tagName(k)),
            .float => |k| try out.appendSlice(self.allocator, @tagName(k)),
            .variable => |v| try out.print(self.allocator, "_{d}", .{v.id}),
            .named => |n| {
                try out.appendSlice(self.allocator, n.name);
                if (n.args.len > 0) {
                    try out.appendSlice(self.allocator, "<");
                    for (n.args, 0..) |arg, i| {
                        if (i != 0) try out.appendSlice(self.allocator, ", ");
                        try self.formatType(out, arg);
                    }
                    try out.appendSlice(self.allocator, ">");
                }
            },
            .reference => |r| {
                try out.appendSlice(self.allocator, if (r.mutable) "&mut " else "&");
                try self.formatType(out, r.child);
            },
            .box => |child| {
                try out.appendSlice(self.allocator, "*");
                try self.formatType(out, child);
            },
            .raw_pointer => |child| {
                try out.appendSlice(self.allocator, "*raw ");
                try self.formatType(out, child);
            },
            .optional => |child| {
                try out.appendSlice(self.allocator, "?");
                try self.formatType(out, child);
            },
            .error_union => |e| {
                try self.formatType(out, e.error_type);
                try out.appendSlice(self.allocator, "!");
                try self.formatType(out, e.value_type);
            },
            .error_value => |name| {
                try out.appendSlice(self.allocator, "!");
                try out.appendSlice(self.allocator, name);
            },
            .function => |f| {
                try out.appendSlice(self.allocator, "(");
                for (f.params, 0..) |param, i| {
                    if (i != 0) try out.appendSlice(self.allocator, ", ");
                    try self.formatType(out, param);
                }
                try out.appendSlice(self.allocator, ") -> ");
                try self.formatType(out, f.result);
            },
            .tuple => |items| {
                try out.appendSlice(self.allocator, "(");
                for (items, 0..) |item, i| {
                    if (i != 0) try out.appendSlice(self.allocator, ", ");
                    try self.formatType(out, item);
                }
                try out.appendSlice(self.allocator, ")");
            },
            .array => |a| {
                try out.appendSlice(self.allocator, "[");
                try self.formatType(out, a.element);
                if (a.length) |length| {
                    try out.print(self.allocator, "; {d}", .{length});
                    if (a.columns) |columns| try out.print(self.allocator, ", {d}", .{columns});
                }
                try out.appendSlice(self.allocator, "]");
            },
            .map => |m| {
                try out.appendSlice(self.allocator, "map[");
                try self.formatType(out, m.key);
                try out.appendSlice(self.allocator, ", ");
                try self.formatType(out, m.value);
                try out.appendSlice(self.allocator, "]");
            },
            .range => |child| {
                try out.appendSlice(self.allocator, "range<");
                try self.formatType(out, child);
                try out.appendSlice(self.allocator, ">");
            },
            .query => |q| {
                try out.appendSlice(self.allocator, "query<");
                try self.formatType(out, q.element);
                try out.appendSlice(self.allocator, ">");
            },
            .resource => |child| {
                try out.appendSlice(self.allocator, "res ");
                try self.formatType(out, child);
            },
            .generic => |g| try out.appendSlice(self.allocator, g.name),
        }
    }

    pub fn builtin(name: []const u8) ?Type {
        const ints = std.StaticStringMap(IntKind).initComptime(.{
            .{ "i8", .i8 },   .{ "i16", .i16 },   .{ "i32", .i32 },
            .{ "i64", .i64 }, .{ "i128", .i128 }, .{ "isize", .isize },
            .{ "u8", .u8 },   .{ "u16", .u16 },   .{ "u32", .u32 },
            .{ "u64", .u64 }, .{ "u128", .u128 }, .{ "usize", .usize },
        });
        if (ints.get(name)) |kind| return .{ .int = kind };
        const floats = std.StaticStringMap(FloatKind).initComptime(.{
            .{ "f16", .f16 }, .{ "f32", .f32 }, .{ "f64", .f64 }, .{ "f128", .f128 },
        });
        if (floats.get(name)) |kind| return .{ .float = kind };
        if (std.mem.eql(u8, name, "bool")) return .bool;
        if (std.mem.eql(u8, name, "str")) return .string;
        if (std.mem.eql(u8, name, "String")) return .string;
        return null;
    }
};

test "unifies numeric variables and resolves defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = TypeStore.init(arena.allocator());
    const int = try store.integerVar();
    const i32_type = try store.make(.{ .int = .i32 });
    try store.unify(int, i32_type);
    try std.testing.expect(store.resolve(int).* == .int);
}

test "refuses mutable-to-shared unification but assignment allows it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = TypeStore.init(arena.allocator());
    const i32_type = try store.make(.{ .int = .i32 });
    const shared = try store.make(.{ .reference = .{ .mutable = false, .child = i32_type } });
    const mutable = try store.make(.{ .reference = .{ .mutable = true, .child = i32_type } });
    try std.testing.expectError(error.TypeMismatch, store.unify(shared, mutable));
    try store.assignable(shared, mutable);
}
