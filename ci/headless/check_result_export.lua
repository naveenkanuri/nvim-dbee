-- Headless regression tests for result file export:
--   RSLT-01: Export result to CSV/JSON file
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=$(pwd)" \
--   -c "luafile ci/headless/check_result_export.lua"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function fail(msg)
  print("EXPORT_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local function assert_eq(label, got, expected)
  if got ~= expected then
    fail(label .. ": expected " .. vim.inspect(expected) .. " got " .. vim.inspect(got))
  end
end

local function assert_true(label, val)
  if not val then
    fail(label .. ": expected truthy, got " .. vim.inspect(val))
  end
end

local function assert_match(label, str, pattern)
  if type(str) ~= "string" or not str:find(pattern, 1, true) then
    fail(label .. ": expected string containing " .. vim.inspect(pattern) .. " got " .. vim.inspect(str))
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
-- Stub dependencies before requiring result
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

-- Now require ResultUI
local ResultUI = require("dbee.ui.result")

-- ---------------------------------------------------------------------------
-- Build a stub ResultUI with real get_actions()
-- ---------------------------------------------------------------------------

local store_calls = {}
local store_should_error = false

local stub_handler = {
  register_event_listener = function() end,
  call_store_result = function(self, call_id, format, output, opts)
    if store_should_error then
      error("store error: disk full")
    end
    store_calls[#store_calls + 1] = {
      call_id = call_id,
      format = format,
      output = output,
      opts = opts,
    }
  end,
  call_display_result = function() return 0 end,
}

-- Mock vim.ui.input to auto-provide a path
local mock_input_path = "/tmp/result.csv"
local saved_ui_input = vim.ui.input
vim.ui.input = function(opts, on_confirm)
  on_confirm(mock_input_path)
end

-- Mock vim.fn.filereadable
local mock_filereadable = 0
local saved_filereadable = vim.fn.filereadable
vim.fn.filereadable = function(path)
  return mock_filereadable
end

-- Mock vim.ui.select for overwrite confirmation
local mock_select_choice = "Yes"
local saved_ui_select = vim.ui.select
vim.ui.select = function(items, opts, on_choice)
  on_choice(mock_select_choice)
end

-- Create a ResultUI instance
local result = ResultUI:new(stub_handler, {
  mappings = {},
  page_size = 100,
})

-- Set up state for testing
result.current_call = { id = "test-id" }
result.total_rows = 42

-- Get actions from real code
local actions = result:get_actions()

-- ---------------------------------------------------------------------------
-- B1: export_result with no current_call logs "warn" and returns
-- ---------------------------------------------------------------------------

clear_notifications()
store_calls = {}
result.current_call = nil
actions.export_result()
assert_true("b1_notif_count", #notifications >= 1)
assert_match("b1_notif_msg", notifications[1].msg, "No results to export")
assert_eq("b1_notif_level", notifications[1].level, vim.log.levels.WARN)
assert_eq("b1_no_store_call", #store_calls, 0)

print("EXPORT_B1_NO_CALL_OK=true")

-- ---------------------------------------------------------------------------
-- B2: format inference maps .csv->csv, .json->json
-- ---------------------------------------------------------------------------

-- B2a: CSV
clear_notifications()
store_calls = {}
result.current_call = { id = "test-id" }
result.total_rows = 42
mock_input_path = "/tmp/output.csv"
mock_filereadable = 0
actions.export_result()
assert_eq("b2a_store_count", #store_calls, 1)
assert_eq("b2a_format", store_calls[1].format, "csv")

-- B2b: JSON
clear_notifications()
store_calls = {}
result.current_call = { id = "test-id" }
result.total_rows = 42
mock_input_path = "/tmp/output.json"
mock_filereadable = 0
actions.export_result()
assert_eq("b2b_store_count", #store_calls, 1)
assert_eq("b2b_format", store_calls[1].format, "json")

print("EXPORT_B2_FORMAT_INFER_OK=true")

-- ---------------------------------------------------------------------------
-- B3: unsupported extension (.txt) logs "warn" about unsupported format
-- ---------------------------------------------------------------------------

clear_notifications()
store_calls = {}
result.current_call = { id = "test-id" }
result.total_rows = 42
mock_input_path = "/tmp/output.txt"
mock_filereadable = 0
actions.export_result()
assert_eq("b3_no_store_call", #store_calls, 0)
assert_true("b3_notif_count", #notifications >= 1)
assert_match("b3_notif_msg", notifications[1].msg, "Unsupported format")
assert_match("b3_notif_ext", notifications[1].msg, ".txt")

print("EXPORT_B3_UNSUPPORTED_OK=true")

-- ---------------------------------------------------------------------------
-- B4: export calls handler:call_store_result with correct args
-- ---------------------------------------------------------------------------

clear_notifications()
store_calls = {}
result.current_call = { id = "my-call-42" }
result.total_rows = 100
mock_input_path = "/tmp/data.csv"
mock_filereadable = 0
actions.export_result()
assert_eq("b4_store_count", #store_calls, 1)
assert_eq("b4_call_id", store_calls[1].call_id, "my-call-42")
assert_eq("b4_format", store_calls[1].format, "csv")
assert_eq("b4_output", store_calls[1].output, "file")
assert_eq("b4_extra_arg", store_calls[1].opts.extra_arg, "/tmp/data.csv")

print("EXPORT_B4_ARGS_OK=true")

-- ---------------------------------------------------------------------------
-- B5: success notification includes row count and path
-- ---------------------------------------------------------------------------

clear_notifications()
store_calls = {}
result.current_call = { id = "test-id" }
result.total_rows = 42
mock_input_path = "/tmp/export.json"
mock_filereadable = 0
actions.export_result()
-- Find the success notification
local found_success = false
for _, n in ipairs(notifications) do
  if n.msg and n.msg:find("42", 1, true) and n.msg:find("/tmp/export.json", 1, true) then
    found_success = true
  end
end
assert_true("b5_success_notif", found_success)

print("EXPORT_B5_SUCCESS_NOTIF_OK=true")

-- ---------------------------------------------------------------------------
-- B6: overwrite guard prompts and proceeds on "Yes"
-- ---------------------------------------------------------------------------

clear_notifications()
store_calls = {}
result.current_call = { id = "test-id" }
result.total_rows = 10
mock_input_path = "/tmp/existing.csv"
mock_filereadable = 1
mock_select_choice = "Yes"
actions.export_result()
assert_eq("b6_store_count", #store_calls, 1)

print("EXPORT_B6_OVERWRITE_YES_OK=true")

-- ---------------------------------------------------------------------------
-- B7: overwrite guard aborts on "No"
-- ---------------------------------------------------------------------------

clear_notifications()
store_calls = {}
result.current_call = { id = "test-id" }
result.total_rows = 10
mock_input_path = "/tmp/existing.csv"
mock_filereadable = 1
mock_select_choice = "No"
actions.export_result()
assert_eq("b7_no_store_call", #store_calls, 0)

print("EXPORT_B7_OVERWRITE_NO_OK=true")

-- ---------------------------------------------------------------------------
-- B8: nil path (user pressed Escape) is a no-op
-- ---------------------------------------------------------------------------

clear_notifications()
store_calls = {}
result.current_call = { id = "test-id" }
result.total_rows = 10
mock_input_path = nil
mock_filereadable = 0
actions.export_result()
assert_eq("b8_no_store_call", #store_calls, 0)

print("EXPORT_B8_NIL_PATH_OK=true")

-- ---------------------------------------------------------------------------
-- B9: export error is caught and logged
-- ---------------------------------------------------------------------------

clear_notifications()
store_calls = {}
store_should_error = true
result.current_call = { id = "test-id" }
result.total_rows = 10
mock_input_path = "/tmp/output.csv"
mock_filereadable = 0
actions.export_result()
local found_error = false
for _, n in ipairs(notifications) do
  if n.msg and n.msg:find("Export failed", 1, true) then
    found_error = true
  end
end
assert_true("b9_error_notif", found_error)
store_should_error = false

print("EXPORT_B9_ERROR_OK=true")

-- ---------------------------------------------------------------------------
-- Cleanup and done
-- ---------------------------------------------------------------------------

vim.notify = saved_notify
vim.ui.input = saved_ui_input
vim.ui.select = saved_ui_select

print("EXPORT_ALL_PASS=true")
vim.cmd("qa!")
