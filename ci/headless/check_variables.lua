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

local trigger_query = table.concat({
  "CREATE OR REPLACE TRIGGER trg_test",
  "BEFORE UPDATE ON t_test",
  "FOR EACH ROW",
  "BEGIN",
  "  :NEW.status := :OLD.status;",
  "  INSERT INTO audit_log(id) VALUES (:user_bind);",
  "END;",
}, "\n")
local trigger_tokens = variables.collect(trigger_query, { adapter_type = "oracle" })
if not assert_eq(#trigger_tokens, 1, "trigger_collect_count") then
  return
end
if not assert_eq(trigger_tokens[1].key, "bind:user_bind", "trigger_collect_bind") then
  return
end
local trigger_resolved, trigger_err = variables.resolve(trigger_query, {
  adapter_type = "oracle",
  values = {
    ["bind:user_bind"] = "42",
  },
})
if trigger_err then
  fail("trigger_resolve_err:" .. tostring(trigger_err))
  return
end
if not assert_true(trigger_resolved:find(":NEW.status := :OLD.status;", 1, true) ~= nil, "trigger_pseudocol_preserved") then
  return
end
if not assert_true(trigger_resolved:find("VALUES (42);", 1, true) ~= nil, "trigger_bind_replaced") then
  return
end

local numeric_tokens = variables.collect("SELECT :1, :2, :id FROM dual;", { adapter_type = "oracle" })
if not assert_eq(#numeric_tokens, 1, "numeric_bind_ignored_count") then
  return
end
if not assert_eq(numeric_tokens[1].key, "bind:id", "numeric_bind_ignored_key") then
  return
end

local duplicate_tokens = variables.collect("SELECT &name, &&name, :id, :id FROM dual;", { adapter_type = "oracle" })
if not assert_eq(#duplicate_tokens, 2, "duplicate_token_dedupe_count") then
  return
end

local escaped_quote_tokens = variables.collect("SELECT 'x'' :ignored' AS v, :id FROM dual;", {
  adapter_type = "oracle",
})
if not assert_eq(#escaped_quote_tokens, 1, "escaped_quote_bind_count") then
  return
end
if not assert_eq(escaped_quote_tokens[1].key, "bind:id", "escaped_quote_bind_key") then
  return
end

local nested_comment_tokens = variables.collect(
  "/* outer :skip /* inner &skip */ still :skip */ SELECT :id FROM dual;",
  { adapter_type = "oracle" }
)
if not assert_eq(#nested_comment_tokens, 1, "nested_comment_collect_count") then
  return
end
if not assert_eq(nested_comment_tokens[1].key, "bind:id", "nested_comment_collect_key") then
  return
end

local empty_tokens = variables.collect("", { adapter_type = "oracle" })
if not assert_eq(#empty_tokens, 0, "empty_query_collect_count") then
  return
end
local empty_resolved, empty_err = variables.resolve("", { adapter_type = "oracle" })
if empty_err then
  fail("empty_query_resolve_err:" .. tostring(empty_err))
  return
end
if not assert_eq(empty_resolved, "", "empty_query_resolve_value") then
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

local exec_resolved, exec_opts, exec_err = variables.resolve_for_execute("SELECT :id FROM dual; SELECT '&name' FROM dual;", {
  adapter_type = "oracle",
  values = {
    ["bind:id"] = "42",
    ["substitution:name"] = "ALICE",
  },
})
if exec_err then
  fail("resolve_for_execute_err:" .. tostring(exec_err))
  return
end
if not assert_eq(exec_resolved, "SELECT :id FROM dual; SELECT 'ALICE' FROM dual;", "resolve_for_execute_query") then
  return
end
if not assert_true(exec_opts and exec_opts.binds and exec_opts.binds.id == "42", "resolve_for_execute_binds") then
  return
end

local unsafe_script_resolved, unsafe_script_opts, unsafe_script_err = variables.resolve_for_execute(
  "SELECT '&name' FROM dual;",
  {
    adapter_type = "oracle",
    values = {
      ["substitution:name"] = "foo; DROP TABLE bar",
    },
    reject_script_delimiters = true,
  }
)
if unsafe_script_resolved ~= nil or unsafe_script_opts ~= nil then
  fail("resolve_for_execute_unsafe_expected_nil")
  return
end
if
  not assert_true(
    type(unsafe_script_err) == "string" and unsafe_script_err:find("unsafe substitution value", 1, true) ~= nil,
    "resolve_for_execute_unsafe_error"
  )
then
  return
end

local unsafe_newline_resolved, unsafe_newline_opts, unsafe_newline_err = variables.resolve_for_execute(
  "SELECT '&name' FROM dual;",
  {
    adapter_type = "oracle",
    values = {
      ["substitution:name"] = "foo\nbar",
    },
    reject_script_delimiters = true,
  }
)
if unsafe_newline_resolved ~= nil or unsafe_newline_opts ~= nil then
  fail("resolve_for_execute_unsafe_newline_expected_nil")
  return
end
if
  not assert_true(
    type(unsafe_newline_err) == "string" and unsafe_newline_err:find("newline", 1, true) ~= nil,
    "resolve_for_execute_unsafe_newline_error"
  )
then
  return
end

local bind_opts_filtered = variables.bind_opts_for_query("SELECT :id FROM dual;", {
  adapter_type = "oracle",
  binds = { id = "42", other = "11" },
})
if not assert_true(bind_opts_filtered and bind_opts_filtered.binds and bind_opts_filtered.binds.id == "42", "bind_opts_for_query_match") then
  return
end
if not assert_true(bind_opts_filtered.binds.other == nil, "bind_opts_for_query_filter") then
  return
end
local bind_opts_none = variables.bind_opts_for_query("SELECT 1 FROM dual;", {
  adapter_type = "oracle",
  binds = { id = "42" },
})
if not assert_eq(bind_opts_none, nil, "bind_opts_for_query_none") then
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
local postgres_exec_resolved, postgres_exec_opts, postgres_exec_err = variables.resolve_for_execute(base_query, {
  adapter_type = "postgres",
})
if postgres_exec_err then
  fail("non_oracle_resolve_for_execute_err:" .. tostring(postgres_exec_err))
  return
end
if not assert_eq(postgres_exec_resolved, base_query, "non_oracle_resolve_for_execute_same") then
  return
end
if not assert_eq(postgres_exec_opts, nil, "non_oracle_resolve_for_execute_opts_nil") then
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

local async_provider_saved_ui_input = vim.ui.input
local async_provider_saved_snacks_input = package.loaded["snacks.input"]
vim.ui.input = function(_, cb)
  vim.schedule(function()
    cb("88")
  end)
end
package.loaded["snacks.input"] = nil

local async_provider_resolved, async_provider_err = variables.resolve("SELECT :id FROM dual;", {
  adapter_type = "oracle",
  timeout_ms = 1000,
})

vim.ui.input = async_provider_saved_ui_input
package.loaded["snacks.input"] = async_provider_saved_snacks_input

if async_provider_err then
  fail("async_provider_resolve_err:" .. tostring(async_provider_err))
  return
end
if not assert_eq(async_provider_resolved, "SELECT 88 FROM dual;", "async_provider_resolve_value") then
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

local empty_saved_ui_input = vim.ui.input
local empty_saved_snacks_input = package.loaded["snacks.input"]
vim.ui.input = function(_, cb)
  cb("")
end
package.loaded["snacks.input"] = nil

local empty_prompt_resolved, empty_prompt_err = variables.resolve("SELECT :id FROM dual;", {
  adapter_type = "oracle",
})

vim.ui.input = empty_saved_ui_input
package.loaded["snacks.input"] = empty_saved_snacks_input

if empty_prompt_resolved ~= nil then
  fail("empty_prompt_expected_nil_resolved")
  return
end
if not assert_true(type(empty_prompt_err) == "string" and empty_prompt_err:find("empty", 1, true) ~= nil, "empty_prompt_err") then
  return
end

local ui_saved_input = vim.ui.input
local ui_saved_snacks_input = package.loaded["snacks.input"]
local ui_called = false
package.loaded["snacks.input"] = {
  input = function(_, cb)
    cb("0")
  end,
}
vim.ui.input = function(_, cb)
  ui_called = true
  cb("99")
end

local ui_resolved, ui_err = variables.resolve("SELECT :id FROM dual;", {
  adapter_type = "oracle",
})

vim.ui.input = ui_saved_input
package.loaded["snacks.input"] = ui_saved_snacks_input

if ui_err then
  fail("ui_resolve_err:" .. tostring(ui_err))
  return
end
if not assert_true(ui_called, "ui_called") then
  return
end
if not assert_eq(ui_resolved, "SELECT 99 FROM dual;", "ui_resolved_value") then
  return
end

local callable_saved_ui_input = vim.ui.input
local callable_saved_snacks_input = package.loaded["snacks.input"]
local callable_snacks_called = false
vim.ui.input = nil
package.loaded["snacks.input"] = setmetatable({}, {
  __call = function(_, _, cb)
    callable_snacks_called = true
    cb("55")
  end,
})

local callable_resolved, callable_err = variables.resolve("SELECT :id FROM dual;", {
  adapter_type = "oracle",
})

vim.ui.input = callable_saved_ui_input
package.loaded["snacks.input"] = callable_saved_snacks_input

if callable_err then
  fail("callable_snacks_resolve_err:" .. tostring(callable_err))
  return
end
if not assert_true(callable_snacks_called, "callable_snacks_called") then
  return
end
if not assert_eq(callable_resolved, "SELECT 55 FROM dual;", "callable_snacks_resolved") then
  return
end

local fb_saved_ui_input = vim.ui.input
local fb_saved_snacks_input = package.loaded["snacks.input"]
local fallback_snacks_called = false
vim.ui.input = nil
package.loaded["snacks.input"] = {
  input = function(_, cb)
    fallback_snacks_called = true
    cb("77")
  end,
}

local fallback_resolved, fallback_err = variables.resolve("SELECT :id FROM dual;", {
  adapter_type = "oracle",
})

vim.ui.input = fb_saved_ui_input
package.loaded["snacks.input"] = fb_saved_snacks_input

if fallback_err then
  fail("fallback_resolve_err:" .. tostring(fallback_err))
  return
end
if not assert_true(fallback_snacks_called, "fallback_snacks_called") then
  return
end
if not assert_eq(fallback_resolved, "SELECT 77 FROM dual;", "fallback_resolved_value") then
  return
end

local async_done = false
local async_resolved, async_err = nil, nil
variables.resolve_async("SELECT :id FROM dual;", {
  adapter_type = "oracle",
  prompt_async_fn = function(_, cb)
    cb("", nil)
  end,
}, function(resolved, err)
  async_resolved = resolved
  async_err = err
  async_done = true
end)

if not vim.wait(1000, function()
  return async_done
end, 20) then
  fail("resolve_async_timeout")
  return
end
if async_resolved ~= nil then
  fail("resolve_async_empty_expected_nil_resolved")
  return
end
if not assert_true(type(async_err) == "string" and async_err:find("empty", 1, true) ~= nil, "resolve_async_empty_err") then
  return
end

local exec_async_done = false
local exec_async_query, exec_async_opts, exec_async_err = nil, nil, nil
variables.resolve_for_execute_async("SELECT :id FROM dual; SELECT '&name' FROM dual;", {
  adapter_type = "oracle",
  prompt_async_fn = function(token, cb)
    if token.kind == "bind" then
      cb("77", nil)
    else
      cb("BOB", nil)
    end
  end,
}, function(resolved_query, opts, err)
  exec_async_query = resolved_query
  exec_async_opts = opts
  exec_async_err = err
  exec_async_done = true
end)

if not vim.wait(1000, function()
  return exec_async_done
end, 20) then
  fail("resolve_for_execute_async_timeout")
  return
end
if exec_async_err then
  fail("resolve_for_execute_async_err:" .. tostring(exec_async_err))
  return
end
if not assert_eq(exec_async_query, "SELECT :id FROM dual; SELECT 'BOB' FROM dual;", "resolve_for_execute_async_query") then
  return
end
if not assert_true(exec_async_opts and exec_async_opts.binds and exec_async_opts.binds.id == "77", "resolve_for_execute_async_binds") then
  return
end

print("VARIABLES_COLLECT_COUNT=" .. tostring(#tokens))
print("VARIABLES_PROMPT_ORDER_COUNT=" .. tostring(#prompt_order))
print("VARIABLES_UI_CALLED=" .. tostring(ui_called))
print("VARIABLES_FALLBACK_SNACKS_CALLED=" .. tostring(fallback_snacks_called))
print("VARIABLES_CALLABLE_SNACKS_CALLED=" .. tostring(callable_snacks_called))

vim.cmd("qa!")
