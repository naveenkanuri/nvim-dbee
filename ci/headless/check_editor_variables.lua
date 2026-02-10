-- Headless regression tests for editor action variable resolution.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=/path/to/nvim-dbee" \
--   -c "luafile ci/headless/check_editor_variables.lua"

local EditorUI = require("dbee.ui.editor")

local function fail(msg)
  print("EDITOR_VARS_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local function wait_until(label, predicate, timeout_ms)
  local ok = vim.wait(timeout_ms or 1000, predicate, 20)
  if ok then
    return true
  end
  fail("timeout_" .. label)
  return false
end

local calls = {}
local saved_call = nil

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
      state = "archived",
      error = nil,
    }
    calls[#calls + 1] = call
    saved_call = call
    return call
  end,
}

local result = {
  set_call = function(_, call)
    saved_call = call
  end,
  clear = function() end,
  restore_call = function() end,
}

local tmp_dir = vim.fn.tempname() .. "_dbee_editor_vars"
vim.fn.mkdir(tmp_dir, "p")

local editor = EditorUI:new(handler, result, {
  directory = tmp_dir,
  mappings = {},
  buffer_options = {},
  window_options = {},
})

local function with_input(fake_input, wait_predicate, fn)
  local saved_ui_input = vim.ui.input
  local saved_snacks_input = package.loaded["snacks.input"]
  vim.ui.input = fake_input
  package.loaded["snacks.input"] = nil
  local ok, err = pcall(fn)
  if ok and wait_predicate then
    ok = vim.wait(1000, wait_predicate, 20)
    if not ok then
      err = "timeout_wait_predicate"
    end
  end
  vim.ui.input = saved_ui_input
  package.loaded["snacks.input"] = saved_snacks_input
  if not ok then
    error(err)
  end
end

-- run_under_cursor should resolve :id using prompt value.
local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(bufnr)
vim.bo[bufnr].filetype = "sql"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "select :id from dual;",
})
vim.api.nvim_win_set_cursor(0, { 1, 15 })

with_input(function(_, cb)
  cb("42")
end, function()
  return #calls == 1
end, function()
  editor:do_action("run_under_cursor")
end)
if not wait_until("run_under_cursor", function()
  return #calls == 1
end) then
  return
end

if #calls ~= 1 then
  fail("run_under_cursor_call_count:" .. tostring(#calls))
  return
end
if calls[1].query ~= "select :id from dual" then
  fail("run_under_cursor_query:" .. tostring(calls[1].query))
  return
end
if not (calls[1].opts and calls[1].opts.binds and calls[1].opts.binds.id == "42") then
  fail("run_under_cursor_bind_opts")
  return
end

-- run_file should resolve &name and preserve statement delimiters in full buffer execution.
editor.winid = vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "select '&name' as v from dual;",
})

with_input(function(_, cb)
  cb("ALICE")
end, function()
  return #calls == 2
end, function()
  editor:do_action("run_file")
end)
if not wait_until("run_file", function()
  return #calls == 2
end) then
  return
end

if #calls ~= 2 then
  fail("run_file_call_count:" .. tostring(#calls))
  return
end
if calls[2].query ~= "select 'ALICE' as v from dual;" then
  fail("run_file_query:" .. tostring(calls[2].query))
  return
end
if calls[2].opts ~= nil and calls[2].opts.binds ~= nil then
  fail("run_file_unexpected_bind_opts")
  return
end

-- canceled prompt should skip execution.
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "select :id from dual;",
})
vim.api.nvim_win_set_cursor(0, { 1, 15 })
local cancel_prompt_seen = false
with_input(function(_, cb)
  cancel_prompt_seen = true
  cb(nil)
end, function()
  return cancel_prompt_seen
end, function()
  editor:do_action("run_under_cursor")
end)
if not wait_until("cancel_no_execution", function()
  return #calls == 2
end) then
  return
end

if #calls ~= 2 then
  fail("cancel_should_not_execute:" .. tostring(#calls))
  return
end

-- empty prompt should also skip execution.
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "select :id from dual;",
})
vim.api.nvim_win_set_cursor(0, { 1, 15 })
local empty_prompt_seen = false
with_input(function(_, cb)
  empty_prompt_seen = true
  cb("")
end, function()
  return empty_prompt_seen
end, function()
  editor:do_action("run_under_cursor")
end)
if not wait_until("empty_input_no_execution", function()
  return #calls == 2
end) then
  return
end
if #calls ~= 2 then
  fail("empty_input_should_not_execute:" .. tostring(#calls))
  return
end

print("EDITOR_VARS_CALLS=" .. tostring(#calls))
print("EDITOR_VARS_LAST_QUERY=" .. tostring(saved_call and saved_call.query or ""))

vim.cmd("qa!")
