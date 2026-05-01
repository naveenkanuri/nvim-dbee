-- Strict Phase 12.1 hover/resolve rollup gate.

local function emit(label, value)
  print(label .. "=" .. tostring(value))
end

local function fail(failures)
  for _, failure in ipairs(failures) do
    emit("LSP12_ROLLUP_FAIL", failure)
  end
  emit("LSP12_HOVER_RESOLVE_ALL_PASS", "false")
  vim.cmd("cquit 1")
end

local required_true_markers = {
  "LSP12_HOVER_TABLE_OK",
  "LSP12_HOVER_COLUMN_OK",
  "LSP12_HOVER_SCHEMA_OK",
  "LSP12_HOVER_NIL_ON_KEYWORD",
  "LSP12_HOVER_NIL_ON_UNKNOWN",
  "LSP12_HOVER_AUTHORITY_FAIL_CLOSED",
  "LSP12_HOVER_CANONICAL_LOOKUP_OK",
  "LSP12_HOVER_QUOTED_CASE_PRESERVED",
  "LSP12_HOVER_MARKDOWN_FORMAT_OK",
  "LSP12_HOVER_MARKDOWN_BACKTICK_SAFE",
  "LSP12_HOVER_CONTEXT_SCAN_BOUNDED",
  "LSP12_HOVER_WIDE_TABLE_BOUNDED_COPY",
  "LSP12_SCHEMA_HOVER_BOUNDED",
  "LSP12_HOVER_SELECT_LIST_SINGLE_TABLE_OK",
  "LSP12_HOVER_SELECT_LIST_AMBIGUOUS_NIL",
  "LSP12_HOVER_COMMA_FROM_AMBIGUOUS_NIL",
  "LSP12_HOVER_SAME_LINE_SEMICOLON_OK",
  "LSP12_HOVER_INVALIDATION_LAG_FAIL_CLOSED",
  "LSP12_DISK_CACHE_EPOCH_FAIL_CLOSED",
  "LSP12_COLUMN_LOAD_NO_EPOCH_LAUNDER",
  "LSP12_EPOCH_HELPER_PRESENT",
  "LSP12_EPOCH_HELPER_FRESH_TRUE",
  "LSP12_EPOCH_HELPER_FRESH_FALSE",
  "LSP12_EPOCH_HELPER_ADMIT_OK",
  "LSP12_EPOCH_HELPER_ADMIT_REJECT",
  "LSP12_EPOCH_HELPER_UNAVAILABLE_FAIL_CLOSED",
  "LSP12_EPOCH_HELPER_ALL_CONSUMERS_ROUTED",
  "LSP12_COLUMNS_CACHED_HIT_FAIL_CLOSED",
  "LSP12_SCHEMAS_REFRESH_PRESERVE_LOADED_ATOMIC",
  "LSP12_METADATA_ROWS_STALE_EPOCH_REJECTED",
  "LSP12_DIAGNOSTICS_FAIL_CLOSED_ON_STALE_CACHE",
  "LSP12_ROLLUP_EXACTLY_ONCE_OK",
  "LSP12_HOVER_NO_SYNC_DB",
  "LSP12_HOVER_NO_ASYNC_DB",
  "LSP12_RESOLVE_SCHEMA_DOCS_OK",
  "LSP12_RESOLVE_TABLE_DOCS_OK",
  "LSP12_RESOLVE_COLUMN_DOCS_OK",
  "LSP12_RESOLVE_NON_DBEE_ITEM_PASSTHROUGH",
  "LSP12_RESOLVE_STALE_RETURNS_INCOMPLETE",
  "LSP12_RESOLVE_AUTHORITY_FAIL_CLOSED",
  "LSP12_RESOLVE_FRESH_ITEM_GENERATION_OK",
  "LSP12_RESOLVE_GENERATION_PROOF_ALL_PATHS",
  "LSP12_RESOLVE_GLOBAL_COLUMN_AMBIGUOUS_PASSTHROUGH",
  "LSP12_RESOLVE_AMBIGUOUS_GLOBAL_NO_DOCS",
  "LSP12_RESOLVE_EXACT_CASE_PRESERVED",
  "LSP12_RESOLVE_MEMO_EXACT_DISTINCT",
  "LSP12_RESOLVE_AUTHORITY_SCRUBS_PRIOR_DOCS",
  "LSP12_RESOLVE_GEN_BUMP_SCRUBS_PRIOR_DOCS",
  "LSP12_RESOLVE_INVALIDATION_BUMPS_GENERATION",
  "LSP12_RESOLVE_INVALIDATION_LAG_FAIL_CLOSED",
  "LSP12_RESOLVE_STALE_PATH_CHECKS_AUTHORITY",
  "LSP12_RESOLVE_NO_SYNC_DB",
  "LSP12_RESOLVE_NO_ASYNC_DB",
  "LSP12_RESOLVE_MEMO_PER_GENERATION_OK",
  "LSP12_RESOLVE_MEMO_PRUNED_ON_GEN_BUMP",
}

local required_advisory_markers = {
  "LSP12_HOVER_PERF_BUDGET_50MS",
  "LSP12_RESOLVE_PERF_BUDGET_100MS",
}

local required_lsp12_2_true_markers = {
  "LSP12_2_DOCSYMBOL_HIERARCHY_OK",
  "LSP12_2_DOCSYMBOL_FLAT_FALLBACK_OK",
  "LSP12_2_DOCSYMBOL_RANGES_VALID",
  "LSP12_2_DOCSYMBOL_UNKNOWN_REF_OK",
  "LSP12_2_DOCSYMBOL_UNQUALIFIED_FLAT",
  "LSP12_2_DOCSYMBOL_UNKNOWN_QUALIFIED_FLAT",
  "LSP12_2_DOCSYMBOL_AUTHORITY_NEUTRAL",
  "LSP12_2_DOCSYMBOL_COLUMN_SCOPE_SAFE",
  "LSP12_2_DOCSYMBOL_FULL_DOC_BOUNDED",
  "LSP12_2_DOCSYMBOL_LARGE_BUFFER_BOUNDED",
  "LSP12_2_DOCSYMBOL_BUFFER_CACHE_INVALIDATED",
  "LSP12_2_DOCSYMBOL_DIDCLOSE_EVICTS",
  "LSP12_2_DOCSYMBOL_INVALID_BUFFER_EVICTS",
  "LSP12_2_DOCSYMBOL_DISABLED_NO_CAPABILITY",
  "LSP12_2_WORKSPACESYMBOL_AUTHORITY_FAIL_CLOSED",
  "LSP12_2_WORKSPACESYMBOL_AUTHORITY_LEGACY_IMPLICIT_ALL",
  "LSP12_2_WORKSPACESYMBOL_AUTHORITY_OK_SCOPED",
  "LSP12_2_WORKSPACESYMBOL_EPOCH_FAIL_CLOSED",
  "LSP12_2_WORKSPACESYMBOL_CANONICAL_LOOKUP",
  "LSP12_2_WORKSPACESYMBOL_QUERY_SUBSTRING",
  "LSP12_2_WORKSPACESYMBOL_PAGINATION_OK",
  "LSP12_2_WORKSPACESYMBOL_CAP_BEFORE_COPY",
  "LSP12_2_WORKSPACESYMBOL_ACTIVE_CONNECTION_ONLY",
  "LSP12_2_WORKSPACESYMBOL_DBEE_URI_PERCENT_ENCODED",
  "LSP12_2_WORKSPACESYMBOL_LOCATION_FALLBACK_OK",
  "LSP12_2_WORKSPACESYMBOL_DISABLED_NO_CAPABILITY",
  "LSP12_2_WORKSPACESYMBOL_SHAPE_FALLBACK_OK",
  "LSP12_2_DOCSYMBOL_NO_SYNC_DB",
  "LSP12_2_DOCSYMBOL_NO_ASYNC_DB",
  "LSP12_2_WORKSPACESYMBOL_NO_SYNC_DB",
  "LSP12_2_WORKSPACESYMBOL_NO_ASYNC_DB",
  "LSP12_2_NEW_SYMBOL_CODE_NO_HELPER_BYPASS",
  "LSP12_2_MAKE_PERF_LSP_WIRED",
  "LSP12_2_ROLLUP_EXACTLY_ONCE_OK",
  "LSP12_2_DOCSYMBOL_PERF_BUDGET_50MS",
  "LSP12_2_WORKSPACESYMBOL_PERF_BUDGET_100MS",
}

local function parse_markers(lines)
  local markers = {}
  for _, line in ipairs(lines) do
    local key, value = line:match("^([%w_]+)=(.*)$")
    if key then
      markers[key] = markers[key] or {}
      markers[key][#markers[key] + 1] = value
    end
  end
  return markers
end

local function evaluate(lines)
  local markers = parse_markers(lines)
  local failures = {}

  local function require_marker(label, allowed)
    local values = markers[label]
    if not values or #values == 0 then
      failures[#failures + 1] = "missing " .. label
      return
    end
    if #values ~= 1 then
      failures[#failures + 1] = label .. " must appear exactly once, found " .. tostring(#values)
    end
    for _, value in ipairs(values) do
      if not allowed[value] then
        failures[#failures + 1] = label .. " has unsupported value " .. tostring(value)
      end
    end
  end

  for _, label in ipairs(required_true_markers) do
    require_marker(label, { ["true"] = true })
  end
  for _, label in ipairs(required_advisory_markers) do
    require_marker(label, { ["true"] = true, unfrozen = true })
  end
  require_marker("LSP12_PERF_SCENARIOS_COUNT", { ["10"] = true })

  return {
    ok = #failures == 0,
    failures = failures,
    checked = #required_true_markers + #required_advisory_markers + 1,
  }
end

local function evaluate_lsp12_2(lines)
  local markers = parse_markers(lines)
  local failures = {}

  local function require_marker(label, allowed)
    local values = markers[label]
    if not values or #values == 0 then
      failures[#failures + 1] = "missing " .. label
      return
    end
    if #values ~= 1 then
      failures[#failures + 1] = label .. " must appear exactly once, found " .. tostring(#values)
    end
    for _, value in ipairs(values) do
      if not allowed[value] then
        failures[#failures + 1] = label .. " has unsupported value " .. tostring(value)
      end
    end
  end

  for _, label in ipairs(required_lsp12_2_true_markers) do
    require_marker(label, { ["true"] = true })
  end
  require_marker("LSP12_2_PERF_SCENARIOS_COUNT", { ["4"] = true })

  return {
    ok = #failures == 0,
    failures = failures,
    checked = #required_lsp12_2_true_markers + 1,
  }
end

if vim.env.LSP12_ROLLUP_EXPORT == "1" then
  return {
    evaluate = evaluate,
    required_true_markers = required_true_markers,
    required_advisory_markers = required_advisory_markers,
    evaluate_lsp12_2 = evaluate_lsp12_2,
    required_lsp12_2_true_markers = required_lsp12_2_true_markers,
  }
end

local function read_lines()
  local log_path = vim.env.LSP12_ROLLUP_LOG or vim.env.UX13_ROLLUP_LOG
  if not log_path or log_path == "" then
    fail({ "missing LSP12_ROLLUP_LOG/UX13_ROLLUP_LOG" })
  end
  local ok, lines = pcall(vim.fn.readfile, log_path)
  if not ok or type(lines) ~= "table" then
    fail({ "unable to read rollup log: " .. tostring(log_path) })
  end
  return lines
end

local function selftest()
  local lines = {}
  for _, marker in ipairs(required_true_markers) do
    lines[#lines + 1] = marker .. "=true"
  end
  for _, marker in ipairs(required_advisory_markers) do
    lines[#lines + 1] = marker .. "=unfrozen"
  end
  lines[#lines + 1] = "LSP12_PERF_SCENARIOS_COUNT=10"
  local valid = evaluate(lines)
  if not valid.ok then
    fail({ "selftest valid log failed: " .. table.concat(valid.failures, "; ") })
  end
  local duplicate_lines = vim.deepcopy(lines)
  duplicate_lines[#duplicate_lines + 1] = required_true_markers[1] .. "=true"
  local duplicate = evaluate(duplicate_lines)
  if duplicate.ok then
    fail({ "selftest duplicate marker did not fail" })
  end
  table.remove(lines, 1)
  local invalid = evaluate(lines)
  if invalid.ok then
    fail({ "selftest missing marker did not fail" })
  end
  local lsp12_2_lines = {}
  for _, marker in ipairs(required_lsp12_2_true_markers) do
    lsp12_2_lines[#lsp12_2_lines + 1] = marker .. "=true"
  end
  lsp12_2_lines[#lsp12_2_lines + 1] = "LSP12_2_PERF_SCENARIOS_COUNT=4"
  local lsp12_2_valid = evaluate_lsp12_2(lsp12_2_lines)
  if not lsp12_2_valid.ok then
    fail({ "selftest valid LSP12.2 log failed: " .. table.concat(lsp12_2_valid.failures, "; ") })
  end
  lsp12_2_lines[#lsp12_2_lines + 1] = required_lsp12_2_true_markers[1] .. "=true"
  local lsp12_2_duplicate = evaluate_lsp12_2(lsp12_2_lines)
  if lsp12_2_duplicate.ok then
    fail({ "selftest duplicate LSP12.2 marker did not fail" })
  end
  emit("LSP12_ROLLUP_SELFTEST_ALL_PASS", "true")
  vim.cmd("qa!")
end

if vim.env.LSP12_ROLLUP_SELFTEST == "1" then
  selftest()
end

local lines = read_lines()
local result = evaluate(lines)
local lsp12_2_result = evaluate_lsp12_2(lines)
local failures = {}
for _, failure in ipairs(result.failures) do
  failures[#failures + 1] = failure
end
for _, failure in ipairs(lsp12_2_result.failures) do
  failures[#failures + 1] = failure
end
if #failures > 0 then
  fail(failures)
end

emit("LSP12_ROLLUP_MARKERS_CHECKED", result.checked)
emit("LSP12_HOVER_RESOLVE_ALL_PASS", "true")
emit("LSP12_2_ROLLUP_MARKERS_CHECKED", lsp12_2_result.checked)
emit("LSP12_2_ALL_PASS", "true")
vim.cmd("qa!")
