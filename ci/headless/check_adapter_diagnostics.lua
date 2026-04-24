-- Headless regression tests for Phase 05 adapter diagnostics.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=/path/to/nvim-dbee" \
--   -c "luafile ci/headless/check_adapter_diagnostics.lua"

local reconnect_listeners = {}
local reconnect_registered = {}
local forgotten_calls = {}
local current_conn = { id = "conn_oracle", name = "conn_oracle", type = "oracle" }
local executed_calls = {}

package.loaded["dbee.reconnect"] = {
  register_connection_rewritten_listener = function(key, listener)
    if reconnect_registered[key] then
      error(("duplicate reconnect rewrite listener: %s"):format(key))
    end
    reconnect_registered[key] = true
    reconnect_listeners[key] = listener
  end,
  register_call = function() end,
  forget_call = function(call_id)
    forgotten_calls[#forgotten_calls + 1] = call_id
  end,
  _emit_rewrite = function(old_conn_id, new_conn_id)
    for _, listener in pairs(reconnect_listeners) do
      listener(old_conn_id, new_conn_id)
    end
  end,
}

local diagnostics = require("dbee.ui.editor.diagnostics")
local EditorUI = require("dbee.ui.editor")

local function fail(msg)
  print("ADPT02_FAIL=" .. tostring(msg))
  vim.cmd("cquit 1")
end

local function assert_true(name, value)
  if not value then
    fail(name .. ":" .. vim.inspect(value))
  end
end

local function assert_eq(name, got, want)
  if got ~= want then
    fail(name .. ":" .. vim.inspect(got) .. "!=" .. vim.inspect(want))
  end
end

local function flush_scheduled()
  local drained = false
  vim.schedule(function()
    drained = true
  end)
  local ok = vim.wait(200, function()
    return drained
  end, 10)
  if not ok then
    fail("schedule_flush_timeout")
  end
end

local handler = {
  register_event_listener = function() end,
  get_current_connection = function()
    return current_conn
  end,
  connection_execute = function(_, _, query, opts)
    local call = {
      id = "exec_" .. tostring(#executed_calls + 1),
      query = query,
      opts = opts,
      state = "executing",
      time_taken_us = 0,
      timestamp_us = #executed_calls + 1,
      error = nil,
    }
    executed_calls[#executed_calls + 1] = call
    return call
  end,
  connection_get_calls = function()
    return {}
  end,
}

local result = {
  set_call = function() end,
  clear = function() end,
  restore_call = function() end,
}

local tmp_dir = vim.fn.tempname() .. "_dbee_adapter_diag"
vim.fn.mkdir(tmp_dir, "p")

local editor = EditorUI:new(handler, result, {
  directory = tmp_dir,
  mappings = {},
  buffer_options = {},
  window_options = {},
})

local winid = vim.api.nvim_get_current_win()
editor:show(winid)

local function set_buffer_lines(bufnr, lines)
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_buf(winid, bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

local function create_note(name, lines)
  local note_id = editor:namespace_create_note("global", name)
  editor:set_current_note(note_id)
  local note = editor:get_current_note()
  if not note or not note.bufnr or not vim.api.nvim_buf_is_valid(note.bufnr) then
    fail("invalid_note:" .. tostring(name))
  end
  set_buffer_lines(note.bufnr, lines)
  return note_id, note.bufnr
end

local function attach_call(note_id, bufnr, call_id, conn, resolved_query, start_line, start_col)
  local call = {
    id = call_id,
    query = resolved_query,
    state = "executing",
    time_taken_us = 0,
    timestamp_us = 0,
    error = nil,
  }
  editor:set_result_for_note(note_id, call, bufnr, start_line, start_col, conn.id, conn.name, conn.type, resolved_query)
  return call
end

local function emit(call_id, state, err, err_kind)
  editor:on_call_state_changed({
    call = {
      id = call_id,
      state = state,
      error = err,
      error_kind = err_kind or "unknown",
    },
  })
  flush_scheduled()
end

local function get_diags(conn_id, bufnr)
  return vim.diagnostic.get(bufnr, { namespace = editor:get_diag_namespace(conn_id) })
end

local function clear_conn_diags(conn_id, bufnr)
  vim.diagnostic.reset(editor:get_diag_namespace(conn_id), bufnr)
end

local oracle_conn = { id = "conn_oracle", name = "conn_oracle", type = "oracle" }
local pg_alias_conn = { id = "conn_pg_alias", name = "conn_pg_alias", type = "postgresql" }
local pg_mid_conn = { id = "conn_pg_mid", name = "conn_pg_mid", type = "postgres" }
local mysql_conn = { id = "conn_mysql", name = "conn_mysql", type = "mysql" }
local sqlite_conn = { id = "conn_sqlite", name = "conn_sqlite", type = "sqlite" }
local click_conn = { id = "conn_click", name = "conn_click", type = "clickhouse" }
local mongo_conn = { id = "conn_mongo", name = "conn_mongo", type = "mongo" }
local rewrite_old_conn = { id = "conn_old", name = "conn_old", type = "postgres" }
local rewrite_new_conn = { id = "conn_new", name = "conn_new", type = "postgres" }
local other_conn = { id = "conn_other", name = "conn_other", type = "postgres" }

local oracle_calls = 0
local original_build_diagnostic = diagnostics.build_diagnostic
diagnostics.build_diagnostic = function(adapter, err_msg, ctx)
  if tostring(adapter):lower() == "oracle" then
    oracle_calls = oracle_calls + 1
  end
  return original_build_diagnostic(adapter, err_msg, ctx)
end

local oracle_note_id, oracle_buf = create_note("oracle_diag", {
  "BEGIN",
  "  INVALID_PROCEDURE();",
  "END;",
  "/",
})
local oracle_call = attach_call(oracle_note_id, oracle_buf, "oracle_call", oracle_conn, "BEGIN\n  INVALID_PROCEDURE();\nEND", 0, 0)
vim.api.nvim_win_set_cursor(winid, { 1, 0 })
emit(oracle_call.id, "executing_failed", "ORA-06550: line 2, column 5:\nPLS-00103: Encountered the symbol \"END\"")

local oracle_diags = get_diags(oracle_conn.id, oracle_buf)
if #oracle_diags ~= 1 then
  fail("oracle_diag_count:" .. tostring(#oracle_diags))
end
assert_eq("oracle_diag_col", oracle_diags[1].col, 4)
local oracle_cursor = vim.api.nvim_win_get_cursor(winid)
assert_eq("oracle_cursor_row", oracle_cursor[1], oracle_diags[1].lnum + 1)
assert_eq("oracle_cursor_col", oracle_cursor[2], oracle_diags[1].col)
assert_eq("oracle_parser_path_calls", oracle_calls, 1)
emit(oracle_call.id, "archived", nil)
assert_eq("oracle_archived_clears", #get_diags(oracle_conn.id, oracle_buf), 0)

print("ADPT02_ORACLE_OK=true")

local pg_alias_note_id, pg_alias_buf = create_note("postgres_alias_diag", {
  "-- ignore",
  "-- ignore",
  "SELECT 1",
  "FROMM users",
})
local pg_alias_call = attach_call(
  pg_alias_note_id,
  pg_alias_buf,
  "pg_alias_call",
  pg_alias_conn,
  "SELECT 1\nFROMM users",
  2,
  0
)
emit(pg_alias_call.id, "executing_failed", 'pq: syntax error at or near "FROMM" (SQLSTATE 42601) POSITION: 10')
local pg_alias_diags = get_diags(pg_alias_conn.id, pg_alias_buf)
if #pg_alias_diags ~= 1 then
  fail("pg_alias_diag_count:" .. tostring(#pg_alias_diags))
end
assert_eq("pg_alias_lnum", pg_alias_diags[1].lnum, 3)
assert_eq("pg_alias_col", pg_alias_diags[1].col, 0)

local pg_mid_note_id, pg_mid_buf = create_note("postgres_midline_diag", {
  "    SELECT FROMM users;",
})
local pg_mid_call = attach_call(
  pg_mid_note_id,
  pg_mid_buf,
  "pg_mid_call",
  pg_mid_conn,
  "SELECT FROMM users",
  0,
  4
)
emit(pg_mid_call.id, "executing_failed", 'pq: syntax error at or near "FROMM" (SQLSTATE 42601) POSITION: 10')
local pg_mid_diags = get_diags(pg_mid_conn.id, pg_mid_buf)
if #pg_mid_diags ~= 1 then
  fail("pg_mid_diag_count:" .. tostring(#pg_mid_diags))
end
assert_eq("pg_mid_col", pg_mid_diags[1].col, 13)

local pg_multi_note_id, pg_multi_buf = create_note("postgres_multiline_diag", {
  "    SELECT 1",
  "FROMM users",
})
local pg_multi_call = attach_call(
  pg_multi_note_id,
  pg_multi_buf,
  "pg_multi_call",
  pg_mid_conn,
  "SELECT 1\nFROMM users",
  0,
  4
)
emit(pg_multi_call.id, "executing_failed", 'pq: syntax error at or near "FROMM" (SQLSTATE 42601) POSITION: 10')
local pg_multi_diags = get_diags(pg_mid_conn.id, pg_multi_buf)
if #pg_multi_diags ~= 1 then
  fail("pg_multi_diag_count:" .. tostring(#pg_multi_diags))
end
assert_eq("pg_multi_lnum", pg_multi_diags[1].lnum, 1)
assert_eq("pg_multi_col", pg_multi_diags[1].col, 0)

local mysql_note_id, mysql_buf = create_note("mysql_diag", {
  "SELECT 1;",
  "FROMM users;",
})
local mysql_call = attach_call(mysql_note_id, mysql_buf, "mysql_call", mysql_conn, "SELECT 1;\nFROMM users;", 0, 0)
emit(mysql_call.id, "executing_failed", "Error 1064 (42000): You have an error in your SQL syntax; check the manual that corresponds to your MySQL server version for the right syntax to use near 'FROMM users' at line 2")
local mysql_diags = get_diags(mysql_conn.id, mysql_buf)
if #mysql_diags ~= 1 then
  fail("mysql_diag_count:" .. tostring(#mysql_diags))
end
assert_eq("mysql_line", mysql_diags[1].lnum, 1)
assert_eq("mysql_col", mysql_diags[1].col, 0)

local sqlite_note_id, sqlite_buf = create_note("sqlite_diag", {
  "    SELECT * FROMM users;",
})
local sqlite_call = attach_call(sqlite_note_id, sqlite_buf, "sqlite_call", sqlite_conn, "SELECT * FROMM users", 0, 4)
emit(sqlite_call.id, "executing_failed", 'near "FROMM": syntax error')
local sqlite_diags = get_diags(sqlite_conn.id, sqlite_buf)
if #sqlite_diags ~= 1 then
  fail("sqlite_diag_count:" .. tostring(#sqlite_diags))
end
assert_eq("sqlite_fallback_col", sqlite_diags[1].col, 4)
assert_true("sqlite_fallback_msg", sqlite_diags[1].message:find("[sqlite]", 1, true) ~= nil)

local click_note_id, click_buf = create_note("click_diag", {
  "SELECT * FROM table",
})
local click_call = attach_call(click_note_id, click_buf, "click_call", click_conn, "SELECT * FROM table", 0, 0)
emit(click_call.id, "executing_failed", "syntax error")
local click_diags = get_diags(click_conn.id, click_buf)
if #click_diags ~= 1 then
  fail("click_diag_count:" .. tostring(#click_diags))
end
assert_true("click_fallback_msg", click_diags[1].message:find("[clickhouse]", 1, true) ~= nil)

local mongo_note_id, mongo_buf = create_note("mongo_diag", {
  "{ find: 'users' }",
})
local mongo_call = attach_call(mongo_note_id, mongo_buf, "mongo_call", mongo_conn, "{ find: 'users' }", 0, 0)
emit(mongo_call.id, "executing_failed", "mongo error")
assert_eq("mongo_diag_suppressed", #get_diags(mongo_conn.id, mongo_buf), 0)

local alias_diag = diagnostics.build_diagnostic(
  "mssql",
  "mssql: Incorrect syntax near 'FROMM'. Line 4",
  { resolved_query = "SELECT 1", start_line = 1, start_col = 0 }
)
assert_true("mssql_alias_diag", alias_diag ~= nil)
assert_eq("mssql_alias_line", alias_diag.line, 4)
assert_true("duckdb_alias_sql", diagnostics.is_sql_adapter("duckdb"))
local duckdb_alias_diag = diagnostics.build_diagnostic(
  "duckdb",
  "syntax error",
  { resolved_query = "SELECT 1", start_line = 2, start_col = 3 }
)
assert_true("duckdb_alias_diag", duckdb_alias_diag ~= nil)
assert_eq("duckdb_alias_line", duckdb_alias_diag.line, 2)
assert_eq("duckdb_alias_col", duckdb_alias_diag.col, 3)
assert_true("duckdb_alias_msg", duckdb_alias_diag.message:find("[duck]", 1, true) ~= nil)
local duplicate_alias_ok = pcall(diagnostics.register_parser, "pg", function() end, { sql = true })
assert_true("duplicate_alias_guard", not duplicate_alias_ok)

print("ADPT02_POSTGRES_CTX_OK=true")
print("ADPT02_START_COL_OK=true")
print("ADPT02_ALIAS_MAP_OK=true")
print("ADPT02_DUCKDB_ALIAS_OK=true")
print("ADPT02_SQLITE_FALLBACK_OK=true")

-- Lifecycle clears: rerun start, explicit clear, note switch, note removal.
current_conn = mysql_conn
editor:set_current_note(mysql_note_id)
emit(mysql_call.id, "executing_failed", "Error 1064 (42000): You have an error in your SQL syntax; check the manual that corresponds to your MySQL server version for the right syntax to use near 'FROMM users' at line 2")
assert_eq("mysql_diag_before_rerun", #get_diags(mysql_conn.id, mysql_buf), 1)
editor:do_action("run_file")
assert_eq("mysql_diag_cleared_on_rerun", #get_diags(mysql_conn.id, mysql_buf), 0)

current_conn = sqlite_conn
editor:set_current_note(sqlite_note_id)
emit(sqlite_call.id, "executing_failed", 'near "FROMM": syntax error')
assert_eq("sqlite_diag_before_clear", #get_diags(sqlite_conn.id, sqlite_buf), 1)
editor:do_action("clear_diagnostics")
assert_eq("sqlite_diag_after_clear", #get_diags(sqlite_conn.id, sqlite_buf), 0)

editor:set_current_note(pg_alias_note_id)
emit(pg_alias_call.id, "executing_failed", 'pq: syntax error at or near "FROMM" (SQLSTATE 42601) POSITION: 10')
assert_eq("pg_diag_before_switch", #get_diags(pg_alias_conn.id, pg_alias_buf), 1)
editor:set_current_note(oracle_note_id)
assert_eq("pg_diag_after_switch", #get_diags(pg_alias_conn.id, pg_alias_buf), 0)

emit(click_call.id, "executing_failed", "syntax error")
assert_eq("click_diag_before_remove", #get_diags(click_conn.id, click_buf), 1)
editor:namespace_remove_note("global", click_note_id)
assert_eq("click_diag_after_remove", #get_diags(click_conn.id, click_buf), 0)

print("ADPT02_CLEAR_LIFECYCLE_OK=true")

-- Rewrite scope and listener guard.
local rewrite_note_id, rewrite_buf = create_note("rewrite_old", {
  "SELECT 1",
})
local rewrite_call = attach_call(rewrite_note_id, rewrite_buf, "rewrite_call", rewrite_old_conn, "SELECT 1", 0, 0)
emit(rewrite_call.id, "executing_failed", 'pq: syntax error at or near "FROMM" (SQLSTATE 42601) POSITION: 1')
assert_eq("rewrite_old_before", #get_diags(rewrite_old_conn.id, rewrite_buf), 1)

local other_note_id, other_buf = create_note("rewrite_other", {
  "SELECT 2",
})
local other_call = attach_call(other_note_id, other_buf, "other_call", other_conn, "SELECT 2", 0, 0)
emit(other_call.id, "executing_failed", 'pq: syntax error at or near "FROMM" (SQLSTATE 42601) POSITION: 1')
assert_eq("rewrite_other_before", #get_diags(other_conn.id, other_buf), 1)

editor:rebind_note_connection(rewrite_note_id, rewrite_new_conn.id, rewrite_new_conn.name, rewrite_new_conn.type)
assert_eq("rewrite_old_after_rebind", #get_diags(rewrite_old_conn.id, rewrite_buf), 0)

local rewrite_new_call = attach_call(rewrite_note_id, rewrite_buf, "rewrite_new_call", rewrite_new_conn, "SELECT 1", 0, 0)
emit(rewrite_new_call.id, "executing_failed", 'pq: syntax error at or near "FROMM" (SQLSTATE 42601) POSITION: 1')
assert_eq("rewrite_new_before_signal", #get_diags(rewrite_new_conn.id, rewrite_buf), 1)

package.loaded["dbee.reconnect"]._emit_rewrite(rewrite_old_conn.id, rewrite_new_conn.id)
assert_eq("rewrite_old_after_signal", #get_diags(rewrite_old_conn.id, rewrite_buf), 0)
assert_eq("rewrite_new_after_signal", #get_diags(rewrite_new_conn.id, rewrite_buf), 1)
assert_eq("rewrite_other_after_signal", #get_diags(other_conn.id, other_buf), 1)

local duplicate_listener_ok = pcall(
  package.loaded["dbee.reconnect"].register_connection_rewritten_listener,
  "editor-diagnostics",
  function() end
)
assert_true("duplicate_rewrite_listener_guard", not duplicate_listener_ok)

print("ADPT02_REWRITE_SIGNAL_SCOPE_OK=true")
print("ADPT02_REWRITE_LISTENER_GUARD_OK=true")

print("ADPT02_ALL_PASS=true")
vim.cmd("qa!")
