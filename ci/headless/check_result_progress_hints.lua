-- Headless regression check for result progress slow/stuck hints.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=/path/to/nvim-dbee" \
--   -c "luafile /path/to/nvim-dbee/ci/headless/check_result_progress_hints.lua"

local progress = require("dbee.ui.result.progress")

local function fail(msg)
  print("RESULT_PROGRESS_HINT_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local function run_case(opts)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local stop = progress.display(bufnr, vim.tbl_extend("force", {
    text_prefix = "Executing...",
    spinner = { "." },
    slow_threshold_s = 8,
    stuck_threshold_s = 20,
    slow_hint = "Slow query",
    stuck_hint = "Possibly stuck",
    cancel_hint = "cancel with <C-c> (default)",
  }, opts or {}))

  vim.wait(200)
  local line = (vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or "")
  stop()
  return line
end

local line_fast = run_case({ start_offset = 1 })
local line_slow = run_case({ start_offset = 9 })
local line_stuck = run_case({ start_offset = 21 })
local line_custom = run_case({
  start_offset = 6,
  slow_threshold_s = 2,
  stuck_threshold_s = 4,
  slow_hint = "SLOW",
  stuck_hint = "STUCK",
  cancel_hint = "cancel now",
})
local line_disabled = run_case({
  start_offset = 99,
  slow_threshold_s = 0,
  stuck_threshold_s = 0,
})

if not line_fast:find("Executing...", 1, true) then
  fail("fast_missing_prefix:" .. line_fast)
  return
end
if line_fast:find("Slow query", 1, true) or line_fast:find("Possibly stuck", 1, true) then
  fail("fast_unexpected_hint:" .. line_fast)
  return
end

if not line_slow:find("Slow query", 1, true) or not line_slow:find("cancel with <C-c> (default)", 1, true) then
  fail("slow_missing_hint:" .. line_slow)
  return
end
if line_slow:find("Possibly stuck", 1, true) then
  fail("slow_has_stuck_hint:" .. line_slow)
  return
end

if not line_stuck:find("Possibly stuck", 1, true) or not line_stuck:find("cancel with <C-c> (default)", 1, true) then
  fail("stuck_missing_hint:" .. line_stuck)
  return
end

if not line_custom:find("STUCK", 1, true) or not line_custom:find("cancel now", 1, true) then
  fail("custom_missing_hint:" .. line_custom)
  return
end

if line_disabled:find("Slow query", 1, true) or line_disabled:find("Possibly stuck", 1, true) then
  fail("disabled_has_hint:" .. line_disabled)
  return
end

print("RESULT_PROGRESS_HINT_FAST_OK=true")
print("RESULT_PROGRESS_HINT_SLOW_OK=true")
print("RESULT_PROGRESS_HINT_STUCK_OK=true")
print("RESULT_PROGRESS_HINT_CUSTOM_OK=true")
print("RESULT_PROGRESS_HINT_DISABLED_OK=true")
vim.cmd("qa!")
