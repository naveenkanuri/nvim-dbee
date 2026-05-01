---
phase: 07-connection-only-drawer
plan: 02
subsystem: drawer
tags: [drawer, connections, actions, lifecycle, ui]

requires:
  - phase: 07-connection-only-drawer
    provides: lifecycle invalidation events and bootstrap snapshot helper
provides:
  - connection-only drawer root with connection-first mappings
  - non-mutating connection test surface on key `t`
  - explicit drawer dispatcher ownership and secondary source-file edit reachability
affects: [07-03, 07-04]

tech-stack:
  added:
    - "DbeeConnectionTest(conn_id)"
  patterns:
    - "Connection-only drawer root with source metadata suffixes"
    - "Explicit `close_only` vs `refresh_after_action` drawer dispatcher modes"
    - "Secondary source-file editing from connection-row context without reviving source rows"

key-files:
  created: []
  modified:
    - dbee/endpoints.go
    - dbee/handler/handler.go
    - lua/dbee/api/__register.lua
    - lua/dbee/handler/init.lua
    - lua/dbee/ui/drawer/convert.lua
    - lua/dbee/ui/drawer/model.lua
    - lua/dbee/ui/drawer/init.lua
    - lua/dbee/config.lua
    - lua/dbee/doc.lua

key-decisions:
  - "D-65/D-67: the drawer root is saved-connections only, with the locked connection-first mapping set"
  - "D-66/D-68: source-file editing stays reachable from a connection row, but only through a secondary action surface"
  - "D-69/D-74/D-75: authoritative lifecycle actions fail closed, rerender from `connection_invalidated`, and `current_connection_changed` stays presentation-only"

requirements-completed: [DCFG-01]

duration: 1 session
completed: 2026-04-28
---

# Phase 7 Plan 02: Connection-Only Drawer Summary

**The drawer is now a connection-management surface: flat connection root, connection-first CRUD/test/activate actions, and explicit rerender ownership for authoritative lifecycle changes.**

## Performance

- **Started:** 2026-04-28T12:03:43-05:00
- **Completed:** 2026-04-28T12:12:22-05:00
- **Tasks:** 2
- **Files modified:** 9

## Accomplishments

- Added the locked D-82 non-mutating `DbeeConnectionTest(conn_id)` RPC surface and Lua wrapper, then regenerated `lua/dbee/api/__register.lua`.
- Flattened the drawer root to saved connections only, preserving Phase 6 subtree expansion beneath each connection and decorating rows with source metadata.
- Reworked drawer action handling around explicit dispatcher modes so add/edit/delete/source-reload flows rely on authoritative `connection_invalidated` rerenders while pure UI actions stay local.
- Made `current_connection_changed` presentation-only inside DrawerUI and kept secondary source-file editing reachable through `e` on a connection row plus help text.

## Task Commits

1. **Task 07-02-01: Add the connection-only root, source metadata decoration, and non-mutating test action surface** - `9a24dbf` (feat)
2. **Task 07-02-02: Make drawer actions connection-first and rerender ownership explicit** - `1a9bd36` (feat)

## Verification Results

- `07-02-01` verify block passed on 2026-04-28: `DbeeConnectionTest` is present in Go, Lua, docs, and regenerated manifest output; the manifest diff stayed clean after `cd dbee && GOCACHE=/tmp/go-build go run . -manifest ../lua/dbee/api/__register.lua`.
- `07-02-01` mapping and render-model greps passed for the connection-only root, `source_meta`, and the locked Phase 7 keyset in `lua/dbee/config.lua`.
- `07-02-02` verify block passed on 2026-04-28: `close_only`, `refresh_after_action`, presentation-only `on_current_connection_changed`, `Select a source`, and the secondary `source file` path are present in the drawer code/help surface.
- Syntax checks passed with `luac -p lua/dbee/ui/drawer/init.lua`, `luac -p lua/dbee/ui/drawer/convert.lua`, and `luac -p lua/dbee/doc.lua`.

## Decisions Made

- Source lookup for connection-row actions stays local to DrawerUI by scanning `handler:get_sources()` plus `handler:source_get_connections()`, which avoids widening the render model beyond what D-65 requires.
- Connection activation now relies on the existing `current_connection_changed` event for visual updates instead of forcing drawer refreshes from the action callback.
- Secondary source-file editing is documented in the drawer help node instead of reviving source rows or introducing a new primary mapping.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

- The repository Go build cache path is not writable inside this sandbox, so manifest generation continues to use `GOCACHE=/tmp/go-build` for deterministic Phase 7 RPC verification.

## User Setup Required

None - no external setup is required for the new drawer actions.

## Next Phase Readiness

- `07-03` can now build on a connection-only drawer with authoritative invalidation listeners already in place.
- The remaining coordination work is isolated to handler/LSP/reconnect/bootstrap ownership and does not need to reopen drawer UX contracts from `07-02`.

---
*Phase: 07-connection-only-drawer*
*Completed: 2026-04-28*
