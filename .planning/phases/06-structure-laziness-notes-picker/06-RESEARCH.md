---
phase: 06
slug: structure-laziness-notes-picker
status: draft
created: 2026-04-27
---

# Phase 06 — Research

> Focused research for `STRUCT-01` and `NOTES-01`, with the main technical question centered on D-35: whether truthful non-blocking table-child expansion can be delivered without additive backend work.

---

## Research Question

Can Phase 6 satisfy `STRUCT-01` with Lua-only drawer changes, or does truthful non-blocking child expansion require additive Go/Lua async child-fetch support?

Related notes question:

- Should `NOTES-01` extend the existing flat `editor_get_all_notes()` helper, or add a picker-specific structured helper that avoids breaking unrelated callers?

---

## Evidence Read

- `.planning/phases/06-structure-laziness-notes-picker/06-CONTEXT.md`
- `.planning/ROADMAP.md`
- `.planning/REQUIREMENTS.md`
- `dbee/endpoints.go`
- `dbee/handler/handler.go`
- `dbee/handler/event_bus.go`
- `lua/dbee/handler/init.lua`
- `lua/dbee/ui/drawer/init.lua`
- `lua/dbee/ui/drawer/convert.lua`
- `lua/dbee/ui/drawer/model.lua`
- `lua/dbee/lsp/init.lua`
- `lua/dbee.lua`
- `lua/dbee/api/ui.lua`
- `lua/dbee/ui/editor/init.lua`

---

## Current-State Findings

### 1. Full-tree async structure loading is already a shared contract

- `Handler:connection_get_structure_async(id, request_id)` exists today in `lua/dbee/handler/init.lua`.
- `DbeeConnectionGetStructureAsync` exists in `dbee/endpoints.go`.
- `structure_loaded{ conn_id, request_id, structures }` is already consumed by:
  - the drawer in `lua/dbee/ui/drawer/init.lua`
  - the LSP bootstrap/refresh path in `lua/dbee/lsp/init.lua`
- Phase 4 already hardened this flow with `structure_request_gen` and `structure_applied_gen`.

Conclusion:

- D-31 is correct. `structure_loaded` must remain the full-tree event and cannot be narrowed into a subtree event without breaking existing consumers or forcing unnecessary churn into LSP.

### 2. Table child loading is synchronous today

- `Handler:connection_get_columns(id, opts)` in `lua/dbee/handler/init.lua` calls `vim.fn.DbeeConnectionGetColumns(...)` synchronously.
- `DbeeConnectionGetColumns` in `dbee/endpoints.go` is a direct request/response endpoint.
- `lua/dbee/ui/drawer/convert.lua` wires table/view `lazy_children` to:

```lua
node.lazy_children = function()
  return column_nodes(struct.id, handler:connection_get_columns(conn_id, table_opts))
end
```

Conclusion:

- Table expansion currently blocks until the RPC returns.
- Wrapping this call in `vim.schedule()` would only defer when the blocking happens; it would not make the fetch asynchronous or keep Neovim responsive during the fetch itself.
- D-35 therefore rules out a Lua-only shim if Phase 6 promises non-blocking table expansion.

### 3. Connection expansion is also still eager after cache warmup

- `lua/dbee/ui/drawer/convert.lua` recursively calls `to_tree_nodes(struct.children, node_id)` when cached structure exists.
- That means once the full structure tree is present, the drawer eagerly materializes the entire subtree into Nui nodes during refresh, instead of only the next visible level.

Conclusion:

- Phase 6 must change drawer materialization behavior even if the backend full-tree contract remains unchanged.
- Connection/schema expansion can become lazy using cached full-tree data without adding new backend RPCs.

### 4. Filter and stale-load contracts already exist and must survive the refactor

- `lua/dbee/ui/drawer/init.lua` already tracks:
  - `loaded_lazy_ids`
  - `structure_request_gen`
  - `structure_applied_gen`
- `DRAW-01` zero-RPC filter guarantees already live in `DrawerUI:apply_filter()`.

Conclusion:

- Phase 6 should extend the existing generation-based stale-load discipline rather than invent a new global cache protocol.
- Filter search corpora must continue to be built from authoritative cached data only and must not trigger cold structure RPCs while typing.

### 5. `editor_get_all_notes()` is already shared beyond `pick_notes()`

- `dbee.pick_notes()` uses `api.ui.editor_get_all_notes()`.
- Another path in `lua/dbee.lua` also uses `api.ui.editor_get_all_notes()` to find note files during history restore/jump.

Conclusion:

- Changing the return shape of `editor_get_all_notes()` is risky and unnecessary.
- `NOTES-01` should add a picker-specific structured helper rather than mutate the flat helper contract.

### 6. Local note ownership is already namespace-based and should stay that way

- `api.ui.editor_get_all_notes()` reads local notes from `namespace_get_notes(tostring(current_connection.id))`.
- `EditorUI:namespace_get_notes()` remains the source of truth for note storage.
- `note_exec_meta` and reconnect metadata exist, but they are not note ownership.

Conclusion:

- D-43 is the correct boundary. Phase 6 should not reinterpret local-note membership from execution metadata.

---

## Options Considered

### Option A: Lua-only lazy render, keep synchronous `connection_get_columns()`

Pros:

- Smaller change set.
- No Go or event-bus work.

Cons:

- Violates D-35 for table expansion.
- Still blocks Neovim on table/view expansion.
- Would market synchronous work as "lazy/non-blocking" even though only the connection/schema layers improved.

Verdict:

- Rejected.

### Option B: Additive async child-fetch path for table children, keep full-tree root contract unchanged

Pros:

- Satisfies D-31 and D-35 together.
- Keeps LSP and current root-structure consumers untouched.
- Lets connection/schema expansion use cached full-tree data lazily while table/view expansion gets a truthful non-blocking path.
- Can be shaped so future child kinds reuse the same drawer-side branch state and event handling.

Cons:

- Requires additive Go endpoint/event work plus Lua handler wrapper changes.
- Adds one more async request lifecycle to the drawer.

Verdict:

- Accepted.

### Option C: Change `editor_get_all_notes()` into a sectioned return shape

Pros:

- Fewer new helper names.

Cons:

- Breaks unrelated flat-list callers.
- Couples picker formatting to a generic UI data helper.

Verdict:

- Rejected.

### Option D: Add picker-specific structured helper and keep `pick_notes()` as the public command

Pros:

- Satisfies D-40 through D-45 cleanly.
- Preserves flat helper compatibility.
- Keeps note-section ordering and empty-state logic in one focused contract.

Cons:

- One extra API helper.

Verdict:

- Accepted.

---

## Recommendation

### STRUCT-01

Plan Phase 6 with an additive async child-fetch surface for table/view children.

Recommended contract:

- Keep `connection_get_structure_async(conn_id, request_id)` and `structure_loaded{ conn_id, request_id, structures }` unchanged.
- Add a separate async child-fetch path for table/view children only in Phase 6.
- Pass an opaque `branch_id` from Lua to Go and echo it back in the async event so drawer state stays keyed by stable encoded node/path identity per D-33.
- Keep the backend child fetch truthful to currently exposed data:
  - Phase 6 must support `columns` because that surface already exists.
  - Phase 6 must shape drawer-side child loading so future kinds such as `indexes`, `sequences`, and `foreign keys` can plug in later.
  - Phase 6 does not need to invent backend coverage for those additional kinds yet if the current core does not expose them truthfully.

Recommended event shape:

```lua
{
  conn_id = "conn-id",
  request_id = 3,
  branch_id = "encoded-node-id",
  kind = "columns",
  columns = { ... },
  error = nil,
}
```

This keeps `structure_loaded` intact while giving the drawer an additive, branch-scoped async contract.

### NOTES-01

Plan `pick_notes()` as a sectioned single picker backed by a new structured helper in `api.ui`.

Recommended contract:

- Keep `dbee.pick_notes()` as the public entry point.
- Add a picker-specific helper that returns:
  - global notes
  - local notes for `tostring(current_connection.id)` when a current connection exists
  - current connection display name for tagging and section headers
- Keep `editor_get_all_notes()` unchanged for other flat-list callers.
- Use non-selectable pseudo-header and hint rows inside the same picker rather than chaining prompts or relying on optional Snacks section-header features.

---

## Planner Guidance

- `06-01-PLAN.md` should include explicit Go changes in:
  - `dbee/handler/handler.go`
  - `dbee/endpoints.go`
  - `dbee/handler/event_bus.go`
  - `lua/dbee/handler/init.lua`
- `06-01-PLAN.md` should also call out the drawer-side refactor in:
  - `lua/dbee/ui/drawer/init.lua`
  - `lua/dbee/ui/drawer/convert.lua`
  - `lua/dbee/ui/drawer/model.lua`
- `06-02-PLAN.md` should keep the notes change additive, likely touching:
  - `lua/dbee.lua`
  - `lua/dbee/api/ui.lua`
  - optional `lua/dbee/doc.lua` if the new helper is documented

---

## Decision Summary

- D-35 requires additive async child-fetch work. A Lua-only `vim.schedule()` wrapper around `connection_get_columns()` is not a truthful non-blocking solution.
- `structure_loaded` stays full-tree and unchanged.
- Drawer rendering must stop eagerly hydrating entire cached subtrees during refresh.
- The notes picker should use a new picker-specific structured helper and must not mutate `editor_get_all_notes()` return shape.
- Local note ownership remains namespace-based off the current connection ID.

**Research outcome:** ready for planning.
