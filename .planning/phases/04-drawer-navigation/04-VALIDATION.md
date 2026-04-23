---
phase: 04
slug: drawer-navigation
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-17
---

# Phase 04 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | headless Neovim Lua scripts |
| **Config file** | `ci/headless/check_*.lua` |
| **Quick run command** | `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_<test>.lua"` |
| **Full suite command** | `sh -c 'set -e; for f in ci/headless/check_*.lua; do out=$(nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile $f" 2>&1); printf "%s\n" "$out"; printf "%s\n" "$out" | grep -E "^[A-Z0-9_]+_ALL_PASS=true$"; ! printf "%s\n" "$out" | grep -E "FAIL=|Lua error|Traceback"; done'` |
| **DRAW-01 smoke perf command** | `DRAW01_PERF_MODE=non-release-smoke nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_drawer_filter.lua"` |
| **Estimated runtime** | Phase 4 full suite exceeds 5s once DRAW-01 startup/perf/soak gates are included |

`ci/headless/check_drawer_filter.lua` currently emits `DRAW01_PERF_MODE=non-release-smoke` only. `.github/workflows/test.yml` keeps the pinned `nui.nvim` install as scaffolding for a future real-nui perf harness, but the current DRAW-01 landing does not claim release-grade headless perf evidence.

---

## Sampling Rate

- **After every task commit:** Run `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_<relevant>.lua"`
- **After every plan wave:** Run full suite
- **Before `/gsd:verify-work`:** Full suite must be green. DRAW-01 headless perf output is smoke-only in this landing; release-grade real-nui perf evidence is deferred, and live UI verification remains required.
- **Max feedback latency:** best-effort under 5s for non-perf checks; DRAW-01 perf gate is allowed to exceed this and remains blocking

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 04-01-01 | 01 | 1 | CLIP-02,NAV-02 | grep/structure | `grep -n "raw_name\|structure_node_id" lua/dbee/ui/drawer/convert.lua && grep -n "yank_name\|schema unavailable" lua/dbee/ui/drawer/init.lua && grep -n "focus_pane" lua/dbee/layouts/init.lua && grep -n "function dbee.focus_pane" lua/dbee.lua && grep -c "focus_editor" lua/dbee/config.lua && grep -c "focus_editor" lua/dbee/ui/editor/init.lua && grep -c "focus_editor" lua/dbee/ui/result/init.lua && grep -c "focus_editor" lua/dbee/ui/call_log.lua` | ❌ W0 | ⬜ pending |
| 04-01-02 | 01 | 1 | CLIP-02 | headless | `sh -c 'out=$(nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_drawer_yank.lua" 2>&1); printf "%s\n" "$out" | grep "^CLIP02_ALL_PASS=true$" && ! printf "%s\n" "$out" | grep -E "FAIL=|Lua error|Traceback"'` | ❌ W0 | ⬜ pending |
| 04-01-03 | 01 | 1 | NAV-02 | headless | `sh -c 'out=$(nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_pane_jump.lua" 2>&1); printf "%s\n" "$out" | grep "^NAV02_ALL_PASS=true$" && ! printf "%s\n" "$out" | grep -E "FAIL=|Lua error|Traceback"'` | ❌ W0 | ⬜ pending |
| 04-02-01 | 02 | 2 | DRAW-01 | grep/structure | `grep -n "function M.filter" lua/dbee/ui/drawer/menu.lua && grep -n "decorate_connection_node\|decorate_structure_node\|structure_node_id\|column_nodes\|INVARIANT: source_meta.id MUST equal source:name()\|INVARIANT: struct.type MUST be passed through as the materialization" lua/dbee/ui/drawer/convert.lua && grep -n "build_rendered_model\|build_search_model\|lazy_children MUST be nil when children is non-empty\|single canonical owner of handler-subtree action/lazy_children" lua/dbee/ui/drawer/model.lua && grep -n "_create_drawer_buffer\|snapshot_rendered_tree\|clone_rendered_snapshot\|capture_filter_snapshot\|cached_render_snapshot\|render_restore_snapshot\|restore_expansion_state\|interrupt_filter\|prepare_close\|rebuild_buffer\|begin_filter_session\|request_structure_reload\|on_structure_loaded\|on_database_selected\|database_selected\|structure_request_gen\|schedule_filter_apply\|cancel_pending_filter_apply\|active_filter_session_id\|next_filter_session_id\|loaded_lazy_ids\|cached_search_model\|refresh_filter_safe\|expand_node_filter_safe\|forwardable_mapping_key_for\|maybe_add_forwarded\|RESERVED_FILTER_KEYS\|normalize_mapping_lhs\|nvim_buf_is_valid" lua/dbee/ui/drawer/init.lua && grep -n "connection_get_structure_async\|request_id" lua/dbee/handler/init.lua dbee/endpoints.go dbee/handler/handler.go dbee/handler/event_bus.go && grep -n "function ui.drawer_prepare_close" lua/dbee/api/ui.lua && grep -n "drawer_prepare_close\|configure_drawer_window_cleanup\|WinClosed\|self.drawer_win = nil" lua/dbee/layouts/init.lua && grep -n 'action = "filter"' lua/dbee/config.lua && grep -n "check_drawer_yank.lua\|check_pane_jump.lua\|check_drawer_filter.lua\|Install nui.nvim\|rtp\\^=" .github/workflows/test.yml` | ❌ W0 | ⬜ pending |
| 04-02-02 | 02 | 2 | DRAW-01 | headless | `sh -c 'out=$(nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_drawer_filter.lua" 2>&1); printf "%s\n" "$out" | grep "^DRAW01_ALL_PASS=true$" && printf "%s\n" "$out" | grep "^DRAW01_PERF_MODE=non-release-smoke$" && ! printf "%s\n" "$out" | grep -E "FAIL=|Lua error|Traceback" && grep -q "Install nui.nvim" .github/workflows/test.yml && grep -q "rtp\\^=" .github/workflows/test.yml && grep -q "check_drawer_yank.lua" .github/workflows/test.yml && grep -q "check_pane_jump.lua" .github/workflows/test.yml && grep -q "check_drawer_filter.lua" .github/workflows/test.yml'` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `ci/headless/check_drawer_yank.lua` — stubs for CLIP-02
- [ ] `ci/headless/check_pane_jump.lua` — stubs for NAV-02
- [ ] `ci/headless/check_drawer_filter.lua` — stubs for DRAW-01

*Existing headless test infrastructure from Phases 1-3 covers framework setup.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Live filter visual update | DRAW-01 | NuiInput rendering requires live Neovim UI | Open drawer, press /, verify the prompt shows the ready-corpus coverage label, type filter text, and verify the tree updates in real-time |
| Pane focus visual feedback | NAV-02 | Window focus requires live Neovim UI | Press pane-jump keys, verify cursor moves to correct pane |
| Clipboard content | CLIP-02 | System clipboard requires display server | Yank node name, paste in editor, verify qualified format |
| Large-schema interactive feel | DRAW-01 | Headless automation cannot prove live interaction feel, and the current DRAW-01 harness is smoke-only rather than release-grade real-nui perf evidence | Open a large schema generated from the same locked corpus/query cohort defined in `check_drawer_filter.lua` (or, before that file exists, from the locked corpus/query cohort specified in `04-02-PLAN.md`), confirm `/` startup plus typing/cancel-restore/submit-restore stay responsive, confirm the prompt reports `N of M connections cached`, and record the live-UI result in `04-02-SUMMARY.md` |
| In-place DB switch invalidation | DRAW-01 | Same-connection database switching must invalidate ready corpus before refresh and next filter start | Use a multi-database connection, switch DB from the drawer, verify the tree settles on the selected database only once, confirm it does not flicker back to the pre-switch schema, then press `/` and confirm filter results come from the refreshed corpus rather than the pre-switch cache |
| Collapsed cached branch coverage | DRAW-01 | Search coverage depends on cached-vs-expanded tree state and must be checked in the real drawer | With a large cached schema, leave some connection/schema branches collapsed, press /, search for an object inside a collapsed cached branch, verify it still appears |
| Filter prompt interaction model | DRAW-01 | Prompt owns focus, so forwarded drawer actions must be proven in live UI too | While the filter prompt is mounted, verify INSERT mode keeps typing intact, `<Up>/<Down>/<Tab>/<S-Tab>` forward correctly, `<C-]>` enters interaction mode, `<C-y>` invokes action_1, normal-mode `<CR>` still submits the filter, `i` returns to typing mode, and any custom binding that collides with a reserved prompt key stays suppressed while the prompt is active |
| Drawer buffer rebuild | DRAW-01 | External buffer invalidation is difficult to model confidently with live layout state alone | With the drawer open and filter active, force-delete the drawer buffer, reopen the drawer, and verify the buffer is rebuilt cleanly without stale prompt state or callback fallout |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] If 04-01 has started or completed, `.planning/phases/04-drawer-navigation/04-01-SUMMARY.md` is present before 04-02 execution/re-review continues
- [ ] Manual live-UI verification for DRAW-01 is recorded in `## DRAW01 Live UI Verification` for the locked corpus/query cohort in all perf modes
- [ ] `.planning/phases/04-drawer-navigation/04-02-SUMMARY.md` records `## DRAW01 Perf Evidence` for the locked corpus/query cohort using the exact labeled fields required by `04-02-PLAN.md`
- [ ] `.github/workflows/test.yml` installs pinned `nui.nvim@de740991c12411b663994b2860f1a4fd0937c130` and prepends it to `runtimepath` as scaffolding for a future DRAW-01 real-nui perf harness
- [ ] DRAW-01 headless perf output is explicitly treated as smoke-only and emits `DRAW01_PERF_MODE=non-release-smoke`
- [ ] DRAW-01 A18 reports only smoke metrics (`DRAW01_SMOKE_FILTER_OPEN_MS`, `DRAW01_SMOKE_FILTER_CYCLE_MS`, `DRAW01_SMOKE_REFRESH_MS`) plus `DRAW01_PERF_NOTE=real-nui perf harness deferred; smoke metrics only`
- [ ] Release-grade real-nui perf evidence is deferred to a follow-up phase before release sign-off
- [ ] DRAW-01 headless coverage includes stale-then-fresh `structure_loaded(request_id)` after same-connection `database_selected`, with only the winning request refreshing
- [ ] DRAW-01 headless coverage proves the `database_switch` action path does not trigger an extra generic refresh before the winning `structure_loaded(request_id)`
- [ ] DRAW-01 headless coverage includes `WinClosed` / `nvim_win_close()` drawer teardown reaching `prepare_close()`
- [ ] DRAW-01 headless coverage includes `cached_render_snapshot` reuse on unchanged trees and invalidation on authoritative refresh plus local expand/collapse/toggle mutations
- [ ] Feedback latency target met where applicable; documented perf gate exception accepted for DRAW-01
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
