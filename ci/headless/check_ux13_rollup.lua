-- Fail-closed Phase 13 rollup gate.
--
-- Usage:
--   UX13_ROLLUP_LOG=/path/to/combined-stdout.log nvim --headless -u NONE -i NONE -n \
--     --cmd "set rtp+=$(pwd)" \
--     -c "luafile ci/headless/check_ux13_rollup.lua"

local function emit(label, value)
  print(label .. "=" .. tostring(value))
end

local function fail(failures)
  for _, failure in ipairs(failures) do
    emit("UX13_ROLLUP_FAIL", failure)
  end
  emit("UX13_ALL_PASS", "false")
  vim.cmd("cquit 1")
end

local required_true_markers = {
  "UX13_CACHE_VERSION2_WRITTEN",
  "UX13_CACHE_LEGACY_V1_SILENT",
  "UX13_CACHE_LEGACY_V1_REMOVED",
  "UX13_CACHE_TRUE_CORRUPTION_WARN",
  "UX13_CACHE_TRUE_CORRUPTION_WARN_RETAINED",
  "UX13_CACHE_MIGRATION_ALL_PASS",
  "UX13_DRAWER_FILTER_CONNECTION_ROOT",
  "UX13_DRAWER_FILTER_SOURCE_BADGE",
  "UX13_DRAWER_FILTER_MIXED_VISIBLE_CACHE",
  "UX13_DRAWER_FILTER_EXPANDED_CACHED_VS_VISIBLE_OK",
  "UX13_DRAWER_FILTER_ZERO_RPC",
  "UX13_DRAWER_FILTER_RESTORE_OK",
  "UX13_DRAWER_FILTER_PERF_COLD_CONNECTION_ONLY",
  "UX13_DRAWER_FILTER_PERF_MIXED_VISIBLE_CACHE",
  "UX13_DRAWER_FILTER_ALL_PASS",
  "UX13_WIZARD_WINHIGHLIGHT_MAIN",
  "UX13_WIZARD_WINHIGHLIGHT_PASSWORD",
  "UX13_WIZARD_WINHIGHLIGHT_INPUT",
  "UX13_WIZARD_WINHIGHLIGHT_SELECT",
  "UX13_WIZARD_WINHIGHLIGHT_MULTILINE",
  "UX13_WIZARD_BRIGHT_BASELINE_OK",
  "UX13_WIZARD_DARK_COLLISION_OK",
  "UX13_WIZARD_TEXT_RENDER_STATE_OK",
  "UX13_WIZARD_NUI_WIN_OPTIONS_THREADED",
  "UX13_WIZARD_INPUT_RENDER_VISIBLE",
  "UX13_WIZARD_ALL_PASS",
  "DRAW01_FILTER_COLD_CONNECTION_ONLY_10_SENTINEL_OK",
  "DRAW01_FILTER_COLD_CONNECTION_ONLY_100_SENTINEL_OK",
  "DRAW01_FILTER_COLD_CONNECTION_ONLY_1000_SENTINEL_OK",
  "DRAW01_FILTER_MIXED_VISIBLE_AND_CACHED_SENTINEL_OK",
  "DRAW01_ALL_PASS",
  "STRUCT01_ALL_PASS",
  "NOTES01_ALL_PASS",
  "DCFG01_DRAWER_LIFECYCLE_ALL_PASS",
  "DCFG01_COORDINATION_ALL_PASS",
  "DCFG02_WIZARD_ALL_PASS",
  "DCFG02_FILESOURCE_ALL_PASS",
  "LSP_ALIAS_NO_SYNC_FETCH",
  "LSP_SCHEMA_ALIAS_VIEW_FALLBACK_OK",
  "LSP_SCHEMA_ALIAS_NO_SYNC_FETCH",
  "LSP_REBIND_NO_SYNC_FETCH",
  "LSP11_LRU_BOUND_HONORED",
  "LSP11_DISK_LOAD_BOUNDED",
  "LSP11_ASYNC_FAILURE_HANDLED",
  "LSP11_ASYNC_PAYLOAD_ERROR_HANDLED",
  "LSP11_ASYNC_MATERIALIZATION_PROBE_CHAIN_OK",
  "LSP11_DIAGNOSTIC_NAMESPACE_OK",
  "LSP11_DEBOUNCE_DIDCHANGE_OK",
  "LSP11_DISK_DEFERRED_GENERATION_FENCED",
  "LSP11_DISK_CORRUPT_RECOVERY_OK",
  "LSP11_ASYNC_DEDUPE_MATERIALIZATION_AWARE",
  "LSP11_DIAGNOSTICS_SINGLE_NAMESPACE_OWNED",
  "LSP11_DISK_DISCOVERY_BOUNDED",
  "LSP11_DISK_INDEX_CORRUPT_RECOVERY_OK",
  "LSP11_DISK_INDEX_CROSS_FIELD_OK",
  "LSP11_DISK_DEFERRED_PRUNE_DRAINED",
  "LSP11_LSP_SYNC_DELIVERY_OK",
  "LSP11_INCREMENTAL_GLOBAL_INDEX_OK",
  "LSP11_DISK_DISCOVERY_ADVERSARIAL_OK",
  "LSP11_INCREMENTAL_INDEX_EQUIVALENT",
  "LSP11_ASYNC_SYNC_DELIVERY_OK",
  "LSP_COMPLETION_REFRESH_NOTIFY_OK",
}

local ROLLUP_CHECK_COUNT = #required_true_markers + 6

local function parse_markers(lines)
  local marker_values = {}
  local marker_records = {}
  for _, line in ipairs(lines) do
    local key, value = line:match("^([%w_]+)=(.*)$")
    if key and value then
      marker_values[key] = marker_values[key] or {}
      marker_values[key][#marker_values[key] + 1] = value
      marker_records[#marker_records + 1] = {
        key = key,
        value = value,
      }
    end
  end
  return marker_values, marker_records
end

local function evaluate(lines)
  local marker_values, marker_records = parse_markers(lines)
  local failures = {}
  local count_failures = {}

  local function add_count_failure(reason)
    count_failures[#count_failures + 1] = reason
    failures[#failures + 1] = "LSP01 count check failed: " .. reason
  end

  local function require_marker(label, allowed)
    local values = marker_values[label]
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

  local function require_single_marker(label, expected)
    local values = marker_values[label]
    if not values or #values == 0 then
      add_count_failure("missing " .. label)
      return
    end
    if #values ~= 1 then
      add_count_failure(label .. " expected exactly one emission, got " .. tostring(#values))
      return
    end
    if values[1] ~= expected then
      add_count_failure(label .. " expected " .. expected .. ", got " .. tostring(values[1]))
    end
  end

  local function require_pattern_count(label, key_pattern, expected, opts)
    opts = opts or {}
    local count = 0
    local seen = {}
    for _, record in ipairs(marker_records) do
      if record.key:match(key_pattern) then
        if record.value ~= "true" then
          add_count_failure(record.key .. " has unsupported value " .. tostring(record.value))
        end
        if opts.distinct then
          if not seen[record.key] then
            seen[record.key] = true
            count = count + 1
          end
        else
          count = count + 1
        end
      end
    end
    if count ~= expected then
      add_count_failure(label .. " expected " .. tostring(expected) .. ", got " .. tostring(count))
    end
  end

  local function require_true(label)
    require_marker(label, { ["true"] = true })
  end

  for _, marker in ipairs(required_true_markers) do
    require_true(marker)
  end

  require_marker("DRAW01_REAL_NUI_PERF_ALL_PASS", { ["true"] = true, unfrozen = true })
  require_marker("LSP01_REAL_LSP_PERF_ALL_PASS", { ["true"] = true, unfrozen = true })
  require_single_marker("LSP01_SCENARIOS_COUNT", "33")
  require_pattern_count("LSP01 sentinel markers", "^LSP01_.*_SENTINEL_OK$", 33, { distinct = true })
  require_pattern_count("LSP01 no-stale-client markers", "^LSP01_.*_NO_STALE_CLIENTS$", 18, { distinct = true })
  require_pattern_count("LSP01 diagnostics didchange compute-only markers", "^LSP01_DIAGNOSTICS_DIDCHANGE_COMPUTE_ONLY$", 3)

  return {
    ok = #failures == 0,
    failures = failures,
    count_failures = count_failures,
  }
end

local function read_rollup_lines()
  local log_path = vim.env.UX13_ROLLUP_LOG
  if not log_path or log_path == "" then
    fail({ "missing UX13_ROLLUP_LOG" })
  end

  local ok_read, lines = pcall(vim.fn.readfile, log_path)
  if not ok_read or type(lines) ~= "table" then
    fail({ "unable to read UX13_ROLLUP_LOG: " .. tostring(log_path) })
  end
  return lines
end

local function valid_synthetic_log()
  local lines = {}
  for _, marker in ipairs(required_true_markers) do
    lines[#lines + 1] = marker .. "=true"
  end
  lines[#lines + 1] = "DRAW01_REAL_NUI_PERF_ALL_PASS=unfrozen"
  lines[#lines + 1] = "LSP01_REAL_LSP_PERF_ALL_PASS=unfrozen"
  lines[#lines + 1] = "LSP01_SCENARIOS_COUNT=33"
  for index = 1, 33 do
    lines[#lines + 1] = string.format("LSP01_SYNTH_%02d_SENTINEL_OK=true", index)
  end
  for index = 1, 18 do
    lines[#lines + 1] = string.format("LSP01_SYNTH_%02d_NO_STALE_CLIENTS=true", index)
  end
  for _ = 1, 3 do
    lines[#lines + 1] = "LSP01_DIAGNOSTICS_DIDCHANGE_COMPUTE_ONLY=true"
  end
  return lines
end

local function has_failure(result, pattern)
  for _, failure in ipairs(result.failures or {}) do
    if failure:find(pattern, 1, true) then
      return true
    end
  end
  for _, failure in ipairs(result.count_failures or {}) do
    if failure:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

local function selftest()
  local valid = evaluate(valid_synthetic_log())
  if not valid.ok then
    fail({ "selftest valid synthetic log failed: " .. table.concat(valid.failures, "; ") })
  end

  local duplicate_unexpected = valid_synthetic_log()
  table.insert(duplicate_unexpected, 1, "UX13_CACHE_VERSION2_WRITTEN=maybe")
  local duplicate_result = evaluate(duplicate_unexpected)
  if duplicate_result.ok or not has_failure(duplicate_result, "UX13_CACHE_VERSION2_WRITTEN has unsupported value maybe") then
    fail({ "selftest duplicate unexpected marker did not fail" })
  end

  local missing_count = valid_synthetic_log()
  for index = #missing_count, 1, -1 do
    if missing_count[index]:match("^LSP01_SYNTH_33_SENTINEL_OK=") then
      table.remove(missing_count, index)
      break
    end
  end
  local missing_count_result = evaluate(missing_count)
  if missing_count_result.ok or not has_failure(missing_count_result, "LSP01 sentinel markers expected 33, got 32") then
    fail({ "selftest missing LSP01 sentinel count did not fail" })
  end

  local false_marker = valid_synthetic_log()
  table.insert(false_marker, 1, "UX13_CACHE_VERSION2_WRITTEN=false")
  local false_result = evaluate(false_marker)
  if false_result.ok or not has_failure(false_result, "UX13_CACHE_VERSION2_WRITTEN has unsupported value false") then
    fail({ "selftest false duplicate marker did not fail" })
  end

  emit("UX13_ROLLUP_SELFTEST_ALL_PASS", "true")
  vim.cmd("qa!")
end

if vim.env.UX13_ROLLUP_SELFTEST == "1" then
  selftest()
end

local result = evaluate(read_rollup_lines())
if not result.ok then
  for _, failure in ipairs(result.count_failures) do
    emit("UX13_ROLLUP_LSP01_COUNT_FAIL", failure)
  end
  fail(result.failures)
end

emit("UX13_ROLLUP_LSP01_COUNTS_OK", "true")
emit("UX13_ROLLUP_MARKERS_CHECKED", tostring(ROLLUP_CHECK_COUNT))
emit("UX13_ALL_PASS", "true")
vim.cmd("qa!")
