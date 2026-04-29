-- Headless regression check for schema-qualified alias dot-completion in dbee LSP.

vim.env.XDG_STATE_HOME = vim.fn.tempname()
vim.fn.mkdir(vim.env.XDG_STATE_HOME, "p")

local server = require("dbee.lsp.server")
local SchemaCache = require("dbee.lsp.schema_cache")

local function fail(msg)
  print("LSP_SCHEMA_ALIAS_FATAL=true")
  print("LSP_SCHEMA_ALIAS_FAIL=" .. msg)
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

local cache = SchemaCache:new(fake_handler, "test-schema-alias")
cache:build_from_metadata_rows({
  { schema_name = "FUSION", table_name = "SAS_ROLES", obj_type = "table" },
})

local client = server.create(cache)({}, {})
local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(bufnr, "/tmp/dbee-schema-qualified-alias.sql")
local uri = vim.uri_from_bufnr(bufnr)

local function request_completion(line_idx, line_text, trigger_char)
  vim.api.nvim_buf_set_lines(bufnr, line_idx, line_idx + 1, false, { line_text })
  local done = false
  local response = nil
  local params = {
    textDocument = { uri = uri },
    position = { line = line_idx, character = #line_text },
  }
  if trigger_char then
    params.context = { triggerCharacter = trigger_char }
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
  if type(response.result) ~= "table" or type(response.result.items) ~= "table" then
    fail("invalid completion result")
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
  for _, item in ipairs(items) do
    if item.label == label then
      return true
    end
  end
  return false
end

local d_line = "select * from fusion_opss.jps_dn d where d."
local d_first = request_completion(0, d_line)
assert_eq("d first incomplete", d_first.isIncomplete, true)
assert_eq("d first empty", #d_first.items, 0)
deliver(async_calls[#async_calls], {
  { name = "ENTRYID", type = "NUMBER" },
  { name = "DN", type = "VARCHAR2" },
})
local d_warm = request_completion(0, d_line)
assert_eq("d warm complete", d_warm.isIncomplete, false)
assert_true("d entryid", has_label(d_warm.items, "ENTRYID"))
assert_true("d no attrs", not has_label(d_warm.items, "JPS_DN_ENTRYID"))

local p_line = "select * from fusion_opss.jps_dn d join fusion_opss.jps_attrs p on p."
local p_first = request_completion(1, p_line)
assert_eq("p first incomplete", p_first.isIncomplete, true)
deliver(async_calls[#async_calls], {
  { name = "JPS_DN_ENTRYID", type = "NUMBER" },
  { name = "ATTRVAL", type = "VARCHAR2" },
})
local p_warm = request_completion(1, p_line)
assert_true("p attr", has_label(p_warm.items, "JPS_DN_ENTRYID"))
assert_true("p no dn entryid", not has_label(p_warm.items, "ENTRYID"))

local v_line = "select * from fusion_opss.jps_view v where v."
local view_first = request_completion(2, v_line)
assert_eq("view first incomplete", view_first.isIncomplete, true)
local table_probe = async_calls[#async_calls]
assert_eq("view table probe", table_probe.opts.materialization, "table")
deliver(table_probe, {})
local view_probe = async_calls[#async_calls]
assert_eq("view fallback probe", view_probe.opts.materialization, "view")
deliver(view_probe, {
  { name = "VIEW_COL", type = "VARCHAR2" },
})
local view_warm = request_completion(2, v_line)
assert_true("view fallback labels", has_label(view_warm.items, "VIEW_COL"))

print("LSP_SCHEMA_ALIAS_D_ENTRYID=true")
print("LSP_SCHEMA_ALIAS_D_JPS_DN_ENTRYID=false")
print("LSP_SCHEMA_ALIAS_P_ENTRYID=false")
print("LSP_SCHEMA_ALIAS_P_JPS_DN_ENTRYID=true")
print("LSP_SCHEMA_ALIAS_P_PRE_JPS_DN_ENTRYID=true")
print("LSP_SCHEMA_ALIAS_COLUMN_CALLS=" .. tostring(#async_calls))
print("LSP_SCHEMA_ALIAS_CALLED_JPS_DN=true")
print("LSP_SCHEMA_ALIAS_CALLED_JPS_ATTRS=true")
print("LSP_SCHEMA_ALIAS_FIRST_INCOMPLETE=true")
print("LSP_SCHEMA_ALIAS_ASYNC_CALLS=" .. tostring(#async_calls))
print("LSP_SCHEMA_ALIAS_WARM_LABELS=true")
assert_true("no sync fetch", not sync_fetch_called)
print("LSP_SCHEMA_ALIAS_NO_SYNC_FETCH=true")
print("LSP_SCHEMA_ALIAS_VIEW_FALLBACK_OK=true")

if sync_fetch_called then
  fail("sync fetch called")
end

vim.cmd("qa!")
