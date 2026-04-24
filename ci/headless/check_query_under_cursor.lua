-- Headless regression tests for dbee.utils.query_under_cursor fallback behavior.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=/path/to/nvim-dbee" \
--   -c "luafile ci/headless/check_query_under_cursor.lua"

local utils = require "dbee.utils"
local original_get_parser = vim.treesitter.get_parser
local original_get_node_text = vim.treesitter.get_node_text

-- Simulate a parser result that incorrectly drops "ALTER SESSION" and only
-- returns "SET ...". Oracle mode must bypass this path.
do
  local fake_node = {}
  function fake_node:type()
    return "statement"
  end
  function fake_node:range()
    return 0, 14, 0, 47
  end
  function fake_node:next_named_sibling()
    return nil
  end

  local fake_root = {}
  function fake_root:iter_children()
    local emitted = false
    return function()
      if emitted then
        return nil
      end
      emitted = true
      return fake_node
    end
  end

  local fake_tree = {}
  function fake_tree:root()
    return fake_root
  end

  local fake_parser = {}
  function fake_parser:parse()
    return { fake_tree }
  end

  vim.treesitter.get_parser = function()
    return fake_parser
  end
  vim.treesitter.get_node_text = function()
    return "SET NLS_DATE_FORMAT = 'YYYY-MM-DD';"
  end
end


local function fail(name, got, want)
  print("QUC_ASSERT_FAIL=" .. name .. ":" .. tostring(got) .. "!=" .. tostring(want))
  vim.cmd "cquit 1"
end

local function assert_eq(name, got, want)
  if got ~= want then
    fail(name, got, want)
    return false
  end
  return true
end

local function assert_range(name, got_start, got_end, want_start, want_end)
  if got_start ~= want_start or got_end ~= want_end then
    fail(name, string.format("%s:%s", tostring(got_start), tostring(got_end)), string.format("%s:%s", tostring(want_start), tostring(want_end)))
    return false
  end
  return true
end

local function run_case(name, lines, cursor_row_1based, cursor_col_0based, want_query, want_start, want_end, opts)
  opts = opts or { adapter_type = "oracle" }
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.bo[bufnr].filetype = "sql"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { cursor_row_1based, cursor_col_0based })

  local query, srow, _, erow = utils.query_under_cursor(bufnr, opts)
  if not assert_eq(name .. "_query", query, want_query) then
    return false
  end
  if not assert_range(name .. "_range", srow, erow, want_start, want_end) then
    return false
  end

  vim.api.nvim_buf_delete(bufnr, { force = true })
  return true
end

if
  not run_case(
    "oracle_bypass_bad_treesitter",
    {
      "ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD';",
      "SELECT SYSDATE FROM DUAL;",
    },
    1,
    0,
    "ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD'",
    0,
    0,
    { adapter_type = "oracle" }
  )
then
  return
end

-- Force fallback path for deterministic splitter behavior in remaining tests.
vim.treesitter.get_parser = function()
  error "forced fallback"
end

if
  not run_case(
    "alter_select_row1",
    {
      "ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD';",
      "SELECT SYSDATE FROM DUAL;",
    },
    1,
    0,
    "ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD'",
    0,
    0
  )
then
  return
end

if
  not run_case(
    "alter_select_row2",
    {
      "ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD';",
      "SELECT SYSDATE FROM DUAL;",
    },
    2,
    0,
    "SELECT SYSDATE FROM DUAL",
    1,
    1
  )
then
  return
end

if
  not run_case(
    "indented_alter_row1_cursor_at_indent",
    {
      "    ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-DD-MM';",
      "    SELECT SYSDATE FROM DUAL;",
    },
    1,
    0,
    "ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-DD-MM'",
    0,
    0
  )
then
  return
end

if
  not run_case(
    "indented_alter_row2_cursor_at_indent",
    {
      "    ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-DD-MM';",
      "    SELECT SYSDATE FROM DUAL;",
    },
    2,
    0,
    "SELECT SYSDATE FROM DUAL",
    1,
    1
  )
then
  return
end

if
  not run_case(
    "single_line_two_statements_first",
    {
      "SELECT 1 FROM dual; SELECT 2 FROM dual;",
    },
    1,
    0,
    "SELECT 1 FROM dual",
    0,
    0
  )
then
  return
end

if
  not run_case(
    "single_line_two_statements_second",
    {
      "SELECT 1 FROM dual; SELECT 2 FROM dual;",
    },
    1,
    25,
    "SELECT 2 FROM dual",
    0,
    0
  )
then
  return
end

if
  not run_case(
    "indented_plsql_row1_cursor_at_indent",
    {
      "    BEGIN",
      "      DBMS_OUTPUT.PUT_LINE('hello');",
      "    END;",
      "    /",
      "    SELECT 1 FROM dual;",
    },
    1,
    0,
    "BEGIN\n      DBMS_OUTPUT.PUT_LINE('hello');\n    END",
    0,
    2
  )
then
  return
end

if
  not run_case(
    "indented_plsql_row5_cursor_at_indent",
    {
      "    BEGIN",
      "      DBMS_OUTPUT.PUT_LINE('hello');",
      "    END;",
      "    /",
      "    SELECT 1 FROM dual;",
    },
    5,
    0,
    "SELECT 1 FROM dual",
    4,
    4
  )
then
  return
end

if
  not run_case(
    "plsql_then_select_row1",
    {
      "BEGIN",
      "  DBMS_OUTPUT.PUT_LINE('hello');",
      "END;",
      "/",
      "SELECT 1 FROM dual;",
    },
    1,
    0,
    "BEGIN\n  DBMS_OUTPUT.PUT_LINE('hello');\nEND",
    0,
    2
  )
then
  return
end

if
  not run_case(
    "plsql_then_select_row5",
    {
      "BEGIN",
      "  DBMS_OUTPUT.PUT_LINE('hello');",
      "END;",
      "/",
      "SELECT 1 FROM dual;",
    },
    5,
    0,
    "SELECT 1 FROM dual",
    4,
    4
  )
then
  return
end

print "QUC_OK=1"
vim.treesitter.get_parser = original_get_parser
vim.treesitter.get_node_text = original_get_node_text
vim.cmd "qa!"
