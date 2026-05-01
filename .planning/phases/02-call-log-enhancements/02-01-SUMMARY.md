---
phase: 02-call-log-enhancements
plan: 01
subsystem: ui
tags: [nui-tree, call-log, duration, timestamp, yank, clipboard]

# Dependency graph
requires:
  - phase: 01-notifications-feedback
    provides: "utils.log pattern, winbar format_duration function"
provides:
  - "utils.format_duration shared function"
  - "Call log inline duration + timestamp columns"
  - "yank_query action with yy mapping"
  - "All call_log.lua vim.notify calls migrated to utils.log"
affects: [02-call-log-enhancements]

# Tech tracking
tech-stack:
  added: []
  patterns: [shared-utility-extraction, smart-timestamp-formatting]

key-files:
  created: []
  modified:
    - lua/dbee/utils.lua
    - lua/dbee/ui/result/init.lua
    - lua/dbee/ui/call_log.lua
    - lua/dbee/config.lua

key-decisions:
  - "format_duration extracted to utils.lua as shared function, result/init.lua uses alias"
  - "Query column width reduced from 40 to 30 chars to fit duration + timestamp"
  - "yy mapping uses mode='n' to avoid capturing visual mode"
  - "Timestamp uses smart date: HH:MM for today, MM-DD HH:MM for older"
  - "In-progress calls show '...' instead of 0ms for duration"

patterns-established:
  - "Smart timestamp formatting: today=HH:MM, older=MM-DD HH:MM"
  - "Shared utility extraction pattern for cross-module reuse"

requirements-completed: [CLOG-01, CLIP-01]

# Metrics
duration: 3min
completed: 2026-03-07
---

# Phase 2 Plan 1: Call Log Enhancements Summary

**Inline duration/timestamp columns on call log entries with yank_query action and format_duration extraction to shared utils**

## Performance

- **Duration:** 3 min
- **Started:** 2026-03-07T00:42:12Z
- **Completed:** 2026-03-07T00:44:52Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- Extracted format_duration from result/init.lua to utils.lua as shared utility
- Added duration and timestamp columns to call log tree entries (NuiLine segments)
- Added yank_query action with yy mapping for copying query text to clipboard
- Cleaned up last raw vim.notify call in call_log.lua cancel_call action

## Task Commits

Each task was committed atomically:

1. **Task 1: Extract format_duration to utils.lua** - `466174b` (refactor)
2. **Task 2: Add duration/timestamp columns, yank action, and cleanup** - `f15dea2` (feat)

## Files Created/Modified
- `lua/dbee/utils.lua` - Added shared format_duration function
- `lua/dbee/ui/result/init.lua` - Replaced local format_duration with utils.format_duration alias
- `lua/dbee/ui/call_log.lua` - Duration+timestamp columns, yank_query action, cancel_call fix
- `lua/dbee/config.lua` - Added yy -> yank_query mapping in call_log.mappings

## Decisions Made
- format_duration extracted as `M.format_duration` to utils.lua; result/init.lua uses `local format_duration = utils.format_duration` alias so all existing call sites remain unchanged
- Query column width reduced from 40 to 30 chars (`QUERY_WIDTH` constant) to make room for duration (8 chars) and timestamp columns
- `yy` mapping uses `mode = "n"` explicitly to avoid capturing visual mode
- Smart timestamp formatting: HH:MM for today's calls, MM-DD HH:MM for older calls
- In-progress calls (state == "executing" or "retrieving") show "..." instead of "0ms"
- Yank notification uses `vim.fn.strchars(query)` for accurate character count (not byte length)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- format_duration is now available as shared utility for any future module
- Call log UI is enhanced with metadata columns; ready for Plan 02 (hover preview enhancements)

## Self-Check: PASSED

All 4 modified files verified on disk. Both task commits (466174b, f15dea2) confirmed in git log.

---
*Phase: 02-call-log-enhancements*
*Completed: 2026-03-07*
