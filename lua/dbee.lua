local install = require("dbee.install")
local api = require("dbee.api")
local config = require("dbee.config")
local utils = require("dbee.utils")
local query_splitter = require("dbee.query_splitter")
local variables = require("dbee.variables")

---@toc dbee.ref.contents

---@mod dbee.ref Dbee Reference
---@brief [[
---Database Client for NeoVim.
---@brief ]]

local dbee = {
  api = {
    core = api.core,
    ui = api.ui,
  },
}

local terminal_states = {
  archived = true,
  executing_failed = true,
  retrieving_failed = true,
  archive_failed = true,
  canceled = true,
}

---@type { canceled: boolean, current_call_id: string?, cancel_sent_call_id: string? }|nil
local active_script_run = nil

local disconnected_error_states = {
  executing_failed = true,
  retrieving_failed = true,
  archive_failed = true,
}

---@return boolean
local function is_core_loaded()
  if not api.core then
    return false
  end
  if type(api.core.is_loaded) == "function" then
    return api.core.is_loaded()
  end
  return true
end

---@param opts? { bootstrap?: boolean }
---@return boolean
---@return string|nil
local function ensure_core_available(opts)
  opts = opts or {}
  if is_core_loaded() then
    return true, nil
  end

  if opts.bootstrap == false then
    return false, "dbee core not loaded"
  end

  local ok_boot = pcall(api.core.get_current_connection)
  if ok_boot then
    return true, nil
  end
  return false, "dbee core not loaded"
end

---@param conn_id connection_id
---@param call_id call_id
---@return string|nil
local function find_call_state(conn_id, call_id)
  local calls = api.core.connection_get_calls(conn_id) or {}
  for _, call in ipairs(calls) do
    if call.id == call_id then
      return call.state
    end
  end
end

---@param conn_id connection_id
---@param call_id call_id
---@param timeout_ms integer
---@param run_state? { canceled: boolean, current_call_id: string?, cancel_sent_call_id: string? }
---@return boolean ok
---@return string|nil state
local function wait_for_call_terminal_state(conn_id, call_id, timeout_ms, run_state)
  local state = nil
  local ok = vim.wait(timeout_ms, function()
    if run_state and run_state.canceled then
      if run_state.cancel_sent_call_id ~= call_id then
        run_state.cancel_sent_call_id = call_id
        pcall(api.core.call_cancel, call_id)
      end
      state = "canceled"
      return true
    end
    state = find_call_state(conn_id, call_id)
    return state ~= nil and terminal_states[state] == true
  end, 50)

  return ok, state
end

---@param call? CallDetails
---@return boolean
local function is_disconnected_failed_call(call)
  return call ~= nil
    and call.error_kind == "disconnected"
    and disconnected_error_states[call.state] == true
end

---@param conn_id connection_id
---@return CallDetails|nil
local function find_latest_disconnected_call(conn_id)
  local calls = api.core.connection_get_calls(conn_id) or {}
  local latest = nil
  local latest_ts = -1
  for _, call in ipairs(calls) do
    if is_disconnected_failed_call(call) then
      local ts = tonumber(call.timestamp_us) or 0
      if latest == nil or ts >= latest_ts then
        latest = call
        latest_ts = ts
      end
    end
  end
  if latest then
    return latest
  end
  return nil
end

---@param conn_id connection_id
---@return source_id|nil
local function find_source_id_for_connection(conn_id)
  if type(api.core.get_sources) ~= "function" or type(api.core.source_get_connections) ~= "function" then
    return nil
  end

  local ok_sources, sources = pcall(api.core.get_sources)
  if not ok_sources or type(sources) ~= "table" then
    return nil
  end

  for _, source in ipairs(sources) do
    if source and type(source.name) == "function" then
      local ok_name, source_id = pcall(source.name, source)
      if ok_name and source_id and source_id ~= "" then
        local ok_conns, source_conns = pcall(api.core.source_get_connections, source_id)
        if ok_conns and type(source_conns) == "table" then
          for _, conn in ipairs(source_conns) do
            if conn and conn.id == conn_id then
              return source_id
            end
          end
        end
      end
    end
  end

  return nil
end

---@param source_id source_id
---@param previous ConnectionParams
---@return ConnectionParams|nil
---@return string|nil
local function resolve_reloaded_connection(source_id, previous)
  local ok_conns, source_conns = pcall(api.core.source_get_connections, source_id)
  if not ok_conns then
    return nil, "failed reading reloaded source connections"
  end
  if type(source_conns) ~= "table" or #source_conns == 0 then
    return nil, "source reload produced no connections"
  end

  local prev_id = tostring(previous.id or "")
  local prev_type = tostring(previous.type or "")
  local prev_url = tostring(previous.url or "")
  local prev_name = tostring(previous.name or "")

  local function find_unique_match(predicate)
    local match = nil
    for _, candidate in ipairs(source_conns) do
      if candidate and candidate.id and candidate.id ~= "" and predicate(candidate) then
        if match ~= nil then
          return nil, true
        end
        match = candidate
      end
    end
    return match, false
  end

  if prev_id ~= "" then
    local match, ambiguous = find_unique_match(function(candidate)
      return tostring(candidate.id or "") == prev_id
        and (prev_type == "" or tostring(candidate.type or "") == prev_type)
    end)
    if match then
      return match, nil
    end
    if ambiguous then
      return nil, "reloaded connection id mapping is ambiguous"
    end
  end

  if prev_type ~= "" and prev_url ~= "" then
    local match, ambiguous = find_unique_match(function(candidate)
      return tostring(candidate.type or "") == prev_type and tostring(candidate.url or "") == prev_url
    end)
    if match then
      return match, nil
    end
    if ambiguous then
      return nil, "reloaded connection URL mapping is ambiguous"
    end
  end

  if prev_type ~= "" and prev_name ~= "" then
    local match, ambiguous = find_unique_match(function(candidate)
      return tostring(candidate.type or "") == prev_type and tostring(candidate.name or "") == prev_name
    end)
    if match then
      return match, nil
    end
    if ambiguous then
      return nil, "reloaded connection name mapping is ambiguous"
    end
  end

  if #source_conns == 1 and source_conns[1] and source_conns[1].id and source_conns[1].id ~= "" then
    if prev_type ~= "" and tostring(source_conns[1].type or "") ~= prev_type then
      return nil, "reloaded connection type changed unexpectedly"
    end
    return source_conns[1], nil
  end

  return nil, "unable to map reloaded connection; reconnect manually from connection picker"
end

---Setup function.
---Needs to be called before calling any other function.
---@param cfg? Config
function dbee.setup(cfg)
  -- merge with defaults
  local merged = config.merge_with_default(cfg)

  -- validate config
  config.validate(merged)

  api.setup(merged)
end

---Toggle dbee UI.
function dbee.toggle()
  if api.current_config().window_layout:is_open() then
    dbee.close()
  else
    dbee.open()
  end
end

---Open dbee UI. If already opened, reset window layout.
function dbee.open()
  if api.current_config().window_layout:is_open() then
    return api.current_config().window_layout:reset()
  end
  api.current_config().window_layout:open()
end

---Close dbee UI.
function dbee.close()
  if not api.current_config().window_layout:is_open() then
    return
  end
  api.current_config().window_layout:close()
end

---Check if dbee UI is open or not.
---@return boolean
function dbee.is_open()
  return api.current_config().window_layout:is_open()
end

---Toggle the drawer panel (for MinimalLayout).
function dbee.toggle_drawer()
  local layout = api.current_config().window_layout
  if layout and type(layout.toggle_drawer) == "function" then
    layout:toggle_drawer()
  end
end

---Open notes picker using snacks.nvim.
function dbee.pick_notes()
  if not api.ui.is_loaded() then
    vim.notify("Dbee not loaded", vim.log.levels.WARN)
    return
  end

  local notes = api.ui.editor_get_all_notes()
  if #notes == 0 then
    vim.notify("No notes found", vim.log.levels.INFO)
    return
  end

  local items = {}
  local max_ns_len = 0
  for _, note in ipairs(notes) do
    max_ns_len = math.max(max_ns_len, #note.namespace)
  end

  for i, note in ipairs(notes) do
    table.insert(items, {
      idx = i,
      score = i,
      text = note.name,
      ns = note.namespace,
      id = note.id,
      file = note.file,
    })
  end

  require("snacks").picker({
    title = "Dbee Notes",
    items = items,
    format = function(item)
      return {
        { ("[%-" .. max_ns_len .. "s]"):format(item.ns), "SnacksPickerLabel" },
        { "  " },
        { item.text, "SnacksPickerFile" },
      }
    end,
    confirm = function(picker, item)
      picker:close()
      api.ui.editor_set_current_note(item.id)
    end,
  })
end

---Open connections picker using snacks.nvim.
function dbee.pick_connections()
  if not api.core.is_loaded() then
    vim.notify("Dbee not loaded", vim.log.levels.WARN)
    return
  end

  local conns = api.core.get_all_connections()
  if #conns == 0 then
    vim.notify("No connections found", vim.log.levels.INFO)
    return
  end

  local items = {}
  local max_name_len = 0
  local max_type_len = 0
  for _, conn in ipairs(conns) do
    max_name_len = math.max(max_name_len, #conn.name)
    max_type_len = math.max(max_type_len, #conn.type)
  end

  for i, conn in ipairs(conns) do
    table.insert(items, {
      idx = i,
      score = conn.is_current and 0 or i,
      text = conn.name,
      conn = conn,
    })
  end

  require("snacks").picker({
    title = "Dbee Connections",
    items = items,
    format = function(item)
      local c = item.conn
      return {
        { c.is_current and "● " or "  ", c.is_current and "SnacksPickerMatch" or "SnacksPickerComment" },
        { ("%-" .. max_name_len .. "s"):format(c.name), "SnacksPickerFile" },
        { "  " },
        { ("%-" .. max_type_len .. "s"):format(c.type), "SnacksPickerLabel" },
        { "  " },
        { c.database or "", "SnacksPickerComment" },
      }
    end,
    preview = function(ctx)
      local c = ctx.item.conn
      local lines = {}
      if c.is_current then
        lines[#lines + 1] = "** Active Connection **"
        lines[#lines + 1] = ""
      end
      lines[#lines + 1] = "Name: " .. c.name
      lines[#lines + 1] = "Type: " .. c.type
      if c.database then
        lines[#lines + 1] = "Database: " .. c.database
      end
      lines[#lines + 1] = "ID:   " .. c.id
      ctx.preview:set_lines(lines)
    end,
    confirm = function(picker, item)
      picker:close()
      api.core.set_current_connection(item.conn.id)
    end,
  })
end

---Open call history picker using snacks.nvim.
function dbee.pick_history()
  if not api.core.is_loaded() then
    vim.notify("Dbee not loaded", vim.log.levels.WARN)
    return
  end

  local history = api.core.get_call_history()
  if #history == 0 then
    vim.notify("No call history", vim.log.levels.INFO)
    return
  end

  -- Build connection name lookup for token matching
  local all_conns = api.core.get_all_connections()
  local conn_names = {} -- lowercase name/id → conn_id
  for _, conn in ipairs(all_conns) do
    conn_names[conn.name:lower()] = conn.id
    conn_names[conn.id:lower()] = conn.id
  end

  local all_items = {}
  for i, entry in ipairs(history) do
    table.insert(all_items, {
      idx = i,
      score = i,
      text = entry.query_preview,
      entry = entry,
    })
  end

  -- Date token matchers keyed by prefix
  local date_tokens = {
    ["today:"] = function(ts)
      local start = os.time({ year = tonumber(os.date("%Y")), month = tonumber(os.date("%m")), day = tonumber(os.date("%d")), hour = 0 })
      return ts >= start
    end,
    ["yesterday:"] = function(ts)
      local today_start = os.time({ year = tonumber(os.date("%Y")), month = tonumber(os.date("%m")), day = tonumber(os.date("%d")), hour = 0 })
      return ts >= today_start - 86400 and ts < today_start
    end,
    ["week:"] = function(ts)
      return ts >= os.time() - 7 * 86400
    end,
    ["month:"] = function(ts)
      return ts >= os.time() - 30 * 86400
    end,
  }

  local active_date_fn = nil
  local active_conn_id = nil

  -- Parse tokens from pattern (left-to-right, multiple allowed)
  local function parse_tokens(pattern)
    active_date_fn = nil
    active_conn_id = nil
    -- Parse tokens left to right
    while true do
      local token = pattern:match("^(%S+:)%s*")
      if not token then break end
      local token_lower = token:sub(1, -2):lower() -- strip trailing ':'
      -- Check date tokens first
      if date_tokens[token] then
        active_date_fn = date_tokens[token]
        pattern = pattern:sub(#token + 1):gsub("^%s+", "")
      -- Check connection names/IDs
      elseif conn_names[token_lower] then
        active_conn_id = conn_names[token_lower]
        pattern = pattern:sub(#token + 1):gsub("^%s+", "")
      else
        break -- unknown token, treat as search text
      end
    end
    return pattern
  end

  require("snacks").picker({
    title = "Dbee History",
    items = all_items,
    filter = {
      transform = function(_, filter)
        local pattern = filter.pattern or ""
        local prev_date = active_date_fn
        local prev_conn = active_conn_id
        filter.pattern = parse_tokens(pattern)
        if active_date_fn ~= prev_date or active_conn_id ~= prev_conn then
          return true
        end
      end,
    },
    transform = function(item)
      if active_date_fn and not active_date_fn(item.entry.timestamp) then
        return false
      end
      if active_conn_id and item.entry.conn_id ~= active_conn_id then
        return false
      end
    end,
    format = function(item)
      local e = item.entry
      return {
        { e.state_icon .. "  ", e.state_icon == "✓" and "SnacksPickerMatch" or "SnacksPickerComment" },
        { e.conn_id .. "  ", "SnacksPickerLabel" },
        { e.query_preview, "SnacksPickerFile" },
        { "  " },
        { e.duration, "SnacksPickerComment" },
        { "  " },
        { e.time, "SnacksPickerComment" },
      }
    end,
    preview = function(ctx)
      local query = ctx.item.entry.call.query or ""
      local lines = vim.split(query, "\n")
      ctx.preview:set_lines(lines)
      ctx.preview:highlight({ ft = "sql" })
    end,
    confirm = function(picker, item)
      picker:close()
      local call = item.entry.call

      -- Search all note files for the query text and navigate there
      local query = call.query or ""
      local query_lines = vim.split(query, "\n")
      if #query_lines > 0 and query_lines[1] ~= "" then
        local all_notes = api.ui.editor_get_all_notes()
        for _, note in ipairs(all_notes) do
          -- Read from file on disk (works even if buffer isn't loaded)
          local file_lines = {}
          if note.file and vim.fn.filereadable(note.file) == 1 then
            file_lines = vim.fn.readfile(note.file)
          elseif note.bufnr and vim.api.nvim_buf_is_valid(note.bufnr) then
            file_lines = vim.api.nvim_buf_get_lines(note.bufnr, 0, -1, false)
          end

          for lnum, line in ipairs(file_lines) do
            -- Match first line, then verify subsequent lines match too
            if line:find(query_lines[1], 1, true) then
              local match = true
              local lines_to_check = math.min(#query_lines, 5)
              for offset = 1, lines_to_check - 1 do
                local fl = file_lines[lnum + offset]
                local ql = query_lines[1 + offset]
                if fl and ql then
                  if not fl:find(ql, 1, true) then
                    match = false
                    break
                  end
                end
              end
              if not match then goto continue end
              api.ui.editor_set_current_note(note.id)
              local current_note = api.ui.editor_get_current_note()
              api.ui.result_restore_call(call)
              -- Find the editor window and focus it
              if current_note and current_note.bufnr then
                vim.schedule(function()
                  for _, win in ipairs(vim.api.nvim_list_wins()) do
                    if vim.api.nvim_win_is_valid(win)
                      and vim.api.nvim_win_get_buf(win) == current_note.bufnr then
                      vim.api.nvim_set_current_win(win)
                      local buf_lines = vim.api.nvim_buf_line_count(current_note.bufnr)
                      local safe_lnum = math.min(lnum, buf_lines)
                      vim.api.nvim_win_set_cursor(win, { safe_lnum, 0 })
                      break
                    end
                  end
                end)
              end
              return
            end
            ::continue::
          end
        end
      end

      -- No note found — show results and open floating query preview
      api.ui.result_restore_call(call)

      -- Open floating preview with query text
      local query = call.query or ""
      local lines = vim.split(query, "\n")
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].filetype = "sql"
      vim.bo[buf].modifiable = false
      vim.bo[buf].bufhidden = "wipe"

      local width = math.min(80, vim.o.columns - 10)
      local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.5))
      local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
        title = " Query Preview ",
        title_pos = "center",
      })

      -- Keybindings for the floating preview
      local close_win = function()
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
      end

      vim.keymap.set("n", "yy", function()
        vim.fn.setreg("+", query)
        vim.notify("Query yanked to clipboard", vim.log.levels.INFO)
        close_win()
      end, { buffer = buf })

      vim.keymap.set("n", "yr", function()
        if call.state == "archived" then
          api.core.call_store_result(call.id, "json", "yank", { extra_arg = "+" })
          vim.notify("Results (JSON) yanked to clipboard", vim.log.levels.INFO)
        end
        close_win()
      end, { buffer = buf })

      vim.keymap.set("n", "yc", function()
        if call.state == "archived" then
          api.core.call_store_result(call.id, "csv", "yank", { extra_arg = "+" })
          vim.notify("Results (CSV) yanked to clipboard", vim.log.levels.INFO)
        end
        close_win()
      end, { buffer = buf })

      vim.keymap.set("n", "q", close_win, { buffer = buf })
      vim.keymap.set("n", "<Esc>", close_win, { buffer = buf })
    end,
  })
end

---Run SQL contextually from current buffer.
---In visual mode runs the selection.
---In normal mode runs the statement under cursor (SQL filetype only).
---@param conn ConnectionParams
---@param query string
---@param opts? { variables?: table<string, string> }
---@param on_done fun(call: CallDetails|nil, error_message: string|nil)
local function execute_with_resolved_variables_async(conn, query, opts, on_done)
  opts = opts or {}
  variables.resolve_for_execute_async(query, {
    adapter_type = conn.type,
    values = opts.variables,
  }, function(resolved, exec_opts, resolve_err)
    if resolve_err then
      on_done(nil, resolve_err)
      return
    end

    local ok, call_or_err = pcall(api.core.connection_execute, conn.id, resolved, exec_opts)
    if not ok then
      on_done(nil, tostring(call_or_err))
      return
    end

    local call = call_or_err
    api.ui.result_set_call(call)
    dbee.open()
    on_done(call, nil)
  end)
end

---Run SQL contextually from current buffer.
---In visual mode runs the selection.
---In normal mode runs the statement under cursor (SQL filetype only).
---@param opts? { query?: string, variables?: table<string, string> }
function dbee.execute_context(opts)
  opts = opts or {}

  local core_ready, core_err = ensure_core_available()
  if not core_ready then
    vim.notify(core_err or "dbee core not loaded", vim.log.levels.WARN)
    return
  end

  local query = utils.trim(opts.query)
  if query == "" then
    local mode = vim.api.nvim_get_mode().mode
    if mode:match("^[vV\22]") then
      local srow, scol, erow, ecol = utils.visual_selection()
      local selection = vim.api.nvim_buf_get_text(0, srow, scol, erow, ecol, {})
      query = utils.trim(table.concat(selection, "\n"))
    else
      local under_cursor = utils.query_under_cursor(vim.api.nvim_get_current_buf())
      query = utils.trim(under_cursor)
    end
  end

  if query == "" then
    vim.notify("No SQL statement to execute at cursor", vim.log.levels.WARN)
    return
  end

  local conn = api.core.get_current_connection()
  if not conn then
    vim.notify("no connection currently selected", vim.log.levels.WARN)
    return
  end

  execute_with_resolved_variables_async(conn, query, opts, function(_, err)
    if err then
      vim.notify(err, vim.log.levels.WARN)
    end
  end)
end

---Execute a script in deterministic statement order.
---Oracle scripts are split with PL/SQL awareness and '/' block terminators.
---@param opts? { query?: string, timeout_ms?: integer, stop_on_error?: boolean, variables?: table<string, string> }
---@return CallDetails[] calls
---@return string? error_message
function dbee.execute_script(opts)
  opts = opts or {}

  local core_ready, core_err = ensure_core_available()
  if not core_ready then
    return {}, core_err
  end

  if active_script_run then
    return {}, "script execution already in progress"
  end

  local conn = api.core.get_current_connection()
  if not conn then
    return {}, "no connection currently selected"
  end

  local script = utils.trim(opts.query)
  if script == "" then
    local bufnr = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    script = table.concat(lines, "\n")
  end

  local resolved_script, script_exec_opts, resolve_err = variables.resolve_for_execute(script, {
    adapter_type = conn.type,
    values = opts.variables,
    reject_script_delimiters = true,
  })
  if resolve_err then
    return {}, resolve_err
  end
  script = resolved_script

  local queries = query_splitter.split(script, {
    adapter_type = conn.type,
  })
  if #queries == 0 then
    vim.notify("No executable statements found in script", vim.log.levels.WARN)
    return {}, nil
  end

  local timeout_ms = tonumber(opts.timeout_ms) or (30 * 60 * 1000)
  local stop_on_error = opts.stop_on_error ~= false
  local calls = {}
  local run_state = {
    canceled = false,
    current_call_id = nil,
    cancel_sent_call_id = nil,
  }
  active_script_run = run_state
  local err_msg = nil

  local ok_run, run_err = xpcall(function()
    dbee.open()

    for _, query in ipairs(queries) do
      if run_state.canceled then
        err_msg = "script execution canceled"
        break
      end

      local query_exec_opts = variables.bind_opts_for_query(query, {
        adapter_type = conn.type,
        binds = script_exec_opts and script_exec_opts.binds or nil,
      })
      local ok_exec, call_or_err = pcall(api.core.connection_execute, conn.id, query, query_exec_opts)
      if not ok_exec then
        if stop_on_error then
          err_msg = "script execution failed to start query: " .. tostring(call_or_err)
          break
        end
      else
        local call = call_or_err
        if not call or not call.id then
          if stop_on_error then
            err_msg = "script execution returned no call details"
            break
          end
        else
          run_state.current_call_id = call.id
          run_state.cancel_sent_call_id = nil
          api.ui.result_set_call(call)
          calls[#calls + 1] = call

          local ok, state = wait_for_call_terminal_state(conn.id, call.id, timeout_ms, run_state)
          if run_state.canceled or state == "canceled" then
            err_msg = "script execution canceled"
            break
          end
          if not ok then
            err_msg = "script execution timed out waiting for call " .. tostring(call.id)
            break
          end
          if state ~= "archived" and stop_on_error then
            err_msg = "script execution stopped on state " .. tostring(state) .. " for call " .. tostring(call.id)
            break
          end
          run_state.current_call_id = nil
        end
      end
    end
  end, debug.traceback)

  if active_script_run == run_state then
    active_script_run = nil
  end

  if not ok_run then
    err_msg = "script execution failed: " .. tostring(run_err)
  end

  return calls, err_msg
end

---Cancel currently running script execution.
function dbee.cancel_script()
  if not active_script_run then
    vim.notify("No running script execution", vim.log.levels.INFO)
    return
  end

  if active_script_run.canceled then
    vim.notify("Script cancellation already requested", vim.log.levels.INFO)
    return
  end

  active_script_run.canceled = true
  vim.notify("Script cancellation requested", vim.log.levels.INFO)
  if
    active_script_run.current_call_id
    and active_script_run.cancel_sent_call_id ~= active_script_run.current_call_id
  then
    active_script_run.cancel_sent_call_id = active_script_run.current_call_id
    pcall(api.core.call_cancel, active_script_run.current_call_id)
  end
end

---Reconnect current connection by reloading its source and selecting it again.
---@param opts? { notify?: boolean }
---@return ConnectionParams|nil reconnected_connection
---@return string|nil error_message
function dbee.reconnect_current_connection(opts)
  opts = opts or {}

  if not is_core_loaded() then
    return nil, "dbee core not loaded"
  end

  local conn = api.core.get_current_connection()
  if not conn then
    return nil, "no connection currently selected"
  end

  local source_id = find_source_id_for_connection(conn.id)
  if not source_id then
    return nil, "could not locate source for current connection"
  end
  if type(api.core.source_reload) ~= "function" then
    return nil, "source reload is not supported by current core API"
  end

  local ok_reload, reload_err = pcall(api.core.source_reload, source_id)
  if not ok_reload then
    return nil, "failed reloading connection source: " .. tostring(reload_err)
  end

  local reloaded_conn, resolve_err = resolve_reloaded_connection(source_id, conn)
  if not reloaded_conn then
    return nil, resolve_err
  end

  local ok_set, set_err = pcall(api.core.set_current_connection, reloaded_conn.id)
  if not ok_set then
    return nil, "failed selecting reloaded connection: " .. tostring(set_err)
  end

  if opts.notify ~= false then
    vim.notify("Reconnected " .. (reloaded_conn.name or reloaded_conn.id), vim.log.levels.INFO)
  end
  return reloaded_conn, nil
end

---Reconnect and retry the latest disconnected failed call for current connection.
---@param opts? { variables?: table<string, string> }
---@return boolean retry_started
---@return string|nil error_message
function dbee.retry_last_disconnected(opts)
  opts = opts or {}

  if not is_core_loaded() then
    return false, "dbee core not loaded"
  end

  local conn = api.core.get_current_connection()
  if not conn then
    return false, "no connection currently selected"
  end

  local call = find_latest_disconnected_call(conn.id)
  if not call then
    return false, "no disconnected call available to retry"
  end

  local query = utils.trim(call.query)
  if query == "" then
    return false, "last disconnected call has empty query"
  end

  local reconnected_conn, reconnect_err = dbee.reconnect_current_connection({ notify = false })
  if not reconnected_conn then
    return false, reconnect_err
  end

  execute_with_resolved_variables_async(reconnected_conn, query, opts, function(_, exec_err)
    if exec_err then
      vim.notify(exec_err, vim.log.levels.WARN)
      return
    end
    vim.notify("Retried last disconnected query", vim.log.levels.INFO)
  end)

  return true, nil
end

---Open contextual action picker.
---Supports non-interactive usage with opts.action.
---@param opts? { action?: string }
function dbee.actions(opts)
  opts = opts or {}

  local core_ready = ensure_core_available({ bootstrap = false })
  local current_conn = nil
  local disconnected_call = nil
  if core_ready then
    current_conn = api.core.get_current_connection()
  end
  if current_conn then
    disconnected_call = find_latest_disconnected_call(current_conn.id)
  end

  local actions = {
    {
      id = "execute",
      label = "Execute Context",
      run = function()
        dbee.execute_context()
      end,
    },
    {
      id = "execute_script",
      label = "Execute Script",
      run = function()
        local _, err = dbee.execute_script()
        if err then
          vim.notify(err, vim.log.levels.WARN)
        end
      end,
    },
    {
      id = "cancel_script",
      label = "Cancel Script",
      run = function()
        dbee.cancel_script()
      end,
    },
    {
      id = "history",
      label = "Open History",
      run = function()
        dbee.pick_history()
      end,
    },
    {
      id = "notes",
      label = "Open Notes",
      run = function()
        dbee.pick_notes()
      end,
    },
    {
      id = "connections",
      label = "Switch Connection",
      run = function()
        dbee.pick_connections()
      end,
    },
    {
      id = "drawer",
      label = "Toggle Drawer",
      run = function()
        dbee.toggle_drawer()
      end,
    },
  }

  if current_conn then
    local reconnect_action = {
      id = "reconnect_current",
      label = "Reconnect Current Connection",
      run = function()
        local _, err = dbee.reconnect_current_connection()
        if err then
          vim.notify(err, vim.log.levels.WARN)
        end
      end,
    }
    local inserted = false
    for idx, action in ipairs(actions) do
      if action.id == "connections" then
        table.insert(actions, idx, reconnect_action)
        inserted = true
        break
      end
    end
    if not inserted then
      actions[#actions + 1] = reconnect_action
    end
  end

  if disconnected_call then
    table.insert(actions, 1, {
      id = "recover_disconnected",
      label = "Reconnect + Retry Last Query",
      run = function()
        local _, err = dbee.retry_last_disconnected()
        if err then
          vim.notify(err, vim.log.levels.WARN)
        end
      end,
    })
  end

  if opts.action then
    for _, action in ipairs(actions) do
      if action.id == opts.action then
        action.run()
        return
      end
    end
    vim.notify("unknown or unavailable dbee action: " .. tostring(opts.action), vim.log.levels.WARN)
    return
  end

  local ok_snacks, snacks = pcall(require, "snacks")
  if not ok_snacks then
    if vim.ui and type(vim.ui.select) == "function" then
      vim.ui.select(actions, {
        prompt = "Dbee Actions",
        format_item = function(item)
          return item.label
        end,
      }, function(choice)
        if choice then
          choice.run()
        end
      end)
    else
      vim.notify("snacks.nvim not available and no vim.ui.select fallback", vim.log.levels.WARN)
    end
    return
  end

  local items = {}
  for i, action in ipairs(actions) do
    items[#items + 1] = {
      idx = i,
      score = i,
      text = action.label,
      action = action,
    }
  end

  snacks.picker({
    title = "Dbee Actions",
    items = items,
    format = function(item)
      return {
        { item.text, "SnacksPickerFile" },
      }
    end,
    confirm = function(picker, item)
      picker:close()
      item.action.run()
    end,
  })
end

---Execute a query on current connection.
---Convenience wrapper around some api functions that executes a query on
---current connection and pipes the output to result UI.
---@param query string
---@param opts? { variables?: table<string, string> }
---@return CallDetails|nil call
---@return string|nil error_message
function dbee.execute(query, opts)
  opts = opts or {}

  local core_ready, core_err = ensure_core_available()
  if not core_ready then
    return nil, core_err
  end

  local conn = api.core.get_current_connection()
  if not conn then
    return nil, "no connection currently selected"
  end

  local resolved, exec_opts, resolve_err = variables.resolve_for_execute(query, {
    adapter_type = conn.type,
    values = opts.variables,
  })
  if resolve_err then
    return nil, resolve_err
  end

  local ok_exec, call_or_err = pcall(api.core.connection_execute, conn.id, resolved, exec_opts)
  if not ok_exec then
    return nil, "failed to execute query: " .. tostring(call_or_err)
  end
  local call = call_or_err
  if not call or not call.id then
    return nil, "query execution returned no call details"
  end

  local ok_set, set_err = pcall(api.ui.result_set_call, call)
  if not ok_set then
    return nil, "failed to set result call: " .. tostring(set_err)
  end

  dbee.open()
  return call, nil
end

---Store currently displayed result.
---Convenience wrapper around some api functions.
---@param format string format of the output -> "csv"|"json"|"table"
---@param output string where to pipe the results -> "file"|"yank"|"buffer"
---@param opts { from: integer, to: integer, extra_arg: any }
function dbee.store(format, output, opts)
  local call = api.ui.result_get_call()
  if not call then
    error("no current call to store")
  end

  api.core.call_store_result(call.id, format, output, opts)
end

---Supported install commands.
---@alias install_command
---| '"wget"'
---| '"curl"'
---| '"bitsadmin"'
---| '"go"'
---| '"cgo"'

---Install dbee backend binary.
---@param command? install_command Preffered install command
---@see install_command
function dbee.install(command)
  install.exec(command)
end

return dbee
