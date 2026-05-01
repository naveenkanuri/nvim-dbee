---
phase: 01-notifications-feedback
plan: 02
subsystem: ui
tags: [lua, winbar, notifications, yank, schema-refresh, nvim-dbee]

# Dependency graph
requires:
  - phase: 01-notifications-feedback/01
    provides: utils.log migration, drawer error surfacing
provides:
  - Yank feedback notifications with row count and format
  - Schema refresh notification with manual-only tracking via connection ID set
  - Winbar format overhaul with Page/rows/duration labels
  - Adaptive format_duration helper (ms/s/min)
  - State-specific winbar labels during executing/retrieving
affects: []

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "pcall + utils.log for all user-facing error paths (no raw error())"
    - "Connection ID set drain pattern for one-shot event tracking"
    - "format_duration adaptive time formatting (us -> ms/s/min)"

key-files:
  created:
    - ci/headless/check_winbar_format.lua
  modified:
    - lua/dbee/ui/result/init.lua
    - lua/dbee/ui/drawer/init.lua
    - .github/workflows/test.yml

key-decisions:
  - "format_duration uses microseconds directly (no intermediate seconds conversion)"
  - "Winbar update moved outside _progress_running guard to fire on every state transition"
  - "Schema refresh tracked via connection ID set (cached intersect expanded), not boolean flag"
  - "connection_get_params wrapped with pcall, falls back to conn_id on failure"

patterns-established:
  - "pcall + utils.log for yank wrappers: no error() in user-facing code paths"
  - "Connection ID set drain: populate on action, remove on event, empty = no pending"

requirements-completed: [NOTIF-03, NOTIF-05, NOTIF-06, NOTIF-07]

# Metrics
duration: 5min
completed: 2026-03-06
---

# Phase 1 Plan 2: Yank/Schema Notifications + Winbar Format Summary

**Yank feedback via pcall+utils.log, schema refresh notification with connection ID drain set, winbar overhaul to "Page X/Y | N rows | duration" with adaptive formatting**

## Performance

- **Duration:** 5 min
- **Started:** 2026-03-06T17:47:51Z
- **Completed:** 2026-03-06T17:52:57Z
- **Tasks:** 3
- **Files modified:** 4

## Accomplishments
- All yank wrappers (current/selection/all) use pcall + utils.log: success shows "Yanked N rows (FORMAT)", failure shows reason, no results shows warning
- Schema refresh notification fires only on manual refresh (user presses r), auto-load is silent; uses connection ID set drain pattern
- Winbar format changed from cryptic "1/1 (5) Took 0.035s" to "Page 1/1 | 5 rows | 35ms" with adaptive duration
- on_call_state_changed sets "Executing..."/"Retrieving..." on every state transition (not gated by _progress_running)

## Task Commits

Each task was committed atomically:

1. **Task 1: Yank feedback + winbar format overhaul** - `5ca2a71` (feat)
2. **Task 2: Schema refresh notification** - `024b92a` (feat)
3. **Task 3: Headless tests + CI matrix** - `a8d35c4` (test)

## Files Created/Modified
- `lua/dbee/ui/result/init.lua` - format_duration helper, yank feedback via pcall+utils.log, winbar format overhaul, state-specific winbar labels
- `lua/dbee/ui/drawer/init.lua` - _manual_refresh_conns set, schema loaded notification, utils import
- `ci/headless/check_winbar_format.lua` - Tests for duration formatting, winbar state transitions, yank notifications, schema refresh
- `.github/workflows/test.yml` - Added check_notifications.lua and check_winbar_format.lua to CI matrix

## Decisions Made
- format_duration takes microseconds directly (matches time_taken_us field, avoids lossy intermediate conversion)
- Winbar update for executing/retrieving moved outside the _progress_running guard -- the guard only prevents restarting the spinner, not updating the label
- Schema refresh tracking uses intersection of structure_cache keys with expanded nodes (avoids false positives from collapsed-but-cached connections)
- connection_get_params failure falls back to conn_id string (robust against edge cases)

## Deviations from Plan
None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Phase 1 (Notifications & Feedback) is fully complete with all 7 NOTIF requirements implemented
- All headless tests pass, CI matrix updated
- Ready for Phase 2

## Self-Check: PASSED

All 4 files verified present. All 3 task commits verified in git log.

---
*Phase: 01-notifications-feedback*
*Completed: 2026-03-06*
