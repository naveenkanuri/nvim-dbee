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
  package.loaded["dbee.query_splitter"] = nil
  package.loaded["dbee.variables"] = nil
end

local function make_fake_api(opts)
  opts = opts or {}
  local fail_at_index = opts.fail_at_index
  local hang_at_index = opts.hang_at_index
  local on_poll = opts.on_poll
  local execute_error_at_index = opts.execute_error_at_index
  local no_connection = opts.no_connection
  local cancel_applies_state = opts.cancel_applies_state ~= false

  local conn = { id = "conn_test", type = "oracle" }
  if no_connection then
    conn = nil
  end
  local calls = {}
  local poll_count = {}
  local canceled_ids = {}

  local core = {}
  function core.get_current_connection()
    return conn
  end

  function core.connection_execute(_, query, opts)
    local idx = #calls + 1
    if execute_error_at_index and idx == execute_error_at_index then
      error("execute_boom_" .. tostring(idx))
    end
    local call = {
      id = "call_" .. tostring(idx),
      query = query,
      opts = opts,
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
      if on_poll then
        on_poll({
          index = i,
          call = call,
          poll_count = poll_count[call.id],
        })
      end

      if call.state == "canceled" then
        -- Preserve explicit cancel state set by core.call_cancel.
        call.state = "canceled"
      elseif hang_at_index and i == hang_at_index then
        call.state = "executing"
      elseif poll_count[call.id] >= 1 then
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

  function core.call_cancel(call_id)
    canceled_ids[#canceled_ids + 1] = call_id
    if cancel_applies_state then
      for _, call in ipairs(calls) do
        if call.id == call_id then
          call.state = "canceled"
          return
        end
      end
    end
  end

  local ui = {}
  function ui.result_set_call(_) end

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

  return api, calls, canceled_ids
end

local function run_scenario(name, opts)
  reset_dbee_modules()

  local api, calls, canceled_ids = make_fake_api(opts.api or {})
  package.loaded["dbee.api"] = api
  package.loaded["dbee.install"] = { exec = function() end }
  package.loaded["dbee.config"] = {
    merge_with_default = function(cfg)
      return cfg or {}
    end,
    validate = function() end,
  }

  local dbee = require("dbee")
  if opts.before_run then
    opts.before_run(dbee)
  end

  local executed, err = dbee.execute_script({
    query = opts.script,
    timeout_ms = opts.timeout_ms or 500,
    stop_on_error = opts.stop_on_error ~= false,
  })

  if #executed ~= opts.expected_count then
    print("EXEC_SCRIPT_FAIL=" .. name .. ":count=" .. tostring(#executed))
    vim.cmd("cquit 1")
    return false
  end
  if opts.expected_queries then
    for i, q in ipairs(opts.expected_queries) do
      local got = calls[i] and calls[i].query or nil
      if got ~= q then
        print("EXEC_SCRIPT_FAIL=" .. name .. ":query" .. tostring(i) .. "=" .. tostring(got))
        vim.cmd("cquit 1")
        return false
      end
    end
  end
  if opts.expect_error_contains then
    if type(err) ~= "string" or not err:find(opts.expect_error_contains, 1, true) then
      print("EXEC_SCRIPT_FAIL=" .. name .. ":missing_error:" .. tostring(err))
      vim.cmd("cquit 1")
      return false
    end
  elseif err ~= nil then
    print("EXEC_SCRIPT_FAIL=" .. name .. ":unexpected_error:" .. tostring(err))
    vim.cmd("cquit 1")
    return false
  end
  if opts.expected_canceled_count and #canceled_ids ~= opts.expected_canceled_count then
    print("EXEC_SCRIPT_FAIL=" .. name .. ":canceled_count=" .. tostring(#canceled_ids))
    vim.cmd("cquit 1")
    return false
  end

  print("EXEC_SCRIPT_" .. name .. "_COUNT=" .. tostring(#executed))
  if err then
    print("EXEC_SCRIPT_" .. name .. "_ERROR=" .. err)
  end
  return true
end

local function with_ui_input(fake_input, fn)
  local saved_ui_input = vim.ui.input
  vim.ui.input = fake_input
  local ok, a, b = pcall(fn)
  vim.ui.input = saved_ui_input
  if not ok then
    error(a)
  end
  return a, b
end

local ok0 = run_scenario(
  "MISSING_CONNECTION",
  {
    script = "SELECT 1 FROM dual;",
    api = { no_connection = true },
    expected_count = 0,
    expect_error_contains = "no connection currently selected",
  }
)
if not ok0 then
  return
end

local ok1 = run_scenario(
  "ALL_OK",
  {
    script = table.concat({
      "BEGIN",
      "  DBMS_OUTPUT.PUT_LINE('a');",
      "END;",
      "/",
      "SELECT * FROM dual;",
      "SELECT * FROM dual;",
    }, "\n"),
    expected_count = 3,
    expected_queries = {
      "BEGIN\n  DBMS_OUTPUT.PUT_LINE('a');\nEND;",
      "SELECT * FROM dual;",
      "SELECT * FROM dual;",
    },
  }
)
if not ok1 then
  return
end

local ok2 = run_scenario(
  "STOP_ON_FAIL",
  {
    script = "SELECT 1 FROM dual; SELECT 2 FROM dual; SELECT 3 FROM dual;",
    api = { fail_at_index = 2 },
    expected_count = 2,
    expected_queries = {
      "SELECT 1 FROM dual;",
      "SELECT 2 FROM dual;",
    },
    expect_error_contains = "stopped on state executing_failed",
  }
)
if not ok2 then
  return
end

local ok3 = run_scenario(
  "TIMEOUT_PARTIAL",
  {
    script = "SELECT 1 FROM dual; SELECT 2 FROM dual;",
    api = { hang_at_index = 2 },
    timeout_ms = 120,
    expected_count = 2,
    expected_queries = {
      "SELECT 1 FROM dual;",
      "SELECT 2 FROM dual;",
    },
    expect_error_contains = "timed out",
  }
)
if not ok3 then
  return
end

local ok4 = run_scenario(
  "REENTRANCY_GUARD",
  {
    script = "SELECT 1 FROM dual;",
    api = {
      on_poll = function(ctx)
        if ctx.index == 1 and ctx.poll_count == 1 then
          local inner = require("dbee")
          local _, reentrant_err = inner.execute_script({
            query = "SELECT 99 FROM dual;",
            timeout_ms = 100,
          })
          if not reentrant_err or not reentrant_err:find("already in progress", 1, true) then
            print("EXEC_SCRIPT_FAIL=REENTRANCY_GUARD:missing_reentrant_error:" .. tostring(reentrant_err))
            vim.cmd("cquit 1")
          end
        end
      end,
    },
    expected_count = 1,
    expected_queries = { "SELECT 1 FROM dual;" },
  }
)
if not ok4 then
  return
end

local ok5 = run_scenario(
  "CANCEL",
  {
    script = "SELECT 1 FROM dual;",
    api = {
      hang_at_index = 1,
      on_poll = function(ctx)
        if ctx.poll_count == 1 then
          local inner = require("dbee")
          inner.cancel_script()
        end
      end,
    },
    timeout_ms = 500,
    expected_count = 1,
    expect_error_contains = "canceled",
    expected_canceled_count = 1,
  }
)
if not ok5 then
  return
end

local ok6 = run_scenario(
  "CANCEL_SINGLE_REQUEST",
  {
    script = "SELECT 1 FROM dual;",
    api = {
      hang_at_index = 1,
      cancel_applies_state = false,
      on_poll = function(ctx)
        if ctx.poll_count == 1 then
          local inner = require("dbee")
          inner.cancel_script()
        end
      end,
    },
    timeout_ms = 250,
    expected_count = 1,
    expect_error_contains = "canceled",
    expected_canceled_count = 1,
  }
)
if not ok6 then
  return
end

local function run_variable_prompt_scenario()
  reset_dbee_modules()

  local api, calls = make_fake_api({})
  package.loaded["dbee.api"] = api
  package.loaded["dbee.install"] = { exec = function() end }
  package.loaded["dbee.config"] = {
    merge_with_default = function(cfg)
      return cfg or {}
    end,
    validate = function() end,
  }

  local dbee = require("dbee")
  local prompts = {}
  local answers = { "42", "ALICE" }
  package.loaded["snacks.input"] = nil

  local executed, err = with_ui_input(function(opts, cb)
    prompts[#prompts + 1] = opts.prompt or ""
    cb(answers[#prompts])
  end, function()
    return dbee.execute_script({
      query = "SELECT :id FROM dual; SELECT '&name' FROM dual;",
      timeout_ms = 500,
    })
  end)

  if err ~= nil or #executed ~= 2 then
    print("EXEC_SCRIPT_FAIL=VARIABLE_PROMPT:count_err=" .. tostring(#executed) .. ":" .. tostring(err))
    vim.cmd("cquit 1")
    return false
  end
  if calls[1].query ~= "SELECT :id FROM dual;" or calls[2].query ~= "SELECT 'ALICE' FROM dual;" then
    print("EXEC_SCRIPT_FAIL=VARIABLE_PROMPT:query_values")
    vim.cmd("cquit 1")
    return false
  end
  if not (calls[1].opts and calls[1].opts.binds and calls[1].opts.binds.id == "42") then
    print("EXEC_SCRIPT_FAIL=VARIABLE_PROMPT:bind_values")
    vim.cmd("cquit 1")
    return false
  end
  if calls[2].opts ~= nil and calls[2].opts.binds ~= nil then
    print("EXEC_SCRIPT_FAIL=VARIABLE_PROMPT:unexpected_bind_values")
    vim.cmd("cquit 1")
    return false
  end
  if #prompts ~= 2 then
    print("EXEC_SCRIPT_FAIL=VARIABLE_PROMPT:prompt_count=" .. tostring(#prompts))
    vim.cmd("cquit 1")
    return false
  end
  if not prompts[1]:find("Bind :id", 1, true) or not prompts[2]:find("Substitute &name", 1, true) then
    print("EXEC_SCRIPT_FAIL=VARIABLE_PROMPT:prompt_text")
    vim.cmd("cquit 1")
    return false
  end

  print("EXEC_SCRIPT_VARIABLE_PROMPT_COUNT=2")
  return true
end

if not run_variable_prompt_scenario() then
  return
end

local function run_variable_prompt_unsafe_scenario()
  reset_dbee_modules()

  local api, calls = make_fake_api({})
  package.loaded["dbee.api"] = api
  package.loaded["dbee.install"] = { exec = function() end }
  package.loaded["dbee.config"] = {
    merge_with_default = function(cfg)
      return cfg or {}
    end,
    validate = function() end,
  }

  local dbee = require("dbee")
  package.loaded["snacks.input"] = nil

  local executed, err = with_ui_input(function(_, cb)
    cb("foo; DROP TABLE bar")
  end, function()
    return dbee.execute_script({
      query = "SELECT '&name' FROM dual;\nSELECT 2 FROM dual;",
      timeout_ms = 500,
    })
  end)

  if #executed ~= 0 then
    print("EXEC_SCRIPT_FAIL=VARIABLE_PROMPT_UNSAFE:executed_count=" .. tostring(#executed))
    vim.cmd("cquit 1")
    return false
  end
  if #calls ~= 0 then
    print("EXEC_SCRIPT_FAIL=VARIABLE_PROMPT_UNSAFE:calls_count=" .. tostring(#calls))
    vim.cmd("cquit 1")
    return false
  end
  if type(err) ~= "string" or not err:find("unsafe substitution value", 1, true) then
    print("EXEC_SCRIPT_FAIL=VARIABLE_PROMPT_UNSAFE:error=" .. tostring(err))
    vim.cmd("cquit 1")
    return false
  end

  print("EXEC_SCRIPT_VARIABLE_PROMPT_UNSAFE_COUNT=0")
  return true
end

if not run_variable_prompt_unsafe_scenario() then
  return
end

local function run_variable_prompt_cancel_scenario()
  reset_dbee_modules()

  local api = make_fake_api({})
  package.loaded["dbee.api"] = api
  package.loaded["dbee.install"] = { exec = function() end }
  package.loaded["dbee.config"] = {
    merge_with_default = function(cfg)
      return cfg or {}
    end,
    validate = function() end,
  }

  local dbee = require("dbee")
  package.loaded["snacks.input"] = nil
  local executed, err = with_ui_input(function(_, cb)
    cb(nil)
  end, function()
    return dbee.execute_script({
      query = "SELECT :id FROM dual;",
      timeout_ms = 500,
    })
  end)

  if #executed ~= 0 or type(err) ~= "string" or not err:find("canceled", 1, true) then
    print("EXEC_SCRIPT_FAIL=VARIABLE_PROMPT_CANCEL:" .. tostring(#executed) .. ":" .. tostring(err))
    vim.cmd("cquit 1")
    return false
  end

  print("EXEC_SCRIPT_VARIABLE_PROMPT_CANCEL_COUNT=0")
  return true
end

if not run_variable_prompt_cancel_scenario() then
  return
end

local function run_exception_cleanup_scenario()
  reset_dbee_modules()

  local api = make_fake_api({})
  package.loaded["dbee.api"] = api
  package.loaded["dbee.install"] = { exec = function() end }
  package.loaded["dbee.config"] = {
    merge_with_default = function(cfg)
      return cfg or {}
    end,
    validate = function() end,
  }

  local dbee = require("dbee")
  local original_open = dbee.open
  dbee.open = function()
    error("open_boom")
  end

  local first_calls, first_err = dbee.execute_script({
    query = "SELECT 1 FROM dual;",
    timeout_ms = 100,
  })
  if #first_calls ~= 0 or type(first_err) ~= "string" or not first_err:find("open_boom", 1, true) then
    print("EXEC_SCRIPT_FAIL=EXCEPTION_CLEANUP:first_call=" .. tostring(first_err))
    vim.cmd("cquit 1")
    return false
  end

  dbee.open = original_open

  local second_calls, second_err = dbee.execute_script({
    query = "SELECT 1 FROM dual;",
    timeout_ms = 100,
  })
  if #second_calls ~= 1 or second_err ~= nil then
    print("EXEC_SCRIPT_FAIL=EXCEPTION_CLEANUP:second_call=" .. tostring(second_err))
    vim.cmd("cquit 1")
    return false
  end

  print("EXEC_SCRIPT_EXCEPTION_CLEANUP_COUNT=1")
  return true
end

if not run_exception_cleanup_scenario() then
  return
end

vim.cmd("qa!")
