//! `e7-test`: run tests written in the e7 language itself.
//!
//!     zig build test-e7
//!     zig build test-e7 -- --suite tests/e7 --filter string
//!     zig build test-e7 -- --list
//!
//! A `.e7` file in the suite directory is one test module.  Top-level
//! functions whose name starts with `test_` are discovered as tests; a test
//! takes no parameters and returns 0 on success (a nonzero return marks the
//! test failed).  Tests are compiled with the normal compiler pipeline
//! (parser -> semantic -> bytecode -> LLVM IR -> ORC JIT) and each function is
//! invoked separately in declaration order.
//!
//! Assertions are e7-callable host intrinsics (runtime/src/test_support.zig)
//! wrapped by a small prelude (`assert_eq_i64`, `assert_eq_bool`,
//! `assert_i64_near`, `assert_f32_near`, `assert_str_eq`, `assert_fail`)
//! inserted ahead of every suite module:
//!
//!     test_arithmetic <- () -> i64:
//!         assert_eq_i64(2 + 3, 5)
//!         assert_eq_bool(3 < 4, true)
//!         ret 0
//!
//! A suite file may pull shared or platform e7 sources in front of itself with
//! header comments, so engine units can be tested without a display:
//!
//!     # e7-test-source: ../../engine/platform/vulkan.e7
//!     # e7-test-source: ../../engine/platform/scene.e7
//!
//! The existing Zig test suite (`zig build test`) is unchanged and remains the
//! primary test entry point.

const std = @import("std");
const compiler = @import("compiler");
const orc = @import("orc.zig");
const task = @import("task.zig");
const ecs = @import("ecs.zig");
const test_support = @import("test_support.zig");

pub const Options = struct {
    /// Directory scanned for `*.e7` test modules (relative to the cwd).
    suite: []const u8 = "tests/e7",
    /// Only run tests whose `<file>::<test>` identifier contains this text.
    filter: ?[]const u8 = null,
    /// Print discovered tests without running them.
    list_only: bool = false,
    /// Suppress per-test `ok` lines and the final summary (failures still print).
    quiet: bool = false,
};

pub const Summary = struct {
    files: usize = 0,
    tests: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    assertions: usize = 0,
    compile_failures: usize = 0,

    /// Process exit code: nonzero when anything failed, when a module did not
    /// compile, or when no test was discovered at all.
    pub fn exitCode(self: Summary) u8 {
        if (self.failed > 0 or self.compile_failures > 0) return 1;
        if (self.tests == 0) return 1;
        return 0;
    }
};

const TestInfo = struct {
    name: []u8,
    is_async: bool,
};

/// Assertion sugar prepended to every suite module.  The host intrinsics stay
/// namespaced (`e7_test_*`); tests use plain `assert_*` wrappers, and
/// `test_async_*` functions are awaited by the runner.
pub const prelude =
    \\# e7 test prelude, inserted by runtime/src/e7_test.zig.
    \\# Return the intrinsic status; tests call these as statements and the
    \\# runner reports any recorded failure after the test function returns.
    \\assert_eq_i64 <- (actual: i64, expected: i64) -> i64:
    \\    ret e7_test_assert_eq_i64(actual, expected)
    \\assert_eq_bool <- (actual: bool, expected: bool) -> i64:
    \\    ret e7_test_assert_eq_bool(actual, expected)
    \\assert_i64_near <- (actual: i64, expected: i64, tolerance: i64) -> i64:
    \\    ret e7_test_assert_i64_near(actual, expected, tolerance)
    \\assert_f32_near <- (actual: f32, expected: f32, tolerance: f32) -> i64:
    \\    ret e7_test_assert_f32_near(actual, expected, tolerance)
    \\assert_str_eq <- (actual: str, expected: str) -> i64:
    \\    ret e7_test_assert_str_eq(actual, expected)
    \\assert_fail <- () -> i64:
    \\    ret e7_test_assert_fail()
;

/// Prefix that marks a top-level e7 function as a test.
pub const test_prefix = "test_";

pub fn isTestName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, test_prefix)) return false;
    if (name.len <= test_prefix.len) return false;
    // Async functions additionally compile to an internal `<name>__body`
    // function carrying the parameters; only the public task constructor is a
    // test entry point.
    if (std.mem.endsWith(u8, name, "__body")) return false;
    return true;
}

/// Run every `test_*` function in every `.e7` file of `options.suite`.
pub fn runSuite(allocator: std.mem.Allocator, io: std.Io, options: Options) !Summary {
    var summary = Summary{};

    const suite_path = options.suite;
    var dir = std.Io.Dir.cwd().openDir(io, suite_path, .{ .iterate = true }) catch |err| {
        std.debug.print("e7-test: cannot open suite directory '{s}': {s}\n", .{ suite_path, @errorName(err) });
        summary.compile_failures += 1;
        return summary;
    };
    defer dir.close(io);

    var file_names = std.ArrayList([]u8).empty;
    defer {
        for (file_names.items) |name| allocator.free(name);
        file_names.deinit(allocator);
    }
    {
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!std.mem.endsWith(u8, entry.name, ".e7")) continue;
            try file_names.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]u8, file_names.items, {}, struct {
        fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    for (file_names.items) |file_name| {
        const path = try std.fs.path.join(allocator, &.{ suite_path, file_name });
        defer allocator.free(path);
        try runFile(allocator, io, path, options, &summary);
    }

    if (!options.quiet) {
        if (options.list_only and summary.tests > 0) {
            std.debug.print("e7 tests: {d} tests discovered in {d} files\n", .{
                summary.tests, summary.files,
            });
        } else if (summary.tests > 0 or summary.failed > 0 or summary.compile_failures > 0) {
            std.debug.print(
                "e7 tests: {d} passed, {d} failed, {d} total in {d} files ({d} assertions){s}\n",
                .{
                    summary.passed,
                    summary.failed,
                    summary.tests,
                    summary.files,
                    summary.assertions,
                    if (summary.compile_failures > 0) ", module compile failures" else "",
                },
            );
        } else {
            std.debug.print("e7 tests: no test_* functions found in '{s}'\n", .{suite_path});
        }
    }
    return summary;
}

fn runFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    options: Options,
    summary: *Summary,
) !void {
    summary.files += 1;

    const source = loadSuiteSource(allocator, io, path) catch |err| {
        std.debug.print("e7-test: {s}: cannot load suite source: {s}\n", .{ path, @errorName(err) });
        summary.compile_failures += 1;
        return;
    };
    defer allocator.free(source);

    // Parse and analyze first so compile errors get file diagnostics instead
    // of a bare error name.
    const parsed_result = compiler.parser.parse(allocator, source) catch |err| {
        std.debug.print("e7-test: {s}: parser error: {s}\n", .{ path, @errorName(err) });
        summary.compile_failures += 1;
        return;
    };
    var parsed = switch (parsed_result) {
        .ast => |tree| tree,
        .diagnostic => |diagnostic| {
            std.debug.print("e7-test: {s}:{d}:{d}: {s}\n", .{
                path, diagnostic.line, diagnostic.column, diagnostic.message,
            });
            summary.compile_failures += 1;
            return;
        },
    };
    defer parsed.deinit();

    var analysis = compiler.semantic.analyze(allocator, parsed.module) catch |err| {
        std.debug.print("e7-test: {s}: semantic analysis error: {s}\n", .{ path, @errorName(err) });
        summary.compile_failures += 1;
        return;
    };
    defer analysis.deinit();
    if (!analysis.ok()) {
        for (analysis.diagnostics) |diagnostic| {
            std.debug.print("e7-test: {s}:{}:{}: {s}\n", .{
                path, diagnostic.span.line, diagnostic.span.column, diagnostic.message,
            });
        }
        summary.compile_failures += 1;
        return;
    }

    var compiled = compiler.pipeline.compile(allocator, source, .{}) catch |err| {
        std.debug.print("e7-test: {s}: compile error: {s}\n", .{ path, @errorName(err) });
        summary.compile_failures += 1;
        return;
    };
    defer compiled.deinit();

    var tests = std.ArrayList(TestInfo).empty;
    defer {
        for (tests.items) |info| allocator.free(info.name);
        tests.deinit(allocator);
    }
    for (compiled.bytecode.functions) |function| {
        if (!isTestName(function.name)) continue;
        if (function.params != 0) {
            std.debug.print(
                "e7-test: {s}: test '{s}' must take no parameters (found {d})\n",
                .{ path, function.name, function.params },
            );
            summary.compile_failures += 1;
            continue;
        }
        try tests.append(allocator, .{
            .name = try allocator.dupe(u8, function.name),
            // Async functions return a task handle; the runner awaits it.
            .is_async = std.mem.startsWith(u8, function.name, "test_async_"),
        });
    }
    if (tests.items.len == 0) {
        if (!options.quiet) std.debug.print("e7-test: {s}: no test_* functions\n", .{path});
        return;
    }

    if (options.list_only) {
        for (tests.items) |info| {
            if (!matchesFilter(path, info.name, options.filter)) continue;
            std.debug.print("{s}::{s}\n", .{ path, info.name });
            summary.tests += 1;
        }
        return;
    }

    var jit = orc.Jit.init(allocator) catch |err| {
        std.debug.print("e7-test: {s}: JIT init failed: {s}\n", .{ path, @errorName(err) });
        summary.compile_failures += 1;
        return;
    };
    defer jit.deinit();
    jit.addBytecode(&compiled.bytecode, "e7-test-module") catch |err| {
        std.debug.print("e7-test: {s}: bytecode lowering failed: {s}\n", .{ path, @errorName(err) });
        summary.compile_failures += 1;
        return;
    };
    const assertion_symbols = test_support.symbols();
    jit.defineSymbols(&assertion_symbols) catch |err| {
        std.debug.print("e7-test: {s}: cannot register assertion helpers: {s}\n", .{ path, @errorName(err) });
        summary.compile_failures += 1;
        return;
    };
    // Async functions are awaited deterministically on the calling thread.
    task.e7_task_set_inline(1);
    defer task.e7_task_set_inline(0);

    for (tests.items) |info| {
        if (!matchesFilter(path, info.name, options.filter)) continue;
        summary.tests += 1;
        runOneTest(path, &compiled, &jit, info.name, info.is_async, summary) catch |err| {
            std.debug.print("e7-test: {s}::{s}: harness error: {s}\n", .{ path, info.name, @errorName(err) });
            summary.failed += 1;
        };
    }
}

fn runOneTest(
    path: []const u8,
    compiled: *compiler.CompileResult,
    jit: *orc.Jit,
    name: []const u8,
    is_async: bool,
    summary: *Summary,
) !void {
    // Fresh ECS world and assertion state per test: e7 has no mutable module
    // globals, so function-level isolation is enough for language tests while
    // host-side world state is reset explicitly.
    ecs.e7_ecs_reset();
    for (compiled.analysis.resources) |resource| {
        if (resource.plugin_id != null) continue;
        _ = ecs.e7_ecs_register_resource(resource.id, @intCast(resource.slots));
    }
    for (compiled.analysis.components) |component| {
        _ = ecs.e7_ecs_register_component(component.id, @intCast(component.slots));
    }
    test_support.reset();

    const TestFn = *const fn () callconv(.c) i64;
    const function = jit.get(TestFn, name) catch |err| {
        std.debug.print("FAIL {s}::{s}: symbol lookup failed: {s}\n", .{ path, name, @errorName(err) });
        summary.failed += 1;
        return;
    };
    var result = function();
    if (is_async) {
        if (result == 0) {
            summary.failed += 1;
            std.debug.print("FAIL {s}::{s}: async test returned a null task handle\n", .{ path, name });
            return;
        }
        result = task.e7_task_await(result);
    }
    const assertions = test_support.assertionCount();
    summary.assertions += assertions;
    const failures = test_support.failures();
    if (failures.len > 0 or result != 0) {
        summary.failed += 1;
        std.debug.print("FAIL {s}::{s} ({d} assertions)\n", .{ path, name, assertions });
        for (failures) |message| std.debug.print("       {s}\n", .{message});
        if (result != 0) {
            std.debug.print("       test function returned {d} (0 = pass)\n", .{result});
        }
        return;
    }
    summary.passed += 1;
    std.debug.print("ok   {s}::{s} ({d} assertions)\n", .{ path, name, assertions });
}

fn matchesFilter(path: []const u8, name: []const u8, filter: ?[]const u8) bool {
    const wanted = filter orelse return true;
    if (wanted.len == 0) return true;
    // Match against both the full identifier and the bare test name.
    if (std.mem.indexOf(u8, name, wanted) != null) return true;
    return std.mem.indexOf(u8, path, wanted) != null;
}

/// Read a suite module, prepending any `# e7-test-source: <path>` includes.
/// Include paths are relative to the suite file.
fn loadSuiteSource(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const test_source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(test_source);

    var combined = std.ArrayList(u8).empty;
    errdefer combined.deinit(allocator);
    try combined.appendSlice(allocator, prelude);
    try combined.append(allocator, '\n');

    const directory = std.fs.path.dirname(path) orelse ".";
    var lines = std.mem.splitScalar(u8, test_source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const prefix = "# e7-test-source:";
        if (!std.mem.startsWith(u8, trimmed, prefix)) continue;
        const relative = std.mem.trim(u8, trimmed[prefix.len..], " \t");
        if (relative.len == 0) continue;
        const include_path = if (std.fs.path.isAbsolute(relative))
            try allocator.dupe(u8, relative)
        else
            try std.fs.path.join(allocator, &.{ directory, relative });
        defer allocator.free(include_path);
        const include_source = std.Io.Dir.cwd().readFileAlloc(
            io,
            include_path,
            allocator,
            .limited(32 * 1024 * 1024),
        ) catch |err| {
            std.debug.print("e7-test: {s}: missing e7-test-source '{s}': {s}\n", .{
                path, include_path, @errorName(err),
            });
            return error.MissingSource;
        };
        defer allocator.free(include_source);
        try combined.appendSlice(allocator, include_source);
        try combined.append(allocator, '\n');
    }
    try combined.appendSlice(allocator, test_source);
    return combined.toOwnedSlice(allocator);
}

// ------------------------------------------------------------------- main ---

pub fn main(init: std.process.Init) !void {
    var options = Options{};
    var args = init.minimal.args.iterate();
    _ = args.next(); // executable name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--suite")) {
            options.suite = args.next() orelse return usageError("--suite requires a directory");
        } else if (std.mem.eql(u8, arg, "--filter")) {
            options.filter = args.next() orelse return usageError("--filter requires a substring");
        } else if (std.mem.eql(u8, arg, "--list")) {
            options.list_only = true;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            options.quiet = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else {
            std.debug.print("e7-test: unknown argument '{s}'\n", .{arg});
            return usageError("unknown argument");
        }
    }

    const allocator = std.heap.c_allocator;
    const summary = runSuite(allocator, init.io, options) catch |err| {
        std.debug.print("e7-test: suite failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.process.exit(summary.exitCode());
}

fn usageError(message: []const u8) error{InvalidArguments} {
    std.debug.print("e7-test: {s}\n", .{message});
    printHelp();
    return error.InvalidArguments;
}

fn printHelp() void {
    std.debug.print(
        \\Usage: e7-test [options]
        \\
        \\  --suite DIR      directory of .e7 test modules (default: tests/e7)
        \\  --filter TEXT    only run tests containing TEXT in the file or name
        \\  --list           list discovered tests without running them
        \\  --quiet          suppress per-test ok lines and the summary
        \\  -h, --help       show this help
        \\
        \\Tests are top-level e7 functions named `test_*` with no parameters;
        \\they return 0 on success.  `test_async_*` tests are declared async and
        \\are awaited by the runner.  Assertions: assert_eq_i64, assert_eq_bool,
        \\assert_i64_near, assert_f32_near, assert_str_eq, assert_fail.
        \\
    , .{});
}

// ------------------------------------------------------- harness self-tests --

const testing = std.testing;

fn writeFixture(tmp: *std.testing.TmpDir, relative: []const u8, contents: []const u8) !void {
    const io = testing.io;
    if (std.fs.path.dirname(relative)) |directory| {
        try tmp.dir.createDirPath(io, directory);
    }
    try tmp.dir.writeFile(io, .{ .sub_path = relative, .data = contents });
}

fn suitePath(tmp: *std.testing.TmpDir, buffer: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const length = try tmp.dir.realPath(testing.io, buffer);
    return buffer[0..length];
}

test "discovers test_* functions and ignores other functions" {
    try testing.expect(isTestName("test_arithmetic"));
    try testing.expect(!isTestName("test_"));
    try testing.expect(!isTestName("helper"));
    try testing.expect(!isTestName("main"));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "discovery.e7",
        \\helper <- (a: i64, b: i64) -> i64 = a + b
        \\test_one <- () -> i64:
        \\    assert_eq_i64(helper(2, 3), 5)
        \\    ret 0
        \\test_two <- () -> i64:
        \\    ret 0
        \\main <- () -> i64 = 0
        \\
    );
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try suitePath(&tmp, &buffer);
    const summary = try runSuite(testing.allocator, testing.io, .{ .suite = path, .quiet = true });
    try testing.expectEqual(@as(usize, 1), summary.files);
    try testing.expectEqual(@as(usize, 2), summary.tests);
    try testing.expectEqual(@as(usize, 2), summary.passed);
    try testing.expectEqual(@as(usize, 0), summary.failed);
    try testing.expectEqual(@as(usize, 1), summary.assertions);
    try testing.expectEqual(@as(u8, 0), summary.exitCode());
}

test "passing and failing modules produce the expected exit codes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try suitePath(&tmp, &buffer);

    try writeFixture(&tmp, "pass.e7",
        \\test_pass <- () -> i64:
        \\    assert_eq_i64(2 + 2, 4)
        \\    assert_eq_bool(1 < 2, true)
        \\    assert_i64_near(1000, 1004, 5)
        \\    ret 0
        \\
    );
    const pass_summary = try runSuite(testing.allocator, testing.io, .{ .suite = path, .quiet = true });
    try testing.expectEqual(@as(usize, 1), pass_summary.tests);
    try testing.expectEqual(@as(usize, 1), pass_summary.passed);
    try testing.expectEqual(@as(usize, 0), pass_summary.failed);
    try testing.expectEqual(@as(usize, 3), pass_summary.assertions);
    try testing.expectEqual(@as(u8, 0), pass_summary.exitCode());

    try writeFixture(&tmp, "fail.e7",
        \\test_assert_failure <- () -> i64:
        \\    assert_eq_i64(2 + 2, 5)
        \\    ret 0
        \\
        \\test_explicit_failure <- () -> i64:
        \\    ret 3
        \\
    );
    const fail_summary = try runSuite(testing.allocator, testing.io, .{ .suite = path, .quiet = true });
    try testing.expectEqual(@as(usize, 3), fail_summary.tests);
    try testing.expectEqual(@as(usize, 1), fail_summary.passed);
    try testing.expectEqual(@as(usize, 2), fail_summary.failed);
    try testing.expectEqual(@as(u8, 1), fail_summary.exitCode());

    // Run only the assertion-failing test to inspect the recorded detail.
    const detail_summary = try runSuite(testing.allocator, testing.io, .{
        .suite = path,
        .quiet = true,
        .filter = "test_assert_failure",
    });
    try testing.expectEqual(@as(usize, 1), detail_summary.tests);
    try testing.expectEqual(@as(usize, 1), detail_summary.failed);
    try testing.expectEqual(@as(usize, 1), test_support.failures().len);
    try testing.expect(std.mem.indexOf(u8, test_support.failures()[0], "expected 5, found 4") != null);
}

test "string helpers and include directives" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "support/util.e7",
        \\double <- (value: i64) -> i64 = value * 2
        \\
    );
    try writeFixture(&tmp, "strings.e7",
        \\# e7-test-source: support/util.e7
        \\test_includes <- () -> i64:
        \\    assert_eq_i64(double(21), 42)
        \\    assert_str_eq("e7" + "test", "e7test")
        \\    assert_f32_near(0.5, 0.5, 0.000001)
        \\    ret 0
        \\
    );
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try suitePath(&tmp, &buffer);
    const summary = try runSuite(testing.allocator, testing.io, .{ .suite = path, .quiet = true });
    try testing.expectEqual(@as(usize, 1), summary.tests);
    try testing.expectEqual(@as(usize, 1), summary.passed);
    try testing.expectEqual(@as(usize, 3), summary.assertions);
}

test "integer-only loops lower without the InstCombine fixed-point abort" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "loops.e7",
        \\sum_to <- (n: i64) -> i64:
        \\    total := 0
        \\    index := 1
        \\    while index <= n:
        \\        total = total + index
        \\        index = index + 1
        \\    ret total
        \\test_integer_loop <- () -> i64:
        \\    assert_eq_i64(sum_to(10), 55)
        \\    ret 0
        \\
    );
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try suitePath(&tmp, &buffer);
    const summary = try runSuite(testing.allocator, testing.io, .{ .suite = path, .quiet = true });
    try testing.expectEqual(@as(usize, 1), summary.tests);
    try testing.expectEqual(@as(usize, 1), summary.passed);
    try testing.expectEqual(@as(usize, 0), summary.failed);
}

test "compile failures and empty suites exit nonzero" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "broken.e7",
        \\test_broken <- () -> i64:
        \\    ret missing_function(1)
        \\
    );
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try suitePath(&tmp, &buffer);
    const summary = try runSuite(testing.allocator, testing.io, .{ .suite = path, .quiet = true });
    try testing.expectEqual(@as(usize, 1), summary.compile_failures);
    try testing.expectEqual(@as(u8, 1), summary.exitCode());

    var empty = testing.tmpDir(.{});
    defer empty.cleanup();
    const empty_path = try suitePath(&empty, &buffer);
    const empty_summary = try runSuite(testing.allocator, testing.io, .{ .suite = empty_path, .quiet = true });
    try testing.expectEqual(@as(usize, 0), empty_summary.tests);
    try testing.expectEqual(@as(u8, 1), empty_summary.exitCode());
}
