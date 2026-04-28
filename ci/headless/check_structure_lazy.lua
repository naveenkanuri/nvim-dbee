-- Headless validation for Phase 6 STRUCT-01.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=$(pwd)" \
--   -c "luafile ci/headless/check_structure_lazy.lua"

local function fail(msg)
  print("STRUCT01_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local function assert_true(label, value)
  if not value then
    fail(label .. ": expected truthy, got " .. tostring(value))
  end
end

local function assert_eq(label, actual, expected)
  if actual ~= expected then
    fail(label .. ": expected " .. vim.inspect(expected) .. " got " .. vim.inspect(actual))
  end
end

local function assert_match(label, actual, pattern)
  if tostring(actual):match(pattern) == nil then
    fail(label .. ": expected " .. vim.inspect(actual) .. " to match " .. pattern)
  end
end

local function assert_not_nil(label, value)
  if value == nil then
    fail(label .. ": expected non-nil value")
  end
end

local function visible_node_ids(tree)
  local ids = {}
  for _, node in ipairs(tree.visible_nodes or {}) do
    ids[#ids + 1] = node:get_id()
  end
  return ids
end

local function visible_node_names(tree)
  local names = {}
  for _, node in ipairs(tree.visible_nodes or {}) do
    names[#names + 1] = node.name
  end
  return names
end

local function with_window(width, height)
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

local function close_window_and_buffer(bufnr, winid)
  if winid and vim.api.nvim_win_is_valid(winid) then
    pcall(vim.api.nvim_win_close, winid, true)
  end
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

local saved_notify = vim.notify
local notifications = {}
vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = {
    msg = tostring(msg),
    level = level,
    opts = opts,
  }
end

local function clear_notifications()
  notifications = {}
end

local function last_notification()
  return notifications[#notifications] or {}
end

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
  self.op_log[#self.op_log + 1] = {
    op = "set_nodes",
    parent_id = parent_id,
    size = #nodes,
  }
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
  self.op_log[#self.op_log + 1] = {
    op = "add_node",
    parent_id = parent_id,
    node_id = node.id,
  }
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
  self.op_log[#self.op_log + 1] = {
    op = "remove_node",
    node_id = node_id,
    parent_id = node._parent_id,
  }
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
      op_log = {},
    }, FakeTree)
  end,
})

package.loaded["nui.tree"] = FakeNuiTree
package.loaded["nui.line"] = function()
  return {
    append = function() end,
  }
end

local stub_filter_sessions = {}
package.loaded["dbee.ui.drawer.menu"] = {
  select = function(opts)
    return opts
  end,
  input = function(opts)
    return opts
  end,
  filter = function(opts)
    local session = {
      opts = opts,
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

    stub_filter_sessions[#stub_filter_sessions + 1] = session
    return session
  end,
}

package.loaded["dbee.ui.drawer"] = nil
package.loaded["dbee.ui.drawer.convert"] = nil
package.loaded["dbee.ui.drawer.model"] = nil

local convert = require("dbee.ui.drawer.convert")
local DrawerUI = require("dbee.ui.drawer")

local SOURCE_ID = "__source__source1"
local BIG_COLUMN_COUNT = 3205
local BIG_STRUCT_COUNT = 2205

local BIG_COLUMNS = {}
for index = 1, BIG_COLUMN_COUNT do
  BIG_COLUMNS[#BIG_COLUMNS + 1] = {
    name = string.format("col_%04d", index),
    type = "NUMBER",
  }
end

local BIG_ROOT_STRUCTURES = {}
for index = 1, BIG_STRUCT_COUNT do
  BIG_ROOT_STRUCTURES[#BIG_ROOT_STRUCTURES + 1] = {
    type = "schema",
    name = string.format("schema_%04d", index),
    schema = string.format("schema_%04d", index),
    children = {},
  }
end

local BIG_SCHEMA_CHILDREN = {}
for index = 1, BIG_STRUCT_COUNT do
  BIG_SCHEMA_CHILDREN[#BIG_SCHEMA_CHILDREN + 1] = {
    type = "table",
    name = string.format("wide_table_%04d", index),
    schema = "warehouse",
  }
end

local ROOT_STRUCTURES_WIDE_SCHEMA = {
  {
    type = "schema",
    name = "warehouse",
    schema = "warehouse",
    children = BIG_SCHEMA_CHILDREN,
  },
}

local ROOT_STRUCTURES_READY = {
  {
    type = "schema",
    name = "hr",
    schema = "hr",
    children = {
      { type = "table", name = "big_table", schema = "hr" },
      { type = "table", name = "departments", schema = "hr" },
      { type = "table", name = "employees", schema = "hr" },
      { type = "view", name = "employee_view", schema = "hr" },
    },
  },
}

local ROOT_STRUCTURES_ALT = {
  {
    type = "schema",
    name = "ops",
    schema = "ops",
    children = {
      { type = "table", name = "audit_log", schema = "ops" },
    },
  },
}

local ROOT_STRUCTURES_ANALYTICS = {
  {
    type = "schema",
    name = "analytics",
    schema = "analytics",
    children = {
      { type = "table", name = "events", schema = "analytics" },
    },
  },
}

local COLUMN_DATA = {
  ["conn-ready|hr|employees"] = {
    { name = "employee_id", type = "NUMBER" },
    { name = "employee_name", type = "TEXT" },
  },
  ["conn-ready|hr|employee_view"] = {
    { name = "employee_view_id", type = "NUMBER" },
  },
  ["conn-ready|hr|departments"] = {},
  ["conn-ready|hr|big_table"] = BIG_COLUMNS,
  ["conn-alt|ops|audit_log"] = {
    { name = "log_id", type = "NUMBER" },
  },
}

local function seed_root_cache()
  return {
    ["conn-ready"] = { structures = vim.deepcopy(ROOT_STRUCTURES_READY) },
    ["conn-alt"] = { structures = vim.deepcopy(ROOT_STRUCTURES_ALT) },
  }
end

local function branch_cache_key(branch_id)
  return branch_id .. convert.ID_SEP .. "columns"
end

local function make_ids()
  local conn_id = "conn-ready"
  local hr_schema_id = convert.structure_node_id(conn_id, {
    type = "schema",
    name = "hr",
    schema = "hr",
  })
  local employees_id = convert.structure_node_id(hr_schema_id, {
    type = "table",
    name = "employees",
    schema = "hr",
  })
  local employee_view_id = convert.structure_node_id(hr_schema_id, {
    type = "view",
    name = "employee_view",
    schema = "hr",
  })
  local departments_id = convert.structure_node_id(hr_schema_id, {
    type = "table",
    name = "departments",
    schema = "hr",
  })
  local big_table_id = convert.structure_node_id(hr_schema_id, {
    type = "table",
    name = "big_table",
    schema = "hr",
  })
  return {
    source_id = SOURCE_ID,
    conn_ready = conn_id,
    conn_alt = "conn-alt",
    conn_cold = "conn-cold",
    help_id = "__help_node__",
    global_master_id = "__master_note_global__",
    local_master_id = "__master_note_local__",
    global_note_id = "note-global-1",
    local_note_id = "note-local-1",
    db_switch_id = conn_id .. "_database_switch__",
    hr_schema = hr_schema_id,
    employees = employees_id,
    employee_view = employee_view_id,
    departments = departments_id,
    big_table = big_table_id,
    employee_column = convert.column_node_id(employees_id, {
      name = "employee_id",
      type = "NUMBER",
    }),
    sentinel = convert.load_more_node_id(big_table_id),
  }
end

local function visible_row(tree, target_id)
  for index, node in ipairs(tree.visible_nodes or {}) do
    if node:get_id() == target_id then
      return index
    end
  end
end

local function set_current_node(winid, tree, node_id)
  local row = visible_row(tree, node_id)
  assert_true("set_current_node_" .. tostring(node_id), row ~= nil)
  vim.api.nvim_win_set_cursor(winid, { row, 0 })
end

local function new_fixture(opts)
  opts = opts or {}

  local ids = make_ids()
  local current_connection = opts.current_connection or {
    id = ids.conn_ready,
    name = "Ready Connection",
    type = "postgres",
  }

  local counters = {
    root_async = 0,
    legacy_root_async = 0,
    child_async = 0,
    sync_columns = 0,
    list_databases = {},
    select_database = 0,
    result_set = 0,
  }
  local root_requests = {}
  local child_requests = {}
  local handler_listeners = {}
  local editor_listeners = {}
  local current_db = {
    [ids.conn_ready] = "main",
  }
  local list_database_errors = vim.deepcopy(opts.list_database_errors or {})

  local global_note = {
    id = ids.global_note_id,
    name = "global-note.sql",
    bufnr = vim.api.nvim_create_buf(false, true),
  }
  local local_note = {
    id = ids.local_note_id,
    name = "local-note.sql",
    bufnr = vim.api.nvim_create_buf(false, true),
  }
  local current_note = {
    id = global_note.id,
  }

  local sources = {
    {
      id = "source1",
      name = function()
        return "source1"
      end,
      create = function() end,
      update = function() end,
      delete = function() end,
      file = function()
        return "source1.json"
      end,
    },
  }

  local source_connections = {
    source1 = {
      { id = ids.conn_ready, name = "Ready Connection", type = "postgres" },
      { id = ids.conn_alt, name = "Alt Connection", type = "postgres" },
      { id = ids.conn_cold, name = "Cold Connection", type = "postgres" },
    },
  }

  local handler = {
    register_event_listener = function(_, event, cb)
      handler_listeners[event] = cb
    end,
    get_current_connection = function()
      return current_connection
    end,
    get_sources = function()
      return sources
    end,
    source_get_connections = function(_, source_id)
      return source_connections[source_id] or {}
    end,
    connection_get_structure_async = function(_, conn_id, request_id, root_epoch, caller_token)
      counters.root_async = counters.root_async + 1
      if request_id == nil then
        counters.legacy_root_async = counters.legacy_root_async + 1
      end
      root_requests[#root_requests + 1] = {
        conn_id = conn_id,
        request_id = request_id,
        root_epoch = root_epoch,
        caller_token = caller_token,
      }
    end,
    connection_get_columns_async = function(_, conn_id, request_id, branch_id, root_epoch, table_opts)
      counters.child_async = counters.child_async + 1
      child_requests[#child_requests + 1] = {
        conn_id = conn_id,
        request_id = request_id,
        branch_id = branch_id,
        root_epoch = root_epoch,
        schema = table_opts and table_opts.schema or nil,
        table = table_opts and table_opts.table or nil,
        materialization = table_opts and table_opts.materialization or nil,
        kind = table_opts and table_opts.kind or "columns",
      }
    end,
    connection_get_columns = function(_, conn_id, table_opts)
      counters.sync_columns = counters.sync_columns + 1
      local key = table.concat({
        conn_id,
        table_opts and table_opts.schema or "",
        table_opts and table_opts.table or "",
      }, "|")
      return vim.deepcopy(COLUMN_DATA[key] or {})
    end,
    connection_list_databases = function(_, conn_id)
      counters.list_databases[conn_id] = (counters.list_databases[conn_id] or 0) + 1
      if list_database_errors[conn_id] then
        error(list_database_errors[conn_id])
      end
      if conn_id == ids.conn_ready then
        return current_db[conn_id], { "main", "analytics" }
      end
      return "", {}
    end,
    connection_select_database = function(_, conn_id, database)
      counters.select_database = counters.select_database + 1
      current_db[conn_id] = database
      if handler_listeners.database_selected then
        handler_listeners.database_selected({
          conn_id = conn_id,
          database_name = database,
        })
      end
    end,
    connection_get_helpers = function(_, _, table_opts)
      return {
        ["Browse"] = string.format("select * from %s.%s", table_opts.schema or "", table_opts.table or ""),
      }
    end,
    connection_execute = function(_, _, query)
      counters.result_set = counters.result_set + 1
      return {
        id = "call-" .. tostring(counters.result_set),
        query = query,
      }
    end,
    connection_get_params = function(_, conn_id)
      return {
        id = conn_id,
        name = conn_id,
        type = "postgres",
        url = "postgres://test/" .. conn_id,
      }
    end,
    set_current_connection = function(_, conn_id)
      current_connection = {
        id = conn_id,
        name = conn_id,
        type = "postgres",
      }
      if handler_listeners.current_connection_changed then
        handler_listeners.current_connection_changed({ conn_id = conn_id })
      end
    end,
    source_update_connection = function() end,
    source_remove_connection = function() end,
    source_add_connection = function() end,
    source_reload = function() end,
    call_store_result = function() end,
  }

  local editor = {
    register_event_listener = function(_, event, cb)
      editor_listeners[event] = cb
    end,
    get_current_note = function()
      return current_note
    end,
    namespace_get_notes = function(_, namespace)
      if namespace == "global" then
        return { global_note }
      end
      if namespace == ids.conn_ready then
        return { local_note }
      end
      return {}
    end,
    set_current_note = function(_, note_id)
      current_note = { id = note_id }
    end,
    namespace_create_note = function()
      return "new-note"
    end,
    note_rename = function() end,
    namespace_remove_note = function() end,
    search_note = function()
      return nil
    end,
  }

  local result = {
    set_call = function() end,
  }

  local mappings = {
    { key = "<CR>", mode = "n", action = "action_1" },
    { key = "cw", mode = "n", action = "action_2" },
    { key = "dd", mode = "n", action = "action_3" },
    { key = "o", mode = "n", action = "toggle" },
    { key = "e", mode = "n", action = "expand" },
    { key = "c", mode = "n", action = "collapse" },
    { key = "/", mode = "n", action = "filter" },
    { key = "r", mode = "n", action = "refresh" },
  }

  local drawer = DrawerUI:new(handler, editor, result, {
    mappings = mappings,
  })

  drawer._struct_cache.root = vim.deepcopy(opts.seed_root or {})
  drawer._struct_cache.root_gen = {}
  drawer._struct_cache.root_applied = {}
  drawer._struct_cache.root_epoch = {}
  drawer._struct_cache.loaded_lazy_ids = {}
  drawer._struct_cache.branches = {}

  local real_refresh = drawer.refresh
  drawer.refresh_count = 0
  drawer.refresh = function(self, ...)
    self.refresh_count = self.refresh_count + 1
    return real_refresh(self, ...)
  end

  local host_buf, winid = with_window()
  drawer:show(winid)
  drawer.refresh_count = 0
  stub_filter_sessions = {}

  local fixture = {
    ids = ids,
    drawer = drawer,
    handler = handler,
    editor = editor,
    result = result,
    winid = winid,
    host_buf = host_buf,
    counters = counters,
    root_requests = root_requests,
    child_requests = child_requests,
    handler_listeners = handler_listeners,
    editor_listeners = editor_listeners,
    notes = {
      global = global_note,
      local_note = local_note,
    },
  }

  function fixture:latest_root_request(conn_id)
    for index = #self.root_requests, 1, -1 do
      local request = self.root_requests[index]
      if request.conn_id == conn_id then
        return request
      end
    end
  end

  function fixture:latest_child_request(branch_id)
    for index = #self.child_requests, 1, -1 do
      local request = self.child_requests[index]
      if request.branch_id == branch_id then
        return request
      end
    end
  end

  function fixture:emit_root(request, payload)
    request = request or {}
    payload = payload or {}
    self.drawer:on_structure_loaded(vim.tbl_extend("force", {
      conn_id = request.conn_id or payload.conn_id,
      request_id = request.request_id or payload.request_id,
      root_epoch = request.root_epoch or payload.root_epoch or 0,
      caller_token = request.caller_token or payload.caller_token or "drawer",
      structures = payload.structures,
      error = payload.error,
    }, payload))
  end

  function fixture:emit_child(request, payload)
    request = request or {}
    payload = payload or {}
    self.drawer:on_structure_children_loaded(vim.tbl_extend("force", {
      conn_id = request.conn_id or payload.conn_id,
      request_id = request.request_id or payload.request_id,
      branch_id = request.branch_id or payload.branch_id,
      root_epoch = request.root_epoch or payload.root_epoch or 0,
      kind = request.kind or payload.kind or "columns",
      columns = payload.columns,
      error = payload.error,
    }, payload))
  end

  function fixture:branch_state(branch_id, kind, conn_id)
    local key = branch_id .. convert.ID_SEP .. (kind or "columns")
    local owner = conn_id or self.ids.conn_ready
    return self.drawer._struct_cache.branches[owner] and self.drawer._struct_cache.branches[owner][key] or nil
  end

  function fixture:cleanup()
    close_window_and_buffer(host_buf, winid)
    if drawer.bufnr and vim.api.nvim_buf_is_valid(drawer.bufnr) then
      pcall(vim.api.nvim_buf_delete, drawer.bufnr, { force = true })
    end
    pcall(vim.api.nvim_buf_delete, global_note.bufnr, { force = true })
    pcall(vim.api.nvim_buf_delete, local_note.bufnr, { force = true })
  end

  return fixture
end

local function expand_source(fixture)
  if fixture.drawer.tree:get_node(fixture.ids.source_id) then
    set_current_node(fixture.winid, fixture.drawer.tree, fixture.ids.source_id)
    fixture.drawer:get_actions().expand()
  end
end

local function ensure_ready_root_visible(fixture)
  expand_source(fixture)
  set_current_node(fixture.winid, fixture.drawer.tree, fixture.ids.conn_ready)
  fixture.drawer:get_actions().expand()
  local request = fixture:latest_root_request(fixture.ids.conn_ready)
  if request and fixture.drawer._struct_cache.root[fixture.ids.conn_ready] == nil then
    fixture:emit_root(request, {
      structures = vim.deepcopy(ROOT_STRUCTURES_READY),
    })
  end
end

local function expand_hr_schema(fixture)
  ensure_ready_root_visible(fixture)
  set_current_node(fixture.winid, fixture.drawer.tree, fixture.ids.hr_schema)
  fixture.drawer:get_actions().expand()
end

local function warm_branch(fixture, branch_id, columns)
  expand_hr_schema(fixture)
  set_current_node(fixture.winid, fixture.drawer.tree, branch_id)
  fixture.drawer:get_actions().expand()
  local request = fixture:latest_child_request(branch_id)
  assert_not_nil("warm_branch_request_" .. branch_id, request)
  fixture:emit_child(request, {
    columns = vim.deepcopy(columns),
  })
  return request
end

local function node_names(nodes)
  local names = {}
  for _, node in ipairs(nodes or {}) do
    names[#names + 1] = node.name
  end
  return names
end

local function count_matching(ids)
  local seen = {}
  for _, id in ipairs(ids) do
    seen[id] = (seen[id] or 0) + 1
  end
  return seen
end

do
  local fixture = new_fixture()
  expand_source(fixture)
  set_current_node(fixture.winid, fixture.drawer.tree, fixture.ids.conn_ready)
  fixture.drawer:get_actions().expand()
  local request = fixture:latest_root_request(fixture.ids.conn_ready)
  assert_not_nil("root_lazy_request", request)
  assert_eq("root_lazy_request_count", fixture.counters.root_async, 1)
  assert_eq("root_lazy_loading_row", fixture.drawer.tree:get_nodes(fixture.ids.conn_ready)[1].name, "loading...")
  assert_eq("root_lazy_request_epoch", request.root_epoch, 0)
  assert_eq("root_lazy_request_token", request.caller_token, "drawer")
  fixture.drawer:get_actions().collapse()
  fixture.drawer:get_actions().expand()
  assert_eq("root_lazy_request_dedupe", fixture.counters.root_async, 1)
  print("STRUCT01_ROOT_LAZY_OK=true")
  fixture:cleanup()
end

do
  local fixture = new_fixture({
    seed_root = seed_root_cache(),
  })
  expand_hr_schema(fixture)
  local schema_children = node_names(fixture.drawer.tree:get_nodes(fixture.ids.hr_schema))
  assert_eq("next_level_child_count", #schema_children, 4)
  assert_true("next_level_no_column", fixture.drawer.tree:get_node(fixture.ids.employee_column) == nil)
  assert_eq("next_level_zero_root_rpc", fixture.counters.root_async, 0)
  assert_eq("next_level_zero_child_rpc", fixture.counters.child_async, 0)

  set_current_node(fixture.winid, fixture.drawer.tree, fixture.ids.employees)
  fixture.drawer:get_actions().expand()
  local table_request = fixture:latest_child_request(fixture.ids.employees)
  assert_not_nil("child_async_table_request", table_request)
  assert_eq("child_async_table_materialization", table_request.materialization, "table")
  assert_eq("child_async_sync_columns_table", fixture.counters.sync_columns, 0)
  assert_eq("child_async_loading_row_table", fixture.drawer.tree:get_nodes(fixture.ids.employees)[1].name, "loading...")
  fixture.drawer:get_actions().collapse()
  fixture.drawer:get_actions().expand()
  assert_eq("child_async_table_dedupe", fixture.counters.child_async, 1)

  set_current_node(fixture.winid, fixture.drawer.tree, fixture.ids.employee_view)
  fixture.drawer:get_actions().expand()
  local view_request = fixture:latest_child_request(fixture.ids.employee_view)
  assert_not_nil("child_async_view_request", view_request)
  assert_eq("child_async_view_materialization", view_request.materialization, "view")
  assert_eq("child_async_sync_columns_view", fixture.counters.sync_columns, 0)
  assert_eq("child_async_branch_id_encoded", table_request.branch_id, fixture.ids.employees)
  print("STRUCT01_CHILD_ASYNC_OK=true")
  print("STRUCT01_BRANCH_DEDUPE_OK=true")
  fixture:cleanup()
end

do
  local fixture = new_fixture({
    seed_root = seed_root_cache(),
  })
  expand_hr_schema(fixture)
  set_current_node(fixture.winid, fixture.drawer.tree, fixture.ids.employees)
  fixture.drawer:get_actions().expand()
  local request = fixture:latest_child_request(fixture.ids.employees)
  local state = fixture:branch_state(fixture.ids.employees)
  assert_not_nil("stale_guard_branch_state", state)
  state.request_gen = request.request_id + 1
  state.loading = true
  fixture:emit_child(request, {
    columns = vim.deepcopy(COLUMN_DATA["conn-ready|hr|employees"]),
  })
  assert_true("stale_guard_branch_ignored", state.raw == nil and state.applied_gen == 0)
  fixture:emit_child({
    conn_id = request.conn_id,
    request_id = request.request_id + 1,
    branch_id = request.branch_id,
    root_epoch = request.root_epoch,
    kind = request.kind,
  }, {
    columns = vim.deepcopy(COLUMN_DATA["conn-ready|hr|employees"]),
  })
  assert_eq("stale_guard_branch_applied", #state.raw, 2)

  local root_fixture = new_fixture()
  expand_source(root_fixture)
  set_current_node(root_fixture.winid, root_fixture.drawer.tree, root_fixture.ids.conn_ready)
  root_fixture.drawer:get_actions().expand()
  local root_request = root_fixture:latest_root_request(root_fixture.ids.conn_ready)
  assert_not_nil("stale_guard_root_request", root_request)
  root_fixture:emit_root({
    conn_id = root_request.conn_id,
    request_id = root_request.request_id,
    root_epoch = root_request.root_epoch,
    caller_token = "lsp",
  }, {
    structures = vim.deepcopy(ROOT_STRUCTURES_ALT),
  })
  assert_true("stale_guard_foreign_root_ignored", root_fixture.drawer._struct_cache.root[root_fixture.ids.conn_ready] == nil)

  root_fixture.handler:connection_get_structure_async(root_fixture.ids.conn_ready)
  assert_eq("fulltree_contract_legacy_call_count", root_fixture.counters.legacy_root_async, 1)
  root_fixture.drawer:on_structure_loaded({
    conn_id = root_fixture.ids.conn_ready,
    structures = vim.deepcopy(ROOT_STRUCTURES_ALT),
  })
  assert_true("fulltree_contract_legacy_payload_ignored", root_fixture.drawer._struct_cache.root[root_fixture.ids.conn_ready] == nil)

  root_fixture:emit_root(root_request, {
    structures = vim.deepcopy(ROOT_STRUCTURES_READY),
  })
  assert_not_nil("stale_guard_winning_root_applies", root_fixture.drawer._struct_cache.root[root_fixture.ids.conn_ready])
  print("STRUCT01_STALE_GUARD_OK=true")
  print("STRUCT01_FULLTREE_CONTRACT_OK=true")
  fixture:cleanup()
  root_fixture:cleanup()
end

do
  local fixture = new_fixture({
    seed_root = seed_root_cache(),
  })
  local initial_request = warm_branch(fixture, fixture.ids.employees, COLUMN_DATA["conn-ready|hr|employees"])
  local initial_child_async = fixture.counters.child_async
  set_current_node(fixture.winid, fixture.drawer.tree, fixture.ids.employees)
  fixture.drawer:get_actions().refresh()
  local reload_request = fixture:latest_root_request(fixture.ids.conn_ready)
  assert_not_nil("manual_reload_request", reload_request)
  assert_eq("manual_reload_epoch_bumped", fixture.drawer._struct_cache.root_epoch[fixture.ids.conn_ready], 1)
  assert_true("manual_reload_root_cleared", fixture.drawer._struct_cache.root[fixture.ids.conn_ready] == nil)
  assert_true("manual_reload_branches_cleared", fixture.drawer._struct_cache.branches[fixture.ids.conn_ready] == nil)
  assert_true("manual_reload_lazy_ids_pruned", fixture.drawer._struct_cache.loaded_lazy_ids[fixture.ids.employees] == nil)
  assert_eq("manual_reload_zero_replay_child_rpc", fixture.counters.child_async, initial_child_async)
  fixture:emit_child({
    conn_id = initial_request.conn_id,
    request_id = initial_request.request_id,
    branch_id = initial_request.branch_id,
    root_epoch = initial_request.root_epoch,
    kind = initial_request.kind,
  }, {
    columns = vim.deepcopy(COLUMN_DATA["conn-ready|hr|employees"]),
  })
  assert_true("manual_reload_stale_child_dropped", fixture.drawer._struct_cache.branches[fixture.ids.conn_ready] == nil)
  fixture:emit_root(reload_request, {
    structures = vim.deepcopy(ROOT_STRUCTURES_READY),
  })
  assert_eq("manual_reload_epoch_not_bumped_twice", fixture.drawer._struct_cache.root_epoch[fixture.ids.conn_ready], 1)

  local db_fixture = new_fixture({
    seed_root = seed_root_cache(),
  })
  local db_child_request = warm_branch(db_fixture, db_fixture.ids.employees, COLUMN_DATA["conn-ready|hr|employees"])
  local sibling_calls_before = db_fixture.counters.list_databases[db_fixture.ids.conn_alt] or 0
  db_fixture.handler:connection_select_database(db_fixture.ids.conn_ready, "analytics")
  local db_request = db_fixture:latest_root_request(db_fixture.ids.conn_ready)
  assert_not_nil("database_selected_request", db_request)
  assert_eq("database_selected_epoch_bumped", db_fixture.drawer._struct_cache.root_epoch[db_fixture.ids.conn_ready], 1)
  db_fixture:emit_child(db_child_request, {
    columns = vim.deepcopy(COLUMN_DATA["conn-ready|hr|employees"]),
  })
  assert_true("database_selected_stale_child_dropped", db_fixture.drawer._struct_cache.branches[db_fixture.ids.conn_ready] == nil)
  assert_eq("database_selected_no_sibling_db_list", db_fixture.counters.list_databases[db_fixture.ids.conn_alt] or 0, sibling_calls_before)
  db_fixture:emit_root(db_request, {
    structures = vim.deepcopy(ROOT_STRUCTURES_ANALYTICS),
  })
  assert_eq("database_selected_epoch_not_bumped_twice", db_fixture.drawer._struct_cache.root_epoch[db_fixture.ids.conn_ready], 1)

  local fulltree_fixture = new_fixture()
  expand_source(fulltree_fixture)
  set_current_node(fulltree_fixture.winid, fulltree_fixture.drawer.tree, fulltree_fixture.ids.conn_ready)
  fulltree_fixture.drawer:get_actions().expand()
  local cold_request = fulltree_fixture:latest_root_request(fulltree_fixture.ids.conn_ready)
  set_current_node(fulltree_fixture.winid, fulltree_fixture.drawer.tree, fulltree_fixture.ids.conn_ready)
  fulltree_fixture.drawer:get_actions().refresh()
  local refreshed_request = fulltree_fixture:latest_root_request(fulltree_fixture.ids.conn_ready)
  assert_true("fulltree_epoch_new_request", refreshed_request.request_id ~= cold_request.request_id)
  fulltree_fixture:emit_root(cold_request, {
    structures = vim.deepcopy(ROOT_STRUCTURES_ALT),
  })
  assert_true("fulltree_epoch_stale_root_ignored", fulltree_fixture.drawer._struct_cache.root[fulltree_fixture.ids.conn_ready] == nil)
  fulltree_fixture:emit_root(refreshed_request, {
    structures = vim.deepcopy(ROOT_STRUCTURES_READY),
  })
  assert_eq("fulltree_epoch_single_bump", fulltree_fixture.drawer._struct_cache.root_epoch[fulltree_fixture.ids.conn_ready], 1)

  print("STRUCT01_ROOT_EPOCH_OK=true")
  print("STRUCT01_FULLTREE_EPOCH_OK=true")
  print("STRUCT01_MANUAL_RELOAD_OK=true")
  print("STRUCT01_RELOAD_ZERO_REPLAY_OK=true")
  fixture:cleanup()
  db_fixture:cleanup()
  fulltree_fixture:cleanup()
end

do
  local conn_fixture = new_fixture({
    seed_root = seed_root_cache(),
  })
  expand_source(conn_fixture)
  set_current_node(conn_fixture.winid, conn_fixture.drawer.tree, conn_fixture.ids.conn_ready)
  conn_fixture.drawer:get_actions().refresh()
  assert_not_nil("manual_target_connection", conn_fixture:latest_root_request(conn_fixture.ids.conn_ready))
  conn_fixture:cleanup()

  local descendant_fixture = new_fixture({
    seed_root = seed_root_cache(),
  })
  expand_hr_schema(descendant_fixture)
  set_current_node(descendant_fixture.winid, descendant_fixture.drawer.tree, descendant_fixture.ids.hr_schema)
  descendant_fixture.drawer:get_actions().refresh()
  assert_not_nil("manual_target_descendant", descendant_fixture:latest_root_request(descendant_fixture.ids.conn_ready))
  descendant_fixture:cleanup()

  local db_switch_fixture = new_fixture({
    seed_root = seed_root_cache(),
  })
  ensure_ready_root_visible(db_switch_fixture)
  set_current_node(db_switch_fixture.winid, db_switch_fixture.drawer.tree, db_switch_fixture.ids.db_switch_id)
  db_switch_fixture.drawer:get_actions().refresh()
  assert_not_nil("manual_target_db_switch", db_switch_fixture:latest_root_request(db_switch_fixture.ids.conn_ready))
  db_switch_fixture:cleanup()

  local warn_fixture = new_fixture({
    seed_root = seed_root_cache(),
  })
  expand_source(warn_fixture)
  clear_notifications()
  if warn_fixture.drawer.tree:get_node(warn_fixture.ids.source_id) then
    set_current_node(warn_fixture.winid, warn_fixture.drawer.tree, warn_fixture.ids.source_id)
    warn_fixture.drawer:get_actions().refresh()
    assert_match("manual_target_source_warn", last_notification().msg, "select a connection row to reload")
    assert_true("manual_target_source_no_request", warn_fixture:latest_root_request(warn_fixture.ids.conn_ready) == nil)
  end

  set_current_node(warn_fixture.winid, warn_fixture.drawer.tree, warn_fixture.ids.help_id)
  warn_fixture.drawer:get_actions().refresh()
  assert_match("manual_target_help_warn", last_notification().msg, "select a connection row to reload")

  if warn_fixture.drawer.tree:get_node(warn_fixture.ids.local_master_id)
    and warn_fixture.drawer.tree:get_node(warn_fixture.ids.local_note_id)
  then
    set_current_node(warn_fixture.winid, warn_fixture.drawer.tree, warn_fixture.ids.local_master_id)
    warn_fixture.drawer:get_actions().expand()
    set_current_node(warn_fixture.winid, warn_fixture.drawer.tree, warn_fixture.ids.local_note_id)
    warn_fixture.drawer:get_actions().refresh()
    assert_match("manual_target_note_warn", last_notification().msg, "select a connection row to reload")
  end
  warn_fixture:cleanup()

  print("STRUCT01_MANUAL_R_TARGET_OK=true")
end

do
  local branch_error_fixture = new_fixture({
    seed_root = seed_root_cache(),
  })
  expand_hr_schema(branch_error_fixture)
  set_current_node(branch_error_fixture.winid, branch_error_fixture.drawer.tree, branch_error_fixture.ids.employee_view)
  branch_error_fixture.drawer:get_actions().expand()
  local branch_request = branch_error_fixture:latest_child_request(branch_error_fixture.ids.employee_view)
  branch_error_fixture.drawer.cached_render_snapshot = { { id = "snapshot" } }
  branch_error_fixture:emit_child(branch_request, {
    error = "branch failed",
  })
  local branch_state = branch_error_fixture:branch_state(branch_error_fixture.ids.employee_view)
  assert_eq("branch_error_cached", branch_state.error, "branch failed")
  assert_eq("branch_error_snapshot_invalidated", branch_error_fixture.drawer.cached_render_snapshot, nil)
  assert_eq("branch_error_tree_row", branch_error_fixture.drawer.tree:get_nodes(branch_error_fixture.ids.employee_view)[1].name, "branch failed")

  local root_error_fixture = new_fixture()
  root_error_fixture.handler.connection_list_databases = function(_, conn_id)
    root_error_fixture.counters.list_databases[conn_id] = (root_error_fixture.counters.list_databases[conn_id] or 0) + 1
    error("db listing failed")
  end
  expand_source(root_error_fixture)
  set_current_node(root_error_fixture.winid, root_error_fixture.drawer.tree, root_error_fixture.ids.conn_ready)
  root_error_fixture.drawer:get_actions().expand()
  local root_request = root_error_fixture:latest_root_request(root_error_fixture.ids.conn_ready)
  root_error_fixture:emit_root(root_request, {
    error = "root failed",
  })
  assert_eq("root_error_cached", root_error_fixture.drawer._struct_cache.root[root_error_fixture.ids.conn_ready].error, "root failed")
  local before_root_async = root_error_fixture.counters.root_async
  local before_child_async = root_error_fixture.counters.child_async
  root_error_fixture.drawer:refresh()
  root_error_fixture.drawer:show(root_error_fixture.winid)
  root_error_fixture.editor_listeners.current_note_changed({ note_id = "note-2" })
  vim.api.nvim_set_option_value("modified", true, { buf = root_error_fixture.notes.local_note.bufnr })
  vim.api.nvim_exec_autocmds("BufModifiedSet", { buffer = root_error_fixture.notes.local_note.bufnr })
  root_error_fixture.drawer:refresh()
  assert_eq("root_error_refresh_survives", root_error_fixture.drawer._struct_cache.root[root_error_fixture.ids.conn_ready].error, "root failed")
  assert_eq("root_error_row_visible", root_error_fixture.drawer.tree:get_nodes(root_error_fixture.ids.conn_ready)[1].name, "root failed")
  assert_eq("root_error_skips_db_listing", root_error_fixture.counters.list_databases[root_error_fixture.ids.conn_ready] or 0, 0)
  assert_eq("root_error_no_root_rpc_replay", root_error_fixture.counters.root_async, before_root_async)
  assert_eq("root_error_no_child_rpc_replay", root_error_fixture.counters.child_async, before_child_async)

  local best_effort_fixture = new_fixture({
    seed_root = seed_root_cache(),
    list_database_errors = {
      ["conn-ready"] = "db listing failed",
    },
  })
  expand_source(best_effort_fixture)
  set_current_node(best_effort_fixture.winid, best_effort_fixture.drawer.tree, best_effort_fixture.ids.conn_ready)
  best_effort_fixture.drawer:get_actions().expand()
  assert_true("best_effort_root_visible", best_effort_fixture.drawer.tree:get_node(best_effort_fixture.ids.hr_schema) ~= nil)
  local db_switch_error_node = best_effort_fixture.drawer.tree:get_node(best_effort_fixture.ids.db_switch_id)
  assert_true("best_effort_db_switch_row_present", db_switch_error_node ~= nil)
  assert_match("best_effort_db_switch_row_error", db_switch_error_node.name, "database switch unavailable")
  assert_eq("best_effort_db_list_attempted_once", best_effort_fixture.counters.list_databases[best_effort_fixture.ids.conn_ready], 1)

  print("STRUCT01_ERROR_CACHE_OK=true")
  branch_error_fixture:cleanup()
  root_error_fixture:cleanup()
  best_effort_fixture:cleanup()
end

do
  local fixture = new_fixture({
    seed_root = seed_root_cache(),
  })
  local request = warm_branch(fixture, fixture.ids.employees, COLUMN_DATA["conn-ready|hr|employees"])
  local _ = request
  local before_root_async = fixture.counters.root_async
  local before_child_async = fixture.counters.child_async
  fixture.drawer:refresh()
  fixture.drawer:show(fixture.winid)
  fixture.editor_listeners.current_note_changed({ note_id = "note-2" })
  vim.api.nvim_set_option_value("modified", true, { buf = fixture.notes.local_note.bufnr })
  vim.api.nvim_exec_autocmds("BufModifiedSet", { buffer = fixture.notes.local_note.bufnr })
  fixture.drawer:refresh()
  assert_true("presentation_branch_state_kept", fixture:branch_state(fixture.ids.employees).raw ~= nil)
  assert_true("presentation_column_visible", fixture.drawer.tree:get_node(fixture.ids.employee_column) ~= nil)
  assert_eq("presentation_root_rpc_static", fixture.counters.root_async, before_root_async)
  assert_eq("presentation_child_rpc_static", fixture.counters.child_async, before_child_async)
  print("STRUCT01_PRESENTATION_REFRESH_OK=true")
  fixture:cleanup()
end

do
  local fixture = new_fixture({
    seed_root = seed_root_cache(),
  })
  expand_hr_schema(fixture)
  set_current_node(fixture.winid, fixture.drawer.tree, fixture.ids.big_table)
  fixture.drawer:get_actions().expand()
  local request = fixture:latest_child_request(fixture.ids.big_table)
  fixture.drawer.cached_render_snapshot = { { id = "snapshot" } }
  fixture:emit_child(request, {
    columns = vim.deepcopy(BIG_COLUMNS),
  })
  local state = fixture:branch_state(fixture.ids.big_table)
  local children = fixture.drawer.tree:get_nodes(fixture.ids.big_table)
  assert_eq("load_more_initial_built_count", state.built_count, 1000)
  assert_eq("load_more_initial_child_count", #children, 1001)
  assert_eq("load_more_initial_last_name", children[#children].name, "Load more...")
  assert_eq("load_more_initial_snapshot_invalidated", fixture.drawer.cached_render_snapshot, nil)
  assert_eq("load_more_initial_no_refresh", fixture.drawer.refresh_count, 0)
  local op = fixture.drawer.tree.op_log[#fixture.drawer.tree.op_log]
  assert_eq("load_more_initial_patch_parent", op.parent_id, fixture.ids.big_table)

  fixture.drawer:refresh()
  assert_eq("rebuild_from_cache_after_refresh", #fixture.drawer.tree:get_nodes(fixture.ids.big_table), 1001)
  assert_true("rebuild_from_cache_sentinel_present", fixture.drawer.tree:get_node(fixture.ids.sentinel) ~= nil)

  fixture.drawer.tree.op_log = {}
  fixture.drawer.cached_render_snapshot = { { id = "snapshot" } }
  for _ = 1, 3 do
    set_current_node(fixture.winid, fixture.drawer.tree, fixture.ids.sentinel)
    fixture.drawer:get_actions().action_1()
  end
  local final_children = fixture.drawer.tree:get_nodes(fixture.ids.big_table)
  local final_ids = {}
  for _, node in ipairs(final_children) do
    final_ids[#final_ids + 1] = node:get_id()
  end
  local counts = count_matching(final_ids)
  for id, count in pairs(counts) do
    assert_eq("load_more_unique_" .. id, count, 1)
  end
  assert_eq("load_more_final_built_count", state.built_count, BIG_COLUMN_COUNT)
  assert_eq("load_more_final_child_count", #final_children, BIG_COLUMN_COUNT)
  assert_true("load_more_no_sentinel_after_final_chunk", fixture.drawer.tree:get_node(fixture.ids.sentinel) == nil)
  assert_eq("load_more_snapshot_invalidated", fixture.drawer.cached_render_snapshot, nil)
  assert_eq("load_more_no_refresh", fixture.drawer.refresh_count, 1)
  local saw_remove = false
  local saw_add = false
  for _, entry in ipairs(fixture.drawer.tree.op_log) do
    if entry.op == "remove_node" then
      saw_remove = true
      assert_eq("load_more_remove_parent", entry.parent_id, fixture.ids.big_table)
    elseif entry.op == "add_node" then
      saw_add = true
      assert_eq("load_more_add_parent", entry.parent_id, fixture.ids.big_table)
    end
  end
  assert_true("load_more_remove_seen", saw_remove)
  assert_true("load_more_add_seen", saw_add)

  print("STRUCT01_REBUILD_FROM_CACHE_OK=true")
  print("STRUCT01_LOAD_MORE_OK=true")
  print("STRUCT01_LOAD_MORE_BUILD_BOUND_OK=true")
  print("STRUCT01_PARTIAL_MUTATION_OK=true")
  print("STRUCT01_RENDER_SNAPSHOT_INVALIDATION_OK=true")
  print("STRUCT01_REAL_RENDER_PATH_OK=true")
  fixture:cleanup()
end

do
  local root_fixture = new_fixture({
    seed_root = {
      ["conn-ready"] = { structures = vim.deepcopy(BIG_ROOT_STRUCTURES) },
      ["conn-alt"] = { structures = vim.deepcopy(ROOT_STRUCTURES_ALT) },
    },
  })
  expand_source(root_fixture)
  set_current_node(root_fixture.winid, root_fixture.drawer.tree, root_fixture.ids.conn_ready)
  root_fixture.drawer:get_actions().expand()
  local root_state = root_fixture:branch_state(root_fixture.ids.conn_ready, "structures", root_fixture.ids.conn_ready)
  local root_sentinel = convert.load_more_node_id(root_fixture.ids.conn_ready)
  local root_children = root_fixture.drawer.tree:get_nodes(root_fixture.ids.conn_ready)
  assert_not_nil("large_root_branch_state", root_state)
  assert_eq("large_root_initial_built_count", root_state.built_count, 1000)
  assert_eq("large_root_child_count", #root_children, 1002)
  assert_eq("large_root_first_child_type", root_children[1].type, "database_switch")
  assert_eq("large_root_last_name", root_children[#root_children].name, "Load more...")
  assert_not_nil("large_root_sentinel_visible", root_fixture.drawer.tree:get_node(root_sentinel))
  root_fixture.drawer.tree.op_log = {}
  root_fixture.drawer.cached_render_snapshot = { { id = "snapshot" } }
  set_current_node(root_fixture.winid, root_fixture.drawer.tree, root_sentinel)
  root_fixture.drawer:get_actions().action_1()
  root_children = root_fixture.drawer.tree:get_nodes(root_fixture.ids.conn_ready)
  assert_eq("large_root_built_count_after_load_more", root_state.built_count, 2000)
  assert_eq("large_root_child_count_after_load_more", #root_children, 2002)
  assert_eq("large_root_snapshot_invalidated", root_fixture.drawer.cached_render_snapshot, nil)
  assert_eq("large_root_no_refresh", root_fixture.drawer.refresh_count, 0)
  assert_eq("large_root_first_op_remove", root_fixture.drawer.tree.op_log[1].op, "remove_node")
  assert_eq("large_root_first_op_parent", root_fixture.drawer.tree.op_log[1].parent_id, root_fixture.ids.conn_ready)
  assert_eq("large_root_last_op_parent", root_fixture.drawer.tree.op_log[#root_fixture.drawer.tree.op_log].parent_id, root_fixture.ids.conn_ready)
  root_fixture.drawer:refresh()
  assert_eq("large_root_refresh_preserves_chunk", #root_fixture.drawer.tree:get_nodes(root_fixture.ids.conn_ready), 2002)

  local schema_fixture = new_fixture({
    seed_root = {
      ["conn-ready"] = { structures = vim.deepcopy(ROOT_STRUCTURES_WIDE_SCHEMA) },
      ["conn-alt"] = { structures = vim.deepcopy(ROOT_STRUCTURES_ALT) },
    },
  })
  expand_source(schema_fixture)
  set_current_node(schema_fixture.winid, schema_fixture.drawer.tree, schema_fixture.ids.conn_ready)
  schema_fixture.drawer:get_actions().expand()
  local warehouse_schema = convert.structure_node_id(schema_fixture.ids.conn_ready, {
    type = "schema",
    name = "warehouse",
    schema = "warehouse",
  })
  local schema_sentinel = convert.load_more_node_id(warehouse_schema)
  set_current_node(schema_fixture.winid, schema_fixture.drawer.tree, warehouse_schema)
  schema_fixture.drawer:get_actions().expand()
  local schema_state = schema_fixture:branch_state(warehouse_schema, "structures")
  local schema_children = schema_fixture.drawer.tree:get_nodes(warehouse_schema)
  assert_not_nil("large_schema_branch_state", schema_state)
  assert_eq("large_schema_initial_built_count", schema_state.built_count, 1000)
  assert_eq("large_schema_child_count", #schema_children, 1001)
  assert_eq("large_schema_last_name", schema_children[#schema_children].name, "Load more...")
  assert_not_nil("large_schema_sentinel_visible", schema_fixture.drawer.tree:get_node(schema_sentinel))
  schema_fixture.drawer.tree.op_log = {}
  schema_fixture.drawer.cached_render_snapshot = { { id = "snapshot" } }
  set_current_node(schema_fixture.winid, schema_fixture.drawer.tree, schema_sentinel)
  schema_fixture.drawer:get_actions().action_1()
  schema_children = schema_fixture.drawer.tree:get_nodes(warehouse_schema)
  assert_eq("large_schema_built_count_after_load_more", schema_state.built_count, 2000)
  assert_eq("large_schema_child_count_after_load_more", #schema_children, 2001)
  assert_eq("large_schema_snapshot_invalidated", schema_fixture.drawer.cached_render_snapshot, nil)
  assert_eq("large_schema_no_refresh", schema_fixture.drawer.refresh_count, 0)
  assert_eq("large_schema_first_op_remove", schema_fixture.drawer.tree.op_log[1].op, "remove_node")
  assert_eq("large_schema_first_op_parent", schema_fixture.drawer.tree.op_log[1].parent_id, warehouse_schema)
  assert_eq("large_schema_last_op_parent", schema_fixture.drawer.tree.op_log[#schema_fixture.drawer.tree.op_log].parent_id, warehouse_schema)
  schema_fixture.drawer:refresh()
  assert_eq("large_schema_refresh_preserves_chunk", #schema_fixture.drawer.tree:get_nodes(warehouse_schema), 2001)

  print("STRUCT01_LARGE_CACHED_BRANCH_BOUND_OK=true")
  root_fixture:cleanup()
  schema_fixture:cleanup()
end

do
  local fixture = new_fixture()
  expand_source(fixture)
  set_current_node(fixture.winid, fixture.drawer.tree, fixture.ids.conn_ready)
  fixture.drawer:get_actions().expand()
  local before_alt_calls = fixture.counters.list_databases[fixture.ids.conn_alt] or 0
  local request = fixture:latest_root_request(fixture.ids.conn_ready)
  assert_not_nil("root_partial_request", request)
  fixture:emit_root(request, {
    structures = vim.deepcopy(ROOT_STRUCTURES_READY),
  })
  assert_eq("root_partial_no_global_refresh", fixture.drawer.refresh_count, 0)
  assert_eq("root_partial_no_sibling_db_list", fixture.counters.list_databases[fixture.ids.conn_alt] or 0, before_alt_calls)
  assert_true("root_partial_target_tree_patch", fixture.drawer.tree:get_node(fixture.ids.hr_schema) ~= nil)
  print("STRUCT01_ROOT_PARTIAL_MUTATION_OK=true")
  fixture:cleanup()
end

do
  local fixture = new_fixture()
  local manifest = table.concat(vim.fn.readfile("lua/dbee/api/__register.lua"), "\n")
  assert_match("child_event_manifest", manifest, "DbeeConnectionGetColumnsAsync")
  assert_true("child_event_listener_registered", type(fixture.handler_listeners.structure_children_loaded) == "function")
  print("STRUCT01_CHILD_EVENT_WIRED_OK=true")
  fixture:cleanup()
end

do
  local filter_fixture = new_fixture({
    seed_root = seed_root_cache(),
  })
  local request = warm_branch(filter_fixture, filter_fixture.ids.big_table, BIG_COLUMNS)
  local _ = request
  filter_fixture.drawer:get_actions().filter()
  local session = stub_filter_sessions[#stub_filter_sessions]
  assert_not_nil("filter_session_created", session)
  local baseline_snapshot = vim.deepcopy(filter_fixture.drawer.filter_restore_snapshot)
  local baseline_ids = visible_node_ids(filter_fixture.drawer.tree)
  local search_ref = filter_fixture.drawer.cached_search_model
  local before_root_async = filter_fixture.counters.root_async
  local before_child_async = filter_fixture.counters.child_async
  local before_sync_columns = filter_fixture.counters.sync_columns
  session:change("big")
  assert_eq("filter_zero_rpc_root", filter_fixture.counters.root_async, before_root_async)
  assert_eq("filter_zero_rpc_child", filter_fixture.counters.child_async, before_child_async)
  assert_eq("filter_zero_rpc_sync_columns", filter_fixture.counters.sync_columns, before_sync_columns)
  set_current_node(filter_fixture.winid, filter_fixture.drawer.tree, filter_fixture.ids.big_table)
  session.opts.forward_insert["<Tab>"]()
  local sentinel_before = filter_fixture.drawer.tree:get_node(filter_fixture.ids.sentinel)
  assert_not_nil("filter_sentinel_visible", sentinel_before)
  set_current_node(filter_fixture.winid, filter_fixture.drawer.tree, filter_fixture.ids.sentinel)
  filter_fixture.drawer:get_actions().action_1()
  assert_eq("filter_search_model_preserved_after_load_more", filter_fixture.drawer.cached_search_model, search_ref)
  assert_eq("filter_render_snapshot_invalidated", filter_fixture.drawer.cached_render_snapshot, nil)
  assert_eq("filter_view_frozen_count", #filter_fixture.drawer.tree:get_nodes(filter_fixture.ids.big_table), 1001)
  assert_eq("filter_underlying_built_count_updated", filter_fixture:branch_state(filter_fixture.ids.big_table).built_count, 2000)
  session:close()
  local restored_ids = visible_node_ids(filter_fixture.drawer.tree)
  assert_eq("filter_snapshot_restore_ids", vim.inspect(restored_ids), vim.inspect(baseline_ids))
  assert_eq("filter_snapshot_restore_count", #filter_fixture.drawer.tree:get_nodes(filter_fixture.ids.big_table), 1001)
  filter_fixture.drawer:refresh()
  assert_eq("filter_post_refresh_reveals_deferred_branch", #filter_fixture.drawer.tree:get_nodes(filter_fixture.ids.big_table), 2001)

  local child_filter_fixture = new_fixture({
    seed_root = seed_root_cache(),
  })
  expand_hr_schema(child_filter_fixture)
  child_filter_fixture.drawer:get_actions().filter()
  session = stub_filter_sessions[#stub_filter_sessions]
  session:change("view")
  set_current_node(child_filter_fixture.winid, child_filter_fixture.drawer.tree, child_filter_fixture.ids.employee_view)
  session.opts.forward_insert["<Tab>"]()
  local child_request = child_filter_fixture:latest_child_request(child_filter_fixture.ids.employee_view)
  assert_not_nil("filter_child_request", child_request)
  local loading_names = visible_node_names(child_filter_fixture.drawer.tree)
  child_filter_fixture:emit_child(child_request, {
    columns = vim.deepcopy(COLUMN_DATA["conn-ready|hr|employee_view"]),
  })
  assert_eq("filter_child_view_frozen", vim.inspect(visible_node_names(child_filter_fixture.drawer.tree)), vim.inspect(loading_names))
  assert_true("filter_child_underlying_cache_updated", child_filter_fixture:branch_state(child_filter_fixture.ids.employee_view).raw ~= nil)
  session:close()
  assert_true("filter_child_close_restores_snapshot", child_filter_fixture.drawer.tree:get_node(child_filter_fixture.ids.employee_column) == nil)
  set_current_node(child_filter_fixture.winid, child_filter_fixture.drawer.tree, child_filter_fixture.ids.employee_view)
  child_filter_fixture.drawer:get_actions().expand()
  assert_true("filter_child_reexpand_shows_cached_column", child_filter_fixture.drawer.tree:get_node(convert.column_node_id(child_filter_fixture.ids.employee_view, {
    name = "employee_view_id",
    type = "NUMBER",
  })) ~= nil)

  print("STRUCT01_FILTER_FREEZE_OK=true")
  print("STRUCT01_FILTER_ZERO_RPC_OK=true")
  filter_fixture:cleanup()
  child_filter_fixture:cleanup()
end

print("STRUCT01_ALL_PASS=true")
vim.notify = saved_notify
vim.cmd("qa!")
