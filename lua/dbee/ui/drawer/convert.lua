local utils = require("dbee.utils")
local NuiTree = require("nui.tree")

local M = {}

local ID_SEP = "\x1f"
local SEGMENT_SEP = ":"
local LOAD_MORE_SUFFIX = ID_SEP .. "__load_more__"

---@param value string?
---@return string
local function escape_node_id_part(value)
  return (tostring(value or ""):gsub("[%z\1-\31%%:]", function(char)
    return string.format("%%%02X", string.byte(char))
  end))
end

---@param parts string[]
---@return string
local function encode_node_segment(parts)
  local encoded = {}
  for _, part in ipairs(parts) do
    table.insert(encoded, escape_node_id_part(part))
  end
  return table.concat(encoded, SEGMENT_SEP)
end

---@param parent_id string
---@param struct { name: string, schema?: string, type: string }
---@return string
function M.structure_node_id(parent_id, struct)
  return parent_id .. ID_SEP .. encode_node_segment({
    struct.type,
    struct.name,
    struct.schema or "",
  })
end

---@param parent_id string
---@param column Column
---@return string
function M.column_node_id(parent_id, column)
  return parent_id .. ID_SEP .. encode_node_segment({
    "column",
    column.type,
    column.name,
  })
end

---@param parent_id string
---@param columns Column[]
---@return DrawerUINode[]
local function column_nodes(parent_id, columns)
  ---@type DrawerUINode[]
  local nodes = {}

  for _, column in ipairs(columns) do
    table.insert(
      nodes,
      NuiTree.Node {
        id = M.column_node_id(parent_id, column),
        name = column.name .. "   [" .. column.type .. "]",
        type = "column",
        raw_name = column.name,
      }
    )
  end

  return nodes
end

M.column_nodes = column_nodes
M.ID_SEP = ID_SEP
M.LOAD_MORE_SUFFIX = LOAD_MORE_SUFFIX

---@param parent_id string
---@return string
function M.load_more_node_id(parent_id)
  return parent_id .. LOAD_MORE_SUFFIX
end

---@param id string
---@param name string
---@return DrawerUINode
function M.message_node(id, name)
  return NuiTree.Node({
    id = id,
    name = name,
    type = "",
  }) --[[@as DrawerUINode]]
end

---@param parent_id string
---@return DrawerUINode
function M.loading_node(parent_id)
  return M.message_node(parent_id .. ID_SEP .. "__loading__", "loading...")
end

---@param parent_id string
---@param err any
---@return DrawerUINode
function M.error_node(parent_id, err)
  return M.message_node(parent_id .. ID_SEP .. "__error__", tostring(err))
end

---@param branch_id string
---@param kind string
---@return DrawerUINode
function M.load_more_node(branch_id, kind)
  return NuiTree.Node({
    id = M.load_more_node_id(branch_id),
    name = "Load more...",
    type = "load_more",
    structure_load_more = {
      branch_id = branch_id,
      kind = kind,
    },
  }) --[[@as DrawerUINode]]
end

---@param node DrawerUINode|table
---@param handler Handler
---@param result ResultUI
---@param conn_id string
---@param struct { id: string, name: string, schema?: string, type: string }
---@param lazy_children_factory? fun(): DrawerUINode[]
--- INVARIANT: struct.type MUST be passed through as the materialization.
function M.decorate_structure_node(node, handler, result, conn_id, struct, lazy_children_factory)
  if struct.type ~= "table" and struct.type ~= "view" and struct.type ~= "procedure" and struct.type ~= "function" then
    if type(lazy_children_factory) == "function" then
      node.lazy_children = lazy_children_factory
    end
    return node
  end

  local table_opts = {
    table = struct.name,
    schema = struct.schema,
    materialization = struct.type,
  }

  node.action_1 = function(cb, select)
    local helpers = handler:connection_get_helpers(conn_id, table_opts)
    local items = vim.tbl_keys(helpers)
    table.sort(items)

    select {
      title = "Select a Query",
      items = items,
      on_confirm = function(selection)
        local call = handler:connection_execute(conn_id, helpers[selection])
        result:set_call(call)
        cb()
      end,
      on_yank = function(selection)
        vim.fn.setreg(vim.v.register, helpers[selection])
      end,
    }
  end

  if type(lazy_children_factory) == "function" then
    node.lazy_children = lazy_children_factory
  elseif struct.type == "table" or struct.type == "view" then
    node.lazy_children = function()
      return column_nodes(struct.id, handler:connection_get_columns(conn_id, table_opts))
    end
  end

  return node
end

---@param node DrawerUINode|table
---@param handler Handler
---@param source_meta { id: string, name?: string, can_create?: boolean, can_update: boolean, can_delete: boolean, file?: string|nil }
---@param conn_id string
---@param opts? { open_edit_connection?: fun(source_meta: table, conn_id: string, on_done?: fun()) }
--- INVARIANT: source_meta.id MUST equal source:name().
function M.decorate_connection_node(node, handler, source_meta, conn_id, opts)
  opts = opts or {}

  node.action_1 = function(cb)
    handler:set_current_connection(conn_id)
    cb()
  end

  node.action_2 = nil
  if source_meta.can_update then
    node.action_2 = function(cb)
      if type(opts.open_edit_connection) ~= "function" then
        utils.log("warn", "Wizard-backed connection editing is unavailable")
        cb()
        return
      end

      opts.open_edit_connection(source_meta, conn_id, cb)
    end
  end

  node.action_3 = nil
  if source_meta.can_delete then
    node.action_3 = function(cb, select)
      select {
        title = "Confirm Deletion",
        items = { "Yes", "No" },
        on_confirm = function(selection)
          if selection == "Yes" then
            local ok, err = pcall(handler.source_remove_connection, handler, source_meta.id, conn_id)
            if not ok then
              utils.log("error", "Failed to delete connection: " .. tostring(err))
            end
          end
          cb()
        end,
      }
    end
  end

  return node
end

---@param source Source
---@param source_id string
---@return { id: string, name: string, can_create: boolean, can_update: boolean, can_delete: boolean, file: string|nil }
local function build_source_meta(source, source_id)
  local source_file = nil
  if type(source.file) == "function" then
    local ok, file_or_err = pcall(source.file, source)
    if ok then
      source_file = file_or_err
    else
      utils.log("warn", "Failed reading source file metadata: " .. tostring(file_or_err))
    end
  end

  return {
    id = source_id,
    name = source_id,
    can_create = type(source.create) == "function",
    can_update = type(source.update) == "function",
    can_delete = type(source.delete) == "function",
    file = source_file,
  }
end

---@param conn ConnectionParams
---@param source_meta { name?: string, id: string }
---@param show_source_badge boolean
---@return string
local function connection_display_name(conn, source_meta, show_source_badge)
  if not show_source_badge then
    return tostring(conn.name or conn.id)
  end
  local source_name = source_meta.name or source_meta.id
  return string.format("%s  [%s]", tostring(conn.name or conn.id), tostring(source_name or ""))
end

---@param handler Handler
---@param conn ConnectionParams
---@param result ResultUI
---@param structure_cache table
---@param opts? { connection_children?: fun(conn: ConnectionParams, source_meta: table): DrawerUINode[] }
---@param source_meta? table
---@return DrawerUINode[]
local function connection_nodes(handler, conn, result, structure_cache, opts, source_meta)
  if opts and type(opts.connection_children) == "function" then
    return opts.connection_children(conn, source_meta)
  end

  ---@param structs DBStructure[]
  ---@param parent_id string
  ---@return DrawerUINode[]
  local function to_tree_nodes(structs, parent_id)
    if not structs or structs == vim.NIL then
      return {}
    end

    table.sort(structs, function(k1, k2)
      return k1.type .. k1.name < k2.type .. k2.name
    end)

    ---@type DrawerUINode[]
    local nodes = {}

    for _, struct in ipairs(structs) do
      local node_id = M.structure_node_id(parent_id or "", struct)
      local node = NuiTree.Node({
        id = node_id,
        name = struct.name,
        schema = struct.schema,
        type = struct.type,
      }, to_tree_nodes(struct.children, node_id)) --[[@as DrawerUINode]]

      M.decorate_structure_node(node, handler, result, conn.id, {
        id = node_id,
        name = struct.name,
        schema = struct.schema,
        type = struct.type,
      })

      table.insert(nodes, node)
    end

    return nodes
  end

  -- check cache for async-loaded structure
  local parent_id = conn.id
  local cached = structure_cache and structure_cache.root and structure_cache.root[conn.id] or structure_cache and structure_cache[conn.id]
  local structs
  if cached then
    if cached.error then
      return { M.error_node(parent_id, cached.error) }
    end
    structs = cached.structures or {}
  else
    -- trigger async load and show loading indicator
    handler:connection_get_structure_async(conn.id)
    return { M.loading_node(parent_id) }
  end

  -- recursively parse structure to drawer nodes
  local nodes = to_tree_nodes(structs, conn.id)

  -- database switching
  local current_db, available_dbs = handler:connection_list_databases(conn.id)
  if current_db ~= "" and #available_dbs > 0 then
    local ly = NuiTree.Node {
      id = conn.id .. "_database_switch__",
      name = current_db,
      type = "database_switch",
      action_1 = function(_, select)
        select {
          title = "Select a Database",
          items = available_dbs,
          on_confirm = function(selection)
            handler:connection_select_database(conn.id, selection)
          end,
        }
      end,
    } --[[@as DrawerUINode]]
    table.insert(nodes, 1, ly)
  end

  return nodes
end

---@param handler Handler
---@param result ResultUI
---@param structure_cache table
---@param opts? { connection_children?: fun(conn: ConnectionParams, source_meta: table): DrawerUINode[] }
---@return DrawerUINode[]
local function handler_real_nodes(handler, result, structure_cache, opts)
  ---@type DrawerUINode[]
  local nodes = {}

  local sources = handler:get_sources()
  local show_source_badge = true

  for _, source in ipairs(sources) do
    local source_id = source:name()
    local source_meta = build_source_meta(source, source_id)

    -- get connections of that source
    for _, conn in ipairs(handler:source_get_connections(source_id)) do
      local node = NuiTree.Node {
        id = conn.id,
        name = connection_display_name(conn, source_meta, show_source_badge),
        raw_name = conn.name,
        type = "connection",
        lazy_children = function()
          return connection_nodes(handler, conn, result, structure_cache, opts, source_meta)
        end,
      } --[[@as DrawerUINode]]

      M.decorate_connection_node(node, handler, source_meta, conn.id)

      table.insert(nodes, node)
    end
  end

  return nodes
end

---@return DrawerUINode[]
local function handler_help_nodes()
  local node = NuiTree.Node({
    id = "__handler_help_id__",
    name = "No sources :(",
    type = "",
  }, {
    NuiTree.Node {
      id = "__handler_help_id_child_1__",
      name = 'Type ":h dbee.txt"',
      type = "",
    },
    NuiTree.Node {
      id = "__handler_help_id_child_2__",
      name = "to define your first source!",
      type = "",
    },
  })

  if utils.once("handler_expand_once_helper_id") then
    node:expand()
  end

  return { node }
end

---@param handler Handler
---@param result ResultUI
---@param structure_cache table
---@param opts? { connection_children?: fun(conn: ConnectionParams, source_meta: table): DrawerUINode[] }
---@return DrawerUINode[]
function M.handler_nodes(handler, result, structure_cache, opts)
  -- in case there are no sources defined, return helper nodes
  if #handler:get_sources() < 1 then
    return handler_help_nodes()
  end
  return handler_real_nodes(handler, result, structure_cache, opts)
end

-- whitespace between nodes
---@return DrawerUINode
function M.separator_node()
  return NuiTree.Node {
    id = "__separator_node__" .. tostring(math.random()),
    name = "",
    type = "separator",
  } --[[@as DrawerUINode]]
end

---@param text string
---@return DrawerUINode
function M.header_node(text)
  return NuiTree.Node {
    id = "__header_node__" .. tostring(math.random()),
    name = text,
    type = "header",
  } --[[@as DrawerUINode]]
end

---@param mappings key_mapping[]
---@return DrawerUINode
function M.help_node(mappings)
  -- help node
  ---@type DrawerUINode[]
  local children = {}
  local edit_mapping = nil
  for _, km in ipairs(mappings) do
    if type(km.action) == "string" then
      if km.action == "edit_connection" and km.mode == "n" then
        edit_mapping = km.key
      end
      table.insert(
        children,
        NuiTree.Node {
          id = "__help_action_" .. utils.random_string(),
          name = km.action .. " = " .. km.key .. " (" .. km.mode .. ")",
          type = "",
        }
      )
    end
  end

  if edit_mapping then
    table.insert(children, NuiTree.Node {
      id = "__help_source_file_edit__",
      name = "source file = " .. edit_mapping .. " on a connection row",
      type = "",
    })
  end

  table.sort(children, function(k1, k2)
    return k1.name < k2.name
  end)

  local node = NuiTree.Node({
    id = "__help_node__",
    name = "help",
    type = "help",
  }, children) --[[@as DrawerUINode]]

  if utils.once("help_expand_once_id") then
    node:expand()
  end

  return node
end

---@param bufnr integer
---@param refresh fun() function that refreshes the tree
---@return string suffix
local function modified_suffix(bufnr, refresh)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return ""
  end

  local suffix = ""
  if vim.api.nvim_get_option_value("modified", { buf = bufnr }) then
    suffix = " ●"
  end

  utils.create_singleton_autocmd({ "BufModifiedSet" }, {
    buffer = bufnr,
    callback = refresh,
  })

  return suffix
end

---@param editor EditorUI
---@param namespace namespace_id
---@param refresh fun() function that refreshes the tree
---@return DrawerUINode[]
local function editor_namespace_nodes(editor, namespace, refresh)
  ---@type DrawerUINode[]
  local nodes = {}

  table.insert(
    nodes,
    NuiTree.Node {
      id = "__new_" .. namespace .. "_note__",
      name = "new",
      type = "add",
      action_1 = function(cb, _, input)
        input {
          title = "Enter Note Name",
          default = "note_" .. utils.random_string() .. ".sql",
          on_confirm = function(value)
            if not value or value == "" then
              return
            end
            local id = editor:namespace_create_note(namespace, value)
            editor:set_current_note(id)
            cb()
          end,
        }
      end,
    } --[[@as DrawerUINode]]
  )

  -- global notes
  for _, note in ipairs(editor:namespace_get_notes(namespace)) do
    local node = NuiTree.Node {
      id = note.id,
      name = note.name .. modified_suffix(note.bufnr, refresh),
      type = "note",
      action_1 = function(cb)
        editor:set_current_note(note.id)
        cb()
      end,
      action_2 = function(cb, _, input)
        input {
          title = "New Name",
          default = note.name,
          on_confirm = function(value)
            if not value or value == "" then
              return
            end
            editor:note_rename(note.id, value)
            cb()
          end,
        }
      end,
      action_3 = function(cb, select)
        select {
          title = "Confirm Deletion",
          items = { "Yes", "No" },
          on_confirm = function(selection)
            if selection == "Yes" then
              editor:namespace_remove_note(namespace, note.id)
            end
            cb()
          end,
        }
      end,
    } --[[@as DrawerUINode]]

    table.insert(nodes, node)
  end

  return nodes
end

---@param editor EditorUI
---@param current_connection_id connection_id
---@param refresh fun() function that refreshes the tree
---@return DrawerUINode[]
function M.editor_nodes(editor, current_connection_id, refresh)
  local nodes = {
    NuiTree.Node({
      id = "__master_note_global__",
      name = "global notes",
      type = "note",
    }, editor_namespace_nodes(editor, "global", refresh)),
  }

  if utils.once("editor_global_expand") then
    nodes[1]:expand()
  end

  if current_connection_id then
    table.insert(
      nodes,
      NuiTree.Node({
        id = "__master_note_local__",
        name = "local notes",
        type = "note",
      }, editor_namespace_nodes(editor, current_connection_id, refresh))
    )
    if utils.once("editor_local_expand") then
      nodes[2]:expand()
    end
  end

  return nodes
end

return M
