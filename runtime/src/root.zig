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
pub const aggregate = @import("aggregate.zig");
pub const intrinsics = @import("intrinsics.zig");

pub const window = @import("ffi/window.zig");
pub const vulkan = @import("ffi/vulkan.zig");
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
