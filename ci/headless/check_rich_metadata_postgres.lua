-- Headless validation scaffold for Phase 17 PostgreSQL rich metadata.
--
-- Usage:
-- make perf-headless ARGS='-l ci/headless/check_rich_metadata_postgres.lua'

local function fail(msg)
  print("RICH_PG_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local function read(path)
  local full = vim.fn.getcwd() .. "/" .. path
  local lines = vim.fn.readfile(full)
  if not lines or #lines == 0 then
    fail("unable to read " .. path)
  end
  return table.concat(lines, "\n")
end

local function assert_contains(label, haystack, needle)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    fail(label .. ": missing " .. vim.inspect(needle))
  end
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

local function mark(label)
  print(label .. "=true")
end

local function count_plain(haystack, needle)
  local count = 0
  local start = 1
  while true do
    local found = haystack:find(needle, start, true)
    if not found then
      return count
    end
    count = count + 1
    start = found + #needle
  end
end

local postgres_driver = read("dbee/adapters/postgres_driver.go")
local makefile = read("Makefile")
local model_src = read("lua/dbee/ui/drawer/model.lua")
local drawer_src = read("lua/dbee/ui/drawer/init.lua")
local convert_src = read("lua/dbee/ui/drawer/convert.lua")
local lsp_init_src = read("lua/dbee/lsp/init.lua")
local object_docs_src = read("lua/dbee/lsp/object_docs.lua")
local schema_cache_src = read("lua/dbee/lsp/schema_cache.lua")
local server_src = read("lua/dbee/lsp/server.lua")
local config_src = read("lua/dbee/config.lua")

assert_eq(
  "postgres matview structure branches",
  count_plain(postgres_driver, "'MATERIALIZED VIEW' AS object_type"),
  2
)
assert_eq("old postgres matview label removed", count_plain(postgres_driver, "'VIEW' AS object_type FROM pg_matviews"), 0)
assert_contains("postgres structure type mapping retained", postgres_driver, 'case "MATERIALIZED VIEW":')

assert_contains("perf headless target", makefile, "perf-headless: perf-bootstrap")
assert_contains("perf headless bootstrap command", makefile, "$(PERF_NVIM_HEADLESS) $(ARGS)")

assert_contains("searchable materialized view", model_src, "materialized_view = true")
assert_contains("drawer fallback searchable materialized view", drawer_src, "materialized_view = true")
assert_contains("table-like materialized view", drawer_src, "TABLE_LIKE_TYPES = {\n  table = true,\n  view = true,\n  materialized_view = true,")
assert_contains("capture excludes materialized view", drawer_src, 'and node.type ~= "materialized_view"')
assert_contains("yankable materialized view", drawer_src, "materialized_view = true")
assert_contains("config materialized view icon", config_src, "materialized_view")
assert_contains("table-like consumers retained", drawer_src, "TABLE_LIKE_TYPES[node.type]")

assert_contains("convert early return admits materialized view", convert_src, 'struct.type ~= "materialized_view"')
assert_contains(
  "convert legacy branch admits materialized view",
  convert_src,
  'struct.type == "table" or struct.type == "view" or struct.type == "materialized_view"'
)

assert_contains("schema cache materializations", schema_cache_src, 'MATERIALIZATIONS = { "table", "view", "materialized_view" }')
assert_contains(
  "schema cache flatten materialized view",
  schema_cache_src,
  'stype == "table" or stype == "view" or stype == "materialized_view"'
)
assert_contains("schema cache version bumped", schema_cache_src, "local SCHEMA_CACHE_VERSION = 4")
assert_contains("schema cache fallback uses materializations", schema_cache_src, "opts.materializations or MATERIALIZATIONS")
assert_contains("schema cache completion kind", schema_cache_src, 'table_type == "materialized_view"')
assert_true(
  "schema cache no table/view-only fallback literal",
  not schema_cache_src:find('opts.materializations or { "table", "view" }', 1, true)
)

assert_contains("server probe materialized view", server_src, 'materializations = { "table", "view", "materialized_view" }')
assert_true(
  "server no table/view-only probe literal",
  not server_src:find('materializations = { "table", "view" }', 1, true)
)

local postgres_query = lsp_init_src:match("postgres = %[%[(.-)%]%],%s+mysql =")
assert_true("postgres metadata query found", postgres_query ~= nil)
assert_contains("postgres metadata pg_class", postgres_query, "FROM pg_catalog.pg_class c")
assert_contains("postgres metadata relkind p", postgres_query, "WHEN 'p' THEN 'table'")
assert_contains("postgres metadata relkind f", postgres_query, "WHEN 'f' THEN 'table'")
assert_contains("postgres metadata relkind v", postgres_query, "WHEN 'v' THEN 'view'")
assert_contains("postgres metadata relkind m", postgres_query, "WHEN 'm' THEN 'materialized_view'")
assert_true("postgres metadata no information_schema", not postgres_query:find("information_schema.tables", 1, true))
assert_true("postgres metadata no base-table collapse", not postgres_query:find("BASE TABLE", 1, true))

assert_contains("hover materialized view label", object_docs_src, "Materialized View")

local fake_expansions = {}
package.loaded["dbee.ui.drawer.expansion"] = {
  get = function()
    return fake_expansions
  end,
}

local convert = require("dbee.ui.drawer.convert")
local drawer_model = require("dbee.ui.drawer.model")
local DrawerUI = require("dbee.ui.drawer")
local SchemaCache = require("dbee.lsp.schema_cache")
local object_docs = require("dbee.lsp.object_docs")

assert_true("model SEARCHABLE_TYPES admits mv", drawer_model.SEARCHABLE_TYPES.materialized_view == true)

local decorated = convert.decorate_structure_node(
  { id = "mv-node", name = "mv_sales", type = "materialized_view" },
  {
    connection_get_helpers = function()
      return {}
    end,
  },
  { set_call = function() end },
  "conn",
  { id = "mv-node", name = "mv_sales", schema = "public", type = "materialized_view" },
  function()
    return { "lazy-children-requested" }
  end
)
assert_true("mv reaches decorate_structure_node lazy branch", type(decorated.lazy_children) == "function")
assert_eq("mv lazy children requested", decorated.lazy_children()[1], "lazy-children-requested")

local rich_calls = { columns = {}, indexes = {} }
local fake_handler = {
  connection_supports_rich_metadata = function()
    return { columns = true, indexes = true, sequences = true }
  end,
  connection_get_columns_rich_async = function(_, _conn_id, _request_id, _branch_id, _root_epoch, opts)
    rich_calls.columns[#rich_calls.columns + 1] = vim.deepcopy(opts)
  end,
  connection_get_indexes_async = function(_, _conn_id, _request_id, _branch_id, _root_epoch, opts)
    rich_calls.indexes[#rich_calls.indexes + 1] = vim.deepcopy(opts)
  end,
}
local fake_ui = setmetatable({
  handler = fake_handler,
  _connection_invalidated_consumer_id = "rich-pg",
  _struct_cache = {
    root_epoch = { conn = 0 },
    branches = { conn = {} },
  },
}, { __index = DrawerUI })
function fake_ui:_ensure_rich_metadata_branch(_conn_id, _branch_id, _kind, _metadata, start)
  if type(start) == "function" then
    start(1)
  end
  return {}
end

local mv_children = fake_ui:_build_rich_table_children("conn", "conn.public.mv_sales", {
  id = "conn.public.mv_sales",
  name = "mv_sales",
  schema = "public",
  type = "materialized_view",
})
assert_eq("mv folder child count", #mv_children, 2)
assert_eq("mv columns folder", mv_children[1].name, "Columns")
assert_eq("mv indexes folder", mv_children[2].name, "Indexes")
assert_eq("mv columns request materialization", rich_calls.columns[1].materialization, "materialized_view")
mv_children[2].lazy_children()
assert_eq("mv indexes request materialization", rich_calls.indexes[1].materialization, "materialized_view")

fake_expansions = {
  conn = true,
  ["conn\31schema"] = true,
  ["conn\31schema\31table"] = true,
  ["conn\31schema\31mv"] = true,
}
local nodes = {
  conn = { type = "connection" },
  ["conn\31schema"] = { type = "schema" },
  ["conn\31schema\31table"] = { type = "table" },
  ["conn\31schema\31mv"] = { type = "materialized_view" },
}
local capture_ui = setmetatable({
  tree = {
    get_node = function(_, id)
      return nodes[id]
    end,
  },
  _replay_container_expansions = {},
}, { __index = DrawerUI })
capture_ui:_capture_container_expansions("conn")
local captured = capture_ui._replay_container_expansions.conn
assert_true("schema expansion captured", captured["conn\31schema"] == true)
assert_true("table expansion excluded", captured["conn\31schema\31table"] == nil)
assert_true("mv expansion excluded like table", captured["conn\31schema\31mv"] == nil)

local yank_node = {
  type = "materialized_view",
  schema = "public",
  name = "mv_sales",
}
local yank_ui = setmetatable({
  tree = {
    get_node = function()
      return yank_node
    end,
  },
  handler = {},
}, { __index = DrawerUI })
yank_ui:get_actions().yank_name()
assert_eq("materialized view yank name", vim.fn.getreg('"'), "public.mv_sales")

local schema_filter = require("dbee.schema_filter")
local lsp_calls = { sync = {}, async = {} }
local handler = {
  get_schema_filter_normalized = function()
    return schema_filter.normalize(nil, "postgres")
  end,
  get_authoritative_root_epoch = function()
    return 0
  end,
  connection_get_columns = function(_, _conn_id, opts)
    lsp_calls.sync[#lsp_calls.sync + 1] = vim.deepcopy(opts)
    if opts.materialization == "materialized_view" then
      return { { name = "id", type = "integer" } }
    end
    return nil
  end,
  connection_get_columns_async = function(_, _conn_id, _request_id, _branch_id, _root_epoch, opts)
    lsp_calls.async[#lsp_calls.async + 1] = vim.deepcopy(opts)
  end,
}
local cache = SchemaCache:new(handler, "conn")
assert_true(
  "metadata rows build",
  cache:build_from_metadata_rows({
    { schema_name = "public", table_name = "base_table", obj_type = "table" },
    { schema_name = "public", table_name = "partitioned_table", obj_type = "table" },
    { schema_name = "public", table_name = "foreign_table", obj_type = "table" },
    { schema_name = "public", table_name = "plain_view", obj_type = "view" },
    { schema_name = "public", table_name = "mv_sales", obj_type = "materialized_view" },
  }, { root_epoch = 0 })
)
assert_eq("base table metadata", cache.tables.public.base_table.type, "table")
assert_eq("partitioned table metadata", cache.tables.public.partitioned_table.type, "table")
assert_eq("foreign table metadata", cache.tables.public.foreign_table.type, "table")
assert_eq("view metadata", cache.tables.public.plain_view.type, "view")
assert_eq("mv metadata", cache.tables.public.mv_sales.type, "materialized_view")
assert_eq("find mv in schema", cache:find_table_in_schema("public", "mv_sales"), "mv_sales")

local completion_items = cache:get_table_completion_items("public", { include_data = true })
local mv_completion
for _, item in ipairs(completion_items) do
  if item.label == "mv_sales" then
    mv_completion = item
    break
  end
end
assert_true("mv completion item exists", mv_completion ~= nil)
assert_eq("mv completion kind class", mv_completion.kind, 7)
assert_contains("mv completion detail type", mv_completion.detail, "(materialized_view)")

local probed = cache:get_columns("public", "mv_probe", {
  probe_if_missing = true,
  schema_quoted = true,
  table_quoted = true,
})
assert_eq("mv sync probe columns", #probed, 1)
assert_eq("mv sync probe resolved materialization", cache.tables.public.mv_probe.type, "materialized_view")
assert_eq("mv sync probe reached materialized view", lsp_calls.sync[#lsp_calls.sync].materialization, "materialized_view")

cache:get_columns_async("public", "mv_async", {
  probe_if_missing = true,
  schema_quoted = true,
  table_quoted = true,
  materializations = { "table", "view", "materialized_view" },
})
assert_eq("mv async server probe starts at table", lsp_calls.async[1].materialization, "table")
assert_contains("server source carries mv probe", server_src, 'materializations = { "table", "view", "materialized_view" }')

local hover = object_docs.format_hover({
  kind = "table",
  schema = "public",
  table = "mv_sales",
  table_type = "materialized_view",
}, {
  client_capabilities = {
    textDocument = {
      hover = {
        contentFormat = { "markdown" },
      },
    },
  },
})
assert_contains("mv hover label", hover.value, "Materialized View")

mark("RICH_PG_MATERIALIZED_VIEW_FOLDER_OK")
mark("RICH_PG_MATERIALIZED_VIEW_COLUMNS_OK")
mark("RICH_PG_MATERIALIZED_VIEW_INDEXES_OK")

vim.cmd("qa!")
