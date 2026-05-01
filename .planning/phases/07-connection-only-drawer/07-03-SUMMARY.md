---
phase: 07-connection-only-drawer
plan: 03
subsystem: coordination
tags: [handler, drawer, lsp, reconnect, bootstrap, singleflight]

requires:
  - phase: 07-connection-only-drawer
    provides: connection-only drawer surface and lifecycle invalidation events
provides:
  - handler-owned authoritative root single-flight and bootstrap replay coordination
  - visibility-aware invalidation batching with sticky logical-connection retention
  - reconnect-visible subtree continuity and async database-switch placeholder patching
affects: [07-04]

tech-stack:
  added:
    - "DbeeConnectionListDatabasesAsync(conn_id, request_id, root_epoch)"
  patterns:
    - "Handler-owned authoritative_root_epoch with waiter fanout"
    - "Bootstrap replay buffers with atomic promote-to-live handoff"
    - "Same-epoch reconnect rewrite with conn_id/token migration"

key-files:
  created: []
  modified:
    - dbee/endpoints.go
    - dbee/handler/event_bus.go
    - dbee/handler/handler.go
    - lua/dbee/api/__register.lua
    - lua/dbee/doc.lua
    - lua/dbee/handler/init.lua
    - lua/dbee/lsp/init.lua
    - lua/dbee/reconnect.lua
    - lua/dbee/ui/drawer/init.lua

key-decisions:
  - "D-77/D-84/D-85: handler owns authoritative epochs, same-key single-flight, bootstrap buffering, overflow recovery, and tail-safe promotion"
  - "D-78/D-76: invalidation bursts batch by visibility and sticky selection never auto-promotes an unrelated survivor"
  - "D-80/D-81/D-86/D-88: reconnect rewrites stay same-epoch, migrate warm root continuity, and async database-switch completions are fenced by conn_id/request_id/root_epoch"

requirements-completed: [DCFG-01]

duration: 1 session
completed: 2026-04-28
---

# Phase 7 Plan 03: Coordination Summary

**Drawer, handler, reconnect, and LSP now share one lifecycle coordination layer instead of racing independent root warmups and redraws.**

## Performance

- **Started:** 2026-04-28T13:03:23-0500
- **Completed:** 2026-04-28T13:03:23-0500
- **Tasks:** 3
- **Files modified:** 9

## Accomplishments

- Finished handler-owned `authoritative_root_epoch`, root single-flight fanout, consumer bootstrap replay buffers, overflow recovery, and atomic `promote_to_live()` tail handoff.
- Landed visibility-aware invalidation batching and fixed sticky selection so ambiguous reloads warn instead of drifting to the first recreated survivor.
- Replaced synchronous `database_switch` expansion with an async placeholder-and-patch path, including stale completion fencing and reconnect-aware conn_id/token migration.
- Preserved same-epoch reconnect rewrite semantics by migrating both in-flight structure requests and handler authoritative epochs to the rewritten `conn_id`.

## Task Commits

1. **Task 07-03-01: Add handler-owned root single-flight and snapshot-backed drawer/LSP bootstrap coordination** - `4759586` (feat)
2. **Task 07-03-02: Implement visibility-aware invalidation backpressure and sticky logical-connection retention** - `c338640` (feat)
3. **Task 07-03-03: Add reconnect-visible subtree continuity and async `database_switch` placeholder patching** - uncommitted in this sandbox (`.git` is not writable, so a task commit could not be created here)

## Verification Results

- `luac -p` passed for `lua/dbee/handler/init.lua`, `lua/dbee/reconnect.lua`, `lua/dbee/ui/drawer/init.lua`, and `lua/dbee/doc.lua`.
- `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_connection_coordination.lua"` passed with the full coordination marker set:
  `DCFG01_SINGLE_FLIGHT_OK=true`, `DCFG01_WAITER_FANOUT_OK=true`, `DCFG01_BOOTSTRAP_REPLAY_OK=true`, `LIFECYCLE01_BOOTSTRAP_POST_SNAPSHOT_OK=true`, `LIFECYCLE01_BOOTSTRAP_TAIL_OK=true`, `LIFECYCLE01_BOOTSTRAP_OVERFLOW_OK=true`, `LIFECYCLE01_BOOTSTRAP_OVERFLOW_STORM_OK=true`, `DCFG01_SUPERSEDED_FLIGHT_OK=true`, `DCFG01_WAITER_CLEANUP_OK=true`, `DCFG01_BACKPRESSURE_OK=true`, `DCFG01_STICKY_SELECTION_OK=true`, `DCFG01_RECONNECT_CONTINUITY_OK=true`, `DCFG01_DATABASE_SWITCH_ASYNC_OK=true`, `DCFG01_DATABASE_SWITCH_STALE_DROP_OK=true`, `DCFG01_PHASE6_STRUCTURE_REGRESSION_OK=true`, and `DCFG01_COORDINATION_ALL_PASS=true`.
- `cd dbee && GOCACHE=/tmp/go-build go run . -manifest ../lua/dbee/api/__register.lua` regenerated the manifest successfully, and a before/after `cmp` proved the regenerated `lua/dbee/api/__register.lua` is stable relative to the current worktree state.
- `cd dbee && GOCACHE=/tmp/go-build go test $(GOCACHE=/tmp/go-build go list ./... | grep -v /tests/) -v` passed for Go unit packages.

## Decisions Made

- `Handler:CreateConnection(...)` now auto-selects only on initial startup, not while a reload is rebuilding connections, so sticky-selection ownership stays in the Lua handler instead of leaking through low-level create side effects.
- `migrate_structure_flights(old_conn_id, new_conn_id)` now migrates the authoritative epoch alongside in-flight requests, which keeps D-86 same-epoch reconnect rewrites coherent for both drawer and LSP consumers.
- `database_switch` placeholder invalidation stays in drawer-owned state; authoritative invalidators clear or migrate the pending token before stale async completions arrive.

## Deviations from Plan

None on behavior. The only execution deviation is operational: task `07-03-03` is implemented and verified in the worktree but could not be committed from this sandbox because `.git` is not writable.

## Issues Encountered

- The first coordination harness pass had a false negative in the overflow assertions because multiple bootstrap consumers were appending into the same reused listener table. The suite was corrected to isolate consumer listeners before re-running the D-85 checks.
- The sandbox cannot create `.git/index.lock`, so atomic task commits and a literal `git diff --exit-code` clean state for regenerated files could not be produced here.

## User Setup Required

None for automated coverage. Real-adapter manual validation for reconnect continuity and async `database_switch` truthfulness remains listed in `07-VALIDATION.md`.

## Next Phase Readiness

- `07-04` can now validate the full coordination surface through real DrawerUI and handler paths without inventing new seams.
- Phase 7’s remaining work is test/CI packaging plus summary/reporting, not further lifecycle design.

---
*Phase: 07-connection-only-drawer*
*Completed: 2026-04-28*
