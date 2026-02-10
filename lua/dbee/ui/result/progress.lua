local M = {}

---@alias progress_config { text_prefix?: string, spinner?: string[], start_offset?: number, slow_threshold_s?: number, stuck_threshold_s?: number, slow_hint?: string, stuck_hint?: string, cancel_hint?: string }

--- Display an updated progress loader in the specified buffer
---@param bufnr integer -- buffer to display the progres in
---@param opts? progress_config
---@return fun() # cancel function
function M.display(bufnr, opts)
  if not bufnr then
    return function() end
  end
  opts = opts or {}
  local text_prefix = opts.text_prefix or "Loading..."
  local spinner = opts.spinner or { "|", "/", "-", "\\" }
  if #spinner == 0 then
    spinner = { "|" }
  end
  -- Threshold values can come from user config; normalize to numbers so
  -- string values don't silently disable hint transitions.
  local slow_threshold_s = tonumber(opts.slow_threshold_s) or 8
  local stuck_threshold_s = tonumber(opts.stuck_threshold_s) or 20
  local slow_hint = opts.slow_hint or "Slow query"
  local stuck_hint = opts.stuck_hint or "Possibly stuck"
  local cancel_hint = opts.cancel_hint or "cancel with <C-c> (default)"

  local icon_index = 1
  local start_offset = tonumber(opts.start_offset) or 0
  local start_time = vim.fn.reltimefloat(vim.fn.reltime()) - start_offset

  local timer = nil
  local stopped = false

  local function stop()
    if stopped then
      return
    end
    stopped = true
    if timer ~= nil then
      pcall(vim.fn.timer_stop, timer)
    end
  end

  local function update()
    if stopped then
      return
    end
    if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
      stop()
      return
    end

    local passed_time = vim.fn.reltimefloat(vim.fn.reltime()) - start_time
    icon_index = (icon_index % #spinner) + 1

    local hint = nil
    if stuck_threshold_s > 0 and passed_time >= stuck_threshold_s then
      hint = stuck_hint
    elseif slow_threshold_s > 0 and passed_time >= slow_threshold_s then
      hint = slow_hint
    end

    local suffix = ""
    if hint then
      suffix = string.format(" | %s | %s", hint, cancel_hint)
    end

    local ok = pcall(function()
      vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
      local line = string.format("%s %.3f seconds %s%s", text_prefix, passed_time, spinner[icon_index], suffix)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
      vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
    end)
    if not ok then
      stop()
    end
  end

  update()
  timer = vim.fn.timer_start(100, update, { ["repeat"] = -1 })
  return stop
end

return M
