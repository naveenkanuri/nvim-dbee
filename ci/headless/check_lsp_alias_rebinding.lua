-- Headless regression check for alias rebinding in SQL completion context.
--
-- Repro this guard covers:
--   select * from sas_principals sp where sp.
--   select * from sas_policies sp where sp.
--   select * from sas_policies s where s.
--
-- The same alias ("sp") is reused across separate statements and must resolve
-- to the latest table in scope, not a stale table from earlier text.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=/path/to/nui.nvim" \
--   --cmd "set rtp+=/path/to/nvim-dbee" \
--   -c "luafile ci/headless/check_lsp_alias_rebinding.lua"

local server = require("dbee.lsp.server")

local fake_cache = {
  get_schemas = function()
    return { "FUSION" }
  end,
  get_tables = function(_, schema)
    if schema ~= "FUSION" then
      return {}
    end
    return {
      sas_principals = { type = "table" },
      sas_policies = { type = "table" },
    }
  end,
  find_table = function(_, table_name)
    local lower = table_name:lower()
    if lower == "sas_principals" then
      return "sas_principals", "FUSION"
    end
    if lower == "sas_policies" then
      return "sas_policies", "FUSION"
    end
    return nil, nil
  end,
  get_columns = function(_, schema, table_name)
    if schema ~= "FUSION" then
      return {}
    end
    if table_name == "sas_principals" then
      return {
        { name = "PRINCIPAL_ID", type = "NUMBER" },
        { name = "PRINCIPAL_NAME", type = "VARCHAR2" },
      }
    end
    if table_name == "sas_policies" then
      return {
        { name = "POLICY_ID", type = "NUMBER" },
        { name = "POLICY_NAME", type = "VARCHAR2" },
      }
    end
    return {}
  end,
  get_cached_columns = function()
    return {}
  end,
}

local client = server.create(fake_cache)({}, {})

local bufnr = vim.api.nvim_create_buf(false, true)
local lines = {
  "select * from sas_principals sp where sp.",
  "select * from sas_policies sp where sp.",
  "select * from sas_policies s where s.",
}
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
vim.api.nvim_buf_set_name(bufnr, "/tmp/dbee-alias-rebinding.sql")
local uri = vim.uri_from_bufnr(bufnr)

local function request_items(line_index, opts)
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
    return nil, "timeout"
  end
  if response.err then
    return nil, tostring(response.err)
  end

  return (response.result and response.result.items) or {}, nil
end

local function has_label(items, label)
  for _, item in ipairs(items) do
    if item.label == label then
      return true
    end
  end
  return false
end

local q1, q1_err = request_items(0)
local q2, q2_err = request_items(1)
local q3, q3_err = request_items(2)
local q2_pre, q2_pre_err = request_items(1, {
  line_text = "select * from sas_policies sp where sp",
  trigger_char = ".",
})

if q1_err or q2_err or q3_err or q2_pre_err then
  print("ALIAS_REBIND_FATAL=true")
  print("ALIAS_REBIND_Q1_ERR=" .. tostring(q1_err))
  print("ALIAS_REBIND_Q2_ERR=" .. tostring(q2_err))
  print("ALIAS_REBIND_Q3_ERR=" .. tostring(q3_err))
  print("ALIAS_REBIND_Q2_PRE_ERR=" .. tostring(q2_pre_err))
  vim.cmd("cquit 1")
  return
end

local q1_has_principal = has_label(q1, "PRINCIPAL_ID")
local q1_has_policy = has_label(q1, "POLICY_ID")
local q2_has_principal = has_label(q2, "PRINCIPAL_ID")
local q2_has_policy = has_label(q2, "POLICY_ID")
local q2_pre_has_principal = has_label(q2_pre, "PRINCIPAL_ID")
local q2_pre_has_policy = has_label(q2_pre, "POLICY_ID")
local q3_has_policy = has_label(q3, "POLICY_ID")

print("ALIAS_REBIND_Q1_PRINCIPAL=" .. tostring(q1_has_principal))
print("ALIAS_REBIND_Q1_POLICY=" .. tostring(q1_has_policy))
print("ALIAS_REBIND_Q2_PRINCIPAL=" .. tostring(q2_has_principal))
print("ALIAS_REBIND_Q2_POLICY=" .. tostring(q2_has_policy))
print("ALIAS_REBIND_Q2_PRE_PRINCIPAL=" .. tostring(q2_pre_has_principal))
print("ALIAS_REBIND_Q2_PRE_POLICY=" .. tostring(q2_pre_has_policy))
print("ALIAS_REBIND_Q3_POLICY=" .. tostring(q3_has_policy))

if not q1_has_principal or q1_has_policy
  or q2_has_principal or not q2_has_policy
  or q2_pre_has_principal or not q2_pre_has_policy
  or not q3_has_policy then
  vim.cmd("cquit 1")
  return
end

vim.cmd("qa!")
