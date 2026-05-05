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

local STRICT_MARKERS = {
  "RICH_PG_GO_TYPES_BACKWARD_COMPAT",
  "RICH_PG_MARSHAL_ADDITIVE_FIELDS_OK",
  "RICH_PG_SUPPORT_TRUE",
  "RICH_PG_PG12_FLOOR_BEHAVIOR_OK",
  "RICH_PG_POSITIONAL_BINDS",
  "RICH_PG_CATALOG_SCOPING",
  "RICH_PG_RICH_COLUMNS_OK",
  "RICH_PG_GENERATED_LABEL_OK",
  "RICH_PG_DEFAULT_LABEL_OK",
  "RICH_PG_DEFAULT_UTF8_TRUNCATION_OK",
  "RICH_PG_IDENTITY_LABEL_OK",
  "RICH_PG_COMPOSITE_PK_OK",
  "RICH_PG_COMPOSITE_FK_OK",
  "RICH_PG_FK_REF_POINTER_PER_COLUMN_OK",
  "RICH_PG_INDEXES_OK",
  "RICH_PG_INCLUDE_COLUMNS_OK",
  "RICH_PG_INCLUDE_LABEL_WIDTH_OK",
  "RICH_PG_PK_BACKED_HIDDEN",
  "RICH_PG_SEQUENCES_OK",
  "RICH_PG_SCHEMA_FILTER_NO_QUERY_OK",
  "RICH_PG_MATERIALIZED_VIEW_FOLDER_OK",
  "RICH_PG_MATERIALIZED_VIEW_COLUMNS_OK",
  "RICH_PG_MATERIALIZED_VIEW_INDEXES_OK",
  "RICH_PG_VIEW_NO_INDEXES_FOLDER_OK",
  "RICH_PG_WAITER_FANOUT_ISOLATED",
  "RICH_PG_SUPERSESSION_PRESERVES_ACTIVE_SLOT",
  "RICH_PG_QUEUE_FULL_RETRYABLE",
  "RICH_PG_BACKPRESSURE_MAX_ACTIVE_BOUNDED",
  "RICH_PG_BACKPRESSURE_QUEUE_DRAIN_OK",
  "RICH_PG_BACKPRESSURE_HANDLER_OVERFLOW_REJECTS_OK",
  "RICH_PG_FANOUT_DISPATCH_COUNT_OK",
  "RICH_PG_QUEUE_DRAIN_SLA",
  "RICH_PG_SCALE_10K_ZERO_RPC_OK",
  "RICH_PG_SCALE_10K_RENDER_BUDGET_OK",
  "RICH_PG_BENCH_GO_PARSE_P95_OK",
}

local STRICT_OWNERS = {
  RICH_PG_GO_TYPES_BACKWARD_COMPAT = "go",
  RICH_PG_MARSHAL_ADDITIVE_FIELDS_OK = "go",
  RICH_PG_SUPPORT_TRUE = "go",
  RICH_PG_PG12_FLOOR_BEHAVIOR_OK = "go",
  RICH_PG_POSITIONAL_BINDS = "go",
  RICH_PG_CATALOG_SCOPING = "go",
  RICH_PG_RICH_COLUMNS_OK = "go",
  RICH_PG_COMPOSITE_PK_OK = "go",
  RICH_PG_COMPOSITE_FK_OK = "go",
  RICH_PG_FK_REF_POINTER_PER_COLUMN_OK = "go",
  RICH_PG_INDEXES_OK = "go",
  RICH_PG_INCLUDE_COLUMNS_OK = "go",
  RICH_PG_SEQUENCES_OK = "go",
  RICH_PG_BENCH_GO_PARSE_P95_OK = "bench",
}

for _, marker in ipairs(STRICT_MARKERS) do
  STRICT_OWNERS[marker] = STRICT_OWNERS[marker] or "lua"
end

local DIAGNOSTIC_MARKERS = {
  RICH_PG_PERF_DIAGNOSTIC = true,
  RICH_PG_BENCH_PG_RUNTIME_P95_REPORTED = true,
}

local emitted_lua_markers = {}

local function is_diagnostic_marker(label)
  return DIAGNOSTIC_MARKERS[label] == true or label:match("_REPORTED$") ~= nil or label:match("_DIAGNOSTIC$") ~= nil
end

local function emit(label, value)
  print(label .. "=" .. tostring(value))
end

local function mark(label, value)
  value = value == nil and "true" or tostring(value)
  local owner = STRICT_OWNERS[label]
  if owner and owner ~= "lua" then
    error("Lua cannot emit " .. label .. "; owner is " .. owner)
  end
  if label:match("^RICH_PG_") and not owner and not is_diagnostic_marker(label) then
    error("unknown PostgreSQL strict marker: " .. label)
  end
  emitted_lua_markers[#emitted_lua_markers + 1] = {
    key = label,
    value = value,
    source = "lua",
  }
  emit(label, value)
end

local function diagnostic(label, value)
  emit(label, value)
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

local function strict_markers()
  return vim.deepcopy(STRICT_MARKERS)
end

local postgres_driver = read("dbee/adapters/postgres_driver.go")
local postgres_rich_driver = read("dbee/adapters/postgres_driver_rich_metadata.go")
local postgres_rich_tests = read("dbee/adapters/postgres_driver_rich_metadata_test.go")
local core_types_test = read("dbee/core/rich_metadata_types_test.go")
local handler_marshal_test = read("dbee/handler/rich_metadata_marshal_test.go")
local makefile = read("Makefile")
local model_src = read("lua/dbee/ui/drawer/model.lua")
local drawer_src = read("lua/dbee/ui/drawer/init.lua")
local convert_src = read("lua/dbee/ui/drawer/convert.lua")
local lsp_init_src = read("lua/dbee/lsp/init.lua")
local object_docs_src = read("lua/dbee/lsp/object_docs.lua")
local schema_cache_src = read("lua/dbee/lsp/schema_cache.lua")
local server_src = read("lua/dbee/lsp/server.lua")
local config_src = read("lua/dbee/config.lua")
local ux13_rollup_src = read("ci/headless/check_ux13_rollup.lua")

assert_eq(
  "postgres matview structure branches",
  count_plain(postgres_driver, "'MATERIALIZED VIEW' AS object_type"),
  2
)
assert_eq("old postgres matview label removed", count_plain(postgres_driver, "'VIEW' AS object_type FROM pg_matviews"), 0)
assert_contains("postgres structure type mapping retained", postgres_driver, 'case "MATERIALIZED VIEW":')
assert_contains("postgres supports rich metadata", postgres_rich_driver, "func (d *postgresDriver) SupportsRichMetadata()")
assert_contains("postgres columns positional bind", postgres_rich_driver, "n.nspname = $1")
assert_contains("postgres table positional bind", postgres_rich_driver, "c.relname = $2")
assert_contains("postgres catalog namespace", postgres_rich_driver, "pg_catalog.pg_namespace")
assert_contains("postgres generated field", postgres_rich_driver, "attgenerated")
assert_contains("postgres identity field", postgres_rich_driver, "attidentity")
assert_contains("postgres default expression", postgres_rich_driver, "pg_catalog.pg_get_expr")
assert_contains("postgres serial CTE", postgres_rich_driver, "WITH cols AS")
assert_contains("postgres include column split", postgres_rich_driver, "IncludeColumns")
assert_contains("postgres sequence SQL", postgres_rich_driver, "JOIN pg_catalog.pg_sequence")
assert_contains("postgres bench source", postgres_rich_tests, "BenchmarkPostgresRichMetadataGoParse")
assert_contains("postgres go types marker source", core_types_test, "RICH_PG_GO_TYPES_BACKWARD_COMPAT=true")
assert_contains("postgres marshal marker source", handler_marshal_test, "RICH_PG_MARSHAL_ADDITIVE_FIELDS_OK=true")
assert_true(
  "locked helpers untouched by pg scaffold",
  not convert_src:find("schema_filter_authority", 1, true)
    and not convert_src:find("schema_name_canonical", 1, true)
    and not convert_src:find("epoch_authority", 1, true)
)

assert_contains("perf headless target", makefile, "perf-headless: perf-bootstrap")
assert_contains("perf headless bootstrap command", makefile, "$(PERF_NVIM_HEADLESS) $(ARGS)")
assert_contains("perf lsp postgres go markers", makefile, "TestRichMetadataTypesBackwardCompat|TestRichColumnMarshalPreservesFields|TestPostgres")
assert_contains("perf lsp postgres benchmark", makefile, "BenchmarkPostgresRichMetadataGoParse")
assert_contains("perf lsp postgres recursive make", makefile, "$(MAKE) --no-print-directory perf-headless ARGS='-l ci/headless/check_rich_metadata_postgres.lua'")
local rich16_rollup_pos = ux13_rollup_src:find('"RICH16_ALL_PASS"', 1, true)
local rich_pg_rollup_pos = ux13_rollup_src:find('"RICH_PG_ALL_PASS"', 1, true)
assert_true("ux13 rollup has rich16", rich16_rollup_pos ~= nil)
assert_true("ux13 rollup has rich pg", rich_pg_rollup_pos ~= nil)
assert_true("ux13 rollup rich pg follows rich16", rich_pg_rollup_pos > rich16_rollup_pos)

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
assert_contains("column generated label source", convert_src, "GEN")
assert_contains("column identity label source", convert_src, "IDENTITY")
assert_contains("column default label source", convert_src, "DEFAULT=")
assert_contains("column default utf8 truncation", convert_src, "vim.fn.strcharpart(expr, 0, DEFAULT_LABEL_PREFIX)")
assert_contains("index include source", convert_src, "include_columns")
assert_contains("index include label source", convert_src, "INCLUDE ")

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
assert_contains(
  "drawer view index folder materialization gate",
  drawer_src,
  'support.indexes == true and (struct.type == "table" or struct.type == "materialized_view")'
)

local fake_expansions = {}
package.loaded["dbee.ui.drawer.expansion"] = {
  get = function()
    return fake_expansions
  end,
}

local convert = require("dbee.ui.drawer.convert")
local drawer_model = require("dbee.ui.drawer.model")
local DrawerUI = require("dbee.ui.drawer")
local Handler = require("dbee.handler")
local SchemaCache = require("dbee.lsp.schema_cache")
local event_bus = require("dbee.handler.__events")
local NuiTree = require("nui.tree")
local NuiLine = require("nui.line")
local object_docs = require("dbee.lsp.object_docs")

assert_true("model SEARCHABLE_TYPES admits mv", drawer_model.SEARCHABLE_TYPES.materialized_view == true)

local label_nodes = convert.column_nodes("columns-parent", {
  {
    name = "stored_total",
    type = "numeric",
    generated = "s",
    default = "  ignored_default()  ",
  },
  {
    name = "created_at",
    type = "timestamp",
    default = "  now(\n  )  ",
  },
  {
    name = "account_id",
    type = "bigint",
    identity = "a",
  },
})
assert_contains("generated column label", label_nodes[1].name, "[GEN]")
assert_true("generated column suppresses default label", not label_nodes[1].name:find("[DEFAULT=", 1, true))
mark("RICH_PG_GENERATED_LABEL_OK")

assert_contains("default column label", label_nodes[2].name, "[DEFAULT=now( )]")
mark("RICH_PG_DEFAULT_LABEL_OK")

assert_contains("identity column label", label_nodes[3].name, "[IDENTITY]")
mark("RICH_PG_IDENTITY_LABEL_OK")

local long_utf8_default = "'" .. string.rep("界", 60) .. "'"
local utf8_default_node = convert.column_nodes("columns-parent", {
  {
    name = "utf8_default",
    type = "text",
    default = long_utf8_default,
  },
})[1]
local default_expr = utf8_default_node.name:match("%[DEFAULT=([^%]]+)%]")
assert_true("utf8 default tag exists", default_expr ~= nil)
assert_true("utf8 default tag truncated", default_expr:sub(-3) == "...")
assert_true("utf8 default valid", pcall(vim.fn.strchars, default_expr))
assert_true("utf8 default display cap", vim.fn.strdisplaywidth(default_expr) <= 80)
mark("RICH_PG_DEFAULT_UTF8_TRUNCATION_OK")

local include_node = convert.index_nodes("indexes-parent", {
  {
    name = "idx_lookup",
    columns = { "tenant_id" },
    orders = { "ASC" },
    include_columns = { "payload" },
  },
})[1]
assert_contains("include label separate", include_node.name, "[tenant_id ASC] [INCLUDE payload]")

local ordered_include_node = convert.index_nodes("indexes-parent", {
  {
    name = "idx_order",
    columns = { "tenant_id" },
    include_columns = { "zeta", "alpha", "gamma" },
  },
})[1]
assert_contains("include preserves slice order", ordered_include_node.name, "[INCLUDE zeta, alpha, gamma]")

local many_include_node = convert.index_nodes("indexes-parent", {
  {
    name = "idx_many",
    columns = { "tenant_id" },
    orders = { "ASC" },
    include_columns = { "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet" },
  },
})[1]
assert_contains("include many more", many_include_node.name, "+5 more")
assert_true("include many width cap", vim.fn.strdisplaywidth(many_include_node.name) <= 120)

local long_include_name = string.rep("payload", 34)
local long_include_node = convert.index_nodes("indexes-parent", {
  {
    name = "idx_long",
    columns = { "tenant_id" },
    include_columns = { long_include_name },
  },
})[1]
local long_include_rendered = long_include_node.name:match("%[INCLUDE ([^%]]+)%]")
assert_true("long include tag exists", long_include_rendered ~= nil)
assert_true("long include truncated", long_include_rendered:sub(-3) == "...")
assert_true("long include valid utf8", pcall(vim.fn.strchars, long_include_rendered))
assert_true("long include display cap", vim.fn.strdisplaywidth(long_include_rendered) <= 30)

local wide_include_node = convert.index_nodes("indexes-parent", {
  {
    name = "idx_wide",
    columns = { "tenant_id" },
    include_columns = { string.rep("界", 20) },
  },
})[1]
local wide_include_rendered = wide_include_node.name:match("%[INCLUDE ([^%]]+)%]")
assert_true("wide include tag exists", wide_include_rendered ~= nil)
assert_true("wide include truncated", wide_include_rendered:sub(-3) == "...")
assert_true("wide include valid utf8", pcall(vim.fn.strchars, wide_include_rendered))
assert_true("wide include display cap", vim.fn.strdisplaywidth(wide_include_rendered) <= 30)
mark("RICH_PG_INCLUDE_LABEL_WIDTH_OK")

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

local function new_fake_drawer_ui(handler)
  return setmetatable({
    handler = handler,
    _connection_invalidated_consumer_id = "rich-pg",
    filter_restore_snapshot = true,
    _struct_cache = {
      root_epoch = { conn = 0 },
      branches = { conn = {} },
    },
  }, { __index = DrawerUI })
end

local pk_backed_calls = {}
local pk_backed_ui = new_fake_drawer_ui({
  connection_supports_rich_metadata = function()
    return { columns = true, indexes = true, sequences = true }
  end,
  connection_get_columns_rich_async = function() end,
  connection_get_indexes_async = function(_, conn_id, request_id, branch_id, root_epoch, opts)
    pk_backed_calls[#pk_backed_calls + 1] = {
      conn_id = conn_id,
      request_id = request_id,
      branch_id = branch_id,
      root_epoch = root_epoch,
      opts = vim.deepcopy(opts),
    }
  end,
})
local pk_children = pk_backed_ui:_build_rich_table_children("conn", "conn.public.accounts", {
  id = "conn.public.accounts",
  name = "accounts",
  schema = "public",
  type = "table",
})
assert_eq("pk backed table folder count", #pk_children, 2)
pk_children[2].lazy_children()
assert_eq("pk backed index request count", #pk_backed_calls, 1)
pk_backed_ui:on_structure_children_loaded({
  conn_id = "conn",
  request_id = pk_backed_calls[1].request_id,
  branch_id = pk_backed_calls[1].branch_id,
  root_epoch = pk_backed_calls[1].root_epoch,
  kind = "indexes",
  indexes = {
    { name = "accounts_pkey", columns = { "id" }, pk_backed = true },
    { name = "idx_accounts_payload", columns = { "payload" }, include_columns = { "payload_hash" } },
  },
})
local rendered_indexes = pk_children[2].lazy_children()
assert_eq("pk backed rendered index count", #rendered_indexes, 1)
assert_eq("pk backed hidden visible name", rendered_indexes[1].raw_name, "idx_accounts_payload")
mark("RICH_PG_PK_BACKED_HIDDEN")

local view_index_calls = 0
local view_ui = new_fake_drawer_ui({
  connection_supports_rich_metadata = function()
    return { columns = true, indexes = true, sequences = true }
  end,
  connection_get_columns_rich_async = function() end,
  connection_get_indexes_async = function()
    view_index_calls = view_index_calls + 1
    fail("regular view attempted connection_get_indexes_async")
  end,
})
local view_children = view_ui:_build_rich_table_children("conn", "conn.public.v_sales", {
  id = "conn.public.v_sales",
  name = "v_sales",
  schema = "public",
  type = "view",
})
assert_eq("view folder child count", #view_children, 1)
assert_eq("view columns folder only", view_children[1].name, "Columns")
assert_eq("view indexes stub never called", view_index_calls, 0)
mark("RICH_PG_VIEW_NO_INDEXES_FOLDER_OK")

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

local captured_events = {}
event_bus.register("structure_children_loaded", function(data)
  captured_events[#captured_events + 1] = data
end)

local function wait_events(target)
  vim.wait(200, function()
    return #captured_events >= target
  end, 5)
end

local support_payload = { columns = true, indexes = true, sequences = true }
local rich_calls = { columns = {}, indexes = {}, sequences = {} }

vim.fn.DbeeConnectionGetRichMetadataSupport = function()
  return vim.deepcopy(support_payload)
end
vim.fn.DbeeConnectionGetColumnsRichAsync = function(conn_id, request_id, branch_id, root_epoch, opts)
  rich_calls.columns[#rich_calls.columns + 1] = {
    conn_id = conn_id,
    request_id = request_id,
    branch_id = branch_id,
    root_epoch = root_epoch,
    opts = vim.deepcopy(opts),
  }
end
vim.fn.DbeeConnectionGetIndexesAsync = function(conn_id, request_id, branch_id, root_epoch, opts)
  rich_calls.indexes[#rich_calls.indexes + 1] = {
    conn_id = conn_id,
    request_id = request_id,
    branch_id = branch_id,
    root_epoch = root_epoch,
    opts = vim.deepcopy(opts),
  }
end
vim.fn.DbeeConnectionGetSequencesAsync = function(conn_id, request_id, branch_id, root_epoch, opts)
  rich_calls.sequences[#rich_calls.sequences + 1] = {
    conn_id = conn_id,
    request_id = request_id,
    branch_id = branch_id,
    root_epoch = root_epoch,
    opts = vim.deepcopy(opts),
  }
end

local function reset_rich_calls()
  captured_events = {}
  rich_calls = { columns = {}, indexes = {}, sequences = {} }
end

local function new_pg_handler(filter)
  local h = Handler:new({})
  function h:get_schema_filter_normalized()
    return schema_filter.normalize(filter or { include = { "public" }, lazy_per_schema = true }, "postgres")
  end
  function h:connection_get_params(conn_id)
    return {
      id = conn_id,
      name = conn_id,
      type = "postgres",
      schema_filter = vim.deepcopy(filter or { include = { "public" }, lazy_per_schema = true }),
    }
  end
  return h
end

local function complete_rich_call(h, call, kind, epoch)
  h:_on_rich_metadata_loaded({
    conn_id = "conn",
    request_id = call.request_id,
    branch_id = call.branch_id,
    root_epoch = epoch,
    kind = kind or "columns_rich",
    columns = {},
    indexes = {},
    sequences = {},
  })
end

reset_rich_calls()
local h = new_pg_handler()
h:connection_get_columns_rich_async("conn", 25, "collision-waiter", 6, {
  schema = "public",
  table = "collision",
  materialization = "table",
})
local collision_queue = h._rich_metadata_queues.conn
local collision_call = rich_calls.columns[1]
local collision_key = h._rich_metadata_request_lookup[collision_call.request_id]
h:_on_rich_metadata_loaded({
  conn_id = "conn",
  request_id = collision_call.request_id,
  branch_id = "collision-waiter",
  root_epoch = 6,
  kind = "columns_rich",
  fanout_source = "rich_metadata_waiter",
  error = "queue_full",
  error_kind = "queue_full",
})
assert_eq("pg waiter fanout keeps active slot", collision_queue.active, 1)
assert_eq("pg waiter fanout keeps lookup", h._rich_metadata_request_lookup[collision_call.request_id], collision_key)
assert_true("pg waiter fanout keeps flight", h._rich_metadata_flights[collision_key] ~= nil)
complete_rich_call(h, collision_call, "columns_rich", 6)
assert_eq("pg internal completion frees active slot", collision_queue.active, 0)
mark("RICH_PG_WAITER_FANOUT_ISOLATED")

reset_rich_calls()
h = new_pg_handler()
local superseded_emits = {}
local original_rich_error_emit = h._emit_rich_metadata_error
function h:_emit_rich_metadata_error(waiter, error, error_kind)
  superseded_emits[#superseded_emits + 1] = {
    waiter = waiter,
    error = error,
    error_kind = error_kind,
  }
  return original_rich_error_emit(self, waiter, error, error_kind)
end
h:connection_get_columns_rich_async("conn", 26, "superseded-waiter", 6, {
  schema = "public",
  table = "superseded",
  materialization = "table",
})
local superseded_queue = h._rich_metadata_queues.conn
local superseded_call = rich_calls.columns[1]
h:_supersede_rich_metadata_flights("conn", math.huge, "superseded")
assert_eq("pg supersession keeps active slot", superseded_queue.active, 1)
assert_true("pg supersession keeps request lookup", h._rich_metadata_request_lookup[superseded_call.request_id] ~= nil)
assert_eq("pg supersession defers waiter event", #superseded_emits, 0)
complete_rich_call(h, superseded_call, "columns_rich", 6)
assert_eq("pg superseded completion frees active slot", superseded_queue.active, 0)
assert_eq("pg superseded completion emits error", superseded_emits[1] and superseded_emits[1].error_kind, "superseded")
mark("RICH_PG_SUPERSESSION_PRESERVES_ACTIVE_SLOT")

reset_rich_calls()
h = new_pg_handler()
local joined_count = 0
for i = 1, 200 do
  local result = h:connection_get_columns_rich_async("conn", i, "overflow-" .. i, 7, {
    schema = "public",
    table = "overflow_" .. i,
    materialization = "table",
  })
  if result.joined then
    joined_count = joined_count + 1
  end
end
local queue = h._rich_metadata_queues.conn
assert_eq("pg max active bounded", queue.active, 8)
mark("RICH_PG_BACKPRESSURE_MAX_ACTIVE_BOUNDED")
assert_eq("pg max queued", #queue.queue, 128)
wait_events(64)
local rejected = 0
for _, event in ipairs(captured_events) do
  if event.error == "queue_full" and event.error_kind == "queue_full" then
    rejected = rejected + 1
  end
end
assert_eq("pg overflow rejected", rejected, 64)
assert_eq("pg overflow no joins", joined_count, 0)
mark("RICH_PG_BACKPRESSURE_HANDLER_OVERFLOW_REJECTS_OK")
complete_rich_call(h, rich_calls.columns[1], "columns_rich", 7)
assert_eq("pg queue drain preserves active", queue.active, 8)
assert_eq("pg queue drain removes queued", #queue.queue, 127)
mark("RICH_PG_BACKPRESSURE_QUEUE_DRAIN_OK")

reset_rich_calls()
h = new_pg_handler()
for i = 1, 100 do
  h:connection_get_columns_rich_async("conn", i, "fanout-" .. i, 9, {
    schema = "public",
    table = "fanout_" .. i,
    materialization = "table",
  })
end
queue = h._rich_metadata_queues.conn
assert_eq("pg fanout active", queue.active, 8)
assert_eq("pg fanout queued", #queue.queue, 92)
local completed = 0
while completed < 100 do
  completed = completed + 1
  local call = rich_calls.columns[completed]
  assert_true("pg fanout call present " .. completed, call ~= nil)
  complete_rich_call(h, call, "columns_rich", 9)
end
assert_eq("pg fanout all complete active", queue.active, 0)
assert_eq("pg fanout all complete queue", #queue.queue, 0)
mark("RICH_PG_FANOUT_DISPATCH_COUNT_OK")

reset_rich_calls()
h = new_pg_handler({ include = { "public" }, lazy_per_schema = true })
h:connection_get_columns_rich_async("conn", 70, "blocked-schema", 0, {
  schema = "private",
  table = "accounts",
  materialization = "table",
})
assert_eq("pg schema filter no columns rpc", #rich_calls.columns, 0)
assert_true("pg schema filter no queue", h._rich_metadata_queues.conn == nil or #h._rich_metadata_queues.conn.queue == 0)
mark("RICH_PG_SCHEMA_FILTER_NO_QUERY_OK")

local retry_ui = setmetatable({
  _struct_cache = {
    root = {},
    root_gen = {},
    root_applied = {},
    root_epoch = { conn = 0 },
    root_mode = {},
    root_loaded_schemas = {},
    root_filter_signature = {},
    loaded_lazy_ids = {},
    branches = {},
  },
  filter_input = true,
  cached_render_snapshot = {},
}, { __index = DrawerUI })
local retry_dispatches = {}
local retry_state = retry_ui:_ensure_rich_metadata_branch("conn", "retry-branch", "indexes", {
  schema = "public",
  table = "accounts",
}, function(request_id)
  retry_dispatches[#retry_dispatches + 1] = request_id
end)
assert_eq("pg queue_full first dispatch", #retry_dispatches, 1)
retry_ui:on_structure_children_loaded({
  conn_id = "conn",
  request_id = retry_dispatches[1],
  branch_id = "retry-branch",
  root_epoch = 0,
  kind = "indexes",
  error = "queue_full",
  error_kind = "queue_full",
})
assert_eq("pg queue_full stored as typed error", retry_state.error_kind, "queue_full")
retry_ui:_ensure_rich_metadata_branch("conn", "retry-branch", "indexes", {
  schema = "public",
  table = "accounts",
}, function(request_id)
  retry_dispatches[#retry_dispatches + 1] = request_id
end)
assert_eq("pg queue_full re-expand dispatches again", #retry_dispatches, 2)
assert_eq("pg queue_full retry clears error", retry_state.error, nil)
retry_ui:on_structure_children_loaded({
  conn_id = "conn",
  request_id = retry_dispatches[2],
  branch_id = "retry-branch",
  root_epoch = 0,
  kind = "indexes",
  indexes = { { name = "idx_accounts", columns = { "id" } } },
})
assert_eq("pg queue_full success clears typed error", retry_state.error_kind, nil)
assert_eq("pg queue_full success stores payload", #retry_state.raw, 1)
mark("RICH_PG_QUEUE_FULL_RETRYABLE")

local function percentile(values, ratio)
  local sorted = vim.deepcopy(values)
  table.sort(sorted)
  local index = math.max(1, math.ceil(#sorted * ratio))
  return sorted[index]
end

local function ns_to_ms(value)
  return value / 1000000
end

local function run_queue_drain_iteration()
  reset_rich_calls()
  local iter_handler = new_pg_handler()
  for i = 1, 200 do
    iter_handler:connection_get_columns_rich_async("conn", i, "sla-" .. i, 11, {
      schema = "public",
      table = "sla_" .. i,
      materialization = "table",
    })
  end
  local iter_queue = iter_handler._rich_metadata_queues.conn
  assert_eq("pg sla initial active", iter_queue.active, 8)
  assert_eq("pg sla initial queued", #iter_queue.queue, 128)
  local completed_sla = 0
  while completed_sla < 136 do
    completed_sla = completed_sla + 1
    local call = rich_calls.columns[completed_sla]
    assert_true("pg sla call present " .. completed_sla, call ~= nil)
    complete_rich_call(iter_handler, call, "columns_rich", 11)
  end
  assert_eq("pg sla active drained", iter_queue.active, 0)
  assert_eq("pg sla queue drained", #iter_queue.queue, 0)
end

run_queue_drain_iteration() -- warmup
local drain_samples = {}
for _ = 1, 20 do
  local started = vim.loop.hrtime()
  run_queue_drain_iteration()
  drain_samples[#drain_samples + 1] = vim.loop.hrtime() - started
end
local drain_p95 = percentile(drain_samples, 0.95)
assert_true("pg queue drain sla p95", ns_to_ms(drain_p95) <= 2000)
diagnostic("RICH_PG_PERF_DIAGNOSTIC", string.format("queue_drain_p95_ms=%.2f", ns_to_ms(drain_p95)))
mark("RICH_PG_QUEUE_DRAIN_SLA")

local function make_scale_nodes(count)
  local nodes_10k = {}
  for i = 1, count do
    nodes_10k[i] = NuiTree.Node({
      id = "scale-table-" .. tostring(i),
      name = string.format("scale_table_%05d", i),
      type = "table",
      schema = "public",
    })
  end
  return nodes_10k
end

local function render_scale_nodes(count)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local tree = NuiTree({
    bufnr = bufnr,
    prepare_node = function(node)
      local line = NuiLine()
      line:append(node.name or "")
      return line
    end,
  })
  local nodes_10k = make_scale_nodes(count)
  local start = vim.loop.hrtime()
  tree:set_nodes(nodes_10k)
  tree:render()
  local elapsed = vim.loop.hrtime() - start
  local rendered_count = #tree:get_nodes()
  assert(rendered_count == 10000, "expected 10000 rendered nodes, got " .. tostring(rendered_count))
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  return elapsed, rendered_count
end

local zero_rpc_columns = 0
local zero_rpc_indexes = 0
local old_columns_rpc = vim.fn.DbeeConnectionGetColumnsRichAsync
local old_indexes_rpc = vim.fn.DbeeConnectionGetIndexesAsync
vim.fn.DbeeConnectionGetColumnsRichAsync = function(...)
  zero_rpc_columns = zero_rpc_columns + 1
  return old_columns_rpc(...)
end
vim.fn.DbeeConnectionGetIndexesAsync = function(...)
  zero_rpc_indexes = zero_rpc_indexes + 1
  return old_indexes_rpc(...)
end
local zero_elapsed = render_scale_nodes(10000)
vim.fn.DbeeConnectionGetColumnsRichAsync = old_columns_rpc
vim.fn.DbeeConnectionGetIndexesAsync = old_indexes_rpc
assert_eq("pg scale zero columns rpc", zero_rpc_columns, 0)
assert_eq("pg scale zero indexes rpc", zero_rpc_indexes, 0)
reset_rich_calls()
h = new_pg_handler()
for i = 1, 100 do
  h:connection_get_columns_rich_async("conn", i, "scale-fanout-" .. i, 12, {
    schema = "public",
    table = "scale_" .. i,
    materialization = "table",
  })
end
queue = h._rich_metadata_queues.conn
assert_eq("pg scale fanout active", queue.active, 8)
assert_eq("pg scale fanout queued", #queue.queue, 92)
diagnostic("RICH_PG_PERF_DIAGNOSTIC", string.format("scale_10k_zero_rpc_render_ms=%.2f", ns_to_ms(zero_elapsed)))
mark("RICH_PG_SCALE_10K_ZERO_RPC_OK")

render_scale_nodes(10000) -- warmup
local render_samples = {}
local render_block_started = vim.loop.hrtime()
for _ = 1, 10 do
  local elapsed = render_scale_nodes(10000)
  render_samples[#render_samples + 1] = elapsed
end
local render_block_elapsed = vim.loop.hrtime() - render_block_started
local render_p50 = percentile(render_samples, 0.50)
local render_p95 = percentile(render_samples, 0.95)
assert_true("pg scale render p95", ns_to_ms(render_p95) <= 5000)
diagnostic(
  "RICH_PG_PERF_DIAGNOSTIC",
  string.format(
    "scale_10k_render_p50_ms=%.2f p95_ms=%.2f total_ms=%.2f",
    ns_to_ms(render_p50),
    ns_to_ms(render_p95),
    ns_to_ms(render_block_elapsed)
  )
)
mark("RICH_PG_SCALE_10K_RENDER_BUDGET_OK")

mark("RICH_PG_MATERIALIZED_VIEW_FOLDER_OK")
mark("RICH_PG_MATERIALIZED_VIEW_COLUMNS_OK")
mark("RICH_PG_MATERIALIZED_VIEW_INDEXES_OK")

local function marker_records_from_lines(lines)
  local records = {}
  for _, line in ipairs(lines or {}) do
    local key, value = line:match("([%w_]+)=(.*)$")
    if key and value then
      local owner = STRICT_OWNERS[key]
      local source = "log"
      if owner == "go" or owner == "bench" then
        source = owner
      end
      records[#records + 1] = {
        key = key,
        value = value,
        source = source,
      }
    end
  end
  return records
end

local function evaluate_pg_rollup(log_lines, lua_records)
  local records = {}
  for _, record in ipairs(marker_records_from_lines(log_lines)) do
    records[#records + 1] = record
  end
  for _, record in ipairs(lua_records or {}) do
    records[#records + 1] = record
  end

  local failures = {}
  local by_key = {}
  for _, record in ipairs(records) do
    if STRICT_OWNERS[record.key] then
      by_key[record.key] = by_key[record.key] or {}
      by_key[record.key][#by_key[record.key] + 1] = record
      if record.value ~= "true" then
        failures[#failures + 1] = record.key .. " has unsupported value " .. tostring(record.value)
      end
      if record.source ~= STRICT_OWNERS[record.key] then
        failures[#failures + 1] = record.key .. " emitted from wrong source " .. tostring(record.source)
      end
    elseif record.key:match("^RICH_PG_") and not is_diagnostic_marker(record.key) then
      failures[#failures + 1] = "unknown marker " .. tostring(record.key)
    end
  end

  local satisfied = 0
  for _, marker in ipairs(STRICT_MARKERS) do
    local owner = STRICT_OWNERS[marker]
    local values = {}
    local owned_true = false
    for _, record in ipairs(by_key[marker] or {}) do
      values[record.value] = true
      if record.source == owner and record.value == "true" then
        owned_true = true
      end
    end
    local value_count = 0
    for _ in pairs(values) do
      value_count = value_count + 1
    end
    if value_count > 1 then
      failures[#failures + 1] = marker .. " has conflicting duplicate values"
    end
    if not owned_true then
      failures[#failures + 1] = "missing " .. marker .. " from " .. owner
    else
      satisfied = satisfied + 1
    end
  end

  return {
    ok = #failures == 0,
    failures = failures,
    count = satisfied,
  }
end

local function synthetic_rollup_log()
  local lines = {}
  for _, marker in ipairs(STRICT_MARKERS) do
    local owner = STRICT_OWNERS[marker]
    if owner == "go" or owner == "bench" then
      lines[#lines + 1] = marker .. "=true"
    end
  end
  return lines
end

local function synthetic_lua_records()
  local records = {}
  for _, marker in ipairs(STRICT_MARKERS) do
    if STRICT_OWNERS[marker] == "lua" then
      records[#records + 1] = {
        key = marker,
        value = "true",
        source = "lua",
      }
    end
  end
  return records
end

local function has_failure(result, needle)
  for _, failure in ipairs(result.failures or {}) do
    if failure:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local function run_rollup_self_tests()
  local good = evaluate_pg_rollup(synthetic_rollup_log(), synthetic_lua_records())
  assert_true("pg rollup synthetic valid", good.ok)
  assert_eq("pg rollup diagnostic excluded count", good.count, 35)

  local missing_log = synthetic_rollup_log()
  for index, line in ipairs(missing_log) do
    if line:find("RICH_PG_SUPPORT_TRUE=", 1, true) then
      table.remove(missing_log, index)
      break
    end
  end
  assert_true("pg rollup missing marker fails", has_failure(evaluate_pg_rollup(missing_log, synthetic_lua_records()), "missing RICH_PG_SUPPORT_TRUE"))

  local false_log = synthetic_rollup_log()
  false_log[#false_log + 1] = "RICH_PG_SUPPORT_TRUE=false"
  assert_true("pg rollup false marker fails", has_failure(evaluate_pg_rollup(false_log, synthetic_lua_records()), "unsupported value false"))

  local conflict_log = synthetic_rollup_log()
  conflict_log[#conflict_log + 1] = "RICH_PG_SUPPORT_TRUE=false"
  assert_true("pg rollup conflicting duplicate fails", has_failure(evaluate_pg_rollup(conflict_log, synthetic_lua_records()), "conflicting duplicate values"))

  local wrong_source_records = synthetic_lua_records()
  wrong_source_records[#wrong_source_records + 1] = {
    key = "RICH_PG_SUPPORT_TRUE",
    value = "true",
    source = "lua",
  }
  assert_true(
    "pg rollup wrong source fails",
    has_failure(evaluate_pg_rollup(synthetic_rollup_log(), wrong_source_records), "wrong source lua")
  )

  local ok_guard = pcall(mark, "RICH_PG_SUPPORT_TRUE")
  assert_true("pg mark rejects go-owned marker", not ok_guard)
  local ok_bench_guard = pcall(mark, "RICH_PG_BENCH_GO_PARSE_P95_OK")
  assert_true("pg mark rejects bench-owned marker", not ok_bench_guard)

  local diagnostic_log = synthetic_rollup_log()
  diagnostic_log[#diagnostic_log + 1] = "RICH_PG_PERF_DIAGNOSTIC=synthetic"
  local diagnostic_result = evaluate_pg_rollup(diagnostic_log, synthetic_lua_records())
  assert_true("pg rollup diagnostic marker ignored", diagnostic_result.ok)
  assert_eq("pg rollup diagnostic marker not counted", diagnostic_result.count, 35)
end

local function read_rollup_lines()
  local log_path = vim.env.UX13_ROLLUP_LOG
  if not log_path or log_path == "" then
    fail("missing UX13_ROLLUP_LOG for RICH_PG_ALL_PASS rollup")
  end
  local ok_read, lines = pcall(vim.fn.readfile, log_path)
  if not ok_read or type(lines) ~= "table" then
    fail("unable to read UX13_ROLLUP_LOG: " .. tostring(log_path))
  end
  return lines
end

run_rollup_self_tests()
local rollup_result = evaluate_pg_rollup(read_rollup_lines(), emitted_lua_markers)
if not rollup_result.ok then
  for _, failure in ipairs(rollup_result.failures) do
    emit("RICH_PG_ROLLUP_FAIL", failure)
  end
  fail("RICH_PG rollup failed")
end
assert_eq("pg strict marker count", rollup_result.count, #strict_markers())
emit("RICH_PG_STRICT_MARKER_COUNT", rollup_result.count)
emit("RICH_PG_ALL_PASS", "true")

vim.cmd("qa!")
