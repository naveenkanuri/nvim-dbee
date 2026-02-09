---@class SchemaCache
---@field private handler Handler
---@field private conn_id connection_id
---@field private schemas table<string, boolean>
---@field private tables table<string, table<string, { type: string }>>
---@field private columns table<string, Column[]>
---@field private all_table_names string[] flat list for unqualified completion
---@field private cache_dir string directory for disk cache
local SchemaCache = {}

---@param handler Handler
---@param conn_id connection_id
---@return SchemaCache
function SchemaCache:new(handler, conn_id)
  local cache_dir = vim.fn.stdpath("state") .. "/dbee/lsp_cache"
  local o = {
    handler = handler,
    conn_id = conn_id,
    schemas = {},
    tables = {},
    columns = {},
    all_table_names = {},
    cache_dir = cache_dir,
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

--- Build the cache from metadata query result rows.
--- Each row is a map with schema_name, table_name, obj_type keys (case-insensitive).
---@param rows table[] array of {schema_name: string, table_name: string, obj_type: string}
function SchemaCache:build_from_metadata_rows(rows)
  self.schemas = {}
  self.tables = {}
  self.columns = {}
  self.all_table_names = {}

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

  self:_build_name_list()
end

--- Build the cache from a pre-fetched structure tree.
--- NEVER calls connection_get_structure() — structure must be provided.
---@param structs DBStructure[]
function SchemaCache:build_from_structure(structs)
  self.schemas = {}
  self.tables = {}
  self.columns = {}
  self.all_table_names = {}

  if not structs or structs == vim.NIL then
    return
  end

  self:_flatten(structs, nil)
  self:_build_name_list()
end

---@private
function SchemaCache:_build_name_list()
  local seen = {}
  local unique = {}
  for _, tbls in pairs(self.tables) do
    for name, _ in pairs(tbls) do
      if not seen[name] then
        seen[name] = true
        unique[#unique + 1] = name
      end
    end
  end
  table.sort(unique)
  self.all_table_names = unique
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
    conn_id = self.conn_id,
    schemas = vim.tbl_keys(self.schemas),
    tables = {},
  }
  for schema, tbls in pairs(self.tables) do
    data.tables[schema] = {}
    for name, info in pairs(tbls) do
      data.tables[schema][name] = info.type
    end
  end

  local json = vim.json.encode(data)
  local path = self:_cache_path()
  local f = io.open(path, "w")
  if f then
    f:write(json)
    f:close()
  end
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
    return false
  end

  self.schemas = {}
  self.tables = {}
  self.all_table_names = {}
  self.columns = {}

  if data.schemas then
    for _, s in ipairs(data.schemas) do
      self.schemas[s] = true
    end
  end

  if data.tables then
    for schema, tbls in pairs(data.tables) do
      self.tables[schema] = {}
      for name, stype in pairs(tbls) do
        self.tables[schema][name] = { type = stype }
      end
    end
  end

  self:_build_name_list()
  self:_load_columns_from_disk()
  return true
end

--- Save columns for a single table to disk.
---@private
---@param key string "schema.table"
---@param cols Column[]
function SchemaCache:_save_columns_to_disk(key, cols)
  vim.fn.mkdir(self.cache_dir, "p")
  local path = self:_columns_cache_path(key)
  local json = vim.json.encode(cols)
  local f = io.open(path, "w")
  if f then
    f:write(json)
    f:close()
  end
end

--- Load all cached column files for this connection from disk.
---@private
function SchemaCache:_load_columns_from_disk()
  local prefix = self.conn_id .. "_cols_"
  local pattern = self.cache_dir .. "/" .. prefix .. "*.json"
  local files = vim.fn.glob(pattern, false, true)
  for _, path in ipairs(files) do
    local f = io.open(path, "r")
    if f then
      local content = f:read("*a")
      f:close()
      local ok, cols = pcall(vim.json.decode, content)
      if ok and cols then
        -- extract key from filename
        local fname = vim.fn.fnamemodify(path, ":t:r") -- remove dir and .json
        local key = fname:sub(#prefix + 1):gsub("_", ".", 1) -- first _ back to .
        -- reconstruct proper key from the columns data context
        -- actually store with the encoded key
        self.columns[key] = cols
      end
    end
  end
end

-- ── Public API ──────────────────────────────────────────────

--- Get all schema names.
---@return string[]
function SchemaCache:get_schemas()
  return vim.tbl_keys(self.schemas)
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
  return self.all_table_names
end

--- Get columns for a specific table, lazy-loading from handler on first access.
--- Results are cached to disk for subsequent sessions.
---@param schema string
---@param table_name string
---@return Column[]
function SchemaCache:get_columns(schema, table_name)
  local key = schema .. "." .. table_name
  if self.columns[key] then
    return self.columns[key]
  end

  local tbl_info = (self.tables[schema] or {})[table_name]
  if not tbl_info then
    tbl_info = (self.tables["_default"] or {})[table_name]
    if tbl_info then
      schema = "_default"
      key = schema .. "." .. table_name
      if self.columns[key] then
        return self.columns[key]
      end
    end
  end

  if not tbl_info then
    return {}
  end

  local query_schema = (schema == "_default") and "" or schema

  local ok, cols = pcall(self.handler.connection_get_columns, self.handler, self.conn_id, {
    table = table_name,
    schema = query_schema,
    materialization = tbl_info.type,
  })

  -- Fallback: Oracle can have both lowercase (quoted) and uppercase entries.
  -- If lowercase returns no columns, try uppercase.
  if (not ok or not cols or #cols == 0) and table_name:upper() ~= table_name then
    ok, cols = pcall(self.handler.connection_get_columns, self.handler, self.conn_id, {
      table = table_name:upper(),
      schema = query_schema,
      materialization = tbl_info.type,
    })
  end

  if not ok or not cols or #cols == 0 then
    return {}
  end

  self.columns[key] = cols
  self:_save_columns_to_disk(key, cols)
  return cols
end

--- Get all columns that are already cached (no lazy loading).
---@return table<string, Column[]> keyed by "schema.table"
function SchemaCache:get_cached_columns()
  return self.columns
end

--- Find a table name matching case-insensitively.
---@param table_name string
---@return string? actual_name, string? schema
function SchemaCache:find_table(table_name)
  for schema, tbls in pairs(self.tables) do
    if tbls[table_name] then
      return table_name, schema
    end
  end
  local upper = table_name:upper()
  for schema, tbls in pairs(self.tables) do
    for name, _ in pairs(tbls) do
      if name:upper() == upper then
        return name, schema
      end
    end
  end
  return nil, nil
end

--- Invalidate in-memory cache (disk cache remains for next session).
function SchemaCache:invalidate()
  self.schemas = {}
  self.tables = {}
  self.columns = {}
  self.all_table_names = {}
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
