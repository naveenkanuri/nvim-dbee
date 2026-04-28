local H = {}

local NodeMethods = {}

function NodeMethods:get_id()
  return self.id
end

function NodeMethods:get_parent_id()
  return rawget(self, "_parent_id")
end

function NodeMethods:expand()
  local changed = not self._expanded
  self._expanded = true
  return changed
end

function NodeMethods:collapse()
  local changed = self._expanded == true
  self._expanded = false
  return changed
end

function NodeMethods:is_expanded()
  return self._expanded == true
end

function NodeMethods:has_children()
  return #(self._children or {}) > 0
end

function NodeMethods:get_depth()
  local depth = 1
  local parent_id = self._parent_id
  while parent_id do
    depth = depth + 1
    local parent = self._tree and self._tree.index[parent_id] or nil
    parent_id = parent and parent._parent_id or nil
  end
  return depth
end

local function new_node(fields, children)
  fields = fields or {}
  fields._children = children or {}
  fields.__children = fields._children
  fields._expanded = fields._expanded or false
  return setmetatable(fields, { __index = NodeMethods })
end

local FakeTree = {}
FakeTree.__index = FakeTree

local function attach_children(tree, parent_id, children)
  for _, child in ipairs(children or {}) do
    child._parent_id = parent_id
    child._tree = tree
    child._children = child._children or child.__children or {}
    child.__children = child._children
    attach_children(tree, child.id, child._children)
  end
end

function FakeTree:reindex()
  self.index = {}

  local function walk(nodes, parent_id)
    for _, node in ipairs(nodes or {}) do
      node._parent_id = parent_id
      node._tree = self
      node._children = node._children or node.__children or {}
      node.__children = node._children
      self.index[node.id] = node
      walk(node._children, node.id)
    end
  end

  walk(self.root_nodes, nil)
end

function FakeTree:set_nodes(nodes, parent_id)
  nodes = nodes or {}
  if parent_id then
    local parent = self.index[parent_id]
    if not parent then
      return
    end
    parent._children = nodes
    parent.__children = nodes
    attach_children(self, parent_id, nodes)
  else
    self.root_nodes = nodes
    attach_children(self, nil, nodes)
  end
  self:reindex()
end

function FakeTree:add_node(node, parent_id)
  local parent = self.index[parent_id]
  if not parent then
    return
  end
  parent._children = parent._children or {}
  parent.__children = parent._children
  table.insert(parent._children, node)
  attach_children(self, parent_id, { node })
  self:reindex()
end

function FakeTree:remove_node(node_id)
  local node = self.index[node_id]
  if not node then
    return
  end

  local siblings
  if node._parent_id then
    local parent = self.index[node._parent_id]
    siblings = parent and parent._children or {}
  else
    siblings = self.root_nodes
  end

  for index, child in ipairs(siblings) do
    if child.id == node_id then
      table.remove(siblings, index)
      break
    end
  end

  self:reindex()
end

function FakeTree:get_nodes(parent_id)
  if not parent_id then
    return self.root_nodes
  end
  local parent = self.index[parent_id]
  if not parent then
    return {}
  end
  return parent._children or {}
end

function FakeTree:get_node(id)
  if id ~= nil then
    return self.index[id]
  end

  local winid = vim.fn.bufwinid(self.bufnr)
  if winid < 0 or not vim.api.nvim_win_is_valid(winid) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(winid)[1]
  return self.visible_nodes[row]
end

function FakeTree:render()
  local visible = {}
  local lines = {}

  local function walk(nodes)
    for _, node in ipairs(nodes or {}) do
      visible[#visible + 1] = node
      lines[#lines + 1] = node.name or ""
      if node:is_expanded() then
        walk(node._children)
      end
    end
  end

  walk(self.root_nodes)
  self.visible_nodes = visible
  if #lines == 0 then
    lines = { "" }
  end
  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)

  local winid = vim.fn.bufwinid(self.bufnr)
  if winid > 0 and vim.api.nvim_win_is_valid(winid) then
    local row, col = unpack(vim.api.nvim_win_get_cursor(winid))
    local max_row = math.max(#visible, 1)
    if row > max_row then
      pcall(vim.api.nvim_win_set_cursor, winid, { max_row, col })
    end
  end
end

local FakeNuiTree = setmetatable({
  Node = new_node,
}, {
  __call = function(_, opts)
    return setmetatable({
      bufnr = opts.bufnr,
      prepare_node = opts.prepare_node,
      get_node_id = opts.get_node_id,
      root_nodes = {},
      index = {},
      visible_nodes = {},
    }, FakeTree)
  end,
})

function H.reset_modules(modules)
  for _, module_name in ipairs(modules or {}) do
    package.loaded[module_name] = nil
  end
end

function H.install_ui_stubs(runtime, opts)
  opts = opts or {}

  package.loaded["nui.tree"] = FakeNuiTree
  package.loaded["nui.line"] = function()
    return {
      append = function() end,
    }
  end

  package.loaded["dbee.ui.common"] = {
    create_blank_buffer = function(name)
      local bufnr = vim.api.nvim_create_buf(false, true)
      if name and name ~= "" then
        pcall(vim.api.nvim_buf_set_name, bufnr, name)
      end
      return bufnr
    end,
    configure_buffer_mappings = function() end,
    configure_window_options = function(winid, window_options)
      for key, value in pairs(window_options or {}) do
        pcall(vim.api.nvim_set_option_value, key, value, { win = winid })
      end
    end,
    float_prompt = function(items, prompt_opts)
      runtime.prompt_calls[#runtime.prompt_calls + 1] = {
        items = vim.deepcopy(items or {}),
        opts = prompt_opts,
      }
      if runtime.next_prompt_response and prompt_opts and prompt_opts.callback then
        local response = vim.deepcopy(runtime.next_prompt_response)
        runtime.next_prompt_response = nil
        prompt_opts.callback(response)
      end
    end,
    float_editor = function(path, editor_opts)
      runtime.editor_calls[#runtime.editor_calls + 1] = {
        path = path,
        opts = editor_opts,
      }
      if editor_opts and editor_opts.callback then
        editor_opts.callback()
      end
    end,
  }
  package.loaded["dbee.ui.common.floats"] = {}

  package.loaded["dbee.ui.drawer.menu"] = {
    select = function(select_opts)
      runtime.select_calls[#runtime.select_calls + 1] = select_opts
      if runtime.next_select_choice ~= nil and select_opts.on_confirm then
        local choice = runtime.next_select_choice
        runtime.next_select_choice = nil
        select_opts.on_confirm(choice)
      end
      return select_opts
    end,
    input = function(input_opts)
      runtime.input_calls[#runtime.input_calls + 1] = input_opts
      if runtime.next_input_value ~= nil and input_opts.on_confirm then
        local value = runtime.next_input_value
        runtime.next_input_value = nil
        input_opts.on_confirm(value)
      end
      return input_opts
    end,
    filter = function(filter_opts)
      local session = {
        opts = filter_opts,
        value = "",
        closed = false,
      }

      function session:change(value)
        self.value = value
        if self.opts.on_change then
          self.opts.on_change(value)
        end
      end

      function session:submit(value)
        self.value = value or self.value
        if self.opts.on_submit then
          self.opts.on_submit(self.value)
        end
      end

      function session:close()
        if self.closed then
          return
        end
        self.closed = true
        if self.opts.on_close then
          self.opts.on_close()
        end
      end

      runtime.filter_sessions[#runtime.filter_sessions + 1] = session
      return session
    end,
  }

  if opts.stub_reconnect ~= false then
    runtime.reconnect_listeners = {}
    package.loaded["dbee.reconnect"] = {
      register_connection_rewritten_listener = function(key, listener)
        runtime.reconnect_listeners[key] = listener
      end,
      emit_rewrite = function(old_conn_id, new_conn_id)
        for _, listener in pairs(runtime.reconnect_listeners) do
          listener(old_conn_id, new_conn_id)
        end
      end,
    }
  end
end

function H.with_window(width, height)
  local host_buf = vim.api.nvim_create_buf(false, true)
  local winid = vim.api.nvim_open_win(host_buf, true, {
    relative = "editor",
    width = width or 120,
    height = height or 40,
    row = 1,
    col = 1,
    style = "minimal",
    border = "single",
  })
  return host_buf, winid
end

function H.close_window_and_buffer(bufnr, winid)
  if winid and vim.api.nvim_win_is_valid(winid) then
    pcall(vim.api.nvim_win_close, winid, true)
  end
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

function H.visible_node_ids(tree)
  local ids = {}
  for _, node in ipairs(tree.visible_nodes or {}) do
    ids[#ids + 1] = node:get_id()
  end
  return ids
end

function H.visible_node_names(tree)
  local names = {}
  for _, node in ipairs(tree.visible_nodes or {}) do
    names[#names + 1] = node.name
  end
  return names
end

function H.visible_row(tree, target_id)
  for index, node in ipairs(tree.visible_nodes or {}) do
    if node:get_id() == target_id then
      return index
    end
  end
end

function H.set_current_node(winid, tree, node_id)
  local row = H.visible_row(tree, node_id)
  if row == nil then
    error("missing visible node: " .. tostring(node_id))
  end
  vim.api.nvim_win_set_cursor(winid, { row, 0 })
end

function H.drain(ms)
  vim.wait(ms or 30, function()
    return false
  end, 1)
end

return H
