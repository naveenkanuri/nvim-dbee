local state = require("dbee.api.state")
local SchemaCache = require("dbee.lsp.schema_cache")
local server = require("dbee.lsp.server")
local schema_filter = require("dbee.schema_filter")
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
---@field private _bootstrap_consumer_id string
---@field private _pending_connection_invalidations ConnectionInvalidatedEvent[]
---@field private _connection_invalidation_flush_scheduled boolean
---@field private _connection_invalidated_consumer_live boolean
local M = {
  _client_id = nil,
  _cache = nil,
  _conn_id = nil,
  _attached_bufs = {},
  _pending_bufs = {},
  _async_requested = {},
  _metadata_scheduled = {},
  _metadata_call_ids = {},
  _bootstrap_consumer_id = "lsp",
  _pending_connection_invalidations = {},
  _connection_invalidation_flush_scheduled = false,
  _connection_invalidated_consumer_live = false,
}

---@param reason string
local function cancel_active_async(reason)
  if M._cache and type(M._cache.cancel_async) == "function" then
    M._cache:cancel_async(reason, { conn_id = M._conn_id })
  end
end

local function clear_lsp_diagnostics()
  if type(server.clear_diagnostics) ~= "function" then
    return
  end

  local cleared = false
  for bufnr in pairs(M._attached_bufs or {}) do
    server.clear_diagnostics(bufnr)
    cleared = true
  end
  for bufnr in pairs(M._pending_bufs or {}) do
    server.clear_diagnostics(bufnr)
    cleared = true
  end
  if not cleared then
    server.clear_diagnostics()
  end
end

---@param conn_id connection_id|nil
local function clear_connection_tracking(conn_id)
  if conn_id and conn_id ~= "" then
    M._async_requested[conn_id] = nil
    M._metadata_scheduled[conn_id] = nil
    for call_id, mapped_conn_id in pairs(M._metadata_call_ids) do
      if mapped_conn_id == conn_id then
        M._metadata_call_ids[call_id] = nil
      end
    end
    return
  end

  M._async_requested = {}
  M._metadata_scheduled = {}
  M._metadata_call_ids = {}
end

local function connection_uses_lazy_schema_root(handler, conn)
  if not conn then
    return false
  end

  local normalized
  if handler and type(handler.get_schema_filter_normalized) == "function" and conn.id then
    local ok, scope = pcall(handler.get_schema_filter_normalized, handler, conn.id)
    if ok then
      normalized = scope
    end
  end
  if not normalized then
    normalized = schema_filter.normalize(conn.schema_filter or nil, conn.type or nil)
  end

  local caps = schema_filter.capabilities((normalized and normalized.connection_type) or conn.type or nil)
  return normalized and normalized.lazy_per_schema == true and caps.list_schemas == true and caps.structure_for_schema == true
end

---@param data ConnectionInvalidatedEvent
---@param snapshot_epoch table<connection_id, integer>
---@return boolean
local function should_apply_bootstrap_invalidation(data, snapshot_epoch)
  local event_epoch = tonumber(data and data.authoritative_root_epoch) or 0
  if event_epoch <= 0 then
    return false
  end

  local affected = {}
  for _, conn_id in ipairs(data and data.retired_conn_ids or {}) do
    affected[conn_id] = true
  end
  for _, conn_id in ipairs(data and data.new_conn_ids or {}) do
    affected[conn_id] = true
  end
  if data and data.current_conn_id_before then
    affected[data.current_conn_id_before] = true
  end
  if data and data.current_conn_id_after then
    affected[data.current_conn_id_after] = true
  end

  if next(affected) == nil then
    return true
  end

  for conn_id in pairs(affected) do
    if event_epoch > (snapshot_epoch[conn_id] or 0) then
      return true
    end
  end

  return false
end

---@param data ConnectionInvalidatedEvent
---@return table<string, boolean>
local function affected_connection_ids(data)
  local affected = {}
  for _, conn_id in ipairs(data and data.retired_conn_ids or {}) do
    affected[conn_id] = true
  end
  for _, conn_id in ipairs(data and data.new_conn_ids or {}) do
    affected[conn_id] = true
  end
  if data and data.current_conn_id_before then
    affected[data.current_conn_id_before] = true
  end
  if data and data.current_conn_id_after then
    affected[data.current_conn_id_after] = true
  end
  return affected
end

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

---@private
---@param handler Handler
---@param data table
function M._on_structure_loaded(handler, data)
  if not data or not data.conn_id or data.error_kind == "superseded" then
    return
  end

  if data.caller_token ~= "lsp" then
    return
  end

  local payload_epoch = tonumber(data.root_epoch) or 0
  if payload_epoch < handler:get_authoritative_root_epoch(data.conn_id) then
    return
  end

  local conn = handler:get_current_connection()
  if not conn or conn.id ~= data.conn_id then
    return
  end

  if data.error then
    return
  end

  if not data.structures then
    return
  end

  if M._client_id and M._cache then
    cancel_active_async("structure_loaded")
    if type(M._cache.refresh_schema_scope) == "function" then
      M._cache:refresh_schema_scope()
    end
    M._cache:build_from_structure(data.structures)
    M._cache:save_to_disk()
  else
    local cache = SchemaCache:new(handler, data.conn_id)
    cache:build_from_structure(data.structures)
    cache:save_to_disk()
    M._start_lsp(cache, data.conn_id)
  end
end

---@private
---@param handler Handler
---@param data table
function M._on_schemas_loaded(handler, data)
  if not data or not data.conn_id or data.error_kind == "superseded" then
    return
  end
  if data.caller_token ~= "lsp" then
    return
  end

  local payload_epoch = tonumber(data.root_epoch) or 0
  if payload_epoch < handler:get_authoritative_root_epoch(data.conn_id) then
    return
  end
  local conn = handler:get_current_connection()
  if not conn or conn.id ~= data.conn_id or data.error then
    return
  end

  if M._client_id and M._cache then
    cancel_active_async("schemas_loaded")
    local scope_changed = false
    if type(M._cache.refresh_schema_scope) == "function" then
      scope_changed = M._cache:refresh_schema_scope()
    end
    if scope_changed and type(M._cache.delete_column_cache_for_filter_change) == "function" then
      M._cache:delete_column_cache_for_filter_change()
    end
    M._cache:build_from_schemas(data.schemas or {}, { preserve_loaded = not scope_changed })
    M._cache:save_to_disk()
  else
    local cache = SchemaCache:new(handler, data.conn_id)
    cache:build_from_schemas(data.schemas or {})
    cache:save_to_disk()
    M._start_lsp(cache, data.conn_id)
  end
end

---@private
---@param handler Handler
---@param conn_id connection_id
function M._request_structure_refresh(handler, conn_id)
  M._async_requested[conn_id] = true
  handler:connection_get_structure_singleflight({
    conn_id = conn_id,
    consumer = M._bootstrap_consumer_id,
    caller_token = "lsp",
    callback = function(data)
      M._on_structure_loaded(handler, data)
    end,
  })
end

---@private
---@param handler Handler
---@param conn_id connection_id
function M._request_schema_list_refresh(handler, conn_id)
  M._async_requested[conn_id] = true
  if type(handler.connection_list_schemas_singleflight) ~= "function" then
    M._request_structure_refresh(handler, conn_id)
    return
  end
  handler:connection_list_schemas_singleflight({
    conn_id = conn_id,
    purpose = "lsp",
    consumer = M._bootstrap_consumer_id,
    caller_token = "lsp",
    callback = function(data)
      M._on_schemas_loaded(handler, data)
    end,
  })
end

---@private
---@param handler Handler
---@param conn_id connection_id
function M._request_root_refresh(handler, conn_id)
  local conn
  if type(handler.connection_get_params) == "function" then
    local ok, params = pcall(handler.connection_get_params, handler, conn_id)
    if ok then
      conn = params
    end
  end
  conn = conn or { id = conn_id }

  if connection_uses_lazy_schema_root(handler, conn) then
    M._request_schema_list_refresh(handler, conn_id)
  else
    M._request_structure_refresh(handler, conn_id)
  end
end

---@private
---@param data any
function M._handle_connection_invalidated_consumer_event(data)
  if not data then
    return
  end

  if data.kind == "overflow" then
    utils.log("warn", data.message, "lsp")
    return
  end

  if data.kind == "storm" then
    M._connection_invalidated_consumer_live = false
    utils.log("error", data.message, "lsp")
    return
  end

  M._on_connection_invalidated(data)
end

---@private
---@param handler Handler
---@return boolean ok
---@return string? reason
function M._bootstrap_connection_invalidated(handler)
  M._connection_invalidated_consumer_live = false
  local generation = handler:begin_connection_invalidated_bootstrap(M._bootstrap_consumer_id, function(data)
    M._handle_connection_invalidated_consumer_event(data)
  end)

  while true do
    local snapshot = handler:get_connection_state_snapshot()
    local current_conn = snapshot.current_connection

    local drained = handler:drain_connection_invalidated_bootstrap(M._bootstrap_consumer_id, generation)
    if drained.kind == "restart" then
      if drained.warning and drained.warning.message then
        utils.log("warn", drained.warning.message, "lsp")
      end
      generation = drained.generation or generation
    elseif drained.kind == "storm" then
      utils.log("error", drained.message or "[dbee] bootstrap_overflow_storm", "lsp")
      return false, "storm"
    elseif drained.kind ~= "ok" then
      utils.log("error", drained.message or "[dbee] bootstrap unavailable", "lsp")
      return false, drained.kind
    else
      local should_refresh = false
      for _, event in ipairs(drained.events or {}) do
        if should_apply_bootstrap_invalidation(event, snapshot.snapshot_authoritative_epoch or {}) then
          should_refresh = true
          break
        end
      end

      local promoted = handler:promote_to_live(M._bootstrap_consumer_id, generation)
      if promoted.kind == "restart" then
        if promoted.warning and promoted.warning.message then
          utils.log("warn", promoted.warning.message, "lsp")
        end
        generation = promoted.generation or generation
      elseif promoted.kind == "storm" then
        utils.log("error", promoted.message or "[dbee] bootstrap_overflow_storm", "lsp")
        return false, "storm"
      elseif promoted.kind ~= "ok" then
        utils.log("error", promoted.message or "[dbee] bootstrap unavailable", "lsp")
        return false, promoted.kind
      else
        for _, event in ipairs(promoted.events or {}) do
          if should_apply_bootstrap_invalidation(event, snapshot.snapshot_authoritative_epoch or {}) then
            should_refresh = true
            break
          end
        end

        M._connection_invalidated_consumer_live = true
        if should_refresh and current_conn and current_conn.id then
          M._request_root_refresh(handler, current_conn.id)
        end
        return true
      end
    end
  end
end

---@private
---@param handler Handler
---@return boolean
function M._ensure_connection_invalidated_consumer(handler)
  if M._connection_invalidated_consumer_live then
    return true
  end

  if type(handler.begin_connection_invalidated_bootstrap) ~= "function"
    or type(handler.drain_connection_invalidated_bootstrap) ~= "function"
    or type(handler.promote_to_live) ~= "function"
  then
    M._connection_invalidated_consumer_live = true
    return true
  end

  for attempt = 1, 2 do
    local ok, reason = M._bootstrap_connection_invalidated(handler)
    if ok then
      return true
    end

    if type(handler.teardown_connection_invalidated_consumer) == "function" then
      handler:teardown_connection_invalidated_consumer(M._bootstrap_consumer_id)
    end
    M._pending_connection_invalidations = {}
    M._connection_invalidation_flush_scheduled = false

    if reason ~= "storm" then
      break
    end
  end

  utils.log("error", "[dbee] bootstrap_unavailable", "lsp")
  return false
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
  if not M._ensure_connection_invalidated_consumer(handler) then
    return
  end
  local conn = handler:get_current_connection()
  if not conn then
    return
  end
  local lazy_root = connection_uses_lazy_schema_root(handler, conn)

  -- 1. Try disk cache (instant)
  local cache = SchemaCache:new(handler, conn.id)
  if cache:load_from_disk() then
    M._start_lsp(cache, conn.id)
    -- also trigger async refresh in background to keep cache fresh
    if not M._async_requested[conn.id] then
      M._request_root_refresh(handler, conn.id)
    end
    return
  end

  -- 2. No disk cache — trigger async structure load (non-blocking).
  --    LSP will start when structure_loaded event fires.
  if not M._async_requested[conn.id] then
    M._request_root_refresh(handler, conn.id)
  end

  -- 3. Schedule metadata query fallback.
  --    For large databases, structure_loaded may never arrive (Go→Lua
  --    serialization too large). After 5s, fall back to a lightweight
  --    metadata SQL query that returns only user schemas.
  if not lazy_root and not M._metadata_scheduled[conn.id] and METADATA_QUERIES[conn.type] then
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
---@param conn_id? connection_id
---@param opts? { preserve_structure_waiter_for?: connection_id|nil }
function M.stop(conn_id, opts)
  opts = opts or {}
  clear_connection_tracking(conn_id)
  cancel_active_async("stop")
  clear_lsp_diagnostics()
  if state.is_core_loaded() then
    local handler = state.handler()
    local preserve_structure_waiter = false
    if opts.preserve_structure_waiter_for then
      for _, flight in pairs(handler._structure_flights or {}) do
        if flight.conn_id == opts.preserve_structure_waiter_for
          and (flight.consumer_slots or {})[M._bootstrap_consumer_id]
        then
          preserve_structure_waiter = true
          break
        end
      end
    end
    if not preserve_structure_waiter then
      handler:teardown_structure_consumer(M._bootstrap_consumer_id)
    end
    if type(handler.teardown_connection_invalidated_consumer) == "function" then
      handler:teardown_connection_invalidated_consumer(M._bootstrap_consumer_id)
    end
  end
  M._connection_invalidated_consumer_live = false
  M._pending_connection_invalidations = {}
  M._connection_invalidation_flush_scheduled = false
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
    M._request_root_refresh(handler, conn.id)
  end
end

---@private
---@param data ConnectionInvalidatedEvent
function M._flush_connection_invalidations()
  M._connection_invalidation_flush_scheduled = false

  if not state.is_core_loaded() or not M._connection_invalidated_consumer_live then
    M._pending_connection_invalidations = {}
    return
  end

  local batched = M._pending_connection_invalidations
  M._pending_connection_invalidations = {}
  if not batched or next(batched) == nil then
    return
  end

  local handler = state.handler()
  if not M._ensure_connection_invalidated_consumer(handler) then
    M._pending_connection_invalidations = {}
    return
  end
  local current = handler:get_current_connection()
  if not current or not current.id then
    return
  end

  local should_rewarm = false
  for _, event in ipairs(batched) do
    local affected = affected_connection_ids(event)
    if next(affected) == nil or affected[current.id] then
      should_rewarm = true
      break
    end
  end

  if should_rewarm then
    cancel_active_async("connection_invalidated")
    clear_lsp_diagnostics()
    M._request_root_refresh(handler, current.id)
  end
end

function M.clear_diagnostics(bufnr)
  if bufnr and type(server.clear_diagnostics) == "function" then
    server.clear_diagnostics(bufnr)
    return
  end
  clear_lsp_diagnostics()
end

function M._on_connection_invalidated(data)
  if not data or data.silent == true then
    return
  end

  M._pending_connection_invalidations[#M._pending_connection_invalidations + 1] = data
  if M._connection_invalidation_flush_scheduled then
    return
  end

  M._connection_invalidation_flush_scheduled = true
  vim.schedule(M._flush_connection_invalidations)
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
  M._ensure_connection_invalidated_consumer(handler)

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

  handler:register_event_listener("structure_children_loaded", function(data)
    if not data or data.kind ~= "columns" or not data.conn_id then
      return
    end
    if not M._cache or M._conn_id ~= data.conn_id then
      return
    end
    local payload_epoch = tonumber(data.root_epoch) or 0
    if payload_epoch < handler:get_authoritative_root_epoch(data.conn_id) then
      return
    end
    M._cache:on_columns_loaded(data)
  end)

  handler:register_event_listener("current_connection_changed", function(data)
    if not data then
      return
    end

    M.stop(M._conn_id, {
      preserve_structure_waiter_for = data.conn_id,
    })
    if data.cleared == true or not data.conn_id then
      return
    end

    -- stop current LSP, restart for new connection
    M._try_start()
  end)

  handler:register_event_listener("database_selected", function(data)
    if not data or not data.conn_id then
      return
    end
    if M._conn_id == data.conn_id and M._cache then
      cancel_active_async("database_selected")
      clear_lsp_diagnostics()
      M._cache:invalidate()
      -- trigger fresh structure load
      M._request_root_refresh(handler, data.conn_id)
    end
  end)
end

return M
