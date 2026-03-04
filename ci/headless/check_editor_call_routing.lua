-- Headless regression tests for editor call-id routing across notes.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=/path/to/nvim-dbee" \
--   -c "luafile ci/headless/check_editor_call_routing.lua"

local EditorUI = require("dbee.ui.editor")

local function fail(msg)
  print("EDITOR_CALL_ROUTING_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local calls = {}
local handler = {
  register_event_listener = function(_, _, _) end,
  get_current_connection = function()
    return { id = "conn_test", type = "oracle" }
  end,
  connection_execute = function(_, _, query, opts)
    local call = {
      id = "call_" .. tostring(#calls + 1),
      query = query,
      opts = opts,
      state = "executing",
      error = nil,
    }
    calls[#calls + 1] = call
    return call
  end,
}

local result = {
  set_call = function() end,
  clear = function() end,
  restore_call = function() end,
}

local tmp_dir = vim.fn.tempname() .. "_dbee_editor_call_routing"
vim.fn.mkdir(tmp_dir, "p")

local editor = EditorUI:new(handler, result, {
  directory = tmp_dir,
  mappings = {},
  buffer_options = {},
  window_options = {},
})

local winid = vim.api.nvim_get_current_win()
editor:show(winid)

local note1_id = editor:namespace_create_note("global", "routing_one")
local note2_id = editor:namespace_create_note("global", "routing_two")

local function run_note(note_id, lines, cursor)
  editor:set_current_note(note_id)
  local note = editor:get_current_note()
  if not note or not note.bufnr or not vim.api.nvim_buf_is_valid(note.bufnr) then
    fail("invalid_note_bufnr")
    return nil
  end
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_buf(winid, note.bufnr)
  vim.api.nvim_buf_set_lines(note.bufnr, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(winid, cursor)
  editor:do_action("run_under_cursor")
  return note.bufnr
end

local note1_buf = run_note(note1_id, {
  "BEGIN",
  "  INVALID_ONE();",
  "END;",
  "/",
}, { 2, 4 })
if #calls ~= 1 then
  fail("note1_call_count:" .. tostring(#calls))
  return
end
if not calls[1].query:find("END", 1, true) then
  fail("note1_query_missing_end")
  return
end
if calls[1].query:find("/", 1, true) then
  fail("note1_query_contains_slash")
  return
end

local note2_buf = run_note(note2_id, {
  "BEGIN",
  "  INVALID_TWO();",
  "END;",
  "/",
}, { 2, 4 })
if #calls ~= 2 then
  fail("note2_call_count:" .. tostring(#calls))
  return
end

if editor:find_note_for_call(calls[1].id) ~= note1_id then
  fail("call1_note_owner")
  return
end
if editor:find_note_for_call(calls[2].id) ~= note2_id then
  fail("call2_note_owner")
  return
end

-- Call 1 failure should affect note1 only (note2 is currently visible).
vim.api.nvim_set_current_win(winid)
vim.api.nvim_win_set_buf(winid, note2_buf)
vim.api.nvim_win_set_cursor(winid, { 1, 0 })
editor:on_call_state_changed({
  call = {
    id = calls[1].id,
    state = "executing_failed",
    error = "ORA-06550: line 2, column 3:\nPLS-00103: Encountered the symbol \"END\"",
  },
})

local note1_diags = vim.diagnostic.get(note1_buf, { namespace = editor.diag_ns })
local note2_diags = vim.diagnostic.get(note2_buf, { namespace = editor.diag_ns })
if #note1_diags ~= 1 then
  fail("call1_note1_diag_count:" .. tostring(#note1_diags))
  return
end
if #note2_diags ~= 0 then
  fail("call1_note2_diag_count:" .. tostring(#note2_diags))
  return
end
local cursor = vim.api.nvim_win_get_cursor(winid)
if cursor[1] ~= 1 or cursor[2] ~= 0 then
  fail("call1_cursor_should_not_jump:" .. tostring(cursor[1]) .. ":" .. tostring(cursor[2]))
  return
end

-- Unknown call ids must not use any "last exec" fallback or clear unrelated diagnostics.
vim.diagnostic.set(editor.diag_ns, note2_buf, {
  {
    lnum = 0,
    col = 0,
    severity = vim.diagnostic.severity.ERROR,
    message = "stale",
    source = "test",
  },
})
editor:on_call_state_changed({
  call = {
    id = "call_unknown",
    state = "executing_failed",
    error = "ORA-06550: line 2, column 3:\nPLS-00103: Encountered the symbol \"END\"",
  },
})
note2_diags = vim.diagnostic.get(note2_buf, { namespace = editor.diag_ns })
if #note2_diags ~= 1 or note2_diags[1].message ~= "stale" then
  fail("unknown_call_should_not_touch_note2")
  return
end

-- Call 2 failure should affect note2 and jump cursor there.
editor:on_call_state_changed({
  call = {
    id = calls[2].id,
    state = "executing_failed",
    error = "ORA-06550: line 2, column 4:\nPLS-00103: Encountered the symbol \"END\"",
  },
})
note2_diags = vim.diagnostic.get(note2_buf, { namespace = editor.diag_ns })
if #note2_diags ~= 1 then
  fail("call2_note2_diag_count:" .. tostring(#note2_diags))
  return
end
cursor = vim.api.nvim_win_get_cursor(winid)
if cursor[1] ~= note2_diags[1].lnum + 1 or cursor[2] ~= note2_diags[1].col then
  fail("call2_cursor_not_at_diag:" .. tostring(cursor[1]) .. ":" .. tostring(cursor[2]))
  return
end
note1_diags = vim.diagnostic.get(note1_buf, { namespace = editor.diag_ns })
if #note1_diags ~= 1 then
  fail("call2_should_not_clear_note1_diag")
  return
end

-- Archived state should clear diagnostics only for the owning call/note.
editor:on_call_state_changed({
  call = {
    id = calls[2].id,
    state = "archived",
    error = nil,
  },
})
note2_diags = vim.diagnostic.get(note2_buf, { namespace = editor.diag_ns })
if #note2_diags ~= 0 then
  fail("call2_archived_should_clear_note2_diag:" .. tostring(#note2_diags))
  return
end
note1_diags = vim.diagnostic.get(note1_buf, { namespace = editor.diag_ns })
if #note1_diags ~= 1 then
  fail("call2_archived_should_not_clear_note1_diag")
  return
end

-- New call on note2 should replace call-id ownership and ignore stale events from prior call2.
run_note(note2_id, {
  "BEGIN",
  "  INVALID_THREE();",
  "END;",
  "/",
}, { 2, 4 })
if #calls ~= 3 then
  fail("note2_second_call_count:" .. tostring(#calls))
  return
end
if editor:find_note_for_call(calls[2].id) ~= nil then
  fail("stale_call2_should_be_untracked")
  return
end
if editor:find_note_for_call(calls[3].id) ~= note2_id then
  fail("call3_note_owner")
  return
end

vim.diagnostic.set(editor.diag_ns, note2_buf, {
  {
    lnum = 0,
    col = 0,
    severity = vim.diagnostic.severity.ERROR,
    message = "latest_stale",
    source = "test",
  },
})
editor:on_call_state_changed({
  call = {
    id = calls[2].id,
    state = "executing_failed",
    error = "ORA-06550: line 2, column 5",
  },
})
note2_diags = vim.diagnostic.get(note2_buf, { namespace = editor.diag_ns })
if #note2_diags ~= 1 or note2_diags[1].message ~= "latest_stale" then
  fail("stale_call2_event_should_not_apply")
  return
end

print("EDITOR_CALL_ROUTING_OK=true")

vim.cmd("qa!")
