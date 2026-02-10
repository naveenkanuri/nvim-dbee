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

package.loaded["dbee.api"] = {
  core = {
    get_current_connection = function()
      return conn
    end,
    connection_execute = function(_, query)
      local call = {
        id = "call_" .. tostring(#calls + 1),
        query = query,
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

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(bufnr)
vim.bo[bufnr].filetype = "sql"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "select 1 from dual;",
})
vim.api.nvim_win_set_cursor(0, { 1, 18 })

dbee.actions({ action = "execute" })
if #calls ~= 1 then
  print("ACTIONS_FAIL=execute_count:" .. tostring(#calls))
  vim.cmd("cquit 1")
  return
end

dbee.actions({ action = "execute_script" })
if #calls ~= 2 then
  print("ACTIONS_FAIL=execute_script_count:" .. tostring(#calls))
  vim.cmd("cquit 1")
  return
end

local saved_select = vim.ui.select
vim.ui.select = function(items, _, cb)
  ui_select_called = true
  cb(items[1])
end

package.loaded["snacks"] = nil
dbee.actions()

vim.ui.select = saved_select

if not ui_select_called then
  print("ACTIONS_FAIL=ui_select_not_called")
  vim.cmd("cquit 1")
  return
end

print("ACTIONS_EXECUTE_COUNT=" .. tostring(#calls))

vim.cmd("qa!")
