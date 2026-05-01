---
phase: 2
slug: call-log-enhancements
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-06
---

# Phase 2 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Neovim headless Lua checks (custom, no framework) |
| **Config file** | ci/headless/ directory |
| **Quick run command** | `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_call_log_display.lua"` |
| **Full suite command** | Run all `ci/headless/check_*.lua` scripts |
| **Estimated runtime** | ~3 seconds |

---

## Sampling Rate

- **After every task commit:** Run `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_call_log_display.lua"`
- **After every plan wave:** Run all `ci/headless/check_*.lua` scripts
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 5 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 02-01-01 | 01 | 1 | CLOG-01 | unit (headless) | `check_call_log_display.lua` | ❌ W0 | ⬜ pending |
| 02-01-02 | 01 | 1 | CLIP-01 | unit (headless) | `check_call_log_display.lua` | ❌ W0 | ⬜ pending |
| 02-01-03 | 01 | 1 | CLOG-02 | unit (headless) | `check_call_log_display.lua` | ❌ W0 | ⬜ pending |
| 02-01-04 | 01 | 1 | CLEANUP | unit (headless) | `check_call_log_display.lua` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `ci/headless/check_call_log_display.lua` — stubs for CLOG-01, CLIP-01, CLOG-02, CLEANUP
- [ ] Update `.github/workflows/test.yml` matrix to include `check_call_log_display.lua`

*Existing infrastructure covers framework needs. Only new test file required.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Visual column alignment in real call log | CLOG-01 | Window width varies | Open dbee, run queries, inspect call log tree |
| System clipboard paste in external app | CLIP-01 | Requires GUI clipboard | Yank query, paste in external editor |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 5s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
