-- Headless regression tests for pane jumping:
--   NAV-02: focus pane actions and dbee.focus_pane public API
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=$(pwd)" \
--   -c "luafile ci/headless/check_pane_jump.lua"

local function fail(msg)
  print("NAV02_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local function assert_eq(label, got, expected)
  if got ~= expected then
    fail(label .. ": expected " .. vim.inspect(expected) .. " got " .. vim.inspect(got))
  end
end

local function assert_true(label, value)
  if not value then
    fail(label .. ": expected truthy, got " .. vim.inspect(value))
  end
end

local function assert_match(label, str, pattern)
  if type(str) ~= "string" or not str:find(pattern, 1, true) then
    fail(label .. ": expected string containing " .. vim.inspect(pattern) .. " got " .. vim.inspect(str))
  end
end

local function assert_has_focus_actions(label, actions)
  local expected = {
    "focus_editor",
    "focus_result",
    "focus_drawer",
    "focus_call_log",
  }
  for _, key in ipairs(expected) do
    assert_true(label .. "_" .. key, type(actions[key]) == "function")
  end
end

local notifications = {}
local saved_notify = vim.notify

vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = tostring(msg), level = level, opts = opts }
end

local function clear_notifications()
  notifications = {}
end

local function last_notification()
  return notifications[#notifications]
end

local function new_node(fields, children)
  fields = fields or {}
  fields.__children = children or {}
  return fields
end

package.loaded["nui.tree"] = {
  Node = new_node,
}

package.loaded["nui.line"] = function()
  return {
    append = function() end,
  }
end

package.loaded["dbee.ui.common"] = {
  create_blank_buffer = function()
    return vim.api.nvim_create_buf(false, true)
  end,
  configure_buffer_mappings = function() end,
  configure_window_options = function() end,
  float_prompt = function() end,
  float_editor = function() end,
  float_hover = function() return function() end end,
}

package.loaded["dbee.ui.editor.welcome"] = {
  banner = function()
    return { "-- welcome" }
  end,
}

package.loaded["dbee.ui.result.progress"] = {
  display = function()
    return function() end
  end,
}

package.loaded["dbee.ui.drawer.menu"] = {
  select = function() end,
  input = function() end,
}

package.loaded["dbee.ui.drawer.expansion"] = {
  get = function() return {} end,
  restore = function() end,
}

package.loaded["dbee.layouts.tools"] = {
  capture = function() return {} end,
  restore = function() end,
}

local api_ui_stub = {
  editor_search_note_with_file = function() return nil end,
  editor_search_note_with_buf = function() return nil end,
  editor_show = function() end,
  result_show = function() end,
  drawer_show = function() end,
  call_log_show = function() end,
  drawer_prepare_close = function() end,
}
package.loaded["dbee.api.ui"] = api_ui_stub

local current_config = { window_layout = nil }
package.loaded["dbee.api"] = {
  core = {
    is_loaded = function() return true end,
  },
  ui = api_ui_stub,
  setup = function() end,
  current_config = function()
    return current_config
  end,
}

package.loaded["dbee.install"] = {}
package.loaded["dbee.config"] = { default = {} }
package.loaded["dbee.query_splitter"] = {}
package.loaded["dbee.variables"] = {
  resolve_for_execute_async = function(query, _, cb)
    cb(query, nil, nil)
  end,
}

local utils = require("dbee.utils")

vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = tostring(msg), level = level, opts = opts }
end

local layouts = require("dbee.layouts")
local DrawerUI = require("dbee.ui.drawer")
local EditorUI = require("dbee.ui.editor")
local ResultUI = require("dbee.ui.result")
local CallLogUI = require("dbee.ui.call_log")
local dbee = require("dbee")

local original_is_valid = vim.api.nvim_win_is_valid
local original_set_current_win = vim.api.nvim_set_current_win
local valid_windows = {}
local current_win_calls = {}

vim.api.nvim_win_is_valid = function(winid)
  return valid_windows[winid] == true
end

vim.api.nvim_set_current_win = function(winid)
  current_win_calls[#current_win_calls + 1] = winid
end

local function reset_win_tracking()
  valid_windows = {}
  current_win_calls = {}
end

reset_win_tracking()
valid_windows[101] = true
local default_layout = { windows = { editor = 101 } }
assert_true("a1_default_focus_ok", layouts.Default.focus_pane(default_layout, "editor"))
assert_eq("a1_default_focus_call", current_win_calls[1], 101)
print("NAV02_A1_OK=true")

reset_win_tracking()
valid_windows[101] = true
assert_eq("a2_default_missing", layouts.Default.focus_pane(default_layout, "drawer"), false)
assert_eq("a2_default_missing_calls", #current_win_calls, 0)
print("NAV02_A2_OK=true")

assert_true("a3_default_drawer_visible", layouts.Default.ensure_drawer_visible({}))
print("NAV02_A3_OK=true")

reset_win_tracking()
assert_eq("a4_minimal_call_log", layouts.Minimal.focus_pane({ windows = {} }, "call_log"), false)
assert_eq("a4_minimal_call_log_calls", #current_win_calls, 0)
print("NAV02_A4_OK=true")

reset_win_tracking()
valid_windows[303] = true
local toggled = 0
local minimal_for_ensure = {
  drawer_win = nil,
  toggle_drawer = function(self)
    toggled = toggled + 1
    self.drawer_win = 303
  end,
}
assert_true("a5_minimal_ensure_visible", layouts.Minimal.ensure_drawer_visible(minimal_for_ensure))
assert_eq("a5_toggle_called", toggled, 1)
print("NAV02_A5_OK=true")

clear_notifications()
current_config.window_layout = {
  is_open = function() return false end,
  focus_pane = function() return true end,
}
dbee.focus_pane("editor")
assert_match("a6_closed_layout_warn", last_notification().msg, "Dbee is not open")
print("NAV02_A6_OK=true")

clear_notifications()
current_config.window_layout = {
  is_open = function() return true end,
}
dbee.focus_pane("editor")
assert_match("a7_missing_focus_method_warn", last_notification().msg, "Pane jumping is not supported by the current layout")
print("NAV02_A7_OK=true")

local drawer_stub = {
  tree = { get_node = function() return nil end },
  handler = { get_current_connection = function() return nil end },
  editor = {},
  result = {},
  mappings = {},
  pending_generated_calls = {},
  refresh = function() end,
  get_actions = DrawerUI.get_actions,
}
assert_has_focus_actions("a8_drawer_actions", drawer_stub:get_actions())
print("NAV02_A8_OK=true")

local editor_stub = {
  handler = {
    get_current_connection = function() return nil end,
    connection_get_calls = function() return {} end,
  },
  current_note_id = nil,
  _confirm_pending = false,
  get_actions = EditorUI.get_actions,
}
assert_has_focus_actions("a9_editor_actions", editor_stub:get_actions())
print("NAV02_A9_OK=true")

local result_stub = {
  handler = {},
  get_actions = ResultUI.get_actions,
}
assert_has_focus_actions("a10_result_actions", result_stub:get_actions())
print("NAV02_A10_OK=true")

local call_log_stub = {
  tree = { get_node = function() return nil end },
  get_actions = CallLogUI.get_actions,
}
assert_has_focus_actions("a11_call_log_actions", call_log_stub:get_actions())
print("NAV02_A11_OK=true")

clear_notifications()
local drawer_calls = {}
current_config.window_layout = {
  is_open = function() return true end,
  ensure_drawer_visible = function()
    drawer_calls[#drawer_calls + 1] = "ensure_drawer_visible"
    return true
  end,
  focus_pane = function(_, name)
    drawer_calls[#drawer_calls + 1] = "focus_pane:" .. name
    return true
  end,
}
dbee.focus_pane("drawer")
assert_eq("a12_call_count", #drawer_calls, 2)
assert_eq("a12_call_1", drawer_calls[1], "ensure_drawer_visible")
assert_eq("a12_call_2", drawer_calls[2], "focus_pane:drawer")
print("NAV02_A12_OK=true")

clear_notifications()
local missing_ensure_focus_calls = 0
current_config.window_layout = {
  is_open = function() return true end,
  focus_pane = function()
    missing_ensure_focus_calls = missing_ensure_focus_calls + 1
    return true
  end,
}
dbee.focus_pane("drawer")
assert_match("a13_missing_ensure_warn", last_notification().msg, "Drawer is not supported by the current layout")
assert_eq("a13_missing_ensure_focus_calls", missing_ensure_focus_calls, 0)
print("NAV02_A13_OK=true")

clear_notifications()
local rejected_focus_calls = 0
current_config.window_layout = {
  is_open = function() return true end,
  ensure_drawer_visible = function() return false end,
  focus_pane = function()
    rejected_focus_calls = rejected_focus_calls + 1
    return true
  end,
}
dbee.focus_pane("drawer")
assert_match("a14_unavailable_drawer_warn", last_notification().msg, "Drawer is not available in this layout")
assert_eq("a14_unavailable_drawer_focus_calls", rejected_focus_calls, 0)
print("NAV02_A14_OK=true")

clear_notifications()
local invalid_layout_calls = 0
current_config.window_layout = {
  focus_pane = function()
    invalid_layout_calls = invalid_layout_calls + 1
    return true
  end,
}
dbee.focus_pane("result")
assert_match("a15_missing_is_open_warn", last_notification().msg, "Pane jumping is not supported by the current layout")
assert_eq("a15_missing_is_open_calls", invalid_layout_calls, 0)
print("NAV02_A15_OK=true")

vim.api.nvim_win_is_valid = original_is_valid
vim.api.nvim_set_current_win = original_set_current_win
vim.notify = saved_notify

print("NAV02_ALL_PASS=true")
vim.cmd("qa!")
