---
phase: 07
slug: connection-only-drawer
status: draft
created: 2026-04-28
---

# Phase 07 — Research

> Focused research for `DCFG-01`: connection-only drawer UX plus the lifecycle ownership Phase 6 intentionally deferred.

## Research Questions

1. What live seams still couple drawer, handler, reconnect, and LSP after Phase 6?
2. Which parts belong in a handler/lifecycle foundation plan versus the drawer rewrite plan?
3. Where do the remaining sync stalls and duplicate root warmups actually come from?

## Evidence Read

- `.planning/phases/07-connection-only-drawer/07-CONTEXT.md`
- `.planning/ROADMAP.md`
- `.planning/REQUIREMENTS.md`
- `.planning/phases/04-drawer-navigation/04-CONTEXT.md`
- `.planning/phases/05-resilience-diagnostics/05-CONTEXT.md`
- `.planning/phases/06-structure-laziness-notes-picker/06-CONTEXT.md`
- `lua/dbee/handler/init.lua`
- `lua/dbee/handler/__events.lua`
- `dbee/handler/event_bus.go`
- `lua/dbee/ui/drawer/init.lua`
- `lua/dbee/ui/drawer/convert.lua`
- `lua/dbee/ui/drawer/model.lua`
- `lua/dbee/lsp/init.lua`
- `lua/dbee/reconnect.lua`
- `lua/dbee/config.lua`
- `lua/dbee.lua`
- `ci/headless/check_structure_lazy.lua`

## Current-State Findings

### 1. The drawer root is still source-first and note-bearing

- `lua/dbee/ui/drawer/convert.lua` still renders source rows, add-connection rows, edit-source rows, and connection rows under each source.
- `lua/dbee/ui/drawer/init.lua` still prepends editor/note nodes into the main drawer tree.
- The existing root shape therefore conflicts directly with D-65 and D-66.

Conclusion:

- Phase 7 has to rewrite the primary drawer model, not merely remap keys.

### 2. Drawer rerender ownership is still callback-driven

- `perform_action()` in `lua/dbee/ui/drawer/init.lua` still invokes `refresh_filter_safe(...)` after node actions.
- `on_current_connection_changed()` still behaves like an authoritative redraw path rather than a presentation-only update.
- This is exactly the contract D-74 and D-75 now centralize.

Conclusion:

- Phase 7 needs an explicit dispatcher split and a drawer-local carve-out for presentation-only refresh.

### 3. Source lifecycle wrappers do not expose a canonical invalidation surface yet

- `Handler:source_reload()`, `source_add_connection()`, `source_remove_connection()`, and `source_update_connection()` in `lua/dbee/handler/init.lua` directly mutate source/connection state and return.
- There is no `connection_invalidated` or `source_reload_failed` event today.
- Lua already has a shared listener bus in `lua/dbee/handler/__events.lua`, so the new lifecycle events can stay additive without inventing a second bus.

Conclusion:

- Phase 7 can add the canonical lifecycle event surface in Lua handler land first; it does not need to repurpose existing Go events.

### 4. LSP still warms roots independently

- `lua/dbee/lsp/init.lua` calls `handler:connection_get_structure_async(conn.id)` directly on startup and refresh.
- LSP still maintains its own async-request bookkeeping and metadata fallback schedule.
- Drawer-owned `caller_token` and `root_epoch` fencing from Phase 6 intentionally do not coordinate LSP.

Conclusion:

- Single-flight ownership has to sit above both consumers, in handler-facing coordination logic, not in DrawerUI alone.

### 5. Reconnect rewrite continuity exists locally but is not part of drawer lifecycle yet

- `lua/dbee/reconnect.lua` already maintains rewrite metadata and emits local `connection_rewritten(old_conn_id, new_conn_id)` callbacks.
- The drawer does not consume that surface.
- Phase 5 D-29 already gives the baseline identity-rewrite contract; Phase 7 now owns the visible drawer continuity on top of it.

Conclusion:

- Reconnect continuity can be implemented as an additive bridge from the existing reconnect module into the new canonical invalidation and subtree patch path.

### 6. `database_switch` is still the last unowned synchronous expand seam

- `connection_list_databases()` is still synchronous in `lua/dbee/handler/init.lua`.
- Both `lua/dbee/ui/drawer/convert.lua` and the Phase 6 drawer patch path still build the `database_switch` row synchronously.
- Phase 6 intentionally documented that seam rather than claiming it away.

Conclusion:

- Phase 7 needs a dedicated async list-databases path with placeholder-and-patch semantics, separate from Phase 6 async columns.

### 7. Phase 6 already provides the right drawer substrate

- `_struct_cache`, root fencing, branch async loading, `Load more...`, D-63 nearest-ancestor reload, and filter snapshot restore are already live and locked.
- `build_tree_from_struct_cache(...)` is already the canonical rebuild path.
- Existing headless suites (`check_structure_lazy.lua`, `check_drawer_filter.lua`, `check_notes_picker.lua`) already show how to drive real DrawerUI refresh/expand behavior without bypass stubs.

Conclusion:

- Phase 7 should add lifecycle ownership and drawer root/interaction changes on top of the Phase 6 substrate, not replace it.

## Recommended Plan Split

### 07-01 — Handler/Event Lifecycle Foundation

Scope:

- `connection_invalidated`
- `source_reload_failed`
- `_source_reload_silent`
- structured invalidation payload shaping
- authoritative snapshot bootstrap helper

Why first:

- Drawer, reconnect, and LSP all need the same lifecycle surface before their behavior can be cleaned up.

### 07-02 — Drawer UX Rewrite

Scope:

- connection-only root
- source metadata badges/suffixes
- secondary source-file editing path
- mapping rewrite
- connection-first action targeting
- `perform_action` close-only vs refresh-after-action
- presentation-only drawer handling for `current_connection_changed`
- non-mutating connection test action

Why second:

- This is the user-visible drawer contract, but it depends on 07-01 to avoid hard-coding invalidation behavior into callbacks again.

### 07-03 — Cross-Module Coordination

Scope:

- handler-owned root single-flight
- visibility-aware invalidation backpressure
- sticky logical-connection retention
- reconnect-visible continuity
- async `database_switch`
- drawer/LSP bootstrap and rewarm coordination

Why third:

- These changes span handler, drawer, reconnect, and LSP simultaneously and are easier to land after the drawer surface is already connection-only.

### 07-04 — Headless Coverage And CI

Scope:

- lifecycle headless suite
- connection-only drawer headless suite
- coordination/reconnect/database-switch headless suite
- workflow wiring
- regression guards for Phase 6 suites

Why separate:

- It keeps the behavioral proofs centralized and avoids hiding major coverage work inside implementation plans.

## Key Research Recommendations

### R1. Keep lifecycle invalidation additive and Lua-owned where the mutations already live

- Use `lua/dbee/handler/__events.lua` for the new public lifecycle events.
- Keep existing Go event payloads unchanged; add new events instead of overloading `current_connection_changed` or `structure_loaded`.

### R2. Introduce a minimal additive connection-test API

- Live code has no clean test/ping path for drawer key `t`.
- The cleanest Phase 7 path is an additive handler/core helper that validates a target connection without changing current selection or source state.
- That keeps D-69 honest and avoids temporary-current-connection hacks.

### R3. Keep single-flight above both consumers

- Drawer and LSP both already request roots.
- Consumer-to-consumer piggybacking would entangle modules that D-77 explicitly wants coordinated through handler-owned logic.

### R4. Keep reconnect-visible continuity shallow

- D-80 only requires root continuity plus targeted visible subtree patching.
- Branch-local lazy children are disposable unless their validity is explicit.
- Reusing Phase 6 `_struct_cache` root continuity without trying to migrate all branch state is the lower-risk path.

### R5. Treat `database_switch` like async columns, not like a special one-off

- Placeholder first.
- Patch the targeted subtree later.
- If an adapter still cannot behave truthfully asynchronously, record the residual stall in validation instead of masking it with misleading UX.

## Risks And Mitigations

| Risk | Why it matters | Mitigation |
|---|---|---|
| Reintroducing callback-owned rerenders | Would undo the point of D-74/D-75 | Put dispatcher ownership in 07-02 and prove it in 07-04 |
| Root-load duplication still leaking through LSP | Can waste work and create stale overwrite windows | Centralize waiters and fanout in 07-03 |
| Reconnect continuity over-migrates stale branch state | Easy to get wrong after ID rewrite | Keep only root continuity and visible subtree patching |
| Async `database_switch` claims too much | Phase 6 already documented the residual seam | Require measured validation caveat when adapter behavior still stalls |

## Research Conclusion

Phase 7 is ready for planning as four sequential plans:

1. lifecycle foundation
2. drawer rewrite
3. cross-module coordination
4. headless/CI proof

That split follows the actual code seams, honors the locked D-64..D-81 decisions, and keeps Phase 6’s shipped drawer substrate intact.
