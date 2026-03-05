-- Headless regression test for cancel-confirm prompt in editor.
--
-- Verifies:
--   1. No active call → immediate execution, no prompt.
--   2. Active call → prompt shown, execution blocked.
--   3. Active call finishes → auto-dismiss fires execution.
--   4. User selects "Yes" → cancel ALL active calls + execute (2 active).
--   5. User selects "No" → no execution.
--   6. Rapid Enter while prompt open → second press ignored, no extra calls.
--   7. Older active call still triggers prompt (non-serialized adapters).
--   8. Two active calls, one finishes → prompt does NOT auto-dismiss.
--      Both finish → auto-dismiss fires.
--   9. Picker .close() called on auto-dismiss when available.
--  10. vim.ui.select throws → notify + fall through to execute.
--  11. Call in "unknown" state triggers prompt (pre-executing race window).
--  12. Synchronous picker.close() triggering on_choice(nil) → exactly one execution.
--  13. Prompt text: singular for 1 active, plural for >1 active.
--  14. Pending guard blocks Enter when call is terminal but event not yet delivered.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=/path/to/nvim-dbee" \
--   -c "luafile ci/headless/check_cancel_confirm_prompt.lua"

local EditorUI = require("dbee.ui.editor")

local function fail(msg)
  print("CANCEL_CONFIRM_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

-- -- Fake handler --
local calls = {}
local event_listeners = {}
local handler = {
  register_event_listener = function(_, event, cb)
    event_listeners[event] = event_listeners[event] or {}
    table.insert(event_listeners[event], cb)
  end,
  get_current_connection = function()
    return { id = "conn_test", type = "generic" }
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
  connection_get_calls = function(_, _)
    -- Return calls in insertion order (oldest first), matching Go handler.
    local copy = {}
    for i = 1, #calls do
      copy[i] = calls[i]
    end
    return copy
  end,
  call_cancel = function(_, id)
    for _, c in ipairs(calls) do
      if c.id == id then
        c.state = "canceled"
      end
    end
    return true
  end,
}

local function fire_event(call)
  local cbs = event_listeners["call_state_changed"] or {}
  for _, cb in ipairs(cbs) do
    pcall(cb, { call = call })
  end
end

-- -- Fake result --
local result = {
  set_call = function() end,
  clear = function() end,
  restore_call = function() end,
}

-- -- Fake vim.ui.select with picker handle --
local select_callback = nil
local select_was_called = false
local picker_close_called = false
local last_select_opts = nil
local orig_select = vim.ui.select
vim.ui.select = function(_, opts, on_choice)
  select_was_called = true
  select_callback = on_choice
  last_select_opts = opts
  -- Return a fake picker with .close() to test hybrid dismiss.
  picker_close_called = false
  return { close = function() picker_close_called = true end }
end

-- -- Create editor --
local tmp_dir = vim.fn.tempname() .. "_dbee_cancel_confirm"
vim.fn.mkdir(tmp_dir, "p")

local editor = EditorUI:new(handler, result, {
  directory = tmp_dir,
  mappings = {},
  buffer_options = {},
  window_options = {},
})

local winid = vim.api.nvim_get_current_win()
editor:show(winid)

local note_id = editor:namespace_create_note("global", "confirm_test")
editor:set_current_note(note_id)

local note = editor:get_current_note()
if not note or not note.bufnr then
  fail("setup_no_note_bufnr")
  return
end
vim.api.nvim_win_set_buf(winid, note.bufnr)
vim.api.nvim_buf_set_lines(note.bufnr, 0, -1, false, { "SELECT 1 FROM dual" })

-- -- Test 1: No active call → immediate execution, no prompt --
select_was_called = false
editor:do_action("run_under_cursor")

if select_was_called then
  fail("t1_prompt_shown_when_no_active_call")
  return
end
if #calls ~= 1 then
  fail("t1_expected_1_call_got_" .. #calls)
  return
end

-- -- Test 2: Active call exists → prompt shown, execution blocked --
select_was_called = false
select_callback = nil
local calls_before = #calls

editor:do_action("run_under_cursor")

if not select_was_called then
  fail("t2_prompt_not_shown")
  return
end
if #calls ~= calls_before then
  fail("t2_execution_not_blocked")
  return
end

-- -- Test 3: Active call finishes → auto-dismiss fires execution --
calls[1].state = "archived"
fire_event(calls[1])

vim.wait(100, function()
  return #calls > calls_before
end, 10)

if #calls ~= calls_before + 1 then
  fail("t3_auto_dismiss_count_" .. #calls .. "_expected_" .. (calls_before + 1))
  return
end

-- -- Test 4: User selects "Yes" → cancel ALL active calls + execute --
-- Set up TWO active calls to prove cancel-all, not just cancel-newest.
calls[#calls].state = "executing"
local extra_active = {
  id = "call_extra_t4",
  query = "SELECT EXTRA",
  state = "executing",
  error = nil,
}
table.insert(calls, extra_active)

select_was_called = false
select_callback = nil
local calls_before_t4 = #calls

editor:do_action("run_under_cursor")

if not select_was_called or not select_callback then
  fail("t4_prompt_not_shown")
  return
end

select_callback("Yes")

vim.wait(100, function()
  return #calls > calls_before_t4
end, 10)

if #calls ~= calls_before_t4 + 1 then
  fail("t4_yes_did_not_execute")
  return
end

-- Both active calls must be canceled.
if calls[calls_before_t4 - 1].state ~= "canceled" then
  fail("t4_first_active_not_canceled_" .. calls[calls_before_t4 - 1].state)
  return
end
if calls[calls_before_t4].state ~= "canceled" then
  fail("t4_second_active_not_canceled_" .. calls[calls_before_t4].state)
  return
end

-- -- Test 5: User selects "No" → no execution --
calls[#calls].state = "executing"
select_was_called = false
select_callback = nil
local calls_before_t5 = #calls

editor:do_action("run_under_cursor")

if not select_was_called or not select_callback then
  fail("t5_prompt_not_shown")
  return
end

select_callback("No")
vim.wait(50, function() return false end, 10)

if #calls ~= calls_before_t5 then
  fail("t5_no_should_not_execute")
  return
end

-- Resolve the pending state so next test can proceed.
calls[#calls].state = "archived"
fire_event(calls[#calls])

-- -- Test 6: Rapid Enter while prompt open → second press ignored, no extra calls --
calls[#calls].state = "executing"
select_was_called = false
select_callback = nil
local calls_before_t6 = #calls
local first_callback = nil

editor:do_action("run_under_cursor")

if not select_was_called then
  fail("t6_first_prompt_not_shown")
  return
end
first_callback = select_callback

-- Second Enter while prompt is open
select_was_called = false
select_callback = nil

editor:do_action("run_under_cursor")

-- Second call should be silently ignored (_confirm_pending guard)
if select_was_called then
  fail("t6_second_prompt_should_not_show")
  return
end
-- No extra calls created by second Enter
if #calls ~= calls_before_t6 then
  fail("t6_second_enter_created_calls_" .. #calls .. "_expected_" .. calls_before_t6)
  return
end

-- Resolve first prompt
if first_callback then
  first_callback("No")
end

-- -- Test 7: Older active call triggers prompt (non-serialized adapter scenario) --
-- Make the newest call terminal, but ensure an older call is still active.
for _, c in ipairs(calls) do
  c.state = "archived"
end
-- Insert an older active call
table.insert(calls, 1, {
  id = "call_old_active",
  query = "SELECT SLEEP(60)",
  state = "executing",
  error = nil,
})

select_was_called = false
select_callback = nil

editor:do_action("run_under_cursor")

if not select_was_called then
  fail("t7_older_active_call_should_trigger_prompt")
  return
end

-- Clean up: resolve the prompt
if select_callback then
  select_callback("No")
end
-- Finish the old active call
calls[1].state = "archived"
fire_event(calls[1])

-- -- Test 8: Two active calls, one finishes → NO auto-dismiss.  Both finish → auto-dismiss. --
-- Reset: create two active calls
for _, c in ipairs(calls) do
  c.state = "archived"
end
local active_a = {
  id = "call_multi_a",
  query = "SELECT 1",
  state = "executing",
  error = nil,
}
local active_b = {
  id = "call_multi_b",
  query = "SELECT 2",
  state = "executing",
  error = nil,
}
table.insert(calls, active_a)
table.insert(calls, active_b)

select_was_called = false
select_callback = nil
local calls_before_t8 = #calls

editor:do_action("run_under_cursor")

if not select_was_called then
  fail("t8_prompt_not_shown_for_multi_active")
  return
end

-- Finish call A only — call B is still active.
active_a.state = "archived"
fire_event(active_a)

vim.wait(50, function() return false end, 10)

-- Should NOT have auto-dismissed: B is still active.
if #calls ~= calls_before_t8 then
  fail("t8_auto_dismissed_with_active_remaining_" .. #calls .. "_expected_" .. calls_before_t8)
  return
end

-- Now finish B — should auto-dismiss.
active_b.state = "archived"
fire_event(active_b)

vim.wait(100, function()
  return #calls > calls_before_t8
end, 10)

if #calls ~= calls_before_t8 + 1 then
  fail("t8_auto_dismiss_after_all_done_" .. #calls .. "_expected_" .. (calls_before_t8 + 1))
  return
end

-- -- Test 9: Picker .close() called on auto-dismiss --
-- Reset: create one active call
for _, c in ipairs(calls) do
  c.state = "archived"
end
local active_close = {
  id = "call_close_test",
  query = "SELECT 3",
  state = "executing",
  error = nil,
}
table.insert(calls, active_close)

select_was_called = false
select_callback = nil
picker_close_called = false

editor:do_action("run_under_cursor")

if not select_was_called then
  fail("t9_prompt_not_shown")
  return
end

-- Finish the call — auto-dismiss should fire and close the picker.
active_close.state = "archived"
fire_event(active_close)

vim.wait(100, function()
  return picker_close_called
end, 10)

if not picker_close_called then
  fail("t9_picker_close_not_called_on_auto_dismiss")
  return
end

-- -- Test 10: vim.ui.select throws → notify + fall through to execute --
for _, c in ipairs(calls) do
  c.state = "archived"
end
-- Re-activate one call so prompt fires.
calls[#calls].state = "executing"

-- Replace vim.ui.select with a throwing version.
local notified_msg = nil
local orig_notify = vim.notify
vim.notify = function(msg, _) notified_msg = msg end
vim.ui.select = function() error("select provider broken") end

local calls_before_t10 = #calls
editor:do_action("run_under_cursor")

vim.wait(100, function()
  return #calls > calls_before_t10
end, 10)

if #calls ~= calls_before_t10 + 1 then
  fail("t10_throw_did_not_fall_through_" .. #calls .. "_expected_" .. (calls_before_t10 + 1))
  vim.notify = orig_notify
  return
end
if not notified_msg or not notified_msg:find("Confirm prompt failed") then
  fail("t10_no_notification_" .. tostring(notified_msg))
  vim.notify = orig_notify
  return
end

vim.notify = orig_notify
-- Restore fake vim.ui.select for remaining tests.
picker_close_called = false
vim.ui.select = function(_, opts, on_choice)
  select_was_called = true
  select_callback = on_choice
  last_select_opts = opts
  picker_close_called = false
  return { close = function() picker_close_called = true end }
end

-- -- Test 11: Call in "unknown" state triggers prompt --
for _, c in ipairs(calls) do
  c.state = "archived"
end
local unknown_call = {
  id = "call_unknown",
  query = "SELECT UNKNOWN",
  state = "unknown",
  error = nil,
}
table.insert(calls, unknown_call)

select_was_called = false
select_callback = nil

editor:do_action("run_under_cursor")

if not select_was_called then
  fail("t11_unknown_state_should_trigger_prompt")
  return
end
-- Resolve the prompt.
unknown_call.state = "archived"
fire_event(unknown_call)
vim.wait(50, function() return false end, 10)

-- -- Test 12: Synchronous picker.close() triggering on_choice(nil) → exactly one execution --
-- This validates the resolve-before-close ordering fix.
-- A picker whose .close() synchronously invokes the stored on_choice(nil).
for _, c in ipairs(calls) do
  c.state = "archived"
end
local sync_active = {
  id = "call_sync_close",
  query = "SELECT SYNC",
  state = "executing",
  error = nil,
}
table.insert(calls, sync_active)

local stored_on_choice = nil
vim.ui.select = function(_, opts, on_choice)
  select_was_called = true
  select_callback = on_choice
  last_select_opts = opts
  stored_on_choice = on_choice
  -- Return a picker whose .close() synchronously triggers on_choice(nil).
  return {
    close = function()
      picker_close_called = true
      if stored_on_choice then
        stored_on_choice(nil) -- simulates synchronous dismiss
      end
    end,
  }
end

select_was_called = false
select_callback = nil
picker_close_called = false
local calls_before_t12 = #calls

editor:do_action("run_under_cursor")

if not select_was_called then
  fail("t12_prompt_not_shown")
  return
end

-- Finish the call → auto-dismiss fires resolve() THEN close().
-- close() triggers on_choice(nil), but resolved=true prevents double action.
sync_active.state = "archived"
fire_event(sync_active)

vim.wait(100, function()
  return #calls > calls_before_t12
end, 10)

if #calls ~= calls_before_t12 + 1 then
  fail("t12_sync_close_race_wrong_count_" .. #calls .. "_expected_" .. (calls_before_t12 + 1))
  return
end

-- Restore normal fake select.
vim.ui.select = function(_, opts, on_choice)
  select_was_called = true
  select_callback = on_choice
  last_select_opts = opts
  picker_close_called = false
  return { close = function() picker_close_called = true end }
end

-- -- Test 13: Prompt text singular for 1 active, plural for >1 active --
for _, c in ipairs(calls) do
  c.state = "archived"
end

-- 13a: Single active → singular prompt
local single_active = {
  id = "call_single_prompt",
  query = "SELECT SINGLE",
  state = "executing",
  error = nil,
}
table.insert(calls, single_active)

select_was_called = false
last_select_opts = nil

editor:do_action("run_under_cursor")

if not select_was_called or not last_select_opts then
  fail("t13a_prompt_not_shown")
  return
end
if not last_select_opts.prompt:find("A query is running") then
  fail("t13a_singular_prompt_wrong_" .. tostring(last_select_opts.prompt))
  return
end
-- Resolve
single_active.state = "archived"
fire_event(single_active)
vim.wait(50, function() return false end, 10)

-- 13b: Two active → plural prompt
for _, c in ipairs(calls) do
  c.state = "archived"
end
local multi_a = {
  id = "call_plural_a",
  query = "SELECT A",
  state = "executing",
  error = nil,
}
local multi_b = {
  id = "call_plural_b",
  query = "SELECT B",
  state = "executing",
  error = nil,
}
table.insert(calls, multi_a)
table.insert(calls, multi_b)

select_was_called = false
last_select_opts = nil

editor:do_action("run_under_cursor")

if not select_was_called or not last_select_opts then
  fail("t13b_prompt_not_shown")
  return
end
if not last_select_opts.prompt:find("2 queries running") then
  fail("t13b_plural_prompt_wrong_" .. tostring(last_select_opts.prompt))
  return
end
-- Resolve
multi_a.state = "archived"
multi_b.state = "archived"
fire_event(multi_a)
vim.wait(50, function() return false end, 10)

-- -- Test 14: Pending guard blocks Enter when call is terminal but event not delivered --
-- Simulates: prompt open → call finishes on Go side (state=archived) but
-- vim.schedule hasn't delivered the event yet → second Enter must be blocked.
for _, c in ipairs(calls) do
  c.state = "archived"
end
local pending_call = {
  id = "call_pending_race",
  query = "SELECT PENDING",
  state = "executing",
  error = nil,
}
table.insert(calls, pending_call)

select_was_called = false
select_callback = nil
local calls_before_t14 = #calls

-- First Enter → prompt opens.
editor:do_action("run_under_cursor")
if not select_was_called then
  fail("t14_first_prompt_not_shown")
  return
end

-- Call goes terminal, but we do NOT fire the event (simulates vim.schedule delay).
pending_call.state = "archived"

-- Second Enter: has_active_call() would return false (all terminal),
-- but _confirm_pending must block it.
select_was_called = false
local calls_before_second = #calls

editor:do_action("run_under_cursor")

if select_was_called then
  fail("t14_second_prompt_should_not_show")
  return
end
if #calls ~= calls_before_second then
  fail("t14_pending_guard_failed_double_execute_" .. #calls .. "_expected_" .. calls_before_second)
  return
end

-- Now deliver the event → auto-dismiss fires exactly one execution.
fire_event(pending_call)

vim.wait(100, function()
  return #calls > calls_before_t14
end, 10)

if #calls ~= calls_before_t14 + 1 then
  fail("t14_auto_dismiss_count_" .. #calls .. "_expected_" .. (calls_before_t14 + 1))
  return
end

-- -- Cleanup --
vim.ui.select = orig_select
vim.fn.delete(tmp_dir, "rf")

print("CANCEL_CONFIRM_ALL_PASS=true")
vim.cmd("qa!")
