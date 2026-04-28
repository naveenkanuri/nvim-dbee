local event_bus = require("dbee.handler.__events")
local utils = require("dbee.utils")
local register_remote_plugin = require("dbee.api.__register")

---@param err any
---@return boolean
local function is_invalid_channel_error(err)
  local msg = tostring(err or ""):lower()
  return msg:find("invalid channel", 1, true) ~= nil
end

---@param conns ConnectionParams[]?
---@return ConnectionParams[]
local function copy_connections(conns)
  local copied = {}
  for _, conn in ipairs(conns or {}) do
    if conn and conn.id and conn.id ~= "" then
      copied[#copied + 1] = {
        id = conn.id,
        name = conn.name,
        type = conn.type,
        url = conn.url,
      }
    end
  end

  table.sort(copied, function(left, right)
    local left_name = tostring(left.name or left.id or "")
    local right_name = tostring(right.name or right.id or "")
    if left_name == right_name then
      return tostring(left.id or "") < tostring(right.id or "")
    end
    return left_name < right_name
  end)

  return copied
end

---@param conns ConnectionParams[]
---@return connection_id[]
local function connection_ids(conns)
  local ids = {}
  for _, conn in ipairs(conns or {}) do
    if conn and conn.id and conn.id ~= "" then
      ids[#ids + 1] = conn.id
    end
  end
  table.sort(ids)
  return ids
end

---@param conn_id connection_id?
---@param ids table<string, boolean>
local function add_conn_id(conn_id, ids)
  if conn_id and conn_id ~= "" then
    ids[conn_id] = true
  end
end

---@param candidates ConnectionParams[]
---@param predicate fun(candidate: ConnectionParams): boolean
---@return ConnectionParams|nil
---@return boolean ambiguous
local function find_unique_connection(candidates, predicate)
  local match = nil
  for _, candidate in ipairs(candidates or {}) do
    if candidate and candidate.id and candidate.id ~= "" and predicate(candidate) then
      if match ~= nil then
        return nil, true
      end
      match = candidate
    end
  end
  return match, false
end

---@param previous ConnectionParams[]
---@param current ConnectionParams[]
---@return { old_conn_id: connection_id, new_conn_id: connection_id }[]
local function build_rewrites(previous, current)
  local rewrites = {}
  local used_new_ids = {}

  for _, old in ipairs(previous or {}) do
    local prev_id = tostring(old.id or "")
    local prev_type = tostring(old.type or "")
    local prev_url = tostring(old.url or "")
    local prev_name = tostring(old.name or "")

    local function unused(candidate)
      return candidate and candidate.id and not used_new_ids[candidate.id]
    end

    local match, ambiguous = nil, false
    if prev_id ~= "" then
      match, ambiguous = find_unique_connection(current, function(candidate)
        return unused(candidate)
          and tostring(candidate.id or "") == prev_id
          and (prev_type == "" or tostring(candidate.type or "") == prev_type)
      end)
    end

    if not match and not ambiguous and prev_type ~= "" and prev_url ~= "" then
      match, ambiguous = find_unique_connection(current, function(candidate)
        return unused(candidate)
          and tostring(candidate.type or "") == prev_type
          and tostring(candidate.url or "") == prev_url
      end)
    end

    if not match and not ambiguous and prev_type ~= "" and prev_name ~= "" then
      match, ambiguous = find_unique_connection(current, function(candidate)
        return unused(candidate)
          and tostring(candidate.type or "") == prev_type
          and tostring(candidate.name or "") == prev_name
      end)
    end

    if match and match.id ~= old.id then
      rewrites[#rewrites + 1] = {
        old_conn_id = old.id,
        new_conn_id = match.id,
      }
    end

    if match then
      used_new_ids[match.id] = true
    end
  end

  table.sort(rewrites, function(left, right)
    return tostring(left.old_conn_id or "") < tostring(right.old_conn_id or "")
  end)

  return rewrites
end

-- Handler is an aggregator of connections
---@class Handler
---@field private sources table<source_id, Source>
---@field private source_conn_lookup table<source_id, connection_id[]>
---@field private authoritative_root_epoch table<connection_id, integer>
local Handler = {}

---@param sources? Source[]
---@return Handler
function Handler:new(sources)
  -- class object
  local o = {
    sources = {},
    source_conn_lookup = {},
    authoritative_root_epoch = {},
  }
  setmetatable(o, self)
  self.__index = self

  -- initialize the sources
  sources = sources or {}
  for _, source in ipairs(sources) do
    local ok, mes = pcall(o.add_source, o, source)
    if not ok then
      utils.log("error", "failed registering source: " .. source:name() .. " " .. mes, "core")
    end
  end

  return o
end

---@param event core_event_name
---@param listener event_listener
function Handler:register_event_listener(event, listener)
  event_bus.register(event, listener)
end

---@private
---@return connection_id?
function Handler:_current_connection_id()
  local current = self:get_current_connection()
  return current and current.id or nil
end

---@private
---@param conn_ids connection_id[]
---@return integer|nil
function Handler:_bump_authoritative_root_epoch(conn_ids)
  local unique = {}
  for _, conn_id in ipairs(conn_ids or {}) do
    add_conn_id(conn_id, unique)
  end

  local ordered = vim.tbl_keys(unique)
  table.sort(ordered)
  if #ordered == 0 then
    return nil
  end

  local next_epoch = 0
  for _, conn_id in ipairs(ordered) do
    next_epoch = math.max(next_epoch, self.authoritative_root_epoch[conn_id] or 0)
  end
  next_epoch = next_epoch + 1

  for _, conn_id in ipairs(ordered) do
    self.authoritative_root_epoch[conn_id] = next_epoch
  end

  return next_epoch
end

---@private
---@param result table
---@return connection_id[]
function Handler:_affected_reload_conn_ids(result)
  local unique = {}
  for _, conn_id in ipairs(result.retired_conn_ids or {}) do
    add_conn_id(conn_id, unique)
  end
  for _, conn_id in ipairs(result.new_conn_ids or {}) do
    add_conn_id(conn_id, unique)
  end

  local ids = vim.tbl_keys(unique)
  table.sort(ids)
  return ids
end

---@private
---@param reason string
---@param result table
---@param opts? { silent?: boolean }
function Handler:_emit_connection_invalidated(reason, result, opts)
  opts = opts or {}
  event_bus.trigger("connection_invalidated", {
    reason = reason,
    source_id = result.source_id,
    retired_conn_ids = vim.deepcopy(result.retired_conn_ids or {}),
    new_conn_ids = vim.deepcopy(result.new_conn_ids or {}),
    current_conn_id_before = result.current_conn_id_before,
    current_conn_id_after = result.current_conn_id_after,
    silent = opts.silent == true,
    authoritative_root_epoch = result.authoritative_root_epoch,
  })
end

---@private
---@param payload table
function Handler:_emit_source_reload_failed(payload)
  event_bus.trigger("source_reload_failed", payload)
end

---@private
---@param source_id source_id
---@param reason string
---@param stage string
---@param message any
---@param result? table
function Handler:_source_reload_failed_payload(source_id, reason, stage, message, result)
  result = result or {}
  return {
    source_id = source_id,
    reason = reason,
    stage = stage,
    error_kind = stage == "mutation" and "mutation_failed" or "reload_failed",
    message = tostring(message),
    current_conn_id_before = result.current_conn_id_before,
    current_conn_id_after = result.current_conn_id_after,
    retired_conn_ids = vim.deepcopy(result.retired_conn_ids or {}),
    new_conn_ids = vim.deepcopy(result.new_conn_ids or {}),
    authoritative_root_epoch = result.authoritative_root_epoch,
  }
end

---@private
---@param source_id source_id
---@param opts? { eventful?: boolean }
---@return { source_id: source_id, retired_conn_ids: connection_id[], new_conn_ids: connection_id[], current_conn_id_before: connection_id|nil, current_conn_id_after: connection_id|nil, rewrites: { old_conn_id: connection_id, new_conn_id: connection_id }[], authoritative_root_epoch: integer|nil, reload_error: { error_kind: string, message: string }|nil }
function Handler:_source_reload_silent(source_id, opts)
  opts = opts or {}

  local source = self.sources[source_id]
  if not source then
    error("no source with id: " .. source_id)
  end

  local previous_connections = copy_connections(self:source_get_connections(source_id))
  local current_conn_id_before = self:_current_connection_id()

  for _, conn in ipairs(previous_connections) do
    pcall(vim.fn.DbeeDeleteConnection, conn.id)
  end

  self.source_conn_lookup[source_id] = {}

  local reload_error = nil
  local ok_specs, specs_or_err = pcall(source.load, source)
  if ok_specs then
    for _, spec in ipairs(specs_or_err or {}) do
      if not spec.id or spec.id == "" then
        reload_error = {
          error_kind = "reload_failed",
          message = string.format(
            'connection without an id: { name: "%s", type: %s, url: %s } ',
            spec.name,
            spec.type,
            spec.url
          ),
        }
        break
      end

      local ok_create, conn_id_or_err = pcall(vim.fn.DbeeCreateConnection, spec)
      if not ok_create then
        reload_error = {
          error_kind = "reload_failed",
          message = tostring(conn_id_or_err),
        }
        break
      end

      self.source_conn_lookup[source_id][#self.source_conn_lookup[source_id] + 1] = conn_id_or_err
    end
  else
    reload_error = {
      error_kind = "reload_failed",
      message = tostring(specs_or_err),
    }
  end

  local current_connections = copy_connections(self:source_get_connections(source_id))
  local result = {
    source_id = source_id,
    retired_conn_ids = connection_ids(previous_connections),
    new_conn_ids = connection_ids(current_connections),
    current_conn_id_before = current_conn_id_before,
    current_conn_id_after = self:_current_connection_id(),
    rewrites = build_rewrites(previous_connections, current_connections),
    authoritative_root_epoch = nil,
    reload_error = reload_error,
  }

  if opts.eventful then
    result.authoritative_root_epoch = self:_bump_authoritative_root_epoch(self:_affected_reload_conn_ids(result))
  end

  return result
end

-- add new source and load connections from it
---@param source Source
function Handler:add_source(source)
  local id = source:name()

  -- keep the old source if present
  self.sources[id] = self.sources[id] or source

  local result = self:_source_reload_silent(id, { eventful = false })
  if result.reload_error then
    error(result.reload_error.message)
  end
end

---@return Source[]
function Handler:get_sources()
  local sources = vim.tbl_values(self.sources)
  table.sort(sources, function(k1, k2)
    return k1:name() < k2:name()
  end)
  return sources
end

---Closes old connections of that source
---and loads new ones.
---@param id source_id
function Handler:source_reload(id)
  local result = self:_source_reload_silent(id, { eventful = true })
  self:_emit_connection_invalidated("source_reload", result)

  if result.reload_error then
    self:_emit_source_reload_failed(self:_source_reload_failed_payload(
      id,
      "source_reload",
      "reload",
      result.reload_error.message,
      result
    ))
    error(result.reload_error.message)
  end
end

---@param id source_id
---@param details ConnectionParams
---@return connection_id
function Handler:source_add_connection(id, details)
  if not details then
    error("no connection details provided")
  end

  local source = self.sources[id]
  if not source then
    error("no source with id: " .. id)
  end

  if type(source.create) ~= "function" then
    error("source does not support adding connections")
  end

  local ok_create, conn_id_or_err = pcall(source.create, source, details)
  if not ok_create then
    self:_emit_source_reload_failed(self:_source_reload_failed_payload(
      id,
      "source_add",
      "mutation",
      conn_id_or_err
    ))
    error(conn_id_or_err)
  end

  local result = self:_source_reload_silent(id, { eventful = true })
  self:_emit_connection_invalidated("source_add", result)

  if result.reload_error then
    self:_emit_source_reload_failed(self:_source_reload_failed_payload(
      id,
      "source_add",
      "reload",
      result.reload_error.message,
      result
    ))
    error(result.reload_error.message)
  end

  return conn_id_or_err
end

---@param id source_id
---@param conn_id connection_id
function Handler:source_remove_connection(id, conn_id)
  local source = self.sources[id]
  if not source then
    error("no source with id: " .. id)
  end

  if not conn_id or conn_id == "" then
    error("no connection id provided")
  end

  if type(source.delete) ~= "function" then
    error("source does not support removing connections")
  end

  local ok_delete, delete_err = pcall(source.delete, source, conn_id)
  if not ok_delete then
    self:_emit_source_reload_failed(self:_source_reload_failed_payload(
      id,
      "source_delete",
      "mutation",
      delete_err
    ))
    error(delete_err)
  end

  local result = self:_source_reload_silent(id, { eventful = true })
  self:_emit_connection_invalidated("source_delete", result)

  if result.reload_error then
    self:_emit_source_reload_failed(self:_source_reload_failed_payload(
      id,
      "source_delete",
      "reload",
      result.reload_error.message,
      result
    ))
    error(result.reload_error.message)
  end
end

---@param id source_id
---@param conn_id connection_id
---@param details ConnectionParams
function Handler:source_update_connection(id, conn_id, details)
  local source = self.sources[id]
  if not source then
    error("no source with id: " .. id)
  end

  if not conn_id or conn_id == "" then
    error("no connection id provided")
  end

  if not details then
    error("no connection details provided")
  end

  if type(source.update) ~= "function" then
    error("source does not support updating connections")
  end

  local ok_update, update_err = pcall(source.update, source, conn_id, details)
  if not ok_update then
    self:_emit_source_reload_failed(self:_source_reload_failed_payload(
      id,
      "source_update",
      "mutation",
      update_err
    ))
    error(update_err)
  end

  local result = self:_source_reload_silent(id, { eventful = true })
  self:_emit_connection_invalidated("source_update", result)

  if result.reload_error then
    self:_emit_source_reload_failed(self:_source_reload_failed_payload(
      id,
      "source_update",
      "reload",
      result.reload_error.message,
      result
    ))
    error(result.reload_error.message)
  end
end

---@param id source_id
---@return ConnectionParams[]
function Handler:source_get_connections(id)
  local conn_ids = self.source_conn_lookup[id] or {}
  if #conn_ids < 1 then
    return {}
  end

  ---@type ConnectionParams[]?
  local ret = vim.fn.DbeeGetConnections(conn_ids)
  if not ret or ret == vim.NIL then
    return {}
  end

  table.sort(ret, function(k1, k2)
    return k1.name < k2.name
  end)

  return ret
end

---Return an authoritative, side-effect-free connection snapshot for bootstrap
---consumers before they switch to live `connection_invalidated` events.
---@return ConnectionStateSnapshot
function Handler:get_connection_state_snapshot()
  local snapshot = {
    sources = {},
    current_connection = self:get_current_connection(),
    snapshot_authoritative_epoch = {},
  }

  for _, source in ipairs(self:get_sources()) do
    local source_id = source:name()
    local connections = copy_connections(self:source_get_connections(source_id))
    snapshot.sources[#snapshot.sources + 1] = {
      id = source_id,
      name = source_id,
      connections = connections,
    }

    for _, conn in ipairs(connections) do
      snapshot.snapshot_authoritative_epoch[conn.id] = self.authoritative_root_epoch[conn.id] or 0
    end
  end

  return snapshot
end

---@param helpers table<string, table_helpers> extra helpers per type
function Handler:add_helpers(helpers)
  for type, help in pairs(helpers) do
    vim.fn.DbeeAddHelpers(type, help)
  end
end

---@param id connection_id
---@param opts TableOpts
---@return table_helpers helpers list of table helpers
function Handler:connection_get_helpers(id, opts)
  local helpers = vim.fn.DbeeConnectionGetHelpers(id, {
    table = opts.table,
    schema = opts.schema,
    materialization = opts.materialization,
  })
  if not helpers or helpers == vim.NIL then
    return {}
  end

  return helpers
end

---@return ConnectionParams?
function Handler:get_current_connection()
  local ok, ret = pcall(vim.fn.DbeeGetCurrentConnection)
  if not ok or ret == vim.NIL then
    return
  end
  return ret
end

---@param id connection_id
function Handler:set_current_connection(id)
  vim.fn.DbeeSetCurrentConnection(id)
end

---@param id connection_id
---@param query string
---@param opts? QueryExecuteOpts
---@return CallDetails
function Handler:connection_execute(id, query, opts)
  if opts == nil then
    return vim.fn.DbeeConnectionExecute(id, query)
  end
  return vim.fn.DbeeConnectionExecute(id, query, opts)
end

---@param id connection_id
---@return DBStructure[]
function Handler:connection_get_structure(id)
  local ret = vim.fn.DbeeConnectionGetStructure(id)
  if not ret or ret == vim.NIL then
    return {}
  end
  return ret
end

---@param id connection_id
---@param request_id? integer
---@param root_epoch? integer
---@param caller_token? string
function Handler:connection_get_structure_async(id, request_id, root_epoch, caller_token)
  if request_id == nil and root_epoch == nil and caller_token == nil then
    vim.fn.DbeeConnectionGetStructureAsync(id)
    return
  end
  vim.fn.DbeeConnectionGetStructureAsync(id, request_id or 0, root_epoch or 0, caller_token or "")
end

---@param id connection_id
---@param opts { table: string, schema: string, materialization: string }
---@return Column[]
function Handler:connection_get_columns(id, opts)
  local out = vim.fn.DbeeConnectionGetColumns(id, opts)
  if not out or out == vim.NIL then
    return {}
  end

  return out
end

---@param id connection_id
---@param request_id integer
---@param branch_id string
---@param root_epoch integer
---@param opts { table: string, schema: string, materialization: string, kind?: string }
function Handler:connection_get_columns_async(id, request_id, branch_id, root_epoch, opts)
  vim.fn.DbeeConnectionGetColumnsAsync(id, request_id, branch_id, root_epoch, {
    table = opts.table,
    schema = opts.schema,
    materialization = opts.materialization,
    kind = opts.kind or "columns",
  })
end

---@param id connection_id
---@return ConnectionParams?
function Handler:connection_get_params(id)
  local ret = vim.fn.DbeeConnectionGetParams(id)
  if not ret or ret == vim.NIL then
    return
  end
  return ret
end

---@param id connection_id
---@return string current_db
---@return string[] available_dbs
function Handler:connection_list_databases(id)
  local ret = vim.fn.DbeeConnectionListDatabases(id)
  if not ret or ret == vim.NIL then
    return "", {}
  end

  return unpack(ret)
end

---@param id connection_id
---@param database string
function Handler:connection_select_database(id, database)
  vim.fn.DbeeConnectionSelectDatabase(id, database)
end

---@param id connection_id
---@return CallDetails[]
function Handler:connection_get_calls(id)
  local ret = vim.fn.DbeeConnectionGetCalls(id)
  if not ret or ret == vim.NIL then
    return {}
  end
  return ret
end

---@param id call_id
function Handler:call_cancel(id)
  local ok, err = pcall(vim.fn.DbeeCallCancel, id)
  if ok then
    return true
  end

  if is_invalid_channel_error(err) then
    local reg_ok, reg_err = pcall(register_remote_plugin)
    if not reg_ok then
      local msg = "failed re-registering dbee RPC host: " .. tostring(reg_err)
      utils.log("warn", msg, "core")
      return false, msg
    end

    local retry_ok, retry_err = pcall(vim.fn.DbeeCallCancel, id)
    if retry_ok then
      return true
    end

    local msg = "failed cancelling call after host re-register: " .. tostring(retry_err)
    utils.log("warn", msg, "core")
    return false, msg
  end

  local msg = "failed cancelling call: " .. tostring(err)
  utils.log("warn", msg, "core")
  return false, msg
end

---@param id call_id
---@param bufnr integer
---@param from integer
---@param to integer
---@return integer # total number of rows
function Handler:call_display_result(id, bufnr, from, to)
  local length = vim.fn.DbeeCallDisplayResult(id, { buffer = bufnr, from = from, to = to })
  if not length or length == vim.NIL then
    return 0
  end
  return length
end

---@alias store_format "csv"|"json"|"table"
---@alias store_output "file"|"yank"|"buffer"

---@param id call_id
---@param format store_format format of the output
---@param output store_output where to pipe the results
---@param opts { from: integer, to: integer, extra_arg: any }
function Handler:call_store_result(id, format, output, opts)
  opts = opts or {}

  local from = opts.from or 0
  local to = opts.to or -1

  vim.fn.DbeeCallStoreResult(id, format, output, {
    from = from,
    to = to,
    extra_arg = opts.extra_arg,
  })
end

return Handler
