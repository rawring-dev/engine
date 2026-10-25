#!/bin/sh
# check-slang.sh -- validate generated Khronos Slang sources with a real slangc.
#
# For every `.slang` file in the given directories/files:
#   * find every entry point declared with [shader("...")] [numthreads(...)],
#   * compile each entry to SPIR-V with:
#         slangc -target spirv -profile spirv_1_5 -entry <name> -stage <stage>
#   * files with no entry points (modules / libraries) are front-end checked
#     with `slangc -target none` instead.
#
# Prints a PASS/FAIL line per entry and a summary; exits non-zero if anything
# failed.  Import search paths (-I) are added for every directory argument, for
# --module-dir, and for the parent directory of every discovered file.
#
# Usage:
#   check-slang.sh [options] <dir-or-file>...
#
# Options:
#   --slangc PATH      slangc executable to use.  Default: $SLANGC, else
#                      <repo>/.tooling/slang/bin/slangc, else `slangc` on PATH.
#   --module-dir DIR   Add DIR to the import search path (repeatable).
#   -I DIR             Alias for --module-dir.
#   --keep             Keep the generated .spv files and print their directory.
#   --spirv-val        Also run `spirv-val` on each generated .spv if available.
#   -v, --verbose      Echo the exact slangc command line for each compile.
#   -h, --help         Show this help.
#
# Environment:
#   SLANGC             slangc executable (used when --slangc is not given).
#   SLANG_TARGET       Target, default "spirv".
#   SLANG_PROFILE      Profile, default "spirv_1_5".
#
# Exit status: 0 = every entry compiled, 1 = at least one failure, 2 = usage or
# configuration error (no slangc, no input files, ...).

set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
root_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd) || exit 2

target=${SLANG_TARGET:-spirv}
profile=${SLANG_PROFILE:-spirv_1_5}

keep=0
verbose=0
run_spirv_val=0
slangc_arg=''

inc_file=$(mktemp 2>/dev/null) || { echo "check-slang: cannot create temp file" >&2; exit 2; }
file_list=$(mktemp 2>/dev/null) || { rm -f "$inc_file"; echo "check-slang: cannot create temp file" >&2; exit 2; }
tmpdir=$(mktemp -d 2>/dev/null) || { rm -f "$inc_file" "$file_list"; echo "check-slang: cannot create temp dir" >&2; exit 2; }

cleanup() {
    [ "$keep" = 1 ] || rm -rf "$tmpdir"
    rm -f "$inc_file" "$file_list"
}
trap cleanup EXIT INT TERM HUP

die() {
    echo "check-slang: $*" >&2
    exit 2
}

usage() {
    sed -n '2,35p' "$0" | sed -e 's/^# \{0,1\}//' -e '/^$/d'
}

add_dir() {
    # $1 directory; dedupe in $inc_file
    [ -d "$1" ] || return 0
    if [ ! -s "$inc_file" ] || ! grep -Fxq -- "$1" "$inc_file" 2>/dev/null; then
        printf '%s\n' "$1" >> "$inc_file"
    fi
}

add_input() {
    if [ -d "$1" ]; then
        add_dir "$1"
        find "$1" -type f -name '*.slang' -print >> "$file_list" 2>/dev/null
    elif [ -f "$1" ]; then
        case $1 in
            *.slang) ;;
            *) echo "check-slang: warning: not a .slang file, skipping: $1" >&2; return 0 ;;
        esac
        printf '%s\n' "$1" >> "$file_list"
        add_dir "$(dirname -- "$1")"
    else
        die "no such file or directory: $1"
    fi
}

while [ $# -gt 0 ]; do
    case $1 in
        --slangc)
            [ $# -ge 2 ] || die "--slangc requires a path"
            slangc_arg=$2
            shift 2
            ;;
        --slangc=*)
            slangc_arg=${1#--slangc=}
            shift
            ;;
        --module-dir|-I)
            [ $# -ge 2 ] || die "$1 requires a directory"
            add_dir "$2"
            shift 2
            ;;
        --module-dir=*)
            add_dir "${1#--module-dir=}"
            shift
            ;;
        -I*)
            add_dir "${1#-I}"
            shift
            ;;
        --keep)
            keep=1
            shift
            ;;
        --spirv-val)
            run_spirv_val=1
            shift
            ;;
        -v|--verbose)
            verbose=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            while [ $# -gt 0 ]; do add_input "$1"; shift; done
            ;;
        -*)
            die "unknown option: $1 (try --help)"
            ;;
        *)
            add_input "$1"
            shift
            ;;
    esac
done

# ---- resolve slangc ---------------------------------------------------------
if [ -n "$slangc_arg" ]; then
    slangc=$slangc_arg
elif [ -n "${SLANGC:-}" ]; then
    slangc=$SLANGC
elif [ -x "$root_dir/.tooling/slang/bin/slangc" ]; then
    slangc="$root_dir/.tooling/slang/bin/slangc"
else
    slangc=$(command -v slangc 2>/dev/null) || slangc=''
fi
[ -n "$slangc" ] || die "slangc not found: pass --slangc, set \$SLANGC, or install slangc"
[ -x "$slangc" ] || die "slangc is not executable: $slangc"

# ---- collect inputs ---------------------------------------------------------
sort -u "$file_list" > "$tmpdir/files.sorted"
mv "$tmpdir/files.sorted" "$file_list"
while IFS= read -r f; do
    add_dir "$(dirname -- "$f")"
done < "$file_list"

if [ ! -s "$file_list" ]; then
    die "no .slang files found in the given inputs"
fi

slangc_version=$("$slangc" -v 2>&1 | head -n 1)
[ -n "$slangc_version" ] || slangc_version='unknown'

# ---- entry point discovery --------------------------------------------------
# Emits one "<stage> <function>" line per [shader("...")] entry.  Handles
# attributes and signatures on the same line or spread across several lines,
# leading [[vk::...]]/other attributes, and a trailing return-type semantic.
entry_awk='
function find_name(s,    i, j, endpos, c, depth) {
    sub(/^[[:space:]]+/, "", s)
    if (s == "" || substr(s, 1, 2) == "//") return ""
    while (match(s, /^\[[^][]*\]/)) {
        s = substr(s, RLENGTH + 1)
        sub(/^[[:space:]]+/, "", s)
    }
    i = index(s, "(")
    if (i == 0) return ""
    j = i - 1
    while (j > 0 && substr(s, j, 1) ~ /[[:space:]]/) j--
    if (j > 0 && substr(s, j, 1) == ">") {
        depth = 1
        while (j > 0 && depth > 0) {
            c = substr(s, j, 1)
            if (c == ">") depth++
            else if (c == "<") depth--
            j--
        }
        while (j > 0 && substr(s, j, 1) ~ /[[:space:]]/) j--
    }
    endpos = j
    while (j > 0 && substr(s, j, 1) ~ /[A-Za-z0-9_]/) j--
    if (endpos == j) return ""
    return substr(s, j + 1, endpos - j)
}

function stage_of(line,    a) {
    if (!match(line, /\[shader[[:space:]]*\([[:space:]]*"[A-Za-z0-9_]+"[[:space:]]*\)/)) return ""
    a = substr(line, RSTART, RLENGTH)
    if (match(a, /"[A-Za-z0-9_]+"/)) return substr(a, RSTART + 1, RLENGTH - 2)
    return ""
}

{
    st = stage_of($0)
    if (st != "") pending = st
    if (pending != "") {
        name = find_name($0)
        if (name != "") {
            print pending, name
            pending = ""
        }
    }
}
'

map_stage() {
    case $1 in
        pixel) echo fragment ;;
        *) echo "$1" ;;
    esac
}

# ---- compile loop -----------------------------------------------------------
files_total=0
entries_total=0
entries_pass=0
entries_fail=0
lib_total=0
lib_pass=0
lib_fail=0
seq=0
failures="$tmpdir/failures"
: > "$failures"

indent() {
    sed -e 's/^/    /'
}

while IFS= read -r file; do
    files_total=$((files_total + 1))
    # Build -I arguments in the main shell: `set --` inside a function would
    # only set that function's positional parameters.
    set --
    while IFS= read -r d; do
        set -- "$@" -I "$d"
    done < "$inc_file"
    entries="$tmpdir/entries.$$"
    awk "$entry_awk" "$file" > "$entries" 2>/dev/null || true
    found=0
    while IFS=' ' read -r stage entry; do
        [ -n "${stage:-}" ] || continue
        [ -n "${entry:-}" ] || continue
        found=$((found + 1))
    done < "$entries"

    if [ "$found" -gt 0 ]; then
        while IFS=' ' read -r stage entry; do
            [ -n "${stage:-}" ] || continue
            [ -n "${entry:-}" ] || continue
            stage=$(map_stage "$stage")
            seq=$((seq + 1))
            out="$tmpdir/spv_${seq}.spv"
            entries_total=$((entries_total + 1))
            if [ "$verbose" = 1 ]; then
                echo "+ $slangc -target $target -profile $profile $* -entry $entry -stage $stage -o $out $file"
            fi
            err=$("$slangc" -target "$target" -profile "$profile" "$@" -entry "$entry" -stage "$stage" -o "$out" "$file" 2>&1)
            rc=$?
            if [ $rc -ne 0 ]; then
                entries_fail=$((entries_fail + 1))
                printf 'FAIL  %s: %s (%s)\n' "$file" "$entry" "$stage"
                printf '%s\n' "$err" | indent
                printf '%s: %s (%s)\n' "$file" "$entry" "$stage" >> "$failures"
            elif [ ! -s "$out" ]; then
                entries_fail=$((entries_fail + 1))
                printf 'FAIL  %s: %s (%s) -- slangc succeeded but produced no output\n' "$file" "$entry" "$stage"
                printf '%s\n' "$err" | indent
                printf '%s: %s (%s) [no output]\n' "$file" "$entry" "$stage" >> "$failures"
            elif [ "$run_spirv_val" = 1 ] && command -v spirv-val >/dev/null 2>&1; then
                if valerr=$(spirv-val "$out" 2>&1); then
                    entries_pass=$((entries_pass + 1))
                    printf 'PASS  %s: %s (%s) [spirv-val ok]\n' "$file" "$entry" "$stage"
                else
                    entries_fail=$((entries_fail + 1))
                    printf 'FAIL  %s: %s (%s) -- spirv-val rejected output\n' "$file" "$entry" "$stage"
                    printf '%s\n' "$valerr" | indent
                    printf '%s: %s (%s) [spirv-val]\n' "$file" "$entry" "$stage" >> "$failures"
                fi
            else
                entries_pass=$((entries_pass + 1))
                printf 'PASS  %s: %s (%s)\n' "$file" "$entry" "$stage"
            fi
        done < "$entries"
    else
        lib_total=$((lib_total + 1))
        if [ "$verbose" = 1 ]; then
            echo "+ $slangc -target none $* $file   # no entry points: front-end check"
        fi
        err=$("$slangc" -target none "$@" "$file" 2>&1)
        rc=$?
        if [ $rc -ne 0 ]; then
            lib_fail=$((lib_fail + 1))
            printf 'FAIL  %s (no entry points; front-end check)\n' "$file"
            printf '%s\n' "$err" | indent
            printf '%s (library)\n' "$file" >> "$failures"
        else
            lib_pass=$((lib_pass + 1))
            printf 'PASS  %s (no entry points; front-end check)\n' "$file"
        fi
    fi
    rm -f "$entries"
done < "$file_list"

# ---- summary ----------------------------------------------------------------
printf '\n=== check-slang summary ===\n'
printf 'slangc:        %s (version %s)\n' "$slangc" "$slangc_version"
printf 'target:        %s  profile: %s\n' "$target" "$profile"
printf 'files:         %d\n' "$files_total"
printf 'entries:       %d total, %d passed, %d failed\n' "$entries_total" "$entries_pass" "$entries_fail"
printf 'libraries:     %d total, %d passed, %d failed\n' "$lib_total" "$lib_pass" "$lib_fail"

if [ "$keep" = 1 ]; then
    printf 'spv output:    %s\n' "$tmpdir"
fi

if [ "$entries_fail" -gt 0 ] || [ "$lib_fail" -gt 0 ]; then
    printf 'failures:\n'
    sed -e 's/^/  - /' "$failures"
    exit 1
fi

exit 0
