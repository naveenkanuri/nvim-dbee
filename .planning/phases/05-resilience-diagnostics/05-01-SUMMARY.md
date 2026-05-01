---
phase: 05-resilience-diagnostics
plan: 01
subsystem: reconnect
tags: [reconnect, retry, oracle, registry, diagnostics, headless-tests]

requires:
  - phase: 03-editor-result-actions
    provides: explain_plan public API and Oracle two-step execution pattern
provides:
  - per-connection reconnect episode manager with bounded retry registry
  - `call_state_changed` payload enrichment with `conn_id`, `timestamp_us`, and `error_kind`
  - replay registration across all six user-facing SQL execute sites
  - connection-identity rewrite + note rebinding through `api.ui.rebind_note_connection()`
  - headless coverage for debounce, retry replacement, callback replay, and source-reload remaps
affects: [05-resilience-diagnostics]

tech-stack:
  added: []
  patterns:
    - "Scoped reconnect registry keyed by call_id plus per-connection index"
    - "Opaque retry callback for multi-step flows that are not truthfully replayable as flat SQL"

key-files:
  created:
    - lua/dbee/reconnect.lua
    - ci/headless/check_auto_reconnect.lua
  modified:
    - dbee/handler/handler.go
    - dbee/handler/event_bus.go
    - lua/dbee/api/ui.lua
    - lua/dbee/doc.lua
    - lua/dbee.lua
    - lua/dbee/ui/editor/init.lua
    - lua/dbee/ui/result/init.lua
    - lua/dbee/utils.lua

key-decisions:
  - "D-23: all six required user-facing SQL execute sites register reconnect metadata via reconnect.register_call()"
  - "D-24: Oracle Explain retries through an opaque module-scope callback that recreates the two-step choreography without stale captured state"
  - "D-28: reconnect-to-editor note reassignment crosses modules only through api.ui.rebind_note_connection(), and synthetic Oracle step-2 legacy replay aborts via the locked DBMS_XPLAN pattern"
  - "D-29: reconnect routing keys state by effective_conn_id and skips rewrite/signals entirely on same-ID reconnects"

requirements-completed: [CONN-01]

duration: 1 session
completed: 2026-04-24
---

# Phase 5 Plan 01: Auto-Reconnect Summary

**CONN-01 shipped with bounded reconnect episodes, registry-backed replay across all required execute sites, and headless coverage for reconnect edge cases and callback choreography.**

## Performance

- **Completed:** 2026-04-24
- **Tasks:** 2
- **Files modified:** 10

## Accomplishments

- Added `lua/dbee/reconnect.lua` as the Phase 5 reconnect manager with `calls_by_id`, `call_ids_by_conn`, `episodes`, `retired_by_retry`, and superseded-call tombstones to keep listener work scoped and bounded
- Enriched the Go `call_state_changed` event path so Lua reconnect logic receives `conn_id`, `timestamp_us`, and `error_kind` for prompt gating and reconnect routing
- Registered retry metadata across all six locked user-facing SQL execution sites: editor note execute, editor script execute, `dbee.execute`, `dbee.execute_script`, `dbee.compile_object`, and `dbee.explain_plan`
- Preserved Oracle Explain correctness with a module-scope `run_oracle_explain_on_connection()` helper plus opaque retry callbacks instead of replaying synthetic step-2 SQL directly
- Added connection-identity rewrite fan-out with safe note rebinding through `api.ui.rebind_note_connection()` and previous-current restoration after source reload remaps
- Locked legacy fallback behavior to truthful flat SQL only, warning and aborting on the synthetic `DBMS_XPLAN` step-2 shape

## Task Commits

1. **Task 1: reconnect registry, replay wiring, and public wrappers** - `a233f01` (feat)
2. **Task 2: headless auto-reconnect coverage** - `06cdb6d` (test)
3. **Impl-gate fix pass: episode lifecycle hardening, remap restore, tombstones** - `76852ff` (fix)
4. **Impl-gate fix pass: Lua event payload escaping for reconnect gating** - `c7b8ab3` (fix)

## Verification Results

- `CONN01_ALL_PASS=true` with 17 pass markers in `ci/headless/check_auto_reconnect.lua`
- Covered deep-copy of mutable binds, same-ID fast path, effective-conn routing, Oracle callback replay, retry re-registration, synthetic fallback abort, bounded registry behavior, manual reconnect reset, archived-success reset, previous-current remap restore, and superseded tombstones
- Phase-adjacent editor/query regression checks also passed after the fix pass: `EDITOR_CALL_ROUTING_OK=true` and `QUC_OK=1`

## Key Decisions Honored

- D-23 replay coverage stayed locked to the six user-facing SQL execution sites instead of broadening reconnect registration to unrelated wrappers
- D-24 opaque callback support remained the mechanism for Oracle Explain; retry closures capture immutable replay inputs only
- D-28 bridge ownership stayed intact: reconnect never touches `EditorUI` directly, and legacy synthetic Oracle step-2 replay is explicitly blocked
- D-29 effective-connection routing and same-ID fast path both landed, preventing dead-ID episode recreation and spurious rewrite signals

## Residuals

- No product blockers remain for CONN-01
- Full Docker-backed Go integration coverage remains environment-dependent on local container image availability and certificate trust; this is test infrastructure, not shipped reconnect behavior

## Next Phase Readiness

- 05-01 is complete and verified
- Phase 5 is ready to close with 05-02 and milestone v1.0 completion

