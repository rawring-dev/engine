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
const host = @import("host.zig");
pub const float = @import("float.zig");
pub const json = @import("json.zig");
pub const image = @import("image.zig");
pub const intrinsics = @import("intrinsics.zig");
const host_engine = @import("host_engine.zig");

pub const filesystem = @import("ffi/fs.zig");
pub const net = @import("ffi/net.zig");
pub const http = @import("ffi/http.zig");
pub const quic = @import("ffi/quic.zig");
pub const webrtc = @import("ffi/webrtc.zig");
pub const stdio = @import("ffi/stdio.zig");
pub const dl = @import("ffi/dl.zig");

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
    _ = float;
    _ = json;
    _ = image;
    _ = @import("editor_host.zig");
    _ = @import("editor_run.zig");
    _ = @import("live_reload.zig");
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
    // e7-authored test harness self-tests (discovery, pass/fail classification,
    // include directives) and its native assertion helpers.
    _ = @import("e7_test.zig");
    _ = @import("test_support.zig");
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
    host.reset();
    defer host.reset();
    host.setHeadless(true);
    host.setMaxFrames(2);
    host.setCaptureEnabled(true);

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
    if (root_path.len == 0) return error.TestUnexpectedResult;

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
    const handle = main_ctor();
    try std.testing.expect(handle != 0);
    // `main` returns i32 0 on success after DeInit tears down window/scene.
    try std.testing.expectEqual(@as(i64, 0), task.e7_task_await(handle));
    try std.testing.expect(host.frames() >= 2);
    var capture = host.takeCapture() orelse return error.TestUnexpectedResult;
    defer capture.deinit();
    try std.testing.expectEqual(@as(u32, 960), capture.width);
    try std.testing.expectEqual(@as(u32, 540), capture.height);
    try std.testing.expectEqual(@as(usize, 960 * 540 * 4), capture.pixels.len);
    // A captured headless frame must contain real rendered content, never a
    // zero/empty buffer: the demo camera looks at the cube, so the centre pixel
    // is scene content and differs from the black bands at the top edge.
    var non_zero: usize = 0;
    for (capture.pixels) |byte| {
        if (byte != 0) non_zero += 1;
    }
    try std.testing.expect(non_zero > capture.pixels.len / 2);
    const center = rgbaPixel(capture.pixels, 960, 480, 270);
    const top_edge = rgbaPixel(capture.pixels, 960, 480, 10);
    try std.testing.expect(center != 0xFF000000);
    try std.testing.expect(center != top_edge);
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
        \\    s := f32::sin(1.5707963267948966)
        \\    c := f32::cos(0.0)
        \\    root := f32::sqrt(9.0)
        \\    absv := f32::abs(-2.5)
        \\    clamped := f32::clamp(5.0, 0.0, 1.0)
        \\    i := three_five as i64
        \\    f := i as f64
        \\    less := three_five < 4.0
        \\    neq := three_five != 4.0
        \\    total := f32::to_milli(three_five) + f32::to_milli(s) + f32::to_milli(c)
        \\    total = total + f32::to_milli(root) + f32::to_milli(absv) + f32::to_milli(clamped)
        \\    total = total + i + f32::to_milli(f) + (less as i64) + (neq as i64)
        \\    total
        \\sinm <- () -> i64 = f32::to_milli(f32::sin(1.5707963267948966))
        \\cosm <- () -> i64 = f32::to_milli(f32::cos(0.0))
        \\sqrtm <- () -> i64 = f32::to_milli(f32::sqrt(9.0))
        \\absm <- () -> i64 = f32::to_milli(f32::abs(-2.5))
        \\clampm <- () -> i64 = f32::to_milli(f32::clamp(5.0, 0.0, 1.0))
        \\tfm <- () -> i64 = f32::to_milli(5.0 / 2.0 + 1.0)
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
        \\    f32::to_milli(i as f64)
        \\movement <- () -> i64 = f32::to_milli(1.0 + 3.0 * 0.016)
        \\roundtrip <- () -> i64 = f32::to_milli(f32::from_milli(1235))
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
        \\    f32::to_milli(p.x) + f32::to_milli(p.y) + (p.name.len() as i64)
        \\roundtrip_line <- () -> i64:
        \\    a := Point { x: 1.5, y: -2.0, name: "origin" }
        \\    b := Point { x: 0.0, y: 2.5, name: "dest" }
        \\    tags := ["a", "bb"]
        \\    points := [Point { x: 3.5, y: 0.0, name: "p0" }, Point { x: 0.5, y: 0.0, name: "p1" }]
        \\    line := Line { start: a, end: b, tags: tags, points: points, count: 7, visible: true }
        \\    text := json_encode(line)
        \\    copy := json_decode::<Line>(text)
        \\    f32::to_milli(copy.start.x) + f32::to_milli(copy.end.y) + (copy.end.name.len() as i64) + (copy.tags.len() as i64) + (copy.tags[1].len() as i64) + (copy.points.len() as i64) + f32::to_milli(copy.points[1].x) + copy.count + (copy.visible as i64)
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

test "JIT runs the complete JSON API from e7 source" {
    const source =
        \\@derive(Serialize, Deserialize)
        \\Color <- enum
        \\    Red
        \\    Rgb(i64, i64, i64)
        \\@derive(Serialize, Deserialize)
        \\Point <- struct
        \\    x: f32
        \\    tag: str
        \\@derive(Serialize, Deserialize)
        \\Box <- struct
        \\    name: str
        \\    vector: [i32; 4]
        \\    grid: [f64; 2, 2]
        \\    lookup: map[str, i32]
        \\    colors: [Color]
        \\    shade: Color
        \\    label: ?i64
        \\    points: [Point]
        \\make_box <- () -> Box:
        \\    box := Box {
        \\        name: "box",
        \\        vector: [1, 2, 3, 4],
        \\        grid: [[1.0, 2.0], [3.0, 4.0]],
        \\        lookup: map[str, i32] { "a": 1, "bb": 2 },
        \\        colors: [Color::Red, Color::Rgb(1, 2, 3)],
        \\        shade: Color::Rgb(4, 5, 6),
        \\        label: nil,
        \\        points: [Point { x: 1.5, tag: "p" }],
        \\    }
        \\    box
        \\shade_value <- (color: Color) -> i64:
        \\    match color:
        \\        Red: 1
        \\        Rgb(r, g, b): r + g + b
        \\encode_box <- () -> str:
        \\    json::encode(make_box())
        \\roundtrip <- () -> i64:
        \\    text := json::encode(make_box())
        \\    copy := json::decode::<Box>(text)
        \\    total := copy.vector[2] as i64
        \\    total = total + f32::to_milli(copy.grid[1, 0])
        \\    total = total + (copy.lookup["a"] as i64) + (copy.lookup["bb"] as i64)
        \\    total = total + (copy.name.len() as i64)
        \\    total = total + (copy.points.len() as i64) + f32::to_milli(copy.points[0].x)
        \\    total = total + shade_value(copy.shade)
        \\    total = total + (copy.colors.len() as i64)
        \\    total
        \\unknown_fields <- () -> i64:
        \\    p := json::decode::<Point>("{\"extra\": true, \"tag\": \"ab\", \"x\": 2.5}")
        \\    f32::to_milli(p.x) + (p.tag.len() as i64)
        \\missing_field <- () -> i64:
        \\    p := json::decode::<Point>("{\"x\": 1.0}")
        \\    if ffi::handle(p) == 0:
        \\        ret 1
        \\    ret 0
        \\malformed <- () -> i64:
        \\    p := json::decode::<Point>("{oops}")
        \\    if ffi::handle(p) == 0:
        \\        ret 1
        \\    ret 0
        \\unicode_roundtrip <- () -> i64:
        \\    text := json::encode(Point { x: 2.5, tag: "héllo 😀" })
        \\    p := json::decode::<Point>(text)
        \\    f32::to_milli(p.x) + (p.tag.len() as i64)
        \\encode_primitive <- () -> str:
        \\    json::encode(42)
        \\encode_vector <- () -> str:
        \\    json::encode([1.5, 2.5])
        \\encode_string <- () -> str:
        \\    json::encode("hi")
        \\decode_string <- () -> i64:
        \\    text := json::decode::<str>("\"ab\"")
        \\    text.len() as i64
    ;
    var compiled = compiler.pipeline.compile(std.testing.allocator, source, .{}) catch |err| {
        if (compiler.parser.parse(std.testing.allocator, source)) |parsed_result| {
            switch (parsed_result) {
                .ast => |tree_value| {
                    var tree = tree_value;
                    defer tree.deinit();
                    if (compiler.semantic.analyze(std.testing.allocator, tree.module)) |analysis_value| {
                        var analysis = analysis_value;
                        defer analysis.deinit();
                        for (analysis.diagnostics) |diagnostic| {
                            std.debug.print("json e7 semantic {}:{}: {s}\n", .{ diagnostic.span.line, diagnostic.span.column, diagnostic.message });
                        }
                    } else |_| {}
                },
                .diagnostic => |diagnostic| std.debug.print("json e7 parse: {s}\n", .{diagnostic.message}),
            }
        } else |_| {}
        return err;
    };
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());
    try std.testing.expectEqualStrings("E{Red=u;Rgb=(i,i,i)}", compiled.analysis.derive("Color").?.schema.?);
    try std.testing.expectEqualStrings(
        "{name=s;vector=A4:i;grid=M2:2:f;lookup=<s,i>;colors=[E{Red=u;Rgb=(i,i,i)}];shade=E{Red=u;Rgb=(i,i,i)};label=?i;points=[{x=f;tag=s}]}",
        compiled.analysis.derive("Box").?.schema.?,
    );

    const bytes = try compiler.bytecode.encode(std.testing.allocator, &compiled.bytecode);
    defer std.testing.allocator.free(bytes);
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecodeBytes(bytes, "json-complete");

    const I64 = *const fn () callconv(.c) i64;
    const Str = *const fn () callconv(.c) i64;

    const encode_box = try jit.get(Str, "encode_box");
    const encoded = encode_box();
    try std.testing.expect(encoded != 0);
    const encoded_len = aggregate.e7_str_len(encoded);
    try std.testing.expect(encoded_len > 0);
    const encoded_ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(encoded + 8)));
    const encoded_text = encoded_ptr[0..@intCast(encoded_len)];
    try std.testing.expect(std.mem.indexOf(u8, encoded_text, "\"grid\":[[1,2],[3,4]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded_text, "\"lookup\":{\"a\":1,\"bb\":2}") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded_text, "\"shade\":{\"Rgb\":[4,5,6]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded_text, "\"label\":null") != null);

    const roundtrip = try jit.get(I64, "roundtrip");
    // vector[2]=3 + grid[1,0]=3000 + lookup 1+2 + name len 3
    // + points len 1 + points[0].x 1500 + Rgb(4,5,6)=15 + colors len 2
    try std.testing.expectEqual(@as(i64, 4527), roundtrip());

    const unknown_fields = try jit.get(I64, "unknown_fields");
    try std.testing.expectEqual(@as(i64, 2502), unknown_fields());
    const missing_field = try jit.get(I64, "missing_field");
    try std.testing.expectEqual(@as(i64, 1), missing_field());
    const malformed = try jit.get(I64, "malformed");
    try std.testing.expectEqual(@as(i64, 1), malformed());
    const unicode_roundtrip = try jit.get(I64, "unicode_roundtrip");
    try std.testing.expectEqual(@as(i64, 2500 + 11), unicode_roundtrip());

    const encode_primitive = try jit.get(Str, "encode_primitive");
    const primitive = encode_primitive();
    try std.testing.expect(primitive != 0);
    const primitive_bytes = aggregate.e7_str_len(primitive);
    try std.testing.expectEqual(@as(i64, 2), primitive_bytes);

    const decode_string = try jit.get(I64, "decode_string");
    try std.testing.expectEqual(@as(i64, 2), decode_string());

    const encode_vector = try jit.get(Str, "encode_vector");
    const vector_text = encode_vector();
    try std.testing.expect(vector_text != 0);
    const vector_len = aggregate.e7_str_len(vector_text);
    const vector_ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(vector_text + 8)));
    try std.testing.expectEqualStrings("[1.5,2.5]", vector_ptr[0..@intCast(vector_len)]);

    const encode_string = try jit.get(Str, "encode_string");
    const string_text = encode_string();
    try std.testing.expect(string_text != 0);
    const string_len = aggregate.e7_str_len(string_text);
    const string_ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(string_text + 8)));
    try std.testing.expectEqualStrings("\"hi\"", string_ptr[0..@intCast(string_len)]);
}

fn readRepoTextRuntime(allocator: std.mem.Allocator, relative: []const u8) ?[]u8 {
    const prefixes = [_][]const u8{ "", "../", "../../" };
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    for (prefixes) |prefix| {
        const candidate = std.fmt.bufPrint(&buffer, "{s}{s}", .{ prefix, relative }) catch continue;
        const data = std.Io.Dir.readFileAlloc(
            std.Io.Dir.cwd(),
            std.testing.io,
            candidate,
            allocator,
            .limited(8 * 1024 * 1024),
        ) catch continue;
        return data;
    }
    return null;
}

fn readRepoTextForTest(comptime relative: []const u8) ?[]u8 {
    return readRepoTextRuntime(std.testing.allocator, relative);
}

/// One module for `compileProjectFromSources`.  Either inline `source` (a
/// synthesized module such as `mod gpu` or `mod events`) or a repo-relative
/// `path` is required.
const RepoModule = struct {
    name: []const u8,
    path: ?[]const u8 = null,
    source: ?[]const u8 = null,
};

const LoadedRepoModules = struct {
    sources: []compiler.pipeline.SourceFile,
    owned: [][]u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *LoadedRepoModules) void {
        for (self.owned) |buffer| self.allocator.free(buffer);
        self.allocator.free(self.owned);
        self.allocator.free(self.sources);
    }
};

/// Load repo sources into `SourceFile` entries for `compileProjectFromSources`,
/// failing the test (not skipping it) when a checked-in source is missing.
fn loadRepoModules(allocator: std.mem.Allocator, specs: []const RepoModule) !LoadedRepoModules {
    const sources = try allocator.alloc(compiler.pipeline.SourceFile, specs.len);
    errdefer allocator.free(sources);
    const owned = try allocator.alloc([]u8, specs.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |buffer| allocator.free(buffer);
        allocator.free(owned);
    }
    for (specs, 0..) |spec, index| {
        const source: []u8 = if (spec.source) |literal| blk: {
            break :blk try allocator.dupe(u8, literal);
        } else blk: {
            const path = spec.path orelse {
                std.debug.print("module '{s}' has neither repo path nor inline source\n", .{spec.name});
                return error.TestUnexpectedResult;
            };
            break :blk readRepoTextRuntime(allocator, path) orelse {
                std.debug.print("missing checked-in module source '{s}': {s}\n", .{ spec.name, path });
                return error.TestUnexpectedResult;
            };
        };
        owned[index] = source;
        sources[index] = .{ .name = spec.name, .source = source };
        initialized += 1;
    }
    return .{ .sources = sources, .owned = owned, .allocator = allocator };
}

/// Read one RGBA8 pixel from a captured frame as a little-endian u32
/// (`0xAABBGGRR`-free canonical RGBA bytes become 0xAABBGGRR when read LE).
fn rgbaPixel(pixels: []const u8, width: usize, x: usize, y: usize) u32 {
    const offset = (y * width + x) * 4;
    return std.mem.readInt(u32, pixels[offset..][0..4], .little);
}

/// Engine platform modules import `platform::engine_window` / `engine_scene`
/// and the generated scene layer binds SDL/Vulkan through the generic C FFI.
const platform_module_specs = [_]RepoModule{
    .{ .name = "platform", .path = "engine/platform/main.e7" },
    .{ .name = "text", .path = "engine/platform/text.e7" },
    .{ .name = "sdl", .path = "engine/platform/sdl.e7" },
    .{ .name = "vulkan", .path = "engine/platform/vulkan.e7" },
    .{ .name = "scene", .path = "engine/platform/scene.e7" },
    .{ .name = "engine_window", .path = "engine/platform/engine_window.e7" },
    .{ .name = "engine_scene", .path = "engine/platform/engine_scene.e7" },
    .{ .name = "audio", .path = "engine/platform/audio.e7" },
};

const core_module_specs = [_]RepoModule{
    .{ .name = "core", .source = "mod events\nmod ecs\nmod time\nmod input\nmod camera\nmod window\n" },
    .{ .name = "events", .path = "engine/core/events.e7" },
    .{ .name = "ecs", .path = "engine/core/ecs.e7" },
    .{ .name = "time", .path = "engine/core/time.e7" },
    .{ .name = "input", .path = "engine/core/input.e7" },
    .{ .name = "camera", .path = "engine/core/camera.e7" },
    .{ .name = "window", .path = "engine/core/window.e7" },
};

const physics_module_specs = [_]RepoModule{
    .{ .name = "physics", .path = "engine/physics/main.e7" },
    .{ .name = "broadphase", .path = "engine/physics/broadphase.e7" },
    .{ .name = "narrowphase", .path = "engine/physics/narrowphase.e7" },
};

/// `engine/gfx/main.e7` also declares a `scene` submodule, which would collide
/// with `engine/platform/scene.e7` in the flat in-memory module namespace, so
/// synthesize a gfx root that only pulls in `gpu`.
const gfx_module_specs = [_]RepoModule{
    .{ .name = "gfx", .source = "mod gpu\n" },
    .{ .name = "gpu", .path = "engine/gfx/gpu.e7" },
};

const asset_module_specs = [_]RepoModule{
    .{ .name = "assets", .path = "engine/assets/main.e7" },
    .{ .name = "obj", .path = "engine/assets/obj.e7" },
    .{ .name = "server", .path = "engine/assets/server.e7" },
};

const engine_physics_module_specs =
    core_module_specs ++ platform_module_specs ++ physics_module_specs;
const engine_asset_module_specs =
    core_module_specs ++ platform_module_specs ++ gfx_module_specs ++ asset_module_specs;

test "JIT executes the generic text and parsing intrinsics" {
    var compiled = try compiler.pipeline.compile(
        std.testing.allocator,
        \\main <- () -> i32:
        \\    lines := str::lines("aa\nbb\ncc")
        \\    fields := str::fields(" x  y ")
        \\    parts := str::split("1/2/3", "/")
        \\    number := i64::parse("-42")
        \\    value := f32::parse("1.5")
        \\    values: [f32] := []
        \\    values = vec::push(values, value)
        \\    number32 := number as i32
        \\    ret lines.len() * 100000 + fields.len() * 10000 + parts.len() * 1000 + (0 - number32) * 10 + values.len()
    ,
        .{},
    );
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());

    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "text-intrinsics");
    const Main = *const fn () callconv(.c) i64;
    const main = try jit.get(Main, "main");
    try std.testing.expectEqual(@as(i64, 323421), main());
}

test "JIT loads an image through the e7 image intrinsics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "cube.png",
        .data = @embedFile("testdata/cube.png"),
    });
    const absolute = try tmp.dir.realPathFileAlloc(std.testing.io, "cube.png", std.testing.allocator);
    defer std.testing.allocator.free(absolute);

    const source = try std.fmt.allocPrint(
        std.testing.allocator,
        \\main <- () -> i32:
        \\    image := image::load("{s}")
        \\    width := image::width(image) as i32
        \\    height := image::height(image) as i32
        \\    pixels := image::pixels(image)
        \\    image::free(image)
        \\    ret width * 10 + height + pixels.len() * 0
    ,
        .{absolute},
    );
    defer std.testing.allocator.free(source);

    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());

    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "image-intrinsics");
    const Main = *const fn () callconv(.c) i64;
    const main = try jit.get(Main, "main");
    try std.testing.expectEqual(@as(i64, 22), main());
}

test "JIT executes the compiled e7 OBJ parser from engine/assets/obj.e7" {
    var modules = try loadRepoModules(std.testing.allocator, &engine_asset_module_specs);
    defer modules.deinit();

    const root_source =
        \\mod platform
        \\mod core
        \\mod gfx
        \\mod obj
        \\main <- () -> i32:
        \\    quad := obj::parse_obj(
        \\        "v 0 0 0\nv 1 0 0\nv 0 1 0\nv 1 1 0\nvn 0 0 1\nf 1//1 2//1 3//1 4//1\n"
        \\    )
        \\    tris := obj::parse_obj("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n")
        \\    relative := obj::parse_obj("v 0 0 0\nv 1 0 0\nv 0 1 0\nf -3 -2 -1\n")
        \\    full := obj::parse_obj(
        \\        "v 0 0 0\nv 1 0 0\nv 0 1 0\nv 1 1 0\nvn 0 0 1\nvt 0 0\nf 1/1/1 2/1/1 3/1/1 4/1/1\n"
        \\    )
        \\    malformed := obj::parse_obj("f 1 2 3\n")
        \\    ret quad.indices.len() * 100000 + quad.positions.len() * 10000 + tris.indices.len() * 1000 + relative.indices.len() + full.indices.len() + malformed.indices.len() * 100000000
    ;
    var compiled = try compiler.pipeline.compileProjectFromSources(
        std.testing.allocator,
        root_source,
        modules.sources,
        .{},
    );
    defer compiled.deinit();
    if (!compiled.analysis.ok()) {
        for (compiled.analysis.diagnostics) |diagnostic| {
            std.debug.print("OBJ semantic: {}:{} {s}\n", .{ diagnostic.span.line, diagnostic.span.column, diagnostic.message });
        }
    }
    try std.testing.expect(compiled.analysis.ok());
    try compiler.bytecode.verify(std.testing.allocator, &compiled.bytecode);

    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "obj-parser");
    const Main = *const fn () callconv(.c) i64;
    const main = try jit.get(Main, "main");
    // quad: 2 triangles (6 indices), 4 positions -> 12 flat floats;
    // triangle/negative-relative/full faces contribute 3+3+6 indices; the
    // malformed face contributes nothing.
    try std.testing.expectEqual(@as(i64, 600000 + 120000 + 3000 + 3 + 6), main());
}

test "JIT runs the AssetsPlugin and loads the checked-in image and OBJ" {
    var modules = try loadRepoModules(std.testing.allocator, &engine_asset_module_specs);
    defer modules.deinit();

    const root_source =
        \\mod platform
        \\mod core
        \\mod gfx
        \\mod assets
        \\main <- async () -> i32:
        \\    commands := await query &mut Commands
        \\    commands.add_plugin(assets::AssetsPlugin)
        \\    disown commands
        \\    0
    ;
    var compiled = try compiler.pipeline.compileProjectFromSources(
        std.testing.allocator,
        root_source,
        modules.sources,
        .{},
    );
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());

    ecs.e7_ecs_reset();
    defer ecs.e7_ecs_reset();

    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "assets-plugin");
    const Main = *const fn () callconv(.c) i64;
    const main_ctor = try jit.get(Main, "main");
    const task_handle = main_ctor();
    try std.testing.expect(task_handle != 0);
    try std.testing.expectEqual(@as(i64, 0), task.e7_task_await(task_handle));

    const assets_info = compiled.analysis.resource("assets::Assets") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 1), ecs.e7_ecs_has_resource(assets_info.id));
    const assets_ptr = ecs.e7_ecs_resource(assets_info.id);
    try std.testing.expect(assets_ptr != 0);

    // Assets fields: [0] Image pointer, [1] ObjMesh pointer.
    const image_ptr = aggregate.e7_load_i64(assets_ptr);
    const mesh_ptr = aggregate.e7_load_i64(assets_ptr + 8);
    try std.testing.expect(image_ptr != 0);
    try std.testing.expect(mesh_ptr != 0);

    // Image fields: handle, width, height, pixels.
    const image_handle = aggregate.e7_load_i64(image_ptr);
    try std.testing.expect(image_handle != 0);
    try std.testing.expectEqual(@as(i64, 2), aggregate.e7_load_i64(image_ptr + 8));
    try std.testing.expectEqual(@as(i64, 2), aggregate.e7_load_i64(image_ptr + 16));
    try std.testing.expectEqual(@as(i64, 16), aggregate.e7_str_len(aggregate.e7_load_i64(image_ptr + 24)));
    defer _ = image.e7_image_free(image_handle);

    // ObjMesh fields: positions, normals, uvs, vertices, indices.
    const positions = aggregate.e7_load_i64(mesh_ptr);
    const indices = aggregate.e7_load_i64(mesh_ptr + 32);
    const vertices = aggregate.e7_load_i64(mesh_ptr + 24);
    try std.testing.expectEqual(@as(i64, 24), aggregate.e7_vec_len(positions)); // 8 positions * 3
    try std.testing.expectEqual(@as(i64, 36), aggregate.e7_vec_len(indices)); // 6 quads -> 12 triangles
    try std.testing.expectEqual(@as(i64, 288), aggregate.e7_vec_len(vertices)); // 36 vertices * 8 floats
}

fn makeTestString(text: []const u8) i64 {
    return aggregate.e7_str_new(@intCast(@intFromPtr(text.ptr)), @intCast(text.len));
}

fn mapFindString(map: i64, key: []const u8) ?i64 {
    const count = aggregate.e7_map_len(map);
    var index: i64 = 0;
    while (index < count) : (index += 1) {
        const key_handle = aggregate.e7_map_key_at(map, index);
        const key_len = aggregate.e7_str_len(key_handle);
        if (key_len != key.len) continue;
        const key_ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(key_handle + 8)));
        if (std.mem.eql(u8, key_ptr[0..@intCast(key_len)], key)) {
            return aggregate.e7_map_value_at(map, index);
        }
    }
    return null;
}

test "host list_dir lists cwd-relative directories in the fs list format" {
    const candidates = [_][]const u8{ "engine/assets", "../engine/assets", "../../engine/assets" };
    var listing: ?[]const u8 = null;
    for (candidates) |candidate| {
        const handle = host_engine.e7_engine_list_dir(makeTestString(candidate));
        if (handle == 0) continue;
        const length = aggregate.e7_str_len(handle);
        const ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(handle + 8)));
        listing = ptr[0..@intCast(length)];
        break;
    }
    const text = listing orelse return error.SkipZigTest;
    // Directories carry a trailing '/', files do not, one entry per line.
    try std.testing.expect(std.mem.indexOf(u8, text, "audio/\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "images/\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "meshes/\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "testdata/\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "main.e7\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "server.e7\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cube.obj\n") != null);
    // Missing directories report failure to e7 (0), which scans treat as empty.
    try std.testing.expectEqual(@as(i64, 0), host_engine.e7_engine_list_dir(makeTestString("engine/assets/does-not-exist")));
}

test "JIT runs the AssetServer plugin and scans nested asset folders" {
    var modules = try loadRepoModules(std.testing.allocator, &engine_asset_module_specs);
    defer modules.deinit();

    const root_source =
        \\mod platform
        \\mod core
        \\mod gfx
        \\mod assets
        \\main <- async () -> i32:
        \\    commands := await query &mut Commands
        \\    commands.add_plugin(assets::AssetServerPlugin)
        \\    commands.add_plugin(assets::AssetsPlugin)
        \\    disown commands
        \\    await Init()
        \\    ret 0
    ;
    var compiled = try compiler.pipeline.compileProjectFromSources(
        std.testing.allocator,
        root_source,
        modules.sources,
        .{},
    );
    defer compiled.deinit();
    if (!compiled.analysis.ok()) {
        for (compiled.analysis.diagnostics) |diagnostic| {
            std.debug.print("asset server semantic: {}:{} {s}\n", .{ diagnostic.span.line, diagnostic.span.column, diagnostic.message });
        }
    }
    try std.testing.expect(compiled.analysis.ok());

    host.setHeadless(true);
    defer host.reset();
    ecs.e7_ecs_reset();
    defer ecs.e7_ecs_reset();

    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "asset-server");
    const Load = *const fn () callconv(.c) i64;
    const load = try jit.get(Load, "main");
    const task_handle = load();
    try std.testing.expect(task_handle != 0);
    try std.testing.expectEqual(@as(i64, 0), task.e7_task_await(task_handle));

    const server_info = compiled.analysis.resource("assets::AssetServer") orelse return error.TestUnexpectedResult;
    const server_ptr = ecs.e7_ecs_resource(server_info.id);
    try std.testing.expect(server_ptr != 0);

    // Field order: images, meshes, audio, image_root, mesh_root, audio_root.
    // ImageAssets -> AssetCollection<Image> -> [files map, folders map].
    const images_assets = aggregate.e7_load_i64(server_ptr);
    const images_collection = aggregate.e7_load_i64(images_assets);
    const image_files = aggregate.e7_load_i64(images_collection);
    const image_folders = aggregate.e7_load_i64(images_collection + 8);
    try std.testing.expectEqual(@as(i64, 1), aggregate.e7_map_len(image_files));
    const image_ptr = mapFindString(image_files, "cube/cube.png") orelse return error.TestUnexpectedResult;
    try std.testing.expect(mapFindString(image_files, "engine/assets/images/cube/cube.png") == null);
    try std.testing.expect(aggregate.e7_load_i64(image_ptr) != 0); // runtime image handle
    try std.testing.expectEqual(@as(i64, 2), aggregate.e7_load_i64(image_ptr + 8));
    try std.testing.expectEqual(@as(i64, 2), aggregate.e7_load_i64(image_ptr + 16));
    try std.testing.expectEqual(@as(i64, 16), aggregate.e7_str_len(aggregate.e7_load_i64(image_ptr + 24)));
    try std.testing.expectEqual(@as(i64, 1), aggregate.e7_map_len(image_folders));
    const cube_folder = mapFindString(image_folders, "cube") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 1), aggregate.e7_map_len(cube_folder));
    try std.testing.expectEqual(image_ptr, mapFindString(cube_folder, "cube.png").?);

    // MeshAssets: one nested OBJ parsed into the same 36-index cube mesh.
    const meshes_assets = aggregate.e7_load_i64(server_ptr + 8);
    const meshes_collection = aggregate.e7_load_i64(meshes_assets);
    const mesh_files = aggregate.e7_load_i64(meshes_collection);
    const mesh_folders = aggregate.e7_load_i64(meshes_collection + 8);
    try std.testing.expectEqual(@as(i64, 1), aggregate.e7_map_len(mesh_files));
    const mesh_ptr = mapFindString(mesh_files, "cube/cube.obj") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 36), aggregate.e7_vec_len(aggregate.e7_load_i64(mesh_ptr + 32)));
    try std.testing.expectEqual(@as(i64, 1), aggregate.e7_map_len(mesh_folders));
    try std.testing.expect(mapFindString(mesh_folders, "cube") != null);

    // AudioAssets: the nested WAV decodes to the 100 ms 440 Hz mono fixture.
    const audio_assets = aggregate.e7_load_i64(server_ptr + 16);
    const audio_collection = aggregate.e7_load_i64(audio_assets);
    const audio_files = aggregate.e7_load_i64(audio_collection);
    const audio_folders = aggregate.e7_load_i64(audio_collection + 8);
    try std.testing.expectEqual(@as(i64, 1), aggregate.e7_map_len(audio_files));
    const clip_ptr = mapFindString(audio_files, "sfx/tone.wav") orelse return error.TestUnexpectedResult;
    try std.testing.expect(aggregate.e7_load_i64(clip_ptr) != 0); // PCM data
    try std.testing.expectEqual(@as(i64, 8820), aggregate.e7_load_i64(clip_ptr + 8));
    try std.testing.expectEqual(@as(i64, 1), aggregate.e7_map_len(audio_folders));
    try std.testing.expect(mapFindString(audio_folders, "sfx") != null);

    // Legacy AssetsPlugin fallback still populates the fixed sample assets.
    const assets_info = compiled.analysis.resource("assets::Assets") orelse return error.TestUnexpectedResult;
    const assets_ptr = ecs.e7_ecs_resource(assets_info.id);
    try std.testing.expect(assets_ptr != 0);
    try std.testing.expect(aggregate.e7_load_i64(assets_ptr) != 0); // Image pointer
    try std.testing.expect(aggregate.e7_load_i64(assets_ptr + 8) != 0); // ObjMesh pointer

    // The plugin owns the audio subsystem so one-shot playback has a system.
    const audio_system_info = compiled.analysis.resource("platform::audio::AudioSystem") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 1), ecs.e7_ecs_has_resource(audio_system_info.id));
}

test "JIT executes broadphase aggregation and narrowphase helpers" {
    const broad_source = readRepoTextForTest("engine/physics/broadphase.e7") orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(broad_source);
    const narrow_source = readRepoTextForTest("engine/physics/narrowphase.e7") orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(narrow_source);

    // Minimal shared type surface; the real engine uses physics.e7's copies.
    const root_source =
        \\mod physics_broadphase
        \\mod physics_narrowphase
        \\Vec3 <- struct
        \\    x: f32
        \\    y: f32
        \\    z: f32
        \\Ray <- struct
        \\    origin: Vec3
        \\    direction: Vec3
        \\Aabb <- struct
        \\    min: Vec3
        \\    max: Vec3
        \\RayHit <- struct
        \\    hit: bool
        \\    distance: f32
        \\    point: Vec3
        \\ray_sphere <- (ray: Ray, center: Vec3, radius: f32) -> RayHit = RayHit { hit: false, distance: 0.0, point: center }
        \\main <- () -> i32:
        \\    a := Aabb { min: Vec3 { x: 0.0, y: 0.0, z: 0.0 }, max: Vec3 { x: 2.0, y: 2.0, z: 2.0 } }
        \\    b := Aabb { min: Vec3 { x: 1.0, y: 1.0, z: 1.0 }, max: Vec3 { x: 3.0, y: 3.0, z: 3.0 } }
        \\    overlapping := aabb_overlap(a, b)
        \\    push := aabb_penetration(
        \\        Aabb { min: Vec3 { x: 0.0, y: 0.0, z: 0.0 }, max: Vec3 { x: 2.0, y: 2.0, z: 2.0 } },
        \\        Aabb { min: Vec3 { x: 1.0, y: 1.0, z: 1.0 }, max: Vec3 { x: 3.0, y: 3.0, z: 3.0 } },
        \\    )
        \\    plane_hit := plane_aabb_overlap(
        \\        Vec3 { x: 0.0, y: 1.0, z: 0.0 },
        \\        0.0,
        \\        Aabb { min: Vec3 { x: -1.0, y: -1.0, z: -1.0 }, max: Vec3 { x: 1.0, y: 1.0, z: 1.0 } },
        \\    )
        \\    hit := ray_plane(
        \\        Ray { origin: Vec3 { x: 0.0, y: 1.0, z: 0.0 }, direction: Vec3 { x: 0.0, y: -1.0, z: 0.0 } },
        \\        Vec3 { x: 0.0, y: 1.0, z: 0.0 },
        \\        0.0,
        \\    )
        \\    cells := map[i64, [i64]] {}
        \\    key := cell_key(0, 0, 0)
        \\    cells[key] = vec::push(cells[key], 7)
        \\    spatial := SpatialMap {
        \\        cell_size: 2.0,
        \\        cells: cells,
        \\        ids: [],
        \\        bounds: [],
        \\        count: 1,
        \\    }
        \\    found := query_region(
        \\        &spatial,
        \\        Vec3 { x: 0.2, y: 0.2, z: 0.2 },
        \\        Vec3 { x: 0.4, y: 0.4, z: 0.4 },
        \\    )
        \\    score := 0
        \\    if overlapping:
        \\        score = score + 1
        \\    if push.x < 0.0:
        \\        score = score + 10
        \\    if plane_hit:
        \\        score = score + 100
        \\    if hit.hit:
        \\        score = score + 1000
        \\    if found.len() == 1:
        \\        if found[0] == 7:
        \\            score = score + 10000
        \\    ret score
    ;
    var compiled = try compiler.pipeline.compileProjectFromSources(
        std.testing.allocator,
        root_source,
        &.{
            .{ .name = "physics_broadphase", .source = broad_source },
            .{ .name = "physics_narrowphase", .source = narrow_source },
        },
        .{},
    );
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());

    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "physics-broad-narrow");
    const Main = *const fn () callconv(.c) i64;
    const main = try jit.get(Main, "main");
    try std.testing.expectEqual(@as(i64, 11111), main());
}

test "JIT removes, re-adds, and despawns dynamic ECS markers" {
    ecs.e7_ecs_reset();
    defer ecs.e7_ecs_reset();

    var compiled = try compiler.pipeline.compile(
        std.testing.allocator,
        \\@Components
        \\Counter <- struct
        \\    b: i32
        \\@Components
        \\Held <- struct
        \\@resource
        \\Report <- struct
        \\    value: i32
        \\Components <- table
        \\    entity_id: usize,
        \\    ...
        \\Remove <- trigger
        \\Attach <- trigger
        \\Capture <- trigger
        \\Despawn <- trigger
        \\@trigger(Remove)
        \\remove_sys <- sys (commands: &mut Commands, pairs: select &mut Held, &mut Counter from Components):
        \\    for (held, counter) in pairs:
        \\        counter.b = counter.b + 1
        \\        commands.remove_component::<Held>(pairs.entity())
        \\@trigger(Attach)
        \\attach_sys <- sys (commands: &mut Commands, counters: select &mut Counter from Components):
        \\    for counter in counters:
        \\        commands.add_component::<Held>(counters.entity(), Held {})
        \\@trigger(Capture)
        \\capture_sys <- sys (report: res &mut Report, counters: select &Counter from Components):
        \\    total := 0
        \\    for counter in counters:
        \\        total = total + counter.b
        \\    report.value = total
        \\@trigger(Despawn)
        \\despawn_sys <- sys (commands: &mut Commands, counters: select &mut Counter from Components):
        \\    for counter in counters:
        \\        commands.despawn(counters.entity())
        \\main <- async () -> i32:
        \\    commands := await query &mut Commands
        \\    commands.insert_resource(Report { value: 0 })
        \\    counter := Counter { b: 0 }
        \\    held := Held
        \\    commands.add_row(Components, { counter, held })
        \\    disown commands
        \\    await Remove()
        \\    await Attach()
        \\    await Remove()
        \\    await Capture()
        \\    await Despawn()
        \\    ret 0
    ,
        .{},
    );
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());
    const counter_component = compiled.analysis.component("Counter").?;
    const held_component = compiled.analysis.component("Held").?;
    const report_resource = compiled.analysis.resource("Report").?;

    for (compiled.analysis.resources) |resource| {
        try std.testing.expectEqual(@as(i32, 0), ecs.e7_ecs_register_resource(resource.id, @intCast(resource.slots)));
    }
    for (compiled.analysis.components) |component| {
        try std.testing.expectEqual(@as(i32, 0), ecs.e7_ecs_register_component(component.id, @intCast(component.slots)));
    }

    const bytes = try compiler.bytecode.encode(std.testing.allocator, &compiled.bytecode);
    defer std.testing.allocator.free(bytes);
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecodeBytes(bytes, "ecs-removal");
    const Main = *const fn () callconv(.c) i64;
    const main_ctor = try jit.get(Main, "main");
    const handle = main_ctor();
    try std.testing.expect(handle != 0);
    try std.testing.expectEqual(@as(i64, 0), task.e7_task_await(handle));

    // Two remove passes incremented the counter before the final despawn.
    const report_ptr = ecs.e7_ecs_resource(report_resource.id);
    try std.testing.expect(report_ptr != 0);
    const report_values: [*]const i64 = @ptrFromInt(@as(usize, @intCast(report_ptr)));
    try std.testing.expectEqual(@as(i64, 2), report_values[0]);

    // The only entity was despawned: dead, no component presence, and neither
    // projection nor zero-projection queries report it any more.
    try std.testing.expectEqual(@as(i64, 1), ecs.e7_ecs_entity_count());
    try std.testing.expectEqual(@as(i64, 0), ecs.e7_ecs_entity_alive(0));
    try std.testing.expectEqual(@as(i64, 0), ecs.e7_ecs_component_get(0, counter_component.id));
    try std.testing.expectEqual(@as(i64, 0), ecs.e7_ecs_component_get(0, held_component.id));

    var ids = [_]i64{ counter_component.id, held_component.id };
    var muts = [_]i64{ 0, 0 };
    var query = ecs.e7_ecs_query_begin(1, @intCast(@intFromPtr(&ids)), @intCast(@intFromPtr(&muts)), -1);
    try std.testing.expectEqual(@as(i64, 0), ecs.e7_ecs_query_next(query));
    query = ecs.e7_ecs_query_begin(0, 0, 0, held_component.id);
    try std.testing.expectEqual(@as(i64, 0), ecs.e7_ecs_query_next(query));

    // Re-adding components to a live entity keeps working after despawn of
    // another id; spawn a fresh row and verify presence is independent.
    const cmd = ecs.e7_ecs_commands();
    const row = ecs.e7_ecs_commands_row_begin(cmd);
    var value: i64 = 5;
    try std.testing.expectEqual(@as(i32, 0), ecs.e7_ecs_commands_row_add(row, counter_component.id, @intCast(@intFromPtr(&value))));
    try std.testing.expectEqual(@as(i32, 0), ecs.e7_ecs_commands_row_add(row, held_component.id, 0));
    try std.testing.expectEqual(@as(i32, 0), ecs.e7_ecs_commands_row_finish(row));
    try std.testing.expectEqual(@as(i32, 0), ecs.e7_ecs_commands_flush(cmd));
    try std.testing.expectEqual(@as(i64, 1), ecs.e7_ecs_entity_alive(1));
    try std.testing.expect(ecs.e7_ecs_component_get(1, counter_component.id) != 0);
    query = ecs.e7_ecs_query_begin(1, @intCast(@intFromPtr(&ids)), @intCast(@intFromPtr(&muts)), -1);
    try std.testing.expectEqual(@as(i64, 2), ecs.e7_ecs_query_next(query));
    try std.testing.expectEqual(@as(i64, 0), ecs.e7_ecs_query_next(query));
}

test "JIT executes quaternion, OBB, and oriented capsule narrowphase" {
    const broad_source = readRepoTextForTest("engine/physics/broadphase.e7") orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(broad_source);
    const narrow_source = readRepoTextForTest("engine/physics/narrowphase.e7") orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(narrow_source);

    const root_source =
        \\mod physics_broadphase
        \\mod physics_narrowphase
        \\Vec3 <- struct
        \\    x: f32
        \\    y: f32
        \\    z: f32
        \\Ray <- struct
        \\    origin: Vec3
        \\    direction: Vec3
        \\Aabb <- struct
        \\    min: Vec3
        \\    max: Vec3
        \\RayHit <- struct
        \\    hit: bool
        \\    distance: f32
        \\    point: Vec3
        \\ray_sphere <- (ray: Ray, center: Vec3, radius: f32) -> RayHit = RayHit { hit: false, distance: 0.0, point: center }
        \\main <- () -> i32:
        \\    normalized := quat_normalize(Quat { x: 2.0, y: 0.0, z: 0.0, w: 0.0 })
        \\    norm_length := f32::sqrt(normalized.x * normalized.x + normalized.y * normalized.y + normalized.z * normalized.z + normalized.w * normalized.w)
        \\    rotated_x := quat_rotate(quat_from_euler(0.0, 0.0, 1.5707963), Vec3 { x: 1.0, y: 0.0, z: 0.0 })
        \\    multiplied := quat_mul(quat_from_euler(0.0, 0.0, 0.7853982), quat_from_euler(0.0, 0.0, 0.7853982))
        \\    multiplied_x := quat_rotate(multiplied, Vec3 { x: 1.0, y: 0.0, z: 0.0 })
        \\    integrated := quat_integrate(quat_identity(), Vec3 { x: 0.0, y: 0.0, z: 1.0 }, 0.016)
        \\    integrated_length := f32::sqrt(integrated.x * integrated.x + integrated.y * integrated.y + integrated.z * integrated.z + integrated.w * integrated.w)
        \\    integrated_x := quat_rotate(integrated, Vec3 { x: 1.0, y: 0.0, z: 0.0 })
        \\    overlapping := obb_obb_manifold(
        \\        Obb { center: Vec3 { x: 0.0, y: 0.0, z: 0.0 }, half_extents: Vec3 { x: 1.0, y: 1.0, z: 1.0 }, orientation: quat_identity() },
        \\        Obb { center: Vec3 { x: 1.5, y: 0.0, z: 0.0 }, half_extents: Vec3 { x: 1.0, y: 1.0, z: 1.0 }, orientation: quat_identity() },
        \\    )
        \\    separated := obb_obb_manifold(
        \\        Obb { center: Vec3 { x: 0.0, y: 0.0, z: 0.0 }, half_extents: Vec3 { x: 1.0, y: 1.0, z: 1.0 }, orientation: quat_identity() },
        \\        Obb { center: Vec3 { x: 3.0, y: 0.0, z: 0.0 }, half_extents: Vec3 { x: 1.0, y: 1.0, z: 1.0 }, orientation: quat_identity() },
        \\    )
        \\    rotated_overlap := obb_obb_manifold(
        \\        Obb { center: Vec3 { x: 0.0, y: 0.0, z: 0.0 }, half_extents: Vec3 { x: 1.0, y: 1.0, z: 1.0 }, orientation: quat_identity() },
        \\        Obb { center: Vec3 { x: 0.8, y: 0.0, z: 0.0 }, half_extents: Vec3 { x: 1.0, y: 1.0, z: 1.0 }, orientation: quat_from_euler(0.0, 0.7853982, 0.0) },
        \\    )
        \\    sideways := quat_from_euler(0.0, 0.0, 1.5707963)
        \\    sideways_axis := quat_rotate(sideways, Vec3 { x: 0.0, y: 1.0, z: 0.0 })
        \\    capsule_plane := capsule_plane_manifold(
        \\        Vec3 { x: 0.0, y: 0.3, z: 0.0 }, 0.4, 0.6,
        \\        quat_from_euler(0.0, 0.0, 1.5707963),
        \\        Vec3 { x: 0.0, y: 1.0, z: 0.0 }, 0.0)
        \\    capsule_box := capsule_obb_manifold(
        \\        Vec3 { x: 0.0, y: 1.0, z: 0.0 }, 0.4, 0.6, quat_identity(),
        \\        Obb { center: Vec3 { x: 0.7, y: 1.0, z: 0.0 }, half_extents: Vec3 { x: 0.5, y: 1.0, z: 1.0 }, orientation: quat_identity() })
        \\    capsule_capsule := capsule_capsule_manifold(
        \\        Vec3 { x: 0.0, y: 1.0, z: 0.0 }, 0.2, 0.6, quat_identity(),
        \\        Vec3 { x: 0.3, y: 1.0, z: 0.0 }, 0.2, 0.6, quat_identity())
        \\    score := 0
        \\    if norm_length > 0.999 and norm_length < 1.001:
        \\        score = score + 1
        \\    if rotated_x.y > 0.999 and f32::abs(rotated_x.x) < 0.001:
        \\        score = score + 2
        \\    if multiplied_x.y > 0.999 and f32::abs(multiplied_x.x) < 0.001:
        \\        score = score + 4
        \\    if integrated_length > 0.999 and integrated_length < 1.001:
        \\        score = score + 8
        \\    if integrated_x.x > 0.9998 and integrated_x.x < 0.9999 and integrated_x.y > 0.0159 and integrated_x.y < 0.0161:
        \\        score = score + 16
        \\    if overlapping.hit:
        \\        score = score + 32
        \\    if overlapping.normal.x < -0.99:
        \\        score = score + 64
        \\    if overlapping.penetration > 0.499 and overlapping.penetration < 0.501:
        \\        score = score + 128
        \\    if not separated.hit:
        \\        score = score + 256
        \\    if rotated_overlap.hit and rotated_overlap.penetration > 0.1:
        \\        score = score + 512
        \\    if f32::abs(sideways_axis.x) > 0.999 and f32::abs(sideways_axis.y) < 0.001:
        \\        score = score + 1024
        \\    if capsule_plane.hit and capsule_plane.penetration > 0.099 and capsule_plane.penetration < 0.101:
        \\        score = score + 2048
        \\    if capsule_box.hit and capsule_box.penetration > 0.199 and capsule_box.penetration < 0.201 and capsule_box.normal.x < -0.99:
        \\        score = score + 4096
        \\    if capsule_capsule.hit and capsule_capsule.penetration > 0.099 and capsule_capsule.penetration < 0.101 and capsule_capsule.normal.x < -0.99:
        \\        score = score + 8192
        \\    identity_matrix := quat_to_mat3(quat_identity())
        \\    yaw_matrix := quat_to_mat3(quat_from_euler(0.0, 0.0, 1.5707963))
        \\    yaw_x := mat3_mul_vec(yaw_matrix, Vec3 { x: 1.0, y: 0.0, z: 0.0 })
        \\    y_axis_matrix := quat_to_mat3(quat_from_euler(0.0, 1.5707963, 0.0))
        \\    y_axis_x := mat3_mul_vec(y_axis_matrix, Vec3 { x: 1.0, y: 0.0, z: 0.0 })
        \\    matrix_q := quat_from_euler(0.3, 0.4, 0.5)
        \\    matrix_v := Vec3 { x: 0.2, y: -0.7, z: 1.1 }
        \\    by_matrix := mat3_mul_vec(quat_to_mat3(matrix_q), matrix_v)
        \\    by_quat := quat_rotate(quat_from_euler(0.3, 0.4, 0.5), Vec3 { x: 0.2, y: -0.7, z: 1.1 })
        \\    euler_roundtrip := quat_to_euler(quat_from_euler(0.3, 0.4, 0.5))
        \\    det_matrix := quat_to_mat3(quat_from_euler(0.3, 0.4, 0.5))
        \\    if f32::abs(identity_matrix.m00 - 1.0) < 0.0001 and f32::abs(identity_matrix.m11 - 1.0) < 0.0001 and f32::abs(identity_matrix.m22 - 1.0) < 0.0001 and f32::abs(identity_matrix.m01) < 0.0001:
        \\        score = score + 16384
        \\    # +90 around Z (right-handed) maps +X to +Y.
        \\    if f32::abs(yaw_x.y - 1.0) < 0.001 and f32::abs(yaw_x.x) < 0.001:
        \\        score = score + 32768
        \\    # +90 around Y (right-handed) maps +X to -Z.
        \\    if f32::abs(y_axis_x.z + 1.0) < 0.001 and f32::abs(y_axis_x.x) < 0.001:
        \\        score = score + 262144
        \\    if f32::abs(by_matrix.x - by_quat.x) < 0.001 and f32::abs(by_matrix.y - by_quat.y) < 0.001 and f32::abs(by_matrix.z - by_quat.z) < 0.001:
        \\        score = score + 65536
        \\    if f32::abs(euler_roundtrip.x - 0.3) < 0.01 and f32::abs(euler_roundtrip.y - 0.4) < 0.01 and f32::abs(euler_roundtrip.z - 0.5) < 0.01:
        \\        score = score + 131072
        \\    det := det_matrix.m00 * (det_matrix.m11 * det_matrix.m22 - det_matrix.m12 * det_matrix.m21) - det_matrix.m01 * (det_matrix.m10 * det_matrix.m22 - det_matrix.m12 * det_matrix.m20) + det_matrix.m02 * (det_matrix.m10 * det_matrix.m21 - det_matrix.m11 * det_matrix.m20)
        \\    if f32::abs(det - 1.0) < 0.001:
        \\        score = score + 524288
        \\    ret score
    ;
    var compiled = try compiler.pipeline.compileProjectFromSources(
        std.testing.allocator,
        root_source,
        &.{
            .{ .name = "physics_broadphase", .source = broad_source },
            .{ .name = "physics_narrowphase", .source = narrow_source },
        },
        .{},
    );
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());

    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "physics-quat-obb-capsule");
    const Main = *const fn () callconv(.c) i64;
    const main = try jit.get(Main, "main");
    try std.testing.expectEqual(@as(i64, 1048575), main());
}

test "JIT nearest pickup uses distance then body id tie-break" {
    var modules = try loadRepoModules(std.testing.allocator, &engine_physics_module_specs);
    defer modules.deinit();

    const root_source =
        \\# The e7 engine_window platform layer stubs mouse capture to 0, but the
        \\# pickup interaction only runs while the pointer is captured.  Supply the
        \\# captured state the old SDL input-injection intrinsic used to provide so
        \\# the nearest-pickup distance/id tie-break policy still runs.
        \\e7_engine_mouse_captured <- (handle: u64) -> i64:
        \\    ret 1
        \\mod platform
        \\mod core
        \\mod physics
        \\use core::events::*;
        \\use core::ecs::*;
        \\use core::time::*;
        \\use core::input::*;
        \\use core::camera::*;
        \\use physics::broadphase::*;
        \\use physics::narrowphase::*;
        \\use physics::*;
        \\@resource
        \\pub Probe <- struct
        \\    first: i64
        \\    second: i64
        \\pub CaseA <- trigger
        \\pub CaptureA <- trigger
        \\pub CaseB <- trigger
        \\pub CaptureB <- trigger
        \\pub PickupScene <- plugin
        \\    pickup_scene_plugin_init <- sys (commands: &mut Commands):
        \\        commands.insert_resource(Probe { first: 0, second: 0 })
        \\        commands.insert_resource(Input {
        \\            window: 0,
        \\            move_forward: false,
        \\            move_backward: false,
        \\            move_left: false,
        \\            move_right: false,
        \\            move_up: false,
        \\            move_down: false,
        \\            sprint: false,
        \\            look_left: false,
        \\            look_right: false,
        \\            look_up: false,
        \\            look_down: false,
        \\            look_dx: 0.0,
        \\            look_dy: 0.0,
        \\            jump_pressed: false,
        \\            jump_down: false,
        \\            jump_was_down: false,
        \\            interact: false,
        \\            interact_pressed: false,
        \\            interact_was_down: false,
        \\        })
        \\        camera := Camera { position: [0.0, 2.0, 0.0], yaw: 0.0, pitch: 0.0, fov_y: 1.0, near: 0.1, far: 100.0 }
        \\        controller := CameraController { move_speed: 4.0, look_speed: 0.0025 }
        \\        camera_track := Transform { translation: [0.0, 2.0, 0.0], rotation: [0.0, 0.0, 0.0], scale: [1.0, 1.0, 1.0] }
        \\        commands.add_row(Components, { camera, controller, camera_track })
        \\        first_transform := Transform { translation: [1.0, 1.0, 0.0], rotation: [0.0, 0.0, 0.0], scale: [1.0, 1.0, 1.0] }
        \\        first_id := BodyId { id: 11 }
        \\        first_bounds := BodyBounds { half_extents: [0.2, 0.2, 0.2] }
        \\        first_body := RigidBody {
        \\            velocity: [0.0, 0.0, 0.0],
        \\            angular_velocity: [0.0, 0.0, 0.0],
        \\            orientation: [0.0, 0.0, 0.0],
        \\            inv_mass: 1.0,
        \\            gravity_scale: 0.0,
        \\            rotation_locked: false,
        \\            is_static: false,
        \\        }
        \\        first_flags := BodyFlags {
        \\            shape: 1,
        \\            radius: 0.2,
        \\            half_height: 0.0,
        \\            is_player: false,
        \\            is_pickup: true,
        \\            target_id: 11,
        \\            held_by: 0,
        \\        }
        \\        first_pickup := Pickup { body_id: 11 }
        \\        first_held := Held { by: 0 }
        \\        commands.add_row(Components, { first_transform, first_id, first_bounds, first_body, first_flags, first_pickup, first_held })
        \\        second_transform := Transform { translation: [2.0, 1.0, 0.0], rotation: [0.0, 0.0, 0.0], scale: [1.0, 1.0, 1.0] }
        \\        second_id := BodyId { id: 10 }
        \\        second_bounds := BodyBounds { half_extents: [0.2, 0.2, 0.2] }
        \\        second_body := RigidBody {
        \\            velocity: [0.0, 0.0, 0.0],
        \\            angular_velocity: [0.0, 0.0, 0.0],
        \\            orientation: [0.0, 0.0, 0.0],
        \\            inv_mass: 1.0,
        \\            gravity_scale: 0.0,
        \\            rotation_locked: false,
        \\            is_static: false,
        \\        }
        \\        second_flags := BodyFlags {
        \\            shape: 1,
        \\            radius: 0.2,
        \\            half_height: 0.0,
        \\            is_player: false,
        \\            is_pickup: true,
        \\            target_id: 10,
        \\            held_by: 0,
        \\        }
        \\        second_pickup := Pickup { body_id: 10 }
        \\        second_held := Held { by: 0 }
        \\        commands.add_row(Components, { second_transform, second_id, second_bounds, second_body, second_flags, second_pickup, second_held })
        \\        player_transform := Transform { translation: [0.0, 1.0, 0.0], rotation: [0.0, 0.0, 0.0], scale: [1.0, 1.0, 1.0] }
        \\        player_id := BodyId { id: 2 }
        \\        player_bounds := BodyBounds { half_extents: [0.2, 0.8, 0.2] }
        \\        player_body := RigidBody {
        \\            velocity: [0.0, 0.0, 0.0],
        \\            angular_velocity: [0.0, 0.0, 0.0],
        \\            orientation: [0.0, 0.0, 0.0],
        \\            inv_mass: 1.0,
        \\            gravity_scale: 1.0,
        \\            rotation_locked: true,
        \\            is_static: false,
        \\        }
        \\        player_flags := BodyFlags {
        \\            shape: 2,
        \\            radius: 0.2,
        \\            half_height: 0.8,
        \\            is_player: true,
        \\            is_pickup: false,
        \\            target_id: 2,
        \\            held_by: 0,
        \\        }
        \\        player := Player { body_id: 2 }
        \\        commands.add_row(Components, { player_transform, player_id, player_bounds, player_body, player_flags, player })
        \\@trigger(CaseA)
        \\pub case_a <- sys (
        \\    input: res &mut Input,
        \\    state: res &mut PickupState,
        \\    players: select &mut Transform, &Player from Components,
        \\    pickups: select &mut Transform, &Pickup from Components,
        \\):
        \\    input.interact_pressed = true
        \\    state.held_id = 0
        \\    for (transform, player) in players:
        \\        transform.translation[0] = 0.0
        \\        transform.translation[1] = 1.0
        \\        transform.translation[2] = 0.0
        \\    for (transform, pickup) in pickups:
        \\        if pickup.body_id == 11:
        \\            transform.translation[0] = 1.0
        \\            transform.translation[1] = 1.0
        \\            transform.translation[2] = 0.0
        \\        if pickup.body_id == 10:
        \\            transform.translation[0] = 2.0
        \\            transform.translation[1] = 1.0
        \\            transform.translation[2] = 0.0
        \\@trigger(CaptureA)
        \\pub capture_a <- sys (state: res &PickupState, probe: res &mut Probe):
        \\    probe.first = state.held_id
        \\@trigger(CaseB)
        \\pub case_b <- sys (
        \\    input: res &mut Input,
        \\    state: res &mut PickupState,
        \\    players: select &mut Transform, &Player from Components,
        \\    pickups: select &mut Transform, &Pickup from Components,
        \\):
        \\    input.interact_pressed = true
        \\    state.held_id = 0
        \\    for (transform, player) in players:
        \\        transform.translation[0] = 0.0
        \\        transform.translation[1] = 1.0
        \\        transform.translation[2] = 0.0
        \\    for (transform, pickup) in pickups:
        \\        if pickup.body_id == 11:
        \\            transform.translation[0] = 1.0
        \\            transform.translation[1] = 1.0
        \\            transform.translation[2] = 0.0
        \\        if pickup.body_id == 10:
        \\            transform.translation[0] = -1.0
        \\            transform.translation[1] = 1.0
        \\            transform.translation[2] = 0.0
        \\@trigger(CaptureB)
        \\pub capture_b <- sys (state: res &PickupState, probe: res &mut Probe):
        \\    probe.second = state.held_id
        \\main <- async () -> i32:
        \\    commands := await query &mut Commands
        \\    commands.add_plugin(physics::broadphase::BroadphasePlugin)
        \\    commands.add_plugin(physics::narrowphase::NarrowphasePlugin)
        \\    commands.add_plugin(physics::PhysicsPlugin)
        \\    commands.add_plugin(PickupScene)
        \\    disown commands
        \\    await Init()
        \\    await CaseA()
        \\    await Update()
        \\    await CaptureA()
        \\    await CaseB()
        \\    await Update()
        \\    await CaptureB()
        \\    ret 0
    ;
    var compiled = try compiler.pipeline.compileProjectFromSources(
        std.testing.allocator,
        root_source,
        modules.sources,
        .{},
    );
    defer compiled.deinit();
    if (!compiled.analysis.ok()) {
        for (compiled.analysis.diagnostics) |diagnostic| {
            std.debug.print("pickup scene diagnostic {}:{} {s}\n", .{ diagnostic.span.line, diagnostic.span.column, diagnostic.message });
        }
    }
    try std.testing.expect(compiled.analysis.ok());

    ecs.e7_ecs_reset();
    defer ecs.e7_ecs_reset();
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "nearest-pickup");
    const Main = *const fn () callconv(.c) i64;
    const main_ctor = try jit.get(Main, "main");
    const handle = main_ctor();
    try std.testing.expect(handle != 0);
    try std.testing.expectEqual(@as(i64, 0), task.e7_task_await(handle));

    var probe_id: i64 = -1;
    for (compiled.analysis.resources) |resource| {
        if (std.mem.endsWith(u8, resource.name, "Probe")) probe_id = resource.id;
    }
    try std.testing.expect(probe_id >= 0);
    try std.testing.expectEqual(@as(i64, 1), ecs.e7_ecs_has_resource(probe_id));
    const probe_ptr = ecs.e7_ecs_resource(probe_id);
    try std.testing.expect(probe_ptr != 0);
    try std.testing.expectEqual(@as(i64, 11), aggregate.e7_load_i64(probe_ptr));
    try std.testing.expectEqual(@as(i64, 10), aggregate.e7_load_i64(probe_ptr + 8));
}

test "JIT contact friction slows and tips boxes" {
    var modules = try loadRepoModules(std.testing.allocator, &engine_physics_module_specs);
    defer modules.deinit();

    const root_source =
        \\mod platform
        \\mod core
        \\mod physics
        \\use core::events::*;
        \\use core::ecs::*;
        \\use core::time::*;
        \\use core::input::*;
        \\use core::camera::*;
        \\use physics::broadphase::*;
        \\use physics::narrowphase::*;
        \\use physics::*;
        \\@resource
        \\pub Probe <- struct
        \\    vx: i64
        \\    rot_z: i64
        \\    max_speed: i64
        \\    max_angular: i64
        \\    min_y: i64
        \\    max_y: i64
        \\    init_qx: i64
        \\    init_qy: i64
        \\    init_qz: i64
        \\    init_qw: i64
        \\    final_qx: i64
        \\    final_qy: i64
        \\    final_qz: i64
        \\    final_qw: i64
        \\pub Snapshot <- trigger
        \\pub Capture <- trigger
        \\pub ContactScene <- plugin
        \\    contact_scene_plugin_init <- sys (commands: &mut Commands):
        \\        commands.insert_resource(Probe { vx: 0, rot_z: 0, max_speed: 0, max_angular: 0, min_y: 1000000, max_y: -1000000, init_qx: 0, init_qy: 0, init_qz: 0, init_qw: 0, final_qx: 0, final_qy: 0, final_qz: 0, final_qw: 0 })
        \\        commands.insert_resource(Input {
        \\            window: 0,
        \\            move_forward: false, move_backward: false, move_left: false, move_right: false,
        \\            move_up: false, move_down: false, sprint: false,
        \\            look_left: false, look_right: false, look_up: false, look_down: false,
        \\            look_dx: 0.0, look_dy: 0.0,
        \\            jump_pressed: false, jump_down: false, jump_was_down: false,
        \\            interact: false, interact_pressed: false, interact_was_down: false,
        \\        })
        \\        friction_transform := Transform { translation: [-3.0, 0.55, 0.0], rotation: [0.0, 0.0, 0.25], scale: [1.0, 1.0, 1.0] }
        \\        friction_id := BodyId { id: 10 }
        \\        friction_bounds := BodyBounds { half_extents: [0.5, 0.5, 0.5] }
        \\        friction_body := RigidBody {
        \\            velocity: [2.0, 0.0, 0.0],
        \\            angular_velocity: [0.0, 0.0, 0.0],
        \\            orientation: [0.0, 0.0, 0.0],
        \\            inv_mass: 1.0,
        \\            gravity_scale: 1.0,
        \\            rotation_locked: false,
        \\            is_static: false,
        \\        }
        \\        friction_collider := BoxCollider { half_extents: [0.5, 0.5, 0.5] }
        \\        friction_flags := BodyFlags { shape: 0, radius: 0.0, half_height: 0.0, is_player: false, is_pickup: false, target_id: 10, held_by: 0 }
        \\        friction_orientation := BodyOrientation { x: 0.0, y: 0.0, z: 0.0, w: 1.0 }
        \\        commands.add_row(Components, { friction_transform, friction_id, friction_bounds, friction_body, friction_collider, friction_flags, friction_orientation })
        \\        stack_index := 0
        \\        while stack_index < 3:
        \\            stack_y := 0.5 + (stack_index) as f32
        \\            stack_transform := Transform { translation: [0.0, stack_y, 0.0], rotation: [0.04, 0.0, 0.03], scale: [1.0, 1.0, 1.0] }
        \\            stack_id := BodyId { id: 11 + stack_index }
        \\            stack_bounds := BodyBounds { half_extents: [0.5, 0.5, 0.5] }
        \\            stack_body := RigidBody {
        \\                velocity: [0.0, 0.0, 0.0],
        \\                angular_velocity: [0.0, 0.0, 0.0],
        \\                orientation: [0.0, 0.0, 0.0],
        \\                inv_mass: 1.0,
        \\                gravity_scale: 1.0,
        \\                rotation_locked: false,
        \\                is_static: false,
        \\            }
        \\            stack_collider := BoxCollider { half_extents: [0.5, 0.5, 0.5] }
        \\            stack_flags := BodyFlags { shape: 0, radius: 0.0, half_height: 0.0, is_player: false, is_pickup: false, target_id: 11 + stack_index, held_by: 0 }
        \\            stack_orientation := BodyOrientation { x: 0.0, y: 0.0, z: 0.0, w: 1.0 }
        \\            commands.add_row(Components, { stack_transform, stack_id, stack_bounds, stack_body, stack_collider, stack_flags, stack_orientation })
        \\            stack_index = stack_index + 1
        \\@trigger(Snapshot)
        \\pub snapshot <- sys (probe: res &mut Probe, orientations: select &BodyOrientation, &BodyId from Components):
        \\    for (orientation, id) in orientations:
        \\        if id.id == 10:
        \\            probe.init_qx = (orientation.x * 1000000.0) as i64
        \\            probe.init_qy = (orientation.y * 1000000.0) as i64
        \\            probe.init_qz = (orientation.z * 1000000.0) as i64
        \\            probe.init_qw = (orientation.w * 1000000.0) as i64
        \\@trigger(Capture)
        \\pub capture <- sys (probe: res &mut Probe, boxes: select &Transform, &RigidBody, &BodyId, &BodyOrientation from Components):
        \\    for (transform, body, id, orientation) in boxes:
        \\        speed := f32::abs(body.velocity[0]) + f32::abs(body.velocity[1]) + f32::abs(body.velocity[2])
        \\        angular := f32::abs(body.angular_velocity[0]) + f32::abs(body.angular_velocity[1]) + f32::abs(body.angular_velocity[2])
        \\        speed_milli := f32::to_milli(speed)
        \\        angular_milli := f32::to_milli(angular)
        \\        y_milli := f32::to_milli(transform.translation[1])
        \\        if speed_milli > probe.max_speed:
        \\            probe.max_speed = speed_milli
        \\        if angular_milli > probe.max_angular:
        \\            probe.max_angular = angular_milli
        \\        if y_milli < probe.min_y:
        \\            probe.min_y = y_milli
        \\        if y_milli > probe.max_y:
        \\            probe.max_y = y_milli
        \\        if id.id == 10:
        \\            probe.vx = f32::to_milli(body.velocity[0])
        \\            probe.rot_z = f32::to_milli(orientation.z)
        \\            probe.final_qx = (orientation.x * 1000000.0) as i64
        \\            probe.final_qy = (orientation.y * 1000000.0) as i64
        \\            probe.final_qz = (orientation.z * 1000000.0) as i64
        \\            probe.final_qw = (orientation.w * 1000000.0) as i64
        \\main <- async () -> i32:
        \\    commands := await query &mut Commands
        \\    commands.add_plugin(physics::broadphase::BroadphasePlugin)
        \\    commands.add_plugin(physics::narrowphase::NarrowphasePlugin)
        \\    commands.add_plugin(physics::PhysicsPlugin)
        \\    commands.add_plugin(ContactScene)
        \\    disown commands
        \\    await Init()
        \\    await Snapshot()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await PostUpdate()
        \\    await Capture()
        \\    ret 0
    ;
    var compiled = try compiler.pipeline.compileProjectFromSources(
        std.testing.allocator,
        root_source,
        modules.sources,
        .{},
    );
    defer compiled.deinit();
    if (!compiled.analysis.ok()) {
        for (compiled.analysis.diagnostics) |diagnostic| {
            std.debug.print("contact scene diagnostic {d}:{d} {s}\n", .{ diagnostic.span.line, diagnostic.span.column, diagnostic.message });
        }
    }
    try std.testing.expect(compiled.analysis.ok());

    ecs.e7_ecs_reset();
    defer ecs.e7_ecs_reset();
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "contact-friction-stack");
    const Main = *const fn () callconv(.c) i64;
    const main_ctor = try jit.get(Main, "main");
    const handle = main_ctor();
    try std.testing.expect(handle != 0);
    try std.testing.expectEqual(@as(i64, 0), task.e7_task_await(handle));

    var probe_id: i64 = -1;
    for (compiled.analysis.resources) |resource| {
        if (std.mem.endsWith(u8, resource.name, "Probe")) probe_id = resource.id;
    }
    try std.testing.expect(probe_id >= 0);
    const probe_ptr = ecs.e7_ecs_resource(probe_id);
    try std.testing.expect(probe_ptr != 0);
    const vx = aggregate.e7_load_i64(probe_ptr);
    const max_speed = aggregate.e7_load_i64(probe_ptr + 16);
    const max_angular = aggregate.e7_load_i64(probe_ptr + 24);
    const min_y = aggregate.e7_load_i64(probe_ptr + 32);
    const max_y = aggregate.e7_load_i64(probe_ptr + 40);
    const init_qx = aggregate.e7_load_i64(probe_ptr + 48);
    const init_qy = aggregate.e7_load_i64(probe_ptr + 56);
    const init_qz = aggregate.e7_load_i64(probe_ptr + 64);
    const init_qw = aggregate.e7_load_i64(probe_ptr + 72);
    const final_qx = aggregate.e7_load_i64(probe_ptr + 80);
    const final_qy = aggregate.e7_load_i64(probe_ptr + 88);
    const final_qz = aggregate.e7_load_i64(probe_ptr + 96);
    const final_qw = aggregate.e7_load_i64(probe_ptr + 104);
    try std.testing.expect(vx > -500 and vx < 500);
    // Contacts change the BodyOrientation quaternion (the render source of
    // truth) and keep it normalised; the Euler Transform mirror is not used.
    const dqx = e7Abs(i64, final_qx - init_qx);
    const dqy = e7Abs(i64, final_qy - init_qy);
    const dqz = e7Abs(i64, final_qz - init_qz);
    const dqw = e7Abs(i64, final_qw - init_qw);
    try std.testing.expect(dqx > 10000 or dqy > 10000 or dqz > 10000 or dqw > 10000);
    const norm_sq = final_qx * final_qx + final_qy * final_qy + final_qz * final_qz + final_qw * final_qw;
    // |q| = 1 within 0.2% (values are 1e6-scaled).
    try std.testing.expect(norm_sq > 998000000000 and norm_sq < 1002000000000);
    try std.testing.expect(min_y > 300);
    try std.testing.expect(max_y < 5000);
    try std.testing.expect(max_speed > 0);
    try std.testing.expect(max_angular > 0);
}

fn e7Abs(comptime T: type, value: T) T {
    return if (value < 0) -value else value;
}

test "JIT rotates body inverse inertia by quaternion" {
    const broad_source = readRepoTextForTest("engine/physics/broadphase.e7") orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(broad_source);
    const narrow_source = readRepoTextForTest("engine/physics/narrowphase.e7") orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(narrow_source);
    const root_source =
        \\mod physics_broadphase
        \\mod physics_narrowphase
        \\Vec3 <- struct
        \\    x: f32
        \\    y: f32
        \\    z: f32
        \\Ray <- struct
        \\    origin: Vec3
        \\    direction: Vec3
        \\Aabb <- struct
        \\    min: Vec3
        \\    max: Vec3
        \\RayHit <- struct
        \\    hit: bool
        \\    distance: f32
        \\    point: Vec3
        \\ray_sphere <- (ray: Ray, center: Vec3, radius: f32) -> RayHit = RayHit { hit: false, distance: 0.0, point: center }
        \\main <- () -> i32:
        \\    half := Vec3 { x: 2.0, y: 1.0, z: 0.5 }
        \\    upright := inverse_inertia_world(0, half, 0.0, 0.0, 1.0, quat_identity())
        \\    turned := inverse_inertia_world(0, Vec3 { x: 2.0, y: 1.0, z: 0.5 }, 0.0, 0.0, 1.0, quat_from_euler(0.0, 0.0, 1.5707963))
        \\    diagonal := inverse_inertia_world(0, Vec3 { x: 2.0, y: 1.0, z: 0.5 }, 0.0, 0.0, 1.0, quat_from_euler(0.0, 0.0, 0.7853982))
        \\    score := 0
        \\    if upright.m00 > 2.399 and upright.m00 < 2.401:
        \\        score = score + 1
        \\    if upright.m11 > 0.7057 and upright.m11 < 0.7060:
        \\        score = score + 2
        \\    if upright.m22 > 0.5999 and upright.m22 < 0.6001:
        \\        score = score + 4
        \\    if f32::abs(upright.m01) < 0.001 and f32::abs(upright.m12) < 0.001:
        \\        score = score + 8
        \\    if turned.m00 > 0.7057 and turned.m00 < 0.7060:
        \\        score = score + 16
        \\    if turned.m11 > 2.399 and turned.m11 < 2.401:
        \\        score = score + 32
        \\    if f32::abs(diagonal.m01) > 0.5:
        \\        score = score + 64
        \\    ret score
    ;
    var compiled = try compiler.pipeline.compileProjectFromSources(
        std.testing.allocator,
        root_source,
        &.{
            .{ .name = "physics_broadphase", .source = broad_source },
            .{ .name = "physics_narrowphase", .source = narrow_source },
        },
        .{},
    );
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "rotated-inertia");
    const Main = *const fn () callconv(.c) i64;
    const main = try jit.get(Main, "main");
    try std.testing.expectEqual(@as(i64, 127), main());
}

test "JIT body pairs exchange equal and opposite impulses" {
    var modules = try loadRepoModules(std.testing.allocator, &engine_physics_module_specs);
    defer modules.deinit();

    const root_source =
        \\mod platform
        \\mod core
        \\mod physics
        \\use core::events::*;
        \\use core::ecs::*;
        \\use core::time::*;
        \\use core::input::*;
        \\use core::camera::*;
        \\use physics::broadphase::*;
        \\use physics::narrowphase::*;
        \\use physics::*;
        \\@resource
        \\pub Probe <- struct
        \\    avx: i64
        \\    bvx: i64
        \\    awz: i64
        \\    bwz: i64
        \\pub Capture <- trigger
        \\pub PairScene <- plugin
        \\    pair_scene_plugin_init <- sys (commands: &mut Commands):
        \\        commands.insert_resource(Probe { avx: 0, bvx: 0, awz: 0, bwz: 0 })
        \\        commands.insert_resource(Input {
        \\            window: 0,
        \\            move_forward: false, move_backward: false, move_left: false, move_right: false,
        \\            move_up: false, move_down: false, sprint: false,
        \\            look_left: false, look_right: false, look_up: false, look_down: false,
        \\            look_dx: 0.0, look_dy: 0.0,
        \\            jump_pressed: false, jump_down: false, jump_was_down: false,
        \\            interact: false, interact_pressed: false, interact_was_down: false,
        \\        })
        \\        a_transform := Transform { translation: [0.0, 5.0, 0.0], rotation: [0.0, 0.0, 0.0], scale: [1.0, 1.0, 1.0] }
        \\        a_id := BodyId { id: 10 }
        \\        a_bounds := BodyBounds { half_extents: [0.5, 0.5, 0.5] }
        \\        a_body := RigidBody {
        \\            velocity: [2.0, 0.0, 0.0],
        \\            angular_velocity: [0.0, 0.0, 0.0],
        \\            orientation: [0.0, 0.0, 0.0],
        \\            inv_mass: 1.0,
        \\            gravity_scale: 0.0,
        \\            rotation_locked: false,
        \\            is_static: false,
        \\        }
        \\        a_collider := BoxCollider { half_extents: [0.5, 0.5, 0.5] }
        \\        a_flags := BodyFlags { shape: 0, radius: 0.0, half_height: 0.0, is_player: false, is_pickup: false, target_id: 10, held_by: 0 }
        \\        commands.add_row(Components, { a_transform, a_id, a_bounds, a_body, a_collider, a_flags })
        \\        b_transform := Transform { translation: [0.8, 5.0, 0.0], rotation: [0.0, 0.0, 0.0], scale: [1.0, 1.0, 1.0] }
        \\        b_id := BodyId { id: 11 }
        \\        b_bounds := BodyBounds { half_extents: [0.5, 0.5, 0.5] }
        \\        b_body := RigidBody {
        \\            velocity: [0.0, 0.0, 0.0],
        \\            angular_velocity: [0.0, 0.0, 0.0],
        \\            orientation: [0.0, 0.0, 0.0],
        \\            inv_mass: 1.0,
        \\            gravity_scale: 0.0,
        \\            rotation_locked: false,
        \\            is_static: false,
        \\        }
        \\        b_collider := BoxCollider { half_extents: [0.5, 0.5, 0.5] }
        \\        b_flags := BodyFlags { shape: 0, radius: 0.0, half_height: 0.0, is_player: false, is_pickup: false, target_id: 11, held_by: 0 }
        \\        commands.add_row(Components, { b_transform, b_id, b_bounds, b_body, b_collider, b_flags })
        \\@trigger(Capture)
        \\pub capture <- sys (probe: res &mut Probe, boxes: select &Transform, &RigidBody, &BodyId from Components):
        \\    for (transform, body, id) in boxes:
        \\        if id.id == 10:
        \\            probe.avx = f32::to_milli(body.velocity[0])
        \\            probe.awz = f32::to_milli(body.angular_velocity[2])
        \\        if id.id == 11:
        \\            probe.bvx = f32::to_milli(body.velocity[0])
        \\            probe.bwz = f32::to_milli(body.angular_velocity[2])
        \\main <- async () -> i32:
        \\    commands := await query &mut Commands
        \\    commands.add_plugin(physics::broadphase::BroadphasePlugin)
        \\    commands.add_plugin(physics::narrowphase::NarrowphasePlugin)
        \\    commands.add_plugin(physics::PhysicsPlugin)
        \\    commands.add_plugin(PairScene)
        \\    disown commands
        \\    await Init()
        \\    await Update()
        \\    await Capture()
        \\    ret 0
    ;
    var compiled = try compiler.pipeline.compileProjectFromSources(
        std.testing.allocator,
        root_source,
        modules.sources,
        .{},
    );
    defer compiled.deinit();
    if (!compiled.analysis.ok()) {
        for (compiled.analysis.diagnostics) |diagnostic| {
            std.debug.print("pair scene diagnostic {d}:{d} {s}\n", .{ diagnostic.span.line, diagnostic.span.column, diagnostic.message });
        }
    }
    try std.testing.expect(compiled.analysis.ok());
    ecs.e7_ecs_reset();
    defer ecs.e7_ecs_reset();
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "symmetric-pair");
    const Main = *const fn () callconv(.c) i64;
    const main_ctor = try jit.get(Main, "main");
    const handle = main_ctor();
    try std.testing.expect(handle != 0);
    try std.testing.expectEqual(@as(i64, 0), task.e7_task_await(handle));

    var probe_id: i64 = -1;
    for (compiled.analysis.resources) |resource| {
        if (std.mem.endsWith(u8, resource.name, "Probe")) probe_id = resource.id;
    }
    try std.testing.expect(probe_id >= 0);
    const probe_ptr = ecs.e7_ecs_resource(probe_id);
    try std.testing.expect(probe_ptr != 0);
    const avx = aggregate.e7_load_i64(probe_ptr);
    const bvx = aggregate.e7_load_i64(probe_ptr + 8);
    const awz = aggregate.e7_load_i64(probe_ptr + 16);
    const bwz = aggregate.e7_load_i64(probe_ptr + 24);
    try std.testing.expect(avx < 1950);
    try std.testing.expect(bvx > 50);
    try std.testing.expect(avx + bvx > 1800 and avx + bvx < 2200);
    // A centered face-on impact must transfer momentum without the spurious
    // corner torque that previously destabilized stacks.
    try std.testing.expect(@abs(awz) <= 2 and @abs(bwz) <= 2);
}

test "JIT sleeping body wakes on contact" {
    var modules = try loadRepoModules(std.testing.allocator, &engine_physics_module_specs);
    defer modules.deinit();

    const root_source =
        \\mod platform
        \\mod core
        \\mod physics
        \\use core::events::*;
        \\use core::ecs::*;
        \\use core::time::*;
        \\use core::input::*;
        \\use core::camera::*;
        \\use physics::broadphase::*;
        \\use physics::narrowphase::*;
        \\use physics::*;
        \\@resource
        \\pub Probe <- struct
        \\    ax: i64
        \\    ay: i64
        \\    avx: i64
        \\pub Capture <- trigger
        \\pub WakeScene <- plugin
        \\    wake_scene_plugin_init <- sys (commands: &mut Commands):
        \\        commands.insert_resource(Probe { ax: 0, ay: 0, avx: 0 })
        \\        commands.insert_resource(Input {
        \\            window: 0,
        \\            move_forward: false, move_backward: false, move_left: false, move_right: false,
        \\            move_up: false, move_down: false, sprint: false,
        \\            look_left: false, look_right: false, look_up: false, look_down: false,
        \\            look_dx: 0.0, look_dy: 0.0,
        \\            jump_pressed: false, jump_down: false, jump_was_down: false,
        \\            interact: false, interact_pressed: false, interact_was_down: false,
        \\        })
        \\        sleepers := map[i64, [f32]] {}
        \\        sleepers[10] = [1.0, 1.0]
        \\        commands.insert_resource(PhysicsWorld {
        \\            gravity_y: -9.81,
        \\            max_step: 0.05,
        \\            grounded: false,
        \\            jump_latched: false,
        \\            player_x: 0.0,
        \\            player_y: 0.0,
        \\            player_z: 0.0,
        \\            camera_yaw: 0.0,
        \\            camera_pitch: 0.0,
        \\            move_speed: 4.0,
        \\            quaternions: map[i64, [f32]] {},
        \\            plane_normal: [0.0, 1.0, 0.0],
        \\            plane_offset: 0.0,
        \\            friction: 0.9,
        \\            friction_static: 1.15,
        \\            pending_impulses: map[i64, [f32]] {},
        \\            sleep_state: sleepers,
        \\        })
        \\        sleeping_transform := Transform { translation: [0.0, 2.0, 0.0], rotation: [0.0, 0.0, 0.0], scale: [1.0, 1.0, 1.0] }
        \\        sleeping_id := BodyId { id: 10 }
        \\        sleeping_bounds := BodyBounds { half_extents: [0.5, 0.5, 0.5] }
        \\        sleeping_body := RigidBody { velocity: [0.0, 0.0, 0.0], angular_velocity: [0.0, 0.0, 0.0], orientation: [0.0, 0.0, 0.0], inv_mass: 1.0, gravity_scale: 1.0, rotation_locked: false, is_static: false }
        \\        sleeping_collider := BoxCollider { half_extents: [0.5, 0.5, 0.5] }
        \\        sleeping_flags := BodyFlags { shape: 0, radius: 0.0, half_height: 0.0, is_player: false, is_pickup: false, target_id: 10, held_by: 0 }
        \\        commands.add_row(Components, { sleeping_transform, sleeping_id, sleeping_bounds, sleeping_body, sleeping_collider, sleeping_flags })
        \\        mover_transform := Transform { translation: [1.2, 2.0, 0.0], rotation: [0.0, 0.0, 0.0], scale: [1.0, 1.0, 1.0] }
        \\        mover_id := BodyId { id: 11 }
        \\        mover_bounds := BodyBounds { half_extents: [0.5, 0.5, 0.5] }
        \\        mover_body := RigidBody { velocity: [-2.0, 0.0, 0.0], angular_velocity: [0.0, 0.0, 0.0], orientation: [0.0, 0.0, 0.0], inv_mass: 1.0, gravity_scale: 0.0, rotation_locked: false, is_static: false }
        \\        mover_collider := BoxCollider { half_extents: [0.5, 0.5, 0.5] }
        \\        mover_flags := BodyFlags { shape: 0, radius: 0.0, half_height: 0.0, is_player: false, is_pickup: false, target_id: 11, held_by: 0 }
        \\        commands.add_row(Components, { mover_transform, mover_id, mover_bounds, mover_body, mover_collider, mover_flags })
        \\@trigger(Capture)
        \\pub capture <- sys (probe: res &mut Probe, boxes: select &Transform, &RigidBody, &BodyId from Components):
        \\    for (transform, body, id) in boxes:
        \\        if id.id == 10:
        \\            probe.ax = f32::to_milli(transform.translation[0])
        \\            probe.ay = f32::to_milli(transform.translation[1])
        \\            probe.avx = f32::to_milli(body.velocity[0])
        \\main <- async () -> i32:
        \\    commands := await query &mut Commands
        \\    commands.add_plugin(physics::broadphase::BroadphasePlugin)
        \\    commands.add_plugin(physics::narrowphase::NarrowphasePlugin)
        \\    commands.add_plugin(physics::PhysicsPlugin)
        \\    commands.add_plugin(WakeScene)
        \\    disown commands
        \\    await Init()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Capture()
        \\    ret 0
    ;
    var compiled = try compiler.pipeline.compileProjectFromSources(
        std.testing.allocator,
        root_source,
        modules.sources,
        .{},
    );
    defer compiled.deinit();
    if (!compiled.analysis.ok()) {
        for (compiled.analysis.diagnostics) |diagnostic| {
            std.debug.print("wake scene diagnostic {d}:{d} {s}\n", .{ diagnostic.span.line, diagnostic.span.column, diagnostic.message });
        }
    }
    try std.testing.expect(compiled.analysis.ok());
    ecs.e7_ecs_reset();
    defer ecs.e7_ecs_reset();
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "sleep-wake");
    const Main = *const fn () callconv(.c) i64;
    const main_ctor = try jit.get(Main, "main");
    const handle = main_ctor();
    try std.testing.expect(handle != 0);
    try std.testing.expectEqual(@as(i64, 0), task.e7_task_await(handle));

    var probe_id: i64 = -1;
    for (compiled.analysis.resources) |resource| {
        if (std.mem.endsWith(u8, resource.name, "Probe")) probe_id = resource.id;
    }
    try std.testing.expect(probe_id >= 0);
    const probe_ptr = ecs.e7_ecs_resource(probe_id);
    try std.testing.expect(probe_ptr != 0);
    const ax = aggregate.e7_load_i64(probe_ptr);
    const ay = aggregate.e7_load_i64(probe_ptr + 8);
    const avx = aggregate.e7_load_i64(probe_ptr + 16);
    // Sleeping body kept its height instead of falling under gravity.
    try std.testing.expect(ay > 1500);
    // Contact woke it and transferred horizontal impulse/position.
    try std.testing.expect(ax != 0 or avx != 0);
}

test "JIT calls inherent impl methods with receiver-first lowering" {
    var compiled = try compiler.pipeline.compile(
        std.testing.allocator,
        \\Counter <- struct
        \\    n: i32
        \\impl Counter:
        \\    bump <- (counter: &mut Counter) -> nil:
        \\        counter.n = counter.n + 1
        \\        ret
        \\    bump_by <- (counter: &mut Counter, by: i32) -> i32:
        \\        counter.n = counter.n + by
        \\        ret counter.n
        \\    value <- (counter: &Counter) -> i32 = counter.n
        \\    plus <- (counter: Counter, by: i32) -> i32 = counter.n + by
        \\run <- () -> i32:
        \\    counter := Counter { n: 1 }
        \\    counter.bump()
        \\    counter.bump_by(4)
        \\    counter.value() + counter.plus(1)
    ,
        .{},
    );
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());
    const bytes = try compiler.bytecode.encode(std.testing.allocator, &compiled.bytecode);
    defer std.testing.allocator.free(bytes);
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecodeBytes(bytes, "inherent-methods");
    const Run = *const fn () callconv(.c) i32;
    const run = try jit.get(Run, "run");
    // n: 1 -> bump 2 -> bump_by(4) 6; value() 6 + plus(1) 7 (by-value
    // aggregate receivers alias the object pointer) = 13.
    try std.testing.expectEqual(@as(i32, 13), run());
}

test "host asset write/read round-trip and reload request flag" {
    const path = ".zig-cache/e7-host-asset-roundtrip.json";
    const payload = "{\"editor\":true}\n";
    const path_handle = makeTestString(path);
    const text_handle = makeTestString(payload);
    try std.testing.expectEqual(@as(i64, 0), host_engine.e7_engine_write_asset(path_handle, text_handle));
    const read = host_engine.e7_engine_read_shader(path_handle);
    try std.testing.expect(read != 0);
    const length = aggregate.e7_str_len(read);
    const ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(read + 8)));
    try std.testing.expectEqualStrings(payload, ptr[0..@intCast(length)]);
    // Missing parent directory is reported as failure, not a panic.
    try std.testing.expectEqual(
        @as(i64, -1),
        host_engine.e7_engine_write_asset(makeTestString(".zig-cache/no-such-dir/x.json"), text_handle),
    );

    host.reset();
    defer host.reset();
    try std.testing.expect(!host.takeReloadRequest());
    host.requestReload();
    try std.testing.expect(host.takeReloadRequest());
    try std.testing.expect(!host.takeReloadRequest());
}

const live_reload = @import("live_reload.zig");
var test_live_program: ?*live_reload.Program = null;
var test_live_project: []const u8 = "";
var test_live_fixture: bool = false;
var test_live_preserved: bool = false;

fn stageTestLiveReload() bool {
    const program = test_live_program orelse return false;
    if (!test_live_fixture) return program.stagePath(test_live_project);
    const replacement = compileWorkspaceFixture(std.testing.allocator, test_live_project, 2) catch return false;
    const success = program.stage(replacement);
    if (!success) std.debug.print("live fixture staging: {s}\n", .{program.diagnostic});
    return success;
}

fn applyTestLiveReload() bool {
    const program = test_live_program orelse return false;
    const analysis = program.generations.items[0].compiled.analysis;
    const window_id = (analysis.resource("core::window::Window") orelse return false).id;
    const gpu_id = (analysis.resource("gfx::gpu::Gpu") orelse return false).id;
    const window = ecs.e7_ecs_resource(window_id);
    const gpu = ecs.e7_ecs_resource(gpu_id);
    const window_handle = aggregate.e7_load_i64(window);
    const scene_handle = aggregate.e7_load_i64(gpu);
    const entities = ecs.e7_ecs_entity_count();
    if (program.candidate == null and !stageTestLiveReload()) return false;
    if (!program.commit()) return false;
    test_live_preserved = window_handle != 0 and scene_handle != 0 and
        window == ecs.e7_ecs_resource(window_id) and gpu == ecs.e7_ecs_resource(gpu_id) and
        window_handle == aggregate.e7_load_i64(window) and scene_handle == aggregate.e7_load_i64(gpu) and
        entities == ecs.e7_ecs_entity_count();
    return test_live_preserved;
}

fn editorProjectPath() ![:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, "engine/editor_main.e7", std.testing.allocator) catch
        try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, "../engine/editor_main.e7", std.testing.allocator);
}

test "editor reload keeps one main, window, renderer, ECS world and frame sequence" {
    host.reset();
    defer host.reset();
    host.setHeadless(true);
    host.setMaxFrames(5);
    host.setCaptureEnabled(true);
    defer ecs.e7_ecs_reset();
    const path = try editorProjectPath();
    defer std.testing.allocator.free(path);
    var program = try live_reload.Program.init(std.testing.allocator, try compiler.pipeline.compileProject(std.testing.allocator, path, .{}));
    defer program.deinit();
    const editor_host = @import("editor_host.zig");
    test_live_program = &program;
    test_live_project = path;
    test_live_fixture = false;
    test_live_preserved = false;
    editor_host.check_callback = stageTestLiveReload;
    editor_host.apply_callback = applyTestLiveReload;
    defer {
        editor_host.check_callback = null;
        editor_host.apply_callback = null;
        test_live_program = null;
    }
    task.e7_task_set_inline(1);
    defer task.e7_task_set_inline(0);
    host.requestReload();
    const main_ctor = try program.main();
    try std.testing.expectEqual(@as(i64, 0), task.e7_task_await(main_ctor()));
    try std.testing.expect(test_live_preserved);
    try std.testing.expectEqual(@as(usize, 1), program.reloads());
    try std.testing.expectEqual(@as(i64, 5), host.frames());
    var capture = host.takeCapture() orelse return error.TestUnexpectedResult;
    defer capture.deinit();
    try std.testing.expectEqual(@as(u32, 960), capture.width);
    try std.testing.expectEqual(@as(u32, 540), capture.height);
    try std.testing.expect(host.captureHasContent(capture));
}

fn compileWorkspaceFixture(allocator: std.mem.Allocator, entry: []const u8, version: u8) !compiler.pipeline.CompileResult {
    const fixture_source = readRepoTextForTest("tests/editor_workspace_flow.e7") orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(fixture_source);
    const changed = try std.mem.replaceOwned(u8, allocator, fixture_source, "workspace_fixture_version <- () -> i64 = 1", if (version == 1) "workspace_fixture_version <- () -> i64 = 1" else "workspace_fixture_version <- () -> i64 = 2");
    defer allocator.free(changed);
    const project = loaded: {
        var loaded = try compiler.pipeline.loadProject(allocator, entry);
        errdefer loaded.deinit();
        const text = try loaded.root_ast.arena.allocator().dupe(u8, changed);
        var fixture = switch (try compiler.parser.parse(allocator, text)) {
            .ast => |tree| tree,
            .diagnostic => return error.TestUnexpectedResult,
        };
        var fixture_owned = true;
        errdefer if (fixture_owned) fixture.deinit();
        const modules = try allocator.realloc(loaded.module_asts, loaded.module_asts.len + 1);
        modules[modules.len - 1] = fixture;
        loaded.module_asts = modules;
        fixture_owned = false;
        for (loaded.root_ast.module.items) |item| {
            if (item.kind == .function and std.mem.eql(u8, item.kind.function.name, "main")) item.kind.function.name = "unused_editor_main";
        }
        const original = loaded.root_ast.module.items;
        const items = try loaded.root_ast.arena.allocator().alloc(*compiler.ast.Item, original.len + fixture.module.items.len);
        @memcpy(items[0..original.len], original);
        @memcpy(items[original.len..], fixture.module.items);
        loaded.root_ast.module.items = items;
        break :loaded loaded;
    };
    return compiler.pipeline.compileLoadedProject(allocator, project, .{});
}

test "live editor applies script edits preserving play pause physics and custom resources" {
    const allocator = std.testing.allocator;
    host.reset();
    defer host.reset();
    host.setHeadless(true);
    defer ecs.e7_ecs_reset();
    const path = try editorProjectPath();
    defer allocator.free(path);
    var program = try live_reload.Program.init(allocator, try compileWorkspaceFixture(allocator, path, 1));
    defer program.deinit();
    const editor_host = @import("editor_host.zig");
    test_live_program = &program;
    test_live_project = path;
    test_live_fixture = true;
    test_live_preserved = false;
    editor_host.check_callback = stageTestLiveReload;
    editor_host.apply_callback = applyTestLiveReload;
    defer {
        editor_host.check_callback = null;
        editor_host.apply_callback = null;
        test_live_program = null;
    }
    task.e7_task_set_inline(1);
    defer task.e7_task_set_inline(0);
    const main_ctor = try program.main();
    try std.testing.expectEqual(@as(i64, 0), task.e7_task_await(main_ctor()));
    try std.testing.expect(test_live_preserved);
    try std.testing.expectEqual(@as(usize, 1), program.reloads());
}
