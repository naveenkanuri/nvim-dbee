-- Headless regression tests for note cycling actions:
--   NAV-01: Note cycling within namespace with wrap-around
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=$(pwd)" \
--   -c "luafile ci/headless/check_note_cycling.lua"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function fail(msg)
  print("NAV_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local function assert_eq(label, got, expected)
  if got ~= expected then
    fail(label .. ": expected " .. vim.inspect(expected) .. " got " .. vim.inspect(got))
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
-- Stub dependencies before requiring editor
-- ---------------------------------------------------------------------------

-- Stub common module
package.loaded["dbee.ui.common"] = {
  create_blank_buffer = function()
    return vim.api.nvim_create_buf(false, true)
  end,
  configure_buffer_options = function() end,
  configure_buffer_mappings = function() end,
  configure_window_options = function() end,
}

-- Stub welcome module
package.loaded["dbee.ui.editor.welcome"] = {
  banner = function() return { "-- welcome" } end,
}

-- Stub variables module
package.loaded["dbee.variables"] = {
  resolve_for_execute_async = function(q, opts, cb)
    cb(q, nil, nil)
  end,
}

-- Stub result progress
package.loaded["dbee.ui.result.progress"] = {
  display = function() return function() end end,
}

-- Load utils (real implementation)
local utils = require("dbee.utils")

-- Re-override vim.notify after utils loads
vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = tostring(msg), level = level, opts = opts }
end

-- Now require EditorUI
local EditorUI = require("dbee.ui.editor")

-- ---------------------------------------------------------------------------
-- Build a stub EditorUI-like object with real get_actions()
-- ---------------------------------------------------------------------------

-- We build a minimal object that has the fields get_actions() needs,
-- then call get_actions() to get the real note_next/note_prev closures.

local set_note_calls = {}

-- Notes organized by namespace
local stub_notes = {
  global = {
    ["g1"] = { id = "g1", name = "note1.sql", file = "/tmp/g1.sql" },
    ["g2"] = { id = "g2", name = "note2.sql", file = "/tmp/g2.sql" },
    ["g3"] = { id = "g3", name = "note3.sql", file = "/tmp/g3.sql" },
  },
  conn1 = {
    ["c1"] = { id = "c1", name = "conn_note.sql", file = "/tmp/c1.sql" },
  },
}

-- Build a stub that has the methods note_next/note_prev rely on
local stub = {
  current_note_id = "g1",
  notes = stub_notes,
  handler = {
    get_current_connection = function() return { id = "conn1", type = "postgres" } end,
    connection_get_calls = function() return {} end,
    register_event_listener = function() end,
  },
  result = {
    set_call = function() end,
    clear = function() end,
    restore_call = function() end,
  },
  winid = nil,
  mappings = {},
  note_calls = {},
  note_exec_meta = {},
  call_note_ids = {},
  event_callbacks = {},
  diag_ns = vim.api.nvim_create_namespace("dbee_test"),
  _confirm_pending = false,
}

-- Attach real EditorUI methods to stub
stub.search_note = EditorUI.search_note
stub.namespace_get_notes = EditorUI.namespace_get_notes
stub.get_actions = EditorUI.get_actions
stub.trigger_event = EditorUI.trigger_event
stub.save_last_note = function() end
stub.restore_note_result = EditorUI.restore_note_result
stub.display_note = function() end

-- Override set_current_note to track calls without needing a window
function stub:set_current_note(id)
  set_note_calls[#set_note_calls + 1] = id
  self.current_note_id = id
end

-- Override load_notes_from_disk to prevent actual disk access
function stub:load_notes_from_disk(ns)
  return {}
end

-- Get actions from real code
local actions = stub:get_actions()

-- ---------------------------------------------------------------------------
-- A1: note_next cycles from note 1 to note 2 in a 3-note namespace
-- ---------------------------------------------------------------------------

clear_notifications()
set_note_calls = {}
stub.current_note_id = "g1"
actions.note_next()
assert_eq("a1_next_from_g1", set_note_calls[1], "g2")

print("NAV_A1_NEXT_OK=true")

-- ---------------------------------------------------------------------------
-- A2: note_next wraps from note 3 back to note 1
-- ---------------------------------------------------------------------------

set_note_calls = {}
stub.current_note_id = "g3"
actions.note_next()
assert_eq("a2_wrap_next", set_note_calls[1], "g1")

print("NAV_A2_WRAP_NEXT_OK=true")

-- ---------------------------------------------------------------------------
-- A3: note_prev cycles from note 2 to note 1
-- ---------------------------------------------------------------------------

set_note_calls = {}
stub.current_note_id = "g2"
actions.note_prev()
assert_eq("a3_prev_from_g2", set_note_calls[1], "g1")

print("NAV_A3_PREV_OK=true")

-- ---------------------------------------------------------------------------
-- A4: note_prev wraps from note 1 to note 3
-- ---------------------------------------------------------------------------

set_note_calls = {}
stub.current_note_id = "g1"
actions.note_prev()
assert_eq("a4_wrap_prev", set_note_calls[1], "g3")

print("NAV_A4_WRAP_PREV_OK=true")

-- ---------------------------------------------------------------------------
-- A5: cycling never crosses namespace boundaries
-- ---------------------------------------------------------------------------

set_note_calls = {}
stub.current_note_id = "c1"
actions.note_next()
-- single note in namespace -> no-op (no set_current_note called)
assert_eq("a5_no_cross_namespace", #set_note_calls, 0)

print("NAV_A5_NO_CROSS_OK=true")

-- ---------------------------------------------------------------------------
-- A6: cycling with single note in namespace is a no-op
-- ---------------------------------------------------------------------------

set_note_calls = {}
stub.current_note_id = "c1"
actions.note_prev()
assert_eq("a6_single_note_noop", #set_note_calls, 0)

print("NAV_A6_SINGLE_NOOP_OK=true")

-- ---------------------------------------------------------------------------
-- A7: cycling with no current_note_id is a no-op
-- ---------------------------------------------------------------------------

set_note_calls = {}
stub.current_note_id = nil
actions.note_next()
assert_eq("a7_nil_note_next_noop", #set_note_calls, 0)

set_note_calls = {}
actions.note_prev()
assert_eq("a7_nil_note_prev_noop", #set_note_calls, 0)

print("NAV_A7_NIL_NOOP_OK=true")

-- ---------------------------------------------------------------------------
-- Cleanup and done
-- ---------------------------------------------------------------------------

vim.notify = saved_notify

print("NAV_ALL_PASS=true")
vim.cmd("qa!")
