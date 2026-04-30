-- Headless checks for Phase 14 lazy schema-root LSP behavior.

vim.env.XDG_STATE_HOME = vim.fn.tempname()
vim.fn.mkdir(vim.env.XDG_STATE_HOME, "p")

package.preload["nio"] = package.preload["nio"] or function()
  return {}
end

local server = require("dbee.lsp.server")
local SchemaCache = require("dbee.lsp.schema_cache")
local schema_filter = require("dbee.schema_filter")

local function fail(msg)
  print("ARCH14_LSP_SCHEMA_FILTER_LAZY_FAIL=" .. msg)
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

local function has_label(items, label)
  for _, item in ipairs(items or {}) do
    if item.label == label then
      return true
    end
  end
  return false
end

local schema_object_calls = {}
local sync_fetch_called = false
local normalized = assert(schema_filter.normalize({
  include = { "app%" },
  exclude = { "app_tmp%" },
  lazy_per_schema = true,
}, "postgres"))

local fake_handler = {
  get_schema_filter_normalized = function()
    return normalized
  end,
  get_authoritative_root_epoch = function()
    return 7
  end,
  connection_get_columns = function()
    sync_fetch_called = true
    error("sync fetch must not be used by lazy schema-dot completion")
  end,
  connection_get_schema_objects_singleflight = function(_, opts)
    schema_object_calls[#schema_object_calls + 1] = vim.deepcopy(opts)
    return {
      epoch = 7,
      request_id = opts.request_id or 0,
      joined = false,
      queued = false,
    }
  end,
}

local cache = SchemaCache:new(fake_handler, "lazy-lsp")
cache:build_from_schemas({
  { name = "app" },
  { name = "app_tmp_shadow" },
})

local client = server.create(cache)({}, {})
local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(bufnr, "/tmp/dbee-lsp-lazy-schema.sql")
local uri = vim.uri_from_bufnr(bufnr)
local ns = server.diagnostic_namespace()

local function request_completion(line)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
  local done = false
  local response = nil
  client.request("textDocument/completion", {
    textDocument = { uri = uri },
    position = { line = 0, character = #line },
  }, function(err, result)
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

local first = request_completion("select * from app.")
assert_eq("schema-dot cold incomplete", first.isIncomplete, true)
assert_eq("schema-dot cold empty", #first.items, 0)
assert_eq("one schema object request", #schema_object_calls, 1)
assert_eq("schema object priority", schema_object_calls[1].priority, "lsp")
assert_eq("schema object schema", schema_object_calls[1].schema, "app")
assert_true("no sync fetch on cold schema-dot", not sync_fetch_called)

assert_true("schema objects applied", cache:on_schema_objects_loaded({
  conn_id = "lazy-lsp",
  root_epoch = 7,
  schema = "app",
  objects = {
    { type = "table", schema = "app", name = "accounts" },
    { type = "view", schema = "app", name = "account_view" },
  },
}))

local warm = request_completion("select * from app.")
assert_eq("schema-dot warm complete", warm.isIncomplete, false)
assert_true("schema-dot warm table", has_label(warm.items, "accounts"))
assert_true("schema-dot warm view", has_label(warm.items, "account_view"))
assert_eq("no duplicate schema request after warm", #schema_object_calls, 1)

cache:build_from_schemas({ { name = "app" } })
local preserved = request_completion("select * from app.")
assert_eq("schema-dot refresh preserves loaded branch", preserved.isIncomplete, false)
assert_true("schema-dot preserved table", has_label(preserved.items, "accounts"))
assert_eq("no request after schema-root refresh", #schema_object_calls, 1)

local function run_diagnostics(line)
  vim.diagnostic.set(ns, bufnr, {})
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
  client.notify("textDocument/didSave", {
    textDocument = { uri = uri },
  })
  vim.wait(100, function()
    return true
  end, 20)
  return vim.diagnostic.get(bufnr, { namespace = ns })
end

local unloaded_cache = SchemaCache:new(fake_handler, "lazy-lsp-unloaded")
unloaded_cache:build_from_schemas({ { name = "app" } })
local unloaded_client = server.create(unloaded_cache)({}, {})
local unloaded_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(unloaded_buf, "/tmp/dbee-lsp-lazy-unloaded.sql")
local unloaded_uri = vim.uri_from_bufnr(unloaded_buf)
vim.diagnostic.set(ns, unloaded_buf, {})
vim.api.nvim_buf_set_lines(unloaded_buf, 0, -1, false, { "select * from app.real_table" })
unloaded_client.notify("textDocument/didSave", {
  textDocument = { uri = unloaded_uri },
})
vim.wait(100, function()
  return true
end, 20)
assert_eq("active unloaded diagnostic suppressed", #vim.diagnostic.get(unloaded_buf, { namespace = ns }), 0)

local out_of_scope = run_diagnostics("select * from other_schema.accounts")
assert_eq("out-of-scope diagnostic count", #out_of_scope, 1)
assert_eq("out-of-scope severity", out_of_scope[1].severity, vim.diagnostic.severity.INFO)
assert_true("out-of-scope message", out_of_scope[1].message:find("outside this connection's scope", 1, true) ~= nil)

local missing = run_diagnostics("select * from app.missing_table")
assert_eq("loaded missing diagnostic count", #missing, 1)
assert_eq("loaded missing severity", missing[1].severity, vim.diagnostic.severity.WARN)
assert_eq("loaded missing message", missing[1].message, "Unknown table: app.missing_table")

client.terminate()
unloaded_client.terminate()

print("ARCH14_SCHEMA_CACHE_PARTIAL_INDEX_OK=true")
print("ARCH14_SCHEMA_FILTER_DOWNSTREAM_ALL_PASS=true")
print("ARCH14_LSP_SCHEMA_DOT_INCOMPLETE_OK=true")
print("ARCH14_LSP_SCHEMA_DOT_WARM_OK=true")
print("ARCH14_LSP_SCHEMA_DOT_NO_SYNC_FETCH=true")
print("ARCH14_OUT_OF_SCOPE_HINT_OK=true")
print("ARCH14_LSP_LAZY_UNLOADED_NO_FALSE_WARN=true")
print("ARCH14_LSP_ALL_PASS=true")

vim.fn.delete(vim.env.XDG_STATE_HOME, "rf")
vim.cmd("qa!")
