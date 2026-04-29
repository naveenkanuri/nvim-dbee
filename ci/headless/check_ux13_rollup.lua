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

local log_path = vim.env.UX13_ROLLUP_LOG
if not log_path or log_path == "" then
  fail({ "missing UX13_ROLLUP_LOG" })
end

local ok_read, lines = pcall(vim.fn.readfile, log_path)
if not ok_read or type(lines) ~= "table" then
  fail({ "unable to read UX13_ROLLUP_LOG: " .. tostring(log_path) })
end

local marker_values = {}
for _, line in ipairs(lines) do
  local key, value = line:match("^([%w_]+)=(.+)$")
  if key and value then
    marker_values[key] = marker_values[key] or {}
    marker_values[key][#marker_values[key] + 1] = value
  end
end

local failures = {}

local function require_marker(label, allowed)
  local values = marker_values[label]
  if not values or #values == 0 then
    failures[#failures + 1] = "missing " .. label
    return
  end

  for _, value in ipairs(values) do
    if value == "false" then
      failures[#failures + 1] = label .. " emitted false"
      return
    end
  end

  for _, value in ipairs(values) do
    if allowed[value] then
      return
    end
  end

  failures[#failures + 1] = label .. " has unsupported value " .. tostring(values[#values])
end

local function require_true(label)
  require_marker(label, { ["true"] = true })
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
}

for _, marker in ipairs(required_true_markers) do
  require_true(marker)
end

require_marker("DRAW01_REAL_NUI_PERF_ALL_PASS", { ["true"] = true, unfrozen = true })
require_marker("LSP01_REAL_LSP_PERF_ALL_PASS", { ["true"] = true, unfrozen = true })

if #failures > 0 then
  fail(failures)
end

emit("UX13_ROLLUP_MARKERS_CHECKED", tostring(#required_true_markers + 2))
emit("UX13_ALL_PASS", "true")
vim.cmd("qa!")
