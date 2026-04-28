local NuiTree = require("nui.tree")
local NuiLine = require("nui.line")
local common = require("dbee.ui.common")
local menu = require("dbee.ui.drawer.menu")
local convert = require("dbee.ui.drawer.convert")
local drawer_model = require("dbee.ui.drawer.model")
local expansion = require("dbee.ui.drawer.expansion")
local utils = require("dbee.utils")

-- action function of drawer nodes
---@alias drawer_node_action fun(cb: fun(), select: menu_select, input: menu_input)

---@class DrawerRenderSnapshotNode
---@field id string
---@field name string
---@field type string
---@field schema? string
---@field raw_name? string
---@field action_1? drawer_node_action
---@field action_2? drawer_node_action
---@field action_3? drawer_node_action
---@field lazy_children? fun(): DrawerUINode[]
---@field rendered_children_loaded boolean
---@field children DrawerRenderSnapshotNode[]

-- A single line in drawer tree
---@class DrawerUINode: NuiTree.Node
---@field id string unique identifier
---@field name string display name
---@field type ""|"table"|"view"|"procedure"|"function"|"column"|"history"|"note"|"connection"|"database_switch"|"add"|"edit"|"remove"|"help"|"source"|"separator"|"load_more" type of node
---@field schema? string
---@field raw_name? string
---@field action_1? drawer_node_action primary action if function takes a second selection parameter, pick_items get picked before the call
---@field action_2? drawer_node_action secondary action if function takes a second selection parameter, pick_items get picked before the call
---@field action_3? drawer_node_action tertiary action if function takes a second selection parameter, pick_items get picked before the call
---@field lazy_children? fun():DrawerUINode[] lazy loaded child nodes
---@field structure_load_more? { branch_id: string, kind: string }

---@class DrawerStructureCache
---@field root table<string, { structures?: DBStructure[], error?: any }>
---@field root_gen table<string, integer>
---@field root_applied table<string, integer>
---@field root_epoch table<string, integer>
---@field loaded_lazy_ids table<string, boolean>
---@field branches table<string, table<string, { raw?: Column[], error?: any, built_count: integer, render_limit: integer, request_gen: integer, applied_gen: integer, loading: boolean }>>

---@class DrawerUI
---@field private tree NuiTree
---@field private handler Handler
---@field private editor EditorUI
---@field private result ResultUI
---@field private mappings key_mapping[]
---@field private candies table<string, Candy> map of eye-candy stuff (icons, highlight)
---@field private disable_help boolean show help or not
---@field private winid? integer
---@field private bufnr integer
---@field private current_conn_id? connection_id current active connection
---@field private current_note_id? note_id current active note
---@field private pending_generated_calls table<string, { note_id: note_id, fallback_template: string }>
---@field private _manual_refresh_conns table<string, boolean>
---@field private _replay_container_expansions table<string, table<string, boolean>>
---@field private _struct_cache DrawerStructureCache
---@field private filter_text string current filter string
---@field private pre_filter_expansion table<string, boolean>? saved expansion before filter
---@field private pre_filter_cursor integer[]? saved cursor position {row, col} before filter
---@field private filter_restore_snapshot DrawerRenderSnapshotNode[]? saved rendered snapshot used for cancel/empty restore
---@field private filter_search_model table[]? immutable search model captured when filter starts
---@field private filter_input? table NuiInput instance when filter is active
---@field private next_filter_session_id integer monotonically increasing token assigned to each filter session
---@field private active_filter_session_id? integer token for the currently active filter session; stale scheduled callbacks must no-op when this changes
---@field private filter_debounce_ms integer debounce window for live apply
---@field private pending_filter_text? string latest queued filter text
---@field private filter_timer? uv_timer_t
---@field private cached_search_model? { nodes: table[], coverage: DrawerModelCoverage } immutable search corpus reused across repeated filter starts within the same authoritative drawer generation
---@field private cached_render_snapshot? DrawerRenderSnapshotNode[] baseline rendered-tree snapshot reused across repeated filter starts while the rendered tree is unchanged
---@field private filter_cached_connections integer ready cached connections in the current filter session
---@field private filter_total_connections integer total connections visible to the drawer
---@field private window_options table<string, any> a table of window options
---@field private buffer_options table<string, any> a table of buffer options
local DrawerUI = {}

local SEARCHABLE_TYPES = drawer_model.SEARCHABLE_TYPES or {
  table = true,
  view = true,
  procedure = true,
  ["function"] = true,
}

local SNAPSHOT_ID_SEP = "\x1f"
local ID_SEP = convert.ID_SEP or "\x1f"
local LOAD_MORE_SUFFIX = convert.LOAD_MORE_SUFFIX or (ID_SEP .. "__load_more__")
local COLUMNS_KIND = "columns"
local CHILD_CHUNK_SIZE = 1000
local TABLE_LIKE_TYPES = {
  table = true,
  view = true,
}

local function normalize_mapping_lhs(key)
  return vim.api.nvim_replace_termcodes(key, true, true, true)
end

local RESERVED_FILTER_KEYS = {}
for _, key in ipairs({ "<CR>", "<Esc>", "<C-]>", "i", "<C-y>", "<Up>", "<Down>", "<Tab>", "<S-Tab>", "j", "k" }) do
  RESERVED_FILTER_KEYS[normalize_mapping_lhs(key)] = true
end

---@param key any
---@return boolean
local function is_single_prompt_safe_key(key)
  if type(key) ~= "string" then
    return false
  end
  return vim.fn.strchars(key) == 1 or key:match("^<[^>]+>$") ~= nil
end

---@private
---@param text string
---@return string
local function normalize_text(text)
  return tostring(text):gsub("\r\n", "\n")
end

---@private
---@param schema string?
---@param name string?
---@return string
local function default_call_template(schema, name)
  local schema_name = schema or ""
  local object_name = name or ""
  return string.format("BEGIN\n  %s.%s;\nEND;", schema_name, object_name)
end

---@param ui DrawerUI
---@param node_id string
local function mark_lazy_loaded(ui, node_id)
  ui._struct_cache.loaded_lazy_ids[node_id] = true
end

---@param ui DrawerUI
local function clear_filter_state(ui)
  ui.filter_input = nil
  ui.filter_restore_snapshot = nil
  ui.filter_search_model = nil
  ui.pre_filter_expansion = nil
  ui.pre_filter_cursor = nil
  ui.filter_cached_connections = 0
  ui.filter_total_connections = 0
  ui.filter_text = ""
end

---@param ui DrawerUI
local function invalidate_authoritative_caches(ui)
  ui.cached_search_model = nil
  ui.cached_render_snapshot = nil
end

---@param ui DrawerUI
local function invalidate_render_snapshot(ui)
  ui.cached_render_snapshot = nil
end

---@param value any
---@return integer
local function normalize_root_epoch(value)
  if value == nil or value == vim.NIL then
    return 0
  end
  return tonumber(value) or 0
end

---@param branch_id string
---@param kind? string
---@return string
local function branch_cache_key(branch_id, kind)
  return branch_id .. ID_SEP .. (kind or COLUMNS_KIND)
end

---@param ui DrawerUI
---@param conn_id string
---@return integer
local function current_root_epoch(ui, conn_id)
  return ui._struct_cache.root_epoch[conn_id] or 0
end

---@param ui DrawerUI
---@param conn_id string
---@return boolean
local function root_request_pending(ui, conn_id)
  local requested = ui._struct_cache.root_gen[conn_id] or 0
  local applied = ui._struct_cache.root_applied[conn_id] or 0
  return requested > applied and ui._struct_cache.root[conn_id] == nil
end

---@param ui DrawerUI
---@param conn_id string
---@param branch_id string
---@param kind? string
---@param create? boolean
---@return { raw?: Column[], error?: any, built_count: integer, render_limit: integer, request_gen: integer, applied_gen: integer, loading: boolean }?
local function branch_state(ui, conn_id, branch_id, kind, create)
  local conn_branches = ui._struct_cache.branches[conn_id]
  if not conn_branches and create then
    conn_branches = {}
    ui._struct_cache.branches[conn_id] = conn_branches
  end
  if not conn_branches then
    return nil
  end

  local key = branch_cache_key(branch_id, kind)
  if not conn_branches[key] and create then
    conn_branches[key] = {
      raw = nil,
      error = nil,
      built_count = 0,
      render_limit = CHILD_CHUNK_SIZE,
      request_gen = 0,
      applied_gen = 0,
      loading = false,
    }
  end

  return conn_branches[key]
end

---@param children any[]?
---@return any[]
local function normalize_children(children)
  if not children or children == vim.NIL then
    return {}
  end
  return children
end

---@param structs DBStructure[]?
---@return DBStructure[]
local function sorted_struct_children(structs)
  local sorted = {}
  for _, struct in ipairs(normalize_children(structs)) do
    table.insert(sorted, struct)
  end

  table.sort(sorted, function(a, b)
    return tostring(a.type or "") .. tostring(a.name or "") < tostring(b.type or "") .. tostring(b.name or "")
  end)

  return sorted
end

---@param branch_id string
---@return string
local function load_more_node_id(branch_id)
  return branch_id .. LOAD_MORE_SUFFIX
end

---@param snapshot_nodes DrawerRenderSnapshotNode[]?
---@return DrawerRenderSnapshotNode[]
local function clone_rendered_snapshot(snapshot_nodes)
  local cloned = {}
  for _, snap in ipairs(snapshot_nodes or {}) do
    table.insert(cloned, {
      id = snap.id,
      name = snap.name,
      type = snap.type,
      schema = snap.schema,
      raw_name = snap.raw_name,
      action_1 = snap.action_1,
      action_2 = snap.action_2,
      action_3 = snap.action_3,
      lazy_children = snap.lazy_children,
      rendered_children_loaded = snap.rendered_children_loaded == true,
      children = clone_rendered_snapshot(snap.children),
    })
  end
  return cloned
end

---@param snapshot_nodes DrawerRenderSnapshotNode[]?
---@param out? table<string, boolean>
---@return table<string, boolean>
local function collect_loaded_lazy_ids(snapshot_nodes, out)
  out = out or {}
  for _, snap in ipairs(snapshot_nodes or {}) do
    if snap.rendered_children_loaded then
      out[snap.id] = true
    end
    collect_loaded_lazy_ids(snap.children, out)
  end
  return out
end

---@param snapshot_nodes DrawerRenderSnapshotNode[]?
---@return DrawerUINode[]
local function snapshot_to_tree_nodes(snapshot_nodes)
  local restored = {}
  for _, snap in ipairs(snapshot_nodes or {}) do
    local children = nil
    if snap.rendered_children_loaded and snap.children and #snap.children > 0 then
      children = snapshot_to_tree_nodes(snap.children)
    end

    table.insert(restored, NuiTree.Node({
      id = snap.id,
      name = snap.name,
      type = snap.type,
      schema = snap.schema,
      raw_name = snap.raw_name,
      action_1 = snap.action_1,
      action_2 = snap.action_2,
      action_3 = snap.action_3,
      lazy_children = children == nil and snap.lazy_children or nil,
    }, children))

    if snap.rendered_children_loaded then
      restored[#restored]._materialized_in_tree = true
    end
  end
  return restored
end

---@param ui DrawerUI
---@param tree NuiTree
---@param parent_id? string
---@return DrawerRenderSnapshotNode[]
local function snapshot_rendered_tree(ui, tree, parent_id)
  local snapshot = {}
  for _, node in ipairs(tree:get_nodes(parent_id)) do
    local children = snapshot_rendered_tree(ui, tree, node:get_id())
    local was_materialized = ui._struct_cache.loaded_lazy_ids[node:get_id()] == true or node:is_expanded() or #children > 0
    table.insert(snapshot, {
      id = node.id,
      name = node.name,
      type = node.type,
      schema = node.schema,
      raw_name = node.raw_name,
      action_1 = node.action_1,
      action_2 = node.action_2,
      action_3 = node.action_3,
      lazy_children = was_materialized and nil or node.lazy_children,
      rendered_children_loaded = was_materialized,
      children = children,
    })
  end
  return snapshot
end

---@param node_id string
---@return integer
local function snapshot_node_depth(node_id)
  local _, depth = tostring(node_id or ""):gsub(SNAPSHOT_ID_SEP, "")
  return depth
end

---@param expansion_ids table<string, boolean>?
---@return string[]
local function sorted_expansion_ids(expansion_ids)
  local ids = {}
  for node_id, expanded in pairs(expansion_ids or {}) do
    if expanded then
      table.insert(ids, node_id)
    end
  end
  table.sort(ids, function(a, b)
    local da, db = snapshot_node_depth(a), snapshot_node_depth(b)
    if da == db then
      return a < b
    end
    return da < db
  end)
  return ids
end

---@param ui DrawerUI
---@param node table
---@param inherited_conn_id string?
---@param children? DrawerUINode[]
---@return DrawerUINode
local function searchable_node_to_tree_node(ui, node, inherited_conn_id, children)
  local conn_id = node.type == "connection" and (node.conn_id or node.id) or inherited_conn_id
  local tree_node = NuiTree.Node({
    id = node.id,
    name = node.name,
    type = node.type,
    schema = node.schema,
    raw_name = node.raw_name,
  }, children) --[[@as DrawerUINode]]

  if node.type == "connection" and node.source_meta then
    convert.decorate_connection_node(tree_node, ui.handler, node.source_meta, conn_id or node.id)
  elseif SEARCHABLE_TYPES[node.type] then
    local struct_meta = node.struct_meta or {
      id = node.id,
      name = node.name,
      schema = node.schema,
      type = node.type,
    }
    local lazy_children_factory
    if TABLE_LIKE_TYPES[node.type] then
      lazy_children_factory = function()
        return ui:_materialize_table_like_branch(conn_id or "", node.id, struct_meta)
      end
    end
    convert.decorate_structure_node(tree_node, ui.handler, ui.result, conn_id or "", struct_meta, lazy_children_factory)
  end

  if children and #children > 0 then
    tree_node.lazy_children = nil
    tree_node._materialized_in_tree = true
    tree_node:expand()
  elseif node.expanded then
    tree_node:expand()
  end

  return tree_node
end

---@param ui DrawerUI
---@param node DrawerUINode
---@param render_after? boolean
local function expand_node_filter_safe(ui, node, render_after)
  if not node:is_expanded() and type(node.lazy_children) == "function" and not node._materialized_in_tree then
    local children = node.lazy_children()
    mark_lazy_loaded(ui, node:get_id())
    ui.tree:set_nodes(children, node:get_id())
    node._materialized_in_tree = true
  end

  node:expand()

  if render_after ~= false then
    ui.tree:render()
  end
end

---@param ui DrawerUI
---@param reason string
---@return fun()
local function refresh_filter_safe(ui, reason)
  return function()
    if ui.filter_restore_snapshot or ui.filter_input then
      ui:interrupt_filter(reason)
    end
    ui:refresh()
  end
end

---@param ui DrawerUI
---@param expansion_ids table<string, boolean>?
---@return table<string, boolean> unresolved_ids
local function restore_expansion_state(ui, expansion_ids)
  local unresolved = {}
  for _, node_id in ipairs(sorted_expansion_ids(expansion_ids)) do
    local node = ui.tree:get_node(node_id)
    if node then
      if TABLE_LIKE_TYPES[node.type] then
        if node._materialized_in_tree or node:has_children() then
          node:expand()
        else
          unresolved[node_id] = true
        end
      else
        expand_node_filter_safe(ui, node, false)
      end
    else
      unresolved[node_id] = true
    end
  end
  return unresolved
end

---@param ui DrawerUI
---@param nodes table[]?
---@param pattern string
---@param inherited_conn_id? string
---@return DrawerUINode[]
local function filter_nodes_recursive(ui, nodes, pattern, inherited_conn_id)
  local filtered = {}

  for _, node in ipairs(nodes or {}) do
    local conn_id = node.type == "connection" and (node.conn_id or node.id) or inherited_conn_id
    local children = filter_nodes_recursive(ui, node.children, pattern, conn_id)
    local matched_self = SEARCHABLE_TYPES[node.type] and string.find(string.lower(node.name), pattern, 1, true) ~= nil

    if matched_self or #children > 0 then
      table.insert(filtered, searchable_node_to_tree_node(ui, node, conn_id, children))
    end
  end

  return filtered
end

---@param tree NuiTree
---@param node DrawerUINode|nil
---@return string[]
local function selected_path_ids(tree, node)
  local path = {}
  local current = node

  while current do
    table.insert(path, 1, current:get_id())
    local parent_id = current:get_parent_id()
    if not parent_id then
      break
    end
    current = tree:get_node(parent_id)
  end

  return path
end

---@param tree NuiTree
---@param target_id string
---@param parent_id? string
---@param row? integer
---@return integer?
local function visible_node_row(tree, target_id, parent_id, row)
  row = row or 1

  for _, node in ipairs(tree:get_nodes(parent_id)) do
    if node:get_id() == target_id then
      return row
    end
    row = row + 1
    if node:is_expanded() then
      local found = visible_node_row(tree, target_id, node:get_id(), row)
      if found then
        return found
      end

      local function count_visible(parent)
        local total = 0
        for _, child in ipairs(tree:get_nodes(parent)) do
          total = total + 1
          if child:is_expanded() then
            total = total + count_visible(child:get_id())
          end
        end
        return total
      end

      row = row + count_visible(node:get_id())
    end
  end

  return nil
end

---@param ui DrawerUI
---@param tree NuiTree
---@param path_ids string[]
---@return boolean exact_restored
---@return string? resolved_id
local function materialize_selected_path(ui, tree, path_ids)
  local resolved_id = nil

  for index, node_id in ipairs(path_ids or {}) do
    local node = tree:get_node(node_id)

    if not node and index > 1 then
      local parent = tree:get_node(path_ids[index - 1])
      if parent then
        expand_node_filter_safe(ui, parent, false)
        node = tree:get_node(node_id)
      end
    end

    if not node then
      break
    end

    resolved_id = node:get_id()

    if index < #path_ids then
      expand_node_filter_safe(ui, node, false)
    end
  end

  return resolved_id == path_ids[#path_ids], resolved_id
end

---@param ui DrawerUI
---@param conn_id string
---@param branch_id string
---@param kind? string
---@return DrawerUINode[]
local function build_branch_nodes(ui, conn_id, branch_id, kind)
  local state = branch_state(ui, conn_id, branch_id, kind, false)
  if not state then
    return {}
  end

  if state.loading then
    return { convert.loading_node(branch_id) }
  end

  if state.error then
    return { convert.error_node(branch_id, state.error) }
  end

  local raw = normalize_children(state.raw)
  local render_limit = math.max(state.render_limit or CHILD_CHUNK_SIZE, CHILD_CHUNK_SIZE)
  local built_count = math.min(#raw, render_limit)
  state.render_limit = render_limit
  state.built_count = built_count

  local chunk = {}
  for index = 1, built_count do
    chunk[#chunk + 1] = raw[index]
  end

  local nodes = convert.column_nodes(branch_id, chunk)
  if built_count < #raw then
    nodes[#nodes + 1] = convert.load_more_node(branch_id, kind or COLUMNS_KIND)
  end

  return nodes
end

---@param ui DrawerUI
---@param conn ConnectionParams
---@param opts? { suppress_root_request?: boolean }
---@return DrawerUINode[]
local function build_connection_children(ui, conn, opts)
  opts = opts or {}
  local cached_root = ui._struct_cache.root[conn.id]
  if not cached_root then
    if not opts.suppress_root_request and not root_request_pending(ui, conn.id) then
      ui:request_structure_reload(conn.id)
    end
    return { convert.loading_node(conn.id) }
  end

  local nodes = {}
  if cached_root.error then
    nodes[#nodes + 1] = convert.error_node(conn.id, cached_root.error)
  else
    for _, struct in ipairs(sorted_struct_children(cached_root.structures)) do
      nodes[#nodes + 1] = ui:_build_structure_node(conn.id, conn.id, struct)
    end
  end

  local current_db, available_dbs = ui.handler:connection_list_databases(conn.id)
  if current_db ~= "" and #available_dbs > 0 then
    table.insert(nodes, 1, NuiTree.Node({
      id = conn.id .. "_database_switch__",
      name = current_db,
      type = "database_switch",
      action_1 = function(_, select)
        select {
          title = "Select a Database",
          items = available_dbs,
          on_confirm = function(selection)
            ui.handler:connection_select_database(conn.id, selection)
          end,
        }
      end,
    }) --[[@as DrawerUINode]])
  end

  return nodes
end

---@param tree NuiTree
---@param node DrawerUINode|nil
---@return connection_id?
local function resolve_connection_ancestor(tree, node)
  local current = node
  while current do
    if current.type == "connection" then
      return current:get_id()
    end

    local parent_id = current:get_parent_id()
    if not parent_id then
      break
    end
    current = tree:get_node(parent_id)
  end

  return nil
end

function DrawerUI:_build_structure_children(conn_id, parent_id, structs)
  local nodes = {}
  for _, struct in ipairs(sorted_struct_children(structs)) do
    nodes[#nodes + 1] = self:_build_structure_node(conn_id, parent_id, struct)
  end
  return nodes
end

function DrawerUI:_materialize_table_like_branch(conn_id, node_id, struct)
  local cached = branch_state(self, conn_id, node_id, COLUMNS_KIND, true)
  if cached.loading or cached.error ~= nil or cached.raw ~= nil then
    return build_branch_nodes(self, conn_id, node_id, COLUMNS_KIND)
  end

  local request_id = math.max(cached.request_gen or 0, cached.applied_gen or 0) + 1
  cached.request_gen = request_id
  cached.loading = true
  cached.error = nil
  cached.raw = nil
  cached.built_count = 0
  cached.render_limit = math.max(cached.render_limit or CHILD_CHUNK_SIZE, CHILD_CHUNK_SIZE)

  self.handler:connection_get_columns_async(conn_id, request_id, node_id, current_root_epoch(self, conn_id), {
    table = struct.name,
    schema = struct.schema,
    materialization = struct.type,
    kind = COLUMNS_KIND,
  })

  return { convert.loading_node(node_id) }
end

function DrawerUI:_build_structure_node(conn_id, parent_id, struct)
  local node_id = convert.structure_node_id(parent_id, struct)
  local built_children = nil
  local lazy_children_factory = nil

  if TABLE_LIKE_TYPES[struct.type] then
    local cached_branch = branch_state(self, conn_id, node_id, COLUMNS_KIND, false)
    if cached_branch and (cached_branch.loading or cached_branch.error ~= nil or cached_branch.raw ~= nil) then
      built_children = build_branch_nodes(self, conn_id, node_id, COLUMNS_KIND)
    end

    lazy_children_factory = function()
      return self:_materialize_table_like_branch(conn_id, node_id, struct)
    end
  else
    local children = normalize_children(struct.children)
    if #children > 0 then
      if self._struct_cache.loaded_lazy_ids[node_id] == true then
        built_children = self:_build_structure_children(conn_id, node_id, children)
      end
      lazy_children_factory = function()
        return self:_build_structure_children(conn_id, node_id, children)
      end
    end
  end

  local node = NuiTree.Node({
    id = node_id,
    name = struct.name,
    schema = struct.schema,
    type = struct.type,
  }, built_children) --[[@as DrawerUINode]]

  convert.decorate_structure_node(node, self.handler, self.result, conn_id, {
    id = node_id,
    name = struct.name,
    schema = struct.schema,
    type = struct.type,
  }, lazy_children_factory)

  if self._struct_cache.loaded_lazy_ids[node_id] == true or (built_children and #built_children > 0) then
    node._materialized_in_tree = true
  end

  return node
end

function DrawerUI:_patch_connection_subtree(conn_id, opts)
  opts = opts or {}

  local node = self.tree:get_node(conn_id)
  if not node then
    return false
  end

  local ok_params, conn = pcall(self.handler.connection_get_params, self.handler, conn_id)
  if not ok_params or not conn then
    conn = { id = conn_id, name = conn_id }
  end
  conn.id = conn.id or conn_id
  conn.name = conn.name or conn_id

  local was_expanded = node:is_expanded()
  self.tree:set_nodes(build_connection_children(self, conn, {
    suppress_root_request = opts.suppress_root_request == true,
  }), conn_id)
  node._materialized_in_tree = true

  if was_expanded then
    node:expand()
  end

  if opts.restore_container_expansions then
    local replay = self._replay_container_expansions[conn_id]
    self._replay_container_expansions[conn_id] = nil
    for _, node_id in ipairs(sorted_expansion_ids(replay)) do
      if node_id ~= conn_id then
        local child = self.tree:get_node(node_id)
        if child then
          expand_node_filter_safe(self, child, false)
        end
      end
    end
  end

  self.tree:render()
  return true
end

function DrawerUI:_patch_branch_subtree(conn_id, branch_id, kind)
  local node = self.tree:get_node(branch_id)
  if not node then
    return false
  end

  local was_expanded = node:is_expanded()
  self.tree:set_nodes(build_branch_nodes(self, conn_id, branch_id, kind), branch_id)
  node._materialized_in_tree = true
  if was_expanded then
    node:expand()
  end
  self.tree:render()
  return true
end

function DrawerUI:_capture_container_expansions(conn_id)
  local captured = {}
  local expansion_ids = expansion.get(self.tree)
  for node_id, expanded in pairs(expansion_ids or {}) do
    if expanded and (node_id == conn_id or node_id:sub(1, #conn_id + 1) == conn_id .. ID_SEP) then
      local node = self.tree:get_node(node_id)
      if node and node.type ~= "table" and node.type ~= "view" and node.type ~= "column" and node.type ~= "load_more" then
        captured[node_id] = true
      end
    end
  end
  self._replay_container_expansions[conn_id] = captured
end

function DrawerUI:_prune_loaded_lazy_ids(conn_id)
  for node_id in pairs(self._struct_cache.loaded_lazy_ids) do
    if node_id == conn_id or node_id:sub(1, #conn_id + 1) == conn_id .. ID_SEP then
      self._struct_cache.loaded_lazy_ids[node_id] = nil
    end
  end
end

---@param branch_id string
---@return connection_id
local function branch_owner_conn_id(branch_id)
  local sep_start = tostring(branch_id):find(ID_SEP, 1, true)
  if sep_start then
    return branch_id:sub(1, sep_start - 1)
  end
  return branch_id
end

---@param branch_id string
---@param kind? string
function DrawerUI:structure_load_more(branch_id, kind)
  local conn_id = branch_owner_conn_id(branch_id)
  local state = branch_state(self, conn_id, branch_id, kind, false)
  if not state or state.loading or state.error then
    return
  end

  local raw = normalize_children(state.raw)
  if #raw <= state.built_count then
    return
  end

  state.render_limit = math.max(state.render_limit or CHILD_CHUNK_SIZE, CHILD_CHUNK_SIZE) + CHILD_CHUNK_SIZE
  local next_built = math.min(#raw, state.render_limit)
  local sentinel_id = load_more_node_id(branch_id)

  if self.filter_restore_snapshot or self.filter_input then
    state.built_count = next_built
    invalidate_render_snapshot(self)
    return
  end

  local branch_node = self.tree:get_node(branch_id)
  if not branch_node then
    state.built_count = next_built
    invalidate_render_snapshot(self)
    return
  end

  self.tree:remove_node(sentinel_id)
  for index = state.built_count + 1, next_built do
    self.tree:add_node(convert.column_nodes(branch_id, { raw[index] })[1], branch_id)
  end
  state.built_count = next_built

  if next_built < #raw then
    self.tree:add_node(convert.load_more_node(branch_id, kind or COLUMNS_KIND), branch_id)
  end

  branch_node._materialized_in_tree = true
  invalidate_render_snapshot(self)
  self.tree:render()
end

---@param handler Handler
---@param editor EditorUI
---@param result ResultUI
---@param opts? drawer_config
---@return DrawerUI
function DrawerUI:new(handler, editor, result, opts)
  opts = opts or {}

  if not handler then
    error("no Handler provided to Drawer")
  end
  if not editor then
    error("no Editor provided to Drawer")
  end
  if not result then
    error("no Result provided to Drawer")
  end

  local candies = {}
  if not opts.disable_candies then
    candies = opts.candies or {}
  end

  local current_conn = handler:get_current_connection() or {}
  local current_note = editor:get_current_note() or {}

  local o = {
    handler = handler,
    editor = editor,
    result = result,
    mappings = opts.mappings or {},
    candies = candies,
    disable_help = opts.disable_help or false,
    current_conn_id = current_conn.id,
    current_note_id = current_note.id,
    pending_generated_calls = {},
    _manual_refresh_conns = {},
    _replay_container_expansions = {},
    _struct_cache = {
      root = {},
      root_gen = {},
      root_applied = {},
      root_epoch = {},
      loaded_lazy_ids = {},
      branches = {},
    },
    filter_text = "",
    pre_filter_expansion = nil,
    pre_filter_cursor = nil,
    filter_restore_snapshot = nil,
    filter_search_model = nil,
    filter_input = nil,
    next_filter_session_id = 0,
    active_filter_session_id = nil,
    filter_debounce_ms = 0,
    pending_filter_text = nil,
    filter_timer = nil,
    cached_search_model = nil,
    cached_render_snapshot = nil,
    filter_cached_connections = 0,
    filter_total_connections = 0,
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
      bufhidden = "hide",
      buftype = "nofile",
      swapfile = false,
      filetype = "dbee",
    }, opts.buffer_options or {}),
  }
  setmetatable(o, self)
  self.__index = self

  o.bufnr = o:_create_drawer_buffer()
  common.configure_buffer_mappings(o.bufnr, o:get_actions(), opts.mappings)
  o.tree = o:create_tree(o.bufnr)

  handler:register_event_listener("current_connection_changed", function(data)
    o:on_current_connection_changed(data)
  end)

  editor:register_event_listener("current_note_changed", function(data)
    o:on_current_note_changed(data)
  end)

  handler:register_event_listener("structure_loaded", function(data)
    o:on_structure_loaded(data)
  end)

  handler:register_event_listener("structure_children_loaded", function(data)
    o:on_structure_children_loaded(data)
  end)

  handler:register_event_listener("database_selected", function(data)
    o:on_database_selected(data)
  end)

  handler:register_event_listener("call_state_changed", function(data)
    o:on_call_state_changed(data)
  end)

  return o
end

---@private
function DrawerUI:_create_drawer_buffer()
  local bufnr = common.create_blank_buffer("dbee-drawer", self.buffer_options)
  utils.create_singleton_autocmd({ "BufDelete", "BufWipeout" }, {
    buffer = bufnr,
    callback = function()
      self:prepare_close()
    end,
  })
  return bufnr
end

---@private
function DrawerUI:rebuild_buffer()
  -- _struct_cache persists across buffer rebuilds; rebuild only the UI shell.
  if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
    pcall(vim.api.nvim_buf_delete, self.bufnr, { force = true })
  end

  self.bufnr = self:_create_drawer_buffer()
  self.tree = self:create_tree(self.bufnr)
  common.configure_buffer_mappings(self.bufnr, self:get_actions(), self.mappings)
end

-- event listener for current connection change
---@private
---@param data { conn_id: connection_id }
function DrawerUI:on_current_connection_changed(data)
  if self.current_conn_id == data.conn_id then
    return
  end

  if self.filter_restore_snapshot or self.filter_input then
    self:interrupt_filter("Drawer data changed; closing filter before refresh")
  end
  invalidate_authoritative_caches(self)

  self.current_conn_id = data.conn_id
  self:refresh()
end

-- event listener for current note change
---@private
---@param data { note_id: note_id }
function DrawerUI:on_current_note_changed(data)
  if self.current_note_id == data.note_id then
    return
  end

  if self.filter_restore_snapshot or self.filter_input then
    self:interrupt_filter("Drawer data changed; closing filter before refresh")
  end
  invalidate_render_snapshot(self)

  self.current_note_id = data.note_id
  self:refresh()
end

-- event listener for async structure loading
---@private
---@param data { conn_id: string, request_id?: integer, root_epoch?: integer, caller_token?: string, structures?: DBStructure[], error?: any }
function DrawerUI:on_structure_loaded(data)
  if not data or not data.conn_id then
    return
  end

  if data.caller_token ~= "drawer" then
    return
  end

  local request_id = data.request_id or 0
  local pending_request_id = self._struct_cache.root_gen[data.conn_id]
  local applied_request_id = self._struct_cache.root_applied[data.conn_id] or 0
  local payload_epoch = normalize_root_epoch(data.root_epoch)

  if pending_request_id == nil or request_id ~= pending_request_id then
    return
  end

  if payload_epoch ~= current_root_epoch(self, data.conn_id) then
    return
  end

  if applied_request_id >= request_id then
    return
  end

  if self.filter_restore_snapshot or self.filter_input then
    self:interrupt_filter("Drawer data changed; closing filter before refresh")
  end

  self._struct_cache.root_applied[data.conn_id] = math.max(applied_request_id, request_id)
  invalidate_authoritative_caches(self)

  if self._manual_refresh_conns[data.conn_id] then
    self._manual_refresh_conns[data.conn_id] = nil
    local ok_params, conn_params = pcall(self.handler.connection_get_params, self.handler, data.conn_id)
    local name = (ok_params and conn_params and conn_params.name) or data.conn_id
    if data.error then
      local reason = tostring(data.error):sub(1, 120)
      utils.log("error", "Schema refresh failed: " .. name .. " (" .. reason .. ")")
    else
      utils.log("info", "Schema loaded: " .. name)
    end
  end

  self._struct_cache.root[data.conn_id] = {
    structures = data.structures or {},
    error = data.error,
  }

  if data.error then
    self._replay_container_expansions[data.conn_id] = nil
  end

  self:_patch_connection_subtree(data.conn_id, {
    restore_container_expansions = not data.error,
  })
end

---@private
---@param data { conn_id: string }
function DrawerUI:on_database_selected(data)
  if not (data and data.conn_id) then
    return
  end

  if self.filter_restore_snapshot or self.filter_input then
    self:interrupt_filter("DB switched; closing filter before refresh")
  end

  self:_capture_container_expansions(data.conn_id)
  self:_prune_loaded_lazy_ids(data.conn_id)
  self._struct_cache.root[data.conn_id] = nil
  self._struct_cache.branches[data.conn_id] = nil
  self._struct_cache.root_epoch[data.conn_id] = current_root_epoch(self, data.conn_id) + 1
  invalidate_authoritative_caches(self)
  self:_patch_connection_subtree(data.conn_id, { suppress_root_request = true })
  self:request_structure_reload(data.conn_id)
end

---@private
---@param data { conn_id: string, request_id?: integer, branch_id?: string, root_epoch?: integer, kind?: string, columns?: Column[], error?: any }
function DrawerUI:on_structure_children_loaded(data)
  if not data or not data.conn_id or not data.branch_id then
    return
  end

  local kind = data.kind or COLUMNS_KIND
  local state = branch_state(self, data.conn_id, data.branch_id, kind, false)
  if not state then
    return
  end

  local request_id = data.request_id or 0
  local payload_epoch = normalize_root_epoch(data.root_epoch)
  if request_id ~= state.request_gen then
    return
  end
  if payload_epoch ~= current_root_epoch(self, data.conn_id) then
    return
  end
  if (state.applied_gen or 0) >= request_id then
    return
  end

  state.applied_gen = request_id
  state.loading = false
  state.error = data.error
  state.raw = data.error and nil or (data.columns or {})
  state.render_limit = math.max(state.render_limit or CHILD_CHUNK_SIZE, CHILD_CHUNK_SIZE)
  state.built_count = math.min(#normalize_children(state.raw), state.render_limit)

  invalidate_render_snapshot(self)

  if self.filter_restore_snapshot or self.filter_input then
    return
  end

  self:_patch_branch_subtree(data.conn_id, data.branch_id, kind)
end

---@private
---@param call_id call_id
---@return string?
function DrawerUI:extract_generated_call_template(call_id)
  local bufnr = vim.api.nvim_create_buf(false, true)
  if not bufnr or bufnr == 0 then
    return nil
  end

  local ok_store = pcall(function()
    self.handler:call_store_result(call_id, "json", "buffer", {
      extra_arg = bufnr,
    })
  end)
  if not ok_store then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    return nil
  end

  local content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  if content == "" then
    return nil
  end

  local ok_decode, decoded = pcall(vim.json.decode, content)
  if not ok_decode or type(decoded) ~= "table" or #decoded == 0 then
    return nil
  end

  local first = decoded[1]
  if type(first) == "string" then
    return normalize_text(first)
  end
  if type(first) ~= "table" then
    return nil
  end

  if type(first.call_template) == "string" then
    return normalize_text(first.call_template)
  end
  if type(first.CALL_TEMPLATE) == "string" then
    return normalize_text(first.CALL_TEMPLATE)
  end

  for key, value in pairs(first) do
    if type(value) == "string" and tostring(key):lower() == "call_template" then
      return normalize_text(value)
    end
  end

  for _, value in pairs(first) do
    if type(value) == "string" then
      return normalize_text(value)
    end
  end

  return nil
end

---@private
---@param note_id note_id
---@param template string
function DrawerUI:insert_generated_template_into_note(note_id, template)
  if not template or vim.trim(template) == "" then
    return
  end

  local note = self.editor:search_note(note_id)
  if not note then
    return
  end

  if not note.bufnr or not vim.api.nvim_buf_is_valid(note.bufnr) then
    self.editor:set_current_note(note_id)
    note = self.editor:search_note(note_id)
  end
  if not note or not note.bufnr or not vim.api.nvim_buf_is_valid(note.bufnr) then
    return
  end

  local template_lines = vim.split(template, "\n", { plain = true })
  local buf_lines = vim.api.nvim_buf_get_lines(note.bufnr, 0, -1, false)
  local is_empty = #buf_lines == 0 or (#buf_lines == 1 and buf_lines[1] == "")

  if is_empty then
    vim.api.nvim_buf_set_lines(note.bufnr, 0, -1, false, template_lines)
    return
  end

  local existing = table.concat(buf_lines, "\n")
  if existing:find(template, 1, true) then
    return
  end

  local to_append = {}
  if buf_lines[#buf_lines] ~= "" then
    table.insert(to_append, "")
  end
  for _, line in ipairs(template_lines) do
    table.insert(to_append, line)
  end

  vim.api.nvim_buf_set_lines(note.bufnr, -1, -1, false, to_append)
end

-- event listener for call completion (used by Generate Call insertion)
---@private
---@param data { call: CallDetails }?
function DrawerUI:on_call_state_changed(data)
  if not data or not data.call or not data.call.id then
    return
  end

  local pending = self.pending_generated_calls[data.call.id]
  if not pending then
    return
  end

  local state = data.call.state
  if state == "executing" or state == "retrieving" then
    return
  end

  self.pending_generated_calls[data.call.id] = nil
  if state ~= "archived" then
    return
  end

  local template = self:extract_generated_call_template(data.call.id)
  if not template or vim.trim(template) == "" then
    template = pending.fallback_template
  end

  self:insert_generated_template_into_note(pending.note_id, template)
end

---@private
---@param bufnr integer
---@return NuiTree tree
function DrawerUI:create_tree(bufnr)
  return NuiTree {
    bufnr = bufnr,
    prepare_node = function(node)
      local line = NuiLine()

      if node.type == "separator" then
        return line
      end

      line:append(string.rep("  ", node:get_depth() - 1))

      if node:has_children() or node.lazy_children then
        local candy = self.candies["node_closed"] or { icon = ">", icon_highlight = "NonText" }
        if node:is_expanded() then
          candy = self.candies["node_expanded"] or { icon = "v", icon_highlight = "NonText" }
        end
        line:append(candy.icon .. " ", candy.icon_highlight)
      else
        line:append("  ")
      end

      local candy
      if not node.type or node.type == "" then
        if node:has_children() then
          candy = self.candies["none_dir"]
        else
          candy = self.candies["none"]
        end
      else
        candy = self.candies[node.type] or {}
      end
      candy = candy or {}

      if candy.icon then
        line:append(" " .. candy.icon .. " ", candy.icon_highlight)
      end

      if node.id == self.current_conn_id or self.current_note_id == node.id then
        line:append(string.gsub(node.name, "\n", " "), candy.icon_highlight)
      else
        line:append(string.gsub(node.name, "\n", " "), candy.text_highlight)
      end

      return line
    end,
    get_node_id = function(node)
      if node.id then
        return node.id
      end
      return tostring(math.random())
    end,
  }
end

---@private
---@return boolean ok
---@return string? error_message
function DrawerUI:capture_filter_snapshot()
  if not self.cached_search_model then
    local search_model, coverage = drawer_model.build_search_model(self.handler, self._struct_cache)
    self.cached_search_model = {
      nodes = search_model,
      coverage = coverage,
    }
  end

  local coverage = self.cached_search_model.coverage
  if coverage.ready_connections == 0 then
    return false, "No cached connections available for filter"
  end

  self.filter_cached_connections = coverage.ready_connections
  self.filter_total_connections = coverage.total_connections

  if not self.cached_render_snapshot then
    self.cached_render_snapshot = snapshot_rendered_tree(self, self.tree)
  end

  self.filter_restore_snapshot = clone_rendered_snapshot(self.cached_render_snapshot)
  self.filter_search_model = self.cached_search_model.nodes
  return true, nil
end

---@private
---@return integer
function DrawerUI:begin_filter_session()
  self.next_filter_session_id = self.next_filter_session_id + 1
  self.active_filter_session_id = self.next_filter_session_id
  return self.active_filter_session_id
end

---@private
---@param conn_id string
---@return integer request_id
function DrawerUI:request_structure_reload(conn_id)
  if root_request_pending(self, conn_id) then
    return self._struct_cache.root_gen[conn_id]
  end

  local applied_request_id = self._struct_cache.root_applied[conn_id] or 0
  local requested_request_id = self._struct_cache.root_gen[conn_id] or 0
  self._struct_cache.root_gen[conn_id] = math.max(requested_request_id, applied_request_id) + 1
  local request_id = self._struct_cache.root_gen[conn_id]
  self.handler:connection_get_structure_async(conn_id, request_id, current_root_epoch(self, conn_id), "drawer")
  return request_id
end

---@private
function DrawerUI:cancel_pending_filter_apply()
  if self.filter_timer then
    self.filter_timer:stop()
  end
  self.pending_filter_text = nil
end

---@private
---@param session_id integer
---@param filter_text string
function DrawerUI:schedule_filter_apply(session_id, filter_text)
  if session_id ~= self.active_filter_session_id then
    return
  end

  if self.filter_debounce_ms <= 0 then
    self:apply_filter(filter_text)
    return
  end

  if not self.filter_timer then
    self.filter_timer = vim.loop.new_timer()
  end

  self.pending_filter_text = filter_text
  self.filter_timer:stop()
  self.filter_timer:start(self.filter_debounce_ms, 0, vim.schedule_wrap(function()
    local pending = self.pending_filter_text
    self.pending_filter_text = nil
    if pending == nil then
      return
    end
    if session_id ~= self.active_filter_session_id then
      return
    end
    self:apply_filter(pending)
  end))
end

---@private
---@param reason string
function DrawerUI:interrupt_filter(reason)
  if not self.filter_restore_snapshot and not self.filter_input then
    return
  end

  -- CONTRACT: self.active_filter_session_id = nil MUST happen before input:unmount()
  -- so any scheduled on_close/on_submit callbacks see an invalidated session and no-op.
  self.active_filter_session_id = nil
  self:cancel_pending_filter_apply()

  local input = self.filter_input
  if input and type(input.unmount) == "function" then
    input:unmount()
  end

  clear_filter_state(self)
  utils.log("warn", reason)
end

---@private
---@param snapshot? DrawerRenderSnapshotNode[]
---@param expansion_state? table<string, boolean>
---@param cursor? integer[]
function DrawerUI:render_restore_snapshot(snapshot, expansion_state, cursor)
  snapshot = snapshot or self.filter_restore_snapshot
  expansion_state = expansion_state or self.pre_filter_expansion
  cursor = cursor or self.pre_filter_cursor

  self._struct_cache.loaded_lazy_ids = collect_loaded_lazy_ids(snapshot)
  self.tree:set_nodes(snapshot_to_tree_nodes(snapshot or {}))
  local unresolved = restore_expansion_state(self, expansion_state)
  self.tree:render()

  if cursor and self.winid and vim.api.nvim_win_is_valid(self.winid) then
    pcall(vim.api.nvim_win_set_cursor, self.winid, cursor)
  end

  if next(unresolved) ~= nil then
    utils.log("warn", "Drawer restore skipped unresolved expansion ids after snapshot replay")
  end
end

---@private
---@param filter_text string
function DrawerUI:apply_filter(filter_text)
  -- ZERO-RPC CONTRACT SCOPE: this method covers typing only.
  -- NEVER call convert.handler_nodes(), convert.editor_nodes(), refresh(),
  -- connection_get_structure_async(), or connection_get_columns() from here.
  if not self.filter_search_model then
    return
  end

  if not filter_text or filter_text == "" then
    self:render_restore_snapshot()
    return
  end

  local pattern = string.lower(filter_text)
  local filtered = filter_nodes_recursive(self, self.filter_search_model, pattern)
  self.tree:set_nodes(filtered)
  self.tree:render()
end

---@private
function DrawerUI:prepare_close()
  -- CONTRACT: self.active_filter_session_id = nil MUST happen before input:unmount()
  -- so any scheduled on_close/on_submit callbacks see an invalidated session and no-op.
  self.active_filter_session_id = nil
  self:cancel_pending_filter_apply()

  local input = self.filter_input
  if input and type(input.unmount) == "function" then
    input:unmount()
  end

  clear_filter_state(self)
  self.winid = nil
end

---@private
---@return table<string, fun()>
function DrawerUI:get_actions()
  local function collapse_node(node)
    if node:collapse() then
      self.tree:render()
    end
  end

  local function expand_node(node)
    if not node:is_expanded() and type(node.lazy_children) == "function" and not node._materialized_in_tree then
      local children = node.lazy_children()
      mark_lazy_loaded(self, node:get_id())
      self.tree:set_nodes(children, node.id)
      node._materialized_in_tree = true
    end

    node:expand()
    self.tree:render()
  end

  local function perform_action(action)
    if type(action) ~= "function" then
      return
    end

    action(function()
      refresh_filter_safe(self, "Drawer action changed data; closing filter before refresh")()
    end, function(opts)
      opts = opts or {}
      menu.select {
        relative_winid = self.winid,
        title = opts.title or "",
        mappings = self.mappings,
        items = opts.items or {},
        on_confirm = opts.on_confirm,
        on_yank = opts.on_yank,
      }
    end, function(opts)
      menu.input {
        relative_winid = self.winid,
        title = opts.title or "",
        mappings = self.mappings,
        default_value = opts.default or "",
        on_confirm = opts.on_confirm,
      }
    end)
  end

  local function move_tree_selection(delta)
    if not self.winid or not vim.api.nvim_win_is_valid(self.winid) then
      return
    end
    local row, col = unpack(vim.api.nvim_win_get_cursor(self.winid))
    local max_row = vim.api.nvim_buf_line_count(self.bufnr)
    local target = math.max(1, math.min(max_row, row + delta))
    pcall(vim.api.nvim_win_set_cursor, self.winid, { target, col })
  end

  local function forwardable_mapping_key_for(action_name)
    for _, mapping in ipairs(self.mappings or {}) do
      if mapping.action == action_name and mapping.mode == "n" then
        return mapping.key
      end
    end
  end

  local function maybe_add_forwarded(map, key, fn)
    if not is_single_prompt_safe_key(key) then
      return
    end

    local normalized = normalize_mapping_lhs(key)
    if RESERVED_FILTER_KEYS[normalized] then
      return
    end

    map[normalized] = fn
  end

  return {
    refresh = function()
      local node = self.tree:get_node() --[[@as DrawerUINode]]
      if not node then
        return
      end

      local conn_id = resolve_connection_ancestor(self.tree, node)
      if not conn_id then
        utils.log("warn", "select a connection row to reload")
        return
      end

      if self.filter_restore_snapshot or self.filter_input then
        self:interrupt_filter("Drawer refresh requested; closing filter before rebuild")
      end

      self._manual_refresh_conns = { [conn_id] = true }
      self:_capture_container_expansions(conn_id)
      self:_prune_loaded_lazy_ids(conn_id)
      self._struct_cache.root[conn_id] = nil
      self._struct_cache.branches[conn_id] = nil
      self._struct_cache.root_epoch[conn_id] = current_root_epoch(self, conn_id) + 1
      invalidate_authoritative_caches(self)
      self:_patch_connection_subtree(conn_id, { suppress_root_request = true })
      self:request_structure_reload(conn_id)
    end,
    action_1 = function()
      local node = self.tree:get_node() --[[@as DrawerUINode]]
      if not node then
        return
      end
      if node.structure_load_more then
        self:structure_load_more(node.structure_load_more.branch_id, node.structure_load_more.kind)
        return
      end
      perform_action(node.action_1)
    end,
    action_2 = function()
      local node = self.tree:get_node() --[[@as DrawerUINode]]
      if not node then
        return
      end
      perform_action(node.action_2)
    end,
    action_3 = function()
      local node = self.tree:get_node() --[[@as DrawerUINode]]
      if not node then
        return
      end
      perform_action(node.action_3)
    end,
    collapse = function()
      local node = self.tree:get_node()
      if not node then
        return
      end
      self.cached_render_snapshot = nil
      collapse_node(node)
    end,
    expand = function()
      local node = self.tree:get_node()
      if not node then
        return
      end
      self.cached_render_snapshot = nil
      if self.filter_restore_snapshot or self.filter_input then
        expand_node_filter_safe(self, node)
        return
      end
      expand_node(node)
    end,
    toggle = function()
      local node = self.tree:get_node()
      if not node then
        return
      end
      self.cached_render_snapshot = nil
      if node:is_expanded() then
        collapse_node(node)
      else
        if self.filter_restore_snapshot or self.filter_input then
          expand_node_filter_safe(self, node)
          return
        end
        expand_node(node)
      end
    end,
    generate_call = function()
      local node = self.tree:get_node()
      if not node then
        return
      end

      if node.type ~= "procedure" and node.type ~= "function" then
        return
      end

      local conn = self.handler:get_current_connection()
      if not conn then
        return
      end

      local helpers = self.handler:connection_get_helpers(conn.id, {
        table = node.name,
        schema = node.schema,
        materialization = node.type,
      })

      local gen_call_query = helpers["Generate Call"]
      if not gen_call_query then
        return
      end

      local note_name = "call_" .. node.name .. ".sql"
      local namespace_id = tostring(conn.id)
      local existing_notes = self.editor:namespace_get_notes(namespace_id)
      local found_id = nil
      for _, n in ipairs(existing_notes) do
        if n.name == note_name then
          found_id = n.id
          break
        end
      end

      local note_id = found_id
      if not note_id then
        note_id = self.editor:namespace_create_note(namespace_id, note_name)
      end

      self.editor:set_current_note(note_id)
      self:refresh()

      local call = self.handler:connection_execute(conn.id, gen_call_query)
      self.result:set_call(call)
      self.pending_generated_calls[call.id] = {
        note_id = note_id,
        fallback_template = default_call_template(node.schema, node.name),
      }

      if call.state == "archived" then
        self:on_call_state_changed({ call = call })
      end
    end,
    yank_name = function()
      local node = self.tree:get_node() --[[@as DrawerUINode]]
      if not node then
        return
      end

      local yankable_types = {
        table = true,
        view = true,
        procedure = true,
        ["function"] = true,
        column = true,
      }
      if not yankable_types[node.type] then
        utils.log("warn", "Nothing to copy")
        return
      end

      local qualified_name
      if node.type == "column" then
        local parent = self.tree:get_node(node:get_parent_id())
        if not parent or not parent.name then
          utils.log("warn", "Nothing to copy")
          return
        end
        local col_name = node.raw_name or node.name:match("^(.-)%s+%[") or node.name
        if not parent.schema or parent.schema == "" then
          utils.log("warn", "Nothing to copy (schema unavailable)")
          return
        end
        qualified_name = parent.schema .. "." .. parent.name .. "." .. col_name
      else
        if not node.schema or node.schema == "" then
          utils.log("warn", "Nothing to copy (schema unavailable)")
          return
        end
        qualified_name = node.schema .. "." .. node.name
      end

      local ok, err = pcall(vim.fn.setreg, '"', qualified_name)
      if not ok then
        utils.log("error", "Yank failed: " .. tostring(err))
        return
      end
      pcall(vim.fn.setreg, "+", qualified_name)
      local ok_get_clip, clip_value = pcall(vim.fn.getreg, "+")
      local clip_ok = ok_get_clip and clip_value == qualified_name
      local msg = "Copied: " .. qualified_name
      if not clip_ok then
        msg = msg .. " (clipboard unavailable)"
      end
      utils.log("info", msg)
    end,
    focus_editor = function()
      require("dbee").focus_pane("editor")
    end,
    focus_result = function()
      require("dbee").focus_pane("result")
    end,
    focus_drawer = function()
      require("dbee").focus_pane("drawer")
    end,
    focus_call_log = function()
      require("dbee").focus_pane("call_log")
    end,
    filter = function()
      if not self.winid or not vim.api.nvim_win_is_valid(self.winid) then
        return
      end

      if self.filter_input then
        return
      end

      self.pre_filter_expansion = expansion.get(self.tree)
      self.pre_filter_cursor = vim.api.nvim_win_get_cursor(self.winid)
      self.filter_text = ""

      local ok_snapshot, snapshot_err = self:capture_filter_snapshot()
      if not ok_snapshot then
        utils.log("warn", snapshot_err)
        self.pre_filter_expansion = nil
        self.pre_filter_cursor = nil
        return
      end

      local session_id = self:begin_filter_session()
      local coverage_label = string.format("%d of %d connections cached", self.filter_cached_connections, self.filter_total_connections)

      self.filter_input = menu.filter({
        relative_winid = self.winid,
        coverage_label = coverage_label,
        forward_insert = {
          ["<Up>"] = function()
            move_tree_selection(-1)
          end,
          ["<Down>"] = function()
            move_tree_selection(1)
          end,
          ["<Tab>"] = function()
            local node = self.tree:get_node()
            if node then
              self.cached_render_snapshot = nil
              expand_node_filter_safe(self, node)
            end
          end,
          ["<S-Tab>"] = function()
            local node = self.tree:get_node()
            if node and node.is_expanded and node:is_expanded() then
              self.cached_render_snapshot = nil
              node:collapse()
              self.tree:render()
            end
          end,
        },
        forward_normal = (function()
          local map = {
            [normalize_mapping_lhs("j")] = function()
              move_tree_selection(1)
            end,
            [normalize_mapping_lhs("k")] = function()
              move_tree_selection(-1)
            end,
            [normalize_mapping_lhs("<Up>")] = function()
              move_tree_selection(-1)
            end,
            [normalize_mapping_lhs("<Down>")] = function()
              move_tree_selection(1)
            end,
            [normalize_mapping_lhs("<C-y>")] = function()
              local node = self.tree:get_node()
              if node then
                if node.structure_load_more then
                  self:structure_load_more(node.structure_load_more.branch_id, node.structure_load_more.kind)
                  return
                end
                perform_action(node.action_1)
              end
            end,
          }

          maybe_add_forwarded(map, forwardable_mapping_key_for("toggle"), function()
            local node = self.tree:get_node()
            if not node then
              return
            end
            self.cached_render_snapshot = nil
            if node:is_expanded() then
              collapse_node(node)
            else
              expand_node_filter_safe(self, node)
            end
          end)
          maybe_add_forwarded(map, forwardable_mapping_key_for("expand"), function()
            local node = self.tree:get_node()
            if not node then
              return
            end
            self.cached_render_snapshot = nil
            expand_node_filter_safe(self, node)
          end)
          maybe_add_forwarded(map, forwardable_mapping_key_for("collapse"), function()
            local node = self.tree:get_node()
            if not node then
              return
            end
            self.cached_render_snapshot = nil
            collapse_node(node)
          end)
          maybe_add_forwarded(map, forwardable_mapping_key_for("action_2"), function()
            local node = self.tree:get_node()
            if node then
              perform_action(node.action_2)
            end
          end)
          maybe_add_forwarded(map, forwardable_mapping_key_for("action_3"), function()
            local node = self.tree:get_node()
            if node then
              perform_action(node.action_3)
            end
          end)

          return map
        end)(),
        on_change = function(value)
          if session_id ~= self.active_filter_session_id then
            return
          end
          self.filter_text = value or ""
          self:schedule_filter_apply(session_id, self.filter_text)
        end,
        on_submit = function()
          if session_id ~= self.active_filter_session_id then
            return
          end

          local snapshot = self.filter_restore_snapshot
          local expansion_state = self.pre_filter_expansion
          local restore_cursor = self.pre_filter_cursor
          self.active_filter_session_id = nil
          self:cancel_pending_filter_apply()

          local selected_node = self.tree:get_node()
          local selected_id = selected_node and selected_node:get_id()
          local selected_path = selected_path_ids(self.tree, selected_node)

          clear_filter_state(self)
          self:render_restore_snapshot(snapshot, expansion_state, restore_cursor)

          if selected_id then
            self.cached_render_snapshot = nil
            local exact, resolved_id = materialize_selected_path(self, self.tree, selected_path)
            self.tree:render()

            local target_id = exact and selected_id or resolved_id
            if target_id and self.winid and vim.api.nvim_win_is_valid(self.winid) then
              local row = visible_node_row(self.tree, target_id)
              if row then
                pcall(vim.api.nvim_win_set_cursor, self.winid, { row, 0 })
              end
            end

            if selected_id and not exact then
              utils.log("warn", "Drawer filter submit fell back to the nearest restored ancestor")
            end
          end
        end,
        on_close = function()
          if session_id ~= self.active_filter_session_id then
            return
          end

          local snapshot = self.filter_restore_snapshot
          local expansion_state = self.pre_filter_expansion
          local restore_cursor = self.pre_filter_cursor
          self.active_filter_session_id = nil
          self:cancel_pending_filter_apply()
          clear_filter_state(self)
          self:render_restore_snapshot(snapshot, expansion_state, restore_cursor)
        end,
      })
    end,
  }
end

---Triggers an in-built action.
---@param action string
function DrawerUI:do_action(action)
  local act = self:get_actions()[action]
  if not act then
    error("unknown action: " .. action)
  end
  act()
end

---Refreshes the tree.
function DrawerUI:refresh()
  if self.filter_restore_snapshot or self.filter_input then
    self:interrupt_filter("Drawer refresh requested; closing filter before rebuild")
  end

  invalidate_render_snapshot(self)

  if not self.bufnr or not vim.api.nvim_buf_is_valid(self.bufnr) then
    self:rebuild_buffer()
  end

  local exp = expansion.get(self.tree)
  local current_conn_id = (self.handler:get_current_connection() or {}).id
  self.current_conn_id = current_conn_id

  local render_model, coverage = drawer_model.build_tree_from_struct_cache(
    self.handler,
    self.editor,
    self.result,
    self._struct_cache,
    current_conn_id,
    function()
      self:refresh()
    end,
    {
      disable_help = self.disable_help,
      connection_children = function(conn)
        return build_connection_children(self, conn)
      end,
    }
  )
  self.filter_total_connections = coverage.total_connections

  local function hydrate(model_nodes)
    local out = {}
    for _, model_node in ipairs(model_nodes) do
      local children = model_node.children and #model_node.children > 0 and hydrate(model_node.children) or nil
      local node = NuiTree.Node({
        id = model_node.id,
        name = model_node.name,
        type = model_node.type,
        schema = model_node.schema,
        raw_name = model_node.raw_name,
        action_1 = model_node.action_1,
        action_2 = model_node.action_2,
        action_3 = model_node.action_3,
        lazy_children = children == nil and model_node.lazy_children or nil,
      }, children)

      if children and #children > 0 then
        node._materialized_in_tree = true
      end

      if model_node.expanded then
        node:expand()
      end

      table.insert(out, node)
    end
    return out
  end

  local nodes = {}
  vim.list_extend(nodes, convert.editor_nodes(self.editor, current_conn_id, function()
    self:refresh()
  end))
  table.insert(nodes, convert.separator_node())
  vim.list_extend(nodes, hydrate(render_model))

  if not self.disable_help then
    table.insert(nodes, convert.separator_node())
    table.insert(nodes, convert.help_node(self.mappings))
  end

  self.tree:set_nodes(nodes)
  restore_expansion_state(self, exp)
  self.tree:render()
end

---@param winid integer
function DrawerUI:show(winid)
  if not self.bufnr or not vim.api.nvim_buf_is_valid(self.bufnr) then
    self:rebuild_buffer()
  end

  self.winid = winid
  vim.api.nvim_win_set_buf(self.winid, self.bufnr)
  common.configure_window_options(self.winid, self.window_options)
  self:refresh()
end

return DrawerUI
