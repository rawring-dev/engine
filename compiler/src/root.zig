pub const syntax = @import("syntax.zig");
pub const ast = @import("ast.zig");
pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const semantic = @import("semantic.zig");
pub const iterative = @import("iterative.zig");
pub const bytecode = @import("bytecode.zig");
pub const codegen = @import("codegen.zig");
pub const pipeline = @import("pipeline.zig");
pub const native_methods = @import("native_methods.zig");
pub const intrinsic_audit = @import("intrinsic_audit.zig");
/// Compile a single source buffer.
pub const compile = pipeline.compile;
/// Compile a multi-file project: external `mod name` references load sibling
/// `name.e7` files and are analyzed as prefixed modules (`ui::Ui`).
pub const compileProject = pipeline.compileProject;
/// Load every file of a project without compiling it (paths + sources are
/// exposed for hosts that register ECS metadata themselves).
pub const loadProject = pipeline.loadProject;
pub const Project = pipeline.Project;
pub const ProjectFile = pipeline.ProjectFile;
pub const CompileResult = pipeline.CompileResult;

test {
    _ = syntax;
    _ = ast;
    _ = lexer;
    _ = parser;
    _ = semantic;
    _ = iterative;
    _ = bytecode;
    _ = codegen;
    _ = pipeline;
    _ = native_methods;
    _ = intrinsic_audit;
}
