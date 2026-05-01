---
phase: 05-resilience-diagnostics
plan: 02
subsystem: diagnostics
tags: [diagnostics, adapters, editor, postgres, mysql, oracle, sqlite, headless-tests]

requires:
  - phase: 05-resilience-diagnostics
    provides: reconnect rewrite signal, note connection metadata, and start_line/start_col execution context
provides:
  - adapter diagnostics registry with parser-backed and fallback paths
  - connection-scoped diagnostic namespace lifecycle in EditorUI
  - start_line/start_col aware diagnostic anchoring for parser-backed adapters
  - reconnect-aware namespace pruning keyed by note ownership and connection rewrite signals
  - headless diagnostics and editor regression coverage
affects: [05-resilience-diagnostics]

tech-stack:
  added: []
  patterns:
    - "Adapter registry with O(1) alias lookup and explicit nil-parser fallback semantics"
    - "Connection-scoped diagnostic namespaces with scheduled UI application"

key-files:
  created:
    - lua/dbee/ui/editor/diagnostics.lua
    - ci/headless/check_adapter_diagnostics.lua
  modified:
    - lua/dbee/doc.lua
    - lua/dbee/ui/editor/init.lua
    - .github/workflows/test.yml

key-decisions:
  - "D-25: Phase 5 diagnostics stop at normal editor-owned execution; Explain Plan keeps its pre-existing behavior"
  - "D-26: SQLite remains fallback-only at truthful 1:1 rather than claiming precise parser coverage"
  - "D-28: reconnect-driven note reassignment enters editor state only through the additive UI bridge from 05-01"
  - "D-29: diagnostics consume the rewritten connection identity contract from 05-01 without global scans or same-ID churn"

requirements-completed: [ADPT-02]

duration: 1 session
completed: 2026-04-24
---

# Phase 5 Plan 02: Adapter Diagnostics Summary

**ADPT-02 shipped a shared diagnostics framework for normal editor-owned SQL execution, with parser-backed precision where available, truthful fallback behavior elsewhere, and reconnect-aware namespace lifecycle management.**

## Performance

- **Completed:** 2026-04-24
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments

- Added `lua/dbee/ui/editor/diagnostics.lua` with a parser registry, reverse alias map, parser-backed builders for Postgres/MySQL/SQL Server/Oracle, and truthful SQL fallback builders for SQLite and other SQL adapters
- Added connection-scoped diagnostic namespace ownership to `EditorUI`, including lifecycle clears on rerun, success, note switch, note removal, explicit clear, and reconnect-driven connection rewrites
- Threaded `resolved_query`, `start_line`, and `start_col` through editor execution metadata so parser-backed diagnostics anchor mid-line and multi-line statements correctly
- Preserved non-SQL adapters as notify-only and kept Explain Plan out of the new generic framework per the locked Phase 5 scope
- Added `duckdb` alias coverage for the existing Duck adapter family and optimized Postgres `POSITION` translation to avoid byte-by-byte substring hot paths
- Deferred diagnostic application through `vim.schedule(...)` so error rendering and cursor-jump work leave the event path promptly

## Task Commits

1. **Task 1: adapter diagnostics framework and editor integration** - `d1a065f` (feat)
2. **Task 2: diagnostics headless coverage and CI wiring** - `8b4b8b7` (test)
3. **Impl-gate fix pass: diagnostics perf and alias/runtime tightening** - `1c2d1ba` (perf)

## Verification Results

- `ADPT02_ALL_PASS=true` with 9 pass markers in `ci/headless/check_adapter_diagnostics.lua`
- Covered Oracle parser path, Postgres `POSITION` translation, alias lookup, SQLite fallback, lifecycle clears, reconnect rewrite pruning, and duplicate listener/alias guards
- Editor regressions that touch the same runtime path also passed: `EDITOR_ERR_JUMP_OK=true`, `EDITOR_CALL_ROUTING_OK=true`, and `QUC_OK=1`

## Key Decisions Honored

- D-25 stayed intact: normal editor-owned execution gained shared diagnostics, while Explain Plan retained the existing special-case/non-framework behavior
- D-26 landed explicitly via fallback-only SQLite registration instead of invented line/column precision
- D-28 remained the reconnect/editor boundary: diagnostics react to rewrite signals and note rebinding, but do not own reconnect state
- D-29 contract consumption stayed scoped to connection rewrite events and note metadata, with no global scans and no same-ID rewrite churn

## Residuals

- No queued product residuals remain for ADPT-02
- The diagnostics registry is intentionally internal and non-plugin-extensible for v1.0; any future extension surface should be designed as new scope, not inferred from Phase 5

## Next Phase Readiness

- 05-02 is complete and verified
- Phase 5 and milestone v1.0 are ready for closure
