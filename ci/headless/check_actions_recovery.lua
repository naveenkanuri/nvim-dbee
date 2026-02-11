-- Headless regression tests for disconnected recovery actions.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=/path/to/nui.nvim" \
--   --cmd "set rtp+=/path/to/nvim-dbee" \
--   -c "luafile ci/headless/check_actions_recovery.lua"

package.loaded["dbee"] = nil
package.loaded["dbee.api"] = nil
package.loaded["dbee.config"] = nil
package.loaded["dbee.install"] = nil

local function make_conn(id, opts)
  opts = opts or {}
  return {
    id = id,
    name = opts.name or "Test Oracle",
    type = opts.type or "oracle",
    url = opts.url or "oracle://db",
  }
end

local source = {
  name = function(self)
    return "source_test"
  end,
}

local current_conn = make_conn("conn_old")
local source_conns = { make_conn("conn_old") }
local calls = {
  {
    id = "call_disconnected",
    query = "select :id from dual",
    state = "executing_failed",
    error_kind = "disconnected",
    timestamp_us = 10,
    time_taken_us = 1000,
    error = "dial tcp: lookup db.internal: no such host",
  },
}

local executed = {}
local reload_count = 0
local set_current_count = 0
local ui_input_calls = 0
local last_result_call = nil
local lookup_disabled = false
local core_loaded = true
local reload_mode = "default"

local saved_input = vim.ui.input

local function restore_input()
  vim.ui.input = saved_input
end

local function fail(msg)
  restore_input()
  print("ACTIONS_RECOVERY_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local function find_source_conn(id)
  for _, conn in ipairs(source_conns) do
    if conn.id == id then
      return conn
    end
  end
  return nil
end

package.loaded["dbee.api"] = {
  core = {
    is_loaded = function()
      return core_loaded
    end,
    get_current_connection = function()
      if not core_loaded then
        error("get_current_connection called while core not loaded")
      end
      return current_conn
    end,
    get_sources = function()
      return { source }
    end,
    source_get_connections = function(id)
      if id ~= "source_test" or lookup_disabled then
        return {}
      end
      return source_conns
    end,
    source_reload = function(id)
      if id ~= "source_test" then
        error("unexpected_source:" .. tostring(id))
      end
      reload_count = reload_count + 1

      if reload_mode == "default" then
        source_conns = { make_conn("conn_reloaded_" .. tostring(reload_count)) }
      elseif reload_mode == "id_conflict" then
        source_conns = {
          make_conn(current_conn.id, { type = "postgres", url = "postgres://db" }),
          make_conn("conn_type_ok", { type = current_conn.type, url = current_conn.url }),
        }
      elseif reload_mode == "ambiguous_url" then
        source_conns = {
          make_conn("conn_amb_1", { type = current_conn.type, url = current_conn.url }),
          make_conn("conn_amb_2", { type = current_conn.type, url = current_conn.url }),
        }
      else
        error("unknown_reload_mode:" .. tostring(reload_mode))
      end
    end,
    set_current_connection = function(id)
      local conn = find_source_conn(id)
      if not conn then
        error("unknown_conn:" .. tostring(id))
      end
      current_conn = conn
      set_current_count = set_current_count + 1
    end,
    connection_get_calls = function()
      return calls
    end,
    connection_execute = function(id, query, opts)
      local call = {
        id = "call_exec_" .. tostring(#executed + 1),
        conn_id = id,
        query = query,
        opts = opts,
        state = "archived",
        timestamp_us = 20 + #executed,
        time_taken_us = 1000,
        error = "",
      }
      executed[#executed + 1] = call
      calls[#calls + 1] = call
      return call
    end,
  },
  ui = {
    result_get_call = function()
      return nil
    end,
    result_set_call = function(call)
      last_result_call = call
    end,
  },
  setup = function() end,
  current_config = function()
    return {
      window_layout = {
        is_open = function()
          return false
        end,
        open = function() end,
        close = function() end,
        reset = function() end,
        toggle_drawer = function() end,
      },
    }
  end,
}

package.loaded["dbee.install"] = { exec = function() end }
package.loaded["dbee.config"] = {
  merge_with_default = function(cfg)
    return cfg or {}
  end,
  validate = function() end,
}

local dbee = require("dbee")

vim.ui.input = function(_, cb)
  ui_input_calls = ui_input_calls + 1
  cb("7")
end

dbee.actions({ action = "recover_disconnected" })

local ok = vim.wait(1000, function()
  return #executed == 1
end, 20)
if not ok then
  fail("recover_execute_timeout")
  return
end

if reload_count ~= 1 then
  fail("recover_reload_count:" .. tostring(reload_count))
  return
end
if set_current_count ~= 1 then
  fail("recover_set_current_count:" .. tostring(set_current_count))
  return
end
if executed[1].query ~= "select :id from dual" then
  fail("recover_query:" .. tostring(executed[1].query))
  return
end
if executed[1].conn_id ~= "conn_reloaded_1" then
  fail("recover_conn_id:" .. tostring(executed[1].conn_id))
  return
end
if not (executed[1].opts and executed[1].opts.binds and executed[1].opts.binds.id == "7") then
  fail("recover_bind_opts")
  return
end
if ui_input_calls ~= 1 then
  fail("recover_prompt_count:" .. tostring(ui_input_calls))
  return
end
if not (last_result_call and last_result_call.id == executed[1].id) then
  fail("recover_result_not_updated")
  return
end

dbee.actions({ action = "reconnect_current" })
if reload_count ~= 2 then
  fail("reconnect_reload_count:" .. tostring(reload_count))
  return
end
if set_current_count ~= 2 then
  fail("reconnect_set_current_count:" .. tostring(set_current_count))
  return
end
if current_conn.id ~= "conn_reloaded_2" then
  fail("reconnect_conn_id:" .. tostring(current_conn.id))
  return
end

reload_mode = "id_conflict"
current_conn = make_conn("conn_old_sameid", { type = "oracle", url = "oracle://id-conflict" })
source_conns = { current_conn }
local remapped_conn, remapped_err = dbee.reconnect_current_connection({ notify = false })
if remapped_err ~= nil or not remapped_conn then
  fail("id_conflict_reconnect_err:" .. tostring(remapped_err))
  return
end
if remapped_conn.id ~= "conn_type_ok" then
  fail("id_conflict_selected:" .. tostring(remapped_conn.id))
  return
end
if current_conn.id ~= "conn_type_ok" then
  fail("id_conflict_current:" .. tostring(current_conn.id))
  return
end

reload_mode = "ambiguous_url"
current_conn = make_conn("conn_old_amb", { type = "oracle", url = "oracle://ambiguous" })
source_conns = { current_conn }
local _, ambiguous_err = dbee.reconnect_current_connection({ notify = false })
if not ambiguous_err or not tostring(ambiguous_err):find("URL mapping is ambiguous", 1, true) then
  fail("ambiguous_url_error:" .. tostring(ambiguous_err))
  return
end

for i = #calls, 1, -1 do
  calls[i] = nil
end
calls[1] = {
  id = "call_ok",
  query = "select 1 from dual",
  state = "archived",
  error_kind = "unknown",
  timestamp_us = 99,
  time_taken_us = 1000,
  error = "",
}
local ok_absent, absent_err = pcall(dbee.actions, { action = "recover_disconnected" })
if ok_absent then
  fail("recover_action_should_be_absent")
  return
end
if not tostring(absent_err):find("unknown dbee action", 1, true) then
  fail("recover_absent_error:" .. tostring(absent_err))
  return
end

lookup_disabled = true
local _, reconnect_err = dbee.reconnect_current_connection({ notify = false })
if not reconnect_err or not tostring(reconnect_err):find("could not locate source", 1, true) then
  fail("reconnect_source_lookup_error:" .. tostring(reconnect_err))
  return
end
lookup_disabled = false

core_loaded = false
local ok_guard, guard_err = pcall(dbee.actions, { action = "drawer" })
if not ok_guard then
  fail("actions_core_guard:" .. tostring(guard_err))
  return
end
core_loaded = true

restore_input()

print("ACTIONS_RECOVERY_RETRY_OK=true")
print("ACTIONS_RECOVERY_RECONNECT_OK=true")
print("ACTIONS_RECOVERY_ID_CONFLICT_OK=true")
print("ACTIONS_RECOVERY_AMBIGUOUS_URL_OK=true")
print("ACTIONS_RECOVERY_ABSENT_OK=true")
print("ACTIONS_RECOVERY_SOURCE_LOOKUP_OK=true")
print("ACTIONS_RECOVERY_CORE_GUARD_OK=true")
vim.cmd("qa!")
