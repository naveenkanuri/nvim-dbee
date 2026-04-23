-- Headless regression tests for drawer yank behavior:
--   CLIP-02: yank qualified names from drawer nodes
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=$(pwd)" \
--   -c "luafile ci/headless/check_drawer_yank.lua"

local function fail(msg)
  print("CLIP02_FAIL=" .. msg)
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

local clipboard_store = {}
vim.g.clipboard = {
  name = "test-clipboard",
  copy = {
    ["+"] = function(lines) clipboard_store["+"] = table.concat(lines, "\n") end,
    ["*"] = function(lines) clipboard_store["*"] = table.concat(lines, "\n") end,
  },
  paste = {
    ["+"] = function() return { clipboard_store["+"] or "" } end,
    ["*"] = function() return { clipboard_store["*"] or "" } end,
  },
}

local NodeMethods = {}

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

local function attach_children(parent_id, children)
  for _, child in ipairs(children or {}) do
    child._parent_id = parent_id
  end
end

local function new_node(fields, children)
  fields = fields or {}
  fields.__children = children or {}
  fields._children = fields.__children
  attach_children(fields.id, fields.__children)
  return setmetatable(fields, { __index = NodeMethods })
end

package.loaded["nui.tree"] = {
  Node = new_node,
}

package.loaded["nui.line"] = function()
  return {
    append = function() end,
  }
end

package.loaded["dbee.ui.common"] = {
  create_blank_buffer = function()
    return vim.api.nvim_create_buf(false, true)
  end,
  configure_buffer_mappings = function() end,
  configure_window_options = function() end,
  float_prompt = function() end,
  float_editor = function() end,
}

package.loaded["dbee.ui.drawer.menu"] = {
  select = function() end,
  input = function() end,
}

package.loaded["dbee.ui.drawer.expansion"] = {
  get = function() return {} end,
  restore = function() end,
}

local utils = require("dbee.utils")

vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = tostring(msg), level = level, opts = opts }
end

local convert = require("dbee.ui.drawer.convert")
local DrawerUI = require("dbee.ui.drawer")

local function set_registers(unnamed, clipboard)
  vim.fn.setreg('"', unnamed)
  vim.fn.setreg("+", clipboard)
end

local function assert_registers(label, unnamed, clipboard)
  assert_eq(label .. "_unnamed", vim.fn.getreg('"'), unnamed)
  assert_eq(label .. "_clipboard", vim.fn.getreg("+"), clipboard)
end

local function make_tree(lookup)
  return {
    current = nil,
    get_node = function(self, id)
      if id == nil then
        return self.current
      end
      return lookup[id]
    end,
  }
end

local table_node = new_node({
  id = convert.structure_node_id("conn1", { type = "table", name = "employees", schema = "hr" }),
  name = "employees",
  type = "table",
  schema = "hr",
})

local view_node = new_node({
  id = convert.structure_node_id("conn1", { type = "view", name = "employee_view", schema = "hr" }),
  name = "employee_view",
  type = "view",
  schema = "hr",
})

local function_node = new_node({
  id = convert.structure_node_id("conn1", { type = "function", name = "calculate_bonus", schema = "hr" }),
  name = "calculate_bonus",
  type = "function",
  schema = "hr",
})

local connection_node = new_node({
  id = "conn1",
  name = "prod",
  type = "connection",
})

local help_node = new_node({
  id = "__help__",
  name = "help",
  type = "help",
})

local empty_schema_table = new_node({
  id = convert.structure_node_id("conn1", { type = "table", name = "employees", schema = "" }),
  name = "employees",
  type = "table",
  schema = "",
})

local nil_schema_table = new_node({
  id = convert.structure_node_id("conn1", { type = "table", name = "employees", schema = nil }),
  name = "employees",
  type = "table",
  schema = nil,
})

local column_node = new_node({
  id = table_node.id .. "\x1fcolumn:NUMBER:employee_id",
  name = "employee_id   [NUMBER]",
  type = "column",
  raw_name = "employee_id",
})
column_node._parent_id = table_node.id

local missing_schema_column = new_node({
  id = nil_schema_table.id .. "\x1fcolumn:NUMBER:employee_id",
  name = "employee_id   [NUMBER]",
  type = "column",
  raw_name = "employee_id",
})
missing_schema_column._parent_id = nil_schema_table.id

local tree_lookup = {
  [table_node.id] = table_node,
  [view_node.id] = view_node,
  [function_node.id] = function_node,
  [connection_node.id] = connection_node,
  [help_node.id] = help_node,
  [empty_schema_table.id] = empty_schema_table,
  [nil_schema_table.id] = nil_schema_table,
  [column_node.id] = column_node,
  [missing_schema_column.id] = missing_schema_column,
}

local tree = make_tree(tree_lookup)

local drawer_stub = {
  tree = tree,
  handler = {},
  editor = {},
  result = {},
  mappings = {},
  pending_generated_calls = {},
  refresh = function() end,
  get_actions = DrawerUI.get_actions,
}

local actions = drawer_stub:get_actions()

clear_notifications()
tree.current = table_node
set_registers("seed-unnamed", "seed-plus")
actions.yank_name()
assert_registers("a1_table", "hr.employees", "hr.employees")
print("CLIP02_A1_OK=true")

clear_notifications()
tree.current = column_node
set_registers("seed-unnamed", "seed-plus")
actions.yank_name()
assert_registers("a2_column", "hr.employees.employee_id", "hr.employees.employee_id")
print("CLIP02_A2_OK=true")

clear_notifications()
tree.current = view_node
set_registers("seed-unnamed", "seed-plus")
actions.yank_name()
assert_registers("a3_view", "hr.employee_view", "hr.employee_view")
print("CLIP02_A3_OK=true")

clear_notifications()
tree.current = function_node
set_registers("seed-unnamed", "seed-plus")
actions.yank_name()
assert_registers("a4_function", "hr.calculate_bonus", "hr.calculate_bonus")
print("CLIP02_A4_OK=true")

clear_notifications()
tree.current = connection_node
set_registers("keep-unnamed", "keep-plus")
actions.yank_name()
assert_match("a5_connection_warn", last_notification().msg, "Nothing to copy")
assert_registers("a5_connection_regs", "keep-unnamed", "keep-plus")
print("CLIP02_A5_OK=true")

clear_notifications()
tree.current = help_node
set_registers("keep-unnamed", "keep-plus")
actions.yank_name()
assert_match("a6_help_warn", last_notification().msg, "Nothing to copy")
assert_registers("a6_help_regs", "keep-unnamed", "keep-plus")
print("CLIP02_A6_OK=true")

clear_notifications()
tree.current = empty_schema_table
set_registers("before-unnamed", "before-plus")
actions.yank_name()
assert_match("a7_missing_schema_warn", last_notification().msg, "Nothing to copy (schema unavailable)")
assert_registers("a7_missing_schema_regs", "before-unnamed", "before-plus")
print("CLIP02_A7_OK=true")

clear_notifications()
tree.current = missing_schema_column
set_registers("before-unnamed", "before-plus")
actions.yank_name()
assert_match("a8_missing_parent_schema_warn", last_notification().msg, "Nothing to copy (schema unavailable)")
assert_registers("a8_missing_parent_schema_regs", "before-unnamed", "before-plus")
print("CLIP02_A8_OK=true")

clear_notifications()
tree.current = table_node
set_registers("seed-unnamed", "seed-plus")
actions.yank_name()
assert_match("a9_success_message", last_notification().msg, "Copied: hr.employees")
print("CLIP02_A9_OK=true")

local collision_handler = {
  get_sources = function()
    return {
      {
        name = function() return "source1" end,
      },
    }
  end,
  source_get_connections = function()
    return {
      { id = "conn-collision", name = "Collision Conn", type = "postgres" },
    }
  end,
  connection_get_structure_async = function() end,
  connection_get_helpers = function() return {} end,
  connection_list_databases = function() return "", {} end,
  connection_get_columns = function(_, _, opts)
    if opts.schema == "c" and opts.table == "abtable" then
      return {
        { name = "abcolumn", type = "c" },
        { name = "ab", type = "columnc" },
      }
    end
    if opts.schema == "hr" and opts.table == "team:%" then
      return {
        { name = "col:%", type = "num%:type" },
        { name = "col", type = "%:numtype" },
      }
    end
    return {}
  end,
}

local collision_cache = {
  ["conn-collision"] = {
    structures = {
      { type = "table", name = "abtable", schema = "c" },
      { type = "table", name = "ab", schema = "tablec" },
      { type = "table", name = "team:%", schema = "hr" },
      { type = "table", name = "team", schema = ":%hr" },
    },
  },
}

local s1 = convert.structure_node_id("conn-collision", { type = "table", name = "abtable", schema = "c" })
local s2 = convert.structure_node_id("conn-collision", { type = "table", name = "ab", schema = "tablec" })
local s3 = convert.structure_node_id("conn-collision", { type = "table", name = "team:%", schema = "hr" })
local s4 = convert.structure_node_id("conn-collision", { type = "table", name = "team", schema = ":%hr" })

assert_true("a10_structure_old_concat_collision_resolved", s1 ~= s2)
assert_true("a10_structure_escape_collision_resolved", s3 ~= s4)

local source_nodes = convert.handler_nodes(collision_handler, {}, collision_cache)
local source_node = source_nodes[1]
local connection_collision = source_node and source_node.__children and source_node.__children[1]
assert_true("a10_connection_node_present", connection_collision ~= nil)

local structure_nodes = connection_collision.lazy_children()
local tables_by_key = {}
for _, node in ipairs(structure_nodes) do
  tables_by_key[(node.schema or "") .. "." .. node.name] = node
end

local old_collision_columns = tables_by_key["c.abtable"].lazy_children()
assert_true("a10_column_old_collision_count", #old_collision_columns == 2)
assert_true("a10_column_old_collision_resolved", old_collision_columns[1].id ~= old_collision_columns[2].id)

local escaped_columns = tables_by_key["hr.team:%"].lazy_children()
assert_true("a10_column_escape_collision_count", #escaped_columns == 2)
assert_true("a10_column_escape_collision_resolved", escaped_columns[1].id ~= escaped_columns[2].id)

print("CLIP02_A10_OK=true")

vim.notify = saved_notify

print("CLIP02_ALL_PASS=true")
vim.cmd("qa!")
