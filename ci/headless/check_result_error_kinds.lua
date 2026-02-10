-- Headless regression check for result status messages by call error kind.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=/path/to/nvim-dbee" \
--   -c "luafile /path/to/nvim-dbee/ci/headless/check_result_error_kinds.lua"

local function fail(msg)
  print("RESULT_ERROR_KIND_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local ResultUI = require("dbee.ui.result")

local fake_handler = {
  register_event_listener = function(_, _, _) end,
  call_display_result = function(_, _, _, _, _)
    return 0
  end,
}

local result = ResultUI:new(fake_handler, {})

local function assert_status(name, call, expected_prefix)
  result.current_call = vim.tbl_extend("force", {
    id = name,
    query = "SELECT 1",
    state = "executing_failed",
    time_taken_us = 1230000,
    timestamp_us = 0,
    error = "",
  }, call)

  result:display_status()
  local line = vim.api.nvim_buf_get_lines(result.bufnr, 0, 1, false)[1] or ""
  if not line:find(expected_prefix, 1, true) then
    fail(name .. ":line=" .. line)
    return false
  end
  return true
end

if not assert_status("EXEC_DISC", {
  state = "executing_failed",
  error_kind = "disconnected",
  error = "dial tcp: lookup db.internal: no such host",
}, "Call failed: connection lost after ") then
  return
end

if not assert_status("EXEC_TIMEOUT", {
  state = "executing_failed",
  error_kind = "timeout",
  error = "context deadline exceeded",
}, "Call timed out after ") then
  return
end

if not assert_status("RETR_DISC", {
  state = "retrieving_failed",
  error_kind = "disconnected",
  error = "driver: bad connection",
}, "Result retrieval failed: connection lost after ") then
  return
end

if not assert_status("RETR_TIMEOUT", {
  state = "retrieving_failed",
  error_kind = "timeout",
  error = "next row timeout",
}, "Result retrieval timed out after ") then
  return
end

if not assert_status("RETR_UNKNOWN", {
  state = "retrieving_failed",
  error_kind = "unknown",
  error = "something odd",
}, "Failed retrieving results after ") then
  return
end

if not assert_status("ARCHIVE_UNKNOWN", {
  state = "archive_failed",
  error_kind = "unknown",
  error = "archive write failed",
}, "Failed archiving results after ") then
  return
end

if not assert_status("EXEC_CANCELED_KIND", {
  state = "executing_failed",
  error_kind = "canceled",
  error = "ORA-01013: user requested cancel of current operation",
}, "Call canceled after ") then
  return
end

if not assert_status("CANCELED_STATE", {
  state = "canceled",
  error_kind = "unknown",
  error = "",
}, "Call canceled after ") then
  return
end

if not assert_status("EXEC_UNKNOWN", {
  state = "executing_failed",
  error_kind = "unknown",
  error = "query failed",
}, "Call execution failed after ") then
  return
end

print("RESULT_ERROR_KIND_EXEC_DISC=true")
print("RESULT_ERROR_KIND_EXEC_TIMEOUT=true")
print("RESULT_ERROR_KIND_RETR_DISC=true")
print("RESULT_ERROR_KIND_RETR_TIMEOUT=true")
print("RESULT_ERROR_KIND_RETR_UNKNOWN=true")
print("RESULT_ERROR_KIND_ARCHIVE_UNKNOWN=true")
print("RESULT_ERROR_KIND_EXEC_CANCELED_KIND=true")
print("RESULT_ERROR_KIND_CANCELED_STATE=true")
print("RESULT_ERROR_KIND_EXEC_UNKNOWN=true")

vim.cmd("qa!")
