local convert = require("dbee.ui.drawer.convert")

local M = {}

local SEARCHABLE_TYPES = {
  table = true,
  view = true,
  procedure = true,
  ["function"] = true,
}

---@class DrawerModelCoverage
---@field ready_connections integer
---@field total_connections integer
---@field visible_connections? integer
---@field visible_uncached_connections? integer

---@class DrawerRenderNode
---@field id string
---@field name string
---@field type string
---@field schema string?
---@field raw_name string?
---@field conn_id string?
---@field source_meta table?
---@field search_text string?
---@field action_1 function?
---@field action_2 function?
---@field action_3 function?
---@field lazy_children (fun(): DrawerUINode[])?
---@field children DrawerRenderNode[]
---@field expanded boolean?

local function normalize_children(children)
  if not children or children == vim.NIL then
    return {}
  end
  return children
end

local function sort_struct_children(children)
  local sorted = {}
  for _, child in ipairs(normalize_children(children)) do
    table.insert(sorted, child)
  end
  table.sort(sorted, function(a, b)
    return tostring(a.type or "") .. tostring(a.name or "") < tostring(b.type or "") .. tostring(b.name or "")
  end)
  return sorted
end

local function connection_coverage(handler, structure_cache)
  local coverage = {
    ready_connections = 0,
    total_connections = 0,
  }

  for _, source in ipairs(handler:get_sources()) do
    local source_id = source:name()
    for _, conn in ipairs(handler:source_get_connections(source_id)) do
      coverage.total_connections = coverage.total_connections + 1
      local cached = structure_cache and structure_cache.root and structure_cache.root[conn.id] or structure_cache and structure_cache[conn.id]
      if cached and not cached.error then
        coverage.ready_connections = coverage.ready_connections + 1
      end
    end
  end

  return coverage
end

local function read_node_children(node)
  local children = rawget(node, "__children")
  if type(children) == "table" then
    return children
  end

  children = rawget(node, "_children")
  if type(children) == "table" then
    return children
  end

  return {}
end

local function to_render_node(node)
  local children = {}
  for _, child in ipairs(read_node_children(node)) do
    table.insert(children, to_render_node(child))
  end

  ---@type DrawerRenderNode
  local render_node = {
    id = node.id,
    name = node.name,
    type = node.type,
    schema = node.schema,
    raw_name = node.raw_name,
    conn_id = node.conn_id,
    source_meta = node.source_meta,
    action_1 = node.action_1,
    action_2 = node.action_2,
    action_3 = node.action_3,
    lazy_children = #children == 0 and node.lazy_children or nil,
    children = children,
    expanded = type(node.is_expanded) == "function" and node:is_expanded() or false,
  }

  return render_node
end

local function build_search_struct_nodes(structs, parent_id)
  local nodes = {}

  for _, struct in ipairs(sort_struct_children(structs)) do
    local node_id = convert.structure_node_id(parent_id, struct)
    local children = build_search_struct_nodes(struct.children, node_id)

    local node = {
      id = node_id,
      name = struct.name,
      type = struct.type,
      schema = struct.schema,
      raw_name = struct.name,
      struct_meta = {
        id = node_id,
        name = struct.name,
        schema = struct.schema,
        type = struct.type,
      },
      children = children,
    }

    table.insert(nodes, node)
  end

  return nodes
end

---@param conn ConnectionParams
---@param source_meta { id: string, name: string, can_create: boolean, can_update: boolean, can_delete: boolean, file: string|nil }
---@return string
local function search_connection_name(conn, source_meta)
  return string.format("%s  [%s]", tostring(conn.name or conn.id), tostring(source_meta.name or source_meta.id))
end

local function add_search_part(parts, value)
  if value == nil or value == "" then
    return
  end
  parts[#parts + 1] = tostring(value)
end

---@param conn_id string?
---@param raw_name string?
---@param display_name string?
---@param source_meta table?
---@return string
function M.connection_search_text(conn_id, raw_name, display_name, source_meta)
  local parts = {}
  add_search_part(parts, display_name)
  add_search_part(parts, raw_name)
  add_search_part(parts, conn_id)
  if source_meta then
    add_search_part(parts, source_meta.name)
    add_search_part(parts, source_meta.id)
    add_search_part(parts, source_meta.file)
  end
  return table.concat(parts, "\n")
end

---@param source Source
---@return string|nil
local function search_source_file(source)
  if type(source.file) ~= "function" then
    return nil
  end

  local ok, file_or_err = pcall(source.file, source)
  if ok then
    return file_or_err
  end

  return nil
end

---@param handler Handler
---@param structure_cache table
---@return table[] search_model
---@return DrawerModelCoverage coverage
function M.build_search_model(handler, structure_cache)
  local coverage = connection_coverage(handler, structure_cache)
  local search_model = {}

  for _, source in ipairs(handler:get_sources()) do
    local source_id = source:name()
    local source_meta = {
      id = source_id,
      name = source_id,
      can_create = type(source.create) == "function",
      can_update = type(source.update) == "function",
      can_delete = type(source.delete) == "function",
      file = search_source_file(source),
    }

    for _, conn in ipairs(handler:source_get_connections(source_id)) do
      local cached = structure_cache and structure_cache.root and structure_cache.root[conn.id] or structure_cache and structure_cache[conn.id]
      if cached and not cached.error then
        local display_name = search_connection_name(conn, source_meta)
        table.insert(search_model, {
          id = conn.id,
          name = display_name,
          raw_name = conn.name,
          type = "connection",
          conn_id = conn.id,
          source_meta = source_meta,
          search_text = M.connection_search_text(conn.id, conn.name, display_name, source_meta),
          children = build_search_struct_nodes(cached.structures, conn.id),
        })
      end
    end
  end

  return search_model, coverage
end

local function collect_connection_ids(nodes, out)
  out = out or {}
  for _, node in ipairs(nodes or {}) do
    if node.type == "connection" then
      out[node.conn_id or node.id] = true
    end
    collect_connection_ids(node.children, out)
  end
  return out
end

local function collect_visible_connection_rows(nodes, out)
  out = out or {}
  for _, node in ipairs(nodes or {}) do
    if node.type == "connection" then
      out[#out + 1] = node
    end
    collect_visible_connection_rows(node.children, out)
  end
  return out
end

---@param search_model table[]
---@param rendered_snapshot table[]
---@return table[] merged_model
---@return integer visible_connections
---@return integer visible_uncached_connections
function M.merge_visible_connection_rows(search_model, rendered_snapshot)
  local merged_model = {}
  for _, node in ipairs(search_model or {}) do
    merged_model[#merged_model + 1] = node
  end

  local cached_conn_ids = collect_connection_ids(search_model)
  local visible_connections = 0
  local visible_uncached_connections = 0
  for _, node in ipairs(collect_visible_connection_rows(rendered_snapshot)) do
    visible_connections = visible_connections + 1
    local conn_id = node.conn_id or node.id
    if conn_id and not cached_conn_ids[conn_id] then
      cached_conn_ids[conn_id] = true
      visible_uncached_connections = visible_uncached_connections + 1
      merged_model[#merged_model + 1] = {
        id = node.id,
        name = node.name,
        raw_name = node.raw_name,
        type = "connection",
        conn_id = conn_id,
        source_meta = node.source_meta,
        search_text = M.connection_search_text(conn_id, node.raw_name, node.name, node.source_meta),
        action_1 = node.action_1,
        action_2 = node.action_2,
        action_3 = node.action_3,
        lazy_children = node.lazy_children,
        children = {},
      }
    end
  end

  return merged_model, visible_connections, visible_uncached_connections
end

---@param handler Handler
---@param editor EditorUI
---@param result ResultUI
---@param structure_cache table
---@param current_conn_id string?
---@param refresh_cb fun()
---@param opts? { disable_help?: boolean }
---@return DrawerRenderNode[] render_model
---@return DrawerModelCoverage coverage
function M.build_tree_from_struct_cache(handler, editor, result, structure_cache, current_conn_id, refresh_cb, opts)
  local _ = editor
  local _current = current_conn_id
  local _refresh = refresh_cb
  local _opts = opts

  local coverage = connection_coverage(handler, structure_cache)
  local handler_nodes = convert.handler_nodes(handler, result, structure_cache, opts)
  local render_model = {}

  for _, node in ipairs(handler_nodes) do
    table.insert(render_model, to_render_node(node))
  end

  return render_model, coverage
end

function M.build_rendered_model(handler, editor, result, structure_cache, current_conn_id, refresh_cb, opts)
  return M.build_tree_from_struct_cache(handler, editor, result, structure_cache, current_conn_id, refresh_cb, opts)
end

M.SEARCHABLE_TYPES = SEARCHABLE_TYPES

return M
