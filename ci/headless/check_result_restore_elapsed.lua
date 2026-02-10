-- Headless regression check for ResultUI restore elapsed-time handling.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=/path/to/nvim-dbee" \
--   -c "luafile /path/to/nvim-dbee/ci/headless/check_result_restore_elapsed.lua"

local function fail(msg)
  print("RESULT_RESTORE_ELAPSED_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local ResultUI = require("dbee.ui.result")

local fake_handler = {
  register_event_listener = function(_, _, _) end,
  call_display_result = function(_, _, _, _, _)
    return 0
  end,
}

local result = ResultUI:new(fake_handler, {
  progress = {
    spinner = { "." },
    slow_threshold_s = 1,
    stuck_threshold_s = 2,
    slow_hint = "SLOW",
    stuck_hint = "STUCK",
    cancel_hint = "cancel",
  },
})

result:restore_call({
  id = "restore_elapsed_zero_ts",
  query = "select 1",
  state = "executing",
  timestamp_us = 0,
  time_taken_us = 0,
  error = "",
})

vim.wait(150)
local line = vim.api.nvim_buf_get_lines(result.bufnr, 0, 1, false)[1] or ""
if line:find("SLOW", 1, true) or line:find("STUCK", 1, true) then
  fail("unexpected_hint_with_zero_ts:" .. line)
  return
end

result:clear()
print("RESULT_RESTORE_ELAPSED_ZERO_TS_OK=true")
vim.cmd("qa!")
