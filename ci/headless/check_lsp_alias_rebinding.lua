-- Headless regression check for alias rebinding in SQL completion context.

vim.env.XDG_STATE_HOME = vim.fn.tempname()
vim.fn.mkdir(vim.env.XDG_STATE_HOME, "p")

local server = require("dbee.lsp.server")
local SchemaCache = require("dbee.lsp.schema_cache")

local function fail(msg)
  print("ALIAS_REBIND_FATAL=true")
  print("ALIAS_REBIND_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local function assert_true(label, value)
  if not value then
    fail(label .. ": expected true")
  end
end

local function assert_eq(label, actual, expected)
  if actual ~= expected then
    fail(label .. ": expected " .. vim.inspect(expected) .. " got " .. vim.inspect(actual))
  end
end

local async_calls = {}
local sync_fetch_called = false

local function fail_sync_fetch()
  sync_fetch_called = true
  error("sync column fetch must not be used by LSP completion")
end

local fake_handler = {
  connection_get_columns = fail_sync_fetch,
  get_authoritative_root_epoch = function()
    return 1
  end,
  connection_get_columns_async = function(_, conn_id, request_id, branch_id, root_epoch, opts)
    async_calls[#async_calls + 1] = {
      conn_id = conn_id,
      request_id = request_id,
      branch_id = branch_id,
      root_epoch = root_epoch,
      opts = opts,
    }
  end,
}

local cache = SchemaCache:new(fake_handler, "test-rebinding")
cache:build_from_metadata_rows({
  { schema_name = "FUSION", table_name = "sas_principals", obj_type = "table" },
  { schema_name = "FUSION", table_name = "sas_policies", obj_type = "table" },
  { schema_name = "FUSION", table_name = "sas_groups", obj_type = "table" },
})
cache:_store_columns("FUSION.sas_principals", {
  { name = "PRINCIPAL_ID", type = "NUMBER" },
  { name = "PRINCIPAL_NAME", type = "VARCHAR2" },
})
cache:_store_columns("FUSION.sas_policies", {
  { name = "POLICY_ID", type = "NUMBER" },
  { name = "POLICY_NAME", type = "VARCHAR2" },
})

local client = server.create(cache)({}, {})
local bufnr = vim.api.nvim_create_buf(false, true)
local lines = {
  "select * from sas_principals sp where sp.",
  "select * from sas_policies sp where sp.",
  "select * from sas_policies s where s.",
  "select * from sas_groups sp where sp.",
}
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
vim.api.nvim_buf_set_name(bufnr, "/tmp/dbee-alias-rebinding.sql")
local uri = vim.uri_from_bufnr(bufnr)

local function request_completion(line_index, opts)
  opts = opts or {}
  local line = opts.line_text or lines[line_index + 1]
  if opts.line_text then
    vim.api.nvim_buf_set_lines(bufnr, line_index, line_index + 1, false, { opts.line_text })
  end

  local done = false
  local response = nil
  local params = {
    textDocument = { uri = uri },
    position = { line = line_index, character = #line },
  }
  if opts.trigger_char then
    params.context = { triggerCharacter = opts.trigger_char }
  end

  client.request("textDocument/completion", params, function(err, result)
    response = { err = err, result = result }
    done = true
  end)

  vim.wait(1000, function()
    return done
  end, 20)

  if not response then
    fail("completion timeout")
  end
  if response.err then
    fail("completion error: " .. tostring(response.err))
  end
  return response.result
end

local function deliver(call, columns)
  cache:on_columns_loaded({
    conn_id = call.conn_id,
    request_id = call.request_id,
    branch_id = call.branch_id,
    root_epoch = call.root_epoch,
    kind = "columns",
    columns = columns,
  })
end

local function has_label(result, label)
  for _, item in ipairs((result and result.items) or {}) do
    if item.label == label then
      return true
    end
  end
  return false
end

local q1 = request_completion(0)
local q2 = request_completion(1)
local q3 = request_completion(2)
local q2_pre = request_completion(1, {
  line_text = "select * from sas_policies sp where sp",
  trigger_char = ".",
})

local q1_has_principal = has_label(q1, "PRINCIPAL_ID")
local q1_has_policy = has_label(q1, "POLICY_ID")
local q2_has_principal = has_label(q2, "PRINCIPAL_ID")
local q2_has_policy = has_label(q2, "POLICY_ID")
local q2_pre_has_principal = has_label(q2_pre, "PRINCIPAL_ID")
local q2_pre_has_policy = has_label(q2_pre, "POLICY_ID")
local q3_has_policy = has_label(q3, "POLICY_ID")

assert_eq("q1 complete", q1.isIncomplete, false)
assert_eq("q2 complete", q2.isIncomplete, false)
assert_eq("q3 complete", q3.isIncomplete, false)
assert_true("q1 principal", q1_has_principal)
assert_true("q1 no policy", not q1_has_policy)
assert_true("q2 no principal", not q2_has_principal)
assert_true("q2 policy", q2_has_policy)
assert_true("q2 pre no principal", not q2_pre_has_principal)
assert_true("q2 pre policy", q2_pre_has_policy)
assert_true("q3 policy", q3_has_policy)

local cold = request_completion(3)
assert_eq("cold rebind incomplete", cold.isIncomplete, true)
deliver(async_calls[#async_calls], {
  { name = "GROUP_ID", type = "NUMBER" },
  { name = "GROUP_NAME", type = "VARCHAR2" },
})
local warm = request_completion(3)
assert_eq("warm rebind complete", warm.isIncomplete, false)
assert_true("warm group labels", has_label(warm, "GROUP_ID"))
assert_true("warm no stale principal", not has_label(warm, "PRINCIPAL_ID"))

print("ALIAS_REBIND_Q1_PRINCIPAL=" .. tostring(q1_has_principal))
print("ALIAS_REBIND_Q1_POLICY=" .. tostring(q1_has_policy))
print("ALIAS_REBIND_Q2_PRINCIPAL=" .. tostring(q2_has_principal))
print("ALIAS_REBIND_Q2_POLICY=" .. tostring(q2_has_policy))
print("ALIAS_REBIND_Q2_PRE_PRINCIPAL=" .. tostring(q2_pre_has_principal))
print("ALIAS_REBIND_Q2_PRE_POLICY=" .. tostring(q2_pre_has_policy))
print("ALIAS_REBIND_Q3_POLICY=" .. tostring(q3_has_policy))
print("LSP_REBIND_FIRST_INCOMPLETE=true")
print("LSP_REBIND_WARM_LABELS=true")
assert_true("no sync fetch", not sync_fetch_called)
print("LSP_REBIND_NO_SYNC_FETCH=true")

vim.cmd("qa!")
