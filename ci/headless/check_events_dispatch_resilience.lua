-- Headless regression test for resilient event dispatch.
--
-- Verifies that one failing event listener does not prevent subsequent
-- listeners from running.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=/path/to/nvim-dbee" \
--   -c "luafile ci/headless/check_events_dispatch_resilience.lua"

local events = require("dbee.handler.__events")

local function fail(msg)
  print("EVENTS_DISPATCH_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local notify_calls = {}
local original_notify = vim.notify
vim.notify = function(msg, level, opts)
  notify_calls[#notify_calls + 1] = {
    msg = tostring(msg),
    level = level,
    opts = opts,
  }
end

local callback_count = 0
local seen_state = nil

events.register("call_state_changed", function(_)
  error("boom_listener_one")
end)

events.register("call_state_changed", function(data)
  callback_count = callback_count + 1
  seen_state = data and data.call and data.call.state or nil
end)

events.trigger("call_state_changed", {
  call = {
    id = "call_evt_1",
    state = "retrieving",
  },
})

local ok = vim.wait(1000, function()
  return callback_count == 1
end, 20)

vim.notify = original_notify

if not ok then
  fail("callback_timeout")
  return
end

if seen_state ~= "retrieving" then
  fail("unexpected_state:" .. tostring(seen_state))
  return
end

if #notify_calls < 1 then
  fail("missing_listener_error_notify")
  return
end

local found = false
for _, n in ipairs(notify_calls) do
  if n.msg:find("dbee event listener error %(call_state_changed%)", 1, false) then
    found = true
    break
  end
end
if not found then
  fail("notify_message_mismatch:" .. tostring(notify_calls[1] and notify_calls[1].msg or "nil"))
  return
end

print("EVENTS_DISPATCH_OK=true")
vim.cmd("qa!")
