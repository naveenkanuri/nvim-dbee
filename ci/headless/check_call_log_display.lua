-- Headless regression tests for call log display features:
--   CLOG-01: Duration and timestamp columns
--   CLIP-01: Yank query action
--   CLOG-02: Re-run query action
--   Cleanup:  cancel_call uses utils.log
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=$(pwd)" \
--   -c "luafile ci/headless/check_call_log_display.lua"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function fail(msg)
  print("CLOG_FAIL=" .. msg)
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
-- Stub dependencies before requiring call_log
-- ---------------------------------------------------------------------------

-- NuiLine mock: tracks appended segments
local function make_nui_line()
  local line = { _segments = {} }
  function line:append(text, highlight)
    self._segments[#self._segments + 1] = { text = text, highlight = highlight }
  end
  return line
end
package.loaded["nui.line"] = make_nui_line

-- NuiTree mock: captures prepare_node, provides settable current node
local tree_prepare_node = nil
local tree_current_node = nil

local NuiTreeMock = {}
NuiTreeMock.__index = NuiTreeMock

package.loaded["nui.tree"] = setmetatable({}, {
  __call = function(_, opts)
    tree_prepare_node = opts.prepare_node
    local t = setmetatable({}, NuiTreeMock)
    function t:get_node()
      return tree_current_node
    end
    function t:set_nodes() end
    function t:render() end
    function t:get_nodes() return {} end
    return t
  end,
})
package.loaded["nui.tree"].Node = function(fields, children)
  fields._children = children
  return fields
end

-- Stub common module
package.loaded["dbee.ui.common"] = {
  create_blank_buffer = function()
    return vim.api.nvim_create_buf(false, true)
  end,
  configure_buffer_mappings = function() end,
  configure_window_options = function() end,
  float_hover = function() return function() end end,
}

-- Stub api module for call_log
local mock_cancel_ok = true
local mock_cancel_err = nil

package.loaded["dbee.api"] = {
  core = {
    is_loaded = function() return true end,
    get_current_connection = function() return nil end,
    connection_get_calls = function() return {} end,
    call_cancel = function()
      return mock_cancel_ok, mock_cancel_err
    end,
  },
  ui = {
    is_loaded = function() return false end,
    result_set_call = function() end,
    result_get_call = function() end,
  },
  setup = function() end,
  current_config = function()
    return {
      window_layout = {
        is_open = function() return false end,
        open = function() end,
        close = function() end,
      },
    }
  end,
}

package.loaded["dbee.install"] = {}

package.loaded["dbee.config"] = {
  default = {
    call_log = {
      mappings = {},
      disable_candies = true,
      candies = {},
    },
  },
}

-- Load utils first (real implementation)
local utils = require("dbee.utils")

-- Re-override vim.notify after utils loads
vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = tostring(msg), level = level, opts = opts }
end

-- Now require call_log
local CallLogUI = require("dbee.ui.call_log")

-- Build a mock handler
local mock_handler = {
  register_event_listener = function() end,
  get_current_connection = function()
    return { id = "c1" }
  end,
  connection_get_calls = function()
    return {}
  end,
  call_cancel = function(self, call_id)
    return mock_cancel_ok, mock_cancel_err
  end,
}

-- Build a mock result
local mock_result = {
  restore_call = function() end,
}

-- Create a CallLogUI instance
local call_log = CallLogUI:new(mock_handler, mock_result, {
  mappings = {},
  disable_candies = true,
  candies = {},
})

-- Get the actions table via do_action method wrapper
-- (get_actions is private but do_action exposes it)
local actions = call_log:get_actions()

-- ---------------------------------------------------------------------------
-- Group A: format_duration (shared utility)
-- ---------------------------------------------------------------------------

assert_eq("fmt_dur_zero", utils.format_duration(0), "0ms")
assert_eq("fmt_dur_35ms", utils.format_duration(35000), "35ms")
assert_eq("fmt_dur_1_50s", utils.format_duration(1500000), "1.50s")
assert_eq("fmt_dur_1m30s", utils.format_duration(90000000), "1m 30s")
assert_eq("fmt_dur_nil", utils.format_duration(nil), "0ms")

print("CLOG_FORMAT_DURATION_OK=true")

-- ---------------------------------------------------------------------------
-- Group B: CLOG-01 - Duration and timestamp in prepare_node
-- ---------------------------------------------------------------------------

-- B1: Archived call with today's timestamp
local now_us = os.time() * 1000000
local call_archived = {
  id = "b1",
  state = "archived",
  time_taken_us = 35000,
  timestamp_us = now_us,
  query = "SELECT * FROM users",
}
local node_b1 = { id = "b1", call = call_archived }
local line_b1 = tree_prepare_node(node_b1)
-- Find duration segment containing "35ms"
local found_dur_35ms = false
local found_time_today = false
local today_hhmm = os.date("%H:%M")
for _, seg in ipairs(line_b1._segments) do
  if type(seg.text) == "string" and seg.text:find("35ms", 1, true) then
    found_dur_35ms = true
  end
  if type(seg.text) == "string" and seg.text:find(today_hhmm, 1, true) then
    found_time_today = true
  end
end
assert_true("b1_duration_35ms", found_dur_35ms)
assert_true("b1_timestamp_today_hhmm", found_time_today)

-- B2: Call from yesterday should show MM-DD HH:MM
local yesterday_us = (os.time() - 86400) * 1000000
local call_yesterday = {
  id = "b2",
  state = "archived",
  time_taken_us = 1500000,
  timestamp_us = yesterday_us,
  query = "SELECT 1",
}
local node_b2 = { id = "b2", call = call_yesterday }
local line_b2 = tree_prepare_node(node_b2)
local yesterday_ts = math.floor(yesterday_us / 1000000)
local expected_mmdd = os.date("%m-%d %H:%M", yesterday_ts)
local found_mmdd = false
for _, seg in ipairs(line_b2._segments) do
  if type(seg.text) == "string" and seg.text:find(expected_mmdd, 1, true) then
    found_mmdd = true
  end
end
assert_true("b2_timestamp_mmdd", found_mmdd)

-- B3: Executing state shows "..." not "0ms"
local call_executing = {
  id = "b3",
  state = "executing",
  time_taken_us = 0,
  timestamp_us = now_us,
  query = "SELECT pg_sleep(10)",
}
local node_b3 = { id = "b3", call = call_executing }
local line_b3 = tree_prepare_node(node_b3)
local found_ellipsis_b3 = false
local found_0ms_b3 = false
for _, seg in ipairs(line_b3._segments) do
  if type(seg.text) == "string" and seg.text:find("...", 1, true) then
    found_ellipsis_b3 = true
  end
  if type(seg.text) == "string" and seg.text:find("0ms", 1, true) then
    found_0ms_b3 = true
  end
end
assert_true("b3_executing_ellipsis", found_ellipsis_b3)
assert_true("b3_executing_no_0ms", not found_0ms_b3)

-- B4: Retrieving state shows "..."
local call_retrieving = {
  id = "b4",
  state = "retrieving",
  time_taken_us = 0,
  timestamp_us = now_us,
  query = "SELECT count(*) FROM big_table",
}
local node_b4 = { id = "b4", call = call_retrieving }
local line_b4 = tree_prepare_node(node_b4)
local found_ellipsis_b4 = false
for _, seg in ipairs(line_b4._segments) do
  if type(seg.text) == "string" and seg.text:find("...", 1, true) then
    found_ellipsis_b4 = true
  end
end
assert_true("b4_retrieving_ellipsis", found_ellipsis_b4)

print("CLOG_DURATION_TIMESTAMP_OK=true")

-- ---------------------------------------------------------------------------
-- Group C: CLIP-01 - Yank query action
-- ---------------------------------------------------------------------------

-- C1: Yank with valid query
clear_notifications()
tree_current_node = { call = { query = "SELECT * FROM users WHERE id = 1" } }
actions.yank_query()
assert_eq("c1_unnamed_reg", vim.fn.getreg('"'), "SELECT * FROM users WHERE id = 1")
assert_eq("c1_clipboard_reg", vim.fn.getreg('+'), "SELECT * FROM users WHERE id = 1")
assert_true("c1_notif_count", #notifications >= 1)
assert_match("c1_notif_msg", notifications[1].msg, "Yanked query")
assert_match("c1_notif_chars", notifications[1].msg, "32 chars")

-- C2: Yank with empty query
clear_notifications()
tree_current_node = { call = { query = "" } }
actions.yank_query()
assert_true("c2_notif_count", #notifications >= 1)
assert_match("c2_notif_msg", notifications[1].msg, "No query to yank")
assert_eq("c2_notif_level", notifications[1].level, vim.log.levels.WARN)

print("CLOG_YANK_QUERY_OK=true")

-- ---------------------------------------------------------------------------
-- Group D: CLOG-02 - Re-run query behavior
-- ---------------------------------------------------------------------------

-- D1: Dispatch from call_log action
local rerun_captured_query = nil
package.loaded["dbee"] = {
  rerun_query = function(q)
    rerun_captured_query = q
  end,
}

clear_notifications()
tree_current_node = { call = { query = "SELECT * FROM orders" } }
actions.rerun_query()
assert_eq("d1_dispatch_query", rerun_captured_query, "SELECT * FROM orders")

-- D1b: Empty query guard in action
clear_notifications()
rerun_captured_query = nil
tree_current_node = { call = { query = "   " } }
actions.rerun_query()
assert_eq("d1b_no_dispatch", rerun_captured_query, nil)
assert_true("d1b_notif_count", #notifications >= 1)
assert_match("d1b_notif_msg", notifications[1].msg, "No query to re-run")

-- D1c: No node
clear_notifications()
rerun_captured_query = nil
tree_current_node = nil
actions.rerun_query()
assert_eq("d1c_no_dispatch", rerun_captured_query, nil)

-- D2: dbee.rerun_query guard paths (best-effort with module cache manipulation)
-- Clean slate: reload dbee with dedicated stubs

-- First, clear cached modules
package.loaded["dbee"] = nil
package.loaded["dbee.ui.result.progress"] = {
  display = function() return function() end end,
}
package.loaded["dbee.ui.drawer.menu"] = { select = function() end, input = function() end }
package.loaded["dbee.ui.drawer.convert"] = {
  editor_nodes = function() return {} end,
  handler_nodes = function() return {} end,
  separator_node = function() return {} end,
  help_node = function() return {} end,
}
package.loaded["dbee.ui.drawer.expansion"] = {
  get = function() return {} end,
  set = function() end,
}

-- Control flags for stubs
local stub_core_loaded = false
local stub_current_conn = nil
local stub_exec_called = false

package.loaded["dbee.api"] = {
  core = {
    is_loaded = function() return stub_core_loaded end,
    get_current_connection = function()
      if not stub_core_loaded then
        error("core not loaded")
      end
      return stub_current_conn
    end,
    connection_get_calls = function() return {} end,
    connection_execute = function(conn_id, query, opts)
      stub_exec_called = true
      return { id = "test-call", state = "executing", time_taken_us = 0 }
    end,
  },
  ui = {
    is_loaded = function() return false end,
    result_set_call = function() end,
    result_get_call = function() end,
    editor_get_all_notes = function() return {} end,
  },
  setup = function() end,
  current_config = function()
    return {
      window_layout = {
        is_open = function() return false end,
        open = function() end,
        close = function() end,
      },
    }
  end,
}

package.loaded["dbee.variables"] = {
  resolve_for_execute = function(q) return q end,
  resolve_for_execute_async = function(query, opts, cb)
    cb(query, nil, nil)
  end,
  bind_opts_for_query = function() return {} end,
}

-- Reload utils to get fresh vim.notify capture
package.loaded["dbee.utils"] = nil
utils = require("dbee.utils")
vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = tostring(msg), level = level, opts = opts }
end

-- Reload dbee module
package.loaded["dbee.query_splitter"] = {
  split = function() return {} end,
}
local dbee = require("dbee")

-- D2a: Core not loaded
clear_notifications()
stub_core_loaded = false
stub_current_conn = nil
dbee.rerun_query("SELECT 1")
assert_true("d2a_notif_count", #notifications >= 1)
assert_match("d2a_notif_msg", notifications[1].msg, "dbee core not loaded")
assert_eq("d2a_notif_level", notifications[1].level, vim.log.levels.WARN)

-- D2b: No connection selected
clear_notifications()
stub_core_loaded = true
stub_current_conn = nil
dbee.rerun_query("SELECT 1")
assert_true("d2b_notif_count", #notifications >= 1)
assert_match("d2b_notif_msg", notifications[1].msg, "No connection selected")
assert_match("d2b_notif_guidance", notifications[1].msg, "Select one from the drawer")
assert_eq("d2b_notif_level", notifications[1].level, vim.log.levels.WARN)

-- D2c: Blank/whitespace query
clear_notifications()
stub_core_loaded = true
stub_current_conn = { id = "c1", type = "postgres" }
dbee.rerun_query("   ")
assert_true("d2c_notif_count", #notifications >= 1)
assert_match("d2c_notif_msg", notifications[1].msg, "No query to re-run")
assert_eq("d2c_notif_level", notifications[1].level, vim.log.levels.WARN)

-- D2d: Valid query triggers execution
clear_notifications()
stub_exec_called = false
stub_core_loaded = true
stub_current_conn = { id = "c1", type = "postgres" }
dbee.rerun_query("SELECT * FROM orders")
assert_true("d2d_exec_called", stub_exec_called)

print("CLOG_RERUN_QUERY_OK=true")

-- ---------------------------------------------------------------------------
-- Group E: Cleanup - cancel_call uses utils.log
-- ---------------------------------------------------------------------------

-- Recreate call_log instance with cancellation test handler
-- Reload call_log module for fresh state
package.loaded["dbee.ui.call_log"] = nil
package.loaded["dbee.utils"] = nil
utils = require("dbee.utils")
vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = tostring(msg), level = level, opts = opts }
end

-- Reset api stub with configurable cancel
local cancel_return_ok = false
local cancel_return_err = "test cancel error"

package.loaded["dbee.api"] = {
  core = {
    is_loaded = function() return true end,
    get_current_connection = function() return { id = "c1" } end,
    connection_get_calls = function() return {} end,
  },
  ui = {
    is_loaded = function() return false end,
    result_set_call = function() end,
    result_get_call = function() end,
  },
  setup = function() end,
  current_config = function()
    return {
      window_layout = {
        is_open = function() return false end,
        open = function() end,
        close = function() end,
      },
    }
  end,
}

CallLogUI = require("dbee.ui.call_log")

local mock_handler_e = {
  register_event_listener = function() end,
  get_current_connection = function()
    return { id = "c1" }
  end,
  connection_get_calls = function()
    return {}
  end,
  call_cancel = function(self, call_id)
    return cancel_return_ok, cancel_return_err
  end,
}

local call_log_e = CallLogUI:new(mock_handler_e, mock_result, {
  mappings = {},
  disable_candies = true,
  candies = {},
})

-- Get fresh tree reference and set current node
local actions_e = call_log_e:get_actions()

-- Set a node on the tree mock
tree_current_node = { call = { id = "call-e1", state = "executing", query = "SELECT 1" } }

-- E1: cancel_call with error should route through utils.log (has opts.title = "nvim-dbee")
clear_notifications()
cancel_return_ok = false
cancel_return_err = "test cancel error"
actions_e.cancel_call()
assert_true("e1_notif_count", #notifications >= 1)
assert_match("e1_notif_msg", notifications[1].msg, "test cancel error")
assert_eq("e1_notif_level", notifications[1].level, vim.log.levels.WARN)
-- Verify utils.log was used (it sets opts.title = "nvim-dbee")
assert_true("e1_has_opts", notifications[1].opts ~= nil)
assert_eq("e1_opts_title", notifications[1].opts.title, "nvim-dbee")

print("CLOG_CANCEL_CLEANUP_OK=true")

-- ---------------------------------------------------------------------------
-- Cleanup and done
-- ---------------------------------------------------------------------------

vim.notify = saved_notify

print("CLOG_ALL_PASS=true")
vim.cmd("qa!")
