local schema_filter = require("dbee.schema_filter")
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
---@field supports_folders? fun(self: Source):boolean return true when source supports folder grouping (optional)
---@field load_folders? fun(self: Source):Folder[] return source-local folders (optional)
---@field add_folder? fun(self: Source, name: string):string add folder and return id (optional)
---@field rename_folder? fun(self: Source, folder_id: string, new_name: string) rename folder (optional)
---@field remove_folder? fun(self: Source, folder_id: string) remove folder (optional)
---@field move_connection? fun(self: Source, conn_id: connection_id, target_folder_id?: string) move connection into folder or ungroup (optional)
---@field reload_folders? fun(self: Source) invalidate folder cache (optional)

---@class Folder
---@field id string
---@field name string
---@field connection_ids connection_id[]

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

local function delete_key_path(record, key_path)
  local current = record
  local parts = {}
  for part in tostring(key_path or ""):gmatch("[^%.]+") do
    parts[#parts + 1] = part
  end
  if #parts == 0 then
    return
  end
  for index = 1, #parts - 1 do
    if type(current) ~= "table" then
      return
    end
    current = current[parts[index]]
  end
  if type(current) == "table" then
    current[parts[#parts]] = nil
  end
end

local function delete_keys(record, remove_keys)
  local next_record = vim.deepcopy(record or {})
  for _, key in ipairs(remove_keys or {}) do
    delete_key_path(next_record, key)
  end
  return next_record
end

local function validate_record_schema_filter(record)
  if type(record) ~= "table" or record.schema_filter == nil or record.schema_filter == vim.NIL then
    return
  end
  local ok, err = schema_filter.validate_persisted_filter(record.schema_filter, record.type)
  if not ok then
    error(err)
  end
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
    schema_filter = vim.deepcopy(record.schema_filter),
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
    _folders_load_state = "unloaded",
    _folders_load_error = nil,
    _folders_cache = nil,
    _folders_path = nil,
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
---@return boolean
function sources.FileSource:supports_folders()
  return true
end

---@package
---@return string
function sources.FileSource:folders_path()
  if self._folders_path then
    return self._folders_path
  end

  if self.path:sub(-5) == ".json" and self.path:sub(-13) ~= ".folders.json" then
    self._folders_path = self.path:sub(1, -6) .. ".folders.json"
  else
    self._folders_path = self.path .. ".folders.json"
  end

  return self._folders_path
end

---@package
---@param raw Folder[]
---@param conns ConnectionParams[]
---@return Folder[]
function sources.FileSource:_normalize_folders(raw, conns)
  local conn_ids = {}
  for _, conn in ipairs(conns or {}) do
    if conn and conn.id then
      conn_ids[conn.id] = true
    end
  end

  local seen_conn_ids = {}
  local normalized = {}
  for index, folder in ipairs(raw or {}) do
    local id = folder.id
    if type(id) ~= "string" or vim.trim(id) == "" then
      id = "folder_" .. utils.random_string()
      utils.log("warn", "folder at index " .. tostring(index) .. " is missing an id; generated " .. id)
    end

    local name = folder.name
    if type(name) ~= "string" or vim.trim(name) == "" then
      name = "Folder"
      utils.log("warn", "folder " .. tostring(id) .. " is missing a name; using Folder")
    end

    local connection_ids = {}
    for _, conn_id in ipairs(folder.connection_ids or {}) do
      if not conn_ids[conn_id] then
        utils.log("warn", "folder " .. tostring(id) .. " references missing connection " .. tostring(conn_id))
      elseif seen_conn_ids[conn_id] then
        utils.log("warn", "connection " .. tostring(conn_id) .. " appears in multiple folders; keeping first")
      else
        seen_conn_ids[conn_id] = true
        connection_ids[#connection_ids + 1] = conn_id
      end
    end

    normalized[#normalized + 1] = {
      id = id,
      name = name,
      connection_ids = connection_ids,
    }
  end

  return normalized
end

---@package
---@return boolean
function sources.FileSource:_ensure_folders_loaded()
  if self._folders_load_state == "loaded_ok" then
    return true
  end
  if self._folders_load_state == "load_failed" then
    return false
  end

  local path = self:folders_path()
  if not uv.fs_stat(path) then
    self._folders_cache = {}
    self._folders_load_state = "loaded_ok"
    self._folders_load_error = nil
    return true
  end

  local file, open_err = io.open(path, "r")
  if not file then
    self._folders_cache = {}
    self._folders_load_state = "load_failed"
    self._folders_load_error = "could not open folders sidecar: " .. tostring(open_err)
    utils.log("warn", self._folders_load_error)
    return false
  end

  local content = file:read("*a")
  file:close()
  if content == "" then
    self._folders_cache = {}
    self._folders_load_state = "loaded_ok"
    self._folders_load_error = nil
    return true
  end

  local decode_ok, decoded = pcall(vim.json.decode, content)
  if not decode_ok then
    self._folders_cache = {}
    self._folders_load_state = "load_failed"
    self._folders_load_error = "folders sidecar JSON decode failed"
    utils.log("warn", self._folders_load_error)
    return false
  end

  local malformed = type(decoded) ~= "table" or not vim.islist(decoded)
  if not malformed then
    for _, folder in ipairs(decoded) do
      if
        type(folder) ~= "table"
        or type(folder.connection_ids) ~= "table"
        or not vim.islist(folder.connection_ids)
      then
        malformed = true
        break
      end
    end
  end
  if malformed then
    self._folders_cache = {}
    self._folders_load_state = "load_failed"
    self._folders_load_error = "folders sidecar has malformed shape"
    utils.log("warn", self._folders_load_error)
    return false
  end

  self._folders_cache = self:_normalize_folders(decoded, self:load())
  self._folders_load_state = "loaded_ok"
  self._folders_load_error = nil
  return true
end

---@package
---@return Folder[]
function sources.FileSource:load_folders()
  if not self:_ensure_folders_loaded() then
    utils.log("warn", "folders sidecar corrupt; rendering without folders")
    return {}
  end

  return self._folders_cache or {}
end

---@package
function sources.FileSource:_require_folders_writeable()
  self:_ensure_folders_loaded()
  if self._folders_load_state == "load_failed" then
    error({ message = "folders sidecar is corrupt; refusing to overwrite", cache_corrupt = true })
  end
end

---@package
---@param name string
---@return string
function sources.FileSource:add_folder(name)
  self:_require_folders_writeable()

  if type(name) ~= "string" or vim.trim(name) == "" then
    error("folder name is required")
  end

  local normalized_name = vim.trim(name)
  local key = normalized_name:lower()
  for _, folder in ipairs(self._folders_cache or {}) do
    if tostring(folder.name or ""):lower() == key then
      error("folder name already exists: " .. normalized_name)
    end
  end

  local existing_ids = {}
  for _, folder in ipairs(self._folders_cache or {}) do
    existing_ids[folder.id] = true
  end

  local id = "folder_" .. utils.random_string()
  while existing_ids[id] do
    id = "folder_" .. utils.random_string()
  end

  self._folders_cache[#self._folders_cache + 1] = {
    id = id,
    name = normalized_name,
    connection_ids = {},
  }
  write_records_atomically(self:folders_path(), self._folders_cache)

  return id
end

---@package
---@param folder_id string
---@param new_name string
function sources.FileSource:rename_folder(folder_id, new_name)
  self:_require_folders_writeable()

  if not folder_id or folder_id == "" then
    error("folder id is required")
  end
  if type(new_name) ~= "string" or vim.trim(new_name) == "" then
    error("folder name is required")
  end

  local normalized_name = vim.trim(new_name)
  local key = normalized_name:lower()
  local target = nil
  for _, folder in ipairs(self._folders_cache or {}) do
    if folder.id == folder_id then
      target = folder
    elseif tostring(folder.name or ""):lower() == key then
      error("folder name already exists: " .. normalized_name)
    end
  end

  if not target then
    error("folder id not found: " .. tostring(folder_id))
  end

  target.name = normalized_name
  write_records_atomically(self:folders_path(), self._folders_cache)
end

---@package
---@param folder_id string
function sources.FileSource:remove_folder(folder_id)
  self:_require_folders_writeable()

  if not folder_id or folder_id == "" then
    error("folder id is required")
  end

  local found = false
  local next_folders = {}
  for _, folder in ipairs(self._folders_cache or {}) do
    if folder.id == folder_id then
      found = true
    else
      next_folders[#next_folders + 1] = folder
    end
  end

  if not found then
    error("folder id not found: " .. tostring(folder_id))
  end

  self._folders_cache = next_folders
  write_records_atomically(self:folders_path(), self._folders_cache)
end

---@package
---@param conn_id connection_id
---@param target_folder_id? string
function sources.FileSource:move_connection(conn_id, target_folder_id)
  self:_require_folders_writeable()

  if not conn_id or conn_id == "" then
    error("connection id is required")
  end

  local target_folder = nil
  local current_folder_id = nil
  if target_folder_id ~= nil then
    for _, folder in ipairs(self._folders_cache or {}) do
      if folder.id == target_folder_id then
        target_folder = folder
        break
      end
    end
    if not target_folder then
      error("folder id not found: " .. tostring(target_folder_id))
    end
  end

  for _, folder in ipairs(self._folders_cache or {}) do
    for _, current_conn_id in ipairs(folder.connection_ids or {}) do
      if current_conn_id == conn_id then
        current_folder_id = folder.id
        break
      end
    end
    if current_folder_id then
      break
    end
  end

  if current_folder_id == target_folder_id then
    return
  end

  for _, folder in ipairs(self._folders_cache or {}) do
    for index = #(folder.connection_ids or {}), 1, -1 do
      if folder.connection_ids[index] == conn_id then
        table.remove(folder.connection_ids, index)
      end
    end
  end

  if target_folder then
    target_folder.connection_ids[#target_folder.connection_ids + 1] = conn_id
  end

  write_records_atomically(self:folders_path(), self._folders_cache)
end

---@package
function sources.FileSource:reload_folders()
  self._folders_load_state = "unloaded"
  self._folders_load_error = nil
  self._folders_cache = nil
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
  validate_record_schema_filter(record)
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

  local prior_load_failed = self._folders_load_state == "load_failed"
  local pre_read_ok = false
  local was_member = false
  local raw_folders = nil
  local ok, content = pcall(function()
    local file = io.open(self:folders_path(), "r")
    if not file then
      return nil
    end
    local sidecar = file:read("*a")
    file:close()
    return sidecar
  end)

  if ok and content and content ~= "" then
    local decode_ok, decoded = pcall(vim.json.decode, content)
    if decode_ok and type(decoded) == "table" then
      raw_folders = decoded
      pre_read_ok = true
      for _, folder in ipairs(raw_folders) do
        if type(folder) == "table" and type(folder.connection_ids) == "table" then
          for _, conn_id in ipairs(folder.connection_ids) do
            if conn_id == id then
              was_member = true
              break
            end
          end
        end
        if was_member then
          break
        end
      end
    else
      self._folders_load_state = "load_failed"
      self._folders_load_error = "JSON decode failed during delete pre-read"
      self._folders_cache = {}
      utils.log("warn", "folders sidecar corrupt (decode failed); conn delete proceeds, folder prune skipped")
    end
  end

  if pre_read_ok then
    local saw_malformed = false
    if type(raw_folders) ~= "table" or not vim.islist(raw_folders) then
      saw_malformed = true
    else
      for _, folder in ipairs(raw_folders) do
        if
          type(folder) ~= "table"
          or type(folder.connection_ids) ~= "table"
          or not vim.islist(folder.connection_ids)
        then
          saw_malformed = true
          break
        end
      end
    end

    if saw_malformed then
      self._folders_load_state = "load_failed"
      self._folders_load_error = "malformed folder entries during delete pre-read"
      self._folders_cache = {}
      utils.log("warn", "folders sidecar has malformed entries; conn delete proceeds, folder prune SKIPPED")
      pre_read_ok = false
    end
  end

  local existing = read_json_records(self.path)
  local new = {}
  for _, ex in ipairs(existing) do
    if ex.id ~= id then
      new[#new + 1] = ex
    end
  end

  write_records_atomically(self.path, new)

  if pre_read_ok and was_member and not prior_load_failed then
    for _, folder in ipairs(raw_folders or {}) do
      if type(folder) == "table" and type(folder.connection_ids) == "table" then
        for index = #folder.connection_ids, 1, -1 do
          if folder.connection_ids[index] == id then
            table.remove(folder.connection_ids, index)
          end
        end
      end
    end

    local write_ok, write_err = pcall(write_records_atomically, self:folders_path(), raw_folders)
    if not write_ok then
      utils.log("error", "folder prune write failed: " .. tostring(write_err))
    elseif self._folders_load_state == "loaded_ok" then
      for _, folder in ipairs(self._folders_cache or {}) do
        for index = #(folder.connection_ids or {}), 1, -1 do
          if folder.connection_ids[index] == id then
            table.remove(folder.connection_ids, index)
          end
        end
      end
    end
  end
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
  local matched = false

  for index, ex in ipairs(existing) do
    if ex.id == id then
      matched = true
      local stripped = delete_keys(ex, remove_keys)
      local merged = recursive_merge(stripped, clean_details)
      validate_record_schema_filter(merged)
      existing[index] = merged
    end
  end

  if not matched then
    error("connection id not found: " .. tostring(id))
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
