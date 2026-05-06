local notes_namespace = require("dbee.notes_namespace")

local uv = vim.uv or vim.loop

local M = {}

-- Phase 23 migration owns the one-time transition from installation-wide
-- `notes/global/` files to folder-scoped `notes/folder:<id>/` namespaces.
--
-- On-disk coordination artifacts:
-- - `.notes-migration-v1.promote-manifest` pre-records every staged rename
--   before promotion starts, then flips `promote_complete` after all renames.
-- - `.notes-migration-v1.recovery-needed` is written only when promotion
--   completed but the sentinel write failed.
--
-- In-memory rollback state:
-- - `promote_rollback_paths` tracks final files created by the current
--   process so same-process promotion failures delete only migration-created
--   files, never pre-existing folder notes.
--
-- State flags:
-- - `m.migration_attempted` is set by the first two lines of `maybe_run`.
--   It is a per-process retry guard and defense-in-depth for future direct
--   callers outside setup_handler().
-- - `m.migration_fatal_failed` is owned by state.lua's pcall wrapper and is
--   read only by the fatal latch helper.
--
-- `register()` failure remains out of Phase 23 migration-latch scope. The
-- pre-existing register-once landmine is documented in state.lua; users
-- restart nvim to recover from register-fail.

local VERSION = ".notes-migration-v1"
local LOCK_NAME = ".notes-migration-v1.lock"
local PROMOTE_MANIFEST_NAME = ".notes-migration-v1.promote-manifest"
local RECOVERY_NEEDED_NAME = ".notes-migration-v1.recovery-needed"
local FAILURE_LOG_NAME = ".notes-migration-v1.last-failure.log"
local STAGING_PREFIX = ".notes-migration-v1.staging-"
local TRASH_PREFIX = ".notes-migration-v1.trash-"
local FRESH_LOCK_SECONDS = 300
local SCRATCH_STALE_SECONDS = 3600

local CROSS_FS_NOTIFY =
  "dbee: migration aborted — cross-filesystem rename detected; not supported. Move notes/ off bind mounts and retry, OR set editor.directory in setup() to a same-filesystem path and retry."
local LOAD_FAILED_NOTIFY = "dbee: migration aborted — folder source load failed; fix sidecar before retrying"

local function path_join(...)
  local parts = { ... }
  local out = tostring(parts[1] or "")
  for i = 2, #parts do
    local part = tostring(parts[i] or "")
    if out:sub(-1) == "/" then
      out = out .. part
    else
      out = out .. "/" .. part
    end
  end
  return out
end

local function stat(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  return uv.fs_stat(path)
end

local function exists(path)
  return stat(path) ~= nil
end

local function is_dir(path)
  local s = stat(path)
  return s and s.type == "directory"
end

local function file_size(path)
  local s = stat(path)
  return s and s.size or nil
end

local function basename(path)
  return vim.fs.basename(path)
end

local function dirname(path)
  return vim.fs.dirname(path)
end

local function migration_path(notes_dir, name)
  return path_join(notes_dir, name)
end

local function sentinel_path(notes_dir)
  return migration_path(notes_dir, VERSION)
end

local function lock_path(notes_dir)
  return migration_path(notes_dir, LOCK_NAME)
end

local function promote_manifest_path(notes_dir)
  return migration_path(notes_dir, PROMOTE_MANIFEST_NAME)
end

local function recovery_needed_path(notes_dir)
  return migration_path(notes_dir, RECOVERY_NEEDED_NAME)
end

local function failure_log_path(notes_dir)
  return migration_path(notes_dir, FAILURE_LOG_NAME)
end

local function now_iso()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function random_token()
  local pid = tostring(vim.fn.getpid())
  return pid .. "-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
end

local function safe_unlink(path)
  if path and path ~= "" then
    pcall(vim.fn.delete, path)
  end
end

local function write_file_atomic(path, content)
  local tmp = path .. ".tmp"
  local file, open_err = io.open(tmp, "w")
  if not file then
    return false, tostring(open_err)
  end
  file:write(content)
  file:close()
  local ok, err = uv.fs_rename(tmp, path)
  if not ok then
    safe_unlink(tmp)
    return false, tostring(err)
  end
  return true
end

local function write_json_atomic(path, value)
  local ok_encode, encoded = pcall(vim.json.encode, value)
  if not ok_encode then
    return false, tostring(encoded)
  end
  return write_file_atomic(path, encoded)
end

local function read_file(path, limit)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local content = limit and file:read(limit) or file:read("*a")
  file:close()
  return content
end

local function read_json_file(path)
  local content = read_file(path)
  if not content or content == "" then
    return nil, "missing"
  end
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    return nil, "decode_failed"
  end
  return decoded
end

local function scandir_names(dir)
  local handle = uv.fs_scandir(dir)
  if not handle then
    return {}
  end
  local names = {}
  while true do
    local name = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

local function list_sql_files(dir)
  local files = {}
  if not is_dir(dir) then
    return files
  end
  for _, name in ipairs(scandir_names(dir)) do
    if name:sub(-4) == ".sql" then
      local file = path_join(dir, name)
      if vim.fn.filereadable(file) == 1 then
        files[#files + 1] = file
      end
    end
  end
  table.sort(files, function(a, b)
    return basename(a) < basename(b)
  end)
  return files
end

local function copy_file(src, dst)
  local in_file, in_err = io.open(src, "rb")
  if not in_file then
    return false, tostring(in_err)
  end
  local data = in_file:read("*a")
  in_file:close()

  local out_file, out_err = io.open(dst, "wb")
  if not out_file then
    return false, tostring(out_err)
  end
  out_file:write(data)
  out_file:close()
  return true
end

local function is_exdev(err)
  return tostring(err or ""):find("EXDEV", 1, true) ~= nil
end

local function ensure_dir(path)
  return vim.fn.mkdir(path, "p") ~= 0
end

local function stat_age_seconds(path)
  local s = stat(path)
  if not s or not s.mtime or not s.mtime.sec then
    return nil
  end
  return os.time() - s.mtime.sec
end

local function pid_alive(pid)
  pid = tonumber(pid)
  if not pid or pid <= 0 then
    return false
  end
  local ok, result = pcall(uv.kill, pid, 0)
  return ok and (result == 0 or result == true)
end

local function gc_stale_scratch_dirs(notes_dir)
  local removed = 0
  for _, name in ipairs(scandir_names(notes_dir)) do
    local pid = name:match("^" .. vim.pesc(STAGING_PREFIX) .. "(%d+)%-")
      or name:match("^" .. vim.pesc(TRASH_PREFIX) .. "(%d+)%-")
    if pid then
      local path = path_join(notes_dir, name)
      local age = stat_age_seconds(path)
      local keep = age and age <= SCRATCH_STALE_SECONDS and pid_alive(pid)
      if not keep then
        local ok = notes_namespace.recursive_rmdir(path)
        if ok then
          removed = removed + 1
        end
      end
    end
  end
  if removed > 0 then
    io.stderr:write("dbee notes migration removed stale scratch dirs: " .. tostring(removed) .. "\n")
  end
end

local function source_supports_folders(source)
  return type(source.supports_folders) == "function" and source:supports_folders() == true
end

local function folder_sources(handler)
  local ok_sources, sources = pcall(handler.get_sources, handler)
  if not ok_sources or type(sources) ~= "table" then
    return nil, "load_failed"
  end
  local ret = {}
  for _, source in ipairs(sources) do
    local ok_supports, supports = pcall(source_supports_folders, source)
    if not ok_supports then
      return nil, "load_failed"
    end
    if supports then
      ret[#ret + 1] = source
    end
  end
  return ret
end

local function notify_load_failed()
  vim.notify(LOAD_FAILED_NOTIFY, vim.log.levels.WARN)
end

local function prelock_probe_sources(handler)
  local sources, source_err = folder_sources(handler)
  if not sources then
    notify_load_failed()
    return false, source_err
  end
  for _, source in ipairs(sources) do
    if type(source.load_folders) ~= "function" then
      notify_load_failed()
      return false, "load_failed"
    end
    local ok = pcall(source.load_folders, source)
    if not ok or source._folders_load_state == "load_failed" then
      notify_load_failed()
      return false, "load_failed"
    end
  end
  return true
end

local function refresh_folder_snapshot_under_lock(handler)
  local sources, source_err = folder_sources(handler)
  if not sources then
    notify_load_failed()
    return nil, source_err
  end
  for _, source in ipairs(sources) do
    source._folders_load_state = "unloaded"
    source._folders_load_error = nil
    source._folders_cache = nil
    local ok
    if type(source._ensure_folders_loaded) == "function" then
      ok = pcall(source._ensure_folders_loaded, source)
    elseif type(source.load_folders) == "function" then
      ok = pcall(source.load_folders, source)
    else
      ok = false
    end
    if not ok or source._folders_load_state == "load_failed" then
      notify_load_failed()
      return nil, "load_failed"
    end
  end

  local counts, error_kind = handler:list_all_folder_ids_across_sources()
  if error_kind then
    notify_load_failed()
    return nil, error_kind
  end

  local folder_ids = {}
  for folder_id, count in pairs(counts or {}) do
    if count > 1 then
      vim.notify(
        "dbee: duplicate folder_id detected across sources; migration aborted. Repair sidecars before retry.",
        vim.log.levels.ERROR
      )
      return nil, "duplicate_folder_id"
    end
    if count == 1 then
      folder_ids[#folder_ids + 1] = folder_id
    end
  end
  table.sort(folder_ids)
  return folder_ids
end

local function remove_lock(path)
  if is_dir(path) then
    pcall(uv.fs_rmdir, path)
  end
end

local function acquire_lock(notes_dir)
  local path = lock_path(notes_dir)
  local ok, err = uv.fs_mkdir(path, 448)
  if ok then
    return true, path
  end

  if not exists(path) and tostring(err or ""):find("EEXIST", 1, true) == nil then
    return false, "lock_create_failed: " .. tostring(err)
  end

  local age = stat_age_seconds(path)
  if age and age >= 0 and age < FRESH_LOCK_SECONDS then
    return false, "lock_held"
  end

  remove_lock(path)
  ok, err = uv.fs_mkdir(path, 448)
  if ok then
    return true, path
  end
  if exists(path) then
    return false, "lock_held"
  end
  return false, "lock_create_failed: " .. tostring(err)
end

local function fs_signature(info)
  if type(info) ~= "table" then
    return nil
  end
  return table.concat({
    tostring(info.type or ""),
    tostring(info.bsize or ""),
    tostring(info.frsize or ""),
    tostring(info.blocks or ""),
    tostring(info.files or ""),
  }, ":")
end

local function same_fs_preflight(notes_dir)
  if type(uv.fs_statfs) ~= "function" then
    return true
  end
  local precheck = path_join(notes_dir, VERSION .. ".staging-precheck-tmp")
  pcall(notes_namespace.recursive_rmdir, precheck)
  local ok_mkdir, mkdir_err = uv.fs_mkdir(precheck, 448)
  if not ok_mkdir and not is_dir(precheck) then
    return false, "precheck_mkdir_failed: " .. tostring(mkdir_err)
  end
  local notes_stat = uv.fs_statfs(notes_dir)
  local precheck_stat = uv.fs_statfs(precheck)
  pcall(uv.fs_rmdir, precheck)
  if fs_signature(notes_stat) ~= fs_signature(precheck_stat) then
    vim.notify(CROSS_FS_NOTIFY, vim.log.levels.ERROR)
    return false, "cross_filesystem"
  end
  return true
end

local function backup_path_for_global(notes_dir)
  local default = path_join(notes_dir, "global.bak")
  if not exists(default) then
    return default
  end
  return path_join(notes_dir, "global.bak." .. os.date("%Y%m%d%H%M%S"))
end

local function backup_global_dir(notes_dir)
  local global_dir = path_join(notes_dir, "global")
  if not is_dir(global_dir) then
    return true, nil
  end
  local backup_path = backup_path_for_global(notes_dir)
  local ok, err = uv.fs_rename(global_dir, backup_path)
  if not ok then
    return false, tostring(err), backup_path
  end
  return true, backup_path
end

local function write_sentinel(notes_dir)
  return write_file_atomic(sentinel_path(notes_dir), "migrated_at=" .. now_iso() .. "\n")
end

local function planned_dst_unique_per_folder(entries)
  local per_folder = {}
  for _, entry in ipairs(entries or {}) do
    local folder = dirname(entry.planned_dst or "")
    per_folder[folder] = per_folder[folder] or {}
    if per_folder[folder][entry.planned_dst] then
      return false
    end
    per_folder[folder][entry.planned_dst] = true
  end
  return true
end

local function split_sql_basename(name)
  local stem = name:match("^(.*)%.sql$")
  if stem then
    return stem, ".sql"
  end
  return name, ""
end

local function collision_basename(src_basename, n)
  local stem, ext = split_sql_basename(src_basename)
  if n == 1 then
    return stem .. ".global-migrated" .. ext
  end
  return stem .. ".global-migrated." .. tostring(n) .. ext
end

local function basename_matches_planned(src_basename, actual_basename)
  if actual_basename == src_basename then
    return true
  end
  if actual_basename == collision_basename(src_basename, 1) then
    return true
  end
  return actual_basename:match("^" .. vim.pesc((split_sql_basename(src_basename))) .. "%.global%-migrated%.%d+%.sql$") ~= nil
end

local function validate_promote_manifest(manifest, require_staging_absent)
  if type(manifest) ~= "table" or type(manifest.entries) ~= "table" then
    return false, "manifest malformed"
  end
  if #manifest.entries ~= tonumber(manifest.expected_count or -1) then
    return false, "manifest count mismatch"
  end
  if not planned_dst_unique_per_folder(manifest.entries) then
    return false, "planned destinations not unique"
  end
  for _, entry in ipairs(manifest.entries) do
    if require_staging_absent and exists(entry.src_staging) then
      return false, "staging source still exists"
    end
    local size = file_size(entry.planned_dst)
    if not size or size <= 0 then
      return false, "planned destination missing"
    end
    if tonumber(entry.src_size_bytes or -1) ~= size then
      return false, "planned destination size mismatch"
    end
    if not basename_matches_planned(tostring(entry.src_basename or ""), basename(entry.planned_dst or "")) then
      return false, "planned destination basename mismatch"
    end
  end
  return true
end

local function final_paths_from_entries(entries)
  local final_paths = {}
  local final_sizes = {}
  for _, entry in ipairs(entries or {}) do
    final_paths[#final_paths + 1] = entry.planned_dst
    final_sizes[entry.planned_dst] = tonumber(entry.src_size_bytes or 0)
  end
  return final_paths, final_sizes
end

local function write_recovery_needed(notes_dir, manifest, backup_path, global_deleted)
  local final_paths, final_sizes = final_paths_from_entries(manifest.entries)
  return write_json_atomic(recovery_needed_path(notes_dir), {
    folder_ids = manifest.folder_ids or {},
    final_paths = final_paths,
    final_sizes = final_sizes,
    backup_path = backup_path,
    global_deleted = global_deleted == true,
    migration_run_ts = manifest.migration_run_ts,
    timestamp = now_iso(),
  })
end

local function complete_after_promotion(notes_dir, manifest)
  local backup_ok, backup_result = backup_global_dir(notes_dir)
  if not backup_ok then
    vim.notify("dbee: backup of legacy global notes failed after folder clone; continuing with migrated notes", vim.log.levels.WARN)
  end

  local global_dir = path_join(notes_dir, "global")
  local global_deleted = true
  if is_dir(global_dir) then
    local ok_delete = notes_namespace.recursive_rmdir(global_dir)
    global_deleted = ok_delete == true and not is_dir(global_dir)
    if not ok_delete then
      vim.notify("dbee: legacy global notes could not be deleted after migration; folder notes are already in place", vim.log.levels.WARN)
    end
  end

  local ok_sentinel, sentinel_err = write_sentinel(notes_dir)
  if not ok_sentinel then
    vim.notify("dbee: notes migration completed but sentinel write failed; run :Dbee notes_migration_inspect", vim.log.levels.WARN)
    write_recovery_needed(notes_dir, manifest, backup_result, global_deleted)
    return false, sentinel_err
  end

  safe_unlink(promote_manifest_path(notes_dir))
  return true, backup_result, global_deleted
end

local function final_paths_superset(recovery, promote)
  local set = {}
  for _, path in ipairs(recovery.final_paths or {}) do
    set[path] = true
  end
  for _, entry in ipairs(promote.entries or {}) do
    if not set[entry.planned_dst] then
      return false
    end
  end
  return true
end

local function validate_recovery_manifest(recovery)
  if type(recovery) ~= "table" or type(recovery.final_paths) ~= "table" then
    return false
  end
  for _, final_path in ipairs(recovery.final_paths) do
    local size = file_size(final_path)
    if not size or size <= 0 then
      return false
    end
    local expected = recovery.final_sizes and tonumber(recovery.final_sizes[final_path])
    if expected and expected ~= size then
      return false
    end
  end
  return true
end

local function handle_recovery_needed(notes_dir)
  local recovery, recovery_err = read_json_file(recovery_needed_path(notes_dir))
  if not recovery then
    return false, recovery_err
  end

  local promote = nil
  if exists(promote_manifest_path(notes_dir)) then
    promote = read_json_file(promote_manifest_path(notes_dir))
    if
      not promote
      or recovery.migration_run_ts ~= promote.migration_run_ts
      or not final_paths_superset(recovery, promote)
    then
      vim.notify("dbee: manifest mismatch; inspect via :Dbee notes_migration_inspect; manually resolve", vim.log.levels.ERROR)
      return false, "manifest_mismatch"
    end
  end

  if not validate_recovery_manifest(recovery) then
    vim.notify("dbee: recovery manifest validation failed; run :Dbee notes_migration_inspect", vim.log.levels.ERROR)
    return false, "recovery_validation_failed"
  end

  local ok_sentinel, sentinel_err = write_sentinel(notes_dir)
  if not ok_sentinel then
    return false, sentinel_err
  end
  safe_unlink(recovery_needed_path(notes_dir))
  safe_unlink(promote_manifest_path(notes_dir))
  return true, "recovered"
end

local function handle_promote_manifest(notes_dir)
  local manifest, read_err = read_json_file(promote_manifest_path(notes_dir))
  if not manifest then
    return false, read_err
  end

  local require_staging_absent = manifest.promote_complete == false
  local ok_validate, validate_err = validate_promote_manifest(manifest, require_staging_absent)
  if not ok_validate then
    if require_staging_absent then
      vim.notify(
        "dbee: promote crashed mid-flight; run :Dbee notes_migration_inspect to inspect notes/.notes-migration-v1.staging-* directories before retry",
        vim.log.levels.ERROR
      )
    end
    return false, validate_err
  end

  local ok_complete, complete_err = complete_after_promotion(notes_dir, manifest)
  if not ok_complete then
    return false, complete_err
  end
  return true, "promote_recovered"
end

local function handle_post_lock_artifacts(notes_dir)
  if exists(sentinel_path(notes_dir)) then
    return true, "sentinel"
  end
  if exists(recovery_needed_path(notes_dir)) then
    return handle_recovery_needed(notes_dir)
  end
  if exists(promote_manifest_path(notes_dir)) then
    return handle_promote_manifest(notes_dir)
  end
  return nil
end

local function choose_planned_dst(final_dir, source_basename, reserved)
  local preferred = path_join(final_dir, source_basename)
  if not reserved[preferred] then
    reserved[preferred] = true
    return preferred, nil
  end
  local suffix_index = 1
  while true do
    local candidate_name = collision_basename(source_basename, suffix_index)
    local candidate = path_join(final_dir, candidate_name)
    if not reserved[candidate] then
      reserved[candidate] = true
      if suffix_index == 1 then
        return candidate, ".global-migrated"
      end
      return candidate, ".global-migrated." .. tostring(suffix_index)
    end
    suffix_index = suffix_index + 1
  end
end

local function build_reserved_set(final_dir)
  local reserved = {}
  if is_dir(final_dir) then
    for _, name in ipairs(scandir_names(final_dir)) do
      local path = path_join(final_dir, name)
      if vim.fn.filereadable(path) == 1 then
        reserved[path] = true
      end
    end
  end
  return reserved
end

local function stage_global_notes(notes_dir, folder_ids, global_files)
  local staging_dir = path_join(notes_dir, STAGING_PREFIX .. random_token())
  if not ensure_dir(staging_dir) then
    return nil, nil, "staging_mkdir_failed"
  end

  local entries = {}
  for _, folder_id in ipairs(folder_ids) do
    local namespace = notes_namespace.folder_namespace_id(folder_id)
    local final_dir = notes_namespace.folder_namespace_dir(notes_dir, folder_id)
    local staged_dir = path_join(staging_dir, namespace)
    if not ensure_dir(staged_dir) then
      notes_namespace.recursive_rmdir(staging_dir)
      return nil, nil, "staging_folder_mkdir_failed"
    end

    local reserved = build_reserved_set(final_dir)
    for _, global_file in ipairs(global_files) do
      local src_basename = basename(global_file)
      local staged_path = path_join(staged_dir, src_basename)
      local ok_copy, copy_err = copy_file(global_file, staged_path)
      if not ok_copy then
        notes_namespace.recursive_rmdir(staging_dir)
        return nil, nil, copy_err
      end

      local planned_dst, collision_suffix = choose_planned_dst(final_dir, src_basename, reserved)
      entries[#entries + 1] = {
        src_staging = staged_path,
        src_basename = src_basename,
        planned_dst = planned_dst,
        collision_suffix = collision_suffix,
        src_size_bytes = file_size(staged_path) or 0,
      }
    end
  end
  return staging_dir, entries
end

local function verify_staging(entries, expected_count)
  if #entries ~= expected_count then
    return false, "staging count mismatch"
  end
  if not planned_dst_unique_per_folder(entries) then
    return false, "planned destination collision"
  end
  for _, entry in ipairs(entries) do
    if not exists(entry.src_staging) then
      return false, "missing staged source"
    end
    if basename(entry.src_staging) ~= entry.src_basename then
      return false, "staged basename mismatch"
    end
    if file_size(entry.src_staging) ~= entry.src_size_bytes then
      return false, "staged size mismatch"
    end
  end
  return true
end

local function promote_staging(notes_dir, staging_dir, entries, folder_ids, migration_run_ts)
  local promote_rollback_paths = {}
  local manifest = {
    expected_count = #entries,
    promote_complete = false,
    migration_run_ts = migration_run_ts,
    reserved_dst_uniqueness_assertion = true,
    folder_ids = vim.deepcopy(folder_ids),
    entries = entries,
  }

  local ok_manifest, manifest_err = write_json_atomic(promote_manifest_path(notes_dir), manifest)
  if not ok_manifest then
    return nil, manifest_err
  end

  for _, entry in ipairs(entries) do
    local final_dir = dirname(entry.planned_dst)
    if not ensure_dir(final_dir) then
      return nil, "final_dir_mkdir_failed"
    end
    local ok_rename, rename_err = uv.fs_rename(entry.src_staging, entry.planned_dst)
    if not ok_rename then
      if is_exdev(rename_err) then
        vim.notify(CROSS_FS_NOTIFY, vim.log.levels.ERROR)
        return nil, "EXDEV"
      end
      for _, path in ipairs(promote_rollback_paths) do
        safe_unlink(path)
      end
      return nil, tostring(rename_err)
    end
    promote_rollback_paths[#promote_rollback_paths + 1] = entry.planned_dst
  end

  manifest.promote_complete = true
  ok_manifest, manifest_err = write_json_atomic(promote_manifest_path(notes_dir), manifest)
  if not ok_manifest then
    return nil, manifest_err
  end
  notes_namespace.recursive_rmdir(staging_dir)
  return manifest
end

local function write_zero_folder_sentinel(notes_dir)
  local ok_sentinel, sentinel_err = write_sentinel(notes_dir)
  if not ok_sentinel then
    error("sentinel write failed: " .. tostring(sentinel_err))
  end
end

local function migrate_zero_folder_global(notes_dir)
  local backup_ok, backup_result = backup_global_dir(notes_dir)
  if not backup_ok then
    vim.notify("dbee: backup of legacy global notes failed; migration aborted to prevent data loss", vim.log.levels.ERROR)
    error("global backup failed: " .. tostring(backup_result))
  end
  local global_dir = path_join(notes_dir, "global")
  if is_dir(global_dir) then
    notes_namespace.recursive_rmdir(global_dir)
  end
  write_zero_folder_sentinel(notes_dir)
  vim.notify(
    "dbee: legacy global notes backed up to "
      .. tostring(backup_result)
      .. "; create a folder to enable global notes per folder",
    vim.log.levels.WARN
  )
end

local function run_fresh_migration(handler, notes_dir)
  local folder_ids, folder_err = refresh_folder_snapshot_under_lock(handler)
  if not folder_ids then
    return false, folder_err
  end

  local global_dir = path_join(notes_dir, "global")
  local global_files = list_sql_files(global_dir)

  if #global_files == 0 then
    for _, folder_id in ipairs(folder_ids) do
      local ok_ensure, ensure_err = notes_namespace.ensure_folder_namespace(notes_dir, folder_id, handler)
      if not ok_ensure then
        return false, ensure_err
      end
    end
    write_zero_folder_sentinel(notes_dir)
    return true
  end

  if #folder_ids == 0 then
    migrate_zero_folder_global(notes_dir)
    return true
  end

  vim.notify("dbee: migrating " .. tostring(#global_files) .. " notes into " .. tostring(#folder_ids) .. " folders", vim.log.levels.INFO)

  local ok_fs, fs_err = same_fs_preflight(notes_dir)
  if not ok_fs then
    return false, fs_err
  end

  local staging_dir, entries, stage_err = stage_global_notes(notes_dir, folder_ids, global_files)
  if not staging_dir then
    return false, stage_err
  end

  local ok_verify, verify_err = verify_staging(entries, #global_files * #folder_ids)
  if not ok_verify then
    notes_namespace.recursive_rmdir(staging_dir)
    return false, verify_err
  end

  local migration_run_ts = now_iso()
  local manifest, promote_err = promote_staging(notes_dir, staging_dir, entries, folder_ids, migration_run_ts)
  if not manifest then
    return false, promote_err
  end

  local ok_complete, complete_err = complete_after_promotion(notes_dir, manifest)
  if not ok_complete then
    return false, complete_err
  end

  vim.notify("dbee: global notes are now folder-scoped; access via <C-g>/<C-l> in the notes picker", vim.log.levels.INFO)
  return true
end

function M.is_migration_in_progress(notes_dir)
  if type(notes_dir) ~= "string" or notes_dir == "" then
    return false
  end
  if exists(sentinel_path(notes_dir)) then
    return false
  end
  if not is_dir(lock_path(notes_dir)) then
    return false
  end
  local age = stat_age_seconds(lock_path(notes_dir))
  return age ~= nil and age >= 0 and age < FRESH_LOCK_SECONDS
end

---@param handler Handler
---@param notes_dir string
---@param m table
---@return boolean|nil
---@return string? error_kind
function M.maybe_run(handler, notes_dir, m)
  if m.migration_attempted then return end
  m.migration_attempted = true

  if vim.fn.mkdir(notes_dir, "p") == 0 then
    vim.notify("dbee: cannot create notes directory: " .. tostring(notes_dir) .. "; check permissions", vim.log.levels.ERROR)
    error("cannot create notes directory: " .. tostring(notes_dir))
  end

  gc_stale_scratch_dirs(notes_dir)

  local ok_probe, probe_err = prelock_probe_sources(handler)
  if not ok_probe then
    return false, probe_err
  end

  local acquired, lock_or_err = acquire_lock(notes_dir)
  if not acquired then
    return false, lock_or_err
  end

  local ok, result, err = pcall(function()
    local artifact_result, artifact_err = handle_post_lock_artifacts(notes_dir)
    if artifact_result ~= nil then
      return artifact_result, artifact_err
    end
    return run_fresh_migration(handler, notes_dir)
  end)

  remove_lock(lock_or_err)

  if not ok then
    error(result)
  end
  return result, err
end

return M
