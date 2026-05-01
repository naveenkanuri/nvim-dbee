# Phase 4: Drawer & Navigation - Context

**Gathered:** 2026-03-17
**Status:** Context captured; active Phase 4 plans are the execution authority

<domain>
## Phase Boundary

Users can copy qualified database object names from the drawer, search/filter database objects in large schemas with live filtering, and jump directly between panes with dedicated keybindings. Covers CLIP-02, NAV-02, DRAW-01.

</domain>

<decisions>
## Implementation Decisions

### DRAW-01: Drawer search/filter

#### Search UX
- Live filter mode: type in a floating prompt, tree filters in real-time hiding non-matching nodes
- Trigger key: `/` (standard vim search key), buffer-local to drawer only
- `/` opens the filter prompt when the required cached structure corpus is ready; otherwise it WARNs and does NOT start incremental buffer search
- Filter prompt: small 1-line floating input window anchored to top of drawer (uses existing NuiInput/menu infrastructure from `drawer/menu.lua`)
- Live filtering driven from input change events against a searchable model captured once at filter start, not by per-keystroke tree rebuilds

#### Search scope
- Filter matches against table, view, procedure, and function node names only
- Connections and schemas are kept visible as ancestor containers when they have matching children
- Columns are NOT searchable (avoids needing to expand all lazy children for large schemas)

#### Filter exit behavior
- `<CR>` while filtered: always accept the filter in both prompt modes, capture the selected node ID, clear filter, restore the pre-filter rendered tree, restore expansion state, and refocus that node by ID (not row number)
- `<Esc>` while filtered: clear filter, restore previous cursor/expansion state
- Empty input restores the pre-filter rendered tree
- Normal drawer mappings stay unchanged outside filter mode; while the prompt owns focus, forwarded interaction uses a non-conflicting alias (`<C-y>` for `action_1`) so `<CR>` remains accept-only
- Prompt interaction split: INSERT mode for typing plus non-printing navigation/toggle keys, INTERACTION mode entered with `<C-]>`, and `i` returns to typing

#### Case sensitivity
- Case-insensitive matching is the locked default for DRAW-01

### CLIP-02: Drawer copy (yank qualified names)

#### Format
- Copy as qualified name: `schema.table_name` for tables/views/procs, `schema.table.column_name` for columns
- Targets both unnamed (`"`) and system clipboard (`+`) registers — same as call log yank pattern

#### Keybinding
- `yy` in drawer mappings — consistent with call log yank from Phase 2

#### Scope
- Yankable node types: table, view, procedure, function, column
- Non-yankable nodes (connection, schema, separator, help, etc): WARN `"Nothing to copy"`

#### Notification
- Success: `utils.log("info", "Copied: " .. value)` — shows the actual copied value
- No truncation requirement is locked for Phase 4; show the copied value directly and append the existing clipboard-unavailable suffix when needed

### NAV-02: Pane jumping

#### Interaction model
- Direct pane targeting: dedicated mapping per pane, no cycling
- Keybindings: `<leader>e` (editor), `<leader>r` (result), `<leader>d` (drawer), `<leader>l` (call log)
- Registered as buffer-local mappings on ALL dbee pane buffers (editor, result, drawer, call_log)
- Only active when cursor is in a dbee buffer — no global pollution

#### Drawer jump behavior
- `<leader>d` calls `ensure_drawer_visible()` then `focus_pane("drawer")` — auto-opens in MinimalLayout
- Consistent with "explicit drawer intent = auto-open" decision

### Layout API contract

#### New optional methods on Layout interface
- `focus_pane(name) -> boolean`: focuses the named pane window, returns true on success, false if pane unavailable
- `ensure_drawer_visible() -> boolean`: opens drawer if not visible (no-op in DefaultLayout, opens toggle in MinimalLayout)
- Both methods are optional — custom layouts that don't implement them get graceful degradation (WARN notification)
- Feature code checks for method presence: `if type(layout.focus_pane) == "function" then`
- No `pane_exists()` method — `focus_pane` return value handles this

#### DefaultLayout implementation
- `ensure_drawer_visible()`: no-op, returns true (drawer always visible)
- `focus_pane(name)`: `nvim_set_current_win(self.windows[name])`, returns true

#### MinimalLayout implementation
- `ensure_drawer_visible()`: calls `toggle_drawer()` if `self.drawer_win` is nil or invalid, returns true
- `focus_pane("editor"|"result")`: focuses window, returns true
- `focus_pane("drawer")`: focuses `self.drawer_win` if valid, returns true/false
- `focus_pane("call_log")`: returns false (MinimalLayout has no call log pane)
- Pane jump cycle in MinimalLayout: editor -> result -> drawer (if open) -> editor
- Explicit jump to call_log: WARN `"Call log pane is not available in this layout"`

#### Custom layout fallback
- Missing `focus_pane`: WARN `"Pane jumping is not supported by the current layout"`
- Missing `ensure_drawer_visible`: WARN `"Drawer is not supported by the current layout"`
- Never silently no-op, never fall back to inspecting layout internals

### Claude's Discretion
- Exact NuiInput configuration for filter float (size, position relative to drawer)
- Once `04-02-PLAN.md` exists, DRAW-01 tree rebuild and restore mechanics are no longer discretionary; follow its snapshot-backed searchable-model + session-scoped restore contract
- How to resolve qualified name from node context (walking parent chain vs storing schema on node)
- Whether to add pane-jump mappings to the help node in the drawer

## Supplemental Decisions (plan-gate review round 1)

**Added:** 2026-04-23 after dual-review REJECT verdict.

### GA-1: Cache readiness on filter start
**Decision:** Option (b), refined to a scoped ready corpus. DRAW-01 searches only connections whose `structure_cache[conn_id]` currently holds a successful structure payload. Missing-cache and cached-error connections are excluded from the searchable corpus and MUST NOT be warmed by pressing `/`. If zero connections are ready, `/` WARNs and does not open the prompt. If one or more are ready, the prompt opens and visibly reports partial coverage as `N of M connections cached`.
**Rationale:** This preserves the lazy-load model already used by the drawer, keeps filter start free of structure-warming RPCs, avoids async spinner/timeout races with refresh and teardown, and makes partial coverage explicit instead of silently pretending the corpus is complete. The real design constraint is avoiding cold-cache structure loads on the filter hot path; connection enumeration may still be used only to compute the `N of M` coverage label.
**Affects:** `04-02-PLAN.md` (filter-start contract, prompt copy, startup tests), `04-VALIDATION.md` (partial-corpus startup and coverage checks)

### GA-2: Drawer model sharing
**Decision:** Option (a). Add `lua/dbee/ui/drawer/model.lua` as the canonical drawer-model module. Normal drawer refresh and filtered search MUST both derive from this shared model layer. `convert.lua` keeps decorator/id/column helper responsibility; `drawer/init.lua` owns session lifecycle, prompt callbacks, and rendering orchestration only.
**Rationale:** The rejected plan's parallel pipeline in `drawer/init.lua` would let filtered and unfiltered trees drift. A dedicated model module matches the existing multi-file drawer layout, keeps `convert.lua` from becoming a mixed 500+ line file, and gives downstream reviewers one canonical place to reason about drawer hierarchy construction.
**Affects:** `04-02-PLAN.md` (file layout and task breakdown), `04-VALIDATION.md` (shared-model grep and lifecycle coverage)

### GA-3: Buffer teardown + reopen lifecycle
**Decision:** Option (c). Use both defenses: switch the drawer buffer to `bufhidden = "hide"` for normal drawer hide/show paths, and add `DrawerUI:rebuild_buffer()` so `show()` can recover if the buffer was externally deleted or invalidated. `prepare_close()` remains mandatory before layout-owned drawer teardown and MUST interrupt any active filter session before the host window/buffer disappears.
**Rationale:** `hide` avoids needless churn during ordinary drawer toggles, while `rebuild_buffer()` still protects against `:bd!` and other invalid-buffer paths. The explicit pre-close interruption is still required because the filter popup/session state must never outlive the host drawer window.
**Scope clarification:** "Avoid churn" applies to BUFFER recreation only. Ordinary drawer show/hide cycles still call `refresh()` which rebuilds the tree from `structure_cache` via `build_rendered_model`. This is intentional because event-driven updates such as `structure_loaded` or `database_selected` may have fired while the drawer was hidden, and `refresh()` is how those changes are picked up. A future dirty-flag optimization could skip that rebuild when nothing changed, but that is out of scope for Phase 4.
**Affects:** `04-02-PLAN.md` (buffer lifecycle contract), `04-VALIDATION.md` (buffer teardown and reopen fixtures)

### GA-4: Zero-RPC contract scope
**Decision:** Option (a). The hard zero-RPC guarantee applies only to typing (`on_change` / `apply_filter`). Prompt INTERACTION mode may trigger the same RPC-backed expand/action behavior the normal drawer already allows when the user explicitly drills into a filtered node.
**Rationale:** Typing latency is the user-facing hot path and the place where the contract matters. Forcing a broader "no RPC while prompt exists" rule would either be false or would cripple the primary filtered workflow of finding a table and expanding or acting on it immediately.
**Affects:** `04-02-PLAN.md` (contract wording, forwarded-action semantics), `04-VALIDATION.md` (split typing vs interaction assertions)

### GA-5: CLIP-02 behavior when schema is missing
**Decision:** Option (a). CLIP-02 does not silently degrade. If the selected node lacks the schema context required by the locked output format, `yy` WARNs `Nothing to copy (schema unavailable)` and writes nothing to either register.
**Rationale:** The current roadmap and context already lock the copied format as `schema.object` / `schema.table.column`. A hidden bare-name fallback would violate that contract and make copied output adapter-dependent in a way the user cannot predict from the UI. If schema-less adapter support is wanted later, that should be an explicit requirement/context change rather than an implementation-side downgrade.
**Affects:** `04-01-PLAN.md` (yank contract and CLIP tests), `04-VALIDATION.md` (no bare-name fallback assertions)

</decisions>

<specifics>
## Specific Ideas

- `/` for drawer search follows the universal vim convention for "search in current context"
- `yy` for drawer yank is consistent with call log yank (Phase 2) — same muscle memory across panes
- Direct pane targeting (`<leader>e/r/d/l`) beats cycling because it's deterministic and handles layout differences cleanly
- Filter float should reuse existing NuiInput infrastructure from `drawer/menu.lua` to minimize new code
- `ensure_drawer_visible()` + `focus_pane()` as the layout API keeps drawer lifecycle owned by the layout, not by feature code

</specifics>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase scope and requirements
- `.planning/PROJECT.md` — global constraints including backward compatibility and layout/UI guardrails
- `.planning/ROADMAP.md` — Phase 4 goal, success criteria, and plan breakdown
- `.planning/REQUIREMENTS.md` — CLIP-02, NAV-02, and DRAW-01 requirement statements
- `.planning/STATE.md` — current project/phase status and execution starting point

### Phase 4 planning bundle
- `.planning/phases/04-drawer-navigation/04-01-PLAN.md` — execution contract for CLIP-02 and NAV-02
- `.planning/phases/04-drawer-navigation/04-02-PLAN.md` — authoritative execution contract for DRAW-01 once it exists
- `.planning/phases/04-drawer-navigation/04-RESEARCH.md` — codebase research, pitfalls, and superseded ideas annotated for Phase 4
- `.planning/phases/04-drawer-navigation/04-VALIDATION.md` — task-aligned validation contract and manual release gates

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `drawer/menu.lua` — `menu.input {}` already creates floating NuiInput relative to drawer window, reusable for filter prompt
- `drawer/expansion.lua` — `expansion.get(tree)` / `expansion.set(tree, exp)` saves/restores tree expansion state
- `drawer/convert.lua` — builds tree nodes with `type`, `name`, `schema` fields — filter can match on these
- `common.configure_buffer_mappings(bufnr, actions, mappings)` — registers buffer-local keybindings from action map
- `utils.log(level, msg)` — notification framework from Phase 1
- `DefaultLayout.windows` table stores `{ editor = winid, result = winid, drawer = winid, call_log = winid }`
- `MinimalLayout.toggle_drawer()` — already toggles drawer visibility

### Established Patterns
- Actions registered via `get_actions()` -> consumed by `common.configure_buffer_mappings` (all panes)
- Default keybindings in `config.lua` with `{ key, mode, action }` format
- `pcall` + `utils.log` for error handling on user-facing operations
- `vim.fn.setreg` for register writes (both `"` and `+`) — established in result/call_log yank

### Integration Points
- `lua/dbee/ui/drawer/init.lua` — add `filter` and `yank_name` actions to `get_actions()`
- `lua/dbee/config.lua` — add default mappings: `/` (drawer), `yy` (drawer), `<leader>e/r/d/l` (all panes)
- `lua/dbee/layouts/init.lua` — add `focus_pane()` and `ensure_drawer_visible()` to both layout classes
- `lua/dbee.lua` or `lua/dbee/api/ui.lua` — public API for pane focus that delegates to layout

### Node structure for yank
- DrawerUINode has: `id`, `name`, `type`, `schema` (on table/view/proc/function nodes, not columns)
- Parent-child hierarchy: connection -> schema -> table/view -> column
- Qualified name can be built from node's `schema` + `name` fields (no tree traversal needed for tables/views)
- Column qualified name needs parent table name — may need to walk up or store on node

</code_context>

<deferred>
## Deferred Ideas

- One-step "focus drawer + start filter" from any pane (global shortcut) — separate from `/` which is drawer-local
- `list_focusable_panes()` or `get_pane_state()` for richer layout introspection — add when needed, not now
- Auto-open call_log in MinimalLayout — would be a layout redesign, not a Phase 4 compatibility tweak

</deferred>

---

*Phase: 04-drawer-navigation*
*Context gathered: 2026-03-17*
