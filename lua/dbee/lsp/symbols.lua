local context = require("dbee.lsp.context")
local epoch_authority = require("dbee.lsp.epoch_authority")
local schema_name_canonical = require("dbee.schema_name_canonical")

local M = {}

local MAX_DOCUMENT_LINES = 10000
local MAX_DOCUMENT_BYTES = 1024 * 1024
local WORKSPACE_SYMBOL_LIMIT = 200

local SymbolKind = {
  Namespace = 3,
  Class = 5,
  Field = 8,
}

local document_cache = {}
M._last_workspace_allocations = 0

local function zero_range()
  return {
    start = { line = 0, character = 0 },
    ["end"] = { line = 0, character = 0 },
  }
end

local function copy(value)
  return vim.deepcopy(value)
end

local function uri_bufnr(uri)
  if not uri or uri == "" then
    return nil
  end
  local ok, bufnr = pcall(vim.uri_to_bufnr, uri)
  if ok then
    return bufnr
  end
  return nil
end

local function hierarchical_supported(client_capabilities)
  local text_document = client_capabilities and client_capabilities.textDocument or nil
  local document_symbol = text_document and text_document.documentSymbol or nil
  return document_symbol and document_symbol.hierarchicalDocumentSymbolSupport == true
end

local function workspace_symbol_supported(client_capabilities)
  local workspace = client_capabilities and client_capabilities.workspace or nil
  local symbol = workspace and workspace.symbol or nil
  return symbol and symbol.resolveSupport ~= nil
end

local function get_changedtick(bufnr)
  local ok, changedtick = pcall(vim.api.nvim_buf_get_changedtick, bufnr)
  if ok then
    return changedtick
  end
  return 0
end

local function read_document(uri)
  local bufnr = uri_bufnr(uri)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    document_cache[uri] = nil
    return nil
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local bytes = 0
  local capped = line_count > MAX_DOCUMENT_LINES
  local kept = {}
  local next_line = 0
  while next_line < line_count and #kept < MAX_DOCUMENT_LINES and bytes < MAX_DOCUMENT_BYTES do
    local chunk_end = math.min(line_count, next_line + 128, MAX_DOCUMENT_LINES)
    local lines = vim.api.nvim_buf_get_lines(bufnr, next_line, chunk_end, false)
    if not lines or #lines == 0 then
      break
    end
    for _, line in ipairs(lines) do
      local newline_bytes = #kept > 0 and 1 or 0
      local extra = #line + newline_bytes
      if bytes + extra > MAX_DOCUMENT_BYTES then
        local remaining = MAX_DOCUMENT_BYTES - bytes - newline_bytes
        if remaining > 0 then
          kept[#kept + 1] = line:sub(1, remaining)
          bytes = MAX_DOCUMENT_BYTES
        end
        capped = true
        break
      end
      kept[#kept + 1] = line
      bytes = bytes + extra
    end
    next_line = next_line + #lines
    if capped then
      break
    end
  end

  return {
    bufnr = bufnr,
    changedtick = get_changedtick(bufnr),
    text = table.concat(kept, "\n"),
    capped = capped,
  }
end

local function document_epoch_check(cache)
  local handler = cache and cache.handler or nil
  local conn_id = cache and cache.conn_id or nil
  local _, check = epoch_authority.read_with_freshness(cache, handler, conn_id, function()
    return true
  end)
  return check
end

local function schema_known(cache, ref)
  if not ref.schema or ref.schema == "" then
    return false
  end
  if not cache or type(cache.document_symbol_schema_known) ~= "function" then
    return false
  end
  local ok, known = pcall(cache.document_symbol_schema_known, cache, ref.schema, { schema_quoted = ref.schema_quoted })
  return ok and known == true
end

local function range_key(range)
  if not range then
    return "0:0"
  end
  local start = range.start or {}
  return tostring(start.line or 0) .. ":" .. tostring(start.character or 0)
end

local function cache_fold(cache)
  return cache and cache.fold_id or "case_insensitive"
end

local function canonical_part(value, quoted, cache)
  return schema_name_canonical.canonical(value, quoted == true, cache_fold(cache)).canonical
end

local function document_cache_identity(cache, epoch_check)
  if cache and type(cache.document_symbol_cache_identity) == "function" then
    local ok, identity = pcall(cache.document_symbol_cache_identity, cache)
    if ok and identity then
      return table.concat({
        tostring(identity),
        "handler_epoch:" .. tostring(epoch_check and epoch_check.handler_epoch or "none"),
        "fresh:" .. tostring(epoch_check and epoch_check.fresh == true),
        "available:" .. tostring(epoch_check and epoch_check.available == true),
      }, "|")
    end
  end
  return table.concat({
    cache and ("cache:" .. tostring(cache)) or "cache:none",
    "handler_epoch:" .. tostring(epoch_check and epoch_check.handler_epoch or "none"),
    "fresh:" .. tostring(epoch_check and epoch_check.fresh == true),
    "available:" .. tostring(epoch_check and epoch_check.available == true),
  }, "|")
end

local function table_identity(ref, cache)
  if ref.schema and ref.schema ~= "" then
    return table.concat({
      ref.schema_quoted and "Q" or "U",
      canonical_part(ref.schema, ref.schema_quoted, cache),
      ref.table_quoted and "Q" or "U",
      canonical_part(ref.table, ref.table_quoted, cache),
    }, "\0")
  end
  return table.concat({ "ROOT", ref.table_quoted and "Q" or "U", canonical_part(ref.table, ref.table_quoted, cache) }, "\0")
end

local function column_identity(col, cache)
  return table.concat({
    canonical_part(col.schema or "", col.schema_quoted, cache),
    col.schema_quoted and "Q" or "U",
    canonical_part(col.table or "", col.table_quoted, cache),
    col.table_quoted and "Q" or "U",
    canonical_part(col.column or "", col.column_quoted, cache),
    col.column_quoted and "Q" or "U",
  }, "\0")
end

local function make_document_symbol(name, kind, range, children)
  return {
    name = name,
    kind = kind,
    range = range or zero_range(),
    selectionRange = range or zero_range(),
    children = children,
  }
end

local function make_symbol_information(name, kind, uri, range, container)
  local symbol = {
    name = name,
    kind = kind,
    location = {
      uri = uri,
      range = range or zero_range(),
    },
  }
  if container then
    symbol.containerName = container
  end
  return symbol
end

local function build_document_symbols(uri, refs, cache, hierarchical)
  local schema_nodes = {}
  local schema_order = {}
  local root_tables = {}
  local root_order = {}
  local table_nodes = {}
  local table_order = {}

  local function add_schema(ref)
    local key = (ref.schema_quoted and "Q" or "U") .. "\0" .. canonical_part(ref.schema, ref.schema_quoted, cache)
    if not schema_nodes[key] then
      schema_nodes[key] = make_document_symbol(ref.schema, SymbolKind.Namespace, ref.schema_range, {})
      schema_order[#schema_order + 1] = key
    end
    return schema_nodes[key]
  end

  local function add_table(ref)
    local known_schema = schema_known(cache, ref)
    local table_key = table_identity(ref, cache)
    if table_nodes[table_key] then
      return table_nodes[table_key]
    end

    local table_name = ref.table
    local table_range = ref.table_range or ref.ref_range
    local node
    if ref.schema and ref.schema ~= "" and known_schema then
      node = make_document_symbol(table_name, SymbolKind.Class, table_range, {})
      local parent = add_schema(ref)
      parent.children[#parent.children + 1] = node
    else
      if ref.schema and ref.schema ~= "" then
        table_name = ref.ref
        table_range = ref.ref_range or table_range
      end
      node = make_document_symbol(table_name, SymbolKind.Class, table_range, {})
      root_tables[#root_tables + 1] = node
      root_order[#root_order + 1] = range_key(table_range)
    end

    table_nodes[table_key] = node
    table_order[#table_order + 1] = table_key
    return node
  end

  for _, ref in ipairs(refs.tables or {}) do
    add_table(ref)
  end

  local seen_columns = {}
  for _, col in ipairs(refs.columns or {}) do
    local key = column_identity(col, cache)
    if not seen_columns[key] then
      local table_ref = {
        schema = col.schema,
        schema_quoted = col.schema_quoted,
        table = col.table,
        table_quoted = col.table_quoted,
        table_range = col.range,
        ref_range = col.range,
      }
      local table_node = table_nodes[table_identity(table_ref, cache)]
      if table_node then
        table_node.children = table_node.children or {}
        table_node.children[#table_node.children + 1] =
          make_document_symbol(col.column, SymbolKind.Field, col.range, nil)
        seen_columns[key] = true
      end
    end
  end

  if hierarchical then
    local out = {}
    for _, key in ipairs(schema_order) do
      out[#out + 1] = schema_nodes[key]
    end
    for _, node in ipairs(root_tables) do
      out[#out + 1] = node
    end
    return out
  end

  local flat = {}
  for _, key in ipairs(schema_order) do
    local node = schema_nodes[key]
    flat[#flat + 1] = make_symbol_information(node.name, node.kind, uri, node.selectionRange)
    for _, child in ipairs(node.children or {}) do
      flat[#flat + 1] = make_symbol_information(child.name, child.kind, uri, child.selectionRange, node.name)
      for _, grandchild in ipairs(child.children or {}) do
        flat[#flat + 1] = make_symbol_information(grandchild.name, grandchild.kind, uri, grandchild.selectionRange, child.name)
      end
    end
  end
  for _, node in ipairs(root_tables) do
    flat[#flat + 1] = make_symbol_information(node.name, node.kind, uri, node.selectionRange)
    for _, child in ipairs(node.children or {}) do
      flat[#flat + 1] = make_symbol_information(child.name, child.kind, uri, child.selectionRange, node.name)
    end
  end
  return flat
end

---@param params table
---@param cache SchemaCache?
---@param opts? table
---@return table[]?
function M.handle_document_symbol(params, cache, opts)
  opts = opts or {}
  if opts.enabled == false then
    return nil
  end
  local uri = params and params.textDocument and params.textDocument.uri or nil
  local doc = read_document(uri)
  if not doc then
    return nil
  end

  local hierarchical = opts.force_flat ~= true and hierarchical_supported(opts.client_capabilities)
  local epoch_check = document_epoch_check(cache)
  local cache_key = table.concat({
    uri,
    tostring(doc.bufnr),
    tostring(doc.changedtick),
    document_cache_identity(cache, epoch_check),
    hierarchical and "tree" or "flat",
  }, "|")
  local cached = document_cache[uri]
  if cached and cached.key == cache_key then
    return copy(cached.result)
  end

  local refs = context.extract_symbol_references(doc.text)
  local result = build_document_symbols(uri, refs, cache, hierarchical)
  document_cache[uri] = {
    bufnr = doc.bufnr,
    key = cache_key,
    changedtick = doc.changedtick,
    result = copy(result),
  }
  return result
end

local function encode_uri_component(value)
  value = tostring(value or "")
  return (value:gsub("([^A-Za-z0-9_.~-])", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end))
end

local function symbol_uri(record)
  local parts = {
    "dbee://",
    encode_uri_component(record.conn_id),
    "/",
    encode_uri_component(record.schema_exact),
  }
  if record.kind == "table" then
    parts[#parts + 1] = "/"
    parts[#parts + 1] = encode_uri_component(record.table_exact)
  end
  return table.concat(parts)
end

local function workspace_kind(record)
  if record.kind == "schema" then
    return SymbolKind.Namespace
  end
  return SymbolKind.Class
end

local function workspace_name(record)
  if record.kind == "schema" then
    return record.schema_exact
  end
  return record.table_exact
end

---@param params table
---@param cache SchemaCache?
---@param opts? table
---@return table[]
function M.handle_workspace_symbol(params, cache, opts)
  opts = opts or {}
  if opts.enabled == false then
    return {}
  end
  if not cache or type(cache.get_workspace_symbol_snapshot) ~= "function" then
    return {}
  end

  local snapshot = cache:get_workspace_symbol_snapshot({
    query = params and params.query or "",
    limit = opts.limit or WORKSPACE_SYMBOL_LIMIT,
  })
  local records = snapshot.items or {}
  local force_fallback = opts.force_symbol_information == true
  local use_workspace_symbol = not force_fallback and workspace_symbol_supported(opts.client_capabilities)
  local out = {}

  for _, record in ipairs(records) do
    local name = workspace_name(record)
    local uri = symbol_uri(record)
    if use_workspace_symbol then
      out[#out + 1] = {
        name = name,
        kind = workspace_kind(record),
        containerName = record.kind == "table" and record.schema_exact or nil,
        location = { uri = uri },
      }
    else
      out[#out + 1] = {
        name = name,
        kind = workspace_kind(record),
        containerName = record.kind == "table" and record.schema_exact or nil,
        location = {
          uri = uri,
          range = zero_range(),
        },
      }
    end
  end

  M._last_workspace_allocations = #out
  return out
end

---@param uri string?
function M.invalidate_document(uri)
  if uri then
    document_cache[uri] = nil
  end
end

---@param bufnr integer?
function M.invalidate_buffer(bufnr)
  if not bufnr then
    return
  end
  local ok, uri = pcall(vim.uri_from_bufnr, bufnr)
  if ok then
    document_cache[uri] = nil
  end
end

---@return integer
function M.cache_size()
  local count = 0
  for uri, entry in pairs(document_cache) do
    local bufnr = entry and entry.bufnr or nil
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      document_cache[uri] = nil
    else
      count = count + 1
    end
  end
  return count
end

function M._reset_cache()
  document_cache = {}
  M._last_workspace_allocations = 0
end

return M
