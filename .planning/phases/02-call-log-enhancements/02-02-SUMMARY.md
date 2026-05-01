---
phase: 02-call-log-enhancements
plan: 02
subsystem: ui
tags: [call-log, rerun, yank, headless-tests, ci]

requires:
  - phase: 02-call-log-enhancements/01
    provides: "format_duration in utils.lua, duration/timestamp columns, yank_query action"
provides:
  - "dbee.rerun_query() public API for re-executing past queries"
  - "rerun_query action in call_log.lua with lazy require to avoid circular deps"
  - "R keybinding for rerun in call log buffer"
  - "Comprehensive headless test file covering CLOG-01, CLIP-01, CLOG-02, cleanup"
  - "CI matrix entry for check_call_log_display.lua"
affects: [03-editor-enhancements]

tech-stack:
  added: []
  patterns: [lazy-require-for-circular-deps, headless-test-group-pattern]

key-files:
  created:
    - ci/headless/check_call_log_display.lua
  modified:
    - lua/dbee.lua
    - lua/dbee/ui/call_log.lua
    - lua/dbee/config.lua
    - .github/workflows/test.yml

key-decisions:
  - "Lazy require('dbee') inside rerun_query action body to break circular dependency chain"
  - "rerun_query executes on currently selected connection, not original connection"
  - "D2 guard-path tests use is_loaded false + get_current_connection error to simulate core not loaded"

patterns-established:
  - "Lazy require pattern: require('dbee') inside action function body for call_log -> dbee dependency"
  - "Guard path testing: stub is_loaded + error in get_current_connection for ensure_core_available coverage"

requirements-completed: [CLOG-02]

duration: 10min
completed: 2026-03-07
---

# Phase 2 Plan 2: Re-run from Call Log + Headless Tests Summary

**dbee.rerun_query() API with R keybinding and comprehensive headless tests covering all Phase 2 call log features**

## Performance

- **Duration:** 10 min
- **Started:** 2026-03-07T00:47:24Z
- **Completed:** 2026-03-07T00:57:32Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments
- Added dbee.rerun_query() public API following ensure_core_available + get_current_connection pattern
- Added rerun_query action in call_log.lua using lazy require("dbee") to avoid circular dependency
- Added R -> rerun_query mapping (mode=n) in config.lua
- Created comprehensive headless test file with 5 test groups (format_duration, duration/timestamp display, yank query, rerun dispatch + guard paths, cancel cleanup)
- Updated CI matrix with check_call_log_display.lua

## Task Commits

Each task was committed atomically:

1. **Task 1: Add dbee.rerun_query() API and rerun_query action** - `866d0d2` (feat)
2. **Task 2: Create headless tests and update CI matrix** - `5d00e34` (test)

## Files Created/Modified
- `lua/dbee.lua` - Added dbee.rerun_query(query) public function
- `lua/dbee/ui/call_log.lua` - Added rerun_query action with lazy require
- `lua/dbee/config.lua` - Added R -> rerun_query mapping
- `ci/headless/check_call_log_display.lua` - New headless test file (5 groups, ~25 assertions)
- `.github/workflows/test.yml` - Added check_call_log_display.lua to CI matrix

## Decisions Made
- Lazy require("dbee") inside action function body to break dbee -> api -> state -> call_log -> dbee circular dependency
- rerun_query executes on currently selected connection (not original) per user decision in CONTEXT.md
- D2 guard-path tests stub is_loaded=false AND error in get_current_connection to properly simulate ensure_core_available rejection

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Phase 2 (Call Log Enhancements) is now complete with all requirements (CLOG-01, CLIP-01, CLOG-02) implemented and tested
- All headless tests (new and existing) pass
- Ready for Phase 3: Editor Enhancements

## Self-Check: PASSED

All 5 created/modified files verified present. Both task commits (866d0d2, 5d00e34) confirmed in git log.

---
*Phase: 02-call-log-enhancements*
*Completed: 2026-03-07*
