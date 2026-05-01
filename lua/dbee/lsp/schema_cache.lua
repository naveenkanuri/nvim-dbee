---@class SchemaCache
---@field private handler Handler
---@field private conn_id connection_id
---@field private schemas table<string, boolean>
---@field private tables table<string, table<string, { type: string }>>
---@field private columns table<string, Column[]>
---@field private all_table_names string[] flat list for unqualified completion
---@field private schema_items lsp.CompletionItem[]
---@field private table_items_by_schema table<string, lsp.CompletionItem[]>
---@field private all_table_items lsp.CompletionItem[]
---@field private all_table_item_source_by_label table<string, string>
---@field private all_table_item_ambiguous_by_label table<string, boolean>
---@field private column_items_by_key table<string, lsp.CompletionItem[]>
---@field private schema_lookup_exact table<string, string>
---@field private schema_lookup table<string, string>
---@field private table_lookup_exact_by_schema table<string, table<string, string>>
---@field private table_lookup_by_schema table<string, table<string, string>>
---@field private table_lookup_exact_global table<string, { name: string, schema: string }>
---@field private table_lookup_global table<string, { name: string, schema: string }>
---@field private async_inflight table<string, table>
---@field private async_chains table<string, table>
---@field private async_failed table<string, boolean>
---@field private next_async_request_id integer
---@field private metadata_generation integer
---@field private metadata_root_epoch_value integer
---@field private cache_identity_value string
---@field private cache_dir string directory for disk cache
local SchemaCache = {}

local nio = require("nio")
local schema_filter = require("dbee.schema_filter")
local schema_filter_authority = require("dbee.schema_filter_authority")
local schema_name_canonical = require("dbee.schema_name_canonical")

local MAX_COLUMNS_IN_MEMORY = 500
local SYNC_COLUMN_FILE_LOAD_LIMIT = 100
local SYNC_COLUMN_FILE_SCAN_LIMIT = 200
local FILTER_DELETE_SYNC_SCAN_LIMIT = 200
local FILTER_DELETE_SYNC_DELETE_LIMIT = 100
local COLUMN_CACHE_TTL_SECONDS = 30 * 24 * 60 * 60
local SCHEMA_CACHE_VERSION = 3
local MATERIALIZATIONS = { "table", "view" }

local CompletionItemKind = {
  Field = 5,
  Class = 7,
  Module = 9,
  Struct = 22,
}

---@param schema string
---@param table_name string
---@return string
local function table_key(schema, table_name)
  return (schema or "_default") .. "." .. table_name
end

---@param value string?
---@return string
local function case_insensitive_key(value)
  return schema_name_canonical.canonical(value, false, "case_insensitive").canonical
end

---@param materializations string[]
---@return string
local function materialization_identity(materializations)
  return table.concat(materializations or MATERIALIZATIONS, ",")
end

---@param items table[]
---@return table[]
local function copy_items(items)
  return vim.deepcopy(items or {})
end

---@param columns Column[]?
---@param max_columns integer?
---@return Column[]? copied
---@return integer copied_count
local function copy_column_preview(columns, max_columns)
  if not columns then
    return nil, 0
  end
  local limit = math.max(0, tonumber(max_columns) or 20)
  limit = math.min(#columns, limit)
  local copied = {}
  for i = 1, limit do
    copied[#copied + 1] = vim.deepcopy(columns[i])
  end
  return copied, limit
end

---@param schema string
---@param name string
---@param table_type string?
---@return lsp.CompletionItem
local function table_completion_item(schema, name, table_type)
  table_type = table_type or "table"
  local detail = (schema ~= "_default") and (schema .. "." .. name) or name
  return {
    label = name,
    kind = (table_type == "view") and CompletionItemKind.Class or CompletionItemKind.Struct,
    detail = detail .. " (" .. table_type .. ")",
    insertText = name,
    sortText = "0_" .. name,
  }
end

---@param items lsp.CompletionItem[]
---@param item lsp.CompletionItem
local function upsert_sorted_item(items, item)
  local low, high = 1, #items
  while low <= high do
    local mid = math.floor((low + high) / 2)
    local label = items[mid].label
    if label == item.label then
      items[mid] = item
      return
    end
    if label < item.label then
      low = mid + 1
    else
      high = mid - 1
    end
  end
  table.insert(items, low, item)
end

---@param values string[]
---@param value string
local function upsert_sorted_value(values, value)
  local low, high = 1, #values
  while low <= high do
    local mid = math.floor((low + high) / 2)
    if values[mid] == value then
      return
    end
    if values[mid] < value then
      low = mid + 1
    else
      high = mid - 1
    end
  end
  table.insert(values, low, value)
end

---@param message string
local function warn(message)
  vim.notify(message, vim.log.levels.WARN)
end

---@param handler Handler
---@param conn_id connection_id
---@return SchemaCache
function SchemaCache:new(handler, conn_id)
  local cache_dir = vim.fn.stdpath("state") .. "/dbee/lsp_cache"
  local authority = schema_filter_authority.read(handler, conn_id)
  local normalized_scope = authority.status == "ok" and authority.scope
    or authority.status == "api_absent_legacy" and schema_filter_authority.legacy_implicit_all()
    or schema_filter_authority.fail_closed_scope()
  local o = {
    handler = handler,
    conn_id = conn_id,
    schemas = {},
    tables = {},
    columns = {},
    all_table_names = {},
    schema_items = {},
    table_items_by_schema = {},
    all_table_items = {},
    all_table_item_source_by_label = {},
    all_table_item_ambiguous_by_label = {},
    column_items_by_key = {},
    schema_lookup_exact = {},
    schema_lookup = {},
    table_lookup_exact_by_schema = {},
    table_lookup_by_schema = {},
    table_lookup_exact_global = {},
    table_lookup_global = {},
    column_lru = {},
    column_touch_clock = 0,
    column_evictions = 0,
    disk_pruned = 0,
    sync_column_files_discovered = 0,
    sync_column_files_scanned = 0,
    sync_column_discovery_degraded = false,
    sync_column_files_loaded = 0,
    deferred_dir_advances_per_tick = 0,
    total_deferred_dir_advances = 0,
    deferred_column_files_scheduled = 0,
    deferred_column_files_processed = 0,
    deferred_disk_work_scheduled = false,
    deferred_disk_work_drained = false,
    disk_work_generation = 0,
    deferred_disk_work_canceled = 0,
    async_inflight = {},
    async_chains = {},
    async_failed = {},
    completion_refresh_eligible = {},
    completion_refresh_pending = {},
    completion_refresh_notifier = nil,
    next_async_request_id = 0,
    metadata_generation = 0,
    metadata_root_epoch_value = 0,
    cache_dir = cache_dir,
    fold_id = normalized_scope.fold,
    schema_scope = normalized_scope,
    schema_filter_signature = normalized_scope.schema_filter_signature,
    root_mode = normalized_scope.lazy_per_schema and "schemas_only" or "full",
    loaded_schemas = {},
    pending_delete_total_files = 0,
    pending_delete_sync_deleted = 0,
    pending_delete_sync_scanned = 0,
    pending_delete_deferred_scanned = 0,
    pending_delete_deferred_drain_count = 0,
  }
  setmetatable(o, self)
  self.__index = self
  o.cache_identity_value = tostring(conn_id or "") .. "|" .. tostring(o)
  o.metadata_root_epoch_value = o:authoritative_root_epoch()
  return o
end

---@private
---@param _reason string?
---@param root_epoch integer?
function SchemaCache:_bump_metadata_generation(_reason, root_epoch)
  self.metadata_generation = (self.metadata_generation or 0) + 1
  if root_epoch ~= nil then
    self.metadata_root_epoch_value = tonumber(root_epoch) or 0
  else
    self.metadata_root_epoch_value = self:authoritative_root_epoch()
  end
end

---@private
---@return table
function SchemaCache:_read_normalized_scope()
  local authority = schema_filter_authority.read(self.handler, self.conn_id)
  if authority.status == "ok" then
    return authority.scope
  end
  if authority.status == "api_absent_legacy" then
    return schema_filter_authority.legacy_implicit_all()
  end
  return schema_filter_authority.fail_closed_scope()
end

---@return boolean changed
function SchemaCache:refresh_schema_scope()
  local previous_signature = self.schema_filter_signature
  local normalized_scope = self:_read_normalized_scope()
  self.fold_id = normalized_scope.fold
  self.schema_scope = normalized_scope
  self.schema_filter_signature = normalized_scope.schema_filter_signature
  if normalized_scope.fail_closed == true then
    self:_bump_metadata_generation("refresh_schema_scope_fail_closed")
    self:cancel_async("schema-filter-authority-unavailable", { conn_id = self.conn_id })
    self.schemas = {}
    self.tables = {}
    self.columns = {}
    self.column_lru = {}
    self.loaded_schemas = {}
    self.root_mode = "full"
    self:_reset_indexes()
  end
  local changed = previous_signature ~= nil and previous_signature ~= self.schema_filter_signature
  if changed and normalized_scope.fail_closed ~= true then
    self:_bump_metadata_generation("refresh_schema_scope")
  end
  return changed
end

---@param notifier? fun(payload: table)
function SchemaCache:set_completion_refresh_notifier(notifier)
  if type(notifier) == "function" then
    self.completion_refresh_notifier = notifier
  else
    self.completion_refresh_notifier = nil
  end
end

--- Return the handler's authoritative root epoch for this cache's connection.
--- Hover/resolve use this to fail closed when cache metadata lags connection invalidation.
---@return integer
function SchemaCache:authoritative_root_epoch()
  if self.handler and type(self.handler.get_authoritative_root_epoch) == "function" then
    local ok, epoch = pcall(self.handler.get_authoritative_root_epoch, self.handler, self.conn_id)
    if ok then
      return tonumber(epoch) or 0
    end
  end
  return 0
end

---@private
---@param chain_key string?
function SchemaCache:_mark_completion_refresh_eligible(chain_key)
  if chain_key and chain_key ~= "" then
    self.completion_refresh_eligible[chain_key] = true
  end
end

---@private
---@param entries table[]
---@return boolean
function SchemaCache:_consume_completion_refresh_eligible(entries)
  local eligible = false
  for _, entry in ipairs(entries or {}) do
    if entry.chain_key and self.completion_refresh_eligible[entry.chain_key] then
      eligible = true
      self.completion_refresh_eligible[entry.chain_key] = nil
    end
  end
  return eligible
end

---@private
---@param probe table
---@param request_id integer
---@param root_epoch integer
function SchemaCache:_queue_completion_refresh_notification(probe, request_id, root_epoch)
  if type(self.completion_refresh_notifier) ~= "function" then
    return
  end
  if root_epoch < self:authoritative_root_epoch() then
    return
  end
  if not schema_filter.matches(probe.schema, self.schema_scope) then
    return
  end

  local notify_key = table.concat({
    tostring(self.conn_id or ""),
    tostring(probe.schema or ""),
    tostring(probe.table_name or ""),
    tostring(probe.materialization or ""),
    tostring(root_epoch or 0),
    tostring(self.schema_filter_signature or ""),
  }, "\31")
  if self.completion_refresh_pending[notify_key] then
    return
  end
  self.completion_refresh_pending[notify_key] = true

  local payload = {
    conn_id = self.conn_id,
    schema = probe.schema,
    table = probe.table_name,
    materialization = probe.materialization,
    root_epoch = root_epoch,
    schema_filter_signature = self.schema_filter_signature,
    request_id = request_id,
  }

  vim.schedule(function()
    self.completion_refresh_pending[notify_key] = nil
    if type(self.completion_refresh_notifier) ~= "function" then
      return
    end
    if root_epoch < self:authoritative_root_epoch() then
      return
    end
    self.completion_refresh_notifier(vim.deepcopy(payload))
  end)
end

--- Build the cache from metadata query result rows.
--- Each row is a map with schema_name, table_name, obj_type keys (case-insensitive).
---@param rows table[] array of {schema_name: string, table_name: string, obj_type: string}
---@param opts? { root_epoch?: integer }
function SchemaCache:build_from_metadata_rows(rows, opts)
  opts = opts or {}
  self:_bump_metadata_generation("build_from_metadata_rows", opts.root_epoch)
  self.schemas = {}
  self.tables = {}
  self.columns = {}
  self:_reset_indexes()

  if not rows or #rows == 0 then
    return
  end

  for _, row in ipairs(rows) do
    local schema, tname, otype
    for k, v in pairs(row) do
      local lk = case_insensitive_key(k)
      if lk == "schema_name" then
        schema = v
      elseif lk == "table_name" then
        tname = v
      elseif lk == "obj_type" then
        otype = v
      end
    end

    if schema and tname and schema_filter.matches(schema, self.schema_scope) then
      otype = otype or "table"
      self.schemas[schema] = true
      if not self.tables[schema] then
        self.tables[schema] = {}
      end
      self.tables[schema][tname] = { type = otype }
    end
  end

  self:_rebuild_structure_indexes()
  self.root_mode = "full"
  self.loaded_schemas = {}
  for schema in pairs(self.schemas) do
    self:_mark_schema_loaded(schema)
  end
end

--- Build the cache from a pre-fetched structure tree.
--- NEVER calls connection_get_structure() — structure must be provided.
---@param structs DBStructure[]
---@param opts? { root_epoch?: integer }
function SchemaCache:build_from_structure(structs, opts)
  opts = opts or {}
  self:_bump_metadata_generation("build_from_structure", opts.root_epoch)
  self.schemas = {}
  self.tables = {}
  self.columns = {}
  self:_reset_indexes()

  if not structs or structs == vim.NIL then
    return
  end

  self:_flatten(structs, nil)
  self:_rebuild_structure_indexes()
  self.root_mode = "full"
  self.loaded_schemas = {}
  for schema in pairs(self.schemas) do
    self:_mark_schema_loaded(schema)
  end
end

---@param schemas table[] array of {name: string}
---@param opts? { preserve_loaded?: boolean, root_epoch?: integer }
function SchemaCache:build_from_schemas(schemas, opts)
  opts = opts or {}
  self:_bump_metadata_generation("build_from_schemas", opts.root_epoch)
  local preserve_loaded = opts.preserve_loaded ~= false
  local previous_tables = self.tables or {}
  local previous_columns = self.columns or {}
  local previous_lru = self.column_lru or {}
  local previous_loaded = self.loaded_schemas or {}
  local previous_schema_lookup_exact = self.schema_lookup_exact or {}
  local previous_schema_lookup = self.schema_lookup or {}
  local preserved_loaded_schemas = {}

  local function previous_schema_for_refresh(name)
    local candidates = {}
    if previous_schema_lookup_exact[name] then
      candidates[#candidates + 1] = previous_schema_lookup_exact[name]
    end
    if self.fold_id == "case_insensitive" then
      local canonical_name = schema_name_canonical.canonical(name, false, self.fold_id).canonical
      if previous_schema_lookup[canonical_name] then
        candidates[#candidates + 1] = previous_schema_lookup[canonical_name]
      end
    end

    for _, candidate in ipairs(candidates) do
      if schema_name_canonical.equivalent(candidate, true, name, true, self.fold_id) then
        return candidate
      end
    end

    return name
  end

  self.schemas = {}
  self.tables = {}
  self.columns = {}
  self.column_lru = {}
  self.loaded_schemas = {}
  self.root_mode = "schemas_only"
  self:_reset_indexes()

  for _, schema in ipairs(schemas or {}) do
    local name = schema.name or schema.schema or schema
    if type(name) == "string" and name ~= "" and schema_filter.matches(name, self.schema_scope) then
      self.schemas[name] = true
      local previous_name = previous_schema_for_refresh(name)
      if preserve_loaded and self:_schema_loaded_in(previous_name, previous_loaded) and previous_tables[previous_name] then
        self.tables[name] = vim.deepcopy(previous_tables[previous_name])
        self:_mark_schema_loaded(name)
        preserved_loaded_schemas[previous_name] = name
      else
        self.tables[name] = self.tables[name] or {}
      end
    end
  end

  if preserve_loaded then
    for key, cols in pairs(previous_columns) do
      local schema, table_name = key:match("^(.-)%.(.+)$")
      local preserved_schema = schema and preserved_loaded_schemas[schema]
      if preserved_schema then
        local preserved_key = schema == preserved_schema and key or table_key(preserved_schema, table_name)
        self.columns[preserved_key] = cols
        self.column_lru[preserved_key] = previous_lru[key]
      end
    end
  end

  self:_rebuild_structure_indexes()
  self:_rebuild_column_indexes()
end

---@private
---@param value string?
---@return boolean
function SchemaCache:_can_fold_alias(value)
  if type(value) ~= "string" or value == "" then
    return false
  end
  return schema_name_canonical.is_unquoted_canonical(value, self.fold_id)
end

---@private
---@param exact_lookup table<string, any>?
---@param folded_lookup table<string, any>?
---@param value string?
---@param quoted boolean?
---@return any
function SchemaCache:_resolve_lookup(exact_lookup, folded_lookup, value, quoted)
  if not value or value == "" then
    return nil
  end
  local canonical = schema_name_canonical.canonical(value, quoted == true, self.fold_id).canonical
  if quoted == true then
    return exact_lookup and exact_lookup[value] or nil
  end
  if quoted == false then
    return (folded_lookup and folded_lookup[canonical]) or (exact_lookup and exact_lookup[canonical])
  end
  return (exact_lookup and exact_lookup[value]) or (folded_lookup and folded_lookup[canonical])
end

---@private
---@param out string[]
---@param seen table<string, boolean>
---@param value string?
local function add_probe_candidate(out, seen, value)
  if value and value ~= "" and not seen[value] then
    seen[value] = true
    out[#out + 1] = value
  end
end

---@private
---@param value string?
---@param quoted boolean?
---@return string[]
function SchemaCache:_identifier_probe_candidates(value, quoted)
  return schema_name_canonical.probe_candidates(value, quoted, self.fold_id)
end

---@private
---@param schema string?
---@param quoted boolean?
---@param include_default boolean?
---@return string[]
function SchemaCache:_schema_probe_candidates(schema, quoted, include_default)
  local out = {}
  local seen = {}
  add_probe_candidate(out, seen, self:find_schema(schema, { quoted = quoted }))
  for _, candidate in ipairs(self:_identifier_probe_candidates(schema, quoted)) do
    add_probe_candidate(out, seen, candidate)
  end
  if include_default then
    add_probe_candidate(out, seen, "_default")
  end
  return out
end

---@private
---@param schema string
---@return string
function SchemaCache:_loaded_schema_key(schema)
  return schema_name_canonical.loaded_key(schema, self.fold_id)
end

---@private
---@param schema string
function SchemaCache:_mark_schema_loaded(schema)
  self.loaded_schemas[self:_loaded_schema_key(schema)] = true
end

---@private
---@param schema string
---@param loaded table<string, boolean>?
---@return boolean
function SchemaCache:_schema_loaded_in(schema, loaded)
  return loaded and loaded[self:_loaded_schema_key(schema)] == true or false
end

---@private
---@param schema string
function SchemaCache:_upsert_schema_lookup(schema)
  self.schema_lookup_exact[schema] = schema
  if not self:_can_fold_alias(schema) then
    return
  end
  local canonical = schema_name_canonical.canonical(schema, false, self.fold_id).canonical
  local current = self.schema_lookup[canonical]
  if not current or schema < current then
    self.schema_lookup[canonical] = schema
  end
end

---@private
---@param schema string
---@return table<string, string>, table<string, string>
function SchemaCache:_ensure_table_lookup(schema)
  local exact_lookup = self.table_lookup_exact_by_schema[schema]
  if not exact_lookup then
    exact_lookup = {}
    self.table_lookup_exact_by_schema[schema] = exact_lookup
  end

  local folded_lookup = self.table_lookup_by_schema[schema]
  if not folded_lookup then
    folded_lookup = {}
    self.table_lookup_by_schema[schema] = folded_lookup
  end

  return exact_lookup, folded_lookup
end

---@private
---@param schema string
---@param name string
function SchemaCache:_upsert_table_lookup(schema, name)
  local exact_lookup, folded_lookup = self:_ensure_table_lookup(schema)
  exact_lookup[name] = name
  if not self:_can_fold_alias(name) then
    return
  end
  local canonical = schema_name_canonical.canonical(name, false, self.fold_id).canonical
  local current = folded_lookup[canonical]
  if not current or name < current then
    folded_lookup[canonical] = name
  end
end

---@private
---@param current { name: string, schema: string }?
---@param schema string
---@param name string
---@return boolean
function SchemaCache:_global_lookup_precedes(current, schema, name)
  return not current or schema < current.schema or (schema == current.schema and name <= current.name)
end

---@private
function SchemaCache:_reset_indexes()
  self.all_table_names = {}
  self.schema_items = {}
  self.table_items_by_schema = {}
  self.all_table_items = {}
  self.all_table_item_source_by_label = {}
  self.all_table_item_ambiguous_by_label = {}
  self.column_items_by_key = {}
  self.schema_lookup_exact = {}
  self.schema_lookup = {}
  self.table_lookup_exact_by_schema = {}
  self.table_lookup_by_schema = {}
  self.table_lookup_exact_global = {}
  self.table_lookup_global = {}
end

---@private
function SchemaCache:_build_name_list()
  self:_rebuild_structure_indexes()
end

---@private
function SchemaCache:_rebuild_structure_indexes()
  self.all_table_names = {}
  self.schema_items = {}
  self.table_items_by_schema = {}
  self.all_table_items = {}
  self.all_table_item_source_by_label = {}
  self.all_table_item_ambiguous_by_label = {}
  self.schema_lookup_exact = {}
  self.schema_lookup = {}
  self.table_lookup_exact_by_schema = {}
  self.table_lookup_by_schema = {}
  self.table_lookup_exact_global = {}
  self.table_lookup_global = {}

  local schema_names = vim.tbl_keys(self.schemas)
  table.sort(schema_names)

  for _, schema in ipairs(schema_names) do
    self:_upsert_schema_lookup(schema)
    if schema ~= "_default" then
      self.schema_items[#self.schema_items + 1] = {
        label = schema,
        kind = CompletionItemKind.Module,
        detail = "schema",
        insertText = schema,
        sortText = "0_" .. schema,
      }
    end

    local table_names = vim.tbl_keys(self.tables[schema] or {})
    table.sort(table_names)
    local schema_items = {}

    for _, name in ipairs(table_names) do
      local info = self.tables[schema][name] or { type = "table" }
      self:_upsert_table_lookup(schema, name)

      schema_items[#schema_items + 1] = table_completion_item(schema, name, info.type)
    end

    self.table_items_by_schema[schema] = schema_items
  end

  self:_refresh_global_table_index()
end

---@private
function SchemaCache:_refresh_global_table_index()
  self.table_lookup_exact_global = {}
  self.table_lookup_global = {}
  self.all_table_items = {}
  self.all_table_names = {}
  self.all_table_item_source_by_label = {}
  self.all_table_item_ambiguous_by_label = {}

  local schema_names = vim.tbl_keys(self.schemas)
  table.sort(schema_names)

  for _, schema in ipairs(schema_names) do
    local table_names = vim.tbl_keys(self.tables[schema] or {})
    table.sort(table_names)
    for _, name in ipairs(table_names) do
      local info = self.tables[schema][name] or { type = "table" }
      self:_update_global_table_index_for_table(schema, name, info.type)
    end
  end

  table.sort(self.all_table_items, function(a, b)
    return a.label < b.label
  end)
end

---@private
---@param schema string
---@param name string
---@param table_type string
function SchemaCache:_update_global_table_index_for_table(schema, name, table_type)
  local current_exact = self.table_lookup_exact_global[name]
  if self:_global_lookup_precedes(current_exact, schema, name) then
    self.table_lookup_exact_global[name] = {
      name = name,
      schema = schema,
    }
  end

  if self:_can_fold_alias(name) then
    local canonical = schema_name_canonical.canonical(name, false, self.fold_id).canonical
    local current = self.table_lookup_global[canonical]
    if self:_global_lookup_precedes(current, schema, name) then
      self.table_lookup_global[canonical] = {
        name = name,
        schema = schema,
      }
    end
  end

  local current_source = self.all_table_item_source_by_label[name]
  if current_source and current_source ~= schema then
    self.all_table_item_ambiguous_by_label[name] = true
  end
  if not current_source or schema < current_source or current_source == schema then
    self.all_table_item_source_by_label[name] = schema
    local item = table_completion_item(schema, name, table_type)
    upsert_sorted_item(self.all_table_items, vim.deepcopy(item))
    upsert_sorted_value(self.all_table_names, item.label)
  end
end

---@private
---@param schema string
---@param name string
---@param table_type string
function SchemaCache:_upsert_table_index(schema, name, table_type)
  self:_bump_metadata_generation("_upsert_table_index")
  table_type = table_type or "table"
  local new_schema = not self.schemas[schema]
  self.schemas[schema] = true
  self:_upsert_schema_lookup(schema)

  if not self.tables[schema] then
    self.tables[schema] = {}
  end
  self.tables[schema][name] = { type = table_type }

  if new_schema and schema ~= "_default" then
    upsert_sorted_item(self.schema_items, {
      label = schema,
      kind = CompletionItemKind.Module,
      detail = "schema",
      insertText = schema,
      sortText = "0_" .. schema,
    })
  end

  self:_upsert_table_lookup(schema, name)

  if not self.table_items_by_schema[schema] then
    self.table_items_by_schema[schema] = {}
  end
  local item = table_completion_item(schema, name, table_type)
  upsert_sorted_item(self.table_items_by_schema[schema], item)
  self:_update_global_table_index_for_table(schema, name, table_type)
end

---@private
---@param key string
function SchemaCache:_drop_column_index(key)
  self.column_items_by_key[key] = nil
end

---@private
---@return integer
function SchemaCache:_column_entry_count()
  return vim.tbl_count(self.columns)
end

---@private
function SchemaCache:_bump_disk_work_generation()
  self.disk_work_generation = (self.disk_work_generation or 0) + 1
  self.deferred_disk_work_scheduled = false
  self.deferred_disk_work_drained = false
end

---@private
---@param key string
function SchemaCache:_touch_column(key)
  self.column_touch_clock = (self.column_touch_clock or 0) + 1
  self.column_lru[key] = self.column_touch_clock
end

---@private
function SchemaCache:_evict_columns_if_needed()
  while self:_column_entry_count() > MAX_COLUMNS_IN_MEMORY do
    local evict_key, evict_clock = nil, nil
    for key, clock in pairs(self.column_lru) do
      if self.columns[key] and (not evict_clock or clock < evict_clock) then
        evict_key = key
        evict_clock = clock
      end
    end

    if not evict_key then
      return
    end

    self.columns[evict_key] = nil
    self.column_lru[evict_key] = nil
    self:_drop_column_index(evict_key)
    self.column_evictions = (self.column_evictions or 0) + 1
  end
end

---@private
---@param key string
---@param cols Column[]
---@param opts? { root_epoch?: integer }
function SchemaCache:_store_columns(key, cols, opts)
  opts = opts or {}
  self:_bump_metadata_generation("_store_columns", opts.root_epoch)
  self.columns[key] = cols
  self:_touch_column(key)

  local schema, name = key:match("^(.-)%.(.+)$")
  if schema and name then
    self:_update_column_index(schema, name)
  end

  self:_evict_columns_if_needed()
end

---@private
---@param conn_id connection_id
---@param schema string
---@param table_name string
---@param materialization string
---@param root_epoch integer
---@return string
function SchemaCache:_async_key(conn_id, schema, table_name, materialization, root_epoch)
  return table.concat({
    tostring(conn_id or ""),
    tostring(schema or ""),
    tostring(table_name or ""),
    tostring(materialization or ""),
    tostring(root_epoch or 0),
  }, "|")
end

---@private
---@param conn_id connection_id
---@param schema string
---@param table_name string
---@param materializations string
---@param root_epoch integer
---@return string
function SchemaCache:_async_chain_key(conn_id, schema, table_name, materializations, root_epoch)
  return table.concat({
    tostring(conn_id or ""),
    tostring(schema or ""),
    tostring(table_name or ""),
    tostring(materializations or ""),
    tostring(root_epoch or 0),
  }, "|")
end

---@private
---@return integer
function SchemaCache:_next_request_id()
  self.next_async_request_id = (self.next_async_request_id or 0) + 1
  return self.next_async_request_id
end

---@private
---@param opts table
---@return integer
function SchemaCache:_root_epoch(opts)
  if opts and opts.root_epoch ~= nil then
    return tonumber(opts.root_epoch) or 0
  end
  if self.handler and type(self.handler.get_authoritative_root_epoch) == "function" then
    return tonumber(self.handler:get_authoritative_root_epoch(self.conn_id)) or 0
  end
  return 0
end

---@private
---@param entry table
function SchemaCache:_detach_async_entry(entry)
  local key = entry.active_key
  if key then
    local probe = self.async_inflight[key]
    if probe and probe.entries then
      for index, candidate in ipairs(probe.entries) do
        if candidate == entry then
          table.remove(probe.entries, index)
          break
        end
      end
      if #probe.entries == 0 then
        self.async_inflight[key] = nil
      end
    elseif probe == entry then
      self.async_inflight[key] = nil
    end
  end
  entry.active_key = nil
  entry.request_id = nil
  entry.branch_id = nil
end

---@private
---@param entry table
function SchemaCache:_finish_async_entry(entry)
  self:_detach_async_entry(entry)
  self.completion_refresh_eligible[entry.chain_key] = nil
  self.async_chains[entry.chain_key] = nil
end

---@private
---@param entry table
---@return boolean
function SchemaCache:_queue_async_probe(entry)
  if not self.handler or type(self.handler.connection_get_columns_async) ~= "function" then
    self:_finish_async_entry(entry)
    self.async_failed[entry.chain_key] = true
    return false
  end

  local schema = entry.schema_candidates[entry.schema_index]
  local table_name = entry.table_candidates[entry.table_index]
  local materialization = entry.materializations[entry.materialization_index]
  while schema and table_name and materialization and not schema_filter.matches(schema, self.schema_scope) do
    if not self:_advance_async_probe_indices(entry) then
      schema = nil
      break
    end
    schema = entry.schema_candidates[entry.schema_index]
    table_name = entry.table_candidates[entry.table_index]
    materialization = entry.materializations[entry.materialization_index]
  end
  if not schema or not table_name or not materialization then
    self:_finish_async_entry(entry)
    self.async_failed[entry.chain_key] = true
    return false
  end

  local request_id = self:_next_request_id()
  local branch_id = table.concat({ "lsp-columns", tostring(request_id) }, ":")
  local key = self:_async_key(entry.conn_id, schema, table_name, materialization, entry.root_epoch)
  local query_schema = (schema == "_default") and "" or schema

  local active_probe = self.async_inflight[key]
  if active_probe then
    entry.active_key = key
    entry.request_id = active_probe.request_id
    entry.branch_id = active_probe.branch_id
    entry.schema = schema
    entry.table_name = table_name
    entry.materialization = materialization
    active_probe.entries[#active_probe.entries + 1] = entry
    self.async_chains[entry.chain_key] = entry
    return true
  end

  entry.active_key = key
  entry.request_id = request_id
  entry.branch_id = branch_id
  entry.schema = schema
  entry.table_name = table_name
  entry.materialization = materialization
  self.async_inflight[key] = {
    active_key = key,
    conn_id = entry.conn_id,
    request_id = request_id,
    branch_id = branch_id,
    root_epoch = entry.root_epoch,
    schema = schema,
    table_name = table_name,
    materialization = materialization,
    entries = { entry },
  }
  self.async_chains[entry.chain_key] = entry

  local ok = pcall(self.handler.connection_get_columns_async, self.handler, entry.conn_id, request_id, branch_id, entry.root_epoch, {
    table = table_name,
    schema = query_schema,
    materialization = materialization,
    kind = "columns",
  })
  if not ok then
    local failed_probe = self.async_inflight[key]
    if failed_probe then
      self.async_inflight[key] = nil
      for _, queued in ipairs(failed_probe.entries or {}) do
        queued.active_key = nil
        self.async_chains[queued.chain_key] = nil
        self.async_failed[queued.chain_key] = true
      end
      return false
    end
  end

  return true
end

---@private
---@param entry table
---@return boolean
function SchemaCache:_advance_async_probe_indices(entry)
  entry.materialization_index = entry.materialization_index + 1
  if entry.materialization_index <= #entry.materializations then
    return true
  end

  entry.materialization_index = 1
  entry.table_index = entry.table_index + 1
  if entry.table_index <= #entry.table_candidates then
    return true
  end

  entry.table_index = 1
  entry.schema_index = entry.schema_index + 1
  return entry.schema_index <= #entry.schema_candidates
end

---@private
---@param entry table
---@return boolean
function SchemaCache:_advance_async_probe(entry)
  self:_detach_async_entry(entry)

  if self:_advance_async_probe_indices(entry) then
    return self:_queue_async_probe(entry)
  end

  self:_finish_async_entry(entry)
  self.async_failed[entry.chain_key] = true
  return false
end

---@private
---@param schema string
---@param table_name string
function SchemaCache:_update_column_index(schema, table_name)
  local key = table_key(schema, table_name)
  local cols = self.columns[key]
  if not cols then
    self:_drop_column_index(key)
    return
  end

  local items = {}
  for _, col in ipairs(cols) do
    items[#items + 1] = {
      label = col.name,
      kind = CompletionItemKind.Field,
      detail = col.type,
      insertText = col.name,
      sortText = "0_" .. col.name,
    }
  end
  table.sort(items, function(a, b)
    return a.label < b.label
  end)
  self.column_items_by_key[key] = items
end

---@private
function SchemaCache:_rebuild_column_indexes()
  self.column_items_by_key = {}
  for key, _ in pairs(self.columns) do
    local schema, name = key:match("^(.-)%.(.+)$")
    if schema and name then
      self:_update_column_index(schema, name)
    end
  end
end

---@private
---@param tbl any
---@return boolean
local function is_array(tbl)
  if type(tbl) ~= "table" then
    return false
  end
  if vim.islist then
    return vim.islist(tbl)
  end
  if vim.tbl_islist then
    return vim.tbl_islist(tbl)
  end

  local count = 0
  local max_index = 0
  for key, _ in pairs(tbl) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false
    end
    count = count + 1
    if key > max_index then
      max_index = key
    end
  end
  return count == max_index
end

---@private
---@param cols any
---@return boolean
function SchemaCache:_validate_columns(cols)
  if not is_array(cols) then
    return false
  end
  for _, col in ipairs(cols) do
    if type(col) ~= "table" or type(col.name) ~= "string" or type(col.type) ~= "string" then
      return false
    end
  end
  return true
end

---@private
---@param data any
---@return table?
function SchemaCache:_normalize_schema_index(data)
  if type(data) ~= "table" or is_array(data) then
    return nil
  end
  if not is_array(data.schemas) or type(data.tables) ~= "table" or is_array(data.tables) then
    return nil
  end
  if data.all_table_names ~= nil and not is_array(data.all_table_names) then
    return nil
  end

  local normalized = {
    schemas = {},
    tables = {},
  }
  local schema_set = {}

  for _, schema in ipairs(data.schemas) do
    if type(schema) ~= "string" then
      return nil
    end
    normalized.schemas[#normalized.schemas + 1] = schema
    schema_set[schema] = true
  end

  if data.all_table_names then
    for _, table_name in ipairs(data.all_table_names) do
      if type(table_name) ~= "string" then
        return nil
      end
    end
  end

  for schema, tbls in pairs(data.tables) do
    if type(schema) ~= "string" or type(tbls) ~= "table" or is_array(tbls) then
      return nil
    end
    if not schema_set[schema] then
      return nil
    end

    normalized.tables[schema] = {}
    for table_name, info in pairs(tbls) do
      if type(table_name) ~= "string" then
        return nil
      end

      local table_type = nil
      if type(info) == "string" then
        table_type = info
      elseif type(info) == "table" and type(info.type) == "string" then
        table_type = info.type
      end
      if not table_type then
        return nil
      end

      normalized.tables[schema][table_name] = table_type
    end
  end

  return normalized
end

---@private
---@param path string
---@return table?
function SchemaCache:_file_stat(path)
  local uv = vim.uv or vim.loop
  return uv and uv.fs_stat(path) or nil
end

---@private
---@param path string
---@param stat table?
---@param now integer
---@return boolean
function SchemaCache:_prune_if_old(path, stat, now)
  if not stat or not stat.mtime or not stat.mtime.sec then
    return false
  end
  if now - stat.mtime.sec <= COLUMN_CACHE_TTL_SECONDS then
    return false
  end
  if os.remove(path) then
    self.disk_pruned = (self.disk_pruned or 0) + 1
    return true
  end
  return false
end

---@private
---@param limit? integer
---@return table[]
function SchemaCache:_column_cache_files(limit)
  local prefix = self.conn_id .. "_cols_"
  local files = {}
  local max_files = limit or SYNC_COLUMN_FILE_LOAD_LIMIT
  local max_scans = math.max(max_files, SYNC_COLUMN_FILE_SCAN_LIMIT)
  local scanned = 0
  local scan_limit_hit = false

  local function add_path(path)
    local stat = self:_file_stat(path)
    files[#files + 1] = {
      path = path,
      stat = stat,
      mtime = stat and stat.mtime and stat.mtime.sec or 0,
    }
  end

  if vim.fs and type(vim.fs.dir) == "function" then
    local ok, iter = pcall(vim.fs.dir, self.cache_dir)
    if ok and iter then
      for name, entry_type in iter do
        scanned = scanned + 1
        if entry_type == "file"
          and name:sub(1, #prefix) == prefix
          and name:sub(-5) == ".json"
        then
          add_path(self.cache_dir .. "/" .. name)
        end
        if #files >= max_files or scanned >= max_scans then
          scan_limit_hit = scanned >= max_scans and #files < max_files
          break
        end
      end
    end
  else
    local pattern = self.cache_dir .. "/" .. prefix .. "*.json"
    for _, path in ipairs(vim.fn.glob(pattern, false, true)) do
      scanned = scanned + 1
      add_path(path)
      if #files >= max_files or scanned >= max_scans then
        scan_limit_hit = scanned >= max_scans and #files < max_files
        break
      end
    end
  end

  table.sort(files, function(a, b)
    if a.mtime == b.mtime then
      return a.path < b.path
    end
    return a.mtime > b.mtime
  end)
  self.sync_column_files_discovered = #files
  self.sync_column_files_scanned = scanned
  self.sync_column_discovery_degraded = scan_limit_hit
  return files
end

---@private
---@param path string
---@param prefix string
---@return boolean
function SchemaCache:_load_column_file(path, prefix)
  local f = io.open(path, "r")
  if not f then
    return false
  end

  local content = f:read("*a")
  f:close()
  local ok, payload = pcall(vim.json.decode, content)
  if not ok or not payload then
    self:_remove_corrupt_file(path, "loading column cache")
    return false
  end
  local cols = payload
  if type(payload) == "table" and payload.columns ~= nil then
    if payload.schema_filter_signature ~= self.schema_filter_signature then
      os.remove(path)
      return false
    end
    cols = payload.columns
  elseif type(payload) == "table" and payload.version == nil and payload.schema_filter_signature == nil and #payload > 0 and self:_validate_columns(payload) then
    self:_remove_legacy_column_cache(path)
    return false
  else
    self:_remove_corrupt_file(path, "loading column cache")
    return false
  end
  if not self:_validate_columns(cols) then
    self:_remove_corrupt_file(path, "loading column cache")
    return false
  end

  local fname = vim.fn.fnamemodify(path, ":t:r")
  local key = fname:sub(#prefix + 1)
  self:_store_columns(key, cols)
  return true
end

---@private
---@param files table[]
---@param start_index integer
function SchemaCache:_schedule_deferred_column_work(files, start_index)
  if start_index > #files then
    return
  end

  self.deferred_column_files_scheduled = #files - start_index + 1
  self.deferred_disk_work_scheduled = true
  local generation = self.disk_work_generation or 0
  local prefix = self.conn_id .. "_cols_"
  local index = start_index
  local now = os.time()
  local chunk_size = SYNC_COLUMN_FILE_LOAD_LIMIT

  local function step()
    if self.disk_work_generation ~= generation then
      self.deferred_disk_work_canceled = (self.deferred_disk_work_canceled or 0) + 1
      self.deferred_disk_work_scheduled = false
      return
    end

    local last = math.min(index + chunk_size - 1, #files)
    for i = index, last do
      local entry = files[i]
      if not self:_prune_if_old(entry.path, entry.stat, now) then
        self:_load_column_file(entry.path, prefix)
      end
    end
    index = last + 1
    if index <= #files then
      vim.schedule(step)
    else
      self.deferred_disk_work_scheduled = false
    end
  end

  vim.schedule(step)
end

---@private
---@param seen_paths? table<string, boolean>
function SchemaCache:_schedule_deferred_column_scan(seen_paths)
  seen_paths = seen_paths or {}
  local generation = self.disk_work_generation or 0
  local prefix = self.conn_id .. "_cols_"
  local now = os.time()
  local chunk_size = SYNC_COLUMN_FILE_LOAD_LIMIT
  local scan_budget = SYNC_COLUMN_FILE_SCAN_LIMIT
  local iter = nil
  local fallback_paths = nil
  local fallback_index = 1
  local tried_iter = false

  self.deferred_disk_work_scheduled = true
  self.deferred_disk_work_drained = false

  local function record_tick(advances)
    self.deferred_dir_advances_per_tick = math.max(self.deferred_dir_advances_per_tick or 0, advances)
  end

  local function next_path(state)
    while state.advances < scan_budget do
      local path = nil

      if vim.fs and type(vim.fs.dir) == "function" then
        if not tried_iter then
          tried_iter = true
          local ok, dir_iter = pcall(vim.fs.dir, self.cache_dir)
          if ok then
            iter = dir_iter
          end
        end
        if iter then
          local name, entry_type = iter()
          if not name then
            return nil, "done"
          end
          state.advances = state.advances + 1
          self.total_deferred_dir_advances = (self.total_deferred_dir_advances or 0) + 1
          if entry_type == "file"
            and name:sub(1, #prefix) == prefix
            and name:sub(-5) == ".json"
          then
            path = self.cache_dir .. "/" .. name
          end
        end
      end

      if not iter then
        if not fallback_paths then
          fallback_paths = vim.fn.glob(self.cache_dir .. "/" .. prefix .. "*.json", false, true)
        end
        path = fallback_paths[fallback_index]
        fallback_index = fallback_index + 1
        if not path then
          return nil, "done"
        end
        state.advances = state.advances + 1
        self.total_deferred_dir_advances = (self.total_deferred_dir_advances or 0) + 1
      end

      if path and not seen_paths[path] then
        seen_paths[path] = true
        return path, nil
      end
    end
    return nil, "budget"
  end

  local function step()
    if self.disk_work_generation ~= generation then
      self.deferred_disk_work_canceled = (self.deferred_disk_work_canceled or 0) + 1
      self.deferred_disk_work_scheduled = false
      return
    end

    local processed = 0
    local state = { advances = 0 }
    while processed < chunk_size do
      local path, status = next_path(state)
      if not path then
        record_tick(state.advances)
        if status == "done" then
          self.deferred_disk_work_scheduled = false
          self.deferred_disk_work_drained = true
        else
          vim.schedule(step)
        end
        return
      end

      self.deferred_column_files_scheduled = (self.deferred_column_files_scheduled or 0) + 1
      local stat = self:_file_stat(path)
      if not self:_prune_if_old(path, stat, now) then
        self:_load_column_file(path, prefix)
      end
      self.deferred_column_files_processed = (self.deferred_column_files_processed or 0) + 1
      processed = processed + 1
    end

    record_tick(state.advances)
    vim.schedule(step)
  end

  vim.schedule(step)
end

---@private
---@param structs DBStructure[]
---@param parent_schema string?
function SchemaCache:_flatten(structs, parent_schema)
  if not structs or structs == vim.NIL then
    return
  end

  for _, s in ipairs(structs) do
    local stype = s.type or ""
    local schema = s.schema or parent_schema or ""

    if stype == "schema" then
      local schema_name = schema ~= "" and schema or s.name
      if schema_name == "" then
        schema_name = "_default"
      end
      if not schema_filter.matches(schema_name, self.schema_scope) then
        goto continue
      end
      self.schemas[schema_name] = true
      if not self.tables[schema_name] then
        self.tables[schema_name] = {}
      end
      if s.children then
        self:_flatten(s.children, schema_name)
      end
    elseif stype == "table" or stype == "view" then
      if schema == "" then
        schema = "_default"
      end
      if not schema_filter.matches(schema, self.schema_scope) then
        goto continue
      end
      self.schemas[schema] = true
      if not self.tables[schema] then
        self.tables[schema] = {}
      end
      self.tables[schema][s.name] = { type = stype }
    elseif s.children then
      local next_schema = schema
      if next_schema == "" then
        -- Backward compatibility for adapters that model schema containers
        -- as empty-type nodes without explicit schema fields.
        next_schema = s.name or ""
        if next_schema ~= "" then
          if not schema_filter.matches(next_schema, self.schema_scope) then
            goto continue
          end
          self.schemas[next_schema] = true
          if not self.tables[next_schema] then
            self.tables[next_schema] = {}
          end
        end
      end
      self:_flatten(s.children, next_schema ~= "" and next_schema or parent_schema)
    end
    ::continue::
  end
end

-- ── Disk cache ──────────────────────────────────────────────

---@private
---@return string
function SchemaCache:_cache_path()
  return self.cache_dir .. "/" .. self.conn_id .. ".json"
end

---@private
---@param path string
---@param operation string
function SchemaCache:_remove_corrupt_file(path, operation)
  warn(string.format("dbee-lsp: corrupt cache while %s: %s", operation, path))
  os.remove(path)
end

---@private
---@param path string
function SchemaCache:_remove_legacy_schema_index(path)
  vim.g.dbee_lsp_schema_cache_legacy_v1_migrated = {
    conn_id = self.conn_id,
    path = path,
    version = SCHEMA_CACHE_VERSION,
  }
  os.remove(path)
end

---@private
---@param path string
function SchemaCache:_remove_legacy_column_cache(path)
  vim.g.dbee_lsp_column_cache_legacy_migrated = {
    conn_id = self.conn_id,
    path = path,
    version = SCHEMA_CACHE_VERSION,
  }
  os.remove(path)
end

---@private
---@param path string
---@param value any
---@param operation string
---@return boolean
function SchemaCache:_atomic_write_json(path, value, operation)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

  local ok, json = pcall(vim.json.encode, value)
  if not ok then
    warn(string.format("dbee-lsp: failed to encode cache while %s: %s", operation, path))
    return false
  end

  local uv = vim.uv or vim.loop
  local suffix = uv and tostring(uv.hrtime()) or tostring(math.random(1000000))
  local tmp = path .. ".tmp." .. suffix
  local f, open_err = io.open(tmp, "w")
  if not f then
    warn(string.format("dbee-lsp: failed to open cache temp file while %s: %s (%s)", operation, tmp, open_err or "unknown"))
    return false
  end

  local write_ok, write_err = pcall(function()
    f:write(json)
    f:flush()
  end)
  local close_ok, close_err = f:close()
  if not write_ok or not close_ok then
    os.remove(tmp)
    warn(string.format("dbee-lsp: failed to write cache while %s: %s (%s)", operation, path, write_err or close_err or "unknown"))
    return false
  end

  local renamed, rename_err = os.rename(tmp, path)
  if not renamed then
    os.remove(tmp)
    warn(string.format("dbee-lsp: failed to rename cache while %s: %s (%s)", operation, path, rename_err or "unknown"))
    return false
  end

  return true
end

---@private
---@param table_key string "schema.table"
---@return string
function SchemaCache:_columns_cache_path(table_key)
  -- sanitize key for filesystem
  local safe = table_key:gsub("[^%w_.]", "_")
  return self.cache_dir .. "/" .. self.conn_id .. "_cols_" .. safe .. ".json"
end

--- Save the flattened table/schema index to disk.
function SchemaCache:save_to_disk()
  vim.fn.mkdir(self.cache_dir, "p")

  local data = {
    version = SCHEMA_CACHE_VERSION,
    conn_id = self.conn_id,
    schema_filter_signature = self.schema_filter_signature,
    root_mode = self.root_mode or "full",
    root_loaded_schemas = vim.tbl_keys(self.loaded_schemas or {}),
    schemas = vim.tbl_keys(self.schemas),
    tables = {},
  }
  for schema, tbls in pairs(self.tables) do
    data.tables[schema] = {}
    for name, info in pairs(tbls) do
      data.tables[schema][name] = info.type
    end
  end

  self:_atomic_write_json(self:_cache_path(), data, "saving schema index")
end

--- Load the flattened table/schema index from disk.
---@return boolean success
function SchemaCache:load_from_disk()
  local path = self:_cache_path()
  local f = io.open(path, "r")
  if not f then
    return false
  end

  local content = f:read("*a")
  f:close()

  local ok, data = pcall(vim.json.decode, content)
  if not ok or not data then
    self:_remove_corrupt_file(path, "loading schema index")
    return false
  end

  if type(data) ~= "table" then
    self:_remove_corrupt_file(path, "loading schema index")
    return false
  end

  if data.version == nil then
    local legacy = self:_normalize_schema_index(data)
    if legacy then
      self:_remove_legacy_schema_index(path)
    else
      self:_remove_corrupt_file(path, "loading schema index")
    end
    return false
  end

  if data.version == 2 then
    local legacy = self:_normalize_schema_index(data)
    if legacy then
      self:_remove_legacy_schema_index(path)
    else
      self:_remove_corrupt_file(path, "loading schema index")
    end
    return false
  end

  if data.version ~= SCHEMA_CACHE_VERSION then
    self:_remove_corrupt_file(path, "loading schema index")
    return false
  end

  if data.schema_filter_signature ~= self.schema_filter_signature then
    vim.g.dbee_lsp_schema_cache_filter_signature_migrated = {
      conn_id = self.conn_id,
      path = path,
      expected = self.schema_filter_signature,
      actual = data.schema_filter_signature,
    }
    os.remove(path)
    return false
  end

  local normalized = self:_normalize_schema_index(data)
  if not normalized then
    self:_remove_corrupt_file(path, "loading schema index")
    return false
  end

  self:_bump_metadata_generation("load_from_disk")
  self.schemas = {}
  self.tables = {}
  self.columns = {}
  self:_bump_disk_work_generation()
  self:_reset_indexes()
  self.loaded_schemas = {}
  self.root_mode = data.root_mode or "full"

  for _, s in ipairs(normalized.schemas) do
    self.schemas[s] = true
  end

  for _, loaded_schema in ipairs(data.root_loaded_schemas or {}) do
    if type(loaded_schema) == "string" then
      self.loaded_schemas[self:_loaded_schema_key(loaded_schema)] = true
    end
  end

  for schema, tbls in pairs(normalized.tables) do
    self.tables[schema] = {}
    for name, stype in pairs(tbls) do
      self.tables[schema][name] = { type = stype }
    end
  end

  if self.root_mode == "full" and next(self.loaded_schemas) == nil then
    for schema in pairs(self.schemas) do
      self:_mark_schema_loaded(schema)
    end
  end

  self:_rebuild_structure_indexes()
  self:_load_columns_from_disk()
  self:_rebuild_column_indexes()
  return true
end

--- Save columns for a single table to disk.
---@private
---@param key string "schema.table"
---@param cols Column[]
function SchemaCache:_save_columns_to_disk(key, cols)
  vim.fn.mkdir(self.cache_dir, "p")
  local path = self:_columns_cache_path(key)
  self:_atomic_write_json(path, {
    version = SCHEMA_CACHE_VERSION,
    schema_filter_signature = self.schema_filter_signature,
    columns = cols,
  }, "saving columns")
end

--- Load all cached column files for this connection from disk.
---@private
function SchemaCache:_load_columns_from_disk()
  self.sync_column_files_loaded = 0
  self.sync_column_files_discovered = 0
  self.sync_column_files_scanned = 0
  self.sync_column_discovery_degraded = false
  self.deferred_column_files_scheduled = 0
  self.deferred_column_files_processed = 0
  self.deferred_dir_advances_per_tick = 0
  self.total_deferred_dir_advances = 0
  self.deferred_disk_work_scheduled = false
  self.deferred_disk_work_drained = false

  local prefix = self.conn_id .. "_cols_"
  local files = self:_column_cache_files(SYNC_COLUMN_FILE_LOAD_LIMIT)
  local seen_paths = {}
  local now = os.time()
  local sync_limit = math.min(#files, SYNC_COLUMN_FILE_LOAD_LIMIT)
  for i = 1, sync_limit do
    local entry = files[i]
    seen_paths[entry.path] = true
    if not self:_prune_if_old(entry.path, entry.stat, now) then
      if self:_load_column_file(entry.path, prefix) then
        self.sync_column_files_loaded = self.sync_column_files_loaded + 1
      end
    end
  end

  self:_schedule_deferred_column_scan(seen_paths)
end

--- Schedule column disk pruning without running from completion handlers.
function SchemaCache:schedule_disk_prune()
  self:_schedule_deferred_column_scan({})
end

function SchemaCache:delete_column_cache_for_filter_change()
  local prefix = self.conn_id .. "_cols_"
  local iter = nil
  if vim.fs and type(vim.fs.dir) == "function" then
    local ok, dir_iter = pcall(vim.fs.dir, self.cache_dir)
    if ok then
      iter = function()
        return dir_iter()
      end
    end
  end
  if not iter then
    local uv = vim.uv or vim.loop
    local handle = uv and uv.fs_scandir(self.cache_dir)
    if handle then
      iter = function()
        return uv.fs_scandir_next(handle)
      end
    end
  end
  iter = iter or function()
    return nil
  end

  self.pending_delete_total_files = 0
  self.pending_delete_sync_deleted = 0
  self.pending_delete_sync_scanned = 0
  self.pending_delete_deferred_scanned = 0
  self.pending_delete_deferred_drain_count = 0
  self:_bump_disk_work_generation()
  local generation = self.disk_work_generation

  local function next_delete_path(state)
    while state.scanned < FILTER_DELETE_SYNC_SCAN_LIMIT do
      local name, entry_type = iter()
      if not name then
        return nil, "done"
      end
      state.scanned = state.scanned + 1
      if entry_type == "file" and name:sub(1, #prefix) == prefix and name:sub(-5) == ".json" then
        self.pending_delete_total_files = (self.pending_delete_total_files or 0) + 1
        return self.cache_dir .. "/" .. name
      end
    end
    return nil, "budget"
  end

  local sync_state = { scanned = 0 }
  local sync_deleted_attempts = 0
  local status = nil
  while sync_deleted_attempts < FILTER_DELETE_SYNC_DELETE_LIMIT do
    local path, next_status = next_delete_path(sync_state)
    status = next_status
    if not path then
      break
    end
    sync_deleted_attempts = sync_deleted_attempts + 1
    if os.remove(path) then
      self.pending_delete_sync_deleted = self.pending_delete_sync_deleted + 1
    end
  end
  self.pending_delete_sync_scanned = sync_state.scanned

  local function step()
    if self.disk_work_generation ~= generation then
      self.deferred_disk_work_canceled = (self.deferred_disk_work_canceled or 0) + 1
      self.deferred_disk_work_scheduled = false
      return
    end
    local state = { scanned = 0 }
    local deleted_attempts = 0
    local step_status = nil
    while deleted_attempts < FILTER_DELETE_SYNC_DELETE_LIMIT do
      local path, next_status = next_delete_path(state)
      step_status = next_status
      if not path then
        break
      end
      deleted_attempts = deleted_attempts + 1
      os.remove(path)
    end
    self.pending_delete_deferred_scanned = (self.pending_delete_deferred_scanned or 0) + state.scanned
    self.pending_delete_deferred_drain_count = self.pending_delete_deferred_drain_count + 1
    if step_status == "done" then
      self.deferred_disk_work_scheduled = false
      self.deferred_disk_work_drained = true
    else
      vim.schedule(step)
    end
  end

  if status ~= "done" then
    self.deferred_disk_work_scheduled = true
    self.deferred_disk_work_drained = false
    vim.schedule(step)
  else
    self.deferred_disk_work_scheduled = false
    self.deferred_disk_work_drained = true
  end
end

--- Get test-visible cache stats.
---@return table
function SchemaCache:get_stats()
  return {
    column_entry_count = self:_column_entry_count(),
    column_evictions = self.column_evictions or 0,
    disk_pruned = self.disk_pruned or 0,
    sync_column_files_discovered = self.sync_column_files_discovered or 0,
    sync_column_files_scanned = self.sync_column_files_scanned or 0,
    sync_column_discovery_degraded = self.sync_column_discovery_degraded == true,
    sync_column_files_loaded = self.sync_column_files_loaded or 0,
    deferred_column_files_scheduled = self.deferred_column_files_scheduled or 0,
    deferred_column_files_processed = self.deferred_column_files_processed or 0,
    deferred_dir_advances_per_tick = self.deferred_dir_advances_per_tick or 0,
    total_deferred_dir_advances = self.total_deferred_dir_advances or 0,
    deferred_disk_work_drained = self.deferred_disk_work_drained == true,
    disk_work_generation = self.disk_work_generation or 0,
    deferred_disk_work_canceled = self.deferred_disk_work_canceled or 0,
    max_columns_in_memory = MAX_COLUMNS_IN_MEMORY,
    sync_column_file_load_limit = SYNC_COLUMN_FILE_LOAD_LIMIT,
    sync_column_file_scan_limit = SYNC_COLUMN_FILE_SCAN_LIMIT,
    pending_delete_total_files = self.pending_delete_total_files or 0,
    pending_delete_sync_deleted = self.pending_delete_sync_deleted or 0,
    pending_delete_sync_scanned = self.pending_delete_sync_scanned or 0,
    pending_delete_deferred_scanned = self.pending_delete_deferred_scanned or 0,
    pending_delete_deferred_drain_count = self.pending_delete_deferred_drain_count or 0,
  }
end

-- ── Public API ──────────────────────────────────────────────

local function quoted_option(opts, primary, fallback)
  if type(opts) ~= "table" then
    return nil
  end
  if opts[primary] ~= nil then
    return opts[primary]
  end
  if fallback and opts[fallback] ~= nil then
    return opts[fallback]
  end
  return nil
end

---@private
---@param column_name string?
---@param candidate string?
---@param quoted boolean?
---@return boolean
function SchemaCache:_column_name_matches(column_name, candidate, quoted)
  if type(column_name) ~= "string" or type(candidate) ~= "string" then
    return false
  end
  if self.fold_id == "case_insensitive" then
    return schema_name_canonical.equivalent(column_name, quoted == true, candidate, quoted == true, self.fold_id)
  end
  if quoted == true then
    return column_name == candidate
  end
  if quoted == false then
    if not self:_can_fold_alias(column_name) then
      return false
    end
    return schema_name_canonical.equivalent(column_name, false, candidate, false, self.fold_id)
  end
  if column_name == candidate then
    return true
  end
  if not self:_can_fold_alias(column_name) then
    return false
  end
  return schema_name_canonical.equivalent(column_name, false, candidate, false, self.fold_id)
end

---@private
---@param key string
---@param column_name string
---@param quoted boolean?
---@return Column?
function SchemaCache:_find_cached_column(key, column_name, quoted)
  for _, col in ipairs(self.columns[key] or {}) do
    if self:_column_name_matches(col.name, column_name, quoted) then
      return col
    end
  end
  return nil
end

---@private
---@param kind "schema"|"table"|"column"
---@param identity table
---@return table
function SchemaCache:_completion_data(kind, identity)
  return {
    source = "dbee",
    version = 1,
    kind = kind,
    schema = identity.schema,
    table = identity.table,
    column = identity.column,
    schema_quoted = identity.schema ~= nil and true or nil,
    table_quoted = identity.table ~= nil and true or nil,
    column_quoted = identity.column ~= nil and true or nil,
    schema_exact = identity.schema,
    table_exact = identity.table,
    column_exact = identity.column,
    canonical_path = table.concat({
      tostring(identity.schema or ""),
      tostring(identity.table or ""),
      tostring(identity.column or ""),
    }, "."),
    cache_identity = self:cache_identity(),
    cache_generation = self:generation(),
    root_epoch = self:metadata_root_epoch(),
  }
end

---@private
---@param items lsp.CompletionItem[]
---@param kind "schema"|"table"|"column"
---@param identity_for_item fun(item: lsp.CompletionItem): table?
---@return lsp.CompletionItem[]
function SchemaCache:_copy_items_with_data(items, kind, identity_for_item)
  local copied = copy_items(items)
  for _, item in ipairs(copied) do
    local identity = identity_for_item(item)
    if identity then
      item.data = self:_completion_data(kind, identity)
    end
  end
  return copied
end

---@return integer
function SchemaCache:generation()
  return self.metadata_generation or 0
end

---@return integer
function SchemaCache:metadata_root_epoch()
  return self.metadata_root_epoch_value or 0
end

---@return string
function SchemaCache:cache_identity()
  return self.cache_identity_value or tostring(self.conn_id or "")
end

---@return SchemaFilterAuthority
function SchemaCache:read_lsp_authority()
  return schema_filter_authority.read(self.handler, self.conn_id)
end

---@param schema string?
---@param scope table?
---@return boolean
function SchemaCache:schema_in_current_scope(schema, scope)
  if not schema or schema == "" then
    return false
  end
  local active_scope = scope or self.schema_scope
  return schema_filter.matches(schema, active_scope)
end

---@private
---@return table?
function SchemaCache:_fresh_lsp_scope()
  local authority = self:read_lsp_authority()
  if authority.status == "authority_unavailable" then
    return nil, "authority_unavailable"
  end
  if authority.status == "api_absent_legacy" then
    return schema_filter_authority.legacy_implicit_all(), nil
  end
  return authority.scope, nil
end

---@param schema string
---@param opts? { schema_quoted?: boolean, quoted?: boolean }
---@return table? metadata, string? reason
function SchemaCache:get_schema_metadata(schema, opts)
  opts = opts or {}
  local scope, reason = self:_fresh_lsp_scope()
  if not scope then
    return nil, reason
  end
  local actual_schema = self:find_schema(schema, {
    quoted = quoted_option(opts, "schema_quoted", "quoted"),
  })
  if not actual_schema or not self:schema_in_current_scope(actual_schema, scope) then
    return nil, "missing_or_filtered"
  end

  local table_names = vim.tbl_keys(self.tables[actual_schema] or {})
  table.sort(table_names)
  return {
    kind = "schema",
    schema = actual_schema,
    tables = table_names,
    table_count = #table_names,
    loaded = self.root_mode ~= "schemas_only" or self:_schema_loaded_in(actual_schema, self.loaded_schemas),
  }
end

---@param schema string?
---@param table_name string
---@param opts? { schema_quoted?: boolean, table_quoted?: boolean, max_columns?: integer }
---@return table? metadata, string? reason
function SchemaCache:get_table_metadata(schema, table_name, opts)
  opts = opts or {}
  local scope, reason = self:_fresh_lsp_scope()
  if not scope then
    return nil, reason
  end

  local actual_schema, actual_table
  if schema and schema ~= "" then
    actual_table, actual_schema = self:find_table_in_schema(schema, table_name, opts)
  else
    actual_table, actual_schema = self:find_table(table_name, { table_quoted = opts.table_quoted })
  end
  if not actual_schema or not actual_table or not self:schema_in_current_scope(actual_schema, scope) then
    return nil, "missing_or_filtered"
  end

  local info = (self.tables[actual_schema] or {})[actual_table]
  if not info then
    return nil, "missing"
  end

  local key = table_key(actual_schema, actual_table)
  local columns = self.columns[key]
  local copied_columns, copied_count = copy_column_preview(columns, opts.max_columns)
  local column_count = columns and #columns or nil
  return {
    kind = "table",
    schema = actual_schema,
    table = actual_table,
    table_type = info.type or "table",
    columns = copied_columns,
    column_count = column_count,
    columns_copied = copied_count,
    columns_truncated = column_count ~= nil and copied_count < column_count,
    columns_truncated_at = column_count ~= nil and copied_count or nil,
    columns_loaded = columns ~= nil,
  }
end

---@param schema string?
---@param table_name string
---@param column_name string
---@param opts? { schema_quoted?: boolean, table_quoted?: boolean, column_quoted?: boolean }
---@return table? metadata, string? reason
function SchemaCache:get_column_metadata(schema, table_name, column_name, opts)
  opts = opts or {}
  local scope, reason = self:_fresh_lsp_scope()
  if not scope then
    return nil, reason
  end

  local actual_schema, actual_table
  if schema and schema ~= "" then
    actual_table, actual_schema = self:find_table_in_schema(schema, table_name, opts)
  else
    actual_table, actual_schema = self:find_table(table_name, { table_quoted = opts.table_quoted })
  end
  if not actual_schema or not actual_table or not self:schema_in_current_scope(actual_schema, scope) then
    return nil, "missing_or_filtered"
  end

  local info = (self.tables[actual_schema] or {})[actual_table]
  if not info then
    return nil, "missing"
  end

  local key = table_key(actual_schema, actual_table)
  local col = self:_find_cached_column(key, column_name, opts.column_quoted)
  if not col then
    return nil, "missing_column"
  end

  local meta = vim.deepcopy(col)
  meta.kind = "column"
  meta.schema = actual_schema
  meta.table = actual_table
  meta.column = col.name
  meta.type = col.type
  return meta
end

--- Get all schema names.
---@return string[]
function SchemaCache:get_schemas()
  local schemas = vim.tbl_keys(self.schemas)
  table.sort(schemas)
  return schemas
end

--- Get all table/view names in a schema.
---@param schema string
---@return table<string, { type: string }>
function SchemaCache:get_tables(schema)
  return self.tables[schema] or {}
end

--- Get all table names across all schemas.
---@return string[]
function SchemaCache:get_all_table_names()
  return vim.deepcopy(self.all_table_names)
end

--- Get precomputed schema completion items.
---@param opts? { include_data?: boolean }
---@return lsp.CompletionItem[]
function SchemaCache:get_schema_completion_items(opts)
  if not (opts and opts.include_data == true) then
    return copy_items(self.schema_items)
  end
  return self:_copy_items_with_data(self.schema_items, "schema", function(item)
    return { schema = item.label }
  end)
end

--- Get precomputed table completion items for a schema.
---@param schema string
---@param opts? { schema_quoted?: boolean, quoted?: boolean }
---@return lsp.CompletionItem[]
function SchemaCache:get_table_completion_items(schema, opts)
  opts = opts or {}
  local actual_schema = self:find_schema(schema, { quoted = quoted_option(opts, "schema_quoted", "quoted") }) or schema
  if opts.include_data ~= true then
    return copy_items(self.table_items_by_schema[actual_schema])
  end
  return self:_copy_items_with_data(self.table_items_by_schema[actual_schema], "table", function(item)
    return {
      schema = actual_schema,
      table = item.label,
    }
  end)
end

---@param schema string
---@param opts? { schema_quoted?: boolean, quoted?: boolean }
function SchemaCache:schema_status(schema, opts)
  opts = opts or {}
  local actual_schema = self:find_schema(schema, { quoted = quoted_option(opts, "schema_quoted", "quoted") }) or schema
  if not schema_filter.matches(actual_schema, self.schema_scope) then
    return "filtered_out", actual_schema
  end
  if not self:find_schema(actual_schema, { quoted = true }) then
    return "missing", actual_schema
  end
  if self.root_mode == "schemas_only" and not self:_schema_loaded_in(actual_schema, self.loaded_schemas) then
    return "active_unloaded", actual_schema
  end
  return "loaded", actual_schema
end

function SchemaCache:has_unloaded_active_schemas()
  if self.root_mode ~= "schemas_only" then
    return false
  end
  for schema in pairs(self.schemas or {}) do
    if schema_filter.matches(schema, self.schema_scope) and not self:_schema_loaded_in(schema, self.loaded_schemas) then
      return true
    end
  end
  return false
end

---@param schema string
---@param opts? { schema_quoted?: boolean, quoted?: boolean }
function SchemaCache:get_schema_table_completion_async(schema, opts)
  local status, actual_schema = self:schema_status(schema, opts)
  if status == "loaded" then
    return {
      items = self:get_table_completion_items(actual_schema, {
        schema_quoted = true,
        include_data = opts and opts.include_data == true,
      }),
      is_incomplete = false,
    }
  end
  if status ~= "active_unloaded" then
    return {
      items = {},
      is_incomplete = false,
      reason = status,
    }
  end

  if not self.handler or type(self.handler.connection_get_schema_objects_singleflight) ~= "function" then
    return {
      items = {},
      is_incomplete = false,
      reason = "schema_object_api_unavailable",
    }
  end

  local root_epoch = self:_root_epoch({})
  local request_id = self:_next_request_id()
  local request = self.handler:connection_get_schema_objects_singleflight({
    conn_id = self.conn_id,
    schema = actual_schema,
    consumer = "lsp-schema-dot",
    priority = "lsp",
    request_id = request_id,
    caller_token = "lsp",
    callback = function(data)
      self:on_schema_objects_loaded(data)
    end,
  })
  if request and request.error_kind then
    return {
      items = {},
      is_incomplete = false,
      reason = request.error_kind,
    }
  end

  return {
    items = {},
    is_incomplete = true,
    root_epoch = root_epoch,
  }
end

--- Get precomputed table completion items across all schemas.
---@param opts? { include_data?: boolean }
---@return lsp.CompletionItem[]
function SchemaCache:get_all_table_completion_items(opts)
  if not (opts and opts.include_data == true) then
    return copy_items(self.all_table_items)
  end
  return self:_copy_items_with_data(self.all_table_items, "table", function(item)
    if self.all_table_item_ambiguous_by_label[item.label] then
      return nil
    end
    local schema = self.all_table_item_source_by_label[item.label]
    if not schema then
      return nil
    end
    return {
      schema = schema,
      table = item.label,
    }
  end)
end

--- Get precomputed column completion items for a table.
---@param schema string
---@param table_name string
---@param opts? { schema_quoted?: boolean, table_quoted?: boolean }
---@return lsp.CompletionItem[]
function SchemaCache:get_column_completion_items(schema, table_name, opts)
  opts = opts or {}
  local actual_schema = self:find_schema(schema, { quoted = opts.schema_quoted }) or schema or "_default"
  local actual_table = self:find_table_in_schema(actual_schema, table_name, {
    schema_quoted = true,
    table_quoted = opts.table_quoted,
  }) or table_name
  if opts.include_data ~= true then
    return copy_items(self.column_items_by_key[table_key(actual_schema, actual_table)])
  end
  return self:_copy_items_with_data(self.column_items_by_key[table_key(actual_schema, actual_table)], "column", function(item)
    return {
      schema = actual_schema,
      table = actual_table,
      column = item.label,
    }
  end)
end

--- Find a schema name using exact or folded semantics.
---@param schema_name string?
---@param opts? { quoted?: boolean }
---@return string?
function SchemaCache:find_schema(schema_name, opts)
  if not schema_name or schema_name == "" then
    return nil
  end
  return self:_resolve_lookup(self.schema_lookup_exact, self.schema_lookup, schema_name, opts and opts.quoted)
end

--- Get columns through the non-blocking async miss path.
---@param schema string
---@param table_name string
---@param opts? { probe_if_missing?: boolean, materializations?: string[], root_epoch?: integer, schema_quoted?: boolean, table_quoted?: boolean }
---@return { columns: Column[], is_incomplete: boolean, in_flight: boolean, reason?: string, resolved_schema?: string, resolved_name?: string }
function SchemaCache:get_columns_async(schema, table_name, opts)
  opts = opts or {}
  schema = self:find_schema(schema, { quoted = opts.schema_quoted }) or schema or "_default"
  table_name = table_name or ""

  if not schema_filter.matches(schema, self.schema_scope) then
    return {
      columns = {},
      is_incomplete = false,
      in_flight = false,
      reason = "filtered_out",
    }
  end

  local actual_table = self:find_table_in_schema(schema, table_name, {
    schema_quoted = true,
    table_quoted = opts.table_quoted,
  })
  if actual_table then
    table_name = actual_table
  end

  local key = table_key(schema, table_name)
  if self.columns[key] then
    self:_touch_column(key)
    return {
      columns = self.columns[key],
      is_incomplete = false,
      in_flight = false,
      resolved_schema = schema,
      resolved_name = table_name,
    }
  end

  local root_epoch = self:_root_epoch(opts)
  local materializations = opts.materializations
    or (opts.materialization and { opts.materialization })
    or MATERIALIZATIONS
  local chain_key = self:_async_chain_key(
    self.conn_id,
    schema,
    table_name,
    materialization_identity(materializations),
    root_epoch
  )
  if self.async_failed[chain_key] then
    return {
      columns = {},
      is_incomplete = false,
      in_flight = false,
      reason = "previous_failure",
    }
  end

  if self.async_chains[chain_key] then
    self:_mark_completion_refresh_eligible(chain_key)
    return {
      columns = {},
      is_incomplete = true,
      in_flight = true,
    }
  end

  local tbl_info = (self.tables[schema] or {})[table_name]
  if not tbl_info and not opts.probe_if_missing then
    return {
      columns = {},
      is_incomplete = false,
      in_flight = false,
      reason = "unresolved_table",
    }
  end

  local schema_candidates = { schema }
  local table_candidates = { table_name }
  if opts.probe_if_missing then
    schema_candidates = self:_schema_probe_candidates(schema, opts.schema_quoted, true)
    table_candidates = self:_identifier_probe_candidates(table_name, opts.table_quoted)
  end

  local entry = {
    conn_id = self.conn_id,
    root_epoch = root_epoch,
    chain_key = chain_key,
    schema_candidates = schema_candidates,
    table_candidates = table_candidates,
    materializations = materializations,
    schema_index = 1,
    table_index = 1,
    materialization_index = 1,
    nio = nio,
  }

  if not self:_queue_async_probe(entry) then
    return {
      columns = {},
      is_incomplete = false,
      in_flight = false,
      reason = "queue_failed",
    }
  end

  local resolved_key = (entry.schema and entry.table_name) and table_key(entry.schema, entry.table_name) or key
  local cols_key = self.columns[resolved_key] and resolved_key or key
  local cols = self.columns[cols_key]
  if cols then
    self:_touch_column(cols_key)
    return {
      columns = cols,
      is_incomplete = false,
      in_flight = false,
      resolved_schema = entry.schema or schema,
      resolved_name = entry.table_name or table_name,
    }
  end

  if not self.async_chains[chain_key] then
    return {
      columns = {},
      is_incomplete = false,
      in_flight = false,
      reason = self.async_failed[chain_key] and "previous_failure" or "completed_empty",
    }
  end

  self:_mark_completion_refresh_eligible(chain_key)
  return {
    columns = {},
    is_incomplete = true,
    in_flight = true,
  }
end

--- Apply a structure_children_loaded column payload to the async cache.
---@param data { conn_id?: connection_id, request_id?: integer, branch_id?: string, root_epoch?: integer, kind?: string, columns?: Column[], error?: any }
---@return boolean applied
function SchemaCache:on_columns_loaded(data)
  if not data or data.kind ~= "columns" then
    return false
  end
  if data.conn_id ~= self.conn_id then
    return false
  end

  local payload_epoch = tonumber(data.root_epoch) or 0
  if payload_epoch < self:authoritative_root_epoch() then
    return false
  end

  local probe = nil
  for _, candidate in pairs(self.async_inflight) do
    if candidate.conn_id == data.conn_id
      and candidate.request_id == data.request_id
      and candidate.branch_id == data.branch_id
      and candidate.root_epoch == payload_epoch
    then
      probe = candidate
      break
    end
  end
  if not probe then
    return false
  end

  self.async_inflight[probe.active_key] = nil
  local entries = probe.entries or {}

  if not schema_filter.matches(probe.schema, self.schema_scope) then
    for _, entry in ipairs(entries) do
      entry.active_key = nil
      self.async_chains[entry.chain_key] = nil
      self.completion_refresh_eligible[entry.chain_key] = nil
    end
    return false
  end

  if data.error then
    self.async_failed[probe.active_key] = true
    for _, entry in ipairs(entries) do
      entry.active_key = nil
      self.async_chains[entry.chain_key] = nil
      self.completion_refresh_eligible[entry.chain_key] = nil
      self.async_failed[entry.chain_key] = true
    end
    return true
  end

  local cols = data.columns or {}
  if #cols == 0 then
    self.async_failed[probe.active_key] = true
    local advanced = false
    for _, entry in ipairs(entries) do
      entry.active_key = nil
      if self:_advance_async_probe(entry) then
        advanced = true
      end
    end
    return advanced
  end

  if not (self.tables[probe.schema] and self.tables[probe.schema][probe.table_name]) then
    self:_upsert_table_index(probe.schema, probe.table_name, probe.materialization)
  end
  local key = table_key(probe.schema, probe.table_name)
  self:_store_columns(key, cols, { root_epoch = payload_epoch })
  self:_save_columns_to_disk(key, cols)
  local should_notify = self:_consume_completion_refresh_eligible(entries)
  for _, entry in ipairs(entries) do
    entry.active_key = nil
    self.async_chains[entry.chain_key] = nil
  end
  if should_notify then
    self:_queue_completion_refresh_notification(probe, data.request_id, payload_epoch)
  end
  return true
end

function SchemaCache:on_schema_objects_loaded(data)
  if not data or data.conn_id ~= self.conn_id then
    return false
  end
  if data.error or data.error_kind then
    return false
  end
  local schema = self:find_schema(data.schema, { quoted = true }) or data.schema
  if not schema or schema == "" then
    return false
  end
  if not schema_filter.matches(schema, self.schema_scope) then
    return false
  end

  self:_bump_metadata_generation("on_schema_objects_loaded", data.root_epoch)
  self.schemas[schema] = true
  self.tables[schema] = self.tables[schema] or {}
  local filtered_objects = schema_filter.filter_structures(data.objects or {}, self.schema_scope)
  local function apply_structs(structs, parent_schema)
    for _, struct in ipairs(structs or {}) do
      local stype = struct.type or ""
      local current_schema = struct.schema or parent_schema or schema
      if stype == "schema" then
        current_schema = struct.schema or struct.name or schema
        self.schemas[current_schema] = true
        self.tables[current_schema] = self.tables[current_schema] or {}
        apply_structs(struct.children or {}, current_schema)
      elseif stype == "table" or stype == "view" then
        self.tables[current_schema] = self.tables[current_schema] or {}
        self.tables[current_schema][struct.name] = { type = stype }
      elseif struct.children then
        apply_structs(struct.children, current_schema)
      end
    end
  end
  apply_structs(filtered_objects, schema)
  self:_mark_schema_loaded(schema)
  self:_rebuild_structure_indexes()
  self:save_to_disk()
  return true
end

--- Cancel or retire all async column miss state.
---@param _reason? string
---@param _opts? table
function SchemaCache:cancel_async(_reason, _opts)
  self.async_inflight = {}
  self.async_chains = {}
  self.async_failed = {}
  self.completion_refresh_eligible = {}
  self.completion_refresh_pending = {}
  self:_bump_disk_work_generation()
end

--- Get columns for a specific table, lazy-loading from handler on first access.
--- Results are cached to disk for subsequent sessions.
---@param schema string
---@param table_name string
---@param opts? { probe_if_missing?: boolean, materializations?: string[], schema_quoted?: boolean, table_quoted?: boolean }
---@return Column[]
function SchemaCache:get_columns(schema, table_name, opts)
  opts = opts or {}
  schema = schema or "_default"

  -- Normalize schema casing against known cache entries.
  schema = self:find_schema(schema, { quoted = opts.schema_quoted }) or schema

  local key = table_key(schema, table_name)
  if self.columns[key] then
    self:_touch_column(key)
    return self.columns[key]
  end

  local actual_table = self:find_table_in_schema(schema, table_name, {
    schema_quoted = true,
    table_quoted = opts.table_quoted,
  })
  if actual_table then
    table_name = actual_table
    key = table_key(schema, table_name)
    if self.columns[key] then
      self:_touch_column(key)
      return self.columns[key]
    end
  end

  local tbl_info = (self.tables[schema] or {})[table_name]
  if not tbl_info then
    local default_table = self:find_table_in_schema("_default", table_name, {
      schema_quoted = true,
      table_quoted = opts.table_quoted,
    })
    tbl_info = default_table and (self.tables["_default"] or {})[default_table] or nil
    if tbl_info then
      schema = "_default"
      table_name = default_table
      key = table_key(schema, table_name)
      if self.columns[key] then
        self:_touch_column(key)
        return self.columns[key]
      end
    end
  end

  if not tbl_info then
    -- Normalize table casing against known entries in this schema.
    table_name = self:find_table_in_schema(schema, table_name, {
      schema_quoted = true,
      table_quoted = opts.table_quoted,
    }) or table_name
    tbl_info = (self.tables[schema] or {})[table_name]
    key = table_key(schema, table_name)
    if tbl_info and self.columns[key] then
      self:_touch_column(key)
      return self.columns[key]
    end
  end

  local function fetch_columns(fetch_schema, fetch_table, materialization)
    local query_schema = (fetch_schema == "_default") and "" or fetch_schema
    local ok, cols = pcall(self.handler.connection_get_columns, self.handler, self.conn_id, {
      table = fetch_table,
      schema = query_schema,
      materialization = materialization,
    })
    if not ok or not cols or #cols == 0 then
      return nil
    end
    return cols
  end

  local cols = nil
  local resolved_schema = schema
  local resolved_table = table_name
  local resolved_type = tbl_info and tbl_info.type or "table"

  if tbl_info then
    cols = fetch_columns(schema, table_name, tbl_info.type)
    if not cols then
      for _, candidate_table in ipairs(self:_identifier_probe_candidates(table_name, opts.table_quoted)) do
        if candidate_table ~= table_name then
          resolved_table = candidate_table
          cols = fetch_columns(schema, resolved_table, tbl_info.type)
          if cols then
            break
          end
        end
      end
    end
  elseif opts.probe_if_missing then
    local schema_candidates, table_candidates = {}, {}
    local schema_seen, table_seen = {}, {}

    local function add_schema_candidate(name)
      if not name or name == "" then
        return
      end
      if schema_seen[name] then
        return
      end
      schema_seen[name] = true
      schema_candidates[#schema_candidates + 1] = name
    end

    local function add_table_candidate(name)
      if not name or name == "" then
        return
      end
      if table_seen[name] then
        return
      end
      table_seen[name] = true
      table_candidates[#table_candidates + 1] = name
    end

    -- Prefer an existing resolved schema, then adapter-aware canonical candidates.
    for _, candidate_schema in ipairs(self:_schema_probe_candidates(schema, opts.schema_quoted, false)) do
      add_schema_candidate(candidate_schema)
    end
    for _, candidate_table in ipairs(self:_identifier_probe_candidates(table_name, opts.table_quoted)) do
      add_table_candidate(candidate_table)
    end

    local materializations = opts.materializations or { "table", "view" }
    for _, candidate_schema in ipairs(schema_candidates) do
      for _, candidate_table in ipairs(table_candidates) do
        for _, materialization in ipairs(materializations) do
          cols = fetch_columns(candidate_schema, candidate_table, materialization)
          if cols then
            resolved_schema = candidate_schema
            resolved_table = candidate_table
            resolved_type = materialization
            break
          end
        end
        if cols then
          break
        end
      end
      if cols then
        break
      end
    end
  end

  if not cols or #cols == 0 then
    return {}
  end

  if not self.tables[resolved_schema] then
    self.tables[resolved_schema] = {}
  end
  self.schemas[resolved_schema] = true
  self.tables[resolved_schema][resolved_table] = { type = resolved_type }
  self:_rebuild_structure_indexes()

  key = table_key(resolved_schema, resolved_table)
  self:_store_columns(key, cols)
  self:_save_columns_to_disk(key, cols)
  return cols
end

--- Get all columns that are already cached (no lazy loading).
---@return table<string, Column[]> keyed by "schema.table"
function SchemaCache:get_cached_columns()
  return self.columns
end

--- Find a table within a specific schema.
---@param schema_name string
---@param table_name string
---@param opts? { schema_quoted?: boolean, table_quoted?: boolean }
---@return string? actual_name, string? actual_schema
function SchemaCache:find_table_in_schema(schema_name, table_name, opts)
  opts = opts or {}
  local actual_schema = self:find_schema(schema_name, { quoted = opts.schema_quoted }) or schema_name
  if not table_name or table_name == "" then
    return nil, actual_schema
  end
  local exact_lookup = self.table_lookup_exact_by_schema[actual_schema]
  local schema_lookup = self.table_lookup_by_schema[actual_schema]
  local actual_name = self:_resolve_lookup(exact_lookup, schema_lookup, table_name, opts.table_quoted)
  if actual_name then
    return actual_name, actual_schema
  end
  return nil, actual_schema
end

--- Find a table name using exact or folded semantics.
---@param table_name string
---@param opts? { table_quoted?: boolean, quoted?: boolean }
---@return string? actual_name, string? schema
function SchemaCache:find_table(table_name, opts)
  if not table_name or table_name == "" then
    return nil, nil
  end
  opts = opts or {}
  local match = self:_resolve_lookup(
    self.table_lookup_exact_global,
    self.table_lookup_global,
    table_name,
    quoted_option(opts, "table_quoted", "quoted")
  )
  if match then
    return match.name, match.schema
  end
  return nil, nil
end

--- Invalidate in-memory cache (disk cache remains for next session).
function SchemaCache:invalidate()
  self:_bump_metadata_generation("invalidate")
  self:cancel_async("invalidate")
  self.schemas = {}
  self.tables = {}
  self.columns = {}
  self.column_lru = {}
  self.column_touch_clock = 0
  self:_reset_indexes()
end

--- Update connection ID and clear in-memory cache.
---@param conn_id connection_id
function SchemaCache:set_connection(conn_id)
  self.conn_id = conn_id
  self:invalidate()
end

--- Check if cache has any table data.
---@return boolean
function SchemaCache:is_populated()
  return next(self.schemas) ~= nil
end

return SchemaCache
