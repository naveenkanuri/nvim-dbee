-- Headless regression tests for notification requirements (NOTIF-01, NOTIF-02, NOTIF-04).
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=$(pwd)" \
--   -c "luafile ci/headless/check_notifications.lua"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function fail(msg)
  print("NOTIF_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local function assert_eq(label, got, expected)
  if got ~= expected then
    fail(label .. ": expected " .. vim.inspect(expected) .. " got " .. vim.inspect(got))
  end
end

local function assert_match(label, str, pattern)
  if type(str) ~= "string" or not str:find(pattern, 1, true) then
    fail(label .. ": expected string containing " .. vim.inspect(pattern) .. " got " .. vim.inspect(str))
  end
end

-- ---------------------------------------------------------------------------
-- Capture vim.notify
-- ---------------------------------------------------------------------------

local notifications = {}
local saved_notify = vim.notify

vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = tostring(msg), level = level, opts = opts }
end

local function clear_notifications()
  notifications = {}
end

-- ---------------------------------------------------------------------------
-- Stubs for dbee.api, dbee.install, dbee.config (BEFORE requiring dbee)
-- ---------------------------------------------------------------------------

-- Clear any previously loaded modules
package.loaded["dbee"] = nil
package.loaded["dbee.api"] = nil
package.loaded["dbee.config"] = nil
package.loaded["dbee.install"] = nil

local conn = nil -- start with no connection for NOTIF-01 test
local core_loaded = true

package.loaded["dbee.api"] = {
  core = {
    is_loaded = function()
      return core_loaded
    end,
    get_current_connection = function()
      return conn
    end,
    connection_execute = function(_, query, opts)
      return { id = "call_1", query = query, state = "executing" }
    end,
    connection_get_calls = function()
      return {}
    end,
  },
  ui = {
    result_set_call = function() end,
  },
  setup = function() end,
  current_config = function()
    return {
      window_layout = {
        is_open = function()
          return false
        end,
        open = function() end,
        close = function() end,
        reset = function() end,
      },
    }
  end,
}

package.loaded["dbee.install"] = { exec = function() end }
package.loaded["dbee.config"] = {
  merge_with_default = function(cfg)
    return cfg or {}
  end,
  validate = function() end,
}

local dbee = require("dbee")

-- ---------------------------------------------------------------------------
-- NOTIF-01: No connection selected
-- ---------------------------------------------------------------------------

clear_notifications()
-- conn is nil at this point
local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(bufnr)
vim.bo[bufnr].filetype = "sql"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "SELECT 1;" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })

dbee.execute_context()

if #notifications < 1 then
  fail("notif01_no_notification")
  return
end
assert_match("notif01_msg", notifications[1].msg, "No connection selected")
assert_eq("notif01_level", notifications[1].level, vim.log.levels.WARN)
if not notifications[1].opts or notifications[1].opts.title ~= "nvim-dbee" then
  fail("notif01_title: expected opts.title='nvim-dbee' got " .. vim.inspect(notifications[1].opts))
  return
end

-- ---------------------------------------------------------------------------
-- NOTIF-02: Empty query at cursor
-- ---------------------------------------------------------------------------

clear_notifications()
-- Set connection to a valid value so we pass the NOTIF-01 check
conn = { id = "conn_test", type = "postgres" }

-- Buffer with only whitespace/comments
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "   ", "-- just a comment", "   " })
vim.api.nvim_win_set_cursor(0, { 1, 0 })

dbee.execute_context()

if #notifications < 1 then
  fail("notif02_no_notification")
  return
end
assert_match("notif02_msg", notifications[1].msg, "No SQL found at cursor")
assert_eq("notif02_level", notifications[1].level, vim.log.levels.WARN)

-- ---------------------------------------------------------------------------
-- NOTIF-04: Drawer operation failure (exercise current convert.lua closures)
-- ---------------------------------------------------------------------------

clear_notifications()

-- Stub nui.tree BEFORE requiring convert
package.loaded["nui.tree"] = {
  Node = function(fields, children)
    local expanded = false
    fields._children = children
    fields.has_children = function()
      return children and #children > 0
    end
    fields.expand = function()
      expanded = true
      return true
    end
    fields.is_expanded = function()
      return expanded
    end
    return fields
  end,
}

-- Stub common.float_prompt to auto-invoke callback immediately
package.loaded["dbee.ui.common"] = {
  float_prompt = function(prompt, opts)
    if opts and opts.callback then
      opts.callback({ name = "test-conn", type = "postgres", url = "postgres://localhost/test" })
    end
  end,
}

-- Clear cached convert module so it picks up our stubs
package.loaded["dbee.ui.drawer.convert"] = nil
-- Also clear utils once-tracking so source node expansion works
package.loaded["dbee.utils"] = nil

local utils = require("dbee.utils")
-- Re-override vim.notify since utils module was reloaded
vim.notify = function(msg, level, opts)
  notifications[#notifications + 1] = { msg = tostring(msg), level = level, opts = opts }
end

local convert = require("dbee.ui.drawer.convert")

local function find_node_by_id(nodes, id)
  for _, node in ipairs(nodes or {}) do
    if node.id == id then
      return node
    end
    if node._children then
      local child = find_node_by_id(node._children, id)
      if child then
        return child
      end
    end
  end
  return nil
end

-- Mock handler with a creatable source. Add-connection is now owned by DrawerUI
-- actions/wizard, so convert.handler_nodes() should not emit the legacy add child.
local mock_source = {
  name = function()
    return "test-source"
  end,
  create = function() end, -- presence marks the source as creatable
}

local mock_handler = {
  get_sources = function()
    return { mock_source }
  end,
  source_get_connections = function()
    return {}
  end,
  source_add_connection = function(self, source_id, spec)
    error("connection refused: test error")
  end,
}
local mock_result = {}

local nodes = convert.handler_nodes(mock_handler, mock_result, {})

local add_node = nil
for _, node in ipairs(nodes) do
  if node._children then
    for _, child in ipairs(node._children) do
      if child.type == "add" and child.name == "add" then
        add_node = child
        break
      end
    end
  end
  if add_node then
    break
  end
end

if add_node then
  fail("notif04_legacy_add_node_present")
  return
end

-- NOTIF-04b: edit action without DrawerUI wizard bridge warns instead of calling
-- the legacy source_update_connection closure directly.
clear_notifications()

local mock_handler_update = {
  get_sources = function()
    return { mock_source }
  end,
  source_get_connections = function()
    return { { id = "conn1", name = "test-conn" } }
  end,
  source_update_connection = function(self, source_id, conn_id, spec)
    error("update permission denied")
  end,
  connection_get_params = function(self, conn_id)
    return { name = "test-conn", type = "postgres", url = "postgres://localhost/test" }
  end,
}

-- Add update capability to source
mock_source.update = function() end

local nodes_upd = convert.handler_nodes(mock_handler_update, mock_result, {})
local edit_node = find_node_by_id(nodes_upd, "conn1")

if not edit_node or not edit_node.action_2 then
  fail("notif04_edit_node_not_found")
  return
end

-- action_2 is edit; without the DrawerUI wizard bridge it surfaces a warning.
edit_node.action_2(function() end)

local found_update_warning = false
for _, n in ipairs(notifications) do
  if n.msg:find("Wizard-backed connection editing is unavailable", 1, true) and n.level == vim.log.levels.WARN then
    if n.opts and n.opts.title == "nvim-dbee" then
      found_update_warning = true
      break
    end
  end
end

if not found_update_warning then
  fail("notif04_edit_unavailable_not_surfaced: notifications=" .. vim.inspect(notifications))
  return
end

-- NOTIF-04c: source_remove_connection failure
clear_notifications()

local mock_handler_delete = {
  get_sources = function()
    return { mock_source }
  end,
  source_get_connections = function()
    return { { id = "conn2", name = "del-conn" } }
  end,
  source_remove_connection = function(self, source_id, conn_id)
    error("delete forbidden")
  end,
}

-- Add delete capability to source
mock_source.delete = function() end

-- Stub common to auto-confirm deletion
package.loaded["dbee.ui.common"] = {
  float_prompt = function(prompt, opts)
    if opts and opts.callback then
      opts.callback({ name = "test-conn", type = "postgres", url = "postgres://localhost/test" })
    end
  end,
}

-- Re-require convert to pick up the new common stub
package.loaded["dbee.ui.drawer.convert"] = nil
convert = require("dbee.ui.drawer.convert")

local nodes_del = convert.handler_nodes(mock_handler_delete, mock_result, {})
local del_node = find_node_by_id(nodes_del, "conn2")

if not del_node or not del_node.action_3 then
  fail("notif04_delete_node_not_found")
  return
end

-- action_3 is delete; provide a select stub that auto-confirms "Yes"
del_node.action_3(function() end, function(opts)
  if opts and opts.on_confirm then
    opts.on_confirm("Yes")
  end
end)

local found_delete_error = false
for _, n in ipairs(notifications) do
  if n.msg:find("Failed to delete connection", 1, true) and n.level == vim.log.levels.ERROR then
    if n.opts and n.opts.title == "nvim-dbee" then
      found_delete_error = true
      break
    end
  end
end

if not found_delete_error then
  fail("notif04_delete_error_not_surfaced: notifications=" .. vim.inspect(notifications))
  return
end

-- ---------------------------------------------------------------------------
-- Level mapping + title test (utils.log direct verification)
-- ---------------------------------------------------------------------------

clear_notifications()

utils.log("info", "test info")
utils.log("warn", "test warn")
utils.log("error", "test error")

if #notifications < 3 then
  fail("level_mapping_count:" .. tostring(#notifications))
  return
end

assert_eq("level_info", notifications[1].level, vim.log.levels.INFO)
assert_eq("level_warn", notifications[2].level, vim.log.levels.WARN)
assert_eq("level_error", notifications[3].level, vim.log.levels.ERROR)

for i = 1, 3 do
  if not notifications[i].opts or notifications[i].opts.title ~= "nvim-dbee" then
    fail("level_title_" .. tostring(i) .. ": " .. vim.inspect(notifications[i].opts))
    return
  end
end

-- ---------------------------------------------------------------------------
-- Done
-- ---------------------------------------------------------------------------

vim.notify = saved_notify
print("NOTIF_ALL_PASS=true")
vim.cmd("qa!")
