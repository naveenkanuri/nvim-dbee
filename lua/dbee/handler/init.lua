local event_bus = require("dbee.handler.__events")
local utils = require("dbee.utils")
local register_remote_plugin = require("dbee.api.__register")

local SINGLEFLIGHT_CALLER_TOKEN = "__singleflight"
local BOOTSTRAP_BUFFER_LIMIT = 64
local BOOTSTRAP_OVERFLOW_MAX = 3

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

---@param conns ConnectionParams[]
---@param conn_id connection_id?
---@return boolean
local function connection_in_list(conns, conn_id)
  if not conn_id or conn_id == "" then
    return false
  end
  for _, conn in ipairs(conns or {}) do
    if conn and conn.id == conn_id then
      return true
    end
  end
  return false
end

---@param rewrites { old_conn_id: connection_id, new_conn_id: connection_id }[]
---@param old_conn_id connection_id?
---@return connection_id|nil
local function rewrite_target_for(rewrites, old_conn_id)
  if not old_conn_id or old_conn_id == "" then
    return nil
  end
  for _, rewrite in ipairs(rewrites or {}) do
    if rewrite.old_conn_id == old_conn_id then
      return rewrite.new_conn_id
    end
  end
  return nil
end

---@param conn_id connection_id
---@param epoch integer
---@return string
local function singleflight_key(conn_id, epoch)
  return tostring(conn_id or "") .. "\x1f" .. tostring(epoch or 0)
end

---@param payload any
---@return any
local function copy_payload(payload)
  if payload == nil or payload == vim.NIL then
    return nil
  end
  return vim.deepcopy(payload)
end

-- Handler is an aggregator of connections
---@class Handler
---@field private sources table<source_id, Source>
---@field private source_conn_lookup table<source_id, connection_id[]>
---@field private authoritative_root_epoch table<connection_id, integer>
---@field private _next_singleflight_request_id integer
---@field private _structure_flights table<string, { conn_id: connection_id, epoch: integer, request_id: integer, waiters: table[], consumer_slots: table<string, true>, alias_conn_ids?: table<string, true> }>
---@field private _structure_request_lookup table<integer, string>
---@field private _connection_invalidated_consumers table<string, { listener: event_listener, state: string, generation: integer, buffer?: { events: table[], last_drain_size: integer }, consecutive_overflows: integer, warning?: table }>
local Handler = {}

---@param sources? Source[]
---@return Handler
function Handler:new(sources)
  -- class object
  local o = {
    sources = {},
    source_conn_lookup = {},
    authoritative_root_epoch = {},
    _next_singleflight_request_id = 0,
    _structure_flights = {},
    _structure_request_lookup = {},
    _connection_invalidated_consumers = {},
  }
  setmetatable(o, self)
  self.__index = self

  event_bus.register("structure_loaded", function(data)
    o:_on_singleflight_structure_loaded(data)
  end)
  event_bus.register("connection_invalidated", function(data)
    o:_dispatch_connection_invalidated(data)
  end)

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

---@param conn_id connection_id
---@return integer
function Handler:get_authoritative_root_epoch(conn_id)
  return self.authoritative_root_epoch[conn_id] or 0
end

---@param conn_ids connection_id[]
---@return integer|nil
function Handler:bump_authoritative_root_epoch(conn_ids)
  return self:_bump_authoritative_root_epoch(conn_ids)
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
---@param consumer table
---@param payload table
function Handler:_notify_connection_invalidated_consumer(consumer, payload)
  if type(consumer.listener) ~= "function" then
    return
  end

  local ok, err = pcall(consumer.listener, copy_payload(payload))
  if not ok then
    utils.log("error", "connection invalidated consumer failed: " .. tostring(err), "core")
  end
end

---@param consumer_id string
---@param listener event_listener
---@return integer generation
function Handler:begin_connection_invalidated_bootstrap(consumer_id, listener)
  if not consumer_id or consumer_id == "" then
    error("missing consumer_id")
  end
  if type(listener) ~= "function" then
    error("missing connection_invalidated bootstrap listener")
  end

  local previous = self._connection_invalidated_consumers[consumer_id]
  local generation = previous and (previous.generation + 1) or 0
  self._connection_invalidated_consumers[consumer_id] = {
    listener = listener,
    state = "bootstrap",
    generation = generation,
    buffer = {
      events = {},
      last_drain_size = 0,
    },
    consecutive_overflows = 0,
    warning = nil,
  }

  return generation
end

---@param consumer_id string
---@param generation integer
---@return { kind: string, generation?: integer, events?: table[], warning?: table, message?: string }
function Handler:drain_connection_invalidated_bootstrap(consumer_id, generation)
  local consumer = self._connection_invalidated_consumers[consumer_id]
  if not consumer then
    return {
      kind = "missing",
      message = "connection_invalidated consumer is not registered",
    }
  end

  if consumer.state == "stormed" then
    return {
      kind = "storm",
      generation = consumer.generation,
      message = consumer.warning and consumer.warning.message or "bootstrap overflow storm",
      warning = copy_payload(consumer.warning),
    }
  end

  if generation ~= consumer.generation then
    return {
      kind = "restart",
      generation = consumer.generation,
      warning = copy_payload(consumer.warning),
      message = consumer.warning and consumer.warning.message or "bootstrap generation changed",
    }
  end

  local buffer = consumer.buffer or {
    events = {},
    last_drain_size = 0,
  }
  consumer.buffer = buffer
  consumer.buffer.last_drain_size = #buffer.events
  local warning = consumer.warning
  consumer.warning = nil

  return {
    kind = "ok",
    generation = consumer.generation,
    events = copy_payload(buffer.events) or {},
    warning = copy_payload(warning),
  }
end

---@param consumer_id string
---@param generation? integer
---@return { kind: string, generation?: integer, events?: table[], warning?: table, message?: string }
function Handler:promote_to_live(consumer_id, generation)
  local consumer = self._connection_invalidated_consumers[consumer_id]
  if not consumer then
    return {
      kind = "missing",
      message = "connection_invalidated consumer is not registered",
    }
  end

  if consumer.state == "stormed" then
    return {
      kind = "storm",
      generation = consumer.generation,
      message = consumer.warning and consumer.warning.message or "bootstrap overflow storm",
      warning = copy_payload(consumer.warning),
    }
  end

  local expected_generation = generation == nil and consumer.generation or generation
  if expected_generation ~= consumer.generation then
    return {
      kind = "restart",
      generation = consumer.generation,
      warning = copy_payload(consumer.warning),
      message = consumer.warning and consumer.warning.message or "bootstrap generation changed",
    }
  end

  -- Neovim runs these callbacks on the main loop; because this function does not
  -- yield, sealing the bootstrap buffer and flipping to live mode is atomic.
  local buffer = consumer.buffer or {
    events = {},
    last_drain_size = 0,
  }
  local tail = {}
  for index = (buffer.last_drain_size or 0) + 1, #buffer.events do
    tail[#tail + 1] = copy_payload(buffer.events[index])
  end

  consumer.state = "live"
  consumer.buffer = nil
  consumer.warning = nil
  consumer.consecutive_overflows = 0

  return {
    kind = "ok",
    generation = consumer.generation,
    events = tail,
  }
end

---@param consumer_id string
function Handler:teardown_connection_invalidated_consumer(consumer_id)
  self._connection_invalidated_consumers[consumer_id] = nil
end

---@private
---@param data ConnectionInvalidatedEvent
function Handler:_dispatch_connection_invalidated(data)
  for consumer_id, consumer in pairs(self._connection_invalidated_consumers) do
    if consumer.state == "live" then
      self:_notify_connection_invalidated_consumer(consumer, data)
    elseif consumer.state == "bootstrap" then
      local buffer = consumer.buffer or {
        events = {},
        last_drain_size = 0,
      }
      consumer.buffer = buffer

      if #buffer.events < BOOTSTRAP_BUFFER_LIMIT then
        buffer.events[#buffer.events + 1] = copy_payload(data)
      else
        consumer.consecutive_overflows = (consumer.consecutive_overflows or 0) + 1
        if consumer.consecutive_overflows > BOOTSTRAP_OVERFLOW_MAX then
          consumer.state = "stormed"
          consumer.warning = {
            kind = "storm",
            consumer_id = consumer_id,
            generation = consumer.generation,
            message = string.format(
              "[dbee] bootstrap_overflow_storm for %s; teardown and reinitialize before resuming",
              consumer_id
            ),
          }
          self:_notify_connection_invalidated_consumer(consumer, consumer.warning)
        else
          local next_generation = consumer.generation + 1
          consumer.warning = {
            kind = "overflow",
            consumer_id = consumer_id,
            previous_generation = consumer.generation,
            generation = next_generation,
            message = string.format(
              "[dbee] bootstrap event buffer overflowed for %s; resyncing snapshot",
              consumer_id
            ),
          }
          consumer.generation = next_generation
          consumer.buffer = {
            events = {},
            last_drain_size = 0,
          }
          self:_notify_connection_invalidated_consumer(consumer, consumer.warning)
          consumer.buffer.events[#consumer.buffer.events + 1] = copy_payload(data)
        end
      end
    end
  end
end

---@private
---@param waiter table
---@param payload table
function Handler:_notify_structure_waiter(waiter, payload)
  if type(waiter.callback) ~= "function" then
    return
  end

  local ok, err = pcall(waiter.callback, copy_payload(payload))
  if not ok then
    utils.log("error", "structure singleflight waiter failed: " .. tostring(err), "core")
  end
end

---@private
---@param conn_id connection_id
---@param new_epoch integer
function Handler:_supersede_structure_flights(conn_id, new_epoch)
  local keys_to_drop = {}
  for key, flight in pairs(self._structure_flights) do
    if flight.conn_id == conn_id and flight.epoch < new_epoch then
      for _, waiter in ipairs(flight.waiters or {}) do
        self:_notify_structure_waiter(waiter, {
          conn_id = conn_id,
          request_id = waiter.request_id,
          root_epoch = flight.epoch,
          caller_token = waiter.caller_token,
          error_kind = "superseded",
          new_epoch = new_epoch,
        })
      end
      keys_to_drop[#keys_to_drop + 1] = key
    end
  end

  for _, key in ipairs(keys_to_drop) do
    local flight = self._structure_flights[key]
    if flight then
      self._structure_request_lookup[flight.request_id] = nil
    end
    self._structure_flights[key] = nil
  end
end

---@param opts { conn_id: connection_id, consumer: string, request_id?: integer, caller_token?: string, callback?: fun(payload: table) }
---@return { epoch: integer, request_id: integer, joined: boolean }
function Handler:connection_get_structure_singleflight(opts)
  if not opts or not opts.conn_id or opts.conn_id == "" then
    error("missing connection id for singleflight structure load")
  end
  if not opts.consumer or opts.consumer == "" then
    error("missing structure singleflight consumer")
  end

  local epoch = self:get_authoritative_root_epoch(opts.conn_id)
  local key = singleflight_key(opts.conn_id, epoch)
  local waiter = {
    consumer = opts.consumer,
    request_id = opts.request_id or 0,
    caller_token = opts.caller_token,
    callback = opts.callback,
  }

  local flight = self._structure_flights[key]
  if flight then
    flight.waiters[#flight.waiters + 1] = waiter
    flight.consumer_slots[opts.consumer] = true
    return {
      epoch = epoch,
      request_id = waiter.request_id,
      joined = true,
    }
  end

  self:_supersede_structure_flights(opts.conn_id, epoch)

  self._next_singleflight_request_id = self._next_singleflight_request_id + 1
  local internal_request_id = self._next_singleflight_request_id
  flight = {
    conn_id = opts.conn_id,
    epoch = epoch,
    request_id = internal_request_id,
    waiters = { waiter },
    consumer_slots = {
      [opts.consumer] = true,
    },
  }
  self._structure_flights[key] = flight
  self._structure_request_lookup[internal_request_id] = key

  vim.fn.DbeeConnectionGetStructureAsync(opts.conn_id, internal_request_id, epoch, SINGLEFLIGHT_CALLER_TOKEN)

  return {
    epoch = epoch,
    request_id = waiter.request_id,
    joined = false,
  }
end

---@param consumer string
function Handler:teardown_structure_consumer(consumer)
  for _, flight in pairs(self._structure_flights) do
    local kept = {}
    for _, waiter in ipairs(flight.waiters or {}) do
      if waiter.consumer ~= consumer then
        kept[#kept + 1] = waiter
      end
    end
    flight.waiters = kept
    flight.consumer_slots[consumer] = nil
  end
end

---@param old_conn_id connection_id
---@param new_conn_id connection_id
function Handler:migrate_structure_flights(old_conn_id, new_conn_id)
  if not old_conn_id or not new_conn_id or old_conn_id == new_conn_id then
    return
  end

  local old_epoch = self.authoritative_root_epoch[old_conn_id]
  if old_epoch ~= nil then
    local new_epoch = self.authoritative_root_epoch[new_conn_id]
    if new_epoch == nil then
      self.authoritative_root_epoch[new_conn_id] = old_epoch
    else
      self.authoritative_root_epoch[new_conn_id] = math.max(new_epoch, old_epoch)
    end
    self.authoritative_root_epoch[old_conn_id] = nil
  end

  local migrated = {}
  for key, flight in pairs(self._structure_flights) do
    if flight.conn_id == old_conn_id then
      self._structure_flights[key] = nil
      local new_key = singleflight_key(new_conn_id, flight.epoch)
      local existing = self._structure_flights[new_key]
      flight.alias_conn_ids = flight.alias_conn_ids or {}
      flight.alias_conn_ids[old_conn_id] = true
      flight.conn_id = new_conn_id
      self._structure_request_lookup[flight.request_id] = new_key
      if existing then
        existing.alias_conn_ids = existing.alias_conn_ids or {}
        existing.alias_conn_ids[old_conn_id] = true
        for alias_conn_id in pairs(flight.alias_conn_ids or {}) do
          existing.alias_conn_ids[alias_conn_id] = true
        end
        for _, waiter in ipairs(flight.waiters or {}) do
          existing.waiters[#existing.waiters + 1] = waiter
          if waiter.consumer then
            existing.consumer_slots[waiter.consumer] = true
          end
        end
      else
        migrated[new_key] = flight
      end
    end
  end

  for key, flight in pairs(migrated) do
    self._structure_flights[key] = flight
  end
end

---@private
---@param data { conn_id?: connection_id, request_id?: integer, root_epoch?: integer, caller_token?: string, structures?: DBStructure[], error?: any }
function Handler:_on_singleflight_structure_loaded(data)
  if not data or data.caller_token ~= SINGLEFLIGHT_CALLER_TOKEN or not data.request_id then
    return
  end

  local key = self._structure_request_lookup[data.request_id]
  if not key then
    return
  end

  local flight = self._structure_flights[key]
  self._structure_request_lookup[data.request_id] = nil
  if not flight then
    return
  end
  self._structure_flights[key] = nil

  local payload_root_epoch = tonumber(data.root_epoch) or 0
  local conn_id_matches = flight.conn_id == data.conn_id
  if not conn_id_matches and flight.alias_conn_ids then
    conn_id_matches = flight.alias_conn_ids[data.conn_id] == true
  end
  if not conn_id_matches or flight.epoch ~= payload_root_epoch then
    return
  end

  for _, waiter in ipairs(flight.waiters or {}) do
    self:_notify_structure_waiter(waiter, {
      conn_id = flight.conn_id,
      request_id = waiter.request_id,
      root_epoch = payload_root_epoch,
      caller_token = waiter.caller_token,
      structures = copy_payload(data.structures) or {},
      error = data.error,
    })
  end
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
---@param conn_id connection_id?
---@return boolean
function Handler:_connection_still_exists(conn_id)
  if not conn_id or conn_id == "" then
    return false
  end
  local ok, conn = pcall(self.connection_get_params, self, conn_id)
  return ok and conn ~= nil
end

---@private
---@param source_id source_id
---@param previous_connections ConnectionParams[]
---@param current_connections ConnectionParams[]
---@param previous_current ConnectionParams|nil
---@param rewrites { old_conn_id: connection_id, new_conn_id: connection_id }[]
---@return connection_id|nil
---@return string|nil
function Handler:_resolve_sticky_current_connection(source_id, previous_connections, current_connections, previous_current, rewrites)
  local _ = source_id
  if not previous_current or not previous_current.id or previous_current.id == "" then
    return nil, nil
  end

  local previous_current_id = previous_current.id
  local previous_in_reloaded_source = connection_in_list(previous_connections, previous_current_id)
  if previous_in_reloaded_source then
    if connection_in_list(current_connections, previous_current_id) then
      return previous_current_id, nil
    end

    local rewritten = rewrite_target_for(rewrites, previous_current_id)
    if rewritten then
      return rewritten, nil
    end

    return nil, string.format(
      'Sticky current connection for "%s" became ambiguous or vanished after reload',
      tostring(previous_current.name or previous_current_id)
    )
  end

  if self:_connection_still_exists(previous_current_id) then
    return previous_current_id, nil
  end

  return nil, nil
end

function Handler:emit_connection_invalidated_silent(reason, result)
  self:_emit_connection_invalidated(reason, result, { silent = true })
end

---@param id source_id
---@return { source_id: source_id, retired_conn_ids: connection_id[], new_conn_ids: connection_id[], current_conn_id_before: connection_id|nil, current_conn_id_after: connection_id|nil, rewrites: { old_conn_id: connection_id, new_conn_id: connection_id }[], authoritative_root_epoch: integer|nil, reload_error: { error_kind: string, message: string }|nil }
function Handler:source_reload_reconnect(id)
  local result = self:_source_reload_silent(id, { eventful = false })
  if result.reload_error then
    error(result.reload_error.message)
  end
  return result
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
  local previous_current = self:get_current_connection()
  local current_conn_id_before = previous_current and previous_current.id or nil

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
  local rewrites = build_rewrites(previous_connections, current_connections)
  local sticky_target, sticky_warning =
    self:_resolve_sticky_current_connection(source_id, previous_connections, current_connections, previous_current, rewrites)
  if sticky_target and sticky_target ~= self:_current_connection_id() then
    local ok_set, set_err = pcall(self.set_current_connection, self, sticky_target)
    if not ok_set then
      utils.log("warn", "Failed restoring sticky current connection: " .. tostring(set_err), "core")
    end
  elseif sticky_warning then
    utils.log("warn", sticky_warning, "core")
  end

  local result = {
    source_id = source_id,
    retired_conn_ids = connection_ids(previous_connections),
    new_conn_ids = connection_ids(current_connections),
    current_conn_id_before = current_conn_id_before,
    current_conn_id_after = self:_current_connection_id(),
    rewrites = rewrites,
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
---@return { error_kind: string, message: string }|nil
function Handler:connection_test(id)
  local ret = vim.fn.DbeeConnectionTest(id)
  if not ret or ret == vim.NIL then
    return nil
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
---@param request_id integer
---@param root_epoch integer
function Handler:connection_list_databases_async(id, request_id, root_epoch)
  vim.fn.DbeeConnectionListDatabasesAsync(id, request_id, root_epoch)
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
