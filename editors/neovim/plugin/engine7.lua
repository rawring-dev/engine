-- engine7 language server and formatter integration for Neovim.
--
-- Registers the `engine7` LSP client config so that Neovim starts the
-- `e7-lsp` server (LSP 3.17 over stdio) for engine7 buffers.  The server adds
-- live diagnostics, document symbols, hover, completion, and same-file
-- go-to-definition on top of the static :syntax highlighting.
--
-- The plugin also installs format-on-write for engine7 buffers: it prefers the
-- server's `textDocument/formatting` request and falls back to the `e7-fmt`
-- CLI in `--stdin` mode when no formatting-capable client is attached.  See
-- `:help engine7-format` (README) for the configuration variables.
--
-- Both tools are optional.  When no `e7-lsp`/`e7-fmt` executable can be found
-- the plugin warns once and keeps the rest of the editor support (syntax,
-- filetype, ftplugin, and whichever tool is available) working.
--
-- This file lives in plugin/, so Neovim sources it automatically at startup.
-- The `loaded_engine7_lsp` guard makes it safe to source manually as well.

if vim.g.loaded_engine7_lsp then
  return
end
vim.g.loaded_engine7_lsp = true

local api = vim.api

-- Absolute repository root, derived from this file's location:
--   <repo>/editors/neovim/plugin/engine7.lua
-- `vim.fn.resolve` follows symlinks, so this still works when the plugin is
-- installed as a symlink in a package directory.  When the plugin has been
-- copied somewhere else the derived root simply has no `zig-out` binaries and
-- resolution falls through to PATH.
local function repo_root()
  local source = debug.getinfo(1, "S").source
  source = source:gsub("^@", "")
  local path = vim.fn.fnamemodify(source, ":p")
  if type(vim.fn.resolve) == "function" then
    local ok, resolved = pcall(vim.fn.resolve, path)
    if ok and type(resolved) == "string" and resolved ~= "" then
      path = resolved
    end
  end
  -- dirname: plugin/ -> neovim/ -> editors/ -> repository root.
  local dir = vim.fs.dirname(path)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(dir)))
end

local function executable(path)
  return type(path) == "string" and path ~= "" and vim.fn.executable(path) == 1
end

-- One-shot notifications for the optional tooling.  Formatting runs on every
-- write, so a missing/broken formatter must not produce a message per write.
local notified = {}
local function notify_once(key, message, level)
  if notified[key] then
    return
  end
  notified[key] = true
  vim.notify(message, level or vim.log.levels.WARN)
end


-- ---------------------------------------------------------------------------
-- Formatting: format-on-write, LSP `textDocument/formatting` first, then the
-- `e7-fmt` CLI.  Registered before the LSP code below so it also works when
-- `g:engine7_lsp_enabled` disables the client, when no server binary exists,
-- or when the LSP log directory is read-only.
-- ---------------------------------------------------------------------------

if not vim.g.loaded_engine7_format then
  vim.g.loaded_engine7_format = true

  -- Resolves the formatter CLI, same priority order as the server command:
  --   1. `g:engine7_fmt_path`,
  --   2. `$E7_FMT_BIN`,
  --   3. the repository-local `zig-out/bin/e7-fmt`,
  --   4. `e7-fmt` anywhere on `$PATH`.
  local function resolve_fmt_cmd()
    local candidates = {}

    local configured = vim.g.engine7_fmt_path
    if type(configured) == "string" and configured ~= "" then
      candidates[#candidates + 1] = configured
    end

    local from_env = vim.env.E7_FMT_BIN
    if type(from_env) == "string" and from_env ~= "" then
      candidates[#candidates + 1] = from_env
    end

    candidates[#candidates + 1] = repo_root() .. "/zig-out/bin/e7-fmt"

    local on_path = vim.fn.exepath("e7-fmt")
    if on_path ~= "" then
      candidates[#candidates + 1] = on_path
    end

    for _, candidate in ipairs(candidates) do
      if executable(candidate) then
        return { vim.fn.fnamemodify(candidate, ":p") }
      end
    end
    return nil
  end

  local function format_on_save_enabled()
    local value = vim.g.engine7_format_on_save
    return not (value == false or value == 0)
  end

  -- The attached engine7 client that can format this buffer, if any.
  local function lsp_format_client(bufnr)
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
      if client.name == "engine7" and client:supports_method("textDocument/formatting") then
        return client
      end
    end
    return nil
  end

  local function buffer_text(bufnr)
    return table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n") .. "\n"
  end

  -- `e7-fmt --stdin` writes exactly one trailing newline; strip it so the
  -- buffer gets one list entry per line.  Defensively drop CR characters on
  -- platforms where the pipe is opened in text mode.
  local function output_lines(text)
    local lines = vim.split(text, "\n", { plain = true })
    if lines[#lines] == "" then
      table.remove(lines)
    end
    for i, line in ipairs(lines) do
      lines[i] = line:gsub("\r$", "")
    end
    return lines
  end

  -- Replacing the whole buffer moves every window's cursor to the top; save
  -- and restore the view of each window that displays bufnr.
  local function with_saved_views(bufnr, fn)
    local views = {}
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
      views[#views + 1] = {
        win = win,
        view = api.nvim_win_call(win, vim.fn.winsaveview),
      }
    end
    fn()
    for _, saved in ipairs(views) do
      if api.nvim_win_is_valid(saved.win) then
        pcall(api.nvim_win_call, saved.win, function()
          vim.fn.winrestview(saved.view)
        end)
      end
    end
  end

  local function apply_formatted_text(bufnr, text)
    local new_lines = output_lines(text)
    local old_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if vim.deep_equal(old_lines, new_lines) then
      return false
    end
    with_saved_views(bufnr, function()
      api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
    end)
    return true
  end

  -- Runs `e7-fmt --stdin` synchronously.  Returns the formatted text, or nil
  -- plus a human-readable failure reason (and the CLI's stderr when available).
  local function run_fmt_cli(cmd, input)
    if type(vim.system) == "function" then
      local ok, result = pcall(function()
        return vim.system(cmd, { stdin = input, text = true }):wait(3000)
      end)
      if not ok then
        return nil, "e7-fmt failed to start: " .. tostring(result)
      end
      local stderr_text = type(result.stderr) == "string" and result.stderr or ""
      if result.code ~= 0 then
        local detail = stderr_text:gsub("%s+$", "")
        return nil, string.format("e7-fmt exited %s%s", tostring(result.code),
          detail ~= "" and (": " .. detail) or "")
      end
      if type(result.stdout) ~= "string" or result.stdout == "" then
        return nil, "e7-fmt produced no output"
      end
      return result.stdout, nil, stderr_text
    end

    -- Neovim 0.9 fallback (vim.system arrived in 0.10).
    if type(vim.fn.system) ~= "function" then
      return nil, "no synchronous process API available"
    end
    local output = vim.fn.system(cmd, input)
    if vim.v.shell_error ~= 0 then
      return nil, "e7-fmt exited " .. tostring(vim.v.shell_error)
    end
    if type(output) ~= "string" or output == "" then
      return nil, "e7-fmt produced no output"
    end
    return output
  end

  -- Formats bufnr in place.  Returns `"lsp"` or `"cli"` on success, or nil plus
  -- a human-readable reason.  Never raises: callers sit inside BufWritePre.
  local function format_buffer(bufnr)
    local lsp_error = nil
    if lsp_format_client(bufnr) then
      local ok, err = pcall(vim.lsp.buf.format, {
        bufnr = bufnr,
        -- Synchronous: BufWritePre must see the formatted buffer before the
        -- write happens.  A slow server falls back to the CLI / writes as-is.
        async = false,
        timeout_ms = 2000,
        filter = function(client)
          return client.name == "engine7"
        end,
      })
      if ok then
        return "lsp"
      end
      lsp_error = tostring(err)
    end

    local cmd = resolve_fmt_cmd()
    if not cmd then
      if lsp_error then
        return nil, "e7-lsp formatting failed (" .. lsp_error .. ") and e7-fmt is not available"
      end
      return nil, "no formatter available (e7-lsp with textDocument/formatting, or e7-fmt)"
    end

    -- `e7-fmt --stdin` reads the source from stdin and writes only the
    -- formatted text to stdout (diagnostics go to stderr).
    local text, err, stderr_text = run_fmt_cli({ cmd[1], "--stdin" }, buffer_text(bufnr))
    if not text then
      return nil, err or "e7-fmt failed"
    end
    local parse_note = nil
    if type(stderr_text) == "string" and stderr_text:lower():find("parse error", 1, true) then
      parse_note = "parse error in the file; only whitespace was normalized"
    end
    apply_formatted_text(bufnr, text)
    return "cli", nil, parse_note
  end

  local function format_on_write(args)
    local bufnr = args.buf
    if vim.bo[bufnr].filetype ~= "engine7" then
      return
    end
    if not format_on_save_enabled() then
      return
    end
    if not vim.bo[bufnr].modifiable then
      return
    end

    -- Errors are swallowed on purpose: a formatting problem must never abort
    -- the write.  The unformatted buffer is written and the user is told once.
    local ok, how, err = pcall(format_buffer, bufnr)
    if not ok then
      notify_once("format-write-error", "engine7: formatting failed: " .. tostring(how))
    elseif how == nil then
      notify_once("format-write-unavailable",
        "engine7: " .. tostring(err) .. "; buffer written unformatted")
    end
  end

  api.nvim_create_autocmd("BufWritePre", {
    group = api.nvim_create_augroup("engine7_format", { clear = true }),
    pattern = "*",
    callback = format_on_write,
    desc = "engine7: format buffer before writing",
  })

  api.nvim_create_user_command("Engine7Format", function()
    local bufnr = api.nvim_get_current_buf()
    if vim.bo[bufnr].filetype ~= "engine7" then
      vim.notify("engine7: :Engine7Format only formats engine7 buffers", vim.log.levels.WARN)
      return
    end
    if not vim.bo[bufnr].modifiable then
      vim.notify("engine7: cannot format an unmodifiable buffer", vim.log.levels.WARN)
      return
    end

    local ok, how, err, parse_note = pcall(format_buffer, bufnr)
    if not ok then
      vim.notify("engine7: formatting failed: " .. tostring(how), vim.log.levels.ERROR)
    elseif how == nil then
      vim.notify("engine7: " .. tostring(err), vim.log.levels.ERROR)
    elseif parse_note then
      vim.notify("engine7: " .. parse_note, vim.log.levels.WARN)
    end
  end, {
    desc = "Format the current engine7 buffer (LSP formatting, falling back to e7-fmt)",
    force = true,
  })
end


-- ---------------------------------------------------------------------------
-- Language server: register the `engine7` client and start it for engine7
-- buffers.  `g:engine7_lsp_enabled = 0` keeps the formatter above but skips
-- this section entirely.
-- ---------------------------------------------------------------------------

-- The plugin's LSP side can be disabled with `let g:engine7_lsp_enabled = 0`
-- for users who only want highlighting and format-on-write.
if vim.g.engine7_lsp_enabled == false or vim.g.engine7_lsp_enabled == 0 then
  return
end

-- Workspace markers: the server is file-oriented, but a root directory gives
-- the client a stable workspace and keeps the server's cwd inside the project.
local root_markers = { "build.zig.zon", "build.zig", ".git" }

-- Resolves the server command, in priority order:
--   1. `g:engine7_lsp_path` (an explicit executable path, e.g. from a plugin
--      manager's build step or a non-standard install),
--   2. `$E7_LSP_BIN` (environment override, useful in CI and sandboxes),
--   3. the repository-local `zig-out/bin/e7-lsp` next to this plugin,
--   4. `e7-lsp` anywhere on `$PATH`.
-- Returns an argv list for the client's `cmd`, or nil when nothing is usable.
local function resolve_cmd()
  local candidates = {}

  local configured = vim.g.engine7_lsp_path
  if type(configured) == "string" and configured ~= "" then
    candidates[#candidates + 1] = configured
  end

  local from_env = vim.env.E7_LSP_BIN
  if type(from_env) == "string" and from_env ~= "" then
    candidates[#candidates + 1] = from_env
  end

  candidates[#candidates + 1] = repo_root() .. "/zig-out/bin/e7-lsp"

  local on_path = vim.fn.exepath("e7-lsp")
  if on_path ~= "" then
    candidates[#candidates + 1] = on_path
  end

  for _, candidate in ipairs(candidates) do
    if executable(candidate) then
      -- The client may chdir to the workspace root, so make relative paths
      -- absolute before storing them in `cmd`.
      return { vim.fn.fnamemodify(candidate, ":p") }
    end
  end
  return nil
end

-- The LSP client opens stdpath('log')/lsp.log on its first log message.  When
-- the state directory is read-only (sandboxed homes, some NFS setups) Neovim
-- reports "Failed to open LSP client log file" from inside the FileType
-- autocmd, which makes `:edit` fail.  Rather than break editing in such an
-- environment, leave the optional server off; highlighting and format-on-write
-- still work.
local function lsp_log_unwritable()
  local log = vim.lsp.log
  if type(log) ~= "table" or type(log.get_filename) ~= "function" then
    return nil
  end
  local filename = log.get_filename()
  if type(filename) ~= "string" or filename == "" then
    return nil
  end
  local dir = vim.fs.dirname(filename)
  -- filewritable() returns 2 for a writable directory (1 is for files).
  if vim.fn.isdirectory(dir) == 1 and vim.fn.filewritable(dir) >= 1 then
    return nil
  end
  return filename
end

-- Warn at most once, and only when the user actually opens an engine7 buffer:
-- a missing optional server should not produce noise for every Neovim start.
local lsp_warned = false
local function warn_on_filetype(message)
  api.nvim_create_autocmd("FileType", {
    group = api.nvim_create_augroup("engine7_lsp", { clear = true }),
    pattern = "engine7",
    callback = function()
      if lsp_warned then
        return
      end
      lsp_warned = true
      vim.notify(message, vim.log.levels.WARN)
    end,
    desc = "engine7: report why the language server is not running",
  })
end

local log_file = lsp_log_unwritable()
if log_file then
  warn_on_filetype(string.format(
    "engine7: e7-lsp disabled: Neovim cannot write its LSP log (%s); "
      .. "highlighting and formatting still work",
    log_file
  ))
  return
end

local cmd = resolve_cmd()
if not cmd then
  warn_on_filetype(
    "engine7: e7-lsp not found; run `zig build lsp` in the engine7 repository, "
      .. "or set g:engine7_lsp_path / $E7_LSP_BIN (highlighting and formatting still work)"
  )
  return
end

local lsp_config = {
  name = "engine7",
  cmd = cmd,
  filetypes = { "engine7" },
  root_markers = root_markers,
}

-- Neovim 0.11 introduced `vim.lsp.config()` / `vim.lsp.enable()`; prefer them
-- because they also handle root_dir resolution and reusing clients.  The
-- FileType + `vim.lsp.start()` fallback keeps older Neovim versions working.
local has_modern_api = vim.fn.has("nvim-0.11") == 1
  and type(vim.lsp.enable) == "function"
  and vim.lsp.config ~= nil

if has_modern_api then
  vim.lsp.config("engine7", lsp_config)
  vim.lsp.enable("engine7")
else
  local group = api.nvim_create_augroup("engine7_lsp", { clear = true })

  local function start(bufnr)
    local config = vim.tbl_extend("force", lsp_config, {
      -- `vim.fs.root()` is Neovim 0.10+; older clients run in single-file mode.
      root_dir = type(vim.fs.root) == "function" and vim.fs.root(bufnr, root_markers) or nil,
    })
    -- Older clients compute root_dir themselves from `root_markers`; the
    -- explicit root_dir above makes the field redundant (and unknown to 0.9).
    config.root_markers = nil
    vim.lsp.start(config, { bufnr = bufnr })
  end

  api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "engine7",
    callback = function(ev)
      start(ev.buf)
    end,
    desc = "engine7: start e7-lsp",
  })

  -- Buffers that already have the engine7 filetype when this plugin is sourced
  -- (e.g. when it is loaded lazily) do not get another FileType event.
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "engine7" then
      start(bufnr)
    end
  end
end
