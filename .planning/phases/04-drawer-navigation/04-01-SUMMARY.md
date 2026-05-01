---
phase: 04-drawer-navigation
plan: 01
subsystem: drawer
tags: [drawer, clipboard, navigation, layouts, keybindings, headless-tests]

requires:
  - phase: 03-editor-result-actions
    provides: focus action pattern and headless test harness style
provides:
  - drawer `yank_name` action for qualified object names
  - `dbee.focus_pane()` public API with layout compatibility guards
  - `focus_editor/result/drawer/call_log` actions in all four panes
  - headless CLIP-02 and NAV-02 coverage
affects: [04-drawer-navigation]

tech-stack:
  added: []
  patterns:
    - "Injective drawer node IDs via escaped packed segments"
    - "Pane-jump layout compatibility via optional focus_pane/ensure_drawer_visible methods"

key-files:
  created:
    - ci/headless/check_drawer_yank.lua
    - ci/headless/check_pane_jump.lua
  modified:
    - lua/dbee/ui/drawer/init.lua
    - lua/dbee/ui/drawer/convert.lua
    - lua/dbee/layouts/init.lua
    - lua/dbee/config.lua
    - lua/dbee.lua
    - lua/dbee/ui/editor/init.lua
    - lua/dbee/ui/result/init.lua
    - lua/dbee/ui/call_log.lua

key-decisions:
  - "Drawer yank refuses missing-schema nodes instead of silently downgrading to bare names"
  - "MinimalLayout exposes ensure_drawer_visible() so drawer focus can open-then-focus deterministically"
  - "Headless NAV-02 coverage verifies focus action presence in all 4 pane classes, not just dbee.focus_pane()"

patterns-established:
  - "Clipboard tests assert both unnamed and + registers under headless clipboard stubs"
  - "Pane-jump tests validate call ordering and unsupported-layout WARN branches"

requirements-completed: [CLIP-02, NAV-02]

duration: 1 session
completed: 2026-04-23
---

# Phase 4 Plan 01: Drawer Yank & Pane Jump Summary

**Drawer qualified-name yank (`yy`) and cross-pane focus (`<leader>e/r/d/l`) are implemented and covered by headless regression tests.**

## Performance

- **Completed:** 2026-04-23
- **Tasks:** 2
- **Files modified:** 10

## Accomplishments

- Added drawer `yank_name` behavior for tables, views, routines, and columns with missing-schema refusal and success/warn notifications
- Added `focus_pane()` / `ensure_drawer_visible()` layout APIs plus `dbee.focus_pane()` public dispatcher
- Wired focus actions into drawer, editor, result, and call log panes
- Added headless CLIP-02 and NAV-02 suites covering happy paths, warning paths, ID collision fixtures, layout compatibility, and drawer open-before-focus ordering

## Task Commits

1. **Task 1: Drawer yank_name + pane jump actions (CLIP-02, NAV-02)** - `240c896` (feat)
2. **Task 1 follow-up fix: escape_node_id_part gsub return suppression** - `f7c0c38` (fix)
3. **Task 2: Headless tests for drawer yank + pane jump** - `7ee137e` (test)

## Files Created/Modified

- `lua/dbee/ui/drawer/init.lua` - Added `yank_name` and drawer focus actions
- `lua/dbee/ui/drawer/convert.lua` - Added injective node IDs, `raw_name` on column nodes, and fixed `gsub` return handling in `escape_node_id_part()`
- `lua/dbee/layouts/init.lua` - Added `focus_pane()` and `ensure_drawer_visible()` on default/minimal layouts
- `lua/dbee.lua` - Added `dbee.focus_pane()` public API with compatibility WARN branches
- `lua/dbee/config.lua` - Added default `yy` and `<leader>e/r/d/l` mappings across panes
- `lua/dbee/ui/editor/init.lua` - Added pane focus actions
- `lua/dbee/ui/result/init.lua` - Added pane focus actions
- `lua/dbee/ui/call_log.lua` - Added pane focus actions
- `ci/headless/check_drawer_yank.lua` - Added CLIP-02 regression coverage
- `ci/headless/check_pane_jump.lua` - Added NAV-02 regression coverage

## Issues Encountered

- The new drawer node ID encoder in Task 1 surfaced a Lua multi-return bug: `string.gsub()` returned both encoded text and substitution count, which broke `table.insert()` in `encode_node_segment()`. Fixed in a narrow follow-up commit before running Task 2.

## Deviations from Plan

- No scope deviation. The only extra commit was the targeted Task 1 bug fix inside `lua/dbee/ui/drawer/convert.lua`, which is already in 04-01's approved `files_modified` list.

## User Setup Required

- None.

## Next Phase Readiness

- 04-01 is complete and verified.
- 04-02 remains deferred pending separate filter-plan execution.

## Self-Check: PASSED

- `CLIP02_ALL_PASS=true`
- `NAV02_ALL_PASS=true`
- Task 2 commit scoped to the two `ci/headless/` files only

---
*Phase: 04-drawer-navigation*
*Completed: 2026-04-23*
