#!/usr/bin/env bash
#
# End-to-end tests for `e7-fmt`, the engine7 source formatter.
#
# Usage (from anywhere):
#   bash editors/fmt/test/run.sh
#
# Environment:
#   E7_FMT_BIN         path to an already-built e7-fmt (skips the build check)
#   E7_FMT_TEST_GROUP  `all` (default), `cli`, or `behavior`
#
# Assertions are tagged [cli] or [behavior]:
#   [cli]      CLI mechanics (argument parsing, exit codes, discovery, I/O
#              plumbing, no-op safety).  These must pass even while the
#              formatter core is still a no-op stub.
#   [behavior] formatting results (whitespace, `:=` conversion, wrapping,
#              --check semantics, ...).  These require a functional core.
#
# The suite always runs in a mktemp workspace with a `build.zig.zon` marker and
# cleans up after itself; it never touches the repository's e7 sources.
set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
binary="${E7_FMT_BIN:-$repo_root/zig-out/bin/e7-fmt}"
group="${E7_FMT_TEST_GROUP:-all}"

case "$group" in
    all | cli | behavior) ;;
    *)
        echo "error: E7_FMT_TEST_GROUP must be 'all', 'cli', or 'behavior' (got '$group')" >&2
        exit 2
        ;;
esac

# Rebuild when the binary is missing or older than the formatter/CLI/support
# sources, so the suite never passes against a stale executable.  An explicit
# E7_FMT_BIN is authoritative and is never rebuilt.
if [ -z "${E7_FMT_BIN:-}" ]; then
    needs_build=0
    if [ ! -x "$binary" ]; then
        needs_build=1
    elif [ -n "$(find "$repo_root/editors/fmt/src" "$repo_root/editors/lsp/src" \
        "$repo_root/compiler/src" "$repo_root/build.zig" "$repo_root/build.zig.zon" \
        -newer "$binary" -print -quit 2>/dev/null)" ]; then
        needs_build=1
    fi
    if [ "$needs_build" -eq 1 ]; then
        if ! command -v zig >/dev/null 2>&1; then
            echo "error: e7-fmt is missing or stale and zig is not on PATH ($binary)" >&2
            echo "       run 'zig build fmt' from $repo_root or set E7_FMT_BIN" >&2
            exit 127
        fi
        echo "==> building e7-fmt"
        # The sandbox may make ~/.cache/zig read-only; keep Zig's global cache
        # in the workspace, like the repository's other test scripts.
        if ! (cd "$repo_root" && ZIG_GLOBAL_CACHE_DIR="$repo_root/.zig-cache/global" zig build fmt); then
            echo "error: failed to build e7-fmt (try: zig build fmt)" >&2
            exit 1
        fi
    fi
fi

if [ ! -x "$binary" ]; then
    echo "error: e7-fmt executable not found at $binary" >&2
    exit 127
fi

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/e7-fmt-test.XXXXXX")"
cleanup() {
    if [ -n "${tmp_root:-}" ] && [ -d "$tmp_root" ]; then
        rm -rf -- "$tmp_root"
    fi
}
trap cleanup EXIT INT TERM

stderr_capture="$tmp_root/.stderr"

# ---------------------------------------------------------------------------
# Assertion bookkeeping
# ---------------------------------------------------------------------------

total=0
passed=0
failed=0
skipped=0
cli_total=0
cli_passed=0
behavior_total=0
behavior_passed=0
failures=()

# check <cli|behavior> <description> <command...>
#
# Runs the command and records pass/fail.  Commands are ordinary shell
# commands/functions, so assertions read like `check cli "..." test "$RC" -eq 0`
# or `check behavior "..." grep -q 'value <- 1' "$file"`.
check() {
    local kind="$1"
    local description="$2"
    shift 2

    if [ "$group" != "all" ] && [ "$group" != "$kind" ]; then
        skipped=$((skipped + 1))
        return 0
    fi

    total=$((total + 1))
    if [ "$kind" = "cli" ]; then
        cli_total=$((cli_total + 1))
    else
        behavior_total=$((behavior_total + 1))
    fi

    if "$@"; then
        passed=$((passed + 1))
        if [ "$kind" = "cli" ]; then cli_passed=$((cli_passed + 1)); fi
        if [ "$kind" = "behavior" ]; then behavior_passed=$((behavior_passed + 1)); fi
        printf 'ok %d - [%s] %s\n' "$total" "$kind" "$description"
    else
        failed=$((failed + 1))
        failures+=("[$kind] $description")
        printf 'not ok %d - [%s] %s\n' "$total" "$kind" "$description"
        if [ -n "${OUT:-}" ]; then
            printf '    stdout: %s\n' "$(printf '%s' "$OUT" | head -n 3 | tr '\n' '|')"
        fi
        if [ -n "${ERR:-}" ]; then
            printf '    stderr: %s\n' "$(printf '%s' "$ERR" | head -n 3 | tr '\n' '|')"
        fi
    fi
}

not() { ! "$@"; }

rc_ok() { [ "$RC" -eq 0 ] || [ "$RC" -eq 1 ]; }

# ---------------------------------------------------------------------------
# Fixtures and helpers
# ---------------------------------------------------------------------------

# make_ws <name> -> creates (and prints) a fresh workspace with a marker file.
make_ws() {
    local dir="$tmp_root/$1"
    mkdir -p "$dir"
    printf '{}\n' >"$dir/build.zig.zon"
    printf '%s\n' "$dir"
}

# write_file <path> <exact content> (printf-based, so trailing whitespace and
# missing final newlines survive).
write_file() {
    local path="$1"
    local content="$2"
    printf '%s' "$content" >"$path"
}

# run_fmt <dir> [args...] -> sets RC, OUT, ERR (stdout/stderr are captured
# separately; stdout is stripped of its trailing newline by command
# substitution, which is exactly what assertions want).
RC=0
OUT=""
ERR=""
run_fmt() {
    local dir="$1"
    shift
    OUT="$(cd "$dir" && "$binary" "$@" 2>"$stderr_capture")"
    RC=$?
    ERR="$(cat "$stderr_capture")"
}

# run_stdin <dir> <input> [args...] -> sets RC, OUT, ERR.
run_stdin() {
    local dir="$1"
    local input="$2"
    shift 2
    OUT="$(cd "$dir" && printf '%s' "$input" | "$binary" --stdin "$@" 2>"$stderr_capture")"
    RC=$?
    ERR="$(cat "$stderr_capture")"
}

# digest <dir> -> stable checksum listing used to prove "nothing was written".
digest() {
    (cd "$1" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum)
}

# file_list <dir> -> sorted relative file paths, for artifact detection.
file_list() {
    (cd "$1" && find . -type f | sort)
}

# parse_summary -> extracts the summary counters from $OUT into globals.
FMT_COUNT=""
UNCHANGED_COUNT=""
CONV_COUNT=""
WRAP_COUNT=""
REMAIN_COUNT=0
parse_summary() {
    local line remaining_line
    line="$(printf '%s\n' "$OUT" | grep -E '^e7-fmt: [0-9]+ file\(s\) formatted' | tail -n 1)"
    [ -n "$line" ] || return 1
    FMT_COUNT="$(printf '%s\n' "$line" | sed -E 's/^e7-fmt: ([0-9]+) file\(s\) formatted.*/\1/')"
    UNCHANGED_COUNT="$(printf '%s\n' "$line" | sed -E 's/.*, ([0-9]+) unchanged.*/\1/')"
    CONV_COUNT="$(printf '%s\n' "$line" | sed -E 's/.*, ([0-9]+) conversion\(s\).*/\1/')"
    WRAP_COUNT="$(printf '%s\n' "$line" | sed -E 's/.*, ([0-9]+) wrapped line\(s\).*/\1/')"
    # The remaining-over-80 line is only printed when nonzero.
    REMAIN_COUNT=0
    remaining_line="$(printf '%s\n' "$OUT" | grep -E '^e7-fmt: [0-9]+ line\(s\) remain over' | tail -n 1)"
    if [ -n "$remaining_line" ]; then
        REMAIN_COUNT="$(printf '%s\n' "$remaining_line" | sed -E 's/^e7-fmt: ([0-9]+) line\(s\) remain.*/\1/')"
    fi
    return 0
}

summary_total_is() { [ -n "$FMT_COUNT" ] && [ "$((FMT_COUNT + UNCHANGED_COUNT))" -eq "$1" ]; }
summary_formatted_is() { [ -n "$FMT_COUNT" ] && [ "$FMT_COUNT" -eq "$1" ]; }
summary_conversions_at_least() { [ -n "$CONV_COUNT" ] && [ "$CONV_COUNT" -ge "$1" ]; }
summary_wrapped_is() { [ -n "$WRAP_COUNT" ] && [ "$WRAP_COUNT" -eq "$1" ]; }
summary_wrapped_at_least() { [ -n "$WRAP_COUNT" ] && [ "$WRAP_COUNT" -ge "$1" ]; }
summary_remaining_at_least() { [ -n "$REMAIN_COUNT" ] && [ "$REMAIN_COUNT" -ge "$1" ]; }

# max_line_le <file> <limit>: every line of <file> fits in <limit> columns.
max_line_le() {
    [ -z "$(awk -v limit="$2" 'length > limit { print; exit }' "$1")" ]
}

# last_byte_is_newline <file>
last_byte_is_newline() {
    [ -z "$(tail -c 1 "$1")" ]
}

echo "==> e7-fmt end-to-end tests ($binary)"
echo "    group: $group"
echo "    workspace: $tmp_root"

# ---------------------------------------------------------------------------
# [cli] Argument parsing and exit codes
# ---------------------------------------------------------------------------

run_fmt "$tmp_root" --version
check cli "--version exits 0" test "$RC" -eq 0
check cli "--version prints 'e7-fmt <major>.<minor>.<patch>'" \
    grep -Eq '^e7-fmt [0-9]+\.[0-9]+\.[0-9]+$' <<<"$OUT"

run_fmt "$tmp_root" --help
check cli "--help exits 0" test "$RC" -eq 0
check cli "--help mentions the Usage line" grep -q 'Usage: e7-fmt' <<<"$OUT"
check cli "--help documents --stdin" grep -q -- '--stdin' <<<"$OUT"

run_fmt "$tmp_root"
check cli "no arguments exits 2" test "$RC" -eq 2
check cli "no arguments explains the problem on stderr" grep -q 'no input files' <<<"$ERR"

run_fmt "$tmp_root" --bogus-flag
check cli "unknown option exits 2" test "$RC" -eq 2
check cli "unknown option names the flag on stderr" grep -q -- '--bogus-flag' <<<"$ERR"

run_fmt "$tmp_root" --workspace
check cli "--workspace without a value exits 2" test "$RC" -eq 2

run_fmt "$tmp_root" --version --workspace
check cli "--version wins over later bad options (exits 0)" test "$RC" -eq 0

# Flag combinations that cannot do anything sensible.
combo_ws="$(make_ws combos)"
write_file "$combo_ws/a.e7" $'a <- () -> i64:\n    ret 0\n'
write_file "$combo_ws/b.e7" $'b <- () -> i64:\n    ret 1\n'

run_stdin "$combo_ws" 'ret 0' a.e7
check cli "--stdin rejects file paths (exit 2)" test "$RC" -eq 2

run_stdin "$combo_ws" 'ret 0' --check
check cli "--stdin rejects --check (exit 2)" test "$RC" -eq 2

run_fmt "$combo_ws" --stdout --check a.e7
check cli "--stdout rejects --check (exit 2)" test "$RC" -eq 2

run_fmt "$combo_ws" --stdout a.e7 b.e7
check cli "--stdout with two paths exits 2" test "$RC" -eq 2

run_fmt "$combo_ws" --stdout .
check cli "--stdout on a directory with two files exits 2" test "$RC" -eq 2

run_fmt "$combo_ws" does-not-exist.e7
check cli "missing input exits 2" test "$RC" -eq 2
check cli "missing input names the path on stderr" grep -q 'does-not-exist.e7' <<<"$ERR"

# ---------------------------------------------------------------------------
# [cli] Directory discovery, pruning, dedupe, and write-free modes
# ---------------------------------------------------------------------------

discover_ws="$(make_ws discover)"
write_file "$discover_ws/root_a.e7" $'root_a <- () -> i64:\n    ret 0\n'
write_file "$discover_ws/root_b.e7" $'root_b <- () -> i64:\n    ret 1\n'
mkdir -p "$discover_ws/nested/deep"
write_file "$discover_ws/nested/root_c.e7" $'root_c <- () -> i64:\n    ret 2\n'
write_file "$discover_ws/nested/deep/root_d.e7" $'root_d <- () -> i64:\n    ret 3\n'
# Every pruned directory name gets one e7 file that must never be discovered.
for pruned in .git .zig-cache zig-out zig-pkg node_modules .team .tooling .local-vulkan target; do
    mkdir -p "$discover_ws/$pruned"
    write_file "$discover_ws/$pruned/ignored.e7" $'ignored <- () -> i64:\n    ret 0\n'
done

discover_before="$(digest "$discover_ws")"
run_fmt "$discover_ws" --check .
check cli "directory walk exits 0 or 1 (never a hard error)" rc_ok
check cli "directory walk prints a summary line" parse_summary
check cli "directory walk counts exactly 4 files (pruned dirs are skipped)" summary_total_is 4
check cli "--check writes nothing" test "$(digest "$discover_ws")" = "$discover_before"

run_fmt "$discover_ws" --check . root_a.e7 ./nested
check cli "overlapping inputs are de-duplicated" parse_summary
check cli "de-duplicated run still counts 4 files" summary_total_is 4

# An explicit file inside a pruned directory is still formatted when named.
run_fmt "$discover_ws" --check .git/ignored.e7
check cli "explicitly named file inside a pruned dir is still processed" parse_summary
check cli "explicitly named pruned-dir file counts as one file" summary_total_is 1

# Non-.e7 files are not picked up by directory walks.
write_file "$discover_ws/notes.txt" $'not e7\n'
run_fmt "$discover_ws" --check .
check cli "directory walk ignores non-.e7 files" parse_summary
check cli "non-.e7 files do not add to the count" summary_total_is 4

# --stdout: formatted source goes to stdout, the file is untouched.
stdout_ws="$(make_ws stdout)"
write_file "$stdout_ws/sample.e7" $'sample <- () -> i64:\n    ret 0\n'
stdout_before="$(digest "$stdout_ws")"
run_fmt "$stdout_ws" --stdout sample.e7
check cli "--stdout exits 0" test "$RC" -eq 0
check cli "--stdout prints source on stdout" grep -q 'sample <- () -> i64' <<<"$OUT"
check cli "--stdout leaves stdout free of the summary line" not grep -q 'file(s) formatted' <<<"$OUT"
check cli "--stdout does not modify the file" test "$(digest "$stdout_ws")" = "$stdout_before"

# --stdin: round-trips editor buffers and stays idempotent.
run_stdin "$tmp_root" $'sample <- () -> i64:\n    ret 0\n'
check cli "--stdin exits 0" test "$RC" -eq 0
check cli "--stdin echoes formatted source" grep -q 'sample <- () -> i64' <<<"$OUT"
first_pass="$OUT"
run_stdin "$tmp_root" "$first_pass"$'\n'
check cli "--stdin output is idempotent when fed back in" test "$OUT" = "$first_pass"

run_stdin "$tmp_root" ''
check cli "--stdin accepts an empty buffer" test "$RC" -eq 0

# --workspace: explicit roots are accepted; unresolvable roots are usage errors.
run_fmt "$combo_ws" --workspace "$combo_ws" --check a.e7
check cli "explicit --workspace is accepted" rc_ok
run_fmt "$combo_ws" --workspace "$combo_ws/missing-dir" --check a.e7
check cli "unresolvable --workspace exits 2" test "$RC" -eq 2

# --no-wrap / --no-immutable are accepted in every mode.
run_fmt "$combo_ws" --stdout --no-wrap --no-immutable a.e7
check cli "--no-wrap and --no-immutable are accepted" test "$RC" -eq 0

# In-place mode exits cleanly and leaves no temporary/backup artifacts.
artifacts_ws="$(make_ws artifacts)"
write_file "$artifacts_ws/a.e7" $'a <- () -> i64:\n    ret 0\n'
write_file "$artifacts_ws/b.e7" $'b <- () -> i64:\n    ret 1\n'
expected_list=$'./a.e7\n./b.e7\n./build.zig.zon'
run_fmt "$artifacts_ws" .
check cli "in-place formatting exits 0" test "$RC" -eq 0
check cli "in-place formatting leaves no temporary or backup files" \
    test "$(file_list "$artifacts_ws")" = "$expected_list"

# Invalid UTF-8 is skipped with exit 1 and the bytes are never rewritten.
invalid_ws="$(make_ws invalid)"
printf 'value <- ()\xff\xfe\n' >"$invalid_ws/broken.e7"
invalid_before="$(digest "$invalid_ws")"
run_fmt "$invalid_ws" broken.e7
check cli "invalid UTF-8 exits 1 (skipped)" test "$RC" -eq 1
check cli "invalid UTF-8 is reported on stderr" grep -qi 'utf-8' <<<"$ERR"
check cli "invalid UTF-8 file is left byte-identical" \
    test "$(digest "$invalid_ws")" = "$invalid_before"

# ---------------------------------------------------------------------------
# [behavior] Formatting results (require a functional formatter core)
# ---------------------------------------------------------------------------

fmt_ws="$(make_ws formatting)"
write_file "$fmt_ws/trailing.e7" $'trailing <- () -> i64:\n    x <- 1   \n    ret x\n'
write_file "$fmt_ws/no_newline.e7" $'no_newline <- () -> i64:\n    ret 0'
write_file "$fmt_ws/tabs.e7" $'tabbed <- () -> i64:\n\tx <- 1\n\tret x\n'
write_file "$fmt_ws/convert.e7" $'convert_me <- () -> i64:\n    value := 1\n    ret value + 1\n'
write_file "$fmt_ws/wrap.e7" $'wrap_me <- () -> i64:\n    ret max_of(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20)\n'
write_file "$fmt_ws/parse_error.e7" $'parse_error <- () -> i64:\n    this is not valid e7 (((\n'

# --check must notice unformatted files without touching them.
fmt_before="$(digest "$fmt_ws")"
run_fmt "$fmt_ws" --check .
check behavior "--check reports unformatted files with exit 1" test "$RC" -eq 1
check behavior "--check lists a would-change file on stdout" grep -q 'trailing.e7' <<<"$OUT"
check behavior "--check writes nothing" test "$(digest "$fmt_ws")" = "$fmt_before"

# Format in place, listing what changed.
run_fmt "$fmt_ws" --list .
check behavior "in-place formatting exits 0" test "$RC" -eq 0
check behavior "--list names the formatted files" grep -q 'trailing.e7' <<<"$OUT"
check behavior "trailing whitespace is removed" \
    not grep -qE '[[:space:]]+$' "$fmt_ws/trailing.e7"
check behavior "a missing final newline is added" last_byte_is_newline "$fmt_ws/no_newline.e7"
check behavior "tabs are normalized to spaces" not grep -q "$(printf '\t')" "$fmt_ws/tabs.e7"
check behavior "an unmutated := binding becomes <-" grep -q 'value <- 1' "$fmt_ws/convert.e7"
check behavior "long lines are wrapped below 80 columns" max_line_le "$fmt_ws/wrap.e7" 80
check behavior "the summary counts conversions" parse_summary
check behavior "summary reports at least one conversion" summary_conversions_at_least 1
check behavior "summary reports at least one wrapped line" summary_wrapped_at_least 1

# Second pass: no changes, still exit 0.
run_fmt "$fmt_ws" --check .
check behavior "second --check exits 0 (idempotent)" test "$RC" -eq 0
run_fmt "$fmt_ws" .
check behavior "second in-place run reports zero formatted files" parse_summary
check behavior "second in-place run reports zero formatted files (count)" summary_formatted_is 0
check behavior "second in-place run preserves every file" summary_total_is 6

# --no-wrap keeps long lines but still normalizes.
nowrap_ws="$(make_ws nowrap)"
write_file "$nowrap_ws/long.e7" $'wrap_me <- () -> i64:\n    ret max_of(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20)\n'
run_fmt "$nowrap_ws" --no-wrap long.e7
check behavior "--no-wrap reports zero wrapped lines" parse_summary
check behavior "--no-wrap reports zero wrapped lines (count)" summary_wrapped_is 0
check behavior "--no-wrap leaves the long line over 80 columns" not max_line_le "$nowrap_ws/long.e7" 80

# --no-immutable keeps `:=` as written.
keep_ws="$(make_ws keep)"
write_file "$keep_ws/keep.e7" $'keep_me <- () -> i64:\n    value := 1\n    ret value + 1\n'
run_fmt "$keep_ws" --no-immutable keep.e7
check behavior "--no-immutable keeps := bindings" grep -q 'value := 1' "$keep_ws/keep.e7"

# Lines with an unbreakable over-long token (a string literal) are reported,
# not mangled; --list adds the per-file detail on stderr.
long_string_ws="$(make_ws long_string)"
long_string=$(printf 'a%.0s' $(seq 1 90))
{
    printf 'long_string <- () -> str:\n'
    printf '    ret "%s"\n' "$long_string"
} >"$long_string_ws/string.e7"
run_fmt "$long_string_ws" --list string.e7
check behavior "unbreakable long lines are reported in the summary" parse_summary
check behavior "summary reports lines remaining over 80 columns" summary_remaining_at_least 1
check behavior "--list details lines that remain over 80 columns on stderr" \
    grep -q 'over 80 columns' <<<"$ERR"

# --list/--check ordering is deterministic (sorted paths).
order_ws="$(make_ws order)"
write_file "$order_ws/b_second.e7" $'b_second <- () -> i64:\n    ret 1   \n'
write_file "$order_ws/a_first.e7" $'a_first <- () -> i64:\n    ret 0   \n'
run_fmt "$order_ws" --list --check .
check behavior "--check lists changed files in sorted order" \
    test "$(printf '%s\n' "$OUT" | head -n 1)" = "a_first.e7"

# Parse errors: whitespace normalization is applied, no data is lost, and the
# user is told on stderr.
parse_ws="$(make_ws parse)"
write_file "$parse_ws/broken.e7" $'broken <- () -> i64:\n    this is not valid e7 (((\n'
run_fmt "$parse_ws" broken.e7
check behavior "parse-error file does not fail the run" test "$RC" -eq 0
check behavior "parse error is noted on stderr" grep -q 'parse error' <<<"$ERR"
check behavior "parse-error content is preserved" grep -q 'not valid e7' "$parse_ws/broken.e7"

# Write mode preserves the file mode.
perms_ws="$(make_ws perms)"
write_file "$perms_ws/perms.e7" $'perms <- () -> i64:\n    ret 0   \n'
chmod 640 "$perms_ws/perms.e7"
run_fmt "$perms_ws" perms.e7
check behavior "in-place writes preserve file permissions" \
    test "$(stat -c '%a' "$perms_ws/perms.e7")" = "640"

# A read-only unformatted file fails cleanly without being modified.  Root can
# write regardless of the mode bits, so skip that assertion when running as
# root (the digest check would still pass, but the exit code would not).
if [ "$(id -u)" -ne 0 ]; then
    readonly_ws="$(make_ws readonly)"
    write_file "$readonly_ws/readonly.e7" $'readonly <- () -> i64:\n    ret 0   \n'
    chmod 444 "$readonly_ws/readonly.e7"
    readonly_before="$(digest "$readonly_ws")"
    run_fmt "$readonly_ws" readonly.e7
    check behavior "write failure on a read-only file exits 2" test "$RC" -eq 2
    check behavior "read-only file is not modified" \
        test "$(digest "$readonly_ws")" = "$readonly_before"
fi

# --stdout formats without modifying the source file.
stdout_fmt_ws="$(make_ws stdout_format)"
write_file "$stdout_fmt_ws/fmt.e7" $'fmt_me <- () -> i64:\n    ret 0   \n'
stdout_fmt_before="$(digest "$stdout_fmt_ws")"
run_fmt "$stdout_fmt_ws" --stdout fmt.e7
check behavior "--stdout removes trailing whitespace from its output" \
    not grep -qE '[[:space:]]+$' <<<"$OUT"
check behavior "--stdout does not write the file even when it changes" \
    test "$(digest "$stdout_fmt_ws")" = "$stdout_fmt_before"

# --stdin formats editor buffers.
run_stdin "$tmp_root" $'stdin_me <- () -> i64:\n    ret 0   \n'
check behavior "--stdin removes trailing whitespace from its output" \
    not grep -qE '[[:space:]]+$' <<<"$OUT"

# stdin parse errors: source stays on stdout, diagnostics stay on stderr.
run_stdin "$tmp_root" $'broken <- () -> i64:\n    this is not valid e7 (((\n'
check behavior "--stdin keeps source on stdout when parsing fails" \
    grep -q 'not valid e7' <<<"$OUT"
check behavior "--stdin sends the parse-error note to stderr" grep -q 'parse error' <<<"$ERR"

# --stdin and --stdout agree on formatting (both go through the same core).
write_file "$tmp_root/agree.e7" $'agree <- () -> i64:\n    ret 0   \n'
run_stdin "$tmp_root" $'agree <- () -> i64:\n    ret 0   \n'
stdin_formatted="$OUT"
run_fmt "$tmp_root" --stdout agree.e7
check behavior "--stdin and --stdout produce the same formatted text" \
    test "$OUT" = "$stdin_formatted"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
if [ "$skipped" -gt 0 ]; then
    echo "e7-fmt tests: $passed/$total passed, $failed failed ($skipped skipped by group filter)"
else
    echo "e7-fmt tests: $passed/$total passed, $failed failed"
fi
echo "  cli:      $cli_passed/$cli_total passed"
echo "  behavior: $behavior_passed/$behavior_total passed"

if [ "$failed" -ne 0 ]; then
    echo "FAIL: $failed assertion(s) failed:"
    for failure in "${failures[@]}"; do
        echo "  - $failure"
    done
    exit 1
fi

if [ "$group" = "cli" ] && [ "$behavior_total" -eq 0 ]; then
    echo "PASS: e7-fmt CLI mechanics (behavior assertions skipped by E7_FMT_TEST_GROUP=cli)"
elif [ "$group" = "behavior" ] && [ "$cli_total" -eq 0 ]; then
    echo "PASS: e7-fmt formatting behavior (CLI assertions skipped by E7_FMT_TEST_GROUP=behavior)"
else
    echo "PASS: e7-fmt end-to-end tests"
fi
