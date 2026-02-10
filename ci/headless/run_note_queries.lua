-- Headless runner for executing each query from a SQL note sequentially.
--
-- Usage example:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=/path/to/nui.nvim" \
--   --cmd "set rtp+=/path/to/nvim-dbee" \
--   -c "lua _G.DBEE_NOTE='/abs/path/to/test.sql'; _G.DBEE_CONN='cptcdrlqy'" \
--   -c "lua _G.DBEE_CONNECTIONS='/abs/path/to/connections.json'" \
--   -c "lua _G.DBEE_SUMMARY='/tmp/dbee-summary.json'" \
--   -c "luafile ci/headless/run_note_queries.lua"
--
-- Globals:
--   DBEE_NOTE: absolute path to SQL note file
--   DBEE_CONN: connection id (must exist in DBEE_CONNECTIONS)
--   DBEE_CONNECTIONS: path to FileSource connections JSON
--   DBEE_SUMMARY: optional output file for JSON summary

local ok_dbee, dbee = pcall(require, "dbee")
if not ok_dbee then
  print("RUN_FATAL=require_dbee_failed:" .. tostring(dbee))
  vim.cmd("qa!")
  return
end
local query_splitter = require("dbee.query_splitter")

local function preview(query)
  local s = query:gsub("\n", " "):gsub("%s+", " ")
  if #s > 120 then
    return s:sub(1, 117) .. "..."
  end
  return s
end

---@param query string
---@return string cleaned_query
---@return table|nil exec_opts
---@return string|nil err
local function extract_query_opts(query)
  local lines = vim.split(query or "", "\n", { plain = true })
  local out = {}
  local opts = nil
  local scanning_directives = true

  for _, line in ipairs(lines) do
    if scanning_directives then
      local trimmed = line:match("^%s*(.-)%s*$")
      local directive = trimmed:match("^%-%-%s*DBEE_OPTS:%s*(.+)$")
      if directive then
        local ok_decode, decoded = pcall(vim.json.decode, directive)
        if not ok_decode or type(decoded) ~= "table" then
          return query, nil, "invalid DBEE_OPTS json: " .. tostring(directive)
        end
        opts = decoded
      else
        scanning_directives = false
        out[#out + 1] = line
      end
    else
      out[#out + 1] = line
    end
  end

  return table.concat(out, "\n"), opts, nil
end

local function get_value(key, fallback)
  local v = rawget(_G, key)
  if type(v) == "string" and v ~= "" then
    return v
  end
  return fallback
end

local state_dir = vim.fn.stdpath("state") .. "/dbee"
local data_dir = vim.fn.stdpath("data") .. "/dbee"

local repo_note_path = vim.fn.getcwd() .. "/ci/headless/test.sql"
local default_note_path = (vim.fn.filereadable(repo_note_path) == 1)
    and repo_note_path
  or (state_dir .. "/notes/cptcdrlqy/test.sql")

local note_path = get_value("DBEE_NOTE", default_note_path)
local conn_id = get_value("DBEE_CONN", "cptcdrlqy")
local connections_file = get_value("DBEE_CONNECTIONS", data_dir .. "/connections.json")
local summary_out = rawget(_G, "DBEE_SUMMARY")

if vim.fn.filereadable(note_path) ~= 1 then
  print("RUN_FATAL=note_not_found:" .. note_path)
  vim.cmd("qa!")
  return
end

if vim.fn.filereadable(connections_file) ~= 1 then
  print("RUN_FATAL=connections_file_not_found:" .. connections_file)
  vim.cmd("qa!")
  return
end

local lines = vim.fn.readfile(note_path)
local script = table.concat(lines, "\n")

local ok_setup, setup_err = pcall(dbee.setup, {
  sources = {
    require("dbee.sources").FileSource:new(connections_file),
  },
  default_connection = conn_id,
  editor = {
    directory = state_dir .. "/notes",
  },
})
if not ok_setup then
  print("RUN_FATAL=setup_failed:" .. tostring(setup_err))
  vim.cmd("qa!")
  return
end

local api = dbee.api
local conn = api.core.get_current_connection()
if not conn then
  print("RUN_FATAL=no_current_connection")
  vim.cmd("qa!")
  return
end

local queries = query_splitter.split(script, {
  adapter_type = conn.type,
})
if #queries == 0 then
  print("RUN_FATAL=no_queries_detected")
  vim.cmd("qa!")
  return
end

print("RUN_CONN_ID=" .. tostring(conn.id))
print("RUN_TOTAL_QUERIES=" .. tostring(#queries))

local terminal_states = {
  archived = true,
  executing_failed = true,
  retrieving_failed = true,
  archive_failed = true,
  canceled = true,
}

local function find_call(call_id)
  local ok_calls, calls = pcall(api.core.connection_get_calls, conn.id)
  if not ok_calls or type(calls) ~= "table" then
    return nil
  end

  for _, c in ipairs(calls) do
    if c.id == call_id then
      return c
    end
  end
  return nil
end

local function wait_terminal(call_id, timeout_s)
  local start = vim.loop.hrtime()
  local timeout_ns = timeout_s * 1000000000

  while (vim.loop.hrtime() - start) < timeout_ns do
    vim.wait(150)
    local c = find_call(call_id)
    if c and terminal_states[c.state] then
      return c, false
    end
  end

  return find_call(call_id), true
end

local summary = {
  conn_id = conn.id,
  note_path = note_path,
  total_queries = #queries,
  executed_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  queries = {},
}

for i, query in ipairs(queries) do
  local exec_query, exec_opts, opts_err = extract_query_opts(query)
  local item = {
    index = i,
    preview = preview(exec_query),
    state = "not_executed",
    time_us = 0,
  }
  summary.queries[#summary.queries + 1] = item

  print(string.format("Q%02d_PREVIEW=%s", i, item.preview))

  if opts_err then
    item.state = "invalid_query_opts"
    item.error = opts_err
    print(string.format("Q%02d_STATE=%s", i, item.state))
    print(string.format("Q%02d_ERROR=%s", i, item.error:gsub("\n", "\\n")))
    goto continue
  end

  local ok_exec, call = pcall(api.core.connection_execute, conn.id, exec_query, exec_opts)
  if not ok_exec then
    item.state = "execute_error"
    item.error = tostring(call)
    print(string.format("Q%02d_STATE=%s", i, item.state))
    print(string.format("Q%02d_ERROR=%s", i, item.error:gsub("\n", "\\n")))
    goto continue
  end

  if not call or not call.id then
    item.state = "execute_returned_no_call"
    print(string.format("Q%02d_STATE=%s", i, item.state))
    goto continue
  end

  item.call_id = call.id

  local final_call, timed_out = wait_terminal(call.id, 180)
  if not final_call then
    item.state = timed_out and "timeout_no_call" or "unknown_no_call"
    print(string.format("Q%02d_STATE=%s", i, item.state))
    goto continue
  end

  if timed_out then
    item.state = "timeout_last_state_" .. tostring(final_call.state)
    print(string.format("Q%02d_STATE=%s", i, item.state))
    goto continue
  end

  item.state = tostring(final_call.state)
  item.time_us = tonumber(final_call.time_taken_us) or 0
  item.error = (final_call.error ~= vim.NIL) and final_call.error or nil

  print(string.format("Q%02d_STATE=%s", i, item.state))
  print(string.format("Q%02d_TIME_US=%s", i, tostring(item.time_us)))
  if item.error and item.error ~= "" then
    print(string.format("Q%02d_ERROR=%s", i, tostring(item.error):gsub("\n", "\\n")))
  end

  if item.state == "archived" then
    local tmp = string.format("/tmp/dbee_q_%02d_%s.json", i, tostring(call.id))
    local ok_store, store_err = pcall(api.core.call_store_result, final_call.id, "json", "file", { extra_arg = tmp })
    if not ok_store then
      item.result_store_error = tostring(store_err)
      print(string.format("Q%02d_RESULT_STORE_ERROR=%s", i, item.result_store_error:gsub("\n", "\\n")))
    elseif vim.fn.filereadable(tmp) ~= 1 then
      item.result_store_missing = true
      print(string.format("Q%02d_RESULT_STORE_FILE_MISSING", i))
    else
      local content = table.concat(vim.fn.readfile(tmp), "\n")
      os.remove(tmp)
      local ok_decode, decoded = pcall(vim.json.decode, content)
      if not ok_decode or type(decoded) ~= "table" then
        item.result_decode_error = true
        print(string.format("Q%02d_RESULT_DECODE_ERROR", i))
      else
        item.rows = #decoded
        if #decoded > 0 and type(decoded[1]) == "table" then
          local cols = 0
          for _ in pairs(decoded[1]) do
            cols = cols + 1
          end
          item.cols = cols
        else
          item.cols = 0
        end
        print(string.format("Q%02d_ROWS=%d", i, item.rows))
        print(string.format("Q%02d_COLS=%d", i, item.cols))
      end
    end
  end

  ::continue::
end

if type(summary_out) == "string" and summary_out ~= "" then
  local parent = vim.fs.dirname(summary_out)
  if parent and parent ~= "" then
    vim.fn.mkdir(parent, "p")
  end
  local f = io.open(summary_out, "w")
  if f then
    f:write(vim.json.encode(summary))
    f:close()
    print("RUN_SUMMARY_FILE=" .. summary_out)
  else
    print("RUN_SUMMARY_FILE_ERROR=" .. summary_out)
  end
end

vim.cmd("qa!")
