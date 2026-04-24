-- Headless regression tests for Phase 05 auto-reconnect behavior.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=/path/to/nvim-dbee" \
--   -c "luafile ci/headless/check_auto_reconnect.lua"

local saved_notify = vim.notify
local saved_select = vim.ui.select

local notifications = {}

vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = {
    msg = tostring(msg),
    level = level,
    opts = opts,
  }
end

local function restore_ui()
  vim.notify = saved_notify
  vim.ui.select = saved_select
end

local function fail(msg)
  restore_ui()
  print("CONN01_FAIL=" .. tostring(msg))
  vim.cmd("cquit 1")
end

local function assert_true(name, value)
  if not value then
    fail(name .. ":" .. vim.inspect(value))
  end
end

local function assert_eq(name, got, want)
  if got ~= want then
    fail(name .. ":" .. vim.inspect(got) .. "!=" .. vim.inspect(want))
  end
end

local function map_len(tbl)
  local count = 0
  for _ in pairs(tbl or {}) do
    count = count + 1
  end
  return count
end

local function clear_modules()
  local modules = {
    "dbee",
    "dbee.api",
    "dbee.api.ui",
    "dbee.api.state",
    "dbee.config",
    "dbee.install",
    "dbee.query_splitter",
    "dbee.reconnect",
    "dbee.variables",
  }
  for _, name in ipairs(modules) do
    package.loaded[name] = nil
  end
end

local function make_conn(id, opts)
  opts = opts or {}
  return {
    id = id,
    name = opts.name or id,
    type = opts.type or "oracle",
    url = opts.url or ("db://" .. tostring(id)),
  }
end

local function split_statements(script)
  local queries = {}
  for statement in tostring(script or ""):gmatch("([^;]+)") do
    local trimmed = vim.trim(statement)
    if trimmed ~= "" then
      queries[#queries + 1] = trimmed
    end
  end
  return queries
end

local function load_runtime(opts)
  clear_modules()
  notifications = {}

  opts = opts or {}
  local env = {
    select_choices = {},
    prompts = {},
    executed = {},
    result_calls = {},
    rebind_calls = {},
    rewrite_events = {},
    set_current_calls = {},
    source_conns = vim.deepcopy(opts.source_conns or { opts.current_conn or make_conn("conn_old", { type = opts.adapter_type or "oracle" }) }),
    current_conn = vim.deepcopy(opts.current_conn or make_conn("conn_old", { type = opts.adapter_type or "oracle" })),
    calls_by_conn = opts.calls_by_conn or {},
    reload_count = 0,
    core_loaded = opts.core_loaded ~= false,
    exec_errors = opts.exec_errors or {},
    ui_loaded = opts.ui_loaded == true,
    open_calls = 0,
  }

  env.source = {
    name = function()
      return "source_test"
    end,
  }

  local function ensure_calls(conn_id)
    env.calls_by_conn[conn_id] = env.calls_by_conn[conn_id] or {}
    return env.calls_by_conn[conn_id]
  end

  local function find_conn(conn_id)
    if env.current_conn and env.current_conn.id == conn_id then
      return env.current_conn
    end
    for _, conn in ipairs(env.source_conns or {}) do
      if conn.id == conn_id then
        return conn
      end
    end
    return nil
  end

  local function make_call(conn_id, query, exec_opts)
    local call_id = "call_exec_" .. tostring(#env.executed + 1)
    local call = {
      id = call_id,
      conn_id = conn_id,
      query = query,
      exec_opts = exec_opts,
      state = "executing",
      timestamp_us = #env.executed + 1,
      time_taken_us = 0,
      error = nil,
      error_kind = "unknown",
    }
    env.executed[#env.executed + 1] = {
      conn_id = conn_id,
      query = query,
      exec_opts = exec_opts,
      call = call,
    }
    ensure_calls(conn_id)[#ensure_calls(conn_id) + 1] = call
    return call
  end

  local function reload_source()
    env.reload_count = env.reload_count + 1
    if type(opts.reload_handler) == "function" then
      opts.reload_handler(env)
      return
    end
    if type(opts.reload_sequence) == "table" and opts.reload_sequence[env.reload_count] then
      env.source_conns = vim.deepcopy(opts.reload_sequence[env.reload_count])
      return
    end
    if opts.same_id_reload then
      env.source_conns = { vim.deepcopy(env.current_conn) }
      return
    end
    local new_conn = make_conn("conn_reloaded_" .. tostring(env.reload_count), {
      type = env.current_conn and env.current_conn.type or opts.adapter_type or "oracle",
      name = "conn_reloaded_" .. tostring(env.reload_count),
      url = "db://conn_reloaded_" .. tostring(env.reload_count),
    })
    env.source_conns = { new_conn }
  end

  local listeners = {}

  local function register_listener(event, listener)
    listeners[event] = listeners[event] or {}
    listeners[event][#listeners[event] + 1] = listener
  end

  env.emit_call_state = function(payload)
    local call = payload.call
    local calls = ensure_calls(payload.conn_id)
    local found = false
    for _, existing in ipairs(calls) do
      if existing.id == call.id then
        for key, value in pairs(call) do
          existing[key] = value
        end
        found = true
        break
      end
    end
    if not found then
      calls[#calls + 1] = vim.deepcopy(call)
    end
    for _, listener in ipairs(listeners.call_state_changed or {}) do
      listener(payload)
    end
  end

  vim.ui.select = function(items, select_opts, on_choice)
    env.prompts[#env.prompts + 1] = {
      items = vim.deepcopy(items),
      prompt = select_opts and select_opts.prompt or "",
    }
    local choice = table.remove(env.select_choices, 1)
    if choice == "__defer__" then
      env.pending_select = {
        items = items,
        opts = select_opts,
        on_choice = on_choice,
      }
      return
    end
    on_choice(choice)
  end

  package.loaded["dbee.api"] = {
    core = {
      is_loaded = function()
        return env.core_loaded
      end,
      register_event_listener = register_listener,
      get_current_connection = function()
        if not env.core_loaded then
          error("core not loaded")
        end
        return env.current_conn
      end,
      connection_get_params = function(conn_id)
        local conn = find_conn(conn_id)
        if not conn then
          error("unknown_conn:" .. tostring(conn_id))
        end
        return conn
      end,
      get_sources = function()
        return { env.source }
      end,
      source_get_connections = function(source_id)
        if source_id ~= "source_test" then
          return {}
        end
        return env.source_conns
      end,
      source_reload = function(source_id)
        if source_id ~= "source_test" then
          error("unexpected_source:" .. tostring(source_id))
        end
        reload_source()
      end,
      set_current_connection = function(conn_id)
        local conn = find_conn(conn_id)
        if not conn then
          error("unknown_conn:" .. tostring(conn_id))
        end
        env.current_conn = conn
        env.set_current_calls[#env.set_current_calls + 1] = conn_id
      end,
      connection_execute = function(conn_id, query, exec_opts)
        local exec_err = env.exec_errors[query]
        if exec_err then
          error(exec_err)
        end
        if type(opts.connection_execute) == "function" then
          return opts.connection_execute(env, conn_id, query, exec_opts, make_call)
        end
        return make_call(conn_id, query, exec_opts)
      end,
      connection_get_calls = function(conn_id)
        return ensure_calls(conn_id)
      end,
      call_cancel = function(call_id)
        env.canceled_call_id = call_id
      end,
    },
    ui = {
      is_loaded = function()
        return env.ui_loaded
      end,
      result_set_call = function(call)
        env.result_calls[#env.result_calls + 1] = call
        env.last_result_call = call
      end,
      result_get_call = function()
        return env.last_result_call
      end,
      rebind_note_connection = function(note_id, conn_id, conn_name, conn_type)
        env.rebind_calls[#env.rebind_calls + 1] = {
          note_id = note_id,
          conn_id = conn_id,
          conn_name = conn_name,
          conn_type = conn_type,
        }
      end,
      editor_get_all_notes = function()
        return {}
      end,
    },
    setup = function() end,
    current_config = function()
      return {
        window_layout = {
          is_open = function()
            return env.window_open == true
          end,
          open = function()
            env.window_open = true
            env.open_calls = env.open_calls + 1
          end,
          close = function()
            env.window_open = false
          end,
          reset = function() end,
          toggle_drawer = function() end,
        },
      }
    end,
  }

  package.loaded["dbee.install"] = {
    exec = function() end,
  }

  package.loaded["dbee.config"] = {
    default = {},
    merge_with_default = function(cfg)
      return cfg or {}
    end,
    validate = function() end,
  }

  package.loaded["dbee.query_splitter"] = {
    split = function(script)
      return split_statements(script)
    end,
  }

  package.loaded["dbee.variables"] = {
    resolve_for_execute = function(query, var_opts)
      local binds = var_opts and var_opts.values and vim.deepcopy(var_opts.values) or nil
      if binds and next(binds) ~= nil then
        return query, { binds = binds }, nil
      end
      return query, nil, nil
    end,
    resolve_for_execute_async = function(query, var_opts, on_done)
      local resolved, exec_opts, err = package.loaded["dbee.variables"].resolve_for_execute(query, var_opts)
      on_done(resolved, exec_opts, err)
    end,
    bind_opts_for_query = function(_, bind_opts)
      local binds = bind_opts and bind_opts.binds and vim.deepcopy(bind_opts.binds) or nil
      if binds and next(binds) ~= nil then
        return { binds = binds }
      end
      return nil
    end,
  }

  local dbee = require("dbee")
  local reconnect = require("dbee.reconnect")
  env.listeners = listeners
  return env, dbee, reconnect
end

local function assert_prompt_count(env, want)
  assert_eq("prompt_count", #env.prompts, want)
end

do
  local env, _, reconnect = load_runtime({
    current_conn = make_conn("conn_old", { type = "oracle" }),
    reload_sequence = {
      { make_conn("conn_new", { type = "oracle" }) },
    },
  })

  local exec_opts = { binds = { foo = "1" } }
  local retry_meta = {
    conn_id = "conn_old",
    conn_name = "conn_old",
    conn_type = "oracle",
    resolved_query = "select :foo from dual",
    exec_opts = exec_opts,
  }
  reconnect.register_call("call_old", retry_meta)
  exec_opts.binds.foo = "mutated"

  local stored_meta = reconnect._debug_snapshot().calls_by_id.call_old
  local ok_retry, new_call, new_conn_id = reconnect.retry_call("conn_old", "call_old", stored_meta)
  assert_true("deep_copy_retry_ok", ok_retry)
  assert_eq("deep_copy_reconnected_id", new_conn_id, "conn_new")
  assert_eq("deep_copy_exec_bind", env.executed[1].exec_opts.binds.foo, "1")
  local snapshot = reconnect._debug_snapshot()
  assert_true("deep_copy_registered_new_call", snapshot.calls_by_id[new_call.id] ~= nil)
  assert_eq("deep_copy_meta_conn_id", snapshot.calls_by_id[new_call.id].conn_id, "conn_new")

  print("CONN01_DEEP_COPY_BINDS_OK=true")
  print("CONN01_CHANGED_CONN_ID_OK=true")
end

do
  local env, _, reconnect = load_runtime({
    current_conn = make_conn("conn_same", { type = "oracle" }),
    same_id_reload = true,
  })

  local retry_meta = {
    conn_id = "conn_same",
    conn_name = "conn_same",
    conn_type = "oracle",
    resolved_query = "select 1 from dual",
  }
  reconnect.register_call("call_same", retry_meta)

  local rewrite_hits = 0
  reconnect.register_connection_rewritten_listener("probe", function()
    rewrite_hits = rewrite_hits + 1
  end)
  local ok_duplicate = pcall(reconnect.register_connection_rewritten_listener, "probe", function() end)
  assert_true("rewrite_listener_duplicate_guard", not ok_duplicate)

  local stored_meta = reconnect._debug_snapshot().calls_by_id.call_same
  local ok_retry, new_call, new_conn_id = reconnect.retry_call("conn_same", "call_same", stored_meta)
  assert_true("same_id_retry_ok", ok_retry)
  assert_eq("same_id_conn_id", new_conn_id, "conn_same")
  assert_eq("same_id_rewrite_hits", rewrite_hits, 0)
  local snapshot = reconnect._debug_snapshot()
  assert_true("same_id_new_call_registered", snapshot.calls_by_id[new_call.id] ~= nil)
  assert_eq("same_id_call_bucket_count", map_len(snapshot.call_ids_by_conn.conn_same), 1)

  print("CONN01_SAME_ID_FAST_PATH_OK=true")
  print("CONN01_REWRITE_LISTENER_GUARD_OK=true")
end

do
  local env, _, reconnect = load_runtime({
    current_conn = make_conn("conn_old", { type = "oracle" }),
  })

  env.select_choices = { "__defer__", "__defer__" }

  reconnect.register_connection_rewritten_listener("fanout-probe", function(old_conn_id, new_conn_id)
    env.rewrite_events[#env.rewrite_events + 1] = {
      old_conn_id = old_conn_id,
      new_conn_id = new_conn_id,
    }
  end)

  reconnect.register_call("call_old_a1", {
    conn_id = "conn_old",
    conn_name = "conn_old",
    conn_type = "oracle",
    note_id = "note_a",
    resolved_query = "select 1 from dual",
  })
  reconnect.register_call("call_old_a2", {
    conn_id = "conn_old",
    conn_name = "conn_old",
    conn_type = "oracle",
    note_id = "note_a",
    resolved_query = "select 2 from dual",
  })
  reconnect.register_call("call_old_b", {
    conn_id = "conn_old",
    conn_name = "conn_old",
    conn_type = "oracle",
    note_id = "note_b",
    resolved_query = "select 3 from dual",
  })
  reconnect.register_call("call_new", {
    conn_id = "conn_new",
    conn_name = "conn_new",
    conn_type = "oracle",
    resolved_query = "select 4 from dual",
  })

  env.emit_call_state({
    conn_id = "conn_old",
    call = {
      id = "call_old_a2",
      query = "select 2 from dual",
      state = "executing_failed",
      error_kind = "disconnected",
      timestamp_us = 30,
      time_taken_us = 0,
      error = "lost old",
    },
  })
  env.emit_call_state({
    conn_id = "conn_new",
    call = {
      id = "call_new",
      query = "select 4 from dual",
      state = "executing_failed",
      error_kind = "disconnected",
      timestamp_us = 20,
      time_taken_us = 0,
      error = "lost new",
    },
  })

  reconnect.rewrite_connection_identity("conn_old", "conn_new", "conn_new", "oracle")
  local snapshot = reconnect._debug_snapshot()
  assert_true("fanout_old_bucket_cleared", snapshot.call_ids_by_conn.conn_old == nil)
  assert_true("fanout_new_bucket_exists", snapshot.call_ids_by_conn.conn_new ~= nil)
  assert_eq("fanout_new_bucket_size", map_len(snapshot.call_ids_by_conn.conn_new), 4)
  assert_eq("fanout_rebind_count", #env.rebind_calls, 2)
  assert_eq("fanout_rewrite_events", #env.rewrite_events, 1)
  assert_true("episode_old_migrated", snapshot.episodes.conn_old == nil)
  assert_true("episode_new_exists", snapshot.episodes.conn_new ~= nil)
  assert_eq("episode_new_latest_call", snapshot.episodes.conn_new.latest_call_id, "call_old_a2")
  assert_eq("episode_new_latest_ts", snapshot.episodes.conn_new.latest_failed_ts, 30)

  env.emit_call_state({
    conn_id = "conn_old",
    call = {
      id = "call_old_a2",
      query = "select 2 from dual",
      state = "archive_failed",
      error_kind = "disconnected",
      timestamp_us = 31,
      time_taken_us = 0,
      error = "late old wire event",
    },
  })
  snapshot = reconnect._debug_snapshot()
  assert_true("effective_conn_old_not_recreated", snapshot.episodes.conn_old == nil)
  assert_true("effective_conn_new_persists", snapshot.episodes.conn_new ~= nil)

  print("CONN01_EPISODE_MIGRATION_OK=true")
  print("CONN01_CONN_REWRITE_FANOUT_OK=true")
  print("CONN01_EFFECTIVE_CONN_ID_OK=true")
end

do
  local env, _, reconnect = load_runtime({
    current_conn = make_conn("conn_old", { type = "oracle" }),
    reload_sequence = {
      { make_conn("conn_new1", { type = "oracle" }) },
      { make_conn("conn_new2", { type = "oracle" }) },
    },
  })

  env.select_choices = { "Yes", "Yes" }

  reconnect.register_call("call_retry_old", {
    conn_id = "conn_old",
    conn_name = "conn_old",
    conn_type = "oracle",
    resolved_query = "select retry from dual",
  })

  env.emit_call_state({
    conn_id = "conn_old",
    call = {
      id = "call_retry_old",
      query = "select retry from dual",
      state = "executing_failed",
      error_kind = "disconnected",
      timestamp_us = 10,
      time_taken_us = 0,
      error = "lost first",
    },
  })
  assert_prompt_count(env, 1)
  local first_retry_call = env.executed[1].call
  assert_true("first_retry_call_created", first_retry_call ~= nil)

  env.emit_call_state({
    conn_id = "conn_new1",
    call = {
      id = first_retry_call.id,
      query = first_retry_call.query,
      state = "executing_failed",
      error_kind = "disconnected",
      timestamp_us = 20,
      time_taken_us = 0,
      error = "lost second",
    },
  })
  assert_prompt_count(env, 2)
  local second_retry_call = env.executed[2].call
  assert_true("second_retry_call_created", second_retry_call ~= nil)

  local snapshot = reconnect._debug_snapshot()
  assert_eq("reregister_call_count", snapshot.call_count, 1)
  assert_true("reregister_latest_present", snapshot.calls_by_id[second_retry_call.id] ~= nil)

  env.emit_call_state({
    conn_id = "conn_new1",
    call = {
      id = first_retry_call.id,
      query = first_retry_call.query,
      state = "archive_failed",
      error_kind = "disconnected",
      timestamp_us = 21,
      time_taken_us = 0,
      error = "late stale terminal",
    },
  })

  snapshot = reconnect._debug_snapshot()
  assert_eq("late_retired_registry_bounded", snapshot.call_count, 1)
  assert_true("late_retired_old_episode_absent", snapshot.episodes.conn_new1 == nil)

  print("CONN01_REREGISTER_OK=true")
end

do
  local env, _, reconnect = load_runtime({
    current_conn = make_conn("conn_old", { type = "oracle" }),
    same_id_reload = true,
    exec_errors = {
      ["select explode from dual"] = "execute boom",
    },
  })

  local retry_meta = {
    conn_id = "conn_old",
    conn_name = "conn_old",
    conn_type = "oracle",
    resolved_query = "select explode from dual",
  }
  reconnect.register_call("call_retry_fail", retry_meta)

  local stored_meta = reconnect._debug_snapshot().calls_by_id.call_retry_fail
  local ok_retry, retry_err = reconnect.retry_call("conn_old", "call_retry_fail", stored_meta)
  assert_true("retry_pcall_failed", not ok_retry)
  assert_true("retry_pcall_message", tostring(retry_err):find("execute boom", 1, true) ~= nil)

  print("CONN01_RETRY_PCALL_OK=true")
end

do
  local env, dbee, reconnect = load_runtime({
    current_conn = make_conn("conn_old", { type = "oracle", name = "Oracle Old" }),
    reload_sequence = {
      { make_conn("conn_new", { type = "oracle", name = "Oracle New" }) },
    },
  })

  env.select_choices = { "Yes" }

  dbee.explain_plan({ query = "SELECT * FROM dual" })
  assert_eq("callback_step1_exec_count", #env.executed, 1)
  assert_eq("callback_step1_query", env.executed[1].query, "EXPLAIN PLAN FOR SELECT * FROM dual")

  env.emit_call_state({
    conn_id = "conn_old",
    call = {
      id = env.executed[1].call.id,
      query = env.executed[1].query,
      state = "archived",
      error_kind = "unknown",
      timestamp_us = 10,
      time_taken_us = 0,
      error = nil,
    },
  })
  assert_eq("callback_step2_exec_count", #env.executed, 2)
  assert_eq("callback_step2_query", env.executed[2].query, "SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY)")

  env.emit_call_state({
    conn_id = "conn_old",
    call = {
      id = env.executed[2].call.id,
      query = env.executed[2].query,
      state = "executing_failed",
      error_kind = "disconnected",
      timestamp_us = 20,
      time_taken_us = 0,
      error = "lost step2",
    },
  })
  assert_eq("callback_retry_step1_count", #env.executed, 3)
  assert_eq("callback_retry_step1_query", env.executed[3].query, "EXPLAIN PLAN FOR SELECT * FROM dual")

  env.emit_call_state({
    conn_id = "conn_new",
    call = {
      id = env.executed[3].call.id,
      query = env.executed[3].query,
      state = "archived",
      error_kind = "unknown",
      timestamp_us = 30,
      time_taken_us = 0,
      error = nil,
    },
  })
  assert_eq("callback_retry_step2_count", #env.executed, 4)
  assert_eq("callback_retry_step2_query", env.executed[4].query, "SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY)")

  local snapshot = reconnect._debug_snapshot()
  assert_true("callback_step2_registered", snapshot.calls_by_id[env.executed[4].call.id] ~= nil)
  assert_eq("callback_step2_conn_id", snapshot.calls_by_id[env.executed[4].call.id].conn_id, "conn_new")

  print("CONN01_CALLBACK_REPLAY_OK=true")
end

do
  local env, dbee = load_runtime({
    current_conn = make_conn("conn_old", { type = "oracle" }),
    calls_by_conn = {
      conn_old = {
        {
          id = "call_synth",
          query = "SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY)",
          state = "executing_failed",
          error_kind = "disconnected",
          timestamp_us = 50,
          time_taken_us = 0,
          error = "lost legacy explain",
        },
      },
    },
  })

  local ok_retry, retry_err = dbee.retry_last_disconnected()
  assert_true("synthetic_abort_no_retry", not ok_retry)
  assert_eq("synthetic_abort_exec_count", #env.executed, 0)
  assert_true("synthetic_abort_message", tostring(retry_err):find("Cannot auto-retry opaque flow", 1, true) ~= nil)

  print("CONN01_SYNTHETIC_FALLBACK_ABORT_OK=true")
end

do
  local env, _, reconnect = load_runtime({
    current_conn = make_conn("conn_flap", { type = "oracle" }),
  })

  env.select_choices = { "__defer__" }
  for i = 1, 10 do
    local call_id = "call_flap_" .. tostring(i)
    reconnect.register_call(call_id, {
      conn_id = "conn_flap",
      conn_name = "conn_flap",
      conn_type = "oracle",
      resolved_query = "select " .. tostring(i),
    })
    env.emit_call_state({
      conn_id = "conn_flap",
      call = {
        id = call_id,
        query = "select " .. tostring(i),
        state = "executing_failed",
        error_kind = "disconnected",
        timestamp_us = i,
        time_taken_us = 0,
        error = "lost flap",
      },
    })
  end

  local snapshot = reconnect._debug_snapshot()
  assert_eq("registry_bounded_count", snapshot.call_count, 1)
  assert_eq("registry_bounded_latest", snapshot.episodes.conn_flap.latest_call_id, "call_flap_10")

  print("CONN01_REGISTRY_BOUNDED=true")
end

do
  clear_modules()
  local editor_called = false
  package.loaded["dbee.api.state"] = {
    is_ui_loaded = function()
      return false
    end,
    editor = function()
      editor_called = true
      return {
        rebind_note_connection = function()
          editor_called = true
        end,
      }
    end,
  }

  local ui = require("dbee.api.ui")
  local ok = pcall(ui.rebind_note_connection, "note_1", "conn_new", "conn_new", "oracle")
  assert_true("ui_bridge_noop_ok", ok)
  assert_true("ui_bridge_editor_not_called", not editor_called)

  print("CONN01_UI_BRIDGE_NOOP_OK=true")
end

print("CONN01_ALL_PASS=true")

restore_ui()
vim.cmd("qa!")
