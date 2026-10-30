-- Non-interactive format-on-write tests for the engine7 Neovim plugin.
--
-- Run through editors/neovim/test/run_fmt.sh, which starts nvim with
--   nvim --headless --clean -u NONE -i NONE -l this_file.lua
-- and passes this plugin, a built e7-lsp, and a built e7-fmt through the
-- environment.
--
-- The spec covers both formatting paths:
--
--   * LSP path (default): the plugin has an attached `engine7` client that
--     advertises `textDocument/formatting`; :write formats synchronously in
--     BufWritePre and the formatted text is what lands on disk;
--   * CLI fallback path: with `g:engine7_lsp_enabled = 0` there is no client,
--     so the plugin runs `e7-fmt --stdin` synchronously; a format_on_save=0
--     buffer must be written untouched;
--   * :Engine7Format formats the current buffer without writing the file.
--
-- Formatter expectations asserted here (see editors/fmt/README.md): unnecessary
-- `:=` bindings become `<-`, overlong assignment values use the
-- `name <-` + indented RHS layout, trailing whitespace is stripped, tabs are
-- expanded, spacing around operators is normalized, and the file ends with
-- exactly one newline.  A second write of already formatted text must not
-- change it.
--
-- Every test file lives in a throwaway workspace under $TMPDIR (with a
-- build.zig.zon marker so root_dir/project analysis is exercised).  Clients are
-- stopped and the workspace is removed before exit; nothing is written to the
-- repository.

local plugin_dir = assert(vim.env.E7_NEOVIM_PLUGIN_DIR, "E7_NEOVIM_PLUGIN_DIR is not set")
local lsp_bin = assert(vim.env.E7_LSP_BIN, "E7_LSP_BIN is not set")
local fmt_bin = assert(vim.env.E7_FMT_BIN, "E7_FMT_BIN is not set")

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

local function read_file(path)
  local file = assert(io.open(path, "rb"), "cannot read " .. path)
  local data = file:read("*a")
  file:close()
  return data
end

local function write_file(path, data)
  local file = assert(io.open(path, "wb"), "cannot write " .. path)
  file:write(data)
  file:close()
end

local function text_lines(text)
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

local function longest_line(text)
  local longest = 0
  for _, line in ipairs(text_lines(text)) do
    if #line > longest then
      longest = #line
    end
  end
  return longest
end

local function has_trailing_whitespace(text)
  for _, line in ipairs(text_lines(text)) do
    if line:find("[ \t]$") then
      return true
    end
  end
  return false
end

local function find_line(lines, predicate)
  for index, line in ipairs(lines) do
    if predicate(line) then
      return index, line
    end
  end
  return nil
end

local function describe_written(label, written)
  notes[#notes + 1] = string.format("note: %s output:\n%s", label, written)
end

-- ---------------------------------------------------------------------------
-- Plugin setup.
-- ---------------------------------------------------------------------------

local function stop_clients()
  for _, client in ipairs(vim.lsp.get_clients({ name = "engine7" })) do
    pcall(function()
      client:stop(true)
    end)
  end
  vim.wait(2000, function()
    return #vim.lsp.get_clients({ name = "engine7" }) == 0
  end, 25)
  if type(vim.lsp.enable) == "function" then
    pcall(vim.lsp.enable, "engine7", false)
  end
end

-- (Re)sources the plugin with a clean state so each phase can observe a fresh
-- registration (LSP on/off, format-on-save on/off).
local function reset_plugin(opts)
  stop_clients()
  vim.g.loaded_engine7_lsp = nil
  vim.g.loaded_engine7_format = nil
  vim.g.engine7_lsp_enabled = opts.lsp_enabled
  vim.g.engine7_format_on_save = opts.format_on_save
  vim.g.engine7_fmt_path = nil
  vim.env.E7_LSP_BIN = opts.lsp_bin or ""
  vim.env.E7_FMT_BIN = opts.fmt_bin or ""
  dofile(plugin_dir .. "/plugin/engine7.lua")
end

local function open_engine7(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  -- '--clean' leaves filetype detection off; set the filetype explicitly so
  -- the plugin's FileType/BufWritePre autocmds apply.
  vim.bo[bufnr].filetype = "engine7"
  return bufnr
end

local function wait_for_client(bufnr, timeout)
  local ok = vim.wait(timeout or 5000, function()
    local client = vim.lsp.get_clients({ bufnr = bufnr, name = "engine7" })[1]
    return client ~= nil and client.initialized == true
  end, 25)
  return ok, vim.lsp.get_clients({ bufnr = bufnr, name = "engine7" })[1]
end

local function buffer_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr or 0, 0, -1, false), "\n") .. "\n"
end

-- ---------------------------------------------------------------------------
-- Formatting assertions.
-- ---------------------------------------------------------------------------

-- Properties every formatter output must have.
local function check_common(label, written)
  check(label .. ": no tabs", written:find("\t", 1, true) == nil, vim.inspect(written))
  check(label .. ": no trailing whitespace", not has_trailing_whitespace(written),
    vim.inspect(written))
  check(label .. ": exactly one final newline",
    written:sub(-1) == "\n" and written:sub(-2, -2) ~= "\n", vim.inspect(written))
end

-- The long-assignment sample: `total := ...` is never mutated, so it becomes an
-- immutable binding, and the overlong line uses the indented-RHS layout with
-- its bracketed argument list wrapped at the same time.
local LSP_INPUT = table.concat({
  "pub make <- () -> i32:",
  "    value := 1",
  "    total := combine_three(alpha_one, beta_two, gamma_three, delta_four, epsilon_five, zeta_six, eta_seven)",
  "    ret value + total",
}, "\n") .. "\n"

local function check_lsp_format(label, written)
  check_common(label, written)
  local lines = text_lines(written)

  check(label .. ": unnecessary := converted", written:find(":=", 1, true) == nil,
    vim.inspect(written))
  check(label .. ": simple binding formatted",
    find_line(lines, function(line)
      return line == "    value <- 1"
    end) ~= nil, vim.inspect(lines))

  local total_index, total_line = find_line(lines, function(line)
    return line == "    total <-"
  end)
  check(label .. ": long assignment breaks after the operator",
    total_index ~= nil, "expected a line \"    total <-\"; got " .. vim.inspect(lines))
  if total_index then
    local continuation = lines[total_index + 1] or ""
    check(label .. ": assignment RHS is indented one level",
      continuation:match("^        %S") ~= nil,
      string.format("line after %q: %q", total_line, continuation))
  end

  local overlong_index, overlong_line = find_line(lines, function(line)
    return #line > 80
  end)
  check(label .. ": output fits in 80 columns", overlong_index == nil,
    string.format("longest line is %d: %q", longest_line(written), overlong_line or ""))
  describe_written(label, written)
end

-- The CLI sample: exact spacing/tab/final-newline normalization on lines that
-- need no wrapping.
local CLI_INPUT = "pub add <- (a: i32, b: i32) -> i32:\n"
  .. "    value  :=  1   \n"
  .. "    ret a\t+\tb\n"

local CLI_EXPECTED = table.concat({
  "pub add <- (a: i32, b: i32) -> i32:",
  "    value <- 1",
  "    ret a + b",
}, "\n") .. "\n"

local function check_cli_format(label, written)
  check_common(label, written)
  check_eq(label .. ": normalized output", written, CLI_EXPECTED)
  describe_written(label, written)
end

-- ---------------------------------------------------------------------------
-- Phase 1: LSP formatting path.
-- ---------------------------------------------------------------------------

local function phase_lsp(write_root)
  reset_plugin({
    lsp_enabled = nil,      -- default: client enabled
    format_on_save = nil,   -- default: format-on-save enabled
    lsp_bin = lsp_bin,
    fmt_bin = fmt_bin,
  })

  check("format-on-save registers", vim.g.loaded_engine7_format == true)
  check(":Engine7Format command exists", vim.fn.exists(":Engine7Format") == 2)
  check("BufWritePre autocmd registered",
    #vim.api.nvim_get_autocmds({ group = "engine7_format", event = "BufWritePre" }) >= 1)

  local path = write_root .. "/lsp_dirty.e7"
  write_file(path, LSP_INPUT)
  local bufnr = open_engine7(path)

  local attached, client = wait_for_client(bufnr, 5000)
  if not check("LSP client attaches to .e7 buffer", attached,
      "engine7 client did not initialize within 5s; clients: "
        .. vim.inspect(vim.tbl_map(function(c)
          return c.name
        end, vim.lsp.get_clients({ _uninitialized = true })))) then
    return
  end

  local supports = client:supports_method("textDocument/formatting")
  check("server advertises textDocument/formatting", supports,
    "the LSP formatting path cannot be tested; capabilities: "
      .. vim.inspect(client.server_capabilities))
  if not supports then
    return
  end

  -- BufWritePre formats synchronously, so the file must already be formatted
  -- when :write returns.
  vim.cmd("write")
  local first = read_file(path)
  check("write formatted the file through LSP", first ~= LSP_INPUT, vim.inspect(first))
  check_lsp_format("lsp write", first)

  vim.cmd("write")
  check_eq("second write of formatted file is a no-op", read_file(path), first)

  -- A clean formatted file copied to a fresh path must also survive a write.
  local clean_path = write_root .. "/lsp_clean.e7"
  write_file(clean_path, first)
  local clean_buf = open_engine7(clean_path)
  if wait_for_client(clean_buf, 5000) then
    vim.cmd("write")
    check_eq("clean formatted file is unchanged", read_file(clean_path), first)
  end
end

-- ---------------------------------------------------------------------------
-- Phase 2: CLI fallback (no LSP client).
-- ---------------------------------------------------------------------------

local function phase_cli(write_root)
  reset_plugin({
    lsp_enabled = 0,        -- no engine7 client at all
    format_on_save = nil,   -- format-on-save enabled
    lsp_bin = "",
    fmt_bin = fmt_bin,
  })

  check("LSP disabled leaves format-on-save registered",
    vim.g.loaded_engine7_format == true and vim.fn.exists(":Engine7Format") == 2)

  local path = write_root .. "/cli_dirty.e7"
  write_file(path, CLI_INPUT)
  local bufnr = open_engine7(path)
  check("no client attached with g:engine7_lsp_enabled=0",
    #vim.lsp.get_clients({ bufnr = bufnr, name = "engine7" }) == 0)

  vim.cmd("write")
  local written = read_file(path)
  check("CLI fallback formatted the file", written ~= CLI_INPUT, vim.inspect(written))
  check_cli_format("cli write", written)

  -- Same file written again must not churn.
  vim.cmd("write")
  check_eq("second CLI write of formatted file is a no-op", read_file(path), written)

  -- g:engine7_format_on_save = 0 disables formatting on write.
  vim.g.engine7_format_on_save = 0
  local skipped_path = write_root .. "/cli_skipped.e7"
  write_file(skipped_path, CLI_INPUT)
  open_engine7(skipped_path)
  vim.cmd("write")
  check_eq("format_on_save=0 writes the buffer untouched",
    read_file(skipped_path), CLI_INPUT)
  vim.g.engine7_format_on_save = nil
end

-- ---------------------------------------------------------------------------
-- Phase 3: :Engine7Format formats the buffer without writing.
-- ---------------------------------------------------------------------------

local function phase_command(write_root)
  reset_plugin({
    lsp_enabled = 0,
    format_on_save = 0,     -- only the command may format
    lsp_bin = "",
    fmt_bin = fmt_bin,
  })

  local path = write_root .. "/command.e7"
  write_file(path, CLI_INPUT)
  open_engine7(path)

  check(":Engine7Format exists", vim.fn.exists(":Engine7Format") == 2)
  vim.cmd("Engine7Format")

  local formatted_buffer = buffer_text(0)
  check(":Engine7Format formats the buffer", formatted_buffer ~= CLI_INPUT,
    vim.inspect(formatted_buffer))
  check_cli_format("Engine7Format buffer", formatted_buffer)
  check_eq(":Engine7Format does not write the file", read_file(path), CLI_INPUT)

  -- A non-engine7 buffer must be left alone (and must not error).
  local other = write_root .. "/other.txt"
  write_file(other, "not engine7\n")
  vim.cmd("edit " .. vim.fn.fnameescape(other))
  vim.bo.filetype = "text"
  local ok = pcall(vim.cmd, "Engine7Format")
  check(":Engine7Format on a non-engine7 buffer is a no-op", ok
    and buffer_text(0) == "not engine7\n")
end

-- ---------------------------------------------------------------------------
-- Main.
-- ---------------------------------------------------------------------------

local tmp = nil
local function make_workspace()
  local base = (vim.uv and vim.uv.os_tmpdir and vim.uv.os_tmpdir())
    or os.getenv("TMPDIR") or "/tmp"
  tmp = string.format("%s/e7-fmt-neovim-test-%d-%d", base, vim.fn.getpid(),
    math.floor(((vim.uv and vim.uv.hrtime and vim.uv.hrtime()) or os.time()) / 1000) % 1000000)
  vim.fn.mkdir(tmp, "p")
  -- Workspace marker: the client starts with this directory as root_dir.
  vim.fn.writefile({ "{}" }, tmp .. "/build.zig.zon")
  return tmp
end

local function run()
  local local_assertions_before = assertions

  phase_lsp(tmp)
  phase_cli(tmp)
  phase_command(tmp)

  if assertions == local_assertions_before then
    check("at least one formatting assertion ran", false, "no assertions were recorded")
  end
end

local function cleanup()
  stop_clients()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
  if tmp and tmp:find("e7%-fmt%-neovim%-test%-") then
    pcall(vim.fn.delete, tmp, "rf")
  end
end

make_workspace()
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
