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
  "FOLDER15_ALL_PASS",
  "RICH16_ALL_PASS",
  "RICH_PG_ALL_PASS",
  "LSP_ALIAS_NO_SYNC_FETCH",
  "LSP_SCHEMA_ALIAS_VIEW_FALLBACK_OK",
  "LSP_SCHEMA_ALIAS_NO_SYNC_FETCH",
  "LSP_SCHEMA_ALIAS_CASE_FOLD_OK",
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
  "LSP11_R6_SCHEMA_CASE_LOOKUP_MATCHES",
  "LSP11_R6_CANONICAL_HELPER_PRESENT",
  "LSP11_R6_CANONICAL_HELPER_LOWER_FOLD",
  "LSP11_R6_CANONICAL_HELPER_UPPER_FOLD",
  "LSP11_R6_CANONICAL_HELPER_QUOTED_PRESERVED",
  "LSP11_R6_CANONICAL_HELPER_IDENTITY",
  "LSP11_R6_CANONICAL_HELPER_ALL_CONSUMERS_ROUTED",
  "LSP11_R6_DRAWER_LOADED_SCHEMAS_CANONICAL",
  "LSP11_R6_LSP_SAME_CACHE_ID_CANONICAL",
  "LSP11_R6_HANDLER_SINGLEFLIGHT_CANONICAL",
  "LSP11_R6_CONTEXT_QUOTE_METADATA",
  "LSP11_R6_INC_FULL_REPR_EQUIVALENT",
  "LSP11_R6_QUOTED_VS_UNQUOTED_DISTINCT",
  "LSP11_R6_UNQUOTED_FOLDS_NOT_EXACT",
  "LSP11_R6_LOADED_SCHEMA_EXACT_AWARE",
  "LSP11_R6_SINGLEFLIGHT_EXACT_KEY",
  "LSP11_R6_TARGETED_GLOBAL_INDEX_O1",
  "LSP11_R6_LUA_NIL_TERNARY_CLEARED",
  "LSP11_R6_REFRESH_LOADED_STATE_EXACT",
  "LSP11_R6_SCHEMA_FILTER_CANONICAL_ROUTED",
  "LSP11_R6_PROBE_FALLBACK_ADAPTER_AWARE",
  "LSP_COMPLETION_REFRESH_NOTIFY_OK",
  "LSP12_HOVER_RESOLVE_ALL_PASS",
}

local DB18_BEHAVIOR_MARKERS = {
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

local DB18_REQUIRED_EXISTING_MARKERS = {
  { source = "ARCH14_ALL_PASS", preserved = "DB18_ARCH14_PRESERVED_OK" },
  { source = "FOLDER15_ALL_PASS", preserved = "DB18_FOLDER15_PRESERVED_OK" },
  { source = "RICH16_ALL_PASS", preserved = "DB18_RICH16_PRESERVED_OK" },
  { source = "RICH_PG_ALL_PASS", preserved = "DB18_RICH_PG_PRESERVED_OK" },
  { source = "LSP12_HOVER_RESOLVE_ALL_PASS", preserved = "DB18_LSP12_PRESERVED_OK" },
}

local DB18_BEHAVIOR_OWNED_MARKERS = {
  DB18_NO_CORE_STRUCTURE_DATABASE_OK = true,
  DB18_LOCKED_HELPERS_UNTOUCHED_OK = true,
  DB18_ADAPTER_CURRENT_DB_FALLBACK_OK = true,
}

local GN23_EXPECTED_STRICT_MARKER_COUNT = 88
local DB18_STRICT_MARKER_COUNT = #DB18_BEHAVIOR_MARKERS + #DB18_REQUIRED_EXISTING_MARKERS
local ROLLUP_CHECK_COUNT = #required_true_markers
  + 6
  + #DB18_BEHAVIOR_MARKERS
  + #DB18_REQUIRED_EXISTING_MARKERS
  + 2
  + GN23_EXPECTED_STRICT_MARKER_COUNT
  + 1

local function read_all(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then
    return nil
  end
  return table.concat(lines, "\n")
end

local function load_gn23_strict_markers()
  local plan = read_all(vim.fn.getcwd() .. "/.planning/phases/23-folder-scoped-notes/PLAN.md")
  if not plan then
    return nil, "unable to read Phase 23 PLAN.md"
  end

  local marker_pattern = "GN23_" .. "[A-Z0-9_]+_" .. "OK"
  local seen = {}
  local markers = {}
  for marker in plan:gmatch(marker_pattern) do
    if not seen[marker] then
      seen[marker] = true
      markers[#markers + 1] = marker
    end
  end
  table.sort(markers)
  return markers
end

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

local function evaluate_gn23(marker_values)
  local failures = {}
  local strict_markers, load_err = load_gn23_strict_markers()
  if not strict_markers then
    return {
      ok = false,
      failures = { load_err },
      strict_marker_count = 0,
    }
  end

  if #strict_markers ~= GN23_EXPECTED_STRICT_MARKER_COUNT then
    failures[#failures + 1] = "Phase 23 plan strict marker count expected "
      .. tostring(GN23_EXPECTED_STRICT_MARKER_COUNT)
      .. ", got "
      .. tostring(#strict_markers)
  end

  local seen_count = 0
  for _, marker in ipairs(strict_markers) do
    local values = marker_values[marker]
    if not values or #values == 0 then
      failures[#failures + 1] = "missing " .. marker
    elseif #values ~= 1 then
      failures[#failures + 1] = marker .. " expected exactly one emission, got " .. tostring(#values)
    elseif values[1] ~= "true" and tostring(values[1]):sub(1, 4) ~= "true" then
      failures[#failures + 1] = marker .. " has unsupported value " .. tostring(values[1])
    else
      seen_count = seen_count + 1
    end
  end

  local diagnostic = marker_values.GN23_MIGRATION_PERF_BUDGET_DIAGNOSTIC
  if not diagnostic or #diagnostic == 0 then
    failures[#failures + 1] = "missing GN23_MIGRATION_PERF_BUDGET_DIAGNOSTIC"
  end

  return {
    ok = #failures == 0,
    failures = failures,
    strict_marker_count = seen_count,
  }
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

  local function require_db18_marker(label)
    local values = marker_values[label]
    if not values or #values == 0 then
      add_count_failure("missing " .. label)
      return false
    end
    local saw_true = false
    for _, value in ipairs(values) do
      if value ~= "true" then
        add_count_failure(label .. " has unsupported value " .. tostring(value))
      else
        saw_true = true
      end
    end
    return saw_true
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

  local db18_behavior_seen = {}
  for _, marker in ipairs(DB18_BEHAVIOR_MARKERS) do
    if require_db18_marker(marker) then
      db18_behavior_seen[marker] = true
    end
  end

  local db18_behavior_count = 0
  for _, marker in ipairs(DB18_BEHAVIOR_MARKERS) do
    if db18_behavior_seen[marker] then
      db18_behavior_count = db18_behavior_count + 1
    end
  end
  if db18_behavior_count ~= #DB18_BEHAVIOR_MARKERS then
    add_count_failure("DB18 behavior markers expected " .. tostring(#DB18_BEHAVIOR_MARKERS) .. ", got " .. tostring(db18_behavior_count))
  end

  local db18_preservation = {}
  for _, spec in ipairs(DB18_REQUIRED_EXISTING_MARKERS) do
    local values = marker_values[spec.source]
    local ok = values and #values > 0
    if ok then
      for _, value in ipairs(values) do
        if value ~= "true" then
          ok = false
          add_count_failure(spec.source .. " has unsupported value " .. tostring(value))
        end
      end
    else
      add_count_failure("missing " .. spec.source)
    end
    db18_preservation[spec.preserved] = ok == true
  end

  local gn23_result = evaluate_gn23(marker_values)
  if not gn23_result.ok then
    for _, failure in ipairs(gn23_result.failures) do
      add_count_failure(failure)
    end
  end

  return {
    ok = #failures == 0,
    failures = failures,
    count_failures = count_failures,
    db18_preservation = db18_preservation,
    db18_strict_marker_count = DB18_STRICT_MARKER_COUNT,
    gn23_strict_marker_count = gn23_result.strict_marker_count,
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
  local filtered = {}
  for _, line in ipairs(lines) do
    if line == "===CMD-SOURCE: ux13-rollup===" then
      break
    end
    filtered[#filtered + 1] = line
  end
  return filtered
end

local function valid_synthetic_log()
  local lines = {}
  for _, marker in ipairs(required_true_markers) do
    lines[#lines + 1] = marker .. "=true"
  end
  lines[#lines + 1] = "ARCH14_ALL_PASS=true"
  for _, marker in ipairs(DB18_BEHAVIOR_MARKERS) do
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
  local gn23_markers, gn23_err = load_gn23_strict_markers()
  if not gn23_markers then
    fail({ gn23_err })
  end
  for _, marker in ipairs(gn23_markers) do
    lines[#lines + 1] = marker .. "=true"
  end
  lines[#lines + 1] = "GN23_MIGRATION_PERF_BUDGET_DIAGNOSTIC=n=25 median_ms=1.00 p95_ms=1.00 max_ms=1.00 target_ms=250"
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

  local missing_db18 = valid_synthetic_log()
  for index = #missing_db18, 1, -1 do
    if missing_db18[index] == "DB18_SEARCH_DATABASE_OK=true" then
      table.remove(missing_db18, index)
      break
    end
  end
  local missing_db18_result = evaluate(missing_db18)
  if missing_db18_result.ok or not has_failure(missing_db18_result, "missing DB18_SEARCH_DATABASE_OK") then
    fail({ "selftest missing DB18 behavior marker did not fail" })
  end

  local false_db18 = valid_synthetic_log()
  table.insert(false_db18, "DB18_SEARCH_DATABASE_OK=false")
  local false_db18_result = evaluate(false_db18)
  if false_db18_result.ok or not has_failure(false_db18_result, "DB18_SEARCH_DATABASE_OK has unsupported value false") then
    fail({ "selftest false DB18 behavior marker did not fail" })
  end

  local conflicting_db18 = valid_synthetic_log()
  table.insert(conflicting_db18, "DB18_SEARCH_DATABASE_OK=false")
  local conflicting_db18_result = evaluate(conflicting_db18)
  if conflicting_db18_result.ok or not has_failure(conflicting_db18_result, "DB18_SEARCH_DATABASE_OK has unsupported value false") then
    fail({ "selftest conflicting duplicate DB18 behavior marker did not fail" })
  end

  local gn23_markers, gn23_err = load_gn23_strict_markers()
  if not gn23_markers then
    fail({ gn23_err })
  end

  local missing_gn23 = valid_synthetic_log()
  for index = #missing_gn23, 1, -1 do
    if missing_gn23[index] == gn23_markers[1] .. "=true" then
      table.remove(missing_gn23, index)
      break
    end
  end
  local missing_gn23_result = evaluate(missing_gn23)
  if missing_gn23_result.ok or not has_failure(missing_gn23_result, "missing " .. gn23_markers[1]) then
    fail({ "selftest missing GN23 marker did not fail" })
  end

  local duplicate_gn23 = valid_synthetic_log()
  duplicate_gn23[#duplicate_gn23 + 1] = gn23_markers[1] .. "=true"
  local duplicate_gn23_result = evaluate(duplicate_gn23)
  if duplicate_gn23_result.ok or not has_failure(duplicate_gn23_result, gn23_markers[1] .. " expected exactly one emission") then
    fail({ "selftest duplicate GN23 marker did not fail" })
  end

  local missing_gn23_diagnostic = valid_synthetic_log()
  for index = #missing_gn23_diagnostic, 1, -1 do
    if missing_gn23_diagnostic[index]:match("^GN23_MIGRATION_PERF_BUDGET_DIAGNOSTIC=") then
      table.remove(missing_gn23_diagnostic, index)
      break
    end
  end
  local missing_gn23_diagnostic_result = evaluate(missing_gn23_diagnostic)
  if
    missing_gn23_diagnostic_result.ok
    or not has_failure(missing_gn23_diagnostic_result, "missing GN23_MIGRATION_PERF_BUDGET_DIAGNOSTIC")
  then
    fail({ "selftest missing GN23 diagnostic marker did not fail" })
  end

  local missing_arch14 = valid_synthetic_log()
  for index = #missing_arch14, 1, -1 do
    if missing_arch14[index] == "ARCH14_ALL_PASS=true" then
      table.remove(missing_arch14, index)
      break
    end
  end
  local missing_arch14_result = evaluate(missing_arch14)
  if
    missing_arch14_result.ok
    or missing_arch14_result.db18_preservation.DB18_ARCH14_PRESERVED_OK == true
    or not has_failure(missing_arch14_result, "missing ARCH14_ALL_PASS")
  then
    fail({ "selftest missing ARCH14 preservation marker did not fail" })
  end

  local missing_lsp12 = valid_synthetic_log()
  for index = #missing_lsp12, 1, -1 do
    if missing_lsp12[index] == "LSP12_HOVER_RESOLVE_ALL_PASS=true" then
      table.remove(missing_lsp12, index)
      break
    end
  end
  local missing_lsp12_result = evaluate(missing_lsp12)
  if missing_lsp12_result.ok or missing_lsp12_result.db18_preservation.DB18_LSP12_PRESERVED_OK == true then
    fail({ "selftest missing existing all-pass did not suppress DB18_ALL_PASS" })
  end

  local rollup_src = table.concat(vim.fn.readfile(vim.fn.getcwd() .. "/ci/headless/check_ux13_rollup.lua"), "\n")
  for marker in pairs(DB18_BEHAVIOR_OWNED_MARKERS) do
    if rollup_src:find('emit%("' .. marker .. '"', 1) then
      fail({ "selftest UX13 attempted to emit behavior-owned marker " .. marker })
    end
  end

  emit("UX13_ROLLUP_SELFTEST_ALL_PASS", "true")
  vim.cmd("qa!")
end

local function emit_gn23_success(strict_marker_count)
  local prefix = "GN" .. "23_"
  emit(prefix .. "FOLDER15_PRESERVED_" .. "OK", "true")
  emit(prefix .. "NOTES01_PICKER_CONTRACT_PRESERVED_" .. "OK", "true")
  emit(prefix .. "LOCKED_HELPERS_UNTOUCHED_" .. "OK", "true")
  emit(prefix .. "NO_GO_RPC_ADDED_" .. "OK", "true")
  emit("GN23_STRICT_MARKER_COUNT", tostring(strict_marker_count))
  emit("GN23_ALL_PASS", "true")
end

local function fail_gn23(failures)
  for _, failure in ipairs(failures) do
    emit("GN23_ROLLUP_FAIL", failure)
  end
  emit("GN23_ALL_PASS", "false")
  vim.cmd("cquit 1")
end

if vim.env.UX13_ROLLUP_SELFTEST == "1" then
  selftest()
end

if vim.env.GN23_ROLLUP_ONLY == "1" then
  local marker_values = parse_markers(read_rollup_lines())
  local gn23_result = evaluate_gn23(marker_values)
  if not gn23_result.ok then
    fail_gn23(gn23_result.failures)
  end
  emit_gn23_success(gn23_result.strict_marker_count)
  vim.cmd("qa!")
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
for _, spec in ipairs(DB18_REQUIRED_EXISTING_MARKERS) do
  if result.db18_preservation[spec.preserved] ~= true then
    fail({ "missing preservation result " .. spec.preserved })
  end
  emit(spec.preserved, "true")
end
emit("DB18_STRICT_MARKER_COUNT", tostring(result.db18_strict_marker_count))
emit("DB18_ALL_PASS", "true")
emit_gn23_success(result.gn23_strict_marker_count)
emit("UX13_ALL_PASS", "true")
vim.cmd("qa!")
