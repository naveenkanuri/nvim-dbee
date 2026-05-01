# Phase 13: UX Regression Batch - Context

**Gathered:** 2026-04-29  
**Status:** Locked — ready for planning  
**Codex thread:** `019ddb0e-e8d0-7ca1-a4b0-8d4728863630`

<domain>
## Phase Boundary

Phase 13 is a targeted regression-closure phase for three v1.1/v1.2 user-facing failures: the Phase 8 connection wizard is unreadable on dark colorschemes, the Phase 7 connection-only drawer root cannot enter `/` filter mode before structure cache exists, and Phase 11 cache-shape recovery reports normal upgrade migration as alarming corruption.

In scope:
- Wizard child-window highlight fixes for the existing Phase 8 compound `nui.nvim` wizard.
- Drawer filter fallback for the connection-only root and visible mixed drawer rows.
- LSP schema-cache version/migration UX so legitimate old cache formats do not WARN as corrupt.
- Focused tests for the three regressions plus the existing Phase 4..11 smoke/perf/semantic gates.

Out of scope:
- Schema allowlist or schemas-only lazy loading; those are Phase 14.
- LSP hover, resolve, code actions, or symbols; those are conditional Phase 16.
- LSP index residuals, source-badge visual-noise cleanup, cold-start orientation, and loading timeout/cancel UX; those are Phase 15 unless directly required to close a Phase 13 regression.
- Pre-existing `a and nil or b` cleanup and four legacy headless failures; those remain outside v1.3 Phase 13.

</domain>

<decisions>
## Implementation Decisions

### Phase Shape And Drift Guard
- **D-198:** Phase 13 is regression closure only. It restores the existing wizard, drawer filter, and LSP cache migration workflows; it must not add schema allowlist, deeper lazy-loading architecture, LSP feature surfaces, or broader drawer polish.
- **D-199:** Phase 13 honors D-01..D-197 verbatim. It may depend on prior contracts but must not edit or reinterpret prior CONTEXT decisions. Phase 13 decision numbering starts at D-198 and milestone-level locks in `.planning/milestones/v1.3-roadmap.md` do not consume D-numbers.
- **D-200:** If implementation exposes an obviously wrong defect directly blocking one of the three Phase 13 fixes, planning must surface it as a fix-needed note and keep the patch minimal. Deeper bugs outside this backlog are v1.3 backlog-growth candidates, not silent Phase 14/15/16 scope creep.

### Wizard Highlight Regression
- **D-201:** The Phase 8 wizard implementation path is `lua/dbee/ui/connection_wizard/init.lua`. Downstream agents must not search for a nonexistent `lua/dbee/ui/wizard/*` module before checking this file.
- **D-202:** All wizard-owned `nui.nvim` floating surfaces must use an explicit highlight contract instead of inheriting user colorscheme defaults. The locked mapping is `Normal:NormalFloat,NormalNC:NormalFloat,EndOfBuffer:NormalFloat,FloatBorder:FloatBorder,FloatTitle:FloatTitle,CursorLine:Visual,Search:IncSearch`.
- **D-203:** D-202 applies to the main `Popup`, password `Input`, plain text `menu.input` fields, `menu.select` type/mode/service dropdowns, and the multiline descriptor popup opened from the wizard. The implementation may add an optional `winhighlight` option to `lua/dbee/ui/drawer/menu.lua`, but wizard callers must explicitly pass the locked mapping so unrelated drawer popups do not become an accidental Phase 13 redesign.
- **D-204:** Wizard behavior is otherwise preserved. Field order, mode flow, validation, transient ping, FileSource persistence, raw compatibility behavior, password masking, and Phase 8 D-89..D-106 contracts remain unchanged.
- **D-205:** Wizard visual tests must prove render-state rather than only checking that the wizard opens. Minimum gate: a headless assertion that the relevant Input/Select/Popup windows contain the locked `winhighlight` mapping and typed text remains present in the buffer. If a screenshot harness is practical, include a screenshot check, but absence of screenshots must not block if render-state assertions are deterministic.
- **D-206:** Colorscheme coverage for D-205 includes one bright/default baseline and one dark collision baseline. The dark baseline may be a synthetic headless colorscheme that deliberately makes `Normal` unreadable on floats; if `tokyonight` or `gruvbox-dark` is already available in the test environment, use one as an additional reference without adding a new plugin dependency just for Phase 13.

### Drawer Filter Regression
- **D-207:** Phase 4 DRAW-01 filter-exit behavior remains locked: submit captures selected node ID/path, clears filter, restores the pre-filter rendered tree, restores expansion/cursor state, then refocuses by ID or nearest restored ancestor. Escape/close restores the snapshot without accepting. Phase 13 must not weaken this contract.
- **D-208:** Phase 6 D-38 zero-RPC typing remains locked. `/` and filter `on_change` must never warm structure cache, call `connection_get_structure_async()`, call `connection_get_columns()`, or rebuild from live handler state per keystroke.
- **D-209:** Filter start must operate on whatever is currently visible in the drawer. If `drawer_model.build_search_model()` reports `ready_connections == 0` but the current rendered tree contains visible connection rows, `capture_filter_snapshot()` must still open filter mode using a visible-row search model instead of warning `No cached connections available for filter`.
- **D-210:** Connection-row matching is case-insensitive substring matching, not prefix-only matching, to preserve the existing Phase 4 string-find behavior. Connection rows match on raw connection name, displayed connection row text, connection ID, source name/source ID, and any currently rendered source suffix/badge text.
- **D-211:** Structure-row matching remains the existing cached-structure behavior for schemas/tables/views/procedures/functions, with existing searchable-type boundaries preserved unless required to include visible connection rows. Columns stay out of DRAW-01 search unless a prior locked contract is explicitly changed in a future phase.
- **D-212:** Mixed drawer state must filter both visible connection rows and visible cached structure rows. Example: if one connection is expanded and cached while another remains a collapsed connection row, `/` searches the expanded cached subtree plus the collapsed connection row, without forcing cold structure loads for the collapsed connection.
- **D-213:** Filter snapshot/restore must be based on the pre-filter rendered tree. Fallback visible-row search may reuse `snapshot_rendered_tree()` / `clone_rendered_snapshot()` / `snapshot_to_tree_nodes()` style data, but it must preserve node IDs and action metadata enough for submit-to-restore/refocus to behave like the existing cached-structure path.
- **D-214:** The coverage label may change from `N of M connections cached` when visible-row fallback is active, but it must not imply full structure coverage. Acceptable copy is planner discretion, such as `visible rows` or `0 of M structures cached`.

### Cache Migration UX
- **D-215:** Phase 13 introduces a schema-cache JSON version field. The current written schema-index cache version is `2`, stored as `version = 2` next to `conn_id`, `schemas`, and `tables`.
- **D-216:** `SchemaCache:load_from_disk()` treats missing `version` as legacy v1 format. Missing-version files are a legitimate upgrade path, not corruption. They must not emit WARN-level `corrupt cache` notifications.
- **D-217:** For missing-version v1 cache files, Phase 13 uses silent migration recovery: log at debug or internal-test-observable level, delete the old schema-index file, and return `false` so the existing structure refresh path regenerates a versioned cache. If planning finds a trivial recoverable v1-to-v2 rewrite path, it may load-and-rewrite instead, but the user-facing lock is no WARN for recognizable old formats.
- **D-218:** True corruption still warns. Invalid JSON, current-version malformed fields, unrecognizable table/schema shapes, or column cache files with malformed column entries keep WARN-level diagnostics and safe removal where Phase 11 D-182 already allowed it.
- **D-219:** Future cache format changes must define explicit version handling. Known older versions may migrate or silently regenerate. Unsupported future versions or unrecognized shapes must fail safely without crashing LSP startup and should warn only when current code cannot truthfully treat the file as a known upgrade path.
- **D-220:** Phase 13 must preserve Phase 11 disk-cache safety boundaries: atomic writes, isolated test state, no access to the user's real Neovim state directory, and no completion-path disk pruning or synchronous heavy cache work.

### Test And Verification Gates
- **D-221:** Add Phase 13 headless tests for wizard highlight render-state, drawer connection-only-root filtering by name/source metadata, mixed visible-row plus cached-structure filtering, silent v1 cache migration, and true-corruption WARN behavior.
- **D-222:** Phase 4..11 smoke/perf/semantic evidence remains required. The Phase 13 plan must continue to run the existing drawer filter/perf suites, Phase 10 LSP perf scenarios, the 33 `LSP01_*` markers, the 18 cleanup checks, the 3 compute-only checks, the 7+5+3 LSP11 family checks, and the three LSP semantic checks: `check_lsp_alias_completion.lua`, `check_lsp_schema_alias_completion.lua`, and `check_lsp_alias_rebinding.lua`.
- **D-223:** New tests must avoid live database dependencies. Use existing headless fakes/stubs, synthetic colorscheme state, isolated `XDG_STATE_HOME` or equivalent, and deterministic connection/cache fixtures.

### the agent's Discretion
- Exact helper names and whether the wizard highlight mapping is stored as a local constant in `connection_wizard/init.lua` or a small shared helper, as long as D-202/D-203 hold.
- Exact fallback search-model helper boundaries between `drawer/init.lua` and `drawer/model.lua`, as long as filter typing stays zero-RPC and snapshot restore remains Phase 4-compatible.
- Exact debug-log mechanism for recognized legacy cache migration, as long as tests can prove there is no WARN-level user notification for missing-version v1 files.
- Exact wording of filter coverage labels and cache migration debug messages.

</decisions>

<specifics>
## Specific Ideas

- The wizard regression reproduces as cursor movement with invisible typed text in the Name field on Naveen's daily dark colorscheme.
- Drawer filter should feel like normal drawer search: `/` searches the thing the user can see right now. On a cold connection-only drawer, that means connection rows; on expanded cached structure, that means the existing structure corpus; on mixed state, both.
- Cache migration warning copy is the UX failure, not recovery correctness. Naveen confirmed cache regeneration works and LSP completion works after the warning.

</specifics>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Milestone And Backlog
- `.planning/milestones/v1.3-roadmap.md` — locked v1.3 phase shape, Phase 13 success criteria, D-198 start, and Phase 14/15/16 scope boundaries.
- `known-issues.md` — v1.3 backlog items #1, #2, and #3 plus explicit v1.4 deferrals.
- `.planning/REQUIREMENTS.md` — `DBEE-UX-01` requirement and Phase 13 traceability.
- `.planning/STATE.md` — current milestone state and Phase 13 readiness.

### Locked Prior Decisions
- `.planning/phases/04-drawer-navigation/04-CONTEXT.md` — DRAW-01 filter start, zero-RPC typing, submit/escape restore, and partial-corpus behavior.
- `.planning/phases/06-structure-laziness-notes-picker/06-CONTEXT.md` — D-30..D-63 structure cache, D-38 zero-RPC filter guarantee, and snapshot/cache boundaries.
- `.planning/phases/07-connection-only-drawer/07-CONTEXT.md` — D-64..D-88 connection-only root, source metadata, drawer mappings, handler invalidation, single-flight, and bootstrap contracts.
- `.planning/phases/08-type-aware-connection-wizard/08-CONTEXT.md` — D-89..D-106 compound wizard, transient ping, FileSource atomic write, and wizard metadata contracts.
- `.planning/phases/10-lsp-optimization/10-CONTEXT.md` — D-119..D-149 LSP perf harness contracts.
- `.planning/phases/11-lsp-optimization-correctness/11-CONTEXT.md` — D-150..D-197 async completion, schema cache indexes/LRU, diagnostics, disk cache writes, and corrupt-cache recovery contracts.

### Production Code
- `lua/dbee/ui/connection_wizard/init.lua` — Phase 8 wizard implementation, `Popup`, password `Input`, type/mode/service selects, multiline popup, and field editing.
- `lua/dbee/ui/drawer/menu.lua` — shared `nui.menu` / `nui.input` helper used by wizard selects/inputs and drawer filter prompt.
- `lua/dbee/ui/drawer/init.lua` — filter session lifecycle, snapshot capture, `apply_filter()`, submit/close restore behavior, and drawer action mappings.
- `lua/dbee/ui/drawer/model.lua` — current search model and connection coverage logic that only includes cached structure roots.
- `lua/dbee/ui/drawer/convert.lua` — connection display names, source metadata suffix, node IDs, and structure node materialization.
- `lua/dbee/lsp/schema_cache.lua` — `SchemaCache:load_from_disk()`, `save_to_disk()`, `_normalize_schema_index()`, `_remove_corrupt_file()`, and atomic cache write helpers.

### Headless Tests
- `ci/headless/check_connection_wizard.lua` — existing wizard regression harness to extend for highlight render-state.
- `ci/headless/check_drawer_filter.lua` — existing DRAW-01 filter semantics harness to extend for connection-only root and mixed visible-row filtering.
- `ci/headless/check_drawer_perf.lua` — existing drawer perf/filter evidence that must not regress.
- `ci/headless/check_lsp_disk_cache_safety.lua` — existing disk cache WARN/recovery harness to extend for silent legacy migration.
- `ci/headless/check_lsp_alias_completion.lua`, `ci/headless/check_lsp_schema_alias_completion.lua`, `ci/headless/check_lsp_alias_rebinding.lua` — LSP semantic checks that must continue to pass.
- `ci/headless/check_lsp_perf.lua` and `ci/headless/lsp_perf_thresholds.lua` — Phase 10 perf evidence and threshold source of truth.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `lua/dbee/ui/connection_wizard/init.lua`: `popup_options()` builds the main wizard popup, `open_password_input()` builds the password `Input`, `Wizard:edit_field()` routes select/password/multiline/plain fields, and `Wizard:edit_type()` / `Wizard:edit_mode()` use `menu.select()`.
- `lua/dbee/ui/drawer/menu.lua`: `M.select()`, `M.input()`, and `M.filter()` already centralize popup options where optional `winhighlight` can be threaded without rewriting the wizard.
- `lua/dbee/ui/drawer/init.lua`: filter already has session IDs, snapshot restore, stale scheduled callback guards, submit/close behavior, and zero-RPC typing comments that Phase 13 should preserve.
- `lua/dbee/ui/drawer/model.lua`: `build_search_model()` currently uses cached structure roots only and returns `ready_connections`; this is the likely source of the connection-only root regression.
- `lua/dbee/lsp/schema_cache.lua`: `_normalize_schema_index()` already distinguishes valid schema-index shapes from malformed shapes, and `check_lsp_disk_cache_safety.lua` already captures WARN notifications.

### Established Patterns
- Drawer filter uses case-insensitive substring matching through `string.find(..., 1, true)`, so Phase 13 connection-row search should use the same matching semantics.
- Existing filter tests stub `menu.filter()` and inspect session behavior, which is a good fit for cold-root and mixed-row tests without real UI dependencies.
- Phase 11 cache safety tests isolate state and monkey-patch `vim.notify`; Phase 13 cache migration tests should extend that pattern rather than touching real user cache files.

### Integration Points
- Wizard highlight fix touches `connection_wizard/init.lua` and may add optional plumbing to `drawer/menu.lua`.
- Drawer filter fix likely touches `drawer/model.lua` plus `drawer/init.lua:capture_filter_snapshot()` and may need test fixture updates in `check_drawer_filter.lua`.
- Cache migration fix touches `schema_cache.lua:save_to_disk()` and `schema_cache.lua:load_from_disk()` plus `check_lsp_disk_cache_safety.lua`.

</code_context>

<deferred>
## Deferred Ideas

- Schema allowlist, schema discovery wizard step, schemas-only root fetch, and per-schema table-list lazy loading — Phase 14.
- Case-colliding schema lookup residual, targeted global-index representative map, conditional source badges, cold drawer orientation, and loading timeout/cancel UX — Phase 15.
- LSP `completionItem/resolve`, hover, schema refresh/reload code actions, and document/workspace symbols — conditional Phase 16.
- Semantic tokens, inlay hints, `vim.lsp.config()` migration, multi-client LSP architecture, pre-existing `a and nil or b` cleanup, and four legacy headless failures — out of v1.3 Phase 13 scope.

</deferred>

---

*Phase: 13-ux-regression-batch*
*Context gathered: 2026-04-29*
