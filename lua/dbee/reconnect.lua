local utils = require("dbee.utils")

local function get_api()
  return require("dbee.api")
end

local function get_state()
  return require("dbee.api.state")
end

local M = {}

---@class dbee_retry_meta
---@field conn_id connection_id
---@field conn_name string?
---@field conn_type string?
---@field note_id note_id?
---@field resolved_query string?
---@field exec_opts table?
---@field retry_fn fun(reconnected_conn_id: connection_id, meta: dbee_retry_meta): string|integer|nil, string|nil
---@field on_retry_created fun(new_call: CallDetails, meta: dbee_retry_meta)?
---@field legacy_query string?
---@field last_failed_ts integer?

---@type table<call_id, dbee_retry_meta>
local calls_by_id = {}
---@type table<connection_id, table<call_id, true>>
local call_ids_by_conn = {}
---@type table<connection_id, { prompt_open: boolean, declined: boolean, latest_call_id: call_id|nil, latest_failed_ts: integer, owned_call_ids: table<call_id, true> }>
local episodes = {}
---@type table<call_id, true>
local retired_by_retry = {}
---@type table<call_id, true>
local superseded = {}
---@type table<string, fun(old_conn_id: connection_id, new_conn_id: connection_id)>
local connection_rewritten_listeners = {}
local reconnect_listener_registered = false

local terminal_states = {
  archived = true,
  executing_failed = true,
  retrieving_failed = true,
  archive_failed = true,
  canceled = true,
}

local disconnected_error_states = {
  executing_failed = true,
  retrieving_failed = true,
  archive_failed = true,
}

local SYNTHETIC_STEP2_PATTERN = "^%s*SELECT%s+%*%s+FROM%s+TABLE%s*%(%s*DBMS_XPLAN"

---@param call_id call_id
local function clear_tombstones(call_id)
  retired_by_retry[call_id] = nil
  superseded[call_id] = nil
end

local function prune_orphaned_tombstones()
  for call_id in pairs(retired_by_retry) do
    if not calls_by_id[call_id] then
      retired_by_retry[call_id] = nil
    end
  end
  for call_id in pairs(superseded) do
    if not calls_by_id[call_id] then
      superseded[call_id] = nil
    end
  end
end

---@param exec_opts table|nil
---@return table|nil
local function copy_exec_opts(exec_opts)
  if type(exec_opts) ~= "table" then
    return exec_opts
  end

  local copied = {}
  for key, value in pairs(exec_opts) do
    copied[key] = value
  end

  if type(exec_opts.binds) == "table" then
    copied.binds = vim.deepcopy(exec_opts.binds)
  end

  return copied
end

---@param meta dbee_retry_meta
---@return dbee_retry_meta
local function copy_retry_meta(meta)
  local copied = {}
  for key, value in pairs(meta or {}) do
    copied[key] = value
  end
  copied.exec_opts = copy_exec_opts(meta and meta.exec_opts or nil)
  copied.last_failed_ts = meta and meta.last_failed_ts or 0
  return copied
end

---@param conn_id connection_id
---@return table<call_id, true>
local function ensure_conn_bucket(conn_id)
  call_ids_by_conn[conn_id] = call_ids_by_conn[conn_id] or {}
  return call_ids_by_conn[conn_id]
end

---@param conn_id connection_id
---@param call_id call_id
local function add_call_to_conn(conn_id, call_id)
  ensure_conn_bucket(conn_id)[call_id] = true
end

---@param conn_id connection_id
---@param call_id call_id
local function remove_call_from_conn(conn_id, call_id)
  local bucket = call_ids_by_conn[conn_id]
  if not bucket then
    return
  end
  bucket[call_id] = nil
  if next(bucket) == nil then
    call_ids_by_conn[conn_id] = nil
  end
end

---@param conn_id connection_id
---@return source_id|nil
local function find_source_id_for_connection(conn_id)
  local api = get_api()
  if type(api.core.get_sources) ~= "function" or type(api.core.source_get_connections) ~= "function" then
    return nil
  end

  local ok_sources, sources = pcall(api.core.get_sources)
  if not ok_sources or type(sources) ~= "table" then
    return nil
  end

  for _, source in ipairs(sources) do
    if source and type(source.name) == "function" then
      local ok_name, source_id = pcall(source.name, source)
      if ok_name and source_id and source_id ~= "" then
        local ok_conns, source_conns = pcall(api.core.source_get_connections, source_id)
        if ok_conns and type(source_conns) == "table" then
          for _, conn in ipairs(source_conns) do
            if conn and conn.id == conn_id then
              return source_id
            end
          end
        end
      end
    end
  end

  return nil
end

---@param source_id source_id
---@param previous ConnectionParams
---@return ConnectionParams|nil
---@return string|nil
local function resolve_reloaded_connection(source_id, previous)
  local api = get_api()
  local ok_conns, source_conns = pcall(api.core.source_get_connections, source_id)
  if not ok_conns then
    return nil, "failed reading reloaded source connections"
  end
  if type(source_conns) ~= "table" or #source_conns == 0 then
    return nil, "source reload produced no connections"
  end

  local prev_id = tostring(previous.id or "")
  local prev_type = tostring(previous.type or "")
  local prev_url = tostring(previous.url or "")
  local prev_name = tostring(previous.name or "")

  local function find_unique_match(predicate)
    local match = nil
    for _, candidate in ipairs(source_conns) do
      if candidate and candidate.id and candidate.id ~= "" and predicate(candidate) then
        if match ~= nil then
          return nil, true
        end
        match = candidate
      end
    end
    return match, false
  end

  if prev_id ~= "" then
    local match, ambiguous = find_unique_match(function(candidate)
      return tostring(candidate.id or "") == prev_id
        and (prev_type == "" or tostring(candidate.type or "") == prev_type)
    end)
    if match then
      return match, nil
    end
    if ambiguous then
      return nil, "reloaded connection id mapping is ambiguous"
    end
  end

  if prev_type ~= "" and prev_url ~= "" then
    local match, ambiguous = find_unique_match(function(candidate)
      return tostring(candidate.type or "") == prev_type
        and tostring(candidate.url or "") == prev_url
    end)
    if match then
      return match, nil
    end
    if ambiguous then
      return nil, "reloaded connection URL mapping is ambiguous"
    end
  end

  if prev_type ~= "" and prev_name ~= "" then
    local match, ambiguous = find_unique_match(function(candidate)
      return tostring(candidate.type or "") == prev_type
        and tostring(candidate.name or "") == prev_name
    end)
    if match then
      return match, nil
    end
    if ambiguous then
      return nil, "reloaded connection name mapping is ambiguous"
    end
  end

  if #source_conns == 1 then
    if prev_type ~= "" and tostring(source_conns[1].type or "") ~= prev_type then
      return nil, "reloaded connection type changed unexpectedly"
    end
    return source_conns[1], nil
  end

  return nil, "unable to map reloaded connection; reconnect manually from connection picker"
end

---@param conn_id connection_id
---@return { prompt_open: boolean, declined: boolean, latest_call_id: call_id|nil, latest_failed_ts: integer, owned_call_ids: table<call_id, true> }
local function ensure_episode(conn_id)
  episodes[conn_id] = episodes[conn_id] or {
    prompt_open = false,
    declined = false,
    latest_call_id = nil,
    latest_failed_ts = 0,
    owned_call_ids = {},
  }
  return episodes[conn_id]
end

---@param old_conn_id connection_id
---@param new_conn_id connection_id
local function emit_connection_rewritten(old_conn_id, new_conn_id)
  for key, listener in pairs(connection_rewritten_listeners) do
    local ok, err = pcall(listener, old_conn_id, new_conn_id)
    if not ok then
      utils.log("error", ("reconnect rewrite listener %q failed: %s"):format(key, tostring(err)))
    end
  end
end

function M.ensure_reconnect_listener()
  if reconnect_listener_registered then
    return
  end
  local api = get_api()
  if not api.core or type(api.core.register_event_listener) ~= "function" then
    return
  end
  reconnect_listener_registered = true
  api.core.register_event_listener("call_state_changed", M.handle_call_state_changed)
end

---@param call_id call_id
---@param meta dbee_retry_meta
function M.register_call(call_id, meta)
  M.ensure_reconnect_listener()
  if call_id == nil or call_id == "" then
    error("register_call requires call_id")
  end
  if not meta or not meta.conn_id then
    error("register_call requires meta.conn_id")
  end

  local copied = copy_retry_meta(meta)
  copied.conn_id = meta.conn_id
  calls_by_id[call_id] = copied
  add_call_to_conn(copied.conn_id, call_id)
end

---@param call_id call_id
function M.retire_call(call_id)
  if call_id == nil or call_id == "" then
    return
  end
  retired_by_retry[call_id] = true
end

---@param call_id call_id
function M.forget_call(call_id)
  if call_id == nil or call_id == "" then
    return
  end

  local meta = calls_by_id[call_id]
  if meta and meta.conn_id then
    remove_call_from_conn(meta.conn_id, call_id)
    local episode = episodes[meta.conn_id]
    if episode then
      episode.owned_call_ids[call_id] = nil
      if episode.latest_call_id == call_id then
        episode.latest_call_id = nil
      end
    end
  end

  calls_by_id[call_id] = nil
end

---@param conn_id connection_id
function M.reset_connection_episode(conn_id)
  local episode = episodes[conn_id]
  if not episode then
    prune_orphaned_tombstones()
    return
  end

  local owned_ids = {}
  if episode.latest_call_id then
    owned_ids[#owned_ids + 1] = episode.latest_call_id
  end
  for call_id in pairs(episode.owned_call_ids or {}) do
    if call_id ~= episode.latest_call_id then
      owned_ids[#owned_ids + 1] = call_id
    end
  end

  for _, call_id in ipairs(owned_ids) do
    clear_tombstones(call_id)
    M.forget_call(call_id)
  end

  episodes[conn_id] = nil
  prune_orphaned_tombstones()
end

---@param call_id call_id
---@param new_conn_id connection_id
---@param new_conn_name string?
---@param new_conn_type string?
function M.rewrite_meta_conn_id(call_id, new_conn_id, new_conn_name, new_conn_type)
  local meta = calls_by_id[call_id]
  if not meta or not meta.conn_id then
    return
  end

  local old_conn_id = meta.conn_id
  if old_conn_id ~= new_conn_id then
    remove_call_from_conn(old_conn_id, call_id)
    add_call_to_conn(new_conn_id, call_id)
  end

  meta.conn_id = new_conn_id
  meta.conn_name = new_conn_name
  meta.conn_type = new_conn_type or meta.conn_type
end

---@param old_conn_id connection_id
---@param new_conn_id connection_id
---@param new_conn_name string?
---@param new_conn_type string?
function M.rewrite_connection_identity(old_conn_id, new_conn_id, new_conn_name, new_conn_type)
  if old_conn_id == new_conn_id then
    return
  end

  local api = get_api()

  local ids = {}
  for call_id in pairs(call_ids_by_conn[old_conn_id] or {}) do
    ids[#ids + 1] = call_id
  end

  local note_ids_seen = {}
  for _, call_id in ipairs(ids) do
    local meta = calls_by_id[call_id]
    if meta then
      M.rewrite_meta_conn_id(call_id, new_conn_id, new_conn_name, new_conn_type)
      if meta.note_id and not note_ids_seen[meta.note_id] then
        note_ids_seen[meta.note_id] = true
        api.ui.rebind_note_connection(meta.note_id, new_conn_id, new_conn_name, new_conn_type)
      end
    end
  end

  local old_episode = episodes[old_conn_id]
  local new_episode = episodes[new_conn_id]
  if old_episode then
    if not new_episode then
      episodes[new_conn_id] = old_episode
    else
      local old_ts = old_episode.latest_failed_ts or 0
      local new_ts = new_episode.latest_failed_ts or 0
      if old_ts >= new_ts then
        new_episode.latest_call_id = old_episode.latest_call_id
      end
      new_episode.latest_failed_ts = math.max(new_ts, old_ts)
      for call_id in pairs(old_episode.owned_call_ids or {}) do
        new_episode.owned_call_ids[call_id] = true
      end
      new_episode.declined = new_episode.declined or old_episode.declined
      new_episode.prompt_open = new_episode.prompt_open == true
    end
    episodes[old_conn_id] = nil
  end

  emit_connection_rewritten(old_conn_id, new_conn_id)
end

---@param subscriber_key string
---@param listener fun(old_conn_id: connection_id, new_conn_id: connection_id)
function M.register_connection_rewritten_listener(subscriber_key, listener)
  if not subscriber_key or subscriber_key == "" then
    error("register_connection_rewritten_listener requires subscriber_key")
  end
  if connection_rewritten_listeners[subscriber_key] then
    error(("duplicate reconnect rewrite listener: %s"):format(subscriber_key))
  end
  connection_rewritten_listeners[subscriber_key] = listener
end

---@param conn_id connection_id
---@return dbee_retry_meta|nil
---@return call_id|nil
function M.get_latest_retry_meta(conn_id)
  local episode = episodes[conn_id]
  if episode and episode.latest_call_id and calls_by_id[episode.latest_call_id] then
    return calls_by_id[episode.latest_call_id], episode.latest_call_id
  end

  local latest_meta = nil
  local latest_call_id = nil
  local latest_ts = -1
  for call_id in pairs(call_ids_by_conn[conn_id] or {}) do
    local meta = calls_by_id[call_id]
    local failed_ts = meta and meta.last_failed_ts or 0
    if meta and failed_ts > latest_ts then
      latest_meta = meta
      latest_call_id = call_id
      latest_ts = failed_ts
    end
  end

  if latest_ts <= 0 then
    return nil, nil
  end
  return latest_meta, latest_call_id
end

---@param conn_id connection_id
---@param opts? { restore_current?: boolean }
---@return boolean
---@return string|connection_id|nil
---@return string|nil
---@return string|nil
function M.reconnect_connection(conn_id, opts)
  M.ensure_reconnect_listener()
  opts = opts or {}
  local api = get_api()

  if type(api.core.is_loaded) == "function" and not api.core.is_loaded() then
    return false, "dbee core not loaded", nil, nil
  end

  local handler = get_state().handler()
  if not handler or type(handler.source_reload_reconnect) ~= "function" then
    return false, "silent reconnect reload is not supported by current handler", nil, nil
  end

  local previous_current = nil
  local previous_current_source_id = nil
  local ok_current, current_or_err = pcall(api.core.get_current_connection)
  if ok_current then
    previous_current = current_or_err
    if previous_current and previous_current.id then
      previous_current_source_id = find_source_id_for_connection(previous_current.id)
    end
  end

  local target_conn = nil
  if previous_current and previous_current.id == conn_id then
    target_conn = previous_current
  elseif type(api.core.connection_get_params) == "function" then
    local ok_params, params = pcall(api.core.connection_get_params, conn_id)
    if ok_params then
      target_conn = params
    end
  end
  if not target_conn then
    return false, "could not load connection params for reconnect target", nil, nil
  end

  local source_id = find_source_id_for_connection(conn_id)
  if not source_id then
    return false, "could not locate source for current connection", nil, nil
  end

  M.reset_connection_episode(conn_id)

  local ok_reload, reload_result_or_err = pcall(handler.source_reload_reconnect, handler, source_id)
  if not ok_reload then
    return false, "failed reloading connection source: " .. tostring(reload_result_or_err), nil, nil
  end
  local reload_result = reload_result_or_err

  local reloaded_conn, resolve_err = resolve_reloaded_connection(source_id, target_conn)
  if not reloaded_conn then
    return false, resolve_err, nil, nil
  end

  local ok_set, set_err = pcall(api.core.set_current_connection, reloaded_conn.id)
  if not ok_set then
    return false, "failed selecting reloaded connection: " .. tostring(set_err), nil, nil
  end

  M.reset_connection_episode(reloaded_conn.id)

  if opts.restore_current ~= false and previous_current and previous_current.id ~= conn_id then
    local restore_conn = previous_current
    if previous_current_source_id and previous_current_source_id == source_id then
      local resolved_previous, resolve_err = resolve_reloaded_connection(source_id, previous_current)
      if not resolved_previous then
        utils.log(
          "warn",
          ("Reconnect succeeded, but could not restore previous current connection %q: %s"):format(
            tostring(previous_current.name or previous_current.id),
            tostring(resolve_err)
          )
        )
        return true, reloaded_conn.id, reloaded_conn.name, reloaded_conn.type
      end
      restore_conn = resolved_previous
    end

    local ok_restore, restore_err = pcall(api.core.set_current_connection, restore_conn.id)
    if not ok_restore then
      utils.log(
        "warn",
        ("Reconnect succeeded, but could not restore previous current connection %q: %s"):format(
          tostring(previous_current.name or previous_current.id),
          tostring(restore_err)
        )
      )
    end
  end

  local current_after = nil
  local ok_after, current_or_err = pcall(api.core.get_current_connection)
  if ok_after and current_or_err and current_or_err.id then
    current_after = current_or_err.id
  end
  reload_result.current_conn_id_after = current_after

  if reloaded_conn.id ~= conn_id then
    if type(handler.migrate_structure_flights) == "function" then
      handler:migrate_structure_flights(conn_id, reloaded_conn.id)
    end
    handler:emit_connection_invalidated_silent("reconnect_rewrite", reload_result)
  end

  return true, reloaded_conn.id, reloaded_conn.name, reloaded_conn.type
end

---@param target_conn_id connection_id
---@param call_id call_id
---@param meta dbee_retry_meta
---@param opts? { restore_current?: boolean }
---@return boolean
---@return any
---@return connection_id|nil
---@return dbee_retry_meta|nil
function M.retry_call(target_conn_id, call_id, meta, opts)
  opts = opts or {}
  local api = get_api()
  local ok_conn, new_conn_id_or_err, new_conn_name, new_conn_type =
    M.reconnect_connection(target_conn_id, { restore_current = opts.restore_current ~= false })
  if not ok_conn then
    return false, new_conn_id_or_err, nil, nil
  end

  local new_conn_id = new_conn_id_or_err
  if new_conn_id ~= target_conn_id then
    M.rewrite_connection_identity(target_conn_id, new_conn_id, new_conn_name, new_conn_type)
  end

  local updated_meta = vim.tbl_extend("force", meta, {
    conn_id = new_conn_id,
    conn_name = new_conn_name,
    conn_type = new_conn_type or meta.conn_type,
  })

  M.retire_call(call_id)
  M.forget_call(call_id)

  if updated_meta.retry_fn then
    local new_call_id, retry_err = updated_meta.retry_fn(new_conn_id, updated_meta)
    if retry_err then
      return false, retry_err, new_conn_id, updated_meta
    end
    return true, new_call_id, new_conn_id, updated_meta
  end

  local ok_exec, new_call_or_err =
    pcall(api.core.connection_execute, new_conn_id, updated_meta.resolved_query, updated_meta.exec_opts)
  if not ok_exec or not new_call_or_err then
    return false, new_call_or_err, new_conn_id, updated_meta
  end

  local new_call = new_call_or_err
  M.register_call(new_call.id, updated_meta)
  if updated_meta.on_retry_created then
    updated_meta.on_retry_created(new_call, updated_meta)
  else
    api.ui.result_set_call(new_call)
    require("dbee").open()
  end

  return true, new_call, new_conn_id, updated_meta
end

---@param data { conn_id: connection_id, call: CallDetails }
function M.handle_call_state_changed(data)
  if not data or not data.conn_id or not data.call or not data.call.id then
    return
  end

  local state = data.call.state
  local kind = data.call.error_kind
  local ts = data.call.timestamp_us or 0
  local meta = calls_by_id[data.call.id]
  local effective_conn_id = (meta and meta.conn_id) or data.conn_id
  local episode = episodes[effective_conn_id]
  local conn_name = (meta and meta.conn_name) or effective_conn_id

  if terminal_states[state] and (retired_by_retry[data.call.id] or superseded[data.call.id]) then
    M.forget_call(data.call.id)
    clear_tombstones(data.call.id)
    return
  end

  if state == "archived" then
    if episode and ts > (episode.latest_failed_ts or 0) then
      M.reset_connection_episode(effective_conn_id)
    end
    M.forget_call(data.call.id)
    return
  end

  if state == "canceled" then
    M.forget_call(data.call.id)
    clear_tombstones(data.call.id)
    return
  end

  if (state == "executing_failed" or state == "retrieving_failed" or state == "archive_failed")
    and kind ~= "disconnected"
  then
    M.forget_call(data.call.id)
    clear_tombstones(data.call.id)
    return
  end

  if kind ~= "disconnected" then
    return
  end

  if state ~= "executing_failed" and state ~= "retrieving_failed" and state ~= "archive_failed" then
    return
  end

  episode = episode or ensure_episode(effective_conn_id)
  episodes[effective_conn_id] = episode

  if ts >= (episode.latest_failed_ts or 0) then
    if episode.latest_call_id and episode.latest_call_id ~= data.call.id then
      superseded[episode.latest_call_id] = true
      M.forget_call(episode.latest_call_id)
    end
    episode.latest_failed_ts = ts
    episode.latest_call_id = data.call.id
    episode.owned_call_ids[data.call.id] = true
    if meta then
      meta.last_failed_ts = ts
    end
  else
    M.forget_call(data.call.id)
    return
  end

  if episode.prompt_open or episode.declined then
    return
  end

  episode.prompt_open = true
  vim.ui.select({ "No", "Yes" }, { prompt = ('Reconnect "%s" and retry latest failed query?'):format(conn_name) }, function(choice)
    local callback_meta = calls_by_id[data.call.id]
    local fresh_effective_conn_id = (callback_meta and callback_meta.conn_id) or effective_conn_id
    local fresh_episode = episodes[fresh_effective_conn_id]

    if fresh_episode then
      fresh_episode.prompt_open = false
    end

    if choice == nil or choice == "No" then
      if fresh_episode then
        fresh_episode.declined = true
      end
      utils.log("warn", ('Reconnect declined for "%s"'):format(conn_name))
      return
    end

    if not fresh_episode then
      utils.log("warn", ('Reconnect target reset for "%s"'):format(conn_name))
      return
    end

    local call_id = fresh_episode.latest_call_id
    if not call_id then
      utils.log("warn", ('No target call for reconnect on "%s"'):format(conn_name))
      return
    end

    local latest_meta = calls_by_id[call_id]
    if not latest_meta then
      utils.log("warn", ('Retry target vanished for "%s"'):format(conn_name))
      return
    end

    local ok_retry, result_or_err =
      M.retry_call(fresh_effective_conn_id, call_id, latest_meta, { restore_current = true })
    if not ok_retry then
      utils.log("warn", ('Auto-retry failed for %s: %s'):format(conn_name, tostring(result_or_err)))
    end
  end)
end

function M.synthetic_step2_pattern()
  return SYNTHETIC_STEP2_PATTERN
end

function M._debug_snapshot()
  local call_count = 0
  for _ in pairs(calls_by_id) do
    call_count = call_count + 1
  end
  return {
    calls_by_id = vim.deepcopy(calls_by_id),
    call_ids_by_conn = vim.deepcopy(call_ids_by_conn),
    episodes = vim.deepcopy(episodes),
    retired_by_retry = vim.deepcopy(retired_by_retry),
    superseded = vim.deepcopy(superseded),
    call_count = call_count,
    reconnect_listener_registered = reconnect_listener_registered,
    connection_rewritten_listener_keys = vim.tbl_keys(connection_rewritten_listeners),
  }
end

return M
