# Roadmap: nvim-dbee QoL Improvements

## Overview

This milestone delivers 18 quality-of-life improvements to nvim-dbee, progressing from foundational notification/feedback fixes through clipboard and call log enhancements, new editor and result actions, drawer improvements with pane navigation, and finally resilience and cross-adapter diagnostics. All changes are Lua-only (no Go backend modifications), building on existing extension points (get_actions, event bus, config defaults).

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Notifications & Feedback** - Replace silent failures with vim.notify messages and self-documenting winbar labels
- [ ] **Phase 2: Call Log Enhancements** - Add duration/timestamp display, query copy, and re-run from history
- [ ] **Phase 3: Editor & Result Actions** - Add note cycling, file export, and explain plan execution
- [ ] **Phase 4: Drawer & Navigation** - Add drawer copy/search and dedicated pane-jumping keybindings
- [ ] **Phase 5: Resilience & Diagnostics** - Add auto-reconnect prompt and generic adapter error diagnostics

## Phase Details

### Phase 1: Notifications & Feedback
**Goal**: Every user action produces clear, immediate feedback -- no silent failures, no cryptic labels
**Depends on**: Nothing (first phase)
**Requirements**: NOTIF-01, NOTIF-02, NOTIF-03, NOTIF-04, NOTIF-05, NOTIF-06, NOTIF-07
**Success Criteria** (what must be TRUE):
  1. User sees a vim.notify warning when invoking a run action with no connection selected
  2. User sees a vim.notify warning when executing an empty or blank query
  3. User sees a vim.notify confirmation after yanking rows from the result pane (with row count and format)
  4. User sees vim.notify error messages when drawer operations (add/edit/delete connection) fail, instead of silent swallowing or raw Lua tracebacks
  5. User sees self-documenting winbar labels showing page number, row count, and query duration (e.g., "Page 1/1 | 5 rows | 0.035s")
**Plans**: 2 plans

Plans:
- [ ] 01-01-PLAN.md -- Migrate vim.notify to utils.log in dbee.lua, reword NOTIF-01/02, surface drawer errors (NOTIF-04)
- [ ] 01-02-PLAN.md -- Yank feedback (NOTIF-03/05), schema refresh notification (NOTIF-06), winbar format overhaul (NOTIF-07)

### Phase 2: Call Log Enhancements
**Goal**: Call log becomes a useful audit trail with queryable history
**Depends on**: Phase 1
**Requirements**: CLIP-01, CLOG-01, CLOG-02
**Success Criteria** (what must be TRUE):
  1. User sees duration and timestamp on each call log tree entry without expanding the node
  2. User can yank the SQL text of any call log entry to the clipboard
  3. User can re-run a past query from the call log on the currently selected connection
**Plans**: 2 plans

Plans:
- [ ] 02-01-PLAN.md -- Extract format_duration to utils, add duration/timestamp columns (CLOG-01), yank action (CLIP-01), cleanup
- [ ] 02-02-PLAN.md -- Re-run from history (CLOG-02), headless tests for all Phase 2 features, CI matrix update

### Phase 3: Editor & Result Actions
**Goal**: Users can cycle notes, export results to file, and execute explain plans without leaving nvim-dbee
**Depends on**: Phase 1
**Requirements**: NAV-01, RSLT-01, ADPT-01
**Success Criteria** (what must be TRUE):
  1. User can cycle to next/previous note with keybindings without leaving the editor pane
  2. User can export current result set to a CSV or JSON file via a path prompt
  3. User can execute Explain Plan on the current query and see adapter-appropriate EXPLAIN output in the result pane
**Plans**: 2 plans

Plans:
- [ ] 03-01-PLAN.md -- Note cycling (NAV-01) and file export (RSLT-01) with headless tests
- [ ] 03-02-PLAN.md -- Adapter-aware Explain Plan (ADPT-01) with public API, gE keybinding, headless tests

### Phase 4: Drawer & Navigation
**Goal**: Users can find objects in large schemas and move between panes without manual :wincmd
**Depends on**: Phase 1
**Requirements**: CLIP-02, NAV-02, DRAW-01
**Success Criteria** (what must be TRUE):
  1. User can copy qualified table names (schema.table) and column names from the drawer to clipboard
  2. User can jump focus between editor, result, drawer, and call log panes with dedicated keybindings
  3. User can search/filter tables in the drawer to find objects in schemas with hundreds of tables
**Plans**: 2 plans

Plans:
- [ ] 04-01-PLAN.md -- Drawer yank qualified names (CLIP-02), pane jumping with layout API (NAV-02), headless tests
- [ ] 04-02-PLAN.md -- Live drawer search/filter with NuiInput (DRAW-01), headless tests

### Phase 5: Resilience & Diagnostics
**Goal**: Connection failures surface actionable prompts and query errors show inline markers across all adapters
**Depends on**: Phase 1
**Requirements**: ADPT-02, CONN-01
**Success Criteria** (what must be TRUE):
  1. User sees inline error diagnostics (line/column markers via vim.diagnostic) for query errors from any adapter, not just Oracle
  2. User sees an auto-reconnect prompt when a connection is lost during query execution, following the cancel-confirm prompt pattern
  3. Auto-reconnect prompt includes debounce/cooldown to prevent prompt spam on flapping connections
**Plans**: TBD

Plans:
- [ ] 05-01: TBD
- [ ] 05-02: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3 -> 4 -> 5
Note: Phases 3 and 4 depend only on Phase 1, not on Phase 2. They can execute in parallel if desired.

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Notifications & Feedback | 2/2 | Complete | 2026-03-06 |
| 2. Call Log Enhancements | 2/2 | Complete | 2026-03-07 |
| 3. Editor & Result Actions | 1/2 | In Progress|  |
| 4. Drawer & Navigation | 0/2 | Not started | - |
| 5. Resilience & Diagnostics | 0/0 | Not started | - |
