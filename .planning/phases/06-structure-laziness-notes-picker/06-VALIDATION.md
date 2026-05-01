---
phase: 06
slug: structure-laziness-notes-picker
status: draft
nyquist_compliant: true
wave_0_complete: false
created: 2026-04-27
---

# Phase 06 - Validation Strategy

> Per-phase validation contract for the further-narrowed `STRUCT-01` plus unchanged `NOTES-01` scope.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | headless Neovim Lua scripts |
| **Config file** | `ci/headless/check_*.lua` |
| **Quick run command** | `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_<test>.lua"` |
| **Full suite command** | `sh -c 'set -e; for f in ci/headless/check_structure_lazy.lua ci/headless/check_notes_picker.lua; do out=$(nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile $f" 2>&1); printf "%s\n" "$out"; printf "%s\n" "$out" | grep -E "^[A-Z0-9_]+_ALL_PASS=true$"; ! printf "%s\n" "$out" | grep -E "FAIL=|Lua error|Traceback"; done'` |
| **Estimated runtime** | under 10s for the two new Phase 6 suites once added |

---

## Sampling Rate

- **After every task commit:** run the plan-local script for the touched feature
- **After every plan wave:** run the full headless suite
- **Before `/gsd:verify-work`:** both new Phase 6 scripts must be green and manual live checks below must be recorded in the phase summaries
- **Max feedback latency:** best-effort under 5s for individual Phase 6 scripts

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 06-01-01 | 01 | 1 | STRUCT-01 | grep/structure | `grep -n "DbeeConnectionGetColumnsAsync\|ConnectionGetColumnsAsync\|materialization" dbee/endpoints.go dbee/handler/handler.go lua/dbee/api/__register.lua lua/dbee/handler/init.lua lua/dbee/ui/drawer/convert.lua && grep -n "structure_loaded\|structure_children_loaded\|branch_id\|root_epoch\|caller_token\|kind" dbee/handler/event_bus.go lua/dbee/doc.lua && sh -c "cd dbee && go run . -manifest ../lua/dbee/api/__register.lua && git diff --exit-code ../lua/dbee/api/__register.lua"` | ❌ W0 | ⬜ pending |
| 06-01-02 | 01 | 1 | STRUCT-01 | grep/structure | `grep -n "action = \"refresh\"\|manually refresh drawer" lua/dbee/config.lua && grep -n "_struct_cache\|loaded_lazy_ids\|on_structure_loaded\|on_structure_children_loaded\|root_gen\|root_applied\|root_epoch\|request_gen\|applied_gen\|loading\|cached_search_model\|error\|build_tree_from_struct_cache\|select a connection row to reload" lua/dbee/ui/drawer/init.lua lua/dbee/ui/drawer/model.lua && grep -n "__load_more__\|tree:add_node\|tree:remove_node\|tree:set_nodes\|Load more\|loading\.\.\.\|connection_get_columns_async\|built_count\|render_limit\|structure_load_more\|structure_node_id" lua/dbee/ui/drawer/init.lua lua/dbee/ui/drawer/convert.lua && ! grep -n "self\\.structure_cache\|self\\.loaded_lazy_ids\|self\\.structure_request_gen\|self\\.structure_applied_gen" lua/dbee/ui/drawer/init.lua && grep -n "build_tree_from_struct_cache\|build_search_model" lua/dbee/ui/drawer/model.lua` | ❌ W0 | ⬜ pending |
| 06-01-03 | 01 | 1 | STRUCT-01 | headless + CI wiring | `sh -c "cd dbee && go run . -manifest ../lua/dbee/api/__register.lua && git diff --exit-code ../lua/dbee/api/__register.lua" && sh -c 'out=$(nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_structure_lazy.lua" 2>&1); printf "%s\n" "$out" | grep "^STRUCT01_ALL_PASS=true$" && printf "%s\n" "$out" | grep "^STRUCT01_ROOT_LAZY_OK=true$" && printf "%s\n" "$out" | grep "^STRUCT01_CHILD_ASYNC_OK=true$" && printf "%s\n" "$out" | grep "^STRUCT01_STALE_GUARD_OK=true$" && printf "%s\n" "$out" | grep "^STRUCT01_ROOT_EPOCH_OK=true$" && printf "%s\n" "$out" | grep "^STRUCT01_FULLTREE_EPOCH_OK=true$" && printf "%s\n" "$out" | grep "^STRUCT01_ERROR_CACHE_OK=true$" && printf "%s\n" "$out" | grep "^STRUCT01_PRESENTATION_REFRESH_OK=true$" && printf "%s\n" "$out" | grep "^STRUCT01_REBUILD_FROM_CACHE_OK=true$" && printf "%s\n" "$out" | grep "^STRUCT01_LOAD_MORE_OK=true$" && printf "%s\n" "$out" | grep "^STRUCT01_LOAD_MORE_BUILD_BOUND_OK=true$" && printf "%s\n" "$out" | grep "^STRUCT01_PARTIAL_MUTATION_OK=true$" && printf "%s\n" "$out" | grep "^STRUCT01_ROOT_PARTIAL_MUTATION_OK=true$" && printf "%s\n" "$out" | grep "^STRUCT01_CHILD_EVENT_WIRED_OK=true$" && printf "%s\n" "$out" | grep "^STRUCT01_BRANCH_DEDUPE_OK=true$" && printf "%s\n" "$out" | grep "^STRUCT01_MANUAL_RELOAD_OK=true$" && printf "%s\n" "$out" | grep "^STRUCT01_MANUAL_R_TARGET_OK=true$" && printf "%s\n" "$out" | grep "^STRUCT01_RELOAD_ZERO_REPLAY_OK=true$" && printf "%s\n" "$out" | grep "^STRUCT01_RENDER_SNAPSHOT_INVALIDATION_OK=true$" && printf "%s\n" "$out" | grep "^STRUCT01_FILTER_FREEZE_OK=true$" && printf "%s\n" "$out" | grep "^STRUCT01_REAL_RENDER_PATH_OK=true$" && printf "%s\n" "$out" | grep "^STRUCT01_FILTER_ZERO_RPC_OK=true$" && printf "%s\n" "$out" | grep "^STRUCT01_FULLTREE_CONTRACT_OK=true$" && ! printf "%s\n" "$out" | grep -E "FAIL=|Lua error|Traceback" && grep -q "check_structure_lazy.lua" .github/workflows/test.yml'` | ❌ W0 | ⬜ pending |
| 06-02-01 | 02 | 2 | NOTES-01 | grep/structure | `grep -n "editor_get_note_picker_sections\|editor_get_all_notes" lua/dbee/api/ui.lua && grep -n "Global notes\|Local notes\|\[global\]\|\[local:\|not item\|kind ~= \\\"note\\\"\|not item.note_id\|Select a note row\|picker:close" lua/dbee.lua && grep -n "editor_set_current_note" lua/dbee.lua lua/dbee/api/ui.lua` | ❌ W0 | ⬜ pending |
| 06-02-02 | 02 | 2 | NOTES-01 | headless + CI wiring | `sh -c 'out=$(nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_notes_picker.lua" 2>&1); printf "%s\n" "$out" | grep "^NOTES01_ALL_PASS=true$" && printf "%s\n" "$out" | grep "^NOTES01_SECTION_ORDER_OK=true$" && printf "%s\n" "$out" | grep "^NOTES01_EMPTY_STATE_OK=true$" && printf "%s\n" "$out" | grep "^NOTES01_TAGS_OK=true$" && printf "%s\n" "$out" | grep "^NOTES01_HEADER_GUARD_OK=true$" && printf "%s\n" "$out" | grep "^NOTES01_LOCAL_ONLY_OK=true$" && printf "%s\n" "$out" | grep "^NOTES01_GLOBAL_ONLY_OK=true$" && printf "%s\n" "$out" | grep "^NOTES01_FLAT_HELPER_COMPAT_OK=true$" && printf "%s\n" "$out" | grep "^NOTES01_SNAPSHOT_OK=true$" && ! printf "%s\n" "$out" | grep -E "FAIL=|Lua error|Traceback" && grep -q "check_notes_picker.lua" .github/workflows/test.yml'` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `ci/headless/check_structure_lazy.lua` - structure-lazy, table/view async child loading with preserved `materialization`, explicit root/branch error caching, and bounded branch materialization coverage
- [ ] `ci/headless/check_notes_picker.lua` - notes section ordering, empty states, and guarded single-picker coverage

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Large-schema root payload delivery on a real adapter | STRUCT-01 | Headless stubs cannot fully prove live transport timing or perceived UI feel on real Oracle/Postgres schemas | Open a connection with a large schema, expand connection -> schema -> table, and record that the drawer shows placeholder rows immediately and that the authoritative full-tree root payload either arrives within the 5s bound or is recorded as the D-55 legacy slow-path caveat. Do not treat this row as proof that end-to-end expand paint is fully non-blocking while `connection_list_databases()` remains synchronous. |
| `Load more...` cursor and expansion feel | STRUCT-01 | Headless can assert data/state, not actual interactive feel in Nui | On a branch with more than 1000 children, activate `Load more...` and confirm the next chunk appends in-place without collapsing the branch or jumping to unrelated nodes. |
| Drawer reload scoping | STRUCT-01 | Headless stubs cannot fully prove the live mapping and cursor-targeted reload feel | Trigger the drawer reload action on a connection row, a descendant structure row, a `database_switch` row, and a source/note/help row; confirm connection/descendant/`database_switch` rows reload only the owning connection while non-connection rows warn and no-op. |
| Current Snacks build renders pseudo-header and hint rows clearly | NOTES-01 | Visual clarity is UI-provider-specific | Open `<leader>ef` with globals and locals present, then again with globals-only/current-connection-empty state, and confirm the section headers and local-empty hint read clearly without looking like selectable note rows. |
| One-picker interaction remains intact | NOTES-01 | Headless stubs cannot fully validate provider UX affordances | Confirm `<leader>ef` never chains into a second prompt, local-only state omits an empty Global section, and selecting a note still opens it directly in the editor. |

---

## Validation Sign-Off

- [ ] All tasks have an automated verify command
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers both new headless scripts
- [ ] `06-01-PLAN.md` maps cleanly to D-30 through D-39, D-46 through D-47, D-49 through D-50, D-52, D-55 through D-56, and D-60 through D-63 in `06-CONTEXT.md`
- [ ] `06-02-PLAN.md` maps cleanly to D-40 through D-45 in `06-CONTEXT.md`
- [ ] `STRUCT01_ALL_PASS=true` emitted by `check_structure_lazy.lua`
- [ ] `STRUCT01_ROOT_LAZY_OK=true` proves connection expansion stays lazy and root warmup does not duplicate while cache is live
- [ ] `STRUCT01_CHILD_ASYNC_OK=true` proves both table and view expansion use the additive async child path, preserve `materialization = struct.type`, and never fall back to synchronous `connection_get_columns()`
- [ ] `STRUCT01_STALE_GUARD_OK=true` proves branch payload application is fenced by request generation and `root_epoch`, and that non-drawer `structure_loaded` payloads cannot overwrite drawer root state
- [ ] `STRUCT01_ROOT_EPOCH_OK=true` proves late child payloads after manual `R` or `database_selected` are dropped
- [ ] `STRUCT01_FULLTREE_EPOCH_OK=true` proves late drawer-owned full-tree `structure_loaded` payloads after a same-connection clear are dropped before mutating root cache
- [ ] `STRUCT01_ERROR_CACHE_OK=true` proves root and branch errors stay stored in `_struct_cache` and survive unrelated rerender until a fresh authoritative success replaces them
- [ ] `STRUCT01_PRESENTATION_REFRESH_OK=true` proves the Phase 6-owned presentation refresh paths (`DrawerUI:refresh()`, `show()`, `on_current_note_changed()`, and note-buffer `BufModifiedSet`) are cache-preserving and replay zero child RPCs across repeated unrelated redraws; `current_connection_changed` and action callback refreshes are checked only for non-regression, not for this contract
- [ ] `STRUCT01_REBUILD_FROM_CACHE_OK=true` proves full redraws rebuild from `build_tree_from_struct_cache(...)` and preserve branch-local loaded children / error / sentinel state
- [ ] `STRUCT01_LOAD_MORE_OK=true` proves oversized branches page in-place through a sentinel row, removing and re-adding the deterministic sentinel without duplicates or stranded rows
- [ ] `STRUCT01_LOAD_MORE_BUILD_BOUND_OK=true` proves initial expand builds at most the first chunk of nodes and later sentinel activation builds only the next chunk
- [ ] `STRUCT01_PARTIAL_MUTATION_OK=true` proves child completion and `Load more...` patch only the targeted branch rather than globally refreshing the drawer
- [ ] `STRUCT01_ROOT_PARTIAL_MUTATION_OK=true` proves root success/error mutates only the affected connection subtree, does not call global `refresh()`, and does not call sibling `connection_list_databases()`
- [ ] `STRUCT01_CHILD_EVENT_WIRED_OK=true` proves the manifest and drawer listener are wired for additive child events
- [ ] `STRUCT01_BRANCH_DEDUPE_OK=true` proves rapid repeat expand while a branch is already loading does not dispatch duplicate child RPCs
- [ ] `STRUCT01_MANUAL_RELOAD_OK=true` proves manual `R` reload clears only the targeted connection, clears saved table/view expansion IDs, runs cleanup before refetch, bumps `root_epoch`, and drops stale pre-reload payloads
- [ ] `STRUCT01_MANUAL_R_TARGET_OK=true` proves D-63 nearest-ancestor resolution: connection row -> that connection, descendant structure row or `database_switch` row -> nearest ancestor connection, source/note/help row -> warn + no-op
- [ ] `STRUCT01_RELOAD_ZERO_REPLAY_OK=true` proves manual `R` after previously expanded table/view nodes triggers zero replay child-fetch RPCs before the fresh root load settles
- [ ] `STRUCT01_RENDER_SNAPSHOT_INVALIDATION_OK=true` proves branch-local child apply/error/load-more mutations invalidate rendered snapshots before later filter restore/restart
- [ ] `STRUCT01_FILTER_FREEZE_OK=true` proves active filter views stay frozen during child completion / `Load more...`, underlying `_struct_cache` still updates, filter close restores the Phase 4 D-31 pre-filter snapshot exactly rather than rebuilding from latest cache, filter close itself triggers zero RPCs and no tree mutations beyond that snapshot restore, and a separate post-filter refresh or re-expand is what reveals deferred branch mutations
- [ ] `STRUCT01_REAL_RENDER_PATH_OK=true` proves replay/rebuild-sensitive assertions use the real `DrawerUI` refresh/restore path and real encoded branch IDs from `convert.structure_node_id(...)`
- [ ] `STRUCT01_FILTER_ZERO_RPC_OK=true` proves DRAW-01 zero-RPC typing survives the structure-lazy refactor and that Phase 6 column loads plus `Load more...` invalidate only `cached_render_snapshot`, not `cached_search_model`
- [ ] `STRUCT01_FULLTREE_CONTRACT_OK=true` proves `structure_loaded` remains the existing full-tree contract, existing one-arg `connection_get_structure_async(conn_id)` callers remain valid, and omitted legacy calls stay outside drawer-owned cache mutation
- [ ] Negative grep guard against `lua/dbee/ui/drawer/init.lua` proves legacy top-level drawer structure state (`self.structure_cache`, `self.loaded_lazy_ids`, `self.structure_request_gen`, `self.structure_applied_gen`) is gone in favor of `_struct_cache`
- [ ] Large-schema live validation either passes within the 5s root-delivery bound or is explicitly recorded as the D-55 caveat; no summary may claim root-payload-delivery success on adapters that stay on the legacy slow path or use that bound as proof that the remaining `connection_list_databases()` seam is solved
- [ ] `NOTES01_ALL_PASS=true` emitted by `check_notes_picker.lua`
- [ ] `NOTES01_SECTION_ORDER_OK=true` proves Global-first / Local-second ordering when both sections exist
- [ ] `NOTES01_EMPTY_STATE_OK=true` proves no-notes, no-current-connection, and local-empty behaviors are explicit and correct
- [ ] `NOTES01_TAGS_OK=true` proves note rows are tagged `[global]` or `[local: <conn_name>]`
- [ ] `NOTES01_HEADER_GUARD_OK=true` proves pseudo-header rows, hint rows, nil confirm payloads, and malformed note rows without `note_id` warn, stay open, and cannot open notes
- [ ] `NOTES01_LOCAL_ONLY_OK=true` proves local-only state omits the empty Global section
- [ ] `NOTES01_GLOBAL_ONLY_OK=true` proves no-current-connection state renders only the Global section
- [ ] `NOTES01_FLAT_HELPER_COMPAT_OK=true` proves the flat `editor_get_all_notes()` contract remains intact
- [ ] `NOTES01_SNAPSHOT_OK=true` proves `dbee.pick_notes()` builds one structured note snapshot per open from the public picker entrypoint after stubbing the layout-open guard, rather than refetching notes from callbacks
- [ ] `.github/workflows/test.yml` runs both new Phase 6 headless scripts
- [ ] Manual structure UX verification recorded in `06-01-SUMMARY.md`
- [ ] Manual notes-picker UX verification recorded in `06-02-SUMMARY.md`

**Approval:** pending
