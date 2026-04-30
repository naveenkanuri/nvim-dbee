-- Fail-closed Phase 14 architecture rollup gate.
--
-- Usage:
--   ARCH14_ROLLUP_LOG=/path/to/combined-stdout.log nvim --headless -u NONE -i NONE -n \
--     --cmd "set rtp+=$(pwd)" \
--     -c "luafile ci/headless/check_arch14_rollup.lua"

local function emit(label, value)
  print(label .. "=" .. tostring(value))
end

local function fail(failures)
  for _, failure in ipairs(failures) do
    emit("ARCH14_ROLLUP_FAIL", failure)
  end
  emit("ARCH14_ALL_PASS", "false")
  vim.cmd("cquit 1")
end

local required_true_markers = {
  "ARCH14_SCHEMA_FILTER_PERSISTED",
  "ARCH14_SCHEMA_FILTER_RPC_ROUNDTRIP_OK",
  "ARCH14_SCHEMA_FILTER_MATCHING_OK",
  "ARCH14_SCHEMA_FILTER_SIGNATURE_STABLE",
  "ARCH14_SCHEMA_FILTER_INVALID_PATTERN_REJECTED",
  "ARCH14_LAZY_REQUIRES_INCLUDE",
  "ARCH14_FILTER_CLEAR_NO_STALE",
  "ARCH14_FILTER_VALIDATION_ENFORCED",
  "ARCH14_SCHEMA_FILTER_ALL_PASS",
  "ARCH14_OPTIONS_LUA_GO_ROUNDTRIP_OK",
  "ARCH14_RPC_MANIFEST_REGISTERED",
  "ARCH14_SCHEMA_LIST_SINGLEFLIGHT_OK",
  "ARCH14_SCHEMA_OBJECT_SINGLEFLIGHT_OK",
  "ARCH14_SCHEMA_OBJECT_BACKPRESSURE_OK",
  "ARCH14_SCHEMA_OBJECT_QUEUE_BOUNDED",
  "ARCH14_QUEUE_PRIORITY_HONORED",
  "ARCH14_QUEUE_COALESCE_OK",
  "ARCH14_SCHEMA_EVENTS_SHAPED",
  "ARCH14_FILTERED_STRUCTURE_API_OK",
  "ARCH14_HANDLER_SCHEMA_EVENTS_ALL_PASS",
  "ARCH14_TOP4_ADAPTER_CAPABILITIES_OK",
  "ARCH14_ADAPTER_ORACLE_PUSHDOWN_OK",
  "ARCH14_ADAPTER_ORACLE_PUSHDOWN_PER_ARM_OK",
  "ARCH14_ADAPTER_POSTGRES_PUSHDOWN_OK",
  "ARCH14_ADAPTER_POSTGRES_PUSHDOWN_PER_ARM_OK",
  "ARCH14_ADAPTER_MYSQL_PUSHDOWN_OK",
  "ARCH14_ADAPTER_MYSQL_PUSHDOWN_PER_ARM_OK",
  "ARCH14_ADAPTER_MSSQL_PUSHDOWN_OK",
  "ARCH14_ADAPTER_MSSQL_PUSHDOWN_PER_ARM_OK",
  "ARCH14_ADAPTER_ALL_PASS",
  "ARCH14_SCHEMA_ONLY_ROOT_FAST",
  "ARCH14_SCHEMA_BRANCH_LAZY_OK",
  "ARCH14_SCHEMA_BRANCH_ERROR_RETRY_OK",
  "ARCH14_ZERO_RPC_DRAWER_FILTER_PRESERVED",
  "ARCH14_DRAWER_FILTER_LOADED_SCHEMA_BRANCH_OK",
  "ARCH14_DRAWER_ALL_PASS",
  "ARCH14_CACHE_V3_MIGRATION_OK",
  "ARCH14_FILTER_CHANGE_INVALIDATES",
  "ARCH14_FILTER_CHANGE_CACHE_DELETION_BOUNDED",
  "ARCH14_FILTER_DELETION_BOUNDED_SCAN",
  "ARCH14_PENDING_DELETION_FENCE_OK",
  "ARCH14_CACHE_TRUE_CORRUPTION_WARN_RETAINED",
  "ARCH14_SCHEMA_CACHE_PARTIAL_INDEX_OK",
  "ARCH14_SCHEMA_FILTER_DOWNSTREAM_ALL_PASS",
  "ARCH14_LUA_DEFENSE_FILTER_OK",
  "ARCH14_LSP_SCHEMA_DOT_INCOMPLETE_OK",
  "ARCH14_LSP_SCHEMA_DOT_WARM_OK",
  "ARCH14_LSP_SCHEMA_DOT_NO_SYNC_FETCH",
  "ARCH14_QUEUE_FULL_TRUTHFUL_LSP",
  "ARCH14_OUT_OF_SCOPE_HINT_OK",
  "ARCH14_LSP_LAZY_UNLOADED_NO_FALSE_WARN",
  "ARCH14_LSP_UNQUALIFIED_LAZY_NO_FALSE_WARN",
  "ARCH14_LSP_ALL_PASS",
  "ARCH14_WIZARD_SCHEMA_FILTER_EDIT_OK",
  "ARCH14_WIZARD_CLEAR_FILTER_OK",
  "ARCH14_SCHEMA_DISCOVERY_MANUAL_FALLBACK",
  "ARCH14_WIZARD_ADD_DISCOVERY_NON_MUTATING",
  "ARCH14_WIZARD_ADD_DISCOVERY_DEFAULT_NO",
  "ARCH14_WIZARD_EDIT_DISCOVERY_DEFAULT_YES",
  "ARCH14_WIZARD_ALL_PASS",
  "ARCH14_LEGACY_FULL_STRUCTURE_COMPAT",
  "ARCH14_LEGACY_EAGER_FALLBACK_OK",
  "ARCH14_LAZY_PER_SCHEMA_FLAG_GATED",
  "ARCH14_FILTER_CHANGE_EPOCH_SINGLE_BUMP",
  "ARCH14_RECONNECT_FILTER_SIGNATURE_MIGRATION_OK",
  "ARCH14_RECONNECT_SCHEMA_FLIGHT_MIGRATION_OK",
  "ARCH14_PERF_REAL_MEASUREMENTS_OK",
  "UX13_ALL_PASS",
}

local advisory_markers = {
  ARCH14_PERF_LSP_SCHEMA_DOT_OK = true,
  ARCH14_PERF_DRAWER_FILTER_SCOPED_OK = true,
  DRAW01_REAL_NUI_PERF_ALL_PASS = true,
  LSP01_REAL_LSP_PERF_ALL_PASS = true,
}

local required_perf_true_markers = {
  "ARCH14_DRAWER_FILTER_SCOPED_10_SENTINEL_OK",
  "ARCH14_DRAWER_FILTER_SCOPED_100_SENTINEL_OK",
  "ARCH14_DRAWER_FILTER_SCOPED_1000_SENTINEL_OK",
  "ARCH14_DRAWER_FILTER_SCOPED_10000_SENTINEL_OK",
  "ARCH14_DRAWER_FILTER_MIXED_VISIBLE_AND_LAZY_SENTINEL_OK",
}

local function parse_markers(lines)
  local markers = {}
  for _, line in ipairs(lines) do
    local key, value = line:match("^([%w_]+)=(.*)$")
    if key and value then
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
  for label in pairs(advisory_markers) do
    require_marker(label, { ["true"] = true, unfrozen = true })
  end
  for _, label in ipairs(required_perf_true_markers) do
    require_marker(label, { ["true"] = true })
  end

  return {
    ok = #failures == 0,
    failures = failures,
    checked = #required_true_markers + vim.tbl_count(advisory_markers) + #required_perf_true_markers,
  }
end

local function read_lines()
  local log_path = vim.env.ARCH14_ROLLUP_LOG
  if not log_path or log_path == "" then
    fail({ "missing ARCH14_ROLLUP_LOG" })
  end
  local ok, lines = pcall(vim.fn.readfile, log_path)
  if not ok or type(lines) ~= "table" then
    fail({ "unable to read ARCH14_ROLLUP_LOG: " .. tostring(log_path) })
  end
  return lines
end

local function selftest()
  local lines = {}
  for _, marker in ipairs(required_true_markers) do
    lines[#lines + 1] = marker .. "=true"
  end
  for marker in pairs(advisory_markers) do
    lines[#lines + 1] = marker .. "=unfrozen"
  end
  for _, marker in ipairs(required_perf_true_markers) do
    lines[#lines + 1] = marker .. "=true"
  end
  local valid = evaluate(lines)
  if not valid.ok then
    fail({ "selftest valid synthetic log failed: " .. table.concat(valid.failures, "; ") })
  end

  table.insert(lines, 1, "ARCH14_LSP_ALL_PASS=maybe")
  local invalid = evaluate(lines)
  if invalid.ok then
    fail({ "selftest unsupported duplicate did not fail" })
  end

  local clean_lines = vim.deepcopy(lines)
  table.remove(clean_lines, 1)
  for _, missing_marker in ipairs(required_perf_true_markers) do
    local missing_log = {}
    for _, line in ipairs(clean_lines) do
      if not line:find("^" .. missing_marker .. "=", 1, false) then
        missing_log[#missing_log + 1] = line
      end
    end
    local missing_result = evaluate(missing_log)
    if missing_result.ok then
      fail({ "selftest missing exact scoped marker did not fail for " .. missing_marker })
    end
  end
  emit("ARCH14_ROLLUP_SELFTEST_ALL_PASS", "true")
  vim.cmd("qa!")
end

if vim.env.ARCH14_ROLLUP_SELFTEST == "1" then
  selftest()
end

local result = evaluate(read_lines())
if not result.ok then
  fail(result.failures)
end

emit("ARCH14_ROLLUP_MARKERS_CHECKED", result.checked)
emit("ARCH14_ALL_PASS", "true")
vim.cmd("qa!")
