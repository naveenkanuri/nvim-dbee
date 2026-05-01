---
phase: 07-connection-only-drawer
plan: 04
subsystem: validation
tags: [ci, headless, drawer, lifecycle, coordination]

requires:
  - phase: 07-connection-only-drawer
    provides: lifecycle, drawer, and coordination implementation from plans 01 through 03
provides:
  - headless lifecycle coverage for the connection-only drawer rewrite
  - headless coordination coverage for bootstrap, reconnect, and async database-switch flows
  - CI wiring for the new Phase 7 suites alongside the retained Phase 6 regression suites
affects: []

tech-stack:
  added: []
  patterns:
    - "Real DrawerUI headless harness with fake Nui tree"
    - "Marker-driven lifecycle and coordination proof suites"
    - "CI matrix extension that preserves earlier regression guards"

key-files:
  created:
    - ci/headless/phase7_harness.lua
    - ci/headless/check_connection_lifecycle.lua
    - ci/headless/check_connection_coordination.lua
  modified:
    - .github/workflows/test.yml

key-decisions:
  - "Phase 7 proof stays on real DrawerUI/handler paths rather than stubbing replay-sensitive seams"
  - "Phase 6 suites remain in CI; Phase 7 adds to the regression surface instead of replacing it"
  - "Secondary source-file editing and bootstrap overflow/tail behavior are proven with explicit machine-readable markers"

requirements-completed: [DCFG-01]

duration: 1 session
completed: 2026-04-28
---

# Phase 7 Plan 04: Validation Summary

**Phase 7 now ships with dedicated lifecycle and coordination proof suites, and CI runs them alongside the Phase 6 regression checks they were required to preserve.**

## Performance

- **Started:** 2026-04-28T13:03:23-0500
- **Completed:** 2026-04-28T13:03:23-0500
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments

- Added a reusable Phase 7 headless harness with a fake Nui tree, window helpers, and enough real runtime plumbing to exercise DrawerUI, handler listeners, and reconnect/LSP coordination without stubbing away the replay-sensitive seams.
- Added `check_connection_lifecycle.lua` to prove the D-71 through D-75 / D-82 drawer lifecycle contract, including the secondary source-file edit path and the D-31 filter regression guard.
- Added `check_connection_coordination.lua` to prove single-flight, bootstrap replay, post-snapshot/tail/overflow/no-loss guarantees, backpressure, sticky selection, reconnect continuity, async `database_switch`, stale-drop behavior, and the Phase 6 structure regression guard.
- Extended `.github/workflows/test.yml` so CI runs both Phase 7 suites plus the retained Phase 6 `check_structure_lazy.lua`, `check_notes_picker.lua`, and `check_drawer_filter.lua` suites.

## Task Commits

1. **Task 07-04-01: Add lifecycle and connection-only drawer headless coverage** - uncommitted in this sandbox (`.git` is not writable, so a task commit could not be created here)
2. **Task 07-04-02: Add coordination, reconnect, and async database-switch coverage and wire Phase 7 suites into CI** - uncommitted in this sandbox (`.git` is not writable, so a task commit could not be created here)

## Verification Results

- `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_connection_lifecycle.lua"` passed with:
  `DCFG01_BOOTSTRAP_SNAPSHOT_OK=true`, `DCFG01_INVALIDATION_PAYLOAD_OK=true`, `DCFG01_SILENT_RELOAD_OK=true`, `DCFG01_FAILURE_EVENT_OK=true`, `DCFG01_PARTIAL_FAILURE_OK=true`, `DCFG01_CONNECTION_ONLY_ROOT_OK=true`, `DCFG01_TEST_FAIL_CLOSED_OK=true`, `DCFG01_SOURCE_EDIT_REACHABLE_OK=true`, `DCFG01_ACTION_TARGETING_OK=true`, `DCFG01_CURRENT_CONN_VISUAL_OK=true`, `DCFG01_REFRESH_MODE_OK=true`, `DCFG01_PHASE6_FILTER_REGRESSION_OK=true`, and `DCFG01_DRAWER_LIFECYCLE_ALL_PASS=true`.
- `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_connection_coordination.lua"` passed with the full coordination marker set, including `LIFECYCLE01_BOOTSTRAP_POST_SNAPSHOT_OK=true`, `LIFECYCLE01_BOOTSTRAP_TAIL_OK=true`, `LIFECYCLE01_BOOTSTRAP_OVERFLOW_OK=true`, and `LIFECYCLE01_BOOTSTRAP_OVERFLOW_STORM_OK=true`.
- Workflow grep passed: `.github/workflows/test.yml` includes `check_connection_lifecycle.lua`, `check_connection_coordination.lua`, `check_structure_lazy.lua`, `check_notes_picker.lua`, and `check_drawer_filter.lua`.
- Go unit coverage excluding Docker-backed integration packages passed with `cd dbee && GOCACHE=/tmp/go-build go test $(GOCACHE=/tmp/go-build go list ./... | grep -v /tests/) -v`.

## Decisions Made

- The Phase 7 suites use real drawer actions and real handler events for replay-sensitive assertions, but keep the UI shell deterministic through the shared fake Nui harness so the markers remain stable in CI.
- Secondary source-file editing stays covered headlessly rather than being left as a manual-only validation item, because D-66 was still in scope for Phase 7 and the reachability assertion is cheap to keep green.
- The coordination suite treats reconnect continuity, stale payload drop, and bootstrap storm handling as first-class contract markers rather than incidental sub-assertions.

## Deviations from Plan

None on behavior. The only operational deviation is that these files remain uncommitted in the sandbox because `.git` is not writable.

## Issues Encountered

- The coordination suite exposed two real contract issues during execution: sticky selection was still auto-selecting the first recreated survivor, and same-epoch reconnect rewrites were not migrating `authoritative_root_epoch`. Both were fixed in the implementation before this summary was written.
- The sandbox cannot create `.git/index.lock`, so CI/test changes could not be captured in atomic task commits here.

## User Setup Required

None for automated validation. Manual rows in `07-VALIDATION.md` still exist for layout feel, reconnect visual smoothness, and adapter-specific async `database_switch` truthfulness on real backends.

## Next Phase Readiness

- Phase 7 now has machine-readable proof for the lifecycle and coordination contracts reviewers were iterating on during plan-gate.
- The repo is ready for a normal environment to create the missing task commits and run the standard git-based manifest cleanliness check before merge.

---
*Phase: 07-connection-only-drawer*
*Completed: 2026-04-28*
