-- Headless regression check for schema-qualified alias dot-completion in dbee LSP.
--
-- Repro this guard covers:
--   select * from fusion_opss.jps_dn d where d.
--   select * from fusion_opss.jps_dn d join fusion_opss.jps_attrs p on p.
--
-- This test verifies completion still works when schema/table metadata is not
-- preloaded in cache and must be fetched on-demand from connection_get_columns.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=/path/to/nvim-dbee" \
--   -c "luafile /path/to/nvim-dbee/ci/headless/check_lsp_schema_alias_completion.lua"

local server = require("dbee.lsp.server")
local SchemaCache = require("dbee.lsp.schema_cache")

local column_calls = {}
local fake_handler = {
  connection_get_columns = function(_, _, opts)
    column_calls[#column_calls + 1] = {
      schema = opts.schema,
      table = opts.table,
      materialization = opts.materialization,
    }
    if opts.schema == "FUSION_OPSS" and opts.table == "JPS_DN" then
      return {
        { name = "ENTRYID", type = "NUMBER" },
        { name = "DN", type = "VARCHAR2" },
      }
    end
    if opts.schema == "FUSION_OPSS" and opts.table == "JPS_ATTRS" then
      return {
        { name = "JPS_DN_ENTRYID", type = "NUMBER" },
        { name = "ATTRVAL", type = "VARCHAR2" },
      }
    end
    return {}
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

local lines = {
  "select * from fusion_opss.jps_dn d where d.",
  "select * from fusion_opss.jps_dn d join fusion_opss.jps_attrs p on p.",
}
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

local function request_items(line_idx, line_text, trigger_char)
  if line_text then
    vim.api.nvim_buf_set_lines(bufnr, line_idx, line_idx + 1, false, { line_text })
  else
    line_text = vim.api.nvim_buf_get_lines(bufnr, line_idx, line_idx + 1, false)[1]
  end

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
    return nil, "timeout"
  end
  if response.err then
    return nil, tostring(response.err)
  end
  if type(response.result) ~= "table" or type(response.result.items) ~= "table" then
    return nil, "invalid_response"
  end

  return response.result.items, nil
end

local function has_label(items, label)
  for _, item in ipairs(items) do
    if item.label == label then
      return true
    end
  end
  return false
end

local d_items, d_err = request_items(0)
local p_items, p_err = request_items(1)
local p_pre_items, p_pre_err = request_items(
  1,
  "select * from fusion_opss.jps_dn d join fusion_opss.jps_attrs p on p",
  "."
)

if d_err or p_err or p_pre_err then
  print("LSP_SCHEMA_ALIAS_FATAL=true")
  print("LSP_SCHEMA_ALIAS_D_ERR=" .. tostring(d_err))
  print("LSP_SCHEMA_ALIAS_P_ERR=" .. tostring(p_err))
  print("LSP_SCHEMA_ALIAS_P_PRE_ERR=" .. tostring(p_pre_err))
  vim.cmd("cquit 1")
  return
end

local d_has_entryid = has_label(d_items, "ENTRYID")
local d_has_attr = has_label(d_items, "JPS_DN_ENTRYID")
local p_has_entryid = has_label(p_items, "ENTRYID")
local p_has_attr = has_label(p_items, "JPS_DN_ENTRYID")
local p_pre_has_attr = has_label(p_pre_items, "JPS_DN_ENTRYID")

print("LSP_SCHEMA_ALIAS_D_ENTRYID=" .. tostring(d_has_entryid))
print("LSP_SCHEMA_ALIAS_D_JPS_DN_ENTRYID=" .. tostring(d_has_attr))
print("LSP_SCHEMA_ALIAS_P_ENTRYID=" .. tostring(p_has_entryid))
print("LSP_SCHEMA_ALIAS_P_JPS_DN_ENTRYID=" .. tostring(p_has_attr))
print("LSP_SCHEMA_ALIAS_P_PRE_JPS_DN_ENTRYID=" .. tostring(p_pre_has_attr))
print("LSP_SCHEMA_ALIAS_COLUMN_CALLS=" .. tostring(#column_calls))

local called_jps_dn = false
local called_jps_attrs = false
for _, call in ipairs(column_calls) do
  if call.schema == "FUSION_OPSS" and call.table == "JPS_DN" then
    called_jps_dn = true
  end
  if call.schema == "FUSION_OPSS" and call.table == "JPS_ATTRS" then
    called_jps_attrs = true
  end
end

print("LSP_SCHEMA_ALIAS_CALLED_JPS_DN=" .. tostring(called_jps_dn))
print("LSP_SCHEMA_ALIAS_CALLED_JPS_ATTRS=" .. tostring(called_jps_attrs))

if not d_has_entryid or d_has_attr
  or p_has_entryid or not p_has_attr
  or not p_pre_has_attr
  or not called_jps_dn or not called_jps_attrs then
  vim.cmd("cquit 1")
  return
end

vim.cmd("qa!")
