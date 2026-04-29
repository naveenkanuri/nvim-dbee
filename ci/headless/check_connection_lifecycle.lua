-- Headless validation for Phase 7 lifecycle foundation and connection-only drawer UX.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=$(pwd)" \
--   -c "luafile ci/headless/check_connection_lifecycle.lua"

local Harness = dofile(vim.fn.getcwd() .. "/ci/headless/phase7_harness.lua")

local function fail(msg)
  print("DCFG01_FAIL=" .. msg)
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

local function last_notification()
  return notifications[#notifications] or {}
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
  { key = "a", mode = "n", action = "add_connection" },
  { key = "e", mode = "n", action = "edit_connection" },
  { key = "dd", mode = "n", action = "delete_connection" },
  { key = "t", mode = "n", action = "test_connection" },
  { key = "<C-CR>", mode = "n", action = "activate_connection" },
  { key = "R", mode = "n", action = "refresh" },
  { key = "/", mode = "n", action = "filter" },
  { key = "yy", mode = "n", action = "yank_name" },
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
    _file = vim.fn.getcwd() .. "/source1.json",
    _specs = vim.deepcopy(initial_specs),
    fail_next_load = nil,
    fail_next_create = nil,
    fail_next_update = nil,
    fail_next_delete = nil,
  }

  function source:name()
    return self._id
  end

  function source:file()
    return self._file
  end

  function source:load()
    if self.fail_next_load ~= nil then
      local err = self.fail_next_load
      self.fail_next_load = nil
      error(err)
    end
    return vim.deepcopy(self._specs)
  end

  function source:create(details)
    if self.fail_next_create ~= nil then
      local err = self.fail_next_create
      self.fail_next_create = nil
      error(err)
    end

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
    if self.fail_next_update ~= nil then
      local err = self.fail_next_update
      self.fail_next_update = nil
      error(err)
    end

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
    if self.fail_next_delete ~= nil then
      local err = self.fail_next_delete
      self.fail_next_delete = nil
      error(err)
    end

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

  vim.fn.DbeeConnectionTest = function(conn_id)
    return runtime.connection_test_failures[conn_id] or vim.NIL
  end

  vim.fn.DbeeConnectionTestSpec = function()
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
    "dbee.ui.drawer",
    "dbee.ui.drawer.convert",
    "dbee.ui.drawer.model",
    "dbee.ui.connection_wizard",
    "dbee.reconnect",
  })

  local runtime = {
    prompt_calls = {},
    editor_calls = {},
    select_calls = {},
    input_calls = {},
    filter_sessions = {},
    connections = {},
    current_conn_id = nil,
    connection_test_failures = {},
    database_state = {},
    structure_requests = {},
    column_requests = {},
    database_requests = {},
    executed_queries = {},
    next_prompt_response = nil,
    next_select_choice = nil,
    next_input_value = nil,
    next_wizard_submission = nil,
    last_wizard_submit_err = nil,
  }

  Harness.install_ui_stubs(runtime, {
    stub_reconnect = true,
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
  local DrawerUI = require("dbee.ui.drawer")
  local connection_wizard = require("dbee.ui.connection_wizard")

  local original_wizard_open = connection_wizard.open
  connection_wizard.open = function(open_opts)
    local wizard = original_wizard_open(open_opts)
    if runtime.next_wizard_submission ~= nil and open_opts and type(open_opts.on_submit) == "function" then
      local submission = vim.deepcopy(runtime.next_wizard_submission)
      runtime.next_wizard_submission = nil
      runtime.last_wizard_submit_err = open_opts.on_submit(submission)
      if wizard and wizard.close then
        pcall(wizard.close, wizard)
      end
    end
    return wizard
  end

  local handler = Handler:new({ source })
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

  if opts.seed_root then
    drawer._struct_cache.root = vim.deepcopy(opts.seed_root)
    drawer._struct_cache.root_epoch = vim.deepcopy(opts.seed_root_epoch or {})
  end

  runtime.database_state["conn-alpha"] = {
    current = "main",
    available = { "main", "analytics" },
  }

  local host_buf, winid = Harness.with_window()
  drawer:show(winid)
  Harness.drain()
  drawer.refresh_count = 0

  local env = {
    runtime = runtime,
    source = source,
    handler = handler,
    drawer = drawer,
    convert = convert,
    host_buf = host_buf,
    winid = winid,
  }

  function env:cleanup()
    if self.drawer and self.drawer.prepare_close then
      pcall(self.drawer.prepare_close, self.drawer)
    end
    if self.drawer and self.drawer.bufnr and vim.api.nvim_buf_is_valid(self.drawer.bufnr) then
      pcall(vim.api.nvim_buf_delete, self.drawer.bufnr, { force = true })
    end
    Harness.close_window_and_buffer(self.host_buf, self.winid)
  end

  return env
end

local function node_names(tree)
  return table.concat(Harness.visible_node_names(tree), "\n")
end

local function current_connection_id(env)
  local current = env.handler:get_current_connection()
  return current and current.id or nil
end

local function seed_drawer_root(env, conn_id)
  conn_id = conn_id or "conn-alpha"
  env.drawer._struct_cache.root[conn_id] = {
    structures = vim.deepcopy(ROOT_STRUCTURES),
  }
  env.drawer._struct_cache.root_epoch[conn_id] = env.handler:get_authoritative_root_epoch(conn_id)
  env.drawer:refresh()
  Harness.drain()
end

local function table_node_id(env, conn_id)
  local schema_id = env.convert.structure_node_id(conn_id, {
    type = "schema",
    name = "public",
    schema = "public",
  })
  return env.convert.structure_node_id(schema_id, {
    type = "table",
    name = "users",
    schema = "public",
  })
end

local function run_lifecycle_contracts()
  local env = new_env()
  local invalidations = {}
  local failures = {}

  env.handler:register_event_listener("connection_invalidated", function(data)
    invalidations[#invalidations + 1] = vim.deepcopy(data)
  end)
  env.handler:register_event_listener("source_reload_failed", function(data)
    failures[#failures + 1] = vim.deepcopy(data)
  end)

  local snapshot = env.handler:get_connection_state_snapshot()
  assert_eq("snapshot_sources_count", #snapshot.sources, 1)
  assert_eq("snapshot_connection_count", #snapshot.sources[1].connections, 2)
  assert_eq("snapshot_current_conn", snapshot.current_connection.id, "conn-alpha")
  assert_eq("snapshot_epoch_alpha", snapshot.snapshot_authoritative_epoch["conn-alpha"], 0)
  assert_eq("snapshot_epoch_beta", snapshot.snapshot_authoritative_epoch["conn-beta"], 0)
  print("DCFG01_BOOTSTRAP_SNAPSHOT_OK=true")

  clear_notifications()
  invalidations = {}
  failures = {}
  env.handler:source_reload("source1")
  Harness.drain()
  assert_eq("eventful_reload_invalidations", #invalidations, 1)
  assert_eq("eventful_reload_failures", #failures, 0)
  assert_eq("eventful_reload_reason", invalidations[1].reason, "source_reload")
  assert_eq("eventful_reload_source", invalidations[1].source_id, "source1")
  assert_eq("eventful_reload_silent", invalidations[1].silent, false)
  assert_true("eventful_reload_retired_array", type(invalidations[1].retired_conn_ids) == "table")
  assert_true("eventful_reload_new_array", type(invalidations[1].new_conn_ids) == "table")
  assert_eq("eventful_reload_current_before", invalidations[1].current_conn_id_before, "conn-alpha")
  assert_eq("eventful_reload_current_after", invalidations[1].current_conn_id_after, "conn-alpha")
  assert_eq("eventful_reload_epoch", invalidations[1].authoritative_root_epoch, 1)
  print("DCFG01_INVALIDATION_PAYLOAD_OK=true")

  invalidations = {}
  failures = {}
  env.handler:source_reload_reconnect("source1")
  Harness.drain()
  assert_eq("silent_reload_invalidations", #invalidations, 0)
  assert_eq("silent_reload_failures", #failures, 0)
  print("DCFG01_SILENT_RELOAD_OK=true")

  invalidations = {}
  failures = {}
  env.source.fail_next_create = "create boom"
  local ok_mutation, mutation_err = pcall(env.handler.source_add_connection, env.handler, "source1", {
    name = "Gamma",
    type = "postgres",
    url = "postgres://gamma",
  })
  Harness.drain()
  assert_true("mutation_failure_error", not ok_mutation)
  assert_match("mutation_failure_message", tostring(mutation_err), "create boom")
  assert_eq("mutation_failure_invalidations", #invalidations, 0)
  assert_eq("mutation_failure_failure_events", #failures, 1)
  assert_eq("mutation_failure_stage", failures[1].stage, "mutation")
  assert_eq("mutation_failure_reason", failures[1].reason, "source_add")

  failures = {}
  env.source.fail_next_load = "reload reconnect boom"
  local ok_silent_reload, silent_reload_err = pcall(env.handler.source_reload_reconnect, env.handler, "source1")
  Harness.drain()
  assert_true("silent_reload_error", not ok_silent_reload)
  assert_match("silent_reload_error_message", tostring(silent_reload_err), "reload reconnect boom")
  assert_eq("silent_reload_failure_events", #failures, 0)
  print("DCFG01_FAILURE_EVENT_OK=true")

  invalidations = {}
  failures = {}
  env.source.fail_next_load = "reload after add boom"
  local ok_partial, partial_err = pcall(env.handler.source_add_connection, env.handler, "source1", {
    id = "conn-gamma",
    name = "Gamma",
    type = "postgres",
    url = "postgres://gamma",
  })
  Harness.drain()
  assert_true("partial_failure_error", not ok_partial)
  assert_match("partial_failure_message", tostring(partial_err), "reload after add boom")
  assert_eq("partial_failure_event_count", #invalidations, 1)
  assert_eq("partial_failure_failure_count", #failures, 1)
  assert_eq("partial_failure_order_reason", invalidations[1].reason, "source_add")
  assert_eq("partial_failure_stage", failures[1].stage, "reload")
  local persisted = false
  for _, spec in ipairs(env.source._specs) do
    if spec.id == "conn-gamma" then
      persisted = true
      break
    end
  end
  assert_true("partial_failure_persisted", persisted)
  print("DCFG01_PARTIAL_FAILURE_OK=true")

  env:cleanup()
end

local function run_drawer_contracts()
  local env = new_env()

  local root_names = node_names(env.drawer.tree)
  assert_match("connection_only_root_alpha", root_names, "Alpha  [source1]")
  assert_match("connection_only_root_beta", root_names, "Beta  [source1]")
  assert_true("connection_only_root_no_source_row", not root_names:find("source1.json", 1, true))
  assert_true("connection_only_root_no_note_rows", not root_names:find("note", 1, true))
  print("DCFG01_CONNECTION_ONLY_ROOT_OK=true")

  clear_notifications()
  local help_id = "__help_node__"
  Harness.set_current_node(env.winid, env.drawer.tree, help_id)
  env.drawer:get_actions().edit_connection()
  env.drawer:get_actions().test_connection()
  Harness.drain()
  assert_true("non_connection_warn_edit", has_notification("select a connection row to edit", vim.log.levels.WARN))
  assert_true("non_connection_warn_test", has_notification("select a connection row to test", vim.log.levels.WARN))

  clear_notifications()
  local before_current = current_connection_id(env)
  local before_ids = table.concat(Harness.visible_node_ids(env.drawer.tree), "\n")
  Harness.set_current_node(env.winid, env.drawer.tree, "conn-alpha")
  env.runtime.connection_test_failures["conn-alpha"] = {
    error_kind = "network",
    message = "down",
  }
  env.drawer:get_actions().test_connection()
  Harness.drain()
  assert_eq("test_fail_closed_current", current_connection_id(env), before_current)
  assert_eq("test_fail_closed_tree", table.concat(Harness.visible_node_ids(env.drawer.tree), "\n"), before_ids)
  assert_true("test_fail_closed_notification", has_notification("Connection test failed (network): down", vim.log.levels.ERROR))
  print("DCFG01_TEST_FAIL_CLOSED_OK=true")

  clear_notifications()
  Harness.set_current_node(env.winid, env.drawer.tree, "conn-alpha")
  env.runtime.next_select_choice = "Edit source file"
  env.drawer:get_actions().edit_connection()
  Harness.drain()
  assert_eq("source_edit_calls", #env.runtime.editor_calls, 1)
  assert_match("source_edit_path", env.runtime.editor_calls[1].path, "source1.json")
  assert_match("source_edit_help_text", node_names(env.drawer.tree), "source file = e on a connection row")
  print("DCFG01_SOURCE_EDIT_REACHABLE_OK=true")

  clear_notifications()
  env.runtime.next_wizard_submission = {
    params = {
      name = "Delta",
      type = "postgres",
      url = "postgres://delta",
    },
    wizard = {
      db_kind = "postgres",
      mode = "postgres_url",
      fields = {
        name = "Delta",
        url = "postgres://delta",
      },
    },
  }
  Harness.set_current_node(env.winid, env.drawer.tree, "conn-alpha")
  local select_calls_before = #env.runtime.select_calls
  env.drawer:get_actions().add_connection()
  Harness.drain()
  assert_eq("add_connection_no_source_picker", #env.runtime.select_calls, select_calls_before)
  assert_eq("add_connection_submit_err", env.runtime.last_wizard_submit_err, nil)
  assert_true("add_connection_created", env.source._specs[#env.source._specs].name == "Delta")
  print("DCFG01_ACTION_TARGETING_OK=true")

  local env_refresh = new_env({
    seed_root = {
      ["conn-alpha"] = {
        structures = vim.deepcopy(ROOT_STRUCTURES),
      },
    },
    seed_root_epoch = {
      ["conn-alpha"] = 0,
    },
  })
  seed_drawer_root(env_refresh, "conn-alpha")
  Harness.set_current_node(env_refresh.winid, env_refresh.drawer.tree, "conn-alpha")
  env_refresh.drawer:get_actions().expand()
  Harness.drain()
  local schema_id = env_refresh.convert.structure_node_id("conn-alpha", {
    type = "schema",
    name = "public",
    schema = "public",
  })
  Harness.set_current_node(env_refresh.winid, env_refresh.drawer.tree, schema_id)
  env_refresh.drawer:get_actions().expand()
  Harness.drain()
  local users_id = table_node_id(env_refresh, "conn-alpha")

  env_refresh.drawer.refresh_count = 0
  Harness.set_current_node(env_refresh.winid, env_refresh.drawer.tree, "conn-beta")
  env_refresh.drawer:get_actions().action_1()
  Harness.drain()
  assert_eq("close_only_refresh_count", env_refresh.drawer.refresh_count, 0)
  assert_eq("current_conn_visual_target", current_connection_id(env_refresh), "conn-beta")
  assert_eq("current_conn_visual_cached_root", env_refresh.drawer._struct_cache.root["conn-alpha"].structures[1].name, "public")
  print("DCFG01_CURRENT_CONN_VISUAL_OK=true")

  env_refresh.drawer.refresh_count = 0
  env_refresh.runtime.next_select_choice = "Browse"
  Harness.set_current_node(env_refresh.winid, env_refresh.drawer.tree, users_id)
  env_refresh.drawer:get_actions().action_1()
  Harness.drain()
  assert_true("refresh_after_action_count", env_refresh.drawer.refresh_count > 0)
  print("DCFG01_REFRESH_MODE_OK=true")

  local before_filter_ids = table.concat(Harness.visible_node_ids(env_refresh.drawer.tree), "\n")
  Harness.set_current_node(env_refresh.winid, env_refresh.drawer.tree, "conn-alpha")
  env_refresh.drawer:get_actions().filter()
  Harness.drain()
  local filter_session = env_refresh.runtime.filter_sessions[#env_refresh.runtime.filter_sessions]
  assert_true("filter_session_created", filter_session ~= nil)
  filter_session:change("users")
  Harness.drain()
  assert_true("filter_narrowed", table.concat(Harness.visible_node_ids(env_refresh.drawer.tree), "\n") ~= before_filter_ids)
  filter_session:submit("")
  Harness.drain()
  assert_eq("filter_restore_snapshot", table.concat(Harness.visible_node_ids(env_refresh.drawer.tree), "\n"), before_filter_ids)
  print("DCFG01_PHASE6_FILTER_REGRESSION_OK=true")

  env_refresh:cleanup()
  env:cleanup()
end

run_lifecycle_contracts()
run_drawer_contracts()

print("DCFG01_DRAWER_LIFECYCLE_ALL_PASS=true")

vim.notify = saved_notify
vim.cmd("qa!")
