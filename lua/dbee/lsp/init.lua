local state = require("dbee.api.state")
local SchemaCache = require("dbee.lsp.schema_cache")
local server = require("dbee.lsp.server")
local utils = require("dbee.utils")

-- Metadata SQL queries per connection type.
-- Filters out system schemas to return only user-relevant tables/views.
-- Column aliases: schema_name, table_name, obj_type (normalized in schema_cache).
local METADATA_QUERIES = {
  oracle = [[
    SELECT owner AS schema_name, table_name, 'table' AS obj_type
    FROM all_tables T JOIN all_users U ON T.owner = U.username
    WHERE U.common = 'NO' AND table_name = UPPER(table_name)
    UNION ALL
    SELECT owner AS schema_name, view_name AS table_name, 'view' AS obj_type
    FROM all_views V JOIN all_users U ON V.owner = U.username
    WHERE U.common = 'NO' AND view_name = UPPER(view_name)
    ORDER BY 1, 2]],
  postgres = [[
    SELECT table_schema AS schema_name, table_name,
      CASE table_type WHEN 'BASE TABLE' THEN 'table' ELSE 'view' END AS obj_type
    FROM information_schema.tables
    WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
    ORDER BY 1, 2]],
  mysql = [[
    SELECT table_schema AS schema_name, table_name,
      CASE table_type WHEN 'BASE TABLE' THEN 'table' ELSE 'view' END AS obj_type
    FROM information_schema.tables
    WHERE table_schema NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
    ORDER BY 1, 2]],
  sqlite = [[
    SELECT 'main' AS schema_name, name AS table_name, type AS obj_type
    FROM sqlite_master
    WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%'
    ORDER BY 1, 2]],
  sqlserver = [[
    SELECT s.name AS schema_name, t.name AS table_name,
      CASE t.type WHEN 'U' THEN 'table' WHEN 'V' THEN 'view' END AS obj_type
    FROM sys.objects t JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE t.type IN ('U', 'V')
    ORDER BY 1, 2]],
}
-- Type aliases
METADATA_QUERIES["postgresql"] = METADATA_QUERIES.postgres
METADATA_QUERIES["pg"] = METADATA_QUERIES.postgres
METADATA_QUERIES["sqlite3"] = METADATA_QUERIES.sqlite
METADATA_QUERIES["mssql"] = METADATA_QUERIES.sqlserver

---@class DbeeLsp
---@field private _client_id integer?
---@field private _cache SchemaCache?
---@field private _conn_id connection_id?
---@field private _attached_bufs table<integer, boolean>
---@field private _pending_bufs table<integer, boolean>
---@field private _async_requested table<connection_id, boolean>
---@field private _metadata_scheduled table<connection_id, boolean>
---@field private _metadata_call_ids table<call_id, connection_id>
local M = {
  _client_id = nil,
  _cache = nil,
  _conn_id = nil,
  _attached_bufs = {},
  _pending_bufs = {},
  _async_requested = {},
  _metadata_scheduled = {},
  _metadata_call_ids = {},
}

--- Queue a buffer for LSP attachment.
---@param bufnr integer
function M.queue_buffer(bufnr)
  if M._attached_bufs[bufnr] then
    return
  end

  if M._client_id then
    vim.lsp.buf_attach_client(bufnr, M._client_id)
    M._attached_bufs[bufnr] = true
    return
  end

  M._pending_bufs[bufnr] = true

  -- try to start LSP (from disk cache or trigger async load)
  M._try_start()
end

---@private
function M._flush_pending()
  if not M._client_id then
    return
  end
  for bufnr, _ in pairs(M._pending_bufs) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.lsp.buf_attach_client(bufnr, M._client_id)
      M._attached_bufs[bufnr] = true
    end
  end
  M._pending_bufs = {}
end

--- Start LSP with a populated cache.
---@private
---@param cache SchemaCache
---@param conn_id connection_id
---@return boolean
function M._start_lsp(cache, conn_id)
  local client_id = vim.lsp.start({
    name = "dbee-lsp",
    cmd = server.create(cache),
    root_dir = vim.fn.getcwd(),
  })

  if not client_id then
    utils.log("warn", "failed to start dbee-lsp", "lsp")
    return false
  end

  M._client_id = client_id
  M._cache = cache
  M._conn_id = conn_id

  M._flush_pending()
  return true
end

--- Try to start the LSP — disk cache first, then trigger async load.
--- For large databases where structure_loaded can't deliver, a metadata SQL
--- query fires after a short delay as a fallback.
---@private
function M._try_start()
  if M._client_id then
    return
  end

  if not state.is_core_loaded() then
    return
  end

  local handler = state.handler()
  local conn = handler:get_current_connection()
  if not conn then
    return
  end

  -- 1. Try disk cache (instant)
  local cache = SchemaCache:new(handler, conn.id)
  if cache:load_from_disk() then
    M._start_lsp(cache, conn.id)
    -- also trigger async refresh in background to keep cache fresh
    if not M._async_requested[conn.id] then
      M._async_requested[conn.id] = true
      handler:connection_get_structure_async(conn.id)
    end
    return
  end

  -- 2. No disk cache — trigger async structure load (non-blocking).
  --    LSP will start when structure_loaded event fires.
  if not M._async_requested[conn.id] then
    M._async_requested[conn.id] = true
    handler:connection_get_structure_async(conn.id)
  end

  -- 3. Schedule metadata query fallback.
  --    For large databases, structure_loaded may never arrive (Go→Lua
  --    serialization too large). After 5s, fall back to a lightweight
  --    metadata SQL query that returns only user schemas.
  if not M._metadata_scheduled[conn.id] and METADATA_QUERIES[conn.type] then
    M._metadata_scheduled[conn.id] = true
    local target_id = conn.id
    local target_type = conn.type
    vim.defer_fn(function()
      if M._client_id then
        return
      end
      if not state.is_core_loaded() then
        return
      end
      local h = state.handler()
      local c = h:get_current_connection()
      if not c or c.id ~= target_id then
        return
      end
      M._execute_metadata_query(h, target_id, target_type)
    end, 5000)
  end
end

--- Execute a metadata SQL query to populate the schema cache.
--- Used as fallback when structure_loaded can't deliver for large databases.
---@private
---@param handler Handler
---@param conn_id connection_id
---@param conn_type string
function M._execute_metadata_query(handler, conn_id, conn_type)
  local sql = METADATA_QUERIES[conn_type]
  if not sql then
    return
  end

  local ok, call = pcall(handler.connection_execute, handler, conn_id, "/* dbee-lsp metadata */ " .. sql)
  if not ok or not call then
    return
  end

  M._metadata_call_ids[call.id] = conn_id
end

--- Process metadata query results after call reaches archived state.
---@private
---@param handler Handler
---@param call_id call_id
---@param conn_id connection_id
function M._process_metadata_result(handler, call_id, conn_id)
  local tmp = os.tmpname() .. ".json"

  local ok = pcall(handler.call_store_result, handler, call_id, "json", "file", { extra_arg = tmp })
  if not ok then
    return
  end

  local f = io.open(tmp, "r")
  if not f then
    return
  end
  local content = f:read("*a")
  f:close()
  os.remove(tmp)

  local decode_ok, rows = pcall(vim.json.decode, content)
  if not decode_ok or not rows or type(rows) ~= "table" then
    return
  end

  local cache = SchemaCache:new(handler, conn_id)
  cache:build_from_metadata_rows(rows)
  cache:save_to_disk()

  if not M._client_id then
    M._start_lsp(cache, conn_id)
  elseif M._cache and M._conn_id == conn_id then
    -- LSP already running (structure_loaded was faster) — the structure data
    -- is more complete, so don't override. Just keep what we have.
  end
end

--- Stop the dbee LSP server.
function M.stop()
  if M._client_id then
    local client = vim.lsp.get_client_by_id(M._client_id)
    if client then
      client:stop()
    end
    M._client_id = nil
    M._cache = nil
    M._conn_id = nil
    M._attached_bufs = {}
  end
end

--- Restart the LSP server.
function M.restart()
  M.stop()
  M._try_start()
end

--- Refresh the schema cache from async structure reload.
function M.refresh()
  if not state.is_core_loaded() then
    return
  end
  local handler = state.handler()
  local conn = handler:get_current_connection()
  if conn then
    M._async_requested[conn.id] = true
    handler:connection_get_structure_async(conn.id)
  end
end

--- Get the current status for debugging.
---@return table
function M.status()
  local schemas = M._cache and M._cache:get_schemas() or {}
  local tables = M._cache and M._cache:get_all_table_names() or {}
  return {
    running = M._client_id ~= nil,
    client_id = M._client_id,
    conn_id = M._conn_id,
    schema_count = #schemas,
    table_count = #tables,
    attached_buffers = vim.tbl_keys(M._attached_bufs),
    pending_buffers = vim.tbl_keys(M._pending_bufs),
  }
end

--- Register event listeners for automatic cache management.
--- Called once during setup.
function M.register_events()
  if not state.is_core_loaded() then
    return
  end

  local handler = state.handler()

  -- structure_loaded carries data.structures — use it directly.
  -- Also save to disk for instant load next session.
  handler:register_event_listener("structure_loaded", function(data)
    if not data or not data.conn_id then
      return
    end

    local conn = handler:get_current_connection()
    if not conn or conn.id ~= data.conn_id then
      return
    end

    if not data.structures then
      return
    end

    if M._client_id and M._cache then
      -- LSP already running (from disk cache or metadata query) — refresh with structure data
      M._cache:build_from_structure(data.structures)
      M._cache:save_to_disk()
    else
      -- first start: build cache from event data, save to disk, start LSP
      local cache = SchemaCache:new(handler, data.conn_id)
      cache:build_from_structure(data.structures)
      cache:save_to_disk()
      M._start_lsp(cache, data.conn_id)
    end
  end)

  -- Handle metadata query completion.
  -- When our internal metadata SQL query reaches "archived" state,
  -- export results as JSON and build the schema cache.
  handler:register_event_listener("call_state_changed", function(data)
    if not data or not data.call then
      return
    end

    local conn_id = M._metadata_call_ids[data.call.id]
    if not conn_id then
      return
    end

    if data.call.state == "archived" then
      M._metadata_call_ids[data.call.id] = nil
      -- Verify this connection is still current
      local conn = handler:get_current_connection()
      if not conn or conn.id ~= conn_id then
        return
      end
      M._process_metadata_result(handler, data.call.id, conn_id)
    elseif data.call.state == "executing_failed"
      or data.call.state == "archive_failed"
      or data.call.state == "canceled" then
      M._metadata_call_ids[data.call.id] = nil
    end
  end)

  handler:register_event_listener("current_connection_changed", function(data)
    if not data or not data.conn_id then
      return
    end
    -- stop current LSP, restart for new connection
    M.stop()
    M._try_start()
  end)

  handler:register_event_listener("database_selected", function(data)
    if not data or not data.conn_id then
      return
    end
    if M._conn_id == data.conn_id and M._cache then
      M._cache:invalidate()
      -- trigger fresh structure load
      M._async_requested[data.conn_id] = true
      handler:connection_get_structure_async(data.conn_id)
    end
  end)
end

return M
