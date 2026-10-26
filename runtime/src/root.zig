//! Runtime: execution support for the engine.
//!
//! The runtime is the integration layer: it re-exports the scheduler's
//! numerical machinery, the compiler's front-end/iterative-pipeline API, and
//! owns the LLVM ORC JIT used to execute generated IR.

const std = @import("std");

pub const scheduler = @import("scheduler");
pub const compiler = @import("compiler");
pub const orc = @import("orc.zig");
pub const bytecode_ir = @import("bytecode_ir.zig");
pub const task = @import("task.zig");
pub const lease = @import("lease.zig");
pub const aggregate = @import("aggregate.zig");
pub const ecs = @import("ecs.zig");
pub const engine = @import("engine.zig");
pub const float = @import("float.zig");
pub const json = @import("json.zig");
pub const intrinsics = @import("intrinsics.zig");

pub const window = @import("ffi/window.zig");
pub const vulkan = @import("ffi/vulkan.zig");
pub const renderer = @import("ffi/renderer.zig");
pub const filesystem = @import("ffi/fs.zig");
pub const net = @import("ffi/net.zig");
pub const http = @import("ffi/http.zig");
pub const quic = @import("ffi/quic.zig");
pub const webrtc = @import("ffi/webrtc.zig");
pub const stdio = @import("ffi/stdio.zig");

test "runtime imports both sibling projects" {
    try std.testing.expect(@hasDecl(scheduler, "lbfgs"));
    try std.testing.expect(@hasDecl(scheduler, "spectral"));
    try std.testing.expect(@hasDecl(compiler, "lexer"));
    try std.testing.expect(@hasDecl(compiler, "parser"));
    try std.testing.expect(@hasDecl(compiler, "iterative"));
    try std.testing.expect(@hasDecl(compiler, "semantic"));
    try std.testing.expect(@hasDecl(compiler, "bytecode"));
    try std.testing.expect(@hasDecl(compiler, "pipeline"));
}

test "runtime exercises sibling implementations and native links" {
    var optimized = try compiler.iterative.optimize(
        std.testing.allocator,
        "define i32 @seven() { ret i32 7 }",
        .{ .max_iterations = 2 },
    );
    defer optimized.deinit();
    try std.testing.expect(std.mem.indexOf(u8, optimized.ir, "define i32 @seven") != null);

    const a = [_]f64{2};
    const b = [_]f64{6};
    const x = try scheduler.lapack.solve(std.testing.allocator, &a, &b, 1, 1);
    defer std.testing.allocator.free(x);
    try std.testing.expectApproxEqAbs(@as(f64, 3), x[0], 1e-12);
}

test {
    _ = orc;
    _ = bytecode_ir;
    _ = ecs;
    _ = engine;
    _ = float;
    _ = json;
}

test "compiles source to bytecode and executes it through LLJIT" {
    var compiled = try compiler.pipeline.compile(
        std.testing.allocator,
        \\add <- (a: i32, b: i32) -> i32 = a + b
        \\fact <- (n: i32) -> i32:
        \\    m := n
        \\    r := 1
        \\    while m > 0:
        \\        r = r * m
        \\        m = m - 1
        \\    r
    ,
        .{},
    );
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());

    const serialized = try compiler.bytecode.encode(std.testing.allocator, &compiled.bytecode);
    defer std.testing.allocator.free(serialized);

    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecodeBytes(serialized, "compiler-pipeline");

    const Add = *const fn (i64, i64) callconv(.c) i64;
    const Fact = *const fn (i64) callconv(.c) i64;
    const add = try jit.get(Add, "add");
    const fact = try jit.get(Fact, "fact");
    try std.testing.expectEqual(@as(i64, 9), add(4, 5));
    try std.testing.expectEqual(@as(i64, 120), fact(5));
}

test "JIT executes compiled control flow" {
    var compiled = try compiler.pipeline.compile(
        std.testing.allocator,
        \\choose <- (x: i32) -> i32 = if x > 0: 1 else: 2
        \\sum <- (n: i32) -> i32:
        \\    s := 0
        \\    for i in 0..n:
        \\        s = s + i
        \\    s
        \\loop_sum <- (n: i32) -> i32:
        \\    i := 0
        \\    s := 0
        \\    loop:
        \\        if i >= n:
        \\            break
        \\        s = s + i
        \\        i = i + 1
        \\    s
        \\match_int <- (x: i32) -> i32:
        \\    match x:
        \\        0: 10
        \\        _: 20
        \\both <- (x: i32) -> i32 = if x > 0 and x < 10: 1 else: 0
        \\shadow <- () -> i32:
        \\    x := 1
        \\    if true:
        \\        x := 2
        \\    x
        \\skip <- (n: i32) -> i32:
        \\    s := 0
        \\    for i in 0..n:
        \\        if i == 2:
        \\            cont
        \\        s = s + i
        \\    s
    ,
        .{},
    );
    defer compiled.deinit();

    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "control-flow");

    const Unary = *const fn (i64) callconv(.c) i64;
    const choose = try jit.get(Unary, "choose");
    const sum = try jit.get(Unary, "sum");
    const loop_sum = try jit.get(Unary, "loop_sum");
    const match_int = try jit.get(Unary, "match_int");
    const both = try jit.get(Unary, "both");
    const shadow = try jit.get(Unary, "shadow");
    const skip = try jit.get(Unary, "skip");
    try std.testing.expectEqual(@as(i64, 1), choose(5));
    try std.testing.expectEqual(@as(i64, 2), choose(-1));
    try std.testing.expectEqual(@as(i64, 10), sum(5));
    try std.testing.expectEqual(@as(i64, 10), loop_sum(5));
    try std.testing.expectEqual(@as(i64, 10), match_int(0));
    try std.testing.expectEqual(@as(i64, 20), match_int(7));
    try std.testing.expectEqual(@as(i64, 1), both(5));
    try std.testing.expectEqual(@as(i64, 0), both(20));
    try std.testing.expectEqual(@as(i64, 1), shadow(0));
    try std.testing.expectEqual(@as(i64, 8), skip(5));
}

test {
    _ = intrinsics;
    _ = @import("jit_tests.zig");
}

test "JIT executes compiled async functions" {
    var compiled = try compiler.pipeline.compile(
        std.testing.allocator,
        \\double <- async (x: i32) -> i32 = x * 2
        \\inline := async (x: i32) -> i32 = x + 1
        \\inline_run <- async () -> i32:
        \\    value := (await inline(41))?
        \\    value
        \\pair <- async () -> i32:
        \\    value := (await double(21))?
        \\    value
        \\spawned <- async () -> i32:
        \\    task := spawn double(21)
        \\    value := (await task)?
        \\    value
        \\Update <- trigger
        \\    amount: i32
        \\@trigger(Update)
        \\Apply <- sys():
        \\    await double(1)
        \\triggered <- async () -> i32:
        \\    await Update(10)
        \\    7
        \\triggered_twice <- async () -> i32:
        \\    a := spawn Update(1)
        \\    b := spawn Update(2)
        \\    await a
        \\    await b
        \\    9
    ,
        .{},
    );
    defer compiled.deinit();

    const serialized = try compiler.bytecode.encode(std.testing.allocator, &compiled.bytecode);
    defer std.testing.allocator.free(serialized);

    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecodeBytes(serialized, "async-pipeline");

    const InlineRun = *const fn () callconv(.c) i64;
    const inline_run = try jit.get(InlineRun, "inline_run");
    try std.testing.expectEqual(@as(i64, 42), task.e7_task_await(inline_run()));

    const Pair = *const fn () callconv(.c) i64;
    const pair = try jit.get(Pair, "pair");
    const task_handle = pair();
    try std.testing.expect(task_handle != 0);
    try std.testing.expectEqual(@as(i64, 42), task.e7_task_await(task_handle));

    const Spawned = *const fn () callconv(.c) i64;
    const spawned = try jit.get(Spawned, "spawned");
    const spawned_task = spawned();
    try std.testing.expectEqual(@as(i64, 42), task.e7_task_await(spawned_task));

    const Triggered = *const fn () callconv(.c) i64;
    const triggered = try jit.get(Triggered, "triggered");
    const triggered_task = triggered();
    try std.testing.expectEqual(@as(i64, 7), task.e7_task_await(triggered_task));

    const TriggeredTwice = *const fn () callconv(.c) i64;
    const triggered_twice = try jit.get(TriggeredTwice, "triggered_twice");
    try std.testing.expectEqual(@as(i64, 9), task.e7_task_await(triggered_twice()));
}

test "canceled lazy tasks await to a cancellation result" {
    var compiled = try compiler.pipeline.compile(
        std.testing.allocator,
        \\double <- async (x: i32) -> i32 = x * 2
        \\run <- async () -> i32:
        \\    task := double(21)
        \\    cancel &mut task
        \\    await task
    ,
        .{},
    );
    defer compiled.deinit();
    const serialized = try compiler.bytecode.encode(std.testing.allocator, &compiled.bytecode);
    defer std.testing.allocator.free(serialized);

    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecodeBytes(serialized, "async-cancel");
    const Run = *const fn () callconv(.c) i64;
    const run = try jit.get(Run, "run");
    const handle = run();
    try std.testing.expectEqual(task.cancelled_result, task.e7_task_await(handle));
}

test "JIT lowers struct aggregates and fields" {
    var compiled = try compiler.pipeline.compile(
        std.testing.allocator,
        \\Point <- struct
        \\    x: i32
        \\    y: i32
        \\make <- () -> Point = Point { x: 2, y: 3 }
        \\sum <- () -> i32:
        \\    p := make()
        \\    p.x + p.y
        \\set_x <- () -> i32:
        \\    p := make()
        \\    p.x = 7
        \\    p.x
        \\borrow_local <- () -> i32:
        \\    x := 5
        \\    p := &x
        \\    *p
        \\write_vec <- () -> i32:
        \\    xs := [1, 2, 3]
        \\    xs[1] = 9
        \\    xs[1]
    ,
        .{},
    );
    defer compiled.deinit();
    const serialized = try compiler.bytecode.encode(std.testing.allocator, &compiled.bytecode);
    defer std.testing.allocator.free(serialized);
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecodeBytes(serialized, "structs");
    const Sum = *const fn () callconv(.c) i64;
    try std.testing.expectEqual(@as(i64, 5), (try jit.get(Sum, "sum"))());
    try std.testing.expectEqual(@as(i64, 7), (try jit.get(Sum, "set_x"))());
    try std.testing.expectEqual(@as(i64, 5), (try jit.get(Sum, "borrow_local"))());
    try std.testing.expectEqual(@as(i64, 9), (try jit.get(Sum, "write_vec"))());
}

test "JIT lowers strings, vectors, matrices, maps, and unsafe raw pointers" {
    var compiled = try compiler.pipeline.compile(
        std.testing.allocator,
        \\text <- () -> str = "ab" + "cd"
        \\vec <- () -> [i32; 3] = [1, 2, 3]
        \\dot <- () -> i32 = [1, 2, 3] * [4, 5, 6]
        \\matmul <- () -> [i32; 2, 2] = [[1, 2], [3, 4]] * [[5, 6], [7, 8]]
        \\lookup <- (m: map[i32, i32]) -> i32 = m[7]
        \\mapl <- () -> map[i32, i32] = map[i32, i32] { 1: 10, 2: 20 }
        \\strlookup <- (m: map[str, i32]) -> i32 = m["key"]
        \\strmap <- () -> map[str, i32] = map[str, i32] { "key": 77 }
        \\read <- (p: *raw i32) -> i32:
        \\    unsafe:
        \\        out: i32
        \\        out = *p
        \\        ret out
        \\advance <- (p: *raw i32) -> i32:
        \\    unsafe:
        \\        q := p + 1
        \\        ret *q
    ,
        .{},
    );
    defer compiled.deinit();
    const serialized = try compiler.bytecode.encode(std.testing.allocator, &compiled.bytecode);
    defer std.testing.allocator.free(serialized);
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecodeBytes(serialized, "aggregates");

    const Text = *const fn () callconv(.c) i64;
    const text = (try jit.get(Text, "text"))();
    try std.testing.expectEqual(@as(i64, 4), aggregate.e7_str_len(text));
    const text_bytes: [*]const u8 = @ptrFromInt(@as(usize, @intCast(text + 8)));
    try std.testing.expectEqualStrings("abcd", text_bytes[0..4]);

    const Vec = *const fn () callconv(.c) i64;
    const vec = (try jit.get(Vec, "vec"))();
    try std.testing.expectEqual(@as(i64, 3), aggregate.e7_vec_len(vec));
    try std.testing.expectEqual(@as(i64, 2), aggregate.e7_vec_get(vec, 1));

    const Dot = *const fn () callconv(.c) i64;
    try std.testing.expectEqual(@as(i64, 32), (try jit.get(Dot, "dot"))());

    const MatMul = *const fn () callconv(.c) i64;
    const product = (try jit.get(MatMul, "matmul"))();
    try std.testing.expectEqual(@as(i64, 19), aggregate.e7_vec_get(product, 0));
    try std.testing.expectEqual(@as(i64, 22), aggregate.e7_vec_get(product, 1));
    try std.testing.expectEqual(@as(i64, 43), aggregate.e7_vec_get(product, 2));
    try std.testing.expectEqual(@as(i64, 50), aggregate.e7_vec_get(product, 3));

    const Lookup = *const fn (i64) callconv(.c) i64;
    const map = aggregate.e7_map_new();
    aggregate.e7_map_set(map, 7, 42);
    try std.testing.expectEqual(@as(i64, 42), (try jit.get(Lookup, "lookup"))(map));
    const MapLiteral = *const fn () callconv(.c) i64;
    const literal_map = (try jit.get(MapLiteral, "mapl"))();
    try std.testing.expectEqual(@as(i64, 20), aggregate.e7_map_get(literal_map, 2));

    const StrLookup = *const fn (i64) callconv(.c) i64;
    const str_map = (try jit.get(MapLiteral, "strmap"))();
    try std.testing.expectEqual(@as(i64, 77), (try jit.get(StrLookup, "strlookup"))(str_map));

    const Read = *const fn (i64) callconv(.c) i64;
    const slots = aggregate.e7_alloc_i64(2);
    aggregate.e7_store_i64(slots, 11);
    aggregate.e7_store_i64(slots + 8, 22);
    try std.testing.expectEqual(@as(i64, 11), (try jit.get(Read, "read"))(slots));
    try std.testing.expectEqual(@as(i64, 22), (try jit.get(Read, "advance"))(slots));
}

test "JIT reads, writes, and row-assigns matrix elements" {
    var compiled = try compiler.pipeline.compile(
        std.testing.allocator,
        \\mat_read <- (m: [i32; 2, 3]) -> i32 = m[0, 1]
        \\mat_row_read <- (m: [i32; 2, 3]) -> [i32; 3] = m[1]
        \\mat_nested_read <- (m: [i32; 2, 3]) -> i32 = m[0][1]
        \\mat_write <- () -> i32:
        \\    m := [[1, 2, 3], [4, 5, 6]]
        \\    m[1, 0] = 42
        \\    m[1, 0]
        \\mat_row <- () -> i32:
        \\    m := [[1, 2, 3], [4, 5, 6]]
        \\    m[1] = [7, 8, 9]
        \\    m[1, 2]
        \\mat_row_dynamic <- (row: [i32]) -> i32:
        \\    m := [[1, 2, 3], [4, 5, 6]]
        \\    m[0] = row
        \\    m[0, 1]
        \\mat_bounds_read <- () -> i32:
        \\    m := [[1, 2, 3], [4, 5, 6]]
        \\    m[9, 9]
        \\mat_bounds_write <- () -> i32:
        \\    m := [[1, 2, 3], [4, 5, 6]]
        \\    m[9, 9] = 123
        \\    m[0, 0]
    ,
        .{},
    );
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());
    const serialized = try compiler.bytecode.encode(std.testing.allocator, &compiled.bytecode);
    defer std.testing.allocator.free(serialized);
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecodeBytes(serialized, "matrix-indexing");

    const IntFn = *const fn () callconv(.c) i64;
    const MatrixFn = *const fn (i64) callconv(.c) i64;

    const matrix = aggregate.e7_vec_new(2, 3);
    for (0..6) |i| aggregate.e7_vec_set(matrix, @intCast(i), @intCast(i + 1));
    try std.testing.expectEqual(@as(i64, 2), (try jit.get(MatrixFn, "mat_read"))(matrix));
    try std.testing.expectEqual(@as(i64, 2), (try jit.get(MatrixFn, "mat_nested_read"))(matrix));
    const row_view = (try jit.get(MatrixFn, "mat_row_read"))(matrix);
    try std.testing.expectEqual(@as(i64, 3), aggregate.e7_vec_len(row_view));
    try std.testing.expectEqual(@as(i64, 6), aggregate.e7_vec_get(row_view, 2));

    try std.testing.expectEqual(@as(i64, 42), (try jit.get(IntFn, "mat_write"))());
    try std.testing.expectEqual(@as(i64, 9), (try jit.get(IntFn, "mat_row"))());
    try std.testing.expectEqual(@as(i64, 0), (try jit.get(IntFn, "mat_bounds_read"))());
    try std.testing.expectEqual(@as(i64, 1), (try jit.get(IntFn, "mat_bounds_write"))());

    const RowFn = *const fn (i64) callconv(.c) i64;
    const row_fn = try jit.get(RowFn, "mat_row_dynamic");
    const row = aggregate.e7_vec_new(3, 0);
    aggregate.e7_vec_set(row, 0, 10);
    aggregate.e7_vec_set(row, 1, 11);
    aggregate.e7_vec_set(row, 2, 12);
    try std.testing.expectEqual(@as(i64, 11), row_fn(row));
    // A row whose length does not match the column count is ignored.
    const short = aggregate.e7_vec_new(2, 0);
    aggregate.e7_vec_set(short, 0, 99);
    aggregate.e7_vec_set(short, 1, 98);
    try std.testing.expectEqual(@as(i64, 2), row_fn(short));
}

test "JIT executes map and vector iteration and string container builtins" {
    var compiled = try compiler.pipeline.compile(
        std.testing.allocator,
        \\map_sum <- () -> i32:
        \\    m := map[i32, i32] { 1: 10, 2: 20, 3: 30 }
        \\    total := 0
        \\    for (key, value) in m:
        \\        total = total + key + value
        \\    total
        \\map_keys <- (m: map[i32, i32]) -> i32:
        \\    total := 0
        \\    for key in m:
        \\        total = total + key
        \\    total
        \\map_len <- () -> i32:
        \\    m := map[i32, i32] { 1: 10, 2: 20 }
        \\    m.len()
        \\str_map_sum <- () -> i32:
        \\    m := map[str, i32] { "a": 1, "bb": 2 }
        \\    total := 0
        \\    for (key, value) in m:
        \\        total = total + key.len() + value
        \\    total
        \\vec_sum <- () -> i32:
        \\    xs := [1, 2, 3]
        \\    total := 0
        \\    for x in xs:
        \\        total = total + x
        \\    total
        \\vec_index_sum <- () -> i32:
        \\    xs := [10, 20, 30]
        \\    total := 0
        \\    for (i, x) in xs:
        \\        total = total + i * x
        \\    total
        \\break_map <- () -> i32:
        \\    m := map[i32, i32] { 1: 10, 2: 20, 3: 30 }
        \\    total := 0
        \\    for (key, value) in m:
        \\        if key == 2:
        \\            break
        \\        total = total + key
        \\    for _ in m:
        \\        total = total + 1
        \\    total
        \\vec_len <- () -> i32 = [4, 5, 6].len()
        \\text_len <- () -> i32 = "hello".len()
        \\text_slice <- () -> str = "abcdef".slice(1, 3)
        \\text_char <- () -> str = "abc".char_at(1)
        \\text_iter <- () -> i32:
        \\    text := "abc"
        \\    total := 0
        \\    for c in text:
        \\        total = total + c.len()
        \\    for (i, c) in text:
        \\        total = total + i + c.len()
        \\    total
        \\slice_eq <- () -> i32 = if "abcdef".slice(1, 3) == "bc": 1 else: 0
        \\char_eq <- () -> i32 = if "abc".char_at(1) == "b": 1 else: 0
        \\slice_clamped <- () -> str = "abc".slice(1, 99)
        \\char_out_of_range <- () -> str = "abc".char_at(9)
    ,
        .{},
    );
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());

    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "iteration-and-builtins");

    const IntFn = *const fn () callconv(.c) i64;
    const Lookup = *const fn (i64) callconv(.c) i64;
    const textBytes = struct {
        fn get(ptr: i64) [*]const u8 {
            return @ptrFromInt(@as(usize, @intCast(ptr + 8)));
        }
    };

    try std.testing.expectEqual(@as(i64, 66), (try jit.get(IntFn, "map_sum"))());
    const map = aggregate.e7_map_new();
    aggregate.e7_map_set(map, 5, 50);
    aggregate.e7_map_set(map, 7, 70);
    try std.testing.expectEqual(@as(i64, 12), (try jit.get(Lookup, "map_keys"))(map));
    try std.testing.expectEqual(@as(i64, 2), (try jit.get(IntFn, "map_len"))());
    try std.testing.expectEqual(@as(i64, 6), (try jit.get(IntFn, "str_map_sum"))());

    try std.testing.expectEqual(@as(i64, 6), (try jit.get(IntFn, "vec_sum"))());
    try std.testing.expectEqual(@as(i64, 80), (try jit.get(IntFn, "vec_index_sum"))());
    try std.testing.expectEqual(@as(i64, 4), (try jit.get(IntFn, "break_map"))());
    try std.testing.expectEqual(@as(i64, 3), (try jit.get(IntFn, "vec_len"))());

    try std.testing.expectEqual(@as(i64, 5), (try jit.get(IntFn, "text_len"))());
    const slice = (try jit.get(IntFn, "text_slice"))();
    try std.testing.expectEqual(@as(i64, 2), aggregate.e7_str_len(slice));
    try std.testing.expectEqualStrings("bc", textBytes.get(slice)[0..2]);
    const char = (try jit.get(IntFn, "text_char"))();
    try std.testing.expectEqual(@as(i64, 1), aggregate.e7_str_len(char));
    try std.testing.expectEqualStrings("b", textBytes.get(char)[0..1]);
    try std.testing.expectEqual(@as(i64, 9), (try jit.get(IntFn, "text_iter"))());

    try std.testing.expectEqual(@as(i64, 1), (try jit.get(IntFn, "slice_eq"))());
    try std.testing.expectEqual(@as(i64, 1), (try jit.get(IntFn, "char_eq"))());
    const clamped = (try jit.get(IntFn, "slice_clamped"))();
    try std.testing.expectEqual(@as(i64, 2), aggregate.e7_str_len(clamped));
    try std.testing.expectEqualStrings("bc", textBytes.get(clamped)[0..2]);
    const missing = (try jit.get(IntFn, "char_out_of_range"))();
    try std.testing.expectEqual(@as(i64, 0), aggregate.e7_str_len(missing));
}

test "JIT lowers enums and enum matches" {
    var compiled = try compiler.pipeline.compile(
        std.testing.allocator,
        \\Color <- enum
        \\    Red
        \\    Green
        \\pick <- () -> Color = Color::Green
        \\read_color <- (c: Color) -> i32:
        \\    match c:
        \\        Color::Red: 1
        \\        Color::Green: 2
        \\Maybe <- enum
        \\    None
        \\    Some(i32)
        \\some <- () -> Maybe = Maybe::Some(42)
        \\read_maybe <- (m: Maybe) -> i32:
        \\    match m:
        \\        Maybe::None: 0
        \\        Maybe::Some(x): x
    ,
        .{},
    );
    defer compiled.deinit();
    const serialized = try compiler.bytecode.encode(std.testing.allocator, &compiled.bytecode);
    defer std.testing.allocator.free(serialized);
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecodeBytes(serialized, "enums");

    const Pick = *const fn () callconv(.c) i64;
    const Read = *const fn (i64) callconv(.c) i64;
    const pick = try jit.get(Pick, "pick");
    const read_color = try jit.get(Read, "read_color");
    try std.testing.expectEqual(@as(i64, 2), read_color(pick()));

    const Some = *const fn () callconv(.c) i64;
    const read_maybe = try jit.get(Read, "read_maybe");
    const some = try jit.get(Some, "some");
    try std.testing.expectEqual(@as(i64, 42), read_maybe(some()));
}

test "JIT executes custom operator traits, Deref, and Index" {
    var compiled = try compiler.pipeline.compile(
        std.testing.allocator,
        \\Point <- struct
        \\    x: i32
        \\    y: i32
        \\impl Add for Point:
        \\    add <- (a: Point, b: Point) -> Point = Point { x: a.x + b.x, y: a.y + b.y }
        \\impl Sub for Point:
        \\    sub <- (a: Point, b: Point) -> Point = Point { x: a.x - b.x, y: a.y - b.y }
        \\impl Mul for Point:
        \\    mul <- (a: Point, b: Point) -> Point = Point { x: a.x * b.x, y: a.y * b.y }
        \\impl Div for Point:
        \\    div <- (a: Point, b: Point) -> Point = Point { x: a.x / b.x, y: a.y / b.y }
        \\impl Neg for Point:
        \\    neg <- (a: Point) -> Point = Point { x: -a.x, y: -a.y }
        \\impl PartialEq for Point:
        \\    eq <- (a: Point, b: Point) -> bool = a.x == b.x
        \\impl PartialOrd for Point:
        \\    lt <- (a: Point, b: Point) -> bool = a.x < b.x
        \\impl Deref for Point:
        \\    deref <- (a: Point) -> i32 = a.x + a.y
        \\impl Index for Point:
        \\    index <- (a: Point, i: i32) -> i32 = a.x + a.y + i
        \\add <- () -> i32:
        \\    p := Point { x: 1, y: 2 } + Point { x: 3, y: 4 }
        \\    p.x + p.y
        \\sub <- () -> i32:
        \\    p := Point { x: 5, y: 7 } - Point { x: 2, y: 3 }
        \\    p.x + p.y
        \\mul <- () -> i32:
        \\    p := Point { x: 2, y: 3 } * Point { x: 4, y: 5 }
        \\    p.x + p.y
        \\divide <- () -> i32:
        \\    p := Point { x: 8, y: 6 } / Point { x: 2, y: 3 }
        \\    p.x + p.y
        \\negate <- () -> i32:
        \\    p := Point { x: 2, y: 3 }
        \\    q := -p
        \\    q.x + q.y
        \\equal <- () -> bool:
        \\    a := Point { x: 1, y: 2 }
        \\    b := Point { x: 1, y: 2 }
        \\    a == b
        \\not_equal <- () -> bool:
        \\    a := Point { x: 1, y: 2 }
        \\    b := Point { x: 2, y: 3 }
        \\    a != b
        \\less <- () -> bool:
        \\    a := Point { x: 1, y: 0 }
        \\    b := Point { x: 2, y: 0 }
        \\    a < b
        \\greater <- () -> bool:
        \\    a := Point { x: 2, y: 0 }
        \\    b := Point { x: 1, y: 0 }
        \\    a > b
        \\at_most <- () -> bool:
        \\    a := Point { x: 3, y: 0 }
        \\    b := Point { x: 3, y: 0 }
        \\    a <= b
        \\at_least <- () -> bool:
        \\    a := Point { x: 2, y: 0 }
        \\    b := Point { x: 1, y: 0 }
        \\    a >= b
        \\read <- () -> i32:
        \\    p := Point { x: 4, y: 5 }
        \\    *p
        \\at <- () -> i32:
        \\    p := Point { x: 5, y: 6 }
        \\    p[3]
    ,
        .{},
    );
    defer compiled.deinit();
    const serialized = try compiler.bytecode.encode(std.testing.allocator, &compiled.bytecode);
    defer std.testing.allocator.free(serialized);
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecodeBytes(serialized, "custom-operators");

    const Thunk = *const fn () callconv(.c) i64;
    try std.testing.expectEqual(@as(i64, 10), (try jit.get(Thunk, "add"))());
    try std.testing.expectEqual(@as(i64, 7), (try jit.get(Thunk, "sub"))());
    try std.testing.expectEqual(@as(i64, 23), (try jit.get(Thunk, "mul"))());
    try std.testing.expectEqual(@as(i64, 6), (try jit.get(Thunk, "divide"))());
    try std.testing.expectEqual(@as(i64, -5), (try jit.get(Thunk, "negate"))());
    try std.testing.expectEqual(@as(i64, 1), (try jit.get(Thunk, "equal"))());
    try std.testing.expectEqual(@as(i64, 1), (try jit.get(Thunk, "not_equal"))());
    try std.testing.expectEqual(@as(i64, 1), (try jit.get(Thunk, "less"))());
    try std.testing.expectEqual(@as(i64, 1), (try jit.get(Thunk, "greater"))());
    try std.testing.expectEqual(@as(i64, 1), (try jit.get(Thunk, "at_most"))());
    try std.testing.expectEqual(@as(i64, 1), (try jit.get(Thunk, "at_least"))());
    try std.testing.expectEqual(@as(i64, 9), (try jit.get(Thunk, "read"))());
    try std.testing.expectEqual(@as(i64, 14), (try jit.get(Thunk, "at"))());
}

test "JIT executes aggregate reference semantics" {
    var compiled = try compiler.pipeline.compile(
        std.testing.allocator,
        \\Point <- struct
        \\    x: i32
        \\    y: i32
        \\Inner <- struct
        \\    v: i32
        \\Outer <- struct
        \\    inner: Inner
        \\Color <- enum
        \\    Red
        \\    Green
        \\sum_ref <- (p: &Point) -> i32 = p.x + p.y
        \\value_param <- (p: Point) -> i32 = p.x + p.y
        \\bump <- (p: &mut Point) -> i32:
        \\    p.x = p.x + 1
        \\    p.x
        \\inc <- (p: &mut i32) -> i32:
        \\    *p = *p + 1
        \\    *p
        \\pick <- (c: &Color) -> i32:
        \\    match *c:
        \\        Red: 1
        \\        Green: 2
        \\via_ref <- () -> i32:
        \\    p := Point { x: 2, y: 3 }
        \\    sum_ref(&p)
        \\mutate_param <- () -> i32:
        \\    p := Point { x: 2, y: 3 }
        \\    bump(&mut p)
        \\    p.x
        \\mutate_scalar <- () -> i32:
        \\    x := 5
        \\    inc(&mut x)
        \\    x
        \\local_field <- () -> i32:
        \\    p := Point { x: 2, y: 3 }
        \\    r := &p
        \\    r.x + (*r).y
        \\whole_deref <- () -> i32:
        \\    p := Point { x: 2, y: 3 }
        \\    r := &p
        \\    q := *r
        \\    q.y
        \\deref_arg <- () -> i32:
        \\    p := Point { x: 2, y: 3 }
        \\    r := &p
        \\    value_param(*r)
        \\field_addr <- () -> i32:
        \\    p := Point { x: 2, y: 3 }
        \\    q := &p.x
        \\    *q
        \\field_mut <- () -> i32:
        \\    p := Point { x: 2, y: 3 }
        \\    r := &mut p
        \\    r.x = 7
        \\    r.x + r.y
        \\bump_paren <- (p: &mut Point) -> i32:
        \\    (*p).x = p.x + 2
        \\    p.x
        \\paren_mut <- () -> i32:
        \\    p := Point { x: 2, y: 3 }
        \\    bump_paren(&mut p)
        \\    p.x
        \\inner_ref <- () -> i32:
        \\    o := Outer { inner: Inner { v: 4 } }
        \\    r := &o.inner
        \\    r.v
        \\inner_param <- (r: &Inner) -> i32 = r.v
        \\inner_field_ref <- () -> i32:
        \\    o := Outer { inner: Inner { v: 4 } }
        \\    inner_param(&o.inner)
        \\scalar_field_param <- (p: &i32) -> i32 = *p
        \\scalar_field_ref <- () -> i32:
        \\    p := Point { x: 2, y: 3 }
        \\    scalar_field_param(&p.x)
        \\scalar_ref <- () -> i32:
        \\    x := 5
        \\    r := &x
        \\    *r
        \\inner_mut <- () -> i32:
        \\    o := Outer { inner: Inner { v: 4 } }
        \\    s := &mut o
        \\    s.inner.v = 9
        \\    s.inner.v
        \\enum_ref <- () -> i32:
        \\    c := Color::Green
        \\    pick(&c)
        \\vec_ref <- () -> i32:
        \\    xs := [1, 2, 3]
        \\    r := &mut xs
        \\    r[1] = 9
        \\    r.len() * 10 + r[1]
        \\vec_whole <- () -> i32:
        \\    xs := [1, 2, 3]
        \\    r := &xs
        \\    q := *r
        \\    q[2]
        \\map_ref <- () -> i32:
        \\    m := map[i32, i32] { 1: 10 }
        \\    r := &mut m
        \\    r[2] = 22
        \\    r[1] + r[2]
        \\string_ref <- () -> i32:
        \\    s := "hello"
        \\    r := &s
        \\    r.len() + r.char_at(1).len()
        \\string_whole <- () -> i32:
        \\    s := "hello"
        \\    r := &s
        \\    q := *r
        \\    q.len()
        \\mat_elem <- (m: &[i32; 2, 3]) -> i32 = m[0, 1]
        \\mat_check <- () -> i32:
        \\    m := [[1, 2, 3], [4, 5, 6]]
        \\    mat_elem(&m)
        \\mat_deref <- () -> i32:
        \\    m := [[1, 2, 3], [4, 5, 6]]
        \\    r := &m
        \\    q := *r
        \\    q[1, 0]
    ,
        .{},
    );
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());
    const serialized = try compiler.bytecode.encode(std.testing.allocator, &compiled.bytecode);
    defer std.testing.allocator.free(serialized);
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecodeBytes(serialized, "aggregate-refs");

    const Thunk = *const fn () callconv(.c) i64;
    const Unary = *const fn (i64) callconv(.c) i64;

    try std.testing.expectEqual(@as(i64, 5), (try jit.get(Thunk, "via_ref"))());
    try std.testing.expectEqual(@as(i64, 3), (try jit.get(Thunk, "mutate_param"))());
    try std.testing.expectEqual(@as(i64, 6), (try jit.get(Thunk, "mutate_scalar"))());
    try std.testing.expectEqual(@as(i64, 5), (try jit.get(Thunk, "local_field"))());
    try std.testing.expectEqual(@as(i64, 3), (try jit.get(Thunk, "whole_deref"))());
    try std.testing.expectEqual(@as(i64, 5), (try jit.get(Thunk, "deref_arg"))());
    try std.testing.expectEqual(@as(i64, 2), (try jit.get(Thunk, "field_addr"))());
    try std.testing.expectEqual(@as(i64, 10), (try jit.get(Thunk, "field_mut"))());
    try std.testing.expectEqual(@as(i64, 4), (try jit.get(Thunk, "paren_mut"))());
    try std.testing.expectEqual(@as(i64, 4), (try jit.get(Thunk, "inner_ref"))());
    try std.testing.expectEqual(@as(i64, 4), (try jit.get(Thunk, "inner_field_ref"))());
    try std.testing.expectEqual(@as(i64, 2), (try jit.get(Thunk, "scalar_field_ref"))());
    try std.testing.expectEqual(@as(i64, 5), (try jit.get(Thunk, "scalar_ref"))());
    try std.testing.expectEqual(@as(i64, 9), (try jit.get(Thunk, "inner_mut"))());
    try std.testing.expectEqual(@as(i64, 2), (try jit.get(Thunk, "enum_ref"))());
    try std.testing.expectEqual(@as(i64, 39), (try jit.get(Thunk, "vec_ref"))());
    try std.testing.expectEqual(@as(i64, 3), (try jit.get(Thunk, "vec_whole"))());
    try std.testing.expectEqual(@as(i64, 32), (try jit.get(Thunk, "map_ref"))());
    try std.testing.expectEqual(@as(i64, 6), (try jit.get(Thunk, "string_ref"))());
    try std.testing.expectEqual(@as(i64, 5), (try jit.get(Thunk, "string_whole"))());
    try std.testing.expectEqual(@as(i64, 2), (try jit.get(Thunk, "mat_check"))());
    try std.testing.expectEqual(@as(i64, 4), (try jit.get(Thunk, "mat_deref"))());

    // Host-built aggregate objects interoperate with reference parameters: a
    // `&Point` argument aliases the object pointer directly.
    const point = aggregate.e7_alloc_i64(2);
    aggregate.e7_store_i64(point, 11);
    aggregate.e7_store_i64(point + 8, 31);
    try std.testing.expectEqual(@as(i64, 42), (try jit.get(Unary, "sum_ref"))(point));
    try std.testing.expectEqual(@as(i64, 12), (try jit.get(Unary, "bump"))(point));
    try std.testing.expectEqual(@as(i64, 12), aggregate.e7_load_i64(point));
    try std.testing.expectEqual(@as(i64, 31), aggregate.e7_load_i64(point + 8));
}

test "JIT executes normal sys declarations as async tasks" {
    var compiled = try compiler.pipeline.compile(
        std.testing.allocator,
        \\S <- struct
        \\    a: i32
        \\Bump <- sys(target: &mut S):
        \\    target.a = target.a + 1
        \\run <- async () -> i32:
        \\    s := S { a: 41 }
        \\    task := Bump(&mut s)
        \\    await task
        \\    s.a
    ,
        .{},
    );
    defer compiled.deinit();

    const serialized = try compiler.bytecode.encode(std.testing.allocator, &compiled.bytecode);
    defer std.testing.allocator.free(serialized);

    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecodeBytes(serialized, "async-sys");

    const Run = *const fn () callconv(.c) i64;
    const run = try jit.get(Run, "run");
    const handle = run();
    try std.testing.expect(handle != 0);
    // The system body receives its normal parameter and mutates through it.
    try std.testing.expectEqual(@as(i64, 42), task.e7_task_await(handle));
}

test "JIT executes a source call into a resource-handle system" {
    var compiled = try compiler.pipeline.compile(
        std.testing.allocator,
        \\S <- struct
        \\    a: i32
        \\Consume <- sys(target: res &mut S):
        \\    ret
        \\run <- async () -> i32:
        \\    s := S { a: 7 }
        \\    task := Consume(&mut s)
        \\    await task
        \\    9
    ,
        .{},
    );
    defer compiled.deinit();

    const serialized = try compiler.bytecode.encode(std.testing.allocator, &compiled.bytecode);
    defer std.testing.allocator.free(serialized);

    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecodeBytes(serialized, "async-sys-resource");

    const Run = *const fn () callconv(.c) i64;
    const run = try jit.get(Run, "run");
    try std.testing.expectEqual(@as(i64, 9), task.e7_task_await(run()));
}

test "JITed IR calls the lease release/reacquire ABI" {
    lease.reset();
    defer lease.reset();

    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.defineSymbols(&lease.symbols());

    const ir =
        \\declare i64 @e7_lease_acquire(i64)
        \\declare i64 @e7_lease_release(i64)
        \\declare i64 @e7_lease_active(i64)
        \\define i64 @lease_probe() {
        \\entry:
        \\  %a = call i64 @e7_lease_acquire(i64 77)
        \\  %active = call i64 @e7_lease_active(i64 77)
        \\  %r = call i64 @e7_lease_release(i64 77)
        \\  %after = call i64 @e7_lease_active(i64 77)
        \\  %t = mul i64 %active, 10
        \\  %u = add i64 %t, %r
        \\  %v = mul i64 %after, 100
        \\  %w = add i64 %u, %v
        \\  ret i64 %w
        \\}
    ;
    try jit.addIr(ir, "lease-abi");
    const Probe = *const fn () callconv(.c) i64;
    const probe = try jit.get(Probe, "lease_probe");
    // acquire=1, active=1 (10), release=1, post-release active=0: 10 + 1 = 11.
    try std.testing.expectEqual(@as(i64, 11), probe());
}

test "JITed IR calls the ECS command and query ABI" {
    ecs.e7_ecs_reset();
    defer ecs.e7_ecs_reset();

    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    const symbols = ecs.symbols();
    try jit.defineSymbols(&symbols);
    const aggregate_symbols = aggregate.symbols();
    try jit.defineSymbols(&aggregate_symbols);

    const ir =
        \\declare i32 @e7_ecs_register_component(i64, i64)
        \\declare i64 @e7_ecs_commands()
        \\declare i64 @e7_ecs_commands_row_begin(i64)
        \\declare i32 @e7_ecs_commands_row_add(i64, i64, i64)
        \\declare i32 @e7_ecs_commands_row_finish(i64)
        \\declare i32 @e7_ecs_commands_flush(i64)
        \\declare i64 @e7_ecs_entity_count()
        \\declare i64 @e7_ecs_component_get(i64, i64)
        \\declare i64 @e7_load_i64(i64)
        \\define i64 @ecs_probe(i64 %value_ptr) {
        \\entry:
        \\  %reg = call i32 @e7_ecs_register_component(i64 9, i64 1)
        \\  %cmd = call i64 @e7_ecs_commands()
        \\  %row = call i64 @e7_ecs_commands_row_begin(i64 %cmd)
        \\  %add = call i32 @e7_ecs_commands_row_add(i64 %row, i64 9, i64 %value_ptr)
        \\  %finish = call i32 @e7_ecs_commands_row_finish(i64 %row)
        \\  %flush = call i32 @e7_ecs_commands_flush(i64 %cmd)
        \\  %count = call i64 @e7_ecs_entity_count()
        \\  %component = call i64 @e7_ecs_component_get(i64 0, i64 9)
        \\  %load = call i64 @e7_load_i64(i64 %component)
        \\  %scaled = mul i64 %count, 100
        \\  %result = add i64 %scaled, %load
        \\  ret i64 %result
        \\}
    ;
    try jit.addIr(ir, "ecs-abi");
    const Probe = *const fn (i64) callconv(.c) i64;
    const probe = try jit.get(Probe, "ecs_probe");

    var values = [_]i64{42};
    const value_ptr: i64 = @intCast(@intFromPtr(&values));
    // count=1 contributes 100; the copied component value contributes 42.
    try std.testing.expectEqual(@as(i64, 142), probe(value_ptr));
    try std.testing.expectEqual(@as(i64, 42), aggregate.e7_load_i64(ecs.e7_ecs_component_get(0, 9)));
}

test "JIT executes the ECS resource, row, Commands, and query ABI end-to-end" {
    ecs.e7_ecs_reset();
    defer ecs.e7_ecs_reset();

    var compiled = try compiler.pipeline.compile(
        std.testing.allocator,
        \\@resource
        \\S <- struct
        \\    a: i32
        \\@Components
        \\C <- struct
        \\    b: i32
        \\@Components
        \\Marker <- struct
        \\Components <- table
        \\    entity_id: usize,
        \\    ...
        \\Tick <- sys (
        \\    target: res &mut S,
        \\    items: select &mut C from Components,
        \\    commands: &mut Commands,
        \\):
        \\    target.a = target.a + 1
        \\    commands.add_row(Components, { C { b: 2 }, Marker })
        \\    disown commands
        \\main <- async () -> i32:
        \\    await Tick()
        \\    7
    ,
        .{},
    );
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());

    const resource = compiled.analysis.resource("S").?;
    const component = compiled.analysis.component("C").?;
    const marker = compiled.analysis.component("Marker").?;

    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "ecs-end-to-end");

    const Main = *const fn () callconv(.c) i64;
    const main = try jit.get(Main, "main");
    const handle = main();
    try std.testing.expect(handle != 0);
    try std.testing.expectEqual(@as(i64, 7), task.e7_task_await(handle));

    // `__e7_ecs_setup` registered the resource/columns; the sys prologue wrote
    // through the world resource pointer.
    try std.testing.expectEqual(@as(i64, 1), ecs.e7_ecs_has_resource(resource.id));
    const resource_ptr = ecs.e7_ecs_resource(resource.id);
    try std.testing.expect(resource_ptr != 0);
    try std.testing.expectEqual(@as(i64, 1), aggregate.e7_load_i64(resource_ptr));

    // The sys queued a row and flushed it at `disown commands`.
    try std.testing.expectEqual(@as(i64, 1), ecs.e7_ecs_entity_count());
    const component_ptr = ecs.e7_ecs_component_get(0, component.id);
    try std.testing.expect(component_ptr != 0);
    try std.testing.expectEqual(@as(i64, 2), aggregate.e7_load_i64(component_ptr));
    try std.testing.expect(ecs.e7_ecs_component_get(0, marker.id) != 0);

    // A fresh query over the flushed world observes the entity and component.
    var ids = [_]i64{component.id};
    var muts = [_]i64{1};
    const query = ecs.e7_ecs_query_begin(
        1,
        @intCast(@intFromPtr(&ids)),
        @intCast(@intFromPtr(&muts)),
        -1,
    );
    try std.testing.expect(query != 0);
    try std.testing.expectEqual(@as(i64, 1), ecs.e7_ecs_query_next(query));
    const query_ptr = ecs.e7_ecs_query_component(query, 0);
    try std.testing.expectEqual(@as(i64, 2), aggregate.e7_load_i64(query_ptr));
    try std.testing.expectEqual(@as(i64, 0), ecs.e7_ecs_query_next(query));
}

test "JIT runs the e7 engine project headless and captures a rendered frame" {
    engine.reset();
    defer engine.shutdown();
    engine.setHeadless(true);
    engine.setMaxFrames(2);
    engine.setCaptureEnabled(true);

    const candidates = [_][]const u8{
        "engine/main.e7",
        "../engine/main.e7",
        "../../engine/main.e7",
    };
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var root_path: []const u8 = "";
    for (candidates) |candidate| {
        var probe = std.Io.Dir.cwd().openFile(std.testing.io, candidate, .{}) catch continue;
        probe.close(std.testing.io);
        const absolute = std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, candidate, std.testing.allocator) catch continue;
        @memcpy(path_buffer[0..absolute.len], absolute);
        root_path = path_buffer[0..absolute.len];
        std.testing.allocator.free(absolute);
        break;
    }
    if (root_path.len == 0) return error.SkipZigTest;

    var compiled = compiler.pipeline.compileProject(std.testing.allocator, root_path, .{}) catch |err| {
        std.debug.print("engine project compile failed: {s}\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer compiled.deinit();
    if (!compiled.analysis.ok()) {
        for (compiled.analysis.diagnostics) |diagnostic| {
            std.debug.print("engine project semantic: {}:{} {s}\n", .{ diagnostic.span.line, diagnostic.span.column, diagnostic.message });
        }
        return error.TestUnexpectedResult;
    }

    ecs.e7_ecs_reset();
    defer ecs.e7_ecs_reset();
    for (compiled.analysis.resources) |resource| {
        if (resource.plugin_id != null) continue;
        try std.testing.expectEqual(@as(i32, 0), ecs.e7_ecs_register_resource(resource.id, @intCast(resource.slots)));
    }
    for (compiled.analysis.components) |component| {
        try std.testing.expectEqual(@as(i32, 0), ecs.e7_ecs_register_component(component.id, @intCast(component.slots)));
    }

    const bytes = try compiler.bytecode.encode(std.testing.allocator, &compiled.bytecode);
    defer std.testing.allocator.free(bytes);
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecodeBytes(bytes, "engine-main");
    const Main = *const fn () callconv(.c) i64;
    const main_ctor = try jit.get(Main, "main");
    // Synthetic device input stands in for SDL.  Camera/input policy now runs
    // in the compiled e7 systems, so the ECS Camera row is the observable.
    engine.injectKeyForTest(@intFromEnum(engine.Key.forward), true);
    engine.injectKeyForTest(@intFromEnum(engine.Key.sprint), true);
    engine.injectMouseDeltaForTest(120, 0);
    const handle = main_ctor();
    try std.testing.expect(handle != 0);
    // `main` returns i32 0 on success after DeInit tears down window/scene.
    try std.testing.expectEqual(@as(i64, 0), task.e7_task_await(handle));
    const stats = engine.renderStats();
    try std.testing.expect(stats.scene_draws > 0);

    // Camera component slots: [0] position vector handle, [1] yaw, [2] pitch,
    // then fov/near/far.  Floats are f64 bit patterns in i64 slots.
    const camera_component = compiled.analysis.component("Camera") orelse blk: {
        for (compiled.analysis.components) |component| {
            if (std.mem.endsWith(u8, component.name, "Camera")) break :blk component;
        }
        return error.TestUnexpectedResult;
    };
    var camera_ptr: i64 = 0;
    var entity: i64 = 0;
    const entity_count = ecs.e7_ecs_entity_count();
    while (entity < entity_count and camera_ptr == 0) : (entity += 1) {
        camera_ptr = ecs.e7_ecs_component_get(entity, camera_component.id);
    }
    try std.testing.expect(camera_ptr != 0);
    const loadFloat = struct {
        fn get(base: i64, index: usize) f64 {
            return @bitCast(aggregate.e7_load_i64(base + @as(i64, @intCast(index * 8))));
        }
    }.get;
    const position_handle = aggregate.e7_load_i64(camera_ptr);
    const position_z: f64 = @bitCast(aggregate.e7_vec_get(position_handle, 2));

    try std.testing.expect(position_z < 5.5); // forward key moved -Z
    try std.testing.expect(loadFloat(camera_ptr, 1) > 0.0); // mouse yaw
    try std.testing.expect(loadFloat(camera_ptr, 2) < 0.0); // initial pitch

    try std.testing.expect(engine.frames() >= 2);
    var capture = engine.takeCapture() orelse return error.TestUnexpectedResult;
    defer capture.deinit();
    try std.testing.expectEqual(@as(u32, 960), capture.width);
    try std.testing.expectEqual(@as(u32, 540), capture.height);
    try std.testing.expect(engine.captureIsNonBlack(capture));
    try std.testing.expect(engine.captureHasContent(capture));
}

test "JIT executes query projection iteration and mutable component writes" {
    ecs.e7_ecs_reset();
    defer ecs.e7_ecs_reset();

    var compiled = try compiler.pipeline.compile(
        std.testing.allocator,
        \\@Components
        \\C <- struct
        \\    b: i32
        \\@Components
        \\D <- struct
        \\    c: i32
        \\Components <- table
        \\    entity_id: usize,
        \\    ...
        \\Tick <- sys (
        \\    items: select &mut C, &D from Components,
        \\    singles: select &mut C from Components,
        \\):
        \\    for (c, d) in items:
        \\        c.b = c.b + d.c
        \\    for row in singles:
        \\        row.b = row.b + 1
        \\main <- async () -> i32:
        \\    commands := await query &mut Commands
        \\    c0 := C { b: 1 }
        \\    d0 := D { c: 10 }
        \\    commands.add_row(Components, { c0, d0 })
        \\    disown commands
        \\    await Tick()
        \\    0
    ,
        .{},
    );
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());

    const compiled_component = compiled.analysis.component("C").?;
    const pair_component = compiled.analysis.component("D").?;

    const bytes = try compiler.bytecode.encode(std.testing.allocator, &compiled.bytecode);
    defer std.testing.allocator.free(bytes);
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecodeBytes(bytes, "query-iteration");
    const Main = *const fn () callconv(.c) i64;
    const main_ctor = try jit.get(Main, "main");
    const handle = main_ctor();
    try std.testing.expect(handle != 0);
    try std.testing.expectEqual(@as(i64, 0), task.e7_task_await(handle));

    // Row created via Commands, then mutated through both query loops:
    // c.b = 1 + d.c(10) = 11, then row.b = 11 + 1 = 12.
    try std.testing.expectEqual(@as(i64, 1), ecs.e7_ecs_entity_count());
    const component_ptr = ecs.e7_ecs_component_get(0, compiled_component.id);
    try std.testing.expect(component_ptr != 0);
    try std.testing.expectEqual(@as(i64, 12), aggregate.e7_load_i64(component_ptr));
    const pair_ptr = ecs.e7_ecs_component_get(0, pair_component.id);
    try std.testing.expect(pair_ptr != 0);
    try std.testing.expectEqual(@as(i64, 10), aggregate.e7_load_i64(pair_ptr));
}

test "JIT executes async functions with five or more parameters" {
    var compiled = try compiler.pipeline.compile(
        std.testing.allocator,
        \\sum5 <- async (a: i32, b: i32, c: i32, d: i32, e: i32) -> i32 = a + b + c + d + e
        \\run <- async () -> i32:
        \\    task := sum5(1, 2, 3, 4, 5)
        \\    await task
    ,
        .{},
    );
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());
    const bytes = try compiler.bytecode.encode(std.testing.allocator, &compiled.bytecode);
    defer std.testing.allocator.free(bytes);
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecodeBytes(bytes, "task-arity");
    const Run = *const fn () callconv(.c) i64;
    const run = try jit.get(Run, "run");
    const task_handle = run();
    try std.testing.expect(task_handle != 0);
    try std.testing.expectEqual(@as(i64, 15), task.e7_task_await(task_handle));
}

test "JIT computes float arithmetic, math intrinsics, and conversions" {
    var compiled = try compiler.pipeline.compile(
        std.testing.allocator,
        \\compute <- () -> i64:
        \\    a := 5.0
        \\    b := 2.0
        \\    half := a / b
        \\    three_five := half + 1.0
        \\    s := e7_f32_sin(1.5707963267948966)
        \\    c := e7_f32_cos(0.0)
        \\    root := e7_f32_sqrt(9.0)
        \\    absv := e7_f32_abs(-2.5)
        \\    clamped := e7_f32_clamp(5.0, 0.0, 1.0)
        \\    i := three_five as i64
        \\    f := i as f64
        \\    less := three_five < 4.0
        \\    neq := three_five != 4.0
        \\    total := e7_f32_to_milli(three_five) + e7_f32_to_milli(s) + e7_f32_to_milli(c)
        \\    total = total + e7_f32_to_milli(root) + e7_f32_to_milli(absv) + e7_f32_to_milli(clamped)
        \\    total = total + i + e7_f32_to_milli(f) + (less as i64) + (neq as i64)
        \\    total
        \\sinm <- () -> i64 = e7_f32_to_milli(e7_f32_sin(1.5707963267948966))
        \\cosm <- () -> i64 = e7_f32_to_milli(e7_f32_cos(0.0))
        \\sqrtm <- () -> i64 = e7_f32_to_milli(e7_f32_sqrt(9.0))
        \\absm <- () -> i64 = e7_f32_to_milli(e7_f32_abs(-2.5))
        \\clampm <- () -> i64 = e7_f32_to_milli(e7_f32_clamp(5.0, 0.0, 1.0))
        \\tfm <- () -> i64 = e7_f32_to_milli(5.0 / 2.0 + 1.0)
        \\casti <- () -> i64 = (5.0 / 2.0 + 1.0) as i64
        \\castv <- () -> i64:
        \\    a := 5.0
        \\    b := 2.0
        \\    half := a / b
        \\    tf := half + 1.0
        \\    tf as i64
        \\fmill <- () -> i64:
        \\    a := 5.0
        \\    b := 2.0
        \\    half := a / b
        \\    tf := half + 1.0
        \\    i := tf as i64
        \\    e7_f32_to_milli(i as f64)
        \\movement <- () -> i64 = e7_f32_to_milli(1.0 + 3.0 * 0.016)
        \\roundtrip <- () -> i64 = e7_f32_to_milli(e7_f32_from_milli(1235))
        \\comparisons <- () -> i64:
        \\    a := 1.5
        \\    b := 2.5
        \\    sum := 0
        \\    if a < b:
        \\        sum = sum + 1
        \\    if b > a:
        \\        sum = sum + 1
        \\    if a <= a:
        \\        sum = sum + 1
        \\    if b >= b:
        \\        sum = sum + 1
        \\    if a != b:
        \\        sum = sum + 1
        \\    if a == a:
        \\        sum = sum + 1
        \\    sum
    ,
        .{},
    );
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());
    const bytes = try compiler.bytecode.encode(std.testing.allocator, &compiled.bytecode);
    defer std.testing.allocator.free(bytes);
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecodeBytes(bytes, "float-math");

    const Fn = *const fn () callconv(.c) i64;
    const sinm = try jit.get(Fn, "sinm");
    const cosm = try jit.get(Fn, "cosm");
    const sqrtm = try jit.get(Fn, "sqrtm");
    const absm = try jit.get(Fn, "absm");
    const clampm = try jit.get(Fn, "clampm");
    const tfm = try jit.get(Fn, "tfm");
    const casti = try jit.get(Fn, "casti");
    try std.testing.expectEqual(@as(i64, 1000), sinm());
    try std.testing.expectEqual(@as(i64, 1000), cosm());
    try std.testing.expectEqual(@as(i64, 3000), sqrtm());
    try std.testing.expectEqual(@as(i64, 2500), absm());
    try std.testing.expectEqual(@as(i64, 1000), clampm());
    try std.testing.expectEqual(@as(i64, 3500), tfm());
    try std.testing.expectEqual(@as(i64, 3), casti());
    const castv = try jit.get(Fn, "castv");
    const fmill = try jit.get(Fn, "fmill");
    try std.testing.expectEqual(@as(i64, 3), castv());
    try std.testing.expectEqual(@as(i64, 3000), fmill());
    const compute = try jit.get(Fn, "compute");
    // 3.5 + sin(pi/2) + cos(0) + sqrt(9) + |-2.5| + clamp(5,0,1) + 3 + 3
    // in milli-units plus two comparison bits: 15005.
    try std.testing.expectEqual(@as(i64, 15005), compute());
    const movement = try jit.get(Fn, "movement");
    try std.testing.expectEqual(@as(i64, 1048), movement());
    const roundtrip = try jit.get(Fn, "roundtrip");
    try std.testing.expectEqual(@as(i64, 1235), roundtrip());
    const comparisons = try jit.get(Fn, "comparisons");
    try std.testing.expectEqual(@as(i64, 6), comparisons());
}

test "JIT round-trips JSON for derived structs" {
    var compiled = try compiler.pipeline.compile(
        std.testing.allocator,
        \\@derive(Serialize, Deserialize)
        \\Point <- struct
        \\    x: f32
        \\    y: f32
        \\    name: str
        \\@derive(Serialize, Deserialize)
        \\Line <- struct
        \\    start: Point
        \\    end: Point
        \\    tags: [str]
        \\    points: [Point]
        \\    count: i64
        \\    visible: bool
        \\encode_point <- () -> str:
        \\    p := Point { x: 1.5, y: -2.0, name: "origin" }
        \\    json_encode(p)
        \\decode_point <- () -> i64:
        \\    p := json_decode::<Point>("{\"x\": 1.5, \"y\": -2.0, \"name\": \"origin\"}")
        \\    e7_f32_to_milli(p.x) + e7_f32_to_milli(p.y) + (p.name.len() as i64)
        \\roundtrip_line <- () -> i64:
        \\    a := Point { x: 1.5, y: -2.0, name: "origin" }
        \\    b := Point { x: 0.0, y: 2.5, name: "dest" }
        \\    tags := ["a", "bb"]
        \\    points := [Point { x: 3.5, y: 0.0, name: "p0" }, Point { x: 0.5, y: 0.0, name: "p1" }]
        \\    line := Line { start: a, end: b, tags: tags, points: points, count: 7, visible: true }
        \\    text := json_encode(line)
        \\    copy := json_decode::<Line>(text)
        \\    e7_f32_to_milli(copy.start.x) + e7_f32_to_milli(copy.end.y) + (copy.end.name.len() as i64) + (copy.tags.len() as i64) + (copy.tags[1].len() as i64) + (copy.points.len() as i64) + e7_f32_to_milli(copy.points[1].x) + copy.count + (copy.visible as i64)
    ,
        .{},
    );
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());
    const point = compiled.analysis.derive("Point").?;
    try std.testing.expect(point.serialize and point.deserialize);
    try std.testing.expectEqualStrings("{x=f;y=f;name=s}", point.schema.?);
    const line = compiled.analysis.derive("Line").?;
    try std.testing.expectEqualStrings("{start={x=f;y=f;name=s};end={x=f;y=f;name=s};tags=[s];points=[{x=f;y=f;name=s}];count=i;visible=b}", line.schema.?);

    const bytes = try compiler.bytecode.encode(std.testing.allocator, &compiled.bytecode);
    defer std.testing.allocator.free(bytes);
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecodeBytes(bytes, "json-derive");

    const Str = *const fn () callconv(.c) i64;
    const encode_point = try jit.get(Str, "encode_point");
    const encoded = encode_point();
    try std.testing.expect(encoded != 0);
    const encoded_len = aggregate.e7_str_len(encoded);
    try std.testing.expect(encoded_len > 0);
    const encoded_ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(encoded + 8)));
    const encoded_text = encoded_ptr[0..@intCast(encoded_len)];
    try std.testing.expect(std.mem.startsWith(u8, encoded_text, "{\"x\":"));
    try std.testing.expect(std.mem.indexOf(u8, encoded_text, "\"name\":\"origin\"") != null);

    const I64 = *const fn () callconv(.c) i64;
    const decode_point = try jit.get(I64, "decode_point");
    try std.testing.expectEqual(@as(i64, -494), decode_point()); // 1500 - 2000 + 6

    const roundtrip_line = try jit.get(I64, "roundtrip_line");
    // 1500 + 2500 + len("dest")4 + tags.len()2 + len("bb")2 + points.len()2
    // + points[1].x(0.5)500 + count 7 + visible 1
    try std.testing.expectEqual(@as(i64, 4518), roundtrip_line());
}
