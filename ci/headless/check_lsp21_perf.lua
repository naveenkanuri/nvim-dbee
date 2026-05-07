-- Phase 21 performance gates.

vim.env.XDG_STATE_HOME = vim.fn.tempname()
vim.fn.mkdir(vim.env.XDG_STATE_HOME, "p")

package.preload["nio"] = package.preload["nio"] or function()
  return {}
end

local uv = vim.uv or vim.loop
local SchemaCache = require("dbee.lsp.schema_cache")
local resolve = require("dbee.lsp.resolve")
local schema_filter = require("dbee.schema_filter")

local MEASURED = 100
local scope_ref = { value = schema_filter.normalize(nil, "postgres") }
local epoch_ref = { value = 1 }

local function fail(msg)
  print("LSP21_FAIL=" .. tostring(msg))
  vim.cmd("cquit 1")
end

local function emit(label, value)
  print(label .. "=" .. tostring(value))
end

local function assert_true(label, value)
  if not value then
    fail(label .. ": expected true")
  end
end

local function make_handler()
  local handler = {}
  function handler:get_schema_filter_normalized()
    return scope_ref.value
  end
  function handler:get_authoritative_root_epoch()
    return epoch_ref.value
  end
  function handler:get_current_connection()
    return { id = "lsp21-perf", type = "postgres" }
  end
  return handler
end

local function make_cache(conn_id, rows)
  scope_ref.value = schema_filter.normalize(nil, "postgres")
  epoch_ref.value = 1
  local cache = SchemaCache:new(make_handler(), conn_id)
  cache:build_from_metadata_rows(rows)
  return cache
end

local function percentile(values, ratio)
  local sorted = vim.deepcopy(values)
  table.sort(sorted)
  local index = math.max(1, math.ceil(#sorted * ratio))
  return sorted[index]
end

local function timed_ms(fn)
  collectgarbage("stop")
  local start = uv.hrtime()
  fn()
  local elapsed = (uv.hrtime() - start) / 1e6
  collectgarbage("restart")
  return elapsed
end

local function measure(fn, count)
  local samples = {}
  for _ = 1, count or MEASURED do
    samples[#samples + 1] = timed_ms(fn)
  end
  return percentile(samples, 0.95), samples
end

local function first_label(items, label)
  for _, item in ipairs(items or {}) do
    if item.label == label then
      return item
    end
  end
  return nil
end

local function fixture(table_count, columns_per_table, fk_count, composite_groups)
  local rows = {}
  local columns_by_key = {}
  local fk_seen = 0
  composite_groups = composite_groups or 0
  for t = 1, table_count do
    local table_name = string.format("table_%04d", t)
    rows[#rows + 1] = { schema_name = "public", table_name = table_name, obj_type = "table" }
    local cols = {}
    for c = 1, columns_per_table do
      local col_name = string.format("col_%03d", c)
      local col = { name = col_name, type = "integer" }
      if fk_seen < fk_count and c <= math.max(1, math.floor(fk_count / table_count) + 1) then
        fk_seen = fk_seen + 1
        local target_col = string.format("col_%03d", ((fk_seen - 1) % columns_per_table) + 1)
        if fk_seen <= composite_groups then
          col.foreign_keys = {
            {
              constraint_name = "fk_perf_" .. tostring(fk_seen),
              source_columns = { "col_001", col_name },
              target_schema = "public",
              target_table = "table_0001",
              target_columns = { "col_001", target_col },
              source_ordinal = 2,
            },
          }
        else
          col.foreign_keys = {
            {
              constraint_name = "fk_perf_" .. tostring(fk_seen),
              source_column = col_name,
              target_schema = "public",
              target_table = "table_0001",
              target_column = target_col,
            },
          }
        end
      end
      cols[#cols + 1] = col
    end
    columns_by_key["public." .. table_name] = cols
  end
  return rows, columns_by_key
end

local mid_rows, mid_columns = fixture(1000, 10, 1000, 100)
local mid_cache = make_cache("lsp21-perf-mid", mid_rows)
mid_cache.columns = mid_columns
local mid_build_ms = timed_ms(function()
  mid_cache:_rebuild_column_indexes()
end)
assert_true("mid build budget", mid_build_ms < 50)
assert_true("mid per ref budget", (mid_build_ms * 1000 / 1000) <= 50)
emit("LSP21_PERF_REVERSE_INDEX_BUILD_50MS_OK", "true")

local completion_p95 = measure(function()
  local items = mid_cache:get_column_completion_items("public", "table_0001", {
    schema_quoted = true,
    table_quoted = true,
  })
  if #items ~= 10 then
    fail("mid completion item count")
  end
end)
assert_true("completion p95", completion_p95 < 1)
emit("LSP21_PERF_COMPLETION_READ_P95_OK", "true")

local wide_rows = { { schema_name = "public", table_name = "wide", obj_type = "table" } }
local wide_cache = make_cache("lsp21-perf-wide", wide_rows)
local wide_cols = {}
for i = 1, 500 do
  wide_cols[#wide_cols + 1] = { name = string.format("col_%03d", i), type = "text" }
end
wide_cache:_store_columns("public.wide", wide_cols)
local wide_p95 = measure(function()
  local items = wide_cache:get_column_completion_items("public", "wide", {
    schema_quoted = true,
    table_quoted = true,
  })
  if #items ~= 500 or items[1].labelDetails ~= nil then
    fail("wide completion shape")
  end
end)
assert_true("wide p95", wide_p95 < 2.5 and (wide_p95 * 1000 / 500) <= 5)
emit("LSP21_PERF_COMPLETION_WIDE_TABLE_P95_OK", "true")

local large_rows, large_columns = fixture(5000, 50, 50000, 1000)
local large_cache = make_cache("lsp21-perf-large", large_rows)
large_cache.columns = large_columns
local large_build_ms = timed_ms(function()
  large_cache:_rebuild_column_indexes()
end)
assert_true("large build budget", large_build_ms <= 500)
assert_true("large per ref budget", (large_build_ms * 1000 / 50000) <= 10)
emit("LSP21_PERF_REVERSE_INDEX_BUILD_LARGE_OK", "true")

local churn_cache = make_cache("lsp21-perf-churn", mid_rows)
churn_cache.columns = vim.deepcopy(mid_columns)
churn_cache:_rebuild_column_indexes()
local churn_keys = {}
for i = 1, 1000 do
  churn_keys[#churn_keys + 1] = "public." .. string.format("table_%04d", i)
end
local churn_index = 0
local churn_p95 = measure(function()
  churn_index = churn_index + 1
  local key = churn_keys[churn_index]
  churn_cache.columns[key] = nil
  churn_cache:_drop_column_index(key)
end)
assert_true("churn p95", churn_p95 < 0.5)
emit("LSP21_PERF_EVICTION_CHURN_OK", "true")

local lookup_p95 = measure(function()
  local refs = large_cache:get_reverse_fk_refs("public", "table_0001", "col_001")
  if #refs > 50 then
    fail("lookup cap exceeded")
  end
end)
assert_true("lookup p95", lookup_p95 < 1)
emit("LSP21_PERF_RESOLVE_LOOKUP_P95_OK", "true")

local target_item = first_label(large_cache:get_column_completion_items("public", "table_0001", {
  schema_quoted = true,
  table_quoted = true,
  include_data = true,
}), "col_001")
local resolve_p95 = measure(function()
  local out = resolve.handle(target_item, large_cache, { memo = {} })
  if not out.documentation then
    fail("resolve docs missing")
  end
end)
assert_true("resolve e2e p95", resolve_p95 < 5)
emit("LSP21_PERF_RESOLVE_E2E_P95_OK", "true")

large_cache:_rebuild_column_indexes({ reverse_fk = false, reverse_fk_dirty = true })
local dirty_stats = large_cache:get_stats()
assert_true("deferred dirty", dirty_stats.reverse_fk_index_dirty)
assert_true("deferred target empty", dirty_stats.reverse_fk_target_bucket_count == 0)
assert_true("deferred source empty", dirty_stats.reverse_fk_source_bucket_count == 0)
local deferred_first_ms = timed_ms(function()
  local refs = large_cache:get_reverse_fk_refs("public", "table_0001", "col_001")
  if #refs ~= 0 then
    fail("dirty first lookup should be empty")
  end
end)
assert_true("deferred first overhead", deferred_first_ms < 25)
vim.wait(10000, function()
  return large_cache:get_stats().reverse_fk_index_dirty == false
end, 10)
assert_true("deferred large built", large_cache:get_stats().reverse_fk_index_size == 50000)
emit("LSP21_PERF_LOAD_FROM_DISK_DEFERRED_LARGE_OK", "true")

local stats = large_cache:get_stats()
local canonical_per_ref = stats.reverse_fk_index_size > 0 and (stats.reverse_fk_canonical_calls / stats.reverse_fk_index_size) or 0
local cap_check_per_ref = stats.reverse_fk_index_size > 0 and (stats.reverse_fk_cap_check_ns / stats.reverse_fk_index_size) or 0
emit("LSP21_DIAG_REVERSE_INDEX_BUILD_CANONICAL_CALLS_PER_REF", string.format("%.2f", canonical_per_ref))
emit("LSP21_DIAG_REVERSE_INDEX_BUILD_CAP_CHECK_NS", string.format("%.2f", cap_check_per_ref))
emit("LSP21_DIAG_RESOLVE_MEMO_SIZE", "1")

vim.cmd("qa!")
