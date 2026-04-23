local tools = require("dbee.layouts.tools")
local utils = require("dbee.utils")
local api_ui = require("dbee.api.ui")

---@mod dbee.ref.layout UI Layout
---@brief [[
---Defines the layout of UI windows.
---The default layout is already defined, but it's possible to define your own layout.
---
---Layout implementation should implement the |Layout| interface and show the UI on screen
---as seen fit.
---@brief ]]

---Layout that defines how windows are opened.
---Layouts are free to use both core and ui apis.
---see |dbee.ref.api.core| and |dbee.ref.api.ui|
---
---Important for layout implementations: when opening windows, they must be
---exclusive to dbee. When closing windows, make sure to not reuse any windows dbee left over.
---@class Layout
---@field is_open fun(self: Layout):boolean function that returns the state of ui.
---@field open fun(self: Layout) function to open ui.
---@field reset fun(self: Layout) function to reset ui.
---@field close fun(self: Layout) function to close ui.
---@field focus_pane? fun(self: Layout, name: string):boolean
---@field ensure_drawer_visible? fun(self: Layout):boolean
--- Callers must check optional compatibility methods before using them and WARN gracefully.

local layouts = {}

---@divider -

-- Default layout uses a helper to save the existing window layout before opening any windows,
-- then makes a new empty window for the editor and then opens result and drawer.
-- When later calling close(), the previously saved layout is restored.
---@class DefaultLayout: Layout
---@field private drawer_width integer
---@field private result_height integer
---@field private call_log_height integer
---@field private egg? layout_egg
---@field private windows table<string, integer>
---@field private on_switch "immutable"|"close"
---@field private is_opened boolean
layouts.Default = {}

---Create a default layout.
---The on_switch parameter defines what to do in case another buffer wants to be open in any window. default: "immutable"
---@param opts? { on_switch: "immutable"|"close", drawer_width: integer, result_height: integer, call_log_height: integer }
---@return DefaultLayout
function layouts.Default:new(opts)
  opts = opts or {}

  -- validate opts
  for _, opt in ipairs { "drawer_width", "result_height", "call_log_height" } do
    if opts[opt] and opts[opt] < 0 then
      error(opt .. " must be a positive integer. Got: " .. opts[opt])
    end
  end

  ---@type DefaultLayout
  local o = {
    egg = nil,
    windows = {},
    on_switch = opts.on_switch or "immutable",
    is_opened = false,
    drawer_width = opts.drawer_width or 40,
    result_height = opts.result_height or 20,
    call_log_height = opts.call_log_height or 20,
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

---Action taken when another (inapropriate) buffer is open in the window.
---@package
---@param on_switch "immutable"|"close"
---@param winid integer
---@param open_fn fun(winid: integer)
---@param is_editor? boolean special care needs to be taken with editor - it uses multiple buffers.
function layouts.Default:configure_window_on_switch(on_switch, winid, open_fn, is_editor)
  local action
  if on_switch == "close" then
    action = function(_, buf, file)
      if is_editor then
        local note, _ = api_ui.editor_search_note_with_file(file)
        if note then
          -- do nothing
          return
        end
        note, _ = api_ui.editor_search_note_with_buf(buf)
        if note then
          -- do nothing
          return
        end
      end
      -- close dbee and open buffer
      self:close()
      vim.api.nvim_win_set_buf(0, buf)
    end
  else
    action = function(win, _, _)
      open_fn(win)
    end
  end

  utils.create_singleton_autocmd({ "BufWinEnter", "BufReadPost", "BufNewFile" }, {
    window = winid,
    callback = function(event)
      action(winid, event.buf, event.file)
    end,
  })
end

---Close all other windows when one is closed.
---@package
---@param winid integer
function layouts.Default:configure_window_on_quit(winid)
  utils.create_singleton_autocmd({ "QuitPre" }, {
    window = winid,
    callback = function()
      self:close()
    end,
  })
end

---@package
---@return boolean
function layouts.Default:is_open()
  return self.is_opened
end

---@package
function layouts.Default:open()
  -- save layout before opening ui
  self.egg = tools.save()

  self.windows = {}

  -- editor
  tools.make_only(0)
  local editor_win = vim.api.nvim_get_current_win()
  self.windows["editor"] = editor_win
  api_ui.editor_show(editor_win)
  self:configure_window_on_switch(self.on_switch, editor_win, api_ui.editor_show, true)
  self:configure_window_on_quit(editor_win)

  -- result
  vim.cmd("bo" .. self.result_height .. "split")
  local win = vim.api.nvim_get_current_win()
  self.windows["result"] = win
  api_ui.result_show(win)
  self:configure_window_on_switch(self.on_switch, win, api_ui.result_show)
  self:configure_window_on_quit(win)

  -- drawer
  vim.cmd("to" .. self.drawer_width .. "vsplit")
  win = vim.api.nvim_get_current_win()
  self.windows["drawer"] = win
  api_ui.drawer_show(win)
  self:configure_window_on_switch(self.on_switch, win, api_ui.drawer_show)
  self:configure_window_on_quit(win)

  -- call log
  vim.cmd("belowright " .. self.call_log_height .. "split")
  win = vim.api.nvim_get_current_win()
  self.windows["call_log"] = win
  api_ui.call_log_show(win)
  self:configure_window_on_switch(self.on_switch, win, api_ui.call_log_show)
  self:configure_window_on_quit(win)

  -- set cursor to editor
  vim.api.nvim_set_current_win(editor_win)

  self.is_opened = true
end

---@package
function layouts.Default:reset()
  vim.api.nvim_win_set_height(self.windows["result"], self.result_height)
  vim.api.nvim_win_set_width(self.windows["drawer"], self.drawer_width)
  vim.api.nvim_win_set_height(self.windows["call_log"], self.call_log_height)
end

---@package
function layouts.Default:close()
  -- close all windows
  for _, win in pairs(self.windows) do
    pcall(vim.api.nvim_win_close, win, false)
  end

  -- restore layout
  tools.restore(self.egg)
  self.egg = nil
  self.is_opened = false
end

---Focus a named pane window.
---@param name string pane name: "editor", "result", "drawer", "call_log"
---@return boolean success
function layouts.Default:focus_pane(name)
  local winid = self.windows[name]
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return false
  end
  vim.api.nvim_set_current_win(winid)
  return true
end

---Ensure drawer is visible. No-op for DefaultLayout (drawer always visible).
---@return boolean
function layouts.Default:ensure_drawer_visible()
  return true
end

---@divider -

-- Minimal layout creates only editor + result windows in a 70/30 vertical split.
-- The drawer can be toggled on/off as needed.
---@class MinimalLayout: Layout
---@field private result_height_pct number percentage of window height for results (0.3 = 30%)
---@field private egg? layout_egg
---@field private windows table<string, integer>
---@field private drawer_win? integer optional drawer window when toggled on
---@field private drawer_width integer
---@field private on_switch "immutable"|"close"
---@field private is_opened boolean
layouts.Minimal = {}

---Create a minimal layout (editor + results only).
---The on_switch parameter defines what to do in case another buffer wants to be open in any window. default: "immutable"
---@param opts? { on_switch: "immutable"|"close", result_height_pct: number, drawer_width: integer }
---@return MinimalLayout
function layouts.Minimal:new(opts)
  opts = opts or {}

  -- validate opts
  if opts.result_height_pct and (opts.result_height_pct <= 0 or opts.result_height_pct >= 1) then
    error("result_height_pct must be between 0 and 1. Got: " .. opts.result_height_pct)
  end
  if opts.drawer_width and opts.drawer_width < 0 then
    error("drawer_width must be a positive integer. Got: " .. opts.drawer_width)
  end

  ---@type MinimalLayout
  local o = {
    egg = nil,
    windows = {},
    drawer_win = nil,
    on_switch = opts.on_switch or "immutable",
    is_opened = false,
    result_height_pct = opts.result_height_pct or 0.3,
    drawer_width = opts.drawer_width or 40,
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

---Action taken when another (inapropriate) buffer is open in the window.
---@package
---@param on_switch "immutable"|"close"
---@param winid integer
---@param open_fn fun(winid: integer)
---@param is_editor? boolean special care needs to be taken with editor - it uses multiple buffers.
function layouts.Minimal:configure_window_on_switch(on_switch, winid, open_fn, is_editor)
  local action
  if on_switch == "close" then
    action = function(_, buf, file)
      if is_editor then
        local note, _ = api_ui.editor_search_note_with_file(file)
        if note then
          -- do nothing
          return
        end
        note, _ = api_ui.editor_search_note_with_buf(buf)
        if note then
          -- do nothing
          return
        end
      end
      -- close dbee and open buffer
      self:close()
      vim.api.nvim_win_set_buf(0, buf)
    end
  else
    action = function(win, _, _)
      open_fn(win)
    end
  end

  utils.create_singleton_autocmd({ "BufWinEnter", "BufReadPost", "BufNewFile" }, {
    window = winid,
    callback = function(event)
      action(winid, event.buf, event.file)
    end,
  })
end

---Close all other windows when one is closed.
---@package
---@param winid integer
function layouts.Minimal:configure_window_on_quit(winid)
  utils.create_singleton_autocmd({ "QuitPre" }, {
    window = winid,
    callback = function()
      self:close()
    end,
  })
end

---@package
---@return boolean
function layouts.Minimal:is_open()
  return self.is_opened
end

---@package
function layouts.Minimal:open()
  -- save layout before opening ui
  self.egg = tools.save()

  self.windows = {}

  -- Calculate heights based on total available height
  local total_height = vim.o.lines - vim.o.cmdheight - 1
  local result_height = math.floor(total_height * self.result_height_pct)

  -- editor (takes remaining space)
  tools.make_only(0)
  local editor_win = vim.api.nvim_get_current_win()
  self.windows["editor"] = editor_win
  api_ui.editor_show(editor_win)
  self:configure_window_on_switch(self.on_switch, editor_win, api_ui.editor_show, true)
  self:configure_window_on_quit(editor_win)

  -- result (bottom, 30% height)
  vim.cmd("bo" .. result_height .. "split")
  local win = vim.api.nvim_get_current_win()
  self.windows["result"] = win
  api_ui.result_show(win)
  self:configure_window_on_switch(self.on_switch, win, api_ui.result_show)
  self:configure_window_on_quit(win)

  -- set cursor to editor
  vim.api.nvim_set_current_win(editor_win)

  self.is_opened = true
end

---@package
function layouts.Minimal:reset()
  local total_height = vim.o.lines - vim.o.cmdheight - 1
  local result_height = math.floor(total_height * self.result_height_pct)
  vim.api.nvim_win_set_height(self.windows["result"], result_height)
  if self.drawer_win and vim.api.nvim_win_is_valid(self.drawer_win) then
    vim.api.nvim_win_set_width(self.drawer_win, self.drawer_width)
  end
end

---@package
function layouts.Minimal:close()
  -- close drawer if open
  if self.drawer_win and vim.api.nvim_win_is_valid(self.drawer_win) then
    pcall(vim.api.nvim_win_close, self.drawer_win, false)
    self.drawer_win = nil
  end

  -- close all windows
  for _, win in pairs(self.windows) do
    pcall(vim.api.nvim_win_close, win, false)
  end

  -- restore layout
  tools.restore(self.egg)
  self.egg = nil
  self.is_opened = false
end

---Toggle the drawer panel on the left side.
---@package
function layouts.Minimal:toggle_drawer()
  if self.drawer_win and vim.api.nvim_win_is_valid(self.drawer_win) then
    -- Close drawer
    pcall(vim.api.nvim_win_close, self.drawer_win, false)
    self.drawer_win = nil
  else
    -- Open drawer to the left of editor
    local editor_win = self.windows["editor"]
    if editor_win and vim.api.nvim_win_is_valid(editor_win) then
      vim.api.nvim_set_current_win(editor_win)
      vim.cmd("to" .. self.drawer_width .. "vsplit")
      self.drawer_win = vim.api.nvim_get_current_win()
      api_ui.drawer_show(self.drawer_win)
      self:configure_window_on_switch(self.on_switch, self.drawer_win, api_ui.drawer_show)
      -- Return focus to editor
      vim.api.nvim_set_current_win(editor_win)
    end
  end
end

---Focus a named pane window.
---@param name string pane name: "editor", "result", "drawer", "call_log"
---@return boolean success
function layouts.Minimal:focus_pane(name)
  if name == "call_log" then
    return false
  end
  if name == "drawer" then
    if not self.drawer_win or not vim.api.nvim_win_is_valid(self.drawer_win) then
      return false
    end
    vim.api.nvim_set_current_win(self.drawer_win)
    return true
  end
  local winid = self.windows[name]
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return false
  end
  vim.api.nvim_set_current_win(winid)
  return true
end

---Ensure drawer is visible. Opens drawer if not visible.
---@return boolean
function layouts.Minimal:ensure_drawer_visible()
  if not self.drawer_win or not vim.api.nvim_win_is_valid(self.drawer_win) then
    self:toggle_drawer()
  end
  return self.drawer_win ~= nil and vim.api.nvim_win_is_valid(self.drawer_win)
end

return layouts
