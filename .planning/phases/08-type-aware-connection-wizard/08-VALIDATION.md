---
phase: 08
slug: type-aware-connection-wizard
status: draft
nyquist_compliant: true
wave_0_complete: false
created: 2026-04-28
---

# Phase 08 - Validation Strategy

> Per-phase validation contract for `DCFG-02`: type-aware connection wizard, transient-spec ping, and atomic FileSource persistence.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | headless Neovim Lua scripts + targeted Go unit test + grep/manifest checks |
| **Config file** | `ci/headless/check_connection_wizard.lua`, `ci/headless/check_filesource_persistence.lua`, `dbee/handler/handler_connection_test.go` |
| **Quick run command** | `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_<suite>.lua"` |
| **Full suite command** | `sh -c 'set -e; for f in ci/headless/check_connection_wizard.lua ci/headless/check_filesource_persistence.lua ci/headless/check_connection_lifecycle.lua ci/headless/check_connection_coordination.lua ci/headless/check_drawer_filter.lua; do out=$(nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile $f" 2>&1); printf "%s\n" "$out"; ! printf "%s\n" "$out" | grep -E "FAIL=|Lua error|Traceback"; done; cd dbee && go test ./handler -run \"TestConnectionTest\"'` |
| **Estimated runtime** | under 30s once both new Phase 8 suites exist |

---

## Sampling Rate

- **After every task commit:** run the plan-local verify block for the touched task
- **After every wave:** run the Phase 8 suite added in that wave plus the relevant carried regression suite(s)
- **Before `/gsd:verify-work`:** both new Phase 8 suites, the targeted Go unit test, and the retained Phase 7 regressions must be green
- **Max feedback latency:** best-effort under 10s for each Phase 8 script

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 08-01-01 | 01 | 1 | DCFG-02 | grep/structure | `grep -n "create(conn)\|update(id, details)\|delete(id)\|os.rename\|uv.fs_rename\|wizard\|__remove_keys" lua/dbee/sources.lua` | ❌ W0 | ⬜ pending |
| 08-01-02 | 01 | 1 | DCFG-02 | grep/structure | `grep -n "get_record\|source_get_connection_record" lua/dbee/sources.lua lua/dbee/handler/init.lua lua/dbee/api/core.lua lua/dbee/doc.lua` | ❌ W0 | ⬜ pending |
| 08-02-01 | 02 | 2 | DCFG-02 | grep/structure | `grep -n "oracle_cloud_wallet\|tnsnames\|wallet_path\|service_alias\|oracle_custom_jdbc\|postgres_url\|postgres_form\|other_raw\|function M.open" lua/dbee/ui/connection_wizard/init.lua lua/dbee/doc.lua` | ❌ W0 | ⬜ pending |
| 08-02-02 | 02 | 2 | DCFG-02 | grep/structure | `grep -n "validate\|serialize\|normalize_seed\|rendered_url\|unsupported query\|lossless\|placeholder" lua/dbee/ui/connection_wizard/init.lua lua/dbee/doc.lua` | ❌ W0 | ⬜ pending |
| 08-03-01 | 03 | 3 | DCFG-02 | grep/manifest + Go unit | `grep -n "DbeeConnectionTestSpec\|ConnectionTestSpec\|connection_test_spec" dbee/endpoints.go dbee/handler/handler.go lua/dbee/api/__register.lua lua/dbee/api/core.lua lua/dbee/handler/init.lua lua/dbee/doc.lua && sh -c "cd dbee && go run . -manifest ../lua/dbee/api/__register.lua && git diff --exit-code -- ../lua/dbee/api/__register.lua" && sh -c "cd dbee && go test ./handler -run 'TestConnectionTest'"` | ❌ W0 | ⬜ pending |
| 08-03-02 | 03 | 3 | DCFG-02 | grep/structure | `grep -n "submit_connection_wizard\|connection_test_spec\|source_get_connection_record\|connection_wizard\|Other\|raw\|wizard\|__remove_keys\|current_conn_id_after\|_source_reload_silent" lua/dbee/ui/drawer/init.lua lua/dbee/ui/drawer/convert.lua lua/dbee/ui/connection_wizard/init.lua lua/dbee/handler/init.lua lua/dbee/doc.lua` | ❌ W0 | ⬜ pending |
| 08-04-01 | 04 | 4 | DCFG-02 | headless | `sh -c 'out=$(nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_connection_wizard.lua" 2>&1); printf "%s\n" "$out" | grep "^DCFG02_WIZARD_ALL_PASS=true$" && printf "%s\n" "$out" | grep "^DCFG02_SOURCE_PICKER_OK=true$" && printf "%s\n" "$out" | grep "^DCFG02_MODE_FLOW_OK=true$" && printf "%s\n" "$out" | grep "^DCFG02_WALLET_ALIAS_DISCOVERY_OK=true$" && printf "%s\n" "$out" | grep "^DCFG02_WALLET_ALIAS_FALLBACK_OK=true$" && printf "%s\n" "$out" | grep "^DCFG02_OTHER_FALLBACK_OK=true$" && printf "%s\n" "$out" | grep "^DCFG02_LOCAL_VALIDATION_OK=true$" && printf "%s\n" "$out" | grep "^DCFG02_TRANSIENT_PING_OK=true$" && printf "%s\n" "$out" | grep "^DCFG02_OTHER_MODE_PING_GATED_OK=true$" && printf "%s\n" "$out" | grep "^DCFG02_FAIL_CLOSED_CURRENT_OK=true$" && printf "%s\n" "$out" | grep "^DCFG02_EDIT_SEED_METADATA_OK=true$" && printf "%s\n" "$out" | grep "^DCFG02_EDIT_PARSE_FALLBACK_OK=true$" && printf "%s\n" "$out" | grep "^DCFG02_NON_FILESOURCE_NO_METADATA_OK=true$" && printf "%s\n" "$out" | grep "^DCFG02_FILESOURCE_RAW_FALLBACK_NO_METADATA_OK=true$" && printf "%s\n" "$out" | grep "^DCFG02_EDIT_SEAM_CONSISTENT_OK=true$" && printf "%s\n" "$out" | grep "^DCFG02_PG_URL_UNSUPPORTED_FALLBACK_OK=true$" && printf "%s\n" "$out" | grep "^DCFG02_D83_PARTIAL_FAILURE_OK=true$" && printf "%s\n" "$out" | grep "^DCFG02_NO_AUTO_ACTIVATE_OK=true$" && printf "%s\n" "$out" | grep "^DCFG02_SOURCE_EDIT_SECONDARY_OK=true$" && ! printf "%s\n" "$out" | grep -E "FAIL=|Lua error|Traceback"'` | ❌ W0 | ⬜ pending |
| 08-04-02 | 04 | 4 | DCFG-02 | headless + CI wiring | `sh -c 'out=$(nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_filesource_persistence.lua" 2>&1); printf "%s\n" "$out" | grep "^DCFG02_FILESOURCE_ALL_PASS=true$" && printf "%s\n" "$out" | grep "^DCFG02_ATOMIC_WRITE_OK=true$" && printf "%s\n" "$out" | grep "^DCFG02_UNKNOWN_FIELD_PRESERVE_OK=true$" && printf "%s\n" "$out" | grep "^DCFG02_WIZARD_NESTED_PRESERVE_OK=true$" && printf "%s\n" "$out" | grep "^DCFG02_METADATA_ROUNDTRIP_OK=true$" && printf "%s\n" "$out" | grep "^DCFG02_PASSWORD_PLACEHOLDER_PRESERVED_OK=true$" && printf "%s\n" "$out" | grep "^DCFG02_PG_URL_ROUNDTRIP_OK=true$" && printf "%s\n" "$out" | grep "^DCFG02_PG_FORM_RENDERED_URL_OK=true$" && printf "%s\n" "$out" | grep "^DCFG02_ORACLE_DESCRIPTOR_ROUNDTRIP_OK=true$" && printf "%s\n" "$out" | grep "^DCFG02_DELETE_PRESERVES_SIBLINGS_OK=true$" && ! printf "%s\n" "$out" | grep -E "FAIL=|Lua error|Traceback" && grep -q "check_connection_wizard.lua" .github/workflows/test.yml && grep -q "check_filesource_persistence.lua" .github/workflows/test.yml && grep -q "check_connection_lifecycle.lua" .github/workflows/test.yml && grep -q "check_connection_coordination.lua" .github/workflows/test.yml && grep -q "check_drawer_filter.lua" .github/workflows/test.yml'` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `ci/headless/check_connection_wizard.lua` - wizard flow, wallet alias discovery/fallback, metadata-first edit seeding, convert/edit seam consistency, transient-spec ping gating for scoped and `Other` modes, scoped-mode metadata boundary with stale metadata deletion, raw fallback, D-83 partial failure, and no-auto-activate proof including nil-current preservation
- [ ] `ci/headless/check_filesource_persistence.lua` - atomic write, unknown-field preservation including nested `wizard.*`, metadata fidelity, password placeholder pass-through, and per-mode round-trip proof
- [ ] retained regression coverage for `check_connection_lifecycle.lua`, `check_connection_coordination.lua`, and `check_drawer_filter.lua`

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Compound wizard feel and keyboard navigation | DCFG-02 | Headless can prove state transitions, not actual in-editor feel | Open add/edit from the drawer, verify the wizard feels like one modal surface rather than chained prompts, and confirm keyboard navigation between type, mode, and field sections remains coherent. |
| Password masking usability | DCFG-02 | Headless can assert masked-state logic, not the actual visual UX quality | Enter passwords in Oracle and Postgres modes and confirm the field is masked while still editable and reviewable enough for real use. |
| Live driver ping with real Oracle/Postgres targets | DCFG-02 | Headless stubs prove routing, not adapter-specific auth/network ergonomics | Add/edit one Oracle and one Postgres connection against real targets, confirm ping failure surfaces actionable text before save and ping success proceeds to save without auto-activation. |

---

## Validation Sign-Off

- [ ] All tasks have an automated verify command
- [ ] Wave 0 includes both new Phase 8 suites
- [ ] `08-01-PLAN.md` maps cleanly to D-97 through D-100
- [ ] `08-02-PLAN.md` maps cleanly to D-89 through D-93 and D-101 through D-105 for the UI/state layer
- [ ] `08-03-PLAN.md` maps cleanly to D-94 through D-106 while preserving Phase 7 D-67 through D-69 and D-82 through D-83
- [ ] `DCFG02_WIZARD_ALL_PASS=true` emitted by `check_connection_wizard.lua`
- [ ] `DCFG02_SOURCE_PICKER_OK=true` proves add still routes by Phase 7 source selection rules
- [ ] `DCFG02_MODE_FLOW_OK=true` proves type/mode flow and the five-mode set
- [ ] `DCFG02_WALLET_ALIAS_DISCOVERY_OK=true` proves wallet directory and wallet-`.zip` fixtures populate a selectable alias dropdown
- [ ] `DCFG02_WALLET_ALIAS_FALLBACK_OK=true` proves broken or missing `tnsnames.ora` keeps manual alias entry available with warning
- [ ] `DCFG02_OTHER_FALLBACK_OK=true` proves unsupported/lossy cases keep a raw compatibility path
- [ ] `DCFG02_LOCAL_VALIDATION_OK=true` proves cheap local validation blocks invalid submit states before ping
- [ ] `DCFG02_TRANSIENT_PING_OK=true` proves unsaved specs are tested before save through the additive transient-spec surface
- [ ] `DCFG02_OTHER_MODE_PING_GATED_OK=true` proves `Other`-mode/raw compatibility submits still run transient ping before mutation and forced ping failure causes no mutation
- [ ] `DCFG02_FAIL_CLOSED_CURRENT_OK=true` proves ping/save failure preserves the prior current connection and drawer state
- [ ] `DCFG02_EDIT_SEED_METADATA_OK=true` proves metadata-first edit seeding
- [ ] `DCFG02_EDIT_PARSE_FALLBACK_OK=true` proves lossless parse fallback when metadata is absent
- [ ] `DCFG02_NON_FILESOURCE_NO_METADATA_OK=true` proves non-FileSource/raw compatibility submits strip the `wizard` metadata block
- [ ] `DCFG02_FILESOURCE_RAW_FALLBACK_NO_METADATA_OK=true` proves FileSource `Other` and raw-fallback submits starting from a row with existing wizard metadata physically remove the `wizard` block
- [ ] `DCFG02_EDIT_SEAM_CONSISTENT_OK=true` proves `init.lua`, `convert.lua`, and searchable/filter edit paths delegate to the same wizard-backed loader
- [ ] `DCFG02_PG_URL_UNSUPPORTED_FALLBACK_OK=true` proves unsupported Postgres query params force URL mode instead of silent normalization
- [ ] `DCFG02_D83_PARTIAL_FAILURE_OK=true` proves save commit + reload failure still follows Phase 7 D-83 and preserves `current_conn_id_after = nil` when nil current was intentionally preserved
- [ ] `DCFG02_NO_AUTO_ACTIVATE_OK=true` proves save success does not auto-activate the connection, including the nil-current-with-existing-connections case and `connection_invalidated.current_conn_id_after = nil`
- [ ] `DCFG02_SOURCE_EDIT_SECONDARY_OK=true` proves the Phase 7 D-66 secondary source-file edit path remains reachable
- [ ] `DCFG02_FILESOURCE_ALL_PASS=true` emitted by `check_filesource_persistence.lua`
- [ ] `DCFG02_ATOMIC_WRITE_OK=true` proves failed persistence leaves the original file untouched
- [ ] `DCFG02_UNKNOWN_FIELD_PRESERVE_OK=true` proves unknown sibling records and unknown fields on the edited record survive
- [ ] `DCFG02_WIZARD_NESTED_PRESERVE_OK=true` proves untouched nested keys inside additive `wizard` metadata survive edits to known wizard leaf fields
- [ ] `DCFG02_METADATA_ROUNDTRIP_OK=true` proves additive wizard metadata survives create/update round-trip
- [ ] `DCFG02_PASSWORD_PLACEHOLDER_PRESERVED_OK=true` proves literal cleartext and env-placeholder passwords are byte-preserved with no auto-expansion
- [ ] `DCFG02_PG_URL_ROUNDTRIP_OK=true` proves Postgres URL mode preserves the exact URL string
- [ ] `DCFG02_PG_FORM_RENDERED_URL_OK=true` proves Postgres Form stores decomposed fields plus the exact rendered URL
- [ ] `DCFG02_ORACLE_DESCRIPTOR_ROUNDTRIP_OK=true` proves Oracle Custom JDBC preserves the raw descriptor text
- [ ] `DCFG02_DELETE_PRESERVES_SIBLINGS_OK=true` proves delete removes only the targeted record
- [ ] `sh -c "cd dbee && go run . -manifest ../lua/dbee/api/__register.lua && git diff --exit-code -- ../lua/dbee/api/__register.lua"` stays green for the additive transient-spec RPC
- [ ] `cd dbee && go test ./handler -run "TestConnectionTest"` stays green after the transient-spec ping addition
- [ ] `.github/workflows/test.yml` runs both new Phase 8 suites and the carried Phase 7 regressions
- [ ] Manual compound-wizard, password-mask, and live-driver-ping checks are recorded in the Phase 8 summaries

**Approval:** pending
