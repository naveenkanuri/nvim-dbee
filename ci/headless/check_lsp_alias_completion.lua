-- Headless regression check for alias dot-completion in dbee LSP.
--
-- Repro this guard covers:
--   select * from sas_principals sp where sp.
--
-- Includes both completion timing variants:
-- 1) pre-insert trigger (client sends completion before "." is inserted)
-- 2) post-insert trigger (line already ends with ".")
--
-- This test is hermetic: it uses an in-memory fake cache and does not require
-- any live DB connection, local dbee state, or external files.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=/path/to/nvim-dbee" \
--   -c "luafile /path/to/nvim-dbee/ci/headless/check_lsp_alias_completion.lua"

local server = require("dbee.lsp.server")

local fake_cache = {
  get_schemas = function(_)
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
  get_cached_columns = function(_)
    return {}
  end,
}

local client = server.create(fake_cache)({}, {})
local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(bufnr, "/tmp/dbee-alias-completion.sql")
local uri = vim.uri_from_bufnr(bufnr)

local function request_items(line_text, trigger_char)
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
    return nil, "timeout"
  end
  if response.err then
    return nil, tostring(response.err)
  end

  if type(response.result) ~= "table" then
    return nil, "invalid_completion_result_type:" .. type(response.result)
  end
  if type(response.result.items) ~= "table" then
    return nil, "invalid_completion_items_type:" .. type(response.result.items)
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

local pre_line = "select * from sas_principals sp where sp"
local pre_items, pre_err = request_items(pre_line, ".")
local post_items, post_err = request_items(pre_line .. ".")

if pre_err or post_err then
  print("LSP_ALIAS_FATAL=true")
  print("LSP_ALIAS_PRE_ERR=" .. tostring(pre_err))
  print("LSP_ALIAS_POST_ERR=" .. tostring(post_err))
  vim.cmd("cquit 1")
  return
end

local pre_has_principal = has_label(pre_items, "PRINCIPAL_ID")
local pre_has_policy = has_label(pre_items, "POLICY_ID")
local post_has_principal = has_label(post_items, "PRINCIPAL_ID")
local post_has_policy = has_label(post_items, "POLICY_ID")

print("LSP_ALIAS_PRE_ITEMS=" .. tostring(#pre_items))
print("LSP_ALIAS_POST_ITEMS=" .. tostring(#post_items))
print("LSP_ALIAS_PRE_HAS_PRINCIPAL=" .. tostring(pre_has_principal))
print("LSP_ALIAS_PRE_HAS_POLICY=" .. tostring(pre_has_policy))
print("LSP_ALIAS_POST_HAS_PRINCIPAL=" .. tostring(post_has_principal))
print("LSP_ALIAS_POST_HAS_POLICY=" .. tostring(post_has_policy))

-- Alias `sp` must resolve to sas_principals columns in both trigger timings,
-- and must not leak sas_policies columns.
if not pre_has_principal or pre_has_policy or not post_has_principal or post_has_policy then
  vim.cmd("cquit 1")
  return
end

vim.cmd("qa!")
