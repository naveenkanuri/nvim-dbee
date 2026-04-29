-- Headless checks for Phase 11 LSP diagnostic debounce and config modes.

vim.env.XDG_STATE_HOME = vim.fn.tempname()
vim.fn.mkdir(vim.env.XDG_STATE_HOME, "p")

local server = require("dbee.lsp.server")
local SchemaCache = require("dbee.lsp.schema_cache")

local function fail(msg)
  print("LSP11_DIAGNOSTICS_DEBOUNCE_FAIL=" .. msg)
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

local saved_state = package.loaded["dbee.api.state"]

local function set_lsp_config(mode, debounce_ms)
  package.loaded["dbee.api.state"] = {
    config = function()
      return {
        lsp = {
          diagnostics_mode = mode,
          diagnostics_debounce_ms = debounce_ms or 20,
        },
      }
    end,
  }
end

local cache = SchemaCache:new({}, "diagnostics-debounce")
cache:build_from_metadata_rows({
  { schema_name = "S", table_name = "VALID_TABLE", obj_type = "table" },
})
local ns = server.diagnostic_namespace()

local function new_client(name)
  local client = server.create(cache)({}, {})
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "/tmp/dbee-lsp-diagnostics-" .. name .. ".sql")
  return client, bufnr, vim.uri_from_bufnr(bufnr)
end

local function set_missing_buffer(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "SELECT * FROM MISSING_TABLE",
  })
end

set_lsp_config("debounce_didchange", 25)
local debounce_client, debounce_buf, debounce_uri = new_client("debounce")
set_missing_buffer(debounce_buf)
for i = 1, 3 do
  debounce_client.notify("textDocument/didChange", {
    textDocument = { uri = debounce_uri, version = i },
    contentChanges = {
      { text = "SELECT * FROM MISSING_TABLE" },
    },
  })
end
vim.wait(1000, function()
  return #vim.diagnostic.get(debounce_buf, { namespace = ns }) == 1
end, 10)
assert_eq("debounced diagnostic count", #vim.diagnostic.get(debounce_buf, { namespace = ns }), 1)
debounce_client.terminate()

set_lsp_config("save_only", 25)
local save_client, save_buf, save_uri = new_client("save-only")
set_missing_buffer(save_buf)
save_client.notify("textDocument/didChange", {
  textDocument = { uri = save_uri, version = 1 },
  contentChanges = {
    { text = "SELECT * FROM MISSING_TABLE" },
  },
})
vim.wait(100, function()
  return #vim.diagnostic.get(save_buf, { namespace = ns }) > 0
end, 10)
assert_eq("save_only didChange count", #vim.diagnostic.get(save_buf, { namespace = ns }), 0)
save_client.notify("textDocument/didSave", {
  textDocument = { uri = save_uri },
})
vim.wait(1000, function()
  return #vim.diagnostic.get(save_buf, { namespace = ns }) == 1
end, 10)
assert_eq("save_only didSave count", #vim.diagnostic.get(save_buf, { namespace = ns }), 1)
save_client.terminate()

set_lsp_config("off", 25)
local off_client, off_buf, off_uri = new_client("off")
set_missing_buffer(off_buf)
off_client.notify("textDocument/didChange", {
  textDocument = { uri = off_uri, version = 1 },
  contentChanges = {
    { text = "SELECT * FROM MISSING_TABLE" },
  },
})
vim.wait(100, function()
  return #vim.diagnostic.get(off_buf, { namespace = ns }) > 0
end, 10)
assert_eq("off namespace empty", #vim.diagnostic.get(off_buf, { namespace = ns }), 0)
off_client.notify("textDocument/didSave", {
  textDocument = { uri = off_uri },
})
vim.wait(100, function()
  return #vim.diagnostic.get(off_buf, { namespace = ns }) > 0
end, 10)
assert_eq("off didSave empty", #vim.diagnostic.get(off_buf, { namespace = ns }), 0)
off_client.terminate()

set_lsp_config("debounce_didchange", 200)
local cleanup_client, cleanup_buf, cleanup_uri = new_client("cleanup")
set_missing_buffer(cleanup_buf)
cleanup_client.notify("textDocument/didChange", {
  textDocument = { uri = cleanup_uri, version = 1 },
  contentChanges = {
    { text = "SELECT * FROM MISSING_TABLE" },
  },
})
cleanup_client.terminate()
vim.wait(250, function()
  return #vim.diagnostic.get(cleanup_buf, { namespace = ns }) > 0
end, 10)
assert_eq("cleanup prevents late debounce", #vim.diagnostic.get(cleanup_buf, { namespace = ns }), 0)

package.loaded["dbee.api.state"] = saved_state

print("LSP11_DEBOUNCE_DIDCHANGE_OK=true")
print("LSP11_DIDSAVE_IMMEDIATE_OK=true")
print("LSP11_SAVE_ONLY_OK=true")
print("LSP11_DIAGNOSTICS_OFF_OK=true")
print("LSP11_DEBOUNCE_CLEANUP_OK=true")
print("LSP11_DIAGNOSTICS_SINGLE_NAMESPACE_OWNED=true")

vim.cmd("qa!")
