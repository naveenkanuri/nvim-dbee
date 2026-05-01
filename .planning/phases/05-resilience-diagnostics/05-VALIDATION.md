---
phase: 05
slug: resilience-diagnostics
status: draft
nyquist_compliant: true
wave_0_complete: false
created: 2026-04-23
---

# Phase 05 — Validation Strategy

> Per-phase validation contract for `CONN-01` and `ADPT-02`.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | headless Neovim Lua scripts |
| **Config file** | `ci/headless/check_*.lua` |
| **Quick run command** | `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_<test>.lua"` |
| **Full suite command** | `sh -c 'set -e; for f in ci/headless/check_*.lua; do out=$(nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile $f" 2>&1); printf "%s\n" "$out"; printf "%s\n" "$out" | grep -E "^[A-Z0-9_]+_ALL_PASS=true$"; ! printf "%s\n" "$out" | grep -E "FAIL=|Lua error|Traceback"; done'` |
| **Estimated runtime** | under 10s for the full headless suite once both Phase 5 scripts are added |

---

## Sampling Rate

- **After every task commit:** run the plan-local script for the touched feature
- **After every plan wave:** run the full headless suite
- **Before `/gsd:verify-work`:** full suite must be green and manual live checks below must be recorded in the phase summary
- **Max feedback latency:** best-effort under 5s for individual Phase 5 scripts

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 05-01-01 | 01 | 1 | CONN-01 | grep/structure | `grep -n "conn_id\\|error_kind\\|timestamp_us" dbee/handler/event_bus.go dbee/handler/handler.go lua/dbee/doc.lua && grep -n "call_ids_by_conn\\|register_call\\|retry_fn\\|ensure_reconnect_listener\\|latest_failed_ts\\|forget_call\\|reset_connection_episode\\|rewrite_meta_conn_id\\|rewrite_connection_identity\\|register_connection_rewritten_listener" lua/dbee/reconnect.lua && grep -n "retry_last_disconnected\\|reconnect_current_connection\\|register_call\\|run_oracle_explain_on_connection\\|rewrite_connection_identity\\|SYNTHETIC_STEP2_PATTERN" lua/dbee.lua && grep -n "is_loaded\\|rebind_note_connection" lua/dbee/api/ui.lua && grep -n "resolved_query\\|conn_id\\|conn_name\\|start_line\\|start_col\\|note_exec_meta\\|write_note_conn\\|rebind_note_connection\\|on_retry_created" lua/dbee/ui/editor/init.lua lua/dbee/utils.lua && grep -n "Reconnect" lua/dbee/ui/result/init.lua` | ❌ W0 | ⬜ pending |
| 05-01-02 | 01 | 1 | CONN-01 | headless | `sh -c 'out=$(nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_auto_reconnect.lua" 2>&1); printf "%s\n" "$out" | grep "^CONN01_ALL_PASS=true$" && printf "%s\n" "$out" | grep "^CONN01_CALLBACK_REPLAY_OK=true$" && printf "%s\n" "$out" | grep "^CONN01_DEEP_COPY_BINDS_OK=true$" && printf "%s\n" "$out" | grep "^CONN01_CHANGED_CONN_ID_OK=true$" && printf "%s\n" "$out" | grep "^CONN01_EFFECTIVE_CONN_ID_OK=true$" && printf "%s\n" "$out" | grep "^CONN01_SAME_ID_FAST_PATH_OK=true$" && printf "%s\n" "$out" | grep "^CONN01_EPISODE_MIGRATION_OK=true$" && printf "%s\n" "$out" | grep "^CONN01_REREGISTER_OK=true$" && printf "%s\n" "$out" | grep "^CONN01_RETRY_PCALL_OK=true$" && printf "%s\n" "$out" | grep "^CONN01_CONN_REWRITE_FANOUT_OK=true$" && printf "%s\n" "$out" | grep "^CONN01_SYNTHETIC_FALLBACK_ABORT_OK=true$" && printf "%s\n" "$out" | grep "^CONN01_UI_BRIDGE_NOOP_OK=true$" && printf "%s\n" "$out" | grep "^CONN01_REWRITE_LISTENER_GUARD_OK=true$" && printf "%s\n" "$out" | grep "^CONN01_REGISTRY_BOUNDED=true$" && ! printf "%s\n" "$out" | grep -E "FAIL=|Lua error|Traceback"'` | ❌ W0 | ⬜ pending |
| 05-02-01 | 02 | 2 | ADPT-02 | grep/structure | `grep -n "register_parser\\|build_diagnostic\\|is_sql_adapter\\|resolved_query\\|start_col\\|aliases\\|sqlite\\|oracle\\|sql = true" lua/dbee/ui/editor/diagnostics.lua && grep -n "diag_ns_by_conn\\|diag_bufs_by_conn\\|note_count_by_conn\\|clear_diagnostics\\|prune_diag_namespace\\|write_note_conn\\|rebind_note_connection\\|register_connection_rewritten_listener\\|resolved_query\\|start_col\\|vim.diagnostic.set\\|vim.diagnostic.reset" lua/dbee/ui/editor/init.lua && grep -n "is_loaded\\|rebind_note_connection" lua/dbee/api/ui.lua && grep -n "register_connection_rewritten_listener" lua/dbee/reconnect.lua && grep -n "dbee-" lua/dbee/ui/editor/init.lua lua/dbee/doc.lua` | ❌ W0 | ⬜ pending |
| 05-02-02 | 02 | 2 | ADPT-02 | headless + CI wiring | `sh -c 'out=$(nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_adapter_diagnostics.lua" 2>&1); printf "%s\n" "$out" | grep "^ADPT02_ALL_PASS=true$" && printf "%s\n" "$out" | grep "^ADPT02_POSTGRES_CTX_OK=true$" && printf "%s\n" "$out" | grep "^ADPT02_START_COL_OK=true$" && printf "%s\n" "$out" | grep "^ADPT02_ALIAS_MAP_OK=true$" && printf "%s\n" "$out" | grep "^ADPT02_REWRITE_SIGNAL_SCOPE_OK=true$" && printf "%s\n" "$out" | grep "^ADPT02_REWRITE_LISTENER_GUARD_OK=true$" && printf "%s\n" "$out" | grep "^ADPT02_SQLITE_FALLBACK_OK=true$" && ! printf "%s\n" "$out" | grep -E "FAIL=|Lua error|Traceback" && grep -q "check_auto_reconnect.lua" .github/workflows/test.yml && grep -q "check_adapter_diagnostics.lua" .github/workflows/test.yml'` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `ci/headless/check_auto_reconnect.lua` — reconnect prompt/debounce/retry/callback coverage
- [ ] `ci/headless/check_adapter_diagnostics.lua` — parser/fallback/lifecycle coverage

*Existing headless infrastructure from Phases 1-4 covers framework setup and fixture style.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Reconnect prompt UX in a real `vim.ui.select` provider | CONN-01 | Headless stubs cannot prove dressing/snacks picker behavior | Trigger a disconnected SQL failure against a live connection, confirm the prompt names the connection and presents a simple Yes/No choice, and record the provider plus observed text in the phase summary |
| Flapping-connection debounce feel | CONN-01 | Real database disconnect storms are hard to model faithfully in headless stubs | Trigger multiple disconnected failures rapidly on one connection, confirm only one prompt appears for that connection until you answer or the episode resets |
| Context preservation after reconnecting a non-current connection | CONN-01 | Requires live pane and current-connection state | Start a query on connection A, switch current focus to connection B, trigger a disconnected failure on A, confirm reconnect+retry on A, and verify the current connection returns to B afterward |
| Diagnostic rendering under user-configured Neovim UI | ADPT-02 | Headless can prove namespace payloads, not actual signs/virtual text styling | Run failing queries on at least one parser-backed SQL adapter and one fallback-only SQL adapter (SQLite or another generic SQL adapter), confirm diagnostics appear in the editor using the user's normal `vim.diagnostic` configuration |
| Explicit `clear_diagnostics` discoverability | ADPT-02 | Action-picker/menu affordance is a live interaction detail | Open editor actions, confirm `clear_diagnostics` is present, invoke it, and verify markers disappear without needing a successful rerun |
| Non-SQL unchanged behavior | ADPT-02 | Requires live adapter execution semantics | Trigger a failure on a non-SQL adapter (`mongo` or `redis`) and confirm Phase 5 keeps notify-only behavior with no fabricated SQL marker |
| Explain Plan remains out of Phase 5 diagnostic scope | ADPT-02 | Headless intentionally does not cover Explain ownership or wrapper remapping | Trigger a failing non-Oracle Explain Plan from the editor and confirm Phase 5 still uses the existing result/notify path rather than claiming inline diagnostics |

---

## Validation Sign-Off

- [ ] All tasks have an automated verify command
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all new headless scripts
- [ ] `05-01-PLAN.md` and `05-02-PLAN.md` both map directly to locked decisions in `05-CONTEXT.md`
- [ ] `call_state_changed` enrichment is limited to additive metadata (`conn_id`, `error_kind`, `timestamp_us`) and does not introduce a backend reconnect workflow
- [ ] `CONN01_ALL_PASS=true` emitted by `check_auto_reconnect.lua`
- [ ] `CONN01_DEEP_COPY_BINDS_OK=true` proves bind-value replay is insulated from post-registration mutation
- [ ] `CONN01_CHANGED_CONN_ID_OK=true` proves reconnect rewrites retry metadata to the reloaded connection ID
- [ ] `CONN01_EFFECTIVE_CONN_ID_OK=true` proves late stale-wire events route through `effective_conn_id` to the live rewritten episode instead of recreating dead-ID state
- [ ] `CONN01_SAME_ID_FAST_PATH_OK=true` proves same-ID reconnect skips `rewrite_connection_identity()` and emits no rewrite signal
- [ ] `CONN01_EPISODE_MIGRATION_OK=true` proves old/new connection rewrite merges episode state and does not reopen prompts against dead IDs
- [ ] `CONN01_REREGISTER_OK=true` proves replacement calls are re-registered before UI/result rebinding and stay inside the registry flow on a second disconnect
- [ ] `CONN01_RETRY_PCALL_OK=true` proves synchronous auto-retry execute-start failures are warned and contained instead of crashing the listener callback
- [ ] `CONN01_CONN_REWRITE_FANOUT_OK=true` proves sibling note/call metadata rewrites fan out across the scoped connection index with per-note dedupe
- [ ] `CONN01_SYNTHETIC_FALLBACK_ABORT_OK=true` proves synthetic legacy fallback attempts WARN + abort instead of replaying opaque SQL
- [ ] `CONN01_UI_BRIDGE_NOOP_OK=true` proves reconnect-owned note rewrites no-op safely when the editor UI is unloaded
- [ ] `CONN01_REWRITE_LISTENER_GUARD_OK=true` proves duplicate connection-rewrite listener keys fail loudly instead of double-subscribing
- [ ] `ADPT02_ALL_PASS=true` emitted by `check_adapter_diagnostics.lua`
- [ ] `ADPT02_START_COL_OK=true` proves mid-line/visual-selection diagnostics honor `start_col`
- [ ] `ADPT02_ALIAS_MAP_OK=true` proves adapter aliases hit the registered parser path through the reverse alias map
- [ ] Duplicate canonical adapter names or aliases fail loudly during parser registration instead of silently overwriting the reverse map
- [ ] `ADPT02_REWRITE_SIGNAL_SCOPE_OK=true` proves reconnect-local connection rewrite pruning only touches the `(old_conn_id, new_conn_id)` scope
- [ ] `ADPT02_REWRITE_LISTENER_GUARD_OK=true` proves diagnostics-side keyed rewrite-listener registration rejects duplicate subscribers
- [ ] All Phase 5 diagnostics set severity `ERROR`
- [ ] SQLite is validated as fallback-only rather than precise line/column parsing
- [ ] `.github/workflows/test.yml` runs both Phase 5 headless scripts
- [ ] Manual reconnect UX / debounce verification recorded in the execution summary
- [ ] Manual diagnostic rendering / clear action / Explain-out-of-scope verification recorded in the execution summary

**Approval:** pending
