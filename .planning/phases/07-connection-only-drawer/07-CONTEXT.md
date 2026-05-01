# Phase 7: Connection-Only Drawer - Context

**Gathered:** 2026-04-28
**Status:** Locked — ready for planning

<domain>
## Phase Boundary

Phase 7 turns the drawer into a connection-management surface and absorbs the cross-module lifecycle ownership that Phase 6 intentionally deferred. It removes note discovery and source utility rows from the primary tree, keeps the shipped Phase 6 structure contract intact (`_struct_cache`, drawer-owned `caller_token` + `root_epoch`, async table/view child fetch, bounded `Load more...`, nearest-ancestor `R`), and defines the canonical rules shared by drawer, handler, reconnect, and LSP for invalidation, selection, rerendering, and reconnect continuity.

In scope:
- Connection-only drawer root and mapping rewrite for add, edit, delete, test, activate, reload, expand/collapse, and filter
- Handler/event-bus ownership for `connection_invalidated`, `source_reload_failed`, and source lifecycle choreography
- Canonical ownership for `current_connection_changed`, source-action rerendering, reload/current-selection behavior, and reconnect-visible continuity
- Drawer/LSP full-tree root coordination, invalidation backpressure, startup bootstrap safety, and the remaining `connection_list_databases()` expand seam

Out of scope:
- Phase 8 `DCFG-02` type-aware connection wizard, URL round-tripping, driver ping, and FileSource persistence hardening
- Phase 9 `PERF-01` real-`nui.nvim` drawer performance harness
- Reopening Phase 4 D-31 filter exit behavior or Phase 6 D-30..D-63 structure contracts
- Redesigning note ownership or moving note CRUD back into the drawer; notes stay on the Phase 6 `dbee.pick_notes()` path

</domain>

<decisions>
## Implementation Decisions

### Phase Shape
- **D-64:** Phase 7 is additive to Phase 6, not a rewrite of Phase 4/6 locks. It treats the shipped Phase 6 substrate as fixed and layers drawer/lifecycle ownership above it.
- **D-65:** The drawer root becomes a flat list of saved connections only. Note rows and source rows leave the primary tree entirely, but each connection row keeps source metadata for CRUD routing and may display a lightweight source badge or suffix for disambiguation.
- **D-66:** Source-file editing remains reachable after source rows are removed, but only through a secondary surface, not a primary tree node. That path stays connection-aware and outside the primary tree.

### Drawer Interaction Contract
- **D-67:** The required primary mapping set is fixed: `a` add, `e` edit, `dd` delete, `t` test, `<C-CR>` activate, `R` reload structure, `/` filter, and `<CR>` toggles expansion on expandable connection or structure rows using the shipped Phase 6 lazy-loading contract. Existing structure-only helpers such as `yy` or `gC` may remain only if they do not conflict with this core set.
- **D-68:** Connection-management keys are connection-first, not generic node actions. `a` targets a source: if the cursor is on a connection whose source supports create, preselect that source; otherwise show a picker of create-capable sources; if none exist, warn. `e`, `dd`, `t`, and `<C-CR>` operate only on connection rows. `R` keeps Phase 6 D-63 nearest-ancestor behavior, including `database_switch` rows.
- **D-69:** CRUD and test failures must surface immediately through `utils.log` / `vim.notify` with actionable text, and failed add/edit/delete/test flows must never replace the active connection or silently clear structure state. Phase 7 preserves the prior current connection and tree until authoritative invalidation succeeds.
- **D-70:** The drawer rewrite must stay layout-owned and 2-pane-friendly. Connection actions may call `focus_pane()` or `ensure_drawer_visible()` when they need the drawer visible, but they must not assume a 4-pane layout or add drawer-only state outside the existing layout API.
- **D-82:** Phase 7 owns a minimal non-mutating connection test RPC. `DbeeConnectionTest(conn_id)` is added on the Go side with `Handler:ConnectionTest(conn_id) error` and a Lua `connection_test(conn_id)` wrapper. The implementation opens the adapter connection, may run a trivial liveness probe such as `SELECT 1` or an equivalent driver-specific check, closes the connection, and returns `nil` on success or `{ error_kind, message }` on failure. Phase 7 keeps this wrapper synchronous; async migration is deferred to Phase 8 if profiling shows adapter stalls. Test action is strictly non-mutating: it does not alter source state, the active connection, `_struct_cache`, or persisted files, and it is surfaced only through D-67/D-68's connection-first `t` action.

### Handler And Invalidation Ownership
- **D-71:** `connection_invalidated` becomes the canonical handler/event-bus invalidation event. Its payload is split, not flat: `{ reason, source_id?, retired_conn_ids = {}, new_conn_ids = {}, current_conn_id_before?, current_conn_id_after?, silent? }`. Drawer and LSP both consume it at the handler listener seam; reconnect and public source wrappers do not invent parallel UI-only invalidation channels.
- **D-72:** Handler reload choreography splits into an internal silent path and public eventful wrappers. `_source_reload_silent(source_id, opts)` owns raw reload/replace bookkeeping and returns structured results; public source CRUD and reload wrappers emit `connection_invalidated` and `source_reload_failed` only after that helper finishes. Silent reload is reserved for reconnect or identity-rewrite flows and never becomes the public UI contract.
- **D-73:** `source_reload_failed` is a public handler/event-bus event for user-driven source lifecycle failures only. Silent reconnect flows may log internally, but they do not surface the public failure event unless the user explicitly initiated the source action.
- **D-83:** Public source CRUD wrappers (`source_add_connection`, `source_update_connection`, `source_remove_connection`) use explicit partial-failure lifecycle semantics. When the underlying mutation step succeeds but the subsequent `_source_reload_silent` step fails, the wrapper first emits `connection_invalidated` with the canonical D-71 payload reflecting the committed mutation, then emits `source_reload_failed` with the failure detail and the same `source_id`. The mutation is not rolled back: the file-layer change is already authoritative, the user keeps the change, and later manual `R` retries reload. If the mutation step itself fails, the wrapper emits only `source_reload_failed` and preserves the prior current connection and structure state per D-69.

### Refresh, Action, And Selection Contracts
- **D-74:** `perform_action()` splits into two explicit dispatcher modes: `close_only` and `refresh_after_action`. Any source or connection lifecycle mutation that leads to authoritative handler invalidation uses `close_only`; the invalidation listener owns the rerender. Pure UI actions that do not change authoritative connection state may still use `refresh_after_action` or direct targeted tree mutation.
- **D-75:** `current_connection_changed` becomes presentation-focused and cross-module-canonical: the event means "current logical connection changed," not "drop drawer structure cache." Drawer updates active-row presentation and current-connection affordances; LSP restarts or retargets completion state; neither consumer treats the event as a passive source-lifecycle invalidator.
- **D-76:** Reload and current-selection ownership follows a sticky logical-connection rule. Manual `R`, eventful source reload, silent reconnect reload, and database selection must preserve the same logical connection when Phase 5/handler mapping can resolve it; they must never auto-select an unrelated survivor just because it exists. If mapping fails or is ambiguous, the previous current connection remains if still valid; otherwise current selection clears with a user-facing warning.

### Root Coordination, Backpressure, And Bootstrap
- **D-77:** Drawer/LSP root coordination uses handler-owned single-flight, not ad hoc piggybacking in one consumer. The coalescing key is `(conn_id, authoritative_root_epoch)`; identical flights share the underlying fetch, but completion fans out per waiter so drawer keeps `caller_token = "drawer"` plus request/epoch fences and LSP keeps its legacy-compatible payload handling. A newer authoritative drawer invalidation starts a new flight rather than piggybacking a stale one.
- **D-78:** Invalidation backpressure is visibility-aware and coalesced. Bursts of source or reconnect invalidations collapse into one batch per source/reason on the next scheduled turn; drawer rerenders once per batch; survivor auto-refetch is limited to currently expanded or already-warm visible connections, while cold survivors stay lazy. LSP rewarms only the current connection.
- **D-79:** Startup invalidation safety uses authoritative snapshot bootstrap, not raw event replay. Consumers still subscribe to live events, but on mount they reconcile from handler state (`get_sources()`, `source_get_connections()`, `get_current_connection()`, and any additive connection-state metadata) and treat pre-listener invalidations as already absorbed by that snapshot.
- **D-84:** Phase 7 introduces handler-owned `authoritative_root_epoch[conn_id]` as the canonical epoch source shared by drawer and LSP. Handler increments `authoritative_root_epoch[conn_id]` on every eventful invalidation: manual `R`, `database_selected`, and eventful source CRUD or reload. Drawer no longer invents its own epoch source; instead, at the same pre-request-clear moment Phase 6 already owns, it mirrors the current handler epoch into `_struct_cache.root_epoch[conn_id]`. LSP-first and bootstrap loads use the handler-owned epoch as the single-flight key source, with `0` as the initial pre-invalidation value.
- **D-85:** Startup bootstrap follows strict subscribe-first ordering. Consumer registers its `connection_invalidated` listener with handler first, and handler buffers any invalidations delivered during bootstrap in a bounded per-listener replay buffer. Consumer then reads snapshot state from `get_sources()`, `source_get_connections()`, and `get_current_connection()`, with `snapshot_authoritative_epoch[conn_id]` included for every visible connection. The active bootstrap buffer remains appendable until replay drain finishes and the consumer atomically flips into live mode, so invalidations arriving after snapshot completion but before that flip still queue into the active bootstrap generation. Buffered invalidations are replayed only when their additive `authoritative_root_epoch` exceeds the snapshot epoch for that connection; older events are absorbed by the snapshot and dropped. Once replay drain finishes, the consumer enters live mode and the bootstrap buffer is destroyed. Handler keeps at most the last `64` buffered invalidations per consumer; overflow triggers a snapshot-resync warning and nested bootstrap recovery, where handler immediately allocates a fresh generation buffer, consumer re-runs bootstrap against that generation, there is no drop window across the handoff, and a defensive hard stop fires after `3` consecutive overflow recursions.
- **D-86:** Eventful and silent invalidations have different epoch behavior. Eventful invalidations bump `handler.authoritative_root_epoch[conn_id]`, supersede older same-connection flights, and mirror the new epoch into drawer-local `_struct_cache.root_epoch[conn_id]` at pre-request clear. Superseded waiters receive `{ error_kind = "superseded", new_epoch = N }` and do not auto-retry. Silent invalidations such as reconnect identity rewrite do not bump epoch; instead they migrate the old connection ID path through the Phase 5 D-29 and Phase 6 D-49 continuity path, preserve `silent = true` so consumers suppress avoidable UI churn, and keep same-epoch ordinary in-flight requests valid unless a newer eventful invalidation arrives.
- **D-87:** Handler-owned single-flight waiters have explicit cleanup states. On success, every waiter receives the success payload and the flight entry is dropped. On error, every waiter receives the error and the flight entry is dropped. On supersession, every waiter on the older flight receives `{ error_kind = "superseded", new_epoch = N }`, the older waiter list is dropped, and the new epoch starts its own flight. On consumer teardown, handler removes that consumer's waiter slot from any in-flight flights. Flights are not transport-cancelled; if the last waiter disappears, the background fetch may finish and its result is discarded.

### Reconnect Continuity And Expand Seam
- **D-80:** Drawer-visible reconnect continuity is explicit in Phase 7. When reconnect rewrites `old_conn_id -> new_conn_id`, the canonical path migrates root cache continuity per Phase 5 D-29 and Phase 6 D-49, rewrites targeted visible subtree identity, and patches the connection row in place without flashing a cold tree. Branch-local lazy children remain disposable unless they are proven still valid under the new ID.
- **D-81:** `connection_list_databases()` stops being an unowned synchronous expand seam. Phase 7 absorbs it through an additive async path with a placeholder-and-patch flow for the `database_switch` row so connection expansion stays consistent with the rest of the drawer rewrite. If an adapter cannot support meaningful async list-databases behavior, the residual stall must be measured and explicitly surfaced in validation rather than implied away.
- **D-88:** Async `database_switch` loading mirrors Phase 6 stale fencing. Drawer owns a per-placeholder pending token `{ conn_id, request_id, root_epoch }`, handler emits `connection_databases_loaded` with `{ conn_id, request_id, root_epoch, databases | error }`, and drawer applies the payload only when all three fields match the current pending placeholder for that branch. Manual `R` per D-63, `database_selected`, eventful source CRUD success per D-83, and eventful source reload are the epoch-bumping authoritative invalidators for `database_switch`; they MUST clear or rebuild any pending placeholder before the stale async completion can land through the same `root_epoch` bump path used for Phase 6 column branches, and pending placeholder state is dropped from `_struct_cache` or its Phase 7 equivalent container at the same pre-request-clear moment as other branch state. Reconnect identity rewrite is a separate same-epoch path per D-86: pending `database_switch` placeholders for the old `conn_id` migrate to the new `conn_id` only when they are still semantically valid for the rewritten authoritative connection identity, otherwise they are cleared and stale completions for the old `conn_id` drop by token mismatch without any epoch bump. Mismatched or stale database-switch payloads are dropped silently.

### the agent's Discretion
- Exact connection-row presentation for source identity (badge vs dim suffix), as long as D-65 keeps source metadata visible without reviving source parent rows.
- Exact wording and severity split between `utils.log` and `vim.notify`, as long as D-69's actionable-failure rule holds.
- Exact coalesce window and concurrency constants for D-78, as long as cold survivors do not auto-rewarm.
- Exact placeholder text and iconography for async `database_switch` loading, as long as D-81 stays truthful and non-blocking.

</decisions>

<specifics>
## Specific Ideas

- Treat `a` as "add connection to a source," not "add arbitrary row": if there is exactly one create-capable source, jump straight into that flow; otherwise open a tight source picker first.
- Keep source-file editing discoverable through a secondary connection action such as "Edit source file" or "Reveal source" rather than reviving source rows in the tree.
- Keep `connection_invalidated.reason` enumerable and human-readable, for example `source_add`, `source_update`, `source_delete`, `source_reload`, `database_selected`, and `reconnect_rewrite`.
- Preserve the shipped Phase 6 drawer subtree machinery instead of inventing a parallel model: targeted tree patching, `_struct_cache`, `Load more...`, caller fencing, and nearest-ancestor `R` stay the substrate.
- Let Phase 7 reuse the existing prompt-based add/edit flows first; Phase 8 can replace the prompt/form surface without re-litigating invalidation, rerender, or selection contracts.
- Model async `database_switch` loading after Phase 6 async columns: placeholder row first, targeted branch patch when the databases arrive, no full drawer redraw for success or failure.

</specifics>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Scope And Milestone Locks
- `.planning/PROJECT.md` — milestone goal, backward-compatibility rule, 2-pane constraint, and the decision that notes move out of the drawer
- `.planning/ROADMAP.md` — Phase 7 goal, success criteria, research bullets, and the open source-file-editing product question
- `.planning/REQUIREMENTS.md` — `DCFG-01`, plus the explicit handoff between Phase 6 `STRUCT-01` and Phase 7
- `.planning/STATE.md` — current milestone state and sequencing context

### Locked Prior-Phase Decisions
- `.planning/phases/04-drawer-navigation/04-CONTEXT.md` — Phase 4 D-31 filter snapshot restore and layout-era drawer interaction locks
- `.planning/phases/05-resilience-diagnostics/05-CONTEXT.md` — Phase 5 D-29 reconnect identity-rewrite baseline and additive bridge constraints
- `.planning/phases/05-resilience-diagnostics/05-RESEARCH.md` — reconnect helper placement, episode ownership, and the existing `connection_rewritten` rationale
- `.planning/phases/06-structure-laziness-notes-picker/06-CONTEXT.md` — Phase 6 D-30..D-63, especially D-46, D-48..D-62 deferrals, and D-63 nearest-ancestor reload
- `.planning/phases/06-structure-laziness-notes-picker/06-01-SUMMARY.md` — shipped STRUCT-01 implementation summary and the residual seams Phase 7 now owns

### Architecture And Codebase Maps
- `.planning/codebase/ARCHITECTURE.md` — Lua/Go layering, event flow, layout ownership, and LSP placement
- `.planning/codebase/CONVENTIONS.md` — Lua and Go error-handling, RPC-boundary, and event-system conventions
- `.planning/codebase/STRUCTURE.md` — where drawer, handler, reconnect, layout, and LSP code live today

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `lua/dbee/ui/drawer/init.lua` — already owns `_struct_cache`, drawer-owned root fencing, filter snapshot restore, nearest-ancestor `R`, and targeted tree mutation primitives; Phase 7 should reuse these rather than fork them.
- `lua/dbee/ui/drawer/model.lua` and `lua/dbee/ui/drawer/convert.lua` — existing split between render-model building and node materialization; removing notes and source rows should start here, not in ad hoc tree patches.
- `lua/dbee/layouts/init.lua` — `focus_pane()` and `ensure_drawer_visible()` already provide the 2-pane-compatible hooks the drawer rewrite needs.
- `lua/dbee/api/ui.lua` and `lua/dbee.lua` — Phase 6 already moved note discovery into a dedicated picker, so Phase 7 can remove note nodes without inventing new note access paths.

### Established Patterns
- `lua/dbee/handler/init.lua` is the Lua-side owner of handler/source lifecycle wrappers, while `dbee/handler/event_bus.go` is the additive Go-to-Lua event surface; Phase 7 lifecycle events belong on that seam.
- `lua/dbee/reconnect.lua` already owns connection rewrite state and its local listener registry; Phase 7 must bridge that into the canonical handler-facing invalidation and selection rules rather than duplicate reconnect-specific UI channels.
- `lua/dbee/lsp/init.lua` still independently starts full-tree warmups for the current connection; root coordination cannot be solved inside DrawerUI alone.
- `lua/dbee/config.lua` still ships the legacy drawer keyset (`r`, `<CR>`, `cw`, `dd`, `o`, `gC`, `yy`, `/`), giving Phase 7 one clear place to rewrite primary mappings.

### Integration Points
- `lua/dbee/ui/drawer/convert.lua` currently renders source rows, add connection, edit source, and connection children under each source; that is the primary seam for the connection-only root rewrite.
- `lua/dbee/ui/drawer/init.lua` currently listens to `current_connection_changed`, `structure_loaded`, `structure_children_loaded`, and `database_selected`, and still injects callback-driven rerenders through `perform_action()`; that is where the new invalidation and dispatcher contracts land.
- `lua/dbee/handler/init.lua` public source lifecycle methods still call `source_reload()` directly today; the silent/eventful split belongs there.
- `dbee/handler/event_bus.go` currently emits only `current_connection_changed`, `database_selected`, `structure_loaded`, and `structure_children_loaded`; Phase 7 adds the lifecycle invalidation/failure surface.
- `lua/dbee/reconnect.lua` already emits local `connection_rewritten(old_conn_id, new_conn_id)` signals, but DrawerUI does not consume them yet; Phase 7 owns the visible continuity path.
- `lua/dbee/ui/drawer/init.lua` still performs synchronous `connection_list_databases()` decoration for the `database_switch` row; Phase 7 owns the last connection-expand stall seam.

</code_context>

<deferred>
## Deferred Ideas

- Phase 8 `DCFG-02`: type-aware Oracle and Postgres forms, URL round-tripping, driver ping, and atomic FileSource persistence
- Phase 9 `PERF-01`: real-`nui.nvim` release-grade performance harness and measurement
- Any backend transport pagination beyond Phase 6's bounded in-drawer `Load more...` contract; Phase 7 should reuse the existing chunked materialization before considering deeper transport changes
- Any note-ownership redesign, reconnect-driven note namespace migration, or moving note CRUD back into the drawer; Phase 6 `pick_notes()` remains the supported note surface
- Post-Phase-7 ergonomics follow-up if the secondary source-file editing path proves too hidden after source rows are removed

</deferred>

---

*Phase: 07-connection-only-drawer*
*Context gathered: 2026-04-28*
