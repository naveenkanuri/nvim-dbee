-- Headless validation for Phase 7 coordination, reconnect continuity,
-- and async database-switch patching.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=$(pwd)" \
--   -c "luafile ci/headless/check_connection_coordination.lua"

local Harness = dofile(vim.fn.getcwd() .. "/ci/headless/phase7_harness.lua")

local function fail(msg)
  print("DCFG01_COORDINATION_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local function assert_true(label, value)
  if not value then
    fail(label .. ": expected truthy, got " .. vim.inspect(value))
  end
end

local function assert_eq(label, actual, expected)
  if actual ~= expected then
    fail(label .. ": expected " .. vim.inspect(expected) .. " got " .. vim.inspect(actual))
  end
end

local function assert_match(label, actual, pattern)
  if type(actual) ~= "string" or not actual:find(pattern, 1, true) then
    fail(label .. ": expected " .. vim.inspect(actual) .. " to contain " .. vim.inspect(pattern))
  end
end

local notifications = {}
local saved_notify = vim.notify

vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = {
    msg = tostring(msg),
    level = level,
    opts = opts,
  }
end

local function clear_notifications()
  notifications = {}
end

local function has_notification(fragment, level)
  for _, entry in ipairs(notifications) do
    if tostring(entry.msg):find(fragment, 1, true) and (level == nil or entry.level == level) then
      return true
    end
  end
  return false
end

local DEFAULT_MAPPINGS = {
  { key = "<CR>", mode = "n", action = "action_1" },
  { key = "R", mode = "n", action = "refresh" },
  { key = "e", mode = "n", action = "expand" },
  { key = "c", mode = "n", action = "collapse" },
  { key = "/", mode = "n", action = "filter" },
}

local ROOT_STRUCTURES = {
  {
    type = "schema",
    name = "public",
    schema = "public",
    children = {
      { type = "table", name = "users", schema = "public" },
      { type = "view", name = "users_view", schema = "public" },
    },
  },
}

local function new_source(initial_specs)
  local source = {
    _id = "source1",
    _specs = vim.deepcopy(initial_specs),
    _file = vim.fn.getcwd() .. "/source1.json",
  }

  function source:name()
    return self._id
  end

  function source:file()
    return self._file
  end

  function source:load()
    return vim.deepcopy(self._specs)
  end

  function source:create(details)
    local spec = {
      id = details.id or ("conn-created-" .. tostring(#self._specs + 1)),
      name = details.name,
      type = details.type,
      url = details.url,
    }
    self._specs[#self._specs + 1] = spec
    return spec.id
  end

  function source:update(conn_id, details)
    for _, spec in ipairs(self._specs) do
      if spec.id == conn_id then
        spec.name = details.name
        spec.type = details.type
        spec.url = details.url
        return
      end
    end
    error("missing connection: " .. tostring(conn_id))
  end

  function source:delete(conn_id)
    for index, spec in ipairs(self._specs) do
      if spec.id == conn_id then
        table.remove(self._specs, index)
        return
      end
    end
    error("missing connection: " .. tostring(conn_id))
  end

  return source
end

local function install_dbee_functions(runtime)
  local events = require("dbee.handler.__events")

  vim.fn.DbeeDeleteConnection = function(conn_id)
    runtime.connections[conn_id] = nil
  end

  vim.fn.DbeeCreateConnection = function(spec)
    runtime.connections[spec.id] = vim.deepcopy(spec)
    if runtime.current_conn_id == nil then
      runtime.current_conn_id = spec.id
    end
    return spec.id
  end

  vim.fn.DbeeGetConnections = function(conn_ids)
    local out = {}
    for _, conn_id in ipairs(conn_ids or {}) do
      if runtime.connections[conn_id] then
        out[#out + 1] = vim.deepcopy(runtime.connections[conn_id])
      end
    end
    return out
  end

  vim.fn.DbeeGetCurrentConnection = function()
    if runtime.current_conn_id and runtime.connections[runtime.current_conn_id] then
      return vim.deepcopy(runtime.connections[runtime.current_conn_id])
    end
    return vim.NIL
  end

  vim.fn.DbeeSetCurrentConnection = function(conn_id)
    runtime.current_conn_id = conn_id
    events.trigger("current_connection_changed", {
      conn_id = conn_id,
      cleared = false,
    })
  end

  vim.fn.DbeeClearCurrentConnection = function()
    runtime.current_conn_id = nil
    events.trigger("current_connection_changed", {
      conn_id = vim.NIL,
      cleared = true,
    })
  end

  vim.fn.DbeeConnectionGetParams = function(conn_id)
    if runtime.connections[conn_id] then
      return vim.deepcopy(runtime.connections[conn_id])
    end
    return vim.NIL
  end

  vim.fn.DbeeConnectionGetHelpers = function(_, opts)
    return {
      Browse = string.format("select * from %s.%s", opts.schema or "", opts.table or ""),
    }
  end

  vim.fn.DbeeConnectionExecute = function(conn_id, query)
    runtime.executed_queries[#runtime.executed_queries + 1] = {
      conn_id = conn_id,
      query = query,
    }
    return {
      id = "call-" .. tostring(#runtime.executed_queries),
      query = query,
      state = "archived",
    }
  end

  vim.fn.DbeeConnectionGetCalls = function()
    return {}
  end

  vim.fn.DbeeConnectionGetStructureAsync = function(conn_id, request_id, root_epoch, caller_token)
    runtime.structure_requests[#runtime.structure_requests + 1] = {
      conn_id = conn_id,
      request_id = request_id,
      root_epoch = root_epoch,
      caller_token = caller_token,
    }
  end

  vim.fn.DbeeConnectionGetColumnsAsync = function(conn_id, request_id, branch_id, root_epoch, opts)
    runtime.column_requests[#runtime.column_requests + 1] = {
      conn_id = conn_id,
      request_id = request_id,
      branch_id = branch_id,
      root_epoch = root_epoch,
      opts = vim.deepcopy(opts or {}),
    }
  end

  vim.fn.DbeeConnectionListDatabases = function(conn_id)
    local state = runtime.database_state[conn_id] or {
      current = "",
      available = {},
    }
    return { state.current or "", vim.deepcopy(state.available or {}) }
  end

  vim.fn.DbeeConnectionListDatabasesAsync = function(conn_id, request_id, root_epoch)
    runtime.database_requests[#runtime.database_requests + 1] = {
      conn_id = conn_id,
      request_id = request_id,
      root_epoch = root_epoch,
    }
  end

  vim.fn.DbeeConnectionSelectDatabase = function(conn_id, database)
    runtime.database_state[conn_id] = runtime.database_state[conn_id] or {
      current = "",
      available = {},
    }
    runtime.database_state[conn_id].current = database
    events.trigger("database_selected", {
      conn_id = conn_id,
      database_name = database,
    })
  end

  vim.fn.DbeeConnectionTest = function()
    return vim.NIL
  end

  vim.fn.DbeeCallStoreResult = function() end
  vim.fn.DbeeCallCancel = function() end
  vim.fn.DbeeAddHelpers = function() end
end

local function new_env(opts)
  opts = opts or {}

  Harness.reset_modules({
    "dbee.utils",
    "dbee.handler.__events",
    "dbee.handler",
    "dbee.reconnect",
    "dbee.ui.drawer",
    "dbee.ui.drawer.convert",
    "dbee.ui.drawer.model",
    "dbee.api",
    "dbee.api.state",
    "dbee.lsp",
    "dbee.lsp.schema_cache",
    "dbee.lsp.server",
  })

  local runtime = {
    prompt_calls = {},
    editor_calls = {},
    select_calls = {},
    input_calls = {},
    filter_sessions = {},
    connections = {},
    current_conn_id = nil,
    database_state = {
      ["conn-alpha"] = {
        current = "main",
        available = { "main", "analytics" },
      },
    },
    structure_requests = {},
    column_requests = {},
    database_requests = {},
    executed_queries = {},
    next_select_choice = nil,
    lsp = {
      start_calls = 0,
      attach_calls = 0,
      cache_builds = {},
      stops = 0,
    },
  }

  Harness.install_ui_stubs(runtime, {
    stub_reconnect = false,
  })

  local state_stub = {
    is_core_loaded = function()
      return true
    end,
    handler = function()
      return runtime.handler
    end,
  }
  package.loaded["dbee.api.state"] = state_stub

  package.loaded["dbee.api"] = {
    core = {
      is_loaded = function()
        return true
      end,
      get_current_connection = function()
        return runtime.handler:get_current_connection()
      end,
      connection_get_params = function(conn_id)
        return runtime.handler:connection_get_params(conn_id)
      end,
      set_current_connection = function(conn_id)
        return runtime.handler:set_current_connection(conn_id)
      end,
      get_sources = function()
        return runtime.handler:get_sources()
      end,
      source_get_connections = function(source_id)
        return runtime.handler:source_get_connections(source_id)
      end,
      register_event_listener = function(event, listener)
        return runtime.handler:register_event_listener(event, listener)
      end,
    },
    ui = {
      rebind_note_connection = function() end,
    },
    setup = function() end,
    current_config = function()
      return {
        window_layout = {
          is_open = function()
            return true
          end,
        },
      }
    end,
  }

  package.loaded["dbee.lsp.schema_cache"] = {
    new = function(_, conn_id)
      return {
        conn_id = conn_id,
        load_from_disk = function()
          return false
        end,
        build_from_structure = function(_, structures)
          runtime.lsp.cache_builds[#runtime.lsp.cache_builds + 1] = {
            conn_id = conn_id,
            structures = vim.deepcopy(structures or {}),
          }
        end,
        build_from_metadata_rows = function() end,
        save_to_disk = function()
          runtime.lsp.saved = (runtime.lsp.saved or 0) + 1
        end,
        get_schemas = function()
          return {}
        end,
        get_all_table_names = function()
          return {}
        end,
      }
    end,
  }

  package.loaded["dbee.lsp.server"] = {
    create = function()
      return { "cat" }
    end,
  }

  local original_lsp = vim.lsp
  vim.lsp = vim.tbl_extend("force", original_lsp or {}, {
    start = function()
      runtime.lsp.start_calls = runtime.lsp.start_calls + 1
      return 101
    end,
    buf_attach_client = function()
      runtime.lsp.attach_calls = runtime.lsp.attach_calls + 1
    end,
    get_client_by_id = function()
      return {
        stop = function()
          runtime.lsp.stops = runtime.lsp.stops + 1
        end,
      }
    end,
  })

  local source = new_source(opts.initial_specs or {
    {
      id = "conn-alpha",
      name = "Alpha",
      type = "postgres",
      url = "postgres://alpha",
    },
    {
      id = "conn-beta",
      name = "Beta",
      type = "postgres",
      url = "postgres://beta",
    },
  })

  install_dbee_functions(runtime)

  local Handler = require("dbee.handler")
  local convert = require("dbee.ui.drawer.convert")
  local reconnect = require("dbee.reconnect")
  local DrawerUI = require("dbee.ui.drawer")
  local lsp = require("dbee.lsp")
  local events = require("dbee.handler.__events")

  local handler = Handler:new({ source })
  runtime.handler = handler
  Harness.drain()

  runtime.current_conn_id = opts.current_conn_id or source._specs[1].id
  vim.fn.DbeeSetCurrentConnection(runtime.current_conn_id)
  Harness.drain()

  local editor = {
    register_event_listener = function() end,
    get_current_note = function()
      return { id = "note-1" }
    end,
    namespace_get_notes = function()
      return {}
    end,
    set_current_note = function() end,
    namespace_create_note = function()
      return "note-created"
    end,
    note_rename = function() end,
    namespace_remove_note = function() end,
    search_note = function()
      return nil
    end,
  }

  local result = {
    set_call = function(_, call)
      runtime.last_result_call = call
    end,
  }

  local drawer = DrawerUI:new(handler, editor, result, {
    mappings = vim.deepcopy(DEFAULT_MAPPINGS),
  })
  local real_refresh = drawer.refresh
  drawer.refresh_count = 0
  drawer.refresh = function(self, ...)
    self.refresh_count = self.refresh_count + 1
    return real_refresh(self, ...)
  end

  local host_buf, winid = Harness.with_window()
  drawer:show(winid)
  Harness.drain()
  drawer.refresh_count = 0

  local env = {
    runtime = runtime,
    source = source,
    handler = handler,
    drawer = drawer,
    reconnect = reconnect,
    lsp = lsp,
    convert = convert,
    events = events,
    host_buf = host_buf,
    winid = winid,
    original_lsp = original_lsp,
  }

  function env:cleanup()
    if self.lsp and self.lsp.stop then
      pcall(self.lsp.stop)
    end
    if self.drawer and self.drawer.prepare_close then
      pcall(self.drawer.prepare_close, self.drawer)
    end
    if self.drawer and self.drawer.bufnr and vim.api.nvim_buf_is_valid(self.drawer.bufnr) then
      pcall(vim.api.nvim_buf_delete, self.drawer.bufnr, { force = true })
    end
    Harness.close_window_and_buffer(self.host_buf, self.winid)
    vim.lsp = self.original_lsp
  end

  return env
end

local function seed_drawer_root(env, conn_id, epoch)
  env.drawer._struct_cache.root[conn_id] = {
    structures = vim.deepcopy(ROOT_STRUCTURES),
  }
  env.drawer._struct_cache.root_epoch[conn_id] = epoch or env.handler:get_authoritative_root_epoch(conn_id)
  env.drawer:refresh()
  Harness.drain()
end

local function expand_connection(env, conn_id)
  Harness.set_current_node(env.winid, env.drawer.tree, conn_id)
  env.drawer:get_actions().expand()
  Harness.drain()
end

local function expand_schema(env, conn_id)
  local schema_id = env.convert.structure_node_id(conn_id, {
    type = "schema",
    name = "public",
    schema = "public",
  })
  Harness.set_current_node(env.winid, env.drawer.tree, schema_id)
  env.drawer:get_actions().expand()
  Harness.drain()
  return schema_id
end

local function db_switch_id(conn_id)
  return conn_id .. "_database_switch__"
end

local function emit_structure_loaded(env, request, payload)
  env.events.trigger("structure_loaded", vim.tbl_extend("force", {
    conn_id = request.conn_id,
    request_id = request.request_id,
    root_epoch = request.root_epoch,
    caller_token = request.caller_token,
    structures = vim.deepcopy(ROOT_STRUCTURES),
    error = nil,
  }, payload or {}))
  Harness.drain()
end

local function emit_database_loaded(env, request, payload)
  env.events.trigger("connection_databases_loaded", vim.tbl_extend("force", {
    conn_id = request.conn_id,
    request_id = request.request_id,
    root_epoch = request.root_epoch,
    databases = {
      current = "main",
      available = { "main", "analytics" },
    },
    error = nil,
  }, payload or {}))
  Harness.drain()
end

local function latest_request(list, conn_id)
  for index = #list, 1, -1 do
    if list[index].conn_id == conn_id then
      return list[index]
    end
  end
end

local function has_structure_flight(env, conn_id, consumer)
  for _, flight in pairs(env.handler._structure_flights or {}) do
    if flight.conn_id == conn_id and (consumer == nil or (flight.consumer_slots or {})[consumer]) then
      return true
    end
  end
  return false
end

local function should_apply_bootstrap_event(event, snapshot_epoch)
  local affected = {}
  for _, conn_id in ipairs(event.retired_conn_ids or {}) do
    affected[conn_id] = true
  end
  for _, conn_id in ipairs(event.new_conn_ids or {}) do
    affected[conn_id] = true
  end
  if event.current_conn_id_before then
    affected[event.current_conn_id_before] = true
  end
  if event.current_conn_id_after then
    affected[event.current_conn_id_after] = true
  end
  if next(affected) == nil then
    return true
  end
  for conn_id in pairs(affected) do
    if tonumber(event.authoritative_root_epoch) > (snapshot_epoch[conn_id] or 0) then
      return true
    end
  end
  return false
end

local function new_invalidation(epoch, opts)
  opts = opts or {}
  return {
    reason = opts.reason or "source_reload",
    source_id = opts.source_id or "source1",
    retired_conn_ids = vim.deepcopy(opts.retired_conn_ids or { "conn-alpha" }),
    new_conn_ids = vim.deepcopy(opts.new_conn_ids or {}),
    current_conn_id_before = opts.current_conn_id_before,
    current_conn_id_after = opts.current_conn_id_after,
    authoritative_root_epoch = epoch,
    silent = opts.silent,
  }
end

local function run_singleflight_contracts()
  local env = new_env()

  local waiter_payloads = {}
  env.handler:connection_get_structure_singleflight({
    conn_id = "conn-alpha",
    consumer = "drawer",
    request_id = 41,
    caller_token = "drawer",
    callback = function(data)
      waiter_payloads.drawer = data
    end,
  })
  env.handler:connection_get_structure_singleflight({
    conn_id = "conn-alpha",
    consumer = "lsp",
    callback = function(data)
      waiter_payloads.lsp = data
    end,
  })
  assert_eq("singleflight_underlying_requests", #env.runtime.structure_requests, 1)
  local direct_request = env.runtime.structure_requests[1]
  emit_structure_loaded(env, direct_request, {
    caller_token = "__singleflight",
  })
  assert_eq("drawer_waiter_request_id", waiter_payloads.drawer.request_id, 41)
  assert_eq("drawer_waiter_caller_token", waiter_payloads.drawer.caller_token, "drawer")
  assert_eq("lsp_waiter_request_id", waiter_payloads.lsp.request_id, 0)
  assert_eq("lsp_waiter_caller_token", waiter_payloads.lsp.caller_token, nil)
  print("DCFG01_WAITER_FANOUT_OK=true")

  env.runtime.structure_requests = {}
  seed_drawer_root(env, "conn-alpha", 0)
  env.lsp.refresh()
  env.drawer:request_structure_reload("conn-alpha", { force_new = true })
  assert_eq("drawer_lsp_singleflight_requests", #env.runtime.structure_requests, 1)
  local shared_request = env.runtime.structure_requests[1]
  emit_structure_loaded(env, shared_request, {
    caller_token = "__singleflight",
  })
  assert_true("drawer_root_loaded", env.drawer._struct_cache.root["conn-alpha"] ~= nil)
  assert_true("lsp_cache_built", #env.runtime.lsp.cache_builds > 0)
  print("DCFG01_SINGLE_FLIGHT_OK=true")

  env:cleanup()
end

local function run_bootstrap_contracts()
  local env = new_env()

  local replay_listener_events = {}
  local generation = env.handler:begin_connection_invalidated_bootstrap("probe", function(data)
    replay_listener_events[#replay_listener_events + 1] = vim.deepcopy(data)
  end)
  local snapshot_epoch = {
    ["conn-alpha"] = 0,
  }
  env.handler:_dispatch_connection_invalidated(new_invalidation(1))
  local drained = env.handler:drain_connection_invalidated_bootstrap("probe", generation)
  assert_eq("bootstrap_replay_kind", drained.kind, "ok")
  assert_eq("bootstrap_replay_events", #drained.events, 1)
  assert_true("bootstrap_replay_applies", should_apply_bootstrap_event(drained.events[1], snapshot_epoch))
  print("DCFG01_BOOTSTRAP_REPLAY_OK=true")

  local post_listener_events = {}
  generation = env.handler:begin_connection_invalidated_bootstrap("probe-post", function(data)
    post_listener_events[#post_listener_events + 1] = vim.deepcopy(data)
  end)
  local snapshot_epoch_post = {
    ["conn-alpha"] = 0,
  }
  env.handler:_dispatch_connection_invalidated(new_invalidation(2))
  local post_drained = env.handler:drain_connection_invalidated_bootstrap("probe-post", generation)
  assert_eq("post_snapshot_kind", post_drained.kind, "ok")
  assert_eq("post_snapshot_events", #post_drained.events, 1)
  assert_true("post_snapshot_applies", should_apply_bootstrap_event(post_drained.events[1], snapshot_epoch_post))
  print("LIFECYCLE01_BOOTSTRAP_POST_SNAPSHOT_OK=true")

  env.handler:_dispatch_connection_invalidated(new_invalidation(3))
  local promoted = env.handler:promote_to_live("probe-post", generation)
  assert_eq("tail_promote_kind", promoted.kind, "ok")
  assert_eq("tail_promote_events", #promoted.events, 1)
  assert_eq("tail_promote_epoch", promoted.events[1].authoritative_root_epoch, 3)
  print("LIFECYCLE01_BOOTSTRAP_TAIL_OK=true")

  local overflow_listener_events = {}
  generation = env.handler:begin_connection_invalidated_bootstrap("probe-overflow", function(data)
    overflow_listener_events[#overflow_listener_events + 1] = vim.deepcopy(data)
  end)
  for epoch = 1, 65 do
    env.handler:_dispatch_connection_invalidated(new_invalidation(epoch))
  end
  local overflow_restart = env.handler:drain_connection_invalidated_bootstrap("probe-overflow", generation)
  assert_eq("overflow_restart_kind", overflow_restart.kind, "restart")
  assert_true("overflow_restart_warning", overflow_restart.warning and overflow_restart.warning.kind == "overflow")
  local overflow_generation = overflow_restart.generation
  env.handler:_dispatch_connection_invalidated(new_invalidation(66))
  local overflow_drained = env.handler:drain_connection_invalidated_bootstrap("probe-overflow", overflow_generation)
  assert_eq("overflow_drained_kind", overflow_drained.kind, "ok")
  assert_true("overflow_warning_seen", overflow_listener_events[1] and overflow_listener_events[1].kind == "overflow")
  assert_eq("overflow_event_count", #overflow_drained.events, 2)
  assert_eq("overflow_first_epoch", overflow_drained.events[1].authoritative_root_epoch, 65)
  assert_eq("overflow_second_epoch", overflow_drained.events[2].authoritative_root_epoch, 66)
  print("LIFECYCLE01_BOOTSTRAP_OVERFLOW_OK=true")

  local storm_listener_events = {}
  generation = env.handler:begin_connection_invalidated_bootstrap("probe-storm", function(data)
    storm_listener_events[#storm_listener_events + 1] = vim.deepcopy(data)
  end)
  for burst = 1, 4 do
    for offset = 1, 65 do
      env.handler:_dispatch_connection_invalidated(new_invalidation((burst * 100) + offset))
    end
    local res = env.handler:drain_connection_invalidated_bootstrap("probe-storm", generation)
    if burst < 4 then
      assert_eq("storm_restart_kind_" .. burst, res.kind, "restart")
      assert_true("storm_restart_warning_" .. burst, res.warning and res.warning.kind == "overflow")
      generation = res.generation
    else
      assert_eq("storm_kind", res.kind, "storm")
      assert_true("storm_warning_payload", res.warning and res.warning.kind == "storm")
      assert_match("storm_warning_message", res.message, "bootstrap_overflow_storm")
    end
  end
  assert_true(
    "storm_warning_seen",
    storm_listener_events[#storm_listener_events] and storm_listener_events[#storm_listener_events].kind == "storm"
  )
  print("LIFECYCLE01_BOOTSTRAP_OVERFLOW_STORM_OK=true")

  env:cleanup()
end

local function run_supersession_and_cleanup_contracts()
  local env = new_env()

  seed_drawer_root(env, "conn-alpha", 0)
  env.runtime.structure_requests = {}
  env.runtime.lsp.cache_builds = {}
  env.lsp.refresh()
  env.drawer:request_structure_reload("conn-alpha", { force_new = true })
  local first_payload = nil
  env.handler:connection_get_structure_singleflight({
    conn_id = "conn-alpha",
    consumer = "probe",
    request_id = 11,
    caller_token = "probe",
    callback = function(data)
      first_payload = data
    end,
  })
  assert_eq("supersession_underlying_requests", #env.runtime.structure_requests, 1)
  local stale_request = env.runtime.structure_requests[1]
  local applied_before = env.drawer._struct_cache.root_applied["conn-alpha"] or 0
  local new_epoch = env.handler:bump_authoritative_root_epoch({ "conn-alpha" })
  assert_true("superseded_payload_present", first_payload ~= nil)
  assert_eq("superseded_error_kind", first_payload.error_kind, "superseded")
  assert_eq("superseded_new_epoch", first_payload.new_epoch, new_epoch)
  emit_structure_loaded(env, stale_request, {
    caller_token = "__singleflight",
  })
  assert_eq("superseded_root_applied_unchanged", env.drawer._struct_cache.root_applied["conn-alpha"] or 0, applied_before)
  assert_eq("superseded_lsp_cache_unchanged", #env.runtime.lsp.cache_builds, 0)
  print("DCFG01_SUPERSEDED_FLIGHT_OK=true")
  print("LIFECYCLE01_INVALIDATION_SUPERSESSION_OK=true")

  env.runtime.structure_requests = {}
  env.drawer:request_structure_reload("conn-alpha", { force_new = true })
  local flight_key = next(env.handler._structure_flights)
  assert_true("cleanup_flight_present", flight_key ~= nil)
  env.drawer:prepare_close()
  local remaining = 0
  for _, waiter in ipairs((env.handler._structure_flights[flight_key] or {}).waiters or {}) do
    if waiter.consumer == "drawer" then
      remaining = remaining + 1
    end
  end
  assert_eq("cleanup_waiters", remaining, 0)
  print("DCFG01_WAITER_CLEANUP_OK=true")

  env:cleanup()
end

local function run_consumer_rebootstrap_contracts()
  local env = new_env()
  local reopen_winid = env.winid

  env.drawer:prepare_close()
  env.handler:source_remove_connection("source1", "conn-beta")
  Harness.drain()
  env.drawer:show(reopen_winid)
  Harness.drain()
  assert_true("drawer_reopen_consumer_live", env.drawer._connection_invalidated_consumer_live)
  assert_true("drawer_reopen_snapshot_applied", env.drawer.tree:get_node("conn-beta") == nil)
  print("DCFG01_DRAWER_REBOOTSTRAP_OK=true")

  local stale_env = new_env()
  local stale_reopen_winid = stale_env.winid
  seed_drawer_root(stale_env, "conn-beta", stale_env.handler:get_authoritative_root_epoch("conn-beta"))
  expand_connection(stale_env, "conn-beta")
  assert_true("reopen_stale_cache_seeded", stale_env.drawer._struct_cache.root["conn-beta"] ~= nil)
  stale_env.drawer:prepare_close()
  local original_reopen_snapshot = stale_env.handler.get_connection_state_snapshot
  local replayed_invalidation = false
  stale_env.handler.get_connection_state_snapshot = function(self, ...)
    local snapshot = original_reopen_snapshot(self, ...)
    if not replayed_invalidation then
      replayed_invalidation = true
      self:source_remove_connection("source1", "conn-beta")
    end
    return snapshot
  end
  stale_env.drawer:show(stale_reopen_winid)
  Harness.drain()
  stale_env.handler.get_connection_state_snapshot = original_reopen_snapshot
  assert_eq("reopen_stale_cache_root_cleared", stale_env.drawer._struct_cache.root["conn-beta"], nil)
  assert_eq("reopen_stale_cache_branches_cleared", stale_env.drawer._struct_cache.branches["conn-beta"], nil)
  assert_true("reopen_stale_cache_tree_pruned", stale_env.drawer.tree:get_node("conn-beta") == nil)
  print("DCFG01_REOPEN_STALE_CACHE_PURGE_OK=true")

  stale_env:cleanup()

  local original_snapshot = env.handler.get_connection_state_snapshot
  local drawer_overflow_bursts = 4
  env.drawer:prepare_close()
  env.handler.get_connection_state_snapshot = function(self, ...)
    if drawer_overflow_bursts > 0 then
      for offset = 1, 65 do
        self:_dispatch_connection_invalidated(new_invalidation((drawer_overflow_bursts * 1000) + offset))
      end
      drawer_overflow_bursts = drawer_overflow_bursts - 1
    end
    return original_snapshot(self, ...)
  end
  env.drawer:show(reopen_winid)
  Harness.drain()
  env.handler.get_connection_state_snapshot = original_snapshot
  assert_true("drawer_storm_rebootstrap_live", env.drawer._connection_invalidated_consumer_live)
  env.drawer.refresh_count = 0
  env.events.trigger("connection_invalidated", new_invalidation(env.handler:get_authoritative_root_epoch("conn-alpha") + 1, {
    retired_conn_ids = { "conn-alpha" },
  }))
  Harness.drain()
  assert_true("drawer_storm_rebootstrap_refresh", env.drawer.refresh_count > 0)
  print("DCFG01_DRAWER_STORM_REBOOTSTRAP_OK=true")

  env.runtime.structure_requests = {}
  seed_drawer_root(env, "conn-alpha", env.handler:get_authoritative_root_epoch("conn-alpha"))
  expand_connection(env, "conn-alpha")
  env.events.trigger("connection_invalidated", new_invalidation(env.handler:get_authoritative_root_epoch("conn-alpha") + 1, {
    retired_conn_ids = { "conn-alpha" },
  }))
  env.drawer:prepare_close()
  Harness.drain()
  assert_eq("drawer_close_clears_batched_rewarm", #env.runtime.structure_requests, 0)
  print("DCFG01_CLOSE_BATCH_CLEAR_OK=true")

  env:cleanup()

  local env_lsp = new_env()
  local original_snapshot = env_lsp.handler.get_connection_state_snapshot
  local overflow_bursts = 4
  env_lsp.lsp.register_events()
  Harness.drain()
  env_lsp.drawer:prepare_close()
  env_lsp.lsp.stop()
  env_lsp.handler.get_connection_state_snapshot = function(self, ...)
    if overflow_bursts > 0 then
      for offset = 1, 65 do
        self:_dispatch_connection_invalidated(new_invalidation((overflow_bursts * 100) + offset))
      end
      overflow_bursts = overflow_bursts - 1
    end
    return original_snapshot(self, ...)
  end

  env_lsp.runtime.structure_requests = {}
  env_lsp.lsp._try_start()
  Harness.drain()
  env_lsp.handler.get_connection_state_snapshot = original_snapshot
  assert_true("lsp_rebootstrap_live", env_lsp.lsp._connection_invalidated_consumer_live)

  env_lsp.runtime.structure_requests = {}
  env_lsp.handler:source_reload("source1")
  Harness.drain()
  assert_true("lsp_rebootstrap_rewarm", #env_lsp.runtime.structure_requests > 0)
  print("DCFG01_LSP_REBOOTSTRAP_OK=true")

  env_lsp:cleanup()
end

local function run_backpressure_and_sticky_contracts()
  local env = new_env()
  seed_drawer_root(env, "conn-alpha", 0)
  expand_connection(env, "conn-alpha")
  env.lsp._bootstrap_connection_invalidated(env.handler)
  env.runtime.structure_requests = {}
  env.drawer.refresh_count = 0
  env.handler.authoritative_root_epoch["conn-alpha"] = 1
  env.handler.authoritative_root_epoch["conn-beta"] = 1

  env.events.trigger("connection_invalidated", new_invalidation(1, {
    retired_conn_ids = { "conn-alpha", "conn-beta" },
  }))
  env.events.trigger("connection_invalidated", new_invalidation(1, {
    retired_conn_ids = { "conn-alpha", "conn-beta" },
  }))
  Harness.drain()

  assert_eq("batched_refresh_count", env.drawer.refresh_count, 1)
  assert_eq("batched_rewarm_requests", #env.runtime.structure_requests, 1)
  assert_eq("batched_rewarm_conn", env.runtime.structure_requests[1].conn_id, "conn-alpha")
  print("DCFG01_BACKPRESSURE_OK=true")

  env:cleanup()

  local sticky_env = new_env()
  sticky_env.lsp.register_events()
  sticky_env.runtime.structure_requests = {}
  sticky_env.lsp._request_structure_refresh(sticky_env.handler, "conn-alpha")
  local lsp_request = latest_request(sticky_env.runtime.structure_requests, "conn-alpha")
  assert_true("sticky_lsp_request_present", lsp_request ~= nil)
  emit_structure_loaded(sticky_env, lsp_request, {
    caller_token = "__singleflight",
  })
  Harness.drain()
  assert_true("sticky_lsp_started", sticky_env.lsp.status().running == true)

  clear_notifications()
  sticky_env.source._specs = {
    {
      id = "conn-other-1",
      name = "Alpha Rewrite A",
      type = "postgres",
      url = "postgres://shared",
    },
    {
      id = "conn-other-2",
      name = "Alpha Rewrite B",
      type = "postgres",
      url = "postgres://shared",
    },
  }
  sticky_env.handler:source_reload("source1")
  Harness.drain()
  assert_eq("sticky_selection_nil", sticky_env.handler:get_current_connection(), nil)
  assert_eq("sticky_runtime_current_cleared", sticky_env.runtime.current_conn_id, nil)
  assert_eq("sticky_lsp_stopped_on_clear", sticky_env.runtime.lsp.stops, 1)
  assert_eq("sticky_lsp_running_after_clear", sticky_env.lsp.status().running, false)
  assert_true("sticky_warning_logged", has_notification("ambiguous or vanished", vim.log.levels.WARN))
  print("DCFG01_STICKY_SELECTION_OK=true")

  sticky_env:cleanup()
end

local function run_database_switch_and_reconnect_contracts()
  local function new_db_env(real_reconnect)
    local env = new_env()
    env.handler.authoritative_root_epoch["conn-alpha"] = 2
    seed_drawer_root(env, "conn-alpha", 2)
    expand_connection(env, "conn-alpha")
    return env
  end

  local env_async = new_db_env()
  local initial_request = latest_request(env_async.runtime.database_requests, "conn-alpha")
  assert_true("database_request_present", initial_request ~= nil)
  assert_true("database_placeholder_visible", env_async.drawer.tree:get_node(db_switch_id("conn-alpha")) ~= nil)
  emit_database_loaded(env_async, initial_request, {
    databases = {
      current = "main",
      available = { "main", "analytics" },
    },
  })
  local db_node = env_async.drawer.tree:get_node(db_switch_id("conn-alpha"))
  assert_true("database_node_after_patch", db_node ~= nil)
  assert_eq("database_node_name", db_node.name, "main")
  print("DCFG01_DATABASE_SWITCH_ASYNC_OK=true")
  env_async:cleanup()

  local function assert_stale_drop(case_name, invalidator)
    local env = new_db_env()
    local stale_request = latest_request(env.runtime.database_requests, "conn-alpha")
    invalidator(env)
    Harness.drain()
    emit_database_loaded(env, stale_request, {
      databases = {
        current = "main",
        available = { "main", "analytics" },
      },
    })
    local state = env.drawer._database_switch_state["conn-alpha"]
    assert_true(case_name .. "_state_cleared", state == nil or state.token == nil or state.token.request_id ~= stale_request.request_id)
    local db_node = env.drawer.tree:get_node(db_switch_id("conn-alpha"))
    if db_node then
      assert_true(case_name .. "_no_dead_row", db_node.name ~= "loading databases..." and db_node.name ~= "main (loading databases...)")
    end
    env:cleanup()
  end

  assert_stale_drop("manual_refresh", function(env)
    Harness.set_current_node(env.winid, env.drawer.tree, "conn-alpha")
    env.drawer:get_actions().refresh()
  end)

  assert_stale_drop("database_selected", function(env)
    env.handler:connection_select_database("conn-alpha", "analytics")
  end)

  assert_stale_drop("source_update", function(env)
    env.handler:source_update_connection("source1", "conn-alpha", {
      name = "Alpha",
      type = "postgres",
      url = "postgres://alpha",
    })
  end)

  assert_stale_drop("source_reload", function(env)
    env.handler:source_reload("source1")
  end)

  local env_reconnect = new_db_env()
  local old_db_request = latest_request(env_reconnect.runtime.database_requests, "conn-alpha")
  env_reconnect.handler.authoritative_root_epoch["conn-alpha"] = 2
  env_reconnect.source._specs[1] = {
    id = "conn-alpha-new",
    name = "Alpha",
    type = "postgres",
    url = "postgres://alpha",
  }
  local waiter_payload = nil
  env_reconnect.handler:connection_get_structure_singleflight({
    conn_id = "conn-alpha",
    consumer = "drawer",
    request_id = 91,
    caller_token = "drawer",
    callback = function(data)
      waiter_payload = data
    end,
  })
  local structure_request = latest_request(env_reconnect.runtime.structure_requests, "conn-alpha")
  local reload_result = env_reconnect.handler:source_reload_reconnect("source1")
  assert_eq("reconnect_reload_after", reload_result.current_conn_id_after, "conn-alpha-new")
  env_reconnect.handler:set_current_connection("conn-alpha-new")
  Harness.drain()
  env_reconnect.handler:migrate_structure_flights("conn-alpha", "conn-alpha-new")
  env_reconnect.reconnect.rewrite_connection_identity("conn-alpha", "conn-alpha-new", "Alpha", "postgres")
  Harness.drain()
  assert_true("reconnect_root_migrated", env_reconnect.drawer._struct_cache.root["conn-alpha-new"] ~= nil)
  assert_eq("reconnect_root_epoch_same", env_reconnect.drawer._struct_cache.root_epoch["conn-alpha-new"], 2)
  assert_eq("reconnect_handler_epoch_same", env_reconnect.handler:get_authoritative_root_epoch("conn-alpha-new"), 2)
  emit_structure_loaded(env_reconnect, structure_request, {
    conn_id = "conn-alpha",
    caller_token = "__singleflight",
  })
  assert_true("reconnect_structure_payload", waiter_payload ~= nil)
  assert_eq("reconnect_structure_conn_rewritten", waiter_payload.conn_id, "conn-alpha-new")

  local new_db_request = latest_request(env_reconnect.runtime.database_requests, "conn-alpha-new")
  assert_true("reconnect_database_request_migrated", new_db_request ~= nil)
  assert_eq("reconnect_database_epoch_same", new_db_request.root_epoch, 2)
  emit_database_loaded(env_reconnect, old_db_request, {
    conn_id = "conn-alpha",
  })
  local migrated_state = env_reconnect.drawer._database_switch_state["conn-alpha-new"]
  assert_true("reconnect_stale_old_dropped", migrated_state ~= nil and migrated_state.loading == true)
  emit_database_loaded(env_reconnect, new_db_request, {
    conn_id = "conn-alpha-new",
    databases = {
      current = "main",
      available = { "main", "analytics" },
    },
  })
  local new_db_node = env_reconnect.drawer.tree:get_node(db_switch_id("conn-alpha-new"))
  assert_true("reconnect_db_node_present", new_db_node ~= nil)
  assert_eq("reconnect_db_node_name", new_db_node.name, "main")
  print("DCFG01_RECONNECT_CONTINUITY_OK=true")
  print("DCFG01_DATABASE_SWITCH_STALE_DROP_OK=true")

  env_reconnect:cleanup()

  local env_reconnect_lsp = new_env()
  env_reconnect_lsp.lsp.register_events()
  env_reconnect_lsp.runtime.structure_requests = {}
  env_reconnect_lsp.lsp._try_start()
  local bootstrap_request = latest_request(env_reconnect_lsp.runtime.structure_requests, "conn-alpha")
  assert_true("reconnect_lsp_bootstrap_request", bootstrap_request ~= nil)
  emit_structure_loaded(env_reconnect_lsp, bootstrap_request, {
    caller_token = "__singleflight",
  })
  assert_true("reconnect_lsp_started", env_reconnect_lsp.lsp.status().running == true)

  env_reconnect_lsp.runtime.structure_requests = {}
  env_reconnect_lsp.lsp.refresh()
  local in_flight_request = latest_request(env_reconnect_lsp.runtime.structure_requests, "conn-alpha")
  assert_true("reconnect_lsp_inflight_request", in_flight_request ~= nil)
  assert_true("reconnect_lsp_old_flight_present", has_structure_flight(env_reconnect_lsp, "conn-alpha", "lsp"))

  env_reconnect_lsp.source._specs[1] = {
    id = "conn-alpha-new",
    name = "Alpha",
    type = "postgres",
    url = "postgres://alpha",
  }

  local ok_reconnect, new_conn_id_or_err = env_reconnect_lsp.reconnect.reconnect_connection("conn-alpha")
  assert_true("reconnect_lsp_reload_ok", ok_reconnect)
  assert_eq("reconnect_lsp_new_conn_id", new_conn_id_or_err, "conn-alpha-new")
  env_reconnect_lsp.reconnect.rewrite_connection_identity("conn-alpha", "conn-alpha-new", "Alpha", "postgres")
  Harness.drain()

  assert_eq("reconnect_lsp_single_underlying_request", #env_reconnect_lsp.runtime.structure_requests, 1)
  assert_true("reconnect_lsp_new_flight_present", has_structure_flight(env_reconnect_lsp, "conn-alpha-new", "lsp"))

  emit_structure_loaded(env_reconnect_lsp, in_flight_request, {
    conn_id = "conn-alpha",
    caller_token = "__singleflight",
  })
  assert_eq("reconnect_lsp_status_conn", env_reconnect_lsp.lsp.status().conn_id, "conn-alpha-new")
  print("LIFECYCLE01_RECONNECT_LSP_NO_DOUBLE_HIT_OK=true")

  env_reconnect_lsp:cleanup()

  local env_reconnect_lone = new_env()
  env_reconnect_lone.lsp.register_events()
  env_reconnect_lone.runtime.structure_requests = {}
  env_reconnect_lone.lsp._request_structure_refresh(env_reconnect_lone.handler, "conn-alpha")
  local lone_request = latest_request(env_reconnect_lone.runtime.structure_requests, "conn-alpha")
  assert_true("reconnect_lone_lsp_request", lone_request ~= nil)
  emit_structure_loaded(env_reconnect_lone, lone_request, {
    caller_token = "__singleflight",
  })
  assert_true("reconnect_lone_lsp_started", env_reconnect_lone.lsp.status().running == true)

  clear_notifications()
  env_reconnect_lone.source._specs = {
    {
      id = "conn-solo",
      name = "Solo",
      type = "postgres",
      url = "postgres://solo",
    },
  }
  local ok_lone, lone_err = env_reconnect_lone.reconnect.reconnect_connection("conn-alpha")
  Harness.drain()
  assert_true("reconnect_lone_failed", not ok_lone)
  assert_match("reconnect_lone_error", tostring(lone_err), "unable to map reloaded connection")
  assert_eq("reconnect_lone_current_cleared", env_reconnect_lone.handler:get_current_connection(), nil)
  assert_eq("reconnect_lone_runtime_current_cleared", env_reconnect_lone.runtime.current_conn_id, nil)
  assert_eq("reconnect_lone_lsp_stopped", env_reconnect_lone.runtime.lsp.stops, 1)
  assert_true("reconnect_lone_survivor_not_selected", env_reconnect_lone.runtime.current_conn_id ~= "conn-solo")
  print("LIFECYCLE01_RECONNECT_NO_LONE_SURVIVOR_OK=true")

  env_reconnect_lone:cleanup()

  local env_reconnect_restore = new_env({
    current_conn_id = "conn-beta",
  })
  env_reconnect_restore.lsp.register_events()
  env_reconnect_restore.runtime.structure_requests = {}
  env_reconnect_restore.lsp._request_structure_refresh(env_reconnect_restore.handler, "conn-beta")
  local restore_request = latest_request(env_reconnect_restore.runtime.structure_requests, "conn-beta")
  assert_true("reconnect_restore_lsp_request", restore_request ~= nil)
  emit_structure_loaded(env_reconnect_restore, restore_request, {
    caller_token = "__singleflight",
  })
  assert_true("reconnect_restore_lsp_started", env_reconnect_restore.lsp.status().running == true)

  clear_notifications()
  env_reconnect_restore.source._specs = {
    {
      id = "conn-alpha-new",
      name = "Alpha",
      type = "postgres",
      url = "postgres://alpha",
    },
    {
      id = "conn-beta-a",
      name = "Beta Rewrite A",
      type = "postgres",
      url = "postgres://shared",
    },
    {
      id = "conn-beta-b",
      name = "Beta Rewrite B",
      type = "postgres",
      url = "postgres://shared",
    },
  }
  local ok_restore, restored_conn_id = env_reconnect_restore.reconnect.reconnect_connection("conn-alpha")
  Harness.drain()
  assert_true("reconnect_restore_ok", ok_restore)
  assert_eq("reconnect_restore_target_conn", restored_conn_id, "conn-alpha-new")
  assert_eq("reconnect_restore_current_cleared", env_reconnect_restore.handler:get_current_connection(), nil)
  assert_eq("reconnect_restore_runtime_current_cleared", env_reconnect_restore.runtime.current_conn_id, nil)
  assert_true("reconnect_restore_target_not_current", env_reconnect_restore.runtime.current_conn_id ~= "conn-alpha-new")
  assert_eq("reconnect_restore_lsp_stopped", env_reconnect_restore.runtime.lsp.stops, 1)
  assert_true("reconnect_restore_warning_logged", has_notification("ambiguous or vanished", vim.log.levels.WARN))
  print("LIFECYCLE01_RECONNECT_FAILURE_CLEARS_OK=true")

  env_reconnect_restore:cleanup()
end

local function run_lsp_retarget_rewarm_contracts()
  local env = new_env()
  env.lsp.register_events()

  env.runtime.structure_requests = {}
  env.runtime.executed_queries = {}
  env.lsp._try_start()
  Harness.drain()
  assert_true("lsp_retarget_initial_flight", has_structure_flight(env, "conn-alpha", "lsp"))
  assert_true("lsp_retarget_initial_metadata", env.lsp._metadata_scheduled["conn-alpha"] == true)

  env.handler:set_current_connection("conn-beta")
  Harness.drain()
  assert_eq("lsp_retarget_alpha_async_cleared", env.lsp._async_requested["conn-alpha"], nil)
  assert_eq("lsp_retarget_alpha_metadata_cleared", env.lsp._metadata_scheduled["conn-alpha"], nil)

  Harness.drain(5200)
  env.runtime.executed_queries = {}
  env.runtime.structure_requests = {}

  env.handler:set_current_connection("conn-alpha")
  Harness.drain()
  assert_true("lsp_retarget_return_flight", has_structure_flight(env, "conn-alpha", "lsp"))
  assert_true("lsp_retarget_return_metadata", env.lsp._metadata_scheduled["conn-alpha"] == true)

  Harness.drain(5200)
  local saw_alpha_metadata = false
  for _, call in ipairs(env.runtime.executed_queries or {}) do
    if call.conn_id == "conn-alpha" and tostring(call.query or ""):find("dbee-lsp metadata", 1, true) then
      saw_alpha_metadata = true
      break
    end
  end
  assert_true("lsp_retarget_metadata_query", saw_alpha_metadata)
  print("LIFECYCLE01_LSP_RETARGET_REWARM_OK=true")

  env:cleanup()
end

local function run_structure_regression_guard()
  local env = new_env()
  seed_drawer_root(env, "conn-alpha", 0)
  expand_connection(env, "conn-alpha")
  local schema_id = expand_schema(env, "conn-alpha")
  local users_id = env.convert.structure_node_id(schema_id, {
    type = "table",
    name = "users",
    schema = "public",
  })
  Harness.set_current_node(env.winid, env.drawer.tree, users_id)
  env.drawer:get_actions().expand()
  local child_request = env.runtime.column_requests[#env.runtime.column_requests]
  assert_true("phase6_child_request_present", child_request ~= nil)
  env.events.trigger("structure_children_loaded", {
    conn_id = child_request.conn_id,
    request_id = child_request.request_id,
    branch_id = child_request.branch_id,
    root_epoch = child_request.root_epoch,
    kind = child_request.opts.kind or "columns",
    columns = {
      { name = "id", type = "NUMBER" },
      { name = "email", type = "TEXT" },
    },
  })
  Harness.drain()
  local column_node = env.convert.column_node_id(users_id, {
    name = "id",
    type = "NUMBER",
  })
  assert_true("phase6_column_visible", env.drawer.tree:get_node(column_node) ~= nil)
  print("DCFG01_PHASE6_STRUCTURE_REGRESSION_OK=true")

  env:cleanup()
end

run_singleflight_contracts()
run_bootstrap_contracts()
run_supersession_and_cleanup_contracts()
run_consumer_rebootstrap_contracts()
run_backpressure_and_sticky_contracts()
run_database_switch_and_reconnect_contracts()
run_lsp_retarget_rewarm_contracts()
run_structure_regression_guard()

print("DCFG01_COORDINATION_ALL_PASS=true")

vim.notify = saved_notify
vim.cmd("qa!")
