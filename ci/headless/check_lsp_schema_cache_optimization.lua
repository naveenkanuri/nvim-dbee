-- Headless checks for Phase 11 SchemaCache indexes and LRU behavior.

local SchemaCache = require("dbee.lsp.schema_cache")

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

local function assert_sorted(label, values)
  local sorted = vim.deepcopy(values)
  table.sort(sorted)
  for i, value in ipairs(values) do
    if value ~= sorted[i] then
      fail(label .. ": not sorted: " .. vim.inspect(values))
    end
  end
end

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

print("LSP11_SCHEMA_INDEX_SORTED=true")
print("LSP11_SCHEMA_LOOKUP_SCHEMA_AWARE=true")
print("LSP11_LRU_EVICTION_COUNT=" .. tostring(stats.column_evictions))
print("LSP11_LRU_EVICTION_OK=true")
print("LSP11_LRU_BOUND_HONORED=true")
print("LSP11_COMPLETION_INDEX_IMMUTABLE=true")
print("LSP11_INDEX_INCREMENTAL_OK=true")
print("LSP11_INCREMENTAL_INDEX_EQUIVALENT=true")

vim.cmd("qa!")
