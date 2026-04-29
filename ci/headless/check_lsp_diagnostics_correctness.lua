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

local published = {}
local dispatchers = {
  notification = function(method, params)
    if method == "textDocument/publishDiagnostics" then
      published[#published + 1] = params
    end
  end,
}
local client = server.create(cache)(dispatchers, {})
local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(bufnr, "/tmp/dbee-lsp-diagnostics-correctness.sql")
local uri = vim.uri_from_bufnr(bufnr)
local ns = vim.api.nvim_create_namespace("dbee/lsp")

local function run_diagnostics(lines)
  published = {}
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  client.notify("textDocument/didSave", {
    textDocument = {
      uri = uri,
    },
  })
  vim.wait(1000, function()
    return #published > 0
  end, 20)
  if #published == 0 then
    fail("diagnostic publish timeout")
  end
  return published[#published].diagnostics, vim.diagnostic.get(bufnr, { namespace = ns })
end

local multiline = run_diagnostics({
  "select *",
  "from",
  "  MISSING_TABLE",
})
assert_eq("multiline diagnostic count", #multiline, 1)
assert_eq("multiline message", multiline[1].message, "Unknown table: MISSING_TABLE")
assert_eq("multiline line", multiline[1].range.start.line, 2)

local multi_join_sql = "SELECT * FROM VALID_SCHEMA.VALID_TABLE v JOIN VALID_SCHEMA.JOIN_OK j ON 1=1 JOIN MISSING_JOIN mj ON 1=1"
local multi_join = run_diagnostics({ multi_join_sql })
assert_eq("multi join count", #multi_join, 1)
assert_eq("multi join message", multi_join[1].message, "Unknown table: MISSING_JOIN")
assert_eq("multi join range", multi_join[1].range.start.character, multi_join_sql:find("MISSING_JOIN", 1, true) - 1)

local wrong_schema, ns_diags = run_diagnostics({
  "SELECT * FROM WRONG_SCHEMA.VALID_TABLE",
})
assert_eq("wrong schema count", #wrong_schema, 1)
assert_eq("wrong schema message", wrong_schema[1].message, "Unknown table: WRONG_SCHEMA.VALID_TABLE")
assert_eq("wrong schema source", wrong_schema[1].source, "dbee-lsp")
assert_eq("wrong schema severity", wrong_schema[1].severity, vim.diagnostic.severity.WARN)
assert_true("namespace diagnostics present", #ns_diags == 1 and ns_diags[1].message == "Unknown table: WRONG_SCHEMA.VALID_TABLE")

client.terminate()
assert_eq("namespace cleared", #vim.diagnostic.get(bufnr, { namespace = ns }), 0)

print("LSP11_DIAGNOSTICS_MULTILINE_FROM_OK=true")
print("LSP11_DIAGNOSTICS_MULTI_JOIN_RANGE_OK=true")
print("LSP11_DIAGNOSTICS_SCHEMA_AWARE_OK=true")
print("LSP11_DIAGNOSTICS_SOURCE_WARN_OK=true")
print("LSP11_DIAGNOSTIC_NAMESPACE_OK=true")

vim.cmd("qa!")
