# Phase 6: Structure Laziness & Notes Picker - Context

**Gathered:** 2026-04-27
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 6 is the preparatory v1.1 wave that makes structure browsing responsive and moves note discovery onto a dedicated picker before the larger drawer-configuration phases land. After ten plan-gate rounds, its scope is intentionally narrowed to drawer-local `STRUCT-01` work plus `NOTES-01`: additive async column fetch, drawer-owned root fencing, bounded branch materialization, explicit root/branch error storage inside `_struct_cache`, and the single-picker global/local notes UX.

This phase does NOT remove notes from the drawer yet, redesign note CRUD, redefine note ownership semantics, or turn the larger drawer/handler/LSP/reconnect lifecycle into a unified contract. Cross-module ownership such as current-connection focus semantics, source-action rerender ownership, handler/source invalidation choreography, reconnect/source-reload coordination, invalidation backpressure, reload/current-selection choreography, and LSP single-flight coordination moves to Phase 7 (`DCFG-01`). Phase 6 establishes only the drawer-local contracts that later phases can reuse cleanly.

</domain>

<decisions>
## Implementation Decisions

### Phase Shape
- **D-30:** Phase 6 is split into two plans: `06-01` for `STRUCT-01` and `06-02` for `NOTES-01`. `06-01` establishes the drawer/cache contract reused by Phases 7 and 9; `06-02` upgrades the existing notes picker path without coupling it to drawer removal work.

### STRUCT-01: Structure Fetch + Cache Contract
- **D-31:** Preserve the existing full-tree `connection_get_structure_async(conn_id, request_id)` -> `structure_loaded{ conn_id, request_id, structures }` contract. Phase 6 may add subtree-specific helpers or events, but it must not repurpose or narrow `structure_loaded`, because LSP and Phase 4 stale-load handling already consume that payload.
- **D-32:** Structure cache eviction is explicit and session-scoped, not TTL-based. Phase 6 owns target-connection `R` reload and `database_selected` for that connection. It does NOT own any passive source-lifecycle invalidation listener or producer contract, and it does NOT add drawer-side reconnect choreography. Mere `current_connection_changed` updates focus; its visual/update contract is deferred to Phase 7 and MUST NOT be silently redefined inside Phase 6.
- **D-33:** Cache ownership is conceptually connection/schema/table scoped per the requirement, but internal keys should use stable branch identity rooted in the existing encoded node/path IDs. Do not key solely by display strings; Oracle grouped sections and future child kinds need collision-safe identities.
- **D-34:** Connection expansion shows a placeholder child row immediately and schedules async loading for the next authoritative level. With the current backend, that means one async root-structure warmup per connection; schema and table-like branches are then materialized lazily from the cached payload instead of eagerly hydrating the whole subtree into the tree at refresh time.
- **D-35:** Table-like expansion must be truthfully non-blocking. `vim.schedule()` around a synchronous RPC does not satisfy `STRUCT-01`. If `connection_get_columns()` remains the only table-child surface, planning must either add additive async child-fetch support or explicitly constrain the non-blocking guarantee to the levels that can be loaded without UI stalls. Do not silently ship blocking table expansion under a “lazy” label.
- **D-36:** Loading UX uses transient placeholder child nodes inside the branch being expanded, replaced in place on success or failure. Do not add a separate modal/progress window or a decorator-only spinner state that leaves branch contents ambiguous.
- **D-37:** Oversized branches render the first 1000 children plus an inline `Load more…` sentinel as the last child. Activating the sentinel appends the next chunk in the same branch and preserves expansion and cursor context; it does not reopen the branch in another picker or rebuild unrelated siblings.
- **D-38:** DRAW-01 filter guarantees remain locked. Filter typing stays zero-RPC and operates only on authoritative cached structure data. Lazy-loading may invalidate and rebuild the search corpus when cache changes, but `/` and `on_change` must never warm cold structure RPCs.
- **D-39:** Phase 6 defines a child-loading contract broad enough for future `columns`, `indexes`, `sequences`, and `foreign keys`, but it does not require inventing full idx/seq/FK backend coverage in this phase. Preserve truthful current surfaces first; broader table-child families can land in Phase 7 if new backend helpers are needed.
- **D-46:** Branch-scoped child fetches carry a per-connection `root_epoch`, and drawer-owned root requests may carry the same token. Phase 6 uses a single-bump rule: `root_epoch[conn_id]` increments only during the drawer's pre-request clear for that same connection (targeted manual reload via manual `R` per D-63, or `database_selected` for that connection), and it MUST NOT increment again in the accept/apply path for that request. Any `structure_children_loaded` payload whose `root_epoch` no longer matches the current epoch for that connection is stale and must be dropped silently. LSP-owned root loads stay outside Phase 6 epoch discipline.
- **D-47:** Phase 6 `Load more…` is a bounded-render contract, not transport pagination. This phase may still fetch the full truthful child-family payload for a branch; only in-drawer materialization is chunked to 1000-at-a-time. Backend child paging is deferred unless measured workloads justify it in a later phase.
- **D-48:** DEFERRED to Phase 7+. `connection_invalidated` producer/consumer ownership belongs at the handler/event-bus seam, not `api.core`, because live drawer code already calls handler-layer source lifecycle entry points directly. Phase 6 does not rely on that event shape and does not own any invalidation listener or emitter contract.
- **D-49:** Phase 5's `connection_rewritten` contract preserves only authoritative root continuity as the reconnect baseline for later phases. If that signal is consumed by drawer code, only root cache state (`root`, `root_gen`, `root_applied`, and `root_epoch`) may survive across old/new conn IDs; `loaded_lazy_ids`, saved expansion IDs rooted in the retired conn_id, and all branch-scoped lazy child state are intentionally disposable. Phase 6 does not add active drawer subscription or warm-rerender choreography for this path.
- **D-50:** All Phase 6 structure cache state lives inside one namespaced `DrawerUI` container, `self._struct_cache = { root = { [conn_id] = { structures, error } }, root_gen, root_applied, root_epoch, loaded_lazy_ids, branches = { [conn_id] = { [branch_key] = { raw, error, built_count, render_limit, request_gen, applied_gen, loading } } } }`. Do not scatter new root/branch state across unrelated top-level tables in Phase 6. Phase 7 may extract this container wholesale into `lua/dbee/ui/drawer/structure_cache.lua`.
- **D-51:** DEFERRED to Phase 7+. Handler reload semantics split into silent and eventful variants together with their public wrapper choreography. Phase 6 does not introduce `_source_reload_silent`, and it does not add reconnect-side wrapper choreography on top of the existing Phase 5 surface.
- **D-52:** Early `connection_invalidated` events emitted before any drawer/editor UI instance has registered listeners are intentionally lost. Phase 6 UI consumers must bootstrap from cold-cache/no-cache state on mount instead of depending on event replay, so pre-UI `add_source` or source lifecycle churn stays no-op safe.
- **D-53:** DEFERRED to Phase 7+. Source lifecycle reload failure remains part of the broader handler/source lifecycle contract. Phase 6 does not add `_source_reload_silent()` or a `source_reload_failed` emit path; those policies move with the rest of the public source-lifecycle choreography.
- **D-54:** DEFERRED to Phase 7+. Drawer source-lifecycle UI actions will eventually split prompt closure from data refresh so action callbacks close UI only and authoritative rerender is owned by invalidation listeners. Phase 6 no longer owns that dispatcher contract.
- **D-55:** Large-database root-warmup claims are caveated rather than chunked in Phase 6. This phase does not add chunked `structure_loaded` transport or a new drawer metadata-SQL fallback. Phase 6 may claim improved root-payload delivery only for adapters where full-tree `structure_loaded` delivery succeeds within the validation bound; it does NOT claim end-to-end connection-expand paint responsiveness while `connection_list_databases()` remains synchronous. When full-tree delivery misses the bound, validation records the adapter as a legacy slow-path caveat rather than claiming success. LSP's existing metadata SQL fallback remains LSP-only.
- **D-56:** Full-tree `structure_loaded` ownership is explicit for drawer-owned root loads. `connection_get_structure_async()` may accept additive `caller_token`; drawer-owned root requests pass `caller_token = "drawer"` plus `root_epoch`, and `DrawerUI:on_structure_loaded()` accepts a payload only when `caller_token == "drawer"` plus the drawer-owned pending request token and current `root_epoch` both match. Legacy/LSP-owned root requests remain valid and stay outside the Phase 6 root-epoch discipline.
- **D-57:** DEFERRED to Phase 7+. Drawer action dispatch will eventually split popup callbacks into explicit `close_only` and `refresh_after_action` modes, but Phase 6 no longer owns that cross-module action contract.
- **D-58:** DEFERRED to Phase 7+. Batched rerender ownership for handler-layer invalidation belongs with the larger source-action/lifecycle rewrite; Phase 6 may clear retired cache state when invalidation is observed but does not define the event-wide rerender contract.
- **D-59:** DEFERRED to Phase 7+. Survivor-aware auto-refetch, throttling, and invalidation backpressure move to the connection-only drawer rewrite. In Phase 6, invalidation may drop stale drawer cache, but re-fetch remains lazy on the next user expand.
- **D-60:** Phase 6 scope is intentionally narrowed to converge: it owns drawer-local async table/view column fetch, `_struct_cache`, drawer-owned root `caller_token`/`root_epoch` fencing, bounded `Load more…` materialization, flat `loaded_lazy_ids`, manifest regeneration, real tree mutation primitives, per-branch pending-request dedupe, explicit root/branch error storage, and the unchanged `NOTES-01` picker work. Phase 7 (`DCFG-01`) owns the deferred cross-module seams: `current_connection_changed` semantics, drawer/LSP root-load coordination, source-action dispatcher split, connection-selection callback refresh behavior, invalidation rerender ownership and backpressure, late queued startup invalidations, public source-lifecycle failure/invalidation flows, reconnect/source-reload choreography, reload/current-selection ownership, drawer-visible reconnect continuity, and the remaining `connection_list_databases()` expand seam.
- **D-61:** Further narrow after round 9: D-48, D-51, D-53, D-54, D-57, D-58, and D-59 are all fully Phase 7 concerns. Phase 6 does not own `connection_invalidated`, `_source_reload_silent`, `source_reload_failed`, public source-lifecycle invalidation, or any broader reconnect/source-reload choreography.
- **D-62:** Final narrow after round 10: all reconnect-related drawer work is deferred to Phase 7. Phase 6 does not invoke `rewrite_connection_identity()` from public reconnect flows, does not subscribe to `connection_rewritten`, and does not promise warm subtree continuity after manual reconnect remaps a conn_id. Known limitation: on rare manual reconnects that return a new conn_id, users may see a cold subtree until a later refresh; Phase 7 owns the visible continuity contract.
- **D-63:** Manual `R` is a drawer-local nearest-ancestor reload rule. If the cursor is on a connection row, reload that connection. If the cursor is on a descendant structure row or a `database_switch` row under a connection, walk upward to the nearest ancestor connection row and reload that connection. If the cursor is on a source row, note row, help row, or any node with no connection ancestor, warn (`select a connection row to reload`) and no-op. This is Phase 6's only reload-targeting contract; broader reload/current-selection choreography remains Phase 7 work.

### NOTES-01: Picker Behavior
- **D-40:** Extend the existing public `dbee.pick_notes()` path instead of inventing a new command or modal flow. The picker remains single-select and still opens the chosen note through `api.ui.editor_set_current_note()`.
- **D-41:** Picker ordering is fixed: `Global notes` first, `Local notes (<current connection name>)` second when a current connection exists. Each selectable item carries a source tag for quick scanning: `[global]` or `[local: <conn_name>]`.
- **D-42:** The notes UX must stay one picker, not a chained global/local flow. If the installed Snacks build lacks native section headers, use non-selectable pseudo-header rows inside the same picker rather than splitting interaction into multiple prompts.
- **D-43:** Local note membership remains namespace-based. Phase 6 reads local notes from `namespace_get_notes(tostring(current_connection.id))` and uses the current connection name only for display. It does not reinterpret “local” from `note_exec_meta`, `call_note_ids`, or reconnect history.
- **D-44:** Empty-state behavior is explicit. If there are no notes at all, keep the current lightweight info path and do not open the picker. If globals exist but the current connection has no local notes, still render the local section with a single non-selectable hint row naming that connection. If there is no current connection, render only the global section.
- **D-45:** Phase 6 does not remove notes from the drawer or redesign note CRUD. It only ensures the dedicated picker path is good enough that Phase 7 can remove drawer note discovery without stranding users.

### the agent's Discretion
- Exact helper and module names for subtree cache storage and placeholder-node utilities
- Exact placeholder and sentinel copy, as long as it clearly communicates loading versus pagination
- Exact Snacks row-format implementation for pseudo-header and hint rows
- Whether additive async table-child fetch lands as a new Go endpoint/event pair or a tightly scoped Lua wrapper over a new core API, as long as D-31 and D-35 hold

</decisions>

<specifics>
## Specific Ideas

- The current top-level connection `loading...` row is the right precedent for branch-local loading rows. Show immediate local feedback where the user expanded, not a drawer-wide busy state.
- Oracle with many active connections and large schemas is the motivating worst case. That is why TTL and focus-change invalidation are rejected: they would just rewarm expensive trees and reintroduce stalls.
- Phase 4’s `request_id` / `applied_gen` stale-load rejection remains the baseline for any async structure work in this phase.
- The current notes picker already exists and the drawer already groups global/local notes. Phase 6 is promoting that discovery path into a clearly sectioned picker, not inventing a new notes model.
- `connection_list_databases()` is still a synchronous seam on connection expansion. STRUCT-01 does not silently relabel that path as non-blocking or fold it into the D-55 root-payload-delivery claim; Phase 6 documents it as a residual watchpoint and defers any deeper fix to the later drawer rewrite work.
- The narrow Phase 6 target is "stop synchronous `connection_get_columns()` from blocking table/view expand" plus bounded branch materialization and explicit cache/error ownership. Cross-module rerender/current-selection/LSP coordination, reconnect continuity, invalidation ownership, and source-lifecycle choreography are intentionally postponed rather than half-owned here.
- Full-tree `structure_loaded` transport remains the real ceiling on large-schema responsiveness. Phase 6 ships async columns because it removes the lower blocking seam cleanly; Phase 7 should own any deeper root-path instrumentation, transport changes, or connection-expand rewrite beyond the D-55 caveat.

</specifics>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase scope and milestone constraints
- `.planning/PROJECT.md` — v1.1 milestone goals, additive-change rule, and minimize-RPC constraint
- `.planning/ROADMAP.md` — Phase 6 goal, success criteria, and research bullets; also Phase 7 and Phase 9 dependencies that reuse this contract
- `.planning/REQUIREMENTS.md` — `STRUCT-01` and `NOTES-01` requirement statements plus the explicit note-CRUD redesign out-of-scope guardrail
- `.planning/STATE.md` — current milestone state and Phase 6 starting point

### Prior locked decisions to preserve
- `.planning/phases/04-drawer-navigation/04-CONTEXT.md` — DRAW-01 zero-RPC typing, snapshot/session restore, and stale-load/cache discipline that STRUCT-01 builds on
- `.planning/phases/05-resilience-diagnostics/05-CONTEXT.md` — locked D-01..D-29 boundaries, especially reconnect/editor ownership and note-ownership constraints that NOTES-01 must not redefine

### Architecture references
- `.planning/codebase/ARCHITECTURE.md` — Go↔Lua event flow and existing event-bus ownership boundaries
- `.planning/codebase/CONVENTIONS.md` — additive API expectations and extension conventions for Lua/Go surfaces
- `.planning/codebase/STRUCTURE.md` — codebase map for drawer, handler, editor, and API modules touched by Phase 6

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `lua/dbee/ui/drawer/init.lua` — already owns `structure_request_gen`, `structure_applied_gen`, `loaded_lazy_ids`, filter-session snapshot/restore, and `request_structure_reload()`
- `lua/dbee/ui/drawer/convert.lua` — already defines stable `structure_node_id()` values, top-level loading/error rows, and the current synchronous `lazy_children` contract for table/view columns
- `lua/dbee/ui/drawer/model.lua` — shared rendered/search model from Phase 4; search coverage and searchable-node behavior should remain centralized here
- `dbee/handler/handler.go` + `lua/dbee/handler/init.lua` — existing async full-tree structure load with `request_id`; there is no current async per-table child endpoint
- `lua/dbee/lsp/init.lua` — consumes `structure_loaded.data.structures` to seed and refresh schema cache, so the current event semantics are already shared beyond the drawer
- `lua/dbee.lua` + `lua/dbee/api/ui.lua` — current Snacks-based `pick_notes()` and public note aggregation path
- `lua/dbee/ui/editor/init.lua` — `namespace_get_notes()`, note namespaces keyed by connection ID, and existing `note_exec_meta` that must remain auxiliary rather than becoming storage ownership

### Established Patterns
- Phase 4 already rejects stale async structure loads with `request_id` / `applied_gen`; Phase 6 should extend that pattern instead of replacing it
- `lazy_children` is synchronous today. True async subtree loading will need a new branch-state wrapper or replacement path rather than pretending the current callback contract is non-blocking
- DRAW-01 filter only searches authoritative cached structure and closes on authoritative data changes; Phase 6 must preserve that user-facing contract
- Local notes are currently stored by namespace ID equal to the current connection ID. Execution metadata is separate and does not define note storage ownership

### Integration Points
- `lua/dbee/ui/drawer/init.lua`, `convert.lua`, and `model.lua` for branch state, placeholder rows, chunking, and cache invalidation
- Potential additive Go/Lua bridge points: `dbee/handler/handler.go`, `dbee/handler/event_bus.go`, `lua/dbee/handler/init.lua`, and `lua/dbee/api/__register.lua` if truthful non-blocking table-child fetch needs a new async endpoint
- `lua/dbee.lua` and/or `lua/dbee/api/ui.lua` for sectioned picker assembly on the existing `pick_notes` path
- `lua/dbee/ui/editor/init.lua` for namespace-based local note enumeration and note display metadata used by the picker

</code_context>

<deferred>
## Deferred Ideas

- TTL-based structure eviction
- Reinterpreting local note ownership from execution metadata or migrating note namespaces after reconnect-driven ID rewrite
- Full table-child coverage for indexes, sequences, and foreign keys if current adapter/backend surfaces do not expose them truthfully yet
- The explicit `current_connection_changed` visual/update contract across drawer, handler, reconnect, and LSP
- Drawer/LSP single-flight or piggyback coordination for full-tree `connection_get_structure_async()`
- Source-action callback dispatch ownership (`close_only` vs `refresh_after_action`) and exact rerender ownership for any future invalidation event
- Public wrapper invalidation/error emit policy, including `connection_invalidated`, `source_reload_failed`, late queued startup invalidations, survivor auto-refetch/backpressure, and silent-vs-eventful source reload ownership
- All reconnect/source-reload coordination, including drawer-visible continuity after `connection_rewritten` and any future manual reconnect handoff
- The synchronous `connection_list_databases()` seam on connection expansion and the remaining end-to-end expand-paint stall it can cause; Phase 7 can fold both into the broader drawer rewrite rather than overloading STRUCT-01
- Removing notes from the drawer and all connection-only drawer UX changes — Phase 7
- Real-`nui.nvim` drawer performance harness changes — Phase 9

</deferred>

---

*Phase: 06-structure-laziness-notes-picker*
*Context gathered: 2026-04-27*
