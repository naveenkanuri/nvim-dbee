---
phase: 1
slug: notifications-feedback
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-05
---

# Phase 1 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Headless Neovim Lua tests (custom, in-repo) |
| **Config file** | `.github/workflows/test.yml` (CI matrix) |
| **Quick run command** | `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/<script>.lua"` |
| **Full suite command** | Run all scripts in `ci/headless/` directory via CI matrix |
| **Estimated runtime** | ~5 seconds |

---

## Sampling Rate

- **After every task commit:** Run relevant test script for the plan being executed
- **After every plan wave:** Run all `ci/headless/` scripts
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 10 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | Test Script | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 01-01-01 | 01 | 0 | NOTIF-01, NOTIF-02, NOTIF-04 | test infra | `luafile ci/headless/check_notifications.lua` | check_notifications.lua | pending |
| 01-01-02 | 01 | 1 | NOTIF-01 | unit (headless) | `luafile ci/headless/check_notifications.lua` | check_notifications.lua | pending |
| 01-01-03 | 01 | 1 | NOTIF-02 | unit (headless) | `luafile ci/headless/check_notifications.lua` | check_notifications.lua | pending |
| 01-01-04 | 01 | 1 | NOTIF-04 | unit (headless) | `luafile ci/headless/check_notifications.lua` | check_notifications.lua | pending |
| 01-02-01 | 02 | 1 | NOTIF-03, NOTIF-05 | unit (headless) | `luafile ci/headless/check_winbar_format.lua` | check_winbar_format.lua | pending |
| 01-02-02 | 02 | 1 | NOTIF-06 | unit (headless) | `luafile ci/headless/check_winbar_format.lua` | check_winbar_format.lua | pending |
| 01-02-03 | 02 | 1 | NOTIF-07 | unit (headless) | `luafile ci/headless/check_winbar_format.lua` | check_winbar_format.lua | pending |

*Status: pending / green / red / flaky*

---

## Wave 0 Requirements

- [ ] `ci/headless/check_notifications.lua` -- exercises real dbee.execute_context and drawer convert code paths to verify NOTIF-01, NOTIF-02, NOTIF-04 (Plan 01)
- [ ] `ci/headless/check_winbar_format.lua` -- exercises real ResultUI and DrawerUI module methods to verify format_duration, winbar state transitions, yank notifications, and schema refresh (Plan 02, covers NOTIF-03, NOTIF-05, NOTIF-06, NOTIF-07)
- [ ] Add both scripts to `.github/workflows/test.yml` CI matrix (consolidated in Plan 02 Task 3)

*Existing headless test patterns (check_actions_entrypoints.lua, check_result_progress_hints.lua) demonstrate dependency mocking approach.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| vim.notify popup appearance with nvim-notify/fidget | All | Visual styling depends on user's notification plugin | 1. Open dbee 2. Run query with no connection 3. Verify notification popup appears with "nvim-dbee" title |

*All notification content and levels are testable via headless mocking. Only visual rendering requires manual verification.*

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 10s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
