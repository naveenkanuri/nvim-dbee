-- Headless checks for Phase 11 LSP diagnostic correctness.

vim.env.XDG_STATE_HOME = vim.fn.tempname()
vim.fn.mkdir(vim.env.XDG_STATE_HOME, "p")

local server = require("dbee.lsp.server")
local SchemaCache = require("dbee.lsp.schema_cache")

local function fail(msg)
  print("LSP11_DIAGNOSTICS_CORRECTNESS_FAIL=" .. msg)
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

local cache = SchemaCache:new({}, "diagnostics-correctness")
cache:build_from_metadata_rows({
  { schema_name = "VALID_SCHEMA", table_name = "VALID_TABLE", obj_type = "table" },
  { schema_name = "OTHER_SCHEMA", table_name = "VALID_TABLE", obj_type = "table" },
  { schema_name = "VALID_SCHEMA", table_name = "JOIN_OK", obj_type = "table" },
})

local client = server.create(cache)({}, {})
local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(bufnr, "/tmp/dbee-lsp-diagnostics-correctness.sql")
local uri = vim.uri_from_bufnr(bufnr)
local ns = server.diagnostic_namespace()

local function run_diagnostics(lines)
  vim.diagnostic.set(ns, bufnr, {})
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  client.notify("textDocument/didSave", {
    textDocument = {
      uri = uri,
    },
  })
  vim.wait(1000, function()
    return #vim.diagnostic.get(bufnr, { namespace = ns }) > 0
  end, 20)
  local diagnostics = vim.diagnostic.get(bufnr, { namespace = ns })
  if #diagnostics == 0 then
    fail("diagnostic publish timeout")
  end
  return diagnostics
end

local multiline = run_diagnostics({
  "select *",
  "from",
  "  MISSING_TABLE",
})
assert_eq("multiline diagnostic count", #multiline, 1)
assert_eq("multiline message", multiline[1].message, "Unknown table: MISSING_TABLE")
assert_eq("multiline line", multiline[1].lnum, 2)

local multi_join_sql = "SELECT * FROM VALID_SCHEMA.VALID_TABLE v JOIN VALID_SCHEMA.JOIN_OK j ON 1=1 JOIN MISSING_JOIN mj ON 1=1"
local multi_join = run_diagnostics({ multi_join_sql })
assert_eq("multi join count", #multi_join, 1)
assert_eq("multi join message", multi_join[1].message, "Unknown table: MISSING_JOIN")
assert_eq("multi join range", multi_join[1].col, multi_join_sql:find("MISSING_JOIN", 1, true) - 1)

local wrong_schema = run_diagnostics({
  "SELECT * FROM WRONG_SCHEMA.VALID_TABLE",
})
assert_eq("wrong schema count", #wrong_schema, 1)
assert_eq("wrong schema message", wrong_schema[1].message, "Unknown table: WRONG_SCHEMA.VALID_TABLE")
assert_eq("wrong schema source", wrong_schema[1].source, "dbee-lsp")
assert_eq("wrong schema severity", wrong_schema[1].severity, vim.diagnostic.severity.WARN)
assert_true("namespace diagnostics present", #wrong_schema == 1 and wrong_schema[1].message == "Unknown table: WRONG_SCHEMA.VALID_TABLE")
assert_eq("single namespace count", #vim.diagnostic.get(bufnr), 1)

client.terminate()
assert_eq("namespace cleared", #vim.diagnostic.get(bufnr, { namespace = ns }), 0)
assert_eq("no orphan diagnostics", #vim.diagnostic.get(bufnr), 0)

local saved_state = package.loaded["dbee.api.state"]
local saved_lsp = package.loaded["dbee.lsp"]
local listeners = {}
local current_conn = nil
local fake_handler = {
  get_current_connection = function()
    return current_conn
  end,
  get_authoritative_root_epoch = function()
    return 1
  end,
  register_event_listener = function(_, name, callback)
    listeners[name] = callback
  end,
  connection_get_structure_singleflight = function() end,
  teardown_structure_consumer = function() end,
  teardown_connection_invalidated_consumer = function() end,
}
package.loaded["dbee.api.state"] = {
  is_core_loaded = function()
    return true
  end,
  handler = function()
    return fake_handler
  end,
}
package.loaded["dbee.lsp"] = nil
local lsp = require("dbee.lsp")
lsp.register_events()
lsp._conn_id = "diag-conn"
lsp._cache = {
  cancel_async = function() end,
  invalidate = function() end,
}
lsp._attached_bufs = {
  [bufnr] = true,
}

local function seed_lifecycle_diagnostic()
  vim.diagnostic.set(ns, bufnr, {
    {
      lnum = 0,
      col = 0,
      end_lnum = 0,
      end_col = 1,
      severity = vim.diagnostic.severity.WARN,
      source = "dbee-lsp",
      message = "Unknown table: STALE",
    },
  })
  assert_eq("seeded lifecycle diagnostic", #vim.diagnostic.get(bufnr, { namespace = ns }), 1)
end

seed_lifecycle_diagnostic()
lsp.stop()
assert_eq("stop clears namespace", #vim.diagnostic.get(bufnr, { namespace = ns }), 0)

lsp._conn_id = "diag-conn"
lsp._cache = {
  cancel_async = function() end,
  invalidate = function() end,
}
lsp._attached_bufs = {
  [bufnr] = true,
}
seed_lifecycle_diagnostic()
current_conn = nil
listeners.current_connection_changed({ conn_id = "next-conn" })
assert_eq("current connection clears namespace", #vim.diagnostic.get(bufnr, { namespace = ns }), 0)

lsp._conn_id = "diag-conn"
lsp._cache = {
  cancel_async = function() end,
  invalidate = function() end,
}
lsp._attached_bufs = {
  [bufnr] = true,
}
seed_lifecycle_diagnostic()
listeners.database_selected({ conn_id = "diag-conn", database_name = "next-db" })
assert_eq("database selected clears namespace", #vim.diagnostic.get(bufnr, { namespace = ns }), 0)

lsp._conn_id = "diag-conn"
lsp._cache = {
  cancel_async = function() end,
}
lsp._attached_bufs = {
  [bufnr] = true,
}
current_conn = { id = "diag-conn", type = "postgres" }
lsp._connection_invalidated_consumer_live = true
seed_lifecycle_diagnostic()
lsp._on_connection_invalidated({
  authoritative_root_epoch = 2,
  current_conn_id_after = "diag-conn",
})
vim.wait(1000, function()
  return #vim.diagnostic.get(bufnr, { namespace = ns }) == 0
end, 20)
assert_eq("connection invalidated clears namespace", #vim.diagnostic.get(bufnr, { namespace = ns }), 0)

package.loaded["dbee.api.state"] = saved_state
package.loaded["dbee.lsp"] = saved_lsp

print("LSP11_DIAGNOSTICS_MULTILINE_FROM_OK=true")
print("LSP11_DIAGNOSTICS_MULTI_JOIN_RANGE_OK=true")
print("LSP11_DIAGNOSTICS_SCHEMA_AWARE_OK=true")
print("LSP11_DIAGNOSTICS_SOURCE_WARN_OK=true")
print("LSP11_DIAGNOSTIC_NAMESPACE_OK=true")
print("LSP11_DIAGNOSTICS_SINGLE_NAMESPACE_OWNED=true")

vim.cmd("qa!")
