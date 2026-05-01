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
  "LSP12_HOVER_SELECT_LIST_SINGLE_TABLE_OK",
  "LSP12_HOVER_SELECT_LIST_AMBIGUOUS_NIL",
  "LSP12_HOVER_COMMA_FROM_AMBIGUOUS_NIL",
  "LSP12_HOVER_SAME_LINE_SEMICOLON_OK",
  "LSP12_HOVER_INVALIDATION_LAG_FAIL_CLOSED",
  "LSP12_DISK_CACHE_EPOCH_FAIL_CLOSED",
  "LSP12_COLUMN_LOAD_NO_EPOCH_LAUNDER",
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
  require_marker("LSP12_PERF_SCENARIOS_COUNT", { ["8"] = true })

  return {
    ok = #failures == 0,
    failures = failures,
    checked = #required_true_markers + #required_advisory_markers + 1,
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
  lines[#lines + 1] = "LSP12_PERF_SCENARIOS_COUNT=8"
  local valid = evaluate(lines)
  if not valid.ok then
    fail({ "selftest valid log failed: " .. table.concat(valid.failures, "; ") })
  end
  table.remove(lines, 1)
  local invalid = evaluate(lines)
  if invalid.ok then
    fail({ "selftest missing marker did not fail" })
  end
  emit("LSP12_ROLLUP_SELFTEST_ALL_PASS", "true")
  vim.cmd("qa!")
end

if vim.env.LSP12_ROLLUP_SELFTEST == "1" then
  selftest()
end

local result = evaluate(read_lines())
if not result.ok then
  fail(result.failures)
end

emit("LSP12_ROLLUP_MARKERS_CHECKED", result.checked)
emit("LSP12_HOVER_RESOLVE_ALL_PASS", "true")
vim.cmd("qa!")
