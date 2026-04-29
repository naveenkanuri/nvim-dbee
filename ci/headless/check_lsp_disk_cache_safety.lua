-- Headless checks for Phase 11 LSP disk-cache safety and bounded loading.

local SchemaCache = require("dbee.lsp.schema_cache")

local function fail(msg)
  print("LSP11_DISK_CACHE_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local function assert_true(label, value)
  if not value then
    fail(label .. ": expected true")
  end
end

local function assert_eq(label, actual, expected)
  if actual ~= expected then
    fail(label .. ": expected " .. vim.inspect(expected) .. " got " .. vim.inspect(actual))
  end
end

local notifications = {}
local saved_notify = vim.notify
vim.notify = function(msg, level)
  notifications[#notifications + 1] = { msg = tostring(msg), level = level }
end

local function has_warning(fragment)
  for _, entry in ipairs(notifications) do
    if entry.level == vim.log.levels.WARN and entry.msg:find(fragment, 1, true) then
      return true
    end
  end
  return false
end

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")

local function new_cache(conn_id)
  local cache = SchemaCache:new({}, conn_id)
  cache.cache_dir = root .. "/lsp_cache"
  vim.fn.mkdir(cache.cache_dir, "p")
  return cache
end

local function write_file(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

local function read_file(path)
  local f = assert(io.open(path, "r"))
  local content = f:read("*a")
  f:close()
  return content
end

local function temp_residue_count(dir)
  return #vim.fn.glob(dir .. "/**/*.tmp.*", false, true)
end

local cache = new_cache("disk-safe")
cache:build_from_metadata_rows({
  { schema_name = "S", table_name = "T", obj_type = "table" },
})
cache:save_to_disk()
cache:_save_columns_to_disk("S.T", {
  { name = "ID", type = "NUMBER" },
})

assert_true("schema file written", vim.fn.filereadable(cache:_cache_path()) == 1)
assert_true("column file written", vim.fn.filereadable(cache:_columns_cache_path("S.T")) == 1)
assert_eq("no temp residue", temp_residue_count(cache.cache_dir), 0)

local original = read_file(cache:_cache_path())
local saved_rename = os.rename
os.rename = function()
  return nil, "forced rename failure"
end
cache:build_from_metadata_rows({
  { schema_name = "S", table_name = "T2", obj_type = "table" },
})
cache:save_to_disk()
os.rename = saved_rename
assert_eq("original preserved on rename failure", read_file(cache:_cache_path()), original)
assert_eq("failed write temp cleaned", temp_residue_count(cache.cache_dir), 0)

write_file(cache:_cache_path(), "{not-json")
assert_eq("corrupt schema load returns false", cache:load_from_disk(), false)
assert_true("corrupt schema warning", has_warning("corrupt cache"))
assert_true("corrupt schema removed", vim.fn.filereadable(cache:_cache_path()) == 0)

local malformed_schema_payloads = {
  [[{"schemas":"bad","tables":{}}]],
  [[{"schemas":["S"],"tables":"bad"}]],
  [[{"schemas":["S"],"tables":{"S":[]}}]],
  [[null]],
  [[]],
}
for index, payload in ipairs(malformed_schema_payloads) do
  write_file(cache:_cache_path(), payload)
  local ok, loaded = pcall(function()
    return cache:load_from_disk()
  end)
  assert_true("malformed schema load does not throw " .. index, ok)
  assert_eq("malformed schema load " .. index, loaded, false)
  assert_true("malformed schema removed " .. index, vim.fn.filereadable(cache:_cache_path()) == 0)
end

cache:build_from_metadata_rows({
  { schema_name = "S", table_name = "T", obj_type = "table" },
})
cache:save_to_disk()
local corrupt_col = cache:_columns_cache_path("S.T")
write_file(corrupt_col, "{not-json")
assert_eq("valid schema loads", cache:load_from_disk(), true)
assert_true("corrupt column warning", has_warning("loading columns"))
assert_true("corrupt column removed", vim.fn.filereadable(corrupt_col) == 0)

local malformed_column_payloads = {
  "{ }",
  "null",
  "[{}]",
  vim.json.encode({ { name = "ID" } }),
  vim.json.encode({ { type = "NUMBER" } }),
}
for index, payload in ipairs(malformed_column_payloads) do
  write_file(corrupt_col, payload)
  assert_eq("malformed column load " .. index, cache:load_from_disk(), true)
  assert_true("malformed column removed " .. index, vim.fn.filereadable(corrupt_col) == 0)
end

local prune_cache = new_cache("disk-prune")
local uv = vim.uv or vim.loop
for i = 1, 3 do
  local key = string.format("S.OLD_%03d", i)
  write_file(prune_cache:_columns_cache_path(key), vim.json.encode({
    { name = "OLD_ID", type = "NUMBER" },
  }))
  local old = os.time() - (31 * 24 * 60 * 60)
  uv.fs_utime(prune_cache:_columns_cache_path(key), old, old)
end
prune_cache:schedule_disk_prune()
vim.wait(1000, function()
  return prune_cache:get_stats().disk_pruned >= 3
end, 20)
assert_true("old files pruned", prune_cache:get_stats().disk_pruned >= 3)

local large_cache = new_cache("disk-large")
large_cache:build_from_metadata_rows({
  { schema_name = "S", table_name = "T", obj_type = "table" },
})
large_cache:save_to_disk()
for i = 1, 10000 do
  local key = string.format("S.T%05d", i)
  write_file(large_cache:_columns_cache_path(key), vim.json.encode({
    { name = "ID", type = "NUMBER" },
  }))
end
assert_eq("large schema loads", large_cache:load_from_disk(), true)
local large_stats = large_cache:get_stats()
assert_true("sync discovery bounded", large_stats.sync_column_files_discovered <= 100)
assert_true("sync load bounded", large_stats.sync_column_files_loaded <= 100)
large_cache:cancel_async("test")

local deferred_prune_cache = new_cache("disk-deferred-prune")
deferred_prune_cache:build_from_metadata_rows({
  { schema_name = "S", table_name = "T", obj_type = "table" },
})
deferred_prune_cache:save_to_disk()
for i = 1, 150 do
  local key = string.format("S.DEFERRED_OLD_%03d", i)
  local path = deferred_prune_cache:_columns_cache_path(key)
  write_file(path, vim.json.encode({
    { name = "OLD_ID", type = "NUMBER" },
  }))
  local old = os.time() - (31 * 24 * 60 * 60)
  uv.fs_utime(path, old, old)
end
assert_eq("deferred prune schema loads", deferred_prune_cache:load_from_disk(), true)
local deferred_initial = deferred_prune_cache:get_stats()
assert_true("deferred prune sync discovery bounded", deferred_initial.sync_column_files_discovered <= 100)
vim.wait(3000, function()
  local stats = deferred_prune_cache:get_stats()
  return stats.deferred_disk_work_drained and stats.disk_pruned >= 150
end, 20)
local deferred_stats = deferred_prune_cache:get_stats()
assert_true("deferred prune drained", deferred_stats.deferred_disk_work_drained)
assert_true("deferred prune processed remainder", deferred_stats.deferred_column_files_processed >= 50)
assert_true("deferred prune removed all old files", deferred_stats.disk_pruned >= 150)
assert_eq("deferred prune files gone", #vim.fn.glob(deferred_prune_cache.cache_dir .. "/" .. "disk-deferred-prune_cols_*.json", false, true), 0)

local fenced_cache = new_cache("disk-fenced")
local fenced_files = {}
for i = 1, 125 do
  local key = string.format("S.DEFER_%03d", i)
  local path = fenced_cache:_columns_cache_path(key)
  write_file(path, vim.json.encode({
    { name = "ID", type = "NUMBER" },
  }))
  fenced_files[#fenced_files + 1] = {
    path = path,
    stat = (vim.uv or vim.loop).fs_stat(path),
  }
end
fenced_cache:_schedule_deferred_column_work(fenced_files, 1)
assert_true("fenced work scheduled", fenced_cache:get_stats().deferred_column_files_scheduled > 0)
fenced_cache:invalidate()
vim.wait(1000, function()
  return fenced_cache:get_stats().deferred_disk_work_canceled > 0
end, 20)
assert_eq("fenced columns stay empty", fenced_cache:get_stats().column_entry_count, 0)
assert_true("deferred work canceled", fenced_cache:get_stats().deferred_disk_work_canceled > 0)

vim.notify = saved_notify

print("LSP11_ATOMIC_WRITE_OK=true")
print("LSP11_CORRUPT_CACHE_RECOVERED=true")
print("LSP11_DISK_CORRUPT_RECOVERY_OK=true")
print("LSP11_DISK_INDEX_CORRUPT_RECOVERY_OK=true")
print("LSP11_DISK_PRUNE_COUNT=" .. tostring(prune_cache:get_stats().disk_pruned))
print("LSP11_DISK_CACHE_ISOLATED=true")
print("LSP11_DISK_LOAD_BOUNDED=true")
print("LSP11_DISK_DEFERRED_GENERATION_FENCED=true")
print("LSP11_DISK_DISCOVERY_BOUNDED=true")
print("LSP11_DISK_DEFERRED_PRUNE_DRAINED=true")

vim.fn.delete(root, "rf")
vim.cmd("qa!")
