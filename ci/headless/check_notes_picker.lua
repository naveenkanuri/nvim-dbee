-- Headless validation for Phase 6 NOTES-01.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=$(pwd)" \
--   -c "luafile ci/headless/check_notes_picker.lua"

local function fail(msg)
  print("NOTES01_FAIL=" .. msg)
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

local runtime = {
  layout_open = true,
  ui_loaded = true,
  current_connection = nil,
  global_notes = {},
  local_notes = {},
  set_current_note_calls = {},
  picker_section_calls = 0,
  all_notes_calls = 0,
  picker_calls = {},
}

local editor_stub = {
  namespace_get_notes = function(_, namespace)
    if namespace == "global" then
      return vim.deepcopy(runtime.global_notes)
    end
    if runtime.current_connection and namespace == tostring(runtime.current_connection.id) then
      return vim.deepcopy(runtime.local_notes)
    end
    return {}
  end,
  set_current_note = function(_, note_id)
    runtime.set_current_note_calls[#runtime.set_current_note_calls + 1] = note_id
  end,
}

local handler_stub = {
  get_current_connection = function()
    if not runtime.current_connection then
      return nil
    end
    return vim.deepcopy(runtime.current_connection)
  end,
}

package.loaded["dbee.api.state"] = {
  is_ui_loaded = function()
    return runtime.ui_loaded
  end,
  editor = function()
    return editor_stub
  end,
  handler = function()
    return handler_stub
  end,
}

package.loaded["dbee.api.ui"] = nil
local api_ui = require("dbee.api.ui")
local real_editor_get_note_picker_sections = api_ui.editor_get_note_picker_sections
local real_editor_get_all_notes = api_ui.editor_get_all_notes

api_ui.editor_get_note_picker_sections = function()
  runtime.picker_section_calls = runtime.picker_section_calls + 1
  return real_editor_get_note_picker_sections()
end

api_ui.editor_get_all_notes = function()
  runtime.all_notes_calls = runtime.all_notes_calls + 1
  return real_editor_get_all_notes()
end

local current_config = {
  window_layout = {
    is_open = function()
      return runtime.layout_open
    end,
  },
}

package.loaded["dbee.api"] = {
  core = {
    is_loaded = function()
      return true
    end,
  },
  ui = api_ui,
  setup = function() end,
  current_config = function()
    return current_config
  end,
}

package.loaded["dbee.install"] = { exec = function() end }
package.loaded["dbee.config"] = { default = {} }
package.loaded["dbee.query_splitter"] = {}
package.loaded["dbee.reconnect"] = {}
package.loaded["dbee.variables"] = {
  resolve_for_execute_async = function(query, _, cb)
    cb(query, nil, nil)
  end,
}

package.loaded["snacks"] = {
  picker = function(opts)
    runtime.picker_calls[#runtime.picker_calls + 1] = {
      opts = opts,
    }
    return runtime.picker_calls[#runtime.picker_calls]
  end,
}

package.loaded["dbee"] = nil
local dbee = require("dbee")

local function set_notes(opts)
  opts = opts or {}
  runtime.layout_open = opts.layout_open ~= false
  runtime.ui_loaded = opts.ui_loaded ~= false
  runtime.current_connection = opts.current_connection
  runtime.global_notes = vim.deepcopy(opts.global_notes or {})
  runtime.local_notes = vim.deepcopy(opts.local_notes or {})
  runtime.set_current_note_calls = {}
  runtime.picker_section_calls = 0
  runtime.all_notes_calls = 0
  runtime.picker_calls = {}
  clear_notifications()
end

local function current_picker()
  return runtime.picker_calls[#runtime.picker_calls]
end

local function picker_items()
  local picker = current_picker()
  assert_true("picker_present", picker ~= nil)
  return picker.opts.items
end

local function picker_item_names()
  local names = {}
  for _, item in ipairs(picker_items()) do
    names[#names + 1] = item.text
  end
  return names
end

local function render_chunks(item)
  local picker = current_picker()
  assert_true("picker_for_format", picker ~= nil)
  return picker.opts.format(item)
end

local function render_text(item)
  local chunks = render_chunks(item)
  local parts = {}
  for _, chunk in ipairs(chunks) do
    parts[#parts + 1] = chunk[1]
  end
  return table.concat(parts)
end

local function new_fake_picker()
  return {
    close_calls = 0,
    close = function(self)
      self.close_calls = self.close_calls + 1
    end,
  }
end

local function confirm_with(item)
  local picker = current_picker()
  assert_true("picker_for_confirm", picker ~= nil)
  local fake_picker = new_fake_picker()
  picker.opts.confirm(fake_picker, item)
  return fake_picker
end

local global_note = {
  id = "note-global-1",
  name = "global-note.sql",
  file = "global-note.sql",
}

local local_note = {
  id = "note-local-1",
  name = "local-note.sql",
  file = "local-note.sql",
}

do
  set_notes()
  dbee.pick_notes()
  assert_eq("empty_state_picker_calls", #runtime.picker_calls, 0)
  assert_match("empty_state_info_log", last_notification().msg, "No notes found")
end

do
  set_notes({
    global_notes = { global_note },
  })
  dbee.pick_notes()
  assert_eq("global_only_section_calls", runtime.picker_section_calls, 1)
  assert_eq("global_only_flat_helper_unused", runtime.all_notes_calls, 0)
  local items = picker_items()
  assert_eq("global_only_item_count", #items, 2)
  assert_eq("global_only_header_kind", items[1].kind, "header")
  assert_eq("global_only_header_text", items[1].text, "Global notes")
  assert_eq("global_only_note_kind", items[2].kind, "note")
  assert_match("global_only_tag_text", render_text(items[2]), "[global]")
  print("NOTES01_GLOBAL_ONLY_OK=true")
end

do
  set_notes({
    current_connection = {
      id = "conn-ready",
      name = "Ready Connection",
    },
    global_notes = { global_note },
    local_notes = { local_note },
  })
  local flat_notes = api_ui.editor_get_all_notes()
  assert_eq("flat_helper_count", #flat_notes, 2)
  assert_eq("flat_helper_global_namespace", flat_notes[1].namespace, "global")
  assert_eq("flat_helper_local_namespace", flat_notes[2].namespace, "Ready Connection")
  assert_true("flat_helper_shape_no_kind", flat_notes[1].kind == nil and flat_notes[2].kind == nil)
  print("NOTES01_FLAT_HELPER_COMPAT_OK=true")
end

do
  set_notes({
    current_connection = {
      id = "conn-ready",
      name = "Ready Connection",
    },
    global_notes = { global_note },
    local_notes = { local_note },
  })
  dbee.pick_notes()
  assert_eq("section_order_section_calls", runtime.picker_section_calls, 1)
  assert_eq("section_order_flat_helper_unused", runtime.all_notes_calls, 0)
  assert_eq(
    "section_order_names",
    vim.inspect(picker_item_names()),
    vim.inspect({
      "Global notes",
      "global-note.sql",
      "Local notes (Ready Connection)",
      "local-note.sql",
    })
  )
  local items = picker_items()
  assert_match("tag_global_render", render_text(items[2]), "[global]")
  assert_match("tag_local_render", render_text(items[4]), "[local: Ready Connection]")
  print("NOTES01_SECTION_ORDER_OK=true")
  print("NOTES01_TAGS_OK=true")
end

do
  set_notes({
    current_connection = {
      id = "conn-ready",
      name = "Ready Connection",
    },
    global_notes = { global_note },
    local_notes = {},
  })
  dbee.pick_notes()
  assert_eq(
    "local_empty_items",
    vim.inspect(picker_item_names()),
    vim.inspect({
      "Global notes",
      "global-note.sql",
      "Local notes (Ready Connection)",
      "No local notes for Ready Connection",
    })
  )
  local hint_item = picker_items()[4]
  assert_eq("local_empty_hint_kind", hint_item.kind, "hint")
  assert_match("local_empty_hint_render", render_text(hint_item), "No local notes for Ready Connection")
  print("NOTES01_EMPTY_STATE_OK=true")
end

do
  set_notes({
    current_connection = {
      id = "conn-ready",
      name = "Ready Connection",
    },
    global_notes = { global_note },
    local_notes = { local_note },
  })
  dbee.pick_notes()
  local items = picker_items()

  local header_picker = confirm_with(items[1])
  assert_eq("header_guard_close_calls", header_picker.close_calls, 0)
  assert_eq("header_guard_set_note_calls", #runtime.set_current_note_calls, 0)
  assert_match("header_guard_warn", last_notification().msg, "Select a note row")

  clear_notifications()
  local nil_picker = confirm_with(nil)
  assert_eq("nil_guard_close_calls", nil_picker.close_calls, 0)
  assert_eq("nil_guard_set_note_calls", #runtime.set_current_note_calls, 0)
  assert_match("nil_guard_warn", last_notification().msg, "Select a note row")

  clear_notifications()
  local malformed_picker = confirm_with({
    kind = "note",
    text = "broken-note",
  })
  assert_eq("malformed_guard_close_calls", malformed_picker.close_calls, 0)
  assert_eq("malformed_guard_set_note_calls", #runtime.set_current_note_calls, 0)
  assert_match("malformed_guard_warn", last_notification().msg, "Select a note row")

  clear_notifications()
  set_notes({
    current_connection = {
      id = "conn-ready",
      name = "Ready Connection",
    },
    global_notes = { global_note },
    local_notes = {},
  })
  dbee.pick_notes()
  local hint_picker = confirm_with(picker_items()[4])
  assert_eq("hint_guard_close_calls", hint_picker.close_calls, 0)
  assert_eq("hint_guard_set_note_calls", #runtime.set_current_note_calls, 0)
  assert_match("hint_guard_warn", last_notification().msg, "Select a note row")

  clear_notifications()
  set_notes({
    current_connection = {
      id = "conn-ready",
      name = "Ready Connection",
    },
    global_notes = { global_note },
    local_notes = { local_note },
  })
  dbee.pick_notes()
  local note_picker = confirm_with(picker_items()[2])
  assert_eq("note_confirm_close_calls", note_picker.close_calls, 1)
  assert_eq("note_confirm_set_note_calls", #runtime.set_current_note_calls, 1)
  assert_eq("note_confirm_note_id", runtime.set_current_note_calls[1], global_note.id)
  print("NOTES01_HEADER_GUARD_OK=true")
end

do
  set_notes({
    current_connection = {
      id = "conn-ready",
      name = "Ready Connection",
    },
    global_notes = {},
    local_notes = { local_note },
  })
  dbee.pick_notes()
  local items = picker_items()
  assert_eq("local_only_item_count", #items, 2)
  assert_eq("local_only_first_header", items[1].text, "Local notes (Ready Connection)")
  assert_true("local_only_no_global_header", items[1].text ~= "Global notes")
  assert_match("local_only_tag", render_text(items[2]), "[local: Ready Connection]")
  print("NOTES01_LOCAL_ONLY_OK=true")
end

do
  set_notes({
    current_connection = {
      id = "conn-ready",
      name = "Ready Connection",
    },
    global_notes = { global_note },
    local_notes = { local_note },
  })
  dbee.pick_notes()
  assert_eq("snapshot_single_open", runtime.picker_section_calls, 1)
  local item = picker_items()[2]
  local fake_picker = confirm_with(item)
  assert_eq("snapshot_confirm_closes_note", fake_picker.close_calls, 1)
  assert_eq("snapshot_no_refetch_on_confirm", runtime.picker_section_calls, 1)
  dbee.pick_notes()
  assert_eq("snapshot_second_open_refetches_once", runtime.picker_section_calls, 2)
  print("NOTES01_SNAPSHOT_OK=true")
end

print("NOTES01_ALL_PASS=true")
vim.notify = saved_notify
vim.cmd("qa!")
