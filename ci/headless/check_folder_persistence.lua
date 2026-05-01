-- Headless validation for Phase 15 FileSource folder sidecar persistence.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=$(pwd)" \
--   -c "luafile ci/headless/check_folder_persistence.lua"

local function fail(msg)
  print("FOLDER15_PERSISTENCE_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local function assert_true(label, value)
  if not value then
    fail(label .. ": expected truthy, got " .. vim.inspect(value))
  end
end

local function assert_false(label, value)
  if value then
    fail(label .. ": expected falsey, got " .. vim.inspect(value))
  end
end

local function assert_eq(label, actual, expected)
  if actual ~= expected then
    fail(label .. ": expected " .. vim.inspect(expected) .. " got " .. vim.inspect(actual))
  end
end

local function assert_match(label, actual, pattern)
  if type(actual) ~= "string" or actual:find(pattern, 1, true) == nil then
    fail(label .. ": expected " .. vim.inspect(actual) .. " to contain " .. vim.inspect(pattern))
  end
end

local notifications = {}
local saved_notify = vim.notify
vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = tostring(msg), level = level, opts = opts }
end

local function clear_notifications()
  notifications = {}
end

local function assert_warned(label)
  assert_true(label, #notifications > 0)
end

local function write_file(path, content)
  local file = assert(io.open(path, "w"))
  file:write(content)
  file:close()
end

local function read_file(path)
  local file = assert(io.open(path, "r"))
  local content = file:read("*a")
  file:close()
  return content
end

local function write_json(path, records)
  local ok, encoded = pcall(vim.fn.json_encode, records)
  if not ok then
    fail("json encode failed for " .. tostring(path))
  end
  write_file(path, encoded)
end

local function read_json(path)
  local content = read_file(path)
  if content == "" then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok then
    fail("json decode failed for " .. tostring(path) .. ": " .. tostring(decoded))
  end
  return decoded or {}
end

local function make_temp_dir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

local function cleanup_path(path)
  if path and path ~= "" then
    pcall(vim.fn.delete, path, "rf")
  end
end

local function connection_records()
  return {
    { id = "conn-a", name = "A", type = "postgres", url = "postgres://a" },
    { id = "conn-b", name = "B", type = "postgres", url = "postgres://b" },
    { id = "conn-c", name = "C", type = "postgres", url = "postgres://c" },
  }
end

local function with_source(records, folders, fn)
  local dir = make_temp_dir()
  local path = vim.fs.joinpath(dir, "connections.json")
  write_json(path, records or connection_records())

  local sources = require("dbee.sources")
  local source = sources.FileSource:new(path)
  if folders ~= nil then
    if type(folders) == "string" then
      write_file(source:folders_path(), folders)
    else
      write_json(source:folders_path(), folders)
    end
  end

  local ok, result = pcall(fn, source, path, dir)
  cleanup_path(dir)
  if not ok then
    fail(result)
  end
end

local function find_folder(folders, id)
  for _, folder in ipairs(folders or {}) do
    if folder.id == id then
      return folder
    end
  end
  return nil
end

local function run_sidecar_path_contract()
  local FileSource = require("dbee.sources").FileSource
  assert_match("json suffix", FileSource:new("/tmp/connections.json"):folders_path(), "/tmp/connections.folders.json")
  assert_match("no suffix", FileSource:new("/tmp/connections"):folders_path(), "/tmp/connections.folders.json")
  assert_match(
    "folders suffix collision",
    FileSource:new("/tmp/connections.folders.json"):folders_path(),
    "/tmp/connections.folders.json.folders.json"
  )
  print("FOLDER15_SIDECAR_PATH_DERIVES_OK=true")
end

local function run_missing_file_contract()
  with_source(connection_records(), nil, function(source)
    local folders = source:load_folders()
    assert_eq("missing sidecar folders", #folders, 0)
    assert_eq("missing sidecar state", source._folders_load_state, "loaded_ok")
  end)
  print("FOLDER15_LOAD_MISSING_FILE_EMPTY_OK=true")
end

local function run_normalize_contracts()
  with_source(connection_records(), {
    { id = "folder-one", name = "One", connection_ids = { "conn-a", "missing" } },
    { id = "folder-two", name = "Two", connection_ids = { "conn-a", "conn-b" } },
  }, function(source)
    clear_notifications()
    local original = read_file(source:folders_path())
    local folders = source:load_folders()
    assert_eq("first folder keeps conn-a", vim.inspect(folders[1].connection_ids), vim.inspect({ "conn-a" }))
    assert_eq("second folder drops duplicate keeps conn-b", vim.inspect(folders[2].connection_ids), vim.inspect({ "conn-b" }))
    assert_eq("normalize no rewrite", read_file(source:folders_path()), original)
    assert_warned("normalize warnings")
  end)
  print("FOLDER15_LOAD_DUPE_CONN_DEDUPED_OK=true")
  print("FOLDER15_LOAD_DROPS_MISSING_CONN_OK=true")
  print("FOLDER15_LOAD_NO_AUTO_REWRITE=true")
end

local function run_corrupt_sidecar_contract()
  local malformed_cases = {
    "not json",
    "{}",
    '{"k":"value"}',
    "[1]",
    '[{"id":"folder-one","name":"One","connection_ids":"bad"}]',
  }

  for index, payload in ipairs(malformed_cases) do
    with_source(connection_records(), payload, function(source)
      local original = read_file(source:folders_path())
      clear_notifications()
      assert_eq("corrupt load returns empty " .. index, #source:load_folders(), 0)
      assert_eq("corrupt state " .. index, source._folders_load_state, "load_failed")
      assert_warned("corrupt load warned " .. index)

      local mutations = {
        function()
          return source:add_folder("New")
        end,
        function()
          return source:rename_folder("folder-one", "Renamed")
        end,
        function()
          return source:remove_folder("folder-one")
        end,
        function()
          return source:move_connection("conn-a", "folder-one")
        end,
      }
      for mutation_index, mutation in ipairs(mutations) do
        local ok, err = pcall(mutation)
        assert_false("corrupt mutation refused " .. index .. "." .. mutation_index, ok)
        assert_true("corrupt mutation error table " .. index .. "." .. mutation_index, type(err) == "table")
        assert_eq("corrupt mutation flag " .. index .. "." .. mutation_index, err.cache_corrupt, true)
      end
      assert_eq("corrupt sidecar untouched " .. index, read_file(source:folders_path()), original)
    end)
  end

  print("FOLDER15_CORRUPT_SIDECAR_NO_OVERWRITE=true")
end

local function run_add_folder_contracts()
  with_source(connection_records(), nil, function(source)
    local id = source:add_folder("Production")
    assert_true("folder id prefix", id:find("^folder_") ~= nil)

    local persisted = read_json(source:folders_path())
    assert_eq("folder persisted name", persisted[1].name, "Production")

    local reloaded = require("dbee.sources").FileSource:new(source.path)
    local folders = reloaded:load_folders()
    assert_eq("folder reload sees add", folders[1].id, id)
  end)
  print("FOLDER15_ADD_FOLDER_PERSISTS_OK=true")

  with_source(connection_records(), nil, function(source)
    source:add_folder("Production")
    local original = read_file(source:folders_path())
    local ok, err = pcall(source.add_folder, source, "production")
    assert_false("dupe add rejected", ok)
    assert_match("dupe add error", tostring(err), "already exists")
    assert_eq("dupe add no write", read_file(source:folders_path()), original)
  end)
  print("FOLDER15_ADD_FOLDER_DUPE_NAME_REJECTS=true")
end

local function run_rename_remove_contracts()
  with_source(connection_records(), {
    { id = "folder-one", name = "One", connection_ids = { "conn-a", "conn-b" } },
  }, function(source)
    source:rename_folder("folder-one", "Renamed")
    local folder = read_json(source:folders_path())[1]
    assert_eq("rename id preserved", folder.id, "folder-one")
    assert_eq("rename name persisted", folder.name, "Renamed")
    assert_eq("rename keeps members", vim.inspect(folder.connection_ids), vim.inspect({ "conn-a", "conn-b" }))
  end)
  print("FOLDER15_RENAME_FOLDER_KEEPS_MEMBERS=true")

  with_source(connection_records(), {
    { id = "folder-one", name = "One", connection_ids = { "conn-a", "conn-b" } },
  }, function(source)
    source:remove_folder("folder-one")
    assert_eq("remove sidecar empty", #read_json(source:folders_path()), 0)
    local reloaded = require("dbee.sources").FileSource:new(source.path)
    assert_eq("remove reload empty", #reloaded:load_folders(), 0)
    assert_eq("remove leaves conns", #reloaded:load(), 3)
  end)
  print("FOLDER15_REMOVE_FOLDER_UNGROUPS_CONNS=true")
end

local function run_move_contracts()
  with_source(connection_records(), {
    { id = "folder-one", name = "One", connection_ids = {} },
    { id = "folder-two", name = "Two", connection_ids = {} },
  }, function(source)
    source:move_connection("conn-a", "folder-one")
    local one = find_folder(read_json(source:folders_path()), "folder-one")
    assert_eq("move into folder", vim.inspect(one.connection_ids), vim.inspect({ "conn-a" }))
  end)
  print("FOLDER15_MOVE_CONN_INTO_FOLDER_OK=true")

  with_source(connection_records(), {
    { id = "folder-one", name = "One", connection_ids = { "conn-a" } },
    { id = "folder-two", name = "Two", connection_ids = {} },
  }, function(source)
    source:move_connection("conn-a", "folder-two")
    local folders = read_json(source:folders_path())
    assert_eq("move between removes old", #find_folder(folders, "folder-one").connection_ids, 0)
    assert_eq("move between appends new", vim.inspect(find_folder(folders, "folder-two").connection_ids), vim.inspect({ "conn-a" }))
  end)
  print("FOLDER15_MOVE_CONN_BETWEEN_FOLDERS_OK=true")

  with_source(connection_records(), {
    { id = "folder-one", name = "One", connection_ids = { "conn-a" } },
  }, function(source)
    source:move_connection("conn-a", nil)
    assert_eq("move ungrouped removes", #read_json(source:folders_path())[1].connection_ids, 0)
  end)
  print("FOLDER15_MOVE_CONN_OUT_TO_UNGROUPED_OK=true")

  with_source(connection_records(), {
    { id = "folder-one", name = "One", connection_ids = { "conn-a" } },
  }, function(source)
    source:load_folders()
    local original_rename = vim.loop.fs_rename
    vim.loop.fs_rename = function()
      return nil, "rename should not run"
    end
    local ok, err = pcall(source.move_connection, source, "conn-a", "folder-one")
    vim.loop.fs_rename = original_rename
    assert_true("idempotent move did not write", ok)
    assert_eq("idempotent move err", err, nil)
  end)
  print("FOLDER15_MOVE_CONN_IDEMPOTENT_OK=true")
end

local function run_atomic_contracts()
  with_source(connection_records(), {
    { id = "folder-one", name = "One", connection_ids = {} },
  }, function(source)
    source:load_folders()
    local original = read_file(source:folders_path())
    local original_open = io.open
    io.open = function(target, mode)
      local file, err = original_open(target, mode)
      if not file then
        return file, err
      end
      if mode == "w" and target:find(source:folders_path() .. ".", 1, true) == 1 then
        return {
          write = function()
            return nil, "write exploded"
          end,
          flush = function()
            return file:flush()
          end,
          close = function()
            return file:close()
          end,
        }
      end
      return file, err
    end

    local ok, err = pcall(source.add_folder, source, "Two")
    io.open = original_open
    assert_false("atomic write failure", ok)
    assert_match("atomic write error", tostring(err), "could not write temp file")
    assert_eq("atomic write original untouched", read_file(source:folders_path()), original)
    assert_eq("atomic temp cleanup", vim.fn.glob(source:folders_path() .. ".*.tmp"), "")
  end)
  print("FOLDER15_ATOMIC_WRITE_TEMP_CLEANUP_OK=true")

  with_source(connection_records(), {
    { id = "folder-one", name = "One", connection_ids = {} },
  }, function(source)
    source:load_folders()
    local original = read_file(source:folders_path())
    local original_rename = vim.loop.fs_rename
    vim.loop.fs_rename = function()
      return nil, "rename exploded"
    end

    local ok, err = pcall(source.add_folder, source, "Two")
    vim.loop.fs_rename = original_rename
    assert_false("atomic rename failure", ok)
    assert_match("atomic rename error", tostring(err), "could not rename temp file")
    assert_eq("atomic rename original untouched", read_file(source:folders_path()), original)
    assert_eq("atomic rename temp cleanup", vim.fn.glob(source:folders_path() .. ".*.tmp"), "")
  end)
  print("FOLDER15_ATOMIC_WRITE_RENAME_FAIL_OK=true")
end

local function run_delete_prune_contract()
  with_source(connection_records(), {
    { id = "folder-one", name = "One", connection_ids = { "conn-a", "conn-b" } },
  }, function(source)
    source:load_folders()
    source:delete("conn-a")
    local folder = read_json(source:folders_path())[1]
    assert_eq("loaded delete prunes disk", vim.inspect(folder.connection_ids), vim.inspect({ "conn-b" }))
    assert_eq("loaded delete prunes cache", vim.inspect(source._folders_cache[1].connection_ids), vim.inspect({ "conn-b" }))
    assert_eq("loaded delete removes conn", #source:load(), 2)
  end)

  with_source(connection_records(), {
    { id = "folder-one", name = "One", connection_ids = { "conn-a", "conn-b" } },
  }, function(source)
    source:delete("conn-a")
    local folder = read_json(source:folders_path())[1]
    assert_eq("cold delete prunes disk", vim.inspect(folder.connection_ids), vim.inspect({ "conn-b" }))
    assert_eq("cold delete removes conn", #source:load(), 2)
  end)
  print("FOLDER15_DELETE_CONN_PRUNES_FOLDER_MEMBERSHIP_OK=true")
end

local function run_reload_contract()
  with_source(connection_records(), {
    { id = "folder-one", name = "One", connection_ids = {} },
  }, function(source)
    local folders = source:load_folders()
    assert_eq("reload first name", folders[1].name, "One")
    write_json(source:folders_path(), {
      { id = "folder-two", name = "Two", connection_ids = {} },
    })
    assert_eq("reload cached name", source:load_folders()[1].name, "One")
    source:reload_folders()
    assert_eq("reload rereads name", source:load_folders()[1].name, "Two")
  end)
  print("FOLDER15_RELOAD_FOLDERS_REREADS_DISK=true")
end

local function run_delete_corrupt_contract()
  local malformed_cases = {
    "not json",
    "{}",
    '{"k":"value"}',
    "[1]",
    '[{"id":"folder-one","name":"One","connection_ids":"bad"}]',
  }

  for index, payload in ipairs(malformed_cases) do
    with_source(connection_records(), payload, function(source)
      local original_sidecar = read_file(source:folders_path())
      clear_notifications()
      local ok, err = pcall(source.delete, source, "conn-a")
      assert_true("corrupt delete succeeds " .. index, ok)
      assert_eq("corrupt delete err " .. index, err, nil)
      assert_eq("corrupt delete state " .. index, source._folders_load_state, "load_failed")
      assert_eq("corrupt delete sidecar unchanged " .. index, read_file(source:folders_path()), original_sidecar)
      assert_eq("corrupt delete removes conn " .. index, #source:load(), 2)
      assert_warned("corrupt delete warned " .. index)
    end)
  end

  with_source(connection_records(), "not json", function(source)
    source:load_folders()
    assert_eq("prior failed state", source._folders_load_state, "load_failed")
    write_json(source:folders_path(), {
      { id = "folder-one", name = "One", connection_ids = { "conn-a" } },
    })
    local valid_sidecar = read_file(source:folders_path())
    source:delete("conn-a")
    assert_eq("prior failed still load_failed", source._folders_load_state, "load_failed")
    assert_eq("prior failed skips prune", read_file(source:folders_path()), valid_sidecar)
    assert_eq("prior failed removes conn", #source:load(), 2)
  end)

  with_source(connection_records(), nil, function(source)
    source:delete("conn-a")
    assert_eq("missing sidecar delete state", source._folders_load_state, "unloaded")
    assert_eq("missing sidecar delete removes conn", #source:load(), 2)
  end)

  with_source(connection_records(), "[]", function(source)
    source:delete("conn-a")
    assert_true("empty list delete not failed", source._folders_load_state ~= "load_failed")
    assert_eq("empty list sidecar unchanged", read_file(source:folders_path()), "[]")
  end)

  print("FOLDER15_DELETE_CONN_CORRUPT_SIDECAR_NO_BLOCK=true")
end

run_sidecar_path_contract()
run_missing_file_contract()
run_normalize_contracts()
run_corrupt_sidecar_contract()
run_add_folder_contracts()
run_rename_remove_contracts()
run_move_contracts()
run_atomic_contracts()
run_delete_prune_contract()
run_reload_contract()
run_delete_corrupt_contract()

vim.notify = saved_notify
print("FOLDER15_PERSISTENCE_ALL_PASS=true")
vim.cmd("qa!")
