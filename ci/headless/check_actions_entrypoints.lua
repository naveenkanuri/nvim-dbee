-- Headless regression tests for dbee.actions entrypoints.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=/path/to/nui.nvim" \
--   --cmd "set rtp+=/path/to/nvim-dbee" \
--   -c "luafile ci/headless/check_actions_entrypoints.lua"

package.loaded["dbee"] = nil
package.loaded["dbee.api"] = nil
package.loaded["dbee.config"] = nil
package.loaded["dbee.install"] = nil

local conn = { id = "conn_test", type = "oracle" }
local calls = {}
local poll_count = {}
local ui_select_called = false
local ui_input_calls = 0
local core_loaded = true
local notifications = {}

package.loaded["dbee.api"] = {
  core = {
    is_loaded = function()
      return core_loaded
    end,
    get_current_connection = function()
      if not core_loaded then
        error("core not loaded")
      end
      return conn
    end,
    connection_execute = function(_, query, opts)
      local call = {
        id = "call_" .. tostring(#calls + 1),
        query = query,
        opts = opts,
        state = "executing",
      }
      calls[#calls + 1] = call
      poll_count[call.id] = 0
      return call
    end,
    connection_get_calls = function()
      local out = {}
      for _, call in ipairs(calls) do
        poll_count[call.id] = (poll_count[call.id] or 0) + 1
        if poll_count[call.id] >= 1 then
          call.state = "archived"
        end
        out[#out + 1] = { id = call.id, query = call.query, state = call.state }
      end
      return out
    end,
  },
  ui = {
    result_set_call = function() end,
  },
  setup = function() end,
  current_config = function()
    return {
      window_layout = {
        is_open = function()
          return false
        end,
        open = function() end,
        close = function() end,
        reset = function() end,
        toggle_drawer = function() end,
      },
    }
  end,
}

package.loaded["dbee.install"] = { exec = function() end }
package.loaded["dbee.config"] = {
  merge_with_default = function(cfg)
    return cfg or {}
  end,
  validate = function() end,
}

local dbee = require("dbee")

local function fail(msg)
  print("ACTIONS_FAIL=" .. msg)
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

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(bufnr)
vim.bo[bufnr].filetype = "sql"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "select :id from dual;",
})
vim.api.nvim_win_set_cursor(0, { 1, 18 })

local saved_input = vim.ui.input
vim.ui.input = function(_, cb)
  ui_input_calls = ui_input_calls + 1
  cb("1")
end
local saved_notify = vim.notify
vim.notify = function(msg, level)
  notifications[#notifications + 1] = {
    msg = tostring(msg),
    level = level,
  }
end

dbee.actions({ action = "execute" })
if not wait_until("execute_call", function()
  return #calls == 1
end) then
  return
end
if #calls ~= 1 then
  fail("execute_count:" .. tostring(#calls))
  return
end
if calls[1].query ~= "select :id from dual" then
  fail("execute_query:" .. tostring(calls[1].query))
  return
end
if not (calls[1].opts and calls[1].opts.binds and calls[1].opts.binds.id == "1") then
  fail("execute_bind_opts")
  return
end
if ui_input_calls ~= 1 then
  fail("execute_prompt_count:" .. tostring(ui_input_calls))
  return
end

dbee.actions({ action = "execute_script" })
if #calls ~= 2 then
  fail("execute_script_count:" .. tostring(#calls))
  return
end
if calls[2].query ~= "select :id from dual;" then
  fail("execute_script_query:" .. tostring(calls[2].query))
  return
end
if not (calls[2].opts and calls[2].opts.binds and calls[2].opts.binds.id == "1") then
  fail("execute_script_bind_opts")
  return
end
if ui_input_calls ~= 2 then
  fail("execute_script_prompt_count:" .. tostring(ui_input_calls))
  return
end

local _, direct_err = dbee.execute("select :id from dual;")
if direct_err ~= nil then
  fail("direct_execute_err:" .. tostring(direct_err))
  return
end
if #calls ~= 3 then
  fail("direct_execute_count:" .. tostring(#calls))
  return
end
if calls[3].query ~= "select :id from dual;" then
  fail("direct_execute_query:" .. tostring(calls[3].query))
  return
end
if not (calls[3].opts and calls[3].opts.binds and calls[3].opts.binds.id == "1") then
  fail("direct_execute_bind_opts")
  return
end
if ui_input_calls ~= 3 then
  fail("direct_execute_prompt_count:" .. tostring(ui_input_calls))
  return
end

local saved_select = vim.ui.select
vim.ui.select = function(_, _, cb)
  ui_select_called = true
  cb(nil)
end

package.loaded["snacks"] = nil
dbee.actions()

local calls_before_unloaded = #calls
core_loaded = false
dbee.actions({ action = "execute" })
dbee.actions({ action = "execute_script" })
local _, unloaded_exec_err = dbee.execute("select 1;")
if unloaded_exec_err ~= "dbee core not loaded" then
  fail("unloaded_execute_err:" .. tostring(unloaded_exec_err))
  return
end
if #calls ~= calls_before_unloaded then
  fail("unloaded_execute_dispatched")
  return
end

local unloaded_notice_count = 0
for _, note in ipairs(notifications) do
  if note.msg:find("dbee core not loaded", 1, true) then
    unloaded_notice_count = unloaded_notice_count + 1
  end
end
if unloaded_notice_count < 2 then
  fail("unloaded_notice_count:" .. tostring(unloaded_notice_count))
  return
end

core_loaded = true
local saved_exec = package.loaded["dbee.api"].core.connection_execute
local saved_result_set = package.loaded["dbee.api"].ui.result_set_call

package.loaded["dbee.api"].core.connection_execute = function()
  error("boom_execute")
end
local _, exec_fail_err = dbee.execute("select 1;")
if type(exec_fail_err) ~= "string" or not exec_fail_err:find("failed to execute query", 1, true) then
  fail("direct_execute_error_path:" .. tostring(exec_fail_err))
  return
end

package.loaded["dbee.api"].core.connection_execute = function()
  return nil
end
local _, nil_call_err = dbee.execute("select 1;")
if nil_call_err ~= "query execution returned no call details" then
  fail("direct_execute_nil_call_path:" .. tostring(nil_call_err))
  return
end

package.loaded["dbee.api"].core.connection_execute = saved_exec
package.loaded["dbee.api"].ui.result_set_call = function()
  error("boom_result_set")
end
local _, result_set_err = dbee.execute("select 1;")
if type(result_set_err) ~= "string" or not result_set_err:find("failed to set result call", 1, true) then
  fail("direct_execute_result_set_path:" .. tostring(result_set_err))
  return
end

package.loaded["dbee.api"].ui.result_set_call = saved_result_set

vim.ui.select = saved_select
vim.ui.input = saved_input
vim.notify = saved_notify

if not ui_select_called then
  fail("ui_select_not_called")
  return
end

print("ACTIONS_EXECUTE_COUNT=" .. tostring(#calls))

vim.cmd("qa!")
