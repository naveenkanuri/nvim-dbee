---
phase: 07
slug: connection-only-drawer
status: draft
nyquist_compliant: true
wave_0_complete: false
created: 2026-04-28
---

# Phase 07 - Validation Strategy

> Per-phase validation contract for `DCFG-01`: connection-only drawer plus the deferred lifecycle ownership absorbed from Phase 6.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | headless Neovim Lua scripts + targeted grep/manifest checks |
| **Config file** | `ci/headless/check_connection_lifecycle.lua`, `ci/headless/check_connection_coordination.lua` |
| **Quick run command** | `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_connection_<suite>.lua"` |
| **Full suite command** | `sh -c 'set -e; for f in ci/headless/check_structure_lazy.lua ci/headless/check_notes_picker.lua ci/headless/check_drawer_filter.lua ci/headless/check_connection_lifecycle.lua ci/headless/check_connection_coordination.lua; do out=$(nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile $f" 2>&1); printf "%s\n" "$out"; ! printf "%s\n" "$out" | grep -E "FAIL=|Lua error|Traceback"; done'` |
| **Estimated runtime** | under 25s once all five suites exist |

---

## Sampling Rate

- **After every task commit:** run the plan-local verify block for the touched plan
- **After every wave:** run the relevant headless suite plus the Phase 6 regression suite(s) touched by the change
- **Before `/gsd:verify-work`:** both new Phase 7 suites and the existing Phase 6 suites must be green
- **Max feedback latency:** best-effort under 10s for individual Phase 7 scripts

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 07-01-01 | 01 | 1 | DCFG-01 | grep/structure | `grep -n "_source_reload_silent\|connection_invalidated\|source_reload_failed\|retired_conn_ids\|new_conn_ids\|current_conn_id_before\|current_conn_id_after\|silent\|authoritative_root_epoch" lua/dbee/handler/init.lua lua/dbee/doc.lua && grep -n "function M.trigger\|function M.register" lua/dbee/handler/__events.lua` | ❌ W0 | ⬜ pending |
| 07-01-02 | 01 | 1 | DCFG-01 | grep/structure | `grep -n "get_connection_state_snapshot\|get_sources\|source_get_connections\|get_current_connection\|snapshot_authoritative_epoch" lua/dbee/handler/init.lua lua/dbee/doc.lua` | ❌ W0 | ⬜ pending |
| 07-02-01 | 02 | 2 | DCFG-01 | grep/manifest | `grep -n "DbeeConnectionTest" dbee/endpoints.go dbee/handler/handler.go lua/dbee/api/__register.lua lua/dbee/handler/init.lua lua/dbee/doc.lua && sh -c "cd dbee && go run . -manifest ../lua/dbee/api/__register.lua && git diff --exit-code -- ../lua/dbee/api/__register.lua" && grep -n "decorate_connection_node\|source_meta\|build_tree_from_struct_cache" lua/dbee/ui/drawer/convert.lua lua/dbee/ui/drawer/model.lua && grep -n "{ key = \"a\"\|{ key = \"e\"\|{ key = \"dd\"\|{ key = \"t\"\|{ key = \"<C-CR>\"\|{ key = \"R\"\|{ key = \"/\"\|{ key = \"<CR>\"" lua/dbee/config.lua` | ❌ W0 | ⬜ pending |
| 07-02-02 | 02 | 2 | DCFG-01 | grep/structure | `grep -n "close_only\|refresh_after_action\|perform_action" lua/dbee/ui/drawer/init.lua lua/dbee/doc.lua && grep -n "on_current_connection_changed\|focus_pane\|ensure_drawer_visible" lua/dbee/ui/drawer/init.lua lua/dbee.lua && grep -n "source file\|Edit source\|Select a source" lua/dbee/ui/drawer/init.lua lua/dbee/ui/drawer/convert.lua lua/dbee.lua lua/dbee/doc.lua` | ❌ W0 | ⬜ pending |
| 07-03-01 | 03 | 3 | DCFG-01 | grep/structure | `grep -n "singleflight\|authoritative_root_epoch\|snapshot_authoritative_epoch\|waiter\|superseded\|connection_get_structure_singleflight" lua/dbee/handler/init.lua lua/dbee/doc.lua && grep -n "get_connection_state_snapshot\|register_event_listener\|connection_get_structure_async\|_try_start" lua/dbee/lsp/init.lua lua/dbee/ui/drawer/init.lua` | ❌ W0 | ⬜ pending |
| 07-03-02 | 03 | 3 | DCFG-01 | grep/structure | `grep -n "connection_invalidated\|coalesce\|rewarm\|visible\|authoritative_root_epoch\|silent\|superseded" lua/dbee/handler/init.lua lua/dbee/ui/drawer/init.lua lua/dbee/lsp/init.lua && grep -n "sticky\|ambiguous\|current_conn_id_before\|current_conn_id_after" lua/dbee/handler/init.lua lua/dbee/reconnect.lua lua/dbee/doc.lua` | ❌ W0 | ⬜ pending |
| 07-03-03 | 03 | 3 | DCFG-01 | grep/manifest | `grep -n "DbeeConnectionListDatabasesAsync" dbee/endpoints.go dbee/handler/handler.go lua/dbee/api/__register.lua lua/dbee/handler/init.lua lua/dbee/doc.lua && sh -c "cd dbee && go run . -manifest ../lua/dbee/api/__register.lua && git diff --exit-code -- ../lua/dbee/api/__register.lua" && grep -n "connection_databases_loaded\|root_epoch" dbee/handler/event_bus.go lua/dbee/ui/drawer/init.lua && grep -n "connection_rewritten\|register_connection_rewritten_listener\|database_switch\|loaded_lazy_ids" lua/dbee/reconnect.lua lua/dbee/ui/drawer/init.lua lua/dbee/ui/drawer/convert.lua` | ❌ W0 | ⬜ pending |
| 07-04-01 | 04 | 4 | DCFG-01 | headless | `sh -c 'out=$(nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_connection_lifecycle.lua" 2>&1); printf "%s\n" "$out" | grep "^DCFG01_DRAWER_LIFECYCLE_ALL_PASS=true$" && printf "%s\n" "$out" | grep "^DCFG01_INVALIDATION_PAYLOAD_OK=true$" && printf "%s\n" "$out" | grep "^DCFG01_SILENT_RELOAD_OK=true$" && printf "%s\n" "$out" | grep "^DCFG01_FAILURE_EVENT_OK=true$" && printf "%s\n" "$out" | grep "^DCFG01_PARTIAL_FAILURE_OK=true$" && printf "%s\n" "$out" | grep "^DCFG01_BOOTSTRAP_SNAPSHOT_OK=true$" && printf "%s\n" "$out" | grep "^DCFG01_CONNECTION_ONLY_ROOT_OK=true$" && printf "%s\n" "$out" | grep "^DCFG01_ACTION_TARGETING_OK=true$" && printf "%s\n" "$out" | grep "^DCFG01_SOURCE_EDIT_REACHABLE_OK=true$" && printf "%s\n" "$out" | grep "^DCFG01_TEST_FAIL_CLOSED_OK=true$" && printf "%s\n" "$out" | grep "^DCFG01_REFRESH_MODE_OK=true$" && printf "%s\n" "$out" | grep "^DCFG01_CURRENT_CONN_VISUAL_OK=true$" && printf "%s\n" "$out" | grep "^DCFG01_PHASE6_FILTER_REGRESSION_OK=true$" && ! printf "%s\n" "$out" | grep -E "FAIL=|Lua error|Traceback"'` | ❌ W0 | ⬜ pending |
| 07-04-02 | 04 | 4 | DCFG-01 | headless + CI wiring | `sh -c 'out=$(nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_connection_coordination.lua" 2>&1); printf "%s\n" "$out" | grep "^DCFG01_COORDINATION_ALL_PASS=true$" && printf "%s\n" "$out" | grep "^DCFG01_SINGLE_FLIGHT_OK=true$" && printf "%s\n" "$out" | grep "^DCFG01_WAITER_FANOUT_OK=true$" && printf "%s\n" "$out" | grep "^DCFG01_BOOTSTRAP_REPLAY_OK=true$" && printf "%s\n" "$out" | grep "^LIFECYCLE01_BOOTSTRAP_POST_SNAPSHOT_OK=true$" && printf "%s\n" "$out" | grep "^LIFECYCLE01_BOOTSTRAP_TAIL_OK=true$" && printf "%s\n" "$out" | grep "^LIFECYCLE01_BOOTSTRAP_OVERFLOW_OK=true$" && printf "%s\n" "$out" | grep "^LIFECYCLE01_BOOTSTRAP_OVERFLOW_STORM_OK=true$" && printf "%s\n" "$out" | grep "^DCFG01_SUPERSEDED_FLIGHT_OK=true$" && printf "%s\n" "$out" | grep "^DCFG01_WAITER_CLEANUP_OK=true$" && printf "%s\n" "$out" | grep "^DCFG01_BACKPRESSURE_OK=true$" && printf "%s\n" "$out" | grep "^DCFG01_STICKY_SELECTION_OK=true$" && printf "%s\n" "$out" | grep "^DCFG01_RECONNECT_CONTINUITY_OK=true$" && printf "%s\n" "$out" | grep "^DCFG01_DATABASE_SWITCH_ASYNC_OK=true$" && printf "%s\n" "$out" | grep "^DCFG01_DATABASE_SWITCH_STALE_DROP_OK=true$" && printf "%s\n" "$out" | grep "^DCFG01_PHASE6_STRUCTURE_REGRESSION_OK=true$" && ! printf "%s\n" "$out" | grep -E "FAIL=|Lua error|Traceback" && grep -q "check_connection_lifecycle.lua" .github/workflows/test.yml && grep -q "check_connection_coordination.lua" .github/workflows/test.yml && grep -q "check_structure_lazy.lua" .github/workflows/test.yml && grep -q "check_notes_picker.lua" .github/workflows/test.yml && grep -q "check_drawer_filter.lua" .github/workflows/test.yml'` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `ci/headless/check_connection_lifecycle.lua` - lifecycle invalidation, connection-only drawer root, dispatcher ownership, fail-closed actions, and filter-restore regression
- [ ] `ci/headless/check_connection_coordination.lua` - root single-flight, invalidation backpressure, sticky selection, reconnect continuity, async `database_switch`, and Phase 6 structure regression guard
- [ ] `ci/headless/check_drawer_filter.lua` - retained Phase 4 D-31 regression guard in the full Phase 7 suite

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Connection-only drawer UX in default and minimal layouts | DCFG-01 | Headless can prove action routing and state, not actual pane feel | Open both default and minimal layouts, confirm the drawer shows only connections at the root, source metadata stays visible, and add/edit/delete/test/activate/reload actions remain usable without assuming a 4-pane layout. |
| Reconnect ID rewrite visible continuity | DCFG-01 | Headless can prove patch logic but not visual flash/no-flash feel | Trigger a manual reconnect that remaps `conn_id`, verify the connection row stays visually warm and the visible subtree patches in place without flashing a cold tree. |
| Async `database_switch` truthfulness on real adapters | DCFG-01 | Headless stubs cannot prove adapter-specific stall behavior | Expand a connection with database switching support and confirm the placeholder row appears immediately, the real database list patches in later, and any residual stall is recorded honestly if the adapter cannot behave meaningfully asynchronously. |
| Sticky logical-connection retention on ambiguous reloads | DCFG-01 | User-facing warning quality and ambiguity feel are hard to assess headlessly | Reload or reconnect a source where old/new mapping is ambiguous and confirm the user sees a clear warning instead of silent selection drift to an unrelated survivor. |

---

## Validation Sign-Off

- [ ] All tasks have an automated verify command
- [ ] Sampling continuity: no two implementation plans land without a corresponding headless/CI proof plan
- [ ] Wave 0 includes both new Phase 7 suites
- [ ] `07-01-PLAN.md` maps to D-71 through D-73, D-79, D-83, and the snapshot half of D-85
- [ ] `07-02-PLAN.md` maps to D-65 through D-70, D-74, D-75, and D-82
- [ ] `07-03-PLAN.md` maps to D-76 through D-81 plus D-84 through D-88 while preserving Phase 6 D-46, D-50, D-56, and D-63
- [ ] `DCFG01_DRAWER_LIFECYCLE_ALL_PASS=true` emitted by `check_connection_lifecycle.lua`
- [ ] `DCFG01_INVALIDATION_PAYLOAD_OK=true` proves the D-71 payload shape
- [ ] `DCFG01_SILENT_RELOAD_OK=true` proves `_source_reload_silent` stays internal and public wrappers own emit
- [ ] `DCFG01_FAILURE_EVENT_OK=true` proves `source_reload_failed` is user-driven only
- [ ] `DCFG01_PARTIAL_FAILURE_OK=true` proves D-83 partial-failure ordering emits `connection_invalidated` before `source_reload_failed`
- [ ] `DCFG01_BOOTSTRAP_SNAPSHOT_OK=true` proves snapshot bootstrap exists and is side-effect free
- [ ] `DCFG01_CONNECTION_ONLY_ROOT_OK=true` proves the drawer root renders saved connections only with source metadata visible
- [ ] `DCFG01_ACTION_TARGETING_OK=true` proves `a`, `e`, `dd`, `t`, `<C-CR>`, and `R` target the correct rows and warn/no-op otherwise
- [ ] `DCFG01_SOURCE_EDIT_REACHABLE_OK=true` proves the secondary source-file edit path remains reachable from a connection row without reviving source rows in the tree
- [ ] `DCFG01_TEST_FAIL_CLOSED_OK=true` proves test failures preserve current connection and drawer state
- [ ] `DCFG01_REFRESH_MODE_OK=true` proves `close_only` vs `refresh_after_action` ownership
- [ ] `DCFG01_CURRENT_CONN_VISUAL_OK=true` proves drawer `current_connection_changed` is presentation-only
- [ ] `DCFG01_PHASE6_FILTER_REGRESSION_OK=true` proves D-31 snapshot restore still holds after the drawer rewrite
- [ ] `DCFG01_COORDINATION_ALL_PASS=true` emitted by `check_connection_coordination.lua`
- [ ] `DCFG01_SINGLE_FLIGHT_OK=true` proves same-key root warmups coalesce
- [ ] `DCFG01_WAITER_FANOUT_OK=true` proves drawer and LSP each receive the correct waiter-specific completion behavior
- [ ] `DCFG01_BOOTSTRAP_REPLAY_OK=true` proves D-85 replay ordering only applies invalidations newer than `snapshot_authoritative_epoch`
- [ ] `LIFECYCLE01_BOOTSTRAP_POST_SNAPSHOT_OK=true` proves events arriving after snapshot completion but before drain/live flip are still absorbed or drained with no silent loss
- [ ] `LIFECYCLE01_BOOTSTRAP_TAIL_OK=true` proves handler-owned promotion returns the undrained bootstrap tail and no event is stranded between the last ordinary drain read and live-mode entry
- [ ] `LIFECYCLE01_BOOTSTRAP_OVERFLOW_OK=true` proves a 65+ invalidation burst during bootstrap emits the warning, rolls immediately to a fresh bootstrap generation, requests a fresh snapshot, and applies every event fired during recovery either by snapshot absorption or generation replay with no silent loss
- [ ] `LIFECYCLE01_BOOTSTRAP_OVERFLOW_STORM_OK=true` proves four consecutive overflow bursts emit the defensive `bootstrap_overflow_storm` hard-error on the fourth overflow
- [ ] `DCFG01_SUPERSEDED_FLIGHT_OK=true` proves eventful invalidations supersede older same-connection flights with `{ error_kind = "superseded", new_epoch }`
- [ ] `DCFG01_WAITER_CLEANUP_OK=true` proves consumer teardown removes waiter slots from handler single-flight state
- [ ] `DCFG01_BACKPRESSURE_OK=true` proves invalidation bursts batch and rewarm only where D-78 allows
- [ ] `DCFG01_STICKY_SELECTION_OK=true` proves sticky logical-connection retention never auto-selects unrelated survivors
- [ ] `DCFG01_RECONNECT_CONTINUITY_OK=true` proves reconnect ID rewrite preserves visible drawer continuity without over-migrating stale branch state and keeps the authoritative epoch unchanged per D-86
- [ ] `DCFG01_DATABASE_SWITCH_ASYNC_OK=true` proves `database_switch` uses a placeholder-and-patch async flow
- [ ] `DCFG01_DATABASE_SWITCH_STALE_DROP_OK=true` proves stale `database_switch` payloads are dropped by `{ conn_id, request_id, root_epoch }` mismatch after placeholder clearing on manual `R`, `database_selected`, eventful source CRUD success, eventful source reload, and reconnect rewrite via same-epoch `conn_id` token handling
- [ ] `DCFG01_PHASE6_STRUCTURE_REGRESSION_OK=true` proves Phase 6 structure-lazy behavior remains green after Phase 7 coordination changes
- [ ] Bootstrap recovery proves no silent data loss across the full bootstrap window: pre-snapshot, post-snapshot/pre-drain, mid-drain, post-drain/pre-promotion-return, overflow recovery, and the handler-owned atomic promotion to live mode
- [ ] The bootstrap overflow path is observable through a warning log, and overflow storms surface a hard-error warning, so production debugging is possible when recovery fires
- [ ] Pending `database_switch` placeholder is cleared on every epoch-bumping authoritative invalidation path and resolved on reconnect rewrite through same-epoch `conn_id` token migration or mismatch
- [ ] Dead `database_switch` loading rows are never left visible after authoritative invalidation
- [ ] `sh -c "cd dbee && go run . -manifest ../lua/dbee/api/__register.lua && git diff --exit-code -- ../lua/dbee/api/__register.lua"` stays green for every Phase 7 task that adds a new RPC
- [ ] `.github/workflows/test.yml` runs both new Phase 7 suites and the existing Phase 6 suites
- [ ] Manual layout, reconnect-continuity, async-database-switch, and ambiguous-selection checks are recorded in the plan summaries

**Approval:** pending
