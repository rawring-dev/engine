-- Non-interactive highlighting tests for the engine7 Neovim plugin.
--
-- Run through editors/neovim/test/run.sh, which starts nvim with
--   nvim --headless --clean -u NONE -i NONE -l this_file.lua
-- and passes the plugin root and the shared fixture through the environment.
--
-- Every assertion resolves a token by searching the fixture text, asks the
-- legacy syntax engine for the group at that byte column (transparent items
-- disabled) and compares it with the expected e7* group name.

local plugin_dir = assert(os.getenv("E7_NEOVIM_PLUGIN_DIR"), "E7_NEOVIM_PLUGIN_DIR is not set")
local fixture = assert(os.getenv("E7_FIXTURE"), "E7_FIXTURE is not set")

local assertions = 0
local failures = {}

local function group_at(lnum, col)
  local id = vim.fn.synID(lnum, col, 0)
  local name = vim.fn.synIDattr(id, "name")
  return name == "" and "<none>" or name
end

local function fail(label, lnum, col, token, expected, source)
  local actual = group_at(lnum, col)
  if actual == expected then
    return
  end
  failures[#failures + 1] = string.format(
    "FAIL [%s] line %d col %d token %q: expected %s, got %s\n      source: %s",
    label, lnum, col, token, expected, actual, source)
end

local function record(label, lnum, col, token, expected, source)
  assertions = assertions + 1
  fail(label, lnum, col, token, expected, source)
end

local fixture_lines = {}

local function find_line(needle)
  for lnum, text in ipairs(fixture_lines) do
    if text:find(needle, 1, true) then
      return lnum
    end
  end
  error(string.format("fixture line not found: %q", needle))
end

local function find_col(lnum, token, occurrence)
  local text = fixture_lines[lnum]
  local init, seen = 1, 0
  while true do
    local first, last = text:find(token, init, true)
    if not first then
      break
    end
    seen = seen + 1
    if seen == (occurrence or 1) then
      return first
    end
    init = last + 1
  end
  error(string.format("token %q not found in line %d: %q", token, lnum, text))
end

-- check(label, fixture_line_substring, token, expected_group[, opts])
-- opts.occurrence: 1-based occurrence of token in the line (default 1)
-- opts.offset:     0-based byte offset added to the found column
local function check(label, needle, token, expected, opts)
  opts = opts or {}
  local lnum = find_line(needle)
  local col = find_col(lnum, token, opts.occurrence) + (opts.offset or 0)
  record(label, lnum, col, token, expected, fixture_lines[lnum])
end

local function check_plain(label, lnum, col, expected, source)
  record(label, lnum, col, "<scratch>", expected, source)
end


-- ---------------------------------------------------------------------------
-- Setup: use only this plugin plus the stock runtime.
-- ---------------------------------------------------------------------------
vim.opt.runtimepath:prepend(plugin_dir)
vim.cmd("filetype plugin indent on")
vim.cmd("syntax on")
vim.cmd("edit " .. vim.fn.fnameescape(fixture))

local fixture_buf = vim.api.nvim_get_current_buf()
fixture_lines = vim.api.nvim_buf_get_lines(fixture_buf, 0, -1, false)

-- Filetype detection through ftdetect/engine7.vim.
assertions = assertions + 1
if vim.bo.filetype ~= "engine7" then
  failures[#failures + 1] = string.format(
    "FAIL [filetype] expected engine7 for %s, got %q", fixture, vim.bo.filetype)
end
assertions = assertions + 1
if vim.b.current_syntax ~= "engine7" then
  failures[#failures + 1] = string.format(
    "FAIL [syntax] expected b:current_syntax engine7, got %s",
    tostring(vim.b.current_syntax))
end

-- ftplugin/engine7.vim settings (tabs are rejected by the lexer).
local ftplugin_expect = {
  commentstring = "# %s",
  comments = ":#",
  expandtab = true,
  shiftwidth = 4,
  tabstop = 4,
  softtabstop = 4,
}
for option, expected in pairs(ftplugin_expect) do
  assertions = assertions + 1
  if vim.bo[option] ~= expected then
    failures[#failures + 1] = string.format(
      "FAIL [ftplugin] expected %s=%s, got %s",
      option, vim.inspect(expected), vim.inspect(vim.bo[option]))
  end
end
assertions = assertions + 1
if not tostring(vim.bo.suffixesadd):find(".tri", 1, true) then
  failures[#failures + 1] = string.format(
    "FAIL [ftplugin] expected suffixesadd to contain .tri, got %q", vim.bo.suffixesadd)
end

-- e7* groups are linked to the standard groups of the shared model and never
-- hardcode colors.
local link_expect = {
  e7Comment = "Comment",
  e7String = "String",
  e7Escape = "SpecialChar",
  e7Number = "Number",
  e7Boolean = "Boolean",
  e7Constant = "Constant",
  e7Conditional = "Conditional",
  e7Repeat = "Repeat",
  e7Statement = "Statement",
  e7Include = "Include",
  e7Structure = "Structure",
  e7Keyword = "Keyword",
  e7Storage = "StorageClass",
  e7Type = "Type",
  e7Function = "Function",
  e7Field = "Identifier",
  e7Attribute = "PreProc",
  e7Operator = "Operator",
  e7Delimiter = "Delimiter",
}
for group, target in pairs(link_expect) do
  assertions = assertions + 1
  local hl = vim.api.nvim_get_hl(0, { name = group, link = true })
  if hl.link ~= target then
    failures[#failures + 1] = string.format(
      "FAIL [highlight link] %s: expected link %s, got %s",
      group, target, tostring(hl.link))
  end
end


-- ---------------------------------------------------------------------------
-- Shared fixture assertions.
-- ---------------------------------------------------------------------------

-- comments
check("comment start", "# engine7 kitchen sink", "#", "e7Comment")
check("comment word", "# engine7 kitchen sink", "engine7", "e7Comment")
check("comment operator", "# ---------------------------------------------------------------------------", "-", "e7Comment")

-- strings and escapes
check("double string open", 'quote <- "tab', '"', "e7String")
check("double string body", 'quote <- "tab', "tab", "e7String")
check("double string after escape", 'quote <- "tab', "newline", "e7String")
check("escape \\t", 'quote <- "tab', "\\t", "e7Escape")
check("escape \\n", 'quote <- "tab', "\\n", "e7Escape")
check("escape escaped quote", 'quote <- "tab', '\\"', "e7Escape")
check("escape backslash", 'quote <- "tab', "\\\\", "e7Escape")
check("single string open", "single <- 'single quoted'", "'", "e7String")
check("single string body", "single <- 'single quoted'", "quoted", "e7String")

-- numbers: integer, float with exponent, float with signed exponent
check("integer", "big <- 1_000_000", "1_000_000", "e7Number")
check("integer last byte", "big <- 1_000_000", "1_000_000", "e7Number", { offset = 8 })
check("float", "ratio <- 6.02e23", "6.02e23", "e7Number")
check("float last byte", "ratio <- 6.02e23", "6.02e23", "e7Number", { offset = 6 })
check("float signed exponent", "tiny <- 1.5E-9", "1.5E-9", "e7Number", { offset = 5 })
check("float in expression", "if value > 100.0", "100.0", "e7Number")

-- boolean and nil literals
check("true", "flag <- true", "true", "e7Boolean")
check("false", "other <- false", "false", "e7Boolean")
check("nil", "ret nil", "nil", "e7Constant")

-- conditional keywords
check("if", "if counter >= limit", "if", "e7Conditional")
check("elif", "elif value == 0", "elif", "e7Conditional")
check("else", "    else:", "else", "e7Conditional")
check("match", "ret match color:", "match", "e7Conditional")

-- repeat keywords
check("loop", "    loop:", "loop", "e7Repeat")
check("while", "while counter > 0", "while", "e7Repeat")
check("for", "for entry in query", "for", "e7Repeat")
check("in", "for entry in query", "in", "e7Repeat")

-- flow statements
check("ret", "ret a.x * b.x", "ret", "e7Statement")
check("break", "            break", "break", "e7Statement")
check("cont", "            cont", "cont", "e7Statement")

-- include keywords
check("use", "use crate::ecs::World;", "use", "e7Include")
check("mod", "mod math {", "mod", "e7Include")

-- structure keywords
check("struct", "pub Vec3 <- struct {", "struct", "e7Structure")
check("enum", "pub Color <- enum:", "enum", "e7Structure")
check("table", "pub Entity <- table:", "table", "e7Structure")
check("trigger", "pub Update <- trigger:", "trigger", "e7Structure")
check("sys", "update <- sys(query", "sys", "e7Structure")

-- keyword class
check("impl", "impl Drawable for Body:", "impl", "e7Keyword")
check("trait", "pub trait Drawable: Debug", "trait", "e7Keyword")
check("async", "pub work <- async", "async", "e7Keyword")
check("await", "value <- await task", "await", "e7Keyword")
check("spawn", "spawned <- spawn work(1)", "spawn", "e7Keyword", { occurrence = 2 })
check("detach", "detached <- detach work(2)", "detach", "e7Keyword", { occurrence = 2 })
check("cancel", "cancelled <- cancel spawned", "cancel", "e7Keyword", { occurrence = 2 })
check("unsafe", "    unsafe:", "unsafe", "e7Keyword")
check("select", "select &mut Position", "select", "e7Keyword")
check("from", "from Body", "from", "e7Keyword")
check("where", "-> T where T: Clone:", "where", "e7Keyword")
check("res", "res World", "res", "e7Keyword")
check("as", "id as i32", "as", "e7Keyword")
check("not", "inverted <- not (a == b)", "not", "e7Keyword")
check("and", "both <- a > 0 and b > 0", "and", "e7Keyword")
check("or", "either <- a < 0 or b < 0", "or", "e7Keyword")
check("xor", "xor a >= b", "xor", "e7Keyword")
check("crate", "use crate::ecs::World;", "crate", "e7Keyword")
check("self", "pub(self) LocalOnly", "self", "e7Keyword")
check("super", "use super::math::*;", "super", "e7Keyword")
check("mut", "select &mut Position", "mut", "e7Keyword")
check("raw", "raw_pointer: *raw Vec3", "raw", "e7Keyword", { occurrence = 2 })

-- visibility
check("pub", "pub Vec3 <- struct {", "pub", "e7Storage")

-- types
check("uppercase type declaration", "pub Vec3 <- struct {", "Vec3", "e7Type")
check("uppercase type use", "pub dot <- (a: &Vec3", "Vec3", "e7Type")
check("aggregate declaration name", "pub(crate) Body <- struct:", "Body", "e7Type")
check("lowercase aggregate with generics", "pub pair<T> <- struct where T: Clone:", "pair", "e7Type")
check("generic parameter", "pub pair<T> <- struct where T: Clone:", "T", "e7Type")
check("where-clause bound", "pub trait Drawable: Debug", "Debug", "e7Type")
check("trait name", "pub trait Drawable: Debug", "Drawable", "e7Type")
check("contextual map type", "matrix: map[str, i32]", "map", "e7Type")
check("enum variant type", "Red | Green", "Green", "e7Type")

-- primitive scalar type names are always types (and never members)
check("primitive in parameter", "pub spin <- (limit: i32) -> i32:", "i32", "e7Type")
check("primitive return before layout colon", "pub spin <- (limit: i32) -> i32:", "i32", "e7Type", { occurrence = 2 })
check("primitive after member colon", "pub id: u64", "u64", "e7Type")
check("primitive str in map type", "mapping <- map[str, i32]", "str", "e7Type")
check("primitive i32 in map type", "mapping <- map[str, i32]", "i32", "e7Type")
check("primitive f32 field type", "x: f32", "f32", "e7Type")

-- functions: declarations and calls
check("function declaration", "pub identity<T> <- (value: T)", "identity", "e7Function")
check("async function declaration", "pub work <- async (id: i64)", "work", "e7Function")
check("method declaration", "pub draw <- (body: &Body)", "draw", "e7Function")
check("function call", "print_line(body.id)", "print_line", "e7Function")
check("path function call", "math::dot(&v, &v)", "dot", "e7Function")
check("function call load", 'task <- load("data")', "load", "e7Function")

-- fields and members
check("field access", "entry.position += entry.velocity", "position", "e7Field")
check("second field access", "entry.position += entry.velocity", "velocity", "e7Field")
check("field id", "print_line(body.id)", "id", "e7Field")
check("member id", "pub id: u64", "id", "e7Field")
check("member x", "x: f32", "x", "e7Field")
check("member value", "value: i32", "value", "e7Field")
check("member dt", "    dt: f32", "dt", "e7Field")
check("member first", "    first: T", "first", "e7Field")
check("mutable binding is not a member", "sum := 0", "sum", "<none>")
check("path segment is not a member", "use crate::ecs::World;", "ecs", "<none>")

-- attributes
check("attribute derive", "@derive(Debug, Clone)", "@derive", "e7Attribute")
check("attribute component", "@component(Position, Velocity)", "@component", "e7Attribute")
check("attribute serialize", "@serialize", "@serialize", "e7Attribute")
check("type inside attribute", "@derive(Debug, Clone)", "Debug", "e7Type")

-- operators
check("bind immutable", "pub(crate) Body <- struct:", "<-", "e7Operator")
check("function arrow", "pub dot <- (a: &Vec3, b: &Vec3) -> f32", "->", "e7Operator")
check("bind mutable", "sum := 0", ":=", "e7Operator")
check("assignment", "pub square <- (x: i32) -> i32 = x * x", "=", "e7Operator")
check("range inclusive", "for i in 0..=10:", "..=", "e7Operator")
check("range", "for i in 0..10:", "..", "e7Operator")
check("table ellipsis", "    ...", "...", "e7Operator")
check("table ellipsis third byte", "    ...", "...", "e7Operator", { offset = 2 })
check("error prefix", "inferred_error: !i32", "!", "e7Operator")
check("optional type prefix", "optional: ?i32", "?", "e7Operator")
check("try postfix", "ret value?", "?", "e7Operator")
check("equality", "elif value == 0", "==", "e7Operator")
check("inequality", "a != b xor a >= b", "!=", "e7Operator")
check("greater-or-equal", "a != b xor a >= b", ">=", "e7Operator")
check("comparison less-than", "if value < 0", "<", "e7Operator")
check("reference", "pub dot <- (a: &Vec3", "&", "e7Operator")
check("pattern or", 'Red | Green: "cool"', "|", "e7Operator")
check("multiplication", "ret a.x * b.x", "*", "e7Operator")
check("remainder", "remainder <- a % b", "%", "e7Operator")
check("compound add", "entry.position += entry.velocity", "+=", "e7Operator")

-- delimiters
check("path separator", "use crate::ecs::World;", "::", "e7Delimiter")
check("field dot is a delimiter", "entry.position += entry.velocity", ".", "e7Delimiter")
check("member colon is a delimiter", "pub id: u64", ":", "e7Delimiter")
check("paren delimiter", "print_line(body.id)", "(", "e7Delimiter")
check("brace delimiter", "pub Vec3 <- struct {", "{", "e7Delimiter")
check("bracket delimiter", "matrix: map[str, i32]", "[", "e7Delimiter")
check("comma delimiter", "pub dot <- (a: &Vec3, b: &Vec3) -> f32", ",", "e7Delimiter")
check("close paren delimiter", "@derive(Debug, Clone)", ")", "e7Delimiter")
check("close bracket delimiter", "matrix: map[str, i32]", "]", "e7Delimiter")
check("close brace delimiter", "    }", "}", "e7Delimiter")
check("semicolon delimiter", "use super::math::*;", ";", "e7Delimiter")
check("addition", "ret a.x * b.x", "+", "e7Operator")
check("division", "quotient <- a / b", "/", "e7Operator")
check("compound subtract", "counter -= 1", "-=", "e7Operator")

-- type of code inside strings/comments must not leak
check("keyword-like word in comment", "# engine7 kitchen sink", "kitchen", "e7Comment")


-- ---------------------------------------------------------------------------
-- Extension detection: .tri is canonical; .e7 and .engine7 are aliases.
-- ---------------------------------------------------------------------------
for _, extension in ipairs({ ".tri", ".e7", ".engine7" }) do
  local alias_file = vim.fn.tempname() .. extension
  vim.fn.writefile({ "pub Example <- struct:", "    name: str" }, alias_file)
  local ok_alias, err_alias = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(alias_file))
  assertions = assertions + 1
  if not ok_alias then
    failures[#failures + 1] = string.format(
      "FAIL [%s detection] could not edit a %s file: %s",
      extension, extension, tostring(err_alias))
  elseif vim.bo.filetype ~= "engine7" then
    failures[#failures + 1] = string.format(
      "FAIL [%s detection] expected engine7, got %q", extension, vim.bo.filetype)
  end
  pcall(vim.cmd, "bwipeout!")
  os.remove(alias_file)
end


-- ---------------------------------------------------------------------------
-- Scratch-buffer edge cases: heuristics across contexts.
-- ---------------------------------------------------------------------------
local scratch = {
  [1] = "if(x)",
  [2] = "while(x)",
  [3] = "match(x)",
  [4] = 's <- "a # b"',
  [5] = 's <- "if true"',
  [6] = '# "quoted" and 123',
  [7] = "x.dot(1)",
  [8] = "trait drawable;",
  [9] = "a..b",
  [10] = "foo.exe(1)",
  [11] = "a <= b",
  [12] = "xi32 <- 1",
  [13] = "i32x <- 1",
  [14] = "i32 <- 1",
}
local scratch_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(scratch_buf, 0, -1, false, scratch)
vim.api.nvim_set_current_buf(scratch_buf)
vim.bo[scratch_buf].filetype = "engine7"
vim.cmd("setlocal syntax=engine7")

local function sgroup(lnum, col)
  local id = vim.fn.synID(lnum, col, 0)
  local name = vim.fn.synIDattr(id, "name")
  return name == "" and "<none>" or name
end

local function scheck(label, lnum, col, expected)
  assertions = assertions + 1
  local actual = sgroup(lnum, col)
  if actual ~= expected then
    failures[#failures + 1] = string.format(
      "FAIL [%s] scratch line %d col %d: expected %s, got %s\n      source: %s",
      label, lnum, col, expected, actual, scratch[lnum])
  end
end

-- Keywords immediately followed by '(' must stay keywords, not calls.
scheck("keyword if before paren", 1, 1, "e7Conditional")
scheck("keyword while before paren", 2, 1, "e7Repeat")
scheck("keyword match before paren", 3, 1, "e7Conditional")
scheck("delimiter after keyword", 1, 3, "e7Delimiter")
-- '#' must not start a comment inside a string.
scheck("string starting", 4, 6, "e7String")
scheck("hash inside string", 4, 9, "e7String")
scheck("body char inside string", 4, 11, "e7String")
-- Keywords inside a string stay string.
scheck("keyword-looking body in string", 5, 7, "e7String")
scheck("boolean-looking body in string", 5, 10, "e7String")
-- Strings and numbers inside a comment stay comment.
scheck("quote inside comment", 6, 3, "e7Comment")
scheck("keyword inside comment", 6, 12, "e7Comment")
scheck("number inside comment", 6, 16, "e7Comment")
-- A field access after '.' wins over a call name.
scheck("field after dot beats call", 7, 3, "e7Field")
scheck("number argument", 7, 7, "e7Number")
-- Lowercase name after 'trait' is a type.
scheck("lowercase trait name", 8, 7, "e7Type")
scheck("trait keyword", 8, 1, "e7Keyword")
-- The second dot of a range is an operator, not a field mark.
scheck("range in scratch", 9, 2, "e7Operator")
scheck("range target is not a field", 9, 4, "<none>")
-- Receivers before '.' are not call names; the field after '.' is.
scheck("receiver is not a call", 10, 1, "<none>")
scheck("field after receiver", 10, 5, "e7Field")
scheck("less-or-equal operator", 11, 3, "e7Operator")
scheck("primitive type standalone", 14, 1, "e7Type")
scheck("no primitive inside identifier prefix", 12, 2, "<none>")
scheck("no primitive inside identifier suffix", 13, 1, "<none>")


-- ---------------------------------------------------------------------------
-- Report.
-- ---------------------------------------------------------------------------
io.write(string.format("%d assertions, %d failures\n", assertions, #failures))
if #failures > 0 then
  io.write(table.concat(failures, "\n"), "\n")
  io.stdout:flush()
  vim.cmd("cquit 1")
end
io.stdout:flush()
vim.cmd("qa!")
