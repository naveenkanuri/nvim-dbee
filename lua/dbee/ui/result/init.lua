local utils = require("dbee.utils")
local progress = require("dbee.ui.result.progress")
local common = require("dbee.ui.common")

local format_duration = utils.format_duration

-- ResultUI represents the part of ui with displayed results
---@class ResultUI
---@field private handler Handler
---@field private winid? integer
---@field private bufnr integer
---@field private current_call? CallDetails
---@field private page_size integer
---@field private focus_result boolean
---@field private mappings key_mapping[]
---@field private page_index integer index of the current page
---@field private page_ammount integer number of pages in the current result set
---@field private total_rows integer total row count from last display_result
---@field private stop_progress fun() function that stops progress display
---@field private _progress_running boolean whether progress display is active
---@field private progress_opts progress_config
---@field private window_options table<string, any> a table of window options.
---@field private buffer_options table<string, any> a table of buffer options.
local ResultUI = {}

---@param handler Handler
---@param opts? result_config
---@return ResultUI
function ResultUI:new(handler, opts)
  opts = opts or {}

  if not handler then
    error("no Handler passed to ResultUI")
  end

  -- class object
  local o = {
    handler = handler,
    page_size = opts.page_size or 100,
    page_index = 0,
    page_ammount = 0,
    total_rows = 0,
    focus_result = opts.focus_result,
    mappings = opts.mappings or {},
    stop_progress = function() end,
    _progress_running = false,
    progress_opts = opts.progress or {},
    window_options = vim.tbl_extend("force", {
      wrap = false,
      winfixheight = true,
      winfixwidth = true,
      number = false,
      relativenumber = false,
      spell = false,
    }, opts.window_options or {}),
    buffer_options = vim.tbl_extend("force", {
      buflisted = false,
      bufhidden = "delete",
      buftype = "nofile",
      swapfile = false,
      modifiable = false,
      filetype = "dbee",
    }, opts.buffer_options or {}),
  }
  setmetatable(o, self)
  self.__index = self

  -- create a buffer for drawer and configure it
  o.bufnr = common.create_blank_buffer("dbee-result", o.buffer_options)
  common.configure_buffer_mappings(o.bufnr, o:get_actions(), opts.mappings)

  handler:register_event_listener("call_state_changed", function(data)
    o:on_call_state_changed(data)
  end)

  return o
end

-- event listener for new calls
---@private
---@param data { call: CallDetails }
function ResultUI:on_call_state_changed(data)
  local call = data.call

  -- we only care about the current call
  if not self.current_call or call.id ~= self.current_call.id then
    return
  end

  -- update the current call with up to date details
  self.current_call = call

  -- perform action based on the state
  if call.state == "executing" or call.state == "retrieving" then
    -- Update winbar to reflect current state (must happen on EVERY transition,
    -- not just the first entry when _progress_running is false)
    if self:has_window() then
      if call.state == "executing" then
        vim.api.nvim_set_option_value("winbar", "Executing...", { win = self.winid })
      else
        vim.api.nvim_set_option_value("winbar", "Retrieving...", { win = self.winid })
      end
    end

    -- Only start the progress spinner once per call lifecycle
    if not self._progress_running then
      self.stop_progress()
      self:display_progress()
      self._progress_running = true
    end
  elseif call.state == "archived" then
    self._progress_running = false
    self.stop_progress()
    self:page_current()
  elseif call.state == "executing_failed" or call.state == "retrieving_failed"
      or call.state == "archive_failed" or call.state == "canceled" then
    self._progress_running = false
    self.stop_progress()
    self:display_status()
  else
    self._progress_running = false
    self.stop_progress()
  end
end

---@private
function ResultUI:apply_highlight(winid)
  -- switch to provided window, apply hightlight and jump back
  local current_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(winid)
  -- match table separators and leading row numbers
  vim.cmd([[match NonText /^\s*\d\+\|─\|│\|┼/]])
  vim.api.nvim_set_current_win(current_win)
end

---@private
---@return boolean
function ResultUI:has_window()
  if self.winid and vim.api.nvim_win_is_valid(self.winid) then
    return true
  end
  return false
end

---@private
function ResultUI:focus_result_window()
  if self.focus_result and self:has_window() then
    return vim.api.nvim_set_current_win(self.winid)
  end
end

---@private
function ResultUI:set_default_result_window()
  if self:has_window() then
    vim.api.nvim_set_option_value("winbar", "Results", { win = self.winid })
  end
end

---@private
---@param start_offset? number elapsed seconds to offset the timer by
function ResultUI:display_progress(start_offset)
  local opts = self.progress_opts
  if start_offset then
    opts = vim.tbl_extend("force", opts, { start_offset = start_offset })
  end
  self.stop_progress = progress.display(self.bufnr, opts)
end

---@private
function ResultUI:display_status()
  if not self.current_call then
    error("no call set to result")
  end

  local state = self.current_call.state
  local error_kind = self.current_call.error_kind

  local msg = ""
  if state == "executing_failed" then
    if error_kind == "disconnected" then
      msg = "Call failed: connection lost"
    elseif error_kind == "timeout" then
      msg = "Call timed out"
    elseif error_kind == "canceled" then
      msg = "Call canceled"
    else
      msg = "Call execution failed"
    end
  elseif state == "retrieving_failed" then
    if error_kind == "disconnected" then
      msg = "Result retrieval failed: connection lost"
    elseif error_kind == "timeout" then
      msg = "Result retrieval timed out"
    elseif error_kind == "canceled" then
      msg = "Call canceled"
    else
      msg = "Failed retrieving results"
    end
  elseif state == "archive_failed" then
    if error_kind == "timeout" then
      msg = "Result archiving timed out"
    elseif error_kind == "disconnected" then
      msg = "Result archiving failed: connection lost"
    elseif error_kind == "canceled" then
      msg = "Call canceled"
    else
      msg = "Failed archiving results"
    end
  elseif state == "canceled" then
    msg = "Call canceled"
  end

  local seconds = (tonumber(self.current_call.time_taken_us) or 0) / 1000000

  local lines = {
    string.format("%s after %.3f seconds", msg, seconds),
  }

  if error_kind == "disconnected" then
    table.insert(lines, "Hint: open dbee actions and choose Reconnect + Retry Last Query")
  end

  if self.current_call.error and self.current_call.error ~= "" then
    table.insert(lines, "Reason:")
    for err_line in string.gmatch(self.current_call.error, "[^\n]+") do
      table.insert(lines, "    " .. err_line)
    end
  end

  vim.api.nvim_buf_set_option(self.bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)

  vim.api.nvim_buf_set_option(self.bufnr, "modifiable", false)

  -- set winbar
  self:set_default_result_window()

  -- reset modified flag
  vim.api.nvim_buf_set_option(self.bufnr, "modified", false)
end

--- Displays a page of the current result in the results buffer
---@private
---@param page integer zero based page index
---@return integer # current page
function ResultUI:display_result(page)
  if not self.current_call then
    error("no call set to result")
  end
  -- calculate the ranges
  if page < 0 then
    page = 0
  end
  if page > self.page_ammount then
    page = self.page_ammount
  end
  local from = self.page_size * page
  local to = self.page_size * (page + 1)

  -- call go function
  local length = self.handler:call_display_result(self.current_call.id, self.bufnr, from, to)
  self.total_rows = length

  -- adjust page ammount
  self.page_ammount = math.floor(length / self.page_size)
  if length % self.page_size == 0 and self.page_ammount ~= 0 then
    self.page_ammount = self.page_ammount - 1
  end

  -- set winbar status
  if self:has_window() then
    vim.api.nvim_set_option_value("winbar",
      string.format("Page %d/%d | %d rows | %s",
        page + 1, self.page_ammount + 1, length, format_duration(self.current_call.time_taken_us)),
      { win = self.winid })
  end
  -- set focus if window exists
  self:focus_result_window()

  -- reset modified flag
  vim.api.nvim_buf_set_option(self.bufnr, "modified", false)

  return page
end

---@private
---@return table<string, fun()>
function ResultUI:get_actions()
  return {
    page_next = function()
      self:page_next()
    end,
    page_prev = function()
      self:page_prev()
    end,
    page_last = function()
      self:page_last()
    end,
    page_first = function()
      self:page_first()
    end,

    -- yank functions
    yank_current_json = function()
      self:store_current_wrapper("json", vim.v.register)
    end,
    yank_selection_json = function()
      self:store_selection_wrapper("json", vim.v.register)
    end,
    yank_all_json = function()
      self:store_all_wrapper("json", vim.v.register)
    end,
    yank_current_csv = function()
      self:store_current_wrapper("csv", vim.v.register)
    end,
    yank_selection_csv = function()
      self:store_selection_wrapper("csv", vim.v.register)
    end,
    yank_all_csv = function()
      self:store_all_wrapper("csv", vim.v.register)
    end,

    cancel_call = function()
      if self.current_call then
        local ok, err = self.handler:call_cancel(self.current_call.id)
        if ok == false and err then
          utils.log("warn", err)
        end
      end
    end,

    -- export current result set to a CSV or JSON file
    export_result = function()
      if not self.current_call then
        utils.log("warn", "No results to export")
        return
      end

      -- Capture state before async prompts to avoid race conditions
      local call_id = self.current_call.id
      local row_count = self.total_rows or 0

      vim.ui.input({ prompt = "Export to: ", default = vim.fn.getcwd() .. "/result.csv" }, function(path)
        if not path or path == "" then
          return
        end

        -- Infer format from extension
        local ext = vim.fn.fnamemodify(path, ":e"):lower()
        local format_map = { csv = "csv", json = "json" }
        local format = format_map[ext]
        if not format then
          utils.log("warn", "Unsupported format '." .. ext .. "'. Use .csv or .json")
          return
        end

        local function do_export()
          -- Large export warning
          if row_count > 10000 then
            utils.log("info", string.format("Exporting %d rows - this may take a moment...", row_count))
          end

          local ok, err = pcall(self.handler.call_store_result, self.handler, call_id, format, "file", { extra_arg = path })
          if not ok then
            utils.log("error", "Export failed: " .. tostring(err))
            return
          end
          utils.log("info", string.format("Exported %d rows to %s", row_count, path))
        end

        -- Overwrite guard
        if vim.fn.filereadable(path) == 1 then
          vim.ui.select({ "No", "Yes" }, { prompt = "File exists. Overwrite?" }, function(choice)
            if choice == "Yes" then
              do_export()
            end
          end)
        else
          do_export()
        end
      end)
    end,
  }
end

---Triggers an in-built action.
---@param action string
function ResultUI:do_action(action)
  local act = self:get_actions()[action]
  if not act then
    error("unknown action: " .. action)
  end
  act()
end

-- sets call's result to Result's buffer
---@param call CallDetails
function ResultUI:set_call(call)
  self.page_index = 0
  self.page_ammount = 0
  self.current_call = call

  self.stop_progress()
end

-- Restore a call's display state (used when switching editor notes).
-- Handles all call states: shows spinner for executing, results for
-- retrieving/archived, error message for failed/canceled states.
---@param call CallDetails
function ResultUI:restore_call(call)
  self:set_call(call)

  local function elapsed_since_call_start_us(ts_us)
    local timestamp_us = tonumber(ts_us) or 0
    if timestamp_us <= 0 then
      return 0
    end
    local now_us = vim.fn.localtime() * 1000000
    if now_us <= timestamp_us then
      return 0
    end
    return (now_us - timestamp_us) / 1000000
  end

  if call.state == "executing" then
    if self:has_window() then
      vim.api.nvim_set_option_value("winbar", "Executing...", { win = self.winid })
    end
    local elapsed = elapsed_since_call_start_us(call.timestamp_us)
    self:display_progress(elapsed)
  elseif call.state == "retrieving" then
    if self:has_window() then
      vim.api.nvim_set_option_value("winbar", "Retrieving...", { win = self.winid })
    end
    local elapsed = elapsed_since_call_start_us(call.timestamp_us)
    self:display_progress(elapsed)
  elseif call.state == "archived" then
    self:page_current()
  elseif call.state == "executing_failed" or call.state == "retrieving_failed"
      or call.state == "archive_failed" or call.state == "canceled" then
    self:display_status()
  else
    self:set_default_result_window()
  end
end

-- Clear the result display (used when switching to a note with no query history).
function ResultUI:clear()
  self.stop_progress()
  self.current_call = nil
  self.page_index = 0
  self.page_ammount = 0

  vim.api.nvim_buf_set_option(self.bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, {})
  vim.api.nvim_buf_set_option(self.bufnr, "modifiable", false)
  vim.api.nvim_buf_set_option(self.bufnr, "modified", false)

  self:set_default_result_window()
end

-- Gets the currently displayed call.
---@return CallDetails?
function ResultUI:get_call()
  return self.current_call
end

function ResultUI:page_current()
  self.page_index = self:display_result(self.page_index)
end

function ResultUI:page_next()
  self.page_index = self:display_result(self.page_index + 1)
end

function ResultUI:page_prev()
  self.page_index = self:display_result(self.page_index - 1)
end

function ResultUI:page_last()
  self.page_index = self:display_result(self.page_ammount)
end

function ResultUI:page_first()
  self.page_index = self:display_result(0)
end

-- wrapper for storing the current row
---@private
---@param format string
---@param register string
function ResultUI:store_current_wrapper(format, register)
  if not self.current_call then
    utils.log("warn", "No results to yank")
    return
  end
  local ok_idx, index = pcall(self.current_row_index, self)
  if not ok_idx then
    utils.log("warn", "Could not determine current row")
    return
  end

  index = index - 1
  if index <= 0 then
    index = 0
  end

  local ok, err = pcall(self.handler.call_store_result, self.handler,
    self.current_call.id, format, "yank",
    { from = index, to = index + 1, extra_arg = register })
  if not ok then
    utils.log("error", "Yank failed: " .. tostring(err))
    return
  end
  utils.log("info", "Yanked 1 row (" .. string.upper(format) .. ")")
end

-- wrapper for storing the current visually selected rows
---@private
---@param format string
---@param register string
function ResultUI:store_selection_wrapper(format, register)
  if not self.current_call then
    utils.log("warn", "No results to yank")
    return
  end
  local ok_range, sindex, eindex = pcall(self.current_row_range, self)
  if not ok_range then
    utils.log("warn", "Could not determine selected rows")
    return
  end

  sindex = sindex - 1
  if sindex <= 0 then
    sindex = 0
  end

  local row_count = eindex - sindex

  local ok, err = pcall(self.handler.call_store_result, self.handler,
    self.current_call.id, format, "yank",
    { from = sindex, to = eindex, extra_arg = register })
  if not ok then
    utils.log("error", "Yank failed: " .. tostring(err))
    return
  end
  utils.log("info", string.format("Yanked %d row%s (%s)", row_count, row_count == 1 and "" or "s", string.upper(format)))
end

-- wrapper for storing all rows
---@private
---@param format string
---@param register string
function ResultUI:store_all_wrapper(format, register)
  if not self.current_call then
    utils.log("warn", "No results to yank")
    return
  end
  local ok, err = pcall(self.handler.call_store_result, self.handler,
    self.current_call.id, format, "yank", { extra_arg = register })
  if not ok then
    utils.log("error", "Yank failed: " .. tostring(err))
    return
  end
  local count = self.total_rows or 0
  utils.log("info", string.format("Yanked %d row%s (%s)", count, count == 1 and "" or "s", string.upper(format)))
end

---@private
---@return number # index of the current row
function ResultUI:current_row_index()
  -- get position of the current line identifier
  local row = vim.fn.search([[^\s*[0-9]\+]], "bnc", 1)
  if row == 0 then
    error("couldn't retrieve current row number: row = 0")
  end

  -- get the line and extract the line number
  local line = vim.api.nvim_buf_get_lines(self.bufnr, row - 1, row, true)[1] or ""

  local index = tonumber(line:match("%d+"))
  if not index then
    error("couldn't retrieve current row number")
  end
  return index
end

---@private
---@return number # number of the first row
---@return number # number of the last row
function ResultUI:current_row_range()
  if not self:has_window() then
    error("result cannot operate without a valid window")
  end
  -- get current selection
  local srow, _, erow, _ = utils.visual_selection()

  srow = srow + 1
  erow = erow + 1

  -- save cursor position
  local cursor_position = vim.fn.getcurpos(self.winid)

  -- reposition the cursor
  vim.fn.cursor(srow, 1)
  -- get position of the start line identifier
  local row = vim.fn.search([[^\s*[0-9]\+]], "bnc", 1)
  if row == 0 then
    error("couldn't retrieve start row number: row = 0")
  end

  -- get the selected line and extract the line number
  local line = vim.api.nvim_buf_get_lines(self.bufnr, row - 1, row, true)[1] or ""

  local index_start = tonumber(line:match("%d+"))
  if not index_start then
    error("couldn't retrieve start row number")
  end

  -- reposition the cursor
  vim.fn.cursor(erow, 1)
  -- get position of the end line identifier
  row = vim.fn.search([[^\s*[0-9]\+]], "bnc", 1)
  if row == 0 then
    error("couldn't retrieve end row number: row = 0")
  end
  -- get the selected line and extract the line number
  line = vim.api.nvim_buf_get_lines(self.bufnr, row - 1, row, true)[1] or ""

  local index_end = tonumber(line:match("%d+"))
  if not index_end then
    error("couldn't retrieve end row number")
  end

  -- restore cursor position
  vim.fn.setpos(".", cursor_position)

  return index_start, index_end
end

---@param winid integer
function ResultUI:show(winid)
  self.winid = winid

  -- configure window highlights
  self:apply_highlight(self.winid)

  vim.api.nvim_win_set_buf(self.winid, self.bufnr)

  common.configure_buffer_options(self.bufnr, self.buffer_options)
  common.configure_buffer_mappings(self.bufnr, self:get_actions(), self.mappings)

  -- configure window options (needs to be set after setting the buffer to window)
  common.configure_window_options(self.winid, self.window_options)

  -- display the current result
  local ok = pcall(self.page_current, self)
  if not ok then
    self:set_default_result_window()
  end
end

return ResultUI
