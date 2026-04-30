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
---@field private column_items_by_key table<string, lsp.CompletionItem[]>
---@field private schema_lookup table<string, string>
---@field private table_lookup_by_schema table<string, table<string, string>>
---@field private table_lookup_global table<string, { name: string, schema: string }>
---@field private async_inflight table<string, table>
---@field private async_chains table<string, table>
---@field private async_failed table<string, boolean>
---@field private next_async_request_id integer
---@field private cache_dir string directory for disk cache
local SchemaCache = {}

local nio = require("nio")
local schema_filter = require("dbee.schema_filter")

local MAX_COLUMNS_IN_MEMORY = 500
local SYNC_COLUMN_FILE_LOAD_LIMIT = 100
local SYNC_COLUMN_FILE_SCAN_LIMIT = 200
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
---@return string?
local function fold(value, fold_id)
  if not value then
    return nil
  end
  return schema_filter.fold(value, fold_id or "upper")
end

---@param ... string?
---@return string[]
local function unique_nonempty(...)
  local out = {}
  local seen = {}
  for i = 1, select("#", ...) do
    local value = select(i, ...)
    if value and value ~= "" and not seen[value] then
      seen[value] = true
      out[#out + 1] = value
    end
  end
  return out
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
  local normalized_scope = nil
  if handler and type(handler.get_schema_filter_normalized) == "function" then
    local ok, scope = pcall(handler.get_schema_filter_normalized, handler, conn_id)
    if ok then
      normalized_scope = scope
    end
  end
  normalized_scope = normalized_scope or schema_filter.normalize(nil, nil)
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
    column_items_by_key = {},
    schema_lookup = {},
    table_lookup_by_schema = {},
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
    next_async_request_id = 0,
    cache_dir = cache_dir,
    fold_id = normalized_scope.fold,
    schema_scope = normalized_scope,
    schema_filter_signature = normalized_scope.schema_filter_signature,
    root_mode = normalized_scope.lazy_per_schema and "schemas_only" or "full",
    loaded_schemas = {},
    pending_delete_total_files = 0,
    pending_delete_sync_deleted = 0,
    pending_delete_deferred_drain_count = 0,
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

---@private
---@return table
function SchemaCache:_read_normalized_scope()
  if self.handler and type(self.handler.get_schema_filter_normalized) == "function" then
    local ok, scope = pcall(self.handler.get_schema_filter_normalized, self.handler, self.conn_id)
    if ok and scope then
      return scope
    end
  end
  return schema_filter.normalize(nil, nil)
end

---@return boolean changed
function SchemaCache:refresh_schema_scope()
  local previous_signature = self.schema_filter_signature
  local normalized_scope = self:_read_normalized_scope()
  self.fold_id = normalized_scope.fold
  self.schema_scope = normalized_scope
  self.schema_filter_signature = normalized_scope.schema_filter_signature
  return previous_signature ~= nil and previous_signature ~= self.schema_filter_signature
end

--- Build the cache from metadata query result rows.
--- Each row is a map with schema_name, table_name, obj_type keys (case-insensitive).
---@param rows table[] array of {schema_name: string, table_name: string, obj_type: string}
function SchemaCache:build_from_metadata_rows(rows)
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
      local lk = k:lower()
      if lk == "schema_name" then
        schema = v
      elseif lk == "table_name" then
        tname = v
      elseif lk == "obj_type" then
        otype = v
      end
    end

    if schema and tname then
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
    self.loaded_schemas[self:_fold(schema)] = true
  end
end

--- Build the cache from a pre-fetched structure tree.
--- NEVER calls connection_get_structure() — structure must be provided.
---@param structs DBStructure[]
function SchemaCache:build_from_structure(structs)
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
    self.loaded_schemas[self:_fold(schema)] = true
  end
end

---@param schemas table[] array of {name: string}
---@param opts? { preserve_loaded?: boolean }
function SchemaCache:build_from_schemas(schemas, opts)
  opts = opts or {}
  local preserve_loaded = opts.preserve_loaded ~= false
  local previous_tables = self.tables or {}
  local previous_columns = self.columns or {}
  local previous_lru = self.column_lru or {}
  local previous_loaded = self.loaded_schemas or {}
  local previous_schema_lookup = self.schema_lookup or {}

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
      local folded = self:_fold(name)
      local previous_name = previous_schema_lookup[folded] or name
      if preserve_loaded and previous_loaded[folded] and previous_tables[previous_name] then
        self.tables[name] = vim.deepcopy(previous_tables[previous_name])
        self.loaded_schemas[folded] = true
      else
        self.tables[name] = self.tables[name] or {}
      end
    end
  end

  if preserve_loaded then
    for key, cols in pairs(previous_columns) do
      local schema = key:match("^(.-)%.")
      if schema and self.loaded_schemas[self:_fold(schema)] then
        self.columns[key] = cols
        self.column_lru[key] = previous_lru[key]
      end
    end
  end

  self:_rebuild_structure_indexes()
  self:_rebuild_column_indexes()
end

---@private
---@param value string?
---@return string?
function SchemaCache:_fold(value)
  return fold(value, self.fold_id)
end

---@private
function SchemaCache:_reset_indexes()
  self.all_table_names = {}
  self.schema_items = {}
  self.table_items_by_schema = {}
  self.all_table_items = {}
  self.column_items_by_key = {}
  self.schema_lookup = {}
  self.table_lookup_by_schema = {}
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
  self.schema_lookup = {}
  self.table_lookup_by_schema = {}
  self.table_lookup_global = {}

  local schema_names = vim.tbl_keys(self.schemas)
  table.sort(schema_names)

  for _, schema in ipairs(schema_names) do
    self.schema_lookup[self:_fold(schema)] = self.schema_lookup[self:_fold(schema)] or schema
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
    local schema_lookup = {}
    local schema_items = {}

    for _, name in ipairs(table_names) do
      local info = self.tables[schema][name] or { type = "table" }
      local folded = self:_fold(name)
      schema_lookup[folded] = schema_lookup[folded] or name

      schema_items[#schema_items + 1] = table_completion_item(schema, name, info.type)
    end

    self.table_lookup_by_schema[schema] = schema_lookup
    self.table_items_by_schema[schema] = schema_items
  end

  self:_refresh_global_table_index()
end

---@private
function SchemaCache:_refresh_global_table_index()
  self.table_lookup_global = {}
  self.all_table_items = {}
  self.all_table_names = {}

  local schema_names = vim.tbl_keys(self.schemas)
  table.sort(schema_names)

  local seen = {}
  for _, schema in ipairs(schema_names) do
    for _, item in ipairs(self.table_items_by_schema[schema] or {}) do
      local folded = self:_fold(item.label)
      self.table_lookup_global[folded] = self.table_lookup_global[folded]
        or { name = item.label, schema = schema }
      if not seen[item.label] then
        seen[item.label] = true
        self.all_table_items[#self.all_table_items + 1] = vim.deepcopy(item)
      end
    end
  end

  table.sort(self.all_table_items, function(a, b)
    return a.label < b.label
  end)
  for _, item in ipairs(self.all_table_items) do
    self.all_table_names[#self.all_table_names + 1] = item.label
  end
end

---@private
---@param label string
function SchemaCache:_update_global_table_index_for_label(label)
  local folded = self:_fold(label)
  self.table_lookup_global[folded] = nil

  local schema_names = vim.tbl_keys(self.schemas)
  table.sort(schema_names)

  local representative = nil
  for _, schema in ipairs(schema_names) do
    local lookup = self.table_lookup_by_schema[schema]
    if lookup and lookup[folded] then
      self.table_lookup_global[folded] = {
        name = lookup[folded],
        schema = schema,
      }
      break
    end
  end

  for _, schema in ipairs(schema_names) do
    local info = self.tables[schema] and self.tables[schema][label]
    if info then
      representative = table_completion_item(schema, label, info.type)
      break
    end
  end

  if representative then
    upsert_sorted_item(self.all_table_items, vim.deepcopy(representative))
    upsert_sorted_value(self.all_table_names, representative.label)
  end
end

---@private
---@param schema string
---@param name string
---@param table_type string
function SchemaCache:_upsert_table_index(schema, name, table_type)
  table_type = table_type or "table"
  local new_schema = not self.schemas[schema]
  self.schemas[schema] = true
  self.schema_lookup[self:_fold(schema)] = self.schema_lookup[self:_fold(schema)] or schema

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

  local schema_lookup = self.table_lookup_by_schema[schema] or {}
  local folded_name = self:_fold(name)
  if not schema_lookup[folded_name] or name < schema_lookup[folded_name] then
    schema_lookup[folded_name] = name
  end
  self.table_lookup_by_schema[schema] = schema_lookup

  if not self.table_items_by_schema[schema] then
    self.table_items_by_schema[schema] = {}
  end
  local item = table_completion_item(schema, name, table_type)
  upsert_sorted_item(self.table_items_by_schema[schema], item)
  self:_update_global_table_index_for_label(name)
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
function SchemaCache:_store_columns(key, cols)
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
function SchemaCache:_advance_async_probe(entry)
  self:_detach_async_entry(entry)

  entry.materialization_index = entry.materialization_index + 1
  if entry.materialization_index <= #entry.materializations then
    return self:_queue_async_probe(entry)
  end

  entry.materialization_index = 1
  entry.table_index = entry.table_index + 1
  if entry.table_index <= #entry.table_candidates then
    return self:_queue_async_probe(entry)
  end

  entry.table_index = 1
  entry.schema_index = entry.schema_index + 1
  if entry.schema_index <= #entry.schema_candidates then
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
    self:_remove_corrupt_file(path, "loading columns")
    return false
  end
  local cols = payload
  if type(payload) == "table" and payload.columns ~= nil then
    if payload.schema_filter_signature ~= self.schema_filter_signature then
      os.remove(path)
      return false
    end
    cols = payload.columns
  else
    os.remove(path)
    return false
  end
  if not self:_validate_columns(cols) then
    self:_remove_corrupt_file(path, "loading columns")
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
          self.schemas[next_schema] = true
          if not self.tables[next_schema] then
            self.tables[next_schema] = {}
          end
        end
      end
      self:_flatten(s.children, next_schema ~= "" and next_schema or parent_schema)
    end
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

  for _, folded_schema in ipairs(data.root_loaded_schemas or {}) do
    if type(folded_schema) == "string" then
      self.loaded_schemas[folded_schema] = true
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
      self.loaded_schemas[self:_fold(schema)] = true
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
  local paths = {}
  if vim.fs and type(vim.fs.dir) == "function" then
    local ok, iter = pcall(vim.fs.dir, self.cache_dir)
    if ok and iter then
      for name, entry_type in iter do
        if entry_type == "file" and name:sub(1, #prefix) == prefix and name:sub(-5) == ".json" then
          paths[#paths + 1] = self.cache_dir .. "/" .. name
        end
      end
    end
  else
    paths = vim.fn.glob(self.cache_dir .. "/" .. prefix .. "*.json", false, true)
  end

  table.sort(paths)
  self.pending_delete_total_files = #paths
  self.pending_delete_sync_deleted = 0
  self.pending_delete_deferred_drain_count = 0
  self:_bump_disk_work_generation()
  local generation = self.disk_work_generation
  local sync_limit = math.min(100, #paths)
  for index = 1, sync_limit do
    if os.remove(paths[index]) then
      self.pending_delete_sync_deleted = self.pending_delete_sync_deleted + 1
    end
  end

  local next_index = sync_limit + 1
  local function step()
    if self.disk_work_generation ~= generation then
      return
    end
    local last = math.min(next_index + 99, #paths)
    for index = next_index, last do
      os.remove(paths[index])
    end
    self.pending_delete_deferred_drain_count = self.pending_delete_deferred_drain_count + 1
    next_index = last + 1
    if next_index <= #paths then
      vim.schedule(step)
    end
  end
  if next_index <= #paths then
    vim.schedule(step)
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
    pending_delete_deferred_drain_count = self.pending_delete_deferred_drain_count or 0,
  }
end

-- ── Public API ──────────────────────────────────────────────

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
---@return lsp.CompletionItem[]
function SchemaCache:get_schema_completion_items()
  return copy_items(self.schema_items)
end

--- Get precomputed table completion items for a schema.
---@param schema string
---@return lsp.CompletionItem[]
function SchemaCache:get_table_completion_items(schema)
  local actual_schema = self:find_schema(schema) or schema
  return copy_items(self.table_items_by_schema[actual_schema])
end

function SchemaCache:schema_status(schema)
  local actual_schema = self:find_schema(schema) or schema
  if not schema_filter.matches(actual_schema, self.schema_scope) then
    return "filtered_out", actual_schema
  end
  if not self:find_schema(actual_schema) then
    return "missing", actual_schema
  end
  if self.root_mode == "schemas_only" and not self.loaded_schemas[self:_fold(actual_schema)] then
    return "active_unloaded", actual_schema
  end
  return "loaded", actual_schema
end

function SchemaCache:get_schema_table_completion_async(schema)
  local status, actual_schema = self:schema_status(schema)
  if status == "loaded" then
    return {
      items = self:get_table_completion_items(actual_schema),
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
  self.handler:connection_get_schema_objects_singleflight({
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

  return {
    items = {},
    is_incomplete = true,
    root_epoch = root_epoch,
  }
end

--- Get precomputed table completion items across all schemas.
---@return lsp.CompletionItem[]
function SchemaCache:get_all_table_completion_items()
  return copy_items(self.all_table_items)
end

--- Get precomputed column completion items for a table.
---@param schema string
---@param table_name string
---@return lsp.CompletionItem[]
function SchemaCache:get_column_completion_items(schema, table_name)
  local actual_schema = self:find_schema(schema) or schema or "_default"
  local actual_table = self:find_table_in_schema(actual_schema, table_name) or table_name
  return copy_items(self.column_items_by_key[table_key(actual_schema, actual_table)])
end

--- Find a schema name case-insensitively.
---@param schema_name string?
---@return string?
function SchemaCache:find_schema(schema_name)
  if not schema_name or schema_name == "" then
    return nil
  end
  return self.schema_lookup[self:_fold(schema_name)]
end

--- Get columns through the non-blocking async miss path.
---@param schema string
---@param table_name string
---@param opts? { probe_if_missing?: boolean, materializations?: string[], root_epoch?: integer }
---@return { columns: Column[], is_incomplete: boolean, in_flight: boolean, reason?: string, resolved_schema?: string, resolved_name?: string }
function SchemaCache:get_columns_async(schema, table_name, opts)
  opts = opts or {}
  schema = self:find_schema(schema) or schema or "_default"
  table_name = table_name or ""

  local actual_table = self:find_table_in_schema(schema, table_name)
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
    schema_candidates = unique_nonempty(
      self:find_schema(schema),
      schema,
      schema:upper(),
      "_default"
    )
    table_candidates = unique_nonempty(
      table_name,
      table_name:upper()
    )
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

  if data.error then
    self.async_failed[probe.active_key] = true
    for _, entry in ipairs(entries) do
      entry.active_key = nil
      self.async_chains[entry.chain_key] = nil
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
  self:_store_columns(key, cols)
  self:_save_columns_to_disk(key, cols)
  for _, entry in ipairs(entries) do
    entry.active_key = nil
    self.async_chains[entry.chain_key] = nil
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
  local schema = self:find_schema(data.schema) or data.schema
  if not schema or schema == "" then
    return false
  end
  if not schema_filter.matches(schema, self.schema_scope) then
    return false
  end

  self.schemas[schema] = true
  self.tables[schema] = self.tables[schema] or {}
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
  apply_structs(data.objects or {}, schema)
  self.loaded_schemas[self:_fold(schema)] = true
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
  self:_bump_disk_work_generation()
end

--- Get columns for a specific table, lazy-loading from handler on first access.
--- Results are cached to disk for subsequent sessions.
---@param schema string
---@param table_name string
---@param opts? { probe_if_missing?: boolean, materializations?: string[] }
---@return Column[]
function SchemaCache:get_columns(schema, table_name, opts)
  opts = opts or {}
  schema = schema or "_default"

  -- Normalize schema casing against known cache entries.
  schema = self:find_schema(schema) or schema

  local key = table_key(schema, table_name)
  if self.columns[key] then
    self:_touch_column(key)
    return self.columns[key]
  end

  local actual_table = self:find_table_in_schema(schema, table_name)
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
    local default_table = self:find_table_in_schema("_default", table_name)
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
    table_name = self:find_table_in_schema(schema, table_name) or table_name
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
    -- Fallback: Oracle can have both lowercase (quoted) and uppercase entries.
    -- If lowercase returns no columns, try uppercase.
    if not cols and table_name:upper() ~= table_name then
      resolved_table = table_name:upper()
      cols = fetch_columns(schema, resolved_table, tbl_info.type)
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

    -- Prefer an existing schema with matching case-insensitive name.
    local matched_schema = nil
    matched_schema = self:find_schema(schema)

    add_schema_candidate(matched_schema)
    add_schema_candidate(schema)
    if schema ~= "_default" and schema:upper() ~= schema then
      add_schema_candidate(schema:upper())
    end

    add_table_candidate(table_name)
    if table_name:upper() ~= table_name then
      add_table_candidate(table_name:upper())
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

--- Find a table within a specific schema case-insensitively.
---@param schema_name string
---@param table_name string
---@return string? actual_name, string? actual_schema
function SchemaCache:find_table_in_schema(schema_name, table_name)
  local actual_schema = self:find_schema(schema_name) or schema_name
  local schema_lookup = self.table_lookup_by_schema[actual_schema]
  if not schema_lookup then
    return nil, actual_schema
  end
  local actual_name = schema_lookup[self:_fold(table_name)]
  if actual_name then
    return actual_name, actual_schema
  end
  return nil, actual_schema
end

--- Find a table name matching case-insensitively.
---@param table_name string
---@return string? actual_name, string? schema
function SchemaCache:find_table(table_name)
  local match = self.table_lookup_global[self:_fold(table_name)]
  if match then
    return match.name, match.schema
  end
  return nil, nil
end

--- Invalidate in-memory cache (disk cache remains for next session).
function SchemaCache:invalidate()
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
