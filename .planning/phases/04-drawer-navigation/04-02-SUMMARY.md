---
phase: 04-drawer-navigation
plan: 02
subsystem: drawer-filter
tags: [drawer, filter, nui, request-id, layouts, headless-tests]

requires:
  - phase: 04-drawer-navigation
    provides: 04-01 drawer node IDs, pane focus, and headless harness patterns
provides:
  - live drawer filter with NuiInput-driven typing path
  - request_id-based stale structure rejection for DB switches
  - cached search/render snapshots for repeated filter sessions
  - drawer window cleanup hooks for QuitPre and WinClosed
  - headless DRAW-01 coverage including stale/fresh DB-switch handling
affects: [04-drawer-navigation]

tech-stack:
  added: []
  patterns:
    - "Shared handler-subtree model builders for refresh and filter"
    - "Event-owned DB-switch refresh via database_selected plus winning structure_loaded(request_id)"
    - "Session-scoped filter teardown with cached snapshot restore"

key-files:
  created:
    - lua/dbee/ui/drawer/model.lua
    - ci/headless/check_drawer_filter.lua
  modified:
    - lua/dbee/handler/init.lua
    - dbee/endpoints.go
    - dbee/handler/handler.go
    - dbee/handler/event_bus.go
    - lua/dbee/ui/drawer/convert.lua
    - lua/dbee/ui/drawer/init.lua
    - lua/dbee/ui/drawer/menu.lua
    - lua/dbee/api/ui.lua
    - lua/dbee/layouts/init.lua
    - lua/dbee/config.lua
    - .github/workflows/test.yml

key-decisions:
  - "Typing path is zero-RPC and searches only ready structure_cache entries"
  - "database_selected invalidation is guarded by per-connection request_id generation"
  - "Minimal drawer cleanup uses QuitPre and WinClosed without closing the full layout"

requirements-completed: [DRAW-01]

duration: 1 session
completed: 2026-04-23
---

# Phase 4 Plan 02: Live Drawer Filter Summary

**DRAW-01 is implemented with request-tokened DB-switch invalidation, shared handler-subtree model builders, cached restore/search state, and headless regression coverage.**

## Performance

- **Completed:** 2026-04-23
- **Tasks:** 2
- **Files modified:** 12

## Accomplishments

- Added request_id plumbing from Lua handler calls through Go event publication so stale `structure_loaded` payloads are ignored after DB switches
- Added `drawer/model.lua` plus a large `drawer/init.lua` refactor for refresh/filter shared state, typed filtering, cached search/render snapshots, and buffer rebuild safety
- Added `menu.filter()` plus layout/API cleanup hooks for drawer close handling via `drawer_prepare_close()`
- Added default `/` mapping and CI workflow coverage for drawer filter, drawer yank, and pane jump scripts
- Added `check_drawer_filter.lua` covering ready-corpus startup, zero-RPC typing, DB-switch stale/fresh ordering, WinClosed cleanup, restore semantics, and perf advisories

## Task Commits

1. **Task 1a: request_id plumbing for async structure loads** - `b8394ee` (feat)
2. **Task 1b: drawer search/filter implementation and workflow wiring** - `4c7782b` (feat)
3. **Task 2: headless tests for drawer filter + DB-switch invalidation** - `3652c93` (test)

## Verification Results

- `CLIP02_ALL_PASS=true`
- `NAV02_ALL_PASS=true`
- `DRAW01_ALL_PASS=true`
- `go test ./ ./adapters ./core/... ./handler ./plugin ./tests/testhelpers` passed
- `go test ./...` hit an environment-only integration failure because Docker could not find `testcontainers/ryuk:0.11.0`

## DRAW01 Perf Evidence

- `Perf Mode:` `stub`
- `Locked Corpus:` headless stub fixture from `ci/headless/check_drawer_filter.lua` with one ready connection, one cold connection, and one cached-error connection
- `Startup Metrics:` `DRAW01_STARTUP_MS=0.15`
- `Apply Metrics:` `DRAW01_FILTER_RESTART_MS=0.04`
- `Restore Metrics:` no separate numeric restore metric is emitted in stub mode; restore correctness is covered by A10, A15, A16, and A17 assertions
- `Soak Metrics:` advisory stub-mode soak/restart coverage passed in A18; `DRAW01_REFRESH_MS=0.68`
- `Environment:` local macOS headless Neovim run with repo runtimepath and stubbed `nui.input` / `nui.menu`
- `Reviewer:` Codex executor
- `Date:` 2026-04-23

## DRAW01 Live UI Verification

- `Locked Corpus:` pending manual run against the same drawer corpus/query cohort used for release verification
- `Observed Behavior:` not exercised in a live UI session during this execution turn
- `Outcome:` pending manual verification
- `Reviewer:` unassigned
- `Date:` 2026-04-23

## Deviations from Plan

- No code-scope deviation. Go handler files were included because 04-02 frontmatter explicitly listed the request_id plumbing paths.
- The only incomplete release artifact is manual live-UI verification, which the plan requires separately from headless execution.

## Next Phase Readiness

- DRAW-01 code and headless verification are in place.
- Manual live-UI verification remains before Phase 4 can be treated as fully release-complete under the 04-02 output contract.
