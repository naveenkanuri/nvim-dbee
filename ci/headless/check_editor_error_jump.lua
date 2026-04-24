-- Headless regression tests for editor diagnostics + cursor jump on Oracle compile/runtime errors.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=/path/to/nvim-dbee" \
--   -c "luafile ci/headless/check_editor_error_jump.lua"

local EditorUI = require("dbee.ui.editor")

local function fail(msg)
  print("EDITOR_ERR_JUMP_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local calls = {}
local current_conn_type = "oracle"
local handler = {
  register_event_listener = function(_, _, _) end,
  get_current_connection = function()
    return { id = "conn_test", type = current_conn_type }
  end,
  connection_execute = function(_, _, query, opts)
    local call = {
      id = "call_" .. tostring(#calls + 1),
      query = query,
      opts = opts,
      state = "executing",
      error = nil,
    }
    calls[#calls + 1] = call
    return call
  end,
}

local result = {
  set_call = function() end,
  clear = function() end,
  restore_call = function() end,
}

local tmp_dir = vim.fn.tempname() .. "_dbee_editor_err_jump"
vim.fn.mkdir(tmp_dir, "p")

local editor = EditorUI:new(handler, result, {
  directory = tmp_dir,
  mappings = {},
  buffer_options = {},
  window_options = {},
})
local diag_ns = editor:get_diag_namespace("conn_test")

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(bufnr)
vim.bo[bufnr].filetype = "sql"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "-- note header",
  "BEGIN",
  "  INVALID_PROCEDURE();",
  "END;",
  "/",
})
vim.api.nvim_win_set_cursor(0, { 3, 5 })

editor:do_action("run_under_cursor")
if #calls ~= 1 then
  fail("execute_call_count:" .. tostring(#calls))
  return
end

-- Move cursor away so we can verify jump actually happened.
vim.api.nvim_win_set_cursor(0, { 1, 0 })

editor:on_call_state_changed({
  call = {
    id = calls[1].id,
    state = "executing_failed",
    error = "ORA-06550: line 3, column 5:\nPLS-00103: Encountered the symbol \"END\"",
  },
})

local cursor = vim.api.nvim_win_get_cursor(0)
local diagnostics = vim.diagnostic.get(bufnr, { namespace = diag_ns })
if #diagnostics ~= 1 then
  fail("diagnostic_count:" .. tostring(#diagnostics))
  return
end
if cursor[1] ~= diagnostics[1].lnum + 1 or cursor[2] ~= diagnostics[1].col then
  fail("cursor_not_at_diag:" .. tostring(cursor[1]) .. ":" .. tostring(cursor[2]))
  return
end
if diagnostics[1].col ~= 4 then
  fail("diagnostic_col:" .. tostring(diagnostics[1].col))
  return
end

-- Successful terminal state should clear stale diagnostics.
editor:on_call_state_changed({
  call = {
    id = calls[1].id,
    state = "archived",
    error = nil,
  },
})
diagnostics = vim.diagnostic.get(bufnr, { namespace = diag_ns })
if #diagnostics ~= 0 then
  fail("archived_should_clear_diag:" .. tostring(#diagnostics))
  return
end

-- Unparseable Oracle errors now fall back to a truthful 1:1 diagnostic.
diag_ns = editor:get_diag_namespace("conn_test")
vim.diagnostic.set(diag_ns, bufnr, {
  {
    lnum = 0,
    col = 0,
    severity = vim.diagnostic.severity.ERROR,
    message = "stale",
    source = "test",
  },
})
editor:on_call_state_changed({
  call = {
    id = calls[1].id,
    state = "executing_failed",
    error = "ORA-00000: generic failure without location",
  },
})
diagnostics = vim.diagnostic.get(bufnr, { namespace = diag_ns })
if #diagnostics ~= 1 then
  fail("unparseable_should_fallback_diag:" .. tostring(#diagnostics))
  return
end
if diagnostics[1].message:find("stale", 1, true) then
  fail("unparseable_should_replace_stale")
  return
end
if diagnostics[1].col ~= 0 then
  fail("unparseable_fallback_col:" .. tostring(diagnostics[1].col))
  return
end

-- Line-only Oracle error should still set diagnostics (defaulting to column 1 -> 0-based col 0).
vim.api.nvim_win_set_cursor(0, { 1, 0 })
editor:on_call_state_changed({
  call = {
    id = calls[1].id,
    state = "executing_failed",
    error = "ORA-06512: at line 4",
  },
})

cursor = vim.api.nvim_win_get_cursor(0)
diagnostics = vim.diagnostic.get(bufnr, { namespace = diag_ns })
if #diagnostics ~= 1 then
  fail("line_only_diag_count:" .. tostring(#diagnostics))
  return
end
if diagnostics[1].col ~= 0 then
  fail("line_only_diag_col:" .. tostring(diagnostics[1].col))
  return
end
if cursor[1] ~= diagnostics[1].lnum + 1 or cursor[2] ~= diagnostics[1].col then
  fail("line_only_cursor_not_at_diag:" .. tostring(cursor[1]) .. ":" .. tostring(cursor[2]))
  return
end

-- Column 0 should clamp to beginning of line without negative offsets.
vim.api.nvim_win_set_cursor(0, { 1, 0 })
editor:on_call_state_changed({
  call = {
    id = calls[1].id,
    state = "executing_failed",
    error = "ORA-06550: line 3, column 0:\nPLS-00103: Encountered the symbol \"END\"",
  },
})
cursor = vim.api.nvim_win_get_cursor(0)
diagnostics = vim.diagnostic.get(bufnr, { namespace = diag_ns })
if #diagnostics ~= 1 then
  fail("col0_diag_count:" .. tostring(#diagnostics))
  return
end
if diagnostics[1].col ~= 0 then
  fail("col0_diag_col:" .. tostring(diagnostics[1].col))
  return
end
if cursor[1] ~= diagnostics[1].lnum + 1 or cursor[2] ~= 0 then
  fail("col0_cursor_not_at_diag:" .. tostring(cursor[1]) .. ":" .. tostring(cursor[2]))
  return
end

-- Out-of-bounds columns should be clamped to line length for both diagnostics and cursor jump.
vim.api.nvim_win_set_cursor(0, { 1, 0 })
editor:on_call_state_changed({
  call = {
    id = calls[1].id,
    state = "executing_failed",
    error = "ORA-06550: line 3, column 999:\nPLS-00103: Encountered the symbol \"END\"",
  },
})

cursor = vim.api.nvim_win_get_cursor(0)
diagnostics = vim.diagnostic.get(bufnr, { namespace = diag_ns })
if #diagnostics ~= 1 then
  fail("clamp_diag_count:" .. tostring(#diagnostics))
  return
end
local diag_line = vim.api.nvim_buf_get_lines(bufnr, diagnostics[1].lnum, diagnostics[1].lnum + 1, false)[1] or ""
local expected_col = #diag_line
if diagnostics[1].col ~= expected_col then
  fail("clamp_diag_col:" .. tostring(diagnostics[1].col) .. ":" .. tostring(expected_col))
  return
end
local expected_cursor_col = math.max(expected_col - 1, 0)
if cursor[1] ~= diagnostics[1].lnum + 1 or cursor[2] ~= expected_cursor_col then
  fail("clamp_cursor_not_at_diag:" .. tostring(cursor[1]) .. ":" .. tostring(cursor[2]) .. ":" .. tostring(expected_cursor_col))
  return
end

-- Non-Oracle SQL calls now use the shared diagnostics framework and fall back truthfully.
current_conn_type = "postgres"
editor:do_action("run_under_cursor")
if #calls ~= 2 then
  fail("non_oracle_execute_call_count:" .. tostring(#calls))
  return
end
diag_ns = editor:get_diag_namespace("conn_test")
vim.diagnostic.set(diag_ns, bufnr, {
  {
    lnum = 0,
    col = 0,
    severity = vim.diagnostic.severity.ERROR,
    message = "stale",
    source = "test",
  },
})
vim.api.nvim_win_set_cursor(0, { 1, 0 })
editor:on_call_state_changed({
  call = {
    id = calls[2].id,
    state = "executing_failed",
    error = "syntax error at line 3, column 5",
  },
})
cursor = vim.api.nvim_win_get_cursor(0)
diagnostics = vim.diagnostic.get(bufnr, { namespace = diag_ns })
if #diagnostics ~= 1 then
  fail("non_oracle_diag_count:" .. tostring(#diagnostics))
  return
end
if not diagnostics[1].message:find("[postgres]", 1, true) then
  fail("non_oracle_fallback_message:" .. tostring(diagnostics[1].message))
  return
end
if cursor[1] ~= diagnostics[1].lnum + 1 or cursor[2] ~= diagnostics[1].col then
  fail("non_oracle_cursor_not_at_diag:" .. tostring(cursor[1]) .. ":" .. tostring(cursor[2]))
  return
end

print("EDITOR_ERR_JUMP_OK=true")

vim.cmd("qa!")
