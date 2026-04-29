-- Headless regression check for alias dot-completion in dbee LSP.

vim.env.XDG_STATE_HOME = vim.fn.tempname()
vim.fn.mkdir(vim.env.XDG_STATE_HOME, "p")

local server = require("dbee.lsp.server")
local SchemaCache = require("dbee.lsp.schema_cache")

local function fail(msg)
  print("LSP_ALIAS_FATAL=true")
  print("LSP_ALIAS_FAIL=" .. msg)
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

local cache = SchemaCache:new(fake_handler, "test-alias")
cache:build_from_metadata_rows({
  { schema_name = "FUSION", table_name = "sas_principals", obj_type = "table" },
  { schema_name = "FUSION", table_name = "sas_policies", obj_type = "table" },
  { schema_name = "FUSION", table_name = "sas_queues", obj_type = "table" },
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
vim.api.nvim_buf_set_name(bufnr, "/tmp/dbee-alias-completion.sql")
local uri = vim.uri_from_bufnr(bufnr)

local function request_completion(line_text, trigger_char)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line_text })
  local params = {
    textDocument = { uri = uri },
    position = { line = 0, character = #line_text },
  }
  if trigger_char then
    params.context = { triggerCharacter = trigger_char }
  end

  local done = false
  local response = nil
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

local function has_label(items, label)
  for _, item in ipairs(items or {}) do
    if item.label == label then
      return true
    end
  end
  return false
end

local pre_line = "select * from sas_principals sp where sp"
local pre = request_completion(pre_line, ".")
local post = request_completion(pre_line .. ".")

assert_eq("pre complete", pre.isIncomplete, false)
assert_eq("post complete", post.isIncomplete, false)

local pre_has_principal = has_label(pre.items, "PRINCIPAL_ID")
local pre_has_policy = has_label(pre.items, "POLICY_ID")
local post_has_principal = has_label(post.items, "PRINCIPAL_ID")
local post_has_policy = has_label(post.items, "POLICY_ID")

local cold_line = "select * from sas_queues sq where sq."
local cold = request_completion(cold_line)
assert_eq("cold first incomplete", cold.isIncomplete, true)
assert_eq("cold first empty", #cold.items, 0)
deliver(async_calls[#async_calls], {
  { name = "QUEUE_ID", type = "NUMBER" },
  { name = "QUEUE_NAME", type = "VARCHAR2" },
})
local warm = request_completion(cold_line)
assert_eq("warm complete", warm.isIncomplete, false)
assert_true("warm queue labels", has_label(warm.items, "QUEUE_ID"))

print("LSP_ALIAS_PRE_ITEMS=" .. tostring(#pre.items))
print("LSP_ALIAS_POST_ITEMS=" .. tostring(#post.items))
print("LSP_ALIAS_PRE_HAS_PRINCIPAL=" .. tostring(pre_has_principal))
print("LSP_ALIAS_PRE_HAS_POLICY=" .. tostring(pre_has_policy))
print("LSP_ALIAS_POST_HAS_PRINCIPAL=" .. tostring(post_has_principal))
print("LSP_ALIAS_POST_HAS_POLICY=" .. tostring(post_has_policy))
print("LSP_ALIAS_FIRST_INCOMPLETE=true")
print("LSP_ALIAS_WARM_LABELS=true")
assert_true("no sync fetch", not sync_fetch_called)
print("LSP_ALIAS_NO_SYNC_FETCH=true")

if not pre_has_principal or pre_has_policy or not post_has_principal or post_has_policy then
  fail("cache-hit alias labels incorrect")
end

vim.cmd("qa!")
