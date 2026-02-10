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

local oracle_script = table.concat({
  "BEGIN",
  "  DBMS_OUTPUT.PUT_LINE('hello');",
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

local generic_script = "select 1; select 'a; b'; select 2;"
local generic_queries = splitter.split(generic_script, { adapter_type = "postgres" })
if not assert_eq(#generic_queries, 3, "generic_query_count") then
  return
end
if not assert_eq(generic_queries[2], "select 'a; b';", "generic_quote_split") then
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

print("SPLITTER_ORACLE_COUNT=" .. tostring(#oracle_queries))
print("SPLITTER_GENERIC_COUNT=" .. tostring(#generic_queries))
print("SPLITTER_CREATE_COUNT=" .. tostring(#create_queries))

vim.cmd("qa!")
