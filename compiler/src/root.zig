pub const syntax = @import("syntax.zig");
pub const ast = @import("ast.zig");
pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const semantic = @import("semantic.zig");
pub const iterative = @import("iterative.zig");
pub const bytecode = @import("bytecode.zig");
pub const codegen = @import("codegen.zig");
pub const pipeline = @import("pipeline.zig");
pub const compile = pipeline.compile;
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
}
