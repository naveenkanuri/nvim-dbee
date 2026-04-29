---
phase: 13-ux-regression-batch
plan: 01
subsystem: ux-regressions
tags: [wizard, drawer, lsp-cache, perf]
key-files:
  - lua/dbee/lsp/schema_cache.lua
  - lua/dbee/ui/drawer/model.lua
  - lua/dbee/ui/drawer/init.lua
  - lua/dbee/ui/drawer/menu.lua
  - lua/dbee/ui/connection_wizard/init.lua
  - ci/headless/check_lsp_disk_cache_safety.lua
  - ci/headless/check_drawer_filter.lua
  - ci/headless/check_drawer_perf.lua
  - ci/headless/perf_thresholds.lua
  - ci/headless/check_connection_wizard.lua
  - ci/headless/check_ux13_rollup.lua
  - ci/headless/perf_bootstrap.mk
  - Makefile
metrics:
  ux13_all_pass: true
  draw01_rollup: unfrozen
  lsp01_rollup: unfrozen
---

# Phase 13 Summary

## Commits

| Task | Commit | Description |
|---|---:|---|
| 13-01-01 | b0b2305 | Added schema-index cache version 2, shape-validated legacy v1 silent migration, and WARN retention for true corruption. |
| 13-01-02 | 819a3e3 | Added drawer filter visible-connection fallback for cold and mixed cached/uncached roots plus advisory perf scenarios. |
| 13-01-03 | 1436bdc | Applied the locked wizard float highlight mapping to wizard Popup/Input/Menu surfaces with render-state tests. |
| impl-gate r1 fix | this changeset | Added fail-closed UX13 rollup aggregation, deeper mixed drawer coverage, and real menu win_options threading coverage. |

## Deviations

- None. The implementation stayed within Phase 13 regression scope.
- Local Neovim headless LSP checks required `XDG_STATE_HOME=/tmp/...` because sandboxed runs cannot write `~/.local/state/nvim/nio.log`.
- Local `make perf` marker greps used `2>&1 | tee` so headless Neovim marker output is captured in the log file.

## Verification

- New Phase 13 gates passed:
  - `UX13_CACHE_VERSION2_WRITTEN=true`
  - `UX13_CACHE_LEGACY_V1_SILENT=true`
  - `UX13_CACHE_TRUE_CORRUPTION_WARN_RETAINED=true`
  - `UX13_DRAWER_FILTER_CONNECTION_ROOT=true`
  - `UX13_DRAWER_FILTER_SOURCE_BADGE=true`
  - `UX13_DRAWER_FILTER_MIXED_VISIBLE_CACHE=true`
  - `UX13_DRAWER_FILTER_EXPANDED_CACHED_VS_VISIBLE_OK=true`
  - `UX13_DRAWER_FILTER_ZERO_RPC=true`
  - `UX13_DRAWER_FILTER_RESTORE_OK=true`
  - `UX13_DRAWER_FILTER_ALL_PASS=true`
  - `UX13_WIZARD_WINHIGHLIGHT_MAIN=true`
  - `UX13_WIZARD_WINHIGHLIGHT_PASSWORD=true`
  - `UX13_WIZARD_WINHIGHLIGHT_INPUT=true`
  - `UX13_WIZARD_WINHIGHLIGHT_SELECT=true`
  - `UX13_WIZARD_WINHIGHLIGHT_MULTILINE=true`
  - `UX13_WIZARD_NUI_WIN_OPTIONS_THREADED=true`
  - `UX13_WIZARD_ALL_PASS=true`
- Preserved smoke suites passed:
  - `DRAW01_ALL_PASS=true`
  - `STRUCT01_ALL_PASS=true`
  - `NOTES01_ALL_PASS=true`
  - `DCFG01_DRAWER_LIFECYCLE_ALL_PASS=true`
  - `DCFG01_COORDINATION_ALL_PASS=true`
  - `DCFG02_WIZARD_ALL_PASS=true`
  - `DCFG02_FILESOURCE_ALL_PASS=true`
- Preserved LSP semantic checks passed:
  - `check_lsp_alias_completion.lua`
  - `check_lsp_schema_alias_completion.lua`
  - `check_lsp_alias_rebinding.lua`
- Required LSP11 family markers passed across the Phase 11 headless suites, including:
  - `LSP11_LRU_BOUND_HONORED=true`
  - `LSP11_DISK_LOAD_BOUNDED=true`
  - `LSP11_ASYNC_FAILURE_HANDLED=true`
  - `LSP11_ASYNC_PAYLOAD_ERROR_HANDLED=true`
  - `LSP11_ASYNC_MATERIALIZATION_PROBE_CHAIN_OK=true`
  - `LSP11_DIAGNOSTIC_NAMESPACE_OK=true`
  - `LSP11_DEBOUNCE_DIDCHANGE_OK=true`
  - `LSP11_DISK_DEFERRED_GENERATION_FENCED=true`
  - `LSP11_DISK_CORRUPT_RECOVERY_OK=true`
  - `LSP11_ASYNC_DEDUPE_MATERIALIZATION_AWARE=true`
  - `LSP11_DIAGNOSTICS_SINGLE_NAMESPACE_OWNED=true`
  - `LSP11_DISK_DISCOVERY_BOUNDED=true`
  - `LSP11_DISK_INDEX_CORRUPT_RECOVERY_OK=true`
  - `LSP11_DISK_INDEX_CROSS_FIELD_OK=true`
  - `LSP11_DISK_DEFERRED_PRUNE_DRAINED=true`
  - `LSP11_LSP_SYNC_DELIVERY_OK=true`
  - `LSP11_INCREMENTAL_GLOBAL_INDEX_OK=true`
  - `LSP11_DISK_DISCOVERY_ADVERSARIAL_OK=true`
  - `LSP11_INCREMENTAL_INDEX_EQUIVALENT=true`
  - `LSP11_ASYNC_SYNC_DELIVERY_OK=true`
- Perf gates passed locally in advisory mode:
  - `DRAW01_FILTER_COLD_CONNECTION_ONLY_10_SENTINEL_OK=true`
  - `DRAW01_FILTER_COLD_CONNECTION_ONLY_100_SENTINEL_OK=true`
  - `DRAW01_FILTER_COLD_CONNECTION_ONLY_1000_SENTINEL_OK=true`
  - `DRAW01_FILTER_MIXED_VISIBLE_AND_CACHED_SENTINEL_OK=true`
  - `DRAW01_REAL_NUI_PERF_ALL_PASS=unfrozen`
  - `LSP01_SCENARIOS_COUNT=33`
  - `LSP01_REAL_LSP_PERF_ALL_PASS=unfrozen`
- Fail-closed Phase 13 rollup passed via `ci/headless/check_ux13_rollup.lua`, wired into `make perf-lsp`:
  - `UX13_ROLLUP_MARKERS_CHECKED=62`
  - `UX13_ALL_PASS=true`

## Self-Check: PASSED

`UX13_ALL_PASS=true` is emitted by `ci/headless/check_ux13_rollup.lua` after scanning the combined verification log produced by `make perf-lsp`; it is no longer a summary-only self-attestation.
