---@mod dbee.ref.api.ui Dbee UI API
---@brief [[
---UI API module for nvim dbee.
---
---This module contains functions to operate with UI tiles.
---Functions are prefixed with a ui name:
---- editor
---- result
---- drawer
---- call_log
---
--- Access the module like this:
--->
---require("dbee").api.ui.func()
---<
---@brief ]]

local state = require("dbee.api.state")
local notes_namespace = require("dbee.notes_namespace")

local ui = {}

---Returns true if dbee ui is loaded.
---@return boolean
function ui.is_loaded()
  return state.is_ui_loaded()
end

---@divider -
---@tag dbee.ref.api.ui.editor
---@brief [[
---Editor API
---@brief ]]

---Registers an event handler for editor events.
---@param event editor_event_name
---@param listener event_listener
function ui.editor_register_event_listener(event, listener)
  state.editor():register_event_listener(event, listener)
end

--- Search for a note with provided id across namespaces.
---@param id note_id
---@return note_details|nil
---@return namespace_id _ namespace of the note
function ui.editor_search_note(id)
  return state.editor():search_note(id)
end

--- Search for a note with provided buffer across namespaces.
---@param bufnr integer
---@return note_details|nil
---@return namespace_id _ namespace of the note
function ui.editor_search_note_with_buf(bufnr)
  return state.editor():search_note_with_buf(bufnr)
end

--- Search for a note with provided file name across namespaces.
---@param file string
---@return note_details|nil
---@return namespace_id _ namespace of the note
function ui.editor_search_note_with_file(file)
  return state.editor():search_note_with_file(file)
end

--- Creates a new note in namespace.
--- Errors if id or name is nil or there is a note with the same
--- name in namespace already.
---@param id namespace_id
---@param name string
---@return note_id
function ui.editor_namespace_create_note(id, name)
  return state.editor():namespace_create_note(id, name)
end

--- Get notes of a specified namespace.
---@param id namespace_id
---@return note_details[]
function ui.editor_namespace_get_notes(id)
  return state.editor():namespace_get_notes(id)
end

--- Removes an existing note.
--- Errors if there is no note with provided id in namespace.
---@param id namespace_id
---@param note_id note_id
function ui.editor_namespace_remove_note(id, note_id)
  state.editor():namespace_remove_note(id, note_id)
end

---@param folder_id string
---@param name string
---@return note_id|nil
---@return string? err
function ui.editor_create_note_in_folder(folder_id, name)
  local editor = state.editor()
  return notes_namespace.create_note_in_folder(editor, editor.directory, state.handler(), folder_id, name)
end

---@param source_id string
---@param folder_id string
---@return boolean
---@return string? err
function ui.editor_delete_folder_namespace(source_id, folder_id)
  return state.editor():delete_folder_namespace(source_id, folder_id)
end

--- Renames an existing note.
--- Errors if no name or id provided, there is no note with provided id or
--- there is already an existing note with the same name in the same namespace.
---@param id note_id
---@param name string new name
function ui.editor_note_rename(id, name)
  state.editor():note_rename(id, name)
end

--- Get details of a current note
---@return note_details|nil
function ui.editor_get_current_note()
  return state.editor():get_current_note()
end

--- Sets note with id as the current note
--- and opens it in the window.
---@param id note_id
function ui.editor_set_current_note(id)
  state.editor():set_current_note(id)
end

--- Open the editor UI.
---@param winid integer
function ui.editor_show(winid)
  state.editor():show(winid)
end

--- Trigger an action in editor.
---@param action string
function ui.editor_do_action(action)
  state.editor():do_action(action)
end

--- Rebind a note's connection ownership after reconnect-side identity rewrite.
--- No-ops when the UI is not loaded yet.
---@param note_id note_id
---@param conn_id connection_id
---@param conn_name string?
---@param conn_type string?
function ui.rebind_note_connection(note_id, conn_id, conn_name, conn_type)
  if not ui.is_loaded() then
    return
  end
  state.editor():rebind_note_connection(note_id, conn_id, conn_name, conn_type)
end

---@divider -
---@tag dbee.ref.api.ui.call_log
---@brief [[
---Call Log API
---@brief ]]

--- Refresh the call log.
function ui.call_log_refresh()
  state.call_log():refresh()
end

--- Open the call log UI.
---@param winid integer
function ui.call_log_show(winid)
  state.call_log():show(winid)
end

--- Trigger an action in call_log.
---@param action string
function ui.call_log_do_action(action)
  state.call_log():do_action(action)
end

---@divider -
---@tag dbee.ref.api.ui.drawer
---@brief [[
---Drawer API
---@brief ]]

--- Refresh the drawer.
function ui.drawer_refresh()
  state.drawer():refresh()
end

--- Open the drawer UI.
---@param winid integer
function ui.drawer_show(winid)
  state.drawer():show(winid)
end

--- Prepare the drawer for close/hide before its host window goes away.
function ui.drawer_prepare_close()
  state.drawer():prepare_close()
end

--- Trigger an action in drawer.
---@param action string
function ui.drawer_do_action(action)
  state.drawer():do_action(action)
end

---@divider -
---@tag dbee.ref.api.ui.result
---@brief [[
---Result API
---@brief ]]

--- Sets call's result to Result's buffer.
---@param call CallDetails
function ui.result_set_call(call)
  state.result():set_call(call)
end

--- Restore call's display state in results UI.
---@param call CallDetails
function ui.result_restore_call(call)
  state.result():restore_call(call)
end

--- Gets the currently displayed call.
---@return CallDetails|nil
function ui.result_get_call()
  return state.result():get_call()
end

--- Display the currently selected page in results UI.
function ui.result_page_current()
  state.result():page_current()
end

--- Go to next page in results UI and display it.
function ui.result_page_next()
  state.result():page_next()
end

--- Go to previous page in results UI and display it.
function ui.result_page_prev()
  state.result():page_prev()
end

--- Go to last page in results UI and display it.
function ui.result_page_last()
  state.result():page_last()
end

--- Go to first page in results UI and display it.
function ui.result_page_first()
  state.result():page_first()
end

--- Open the result UI.
---@param winid integer
function ui.result_show(winid)
  state.result():show(winid)
end

--- Trigger an action in result.
---@param action string
function ui.result_do_action(action)
  state.result():do_action(action)
end

--- Get all notes from all namespaces.
--- Returns a flat list with namespace info included.
---@return { id: note_id, name: string, namespace: namespace_id, file: string?, bufnr: integer? }[]
---@class NotePickerSections
---@field current_connection { id: string, name: string }|nil
---@field global_notes note_details[]
---@field local_notes note_details[]
---@field global_namespace_id string|nil
---@field current_folder { id: string, name: string, source_id: string }|nil

---@param error_kind string?
local function notify_folder_lookup_error(error_kind)
  if error_kind == "load_failed" then
    vim.notify("dbee: folder source load failed; fix sidecar before using folder-scoped notes", vim.log.levels.WARN)
  end
end

---@param editor EditorUI
---@param handler Handler
---@param conn_id string
---@return note_details[]
---@return string|nil
---@return { id: string, name: string, source_id: string }|nil
local function folder_notes_for_connection(editor, handler, conn_id)
  local folder, error_kind = handler:get_folder_for_connection(conn_id)
  if error_kind then
    notify_folder_lookup_error(error_kind)
    return {}, nil, nil
  end
  if not folder then
    return {}, nil, nil
  end

  local ok_ns, namespace_or_err = pcall(notes_namespace.folder_namespace_id, folder.folder_id)
  if not ok_ns then
    vim.notify(tostring(namespace_or_err), vim.log.levels.ERROR)
    return {}, nil, nil
  end

  local notes, read_err = notes_namespace.read_folder_namespace_notes(editor, folder.folder_id)
  if not notes then
    vim.notify(tostring(read_err), vim.log.levels.ERROR)
    return {}, nil, nil
  end

  return notes, namespace_or_err, {
    id = folder.folder_id,
    name = folder.folder_name,
    source_id = folder.source_id,
  }
end

--- Get picker-specific note sections without changing the flat helper contract.
---@return NotePickerSections
function ui.editor_get_note_picker_sections()
  local editor = state.editor()
  local handler = state.handler()
  local sections = {
    current_connection = nil,
    global_namespace_id = nil,
    current_folder = nil,
    global_notes = {},
    local_notes = {},
  }

  local conn = handler:get_current_connection()
  if not (conn and conn.id ~= nil) then
    return sections
  end

  local conn_id = tostring(conn.id)
  sections.current_connection = {
    id = conn_id,
    name = conn.name or conn_id,
  }
  local folder_notes, global_namespace_id, current_folder = folder_notes_for_connection(editor, handler, conn_id)
  sections.global_notes = folder_notes
  sections.global_namespace_id = global_namespace_id
  sections.current_folder = current_folder
  sections.local_notes = editor:namespace_get_notes(conn_id)

  return sections
end

--- Get notes for one connection's folder namespace and local namespace.
--- Returns a flat list with namespace info included.
---@param conn_id connection_id
---@return { id: note_id, name: string, namespace: namespace_id, file: string?, bufnr: integer? }[]
function ui.editor_get_notes_for_connection(conn_id)
  local editor = state.editor()
  local handler = state.handler()
  local all_notes = {}

  if not conn_id or conn_id == "" then
    return all_notes
  end

  local folder_notes, folder_namespace = folder_notes_for_connection(editor, handler, tostring(conn_id))
  if folder_namespace then
    for _, note in ipairs(folder_notes) do
      table.insert(all_notes, {
        id = note.id,
        name = note.name,
        namespace = folder_namespace,
        file = note.file,
        bufnr = note.bufnr,
      })
    end
  end

  for _, note in ipairs(editor:namespace_get_notes(tostring(conn_id))) do
    table.insert(all_notes, {
      id = note.id,
      name = note.name,
      namespace = tostring(conn_id),
      file = note.file,
      bufnr = note.bufnr,
    })
  end

  return all_notes
end

--- Get all notes from the active folder namespace and current local namespace.
--- Returns a flat list with namespace info included.
---@return { id: note_id, name: string, namespace: namespace_id, file: string?, bufnr: integer? }[]
function ui.editor_get_all_notes()
  local handler = state.handler()
  local conn = handler:get_current_connection()
  if conn then
    return ui.editor_get_notes_for_connection(tostring(conn.id))
  end

  return all_notes
end

--- Find the note associated with a call ID.
---@param call_id string
---@return note_id|nil
function ui.editor_find_note_for_call(call_id)
  return state.editor():find_note_for_call(call_id)
end

return ui
