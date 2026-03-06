-- Headless regression tests for winbar format (NOTIF-07), yank notifications
-- (NOTIF-03/05), and schema refresh notification (NOTIF-06).
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=$(pwd)" \
--   -c "luafile ci/headless/check_winbar_format.lua"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function fail(msg)
  print("WINBAR_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local function assert_eq(label, got, expected)
  if got ~= expected then
    fail(label .. ": expected " .. vim.inspect(expected) .. " got " .. vim.inspect(got))
  end
end

local function assert_true(label, val)
  if not val then
    fail(label .. ": expected truthy, got " .. vim.inspect(val))
  end
end

local function assert_match(label, str, pattern)
  if type(str) ~= "string" or not str:find(pattern, 1, true) then
    fail(label .. ": expected string containing " .. vim.inspect(pattern) .. " got " .. vim.inspect(str))
  end
end

-- ---------------------------------------------------------------------------
-- Capture vim.notify
-- ---------------------------------------------------------------------------

local notifications = {}
local saved_notify = vim.notify

vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = tostring(msg), level = level, opts = opts }
end

local function clear_notifications()
  notifications = {}
end

-- ---------------------------------------------------------------------------
-- Stub dependencies before requiring modules
-- ---------------------------------------------------------------------------

-- Stub progress module (display_progress creates timers we don't need)
package.loaded["dbee.ui.result.progress"] = {
  display = function()
    return function() end -- stop function
  end,
}

-- Stub common module
package.loaded["dbee.ui.common"] = {
  create_blank_buffer = function(name, opts)
    local bufnr = vim.api.nvim_create_buf(false, true)
    return bufnr
  end,
  configure_buffer_mappings = function() end,
  configure_buffer_options = function() end,
  configure_window_options = function() end,
}

-- Stub floats (used by common)
package.loaded["dbee.ui.common.floats"] = {
  editor = function() end,
  hover = function() end,
  prompt = function() end,
}

-- ---------------------------------------------------------------------------
-- Create a test window for winbar assertions
-- ---------------------------------------------------------------------------

local test_buf = vim.api.nvim_create_buf(false, true)
local test_win = vim.api.nvim_open_win(test_buf, false, {
  relative = "editor",
  width = 60,
  height = 5,
  row = 0,
  col = 0,
})

-- ---------------------------------------------------------------------------
-- Test 1: format_duration via display_result winbar output (NOTIF-07)
-- ---------------------------------------------------------------------------

-- Build a mock handler that satisfies ResultUI:new
local mock_handler = {
  register_event_listener = function() end,
  call_display_result = function(self, call_id, bufnr, from, to)
    return 42 -- total rows
  end,
  call_store_result = function() end,
}

local ResultUI = require("dbee.ui.result")

local result = ResultUI:new(mock_handler)
-- Assign test window so has_window() returns true
result.winid = test_win

-- Helper: set a call with specific time_taken_us and check winbar
local function check_winbar_duration(us, expected_duration, label)
  result.current_call = {
    id = "call_dur_" .. tostring(us),
    state = "archived",
    time_taken_us = us,
  }
  result.page_index = 0
  result.page_ammount = 0
  -- display_result calls format_duration internally
  result:display_result(0)
  local winbar = vim.api.nvim_get_option_value("winbar", { win = test_win })
  assert_match(label .. "_duration", winbar, expected_duration)
  assert_match(label .. "_format", winbar, "Page 1/1 | 42 rows |")
end

check_winbar_duration(0, "0ms", "dur_zero")
check_winbar_duration(500, "0ms", "dur_sub_ms")
check_winbar_duration(35000, "35ms", "dur_ms")
check_winbar_duration(999999, "999ms", "dur_under_1s")
check_winbar_duration(1000000, "1.00s", "dur_1s")
check_winbar_duration(1230000, "1.23s", "dur_1_23s")
check_winbar_duration(59900000, "59.90s", "dur_59s")
check_winbar_duration(60000000, "1m 0s", "dur_1m")
check_winbar_duration(135000000, "2m 15s", "dur_2m15s")
check_winbar_duration(3661000000, "61m 1s", "dur_61m")

print("WINBAR_DURATION_OK=true")

-- ---------------------------------------------------------------------------
-- Test 2: Winbar state transitions via real on_call_state_changed (NOTIF-07)
-- ---------------------------------------------------------------------------

-- Reset state
result.current_call = { id = "call_state_1", state = "executing", time_taken_us = 0 }
result._progress_running = false

-- Fire executing state
result:on_call_state_changed({
  call = { id = "call_state_1", state = "executing", time_taken_us = 0 },
})
local wb_executing = vim.api.nvim_get_option_value("winbar", { win = test_win })
assert_eq("state_executing", wb_executing, "Executing...")

-- Fire retrieving state (same call id) -- MUST update despite _progress_running guard
result:on_call_state_changed({
  call = { id = "call_state_1", state = "retrieving", time_taken_us = 0 },
})
local wb_retrieving = vim.api.nvim_get_option_value("winbar", { win = test_win })
assert_eq("state_retrieving", wb_retrieving, "Retrieving...")

-- Verify set_default_result_window sets "Results"
result:set_default_result_window()
local wb_default = vim.api.nvim_get_option_value("winbar", { win = test_win })
assert_eq("state_default", wb_default, "Results")

print("WINBAR_STATE_TRANSITIONS_OK=true")

-- ---------------------------------------------------------------------------
-- Test 3: restore_call sets state-specific winbar (NOTIF-07)
-- ---------------------------------------------------------------------------

result:restore_call({
  id = "call_restore_1",
  state = "executing",
  time_taken_us = 0,
  timestamp_us = tostring(vim.fn.localtime() * 1000000),
})
local wb_restore_exec = vim.api.nvim_get_option_value("winbar", { win = test_win })
assert_eq("restore_executing", wb_restore_exec, "Executing...")
result.stop_progress()

result:restore_call({
  id = "call_restore_2",
  state = "retrieving",
  time_taken_us = 0,
  timestamp_us = tostring(vim.fn.localtime() * 1000000),
})
local wb_restore_retr = vim.api.nvim_get_option_value("winbar", { win = test_win })
assert_eq("restore_retrieving", wb_restore_retr, "Retrieving...")
result.stop_progress()

print("WINBAR_RESTORE_CALL_OK=true")

-- ---------------------------------------------------------------------------
-- Test 4: Yank notification paths (NOTIF-03, NOTIF-05)
-- ---------------------------------------------------------------------------

-- 4a: store_current_wrapper with no current_call -> WARN
clear_notifications()
result.current_call = nil
result:store_current_wrapper("csv", "+")
assert_true("yank_no_call_count", #notifications >= 1)
assert_match("yank_no_call_msg", notifications[1].msg, "No results to yank")
assert_eq("yank_no_call_level", notifications[1].level, vim.log.levels.WARN)

-- 4b: store_all_wrapper with no current_call -> WARN
clear_notifications()
result:store_all_wrapper("json", "+")
assert_true("yank_all_no_call_count", #notifications >= 1)
assert_match("yank_all_no_call_msg", notifications[1].msg, "No results to yank")

-- 4c: store_all_wrapper succeeds -> INFO with count
clear_notifications()
result.current_call = { id = "call_yank_1", state = "archived", time_taken_us = 1000000 }
result.total_rows = 42
mock_handler.call_store_result = function() end -- succeeds
result:store_all_wrapper("json", "+")
assert_true("yank_all_ok_count", #notifications >= 1)
assert_match("yank_all_ok_msg", notifications[1].msg, "Yanked 42 rows (JSON)")
assert_eq("yank_all_ok_level", notifications[1].level, vim.log.levels.INFO)

-- 4d: store_all_wrapper with handler error -> ERROR
clear_notifications()
mock_handler.call_store_result = function()
  error("RPC timeout")
end
result:store_all_wrapper("csv", "+")
assert_true("yank_all_err_count", #notifications >= 1)
assert_match("yank_all_err_msg", notifications[1].msg, "Yank failed:")
assert_eq("yank_all_err_level", notifications[1].level, vim.log.levels.ERROR)

-- 4e: store_current_wrapper succeeds (need current_row_index to work)
-- Stub current_row_index to return a known value
clear_notifications()
mock_handler.call_store_result = function() end
result.current_row_index = function()
  return 3
end
result:store_current_wrapper("csv", "+")
assert_true("yank_current_ok_count", #notifications >= 1)
assert_match("yank_current_ok_msg", notifications[1].msg, "Yanked 1 row (CSV)")
assert_eq("yank_current_ok_level", notifications[1].level, vim.log.levels.INFO)

-- 4f: store_current_wrapper when current_row_index fails -> WARN
clear_notifications()
result.current_row_index = function()
  error("couldn't retrieve current row number: row = 0")
end
result:store_current_wrapper("csv", "+")
assert_true("yank_current_fail_count", #notifications >= 1)
assert_match("yank_current_fail_msg", notifications[1].msg, "Could not determine current row")
assert_eq("yank_current_fail_level", notifications[1].level, vim.log.levels.WARN)

-- Restore real method
result.current_row_index = nil -- falls back to prototype

print("WINBAR_YANK_NOTIFICATIONS_OK=true")

-- ---------------------------------------------------------------------------
-- Test 5: Schema refresh notification (NOTIF-06)
-- ---------------------------------------------------------------------------

-- Load utils (already loaded by result module)
local utils = require("dbee.utils")

-- We test DrawerUI:on_structure_loaded by creating a minimal object
-- with the real method bound from the module's prototype.

-- First we need to stub DrawerUI dependencies to require the module
package.loaded["nui.tree"] = setmetatable({}, {
  __call = function()
    return {
      set_nodes = function() end,
      render = function() end,
      get_node = function() end,
      get_nodes = function()
        return {}
      end,
    }
  end,
})
package.loaded["nui.tree"].Node = function(fields, children)
  fields._children = children
  return fields
end

package.loaded["nui.line"] = function()
  return { append = function() end }
end

package.loaded["dbee.ui.drawer.menu"] = {
  select = function() end,
  input = function() end,
}

-- Stub convert module
package.loaded["dbee.ui.drawer.convert"] = {
  editor_nodes = function()
    return {}
  end,
  handler_nodes = function()
    return {}
  end,
  separator_node = function()
    return {}
  end,
  help_node = function()
    return {}
  end,
}

-- Stub expansion module
package.loaded["dbee.ui.drawer.expansion"] = {
  get = function()
    return {}
  end,
  set = function() end,
}

-- Reload utils to make sure vim.notify is still captured
package.loaded["dbee.utils"] = nil
utils = require("dbee.utils")
-- Re-override vim.notify after utils reload
vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = tostring(msg), level = level, opts = opts }
end

-- Clear and reload drawer module
package.loaded["dbee.ui.drawer"] = nil
local DrawerUI = require("dbee.ui.drawer")

-- Create a minimal DrawerUI-like object with the real on_structure_loaded method
local drawer_mock_handler = {
  register_event_listener = function() end,
  get_current_connection = function()
    return { id = "c1" }
  end,
  connection_get_params = function(self, conn_id)
    if conn_id == "c2" then
      error("connection not found")
    end
    return { name = "my-postgres-dev" }
  end,
  get_sources = function()
    return {}
  end,
  source_get_connections = function()
    return {}
  end,
}

local drawer_mock_editor = {
  register_event_listener = function() end,
  get_current_note = function()
    return { id = "note1" }
  end,
  namespace_get_notes = function()
    return {}
  end,
}

local drawer = DrawerUI:new(drawer_mock_handler, drawer_mock_editor, result)

-- 5a: Auto-load (conn_id NOT in _manual_refresh_conns) -> NO notification
clear_notifications()
drawer._manual_refresh_conns = {}
drawer:on_structure_loaded({ conn_id = "c1", structures = {} })
assert_eq("schema_autoload_no_notif", #notifications, 0)

-- 5b: Manual refresh (conn_id IN _manual_refresh_conns) -> INFO notification
clear_notifications()
drawer._manual_refresh_conns = { c1 = true }
drawer:on_structure_loaded({ conn_id = "c1", structures = {} })
assert_true("schema_manual_notif_count", #notifications >= 1)
assert_match("schema_manual_notif_msg", notifications[1].msg, "Schema loaded: my-postgres-dev")
assert_eq("schema_manual_notif_level", notifications[1].level, vim.log.levels.INFO)

-- Verify drain: c1 should be removed from set
assert_eq("schema_drain", drawer._manual_refresh_conns["c1"], nil)

-- 5c: After drain, same conn_id should NOT trigger notification (no leak)
clear_notifications()
drawer:on_structure_loaded({ conn_id = "c1", structures = {} })
assert_eq("schema_no_leak", #notifications, 0)

-- 5d: connection_get_params failure -> falls back to conn_id
clear_notifications()
drawer._manual_refresh_conns = { c2 = true }
drawer:on_structure_loaded({ conn_id = "c2", structures = {} })
assert_true("schema_fallback_count", #notifications >= 1)
assert_match("schema_fallback_msg", notifications[1].msg, "Schema loaded: c2")

-- 5e: Error in data -> no notification even if in manual set
clear_notifications()
drawer._manual_refresh_conns = { c3 = true }
drawer:on_structure_loaded({ conn_id = "c3", structures = {}, error = "connection failed" })
assert_eq("schema_error_no_notif", #notifications, 0)
-- But c3 should still be drained
assert_eq("schema_error_drained", drawer._manual_refresh_conns["c3"], nil)

print("WINBAR_SCHEMA_REFRESH_OK=true")

-- ---------------------------------------------------------------------------
-- Cleanup and done
-- ---------------------------------------------------------------------------

vim.notify = saved_notify
pcall(vim.api.nvim_win_close, test_win, true)
pcall(vim.api.nvim_buf_delete, test_buf, { force = true })

print("WINBAR_ALL_PASS=true")
vim.cmd("qa!")
