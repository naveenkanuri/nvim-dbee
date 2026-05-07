-- Persist the last-used connection across nvim restarts.
--
-- Stored at $XDG_STATE_HOME/nvim/dbee/last_connection.json (defaulting to
-- ~/.local/state/nvim/dbee/last_connection.json). On startup, dbee prefers
-- this id over the user's `config.default_connection`. If the persisted id no
-- longer corresponds to a known connection, the caller falls back to
-- `default_connection`.
--
-- Best-effort writes/reads: any I/O failure is swallowed so persistence
-- problems can't block dbee setup or connection switches.

local M = {}

---@return string
local function state_path()
  local state_home = vim.fn.stdpath("state")
  return state_home .. "/dbee/last_connection.json"
end

---@return string?
function M.read()
  local path = state_path()
  local fd, err = vim.uv.fs_open(path, "r", 420) -- 0644
  if not fd then
    if err and not err:match("ENOENT") then
      -- non-missing read error: degrade silently
    end
    return nil
  end
  local stat = vim.uv.fs_fstat(fd)
  if not stat or stat.size == 0 then
    vim.uv.fs_close(fd)
    return nil
  end
  local data = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  if type(data) ~= "string" or data == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, data)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  local id = decoded.conn_id
  if type(id) ~= "string" or id == "" then
    return nil
  end
  return id
end

---@param conn_id string
function M.write(conn_id)
  if type(conn_id) ~= "string" or conn_id == "" then
    return
  end
  local path = state_path()
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")
  local payload = { conn_id = conn_id, ts = os.time() }
  local ok_encode, encoded = pcall(vim.json.encode, payload)
  if not ok_encode then
    return
  end
  -- Atomic write: write to temp + rename. Avoids torn reads if a second nvim
  -- starts mid-write.
  local tmp = path .. ".tmp"
  local fd = vim.uv.fs_open(tmp, "w", 420)
  if not fd then
    return
  end
  vim.uv.fs_write(fd, encoded, 0)
  vim.uv.fs_close(fd)
  vim.uv.fs_rename(tmp, path)
end

return M
