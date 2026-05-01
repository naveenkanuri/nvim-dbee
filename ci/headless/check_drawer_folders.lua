-- Headless validation for Phase 15 drawer folder grouping.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=$(pwd)" \
--   -c "luafile ci/headless/check_drawer_folders.lua"

local Harness = dofile(vim.fn.getcwd() .. "/ci/headless/phase7_harness.lua")

local function fail(msg)
  print("FOLDER15_DRAWER_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local function assert_true(label, value)
  if not value then
    fail(label .. ": expected truthy, got " .. vim.inspect(value))
  end
end

local function assert_eq(label, actual, expected)
  if actual ~= expected then
    fail(label .. ": expected " .. vim.inspect(expected) .. " got " .. vim.inspect(actual))
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

local function reset_drawer_modules()
  Harness.reset_modules({
    "dbee.ui.drawer",
    "dbee.ui.drawer.convert",
    "dbee.ui.drawer.model",
    "dbee.ui.drawer.expansion",
    "dbee.ui.connection_wizard",
    "dbee.reconnect",
  })
end

local function make_source(opts)
  opts = opts or {}
  local source = {
    _id = opts.id or "source-main",
    _file = opts.file or "/tmp/source-main.json",
    _conns = vim.deepcopy(opts.conns or {
      { id = "conn-alpha", name = "Alpha", type = "postgres", url = "postgres://alpha" },
      { id = "conn-beta", name = "Beta", type = "postgres", url = "postgres://beta" },
      { id = "conn-gamma", name = "Gamma", type = "postgres", url = "postgres://gamma" },
    }),
    _folders = vim.deepcopy(opts.folders or {
      { id = "folder-prod", name = "Production", connection_ids = { "conn-alpha", "conn-beta" } },
    }),
    folder_support = opts.folder_support ~= false,
    fail_folder_mutation = false,
  }

  function source:name()
    return self._id
  end

  function source:file()
    return self._file
  end

  function source:load()
    return vim.deepcopy(self._conns)
  end

  function source:create()
    error("not used")
  end

  function source:update()
    error("not used")
  end

  function source:delete()
    error("not used")
  end

  if source.folder_support then
    function source:supports_folders()
      return true
    end
  end

  return source
end

local function remove_from_all_folders(source, conn_id)
  for _, folder in ipairs(source._folders or {}) do
    for index = #(folder.connection_ids or {}), 1, -1 do
      if folder.connection_ids[index] == conn_id then
        table.remove(folder.connection_ids, index)
      end
    end
  end
end

local function make_handler(source, opts)
  opts = opts or {}
  local handler = {
    sources = { [source:name()] = source },
    invalidations = {},
    listeners = {},
    mutations = {},
    call_counts = {
      source_get_connections = 0,
      source_get_folders = 0,
    },
    current_conn_id = opts.current_conn_id or "conn-alpha",
  }

  function handler:register_event_listener(event, cb)
    self.listeners[event] = cb
  end

  function handler:get_sources()
    return { source }
  end

  function handler:get_current_connection()
    for _, conn in ipairs(source._conns) do
      if conn.id == self.current_conn_id then
        return vim.deepcopy(conn)
      end
    end
    return vim.deepcopy(source._conns[1])
  end

  function handler:source_get_connections(source_id)
    self.call_counts.source_get_connections = self.call_counts.source_get_connections + 1
    if source_id ~= source:name() then
      return {}
    end
    return vim.deepcopy(source._conns)
  end

  function handler:source_get_folders(source_id)
    self.call_counts.source_get_folders = self.call_counts.source_get_folders + 1
    if source_id ~= source:name() or type(source.supports_folders) ~= "function" or not source:supports_folders() then
      return {}
    end
    return vim.deepcopy(source._folders)
  end

  local function emit(reason, payload)
    payload = payload or {}
    payload.reason = reason
    handler.invalidations[#handler.invalidations + 1] = payload
  end

  function handler:source_add_folder(source_id, name)
    if source.fail_folder_mutation then
      error("folder mutation failed")
    end
    local id = "folder-" .. tostring(#source._folders + 1)
    source._folders[#source._folders + 1] = { id = id, name = name, connection_ids = {} }
    self.mutations[#self.mutations + 1] = { op = "add", source_id = source_id, name = name, folder_id = id }
    emit("folder_mutation", { source_id = source_id, folder_id = id, op = "add" })
    return id
  end

  function handler:source_rename_folder(source_id, folder_id, new_name)
    if source.fail_folder_mutation then
      error("folder mutation failed")
    end
    for _, folder in ipairs(source._folders) do
      if folder.id == folder_id then
        folder.name = new_name
      end
    end
    self.mutations[#self.mutations + 1] = { op = "rename", source_id = source_id, folder_id = folder_id, name = new_name }
    emit("folder_mutation", { source_id = source_id, folder_id = folder_id, op = "rename" })
  end

  function handler:source_remove_folder(source_id, folder_id)
    if source.fail_folder_mutation then
      error("folder mutation failed")
    end
    for index, folder in ipairs(source._folders) do
      if folder.id == folder_id then
        table.remove(source._folders, index)
        break
      end
    end
    self.mutations[#self.mutations + 1] = { op = "remove", source_id = source_id, folder_id = folder_id }
    emit("folder_mutation", { source_id = source_id, folder_id = folder_id, op = "remove" })
  end

  function handler:source_move_connection(source_id, conn_id, target_folder_id)
    if source.fail_folder_mutation then
      error("folder mutation failed")
    end
    remove_from_all_folders(source, conn_id)
    if target_folder_id then
      for _, folder in ipairs(source._folders) do
        if folder.id == target_folder_id then
          folder.connection_ids[#folder.connection_ids + 1] = conn_id
        end
      end
    end
    self.mutations[#self.mutations + 1] = {
      op = "move",
      source_id = source_id,
      conn_id = conn_id,
      target_folder_id = target_folder_id,
    }
    emit("folder_mutation", { source_id = source_id, conn_id = conn_id, target_folder_id = target_folder_id, op = "move" })
  end

  function handler:set_current_connection(conn_id)
    self.current_conn_id = conn_id
  end

  function handler:connection_get_structure_async()
    self.async_requested = true
  end

  function handler:connection_list_databases()
    return "", {}
  end

  function handler:connection_get_columns()
    return {}
  end

  function handler:connection_get_helpers()
    return { Browse = "select *" }
  end

  return handler
end

local function make_editor()
  return {
    register_event_listener = function() end,
    get_current_note = function()
      return nil
    end,
    namespace_get_notes = function()
      return {}
    end,
  }
end

local function make_result()
  return {
    set_call = function() end,
  }
end

local function new_fixture(opts)
  opts = opts or {}
  reset_drawer_modules()
  local runtime = {
    prompt_calls = {},
    editor_calls = {},
    select_calls = {},
    input_calls = {},
    filter_sessions = {},
  }
  Harness.install_ui_stubs(runtime, { stub_reconnect = true })

  local source = make_source(opts.source or {})
  local handler = make_handler(source, opts.handler or {})
  if opts.bootstrap then
    local boot = opts.bootstrap
    function handler:get_connection_state_snapshot()
      return {
        current_connection = self:get_current_connection(),
        snapshot_authoritative_epoch = {},
      }
    end
    function handler:begin_connection_invalidated_bootstrap(_, listener)
      self.bootstrap_listener = listener
      return 1
    end
    function handler:drain_connection_invalidated_bootstrap()
      return { kind = "ok", events = boot.drain_events or {} }
    end
    function handler:promote_to_live()
      return { kind = "ok", events = boot.promote_events or {} }
    end
  end

  local DrawerUI = require("dbee.ui.drawer")
  local drawer = DrawerUI:new(handler, make_editor(), make_result(), {
    disable_help = true,
    mappings = {
      { key = "<CR>", mode = "n", action = "action_1" },
      { key = "a", mode = "n", action = "add_connection" },
      { key = "/", mode = "n", action = "filter" },
    },
  })
  local host_buf, winid = Harness.with_window(100, 30)
  drawer:show(winid)
  Harness.drain()

  local fixture = {
    runtime = runtime,
    source = source,
    handler = handler,
    drawer = drawer,
    host_buf = host_buf,
    winid = winid,
  }

  function fixture:cleanup()
    if self.drawer and self.drawer.bufnr and vim.api.nvim_buf_is_valid(self.drawer.bufnr) then
      pcall(vim.api.nvim_buf_delete, self.drawer.bufnr, { force = true })
    end
    Harness.close_window_and_buffer(self.host_buf, self.winid)
  end

  return fixture
end

local function find_root_node(nodes, predicate)
  for _, node in ipairs(nodes or {}) do
    if predicate(node) then
      return node
    end
  end
end

local function find_tree_node(tree, predicate)
  for _, node in pairs(tree.index or {}) do
    if predicate(node) then
      return node
    end
  end
end

local function find_snapshot_node(nodes, predicate)
  for _, node in ipairs(nodes or {}) do
    if predicate(node) then
      return node
    end
    local child = find_snapshot_node(node.children, predicate)
    if child then
      return child
    end
  end
end

local function assert_has_action(actions, id)
  assert_true("action_present_" .. id, type(actions[id]) == "function")
end

local function run_convert_contracts()
  reset_drawer_modules()
  Harness.install_ui_stubs({ prompt_calls = {}, editor_calls = {}, select_calls = {}, input_calls = {}, filter_sessions = {} }, {
    stub_reconnect = true,
  })
  local convert = require("dbee.ui.drawer.convert")
  local source = make_source()
  local handler = make_handler(source)
  local nodes = convert.handler_nodes(handler, make_result(), {}, {})

  local folder = find_root_node(nodes, function(node)
    return node.type == "folder"
  end)
  assert_true("folder node rendered", folder ~= nil)
  assert_eq("folder raw name", folder.raw_name, "Production")
  print("FOLDER15_DRAWER_FOLDER_NODE_RENDERED=true")

  local gamma = find_root_node(nodes, function(node)
    return node.type == "connection" and node.id == "conn-gamma"
  end)
  assert_true("ungrouped at root", gamma ~= nil)
  print("FOLDER15_DRAWER_UNGROUPED_AT_ROOT=true")

  local children = folder.lazy_children()
  assert_eq("folder child count", #children, 2)
  assert_eq("folder child order alpha", children[1].id, "conn-alpha")
  assert_eq("folder child order beta", children[2].id, "conn-beta")
  print("FOLDER15_DRAWER_FOLDER_LAZY_CHILDREN_OK=true")

  folder.action_2(function() end, nil, function(opts)
    opts.on_confirm("Prod Renamed")
  end)
  assert_eq("rename mutation op", handler.mutations[#handler.mutations].op, "rename")
  assert_eq("rename mutation name", handler.mutations[#handler.mutations].name, "Prod Renamed")
  print("FOLDER15_DRAWER_FOLDER_RENAME_ACTION_OK=true")

  folder.action_3(function() end, function(opts)
    opts.on_confirm("Delete (members ungrouped)")
  end)
  assert_eq("delete mutation op", handler.mutations[#handler.mutations].op, "remove")
  print("FOLDER15_DRAWER_FOLDER_DELETE_ACTION_OK=true")

  local plain_source = make_source({ folder_support = false })
  local plain_handler = make_handler(plain_source)
  local plain_nodes = convert.handler_nodes(plain_handler, make_result(), {}, {})
  assert_true("non folder direct alpha", find_root_node(plain_nodes, function(node)
    return node.type == "connection" and node.id == "conn-alpha"
  end) ~= nil)
  assert_true("non folder no folder node", find_root_node(plain_nodes, function(node)
    return node.type == "folder"
  end) == nil)
  print("FOLDER15_NON_FILESOURCE_DEGRADES_OK=true")

  local id_one = convert.folder_node_id("__root__", "source:one", "folder" .. string.char(31) .. "x")
  local id_two = convert.folder_node_id("__root__", "source", "one:folder" .. string.char(31) .. "x")
  assert_true("folder node id collision safe", id_one ~= id_two)
  assert_true("folder node id escaped", id_one:find(string.char(31) .. "folder:source%3Aone:folder%1Fx", 1, true) ~= nil)
  print("FOLDER15_FOLDER_NODE_ID_COLLISION_SAFE=true")
end

local function run_drawer_action_contracts()
  local fixture = new_fixture()
  local actions = fixture.drawer:get_actions()
  assert_has_action(actions, "add_folder")
  assert_has_action(actions, "rename_folder")
  assert_has_action(actions, "delete_folder")
  assert_has_action(actions, "move_connection_to_folder")
  print("FOLDER15_DRAWER_LEVEL_ACTIONS_PRESENT=true")

  local folder = find_tree_node(fixture.drawer.tree, function(node)
    return node.type == "folder"
  end)
  assert_true("hydrated folder exists", folder ~= nil)
  assert_eq("hydrate folder id", folder.folder_id, "folder-prod")
  assert_eq("hydrate source meta", folder.source_meta.id, "source-main")
  assert_eq("hydrate search text", folder.search_text, "Production")
  assert_true("hydrate action2", type(folder.action_2) == "function")
  assert_true("hydrate action3", type(folder.action_3) == "function")
  print("FOLDER15_HYDRATE_FOLDER_FIELDS_OK=true")

  local refresh_count = 0
  local original_refresh = fixture.drawer.refresh
  fixture.drawer.refresh = function(self)
    refresh_count = refresh_count + 1
    return original_refresh(self)
  end
  fixture.drawer:on_connection_invalidated({ reason = "folder_mutation" })
  Harness.drain()
  assert_true("folder invalidation refresh", refresh_count > 0)
  print("FOLDER15_DRAWER_INVALIDATE_REFRESH_OK=true")

  local folder_node_id = folder.id
  Harness.set_current_node(fixture.winid, fixture.drawer.tree, folder_node_id)
  actions.expand()
  local expanded_folder = fixture.drawer.tree:get_node(folder_node_id)
  assert_true("folder expanded before add", expanded_folder and expanded_folder:is_expanded())
  fixture.source._folders[#fixture.source._folders + 1] = { id = "folder-stage", name = "Staging", connection_ids = {} }
  fixture.drawer:refresh()
  local restored_folder = fixture.drawer.tree:get_node(folder_node_id)
  assert_true("folder expansion preserved", restored_folder and restored_folder:is_expanded())
  print("FOLDER15_DRAWER_FOLDER_EXPANSION_PRESERVED=true")

  local ok_snapshot, snapshot_err = fixture.drawer:capture_filter_snapshot()
  assert_true("snapshot captured: " .. tostring(snapshot_err), ok_snapshot)
  local folder_snapshot = find_snapshot_node(fixture.drawer.filter_restore_snapshot, function(node)
    return node.type == "folder" and node.folder_id == "folder-prod"
  end)
  assert_true("snapshot folder found", folder_snapshot ~= nil)
  assert_eq("snapshot source meta", folder_snapshot.source_meta.id, "source-main")
  assert_true("snapshot folder action2", type(folder_snapshot.action_2) == "function")
  assert_true("snapshot folder action3", type(folder_snapshot.action_3) == "function")
  fixture.drawer:interrupt_filter("test reset")
  print("FOLDER15_DRAWER_SNAPSHOT_FOLDER_THREADING_OK=true")

  actions.filter()
  local session = fixture.runtime.filter_sessions[#fixture.runtime.filter_sessions]
  assert_true("filter session created", session ~= nil)
  session:change("Alpha")
  Harness.drain()
  local filtered_folder = find_tree_node(fixture.drawer.tree, function(node)
    return node.type == "folder" and node.folder_id == "folder-prod"
  end)
  assert_true("filtered folder visible", filtered_folder ~= nil)
  assert_true("filtered folder expanded", filtered_folder:is_expanded())
  assert_true("filtered folder decorated", type(filtered_folder.action_2) == "function" and type(filtered_folder.action_3) == "function")
  print("FOLDER15_DRAWER_FOLDER_FILTER_VISIBLE=true")
  print("FOLDER15_FILTERED_FOLDER_DECORATION_OK=true")
  session:submit("")
  Harness.drain()

  fixture.source.fail_folder_mutation = true
  refresh_count = 0
  fixture.drawer.refresh = function(self)
    refresh_count = refresh_count + 1
    return original_refresh(self)
  end
  clear_notifications()
  fixture.runtime.next_input_value = "Will Fail"
  actions.add_folder()
  Harness.drain()
  Harness.set_current_node(fixture.winid, fixture.drawer.tree, folder_node_id)
  fixture.runtime.next_input_value = "Will Fail"
  actions.rename_folder()
  Harness.drain()
  Harness.set_current_node(fixture.winid, fixture.drawer.tree, folder_node_id)
  fixture.runtime.next_select_choice = "Delete (members ungrouped)"
  actions.delete_folder()
  Harness.drain()
  Harness.set_current_node(fixture.winid, fixture.drawer.tree, "conn-gamma")
  fixture.runtime.next_select_choice = "(ungrouped)"
  actions.move_connection_to_folder()
  Harness.drain()
  assert_true("mutation errors logged", #notifications >= 4)
  assert_true("mutation recovery refreshes", refresh_count >= 4)
  print("FOLDER15_DRAWER_FOLDER_MUTATION_ERROR_RECOVER_OK=true")
  fixture.source.fail_folder_mutation = false

  fixture:cleanup()
end

local function run_move_picker_duplicate_contract()
  local fixture = new_fixture({
    source = {
      folders = {
        { id = "folder_aaaaaa", name = "Duplicate", connection_ids = {} },
        { id = "folder_bbbbbb", name = "Duplicate", connection_ids = {} },
        { id = "folder_cccccc", name = "Duplicate", connection_ids = {} },
      },
    },
  })
  Harness.set_current_node(fixture.winid, fixture.drawer.tree, "conn-alpha")
  fixture.drawer:get_actions().move_connection_to_folder()
  local select_opts = fixture.runtime.select_calls[#fixture.runtime.select_calls]
  assert_true("move picker opened", select_opts ~= nil)
  local seen = {}
  local duplicate_labels = 0
  for _, item in ipairs(select_opts.items or {}) do
    if item:find("Duplicate", 1, true) then
      duplicate_labels = duplicate_labels + 1
      assert_true("distinct duplicate label " .. item, not seen[item])
      seen[item] = true
    end
  end
  assert_eq("three duplicate labels", duplicate_labels, 3)
  print("FOLDER15_MOVE_PICKER_3_DUPLICATE_NAMES_DISTINCT=true")
  fixture:cleanup()
end

local function run_model_contracts()
  reset_drawer_modules()
  Harness.install_ui_stubs({ prompt_calls = {}, editor_calls = {}, select_calls = {}, input_calls = {}, filter_sessions = {} }, {
    stub_reconnect = true,
  })
  local model = require("dbee.ui.drawer.model")
  local source = make_source()
  local handler = make_handler(source)
  local structure_cache = {
    root = {
      ["conn-alpha"] = {
        structures = {
          { type = "schema", name = "public", schema = "public" },
        },
      },
    },
  }
  local search_model, coverage, all_ids, ready_ids = model.build_search_model(handler, structure_cache)
  assert_eq("build_search_model conn call count", handler.call_counts.source_get_connections, 1)
  assert_eq("build_search_model folder call count", handler.call_counts.source_get_folders, 1)
  assert_true("all ids alpha", all_ids["conn-alpha"])
  assert_true("all ids beta", all_ids["conn-beta"])
  assert_true("ready ids alpha", ready_ids["conn-alpha"])
  assert_true("ready ids beta absent", not ready_ids["conn-beta"])
  print("FOLDER15_BUILD_SEARCH_MODEL_CALL_COUNT_OK=true")

  local folder = search_model[1]
  assert_eq("search folder type", folder.type, "folder")
  assert_eq("search folder children", #folder.children, 2)

  local rendered_snapshot = {
    { id = "conn-alpha", name = "Alpha", raw_name = "Alpha", type = "connection", conn_id = "conn-alpha", source_meta = { id = "source-main" }, children = {} },
    { id = "conn-beta", name = "Beta", raw_name = "Beta", type = "connection", conn_id = "conn-beta", source_meta = { id = "source-main" }, children = {} },
  }
  local _, visible_connections, visible_uncached =
    model.merge_visible_connection_rows(search_model, rendered_snapshot, all_ids, ready_ids)
  assert_eq("visible connections", visible_connections, 2)
  assert_eq("visible uncached", visible_uncached, 1)
  assert_eq("coverage ready", coverage.ready_connections, 1)
  assert_eq("coverage total", coverage.total_connections, 3)
  print("FOLDER15_VISIBLE_UNCACHED_COUNT_PRESERVED_OK=true")
end

local function run_bootstrap_contract()
  local fixture = new_fixture({
    bootstrap = {
      drain_events = {
        { reason = "folder_mutation", source_id = "source-main" },
      },
    },
  })
  assert_true("bootstrap replay left drawer live", fixture.drawer._connection_invalidated_consumer_live)
  assert_true("bootstrap drawer rendered", #fixture.drawer.tree.visible_nodes > 0)
  print("FOLDER15_BOOTSTRAP_REPLAY_FOLDER_MUTATION_OK=true")
  fixture:cleanup()
end

local function run_dbee_api_contracts()
  Harness.reset_modules({ "dbee", "dbee.api" })
  local drawer_actions = {}
  local layout_open = false
  local layout = {
    is_open = function()
      return layout_open
    end,
    open = function()
      layout_open = true
    end,
    reset = function()
      layout_open = true
    end,
    close = function()
      layout_open = false
    end,
    ensure_drawer_visible = function()
      return true
    end,
    focus_pane = function(_, name)
      drawer_actions[#drawer_actions + 1] = "focus:" .. tostring(name)
      return true
    end,
  }
  package.loaded["dbee.api"] = {
    core = {
      is_loaded = function()
        return false
      end,
      get_current_connection = function()
        return nil
      end,
    },
    ui = {
      drawer_do_action = function(name)
        drawer_actions[#drawer_actions + 1] = name
      end,
    },
    current_config = function()
      return { window_layout = layout }
    end,
    setup = function() end,
  }
  local picker_items = nil
  package.loaded["snacks"] = {
    picker = function(opts)
      picker_items = opts.items
    end,
  }
  local dbee = require("dbee")
  dbee.actions()
  local action_ids = {}
  for _, item in ipairs(picker_items or {}) do
    action_ids[item.action.id] = true
  end
  assert_true("picker add folder", action_ids.add_folder)
  assert_true("picker rename folder", action_ids.rename_folder)
  assert_true("picker delete folder", action_ids.delete_folder)
  assert_true("picker move folder", action_ids.move_connection_to_folder)
  print("FOLDER15_DBEE_ACTIONS_PICKER_INCLUDES_FOLDER_OPS=true")

  local ok_add = pcall(dbee.add_folder)
  local ok_rename = pcall(dbee.rename_folder)
  local ok_delete = pcall(dbee.delete_folder)
  local ok_move = pcall(dbee.move_connection_to_folder)
  assert_true("closed add no throw", ok_add)
  assert_true("closed rename no throw", ok_rename)
  assert_true("closed delete no throw", ok_delete)
  assert_true("closed move no throw", ok_move)
  assert_true("drawer action invoked", vim.tbl_contains(drawer_actions, "add_folder"))
  assert_true("drawer action invoked move", vim.tbl_contains(drawer_actions, "move_connection_to_folder"))
  print("FOLDER15_DBEE_ACTIONS_CLOSED_DRAWER_NO_THROW=true")
end

local function run_perf_diagnostic()
  reset_drawer_modules()
  Harness.install_ui_stubs({ prompt_calls = {}, editor_calls = {}, select_calls = {}, input_calls = {}, filter_sessions = {} }, {
    stub_reconnect = true,
  })
  local source = make_source({ folders = {} })
  source._conns = {}
  for folder_index = 1, 50 do
    local folder = { id = "folder-" .. folder_index, name = "Folder " .. folder_index, connection_ids = {} }
    for conn_index = 1, 20 do
      local conn_id = "conn-" .. folder_index .. "-" .. conn_index
      source._conns[#source._conns + 1] = { id = conn_id, name = conn_id, type = "postgres", url = "postgres://" .. conn_id }
      folder.connection_ids[#folder.connection_ids + 1] = conn_id
    end
    source._folders[#source._folders + 1] = folder
  end
  local handler = make_handler(source)
  local convert = require("dbee.ui.drawer.convert")
  local started = vim.loop.hrtime()
  local nodes = convert.handler_nodes(handler, make_result(), {}, {})
  local elapsed_ms = (vim.loop.hrtime() - started) / 1000000
  assert_eq("perf folder count", #nodes, 50)
  print(string.format("FOLDER15_DRAWER_RENDER_PERF_DIAGNOSTIC_MS=%.2f", elapsed_ms))
  print("FOLDER15_DRAWER_RENDER_PERF_DIAGNOSTIC=true")
end

local function run_persistence_contracts_for_all_pass()
  local real_cmd = vim.cmd
  vim.cmd = function(command)
    if command == "qa!" then
      return
    end
    return real_cmd(command)
  end

  local ok, err = pcall(dofile, vim.fn.getcwd() .. "/ci/headless/check_folder_persistence.lua")
  vim.cmd = real_cmd
  if not ok then
    fail("persistence precheck failed: " .. tostring(err))
  end
end

run_persistence_contracts_for_all_pass()
run_convert_contracts()
run_drawer_action_contracts()
run_move_picker_duplicate_contract()
run_model_contracts()
run_bootstrap_contract()
run_dbee_api_contracts()
run_perf_diagnostic()

vim.notify = saved_notify
print("FOLDER15_ALL_PASS=true")
vim.cmd("qa!")
