-- Headless regression tests for dbee.variables.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=/path/to/nvim-dbee" \
--   -c "luafile ci/headless/check_variables.lua"

local variables = require("dbee.variables")

local function fail(msg)
  print("VARIABLES_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local function assert_eq(actual, expected, name)
  if actual ~= expected then
    fail(name .. ":" .. tostring(actual) .. "!=" .. tostring(expected))
    return false
  end
  return true
end

local function assert_true(value, name)
  if not value then
    fail(name .. ":expected_true")
    return false
  end
  return true
end

local base_query = table.concat({
  "SELECT :id FROM dual;",
  "SELECT '&name' FROM dual;",
  "-- :ignored_bind",
  "/* &ignored_sub */",
  'SELECT "A&B" FROM dual;',
}, "\n")

local tokens = variables.collect(base_query, { adapter_type = "oracle" })
if not assert_eq(#tokens, 2, "collect_count") then
  return
end
if not assert_eq(tokens[1].key, "bind:id", "collect_bind_key") then
  return
end
if not assert_eq(tokens[2].key, "substitution:name", "collect_sub_key") then
  return
end

local provided_resolved, provided_err = variables.resolve(base_query, {
  adapter_type = "oracle",
  values = {
    ["bind:id"] = "42",
    ["substitution:name"] = "ALICE",
  },
})
if provided_err then
  fail("resolve_with_values_err:" .. tostring(provided_err))
  return
end
if not assert_true(provided_resolved:find("SELECT 42 FROM dual;", 1, true) ~= nil, "resolve_bind_value") then
  return
end
if not assert_true(provided_resolved:find("SELECT 'ALICE' FROM dual;", 1, true) ~= nil, "resolve_sub_value") then
  return
end
if not assert_true(provided_resolved:find(":ignored_bind", 1, true) ~= nil, "resolve_comment_untouched") then
  return
end

local postgres_tokens = variables.collect(base_query, { adapter_type = "postgres" })
if not assert_eq(#postgres_tokens, 0, "non_oracle_collect_empty") then
  return
end
local postgres_resolved, postgres_err = variables.resolve(base_query, { adapter_type = "postgres" })
if postgres_err then
  fail("non_oracle_resolve_err:" .. tostring(postgres_err))
  return
end
if not assert_eq(postgres_resolved, base_query, "non_oracle_resolve_same") then
  return
end

local saved_ui_input = vim.ui.input
local saved_snacks_input = package.loaded["snacks.input"]

local prompt_order = {}
local answers = { "77", "BOB" }
vim.ui.input = function(opts, cb)
  prompt_order[#prompt_order + 1] = opts.prompt or ""
  cb(answers[#prompt_order])
end
package.loaded["snacks.input"] = nil

local prompted_resolved, prompted_err = variables.resolve("SELECT :id FROM dual; SELECT '&name' FROM dual;", {
  adapter_type = "oracle",
})

vim.ui.input = saved_ui_input
package.loaded["snacks.input"] = saved_snacks_input

if prompted_err then
  fail("prompted_resolve_err:" .. tostring(prompted_err))
  return
end
if not assert_eq(#prompt_order, 2, "prompt_order_count") then
  return
end
if not assert_true(prompt_order[1]:find("Bind :id", 1, true) ~= nil, "prompt_order_bind") then
  return
end
if not assert_true(prompt_order[2]:find("Substitute &name", 1, true) ~= nil, "prompt_order_sub") then
  return
end
if not assert_eq(prompted_resolved, "SELECT 77 FROM dual; SELECT 'BOB' FROM dual;", "prompted_resolve_value") then
  return
end

local cancel_saved_ui_input = vim.ui.input
local cancel_saved_snacks_input = package.loaded["snacks.input"]
vim.ui.input = function(_, cb)
  cb(nil)
end
package.loaded["snacks.input"] = nil

local canceled_resolved, canceled_err = variables.resolve("SELECT :id FROM dual;", {
  adapter_type = "oracle",
})

vim.ui.input = cancel_saved_ui_input
package.loaded["snacks.input"] = cancel_saved_snacks_input

if canceled_resolved ~= nil then
  fail("cancel_expected_nil_resolved")
  return
end
if not assert_true(type(canceled_err) == "string" and canceled_err:find("canceled", 1, true) ~= nil, "cancel_err") then
  return
end

local snacks_saved_ui_input = vim.ui.input
local snacks_saved_snacks_input = package.loaded["snacks.input"]
local snacks_called = false
local ui_called = false
package.loaded["snacks.input"] = {
  input = function(opts, cb)
    snacks_called = true
    cb("99")
  end,
}
vim.ui.input = function(_, cb)
  ui_called = true
  cb("0")
end

local snacks_resolved, snacks_err = variables.resolve("SELECT :id FROM dual;", {
  adapter_type = "oracle",
})

vim.ui.input = snacks_saved_ui_input
package.loaded["snacks.input"] = snacks_saved_snacks_input

if snacks_err then
  fail("snacks_resolve_err:" .. tostring(snacks_err))
  return
end
if not assert_true(snacks_called, "snacks_called") then
  return
end
if ui_called then
  fail("ui_input_should_not_be_called_when_snacks_available")
  return
end
if not assert_eq(snacks_resolved, "SELECT 99 FROM dual;", "snacks_resolved_value") then
  return
end

print("VARIABLES_COLLECT_COUNT=" .. tostring(#tokens))
print("VARIABLES_PROMPT_ORDER_COUNT=" .. tostring(#prompt_order))
print("VARIABLES_SNACKS_CALLED=" .. tostring(snacks_called))

vim.cmd("qa!")
