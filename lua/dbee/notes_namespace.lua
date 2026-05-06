local M = {}

-- Public exports:
-- validate_folder_id, has_folder_prefix, is_folder_namespace, parse_folder_namespace,
-- folder_namespace_id, folder_namespace_dir, ensure_folder_namespace,
-- read_folder_namespace_notes, create_note_in_folder.
--
-- Internal exports:
-- delete_folder_namespace, list_existing_folder_namespaces, recursive_rmdir.

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

---@private
---@param folder_id string
local function notify_duplicate_folder_id(folder_id)
  vim.notify(
    "dbee: folder_id " .. tostring(folder_id) .. " exists in multiple sources; manual sidecar repair needed",
    vim.log.levels.ERROR
  )
end

---@param notes_dir string
---@param folder_id string
---@param handler? Handler
---@return boolean
---@return string? err
function M.ensure_folder_namespace(notes_dir, folder_id, handler)
  local ok_dir, dir_or_err = pcall(M.folder_namespace_dir, notes_dir, folder_id)
  if not ok_dir then
    return false, tostring(dir_or_err)
  end

  if handler and type(handler.list_all_folder_ids_across_sources) == "function" then
    local counts, error_kind = handler:list_all_folder_ids_across_sources()
    if error_kind then
      return false, error_kind
    end
    if (counts[folder_id] or 0) > 1 then
      notify_duplicate_folder_id(folder_id)
      return false, "duplicate_folder_id"
    end
  end

  local mkdir_ok = vim.fn.mkdir(dir_or_err, "p")
  if mkdir_ok == 0 then
    return false, "mkdir_failed"
  end
  return true
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

---@param notes_dir string
---@param folder_id string
---@return boolean
---@return string? err
function M.delete_folder_namespace(notes_dir, folder_id)
  local ok_dir, dir_or_err = pcall(M.folder_namespace_dir, notes_dir, folder_id)
  if not ok_dir then
    return false, tostring(dir_or_err)
  end
  if vim.fn.isdirectory(dir_or_err) ~= 1 then
    return true
  end
  return M.recursive_rmdir(dir_or_err)
end

return M
