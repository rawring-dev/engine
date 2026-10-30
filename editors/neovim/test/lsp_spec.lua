-- Non-interactive LSP integration tests for the engine7 Neovim plugin.
--
-- Run through editors/neovim/test/run_lsp.sh, which starts nvim with
--   nvim --headless --clean -u NONE -i NONE -l this_file.lua
-- and passes the plugin root, the built e7-lsp binary, and the shared
-- highlighting fixture through the environment.
--
-- The script asserts three groups of behavior:
--
--   1. registration - plugin/engine7.lua registers and enables the `engine7`
--      LSP config, and resolves the server command with the documented
--      priority: g:engine7_lsp_path > $E7_LSP_BIN > repo zig-out > $PATH;
--   2. diagnostics  - a file with a parse error and a file with a type error
--      receive Error diagnostics through textDocument/publishDiagnostics, and
--      a well-typed file receives none;
--   3. features     - documentSymbol, hover, completion, and same-file
--      go-to-definition against a copy of editors/samples/kitchen_sink.tri.
--
-- Every buffer lives in a throwaway workspace directory under $TMPDIR (with a
-- build.zig.zon marker, so client root_dir resolution is exercised).  The
-- directory is removed, clients are stopped, and nothing is written to the
-- repository.
--
-- Diagnostics are asynchronous: the assertions below always wait for the
-- client to initialize / for publishDiagnostics to arrive (vim.wait, 5s) and
-- treat a timeout as a test failure rather than assuming empty output means
-- "clean".

local plugin_dir = assert(vim.env.E7_NEOVIM_PLUGIN_DIR, "E7_NEOVIM_PLUGIN_DIR is not set")
local bin = assert(vim.env.E7_LSP_BIN, "E7_LSP_BIN is not set")
local fixture = assert(vim.env.E7_FIXTURE, "E7_FIXTURE is not set")
local repo_root = vim.fn.fnamemodify(plugin_dir .. "/../..", ":p")

local assertions = 0
local failures = {}
local notes = {}

local function check(label, condition, detail)
  assertions = assertions + 1
  if not condition then
    failures[#failures + 1] = string.format(
      "FAIL [%s]%s", label, detail and ("\n      " .. detail) or "")
  end
  return condition and true or false
end

local function check_eq(label, actual, expected)
  return check(label, vim.deep_equal(actual, expected),
    string.format("expected %s, got %s", vim.inspect(expected), vim.inspect(actual)))
end

local function note(message)
  notes[#notes + 1] = "note: " .. message
end

local function normalized(path)
  return vim.fn.fnamemodify(path, ":p")
end

-- ---------------------------------------------------------------------------
-- Plugin registration and command resolution.
-- ---------------------------------------------------------------------------

local function lsp_enabled(name)
  if type(vim.lsp.is_enabled) == "function" then
    return vim.lsp.is_enabled(name)
  end
  return vim.lsp._enabled_configs ~= nil and vim.lsp._enabled_configs[name] ~= nil
end

-- Sources the plugin with a clean guard, so the command-resolution phases can
-- each observe a fresh registration.
local function source_plugin(env_bin, g_path)
  if type(vim.lsp.enable) == "function" and lsp_enabled("engine7") then
    vim.lsp.enable("engine7", false)
  end
  vim.env.E7_LSP_BIN = env_bin
  vim.g.engine7_lsp_path = g_path
  vim.g.loaded_engine7_lsp = nil
  dofile(plugin_dir .. "/plugin/engine7.lua")
end

-- Returns the first executable in the argument list (used for harmless fake
-- server commands: config resolution must not launch them).
local function pick_executable(candidates)
  for _, candidate in ipairs(candidates) do
    if type(candidate) == "string" and candidate ~= "" and vim.fn.executable(candidate) == 1 then
      return candidate
    end
  end
  return nil
end

local function config_for(name)
  if type(vim.lsp.config) == "table" then
    return vim.lsp.config[name]
  end
  return nil
end

local function registration_checks()
  local has_config_api = type(vim.lsp.config) == "table" and type(vim.lsp.enable) == "function"
  if not check("Neovim 0.11+ LSP config API is available",
      has_config_api, "this spec drives vim.lsp.config() / vim.lsp.enable()") then
    -- Legacy fallback path: the plugin registers a FileType autocmd instead.
    source_plugin(bin, nil)
    return
  end

  local fake_a = pick_executable({ vim.v.progpath, "/bin/true" })
  local fake_b = pick_executable({ "/bin/false", "/usr/bin/false", vim.v.progpath })

  -- Phase 1: no user override -> the repository-local zig-out binary.
  source_plugin(nil, nil)
  local repo_bin = normalized(repo_root .. "zig-out/bin/e7-lsp")
  check("repository-local binary exists", vim.fn.executable(repo_bin) == 1,
    "expected " .. repo_bin .. "; run_lsp.sh builds it with 'zig build lsp'")
  local cfg = config_for("engine7")
  check("engine7 config is registered", type(cfg) == "table")
  if cfg then
    check_eq("config name", cfg.name, "engine7")
    check("config filetypes", vim.tbl_contains(cfg.filetypes or {}, "engine7"),
      vim.inspect(cfg.filetypes))
    for _, marker in ipairs({ "build.zig.zon", "build.zig", ".git" }) do
      check("config root marker " .. marker,
        vim.tbl_contains(cfg.root_markers or {}, marker), vim.inspect(cfg.root_markers))
    end
    check_eq("g: unset -> repo-local cmd", cfg.cmd[1], repo_bin)
  end
  check("engine7 config is enabled", lsp_enabled("engine7"))

  -- Phase 2: $E7_LSP_BIN wins over the repository-local binary.
  if fake_a and fake_a ~= repo_bin then
    source_plugin(fake_a, nil)
    cfg = config_for("engine7")
    check_eq("$E7_LSP_BIN cmd", cfg and cfg.cmd[1], normalized(fake_a))
    check("engine7 config re-enabled after override", lsp_enabled("engine7"))
  else
    note("no distinct executable available for the $E7_LSP_BIN priority check")
  end

  -- Phase 3: g:engine7_lsp_path wins over $E7_LSP_BIN.
  if fake_a and fake_b and fake_a ~= fake_b then
    source_plugin(fake_a, fake_b)
    cfg = config_for("engine7")
    check_eq("g:engine7_lsp_path cmd", cfg and cfg.cmd[1], normalized(fake_b))
  else
    note("no distinct executable available for the g:engine7_lsp_path priority check")
  end

  -- Back to the real binary for the integration phases.
  source_plugin(bin, nil)
  cfg = config_for("engine7")
  check("real binary configured", type(cfg) == "table" and cfg.cmd[1] == normalized(bin),
    vim.inspect(cfg and cfg.cmd))
  check("engine7 config enabled for integration", lsp_enabled("engine7"))

  -- Sourcing a second time is a no-op thanks to the loaded guard.
  local before = cfg and vim.deepcopy(cfg)
  local ok = pcall(dofile, plugin_dir .. "/plugin/engine7.lua")
  check("plugin can be sourced twice", ok and vim.g.loaded_engine7_lsp == true)
  check_eq("loaded guard keeps the config", before, config_for("engine7"))
end

-- ---------------------------------------------------------------------------
-- Workspace with test files.
-- ---------------------------------------------------------------------------

local tmp = nil
local function make_workspace()
  local base = (vim.uv and vim.uv.os_tmpdir and vim.uv.os_tmpdir()) or os.getenv("TMPDIR") or "/tmp"
  tmp = string.format("%s/e7-lsp-neovim-test-%d-%d", base, vim.fn.getpid(),
    math.floor(((vim.uv and vim.uv.hrtime and vim.uv.hrtime()) or os.time()) / 1000) % 1000000)
  vim.fn.mkdir(tmp, "p")

  -- The workspace root marker lets vim.lsp start the client with this
  -- directory as root_dir instead of single-file mode.
  vim.fn.writefile({ "{}" }, tmp .. "/build.zig.zon")

  -- Copy of the shared highlighting fixture: declarations for the feature
  -- requests (documentSymbol / hover / definition).
  vim.fn.writefile(vim.fn.readfile(fixture), tmp .. "/main.tri")

  -- Parse error.  This exact shape is covered by the compiler parser tests,
  -- which expect a diagnostic on line 2 (the "if" has no condition/body).
  vim.fn.writefile({
    "f <- () -> i32:",
    "    if",
  }, tmp .. "/parse_error.tri")

  -- Semantic (type) error.  This exact shape is covered by the compiler
  -- semantic tests, which expect a "type mismatch" diagnostic for x = "no".
  vim.fn.writefile({
    "f <- () -> i32:",
    "    x := 1",
    '    x = "no"',
    "    0",
  }, tmp .. "/type_error.tri")

  -- Well-typed program from the compiler semantic tests: must stay silent.
  vim.fn.writefile({
    "S <- struct",
    "    a: i32",
    "    b: u32",
    "add <- (x: i32, y: i32) -> i32 = x + y",
    "make <- () -> S = S { a: 1, b: 2 }",
  }, tmp .. "/clean.tri")

  -- Small program for completion: `add` is declared above the cursor.
  vim.fn.writefile({
    "pub add <- (a: i32, b: i32) -> i32:",
    "    ret a + b",
    "",
    "pub caller <- () -> i32:",
    "    value := add(1, 2)",
    "    ret value",
  }, tmp .. "/completion.tri")
end

local function open_buffer(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  -- '--clean' leaves filetype detection off; set the filetype explicitly so
  -- the FileType autocmd registered by plugin/engine7.lua starts the client.
  vim.bo[bufnr].filetype = "engine7"
  return bufnr
end

-- ---------------------------------------------------------------------------
-- Client helpers.
-- ---------------------------------------------------------------------------

local function get_client(bufnr)
  return vim.lsp.get_clients({ bufnr = bufnr, name = "engine7" })[1]
end

local function client_status()
  local clients = vim.lsp.get_clients({ _uninitialized = true })
  if #clients == 0 then
    return "no engine7 LSP client is running"
  end
  local parts = {}
  for _, client in ipairs(clients) do
    parts[#parts + 1] = string.format("%s(id=%d, initialized=%s)",
      client.name, client.id, tostring(client.initialized))
  end
  return table.concat(parts, "; ")
end

local function wait_for_client(bufnr, label)
  local ok = vim.wait(5000, function()
    local client = get_client(bufnr)
    return client ~= nil and client.initialized == true
  end, 25)
  if ok then
    check(label .. ": client attaches", true)
    return get_client(bufnr)
  end
  check(label .. ": client attaches", false, string.format(
    "no initialized engine7 client after 5s (%s)\n"
      .. "      server binary: %s\n"
      .. "      hint: the server must answer initialize and didOpen; run '%s --version' "
      .. "and check editors/lsp",
    client_status(), bin, bin))
  return nil
end

-- Requests a synchronous LSP response; returns the result, or nil after
-- recording a failure.  `request_sync` returns nil on timeout and
-- { err = ..., result = ... } otherwise (Neovim 0.11+).
local function request(client, method, params, bufnr)
  local response, reason = client:request_sync(method, params, 5000, bufnr)
  if not response then
    check(method .. " responds", false,
      "timed out after 5s" .. (reason and (": " .. tostring(reason)) or ""))
    return nil
  end
  if response.err then
    check(method .. " responds", false, "JSON-RPC error: " .. vim.inspect(response.err))
    return nil
  end
  check(method .. " responds", true)
  return response.result
end

-- ---------------------------------------------------------------------------
-- Diagnostics assertions.
-- ---------------------------------------------------------------------------

local severity_name = {
  [1] = "ERROR",
  [2] = "WARN",
  [3] = "INFO",
  [4] = "HINT",
}

local function describe(diagnostics)
  if #diagnostics == 0 then
    return "<no diagnostics>"
  end
  local parts = {}
  for _, diagnostic in ipairs(diagnostics) do
    parts[#parts + 1] = string.format("%s %d:%d %q",
      (severity_name[diagnostic.severity] or tostring(diagnostic.severity)),
      diagnostic.lnum + 1, diagnostic.col + 1, diagnostic.message)
  end
  return table.concat(parts, " | ")
end

local function wait_for_diagnostics(bufnr)
  local ok = vim.wait(5000, function()
    return #vim.diagnostic.get(bufnr) > 0
  end, 25)
  return ok, vim.diagnostic.get(bufnr)
end

local function expect_error_diagnostic(label, bufnr, message_needle)
  local arrived, diagnostics = wait_for_diagnostics(bufnr)
  check(label .. ": publishes diagnostics", arrived,
    "no textDocument/publishDiagnostics within 5s for " .. vim.api.nvim_buf_get_name(bufnr)
      .. " (" .. client_status() .. ")")
  if not arrived then
    return
  end
  local first = diagnostics[1]
  check_eq(label .. ": severity is ERROR", first.severity, vim.diagnostic.severity.ERROR)
  check(label .. ": message is non-empty",
    type(first.message) == "string" and #first.message > 0, describe(diagnostics))
  check_eq(label .. ": source is e7", first.source, "e7")
  local lines = vim.api.nvim_buf_line_count(bufnr)
  check(label .. ": range is inside the buffer",
    first.lnum >= 0 and first.lnum < lines, describe(diagnostics))
  if message_needle then
    check(label .. ": message mentions " .. message_needle,
      type(first.message) == "string"
        and first.message:lower():find(message_needle:lower(), 1, true) ~= nil,
      describe(diagnostics))
  end
  note(label .. " diagnostic: " .. describe(diagnostics))
end

-- ---------------------------------------------------------------------------
-- Language feature assertions.
-- ---------------------------------------------------------------------------

local function buffer_position(bufnr, needle, token, occurrence)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for lnum, text in ipairs(lines) do
    if text:find(needle, 1, true) then
      local init, seen = 1, 0
      while true do
        local first, last = text:find(token, init, true)
        if not first then
          break
        end
        seen = seen + 1
        if seen == (occurrence or 1) then
          -- The fixture text is ASCII, so byte == UTF-16 code unit.
          return { line = lnum - 1, character = first - 1 }, lnum, text
        end
        init = last + 1
      end
      error(string.format("token %q not found on line %d: %q", token, lnum, text))
    end
  end
  error(string.format("buffer line not found: %q", needle))
end

local function markup_text(contents)
  if type(contents) == "string" then
    return contents
  end
  if type(contents) == "table" then
    if type(contents.value) == "string" then
      return contents.value
    end
    if type(contents.text) == "string" then
      return contents.text
    end
  end
  return nil
end

local function sorted_names(names)
  local list = {}
  for name in pairs(names) do
    list[#list + 1] = name
  end
  table.sort(list)
  return table.concat(list, ", ")
end

local function feature_checks(client)
  local uri = vim.uri_from_bufnr(0)
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local function symbol_line(needle)
    for lnum, text in ipairs(lines) do
      if text:find(needle, 1, true) then
        return lnum
      end
    end
    error("fixture line not found: " .. needle)
  end

  -- documentSymbol: top-level declarations are visible (possibly nested).
  local symbols = request(client, "textDocument/documentSymbol",
    { textDocument = { uri = uri } }, bufnr)
  local names, symbol_count, shape_ok = {}, 0, true
  local function walk(list)
    for _, symbol in ipairs(list or {}) do
      if type(symbol) ~= "table" then
        shape_ok = false
      else
        symbol_count = symbol_count + 1
        if type(symbol.name) == "string" then
          names[symbol.name] = true
        else
          shape_ok = false
        end
        if type(symbol.kind) ~= "number" then
          shape_ok = false
        end
        if type(symbol.range) ~= "table" or type(symbol.selectionRange) ~= "table" then
          shape_ok = false
        end
        if type(symbol.children) == "table" then
          walk(symbol.children)
        end
      end
    end
  end
  if symbols ~= nil then
    check("documentSymbol returns a list",
      type(symbols) == "table" and #symbols > 0, vim.inspect(symbols))
    walk(symbols)
    check("documentSymbol reports declarations", symbol_count >= 8,
      string.format("expected >= 8 symbols, got %d", symbol_count))
    check("documentSymbol entries have name/kind/range/selectionRange", shape_ok,
      sorted_names(names))
    for _, expected in ipairs({ "Vec3", "Body", "identity", "square", "compute", "finish" }) do
      check(string.format("documentSymbol contains %q", expected),
        names[expected] == true, "names: " .. sorted_names(names))
    end
    note(string.format("documentSymbol: %d symbols, %d names", symbol_count, vim.tbl_count(names)))
  end

  -- hover on a declaration name.
  local hover_position = buffer_position(bufnr, "pub square <-", "square")
  local hover = request(client, "textDocument/hover",
    { textDocument = { uri = uri }, position = hover_position }, bufnr)
  if hover ~= nil then
    local contents = type(hover) == "table" and hover.contents or nil
    check("hover has markdown contents",
      type(contents) == "table" and contents.kind == "markdown", vim.inspect(hover))
    local value = markup_text(contents)
    check("hover text is non-empty", type(value) == "string" and #value > 0, vim.inspect(hover))
    check("hover mentions the declaration name",
      type(value) == "string" and value:find("square", 1, true) ~= nil, vim.inspect(value))
    check("hover has a range", type(hover.range) == "table", vim.inspect(hover))
    note("hover: " .. vim.inspect((value or ""):gsub("%s+", " "):sub(1, 100)))
  end

  -- completion: labels come from the document's declarations and keywords.
  local completion_buf = open_buffer(tmp .. "/completion.tri")
  if wait_for_client(completion_buf, "completion buffer") then
    local completion_uri = vim.uri_from_bufnr(completion_buf)
    -- Cursor at the start of "value", i.e. at an empty-name position inside a
    -- function body where completion should offer declarations and keywords.
    local position = buffer_position(completion_buf, "    value := add(1, 2)", "value")
    local completion = request(client, "textDocument/completion",
      { textDocument = { uri = completion_uri }, position = position }, completion_buf)
    if completion ~= nil then
      local items = completion
      if type(completion) == "table" and type(completion.items) == "table" then
        items = completion.items
      end
      check("completion returns a list", type(items) == "table" and #items > 0,
        vim.inspect(completion))
      local labels_ok, offered = true, {}
      for _, item in ipairs(items or {}) do
        if type(item) == "table" and type(item.label) == "string" then
          offered[item.label] = true
        else
          labels_ok = false
        end
      end
      check("completion items have string labels", labels_ok)
      local expected = {
        "add", "caller", "pub", "struct", "use", "mod", "ret", "if", "match",
        "loop", "value", "i32",
      }
      local hits = 0
      for _, label in ipairs(expected) do
        if offered[label] then
          hits = hits + 1
        end
      end
      check("completion offers engine7 names/keywords", hits >= 3,
        string.format("expected >= 3 of %s in %s",
          table.concat(expected, ", "), sorted_names(offered)))
      note(string.format("completion: %d items, %d expected labels", #(items or {}), hits))
    end
    -- Leave the fixture buffer current for the definition check.
    vim.api.nvim_set_current_buf(bufnr)
  end

  -- same-file definition: the `load("data")` call resolves to `pub load <-`.
  local definition_position = buffer_position(bufnr, 'task <- load("data")', "load")
  local definition = request(client, "textDocument/definition",
    { textDocument = { uri = uri }, position = definition_position }, bufnr)
  if definition ~= nil then
    local location = definition
    if type(definition) == "table" and type(definition[1]) == "table" then
      location = definition[1] -- tolerate Location[]
    end
    check("definition returns a location",
      type(location) == "table" and type(location.uri) == "string"
        and type(location.range) == "table", vim.inspect(definition))
    if type(location) == "table" and type(location.uri) == "string" then
      check_eq("definition is in the same file", location.uri, uri)
      local declaration_line = symbol_line("pub load <-")
      check("definition points at the declaration",
        type(location.range) == "table"
          and location.range.start.line == declaration_line - 1,
        string.format("expected declaration on line %d (0-based), got %s",
          declaration_line - 1, vim.inspect(location.range and location.range.start)))
      note(string.format("definition: line %d (0-based), expected %d",
        location.range and location.range.start.line or -1, declaration_line - 1))
    end
  end
end

-- ---------------------------------------------------------------------------
-- Main test body.
-- ---------------------------------------------------------------------------

local function run()
  -- Pre-flight: a binary that cannot print its version is definitely not the
  -- language server, which keeps the failure message actionable.
  local version = vim.system({ bin, "--version" }, { text = true }):wait(5000)
  if not check("e7-lsp --version runs", version.code == 0 and type(version.stdout) == "string"
        and version.stdout:find("e7%-lsp") ~= nil,
      string.format("command: %s --version\nexit: %s\nstdout: %s\nstderr: %s",
        bin, tostring(version.code), vim.inspect(version.stdout), vim.inspect(version.stderr))) then
    return
  end

  make_workspace()
  registration_checks()

  local client = nil

  -- 1. Parse error diagnostics.
  local parse_buf = open_buffer(tmp .. "/parse_error.tri")
  client = wait_for_client(parse_buf, "parse error buffer")
  if not client then
    return
  end
  expect_error_diagnostic("parse error", parse_buf, nil)

  -- 2. Type (semantic) error diagnostics.
  local type_buf = open_buffer(tmp .. "/type_error.tri")
  if wait_for_client(type_buf, "type error buffer") then
    -- The compiler's semantic analyzer reports assignment mismatches with a
    -- "type mismatch" message; require that this is surfaced as a diagnostic.
    expect_error_diagnostic("type error", type_buf, "mismatch")
  end

  -- 3. A well-typed file must produce no diagnostics.  Ordering a request
  -- after didOpen guarantees the server has processed the open (and therefore
  -- already published any diagnostics) before the empty list is inspected.
  local clean_buf = open_buffer(tmp .. "/clean.tri")
  if wait_for_client(clean_buf, "clean buffer") then
    local clean_uri = vim.uri_from_bufnr(clean_buf)
    request(client, "textDocument/documentSymbol",
      { textDocument = { uri = clean_uri } }, clean_buf)
    local clean_diagnostics = vim.diagnostic.get(clean_buf)
    check("clean file has no diagnostics", #clean_diagnostics == 0,
      describe(clean_diagnostics))
  end

  -- 4. Language features on a copy of the shared kitchen-sink fixture.
  local main_buf = open_buffer(tmp .. "/main.tri")
  if wait_for_client(main_buf, "kitchen sink buffer") then
    vim.api.nvim_set_current_buf(main_buf)
    feature_checks(client)
  end
end

-- ---------------------------------------------------------------------------
-- Cleanup and report.
-- ---------------------------------------------------------------------------

local function cleanup()
  for _, client in ipairs(vim.lsp.get_clients()) do
    -- Client:stop() replaced the deprecated vim.lsp.stop_client() in 0.11.
    -- `true` terminates immediately instead of waiting for a graceful exit.
    pcall(function()
      client:stop(true)
    end)
  end
  vim.wait(2000, function()
    return #vim.lsp.get_clients() == 0
  end, 25)

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end

  if tmp and tmp:find("e7%-lsp%-neovim%-test%-") then
    pcall(vim.fn.delete, tmp, "rf")
  end
end

local ok, err = pcall(run)
if not ok then
  assertions = assertions + 1
  failures[#failures + 1] = "FAIL [unexpected Lua error] " .. tostring(err)
end

cleanup()

io.write(string.format("%d assertions, %d failures\n", assertions, #failures))
for _, message in ipairs(notes) do
  io.write(message, "\n")
end
io.stdout:flush()

if #failures > 0 then
  io.write(table.concat(failures, "\n"), "\n")
  io.stdout:flush()
  vim.cmd("cquit 1")
end

vim.cmd("qa!")
