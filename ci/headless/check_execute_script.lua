-- Headless regression tests for dbee.execute_script.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=/path/to/nui.nvim" \
--   --cmd "set rtp+=/path/to/nvim-dbee" \
--   -c "luafile ci/headless/check_execute_script.lua"

local function reset_dbee_modules()
  package.loaded["dbee"] = nil
  package.loaded["dbee.api"] = nil
  package.loaded["dbee.config"] = nil
  package.loaded["dbee.install"] = nil
end

local function make_fake_api(fail_at_index)
  local conn = { id = "conn_test", type = "oracle" }
  local calls = {}
  local poll_count = {}
  local shown_calls = {}

  local core = {}
  function core.get_current_connection()
    return conn
  end

  function core.connection_execute(_, query)
    local idx = #calls + 1
    local call = {
      id = "call_" .. tostring(idx),
      query = query,
      state = "executing",
    }
    calls[idx] = call
    poll_count[call.id] = 0
    return call
  end

  function core.connection_get_calls(_)
    local out = {}
    for i, call in ipairs(calls) do
      poll_count[call.id] = (poll_count[call.id] or 0) + 1
      if poll_count[call.id] >= 1 then
        if fail_at_index and i == fail_at_index then
          call.state = "executing_failed"
        else
          call.state = "archived"
        end
      end

      out[#out + 1] = {
        id = call.id,
        query = call.query,
        state = call.state,
      }
    end

    return out
  end

  local ui = {}
  function ui.result_set_call(call)
    shown_calls[#shown_calls + 1] = call.id
  end

  local api = {
    core = core,
    ui = ui,
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

  return api, calls, shown_calls
end

local function run_scenario(name, script, fail_at_index, expected_count, expected_second_query)
  reset_dbee_modules()

  local api, calls = make_fake_api(fail_at_index)
  package.loaded["dbee.api"] = api
  package.loaded["dbee.install"] = { exec = function() end }
  package.loaded["dbee.config"] = {
    merge_with_default = function(cfg)
      return cfg or {}
    end,
    validate = function() end,
  }

  local dbee = require("dbee")
  local executed = dbee.execute_script({
    query = script,
    timeout_ms = 500,
    stop_on_error = true,
  })

  if #executed ~= expected_count then
    print("EXEC_SCRIPT_FAIL=" .. name .. ":count=" .. tostring(#executed))
    vim.cmd("cquit 1")
    return false
  end
  if expected_second_query and calls[2] and calls[2].query ~= expected_second_query then
    print("EXEC_SCRIPT_FAIL=" .. name .. ":query2=" .. tostring(calls[2].query))
    vim.cmd("cquit 1")
    return false
  end

  print("EXEC_SCRIPT_" .. name .. "_COUNT=" .. tostring(#executed))
  return true
end

local ok1 = run_scenario(
  "ALL_OK",
  table.concat({
    "BEGIN",
    "  DBMS_OUTPUT.PUT_LINE('a');",
    "END;",
    "/",
    "SELECT * FROM dual;",
    "SELECT * FROM dual;",
  }, "\n"),
  nil,
  3,
  "SELECT * FROM dual;"
)
if not ok1 then
  return
end

local ok2 = run_scenario(
  "STOP_ON_FAIL",
  "SELECT 1 FROM dual; SELECT 2 FROM dual; SELECT 3 FROM dual;",
  2,
  2,
  "SELECT 2 FROM dual;"
)
if not ok2 then
  return
end

vim.cmd("qa!")
