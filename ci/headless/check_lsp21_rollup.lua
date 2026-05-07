-- Strict Phase 21 rollup gate.

local function emit(label, value)
  print(label .. "=" .. tostring(value))
end

local function fail(failures)
  for _, failure in ipairs(failures) do
    emit("LSP21_ROLLUP_FAIL", failure)
  end
  emit("LSP21_ALL_PASS", "false")
  vim.cmd("cquit 1")
end

local strict_markers = {
  "LSP21_COMPLETION_LABEL_UNCHANGED_OK",
  "LSP21_LABELDETAILS_DETAIL_RENDERED_OK",
  "LSP21_DETAIL_COMPAT_RENDERED_OK",
  "LSP21_PK_SINGLE_MARKER_OK",
  "LSP21_PK_COMPOSITE_ORDINAL_OK",
  "LSP21_PK_COMPOSITE_NO_ORDINAL_FALLBACK_OK",
  "LSP21_NULLABLE_TRUE_MARKER_OK",
  "LSP21_PK_NULL_SUPPRESSED_OK",
  "LSP21_NOT_NULL_OMITTED_OK",
  "LSP21_FK_SINGLE_MARKER_OK",
  "LSP21_FK_COMPOSITE_TARGET_TUPLE_OK",
  "LSP21_FK_MULTIPLE_REFS_OK",
  "LSP21_FK_COMPOSITE_PAIRING_PRECEDENCE_OK",
  "LSP21_CAPABILITY_FALSE_EMPTY_RICH_FIELDS_OMIT_OK",
  "LSP21_DISK_PAYLOAD_SHAPE_UNCHANGED_OK",
  "LSP21_COLUMN_RECORDS_UNMUTATED_BY_ANNOTATION_OK",
  "LSP21_REVERSE_FK_INDEX_EMPTY_INIT_OK",
  "LSP21_REVERSE_FK_INDEX_BUILD_ON_COLUMN_STORE_OK",
  "LSP21_REVERSE_FK_INDEX_REBUILD_ON_COLUMN_INDEX_REBUILD_OK",
  "LSP21_REVERSE_FK_INDEX_CLEAR_ON_RESET_INVALIDATE_OK",
  "LSP21_REVERSE_FK_INDEX_EVICTION_DROPS_REFS_OK",
  "LSP21_REVERSE_FK_CACHE_EPOCH_FAIL_CLOSED_OK",
  "LSP21_REVERSE_FK_CACHE_EPOCH_WRITE_STAMP_OK",
  "LSP21_REVERSE_FK_COMPOSITE_SOURCE_TARGET_OK",
  "LSP21_REVERSE_FK_DEDUP_SHORTHAND_OK",
  "LSP21_REVERSE_FK_SIZE_BOUND_OK",
  "LSP21_REVERSE_FK_PER_TARGET_CAP_OK",
  "LSP21_REVERSE_FK_PER_SOURCE_CAP_OK",
  "LSP21_REVERSE_FK_OVERFLOW_TRUNCATED_DISPLAY_OK",
  "LSP21_REVERSE_FK_OVERFLOW_NOTIFY_ONCE_OK",
  "LSP21_REVERSE_FK_KEY_FOLD_AWARE_OK",
  "LSP21_REVERSE_FK_AUTHORITY_FAIL_CLOSED_OK",
  "LSP21_REVERSE_FK_DISK_LOAD_DEFERRED_OK",
  "LSP21_REVERSE_FK_DEFERRED_BUILD_SINGLEFLIGHT_OK",
  "LSP21_REVERSE_FK_OVERFLOW_CLEARS_AFTER_EVICTION_OK",
  "LSP21_REVERSE_FK_PER_SOURCE_BACKSTOP_OK",
  "LSP21_REVERSE_FK_SORT_STABLE_OK",
  "LSP21_RESOLVE_REFERENCED_BY_DOC_OK",
  "LSP21_RESOLVE_REFERENCED_BY_CONSTRAINT_OK",
  "LSP21_RESOLVE_REFERENCED_BY_COMPOSITE_OK",
  "LSP21_RESOLVE_NO_REFS_DOC_UNCHANGED_OK",
  "LSP21_RESOLVE_MARKDOWN_PLAINTEXT_OK",
  "LSP21_RESOLVE_MEMO_REVERSE_FK_GENERATION_OK",
  "LSP21_RESOLVE_MEMO_REVERSE_FK_GENERATION_DIMENSION_OK",
  "LSP21_RESOLVE_STALE_REVERSE_FK_FAIL_CLOSED_OK",
  "LSP21_RESOLVE_NO_DB_CALLS_OK",
  "LSP21_HEADLESS_PG_ORACLE_FIXTURES_OK",
  "LSP21_HEADLESS_CAPABILITY_FALSE_FIXTURE_OK",
  "LSP21_HEADLESS_1K_TABLES_100_FKS_SMOKE_OK",
  "LSP21_QUOTED_MIXED_CASE_FIXTURE_OK",
  "LSP21_SELF_FK_FIXTURE_OK",
  "LSP21_CROSS_SCHEMA_OUT_OF_CACHE_FIXTURE_OK",
  "LSP21_ZERO_FK_FIXTURE_OK",
  "LSP21_HIGH_FAN_IN_FIXTURE_OK",
  "LSP21_ROLLUP_EXACTLY_ONCE_OK",
  "LSP21_LOCKED_HELPERS_UNTOUCHED_OK",
  "LSP21_LOCKED_HELPERS_ALL_CONSUMERS_ROUTED_OK",
  "LSP21_CACHE_VERSION4_NO_BUMP_OK",
  "LSP21_RICH16_UX13_PRESERVED_OK",
  "LSP21_PERF_COMPLETION_READ_P95_OK",
  "LSP21_PERF_COMPLETION_WIDE_TABLE_P95_OK",
  "LSP21_PERF_REVERSE_INDEX_BUILD_50MS_OK",
  "LSP21_PERF_REVERSE_INDEX_BUILD_LARGE_OK",
  "LSP21_PERF_EVICTION_CHURN_OK",
  "LSP21_PERF_RESOLVE_LOOKUP_P95_OK",
  "LSP21_PERF_RESOLVE_E2E_P95_OK",
  "LSP21_PERF_LOAD_FROM_DISK_DEFERRED_LARGE_OK",
}

local function parse_markers(lines)
  local values = {}
  for _, line in ipairs(lines or {}) do
    local key, value = line:match("^([%w_]+)=(.*)$")
    if key and value then
      values[key] = values[key] or {}
      values[key][#values[key] + 1] = value
    end
  end
  return values
end

local function evaluate(lines)
  local values = parse_markers(lines)
  local failures = {}
  if #strict_markers ~= 67 then
    failures[#failures + 1] = "strict marker list length is " .. tostring(#strict_markers)
  end
  local count_values = values.LSP21_STRICT_MARKER_COUNT or {}
  if #count_values ~= 1 or count_values[1] ~= "67" then
    failures[#failures + 1] = "LSP21_STRICT_MARKER_COUNT must be emitted exactly once as 67"
  end
  for _, marker in ipairs(strict_markers) do
    local marker_values = values[marker] or {}
    if #marker_values ~= 1 then
      failures[#failures + 1] = marker .. " expected exactly once, got " .. tostring(#marker_values)
    elseif marker_values[1] ~= "true" then
      failures[#failures + 1] = marker .. " expected true, got " .. tostring(marker_values[1])
    end
  end
  return {
    ok = #failures == 0,
    failures = failures,
    checked = #strict_markers,
  }
end

if vim.env.LSP21_ROLLUP_EXPORT == "1" then
  return {
    evaluate = evaluate,
    strict_markers = strict_markers,
  }
end

local log_path = vim.env.LSP21_ROLLUP_LOG or vim.env.UX13_ROLLUP_LOG
if not log_path or log_path == "" then
  fail({ "missing LSP21_ROLLUP_LOG/UX13_ROLLUP_LOG" })
end
local ok, lines = pcall(vim.fn.readfile, log_path)
if not ok or type(lines) ~= "table" then
  fail({ "unable to read rollup log: " .. tostring(log_path) })
end

local result = evaluate(lines)
if not result.ok then
  fail(result.failures)
end
emit("LSP21_ROLLUP_MARKERS_CHECKED", result.checked)
emit("LSP21_ALL_PASS", "true")
vim.cmd("qa!")
