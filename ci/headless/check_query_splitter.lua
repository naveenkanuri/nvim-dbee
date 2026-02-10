-- Headless regression tests for dbee.query_splitter.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=/path/to/nui.nvim" \
--   --cmd "set rtp+=/path/to/nvim-dbee" \
--   -c "luafile ci/headless/check_query_splitter.lua"

local splitter = require("dbee.query_splitter")

local function assert_eq(actual, expected, name)
  if actual ~= expected then
    print("SPLITTER_ASSERT_FAIL=" .. name .. ":" .. tostring(actual) .. "!=" .. tostring(expected))
    vim.cmd("cquit 1")
    return false
  end
  return true
end

local function assert_true(value, name)
  if not value then
    print("SPLITTER_ASSERT_FAIL=" .. name .. ":expected_true")
    vim.cmd("cquit 1")
    return false
  end
  return true
end

local oracle_script = table.concat({
  "BEGIN",
  "  DBMS_OUTPUT.PUT_LINE('hello');",
  "",
  "  DBMS_OUTPUT.PUT_LINE('world');",
  "END;",
  "/",
  "SELECT * FROM dual;",
}, "\n")

local oracle_queries = splitter.split(oracle_script, { adapter_type = "oracle" })
if not assert_eq(#oracle_queries, 2, "oracle_query_count") then
  return
end
if not assert_eq(oracle_queries[1]:match("^BEGIN") and "BEGIN" or "", "BEGIN", "oracle_query_1_type") then
  return
end
if not assert_eq(oracle_queries[2], "SELECT * FROM dual;", "oracle_query_2_value") then
  return
end
if not assert_true(not oracle_queries[1]:find("\n/%s*$"), "oracle_block_does_not_contain_slash") then
  return
end
if not assert_true(oracle_queries[1]:find("world", 1, true) ~= nil, "oracle_blank_line_block_preserved") then
  return
end

local call_script = "CALL pkg_one.proc_one();\nCALL pkg_two.proc_two();"
local call_queries = splitter.split(call_script, { adapter_type = "oracle" })
if not assert_eq(#call_queries, 2, "oracle_call_split_count") then
  return
end

local oracle_anon_no_slash = table.concat({
  "BEGIN",
  "  DBMS_OUTPUT.PUT_LINE('a');",
  "END;",
  "",
  "BEGIN",
  "  DBMS_OUTPUT.PUT_LINE('b');",
  "END;",
  "",
  "SELECT 1 FROM dual;",
}, "\n")
local anon_no_slash_queries = splitter.split(oracle_anon_no_slash, { adapter_type = "oracle" })
if not assert_eq(#anon_no_slash_queries, 3, "oracle_anon_no_slash_count") then
  return
end
if not assert_eq(anon_no_slash_queries[1], "BEGIN\n  DBMS_OUTPUT.PUT_LINE('a');\nEND;", "oracle_anon_no_slash_first") then
  return
end
if not assert_eq(anon_no_slash_queries[2], "BEGIN\n  DBMS_OUTPUT.PUT_LINE('b');\nEND;", "oracle_anon_no_slash_second") then
  return
end
if not assert_eq(anon_no_slash_queries[3], "SELECT 1 FROM dual;", "oracle_anon_no_slash_third") then
  return
end

local generic_script = "select 1; select 'a; b'; select 2;"
local generic_queries = splitter.split(generic_script, { adapter_type = "postgres" })
if not assert_eq(#generic_queries, 3, "generic_query_count") then
  return
end
if not assert_eq(generic_queries[2], "select 'a; b';", "generic_quote_split") then
  return
end

local generic_comments = table.concat({
  "select 1; -- keep ; in comment ; ;",
  "/* block ; ; */",
  "select 2;",
}, "\n")
local generic_comment_queries = splitter.split(generic_comments, { adapter_type = "postgres" })
if not assert_eq(#generic_comment_queries, 2, "generic_comment_split_count") then
  return
end

local generic_double_quote = 'select "column;name" from dual; select 2;'
local generic_double_quote_queries = splitter.split(generic_double_quote, { adapter_type = "postgres" })
if not assert_eq(#generic_double_quote_queries, 2, "generic_double_quote_count") then
  return
end
if not assert_eq(generic_double_quote_queries[1], 'select "column;name" from dual;', "generic_double_quote_value") then
  return
end

local oracle_create = table.concat({
  "CREATE OR REPLACE PROCEDURE p_test AS",
  "BEGIN",
  "  NULL;",
  "END;",
  "/",
  "SELECT 1 FROM dual;",
}, "\n")

local create_queries = splitter.split(oracle_create, { adapter_type = "oracle" })
if not assert_eq(#create_queries, 2, "oracle_create_split_count") then
  return
end
if not assert_eq(create_queries[2], "SELECT 1 FROM dual;", "oracle_create_followup") then
  return
end

local begin_word_boundary = table.concat({
  "beginning_variable := 1;",
  "select 1 from dual;",
}, "\n")
local boundary_queries = splitter.split(begin_word_boundary, { adapter_type = "oracle" })
if not assert_eq(#boundary_queries, 2, "begin_word_boundary_count") then
  return
end

print("SPLITTER_ORACLE_COUNT=" .. tostring(#oracle_queries))
print("SPLITTER_GENERIC_COUNT=" .. tostring(#generic_queries))
print("SPLITTER_CREATE_COUNT=" .. tostring(#create_queries))
print("SPLITTER_CALL_COUNT=" .. tostring(#call_queries))
print("SPLITTER_ANON_NO_SLASH_COUNT=" .. tostring(#anon_no_slash_queries))
print("SPLITTER_GENERIC_COMMENT_COUNT=" .. tostring(#generic_comment_queries))
print("SPLITTER_BOUNDARY_COUNT=" .. tostring(#boundary_queries))

vim.cmd("qa!")
