local utils = require("dbee.utils")

local uv = vim.loop

---@mod dbee.ref.sources Sources
---@brief [[
---Sources can be created by implementing the Source interface.
---Some methods are optional and are related to updating/editing functionality.
---@brief ]]

---ID of a source.
---@alias source_id string

---Source interface
---"name" and "load" methods are mandatory for basic functionality.
---"create", "update" and "delete" methods are optional and provide interactive CRUD.
---"file" method is used for providing optional manual edits of the source's file.
---"get_record" is optional and exposes the raw persisted record for metadata-first edit seeding.
---A source is also in charge of managing ids of connections. A connection parameter without
---a unique id results in an error or undefined behavior.
---@class Source
---@field name fun(self: Source):string function to return the name of the source
---@field load fun(self: Source):ConnectionParams[] function to load connections from external source
---@field create? fun(self: Source, details: ConnectionParams):connection_id create a connection and return its id (optional)
---@field delete? fun(self: Source, id: connection_id) delete a connection from its id (optional)
---@field update? fun(self: Source, id: connection_id, details: ConnectionParams) update provided connection (optional)
---@field get_record? fun(self: Source, id: connection_id):table|nil return the raw persisted record for a connection id (optional)
---@field file? fun(self: Source):string function which returns a source file to edit (optional)

local sources = {}

local function read_json_records(path)
  if not uv.fs_stat(path) then
    return {}
  end

  local lines = {}
  for line in io.lines(path) do
    if not vim.startswith(vim.trim(line), "//") then
      lines[#lines + 1] = line
    end
  end

  local contents = table.concat(lines, "\n")
  if contents == "" then
    return {}
  end

  local ok, data = pcall(vim.fn.json_decode, contents)
  if not ok then
    error('Could not parse json file: "' .. path .. '".')
  end

  if type(data) ~= "table" then
    return {}
  end

  local records = {}
  local iter = vim.islist(data) and ipairs or pairs
  for _, record in iter(data) do
    if type(record) == "table" then
      records[#records + 1] = record
    end
  end

  return records
end

local function cleanup_file(path)
  if not path or path == "" or not uv.fs_stat(path) then
    return
  end

  pcall(uv.fs_unlink, path)
end

local function abort_atomic_write(file, temp_path, prefix, err)
  if file then
    pcall(file.close, file)
  end
  cleanup_file(temp_path)
  error(prefix .. tostring(err))
end

local function write_records_atomically(path, records)
  local ok, json = pcall(vim.fn.json_encode, records)
  if not ok then
    error("could not convert connection list to json")
  end

  local temp_path = string.format("%s.%s.tmp", path, utils.random_string())
  local file, open_err = io.open(temp_path, "w")
  if not file then
    error("could not open temp file: " .. tostring(open_err))
  end

  local ok_write, write_result, write_err = pcall(file.write, file, json)
  if not ok_write or write_result == nil then
    abort_atomic_write(file, temp_path, "could not write temp file: ", ok_write and write_err or write_result)
  end

  local ok_flush, flush_result, flush_err = pcall(file.flush, file)
  if not ok_flush or flush_result == nil then
    abort_atomic_write(file, temp_path, "could not flush temp file: ", ok_flush and flush_err or flush_result)
  end

  local ok_close, close_result, close_err = pcall(file.close, file)
  if not ok_close or close_result == nil then
    cleanup_file(temp_path)
    error("could not close temp file: " .. tostring(ok_close and close_err or close_result))
  end

  local ok_rename, rename_err = uv.fs_rename(temp_path, path)
  if not ok_rename then
    cleanup_file(temp_path)
    error("could not rename temp file: " .. tostring(rename_err))
  end
end

local function normalize_remove_keys(details)
  if type(details) ~= "table" or type(details.__remove_keys) ~= "table" then
    return {}
  end

  local keys = {}
  for _, key in ipairs(details.__remove_keys) do
    if type(key) == "string" and key ~= "" and key ~= "__remove_keys" then
      keys[#keys + 1] = key
    end
  end
  return keys
end

local function strip_control_fields(record)
  local clean = vim.deepcopy(record or {})
  clean.__remove_keys = nil
  return clean
end

local function delete_top_level_keys(record, remove_keys)
  local next_record = vim.deepcopy(record or {})
  for _, key in ipairs(remove_keys or {}) do
    next_record[key] = nil
  end
  return next_record
end

local function recursive_merge(existing, details)
  local merged = vim.deepcopy(existing or {})
  for key, value in pairs(details or {}) do
    if key ~= "__remove_keys" then
      if type(merged[key]) == "table" and type(value) == "table" then
        merged[key] = recursive_merge(merged[key], value)
      else
        merged[key] = vim.deepcopy(value)
      end
    end
  end
  return merged
end

local function record_to_connection_params(record)
  return {
    id = record.id,
    name = record.name,
    type = record.type,
    url = record.url,
  }
end

---@divider -

---Built-In File Source.
---@class FileSource: Source
---@field private path string path to file
sources.FileSource = {}

--- Loads connections from json file
---@param path string path to file
---@return Source
function sources.FileSource:new(path)
  if not path then
    error("no path provided")
  end
  local o = {
    path = path,
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

---@package
---@return string
function sources.FileSource:name()
  return vim.fs.basename(self.path)
end

---@package
---@return ConnectionParams[]
function sources.FileSource:load()
  local records = read_json_records(self.path)

  ---@type ConnectionParams[]
  local conns = {}
  for _, record in ipairs(records) do
    conns[#conns + 1] = record_to_connection_params(record)
  end

  return conns
end

---@package
---@param conn ConnectionParams
---@return connection_id
function sources.FileSource:create(conn)
  if not conn or vim.tbl_isempty(conn) then
    error("cannot create an empty connection")
  end

  local existing = read_json_records(self.path)
  local record = strip_control_fields(conn)
  record.id = record.id or ("file_source_/" .. utils.random_string())
  existing[#existing + 1] = record

  write_records_atomically(self.path, existing)

  return record.id
end

---@package
---@param id connection_id
function sources.FileSource:delete(id)
  if not id or id == "" then
    error("no id passed to delete function")
  end

  local existing = read_json_records(self.path)
  local new = {}
  for _, ex in ipairs(existing) do
    if ex.id ~= id then
      new[#new + 1] = ex
    end
  end

  write_records_atomically(self.path, new)
end

---@package
---@param id connection_id
---@param details ConnectionParams
function sources.FileSource:update(id, details)
  if not id or id == "" then
    error("no id passed to update function")
  end

  if not details or vim.tbl_isempty(details) then
    error("cannot create an empty connection")
  end

  local existing = read_json_records(self.path)
  local remove_keys = normalize_remove_keys(details)
  local clean_details = strip_control_fields(details)

  for index, ex in ipairs(existing) do
    if ex.id == id then
      local stripped = delete_top_level_keys(ex, remove_keys)
      existing[index] = recursive_merge(stripped, clean_details)
    end
  end

  write_records_atomically(self.path, existing)
end

---@package
---@return string
function sources.FileSource:file()
  return self.path
end

---@package
---@param id connection_id
---@return table|nil
function sources.FileSource:get_record(id)
  if not id or id == "" then
    return nil
  end

  for _, record in ipairs(read_json_records(self.path)) do
    if record.id == id then
      return vim.deepcopy(record)
    end
  end

  return nil
end

---@divider -

---Built-In Env Source.
---Loads connections from json string of env variable.
---@class EnvSource: Source
---@field private var string path to file
sources.EnvSource = {}

---@param var string env var to load connections from
---@return Source
function sources.EnvSource:new(var)
  if not var then
    error("no path provided")
  end
  local o = {
    var = var,
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

---@package
---@return string
function sources.EnvSource:name()
  return self.var
end

---@package
---@return ConnectionParams[]
function sources.EnvSource:load()
  ---@type ConnectionParams[]
  local conns = {}

  local raw = os.getenv(self.var)
  if not raw then
    return {}
  end

  local ok, data = pcall(vim.fn.json_decode, raw)
  if not ok then
    error('Could not parse connections from env: "' .. self.var .. '".')
    return {}
  end

  for i, conn in pairs(data) do
    if type(conn) == "table" and conn.url and conn.type then
      conn.id = conn.id or ("environment_source_" .. self.var .. "_" .. i)
      table.insert(conns, conn)
    end
  end

  return conns
end

---@divider -

---Built-In Memory Source.
---Loads connections from lua table.
---@class MemorySource: Source
---@field private conns ConnectionParams[]
---@field private display_name string
sources.MemorySource = {}

---@param conns ConnectionParams[] list of connections
---@param name? string optional display name
---@return Source
function sources.MemorySource:new(conns, name)
  name = name or "memory"

  local parsed = {}
  for i, conn in pairs(conns or {}) do
    if type(conn) == "table" and conn.url and conn.type then
      conn.id = "memory_source_" .. name .. i
      table.insert(parsed, conn)
    end
  end

  local o = {
    conns = parsed,
    display_name = name,
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

---@package
---@return string
function sources.MemorySource:name()
  return self.display_name
end

---@package
---@return ConnectionParams[]
function sources.MemorySource:load()
  return self.conns
end

return sources
