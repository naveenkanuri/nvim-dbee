---
phase: 08-type-aware-connection-wizard
plan: 04
subsystem: validation
tags: [wizard, filesource, headless, ci]

requires:
  - phase: 08-type-aware-connection-wizard
    provides: wizard UI, serializers, transient-spec ping, and wizard-backed drawer integration
provides:
  - dedicated headless proof for the Phase 8 wizard flow and save gate
  - temp-file-backed FileSource persistence proof
  - carried Phase 7 regression suites that remain compatible with the new wizard dependency
affects: []

tech-stack:
  added: []
  patterns:
    - "Wizard flow is proven through real drawer and handler seams, with only nui popup/input stubbed in headless mode"
    - "FileSource contracts are proven against real temp JSON files rather than table-only fakes"
    - "Shared headless harnesses stub new UI dependencies so earlier lifecycle suites remain runnable without the real nui plugin"

key-files:
  created:
    - ci/headless/check_connection_wizard.lua
    - ci/headless/check_filesource_persistence.lua
  modified:
    - .github/workflows/test.yml
    - ci/headless/check_connection_lifecycle.lua
    - ci/headless/check_drawer_filter.lua
    - ci/headless/phase7_harness.lua

key-decisions:
  - "Phase 8 validation uses one wizard/integration suite and one FileSource persistence suite so failures isolate cleanly"
  - "The carried Phase 7 regression suites stay in CI and are adapted only at the headless-stub layer, not by weakening their assertions"

requirements-completed: [DCFG-02]

duration: 1 session
completed: 2026-04-28
---

# Phase 8 Plan 04: Validation Summary

**Phase 8 now ships with dedicated automated proof for the wizard surface, transient-spec save gate, and atomic FileSource persistence, while the relevant Phase 7 lifecycle suites continue to pass under the new wizard dependency graph.**

## Performance

- **Completed:** 2026-04-28
- **Tasks:** 2
- **Files modified:** 6

## Accomplishments

- Added `ci/headless/check_connection_wizard.lua` to prove source picking, metadata-first edit seeding, parse/raw fallback behavior, wallet alias discovery and fallback, transient ping gating, raw metadata stripping, nil-current preservation, D-83 partial failure, and source-file edit reachability.
- Added `ci/headless/check_filesource_persistence.lua` to prove atomic rename fail-closed behavior, unknown-field preservation, nested `wizard.*` preservation, per-mode round trips, placeholder/literal password preservation, and delete-with-sibling safety against real temp files.
- Wired both Phase 8 suites into `.github/workflows/test.yml` and updated the shared/local headless stubs so the carried Phase 7 regression suites still run green without requiring a live nui plugin in the local validation path.

## Task Commits

1. **Task 08-04-01: Add headless coverage for wizard flow and transient-spec save gating** - `153221e` (feat)
2. **Task 08-04-02: Add temp-file FileSource coverage and wire Phase 8 plus Phase 7 regressions into CI** - `6b9d367` (feat)
3. **Follow-up regression harness fix for 08-04-02** - `7bbc489` (fix)

## Verification Results

- `08-04-01` verify block passed on 2026-04-28: every required `DCFG02_*` wizard marker emitted cleanly from `ci/headless/check_connection_wizard.lua`.
- `08-04-02` verify block passed on 2026-04-28: every required `DCFG02_*` FileSource marker emitted cleanly from `ci/headless/check_filesource_persistence.lua`, and `.github/workflows/test.yml` includes both new Phase 8 suites plus the retained Phase 7 regressions.
- Final phase verification passed on 2026-04-28:
  - `ci/headless/check_connection_wizard.lua`
  - `ci/headless/check_filesource_persistence.lua`
  - `ci/headless/check_connection_lifecycle.lua`
  - `ci/headless/check_connection_coordination.lua`
  - `ci/headless/check_drawer_filter.lua`
  - `cd dbee && GOCACHE=/tmp/nvim-dbee-gocache go run . -manifest ../lua/dbee/api/__register.lua && git diff --exit-code -- ../lua/dbee/api/__register.lua`
  - `cd dbee && GOCACHE=/tmp/nvim-dbee-gocache go test ./handler -run 'TestConnectionTest'`

## Decisions Made

- The new wizard tests stub only the popup/input primitives and otherwise exercise the real drawer, handler, and FileSource seams.
- The carried Phase 7 suites were updated only where the headless substrate or obsolete prompt-based test expectations conflicted with the locked Phase 8 wizard surface.

## Deviations from Plan

- `08-04-02` needed a small follow-up commit to keep the carried Phase 7 headless suites compatible with the new `connection_wizard` dependency and the Phase 8 wizard-only add path.

## Issues Encountered

- Local headless verification does not have the real `nui.nvim` plugin on the runtime path by default, so the shared headless substrate had to stub `nui.popup` and `nui.input` explicitly once Phase 8 made `drawer/init.lua` depend on `connection_wizard`.

## User Setup Required

None.

## Next Phase Readiness

- Phase 8 is ready to close: DCFG-02 is implemented, headlessly proven, CI-wired, and revalidated against the relevant Phase 7 lifecycle substrate.

---
*Phase: 08-type-aware-connection-wizard*
*Completed: 2026-04-28*
