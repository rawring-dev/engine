//! Program model: collects declarations from every parsed e7 module so the
//! lowering pass can resolve names, field order, generic substitutions, and
//! resource types before emitting any Slang.

const std = @import("std");
const compiler = @import("compiler");
const ast = compiler.ast;
const astx = @import("astx.zig");

pub const ModuleInfo = struct {
    /// Slang module name; also the output file stem.
    name: []const u8,
    source: []const u8,
    ast: *const compiler.parser.Ast,
    is_root: bool = false,
};

pub const StructInfo = struct {
    module: []const u8,
    qualified: []const u8,
    decl: *const ast.StructDecl,
    is_public: bool,
};

pub const EnumInfo = struct {
    module: []const u8,
    qualified: []const u8,
    decl: *const ast.EnumDecl,
    is_public: bool,
};

pub const TraitInfo = struct {
    module: []const u8,
    qualified: []const u8,
    decl: *const ast.TraitDecl,
    is_public: bool,
};

pub const FunctionInfo = struct {
    module: []const u8,
    qualified: []const u8,
    decl: *const ast.FunctionDecl,
    is_public: bool,
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    modules: []const ModuleInfo,

    structs: std.StringHashMapUnmanaged(*const StructInfo) = .empty,
    enums: std.StringHashMapUnmanaged(*const EnumInfo) = .empty,
    traits: std.StringHashMapUnmanaged(*const TraitInfo) = .empty,
    functions: std.StringHashMapUnmanaged(*const FunctionInfo) = .empty,

    external_modules: std.StringHashMapUnmanaged(void) = .empty,
    inline_modules: std.StringHashMapUnmanaged(void) = .empty,

    /// Canonical types used by expression inference.
    ty_i32: *ast.Type = undefined,
    ty_f32: *ast.Type = undefined,
    ty_bool: *ast.Type = undefined,

    pub fn collect(
        allocator: std.mem.Allocator,
        modules: []const ModuleInfo,
    ) !Program {
        var program = Program{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .modules = modules,
        };
        errdefer program.deinit();

        program.ty_i32 = try program.makePathType("i32");
        program.ty_f32 = try program.makePathType("f32");
        program.ty_bool = try program.makePathType("bool");

        for (modules) |module| {
            try program.collectItems(module.name, "", module.ast.module.items);
        }
        return program;
    }

    pub fn deinit(self: *Program) void {
        self.structs.deinit(self.allocator);
        self.enums.deinit(self.allocator);
        self.traits.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        self.external_modules.deinit(self.allocator);
        self.inline_modules.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    fn collectItems(
        self: *Program,
        module_name: []const u8,
        prefix: []const u8,
        items: []*ast.Item,
    ) !void {
        for (items) |item| {
            switch (item.kind) {
                .mod => |mod_decl| {
                    if (mod_decl.items) |nested| {
                        try self.inline_modules.put(self.allocator, mod_decl.name, {});
                        const child_prefix = try self.joinPrefix(prefix, mod_decl.name);
                        try self.collectItems(module_name, child_prefix, nested);
                    } else {
                        try self.external_modules.put(self.allocator, mod_decl.name, {});
                    }
                },
                .struct_decl => {
                    const qualified_name = try self.qualified(module_name, prefix, item.kind.struct_decl.name);
                    const info = try self.arena.allocator().create(StructInfo);
                    info.* = .{
                        .module = module_name,
                        .qualified = qualified_name,
                        .decl = &item.kind.struct_decl,
                        .is_public = astx.isPublic(item.visibility),
                    };
                    try self.structs.put(self.allocator, qualified_name, info);
                    if (!self.structs.contains(item.kind.struct_decl.name)) {
                        try self.structs.put(self.allocator, item.kind.struct_decl.name, info);
                    }
                },
                .enum_decl => {
                    const qualified_name = try self.qualified(module_name, prefix, item.kind.enum_decl.name);
                    const info = try self.arena.allocator().create(EnumInfo);
                    info.* = .{
                        .module = module_name,
                        .qualified = qualified_name,
                        .decl = &item.kind.enum_decl,
                        .is_public = astx.isPublic(item.visibility),
                    };
                    try self.enums.put(self.allocator, qualified_name, info);
                    if (!self.enums.contains(item.kind.enum_decl.name)) {
                        try self.enums.put(self.allocator, item.kind.enum_decl.name, info);
                    }
                },
                .trait_decl => {
                    const qualified_name = try self.qualified(module_name, prefix, item.kind.trait_decl.name);
                    const info = try self.arena.allocator().create(TraitInfo);
                    info.* = .{
                        .module = module_name,
                        .qualified = qualified_name,
                        .decl = &item.kind.trait_decl,
                        .is_public = astx.isPublic(item.visibility),
                    };
                    try self.traits.put(self.allocator, qualified_name, info);
                    if (!self.traits.contains(item.kind.trait_decl.name)) {
                        try self.traits.put(self.allocator, item.kind.trait_decl.name, info);
                    }
                },
                .function => {
                    const qualified_name = try self.qualified(module_name, prefix, item.kind.function.name);
                    const info = try self.arena.allocator().create(FunctionInfo);
                    info.* = .{
                        .module = module_name,
                        .qualified = qualified_name,
                        .decl = &item.kind.function,
                        .is_public = astx.isPublic(item.visibility),
                    };
                    try self.functions.put(self.allocator, qualified_name, info);
                    if (!self.functions.contains(item.kind.function.name)) {
                        try self.functions.put(self.allocator, item.kind.function.name, info);
                    }
                },
                else => {},
            }
        }
    }

    fn joinPrefix(self: *Program, prefix: []const u8, name: []const u8) ![]const u8 {
        if (prefix.len == 0) return name;
        return std.fmt.allocPrint(self.arena.allocator(), "{s}::{s}", .{ prefix, name });
    }

    fn qualified(self: *Program, module_name: []const u8, prefix: []const u8, name: []const u8) ![]const u8 {
        if (prefix.len == 0) {
            return std.fmt.allocPrint(self.arena.allocator(), "{s}::{s}", .{ module_name, name });
        }
        return std.fmt.allocPrint(self.arena.allocator(), "{s}::{s}::{s}", .{ module_name, prefix, name });
    }

    pub fn findStruct(self: *const Program, name: []const u8) ?*const StructInfo {
        return self.structs.get(name);
    }

    pub fn findStructByPath(self: *const Program, path: ast.Path) ?*const StructInfo {
        if (path.segments.len == 0) return null;
        return self.findStruct(astx.pathLast(path));
    }

    pub fn findEnum(self: *const Program, name: []const u8) ?*const EnumInfo {
        return self.enums.get(name);
    }

    pub fn findEnumByPath(self: *const Program, path: ast.Path) ?*const EnumInfo {
        if (path.segments.len == 0) return null;
        return self.findEnum(astx.pathLast(path));
    }

    pub fn findTrait(self: *const Program, name: []const u8) ?*const TraitInfo {
        return self.traits.get(name);
    }

    pub fn findFunction(self: *const Program, name: []const u8) ?*const FunctionInfo {
        return self.functions.get(name);
    }

    pub fn findFunctionByPath(self: *const Program, path: ast.Path) ?*const FunctionInfo {
        if (path.segments.len == 0) return null;
        return self.findFunction(astx.pathLast(path));
    }

    pub fn isExternalModule(self: *const Program, name: []const u8) bool {
        return self.external_modules.contains(name);
    }

    pub fn hasModule(self: *const Program, name: []const u8) bool {
        for (self.modules) |module| {
            if (std.mem.eql(u8, module.name, name)) return true;
        }
        return false;
    }

    pub fn isInlineModule(self: *const Program, name: []const u8) bool {
        return self.inline_modules.contains(name);
    }

    pub fn makePathType(self: *Program, name: []const u8) !*ast.Type {
        const allocator = self.arena.allocator();
        const segments = try allocator.alloc(ast.PathSegment, 1);
        segments[0] = .{ .name = name, .args = &.{} };
        const ty = try allocator.create(ast.Type);
        ty.* = .{ .path = .{ .segments = segments } };
        return ty;
    }

    pub fn makePathTypeFromPath(self: *Program, path: ast.Path) !*ast.Type {
        const allocator = self.arena.allocator();
        const ty = try allocator.create(ast.Type);
        ty.* = .{ .path = path };
        return ty;
    }

    pub fn makeVectorType(self: *Program, element: *ast.Type, length: i64) !*ast.Type {
        const allocator = self.arena.allocator();
        const length_expr = try allocator.create(ast.Expr);
        length_expr.* = .{ .int = length };
        const ty = try allocator.create(ast.Type);
        ty.* = .{ .array = .{ .element = element, .length = length_expr } };
        return ty;
    }

    pub fn makeMatrixType(
        self: *Program,
        element: *ast.Type,
        rows: i64,
        columns: i64,
    ) !*ast.Type {
        const allocator = self.arena.allocator();
        const rows_expr = try allocator.create(ast.Expr);
        rows_expr.* = .{ .int = rows };
        const columns_expr = try allocator.create(ast.Expr);
        columns_expr.* = .{ .int = columns };
        const ty = try allocator.create(ast.Type);
        ty.* = .{ .array = .{
            .element = element,
            .length = rows_expr,
            .columns = columns_expr,
        } };
        return ty;
    }

    pub fn substitutionFor(self: *Program, info: *const StructInfo, path: ast.Path) !std.StringHashMapUnmanaged(*ast.Type) {
        var subst: std.StringHashMapUnmanaged(*ast.Type) = .empty;
        const args = if (path.segments.len == 0) &.{} else path.segments[path.segments.len - 1].args;
        if (args.len == 0) return subst;
        for (info.decl.generics, 0..) |generic, i| {
            if (i >= args.len) break;
            try subst.put(self.allocator, generic.name, args[i]);
        }
        return subst;
    }

    /// Substitute generic parameter names in `ty` with concrete AST types.
    /// The result is allocated in the program arena.
    pub fn substituteType(
        self: *Program,
        ty: *const ast.Type,
        subst: *const std.StringHashMapUnmanaged(*ast.Type),
    ) !*ast.Type {
        if (subst.count() == 0) return @constCast(ty);
        const allocator = self.arena.allocator();
        switch (ty.*) {
            .path => |path| {
                if (path.segments.len == 1) {
                    if (subst.get(path.segments[0].name)) |replacement| return replacement;
                    return @constCast(ty);
                }
                var changed = false;
                const segments = try allocator.alloc(ast.PathSegment, path.segments.len);
                for (path.segments, 0..) |segment, i| {
                    segments[i] = segment;
                    if (segment.args.len > 0) {
                        const args = try allocator.alloc(*ast.Type, segment.args.len);
                        for (segment.args, 0..) |arg, j| {
                            args[j] = try self.substituteType(arg, subst);
                            if (args[j] != arg) changed = true;
                        }
                        segments[i].args = args;
                    }
                }
                if (!changed) return @constCast(ty);
                const result = try allocator.create(ast.Type);
                result.* = .{ .path = .{ .segments = segments } };
                return result;
            },
            .array => |array| {
                const element = try self.substituteType(array.element, subst);
                if (element == array.element) return @constCast(ty);
                const result = try allocator.create(ast.Type);
                result.* = .{ .array = .{
                    .element = element,
                    .length = array.length,
                    .columns = array.columns,
                } };
                return result;
            },
            .reference => |reference| {
                const child = try self.substituteType(reference.child, subst);
                if (child == reference.child) return @constCast(ty);
                const result = try allocator.create(ast.Type);
                result.* = .{ .reference = .{ .mutable = reference.mutable, .child = child } };
                return result;
            },
            .box => |child| {
                const replaced = try self.substituteType(child, subst);
                if (replaced == child) return @constCast(ty);
                const result = try allocator.create(ast.Type);
                result.* = .{ .box = replaced };
                return result;
            },
            .optional => |child| {
                const replaced = try self.substituteType(child, subst);
                if (replaced == child) return @constCast(ty);
                const result = try allocator.create(ast.Type);
                result.* = .{ .optional = replaced };
                return result;
            },
            .inferred_error => |child| {
                const replaced = try self.substituteType(child, subst);
                if (replaced == child) return @constCast(ty);
                const result = try allocator.create(ast.Type);
                result.* = .{ .inferred_error = replaced };
                return result;
            },
            else => return @constCast(ty),
        }
    }
};
