#!/usr/bin/env python3
"""End-to-end LSP conformance test for the engine7 language server (`e7-lsp`).

The test drives the server over stdio exactly like an editor would:

  initialize -> initialized -> didOpen/didChange/didClose -> requests ->
  shutdown -> exit

It asserts diagnostics, document symbols, hover, completion, and definition
responses against the built binary.  Only the Python standard library is used.

Usage:
    python3 editors/lsp/test/client.py path/to/e7-lsp [--verbose]

Exit status is 0 only when every assertion passes.  On failure the pending
message queue and the server's stderr are printed to aid debugging.
"""

import json
import os
import select
import subprocess
import sys
import threading
import time

VALID_SOURCE = """\
Point <- struct
    x: f32
    y: f32

dot <- (a: i32, b: i32) -> i32:
    ret a * b

main <- () -> i32:
    ret dot(1, 2)
"""

SEMANTIC_ERROR_SOURCE = """\
f <- () -> i32:
    x := 1
    x = "no"
    0
"""

PARSE_ERROR_SOURCE = """\
f <- (
"""


class Checks:
    def __init__(self):
        self.count = 0
        self.failures = []

    def check(self, condition, message):
        self.count += 1
        if not condition:
            self.failures.append(message)
            print("FAIL: " + message)

    def eq(self, actual, expected, message):
        self.check(actual == expected, "%s (expected %r, got %r)" % (message, expected, actual))


class Client:
    def __init__(self, binary):
        self.proc = subprocess.Popen(
            [binary],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        self.buffer = b""
        self.queue = []
        self.next_id = 1
        self.stderr_lines = []
        self.stderr_thread = threading.Thread(target=self._drain_stderr, daemon=True)
        self.stderr_thread.start()

    def _drain_stderr(self):
        for line in self.proc.stderr:
            self.stderr_lines.append(line.decode("utf-8", "replace"))
            del self.stderr_lines[:-100]

    def _read_bytes(self, count, deadline):
        while len(self.buffer) < count:
            remaining = deadline - time.time()
            if remaining <= 0:
                raise TimeoutError("timed out waiting for %d byte(s)" % count)
            ready, _, _ = select.select([self.proc.stdout], [], [], remaining)
            if not ready:
                raise TimeoutError("timed out waiting for server output")
            chunk = os.read(self.proc.stdout.fileno(), 65536)
            if not chunk:
                raise EOFError("server closed stdout; stderr:\n" + "".join(self.stderr_lines))
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def _read_header(self, deadline):
        line = b""
        length = None
        while True:
            byte = self._read_bytes(1, deadline)
            if byte == b"\n":
                line = line.rstrip(b"\r")
                if not line:
                    if length is None:
                        raise ValueError("missing Content-Length header")
                    return length
                if line.lower().startswith(b"content-length:"):
                    length = int(line.split(b":", 1)[1].strip())
                line = b""
            else:
                line += byte

    def _read_message(self, timeout):
        deadline = time.time() + timeout
        length = self._read_header(deadline)
        body = self._read_bytes(length, deadline)
        return json.loads(body.decode("utf-8"))

    def send(self, message):
        body = json.dumps(message, separators=(",", ":")).encode("utf-8")
        self.proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body))
        self.proc.stdin.write(body)
        self.proc.stdin.flush()

    def notify(self, method, params=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self.send(message)

    def wait_for(self, predicate, timeout=5.0, description="message"):
        withheld = []
        for index, message in enumerate(self.queue):
            if predicate(message):
                del self.queue[index]
                self.queue = withheld + self.queue
                return message
            withheld.append(message)
        self.queue = withheld
        deadline = time.time() + timeout
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                raise TimeoutError("timed out waiting for " + description)
            message = self._read_message(remaining)
            if predicate(message):
                return message
            self.queue.append(message)

    def request(self, method, params, timeout=5.0):
        request_id = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        response = self.wait_for(
            lambda message: message.get("id") == request_id,
            timeout,
            "%s response" % method,
        )
        if "error" in response:
            raise AssertionError("%s returned error: %s" % (method, response["error"]))
        return response.get("result")

    def wait_diagnostics(self, uri, timeout=5.0, predicate=None):
        def matches(message):
            if message.get("method") != "textDocument/publishDiagnostics":
                return False
            params = message.get("params", {})
            if params.get("uri") != uri:
                return False
            diagnostics = params.get("diagnostics", [])
            return predicate is None or predicate(diagnostics)

        return self.wait_for(matches, timeout, "diagnostics for " + uri)["params"]["diagnostics"]

    def stop(self):
        try:
            if self.proc.poll() is None:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
        finally:
            self.stderr_thread.join(timeout=1)


def find_position(source, needle):
    offset = source.index(needle)
    line = source.count("\n", 0, offset)
    character = offset - (source.rfind("\n", 0, offset) + 1)
    return {"line": line, "character": character}


def parse_workspace(argv):
    if "--workspace" in argv:
        index = argv.index("--workspace")
        if index + 1 >= len(argv):
            raise SystemExit("--workspace requires a directory")
        return os.path.abspath(argv[index + 1])
    return None


def main(argv):
    if len(argv) < 2:
        print("usage: client.py path/to/e7-lsp [--workspace DIR] [--verbose]", file=sys.stderr)
        return 2
    binary = argv[1]
    workspace = parse_workspace(argv)
    verbose = "--verbose" in argv
    if not os.access(binary, os.X_OK):
        print("error: %s is not executable" % binary, file=sys.stderr)
        return 2

    checks = Checks()
    client = Client(binary)
    try:
        run_scenario(client, checks, verbose)
    except Exception as error:  # noqa: BLE001 - report any protocol failure
        checks.check(False, "protocol exception: %s" % error)
        print("pending messages:", json.dumps(client.queue, indent=2)[:4000])
        print("server stderr:", "".join(client.stderr_lines)[:4000])
    finally:
        client.stop()

    if workspace:
        project_client = Client(binary)
        try:
            run_project_scenario(project_client, checks, workspace, verbose)
        except Exception as error:  # noqa: BLE001
            checks.check(False, "project scenario exception: %s" % error)
            print("pending messages:", json.dumps(project_client.queue, indent=2)[:4000])
            print("server stderr:", "".join(project_client.stderr_lines)[:4000])
        finally:
            project_client.stop()

    if checks.failures:
        print("%d assertions, %d failures" % (checks.count, len(checks.failures)))
        return 1
    print("%d assertions, 0 failures" % checks.count)
    return 0


def run_scenario(client, checks, verbose):
    root_uri = "file:///tmp/e7-lsp-test"
    valid_uri = root_uri + "/valid.tri"
    semantic_uri = root_uri + "/semantic.tri"
    parse_uri = root_uri + "/parse.tri"

    initialized = client.request(
        "initialize",
        {
            "processId": os.getpid(),
            "rootUri": root_uri,
            "capabilities": {
                "general": {"positionEncodings": ["utf-16"]},
                "textDocument": {
                    "documentSymbol": {"hierarchicalDocumentSymbolSupport": True},
                },
            },
            "clientInfo": {"name": "e7-lsp-test", "version": "1.0"},
        },
    )
    capabilities = initialized.get("capabilities", {}) if initialized else {}
    checks.eq(capabilities.get("documentSymbolProvider"), True, "documentSymbolProvider advertised")
    checks.eq(capabilities.get("hoverProvider"), True, "hoverProvider advertised")
    checks.eq(capabilities.get("definitionProvider"), True, "definitionProvider advertised")
    checks.eq(capabilities.get("documentFormattingProvider"), True, "documentFormattingProvider advertised")
    checks.check(capabilities.get("completionProvider") is not None, "completionProvider advertised")
    sync = capabilities.get("textDocumentSync")
    checks.check(isinstance(sync, dict) and sync.get("openClose") is True, "textDocumentSync openClose")
    checks.eq(sync.get("change") if isinstance(sync, dict) else None, 1, "full document sync")

    client.notify("initialized", {})

    # --- Valid document: no diagnostics, symbols, hover, completion, definition.
    client.notify(
        "textDocument/didOpen",
        {
            "textDocument": {
                "uri": valid_uri,
                "languageId": "engine7",
                "version": 1,
                "text": VALID_SOURCE,
            }
        },
    )
    diagnostics = client.wait_diagnostics(valid_uri, predicate=lambda items: True)
    checks.eq(diagnostics, [], "clean document reports no diagnostics")

    symbols = client.request("textDocument/documentSymbol", {"textDocument": {"uri": valid_uri}})
    checks.check(isinstance(symbols, list) and len(symbols) > 0, "documentSymbol returns symbols")
    names = {symbol.get("name"): symbol for symbol in symbols or [] if isinstance(symbol, dict)}
    checks.check("Point" in names, "documentSymbol includes struct Point")
    checks.check("dot" in names, "documentSymbol includes function dot")
    checks.eq(names.get("dot", {}).get("kind"), 12, "function symbol kind")
    point_children = names.get("Point", {}).get("children") or []
    checks.check(
        {child.get("name") for child in point_children} >= {"x", "y"},
        "documentSymbol nests struct fields",
    )

    call_position = find_position(VALID_SOURCE, "dot(1")
    hover = client.request(
        "textDocument/hover",
        {"textDocument": {"uri": valid_uri}, "position": call_position},
    )
    hover_text = ""
    if isinstance(hover, dict):
        contents = hover.get("contents")
        hover_text = contents.get("value", "") if isinstance(contents, dict) else str(contents)
    checks.check("dot" in hover_text, "hover shows the declaration")
    checks.check("```e7" in hover_text, "hover is fenced e7 markdown")

    definition = client.request(
        "textDocument/definition",
        {"textDocument": {"uri": valid_uri}, "position": call_position},
    )
    definition_start = (definition or {}).get("range", {}).get("start", {}) if isinstance(definition, dict) else {}
    checks.eq(definition_start.get("line"), 4, "definition points at the dot declaration line")
    checks.eq(definition_start.get("character"), 0, "definition points at the declaration column")

    completion = client.request(
        "textDocument/completion",
        {"textDocument": {"uri": valid_uri}, "position": call_position},
    )
    items = completion.get("items", []) if isinstance(completion, dict) else []
    labels = {item.get("label") for item in items if isinstance(item, dict)}
    checks.check("struct" in labels, "completion includes keywords")
    checks.check("i32" in labels, "completion includes builtin types")
    checks.check("dot" in labels, "completion includes document symbols")
    checks.check("Point" in labels, "completion includes declared types")

    # --- Formatting: normalize whitespace and rewrite an unnecessary `:=`.
    format_uri = root_uri + "/format.tri"
    format_source = "f <- () -> i32:   \n    x := 1\n    ret x\n"
    client.notify(
        "textDocument/didOpen",
        {
            "textDocument": {
                "uri": format_uri,
                "languageId": "engine7",
                "version": 1,
                "text": format_source,
            }
        },
    )
    client.wait_diagnostics(format_uri, predicate=lambda items: True)
    edits = client.request(
        "textDocument/formatting",
        {
            "textDocument": {"uri": format_uri},
            "options": {"tabSize": 4, "insertSpaces": True},
        },
    )
    checks.check(isinstance(edits, list) and len(edits) == 1, "formatting returns one edit")
    formatted = format_source
    if isinstance(edits, list) and edits:
        edit = edits[0]
        start = edit.get("range", {}).get("start", {})
        end = edit.get("range", {}).get("end", {})
        checks.eq(start, {"line": 0, "character": 0}, "format edit starts at the document")
        if end.get("line") is not None:
            formatted = edit.get("newText", formatted)
    checks.check("x <- 1" in formatted, "formatting makes an unused mutable binding immutable")
    checks.check("   \n" not in formatted, "formatting strips trailing whitespace")
    checks.check(formatted.endswith("\n") and not formatted.endswith("\n\n"), "formatting keeps one final newline")
    client.notify("textDocument/didClose", {"textDocument": {"uri": format_uri}})
    client.wait_diagnostics(format_uri, predicate=lambda items: True)

    # --- Semantic diagnostics + full sync: bad source then fixed source.
    client.notify(
        "textDocument/didOpen",
        {
            "textDocument": {
                "uri": semantic_uri,
                "languageId": "engine7",
                "version": 1,
                "text": SEMANTIC_ERROR_SOURCE,
            }
        },
    )
    diagnostics = client.wait_diagnostics(semantic_uri, predicate=bool)
    checks.check(len(diagnostics) > 0, "semantic error produces diagnostics")
    if diagnostics:
        checks.eq(diagnostics[0].get("severity"), 1, "diagnostic severity is error")
        checks.eq(diagnostics[0].get("source"), "e7", "diagnostic source is e7")
        checks.check(
            "type mismatch" in diagnostics[0].get("message", ""),
            "semantic diagnostic message mentions type mismatch",
        )
        checks.eq(diagnostics[0].get("range", {}).get("start", {}).get("line"), 2, "diagnostic line")

    client.notify(
        "textDocument/didChange",
        {
            "textDocument": {"uri": semantic_uri, "version": 2},
            "contentChanges": [{"text": VALID_SOURCE}],
        },
    )
    diagnostics = client.wait_diagnostics(semantic_uri, predicate=lambda items: True)
    checks.eq(diagnostics, [], "fixing the document clears diagnostics")

    # --- Parse errors.
    client.notify(
        "textDocument/didOpen",
        {
            "textDocument": {
                "uri": parse_uri,
                "languageId": "engine7",
                "version": 1,
                "text": PARSE_ERROR_SOURCE,
            }
        },
    )
    diagnostics = client.wait_diagnostics(parse_uri, predicate=bool)
    checks.check(len(diagnostics) > 0, "parse error produces diagnostics")
    if diagnostics:
        # The parser is fail-fast: this file ends after `f <- (`, so the error
        # can point at the opening line or at EOF on the next line.
        line = diagnostics[0].get("range", {}).get("start", {}).get("line")
        checks.check(line in (0, 1), "parse error line is on the source (got %r)" % (line,))

    # --- Unknown requests answer null; closing publishes empty diagnostics.
    unknown = client.request("e7/unknownRequest", {})
    checks.eq(unknown, None, "unknown request returns null result")

    client.notify("textDocument/didClose", {"textDocument": {"uri": semantic_uri}})
    diagnostics = client.wait_diagnostics(semantic_uri, predicate=lambda items: True)
    checks.eq(diagnostics, [], "didClose publishes empty diagnostics")

    # --- Shutdown handshake.
    shutdown = client.request("shutdown", None)
    checks.eq(shutdown, None, "shutdown returns null")
    client.notify("exit")
    try:
        exit_code = client.proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        exit_code = None
    checks.eq(exit_code, 0, "server exits 0 after shutdown/exit")

    if verbose:
        print("received messages:", len(client.queue), "queued")
        print("server stderr:", "".join(client.stderr_lines))


PROJECT_DIAGNOSTIC_CASES = [
    "engine/gameplay.e7",
    "engine/editor/model.e7",
    "engine/main.e7",
]

PROJECT_ERROR_SOURCE = """\
f <- () -> i32:
    x := 1
    x = "no"
    0
"""


def run_project_scenario(client, checks, workspace, verbose):
    """Multi-file project mode: external `mod` files must be loaded so that
    diagnostics do not contain bogus "unknown type/name" errors, and semantic
    errors update again on save (project analysis runs on open/save, syntax
    only on change)."""
    root_uri = "file://" + workspace
    initialized = client.request(
        "initialize",
        {
            "processId": os.getpid(),
            "rootUri": root_uri,
            "capabilities": {"general": {"positionEncodings": ["utf-16"]}},
            "workspaceFolders": [{"uri": root_uri, "name": "engine7"}],
        },
    )
    checks.check(isinstance(initialized, dict), "project initialize returns a result")
    client.notify("initialized", {})

    for relative in PROJECT_DIAGNOSTIC_CASES:
        path = os.path.join(workspace, relative)
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
        uri = "file://" + path
        client.notify(
            "textDocument/didOpen",
            {
                "textDocument": {
                    "uri": uri,
                    "languageId": "engine7",
                    "version": 1,
                    "text": source,
                }
            },
        )
        diagnostics = client.wait_diagnostics(uri, timeout=30, predicate=lambda items: True)
        checks.check(
            diagnostics == [],
            "%s has no false diagnostics in project mode (got %d: %s)"
            % (
                relative,
                len(diagnostics),
                "; ".join(item.get("message", "") for item in diagnostics[:3]),
            ),
        )
        symbols = client.request(
            "textDocument/documentSymbol", {"textDocument": {"uri": uri}}, timeout=10
        )
        checks.check(
            isinstance(symbols, list) and len(symbols) > 0,
            "%s indexes project document symbols" % relative,
        )
        client.notify("textDocument/didClose", {"textDocument": {"uri": uri}})
        client.wait_diagnostics(uri, timeout=10, predicate=lambda items: True)

    # Project files re-analyze semantically on save: a type error typed into a
    # project buffer is reported after didSave.
    probe_relative = PROJECT_DIAGNOSTIC_CASES[0]
    probe_path = os.path.join(workspace, probe_relative)
    if os.path.isfile(probe_path):
        uri = "file://" + probe_path
        client.notify(
            "textDocument/didOpen",
            {
                "textDocument": {
                    "uri": uri,
                    "languageId": "engine7",
                    "version": 1,
                    "text": PROJECT_ERROR_SOURCE,
                }
            },
        )
        client.wait_diagnostics(uri, timeout=30, predicate=lambda items: True)
        client.notify("textDocument/didSave", {"textDocument": {"uri": uri}})
        diagnostics = client.wait_diagnostics(
            uri, timeout=30, predicate=lambda items: any("mismatch" in item.get("message", "") for item in items)
        )
        checks.check(
            any("mismatch" in item.get("message", "") for item in diagnostics),
            "project buffer reports semantic errors after didSave",
        )
        client.notify("textDocument/didClose", {"textDocument": {"uri": uri}})
        client.wait_diagnostics(uri, timeout=10, predicate=lambda items: True)

    shutdown = client.request("shutdown", None)
    checks.eq(shutdown, None, "project shutdown returns null")
    client.notify("exit")
    try:
        exit_code = client.proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        exit_code = None
    checks.eq(exit_code, 0, "project server exits 0")

    if verbose:
        print("project server stderr:", "".join(client.stderr_lines))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
