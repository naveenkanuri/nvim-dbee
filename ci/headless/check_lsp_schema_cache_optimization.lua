-- Headless checks for Phase 11 SchemaCache indexes and LRU behavior.

local SchemaCache = require("dbee.lsp.schema_cache")
local context = require("dbee.lsp.context")
local schema_filter = require("dbee.schema_filter")
local schema_name_canonical = require("dbee.schema_name_canonical")

local function fail(msg)
  print("LSP11_SCHEMA_CACHE_OPT_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local function assert_true(label, value)
  if not value then
    fail(label .. ": expected true")
  end
end

local function assert_eq(label, actual, expected)
  if actual ~= expected then
    fail(label .. ": expected " .. vim.inspect(expected) .. " got " .. vim.inspect(actual))
  end
end

local function labels(items)
  local out = {}
  for _, item in ipairs(items) do
    out[#out + 1] = item.label
  end
  return out
end

local function scoped_cache(conn_type, id)
  local scope = assert(schema_filter.normalize(nil, conn_type))
  return SchemaCache:new({
    get_schema_filter_normalized = function()
      return scope
    end,
  }, id)
end

local function assert_sorted(label, values)
  local sorted = vim.deepcopy(values)
  table.sort(sorted)
  for i, value in ipairs(values) do
    if value ~= sorted[i] then
      fail(label .. ": not sorted: " .. vim.inspect(values))
    end
  end
end

assert_true("canonical helper api present", type(schema_name_canonical.canonical) == "function")
assert_true("canonical equivalent api present", type(schema_name_canonical.equivalent) == "function")
assert_true("canonical fold api present", type(schema_name_canonical.fold_for) == "function")
assert_true("canonical probe candidates api present", type(schema_name_canonical.probe_candidates) == "function")
assert_eq("postgres lower fold", schema_name_canonical.canonical("Public", false, "lower").canonical, "public")
assert_eq("oracle upper fold", schema_name_canonical.canonical("users", false, "upper").canonical, "USERS")
assert_eq("quoted preserved", schema_name_canonical.canonical("Public", true, "lower").canonical, "Public")
assert_true("clickhouse identity distinct", not schema_name_canonical.equivalent("Public", false, "public", false, "identity"))
assert_eq("schema filter canonical lower", schema_filter.fold("Public", "lower"), schema_name_canonical.canonical("Public", false, "lower").canonical)
assert_eq("schema filter canonical upper", schema_filter.fold("public", "upper"), schema_name_canonical.canonical("public", false, "upper").canonical)
assert_eq("schema filter legacy default fold", schema_filter.fold_id(nil), "upper")

local quoted_ref = context.parse_table_ref('"Public"."Users"')
assert_true("quoted ref parsed", quoted_ref ~= nil)
assert_eq("quoted schema metadata", quoted_ref.schema_quoted, true)
assert_eq("quoted table metadata", quoted_ref.table_quoted, true)
assert_eq("quoted schema name", quoted_ref.schema, "Public")
assert_eq("quoted table name", quoted_ref.table, "Users")
local unquoted_ref = context.parse_table_ref("Public.users")
assert_true("unquoted ref parsed", unquoted_ref ~= nil)
assert_eq("unquoted schema metadata", unquoted_ref.schema_quoted, false)
assert_eq("unquoted table metadata", unquoted_ref.table_quoted, false)

local function source(path)
  local fd = assert(io.open(path, "r"))
  local text = fd:read("*a")
  fd:close()
  return text
end

local consumer_files = {
  "lua/dbee/lsp/schema_cache.lua",
  "lua/dbee/lsp/init.lua",
  "lua/dbee/handler/init.lua",
  "lua/dbee/ui/drawer/init.lua",
}
for _, path in ipairs(consumer_files) do
  local text = source(path)
  assert_true(path .. " does not call schema_filter.fold", not text:find("schema_filter%.fold%("))
  assert_true(path .. " does not use local _fold helper", not text:find("[:%.]_fold%("))
end

local drawer_source = source("lua/dbee/ui/drawer/init.lua")
assert_true("drawer loaded schemas uses canonical helper", drawer_source:find("drawer_schema_loaded_key", 1, true) ~= nil)
assert_true("drawer loaded schemas no hardcoded case insensitive fold", not drawer_source:find("root_loaded_schemas.-case_insensitive"))

local lsp_init_source = source("lua/dbee/lsp/init.lua")
assert_true("lsp same cache identifier uses canonical helper", lsp_init_source:find("schema_name_canonical.singleflight_key", 1, true) ~= nil)

local schema_filter_source = source("lua/dbee/schema_filter.lua")
assert_true(
  "schema filter fold routes through canonical helper",
  schema_filter_source:find("schema_name_canonical.canonical", 1, true) ~= nil
)
assert_true("schema filter fold no local upper transform", not schema_filter_source:find("value:upper%("))
assert_true("schema filter fold no local lower transform", not schema_filter_source:find("value:lower%("))

local schema_cache_source = source("lua/dbee/lsp/schema_cache.lua")
assert_true("schema cache no direct upper transform", not schema_cache_source:find(":upper%("))
assert_true("schema cache no direct lower transform", not schema_cache_source:find(":lower%("))
assert_true("schema cache no fixed upper canonical probe", not schema_cache_source:find('canonical%([^%)]-"upper"'))

local cache = SchemaCache:new({}, "lsp11-schema-cache-optimization")
cache:build_from_metadata_rows({
  { schema_name = "B_SCHEMA", table_name = "VALID_TABLE", obj_type = "table" },
  { schema_name = "A_SCHEMA", table_name = "DUP_TABLE", obj_type = "table" },
  { schema_name = "B_SCHEMA", table_name = "DUP_TABLE", obj_type = "view" },
  { schema_name = "A_SCHEMA", table_name = "Z_TABLE", obj_type = "table" },
})

local schema_labels = labels(cache:get_schema_completion_items())
local a_table_labels = labels(cache:get_table_completion_items("a_schema"))
local all_table_labels = labels(cache:get_all_table_completion_items())

assert_sorted("schema completion", schema_labels)
assert_sorted("schema table completion", a_table_labels)
assert_sorted("all table completion", all_table_labels)
assert_eq("schema lookup", cache:find_schema("b_schema"), "B_SCHEMA")

local wrong_table = cache:find_table_in_schema("WRONG_SCHEMA", "VALID_TABLE")
assert_eq("schema-aware lookup rejects wrong schema", wrong_table, nil)

local pg_cache = scoped_cache("postgres", "lsp11-r6-case-lookup")
pg_cache:build_from_metadata_rows({
  { schema_name = "public", table_name = "users", obj_type = "table" },
})
pg_cache:_store_columns("public.users", {
  { name = "id", type = "integer" },
})
local public_users, public_schema = pg_cache:find_table_in_schema("PUBLIC", "USERS")
assert_eq("postgres schema lookup folds upper", pg_cache:find_schema("PUBLIC"), "public")
assert_eq("postgres schema lookup folds mixed", pg_cache:find_schema("pUbLiC"), "public")
assert_eq("postgres table lookup folds schema", public_schema, "public")
assert_eq("postgres table lookup folds table", public_users, "users")
assert_eq("postgres table completion folds schema", #pg_cache:get_table_completion_items("Public"), 1)
assert_eq("postgres column completion folds schema/table", pg_cache:get_column_completion_items("PUBLIC", "USERS")[1].label, "id")

local pg_quoted_cache = scoped_cache("postgres", "lsp11-r6-pg-quoted-distinct")
pg_quoted_cache:build_from_metadata_rows({
  { schema_name = "public", table_name = "Users", obj_type = "table" },
  { schema_name = "Public", table_name = "users", obj_type = "table" },
})
assert_eq("postgres quoted table exact", pg_quoted_cache:find_table_in_schema("PUBLIC", "Users"), "Users")
assert_eq("postgres quoted table not unquoted folded", pg_quoted_cache:find_table_in_schema("PUBLIC", "USERS"), nil)
assert_eq("postgres quoted schema exact", pg_quoted_cache:find_schema("Public"), "Public")
assert_eq("postgres quoted schema not unquoted folded", pg_quoted_cache:find_schema("pUbLiC"), "public")

local pg_unquoted_cache = scoped_cache("postgres", "lsp11-r6-unquoted-folds")
pg_unquoted_cache:build_from_metadata_rows({
  { schema_name = "public", table_name = "users", obj_type = "table" },
  { schema_name = "Public", table_name = "users", obj_type = "table" },
})
local pg_unquoted_name, pg_unquoted_schema = pg_unquoted_cache:find_table_in_schema("Public", "users", {
  schema_quoted = false,
  table_quoted = false,
})
local pg_quoted_name, pg_quoted_schema = pg_unquoted_cache:find_table_in_schema("Public", "users", {
  schema_quoted = true,
  table_quoted = false,
})
assert_eq("postgres unquoted schema uses folded canonical schema", pg_unquoted_schema, "public")
assert_eq("postgres unquoted schema uses folded canonical table", pg_unquoted_name, "users")
assert_eq("postgres quoted schema keeps exact schema", pg_quoted_schema, "Public")
assert_eq("postgres quoted schema finds exact-distinct table", pg_quoted_name, "users")

local pg_loaded_cache = scoped_cache("postgres", "lsp11-r6-loaded-exact-aware")
pg_loaded_cache:build_from_schemas({ "public", "Public" }, { preserve_loaded = false })
pg_loaded_cache:on_schema_objects_loaded({
  conn_id = "lsp11-r6-loaded-exact-aware",
  schema = "public",
  objects = {
    { type = "table", schema = "public", name = "users" },
  },
})
assert_eq("postgres unquoted loaded status", pg_loaded_cache:schema_status("public", { schema_quoted = false }), "loaded")
assert_eq("postgres quoted exact-distinct unloaded status", pg_loaded_cache:schema_status("Public", { schema_quoted = true }), "active_unloaded")

local pg_refresh_cache = scoped_cache("postgres", "lsp11-r6-refresh-exact-aware")
pg_refresh_cache:build_from_schemas({ "public" }, { preserve_loaded = false })
pg_refresh_cache:on_schema_objects_loaded({
  conn_id = "lsp11-r6-refresh-exact-aware",
  schema = "public",
  objects = {
    { type = "table", schema = "public", name = "users" },
  },
})
pg_refresh_cache:build_from_schemas({ "public", "Public" }, { preserve_loaded = true })
assert_eq("postgres refresh preserves original loaded schema", pg_refresh_cache:schema_status("public", { schema_quoted = false }), "loaded")
assert_eq("postgres refresh does not load exact-distinct schema", pg_refresh_cache:schema_status("Public", { schema_quoted = true }), "active_unloaded")
assert_eq("postgres refresh exact-distinct table items", #pg_refresh_cache:get_table_completion_items("Public", { schema_quoted = true }), 0)

local sqlite_refresh_cache = scoped_cache("sqlite", "lsp11-r6-refresh-case-insensitive")
sqlite_refresh_cache:build_from_schemas({ "Main" }, { preserve_loaded = false })
sqlite_refresh_cache:on_schema_objects_loaded({
  conn_id = "lsp11-r6-refresh-case-insensitive",
  schema = "Main",
  objects = {
    { type = "table", schema = "Main", name = "Users" },
  },
})
sqlite_refresh_cache:_store_columns("Main.Users", {
  { name = "id", type = "integer" },
})
sqlite_refresh_cache:build_from_schemas({ "MAIN" }, { preserve_loaded = true })
assert_eq("sqlite refresh preserves loaded state by canonical", sqlite_refresh_cache:schema_status("main", { schema_quoted = false }), "loaded")
assert_eq("sqlite refresh remaps preserved table items", #sqlite_refresh_cache:get_table_completion_items("MAIN", { schema_quoted = true }), 1)
assert_eq("sqlite refresh remaps preserved columns", sqlite_refresh_cache:get_column_completion_items("MAIN", "Users", { schema_quoted = true })[1].label, "id")

local oracle_cache = scoped_cache("oracle", "lsp11-r6-oracle-case-lookup")
oracle_cache:build_from_metadata_rows({
  { schema_name = "APP", table_name = "USERS", obj_type = "table" },
})
assert_eq("oracle schema lookup folds lower", oracle_cache:find_schema("app"), "APP")
assert_eq("oracle table lookup folds lower", oracle_cache:find_table_in_schema("app", "users"), "USERS")

local oracle_quoted_cache = scoped_cache("oracle", "lsp11-r6-oracle-quoted-distinct")
oracle_quoted_cache:build_from_metadata_rows({
  { schema_name = "APP", table_name = "Users", obj_type = "table" },
  { schema_name = "App", table_name = "USERS", obj_type = "table" },
})
assert_eq("oracle quoted table exact", oracle_quoted_cache:find_table_in_schema("app", "Users"), "Users")
assert_eq("oracle quoted table not unquoted folded", oracle_quoted_cache:find_table_in_schema("app", "users"), nil)
assert_eq("oracle quoted schema exact", oracle_quoted_cache:find_schema("App"), "App")
assert_eq("oracle quoted schema not unquoted folded", oracle_quoted_cache:find_schema("aPp"), "APP")

local sqlite_cache = scoped_cache("sqlite", "lsp11-r6-sqlite-case-insensitive")
sqlite_cache:build_from_metadata_rows({
  { schema_name = "Main", table_name = "Users", obj_type = "table" },
})
assert_eq("sqlite schema lookup case-insensitive", sqlite_cache:find_schema("MAIN"), "Main")
assert_eq("sqlite table lookup case-insensitive", sqlite_cache:find_table_in_schema("main", "users"), "Users")

local clickhouse_cache = scoped_cache("clickhouse", "lsp11-r6-clickhouse-case-sensitive")
clickhouse_cache:build_from_metadata_rows({
  { schema_name = "Sales", table_name = "Users", obj_type = "table" },
})
assert_eq("clickhouse schema lookup preserves case", clickhouse_cache:find_schema("Sales"), "Sales")
assert_eq("clickhouse schema lookup rejects folded case", clickhouse_cache:find_schema("SALES"), nil)
assert_eq("clickhouse table lookup rejects folded case", clickhouse_cache:find_table_in_schema("Sales", "USERS"), nil)

local function column_probe_calls(conn_type, schema, table_name)
  local scope = assert(schema_filter.normalize(nil, conn_type))
  local calls = {}
  local probe_cache = SchemaCache:new({
    get_schema_filter_normalized = function()
      return scope
    end,
    connection_get_columns = function(_, _, opts)
      calls[#calls + 1] = {
        schema = opts.schema,
        table = opts.table,
      }
      return {}
    end,
  }, "lsp11-r6-probe-" .. conn_type)
  probe_cache:get_columns(schema, table_name, {
    probe_if_missing = true,
    schema_quoted = false,
    table_quoted = false,
    materializations = { "table" },
  })
  return calls
end

local function has_probe(calls, field, value)
  for _, call in ipairs(calls) do
    if call[field] == value then
      return true
    end
  end
  return false
end

local pg_probe_calls = column_probe_calls("postgres", "Public", "Users")
assert_true("postgres probe adds lower schema candidate", has_probe(pg_probe_calls, "schema", "public"))
assert_true("postgres probe adds lower table candidate", has_probe(pg_probe_calls, "table", "users"))
assert_true("postgres probe does not add uppercase schema candidate", not has_probe(pg_probe_calls, "schema", "PUBLIC"))
assert_true("postgres probe does not add uppercase table candidate", not has_probe(pg_probe_calls, "table", "USERS"))

local oracle_probe_calls = column_probe_calls("oracle", "app", "users")
assert_true("oracle probe adds uppercase schema candidate", has_probe(oracle_probe_calls, "schema", "APP"))
assert_true("oracle probe adds uppercase table candidate", has_probe(oracle_probe_calls, "table", "USERS"))

local clickhouse_probe_calls = column_probe_calls("clickhouse", "Sales", "Users")
assert_true("clickhouse probe does not add uppercase schema candidate", not has_probe(clickhouse_probe_calls, "schema", "SALES"))
assert_true("clickhouse probe does not add uppercase table candidate", not has_probe(clickhouse_probe_calls, "table", "USERS"))

local baseline_all_count = #cache:get_all_table_completion_items()
local mutable_copy = cache:get_all_table_completion_items()
mutable_copy[#mutable_copy + 1] = { label = "MUTATED" }
assert_eq("completion arrays are caller-owned", #cache:get_all_table_completion_items(), baseline_all_count)

for i = 1, 500 do
  local key = string.format("A_SCHEMA.T%03d", i)
  cache:_store_columns(key, {
    { name = string.format("COL_%03d", i), type = "NUMBER" },
  })
end

cache:_touch_column("A_SCHEMA.T001")
cache:_store_columns("A_SCHEMA.T501", {
  { name = "COL_501", type = "NUMBER" },
})

local stats = cache:get_stats()
assert_true("LRU bound", stats.column_entry_count <= 500)
assert_true("LRU evicted", stats.column_evictions > 0)
assert_eq("touched key survives", cache:get_cached_columns()["A_SCHEMA.T001"] ~= nil, true)
assert_eq("least-recent key evicted", cache:get_cached_columns()["A_SCHEMA.T002"], nil)

local before_tables = #cache:get_all_table_completion_items()
cache:_store_columns("A_SCHEMA.T001", {
  { name = "COL_REPLACED", type = "VARCHAR2" },
})
local after_tables = #cache:get_all_table_completion_items()
local column_items = cache:get_column_completion_items("A_SCHEMA", "T001")
assert_eq("column mutation does not rebuild structure list", after_tables, before_tables)
assert_eq("column index updated", column_items[1].label, "COL_REPLACED")

local function index_snapshot(target)
  return {
    schemas = vim.deepcopy(target.schemas),
    tables = vim.deepcopy(target.tables),
    schema_lookup_exact = vim.deepcopy(target.schema_lookup_exact),
    schema_lookup = vim.deepcopy(target.schema_lookup),
    table_lookup_exact_by_schema = vim.deepcopy(target.table_lookup_exact_by_schema),
    table_lookup_by_schema = vim.deepcopy(target.table_lookup_by_schema),
    table_lookup_exact_global = vim.deepcopy(target.table_lookup_exact_global),
    table_lookup_global = vim.deepcopy(target.table_lookup_global),
    all_table_names = target:get_all_table_names(),
    schema_items = target:get_schema_completion_items(),
    a_table_items = target:get_table_completion_items("A_SCHEMA"),
    b_table_items = target:get_table_completion_items("B_SCHEMA"),
    c_table_items = target:get_table_completion_items("C_SCHEMA"),
    all_table_items = target:get_all_table_completion_items(),
    column_items_by_key = vim.deepcopy(target.column_items_by_key),
  }
end

local equivalence_rows = {
  { schema_name = "B_SCHEMA", table_name = "DUP_TABLE", obj_type = "view" },
  { schema_name = "A_SCHEMA", table_name = "DUP_TABLE", obj_type = "table" },
  { schema_name = "A_SCHEMA", table_name = "Z_TABLE", obj_type = "table" },
  { schema_name = "C_SCHEMA", table_name = "A_TABLE", obj_type = "view" },
}
local full_index_cache = SchemaCache:new({}, "lsp11-full-index")
full_index_cache:build_from_metadata_rows(equivalence_rows)
local incremental_index_cache = SchemaCache:new({}, "lsp11-incremental-index")
for _, row in ipairs(equivalence_rows) do
  incremental_index_cache:_upsert_table_index(row.schema_name, row.table_name, row.obj_type)
end
assert_true(
  "incremental table index equals full rebuild",
  vim.deep_equal(index_snapshot(incremental_index_cache), index_snapshot(full_index_cache))
)

local full_update_cache = SchemaCache:new({}, "lsp11-full-update-index")
full_update_cache:build_from_metadata_rows({
  { schema_name = "A_SCHEMA", table_name = "CHANGE_ME", obj_type = "view" },
})
local incremental_update_cache = SchemaCache:new({}, "lsp11-incremental-update-index")
incremental_update_cache:_upsert_table_index("A_SCHEMA", "CHANGE_ME", "table")
incremental_update_cache:_upsert_table_index("A_SCHEMA", "CHANGE_ME", "view")
assert_true(
  "incremental table update equals full rebuild",
  vim.deep_equal(index_snapshot(incremental_update_cache), index_snapshot(full_update_cache))
)

local case_equivalence_rows = {
  { schema_name = "aA", table_name = "tT", obj_type = "table" },
  { schema_name = "Aa", table_name = "Tt", obj_type = "table" },
}
local full_case_cache = scoped_cache("sqlite", "lsp11-r6-full-case-index")
full_case_cache:build_from_metadata_rows(case_equivalence_rows)
local incremental_case_cache = scoped_cache("sqlite", "lsp11-r6-incremental-case-index")
for _, row in ipairs(case_equivalence_rows) do
  incremental_case_cache:_upsert_table_index(row.schema_name, row.table_name, row.obj_type)
end
assert_true(
  "incremental case-fold representatives equal full rebuild",
  vim.deep_equal(index_snapshot(incremental_case_cache), index_snapshot(full_case_cache))
)
local expected_case_schema = full_case_cache:find_schema("AA")
local expected_case_table = full_case_cache:find_table_in_schema("AA", "TT")
incremental_case_cache:_store_columns(expected_case_schema .. "." .. expected_case_table, {
  { name = "ID", type = "integer" },
})
assert_eq("incremental case-fold schema representative", incremental_case_cache:find_schema("AA"), expected_case_schema)
assert_eq("incremental case-fold table representative", incremental_case_cache:find_table_in_schema("AA", "TT"), expected_case_table)
assert_eq("incremental case-fold warm columns", incremental_case_cache:get_column_completion_items("AA", "TT")[1].label, "ID")

local o1_cache = SchemaCache:new({}, "lsp11-r6-targeted-o1")
local o1_rows = {}
for i = 1, 100 do
  o1_rows[#o1_rows + 1] = {
    schema_name = string.format("S%03d", i),
    table_name = string.format("BASE_%03d", i),
    obj_type = "table",
  }
end
o1_cache:build_from_metadata_rows(o1_rows)
for schema, tables in pairs(o1_cache.tables) do
  if schema ~= "S050" then
    setmetatable(tables, {
      __index = function(_, key)
        error("targeted update touched non-target schema table " .. schema .. "." .. tostring(key))
      end,
    })
  end
end
for schema, lookup in pairs(o1_cache.table_lookup_by_schema) do
  if schema ~= "S050" then
    setmetatable(lookup, {
      __index = function(_, key)
        error("targeted update touched non-target schema lookup " .. schema .. "." .. tostring(key))
      end,
    })
  end
end
local o1_ok, o1_err = pcall(function()
  o1_cache:_upsert_table_index("S050", "TARGET_DIRECT", "table")
end)
assert_true("targeted global index direct update", o1_ok)
assert_eq("targeted global table schema", select(2, o1_cache:find_table("TARGET_DIRECT")), "S050")
assert_eq("targeted global table name", o1_cache:find_table("TARGET_DIRECT"), "TARGET_DIRECT")

local nil_ternary_hits = {}
for _, path in ipairs(vim.fn.globpath(vim.fn.getcwd(), "lua/dbee/**/*.lua", false, true)) do
  local line_no = 0
  for line in io.lines(path) do
    line_no = line_no + 1
    if line:match("%f[%a]and%s+nil%s+or%f[%A]") then
      nil_ternary_hits[#nil_ternary_hits + 1] = path .. ":" .. tostring(line_no)
    end
  end
end
assert_eq("lua nil ternary pattern cleared", table.concat(nil_ternary_hits, ","), "")

print("LSP11_SCHEMA_INDEX_SORTED=true")
print("LSP11_SCHEMA_LOOKUP_SCHEMA_AWARE=true")
print("LSP11_R6_SCHEMA_CASE_LOOKUP_MATCHES=true")
print("LSP11_R6_CANONICAL_HELPER_PRESENT=true")
print("LSP11_R6_CANONICAL_HELPER_LOWER_FOLD=true")
print("LSP11_R6_CANONICAL_HELPER_UPPER_FOLD=true")
print("LSP11_R6_CANONICAL_HELPER_QUOTED_PRESERVED=true")
print("LSP11_R6_CANONICAL_HELPER_IDENTITY=true")
print("LSP11_R6_CANONICAL_HELPER_ALL_CONSUMERS_ROUTED=true")
print("LSP11_R6_DRAWER_LOADED_SCHEMAS_CANONICAL=true")
print("LSP11_R6_LSP_SAME_CACHE_ID_CANONICAL=true")
print("LSP11_R6_CONTEXT_QUOTE_METADATA=true")
print("LSP11_LRU_EVICTION_COUNT=" .. tostring(stats.column_evictions))
print("LSP11_LRU_EVICTION_OK=true")
print("LSP11_LRU_BOUND_HONORED=true")
print("LSP11_COMPLETION_INDEX_IMMUTABLE=true")
print("LSP11_INDEX_INCREMENTAL_OK=true")
print("LSP11_INCREMENTAL_INDEX_EQUIVALENT=true")
print("LSP11_R6_INC_FULL_REPR_EQUIVALENT=true")
print("LSP11_R6_QUOTED_VS_UNQUOTED_DISTINCT=true")
print("LSP11_R6_UNQUOTED_FOLDS_NOT_EXACT=true")
print("LSP11_R6_LOADED_SCHEMA_EXACT_AWARE=true")
print("LSP11_R6_TARGETED_GLOBAL_INDEX_O1=true")
print("LSP11_R6_LUA_NIL_TERNARY_CLEARED=true")
print("LSP11_R6_REFRESH_LOADED_STATE_EXACT=true")
print("LSP11_R6_SCHEMA_FILTER_CANONICAL_ROUTED=true")
print("LSP11_R6_PROBE_FALLBACK_ADAPTER_AWARE=true")

vim.cmd("qa!")
