local context = require("dbee.lsp.context")
local docs = require("dbee.lsp.object_docs")
local epoch_authority = require("dbee.lsp.epoch_authority")
local schema_filter_authority = require("dbee.schema_filter_authority")

local M = {}

---@param opts table?
---@return boolean
local function enabled(opts)
  if opts and opts.enabled == false then
    return false
  end
  return true
end

---@param cache SchemaCache
---@return boolean
local function authority_available(cache)
  if not cache or type(cache.read_lsp_authority) ~= "function" then
    return false
  end
  return not schema_filter_authority.is_fail_closed(cache:read_lsp_authority())
end

---@param cache SchemaCache
---@return boolean
local function cache_fresh(cache)
  local check = epoch_authority.check_fresh(cache, cache and cache.handler, cache and cache.conn_id)
  return check.fresh
end

---@param cache SchemaCache
---@param ref table
---@return table?
local function schema_metadata(cache, ref)
  local meta = cache:get_schema_metadata(ref.schema, {
    schema_quoted = ref.schema_quoted,
  })
  return meta
end

---@param cache SchemaCache
---@param ref table
---@return table?
local function table_metadata(cache, ref)
  local meta = cache:get_table_metadata(ref.schema, ref.table, {
    schema_quoted = ref.schema_quoted,
    table_quoted = ref.table_quoted,
  })
  return meta
end

---@param cache SchemaCache
---@param ref table
---@param column table
---@return table?
local function column_metadata(cache, ref, column)
  local meta = cache:get_column_metadata(ref.schema, ref.table, column.name, {
    schema_quoted = ref.schema_quoted,
    table_quoted = ref.table_quoted,
    column_quoted = column.quoted,
  })
  return meta
end

---@param hover_ctx table
---@param cache SchemaCache
---@return table?
local function resolve_metadata(hover_ctx, cache)
  local token = hover_ctx.token
  local selected = hover_ctx.selected_ref
  if selected then
    if selected.component == "schema" and selected.schema then
      return schema_metadata(cache, selected)
    end
    return table_metadata(cache, selected)
  end

  if hover_ctx.prefix then
    local alias = hover_ctx.aliases[hover_ctx.prefix.name:lower()]
    if alias then
      return column_metadata(cache, alias, token)
    end

    local direct_ref = {
      schema = nil,
      schema_quoted = nil,
      table = hover_ctx.prefix.name,
      table_quoted = hover_ctx.prefix.quoted,
    }
    local column = column_metadata(cache, direct_ref, token)
    if column then
      return column
    end
  end

  if hover_ctx.single_table_ref then
    local column = column_metadata(cache, hover_ctx.single_table_ref, token)
    if column then
      return column
    end
  elseif #hover_ctx.table_refs > 1 then
    return nil
  end

  local schema = cache:get_schema_metadata(token.name, { schema_quoted = token.quoted })
  if schema then
    return schema
  end

  local table_meta = cache:get_table_metadata(nil, token.name, { table_quoted = token.quoted })
  if table_meta then
    return table_meta
  end

  return nil
end

---@param params table
---@param cache SchemaCache
---@param opts? { enabled?: boolean, client_capabilities?: table, max_scan_lines?: integer }
---@return table?
function M.handle(params, cache, opts)
  opts = opts or {}
  if not enabled(opts) or not cache then
    return nil
  end
  if not authority_available(cache) then
    return nil
  end
  if not cache_fresh(cache) then
    return nil
  end

  local hover_ctx = context.hover_context(params, {
    max_scan_lines = opts.max_scan_lines,
  })
  if not hover_ctx or hover_ctx.capped then
    return nil
  end

  local metadata = resolve_metadata(hover_ctx, cache)
  if not metadata then
    return nil
  end

  return {
    contents = docs.format_hover(metadata, {
      client_capabilities = opts.client_capabilities,
    }),
    range = hover_ctx.token.range,
  }
end

return M
