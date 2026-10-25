#!/usr/bin/env python3
"""Static cross-checks for the engine7 editor plugins.

Checks that the keyword tables in compiler/src/syntax.zig are represented in
both editor highlighters, that the VS Code metadata is valid, and that the
shared fixture is present.  Dynamic highlighting assertions live in each
plugin's test/run.sh.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NVIM_SYNTAX = ROOT / "editors/neovim/syntax/engine7.vim"
TM_GRAMMAR = ROOT / "editors/vscode/syntaxes/engine7.tmLanguage.json"
VSCODE_PACKAGE = ROOT / "editors/vscode/package.json"
LANG_CONF = ROOT / "editors/vscode/language-configuration.json"
SAMPLE = ROOT / "editors/samples/kitchen_sink.tri"
SYNTAX_ZIG = ROOT / "compiler/src/syntax.zig"

# Keywords that the highlighters must treat as words.  `map` is contextual
# (only a type before `[`) and is checked separately.
CONTEXTUAL = {"map"}

# Built-in scalar types from compiler/src/semantic/types.zig.  They are not
# reserved words, but both highlighters treat them as types.
PRIMITIVES = [
    "i8",
    "i16",
    "i32",
    "i64",
    "i128",
    "isize",
    "u8",
    "u16",
    "u32",
    "u64",
    "u128",
    "usize",
    "f16",
    "f32",
    "f64",
    "f128",
    "bool",
    "str",
]

# Groups/sections the Neovim syntax file is expected to link.
NEOVIM_LINKS = [
    "e7Comment",
    "e7String",
    "e7Escape",
    "e7Number",
    "e7Boolean",
    "e7Constant",
    "e7Conditional",
    "e7Repeat",
    "e7Statement",
    "e7Include",
    "e7Structure",
    "e7Keyword",
    "e7Storage",
    "e7Type",
    "e7Function",
    "e7Field",
    "e7Attribute",
    "e7Operator",
    "e7Delimiter",
]

REQUIRED_TM_SCOPES = [
    "comment.line.number-sign.engine7",
    "string.quoted.double.engine7",
    "string.quoted.single.engine7",
    "constant.character.escape.engine7",
    "constant.numeric.integer.engine7",
    "constant.numeric.float.engine7",
    "constant.language.boolean.engine7",
    "constant.language.nil.engine7",
    "keyword.control.conditional.engine7",
    "keyword.control.loop.engine7",
    "keyword.control.flow.engine7",
    "keyword.control.import.engine7",
    "storage.type.declaration.engine7",
    "keyword.other.declaration.engine7",
    "keyword.other.modifier.engine7",
    "keyword.other.query.engine7",
    "keyword.operator.word.engine7",
    "variable.language.engine7",
    "storage.modifier.visibility.engine7",
    "entity.name.type.engine7",
    "entity.name.function.engine7",
    "variable.other.property.engine7",
    "variable.other.member.engine7",
    "entity.other.attribute-name.engine7",
    "keyword.operator.engine7",
    "punctuation.ellipsis.engine7",
]

failures: list[str] = []
checks = 0


def check(condition: bool, message: str) -> None:
    global checks
    checks += 1
    if not condition:
        failures.append(message)


def read(path: Path) -> str:
    check(path.is_file(), f"missing required file: {path.relative_to(ROOT)}")
    return path.read_text(encoding="utf-8") if path.is_file() else ""


def compiler_keywords(text: str) -> list[str]:
    return re.findall(r'\.\{\s*"([A-Za-z_][A-Za-z0-9_]*)",\s*TokenKind\.', text)


def neovim_keyword_tokens(text: str) -> set[str]:
    """Tokens declared by `syn keyword` lines (including Vim continuations)."""
    tokens: set[str] = set()
    current = False
    for raw in text.splitlines():
        line = raw.strip()
        if re.match(r"^syn(?:tax)?\s+keyword\b", line):
            current = True
        elif current and raw.startswith((" ", "\t")) and line and not line.startswith('"'):
            # Vim finishes a command at the first newline; a leading backslash
            # is the only continuation form.  Anything else ends the keyword.
            if not line.startswith("\\"):
                current = False
                continue
            line = line[1:].strip()
        elif not line.startswith('"'):
            current = False
        if current:
            # Drop the command and group name, then collect words.  Keyword
            # groups may use `contains=`/`contained` options; skip them.
            body = re.sub(r"^syn(?:tax)?\s+keyword\s+\S+\s*", "", line)
            body = re.sub(r"\\\s*$", "", body)
            for word in body.split():
                if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", word):
                    tokens.add(word)
    return tokens


def word_present(needle: str, haystack: str) -> bool:
    return (
        re.search(
            r"(?<![A-Za-z0-9_])" + re.escape(needle) + r"(?![A-Za-z0-9_])",
            haystack,
        )
        is not None
    )


def main() -> int:
    syntax_zig = read(SYNTAX_ZIG)
    nvim = read(NVIM_SYNTAX)
    tm_text = read(TM_GRAMMAR)
    package_text = read(VSCODE_PACKAGE)
    conf_text = read(LANG_CONF)
    read(SAMPLE)

    keywords = compiler_keywords(syntax_zig)
    check(len(keywords) >= 40, f"could not extract keyword table from syntax.zig ({len(keywords)})")
    check("trait" in keywords, "trait missing from compiler keyword table")

    # --- Neovim ---------------------------------------------------------
    declared = neovim_keyword_tokens(nvim)
    for kw in keywords:
        if kw in CONTEXTUAL:
            continue
        check(
            kw in declared or word_present(kw, nvim),
            f"neovim syntax does not highlight keyword {kw!r}",
        )
    for group in NEOVIM_LINKS:
        if group == "e7Field":
            # Fields may intentionally link a different group; require a link.
            check(
                re.search(r"hi(?:ghlight)?\s+(?:def\s+)?link\s+" + group + r"\b", nvim)
                is not None,
                f"neovim syntax does not link {group}",
            )
            continue
        check(
            f"{group}" in nvim,
            f"neovim syntax does not define {group}",
        )
    check(
        re.search(r"hi(?:ghlight)?\s+(?:def\s+)?link\s+e7Comment\s+Comment\b", nvim)
        is not None,
        "neovim: e7Comment must link to Comment",
    )
    check(
        re.search(r"hi(?:ghlight)?\s+(?:def\s+)?link\s+e7Function\s+Function\b", nvim)
        is not None,
        "neovim: e7Function must link to Function",
    )
    check(
        re.search(r"hi(?:ghlight)?\s+(?:def\s+)?link\s+e7Attribute\s+PreProc\b", nvim)
        is not None,
        "neovim: e7Attribute must link to PreProc",
    )
    map_rules = [
        line
        for line in nvim.splitlines()
        if re.search(r"^\s*syn(?:tax)?\s+match\b", line) and "map" in line
    ]
    check(
        any("\\[" in line or "[" in line for line in map_rules),
        "neovim: missing contextual map[...] rule",
    )
    check("b:current_syntax" in nvim, "neovim syntax file lacks b:current_syntax guard")
    ftdetect = read(ROOT / "editors/neovim/ftdetect/engine7.vim")
    check("tri" in ftdetect, "neovim ftdetect does not register the .tri extension")
    check(
        not (ROOT / "editors/neovim/queries").exists(),
        "neovim plugin must not ship tree-sitter queries (no parser exists)",
    )
    for primitive in PRIMITIVES:
        check(
            word_present(primitive, nvim),
            f"neovim syntax does not mention primitive type {primitive!r}",
        )

    # --- VS Code metadata ----------------------------------------------
    try:
        package = json.loads(package_text)
    except json.JSONDecodeError as exc:  # pragma: no cover - failure path
        failures.append(f"invalid package.json: {exc}")
        package = {}
    try:
        conf = json.loads(conf_text)
    except json.JSONDecodeError as exc:  # pragma: no cover - failure path
        failures.append(f"invalid language-configuration.json: {exc}")
        conf = {}
    try:
        grammar = json.loads(tm_text)
    except json.JSONDecodeError as exc:  # pragma: no cover - failure path
        failures.append(f"invalid tmLanguage JSON: {exc}")
        grammar = {}

    check(package.get("name") == "engine7", "package.json name must be engine7")
    languages = package.get("contributes", {}).get("languages", [])
    check(
        any(lang.get("id") == "engine7" for lang in languages),
        "package.json does not contribute language id engine7",
    )
    check(
        any(
            ".tri" in lang.get("extensions", [])
            and ".e7" in lang.get("extensions", [])
            and ".engine7" in lang.get("extensions", [])
            for lang in languages
            if lang.get("id") == "engine7"
        ),
        "package.json language must list .tri (canonical), .e7, and .engine7",
    )
    grammars = package.get("contributes", {}).get("grammars", [])
    check(
        any(g.get("scopeName") == "source.engine7" for g in grammars),
        "package.json does not contribute scopeName source.engine7",
    )
    check(
        grammar.get("scopeName") == "source.engine7",
        "tmLanguage scopeName must be source.engine7",
    )
    tm_scopes_text = json.dumps(grammar)
    for scope in REQUIRED_TM_SCOPES:
        check(scope in tm_scopes_text, f"tmLanguage missing scope {scope}")
    check("primitive-type-name" in tm_scopes_text, "tmLanguage missing primitive-type-name rule")
    check("map-type" in tm_scopes_text, "tmLanguage missing map-type rule")
    for primitive in PRIMITIVES:
        check(
            word_present(primitive, tm_scopes_text),
            f"tmLanguage does not mention primitive type {primitive!r}",
        )
    for kw in keywords:
        if kw in CONTEXTUAL:
            continue
        check(
            word_present(kw, tm_scopes_text),
            f"tmLanguage does not mention keyword {kw!r}",
        )
    check(
        "lineComment" in conf.get("comments", {})
        and conf["comments"]["lineComment"] == "#",
        "language-configuration.json must set lineComment to #",
    )
    check("brackets" in conf, "language-configuration.json missing brackets")
    check("indentationRules" in conf, "language-configuration.json missing indentationRules")

    # The fixture must exercise every keyword class.  Cheap sanity check that
    # all compiler keywords appear somewhere in the sample.
    sample = read(SAMPLE)
    for kw in keywords:
        if kw in CONTEXTUAL:
            continue
        check(word_present(kw, sample), f"shared fixture never uses keyword {kw!r}")

    if failures:
        print("static checks FAILED:", file=sys.stderr)
        for message in failures:
            print(f"  - {message}", file=sys.stderr)
        return 1
    print(f"static checks OK ({checks} checks, {len(keywords)} keywords)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
