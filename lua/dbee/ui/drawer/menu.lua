local NuiMenu = require("nui.menu")
local NuiInput = require("nui.input")

local M = {}

---@alias menu_select fun(opts?: { title: string, items: string[], on_confirm: fun(selection: string), on_yank: fun(selection: string) })
---@alias menu_input fun(opts?: { title: string, default: string, on_confirm: fun(value: string) })

-- Pick items from a list.
---@param opts { relative_winid: integer, items: string[], on_confirm: fun(item: string), on_yank: fun(item:string), title: string, mappings: key_mapping[], winhighlight?: string }
function M.select(opts)
  opts = opts or {}
  if not opts.relative_winid or not vim.api.nvim_win_is_valid(opts.relative_winid) then
    error("no window id provided")
  end

  local width = vim.api.nvim_win_get_width(opts.relative_winid)
  local row, _ = unpack(vim.api.nvim_win_get_cursor(opts.relative_winid))

  local popup_options = {
    relative = {
      type = "win",
      winid = opts.relative_winid,
    },
    position = {
      row = row + 1,
      col = 0,
    },
    size = {
      width = width,
    },
    zindex = 160,
    border = {
      style = { "─", "─", "─", "", "─", "─", "─", "" },
      text = {
        top = opts.title or "",
        top_align = "left",
      },
    },
    win_options = {
      cursorline = true,
      winhighlight = opts.winhighlight,
    },
  }

  local lines = {}
  for _, item in ipairs(opts.items or {}) do
    table.insert(lines, NuiMenu.item(item))
  end

  local menu = NuiMenu(popup_options, {
    lines = lines,
    keymap = {
      focus_next = { "j", "<Down>", "<Tab>" },
      focus_prev = { "k", "<Up>", "<S-Tab>" },
      close = {},
      submit = {},
    },
    on_submit = function() end,
  })

  -- configure mappings
  for _, km in ipairs(opts.mappings or {}) do
    local action
    if km.action == "menu_confirm" then
      action = opts.on_confirm
    elseif km.action == "menu_yank" then
      action = opts.on_yank
    elseif km.action == "menu_close" then
      action = function() end
    end

    local map_opts = km.opts or { noremap = true, nowait = true }

    if action then
      menu:map(km.mode, km.key, function()
        local item = menu.tree:get_node()
        menu:unmount()
        if item then
          action(item.text)
        end
      end, map_opts)
    end
  end

  menu:mount()
end

-- Ask for input.
---@param opts { relative_winid: integer, default_value: string, on_confirm: fun(item: string), title: string, mappings: key_mapping[], winhighlight?: string }
function M.input(opts)
  if not opts.relative_winid or not vim.api.nvim_win_is_valid(opts.relative_winid) then
    error("no window id provided")
  end

  local width = vim.api.nvim_win_get_width(opts.relative_winid)
  local row, _ = unpack(vim.api.nvim_win_get_cursor(opts.relative_winid))

  local popup_options = {
    relative = {
      type = "win",
      winid = opts.relative_winid,
    },
    position = {
      row = row + 1,
      col = 0,
    },
    size = {
      width = width,
    },
    zindex = 160,
    border = {
      style = { "─", "─", "─", "", "─", "─", "─", "" },
      text = {
        top = opts.title or "",
        top_align = "left",
      },
    },
    win_options = {
      cursorline = false,
      winhighlight = opts.winhighlight,
    },
  }

  local input = NuiInput(popup_options, {
    default_value = opts.default_value,
    on_submit = opts.on_confirm,
  })

  -- configure mappings
  for _, km in ipairs(opts.mappings or {}) do
    local action
    if km.action == "menu_confirm" then
      action = opts.on_confirm
    elseif km.action == "menu_close" then
      action = function() end
    end

    local map_opts = km.opts or { noremap = true, nowait = true }

    if action then
      input:map(km.mode, km.key, function()
        local line = vim.api.nvim_buf_get_lines(input.bufnr, 0, 1, false)[1]
        input:unmount()
        action(line)
      end, map_opts)
    end
  end

  input:mount()
end

-- Live filter with on_change callback.
---@param opts { relative_winid: integer, coverage_label?: string, on_change: fun(value: string), on_submit: fun(value: string), on_close: fun(), mappings?: key_mapping[], forward_insert?: table<string, fun()>, forward_normal?: table<string, fun()> }
function M.filter(opts)
  if not opts.relative_winid or not vim.api.nvim_win_is_valid(opts.relative_winid) then
    error("no window id provided")
  end

  local width = vim.api.nvim_win_get_width(opts.relative_winid)
  local input
  local manual_submit_value = nil

  local popup_options = {
    relative = {
      type = "win",
      winid = opts.relative_winid,
    },
    position = {
      row = 0,
      col = 0,
    },
    size = {
      width = width,
    },
    zindex = 160,
    border = {
      style = { "─", "─", "─", "", "─", "─", "─", "" },
      text = {
        top = " Filter ",
        top_align = "left",
        bottom = opts.coverage_label,
        bottom_align = "right",
      },
    },
    win_options = {
      cursorline = false,
    },
  }

  local function current_value()
    local line = vim.api.nvim_buf_get_lines(input.bufnr, 0, 1, false)[1] or ""
    if line:sub(1, 1) == "/" then
      return line:sub(2)
    end
    return line
  end

  input = NuiInput(popup_options, {
    prompt = "/",
    default_value = "",
    on_change = opts.on_change,
    on_submit = function(value)
      manual_submit_value = nil
      if opts.on_submit then
        opts.on_submit(value)
      end
    end,
    on_close = function()
      if manual_submit_value ~= nil then
        local value = manual_submit_value
        manual_submit_value = nil
        if opts.on_submit then
          opts.on_submit(value)
        end
        return
      end
      if opts.on_close then
        opts.on_close()
      end
    end,
  })

  local reserved_map_opts = { noremap = true, nowait = true }
  local forwarded_map_opts = { noremap = true, nowait = true }

  input:map("i", "<Esc>", function()
    input:unmount()
  end, reserved_map_opts)
  input:map("n", "<Esc>", function()
    input:unmount()
  end, reserved_map_opts)

  for key, fn in pairs(opts.forward_insert or {}) do
    input:map("i", key, fn, forwarded_map_opts)
  end

  input:map("i", "<C-]>", function()
    vim.cmd("stopinsert")
  end, reserved_map_opts)

  input:map("n", "i", function()
    vim.cmd("startinsert")
  end, reserved_map_opts)
  input:map("n", "<CR>", function()
    manual_submit_value = current_value()
    input:unmount()
  end, reserved_map_opts)

  for key, fn in pairs(opts.forward_normal or {}) do
    input:map("n", key, fn, forwarded_map_opts)
  end

  input:mount()
  return input
end

return M
