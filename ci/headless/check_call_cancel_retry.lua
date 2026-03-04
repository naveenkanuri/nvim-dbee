-- Headless regression tests for stale RPC channel handling in call_cancel.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=/path/to/nvim-dbee" \
--   -c "luafile ci/headless/check_call_cancel_retry.lua"

local function fail(name, got, want)
  print("CALL_CANCEL_RETRY_FAIL=" .. name .. ":" .. tostring(got) .. "!=" .. tostring(want))
  vim.cmd("cquit 1")
end

local function assert_eq(name, got, want)
  if got ~= want then
    fail(name, got, want)
    return false
  end
  return true
end

local register_calls = 0
package.loaded["dbee.api.__register"] = function()
  register_calls = register_calls + 1
end
package.loaded["dbee.handler"] = nil

local Handler = require("dbee.handler")
local handler = Handler:new({})

local original_cancel = vim.fn.DbeeCallCancel

-- Invalid channel should trigger one re-register and retry once.
do
  local cancel_calls = 0
  local cancelled_id = nil
  vim.fn.DbeeCallCancel = function(id)
    cancel_calls = cancel_calls + 1
    if cancel_calls == 1 then
      error("Invalid channel: 4")
    end
    cancelled_id = id
  end

  local ok, err = handler:call_cancel("call_retry")
  if not assert_eq("retry_ok", ok, true) then
    return
  end
  if not assert_eq("retry_err", err, nil) then
    return
  end
  if not assert_eq("register_calls_after_retry", register_calls, 1) then
    return
  end
  if not assert_eq("cancel_calls_after_retry", cancel_calls, 2) then
    return
  end
  if not assert_eq("cancelled_id", cancelled_id, "call_retry") then
    return
  end
end

-- Non-channel errors should not trigger re-register and should return false.
do
  vim.fn.DbeeCallCancel = function()
    error("some other failure")
  end
  local ok, err = handler:call_cancel("call_no_retry")
  if not assert_eq("non_channel_ok", ok, false) then
    return
  end
  if type(err) ~= "string" or not err:find("some other failure", 1, true) then
    fail("non_channel_err_contains", err, "*contains some other failure*")
    return
  end
  if not assert_eq("register_calls_after_non_channel", register_calls, 1) then
    return
  end
end

vim.fn.DbeeCallCancel = original_cancel
print("CALL_CANCEL_RETRY_OK=true")
vim.cmd("qa!")
