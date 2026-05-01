---
phase: 3
slug: editor-result-actions
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-08
---

# Phase 3 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Neovim headless Lua (custom, no plenary) |
| **Config file** | none -- scripts self-contained |
| **Quick run command** | `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_<name>.lua"` |
| **Full suite command** | `for f in ci/headless/check_*.lua; do nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile $f"; done` |
| **Estimated runtime** | ~5 seconds |

---

## Sampling Rate

- **After every task commit:** Run specific check script for that task
- **After every plan wave:** Run full suite command
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 5 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 03-01-T1 | 01 | 1 | NAV-01 | unit | `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_note_cycling.lua"` | ❌ W0 | ⬜ pending |
| 03-01-T2 | 01 | 1 | RSLT-01 | unit | `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_result_export.lua"` | ❌ W0 | ⬜ pending |
| 03-02-T1 | 02 | 1 | ADPT-01 | unit | `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_explain_plan.lua"` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `ci/headless/check_note_cycling.lua` — mock EditorUI with notes, verify cycling wraps, stays in namespace
- [ ] `ci/headless/check_result_export.lua` — mock handler/call, verify format inference, no-call guard, path prompt flow
- [ ] `ci/headless/check_explain_plan.lua` — mock connection with type, verify wrapper dispatch, Oracle singleton-listener two-step, pending-map lifecycle, timeout cleanup, unsupported adapter warning

*Existing infrastructure (ci/headless/) provides the pattern; new test files needed per requirement.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| vim.ui.input path prompt UI | RSLT-01 | Requires interactive input/display | Open dbee, run query, press `ge`, verify prompt appears with default path |
| vim.ui.select overwrite confirm | RSLT-01 | Requires interactive selection | Export to existing file, verify "Overwrite?" prompt |
| Oracle singleton-listener two-step with real DB | ADPT-01 | Requires live Oracle connection | Connect to Oracle, run EXPLAIN on SELECT, verify DBMS_XPLAN output and step-2 chaining after step-1 completion |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 5s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
