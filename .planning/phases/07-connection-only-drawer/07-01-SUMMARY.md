---
phase: 07-connection-only-drawer
plan: 01
subsystem: lifecycle
tags: [drawer, handler, lifecycle, invalidation, bootstrap]

requires:
  - phase: 06-structure-laziness-notes-picker
    provides: drawer-owned structure substrate and nearest-ancestor reload targeting
provides:
  - additive `connection_invalidated` and `source_reload_failed` handler events
  - internal `_source_reload_silent(...)` bookkeeping path for later reconnect coordination
  - authoritative bootstrap snapshot helper with `snapshot_authoritative_epoch`
affects: [07-02, 07-03, 07-04]

tech-stack:
  added: []
  patterns:
    - "Silent handler reload helper with eventful public wrapper choreography"
    - "Handler-owned per-connection `authoritative_root_epoch` for lifecycle invalidations"
    - "Side-effect-free bootstrap snapshot packaging for drawer/LSP consumers"

key-files:
  created: []
  modified:
    - lua/dbee/handler/init.lua
    - lua/dbee/doc.lua

key-decisions:
  - "D-71/D-72: lifecycle invalidation moved onto explicit handler events and silent reload bookkeeping"
  - "D-73/D-83: user-driven failures emit public failure events, with partial failures emitting invalidation first and failure second"
  - "D-79: bootstrap consumers get an authoritative snapshot instead of depending on missed-event replay"

requirements-completed: [DCFG-01]

duration: 1 session
completed: 2026-04-28
---

# Phase 7 Plan 01: Lifecycle Foundation Summary

**Connection lifecycle now has explicit handler-owned invalidation and failure events, plus a side-effect-free bootstrap snapshot for later drawer/LSP coordination.**

## Performance

- **Started:** 2026-04-28T16:47:58Z
- **Completed:** 2026-04-28T16:56:35Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments

- Added `_source_reload_silent(...)` so reconnect and later coordination work can reuse raw source reload bookkeeping without leaking public lifecycle events.
- Refactored public source reload/add/update/delete wrappers to emit canonical `connection_invalidated` and `source_reload_failed` payloads with D-83 partial-failure ordering.
- Added `get_connection_state_snapshot()` and the matching doc types so bootstrap consumers can reconcile sources, connections, current selection, and authoritative epochs from handler state.

## Task Commits

1. **Task 07-01-01: Split silent reload from public lifecycle emit and add the canonical invalidation events** - `7cd64d5` (feat)
2. **Task 07-01-02: Add authoritative bootstrap snapshot helpers for drawer and LSP consumers** - `f495d7e` (feat)

## Verification Results

- `07-01-01` verify block passed on 2026-04-28: lifecycle surface grep checks were green in `lua/dbee/handler/init.lua` and `lua/dbee/doc.lua`, and `lua/dbee/handler/__events.lua` remained the shared listener seam.
- `07-01-01` syntax checks passed with `luac -p lua/dbee/handler/init.lua` and `luac -p lua/dbee/doc.lua`.
- `07-01-02` verify block passed on 2026-04-28: `get_connection_state_snapshot`, `get_sources`, `source_get_connections`, `get_current_connection`, and `snapshot_authoritative_epoch` are present in the handler/docs.
- `07-01-02` syntax checks remained green after the snapshot helper landed.

## Decisions Made

- Initial source registration stays silent so freshly loaded connections begin at `authoritative_root_epoch = 0` instead of looking like a prior invalidation already happened.
- Eventful source reload/add/update/delete flows still raise errors to preserve existing call-site behavior, but they now emit canonical lifecycle payloads before surfacing the failure.
- Snapshot packaging stays internal to the handler layer for now; later drawer and LSP work can consume it directly without widening the public core API yet.

## Deviations from Plan

None - plan executed as written.

## Issues Encountered

- The first implementation pass mixed both Wave 1 tasks into one uncommitted delta. That was split back into task-sized commits before the first commit so execution history stayed aligned with the approved plan.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- `07-01` now exposes the lifecycle and bootstrap surfaces that `07-02` and `07-03` were planned against.
- The drawer rewrite can start without inventing new invalidation channels or bootstrap helpers.

---
*Phase: 07-connection-only-drawer*
*Completed: 2026-04-28*
