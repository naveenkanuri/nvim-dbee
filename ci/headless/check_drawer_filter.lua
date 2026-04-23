-- Headless regression tests for live drawer filter behavior:
--   DRAW-01: live drawer filter, stale request rejection, and teardown safety
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=$(pwd)" \
--   -c "luafile ci/headless/check_drawer_filter.lua"

local function fail(msg)
  print("DRAW01_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local function assert_eq(label, got, expected)
  if got ~= expected then
    fail(label .. ": expected " .. vim.inspect(expected) .. " got " .. vim.inspect(got))
  end
end

local function assert_true(label, value)
  if not value then
    fail(label .. ": expected truthy, got " .. vim.inspect(value))
  end
end

local function assert_match(label, str, pattern)
  if type(str) ~= "string" or not str:find(pattern, 1, true) then
    fail(label .. ": expected string containing " .. vim.inspect(pattern) .. " got " .. vim.inspect(str))
  end
end

local function median(values)
  if #values == 0 then
    return 0
  end

  table.sort(values)
  local mid = math.floor(#values / 2) + 1
  if #values % 2 == 1 then
    return values[mid]
  end
  return (values[mid - 1] + values[mid]) / 2
end

local notifications = {}
local saved_notify = vim.notify

vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = tostring(msg), level = level, opts = opts }
end

local function clear_notifications()
  notifications = {}
end

local function last_notification()
  return notifications[#notifications]
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
    local tree = setmetatable({
      bufnr = opts.bufnr,
      prepare_node = opts.prepare_node,
      get_node_id = opts.get_node_id,
      root_nodes = {},
      index = {},
      visible_nodes = {},
    }, FakeTree)
    return tree
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
  select = function() end,
  input = function() end,
  filter = function(opts)
    local session = {
      opts = opts,
      closed = false,
    }

    function session:change(value)
      if opts.on_change then
        opts.on_change(value)
      end
    end

    function session:submit(value)
      if opts.on_submit then
        opts.on_submit(value)
      end
    end

    function session:close()
      if self.closed then
        return
      end
      self.closed = true
      if opts.on_close then
        opts.on_close()
      end
    end

    function session:unmount()
      self:close()
    end

    stub_filter_sessions[#stub_filter_sessions + 1] = session
    return session
  end,
}

package.loaded["dbee.ui.common"] = {
  create_blank_buffer = function(name)
    local bufnr = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, bufnr, name)
    return bufnr
  end,
  configure_buffer_mappings = function() end,
  configure_window_options = function() end,
  float_prompt = function() end,
  float_editor = function() end,
  float_hover = function() return function() end end,
}

package.loaded["dbee.ui.common.floats"] = {
  editor = function() end,
  hover = function() return function() end end,
  prompt = function() end,
}

package.loaded["dbee.layouts.tools"] = {
  save = function() return {} end,
  restore = function() end,
  make_only = function() end,
}

local api_ui_state = {
  drawer_prepare_close_calls = 0,
}

package.loaded["dbee.api.ui"] = {
  editor_search_note_with_file = function() return nil end,
  editor_search_note_with_buf = function() return nil end,
  editor_show = function() end,
  result_show = function() end,
  drawer_show = function() end,
  call_log_show = function() end,
  drawer_prepare_close = function()
    api_ui_state.drawer_prepare_close_calls = api_ui_state.drawer_prepare_close_calls + 1
  end,
}

package.loaded["dbee.ui.drawer"] = nil
package.loaded["dbee.ui.drawer.convert"] = nil
package.loaded["dbee.ui.drawer.model"] = nil
package.loaded["dbee.layouts"] = nil

local DrawerUI = require("dbee.ui.drawer")
local convert = require("dbee.ui.drawer.convert")
local layouts = require("dbee.layouts")

local function visible_ids(tree, parent_id, out)
  out = out or {}
  for _, node in ipairs(tree:get_nodes(parent_id)) do
    out[#out + 1] = node:get_id()
    if node:is_expanded() then
      visible_ids(tree, node:get_id(), out)
    end
  end
  return out
end

local function visible_row(tree, target_id)
  local ids = visible_ids(tree)
  for idx, id in ipairs(ids) do
    if id == target_id then
      return idx
    end
  end
end

local function set_current_node(winid, tree, node_id)
  local row = visible_row(tree, node_id)
  assert_true("set_current_node_" .. tostring(node_id), row ~= nil)
  vim.api.nvim_win_set_cursor(winid, { row, 0 })
end

local function get_visible_names(tree)
  local names = {}
  for _, id in ipairs(visible_ids(tree)) do
    local node = tree:get_node(id)
    names[#names + 1] = node and node.name or "<missing>"
  end
  return names
end

local function with_window(width, height)
  local host_buf = vim.api.nvim_create_buf(false, true)
  local winid = vim.api.nvim_open_win(host_buf, true, {
    relative = "editor",
    row = 1,
    col = 1,
    width = width or 90,
    height = height or 30,
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

local default_structures = {
  {
    type = "schema",
    name = "hr",
    schema = "hr",
    children = {
      { type = "table", name = "departments", schema = "hr" },
      { type = "table", name = "employees", schema = "hr" },
      { type = "view", name = "employee_view", schema = "hr" },
      { type = "function", name = "calculate_bonus", schema = "hr" },
    },
  },
  {
    type = "schema",
    name = "sales",
    schema = "sales",
    children = {
      { type = "table", name = "orders", schema = "sales" },
    },
  },
}

local alt_structures = {
  {
    type = "schema",
    name = "ops",
    schema = "ops",
    children = {
      { type = "table", name = "audit_log", schema = "ops" },
    },
  },
}

local function new_fixture(opts)
  opts = opts or {}

  local counters = {
    async = 0,
    columns = 0,
    list_databases = 0,
    select_database = 0,
    result_set = 0,
    execute = 0,
  }

  local handler_listeners = {}
  local editor_listeners = {}
  local current_db = {
    ["conn-ready"] = "main",
  }

  local columns_by_table = {
    ["conn-ready|hr|employees"] = {
      { name = "employee_id", type = "NUMBER" },
      { name = "employee_name", type = "TEXT" },
    },
    ["conn-ready|hr|departments"] = {},
    ["conn-ready|sales|orders"] = {
      { name = "order_id", type = "NUMBER" },
    },
    ["conn-alt|ops|audit_log"] = {
      { name = "log_id", type = "NUMBER" },
    },
  }

  local sources = opts.sources or {
    {
      name = function() return "source1" end,
      create = function() end,
      update = function() end,
      delete = function() end,
      file = function() return "source1.json" end,
    },
  }

  local source_connections = opts.source_connections or {
    source1 = {
      { id = "conn-ready", name = "Ready Connection", type = "postgres" },
      { id = "conn-alt", name = "Alt Connection", type = "postgres" },
      { id = "conn-cold", name = "Cold Connection", type = "postgres" },
      { id = "conn-error", name = "Error Connection", type = "postgres" },
    },
  }

  local handler = {
    register_event_listener = function(_, event, cb)
      handler_listeners[event] = cb
    end,
    get_current_connection = function()
      return { id = "conn-ready", name = "Ready Connection", type = "postgres" }
    end,
    get_sources = function()
      return sources
    end,
    source_get_connections = function(_, source_id)
      return source_connections[source_id] or {}
    end,
    connection_get_structure_async = function(_, conn_id, request_id)
      counters.async = counters.async + 1
      counters.last_async = { conn_id = conn_id, request_id = request_id }
    end,
    connection_get_columns = function(_, conn_id, table_opts)
      counters.columns = counters.columns + 1
      return columns_by_table[table.concat({ conn_id, table_opts.schema or "", table_opts.table or "" }, "|")] or {}
    end,
    connection_list_databases = function(_, conn_id)
      counters.list_databases = counters.list_databases + 1
      if conn_id == "conn-ready" then
        return current_db[conn_id], { "main", "analytics" }
      end
      return "", {}
    end,
    connection_select_database = function(_, conn_id, database)
      counters.select_database = counters.select_database + 1
      current_db[conn_id] = database
      if handler_listeners.database_selected then
        handler_listeners.database_selected({ conn_id = conn_id, database_name = database })
      end
    end,
    connection_get_helpers = function(_, _, table_opts)
      return {
        ["Browse"] = string.format("select * from %s.%s", table_opts.schema or "", table_opts.table or ""),
      }
    end,
    connection_execute = function(_, _, query)
      counters.execute = counters.execute + 1
      return { id = "call-" .. counters.execute, query = query, state = "archived" }
    end,
    connection_get_params = function(_, conn_id)
      return {
        name = conn_id,
        type = "postgres",
        url = "postgres://test/" .. conn_id,
      }
    end,
    set_current_connection = function(_, conn_id)
      counters.last_current_connection = conn_id
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
      return { id = "note-1" }
    end,
    namespace_get_notes = function(_, namespace)
      if namespace == "global" then
        return {
          { id = "note-global-1", name = "global-note.sql", bufnr = vim.api.nvim_create_buf(false, true) },
        }
      end
      return {
        { id = "note-local-1", name = "local-note.sql", bufnr = vim.api.nvim_create_buf(false, true) },
      }
    end,
    search_note = function()
      return nil
    end,
    set_current_note = function(_, note_id)
      counters.last_current_note = note_id
    end,
    namespace_create_note = function()
      return "new-note"
    end,
    note_rename = function() end,
    namespace_remove_note = function() end,
  }

  local result = {
    set_call = function(_, call)
      counters.result_set = counters.result_set + 1
      counters.last_call = call
    end,
  }

  local mappings = opts.mappings or {
    { key = "<CR>", mode = "n", action = "action_1" },
    { key = "cw", mode = "n", action = "action_2" },
    { key = "dd", mode = "n", action = "action_3" },
    { key = "o", mode = "n", action = "toggle" },
    { key = "e", mode = "n", action = "expand" },
    { key = "c", mode = "n", action = "collapse" },
    { key = "/", mode = "n", action = "filter" },
  }

  local drawer = DrawerUI:new(handler, editor, result, {
    mappings = mappings,
  })

  drawer.structure_cache = opts.structure_cache or {
    ["conn-ready"] = { structures = vim.deepcopy(default_structures) },
    ["conn-alt"] = { structures = vim.deepcopy(alt_structures) },
    ["conn-error"] = { error = "boom" },
  }

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

  local function cleanup()
    close_window_and_buffer(host_buf, winid)
    if drawer.bufnr and vim.api.nvim_buf_is_valid(drawer.bufnr) then
      pcall(vim.api.nvim_buf_delete, drawer.bufnr, { force = true })
    end
  end

  return {
    drawer = drawer,
    winid = winid,
    host_buf = host_buf,
    counters = counters,
    handler = handler,
    handler_listeners = handler_listeners,
    editor_listeners = editor_listeners,
    cleanup = cleanup,
  }
end

local fixture = new_fixture()
local drawer = fixture.drawer
local counters = fixture.counters
local rebuilt_host_buf = nil
local rebuilt_winid = nil

local source_id = "__source__source1"
local conn_id = "conn-ready"
local hr_schema_id = convert.structure_node_id(conn_id, { type = "schema", name = "hr", schema = "hr" })
local employees_id = convert.structure_node_id(hr_schema_id, { type = "table", name = "employees", schema = "hr" })
local departments_id = convert.structure_node_id(hr_schema_id, { type = "table", name = "departments", schema = "hr" })
local employee_view_id = convert.structure_node_id(hr_schema_id, { type = "view", name = "employee_view", schema = "hr" })
local employee_col_id = convert.column_node_id(employees_id, { type = "NUMBER", name = "employee_id" })
local db_switch_id = conn_id .. "_database_switch__"

set_current_node(fixture.winid, drawer.tree, source_id)
drawer:get_actions().expand()
set_current_node(fixture.winid, drawer.tree, conn_id)
drawer:get_actions().expand()
set_current_node(fixture.winid, drawer.tree, hr_schema_id)
drawer:get_actions().expand()
set_current_node(fixture.winid, drawer.tree, employees_id)
drawer:get_actions().expand()
set_current_node(fixture.winid, drawer.tree, departments_id)
drawer:get_actions().expand()
drawer:get_actions().collapse()

local baseline_columns = counters.columns
local baseline_cursor = vim.api.nvim_win_get_cursor(fixture.winid)
local baseline_snapshot_ref = nil

clear_notifications()
drawer:get_actions().filter()
local session = stub_filter_sessions[#stub_filter_sessions]
assert_true("a1_session_created", session ~= nil)
assert_true("a1_snapshot_saved", drawer.filter_restore_snapshot ~= nil)
assert_true("a1_search_model_saved", drawer.filter_search_model ~= nil)
assert_true("a1_cursor_saved", drawer.pre_filter_cursor ~= nil)
assert_true("a1_expansion_saved", drawer.pre_filter_expansion ~= nil)
assert_true("a1_plain_snapshot", type(drawer.filter_restore_snapshot[1].get_id) ~= "function")
baseline_snapshot_ref = drawer.cached_render_snapshot
print("DRAW01_A1_OK=true")

local empty_fixture = new_fixture({
  structure_cache = {
    ["conn-error"] = { error = "boom" },
  },
})
clear_notifications()
empty_fixture.drawer:get_actions().filter()
assert_match("a2_warn_zero_ready", last_notification().msg, "No cached connections available for filter")
assert_eq("a2_no_prompt", #stub_filter_sessions, 0)
assert_eq("a2_no_async", empty_fixture.counters.async, 0)
assert_eq("a2_no_db_list", empty_fixture.counters.list_databases, 0)
empty_fixture.cleanup()

assert_match("a2_coverage_label", session.opts.coverage_label, "2 of 4 connections cached")
print("DRAW01_A2_OK=true")

session:change("emp")
local visible_after_emp = get_visible_names(drawer.tree)
assert_true("a3_collapsed_cached_searchable", vim.tbl_contains(visible_after_emp, "employees"))
print("DRAW01_A3_OK=true")

local employees_node = drawer.tree:get_node(employees_id)
assert_true("a4_employees_node_present", employees_node ~= nil)
assert_true("a4_action_1_preserved", type(employees_node.action_1) == "function")
print("DRAW01_A4_OK=true")

local hr_children = drawer.tree:get_nodes(hr_schema_id)
assert_eq("a5_filtered_child_count", #hr_children, 2)
assert_eq("a5_filtered_order_1", hr_children[1].name, "employees")
assert_eq("a5_filtered_order_2", hr_children[2].name, "employee_view")
assert_true("a5_injective_ids", employees_id ~= employee_view_id)
print("DRAW01_A5_OK=true")

local refresh_before_restore = drawer.refresh_count
local columns_before_restore = counters.columns
session:change("")
assert_eq("a6_no_refresh_on_empty_restore", drawer.refresh_count, refresh_before_restore)
assert_eq("a6_no_column_rpc_on_restore", counters.columns, columns_before_restore)
assert_eq("a6_cursor_restored", vim.inspect(vim.api.nvim_win_get_cursor(fixture.winid)), vim.inspect(baseline_cursor))
print("DRAW01_A6_OK=true")

session:change("emp")
counters.async = 0
session:change("employee")
session:change("employees")
assert_eq("a7_zero_async_while_typing", counters.async, 0)
print("DRAW01_A7_OK=true")

counters.columns = 0
session:change("view")
session:change("bonus")
assert_eq("a8_zero_columns_while_typing", counters.columns, 0)
print("DRAW01_A8_OK=true")

local real_render_restore_snapshot = drawer.render_restore_snapshot
local close_restore_used_captured_state = false
drawer.render_restore_snapshot = function(self, snapshot, expansion, cursor)
  close_restore_used_captured_state = snapshot ~= nil and expansion ~= nil and cursor ~= nil
  -- Simulate async state clearing between filter_input = nil and restore.
  self.filter_restore_snapshot = nil
  self.pre_filter_expansion = nil
  self.pre_filter_cursor = nil
  return real_render_restore_snapshot(self, snapshot, expansion, cursor)
end
session:close()
drawer.render_restore_snapshot = real_render_restore_snapshot
assert_true("a9_filter_cleared", drawer.filter_input == nil and drawer.filter_restore_snapshot == nil)
assert_eq("a9_cursor_restored", vim.inspect(vim.api.nvim_win_get_cursor(fixture.winid)), vim.inspect(baseline_cursor))
assert_true("a9_employees_expanded", drawer.tree:get_node(employees_id):is_expanded())
assert_eq("a9_no_extra_empty_branch_load", counters.columns, 0)
assert_true("a9_close_uses_captured_snapshot", close_restore_used_captured_state)
assert_true("a9_close_not_blank", drawer.tree:get_node(employees_id) ~= nil)
print("DRAW01_A9_OK=true")

clear_notifications()
drawer:get_actions().filter()
session = stub_filter_sessions[#stub_filter_sessions]
session:change("emp")
set_current_node(fixture.winid, drawer.tree, employees_id)
local submit_restore_used_captured_state = false
drawer.render_restore_snapshot = function(self, snapshot, expansion, cursor)
  submit_restore_used_captured_state = snapshot ~= nil and expansion ~= nil and cursor ~= nil
  -- Simulate async state clearing between filter_input = nil and restore.
  self.filter_restore_snapshot = nil
  self.pre_filter_expansion = nil
  self.pre_filter_cursor = nil
  return real_render_restore_snapshot(self, snapshot, expansion, cursor)
end
session:submit("emp")
drawer.render_restore_snapshot = real_render_restore_snapshot
assert_eq("a10_exact_submit_focus", drawer.tree:get_node():get_id(), employees_id)
assert_true("a10_submit_uses_captured_snapshot", submit_restore_used_captured_state)
assert_true("a10_submit_not_blank", drawer.tree:get_node(employees_id) ~= nil)
print("DRAW01_A10_OK=true")

drawer:get_actions().filter()
session = stub_filter_sessions[#stub_filter_sessions]
session:change("emp")
set_current_node(fixture.winid, drawer.tree, employees_id)
session.opts.forward_insert["<Tab>"]()
set_current_node(fixture.winid, drawer.tree, employee_col_id)
session:submit("emp")
assert_eq("a11_submit_column_focus", drawer.tree:get_node():get_id(), employee_col_id)
assert_true("a11_column_rpc_happened", counters.columns >= 1)
print("DRAW01_A11_OK=true")

drawer:get_actions().filter()
session = stub_filter_sessions[#stub_filter_sessions]
session:change("emp")
set_current_node(fixture.winid, drawer.tree, conn_id)
drawer:get_actions().toggle()
drawer:get_actions().toggle()
local names_after_reexpand = get_visible_names(drawer.tree)
assert_true("a12_filtered_subset_kept", not vim.tbl_contains(names_after_reexpand, "main"))
assert_true("a12_filtered_subset_kept_alt", not vim.tbl_contains(names_after_reexpand, "analytics"))
assert_true("a12_filtered_unrelated_hidden", not vim.tbl_contains(names_after_reexpand, "departments"))
print("DRAW01_A12_OK=true")
session:close()

local requested_perf_mode = vim.env.DRAW01_PERF_MODE or "stub"
local actual_perf_mode = requested_perf_mode == "real-nui" and "stub" or requested_perf_mode

package.loaded["dbee.ui.drawer.menu"] = nil
package.loaded["nui.menu"] = {
  item = function(text)
    return { text = text }
  end,
}

local saved_cmd = vim.cmd
local cmd_calls = {}
local submitted_value = nil
local closed_count = 0
local fake_input_last

package.loaded["nui.input"] = setmetatable({}, {
  __call = function(_, popup_options, opts)
    local bufnr = vim.api.nvim_create_buf(false, true)
    local winid = vim.api.nvim_open_win(bufnr, false, {
      relative = "editor",
      row = 2,
      col = 2,
      width = 40,
      height = 1,
      border = "single",
    })
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/" })

    local input = {
      bufnr = bufnr,
      winid = winid,
      maps = {},
      opts = opts,
      mounted = false,
      closed = false,
    }

    function input:map(mode, key, fn)
      self.maps[mode .. ":" .. key] = fn
    end

    function input:mount()
      self.mounted = true
    end

    function input:unmount()
      if self.closed then
        return
      end
      self.closed = true
      if self.opts.on_close then
        self.opts.on_close()
      end
      close_window_and_buffer(self.bufnr, self.winid)
    end

    fake_input_last = input
    return input
  end,
})

vim.cmd = function(command)
  cmd_calls[#cmd_calls + 1] = command
end

local real_menu = require("dbee.ui.drawer.menu")
assert_true("a13_filter_exists", type(real_menu.filter) == "function")
local menu_buf, menu_win = with_window(60, 5)
local real_input = real_menu.filter({
  relative_winid = menu_win,
  coverage_label = "2 of 4 connections cached",
  on_change = function() end,
  on_submit = function(value)
    submitted_value = value
  end,
  on_close = function()
    closed_count = closed_count + 1
  end,
  forward_insert = {
    ["<Up>"] = function()
      cmd_calls[#cmd_calls + 1] = "up"
    end,
    ["<Down>"] = function()
      cmd_calls[#cmd_calls + 1] = "down"
    end,
    ["<Tab>"] = function()
      cmd_calls[#cmd_calls + 1] = "tab"
    end,
  },
  forward_normal = {
    ["j"] = function()
      cmd_calls[#cmd_calls + 1] = "j"
    end,
    ["k"] = function()
      cmd_calls[#cmd_calls + 1] = "k"
    end,
    ["<C-y>"] = function()
      cmd_calls[#cmd_calls + 1] = "cy"
    end,
  },
})

assert_true("a13_input_mounted", real_input.mounted == true)
assert_true("a13_insert_up_mapped", type(real_input.maps["i:<Up>"]) == "function")
assert_true("a13_insert_down_mapped", type(real_input.maps["i:<Down>"]) == "function")
assert_true("a13_insert_tab_mapped", type(real_input.maps["i:<Tab>"]) == "function")
assert_true("a13_normal_j_mapped", type(real_input.maps["n:j"]) == "function")
assert_true("a13_normal_k_mapped", type(real_input.maps["n:k"]) == "function")
assert_true("a13_normal_cy_mapped", type(real_input.maps["n:<C-y>"]) == "function")
assert_true("a13_reserved_cr_mapped", type(real_input.maps["n:<CR>"]) == "function")
assert_true("a13_reserved_esc_insert", type(real_input.maps["i:<Esc>"]) == "function")
assert_true("a13_reserved_esc_normal", type(real_input.maps["n:<Esc>"]) == "function")
assert_true("a13_mode_switch_insert_to_normal", type(real_input.maps["i:<C-]>"]) == "function")
assert_true("a13_mode_switch_normal_to_insert", type(real_input.maps["n:i"]) == "function")
assert_true("a13_printable_not_forwarded", real_input.maps["i:o"] == nil)
real_input.maps["i:<C-]>"]()
real_input.maps["n:i"]()
vim.api.nvim_buf_set_lines(real_input.bufnr, 0, -1, false, { "/employees" })
real_input.maps["n:<CR>"]()
assert_eq("a13_submit_value", submitted_value, "employees")
assert_true("a13_stopinsert_called", vim.tbl_contains(cmd_calls, "stopinsert"))
assert_true("a13_startinsert_called", vim.tbl_contains(cmd_calls, "startinsert"))
print("DRAW01_A13_OK=true")

vim.cmd = saved_cmd
close_window_and_buffer(menu_buf, menu_win)

set_current_node(fixture.winid, drawer.tree, employees_id)
drawer:get_actions().collapse()
drawer:refresh()
drawer:get_actions().filter()
session = stub_filter_sessions[#stub_filter_sessions]
session:change("emp")
set_current_node(fixture.winid, drawer.tree, employees_id)
session.opts.forward_insert["<Tab>"]()
set_current_node(fixture.winid, drawer.tree, employee_col_id)
local original_columns = fixture.handler.connection_get_columns
fixture.handler.connection_get_columns = function()
  counters.columns = counters.columns + 1
  return {}
end
clear_notifications()
session:submit("emp")
fixture.handler.connection_get_columns = original_columns
assert_eq("a14_fallback_focus", drawer.tree:get_node():get_id(), employees_id)
assert_match("a14_warn_fallback", last_notification().msg, "nearest restored ancestor")
print("DRAW01_A14_OK=true")

drawer:refresh()
set_current_node(fixture.winid, drawer.tree, source_id)
drawer:get_actions().expand()
set_current_node(fixture.winid, drawer.tree, conn_id)
drawer:get_actions().expand()
local db_switch_node = drawer.tree:get_node(db_switch_id)
assert_true("a15_db_switch_present", db_switch_node ~= nil)
drawer.refresh_count = 0

drawer:get_actions().filter()
session = stub_filter_sessions[#stub_filter_sessions]
session:change("emp")
assert_true("a15_filter_active", drawer.filter_input ~= nil)

local db_refresh_cb_calls = 0
db_switch_node.action_1(function()
  db_refresh_cb_calls = db_refresh_cb_calls + 1
end, function(opts)
  opts.on_confirm("analytics")
end)

assert_eq("a15_db_switch_no_generic_cb", db_refresh_cb_calls, 0)
assert_true("a15_filter_interrupted_on_db_switch", drawer.filter_input == nil)
assert_eq("a15_structure_cache_cleared", drawer.structure_cache[conn_id], nil)
assert_true("a15_request_recorded", drawer.structure_request_gen[conn_id] ~= nil)
assert_eq("a15_no_refresh_before_winner", drawer.refresh_count, 0)

local pending_request_id = drawer.structure_request_gen[conn_id]
drawer:on_structure_loaded({ conn_id = conn_id, request_id = pending_request_id - 1, structures = alt_structures })
assert_eq("a15_stale_refresh_ignored", drawer.refresh_count, 0)
assert_eq("a15_stale_cache_ignored", drawer.structure_cache[conn_id], nil)

drawer:on_structure_loaded({ conn_id = conn_id, request_id = pending_request_id, structures = alt_structures })
assert_eq("a15_winning_refresh_runs_once", drawer.refresh_count, 1)
assert_true("a15_winning_cache_updates", drawer.structure_cache[conn_id] ~= nil)
assert_eq("a15_request_preserved", drawer.structure_request_gen[conn_id], pending_request_id)
assert_eq("a15_applied_gen_recorded", drawer.structure_applied_gen[conn_id], pending_request_id)

drawer:on_structure_loaded({ conn_id = conn_id, request_id = pending_request_id - 1, structures = default_structures })
assert_eq("a15_stale_after_fresh_refresh_ignored", drawer.refresh_count, 1)
assert_eq("a15_stale_after_fresh_cache_kept", drawer.structure_cache[conn_id].structures[1].name, "ops")
assert_eq("a15_applied_gen_retained", drawer.structure_applied_gen[conn_id], pending_request_id)

drawer:get_actions().filter()
session = stub_filter_sessions[#stub_filter_sessions]
session:change("audit")
fixture.editor_listeners.current_note_changed({ note_id = "note-2" })
assert_true("a15_note_change_interrupts", drawer.filter_input == nil)

drawer:get_actions().filter()
session = stub_filter_sessions[#stub_filter_sessions]
session:change("audit")
local old_bufnr = drawer.bufnr
vim.api.nvim_buf_delete(drawer.bufnr, { force = true })
assert_true("a15_bufdelete_prepare_close", drawer.filter_input == nil and drawer.winid == nil)
if not vim.api.nvim_win_is_valid(fixture.winid) then
  rebuilt_host_buf, rebuilt_winid = with_window()
  fixture.winid = rebuilt_winid
  fixture.host_buf = rebuilt_host_buf
end
drawer:show(fixture.winid)
assert_true("a15_buf_rebuilt", drawer.bufnr ~= old_bufnr and vim.api.nvim_buf_is_valid(drawer.bufnr))

drawer:get_actions().filter()
session = stub_filter_sessions[#stub_filter_sessions]
session:close()
local snapshot_before_restart = drawer.cached_render_snapshot
drawer:get_actions().filter()
session = stub_filter_sessions[#stub_filter_sessions]
assert_true("a15_cached_snapshot_reused", drawer.cached_render_snapshot == snapshot_before_restart)
session:close()
set_current_node(fixture.winid, drawer.tree, source_id)
drawer:get_actions().expand()
set_current_node(fixture.winid, drawer.tree, conn_id)
drawer:get_actions().toggle()
assert_eq("a15_local_toggle_invalidates_snapshot", drawer.cached_render_snapshot, nil)

local cleanup_buf, cleanup_win = with_window(40, 5)
api_ui_state.drawer_prepare_close_calls = 0
local minimal_layout = { drawer_win = cleanup_win }
setmetatable(minimal_layout, { __index = layouts.Minimal })
local utils_mod = require("dbee.utils")
local saved_singleton_autocmd = utils_mod.create_singleton_autocmd
utils_mod.create_singleton_autocmd = function(events, opts)
  local callback = opts.callback
  local window = opts.window
  local buffer = opts.buffer
  opts.callback = function(event)
    if window and event.match and tostring(window) ~= tostring(event.match) then
      return
    end
    callback(event)
  end
  opts.window = nil
  opts.buffer = buffer
  vim.api.nvim_create_autocmd(events, opts)
end
minimal_layout:configure_drawer_window_cleanup(cleanup_win)
vim.api.nvim_win_close(cleanup_win, true)
vim.wait(50, function() return api_ui_state.drawer_prepare_close_calls > 0 end)
utils_mod.create_singleton_autocmd = saved_singleton_autocmd
assert_true("a15_winclosed_cleanup_called", api_ui_state.drawer_prepare_close_calls > 0)
assert_eq("a15_winclosed_clears_drawer_win", minimal_layout.drawer_win, nil)
close_window_and_buffer(cleanup_buf, cleanup_win)
print("DRAW01_A15_OK=true")

drawer:get_actions().filter()
session = stub_filter_sessions[#stub_filter_sessions]
session:change("AUDIT")
assert_true("a16_case_insensitive", vim.tbl_contains(get_visible_names(drawer.tree), "audit_log"))
session:close()
print("DRAW01_A16_OK=true")

assert_true("a17_real_menu_filter_exists", type(real_menu.filter) == "function")
print("DRAW01_A17_OK=true")

local startup_ms = {}
local restart_ms = {}
local refresh_ms = {}

for _ = 1, 5 do
  local t0 = vim.loop.hrtime()
  drawer:get_actions().filter()
  session = stub_filter_sessions[#stub_filter_sessions]
  startup_ms[#startup_ms + 1] = (vim.loop.hrtime() - t0) / 1e6

  local t1 = vim.loop.hrtime()
  session:close()
  restart_ms[#restart_ms + 1] = (vim.loop.hrtime() - t1) / 1e6

  local t2 = vim.loop.hrtime()
  drawer:refresh()
  refresh_ms[#refresh_ms + 1] = (vim.loop.hrtime() - t2) / 1e6
end

print(string.format("DRAW01_STARTUP_MS=%.2f", median(startup_ms)))
print(string.format("DRAW01_FILTER_RESTART_MS=%.2f", median(restart_ms)))
print(string.format("DRAW01_REFRESH_MS=%.2f", median(refresh_ms)))
print("DRAW01_PERF_MODE=" .. actual_perf_mode)
print("DRAW01_A18_OK=true")

local applied_values = {}
local real_apply_filter = drawer.apply_filter
drawer.apply_filter = function(self, value)
  table.insert(applied_values, value)
  return real_apply_filter(self, value)
end

drawer.filter_debounce_ms = 15
drawer:get_actions().filter()
session = stub_filter_sessions[#stub_filter_sessions]
session:change("a")
session:change("ab")
session:change("abc")
vim.wait(100, function() return #applied_values >= 1 end)
assert_eq("a19_latest_input_wins", applied_values[#applied_values], "abc")
local applied_before_close = #applied_values
session:change("stale")
session:close()
vim.wait(50, function() return false end, 10)
assert_eq("a19_close_cancels_pending", #applied_values, applied_before_close)
drawer.apply_filter = real_apply_filter
drawer.filter_debounce_ms = 0
print("DRAW01_A19_OK=true")

fixture.cleanup()
close_window_and_buffer(rebuilt_host_buf, rebuilt_winid)
vim.notify = saved_notify

print("DRAW01_ALL_PASS=true")
vim.cmd("qa!")
