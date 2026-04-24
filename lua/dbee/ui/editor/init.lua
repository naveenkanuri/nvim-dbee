local utils = require("dbee.utils")
local common = require("dbee.ui.common")
local welcome = require("dbee.ui.editor.welcome")
local variables = require("dbee.variables")

---@return table|nil
local function get_reconnect()
  local ok, reconnect = pcall(require, "dbee.reconnect")
  if not ok then
    return nil
  end
  return reconnect
end

--- Parse Oracle error location from error string.
--- Returns (line, col) or (nil, nil) if not found.
---@param err_msg string
---@return integer?, integer?
local function parse_oracle_error_location(err_msg)
  local line, col = err_msg:match("line%s+(%d+),?%s*column%s+(%d+)")
  if line and col then
    return tonumber(line), tonumber(col)
  end
  -- Also check the formatted [L3:C5] form
  line, col = err_msg:match("%[L(%d+):C(%d+)%]")
  if line and col then
    return tonumber(line), tonumber(col)
  end
  -- Some Oracle errors only include line info (e.g. ORA-06512: at line 4).
  line = err_msg:match("[Aa][Tt]%s+[Ll][Ii][Nn][Ee]%s+(%d+)")
  if line then
    return tonumber(line), 1
  end
  -- Fallback for "line N" without explicit column.
  line = err_msg:match("[Ll][Ii][Nn][Ee]%s+(%d+)")
  if line then
    return tonumber(line), 1
  end
  return nil, nil
end

---@alias namespace_id "global"|string

---@alias note_id string
---@alias note_details { id: note_id, name: string, file: string, bufnr: integer? }

---@class EditorUI
---@field private handler Handler
---@field private result ResultUI
---@field private winid? integer
---@field private mappings key_mapping[]
---@field private notes table<namespace_id, table<note_id, note_details>> namespace: { id: note_details } mapping
---@field private current_note_id? note_id
---@field private directory string directory where notes are stored
---@field private event_callbacks table<editor_event_name, event_listener[]> callbacks for events
---@field private window_options table<string, any> a table of window options.
---@field private buffer_options table<string, any> a table of buffer options for all notes.
---@field private diag_ns integer diagnostic namespace id
---@field private last_exec_offset integer? line offset of last executed query in buffer
---@field private last_exec_bufnr integer? buffer of last executed query
---@field private note_calls table<note_id, CallDetails> last call per note
---@field private note_exec_meta table<note_id, { bufnr: integer, offset: integer, start_line: integer, start_col: integer, conn_id: string?, conn_name: string?, conn_type: string?, resolved_query: string? }> execution metadata per note
---@field private call_note_ids table<string, note_id> call id to note ownership mapping for active note calls
---@field private state_file string path to persist last-active note state
---@field private pending_cursor_line? integer one-shot cursor line to restore on first display
---@field private _confirm_pending boolean true while a cancel-confirm prompt is open
---@field private _confirm_conn_id? string connection ID being monitored for auto-dismiss
---@field private _confirm_resolve? fun() function to call when auto-dismiss fires
---@field private _confirm_picker? table picker handle from vim.ui.select (if provider returns one)
local EditorUI = {}

---@param handler Handler
---@param result ResultUI
---@param opts? editor_config
---@return EditorUI
function EditorUI:new(handler, result, opts)
  opts = opts or {}

  if not handler then
    error("no Handler provided to EditorTile")
  end
  if not result then
    error("no Result provided to EditorTile")
  end

  -- class object
  ---@type EditorUI
  local o = {
    handler = handler,
    result = result,
    notes = {},
    event_callbacks = {},
    directory = opts.directory or vim.fn.stdpath("state") .. "/dbee/notes",
    mappings = opts.mappings,
    window_options = vim.tbl_extend("force", {}, opts.window_options or {}),
    buffer_options = vim.tbl_extend("force", {
      buflisted = false,
      swapfile = false,
      filetype = "sql",
    }, opts.buffer_options or {}),
    diag_ns = vim.api.nvim_create_namespace("dbee_diagnostics"),
    last_exec_offset = nil,
    last_exec_bufnr = nil,
    note_calls = {},
    note_exec_meta = {},
    call_note_ids = {},
    state_file = vim.fn.stdpath("state") .. "/dbee/last_note.json",
    pending_cursor_line = nil,
    _confirm_pending = false,      -- true while a cancel-confirm prompt is open
    _confirm_conn_id = nil,        -- connection ID being monitored for auto-dismiss
    _confirm_resolve = nil,        -- function to call when auto-dismiss fires
    _confirm_picker = nil,         -- picker handle from vim.ui.select (if provider returns one)
  }
  setmetatable(o, self)
  self.__index = self

  handler:register_event_listener("call_state_changed", function(data)
    o:on_call_state_changed(data)
  end)

  -- Auto-dismiss cancel-confirm prompt when ALL calls on the monitored
  -- connection reach terminal state.
  handler:register_event_listener("call_state_changed", function(data)
    if not o._confirm_conn_id then
      return
    end
    -- Fast-return: if the event's call is still active, the connection
    -- definitely has at least one active call.  Skips the RPC entirely.
    local s = data and data.call and data.call.state
    if s == "executing" or s == "retrieving" or s == "unknown" then
      return
    end
    -- The event's call reached a terminal state.  Re-check if the monitored
    -- connection still has OTHER active calls (non-serialized adapters can
    -- have multiple concurrent calls).
    local ok, calls = pcall(o.handler.connection_get_calls, o.handler, o._confirm_conn_id)
    if not ok or not calls then
      return
    end
    for _, c in ipairs(calls) do
      if c.state == "executing" or c.state == "retrieving" or c.state == "unknown" then
        return -- still has active calls, keep waiting
      end
    end
    -- No active calls remain — resolve BEFORE closing picker.
    -- If picker.close synchronously triggers the choice callback (with nil),
    -- the choice callback will see resolved=true and return early.
    local picker = o._confirm_picker
    local resolve = o._confirm_resolve
    o._confirm_conn_id = nil
    o._confirm_resolve = nil
    o._confirm_pending = false
    o._confirm_picker = nil
    if resolve then
      resolve()
    end
    if picker and type(picker.close) == "function" then
      pcall(picker.close, picker)
    end
  end)

  -- restore last-active note from previous session, or fall back to first global note
  local restored = false
  local last = o:load_last_note()
  if last then
    local note_id = o:resolve_note_from_file(last.file)
    if note_id then
      o.current_note_id = note_id
      if last.cursor_line then
        o.pending_cursor_line = last.cursor_line
      end
      restored = true
    end
  end

  if not restored then
    local global_notes = o:namespace_get_notes("global")
    if not vim.tbl_isempty(global_notes) then
      o.current_note_id = global_notes[1].id
    else
      o.current_note_id = o:create_welcome_note()
    end
  end

  return o
end

---@private
--- Persist the current note's file path and cursor line to disk.
function EditorUI:save_last_note()
  local note = self:search_note(self.current_note_id)
  if not note then
    return
  end

  local cursor_line = nil

  if note.bufnr and vim.api.nvim_buf_is_valid(note.bufnr) then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == note.bufnr then
        local pos = vim.api.nvim_win_get_cursor(win)
        cursor_line = math.max((pos[1] or 1) - 1, 0)
        break
      end
    end
  end

  local dir = vim.fs.dirname(self.state_file)
  vim.fn.mkdir(dir, "p")

  local f = io.open(self.state_file, "w")
  if not f then
    return
  end
  f:write(vim.json.encode({ file = note.file, cursor_line = cursor_line }))
  f:close()
end

---@private
--- Read persisted last-note state from disk.
---@return { file: string, cursor_line: integer? }?
function EditorUI:load_last_note()
  local f = io.open(self.state_file, "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()

  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" or not data.file then
    return nil
  end
  return data
end

---@private
--- Given a file path, find or load the note and return its note_id.
---@param file string
---@return note_id?
function EditorUI:resolve_note_from_file(file)
  if vim.fn.filereadable(file) ~= 1 then
    return nil
  end

  -- check already-loaded namespaces
  local note = self:search_note_with_file(file)
  if note then
    return note.id
  end

  -- derive namespace from path: strip directory prefix, take first component
  local prefix = self.directory .. "/"
  if vim.startswith(file, prefix) then
    local rel = file:sub(#prefix + 1)
    local namespace = rel:match("^([^/]+)")
    if namespace then
      -- load that namespace (triggers load_notes_from_disk)
      self:namespace_get_notes(namespace)
      -- search again
      note = self:search_note_with_file(file)
      if note then
        return note.id
      end
    end
  end

  return nil
end

---@private
---@return note_id
function EditorUI:create_welcome_note()
  local note_id = self:namespace_create_note("global", "welcome")
  local note = self:search_note(note_id)
  if not note then
    error("failed creating welcome note")
  end

  -- create note buffer with contents
  local bufnr = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(bufnr, note.file)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, welcome.banner())
  vim.api.nvim_buf_set_option(bufnr, "modified", false)

  self.notes["global"][note_id].bufnr = bufnr

  -- remove all text when first change happens to text
  vim.api.nvim_create_autocmd({ "InsertEnter" }, {
    once = true,
    buffer = bufnr,
    callback = function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, {})
      vim.api.nvim_buf_set_option(bufnr, "modified", false)
    end,
  })

  -- configure options and mappings on new buffer
  common.configure_buffer_options(bufnr, self.buffer_options)
  common.configure_buffer_mappings(bufnr, self:get_actions(), self.mappings)

  return note_id
end

---@private
---@return table<string, fun()>
function EditorUI:get_actions()
  local function execute_query_with_variables_async(conn, query, on_done)
    variables.resolve_for_execute_async(query, {
      adapter_type = conn and conn.type or nil,
    }, function(resolved, exec_opts, resolve_err)
      if resolve_err then
        vim.notify(resolve_err, vim.log.levels.WARN)
        on_done(nil)
        return
      end

      local ok, call_or_err = pcall(function()
        return self.handler:connection_execute(conn.id, resolved, exec_opts)
      end)
      if not ok then
        vim.notify(tostring(call_or_err), vim.log.levels.WARN)
        on_done(nil)
        return
      end

      on_done(call_or_err, resolved, exec_opts)
    end)
  end

  -- Returns the count of active calls on the current connection (0 = none).
  -- Includes "unknown" state: calls start there before the Go goroutine
  -- transitions them to "executing" (async, nanosecond window).
  -- Uses pcall so test stubs that omit connection_get_calls still work.
  local function active_call_count()
    local conn = self.handler:get_current_connection()
    if not conn then
      return 0
    end
    local ok, calls = pcall(self.handler.connection_get_calls, self.handler, conn.id)
    if not ok or not calls or #calls == 0 then
      return 0
    end
    local count = 0
    for _, c in ipairs(calls) do
      if c.state == "executing" or c.state == "retrieving" or c.state == "unknown" then
        count = count + 1
      end
    end
    return count
  end

  -- Guard that wraps an action body with a cancel-confirm prompt when any
  -- query is running on the current connection.  If nothing is running,
  -- calls action_fn immediately.  The prompt auto-dismisses (and fires
  -- action_fn) when ALL running queries on the connection reach terminal
  -- state.  The picker window is closed programmatically if the provider
  -- supports it (hybrid: checks for .close() method).
  local function confirm_and_execute(action_fn)
    -- Pending check MUST come before active_call_count().  Events arrive via
    -- vim.schedule, so there is a window where the Go side has moved calls
    -- to terminal but the Lua event hasn't fired yet.  Without this guard,
    -- active_call_count() returns 0 → immediate execute, then the queued
    -- auto-dismiss fires resolve() → double execution.
    if self._confirm_pending then
      return
    end

    local num_active = active_call_count()
    if num_active == 0 then
      action_fn()
      return
    end
    self._confirm_pending = true

    -- Capture connection ID for the auto-dismiss listener and "Yes" cancel.
    local conn = self.handler:get_current_connection()
    local captured_conn_id = conn and conn.id or nil

    -- Wire auto-dismiss: the listener registered in EditorUI:new() will
    -- check all calls for _confirm_conn_id on every state change event.
    local resolved = false
    local function do_resolve()
      if resolved then
        return
      end
      resolved = true
      self._confirm_pending = false
      self._confirm_conn_id = nil
      self._confirm_resolve = nil
      self._confirm_picker = nil
      action_fn()
    end

    self._confirm_conn_id = captured_conn_id
    self._confirm_resolve = do_resolve

    local prompt_text = num_active > 1
      and (num_active .. " queries running. Cancel all and run new?")
      or "A query is running. Cancel and run new?"

    local select_ok, picker_or_err = pcall(vim.ui.select, { "No", "Yes" }, {
      prompt = prompt_text,
    }, function(choice)
      -- Clear confirm state regardless of choice.
      self._confirm_pending = false
      self._confirm_conn_id = nil
      self._confirm_resolve = nil
      self._confirm_picker = nil

      if resolved then
        return -- auto-dismiss already fired action_fn
      end
      resolved = true

      if choice ~= "Yes" then
        return
      end

      -- Cancel ALL active calls for the captured connection.
      -- Includes "unknown" — Cancel() is a no-op on unknown-state calls
      -- (Go side guards to executing/retrieving only), but by the time the
      -- user picks "Yes" (human speed) the call is in executing.
      if captured_conn_id then
        local ok, calls = pcall(self.handler.connection_get_calls, self.handler, captured_conn_id)
        if ok and calls then
          for _, c in ipairs(calls) do
            if c.state == "executing" or c.state == "retrieving" or c.state == "unknown" then
              local cancel_ok, cancel_err = self.handler:call_cancel(c.id)
              if cancel_ok == false and cancel_err then
                vim.notify(cancel_err, vim.log.levels.WARN)
              end
            end
          end
        end
      end
      action_fn()
    end)

    if select_ok then
      -- Hybrid picker close: if vim.ui.select returns an object with a
      -- .close() method (e.g. snacks.nvim picker), store it so the
      -- auto-dismiss listener can close the picker window.
      if type(picker_or_err) == "table" and type(picker_or_err.close) == "function" then
        self._confirm_picker = picker_or_err
      end
    else
      -- vim.ui.select threw synchronously — unlatch and fall through.
      self._confirm_pending = false
      self._confirm_conn_id = nil
      self._confirm_resolve = nil
      self._confirm_picker = nil
      vim.notify("Confirm prompt failed: " .. tostring(picker_or_err), vim.log.levels.WARN)
      action_fn()
    end
  end

  local function register_note_retry(note_id, call, conn, bufnr, start_line, start_col, original_query, resolved_query, exec_opts)
    if not note_id or not call or not call.id then
      return
    end

    local reconnect = get_reconnect()
    if not reconnect then
      return
    end

    reconnect.register_call(call.id, {
      conn_id = conn.id,
      conn_name = conn.name,
      conn_type = conn.type,
      note_id = note_id,
      resolved_query = resolved_query,
      exec_opts = exec_opts,
      legacy_query = original_query,
      on_retry_created = function(new_call, meta)
        self:set_result_for_note(
          note_id,
          new_call,
          bufnr,
          start_line,
          start_col,
          meta.conn_id or conn.id,
          meta.conn_name or conn.name,
          meta.conn_type or conn.type,
          resolved_query
        )
      end,
    })
  end

  return {
    run_file = function()
      if not self.winid or not vim.api.nvim_win_is_valid(self.winid) then
        return
      end
      local conn = self.handler:get_current_connection()
      if not conn then
        return
      end
      local bufnr = vim.api.nvim_win_get_buf(self.winid)
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local query = table.concat(lines, "\n")

      confirm_and_execute(function()
        self.last_exec_offset = 0
        self.last_exec_bufnr = bufnr
        vim.diagnostic.reset(self.diag_ns, bufnr)

        local note_id = self.current_note_id
        local exec_bufnr = self.last_exec_bufnr
        local exec_start_line = self.last_exec_offset
        local exec_start_col = 0
        execute_query_with_variables_async(conn, query, function(call, resolved_query, exec_opts)
          self:set_result_for_note(
            note_id,
            call,
            exec_bufnr,
            exec_start_line,
            exec_start_col,
            conn.id,
            conn.name,
            conn.type,
            resolved_query
          )
          register_note_retry(
            note_id,
            call,
            conn,
            exec_bufnr,
            exec_start_line,
            exec_start_col,
            query,
            resolved_query,
            exec_opts
          )
        end)
      end)
    end,
    run_selection = function()
      local srow, scol, erow, ecol = utils.visual_selection()
      local selection = vim.api.nvim_buf_get_text(0, srow, scol, erow, ecol, {})
      local query = table.concat(selection, "\n")

      local conn = self.handler:get_current_connection()
      if not conn then
        return
      end

      confirm_and_execute(function()
        self.last_exec_offset = srow
        self.last_exec_bufnr = vim.api.nvim_get_current_buf()
        vim.diagnostic.reset(self.diag_ns, self.last_exec_bufnr)

        local note_id = self.current_note_id
        local exec_bufnr = self.last_exec_bufnr
        local exec_start_line = self.last_exec_offset
        local exec_start_col = scol
        execute_query_with_variables_async(conn, query, function(call, resolved_query, exec_opts)
          self:set_result_for_note(
            note_id,
            call,
            exec_bufnr,
            exec_start_line,
            exec_start_col,
            conn.id,
            conn.name,
            conn.type,
            resolved_query
          )
          register_note_retry(
            note_id,
            call,
            conn,
            exec_bufnr,
            exec_start_line,
            exec_start_col,
            query,
            resolved_query,
            exec_opts
          )
        end)
      end)
    end,
    -- cycle to next note within current namespace
    note_next = function()
      if not self.current_note_id then
        return
      end
      local note, namespace = self:search_note(self.current_note_id)
      if not note or namespace == "" then
        return
      end
      local notes = self:namespace_get_notes(namespace)
      if #notes <= 1 then
        return
      end
      local current_idx = 0
      for i, n in ipairs(notes) do
        if n.id == self.current_note_id then
          current_idx = i
          break
        end
      end
      if current_idx == 0 then
        return
      end
      local next_idx = current_idx % #notes + 1
      self:set_current_note(notes[next_idx].id)
    end,

    -- cycle to previous note within current namespace
    note_prev = function()
      if not self.current_note_id then
        return
      end
      local note, namespace = self:search_note(self.current_note_id)
      if not note or namespace == "" then
        return
      end
      local notes = self:namespace_get_notes(namespace)
      if #notes <= 1 then
        return
      end
      local current_idx = 0
      for i, n in ipairs(notes) do
        if n.id == self.current_note_id then
          current_idx = i
          break
        end
      end
      if current_idx == 0 then
        return
      end
      local prev_idx = (current_idx - 2) % #notes + 1
      self:set_current_note(notes[prev_idx].id)
    end,

    -- explain plan (normal mode): query under cursor
    explain_plan = function()
      require("dbee").explain_plan()
    end,

    -- explain plan (visual selection): uses is_visual flag since mode has
    -- already exited visual by the time the keybinding fires
    explain_plan_visual = function()
      require("dbee").explain_plan({ is_visual = true })
    end,
    focus_editor = function()
      require("dbee").focus_pane("editor")
    end,
    focus_result = function()
      require("dbee").focus_pane("result")
    end,
    focus_drawer = function()
      require("dbee").focus_pane("drawer")
    end,
    focus_call_log = function()
      require("dbee").focus_pane("call_log")
    end,

    run_under_cursor = function()
      local bufnr = vim.api.nvim_get_current_buf()
      local conn = self.handler:get_current_connection()
      if not conn then
        return
      end
      local query, srow, scol, erow = utils.query_under_cursor(bufnr, {
        adapter_type = conn.type,
      })

      if query ~= "" then
        confirm_and_execute(function()
          self.last_exec_offset = srow
          self.last_exec_bufnr = bufnr
          vim.diagnostic.reset(self.diag_ns, bufnr)

          -- highlight the statement that will be executed
          local ns_id = vim.api.nvim_create_namespace("dbee_query_highlight")
          vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
          vim.api.nvim_buf_set_extmark(bufnr, ns_id, srow, 0, {
            end_row = erow + 1,
            end_col = 0,
            hl_group = "DiffText",
            priority = 100,
          })

          local note_id = self.current_note_id
          local exec_bufnr = self.last_exec_bufnr
          local exec_start_line = self.last_exec_offset
          local exec_start_col = scol or 0
          execute_query_with_variables_async(conn, query, function(call, resolved_query, exec_opts)
            self:set_result_for_note(
              note_id,
              call,
              exec_bufnr,
              exec_start_line,
              exec_start_col,
              conn.id,
              conn.name,
              conn.type,
              resolved_query
            )
            register_note_retry(
              note_id,
              call,
              conn,
              exec_bufnr,
              exec_start_line,
              exec_start_col,
              query,
              resolved_query,
              exec_opts
            )
          end)

          -- remove highlighting after delay
          vim.defer_fn(function()
            vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
          end, 750)
        end)
      end
    end,
  }
end

---Triggers an in-built action.
---@param action string
function EditorUI:do_action(action)
  local act = self:get_actions()[action]
  if not act then
    error("unknown action: " .. action)
  end
  act()
end

---@private
---@param event editor_event_name
---@param data any
function EditorUI:trigger_event(event, data)
  local cbs = self.event_callbacks[event] or {}
  for _, cb in ipairs(cbs) do
    cb(data)
  end
end

---@param event editor_event_name
---@param listener event_listener
function EditorUI:register_event_listener(event, listener)
  self.event_callbacks[event] = self.event_callbacks[event] or {}
  table.insert(self.event_callbacks[event], listener)
end

---@private
---@param namespace string
---@return string
function EditorUI:dir(namespace)
  return self.directory .. "/" .. namespace
end

---@private
---@param id namespace_id
---@param name string name to check
---@return boolean # true - conflict, false - no conflict
function EditorUI:namespace_check_conflict(id, name)
  local notes = self.notes[id] or {}
  for _, note in pairs(notes) do
    if note.name == name then
      return true
    end
  end
  return false
end

---@param id note_id
---@return note_details?
---@return namespace_id namespace
function EditorUI:search_note(id)
  for namespace, per_namespace in pairs(self.notes) do
    for _, note in pairs(per_namespace) do
      if note.id == id then
        return note, namespace
      end
    end
  end
  return nil, ""
end

---@param bufnr integer
---@return note_details?
---@return namespace_id namespace
function EditorUI:search_note_with_buf(bufnr)
  for namespace, per_namespace in pairs(self.notes) do
    for _, note in pairs(per_namespace) do
      if note.bufnr and note.bufnr == bufnr then
        return note, namespace
      end
    end
  end
  return nil, ""
end

---@param file string
---@return note_details?
---@return namespace_id namespace
function EditorUI:search_note_with_file(file)
  for namespace, per_namespace in pairs(self.notes) do
    for _, note in pairs(per_namespace) do
      if note.file and note.file == file then
        return note, namespace
      end
    end
  end
  return nil, ""
end

-- Creates a new note in namespace.
-- Errors if id or name is nil or there is a note with the same
-- name in namespace already.
---@param id namespace_id
---@param name string
---@return note_id
function EditorUI:namespace_create_note(id, name)
  local namespace = id
  if not namespace or namespace == "" then
    error("invalid namespace id")
  end
  if not name or name == "" then
    error("no name for global note")
  end

  if not vim.endswith(name, ".sql") then
    name = name .. ".sql"
  end

  -- create namespace directory
  vim.fn.mkdir(self:dir(namespace), "p")

  if self:namespace_check_conflict(namespace, name) then
    error('note with this name already exists in "' .. namespace .. '" namespace')
  end

  local file = self:dir(namespace) .. "/" .. name
  local note_id = file .. utils.random_string()
  ---@type note_details
  local s = {
    id = note_id,
    name = name,
    file = file,
  }

  self.notes[namespace] = self.notes[namespace] or {}
  self.notes[namespace][note_id] = s

  self:trigger_event("note_created", { note = s })

  return note_id
end

---@param id namespace_id
---@return note_details[]
function EditorUI:namespace_get_notes(id)
  local namespace = id
  if not namespace or namespace == "" then
    error("invalid namespace id")
  end

  if not self.notes[namespace] then
    self.notes[namespace] = self:load_notes_from_disk(namespace)
  end
  local notes_list = vim.tbl_values(self.notes[namespace])

  table.sort(notes_list, function(k1, k2)
    return k1.name < k2.name
  end)
  return notes_list
end

-- If no notes were found, return an empty table.
---@private
---@param namespace_id namespace_id
---@return table<note_id, note_details>
function EditorUI:load_notes_from_disk(namespace_id)
  local full_dir = self.directory .. "/" .. namespace_id
  local ret = {}
  for _, file in pairs(vim.split(vim.fn.glob(full_dir .. "/*"), "\n")) do
    if vim.fn.filereadable(file) == 1 then
      local id = file .. utils.random_string()
      ret[id] = {
        id = id,
        name = vim.fs.basename(file),
        file = file,
      }
    end
  end
  return ret
end

-- Removes an existing note.
-- Errors if there is no note with provided id in namespace.
---@param id namespace_id
---@param note_id note_id
function EditorUI:namespace_remove_note(id, note_id)
  local namespace = id
  if not self.notes[namespace] then
    error("invalid namespace id to remove the note from")
  end

  local note = self.notes[namespace][note_id]
  if not note then
    error("invalid note id to remove")
  end

  -- delete file
  vim.fn.delete(note.file)

  -- delete record
  self.notes[namespace][note_id] = nil

  -- Clean up associated call tracking
  local old_call = self.note_calls[note_id]
  if old_call and old_call.id then
    self.call_note_ids[old_call.id] = nil
    local reconnect = get_reconnect()
    if reconnect then
      reconnect.forget_call(old_call.id)
    end
  end
  self.note_calls[note_id] = nil
  self.note_exec_meta[note_id] = nil

  self:trigger_event("note_removed", { note_id = note_id })
end

-- Renames an existing note.
-- Errors if no name or id provided, there is no note with provided id or
-- there is already an existing note with the same name in the same namespace.
---@param id note_id
---@param name string new name
function EditorUI:note_rename(id, name)
  local note, namespace = self:search_note(id)
  if not note then
    error("invalid note id to rename")
  end
  if not name or name == "" then
    error("invalid name")
  end

  if not vim.endswith(name, ".sql") then
    name = name .. ".sql"
  end

  if self:namespace_check_conflict(namespace, name) then
    error('note with this name already exists in "' .. namespace .. '" namespace')
  end

  local new_file = self:dir(namespace) .. "/" .. name

  -- rename file
  if vim.fn.filereadable(note.file) == 1 then
    vim.fn.rename(note.file, new_file)
  end

  -- rename buffer
  if note.bufnr and vim.api.nvim_buf_get_name(note.bufnr) == note.file then
    vim.api.nvim_buf_set_name(note.bufnr, new_file)
  end

  -- save changes
  self.notes[namespace][id].file = new_file
  self.notes[namespace][id].name = name

  self:trigger_event("note_state_changed", { note = self.notes[namespace][id] })

  if id == self.current_note_id then
    self:save_last_note()
  end
end

---@return note_details?
function EditorUI:get_current_note()
  local note, _ = self:search_note(self.current_note_id)
  return note
end

---@param note_id note_id
---@param conn_id connection_id
---@param conn_name string?
---@param conn_type string?
function EditorUI:write_note_conn(note_id, conn_id, conn_name, conn_type)
  if not note_id then
    return
  end

  local meta = self.note_exec_meta[note_id] or {}
  meta.conn_id = conn_id
  meta.conn_name = conn_name
  meta.conn_type = conn_type or meta.conn_type
  self.note_exec_meta[note_id] = meta
end

---@param note_id note_id
---@param call CallDetails
---@param bufnr integer
---@param start_line integer
---@param start_col integer
---@param conn_id connection_id
---@param conn_name string?
---@param conn_type string?
---@param resolved_query string?
function EditorUI:set_result_for_note(note_id, call, bufnr, start_line, start_col, conn_id, conn_name, conn_type, resolved_query)
  if not call then
    return
  end

  self.result:set_call(call)
  if not note_id then
    return
  end

  local previous_call = self.note_calls[note_id]
  if previous_call and previous_call.id and previous_call.id ~= call.id then
    self.call_note_ids[previous_call.id] = nil
    local reconnect = get_reconnect()
    if reconnect then
      reconnect.forget_call(previous_call.id)
    end
  end

  self.note_calls[note_id] = call
  self.call_note_ids[call.id] = note_id

  local meta = self.note_exec_meta[note_id] or {}
  meta.bufnr = bufnr
  meta.offset = start_line or 0
  meta.start_line = start_line or 0
  meta.start_col = start_col or 0
  meta.resolved_query = resolved_query
  self.note_exec_meta[note_id] = meta
  self:write_note_conn(note_id, conn_id, conn_name, conn_type)

  if self.current_note_id == note_id then
    self:save_last_note()
  end
end

---@param note_id note_id
---@param new_conn_id connection_id
---@param new_conn_name string?
---@param new_conn_type string?
function EditorUI:rebind_note_connection(note_id, new_conn_id, new_conn_name, new_conn_type)
  local meta = self.note_exec_meta[note_id]
  if not meta then
    return
  end
  if meta.conn_id == new_conn_id then
    return
  end
  self:write_note_conn(note_id, new_conn_id, new_conn_name, new_conn_type)
end

---@private
---@param note_id note_id
function EditorUI:restore_note_result(note_id)
  local saved_call = self.note_calls[note_id]
  if not saved_call then
    self.result:clear()
    return
  end

  self.result:restore_call(saved_call)
end

--- Find the note associated with a call ID.
---@param call_id string
---@return note_id|nil
function EditorUI:find_note_for_call(call_id)
  return self.call_note_ids[call_id]
end

-- Sets note with id as the current note
-- and opens it in the window
---@param id note_id
function EditorUI:set_current_note(id)
  if id and self.current_note_id == id then
    self:display_note(id)
    return
  end

  local note, _ = self:search_note(id)
  if not note then
    error("invalid note set as current")
  end

  self.current_note_id = id

  self:display_note(id)

  -- Restore the note's last query result
  self:restore_note_result(id)

  self:trigger_event("current_note_changed", { note_id = id })

  self:save_last_note()
end

---@private
---@param id note_id
function EditorUI:display_note(id)
  if not self.winid or not vim.api.nvim_win_is_valid(self.winid) then
    return
  end

  local note, namespace = self:search_note(id)
  if not note then
    return
  end

  -- if buffer is configured, just open it
  if note.bufnr and vim.api.nvim_buf_is_valid(note.bufnr) then
    vim.api.nvim_win_set_buf(self.winid, note.bufnr)
    vim.api.nvim_set_current_win(self.winid)
    self:apply_pending_cursor()
    return
  end

  -- otherwise open a file and update note's buffer
  vim.api.nvim_set_current_win(self.winid)
  vim.cmd("e " .. note.file)

  local bufnr = vim.api.nvim_get_current_buf()
  self.notes[namespace][id].bufnr = bufnr

  -- configure options and mappings on new buffer
  common.configure_buffer_options(bufnr, self.buffer_options)
  common.configure_buffer_mappings(bufnr, self:get_actions(), self.mappings)

  -- queue buffer for dbee LSP attachment (LSP starts when structure_loaded fires)
  local ok, lsp = pcall(require, "dbee.lsp")
  if ok then
    lsp.queue_buffer(bufnr)
  end

  self:apply_pending_cursor()
end

---@private
--- Apply and clear the one-shot pending cursor position.
function EditorUI:apply_pending_cursor()
  if not self.pending_cursor_line then
    return
  end
  if not self.winid or not vim.api.nvim_win_is_valid(self.winid) then
    self.pending_cursor_line = nil
    return
  end

  local bufnr = vim.api.nvim_win_get_buf(self.winid)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local target = math.min(self.pending_cursor_line + 1, line_count)
  if target < 1 then
    target = 1
  end
  vim.api.nvim_win_set_cursor(self.winid, { target, 0 })
  self.pending_cursor_line = nil
end

---@param winid integer
function EditorUI:show(winid)
  self.winid = winid

  -- open current note
  self:display_note(self.current_note_id)

  -- configure window options (needs to be set after setting the buffer to window)
  common.configure_window_options(winid, self.window_options)
end

---@private
---@param data { call: CallDetails }
function EditorUI:on_call_state_changed(data)
  if not data or not data.call then
    return
  end

  local note_id = self.call_note_ids[data.call.id]
  if not note_id then
    return
  end

  local stored_call = self.note_calls[note_id]
  if not stored_call or stored_call.id ~= data.call.id then
    return
  end
  self.note_calls[note_id] = data.call

  local meta = self.note_exec_meta[note_id]
  if not meta or not meta.bufnr or not vim.api.nvim_buf_is_valid(meta.bufnr) then
    return
  end

  local exec_bufnr = meta.bufnr
  local exec_start_line = meta.start_line or meta.offset or 0
  local exec_start_col = meta.start_col or 0
  local exec_conn_type = meta.conn_type

  if data.call.state == "archived" then
    vim.diagnostic.reset(self.diag_ns, exec_bufnr)
    return
  end

  if data.call.state ~= "executing_failed" then
    return
  end

  -- Always clear stale diagnostics for this note/call first.
  vim.diagnostic.reset(self.diag_ns, exec_bufnr)

  if not exec_conn_type or exec_conn_type:lower() ~= "oracle" then
    return
  end

  local err_msg = data.call.error
  if not err_msg or err_msg == "" then
    return
  end

  local err_line, err_col = parse_oracle_error_location(err_msg)
  if not err_line then
    return
  end

  local buf_line = exec_start_line + err_line - 1
  local buf_col = math.max((err_col or 1) - 1, 0)
  if err_line == 1 then
    buf_col = exec_start_col + buf_col
  end

  local line_count = vim.api.nvim_buf_line_count(exec_bufnr)
  if line_count < 1 then
    return
  end
  if buf_line < 0 then
    buf_line = 0
  end
  if buf_line >= line_count then
    buf_line = line_count - 1
  end
  local line_text = vim.api.nvim_buf_get_lines(exec_bufnr, buf_line, buf_line + 1, false)[1] or ""
  local max_col = #line_text
  local clamped_col = math.min(buf_col, max_col)
  local cursor_col = clamped_col
  if max_col > 0 and cursor_col >= max_col then
    cursor_col = max_col - 1
  end

  vim.diagnostic.set(self.diag_ns, exec_bufnr, {
    {
      lnum = buf_line,
      col = clamped_col,
      severity = vim.diagnostic.severity.ERROR,
      message = err_msg,
      source = "dbee",
    },
  })

  -- Jump cursor to first compile/runtime error location when note buffer is visible.
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == exec_bufnr then
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { buf_line + 1, cursor_col })
      break
    end
  end
end

return EditorUI
