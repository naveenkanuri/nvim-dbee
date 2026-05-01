---
phase: 08-type-aware-connection-wizard
plan: 03
subsystem: ui
tags: [wizard, drawer, rpc, lifecycle]

requires:
  - phase: 08-type-aware-connection-wizard
    provides: compound wizard UI and FileSource raw-record persistence helpers
provides:
  - additive transient-spec ping RPC for unsaved connection specs
  - wizard-backed drawer add/edit routing across primary and searchable edit seams
  - shared submit dispatcher with FileSource metadata gating and nil-current preservation
affects: [08-04]

tech-stack:
  added: []
  patterns:
    - "Transient spec ping mirrors persisted connection test without mutating handler state"
    - "All add/edit save paths route through one wizard submit dispatcher"
    - "Nil-current preservation is resolved inside the reload seam before D-71/D-83 payload emission"

key-files:
  created: []
  modified:
    - dbee/endpoints.go
    - dbee/handler/handler.go
    - dbee/handler/handler_connection_test.go
    - lua/dbee/api/__register.lua
    - lua/dbee/api/core.lua
    - lua/dbee/handler/init.lua
    - lua/dbee/ui/drawer/convert.lua
    - lua/dbee/ui/drawer/init.lua
    - lua/dbee/ui/connection_wizard/init.lua
    - lua/dbee/doc.lua

key-decisions:
  - "D-94: transient-spec ping is a sibling RPC that reuses the connection-test error contract without touching persisted state"
  - "D-89/D-97/D-101: only FileSource-backed scoped modes persist wizard metadata; raw compatibility updates physically remove stale metadata through `__remove_keys`"
  - "D-96: nil-current preservation happens inside `_source_reload_silent()` before `current_conn_id_after` is frozen into Phase 7 invalidation payloads"

requirements-completed: [DCFG-02]

duration: 1 session
completed: 2026-04-28
---

# Phase 8 Plan 03: Wizard Integration Summary

**Phase 8 now routes every drawer add/edit save through the type-aware wizard, pre-save pings unsaved specs, and preserves Phase 7 lifecycle guarantees during save and partial failure.**

## Performance

- **Completed:** 2026-04-28
- **Tasks:** 2
- **Files modified:** 10

## Accomplishments

- Added `DbeeConnectionTestSpec` plus Lua wrappers so unsaved connection specs can be pinged with the same actionable error shape as Phase 7’s persisted `connection_test(conn_id)` path.
- Replaced the old prompt-based drawer add/edit save flow with a wizard-backed dispatcher in both the primary drawer actions and searchable/filter row actions.
- Kept Phase 7 lifecycle ownership intact by persisting wizard metadata only for FileSource scoped modes, stripping stale metadata on raw compatibility updates, and clearing wizard-driven auto-selection inside `_source_reload_silent()` before invalidation payloads are emitted.

## Task Commits

1. **Task 08-03-01: Add additive transient-spec ping and Go-side proof** - `29811b7` (feat)
2. **Task 08-03-02: Wire drawer add/edit seams through the wizard with metadata-first seeds and fail-closed save gating** - `2321ef0` (feat)

## Verification Results

- `08-03-01` verify block passed on 2026-04-28: `DbeeConnectionTestSpec`, `ConnectionTestSpec`, and `connection_test_spec` exist across Go, manifest, Lua API, handler wrapper, and docs; `cd dbee && GOCACHE=/tmp/nvim-dbee-gocache go run . -manifest ../lua/dbee/api/__register.lua && git diff --exit-code -- ../lua/dbee/api/__register.lua && GOCACHE=/tmp/nvim-dbee-gocache go test ./handler -run 'TestConnectionTest'` passed.
- `08-03-02` structural verify block passed on 2026-04-28: `submit_connection_wizard`, `source_get_connection_record`, `connection_wizard`, `__remove_keys`, and `_source_reload_silent` are explicit in the drawer and handler integration files.
- Stubbed headless smokes passed for the shared submit dispatcher and wizard submit contract: scoped FileSource updates persist `wizard`, raw FileSource updates send `__remove_keys = { "wizard" }`, ping failure blocks save without mutation, wizard submit stays open on returned errors, and `require('dbee.ui.drawer')` loads with minimal UI stubs after the integration changes.

## Decisions Made

- Drawer add/edit seed building stays metadata-first but never depends on runtime `ConnectionParams` widening; raw records remain source-local and optional.
- Wizard submission errors are surfaced back into the wizard surface itself rather than only logging and closing the modal, which keeps save failures fail-closed and actionable.

## Deviations from Plan

None - plan executed as written.

## Issues Encountered

- The repo sandbox blocks writes to the default Go build cache, so manifest regeneration and focused Go tests were run with `GOCACHE=/tmp/nvim-dbee-gocache`.

## User Setup Required

None.

## Next Phase Readiness

- `08-04` can now exercise real drawer add/edit flows, ping gating, raw metadata deletion, nil-current preservation, and searchable edit consistency through headless tests instead of structural checks alone.

---
*Phase: 08-type-aware-connection-wizard*
*Completed: 2026-04-28*
