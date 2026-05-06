local M = {}

-- Public exports:
-- validate_folder_id, has_folder_prefix, is_folder_namespace, parse_folder_namespace,
-- folder_namespace_id, folder_namespace_dir, ensure_folder_namespace,
-- read_folder_namespace_notes, create_note_in_folder, encode_local_namespace_path,
-- decode_local_namespace_path.
--
-- Internal exports:
-- _ensure_folder_namespace_unchecked_for_migration, delete_folder_namespace,
-- list_existing_folder_namespaces, recursive_rmdir.

---@param folder_id any
---@return boolean
function M.validate_folder_id(folder_id)
  return type(folder_id) == "string" and folder_id:match("^folder_[A-Za-z0-9]+$") ~= nil
end

---@param ns any
---@return boolean
function M.has_folder_prefix(ns)
  return type(ns) == "string" and #ns >= 7 and ns:sub(1, 7) == "folder:"
end

---@param ns any
---@return boolean
function M.is_folder_namespace(ns)
  return M.has_folder_prefix(ns)
end

---@param ns any
---@return string|nil
function M.parse_folder_namespace(ns)
  if not M.has_folder_prefix(ns) then
    return nil
  end
  local folder_id = ns:sub(8)
  if M.validate_folder_id(folder_id) then
    return folder_id
  end
  return nil
end

---@param folder_id string
---@return string
function M.folder_namespace_id(folder_id)
  if not M.validate_folder_id(folder_id) then
    error("invalid folder_id: " .. tostring(folder_id))
  end
  return "folder:" .. folder_id
end

---@param notes_dir string
---@param folder_id string
---@return string
function M.folder_namespace_dir(notes_dir, folder_id)
  if type(notes_dir) ~= "string" or notes_dir == "" then
    error("invalid notes_dir")
  end
  return notes_dir .. "/" .. M.folder_namespace_id(folder_id)
end

---@param namespace string
---@return string
function M.encode_local_namespace_path(namespace)
  if type(namespace) ~= "string" or namespace == "" then
    error("invalid namespace")
  end
  return (namespace:gsub("[^A-Za-z0-9_-]", function(char)
    return string.format("%%%02X", string.byte(char))
  end))
end

---@param path_component string
---@return string
function M.decode_local_namespace_path(path_component)
  if type(path_component) ~= "string" or path_component == "" then
    error("invalid namespace path")
  end
  return (path_component:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

---@private
---@param folder_id string
local function notify_duplicate_folder_id(folder_id)
  vim.notify(
    "dbee: folder_id " .. tostring(folder_id) .. " exists in multiple sources; manual sidecar repair needed",
    vim.log.levels.ERROR
  )
end

---@private
---@param notes_dir string
---@param folder_id string
---@return boolean
---@return string? err
local function ensure_folder_namespace_dir(notes_dir, folder_id)
  local ok_dir, dir_or_err = pcall(M.folder_namespace_dir, notes_dir, folder_id)
  if not ok_dir then
    return false, tostring(dir_or_err)
  end

  local mkdir_ok = vim.fn.mkdir(dir_or_err, "p")
  if mkdir_ok == 0 then
    return false, "mkdir_failed"
  end
  return true
end

---@private
---@param notes_dir string
---@param folder_id string
---@return boolean
---@return string? err
function M._ensure_folder_namespace_unchecked_for_migration(notes_dir, folder_id)
  return ensure_folder_namespace_dir(notes_dir, folder_id)
end

---@param notes_dir string
---@param folder_id string
---@param handler? Handler
---@return boolean
---@return string? err
function M.ensure_folder_namespace(notes_dir, folder_id, handler)
  if not handler or type(handler.list_all_folder_ids_across_sources) ~= "function" then
    return false, "missing_handler"
  end
  local counts, error_kind = handler:list_all_folder_ids_across_sources()
  if error_kind then
    return false, error_kind
  end
  local count = (counts or {})[folder_id] or 0
  if count > 1 then
    notify_duplicate_folder_id(folder_id)
    return false, "duplicate_folder_id"
  end
  if count ~= 1 then
    return false, "folder_not_found"
  end
  return ensure_folder_namespace_dir(notes_dir, folder_id)
end

---@param editor EditorUI
---@param folder_id string
---@return note_details[]|nil
---@return string? err
function M.read_folder_namespace_notes(editor, folder_id)
  local ok_ns, namespace_or_err = pcall(M.folder_namespace_id, folder_id)
  if not ok_ns then
    return nil, tostring(namespace_or_err)
  end

  local ok_notes, notes_or_err = pcall(editor.namespace_get_notes, editor, namespace_or_err, { from_authority = true })
  if not ok_notes then
    return nil, tostring(notes_or_err)
  end
  return notes_or_err or {}
end

---@param editor EditorUI
---@param notes_dir string
---@param handler Handler
---@param folder_id string
---@param name string
---@return note_id|nil
---@return string? err
function M.create_note_in_folder(editor, notes_dir, handler, folder_id, name)
  local ok_ns, namespace_or_err = pcall(M.folder_namespace_id, folder_id)
  if not ok_ns then
    return nil, tostring(namespace_or_err)
  end

  local ok_ensure, ensure_err = M.ensure_folder_namespace(notes_dir, folder_id, handler)
  if not ok_ensure then
    return nil, ensure_err
  end

  local ok_note, note_or_err =
    pcall(editor.namespace_create_note, editor, namespace_or_err, name, { from_authority = true })
  if not ok_note then
    return nil, tostring(note_or_err)
  end
  return note_or_err
end

---@param path string
---@return boolean
---@return string? err
function M.recursive_rmdir(path)
  if type(path) ~= "string" or path == "" then
    return false, "invalid path"
  end
  local ok = vim.fn.delete(path, "rf") == 0
  if not ok then
    return false, "delete_failed"
  end
  return true
end

---@param notes_dir string
---@return string[]
function M.list_existing_folder_namespaces(notes_dir)
  local namespaces = {}
  if type(notes_dir) ~= "string" or notes_dir == "" then
    return namespaces
  end
  for _, path in ipairs(vim.split(vim.fn.glob(notes_dir .. "/folder:*"), "\n", { trimempty = true })) do
    local name = vim.fs.basename(path)
    if M.is_folder_namespace(name) then
      namespaces[#namespaces + 1] = name
    end
  end
  table.sort(namespaces)
  return namespaces
end

---@private
---@param folder_id string
local function notify_delete_duplicate_folder_id(folder_id)
  vim.notify(
    "dbee: folder_id " .. tostring(folder_id) .. " duplicated across sources; refusing delete to prevent shared-namespace data loss",
    vim.log.levels.ERROR
  )
end

---@private
local function migration_trash_dir(notes_dir)
  return notes_dir
    .. "/.notes-migration-v1.trash-"
    .. tostring(vim.fn.getpid())
    .. "-"
    .. tostring(os.time())
    .. "-"
    .. tostring(math.random(100000, 999999))
end

---@private
---@param err any
---@return boolean
local function is_exdev(err)
  return tostring(err or ""):find("EXDEV", 1, true) ~= nil
end

---@param notes_dir string
---@param folder_id string
---@param source_id string
---@param handler Handler
---@return boolean
---@return string? err
function M.delete_folder_namespace(notes_dir, folder_id, source_id, handler)
  local ok_dir, dir_or_err = pcall(M.folder_namespace_dir, notes_dir, folder_id)
  if not ok_dir then
    return false, tostring(dir_or_err)
  end

  if not handler or type(handler.list_all_folder_ids_across_sources) ~= "function" then
    return false, "missing_handler"
  end
  local counts, error_kind = handler:list_all_folder_ids_across_sources()
  if error_kind then
    vim.notify("dbee: folder delete aborted — folder source load failed; fix sidecar before retrying", vim.log.levels.WARN)
    return false, error_kind
  end
  local count = counts[folder_id] or 0
  if count > 1 then
    notify_delete_duplicate_folder_id(folder_id)
    return false, "duplicate_folder_id"
  end
  if count ~= 1 then
    return false, "folder_not_found"
  end

  local trash_root = nil
  local staged_dir = nil
  local staged = false
  if vim.fn.isdirectory(dir_or_err) == 1 then
    trash_root = migration_trash_dir(notes_dir)
    staged_dir = trash_root .. "/" .. M.folder_namespace_id(folder_id)
    local mkdir_ok = vim.fn.mkdir(trash_root, "p")
    if mkdir_ok == 0 then
      return false, "trash_mkdir_failed"
    end
    local ok_rename, rename_err = vim.loop.fs_rename(dir_or_err, staged_dir)
    if not ok_rename then
      if is_exdev(rename_err) then
        vim.notify(
          "dbee: migration aborted — cross-filesystem rename detected; not supported. Move notes/ off bind mounts and retry, OR set editor.directory in setup() to a same-filesystem path and retry.",
          vim.log.levels.ERROR
        )
        M.recursive_rmdir(trash_root)
        return false, "EXDEV"
      end
      M.recursive_rmdir(trash_root)
      vim.notify("dbee: folder notes trash staging failed: " .. tostring(rename_err), vim.log.levels.ERROR)
      return false, "trash_mkdir_failed"
    end
    staged = true
  end

  local ok_remove, remove_err = pcall(handler.source_remove_folder, handler, source_id, folder_id)
  if not ok_remove then
    if staged then
      vim.fn.mkdir(vim.fs.dirname(dir_or_err), "p")
      local ok_restore, restore_err = vim.loop.fs_rename(staged_dir, dir_or_err)
      if not ok_restore then
        vim.notify(
          "dbee: folder delete failed and notes restore failed for "
            .. tostring(folder_id)
            .. ": "
            .. tostring(restore_err),
          vim.log.levels.ERROR
        )
      end
      M.recursive_rmdir(trash_root)
    end
    vim.notify("dbee: folder delete failed; restored notes when possible: " .. tostring(remove_err), vim.log.levels.ERROR)
    return false, "trash_mkdir_failed"
  end

  if staged then
    M.recursive_rmdir(trash_root)
  end
  return true
end

return M
