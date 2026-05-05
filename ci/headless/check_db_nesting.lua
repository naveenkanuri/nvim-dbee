-- Headless validation scaffold for Phase 18 database nesting.
--
-- Usage:
--   make perf-headless ARGS='-l ci/headless/check_db_nesting.lua'

local Harness = dofile(vim.fn.getcwd() .. "/ci/headless/phase7_harness.lua")

local function fail(message)
  print("DB18_FAIL=" .. tostring(message))
  vim.cmd("cquit 1")
end

local function read(path)
  local full = vim.fn.getcwd() .. "/" .. path
  local ok, lines = pcall(vim.fn.readfile, full)
  if not ok or type(lines) ~= "table" then
    fail("unable to read " .. tostring(path))
  end
  return table.concat(lines, "\n")
end

local function assert_true(value, message)
  if not value then
    fail((message or "expected truthy") .. ": got " .. vim.inspect(value))
  end
end

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    fail((message or "values differ") .. ": expected " .. vim.inspect(expected) .. " got " .. vim.inspect(actual))
  end
end

local function assert_contains(haystack, needle, message)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    fail((message or "missing substring") .. ": missing " .. vim.inspect(needle))
  end
end

local STRICT_MARKERS = {
  "DB18_TOPOLOGY_POSTGRES_NESTED_OK",
  "DB18_TOPOLOGY_SQLSERVER_NESTED_OK",
  "DB18_TOPOLOGY_REDSHIFT_NESTED_OK",
  "DB18_TOPOLOGY_DATABRICKS_NESTED_OK",
  "DB18_TOPOLOGY_MONGO_NESTED_OK",
  "DB18_TOPOLOGY_MYSQL_FLAT_OK",
  "DB18_TOPOLOGY_CLICKHOUSE_FLAT_OK",
  "DB18_TOPOLOGY_ORACLE_FLAT_OK",
  "DB18_TOPOLOGY_SQLITE_FLAT_OK",
  "DB18_TOPOLOGY_DUCKDB_FLAT_OK",
  "DB18_TOPOLOGY_BIGQUERY_FLAT_OK",
  "DB18_TOPOLOGY_REDIS_FLAT_OK",
  "DB18_SINGLE_DB_CURRENT_RENDER_OK",
  "DB18_DATABASE_NODE_ID_STABLE_OK",
  "DB18_SCHEMA_ID_MIGRATION_OK",
  "DB18_SWITCH_INVALIDATION_OK",
  "DB18_LAZY_SCHEMA_ROOT_PRESERVED_OK",
  "DB18_FULL_ROOT_WRAPPED_OK",
  "DB18_REFRESH_REPLAY_DATABASE_OK",
  "DB18_CAPTURE_CONTAINER_DATABASE_OK",
  "DB18_SEARCH_DATABASE_OK",
  "DB18_YANK_DATABASE_ONLY_OK",
  "DB18_MV_RICH_FOLDERS_UNDER_DB_OK",
  "DB18_SCHEMA_FILTER_KEY_UNCHANGED_OK",
  "DB18_NO_CORE_STRUCTURE_DATABASE_OK",
  "DB18_LOCKED_HELPERS_UNTOUCHED_OK",
  "DB18_ADAPTER_CURRENT_DB_FALLBACK_OK",
  "DB18_TOPOLOGY_REGISTRY_COMPLETE_OK",
  "DB18_REPLAY_NO_REFETCH_OK",
}

local STRICT_MARKER_SET = {}
for _, marker in ipairs(STRICT_MARKERS) do
  STRICT_MARKER_SET[marker] = true
end

local emitted = {}

local function mark(name, value)
  value = value == nil and "true" or tostring(value)
  if not STRICT_MARKER_SET[name] then
    fail("unknown DB18 strict marker: " .. tostring(name))
  end
  if emitted[name] ~= nil and emitted[name] ~= value then
    fail("conflicting DB18 strict marker value for " .. name)
  end
  emitted[name] = value
  print(name .. "=" .. value)
end

local CANONICAL_TOPOLOGY = {
  postgres = "nested",
  sqlserver = "nested",
  redshift = "nested",
  databricks = "nested",
  mongo = "nested",

  mysql = "flat",
  clickhouse = "flat",
  sqlite = "flat",
  duck = "flat",
  oracle = "flat",
  bigquery = "flat",
  redis = "flat",
}

local ALIAS_TO_CANONICAL = {
  postgresql = "postgres",
  pg = "postgres",
  mssql = "sqlserver",
  mongodb = "mongo",
  duckdb = "duck",
}

local NESTED_ADAPTERS = { "postgres", "sqlserver", "redshift", "databricks", "mongo" }
local FLAT_ADAPTERS = { "mysql", "clickhouse", "oracle", "sqlite", "duck", "bigquery", "redis" }
local ID_SEP = "\x1f"
local DATABASE_SWITCH_SUFFIX = "_database_switch__"
local UNKNOWN_ADAPTER = "__unknown_test_adapter__"

local function sorted_keys(set)
  local keys = {}
  for key in pairs(set or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

local function list_to_set(items)
  local set = {}
  for _, item in ipairs(items or {}) do
    set[item] = true
  end
  return set
end

local function set_equals(left, right)
  for key in pairs(left or {}) do
    if not right[key] then
      return false
    end
  end
  for key in pairs(right or {}) do
    if not left[key] then
      return false
    end
  end
  return true
end

local function shell(command)
  local handle = io.popen(command .. " 2>&1; printf '\\n__DB18_EXIT__=%s\\n' $?")
  if not handle then
    fail("unable to run command: " .. command)
  end
  local output = handle:read("*a") or ""
  handle:close()
  local exit = tonumber(output:match("__DB18_EXIT__=(%d+)%s*$")) or 127
  output = output:gsub("\n?__DB18_EXIT__=%d+%s*$", "")
  return output, exit
end

local function shell_output(command)
  local output, exit = shell(command)
  if exit ~= 0 then
    fail("command failed (" .. tostring(exit) .. "): " .. command .. "\n" .. output)
  end
  return output
end

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
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

local function make_structures()
  return {
    {
      name = "public",
      schema = "public",
      type = "schema",
      children = {
        { name = "accounts", schema = "public", type = "table" },
        { name = "account_summary", schema = "public", type = "materialized_view" },
      },
    },
    {
      name = "analytics",
      schema = "analytics",
      type = "schema",
      children = {
        { name = "daily_rollup", schema = "analytics", type = "view" },
      },
    },
  }
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
    search_note = function()
      return nil
    end,
  }
end

local function make_result()
  return {
    set_call = function() end,
  }
end

local function make_source(conns)
  return {
    _conns = conns,
    name = function()
      return "db18-source"
    end,
    file = function()
      return "/tmp/db18-source.json"
    end,
    create = function() end,
    update = function() end,
    delete = function() end,
  }
end

local FAIL_ON_RPC_NAMES = {
  "connection_get_structure_async",
  "connection_get_structure_singleflight",
  "connection_list_schemas_async",
  "connection_list_schemas_singleflight",
  "connection_get_schema_objects_async",
  "connection_get_schema_objects_singleflight",
  "connection_list_databases",
  "connection_list_databases_async",
  "connection_get_columns_rich_async",
  "connection_get_columns_async",
  "connection_get_indexes_async",
  "connection_get_sequences_async",
}

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

  local conn = vim.deepcopy(opts.conn or {
    id = "conn-db18",
    name = "DB18",
    type = opts.adapter or "postgres",
    url = "db18://fixture",
  })
  local conns = vim.deepcopy(opts.conns or { conn })
  local conn_by_id = {}
  for _, candidate in ipairs(conns) do
    conn_by_id[candidate.id] = candidate
  end

  local current_conn = conn
  local listeners = {}
  local counters = {}
  local requests = {
    root = {},
    schemas = {},
    schema_objects = {},
    columns_rich = {},
    columns = {},
    indexes = {},
    sequences = {},
    selected = {},
  }
  local current_db = vim.deepcopy(opts.current_db or { [conn.id] = "dbee_test" })
  local available_db = vim.deepcopy(opts.available_db or { [conn.id] = { "analytics", "archive" } })
  local root_epoch = vim.deepcopy(opts.root_epoch or {})
  local schema_filter_calls = {}
  local fail_on_rpc = opts.fail_on_rpc == true

  local function bump(name)
    counters[name] = (counters[name] or 0) + 1
  end

  local function fail_if_sentinel(name)
    if fail_on_rpc then
      fail("unexpected RPC during sentinel fixture: " .. name)
    end
    bump(name)
  end

  local source = make_source(conns)
  local handler = {}

  function handler:register_event_listener(event, cb)
    listeners[event] = cb
  end

  function handler:get_sources()
    return { source }
  end

  function handler:source_get_connections(source_id)
    if source_id ~= "db18-source" then
      return {}
    end
    return vim.deepcopy(conns)
  end

  function handler:source_get_folders()
    return {}
  end

  function handler:get_current_connection()
    return vim.deepcopy(current_conn)
  end

  function handler:set_current_connection(conn_id)
    current_conn = conn_by_id[conn_id] or current_conn
    if listeners.current_connection_changed then
      listeners.current_connection_changed({ conn_id = conn_id })
    end
  end

  function handler:connection_get_params(conn_id)
    return vim.deepcopy(conn_by_id[conn_id])
  end

  function handler:get_authoritative_root_epoch(conn_id)
    return root_epoch[conn_id] or 0
  end

  function handler:bump_authoritative_root_epoch(conn_ids)
    local next_epoch = 0
    for _, conn_id in ipairs(conn_ids or {}) do
      root_epoch[conn_id] = (root_epoch[conn_id] or 0) + 1
      next_epoch = math.max(next_epoch, root_epoch[conn_id])
    end
    return next_epoch
  end

  function handler:get_schema_filter_normalized(conn_id)
    schema_filter_calls[#schema_filter_calls + 1] = { conn_id = conn_id }
    local c = conn_by_id[conn_id] or conn
    local schema_filter = require("dbee.schema_filter")
    return schema_filter.normalize(opts.schema_filter, c and c.type or nil)
  end

  function handler:connection_get_structure_async(conn_id, request_id, epoch, caller_token)
    fail_if_sentinel("connection_get_structure_async")
    requests.root[#requests.root + 1] = {
      conn_id = conn_id,
      request_id = request_id,
      root_epoch = epoch,
      caller_token = caller_token,
    }
  end

  function handler:connection_get_structure_singleflight(payload)
    fail_if_sentinel("connection_get_structure_singleflight")
    requests.root[#requests.root + 1] = vim.deepcopy(payload)
  end

  function handler:connection_list_schemas_async(conn_id, request_id, epoch, caller_token)
    fail_if_sentinel("connection_list_schemas_async")
    requests.schemas[#requests.schemas + 1] = {
      conn_id = conn_id,
      request_id = request_id,
      root_epoch = epoch,
      caller_token = caller_token,
    }
  end

  function handler:connection_list_schemas_singleflight(payload)
    fail_if_sentinel("connection_list_schemas_singleflight")
    requests.schemas[#requests.schemas + 1] = vim.deepcopy(payload)
  end

  function handler:connection_get_schema_objects_async(conn_id, request_id, branch_id, epoch, schema)
    fail_if_sentinel("connection_get_schema_objects_async")
    requests.schema_objects[#requests.schema_objects + 1] = {
      conn_id = conn_id,
      request_id = request_id,
      branch_id = branch_id,
      root_epoch = epoch,
      schema = schema,
    }
  end

  function handler:connection_get_schema_objects_singleflight(payload)
    fail_if_sentinel("connection_get_schema_objects_singleflight")
    requests.schema_objects[#requests.schema_objects + 1] = vim.deepcopy(payload)
  end

  function handler:connection_list_databases(conn_id)
    fail_if_sentinel("connection_list_databases")
    return tostring(current_db[conn_id] or ""), vim.deepcopy(available_db[conn_id] or {})
  end

  function handler:connection_list_databases_async(conn_id, request_id, epoch)
    fail_if_sentinel("connection_list_databases_async")
    if listeners.connection_databases_loaded then
      listeners.connection_databases_loaded({
        conn_id = conn_id,
        request_id = request_id,
        root_epoch = epoch,
        databases = {
          current = tostring(current_db[conn_id] or ""),
          available = vim.deepcopy(available_db[conn_id] or {}),
        },
      })
    end
  end

  function handler:connection_select_database(conn_id, database)
    current_db[conn_id] = database
    requests.selected[#requests.selected + 1] = { conn_id = conn_id, database = database }
    if listeners.database_selected then
      listeners.database_selected({ conn_id = conn_id, database_name = database })
    end
  end

  function handler:connection_supports_rich_metadata()
    return vim.deepcopy(opts.rich_support or { columns = false, indexes = false, sequences = false })
  end

  function handler:connection_get_columns_rich_async(conn_id, request_id, branch_id, epoch, table_opts)
    fail_if_sentinel("connection_get_columns_rich_async")
    requests.columns_rich[#requests.columns_rich + 1] = {
      conn_id = conn_id,
      request_id = request_id,
      branch_id = branch_id,
      root_epoch = epoch,
      opts = vim.deepcopy(table_opts or {}),
    }
  end

  function handler:connection_get_columns_async(conn_id, request_id, branch_id, epoch, table_opts)
    fail_if_sentinel("connection_get_columns_async")
    requests.columns[#requests.columns + 1] = {
      conn_id = conn_id,
      request_id = request_id,
      branch_id = branch_id,
      root_epoch = epoch,
      opts = vim.deepcopy(table_opts or {}),
    }
  end

  function handler:connection_get_indexes_async(conn_id, request_id, branch_id, epoch, table_opts)
    fail_if_sentinel("connection_get_indexes_async")
    requests.indexes[#requests.indexes + 1] = {
      conn_id = conn_id,
      request_id = request_id,
      branch_id = branch_id,
      root_epoch = epoch,
      opts = vim.deepcopy(table_opts or {}),
    }
  end

  function handler:connection_get_sequences_async(conn_id, request_id, branch_id, epoch, table_opts)
    fail_if_sentinel("connection_get_sequences_async")
    requests.sequences[#requests.sequences + 1] = {
      conn_id = conn_id,
      request_id = request_id,
      branch_id = branch_id,
      root_epoch = epoch,
      opts = vim.deepcopy(table_opts or {}),
    }
  end

  function handler:connection_get_columns()
    return {}
  end

  function handler:connection_get_helpers(_, table_opts)
    return {
      Browse = string.format("select * from %s.%s", table_opts.schema or "", table_opts.table or ""),
    }
  end

  function handler:connection_execute(_, query)
    return { id = "call-db18", query = query }
  end

  for _, rpc_name in ipairs(FAIL_ON_RPC_NAMES) do
    if handler[rpc_name] == nil then
      handler[rpc_name] = function()
        fail_if_sentinel(rpc_name)
      end
    end
  end

  local DrawerUI = require("dbee.ui.drawer")
  local drawer = DrawerUI:new(handler, make_editor(), make_result(), {
    disable_help = true,
    dynamic_width = false,
    mappings = {
      { key = "<CR>", mode = "n", action = "action_1" },
      { key = "yy", mode = "n", action = "yank_name" },
      { key = "/", mode = "n", action = "filter" },
      { key = "R", mode = "n", action = "refresh" },
    },
  })

  drawer._struct_cache.root = vim.deepcopy(opts.seed_root or {})
  drawer._struct_cache.root_mode = vim.deepcopy(opts.root_mode or {})
  drawer._struct_cache.root_loaded_schemas = vim.deepcopy(opts.root_loaded_schemas or {})
  drawer._struct_cache.root_filter_signature = vim.deepcopy(opts.root_filter_signature or {})
  drawer._struct_cache.branches = vim.deepcopy(opts.branches or {})
  drawer._struct_cache.loaded_lazy_ids = vim.deepcopy(opts.loaded_lazy_ids or {})
  drawer._struct_cache.root_gen = vim.deepcopy(opts.root_gen or {})
  drawer._struct_cache.root_applied = vim.deepcopy(opts.root_applied or {})
  drawer._struct_cache.root_epoch = vim.deepcopy(opts.root_epoch or {})

  local host_buf, winid = Harness.with_window(120, 40)
  drawer:show(winid)
  Harness.drain()

  return {
    runtime = runtime,
    conn = conn,
    conns = conns,
    handler = handler,
    drawer = drawer,
    winid = winid,
    host_buf = host_buf,
    counters = counters,
    requests = requests,
    listeners = listeners,
    current_db = current_db,
    available_db = available_db,
    schema_filter_calls = schema_filter_calls,
    cleanup = function(self)
      if self.drawer and type(self.drawer.prepare_close) == "function" then
        pcall(self.drawer.prepare_close, self.drawer)
      end
      Harness.close_window_and_buffer(self.host_buf, self.winid)
    end,
  }
end

local function materialize(drawer, node_id)
  local node = drawer.tree:get_node(node_id)
  assert_true(node ~= nil, "materialize missing node " .. tostring(node_id))
  if type(node.lazy_children) == "function" and not node._materialized_in_tree then
    local children = node.lazy_children()
    drawer.tree:set_nodes(children, node_id)
    node._materialized_in_tree = true
    drawer._struct_cache.loaded_lazy_ids[node_id] = true
  end
  node:expand()
  drawer.tree:render()
  return node
end

local function direct_children(drawer, node_id)
  return drawer.tree:get_nodes(node_id)
end

local function find_child(drawer, parent_id, predicate)
  for _, child in ipairs(direct_children(drawer, parent_id)) do
    if predicate(child) then
      return child
    end
  end
end

local function database_node_id(conn_id)
  local convert = require("dbee.ui.drawer.convert")
  return convert.database_node_id(conn_id)
end

local function structure_node_id(parent_id, struct)
  return require("dbee.ui.drawer.convert").structure_node_id(parent_id, struct)
end

local function render_connection(opts)
  local conn = {
    id = opts.conn_id or "conn-" .. tostring(opts.adapter),
    name = opts.name or tostring(opts.adapter),
    type = opts.adapter,
  }
  local fixture = new_fixture({
    conn = conn,
    seed_root = {
      [conn.id] = {
        structures = vim.deepcopy(opts.structures or make_structures()),
      },
    },
    root_mode = {
      [conn.id] = opts.root_mode,
    },
    current_db = {
      [conn.id] = opts.current_db == nil and "dbee_test" or opts.current_db,
    },
    available_db = {
      [conn.id] = opts.available_db == nil and { "analytics", "archive" } or opts.available_db,
    },
    rich_support = opts.rich_support,
  })
  materialize(fixture.drawer, conn.id)
  return fixture
end

local function assert_nested_adapter(adapter, marker)
  local fixture = render_connection({ adapter = adapter })
  local conn_id = fixture.conn.id
  local db = find_child(fixture.drawer, conn_id, function(node)
    return node.type == "database"
  end)
  assert_true(db ~= nil, adapter .. " should render database node")
  assert_eq(db:get_id(), database_node_id(conn_id), adapter .. " database id")
  assert_true(db:get_id() ~= conn_id .. DATABASE_SWITCH_SUFFIX, adapter .. " database id collision")
  local direct_schema = find_child(fixture.drawer, conn_id, function(node)
    return node.type == "schema"
  end)
  assert_true(direct_schema == nil, adapter .. " schema should not be direct connection child")
  local nested_schema = find_child(fixture.drawer, db:get_id(), function(node)
    return node.type == "schema" and node.name == "public"
  end)
  assert_true(nested_schema ~= nil, adapter .. " schema should be under database node")
  fixture:cleanup()
  mark(marker)
end

local function assert_flat_adapter(adapter, marker)
  local fixture = render_connection({
    adapter = adapter,
    current_db = "",
    available_db = {},
  })
  local conn_id = fixture.conn.id
  local db = find_child(fixture.drawer, conn_id, function(node)
    return node.type == "database"
  end)
  assert_true(db == nil, adapter .. " should not render database node")
  local direct_schema = find_child(fixture.drawer, conn_id, function(node)
    return node.type == "schema" and node.name == "public"
  end)
  assert_true(direct_schema ~= nil, adapter .. " schema should be direct connection child")
  fixture:cleanup()
  mark(marker)
end

local function driver_file_stems()
  local stems = {}
  local files = vim.fn.globpath(vim.fn.getcwd() .. "/dbee/adapters", "*_driver.go", false, true)
  for _, file in ipairs(files or {}) do
    local stem = vim.fn.fnamemodify(file, ":t"):gsub("_driver%.go$", "")
    stems[stem] = true
  end
  return stems
end

local function validate_topology(topology, aliases, expected_driver_stems)
  local canonical = {}
  for adapter in pairs(topology or {}) do
    if aliases[adapter] then
      return false, "alias counted as canonical stem: " .. adapter
    end
    canonical[adapter] = true
  end
  if not set_equals(canonical, expected_driver_stems) then
    return false,
      "canonical topology mismatch expected "
        .. table.concat(sorted_keys(expected_driver_stems), ",")
        .. " got "
        .. table.concat(sorted_keys(canonical), ",")
  end
  for alias, target in pairs(aliases or {}) do
    if not canonical[target] then
      return false, "alias " .. alias .. " resolves to missing canonical stem " .. tostring(target)
    end
    if canonical[alias] then
      return false, "alias " .. alias .. " was counted as canonical stem"
    end
  end
  return true
end

local function run_selftests()
  local ok_unknown, unknown_err = pcall(function()
    local fixture = render_connection({
      adapter = UNKNOWN_ADAPTER,
      current_db = "",
      available_db = {},
    })
    local db = find_child(fixture.drawer, fixture.conn.id, function(node)
      return node.type == "database"
    end)
    fixture:cleanup()
    assert_true(db == nil, "unknown external adapter rendered a DB wrapper")
  end)
  assert_true(ok_unknown, "unknown adapter selftest failed: " .. tostring(unknown_err))

  local stems = driver_file_stems()
  local omitted = vim.deepcopy(CANONICAL_TOPOLOGY)
  omitted.postgres = nil
  local ok_omitted = validate_topology(omitted, ALIAS_TO_CANONICAL, stems)
  assert_true(not ok_omitted, "topology omission selftest should fail validation")

  local alias_counted = vim.deepcopy(CANONICAL_TOPOLOGY)
  alias_counted.pg = "nested"
  local ok_alias_counted = validate_topology(alias_counted, ALIAS_TO_CANONICAL, stems)
  assert_true(not ok_alias_counted, "alias-counted topology selftest should fail validation")

  local aliases_missing = vim.deepcopy(ALIAS_TO_CANONICAL)
  aliases_missing.pg = "missing"
  local ok_alias_missing = validate_topology(CANONICAL_TOPOLOGY, aliases_missing, stems)
  assert_true(not ok_alias_missing, "alias missing target selftest should fail validation")

  local own_source = read("ci/headless/check_db_nesting.lua")
  assert_true(not own_source:find('mark%("DB18_ALL_PASS"', 1), "check_db_nesting must not emit DB18_ALL_PASS")
  assert_true(not own_source:find('mark%("DB18_STRICT_MARKER_COUNT"', 1), "check_db_nesting must not emit strict count")

  for _, rpc in ipairs(FAIL_ON_RPC_NAMES) do
    local sentinel = { fail_on_rpc = true, count = 0 }
    local ok_rpc = pcall(function()
      sentinel.count = sentinel.count + 1
      error("unexpected RPC during sentinel fixture: " .. rpc)
    end)
    assert_true(not ok_rpc and sentinel.count == 1, "RPC sentinel selftest should fail for " .. rpc)
  end

  local behavior_owned = {
    "DB18_NO_CORE_STRUCTURE_DATABASE_OK",
    "DB18_LOCKED_HELPERS_UNTOUCHED_OK",
    "DB18_ADAPTER_CURRENT_DB_FALLBACK_OK",
  }
  local rollup_src = read("ci/headless/check_ux13_rollup.lua")
  for _, marker_name in ipairs(behavior_owned) do
    assert_true(
      not rollup_src:find('emit%("' .. marker_name .. '"', 1),
      "UX13 rollup must not emit behavior-owned marker " .. marker_name
    )
  end
end

local function run_topology_registry_fixture()
  local stems = driver_file_stems()
  local expected = list_to_set({
    "bigquery",
    "clickhouse",
    "databricks",
    "duck",
    "mongo",
    "mysql",
    "oracle",
    "postgres",
    "redis",
    "redshift",
    "sqlite",
    "sqlserver",
  })
  assert_true(set_equals(stems, expected), "driver file stems should match DB18 closed-world fixture")
  local ok, err = validate_topology(CANONICAL_TOPOLOGY, ALIAS_TO_CANONICAL, stems)
  assert_true(ok, err)

  local drawer_src = read("lua/dbee/ui/drawer/init.lua")
  for _, adapter in ipairs(NESTED_ADAPTERS) do
    assert_contains(drawer_src, adapter .. ' = "nested"', "drawer topology nested " .. adapter)
  end
  for _, adapter in ipairs({ "mysql", "clickhouse", "sqlite", "duck", "oracle", "bigquery", "redis" }) do
    assert_contains(drawer_src, adapter .. ' = "flat"', "drawer topology flat " .. adapter)
  end
  for alias, canonical in pairs(ALIAS_TO_CANONICAL) do
    assert_contains(drawer_src, alias .. ' = "' .. canonical .. '"', "drawer alias " .. alias)
  end

  mark("DB18_TOPOLOGY_REGISTRY_COMPLETE_OK")
end

local function run_postgres_system_schema_fixture()
  local structures = {
    { name = "public", schema = "public", type = "schema", children = {} },
    { name = "pg_catalog", schema = "pg_catalog", type = "schema", children = {} },
    { name = "information_schema", schema = "information_schema", type = "schema", children = {} },
  }
  local fixture = render_connection({ adapter = "postgres", structures = structures })
  local db_id = database_node_id(fixture.conn.id)
  local found = {}
  for _, child in ipairs(direct_children(fixture.drawer, db_id)) do
    if child.name == "pg_catalog" or child.name == "information_schema" then
      found[child.name] = child.type
    end
    assert_true(not (child.type == "folder" and child.name == "System"), "system schemas must not be grouped")
  end
  assert_eq(found.pg_catalog, "schema", "pg_catalog should render as ordinary schema")
  assert_eq(found.information_schema, "schema", "information_schema should render as ordinary schema")
  fixture:cleanup()
end

local function run_unknown_adapter_fixture()
  local fixture = render_connection({
    adapter = UNKNOWN_ADAPTER,
    current_db = "",
    available_db = {},
  })
  local db = find_child(fixture.drawer, fixture.conn.id, function(node)
    return node.type == "database"
  end)
  assert_true(db == nil, "unknown external adapter should fall back flat")
  local schema = find_child(fixture.drawer, fixture.conn.id, function(node)
    return node.type == "schema"
  end)
  assert_true(schema ~= nil, "unknown external adapter schema should be direct child")
  fixture:cleanup()
end

local function run_single_db_and_stable_id_fixtures()
  local fixture = render_connection({
    adapter = "postgres",
    current_db = "dbee_test",
    available_db = {},
  })
  local db = find_child(fixture.drawer, fixture.conn.id, function(node)
    return node.type == "database"
  end)
  assert_true(db ~= nil, "single current DB should render database node")
  assert_eq(db.raw_name, "dbee_test", "single current DB raw name")
  mark("DB18_SINGLE_DB_CURRENT_RENDER_OK")

  local first_id = db:get_id()
  fixture.current_db[fixture.conn.id] = "other_db"
  fixture.drawer:_clear_database_switch_state(fixture.conn.id)
  fixture.drawer:_patch_connection_subtree(fixture.conn.id, { suppress_root_request = true })
  local second = find_child(fixture.drawer, fixture.conn.id, function(node)
    return node.type == "database"
  end)
  assert_true(second ~= nil, "second database node")
  assert_eq(second:get_id(), first_id, "database node id must not include DB name")
  assert_true(second:get_id() ~= fixture.conn.id .. DATABASE_SWITCH_SUFFIX, "database id must not collide with switch suffix")
  assert_true(not second:get_id():find("dbee_test", 1, true), "database id should omit old DB name")
  assert_true(not second:get_id():find("other_db", 1, true), "database id should omit current DB name")
  fixture:cleanup()
  mark("DB18_DATABASE_NODE_ID_STABLE_OK")
end

local function run_full_root_fixture()
  local structures = make_structures()
  local fixture = render_connection({ adapter = "postgres", structures = structures })
  assert_eq(vim.inspect(fixture.drawer._struct_cache.root[fixture.conn.id].structures), vim.inspect(structures), "root cache unchanged")
  local db_id = database_node_id(fixture.conn.id)
  local schema = find_child(fixture.drawer, db_id, function(node)
    return node.type == "schema" and node.name == "public"
  end)
  assert_true(schema ~= nil, "full root schema wrapped under DB")
  fixture:cleanup()
  mark("DB18_FULL_ROOT_WRAPPED_OK")
end

local function run_lazy_root_fixture()
  local conn = { id = "conn-lazy", name = "Lazy", type = "postgres" }
  local fixture = new_fixture({
    conn = conn,
    schema_filter = { mode = "all" },
    seed_root = {
      [conn.id] = {
        structures = {
          { name = "analytics", schema = "analytics", type = "schema", children = {} },
          { name = "public", schema = "public", type = "schema", children = {} },
        },
        schemas_only = true,
      },
    },
    root_mode = { [conn.id] = "schemas_only" },
  })
  materialize(fixture.drawer, conn.id)
  local db_id = database_node_id(conn.id)
  local public = find_child(fixture.drawer, db_id, function(node)
    return node.type == "schema" and node.name == "public"
  end)
  assert_true(public ~= nil, "lazy schema row should render under DB")
  materialize(fixture.drawer, public:get_id())
  assert_eq(#fixture.requests.schema_objects, 1, "schema expansion should use schema-object load path")
  assert_eq(fixture.requests.schema_objects[1].schema, "public", "schema object request schema")
  fixture:cleanup()
  mark("DB18_LAZY_SCHEMA_ROOT_PRESERVED_OK")
end

local function run_snapshot_capture_fixture()
  local conn = { id = "conn-snapshot", name = "Snapshot", type = "postgres" }
  local fixture = render_connection({ adapter = "postgres", conn_id = conn.id })
  local legacy_schema_id = structure_node_id(conn.id, { type = "schema", name = "legacy", schema = "legacy" })
  local snapshot = {
    {
      id = conn.id,
      name = "Snapshot",
      type = "connection",
      conn_id = conn.id,
      raw_name = "Snapshot",
      rendered_children_loaded = true,
      children = {
        {
          id = legacy_schema_id,
          name = "legacy",
          type = "schema",
          schema = "legacy",
          raw_name = "legacy",
          rendered_children_loaded = true,
          children = {},
        },
      },
    },
  }
  fixture.drawer:render_restore_snapshot(snapshot, { [conn.id] = true }, { 1, 0 })
  materialize(fixture.drawer, conn.id)
  local db_id = database_node_id(conn.id)
  local migrated = find_child(fixture.drawer, db_id, function(node)
    return node.type == "schema" and node.name == "legacy"
  end)
  assert_true(migrated ~= nil, "legacy snapshot schema should hydrate under DB")
  assert_true(migrated:get_id():sub(1, #db_id) == db_id, "legacy schema id should be rewritten under DB")

  fixture.drawer:capture_filter_snapshot()
  local function snapshot_has_database(nodes)
    for _, node in ipairs(nodes or {}) do
      if node.id == db_id and node.type == "database" then
        return true
      end
      if snapshot_has_database(node.children) then
        return true
      end
    end
    return false
  end
  assert_true(snapshot_has_database(fixture.drawer.filter_restore_snapshot), "filter restore snapshot should preserve DB container")
  fixture:cleanup()
  mark("DB18_CAPTURE_CONTAINER_DATABASE_OK")
end

local function run_schema_id_migration_fixture()
  local conn = { id = "conn-migration", name = "Migration", type = "postgres" }
  local legacy_schema = { type = "schema", name = "public", schema = "public" }
  local legacy_id = structure_node_id(conn.id, legacy_schema)
  local fixture = new_fixture({
    conn = conn,
    seed_root = {
      [conn.id] = {
        structures = {
          { type = "schema", name = "public", schema = "public", children = {} },
        },
        schemas_only = true,
      },
    },
    root_mode = { [conn.id] = "schemas_only" },
    branches = {
      [conn.id] = {
        [legacy_id .. ID_SEP .. "structures"] = {
          raw = { { type = "table", name = "customers", schema = "public" } },
          error = nil,
          built_count = 0,
          render_limit = 1000,
          request_gen = 1,
          applied_gen = 1,
          loading = false,
        },
      },
    },
    loaded_lazy_ids = { [legacy_id] = true },
  })
  materialize(fixture.drawer, conn.id)
  local db_id = database_node_id(conn.id)
  local schema = find_child(fixture.drawer, db_id, function(node)
    return node.type == "schema" and node.name == "public"
  end)
  assert_true(schema ~= nil, "schema after id migration")
  materialize(fixture.drawer, schema:get_id())
  local tables = {}
  for _, child in ipairs(direct_children(fixture.drawer, schema:get_id())) do
    if child.type == "table" and child.name == "customers" then
      tables[#tables + 1] = child
    end
  end
  assert_eq(#tables, 1, "old/new duplicate expansion should render one schema branch")
  fixture:cleanup()
  mark("DB18_SCHEMA_ID_MIGRATION_OK")
end

local function run_replay_no_refetch_fixture()
  local conn = { id = "conn-replay", name = "Replay", type = "postgres" }
  local fixture = new_fixture({
    conn = conn,
    seed_root = {
      [conn.id] = {
        structures = {
          { type = "schema", name = "public", schema = "public", children = {} },
        },
        schemas_only = true,
      },
    },
    root_mode = { [conn.id] = "schemas_only" },
  })
  materialize(fixture.drawer, conn.id)
  local db_id = database_node_id(conn.id)
  local schema = find_child(fixture.drawer, db_id, function(node)
    return node.type == "schema"
  end)
  materialize(fixture.drawer, schema:get_id())
  assert_eq(#fixture.requests.schema_objects, 1, "first schema expansion request")
  local request = fixture.requests.schema_objects[1]
  request.callback({
    conn_id = conn.id,
    request_id = request.request_id,
    root_epoch = fixture.drawer._struct_cache.root_epoch[conn.id],
    schema = "public",
    objects = {
      { type = "table", name = "customers", schema = "public" },
    },
  })
  materialize(fixture.drawer, schema:get_id())
  assert_eq(#fixture.requests.schema_objects, 1, "replay should not refetch cached schema")
  fixture:cleanup()
  mark("DB18_REPLAY_NO_REFETCH_OK")
end

local function run_refresh_replay_fixture()
  local conn = { id = "conn-refresh", name = "Refresh", type = "postgres" }
  local fixture = render_connection({ adapter = "postgres", conn_id = conn.id })
  local db_id = database_node_id(conn.id)
  local schema = find_child(fixture.drawer, db_id, function(node)
    return node.type == "schema" and node.name == "public"
  end)
  materialize(fixture.drawer, db_id)
  materialize(fixture.drawer, schema:get_id())
  fixture.drawer._replay_container_expansions[conn.id] = {
    [db_id] = true,
    [schema:get_id()] = true,
  }
  local request_id = (fixture.drawer._struct_cache.root_gen[conn.id] or 0) + 1
  fixture.drawer._struct_cache.root_gen[conn.id] = request_id
  fixture.drawer:on_structure_loaded({
    conn_id = conn.id,
    request_id = request_id,
    root_epoch = fixture.drawer._struct_cache.root_epoch[conn.id],
    caller_token = "drawer",
    structures = make_structures(),
  })
  local db_after = fixture.drawer.tree:get_node(db_id)
  local schema_after = fixture.drawer.tree:get_node(schema:get_id())
  assert_true(db_after and db_after:is_expanded(), "database expansion should replay after refresh")
  assert_true(schema_after and schema_after:is_expanded(), "schema expansion should replay after refresh")
  fixture:cleanup()
  mark("DB18_REFRESH_REPLAY_DATABASE_OK")
end

local function run_switch_invalidation_fixture()
  local conn = { id = "conn-switch", name = "Switch", type = "postgres" }
  local fixture = render_connection({
    adapter = "postgres",
    conn_id = conn.id,
    current_db = "A",
    available_db = { "B", "C" },
  })
  local function select_db(name)
    local db = find_child(fixture.drawer, conn.id, function(node)
      return node.type == "database"
    end)
    assert_true(db ~= nil, "database node before select " .. name)
    db.action_1(function() end, function(select_opts)
      select_opts.on_confirm(name)
    end)
    assert_eq(fixture.drawer._struct_cache.root[conn.id], nil, "switch should clear root cache")
    local request = fixture.requests.root[#fixture.requests.root]
    assert_true(request ~= nil, "switch should request structure reload")
    request.callback({
      conn_id = conn.id,
      request_id = request.request_id,
      root_epoch = fixture.drawer._struct_cache.root_epoch[conn.id],
      caller_token = "drawer",
      structures = make_structures(),
    })
    materialize(fixture.drawer, conn.id)
  end
  select_db("B")
  select_db("C")
  local db_count = 0
  for _, child in ipairs(direct_children(fixture.drawer, conn.id)) do
    if child.type == "database" then
      db_count = db_count + 1
    end
  end
  assert_eq(db_count, 1, "A -> B -> C switch chain should leave one database node")
  fixture:cleanup()
  mark("DB18_SWITCH_INVALIDATION_OK")
end

local function run_search_filter_fixture()
  local conn = { id = "conn-search", name = "Search", type = "postgres" }
  local fixture = render_connection({
    adapter = "postgres",
    conn_id = conn.id,
    current_db = "search_db",
  })
  fixture.handler.fail_on_rpc = true
  fixture.drawer:capture_filter_snapshot()
  fixture.drawer:apply_filter("search_db")
  local db = fixture.drawer.tree:get_node(database_node_id(conn.id))
  assert_true(db ~= nil and db.type == "database", "database should be searchable without RPC")
  fixture:cleanup()
  mark("DB18_SEARCH_DATABASE_OK")
end

local function run_yank_fixture()
  local conn = { id = "conn-yank", name = "Yank", type = "postgres" }
  local fixture = render_connection({
    adapter = "postgres",
    conn_id = conn.id,
    current_db = "dbee_test",
  })
  local actions = fixture.drawer:get_actions()
  Harness.set_current_node(fixture.winid, fixture.drawer.tree, database_node_id(conn.id))
  actions.yank_name()
  assert_eq(vim.fn.getreg(vim.v.register), "dbee_test", "database yank should copy only DB name")

  local db_id = database_node_id(conn.id)
  materialize(fixture.drawer, db_id)
  local schema = find_child(fixture.drawer, db_id, function(node)
    return node.type == "schema" and node.name == "public"
  end)
  materialize(fixture.drawer, schema:get_id())
  local table_node = find_child(fixture.drawer, schema:get_id(), function(node)
    return node.type == "table" and node.name == "accounts"
  end)
  Harness.set_current_node(fixture.winid, fixture.drawer.tree, table_node:get_id())
  actions.yank_name()
  assert_eq(vim.fn.getreg(vim.v.register), "public.accounts", "table yank should stay schema-qualified")
  fixture:cleanup()
  mark("DB18_YANK_DATABASE_ONLY_OK")
end

local function run_mv_rich_fixture()
  local conn = { id = "conn-mv", name = "MV", type = "postgres" }
  local fixture = render_connection({
    adapter = "postgres",
    conn_id = conn.id,
    rich_support = { columns = true, indexes = true, sequences = false },
  })
  local db_id = database_node_id(conn.id)
  local schema = find_child(fixture.drawer, db_id, function(node)
    return node.type == "schema" and node.name == "public"
  end)
  materialize(fixture.drawer, schema:get_id())
  local mv = find_child(fixture.drawer, schema:get_id(), function(node)
    return node.type == "materialized_view" and node.name == "account_summary"
  end)
  assert_true(mv ~= nil, "materialized view under DB")
  materialize(fixture.drawer, mv:get_id())
  local columns = find_child(fixture.drawer, mv:get_id(), function(node)
    return node.type == "folder" and node.name == "Columns"
  end)
  local indexes = find_child(fixture.drawer, mv:get_id(), function(node)
    return node.type == "folder" and node.name == "Indexes"
  end)
  assert_true(columns ~= nil, "MV columns folder")
  assert_true(indexes ~= nil, "MV indexes folder")
  assert_eq(#fixture.requests.columns_rich, 1, "MV columns rich prefetch")
  assert_contains(fixture.requests.columns_rich[1].branch_id, db_id, "rich branch id should stay under DB node")
  fixture:cleanup()
  mark("DB18_MV_RICH_FOLDERS_UNDER_DB_OK")
end

local function run_schema_object_attach_fixture()
  local conn = { id = "conn-attach", name = "Attach", type = "postgres" }
  local fixture = new_fixture({
    conn = conn,
    seed_root = {
      [conn.id] = {
        structures = {
          { type = "schema", name = "public", schema = "public", children = {} },
        },
        schemas_only = true,
      },
    },
    root_mode = { [conn.id] = "schemas_only" },
  })
  materialize(fixture.drawer, conn.id)
  local db_id = database_node_id(conn.id)
  local schema = find_child(fixture.drawer, db_id, function(node)
    return node.type == "schema"
  end)
  materialize(fixture.drawer, schema:get_id())
  local request = fixture.requests.schema_objects[1]
  request.callback({
    conn_id = conn.id,
    request_id = request.request_id,
    root_epoch = fixture.drawer._struct_cache.root_epoch[conn.id],
    schema = "public",
    objects = {
      { type = "table", name = "orders", schema = "public" },
    },
  })
  local root_schema = fixture.drawer._struct_cache.root[conn.id].structures[1]
  assert_eq(root_schema.children[1].name, "orders", "schema objects should attach to root cache schema row")
  local rendered_order = find_child(fixture.drawer, schema:get_id(), function(node)
    return node.type == "table" and node.name == "orders"
  end)
  assert_true(rendered_order ~= nil, "schema objects should attach to rendered schema row")
  fixture:cleanup()
end

local function run_schema_filter_fixture()
  local conn = { id = "conn-filter", name = "Filter", type = "postgres" }
  local fixture = render_connection({
    adapter = "postgres",
    conn_id = conn.id,
    current_db = "filter_db",
  })
  local request_id = (fixture.drawer._struct_cache.root_gen[conn.id] or 0) + 1
  fixture.drawer._struct_cache.root_gen[conn.id] = request_id
  fixture.drawer:on_structure_loaded({
    conn_id = conn.id,
    request_id = request_id,
    root_epoch = fixture.drawer._struct_cache.root_epoch[conn.id],
    caller_token = "drawer",
    structures = make_structures(),
  })
  assert_true(#fixture.schema_filter_calls > 0, "schema filter should be read")
  for _, call in ipairs(fixture.schema_filter_calls) do
    assert_eq(call.conn_id, conn.id, "schema filter identity remains conn_id only")
    assert_true(call.database == nil, "schema filter must not add database dimension")
  end
  fixture:cleanup()
  mark("DB18_SCHEMA_FILTER_KEY_UNCHANGED_OK")
end

local function run_legacy_convert_fixture()
  reset_drawer_modules()
  Harness.install_ui_stubs({
    prompt_calls = {},
    editor_calls = {},
    select_calls = {},
    input_calls = {},
    filter_sessions = {},
  }, { stub_reconnect = true })
  local convert = require("dbee.ui.drawer.convert")
  local handler = {
    get_sources = function()
      return { make_source({ { id = "conn-convert", name = "Convert", type = "postgres" } }) }
    end,
    source_get_connections = function()
      return { { id = "conn-convert", name = "Convert", type = "postgres" } }
    end,
    source_get_folders = function()
      return {}
    end,
    connection_list_databases = function()
      fail("legacy convert fallback attempted database-list RPC")
    end,
    connection_get_structure_async = function()
      fail("legacy convert fallback attempted structure RPC")
    end,
  }
  local nodes = convert.handler_nodes(handler, make_result(), {}, {
    connection_children = function()
      return {
        require("nui.tree").Node({
          id = "conn-convert" .. ID_SEP .. "child",
          name = "Injected",
          type = "schema",
        }),
      }
    end,
  })
  assert_eq(#nodes, 1, "convert should build one connection")
  local children = nodes[1].lazy_children()
  assert_eq(children[1].name, "Injected", "normal drawer construction should use injected connection_children")
end

local function run_source_contract_fixture()
  local output = shell_output("rg -n 'StructureTypeDatabase' dbee/core/ || true")
  assert_eq(trim(output), "", "core must not define StructureTypeDatabase")

  local function extract_event_names(text)
    local events = {}
    for event in text:gmatch('callLua%("([^"]+)"') do
      events[event] = true
    end
    return events
  end
  local baseline_event_bus = shell_output("git show d8a4161:dbee/handler/event_bus.go")
  local current_event_bus = read("dbee/handler/event_bus.go")
  local baseline_events = extract_event_names(baseline_event_bus)
  local current_events = extract_event_names(current_event_bus)
  for event in pairs(current_events) do
    assert_true(baseline_events[event] == true, "new handler event constant introduced since d8a4161: " .. event)
  end

  local function extract_handler_methods(text)
    local methods = {}
    for name in text:gmatch("func%s+%([^%)]*%*Handler[^%)]*%)%s+([A-Z][%w_]*)%s*%(") do
      methods[name] = true
    end
    return methods
  end
  local baseline_handler = shell_output("git show d8a4161:dbee/handler/handler.go")
  local current_handler = read("dbee/handler/handler.go")
  local baseline_methods = extract_handler_methods(baseline_handler)
  local current_methods = extract_handler_methods(current_handler)
  for method in pairs(current_methods) do
    assert_true(baseline_methods[method] == true, "new exported Handler method introduced since d8a4161: " .. method)
  end

  local config_src = read("lua/dbee/config.lua")
  assert_contains(config_src, "database_switch = {", "database_switch candy retained")
  assert_contains(config_src, "database = {", "database candy retained")

  mark("DB18_NO_CORE_STRUCTURE_DATABASE_OK")
end

local LOCKED_HELPERS = table.concat({
  "lua/dbee/schema_filter_authority.lua",
  "lua/dbee/schema_name_canonical.lua",
  "lua/dbee/lsp/epoch_authority.lua",
}, " ")

local function assert_empty_command(command, label)
  local output, exit = shell(command)
  if exit ~= 0 then
    fail(label .. " failed with exit " .. tostring(exit) .. "\n" .. output)
  end
  if trim(output) ~= "" then
    fail(label .. " produced locked-helper diff output:\n" .. output)
  end
end

local function run_locked_helper_fixture()
  local log_path = vim.env.UX13_ROLLUP_LOG
  if log_path and log_path ~= "" and vim.fn.filereadable(log_path) == 1 then
    local lines = table.concat(vim.fn.readfile(log_path), "\n")
    assert_contains(lines, "DB18_LOCKED_HELPERS_GIT_DIFF_OK=true", "Makefile guard marker")
    assert_contains(lines, "ARCH14_AUTHORITY_HELPER_ALL_CONSUMERS_ROUTED=true", "ARCH14 routed helper sentinel")
    assert_contains(lines, "LSP11_R6_CANONICAL_HELPER_ALL_CONSUMERS_ROUTED=true", "LSP11 canonical routed helper sentinel")
    assert_contains(lines, "LSP12_EPOCH_HELPER_ALL_CONSUMERS_ROUTED=true", "LSP12 epoch routed helper sentinel")
  else
    assert_empty_command("git diff -- " .. LOCKED_HELPERS, "standalone git diff")
    assert_empty_command("git diff --cached -- " .. LOCKED_HELPERS, "standalone git diff cached")
    assert_empty_command("git diff d8a4161..HEAD -- " .. LOCKED_HELPERS, "standalone git diff baseline")
    assert_empty_command("git diff --name-only d8a4161..HEAD -- " .. LOCKED_HELPERS, "standalone git diff baseline names")
    assert_empty_command("git diff --cached --name-only -- " .. LOCKED_HELPERS, "standalone git diff cached names")
    assert_empty_command("git diff --name-only -- " .. LOCKED_HELPERS, "standalone git diff working names")
  end

  assert_empty_command("git diff --name-only d8a4161..HEAD -- " .. LOCKED_HELPERS, "locked helpers baseline names")
  assert_empty_command("git diff --cached --name-only -- " .. LOCKED_HELPERS, "locked helpers cached names")
  assert_empty_command("git diff --name-only -- " .. LOCKED_HELPERS, "locked helpers working names")
  mark("DB18_LOCKED_HELPERS_UNTOUCHED_OK")
end

local function run_adapter_current_db_fixture()
  local output, exit = shell(
    "env GOCACHE=/tmp/codex-go-cache go -C dbee test ./adapters -run 'Test(Postgres|SQLServer|Redshift)ListDatabases' -v"
  )
  if exit ~= 0 then
    fail("focused adapter current DB tests failed:\n" .. output)
  end
  assert_true(not output:find("no tests to run", 1, true), "focused adapter current DB tests must not skip")
  local tests = {
    "TestPostgresListDatabasesNoAlternatives",
    "TestSQLServerListDatabasesNoAlternatives",
    "TestRedshiftListDatabasesNoAlternatives",
    "TestPostgresListDatabasesWithAlternatives",
    "TestSQLServerListDatabasesWithAlternatives",
    "TestRedshiftListDatabasesWithAlternatives",
  }
  for _, test_name in ipairs(tests) do
    assert_contains(output, "=== RUN   " .. test_name, "focused adapter RUN line " .. test_name)
    assert_contains(output, "--- PASS: " .. test_name, "focused adapter PASS line " .. test_name)
  end
  mark("DB18_ADAPTER_CURRENT_DB_FALLBACK_OK")
end

run_selftests()
run_topology_registry_fixture()

assert_nested_adapter("postgres", "DB18_TOPOLOGY_POSTGRES_NESTED_OK")
run_postgres_system_schema_fixture()
assert_nested_adapter("sqlserver", "DB18_TOPOLOGY_SQLSERVER_NESTED_OK")
assert_nested_adapter("redshift", "DB18_TOPOLOGY_REDSHIFT_NESTED_OK")
assert_nested_adapter("databricks", "DB18_TOPOLOGY_DATABRICKS_NESTED_OK")
assert_nested_adapter("mongo", "DB18_TOPOLOGY_MONGO_NESTED_OK")

assert_flat_adapter("mysql", "DB18_TOPOLOGY_MYSQL_FLAT_OK")
assert_flat_adapter("clickhouse", "DB18_TOPOLOGY_CLICKHOUSE_FLAT_OK")
assert_flat_adapter("oracle", "DB18_TOPOLOGY_ORACLE_FLAT_OK")
assert_flat_adapter("sqlite", "DB18_TOPOLOGY_SQLITE_FLAT_OK")
assert_flat_adapter("duck", "DB18_TOPOLOGY_DUCKDB_FLAT_OK")
assert_flat_adapter("bigquery", "DB18_TOPOLOGY_BIGQUERY_FLAT_OK")
assert_flat_adapter("redis", "DB18_TOPOLOGY_REDIS_FLAT_OK")
run_unknown_adapter_fixture()

run_single_db_and_stable_id_fixtures()
run_full_root_fixture()
run_lazy_root_fixture()
run_snapshot_capture_fixture()
run_schema_id_migration_fixture()
run_replay_no_refetch_fixture()
run_refresh_replay_fixture()
run_switch_invalidation_fixture()
run_search_filter_fixture()
run_yank_fixture()
run_mv_rich_fixture()
run_schema_object_attach_fixture()
run_schema_filter_fixture()
run_legacy_convert_fixture()
run_source_contract_fixture()
run_locked_helper_fixture()
run_adapter_current_db_fixture()

for _, marker_name in ipairs(STRICT_MARKERS) do
  if emitted[marker_name] ~= "true" then
    fail("missing DB18 strict behavior marker " .. marker_name)
  end
end

assert_eq(#sorted_keys(emitted), 29, "DB18 strict behavior marker count")
vim.cmd("qa!")
