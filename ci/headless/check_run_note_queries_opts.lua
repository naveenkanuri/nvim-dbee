-- Headless regression tests for run_note_queries option handling.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=/path/to/nvim-dbee" \
--   -c "luafile ci/headless/check_run_note_queries_opts.lua"

local function fail(msg)
  print("RUN_NOTE_OPTS_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local function write_file(path, content)
  local fd = io.open(path, "w")
  if not fd then
    fail("write_open:" .. path)
    return false
  end
  fd:write(content)
  fd:close()
  return true
end

local cwd = vim.fn.getcwd()
local tmp_dir = vim.fn.tempname() .. "_run_note_opts"
vim.fn.mkdir(tmp_dir, "p")

local connections_file = tmp_dir .. "/connections.json"
local conn_json = vim.json.encode({
  {
    id = "opts_sqlite",
    name = "opts_sqlite",
    type = "sqlite",
    url = ":memory:",
  },
})
if not write_file(connections_file, conn_json) then
  return
end

local function run_runner(note_path, summary_path)
  local cmd = {
    "nvim",
    "--headless",
    "-u",
    "NONE",
    "-i",
    "NONE",
    "-n",
  }

  local nui_path = vim.fn.expand("~/.local/share/nvim/lazy/nui.nvim")
  if vim.fn.isdirectory(nui_path) == 1 then
    cmd[#cmd + 1] = "--cmd"
    cmd[#cmd + 1] = "set rtp+=" .. nui_path
  end

  cmd[#cmd + 1] = "--cmd"
  cmd[#cmd + 1] = "set rtp+=" .. cwd
  cmd[#cmd + 1] = "-c"
  cmd[#cmd + 1] = "lua _G.DBEE_NOTE=" .. string.format("%q", note_path)
  cmd[#cmd + 1] = "-c"
  cmd[#cmd + 1] = "lua _G.DBEE_CONN='opts_sqlite'"
  cmd[#cmd + 1] = "-c"
  cmd[#cmd + 1] = "lua _G.DBEE_CONNECTIONS=" .. string.format("%q", connections_file)
  cmd[#cmd + 1] = "-c"
  cmd[#cmd + 1] = "lua _G.DBEE_SUMMARY=" .. string.format("%q", summary_path)
  cmd[#cmd + 1] = "-c"
  cmd[#cmd + 1] = "luafile " .. cwd .. "/ci/headless/run_note_queries.lua"

  local result = vim.system(cmd, { text = true }):wait()
  local output = (result.stdout or "") .. (result.stderr or "")
  return output, result.code
end

local note_bad_json = tmp_dir .. "/bad_json.sql"
if not write_file(note_bad_json, table.concat({
  [[-- DBEE_OPTS: {"binds":[1,2}]],
  "SELECT 1;",
  "",
}, "\n")) then
  return
end

local out_json, code_json = run_runner(note_bad_json, tmp_dir .. "/summary_bad_json.json")
if code_json ~= 0 then
  fail("bad_json_exit_code:" .. tostring(code_json))
  return
end
if not out_json:find("Q01_STATE=invalid_query_opts", 1, true) then
  fail("bad_json_missing_state")
  return
end
if not out_json:find("Q01_ERROR=invalid DBEE_OPTS json", 1, true) then
  fail("bad_json_missing_error")
  return
end

local note_bad_binds = tmp_dir .. "/bad_binds.sql"
if not write_file(note_bad_binds, table.concat({
  [[-- DBEE_OPTS: {"binds":[1,2]}]],
  "SELECT 1;",
  "",
}, "\n")) then
  return
end

local out_binds, code_binds = run_runner(note_bad_binds, tmp_dir .. "/summary_bad_binds.json")
if code_binds ~= 0 then
  fail("bad_binds_exit_code:" .. tostring(code_binds))
  return
end
if not out_binds:find("Q01_STATE=execute_error", 1, true) then
  fail("bad_binds_missing_state")
  return
end
if not out_binds:find("query option \"binds\" must be a map", 1, true) then
  fail("bad_binds_missing_error")
  return
end

print("RUN_NOTE_OPTS_BAD_JSON_OK=true")
print("RUN_NOTE_OPTS_BAD_BINDS_OK=true")
vim.cmd("qa!")
