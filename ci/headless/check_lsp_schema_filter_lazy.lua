-- Headless checks for Phase 14 lazy schema-root LSP behavior.

vim.env.XDG_STATE_HOME = vim.fn.tempname()
vim.fn.mkdir(vim.env.XDG_STATE_HOME, "p")

package.preload["nio"] = package.preload["nio"] or function()
  return {}
end

local server = require("dbee.lsp.server")
local lsp_init = require("dbee.lsp")
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

local queue_full_handler = {
  get_schema_filter_normalized = function()
    return normalized
  end,
  get_authoritative_root_epoch = function()
    return 7
  end,
  connection_get_schema_objects_singleflight = function()
    return { error_kind = "queue_full" }
  end,
}

local transport_fail_handler = {
  get_schema_filter_normalized = function()
    return normalized
  end,
  get_authoritative_root_epoch = function()
    return 7
  end,
  connection_get_schema_objects_singleflight = function()
    return { error_kind = "transport" }
  end,
}

local cache = SchemaCache:new(fake_handler, "lazy-lsp")
cache:build_from_schemas({
  { name = "app" },
  { name = "app_tmp_shadow" },
})

local defense_cache = SchemaCache:new(fake_handler, "lazy-lsp-defense")
defense_cache:build_from_structure({
  {
    type = "schema",
    schema = "app",
    name = "app",
    children = {
      { type = "table", schema = "app", name = "kept_table" },
    },
  },
  {
    type = "schema",
    schema = "other",
    name = "other",
    children = {
      { type = "table", schema = "other", name = "filtered_table" },
    },
  },
})
assert_true("defense kept schema", defense_cache:find_schema("app") ~= nil)
assert_true("defense pruned schema", defense_cache:find_schema("other") == nil)
assert_true("defense pruned table", defense_cache:find_table("filtered_table") == nil)

defense_cache:build_from_metadata_rows({
  { schema_name = "app", table_name = "kept_metadata", obj_type = "table" },
  { schema_name = "other", table_name = "filtered_metadata", obj_type = "table" },
})
assert_true("metadata defense kept", defense_cache:find_table("kept_metadata") ~= nil)
assert_true("metadata defense pruned", defense_cache:find_table("filtered_metadata") == nil)

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

local queue_full_cache = SchemaCache:new(queue_full_handler, "lazy-lsp-queue-full")
queue_full_cache:build_from_schemas({ { name = "app" } })
local queue_full_client = server.create(queue_full_cache)({}, {})
local queue_full_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(queue_full_buf, "/tmp/dbee-lsp-lazy-queue-full.sql")
local queue_full_uri = vim.uri_from_bufnr(queue_full_buf)
vim.api.nvim_buf_set_lines(queue_full_buf, 0, -1, false, { "select * from app." })
local queue_full_done = false
local queue_full_result = nil
queue_full_client.request("textDocument/completion", {
  textDocument = { uri = queue_full_uri },
  position = { line = 0, character = #"select * from app." },
}, function(err, result)
  if err then
    fail("queue_full completion error: " .. tostring(err))
  end
  queue_full_result = result
  queue_full_done = true
end)
vim.wait(1000, function()
  return queue_full_done
end, 20)
assert_true("queue_full completion returned", queue_full_done)
assert_eq("queue_full truthful complete", queue_full_result.isIncomplete, false)
assert_eq("queue_full empty", #queue_full_result.items, 0)
queue_full_client.terminate()

local transport_fail_cache = SchemaCache:new(transport_fail_handler, "lazy-lsp-transport-fail")
transport_fail_cache:build_from_schemas({ { name = "app" } })
local transport_fail_client = server.create(transport_fail_cache)({}, {})
local transport_fail_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(transport_fail_buf, "/tmp/dbee-lsp-lazy-transport-fail.sql")
local transport_fail_uri = vim.uri_from_bufnr(transport_fail_buf)
vim.api.nvim_buf_set_lines(transport_fail_buf, 0, -1, false, { "select * from app." })
local transport_fail_done = false
local transport_fail_result = nil
transport_fail_client.request("textDocument/completion", {
  textDocument = { uri = transport_fail_uri },
  position = { line = 0, character = #"select * from app." },
}, function(err, result)
  if err then
    fail("transport fail completion error: " .. tostring(err))
  end
  transport_fail_result = result
  transport_fail_done = true
end)
vim.wait(1000, function()
  return transport_fail_done
end, 20)
assert_true("transport fail completion returned", transport_fail_done)
assert_eq("transport fail truthful complete", transport_fail_result.isIncomplete, false)
assert_eq("transport fail empty", #transport_fail_result.items, 0)
transport_fail_client.terminate()

assert_true("schema objects applied", cache:on_schema_objects_loaded({
  conn_id = "lazy-lsp",
  root_epoch = 7,
  schema = "app",
  objects = {
    { type = "table", schema = "app", name = "accounts" },
    { type = "view", schema = "app", name = "account_view" },
  },
}))

local object_defense_cache = SchemaCache:new(fake_handler, "lazy-lsp-object-defense")
object_defense_cache:build_from_schemas({ { name = "app" } })
assert_true("schema object defense applied", object_defense_cache:on_schema_objects_loaded({
  conn_id = "lazy-lsp-object-defense",
  root_epoch = 7,
  schema = "app",
  objects = {
    { type = "table", schema = "app", name = "payload_kept" },
    { type = "table", schema = "other", name = "payload_leaked" },
  },
}))
assert_true("schema object defense kept", object_defense_cache:find_table("payload_kept") ~= nil)
assert_true("schema object defense pruned", object_defense_cache:find_table("payload_leaked") == nil)

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

vim.diagnostic.set(ns, unloaded_buf, {})
vim.api.nvim_buf_set_lines(unloaded_buf, 0, -1, false, { "select * from real_table" })
unloaded_client.notify("textDocument/didSave", {
  textDocument = { uri = unloaded_uri },
})
vim.wait(100, function()
  return true
end, 20)
assert_eq("unqualified active unloaded diagnostic suppressed", #vim.diagnostic.get(unloaded_buf, { namespace = ns }), 0)

local out_of_scope = run_diagnostics("select * from other_schema.accounts")
assert_eq("out-of-scope diagnostic count", #out_of_scope, 1)
assert_eq("out-of-scope severity", out_of_scope[1].severity, vim.diagnostic.severity.INFO)
assert_true("out-of-scope message", out_of_scope[1].message:find("outside this connection's scope", 1, true) ~= nil)

local missing = run_diagnostics("select * from app.missing_table")
assert_eq("loaded missing diagnostic count", #missing, 1)
assert_eq("loaded missing severity", missing[1].severity, vim.diagnostic.severity.WARN)
assert_eq("loaded missing message", missing[1].message, "Unknown table: app.missing_table")

local saved_client_id = lsp_init._client_id
local saved_cache = lsp_init._cache
local saved_conn_id = lsp_init._conn_id
local eager_delete_count = 0
local eager_build_count = 0
lsp_init._client_id = 14
lsp_init._conn_id = "lazy-lsp"
lsp_init._cache = {
  cancel_async = function() end,
  refresh_schema_scope = function()
    return true
  end,
  delete_column_cache_for_filter_change = function()
    eager_delete_count = eager_delete_count + 1
  end,
  build_from_structure = function(_, structs)
    eager_build_count = #structs
  end,
  save_to_disk = function() end,
}
lsp_init._on_structure_loaded({
  get_authoritative_root_epoch = function()
    return 7
  end,
  get_current_connection = function()
    return { id = "lazy-lsp" }
  end,
}, {
  conn_id = "lazy-lsp",
  caller_token = "lsp",
  root_epoch = 7,
  structures = {
    { type = "schema", schema = "app", name = "app" },
  },
})
assert_eq("eager path deletes stale columns", eager_delete_count, 1)
assert_eq("eager path rebuilds structure", eager_build_count, 1)
lsp_init._client_id = saved_client_id
lsp_init._cache = saved_cache
lsp_init._conn_id = saved_conn_id

client.terminate()
unloaded_client.terminate()

print("ARCH14_SCHEMA_CACHE_PARTIAL_INDEX_OK=true")
print("ARCH14_SCHEMA_FILTER_DOWNSTREAM_ALL_PASS=true")
print("ARCH14_LUA_DEFENSE_FILTER_OK=true")
print("ARCH14_LSP_SCHEMA_DOT_INCOMPLETE_OK=true")
print("ARCH14_LSP_SCHEMA_DOT_WARM_OK=true")
print("ARCH14_LSP_SCHEMA_DOT_NO_SYNC_FETCH=true")
print("ARCH14_QUEUE_FULL_TRUTHFUL_LSP=true")
print("ARCH14_LSP_TRANSPORT_FAIL_TRUTHFUL=true")
print("ARCH14_OUT_OF_SCOPE_HINT_OK=true")
print("ARCH14_LSP_LAZY_UNLOADED_NO_FALSE_WARN=true")
print("ARCH14_LSP_UNQUALIFIED_LAZY_NO_FALSE_WARN=true")
print("ARCH14_FILTER_DELETION_EAGER_PATH_OK=true")
print("ARCH14_LSP_ALL_PASS=true")

vim.fn.delete(vim.env.XDG_STATE_HOME, "rf")
vim.cmd("qa!")
