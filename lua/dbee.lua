local install = require("dbee.install")
local api = require("dbee.api")
local config = require("dbee.config")

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

  require("snacks").picker({
    title = "Dbee History",
    items = all_items,
    filter = {
      transform = function(_, filter)
        local pattern = filter.pattern or ""
        local prev = active_date_fn
        active_date_fn = nil
        for token, fn in pairs(date_tokens) do
          if pattern:sub(1, #token) == token then
            active_date_fn = fn
            filter.pattern = pattern:sub(#token + 1)
            break
          end
        end
        -- Force refresh when date filter changes (added or removed)
        if active_date_fn ~= prev then
          return true
        end
      end,
    },
    transform = function(item)
      if active_date_fn and not active_date_fn(item.entry.timestamp) then
        return false
      end
    end,
    format = function(item)
      local e = item.entry
      return {
        { e.state_icon .. "  ", e.state_icon == "✓" and "SnacksPickerMatch" or "SnacksPickerComment" },
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
              api.ui.result_set_call(call)
              if call.state == "archived" or call.state == "retrieving" then
                api.ui.result_page_current()
              end
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
      api.ui.result_set_call(call)
      if call.state == "archived" or call.state == "retrieving" then
        api.ui.result_page_current()
      end

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

---Execute a query on current connection.
---Convenience wrapper around some api functions that executes a query on
---current connection and pipes the output to result UI.
---@param query string
function dbee.execute(query)
  local conn = api.core.get_current_connection()
  if not conn then
    error("no connection currently selected")
  end

  local call = api.core.connection_execute(conn.id, query)
  api.ui.result_set_call(call)

  dbee.open()
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
