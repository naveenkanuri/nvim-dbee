local docs = require("dbee.lsp.object_docs")
local schema_filter_authority = require("dbee.schema_filter_authority")

local M = {}

---@param item table
---@return table
local function clone_item(item)
  return vim.deepcopy(item or {})
end

---@param item table
---@return table?
local function dbee_data(item)
  local data = type(item) == "table" and item.data or nil
  if type(data) ~= "table" or data.source ~= "dbee" or data.version ~= 1 then
    return nil
  end
  return data
end

---@param item table
---@param reason string
---@return table
local function incomplete(item, reason)
  local out = clone_item(item)
  out.documentation = nil
  local data = out.data
  if type(data) == "table" then
    if data.dbee_resolved == true then
      out.detail = nil
    end
    data.dbee_resolved = false
    data.dbee_resolve_status = "incomplete"
    data.dbee_resolve_reason = reason
  end
  return out
end

---@param cache SchemaCache
---@return boolean
local function authority_available(cache)
  if not cache or type(cache.read_lsp_authority) ~= "function" then
    return false
  end
  return not schema_filter_authority.is_fail_closed(cache:read_lsp_authority())
end

---@param data table
---@param markdown_kind string
---@return string
local function memo_key(data, markdown_kind)
  return table.concat({
    tostring(data.kind or ""),
    tostring(data.schema_exact or data.schema or ""),
    tostring(data.table_exact or data.table or ""),
    tostring(data.column_exact or data.column or ""),
    tostring(data.schema_quoted == true),
    tostring(data.table_quoted == true),
    tostring(data.column_quoted == true),
    tostring(data.cache_generation or ""),
    tostring(markdown_kind or "markdown"),
  }, "|")
end

---@param memo table?
---@param generation integer
function M.prune_memo(memo, generation)
  if type(memo) ~= "table" then
    return
  end
  if rawget(memo, "__dbee_generation") == generation then
    return
  end
  for key in pairs(memo) do
    memo[key] = nil
  end
  memo.__dbee_generation = generation
end

---@param item table
---@param rendered table
---@return table
local function apply_rendered(item, rendered)
  local out = clone_item(item)
  out.documentation = rendered.documentation
  if rendered.detail then
    out.detail = rendered.detail
  end
  out.data = out.data or {}
  out.data.dbee_resolved = true
  out.data.dbee_resolve_status = "complete"
  out.data.dbee_resolve_reason = nil
  return out
end

---@param cache SchemaCache
---@param data table
---@return table?
local function metadata_for(cache, data)
  if data.kind == "schema" then
    local meta = cache:get_schema_metadata(data.schema_exact or data.schema, {
      schema_quoted = data.schema_quoted,
    })
    return meta
  end
  if data.kind == "table" then
    local meta = cache:get_table_metadata(data.schema_exact or data.schema, data.table_exact or data.table, {
      schema_quoted = data.schema_quoted,
      table_quoted = data.table_quoted,
    })
    return meta
  end
  if data.kind == "column" then
    local meta = cache:get_column_metadata(
      data.schema_exact or data.schema,
      data.table_exact or data.table,
      data.column_exact or data.column,
      {
        schema_quoted = data.schema_quoted,
        table_quoted = data.table_quoted,
        column_quoted = data.column_quoted,
      }
    )
    return meta
  end
  return nil
end

---@param client_capabilities table?
---@return string
local function markdown_kind(client_capabilities)
  local formats = client_capabilities
    and client_capabilities.textDocument
    and client_capabilities.textDocument.completion
    and client_capabilities.textDocument.completion.completionItem
    and client_capabilities.textDocument.completion.completionItem.documentationFormat
  if type(formats) == "table" then
    for _, format in ipairs(formats) do
      if format == "markdown" then
        return "markdown"
      end
    end
    return "plaintext"
  end
  return "markdown"
end

---@param item table
---@param cache SchemaCache
---@param opts? { enabled?: boolean, client_capabilities?: table, memo?: table }
---@return table
function M.handle(item, cache, opts)
  opts = opts or {}
  if opts.enabled == false then
    return clone_item(item)
  end

  local data = dbee_data(item)
  if not data then
    return item
  end
  if not cache then
    return incomplete(item, "cache_missing")
  end
  local memo = opts.memo or {}
  local current_generation = cache:generation()
  M.prune_memo(memo, current_generation)
  if not authority_available(cache) then
    return incomplete(item, "authority_unavailable")
  end
  if data.dbee_ambiguous == true then
    return incomplete(item, "ambiguous")
  end
  if data.cache_identity ~= cache:cache_identity()
    or tonumber(data.cache_generation) ~= current_generation
    or tonumber(data.root_epoch or 0) ~= cache:_authoritative_root_epoch()
  then
    return incomplete(item, "stale_generation")
  end

  local metadata = metadata_for(cache, data)
  if not metadata then
    return incomplete(item, "metadata_missing")
  end

  local kind = markdown_kind(opts.client_capabilities)
  local key = memo_key(data, kind)
  if memo[key] then
    return apply_rendered(item, memo[key])
  end

  local rendered = docs.format_resolve(metadata, item, {
    client_capabilities = opts.client_capabilities,
  })
  memo[key] = rendered
  return apply_rendered(item, rendered)
end

return M
