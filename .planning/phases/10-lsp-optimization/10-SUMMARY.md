---
phase: 10-lsp-optimization
plan: 01
subsystem: lsp-perf-harness
tags: [lsp, perf, benchmark, ci]
key-files:
  - ci/headless/perf_bootstrap.mk
  - ci/headless/lsp_perf_thresholds.lua
  - ci/headless/check_lsp_perf.lua
  - lua/dbee/lsp/server.lua
  - lua/dbee/lsp/bench.lua
  - Makefile
  - .github/workflows/test.yml
metrics:
  scenarios: 29
  sentinel_true_count: 29
  sentinel_false_count: 0
  macos_rollup: unfrozen
---

# Phase 10 Summary

## Commits

| Task | Commit | Description |
|---|---:|---|
| 10-01-01 | fed004c | Extended shared Phase 9 perf bootstrap contract for LSP lane. |
| 10-01-02 | 29e1971 | Added LSP threshold source of truth. |
| 10-01-03 | a184c22 | Added `make perf-lsp` and `make perf-all`. |
| 10-01-04 | ed7390f | Migrated interactive LSP bench timer to `vim.uv`. |
| 10-01-05 | 1290d94 | Scaffolded LSP perf harness shell, markers, threshold state machine, artifacts. |
| 10-01-06 | 6713ff9 | Added deterministic fixtures, fake handler/state, lifecycle helpers. |
| 10-01-07 | 7aa72af | Added startup and metadata-fallback scenarios. |
| 10-01-08 | 97854e9 | Added cached completion scenarios. |
| 10-01-09 | 241ae84 | Added synchronous cold column miss scenario. |
| 10-01-10 | de7482b | Added diagnostics and alias/context scenarios. |
| 10-01-11 | fc9003e | Added schema-cache build/load/save scenarios. |
| 10-01-12 | 79e8739 | Added macOS/Linux LSP perf advisory workflow. |
| harness fix | 5fdce3e | Exercised real table context for table/schema completion cohorts. |
| harness fix | da6b091 | Stabilized column-miss warmup/reset lifecycle. |
| harness fix | 201dd75 | Isolated column-miss buffers per sample while sharing cache. |
| harness fix | fac19ff | Published diagnostics through Neovim 0.12 `dispatchers.notification`. |
| harness fix | 61d0be0 | Aligned alias fixtures with synthetic schema distribution. |
| harness fix | c6bf1ee | Defined cache cleanup before cache scenario registration. |
| harness fix | 9a79b97 | Scoped startup lifecycle sentinel requirements by cohort. |

## Deviations

- Added one production-path fix in `lua/dbee/lsp/server.lua`: diagnostics now call `dispatchers.notification` with `dispatchers.on_notify` fallback. This was required for the real Neovim 0.12 LSP client path to receive `textDocument/publishDiagnostics`; no optimization or feature behavior was added.
- Added harness-needed fixes after local smoke exposed fixture/lifecycle bugs. All stayed scoped to Phase 10 measurement fidelity.

## Verification

- `make perf-lsp PERF_PLATFORM=macos` passed locally with:
  - `LSP01_SCENARIOS_COUNT=29`
  - `SENTINEL_TRUE_COUNT=29`
  - `SENTINEL_FALSE_COUNT=0`
  - `LSP01_COLUMN_MISS_FETCH_DELTAS=1,0,0,0,0,0,0,0,0,0`
  - `LSP01_COLUMN_MISS_FETCH_DELTAS_OK=true`
  - `LSP01_COLD_DISK_DEFERRED_CALLBACK_COUNT=0`
  - `LSP01_WARM_DISK_DEFERRED_CALLBACK_COUNT=0`
  - `LSP01_METADATA_FALLBACK_DEFERRED_CALLBACK_COUNT=1`
  - `LSP01_PLATFORM_AUTHENTIC=true`
  - `LSP01_PUBLISHABLE=true`
  - `LSP01_REAL_LSP_PERF_ALL_PASS=unfrozen`
  - summary and trace artifacts non-empty.
- Existing Phase 9 drawer perf target passed locally with `DRAW01_PHASE4_BUDGETS_PASS=true`, `DRAW01_MACOS_PERF_THRESHOLD_PASS=unfrozen`, and `DRAW01_REAL_NUI_PERF_ALL_PASS=unfrozen`.
- Preserved smoke suites passed:
  - `DRAW01_ALL_PASS=true`
  - `STRUCT01_ALL_PASS=true`
  - `DCFG01_DRAWER_LIFECYCLE_ALL_PASS=true`
  - `DCFG01_COORDINATION_ALL_PASS=true`
  - `DCFG02_WIZARD_ALL_PASS=true`
  - `DCFG02_FILESOURCE_ALL_PASS=true`
  - `NOTES01_ALL_PASS=true`
- Preserved LSP semantic checks passed:
  - `check_lsp_alias_completion.lua`
  - `check_lsp_schema_alias_completion.lua`
  - `check_lsp_alias_rebinding.lua`

## Self-Check: PASSED

Phase 10 now provides macOS/Linux advisory CI wiring, local `make perf-lsp`, deterministic real-LSP benchmark scenarios, sentinel-gated marker output, threshold candidate emission, and artifact generation. Thresholds remain advisory/unfrozen as planned.
