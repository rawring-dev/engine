//! Public semantic-analysis API.

pub const types = @import("semantic/types.zig");
pub const analyzer = @import("semantic/analyzer.zig");
pub const analyze = analyzer.analyze;
pub const Analysis = analyzer.Analysis;
pub const Diagnostic = analyzer.Diagnostic;
pub const TriggerInfo = analyzer.TriggerInfo;

const std = @import("std");
const parser = @import("parser.zig");
const ast = @import("ast.zig");

fn analyzeSource(source: []const u8) !struct { parsed: parser.Ast, analysis: Analysis } {
    const result = try parser.parse(std.testing.allocator, source);
    var parsed = switch (result) {
        .ast => |tree| tree,
        .diagnostic => |diagnostic| {
            std.debug.print("parse failed at {d}:{d}: {s}\n", .{
                diagnostic.line,
                diagnostic.column,
                diagnostic.message,
            });
            return error.TestUnexpectedResult;
        },
    };
    errdefer parsed.deinit();
    const analysis = try analyze(std.testing.allocator, parsed.module);
    return .{ .parsed = parsed, .analysis = analysis };
}

fn expectClean(source: []const u8) !void {
    var result = try analyzeSource(source);
    defer result.parsed.deinit();
    defer result.analysis.deinit();
    if (!result.analysis.ok()) {
        for (result.analysis.diagnostics) |diagnostic| {
            std.debug.print("semantic error: {s}\n", .{diagnostic.message});
        }
        return error.TestUnexpectedResult;
    }
}

fn findDiagnosticSpan(source: []const u8, needle: []const u8) !ast.Span {
    var result = try analyzeSource(source);
    defer result.parsed.deinit();
    defer result.analysis.deinit();
    for (result.analysis.diagnostics) |diagnostic| {
        if (std.mem.indexOf(u8, diagnostic.message, needle) != null) return diagnostic.span;
    }
    for (result.analysis.diagnostics) |diagnostic| {
        std.debug.print("semantic error: {s}\n", .{diagnostic.message});
    }
    std.debug.print("missing expected diagnostic: {s}\n", .{needle});
    return error.TestUnexpectedResult;
}

fn expectDiagnostic(source: []const u8, needle: []const u8) !void {
    var result = try analyzeSource(source);
    defer result.parsed.deinit();
    defer result.analysis.deinit();
    for (result.analysis.diagnostics) |diagnostic| {
        if (std.mem.indexOf(u8, diagnostic.message, needle) != null) return;
    }
    for (result.analysis.diagnostics) |diagnostic| {
        std.debug.print("semantic error: {s}\n", .{diagnostic.message});
    }
    std.debug.print("missing expected diagnostic: {s}\n", .{needle});
    return error.TestUnexpectedResult;
}

test "accepts a well-typed function and struct" {
    try expectClean(
        \\S <- struct
        \\    a: i32
        \\    b: u32
        \\add <- (x: i32, y: i32) -> i32 = x + y
        \\make <- () -> S = S { a: 1, b: 2 }
    );
}

test "reports assignment type mismatches" {
    try expectDiagnostic(
        \\f <- () -> i32:
        \\    x := 1
        \\    x = "no"
        \\    0
    , "type mismatch");
}

test "reports writes to immutable bindings" {
    try expectDiagnostic(
        \\f <- () -> i32:
        \\    x <- 1
        \\    x = 2
        \\    0
    , "immutable");
}

test "detects a mutation while borrowed" {
    try expectDiagnostic(
        \\f <- () -> i32:
        \\    x := 1
        \\    r := &x
        \\    x = 2
        \\    print(r)
        \\    0
    , "borrowed");
}

test "allows multiple shared borrows" {
    try expectClean(
        \\f <- () -> i32:
        \\    x := 1
        \\    a := &x
        \\    b := &x
        \\    0
    );
}

test "releases temporary call borrows at statement end" {
    try expectClean(
        \\id <- (x: &i32) -> i32 = 1
        \\f <- () -> i32:
        \\    x := 1
        \\    id(&x)
        \\    x = 2
        \\    0
    );
}

test "ends unused borrows before later mutations" {
    try expectClean(
        \\f <- () -> i32:
        \\    x := 1
        \\    r := &x
        \\    x = 2
        \\    0
    );
}

test "rejects mutable borrow of an immutable binding" {
    try expectDiagnostic(
        \\f <- () -> i32:
        \\    x <- 1
        \\    r := &mut x
        \\    0
    , "immutable");
}

test "rejects conflicting mutable and shared borrows" {
    try expectDiagnostic(
        \\f <- () -> i32:
        \\    x := 1
        \\    a := &mut x
        \\    b := &x
        \\    print(a)
        \\    0
    , "conflicting borrow");
}

test "reports unknown types" {
    try expectDiagnostic(
        \\f <- (x: Missing) -> i32 = 0
    , "unknown type");
}

test "checks struct fields and match patterns" {
    try expectClean(
        \\E <- enum
        \\    A(i32)
        \\    B
        \\f <- (e: E) -> i32:
        \\    match e:
        \\        A(v): v
        \\        B: 0
    );
}

test "reports unknown struct fields" {
    try expectDiagnostic(
        \\S <- struct
        \\    a: i32
        \\f <- () -> i32 = S { a: 1, b: 2 }
    , "unknown field");
}

test "field borrows are disjoint and mutations through fields are checked" {
    try expectClean(
        \\S <- struct
        \\    a: i32
        \\    b: i32
        \\f <- () -> i32:
        \\    s := S { a: 1, b: 2 }
        \\    r := &s.a
        \\    s.b = 3
        \\    0
    );

    try expectDiagnostic(
        \\S <- struct
        \\    a: i32
        \\    b: i32
        \\f <- () -> i32:
        \\    s := S { a: 1, b: 2 }
        \\    r := &s.a
        \\    s.a = 3
        \\    print(r)
        \\    0
    , "borrowed");
}

test "reading while mutably borrowed is rejected" {
    try expectDiagnostic(
        \\f <- () -> i32:
        \\    x := 1
        \\    m := &mut x
        \\    y := x
        \\    print(m)
        \\    0
    , "mutably borrowed");
}

test "infers generic function results" {
    try expectClean(
        \\id<T> <- (x: T) -> T = x
        \\f <- () -> i32 = id(1)
    );
}

test "checks impl static methods" {
    try expectClean(
        \\Foo <- struct
        \\    a: i32
        \\impl Foo:
        \\    new <- () -> Foo = Foo { a: 0 }
        \\f <- () -> Foo = Foo::new()
    );
}

test "checks sys query and resource parameters" {
    try expectClean(
        \\Update <- trigger
        \\    a: i32
        \\F <- struct
        \\    a: i32
        \\    b: u32
        \\@trigger(Update)
        \\step <- sys (
        \\    update: &Update,
        \\    queries: select &a, &b from F where a < 5,
        \\    target: res &mut F
        \\):
        \\    target.a += update.a
        \\    for q in queries:
        \\        target.a += q.a
    );
}

test "or-patterns do not redeclare bindings" {
    try expectClean(
        \\f <- (x: i32) -> i32:
        \\    match x:
        \\        n | n: n
    );
}

test "checks return error values" {
    try expectClean(
        \\E <- enum
        \\    Bad
        \\f <- () -> E!i32:
        \\    ret !E::Bad
    );
}

test "reports wrong call arity and missing returns" {
    try expectDiagnostic(
        \\g <- (x: i32) -> i32 = x
        \\f <- () -> i32:
        \\    g()
    , "argument");
}

test "reports a missing return value" {
    try expectDiagnostic(
        \\f <- () -> i32:
        \\    x := 1
    , "may return");
}

test "does not unify integer and float variables" {
    try expectDiagnostic(
        \\f <- () -> i32:
        \\    x := 1
        \\    y := 1.0
        \\    z := x + y
        \\    0
    , "type mismatch");
}

test "checks generic types and generic static methods" {
    try expectClean(
        \\Box<T> <- struct
        \\    value: T
        \\impl<T> Box<T>:
        \\    get <- (b: Box<T>) -> T = b.value
        \\f <- () -> i32 = Box<i32>::get(Box<i32> { value: 1 })
    );
}

test "reports wrong generic argument counts" {
    try expectDiagnostic(
        \\Box<T> <- struct
        \\    value: T
        \\f <- (b: Box) -> i32 = 0
    , "type argument");
}

test "allows mutation through a mutable reference parameter" {
    try expectClean(
        \\f <- (p: &mut i32) -> i32:
        \\    *p = 1
        \\    *p
    );
}

test "rejects mutation through a shared reference parameter" {
    try expectDiagnostic(
        \\f <- (p: &i32) -> i32:
        \\    *p = 1
        \\    0
    , "immutable");
}

test "rejects mutation through a shared reference field" {
    try expectDiagnostic(
        \\S <- struct
        \\    a: i32
        \\f <- (p: &S) -> i32:
        \\    p.a = 1
        \\    0
    , "immutable");
}

test "allows mutation through a mutable reference field" {
    try expectClean(
        \\S <- struct
        \\    a: i32
        \\f <- (p: &mut S) -> i32:
        \\    p.a = 1
        \\    0
    );
}

test "reports non-exhaustive enum matches" {
    try expectDiagnostic(
        \\E <- enum
        \\    A
        \\    B
        \\f <- (e: E) -> i32:
        \\    match e:
        \\        A: 1
    , "non-exhaustive");
}

test "accepts exhaustive enum and bool matches" {
    try expectClean(
        \\E <- enum
        \\    A
        \\    B
        \\f <- (e: E) -> i32:
        \\    match e:
        \\        A: 1
        \\        B: 2
        \\g <- (b: bool) -> i32:
        \\    match b:
        \\        true: 1
        \\        false: 0
    );
}

test "checks enum constructors and unit variants" {
    try expectClean(
        \\E <- enum
        \\    A(i32)
        \\    B
        \\a <- () -> E = E::A(1)
        \\b <- () -> E = E::B
    );
}

test "checks optional values and try unwrapping" {
    try expectClean(
        \\f <- (x: ?i32) -> i32 = x?
        \\g <- () -> ?i32 = nil
    );
}

test "checks arrays, iteration, and indexing" {
    try expectClean(
        \\f <- () -> i32:
        \\    xs := [1, 2, 3]
        \\    for x in xs:
        \\        print(x)
        \\    xs[0]
    );
}

test "resolves type and function aliases from use declarations" {
    try expectClean(
        \\Base <- struct
        \\    a: i32
        \\inc <- (x: i32) -> i32 = x + 1
        \\use Base as Alias;
        \\use inc as bump;
        \\f <- (x: Alias) -> i32 = bump(x.a)
    );
}

test "handles unit return types and bare ret" {
    try expectClean(
        \\f <- () -> ():
        \\    ret
    );
    try expectDiagnostic(
        \\f <- () -> ():
        \\    ret 1
    , "type mismatch");
}

test "binds shorthand fields in struct patterns" {
    try expectClean(
        \\S <- struct
        \\    a: i32
        \\    b: i32
        \\f <- (s: S) -> i32:
        \\    match s:
        \\        S { a, b }: a + b
    );
}

test "checks enum struct-variant patterns" {
    try expectClean(
        \\E <- enum
        \\    A { x: i32, y: i32 }
        \\    B
        \\f <- (e: E) -> i32:
        \\    match e:
        \\        A { x, y }: x + y
        \\        B: 0
    );
}

test "checks enum struct-variant construction" {
    try expectClean(
        \\E <- enum
        \\    A { x: i32, y: i32 }
        \\    B
        \\f <- () -> E = E::A { x: 1, y: 2 }
    );
}

test "rejects returning a borrow of a local" {
    try expectDiagnostic(
        \\f <- () -> &i32:
        \\    x := 1
        \\    &x
    , "borrow of local");
}

test "allows returning a borrow of a parameter" {
    try expectClean(
        \\f <- (x: &i32) -> &i32 = x
    );
}

test "rejects returning a reference value that borrows a local" {
    try expectDiagnostic(
        \\f <- () -> &i32:
        \\    x := 1
        \\    r := &x
        \\    r
    , "borrowing local");
}

test "reassigning a reference releases its previous loan" {
    try expectClean(
        \\f <- () -> i32:
        \\    x := 1
        \\    y := 2
        \\    r := &x
        \\    r = &y
        \\    x = 3
        \\    0
    );
}

test "temporary mutable borrows are released after the call" {
    try expectClean(
        \\f <- () -> i32:
        \\    x := 1
        \\    print(&mut x)
        \\    x = 2
        \\    0
    );
}

test "rejects conflicting borrows in one argument list" {
    try expectDiagnostic(
        \\f <- () -> i32:
        \\    x := 1
        \\    print(&mut x, &x)
        \\    0
    , "conflicting borrow");
}

test "assigning one field does not release an unrelated field loan" {
    try expectDiagnostic(
        \\S <- struct
        \\    a: &i32
        \\    b: &i32
        \\f <- () -> i32:
        \\    x := 1
        \\    y := 2
        \\    z := 3
        \\    s := S { a: &x, b: &y }
        \\    s.a = &z
        \\    y = 4
        \\    print(s)
        \\    0
    , "borrowed");
}

test "checks all type constructor forms in fields" {
    try expectClean(
        \\E <- enum
        \\    Bad
        \\S <- struct
        \\    a: !i32
        \\    b: E!i32
        \\    c: ?i32
        \\    d: &i32
        \\    e: &mut i32
        \\    f: *i32
        \\    g: *raw i32
        \\    h: (i32) -> i32
        \\    i: (i32, u32)
        \\    j: [i32]
        \\    k: [i32; 3]
    );
}

test "attaches statement spans to semantic diagnostics" {
    const span = try findDiagnosticSpan(
        \\f <- () -> i32:
        \\    x := 1
        \\    x = "bad"
        \\    0
    , "type mismatch");
    try std.testing.expectEqual(@as(usize, 3), span.line);
    try std.testing.expect(span.column > 0);
}

test "tracks moves of non-Copy values" {
    try expectDiagnostic(
        \\S <- struct
        \\    a: i32
        \\f <- () -> i32:
        \\    s := S { a: 1 }
        \\    t := s
        \\    s.a
    , "moved");
}

test "Copy values can be used after assignment" {
    try expectClean(
        \\f <- () -> i32:
        \\    x := 1
        \\    y := x
        \\    x = 2
        \\    y + x
    );
}

test "moving while borrowed is rejected" {
    try expectDiagnostic(
        \\S <- struct
        \\    a: i32
        \\f <- () -> i32:
        \\    s := S { a: 1 }
        \\    r := &s
        \\    t := s
        \\    print(r)
        \\    0
    , "cannot move");
}

test "assigning a moved value reinitializes it" {
    try expectClean(
        \\S <- struct
        \\    a: i32
        \\f <- () -> i32:
        \\    s := S { a: 1 }
        \\    t := s
        \\    s = S { a: 2 }
        \\    s.a
    );
}

test "moves values passed to functions" {
    try expectDiagnostic(
        \\S <- struct
        \\    a: i32
        \\take <- (s: S) -> i32 = s.a
        \\f <- () -> i32:
        \\    s := S { a: 1 }
        \\    take(s)
        \\    s.a
    , "moved");
}

test "moves a local out through an if expression" {
    try expectDiagnostic(
        \\S <- struct
        \\    a: i32
        \\f <- () -> i32:
        \\    s := S { a: 1 }
        \\    x := if true: s else: S { a: 2 }
        \\    s.a
    , "moved");
}

test "reports duplicate and unreachable match arms" {
    try expectDiagnostic(
        \\E <- enum
        \\    A
        \\    B
        \\f <- (e: E) -> i32:
        \\    match e:
        \\        A: 1
        \\        A: 2
        \\        B: 3
    , "duplicate variant");
    try expectDiagnostic(
        \\f <- (x: i32) -> i32:
        \\    match x:
        \\        _: 0
        \\        1: 1
    , "unreachable");
}

test "requires a wildcard for open-ended matches" {
    try expectDiagnostic(
        \\f <- (x: i32) -> i32:
        \\    match x:
        \\        1: 1
        \\        2: 2
    , "non-exhaustive");
}

test "checks optional match coverage" {
    try expectClean(
        \\f <- (x: ?i32) -> i32:
        \\    match x:
        \\        nil: 0
        \\        _: 1
    );
    try expectDiagnostic(
        \\f <- (x: ?i32) -> i32:
        \\    match x:
        \\        nil: 0
    , "non-exhaustive");
}

test "partial struct patterns require a catch-all" {
    try expectDiagnostic(
        \\S <- struct
        \\    a: i32
        \\    b: i32
        \\f <- (s: S) -> i32:
        \\    match s:
        \\        S { a }: a
    , "non-exhaustive");
}

test "reports duplicate bool arms" {
    try expectDiagnostic(
        \\f <- (b: bool) -> i32:
        \\    match b:
        \\        true: 1
        \\        true: 2
        \\        false: 3
    , "duplicate `true`");
}

test "resolves module-qualified type and function paths" {
    try expectClean(
        \\mod a {
        \\    S <- struct
        \\        a: i32
        \\    get <- (s: S) -> i32 = s.a
        \\}
        \\f <- (s: a::S) -> i32 = a::get(s)
        \\g <- () -> a::S = a::S { a: 1 }
    );
}

test "imports types and functions from a module globe" {
    try expectClean(
        \\mod a {
        \\    S <- struct
        \\        a: i32
        \\    get <- (s: S) -> i32 = s.a
        \\}
        \\use a::*;
        \\f <- (s: S) -> i32 = get(s)
    );
}

test "supports nested module-qualified paths" {
    try expectClean(
        \\mod a {
        \\    mod b {
        \\        S <- struct
        \\            a: i32
        \\    }
        \\}
        \\f <- (s: a::b::S) -> i32 = s.a
    );
}

test "scopes unqualified names to their defining module" {
    try expectClean(
        \\mod a {
        \\    S <- struct
        \\        a: i32
        \\    f <- (s: S) -> i32 = s.a
        \\}
        \\mod b {
        \\    S <- struct
        \\        b: u32
        \\    f <- (s: S) -> u32 = s.b
        \\}
        \\g <- (s: a::S, t: b::S) -> u32 = a::f(s) as u32 + b::f(t)
    );
}

test "checks impl methods inside modules" {
    try expectClean(
        \\mod m {
        \\    S <- struct
        \\        a: i32
        \\    impl S:
        \\        new <- () -> S = S { a: 1 }
        \\}
        \\f <- () -> m::S = m::S::new()
    );
}

test "enforces generic type bounds from trait impls" {
    try expectClean(
        \\trait Show
        \\S <- struct
        \\    a: i32
        \\impl Show for S:
        \\    show <- (s: S) -> str = "S"
        \\Box<T: Show> <- struct
        \\    value: T
        \\f <- (b: Box<S>) -> i32 = b.value.a
    );
    try expectDiagnostic(
        \\trait Show
        \\Box<T: Show> <- struct
        \\    value: T
        \\f <- (b: Box<i32>) -> i32 = b.value
    , "trait bound not satisfied");
}

test "enforces where-clause bounds on types and functions" {
    try expectClean(
        \\trait Show
        \\S <- struct
        \\    a: i32
        \\impl Show for S:
        \\    show <- (s: S) -> str = "S"
        \\Box<T> <- struct where T: Show
        \\    value: T
        \\f <- (b: Box<S>) -> i32 = b.value.a
        \\id<T: Show> <- (x: T) -> T = x
        \\g <- () -> S = id<S>(S { a: 1 })
    );
    try expectDiagnostic(
        \\trait Show
        \\id<T: Show> <- (x: T) -> T = x
        \\f <- () -> i32 = id<i32>(1)
    , "trait bound not satisfied");
}

test "trait bounds respect supertraits" {
    try expectClean(
        \\trait A
        \\trait B: A
        \\S <- struct
        \\    a: i32
        \\impl B for S:
        \\    b <- (s: S) -> i32 = s.a
        \\use_a<T: A> <- (x: T) -> T = x
        \\f <- () -> S = use_a<S>(S { a: 1 })
    );
}

test "reports unknown trait bounds" {
    try expectDiagnostic(
        \\Box<T: Missing> <- struct
        \\    value: T
    , "unknown trait bound");
}

test "enforces inferred generic bounds at call sites" {
    try expectClean(
        \\trait Show
        \\S <- struct
        \\    a: i32
        \\impl Show for S:
        \\    show <- (s: S) -> str = "S"
        \\id<T: Show> <- (x: T) -> T = x
        \\f <- () -> S = id(S { a: 1 })
    );
    try expectDiagnostic(
        \\trait Show
        \\id<T: Show> <- (x: T) -> T = x
        \\f <- () -> i32 = id(1)
    , "trait bound not satisfied");
}

test "checks async functions and await" {
    try expectClean(
        \\load <- async (path: i32) -> i32 = path + 1
        \\run <- async () -> i32:
        \\    value := (await load(1))?
        \\    value
    );
}

test "await is rejected outside async context" {
    try expectDiagnostic(
        \\load <- async () -> i32 = 1
        \\run <- () -> i32:
        \\    value := (await load())?
        \\    value
    , "only allowed in async context");
}

test "checks async function expressions and spawn" {
    try expectClean(
        \\load <- async (x: i32) -> i32 = x + 1
        \\inline <- async (x: i32) -> i32 = x * 2
        \\run <- async () -> i32:
        \\    task := spawn load(1)
        \\    value := (await task)?
        \\    other := (await inline(2))?
        \\    value + other
    );
}

test "trigger declarations are callable and awaitable" {
    try expectClean(
        \\Update <- trigger
        \\    amount: i32
        \\run <- async () -> ():
        \\    await Update(10)
    );
}

test "rejects external borrows across await" {
    try expectDiagnostic(
        \\S <- struct
        \\    a: i32
        \\noop <- async () -> ():
        \\    ret
        \\Tick <- sys(q: select &a from S):
        \\    p := &q
        \\    await noop()
        \\    p
    , "cannot cross `await`");
}

test "allows task-local borrows across await" {
    try expectClean(
        \\noop <- async () -> ():
        \\    ret
        \\run <- async () -> i32:
        \\    x := 1
        \\    p := &x
        \\    await noop()
        \\    *p
    );
}

test "rejects reference parameters on async functions" {
    try expectDiagnostic(
        \\bad <- async (x: &i32) -> i32 = *x
    , "cannot contain references");
}

test "registers trigger systems and calls triggers" {
    try expectClean(
        \\Update <- trigger
        \\    amount: i32
        \\@trigger(Update)
        \\Apply <- sys():
        \\    ret
        \\run <- async () -> ():
        \\    await Update(10)
    );
}

test "resolves Task and Cancelled types" {
    try expectClean(
        \\load <- async () -> i32 = 1
        \\consume <- (t: Task<Cancelled!i32>) -> i32 = 1
        \\run <- async () -> i32:
        \\    task: Task<Cancelled!i32> := load()
        \\    value := (await task)?
        \\    value
    );
}

test "sys parameters are usable after await as fresh acquisitions" {
    try expectClean(
        \\S <- struct
        \\    a: i32
        \\noop <- async () -> ():
        \\    ret
        \\Tick <- sys(q: select &a from S, target: res &mut S):
        \\    await noop()
        \\    for row in q:
        \\        target.a = row.a
    );
}

test "supports vector, matrix, map, and str types" {
    try expectClean(
        \\vec_add <- (a: [i32; 3], b: [i32; 3]) -> [i32; 3] = a + b
        \\dot <- (a: [i32; 3], b: [i32; 3]) -> i32 = a * b
        \\mat_mul <- (a: [i32; 2, 3], b: [i32; 3, 4]) -> [i32; 2, 4] = a * b
        \\mat_vec <- (a: [i32; 2, 3], v: [i32; 3]) -> [i32; 2] = a * v
        \\scaled <- (a: [i32; 3], s: i32) -> [i32; 3] = a * s
        \\dynamic <- (a: [i32], b: [i32]) -> i32 = a * b
        \\lookup <- (m: map[str, i32]) -> i32 = m["answer"]
        \\text <- (s: str) -> str = s + "!"
    );
}

test "supports operator traits on custom types" {
    try expectClean(
        \\Foo <- struct
        \\    x: i32
        \\impl Add for Foo:
        \\    add <- (a: Foo, b: Foo) -> Foo = Foo { x: a.x + b.x }
        \\impl Sub for Foo:
        \\    sub <- (a: Foo, b: Foo) -> Foo = Foo { x: a.x - b.x }
        \\impl Mul for Foo:
        \\    mul <- (a: Foo, b: Foo) -> Foo = Foo { x: a.x * b.x }
        \\impl Div for Foo:
        \\    div <- (a: Foo, b: Foo) -> Foo = Foo { x: a.x / b.x }
        \\impl Neg for Foo:
        \\    neg <- (a: Foo) -> Foo = Foo { x: -a.x }
        \\impl PartialEq for Foo:
        \\    eq <- (a: Foo, b: Foo) -> bool = a.x == b.x
        \\impl PartialOrd for Foo:
        \\    lt <- (a: Foo, b: Foo) -> bool = a.x < b.x
        \\f <- (a: Foo, b: Foo) -> Foo = (a + b) - (a * b) / b
        \\g <- (a: Foo) -> Foo = -a
        \\h <- (a: Foo, b: Foo) -> bool = a < b
        \\i <- (a: Foo, b: Foo) -> bool = a == b
    );
}

test "supports custom Deref and operator bound checks" {
    try expectClean(
        \\Foo <- struct
        \\    x: i32
        \\impl Deref for Foo:
        \\    deref <- (f: Foo) -> i32 = f.x
        \\impl PartialOrd for Foo:
        \\    lt <- (a: Foo, b: Foo) -> bool = a.x < b.x
        \\read <- (f: Foo) -> i32 = *f
        \\cmp <- (a: Foo, b: Foo) -> bool = a < b
        \\needs_add<T: Add> <- (a: T, b: T) -> T = a + b
    );
}

test "rejects incompatible vector and matrix shapes" {
    try expectDiagnostic(
        \\bad <- (a: [i32; 2, 3], b: [i32; 4, 2]) -> [i32; 2, 2] = a * b
    , "dimension mismatch");
    try expectDiagnostic(
        \\bad <- (a: [i32; 2], b: [i32; 3]) -> i32 = a * b
    , "dimension mismatch");
}

test "supports custom Index implementations" {
    try expectClean(
        \\Foo <- struct
        \\    x: i32
        \\impl Index for Foo:
        \\    index <- (f: Foo, i: i32) -> i32 = f.x + i
        \\get <- (f: Foo, i: i32) -> i32 = f[i]
    );
}

test "matrix indexing yields a row vector" {
    try expectClean(
        \\row <- (m: [i32; 2, 3]) -> [i32; 3] = m[0]
    );
}

test "supports unsafe blocks, raw deref, and uninitialized declarations" {
    try expectClean(
        \\T <- struct
        \\    value: i32
        \\read <- (p: *raw T) -> T:
        \\    unsafe:
        \\        out: T
        \\        out = *p
        \\        ret out
    );
    try expectDiagnostic(
        \\read <- (p: *raw i32) -> i32 = *p
    , "requires an `unsafe` block");
    try expectDiagnostic(
        \\advance <- (p: *raw i32) -> *raw i32 = p + 1
    , "requires an `unsafe` block");
}

test "reports reads of uninitialized declarations" {
    try expectDiagnostic(
        \\f <- () -> i32:
        \\    x: i32
        \\    x
    , "uninitialized");
}
