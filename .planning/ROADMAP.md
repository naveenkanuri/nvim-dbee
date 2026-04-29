# Roadmap: nvim-dbee Connection UX & Performance Improvements

## Overview

Milestone v1.0 delivered 18 quality-of-life improvements to nvim-dbee across notifications, call history, editor/result actions, drawer navigation, resilience, and diagnostics. Milestone v1.1 focuses on the next dominant usability gap: managing real connection configurations without hand-editing JSON, adding drawer-local async table/view child fetch with the minimum bounded materialization needed to make it usable, organizing notes outside the drawer, and promoting DRAW-01 performance evidence to release-grade real-`nui.nvim` coverage. The remaining connection-expand `connection_list_databases()` seam and the deferred cross-module lifecycle ownership move to Phase 7 (`DCFG-01`).

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)
- v1.1 continues from Phase 6 because `$gsd-new-milestone` was run without `--reset-phase-numbers`

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Notifications & Feedback** - Replace silent failures with vim.notify messages and self-documenting winbar labels
- [x] **Phase 2: Call Log Enhancements** - Add duration/timestamp display, query copy, and re-run from history
- [x] **Phase 3: Editor & Result Actions** - Add note cycling, file export, and explain plan execution
- [x] **Phase 4: Drawer & Navigation** - Add drawer copy/search and dedicated pane-jumping keybindings
- [x] **Phase 5: Resilience & Diagnostics** - Add auto-reconnect prompt and generic adapter error diagnostics
- [ ] **Phase 6: Structure Laziness & Notes Picker** - Add drawer-local async table/view child fetch, the supporting bounded child materialization it needs, and a sectioned notes picker
- [ ] **Phase 7: Connection-Only Drawer** - Re-scope drawer to saved connections, activation, CRUD affordances, test, reload, and structure navigation
- [ ] **Phase 8: Type-Aware Connection Wizard** - Add Oracle/Postgres connection forms, URL round-tripping, driver ping, and atomic FileSource persistence
- [ ] **Phase 9: Real-Nui Drawer Perf Harness** - Promote DRAW-01 perf validation from non-release smoke to real-`nui.nvim` release evidence

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
  1. User can copy qualified database object names from the drawer to clipboard (schema.object for tables/views/procedures/functions, schema.table.column for columns)
  2. User can jump focus between editor, result, drawer, and call log panes with dedicated keybindings
  3. User can search/filter searchable database objects in the drawer to find objects in schemas with hundreds of tables when the required cache is ready, and gets a WARN instead of a partial/ambiguous filter corpus when it is not
**Plans**: 2 plans

Plans:
- [x] 04-01-PLAN.md -- Drawer yank qualified names (CLIP-02), pane jumping with layout API (NAV-02), headless tests
- [x] 04-02-PLAN.md -- Live drawer search/filter with NuiInput (DRAW-01), headless tests

### Phase 5: Resilience & Diagnostics
**Goal**: Connection failures surface actionable prompts and query errors show inline markers across all adapters
**Depends on**: Phase 1
**Requirements**: ADPT-02, CONN-01
**Status**: Complete (`a233f01..c7b8ab3`)
**Success Criteria** (what must be TRUE):
  1. User sees inline error diagnostics (line/column markers via vim.diagnostic) for query errors from any adapter, not just Oracle
  2. User sees an auto-reconnect prompt when a connection is lost during query execution, following the cancel-confirm prompt pattern
  3. Auto-reconnect prompt includes debounce/cooldown to prevent prompt spam on flapping connections
**Plans**: 2 plans

Plans:
- [x] 05-01-PLAN.md -- Auto-reconnect prompt, bounded replay registry, connection rewrite/rebind flow, and headless coverage
- [x] 05-02-PLAN.md -- Adapter diagnostics registry, connection-scoped namespace lifecycle, and CI/headless coverage

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3 -> 4 -> 5
Note: Phases 3 and 4 depend only on Phase 1, not on Phase 2. They can execute in parallel if desired.

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Notifications & Feedback | 2/2 | Complete | 2026-03-06 |
| 2. Call Log Enhancements | 2/2 | Complete | 2026-03-07 |
| 3. Editor & Result Actions | 2/2 | Complete | 2026-03-09 |
| 4. Drawer & Navigation | 2/2 | Complete | 2026-04-23 |
| 5. Resilience & Diagnostics | 2/2 | Complete (`a233f01..c7b8ab3`) | 2026-04-24 |

## Milestone Summary

- Milestone v1.0 is complete: 5/5 phases and 10/10 plans shipped
- Commit range: `a233f01..c7b8ab3`
- Delivered scope: notifications and feedback, call log history actions, editor/result actions, drawer navigation and filtering, and resilience plus diagnostics
- Phase 5 closed with reconnect registry coverage (`CONN-01`) and adapter diagnostics coverage (`ADPT-02`) verified clean at impl-gate

## Milestone v1.1: Drawer Connection Config + Structure Perf + Notes UX

**Goal:** Users can manage saved connections from the drawer, get drawer-local async table/view child loading plus the supporting bounded branch materialization it needs, and find notes through a global/local picker while Phase 7 absorbs the remaining lifecycle seams.

**Requirements:** DCFG-01, DCFG-02, STRUCT-01, NOTES-01, PERF-01

### Phase 6: Structure Laziness & Notes Picker

**Goal**: Remove the easiest drawer contention first by adding drawer-owned async table/view child fetch, bounded child materialization, and a dedicated notes picker without claiming the remaining connection-expand seam or reconnect continuity are solved.
**Depends on**: Phase 5
**Requirements**: STRUCT-01, NOTES-01
**Success Criteria** (what must be TRUE):
  1. Drawer-owned full-tree root loads are fenced by `root_epoch` plus `caller_token`, and table/view expansion uses additive async child fetch with preserved `materialization`.
  2. Per-connection structure cache entries are keyed by connection and branch identity, `R` and `database_selected` clear only the targeted drawer cache before reload, and root/branch error state remains explicit inside `_struct_cache` rather than disappearing on later rerender.
  3. Oversized child branches render the first 1000 nodes promptly and expose a "Load more..." sentinel for the tail.
  4. `<leader>ef` opens a snacks picker with "Global notes" above "Local notes (current connection)", tagging items as `[global]` or `[local: conn_name]`.
**Plans**: TBD by `$gsd-plan-phase 6`

**Research bullets:**
- Reuse existing `connection_get_structure_async`, `structure_loaded(request_id)`, and DRAW-01 snapshot/session contracts from Phase 4.
- Confirm the additive table/view child-fetch path carries `materialization = struct.type` from drawer node dispatch through the Go endpoint and child event so table/view column semantics stay truthful.
- Keep the remaining `connection_list_databases()` connection-expand seam explicitly assigned to Phase 7 (`DCFG-01`) rather than treating Phase 6 root-payload delivery as proof of end-to-end expand responsiveness.
- Keep drawer-visible reconnect continuity explicitly assigned to Phase 7 (`DCFG-01`) rather than letting Phase 6's cache work imply a solved reconnect contract.
- Study current `pick_notes` snacks formatting and editor namespace APIs before introducing section headers.

### Phase 7: Connection-Only Drawer

**Goal**: Turn the drawer into a connection-management surface instead of a mixed tree of notes, source controls, connections, and structure, and absorb the deferred cross-module lifecycle ownership that Phase 6 intentionally left out.
**Depends on**: Phase 6
**Requirements**: DCFG-01
**Success Criteria** (what must be TRUE):
  1. Drawer root contains saved connections only, with notes removed from the drawer entirely.
  2. `<CR>` on a connection toggles expansion into schemas, tables, columns, indexes, sequences, and foreign keys using the Phase 6 lazy-loading contract.
  3. Drawer mappings expose `a`, `e`, `dd`, `t`, `<C-CR>`, `R`, and `/` for add, edit, delete, test, activate, reload structure, and filter.
  4. CRUD/test failures surface through `utils.log`/`vim.notify` with actionable messages and preserve the existing active connection when operations fail.
  5. Source actions and public source-lifecycle methods own one canonical rerender/invalidation contract, including `connection_invalidated`, failure emit behavior, and close-vs-refresh callback dispatch, instead of hidden double-refresh or stale-tree windows.
  6. `current_connection_changed`, manual reconnect, source reload, and current-selection retention follow one canonical cross-module contract shared by drawer, handler, reconnect, and LSP.
  7. Drawer and LSP coordinate full-tree `connection_get_structure_async()` so same-connection root warmups are coalesced instead of duplicated.
  8. Invalidation and expand flows are backpressured, startup invalidation is idempotent, reconnect/source-reload choreography is explicit, and the remaining synchronous `connection_list_databases()` expand seam is absorbed into the drawer rewrite rather than left as an unowned residual.
**Plans**: TBD by `$gsd-plan-phase 7`

**Research bullets:**
- Audit `lua/dbee/ui/drawer/init.lua`, `model.lua`, `convert.lua`, and `config.lua` mapping contracts before removing editor note nodes.
- Verify how `source_add_connection`, `source_update_connection`, `source_remove_connection`, `source_reload`, and `set_current_connection` report failures.
- Decide the canonical ownership for source-action callbacks, `current_connection_changed`, and reload/current-selection semantics across drawer, handler, reconnect, and LSP.
- Choose a drawer/LSP single-flight or piggyback rule for full-tree root loads and a backpressure rule for invalidation-driven rewarm.
- Decide whether source-level "edit source" remains accessible through an action picker or is intentionally deprecated from the drawer.

### Phase 8: Type-Aware Connection Wizard

**Goal**: Let users add/edit Oracle and Postgres connections through form-based flows that save compatible URLs safely.
**Depends on**: Phase 7
**Requirements**: DCFG-02
**Success Criteria** (what must be TRUE):
  1. Add/edit opens a modal form whose middle section swaps between Oracle Cloud Wallet, Oracle Custom JDBC, Postgres Form, and Postgres URL modes.
  2. Oracle Cloud Wallet mode accepts username, password, wallet directory or `.zip`, service dropdown from `tnsnames.ora`, and SSL toggles.
  3. Oracle Custom JDBC and Postgres URL modes preserve raw text areas without lossy rewriting; Postgres Form mode parses/saves a compatible URL.
  4. Test performs a real driver-level connection attempt before save and blocks save on failure unless the user explicitly cancels.
  5. FileSource writes are atomic via temp-file-plus-rename, preserve non-edited fields where possible, and never corrupt `connections.json` on encode/write failure.
**Plans**: TBD by `$gsd-plan-phase 8`

**Research bullets:**
- Research Oracle JDBC wallet URL shapes, wallet `.zip` extraction expectations, and `tnsnames.ora` service parsing edge cases.
- Research Postgres URL parsing/encoding in Lua and expected `sslmode`, `schema`, and `application_name` query parameters.
- Inspect existing Nui popup/form helpers and other Neovim plugin patterns for multi-field modal forms before introducing new UI primitives.
- Confirm which core API should perform connection test/ping without mutating current connection state.

### Phase 9: Real-Nui Drawer Perf Harness

**Goal**: Convert DRAW-01 performance validation from non-release smoke to release-grade headless evidence with real `nui.nvim`.
**Depends on**: Phase 6
**Requirements**: PERF-01
**Success Criteria** (what must be TRUE):
  1. CI/headless test loads real `nui.nvim` from `RUNNER_TEMP/nui.nvim` using the same install path as CI.
  2. `DRAW01_PERF_MODE=real-nui` exercises real `menu.filter`, `nui.input`, and `nui.tree` paths rather than stubs.
  3. The locked DRAW-01 corpus reports startup, snapshot, model-build, prompt-mount, apply, restore, and soak metrics with the existing Phase 4 budgets.
  4. The test fails closed if real `nui.nvim` is unavailable in release mode; `non-release-smoke` remains clearly labeled as smoke-only.
**Plans**: TBD by `$gsd-plan-phase 9`

**Research bullets:**
- Re-read `.planning/phases/04-drawer-navigation/04-02-PLAN.md` and `04-VALIDATION.md` for the exact DRAW-01 perf metrics and locked corpus.
- Verify `.github/workflows/test.yml` current `nui.nvim` install path and runtimepath setup.
- Inspect `ci/headless/check_drawer_filter.lua` to separate stubs that are still valid from stubs that invalidate real-nui perf claims.

## v1.1 Progress

**Execution Order:**
Phase 6 -> Phase 7 -> Phase 8. Phase 9 depends on Phase 6 and can run before or after Phase 8 if capacity allows.

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 6. Structure Laziness & Notes Picker | 0/TBD | Pending | - |
| 7. Connection-Only Drawer | 0/TBD | Pending | - |
| 8. Type-Aware Connection Wizard | 0/TBD | Pending | - |
| 9. Real-Nui Drawer Perf Harness | 0/TBD | Pending | - |

## Open Product Questions

- DCFG-02: Should saved passwords be written literally into `connections.json` when entered in the wizard, or should the wizard default to/template environment placeholders?
- DCFG-02: If Oracle Cloud Wallet service discovery cannot parse `tnsnames.ora`, should the wizard allow manual service entry or require fixing the wallet first?
- DCFG-01: Should source-file editing remain reachable from a secondary action outside the drawer after notes/source utility rows are removed?

## Milestone v1.2: LSP Optimization

**Goal:** Optimize the built-in dbee LSP while preserving the in-process singleton-per-current-connection architecture and the v1.1 handler-owned lifecycle contracts.

**Roadmap artifact:** `.planning/milestones/v1.2-roadmap.md`

**Requirements:** LSP-PERF-01, LSP-OPT-01, LSP-CORR-01, LSP-FEAT-01 (conditional)

**Phase ordering:** Phase 10 -> Phase 11 -> conditional Phase 12.

### Phase 10: LSP Perf Harness

**Goal**: Stand up a `benchmark.nvim`-driven headless LSP perf harness before changing behavior.
**Depends on**: Phase 9
**Requirements**: LSP-PERF-01
**Success Criteria** (what must be TRUE):
  1. `make perf-lsp` runs locally and uses the same pinned plugin bootstrap pattern as the Phase 9 `make perf` path.
  2. CI has Linux and macOS advisory LSP perf lanes with grep-friendly markers, median/p95 reporting, and uploaded artifacts.
  3. The harness measures cold LSP start, table completion with 100/1000/10000-table caches, cold `column_of_table` completion, diagnostics over 100/1000/10000-line buffers, and alias parsing scaling.
  4. Interactive `bench.lua` remains available, but relevant steps are converted into deterministic headless benchmark scenarios.
**Plans**: TBD by `$gsd-plan-phase 10`

**Research bullets:**
- Reuse `ci/headless/perf_bootstrap.mk`, pinned `benchmark.nvim`, pinned `profile.nvim`, and `ci/headless/perf_thresholds.lua` patterns from Phase 9.
- Keep the initial lane advisory, with advisory-to-blocking promotion after four weeks at `>=95%` pass rate per platform.
- Avoid live database dependencies; use synthetic caches and fake handler surfaces for blocking evidence.

### Phase 11: LSP Perf Optimization And Correctness

**Goal**: Remove completion/diagnostics/cache hot-path hazards and fix real diagnostics correctness bugs surfaced by research.
**Depends on**: Phase 10
**Requirements**: LSP-OPT-01, LSP-CORR-01
**Success Criteria** (what must be TRUE):
  1. Cold-cache alias/table dot completion returns immediately, warms columns asynchronously, dedupes in-flight work, and sets `isIncomplete = true` only for truthful in-flight misses.
  2. `SchemaCache` precomputes sorted completion arrays and case-folded lookup indexes, caps in-memory columns with a 500-table LRU, and prunes disk column-cache files older than 30 days on startup.
  3. `didChange` diagnostics are debounced by default at 250ms, with save-only/off config options.
  4. Diagnostics support multi-line `FROM`/`JOIN`, fix multi-JOIN-per-line range placement, and validate schema-qualified table references by schema.
  5. Disk cache writes are atomic temp-file-plus-rename writes and cache read/write failures are logged instead of silently swallowed.
  6. `bench.lua` uses `vim.uv` instead of `vim.loop`.
**Plans**: TBD by `$gsd-plan-phase 11`

**Research bullets:**
- Adopt `nvim-nio` as a peer dependency for future/coroutine orchestration, but use it over the existing `connection_get_columns_async` / `structure_children_loaded` event surface rather than wrapping synchronous `connection_get_columns()`.
- Preserve singleton-per-current-connection LSP behavior for v1.2; multi-client/per-buffer connection models are deferred.
- Keep the built-in dbee LSP as the canonical completion surface while preserving external `cmp-dbee` compatibility.

### Phase 12: LSP Feature Gap Closure

**Goal**: Add high-value LSP features that can be supported truthfully from schema/cache state.
**Depends on**: Phase 11
**Requirements**: LSP-FEAT-01
**Status**: Conditional. Decide at Phase 11 ship.
**Success Criteria** (what must be TRUE):
  1. If Phase 10+11 finish with budget headroom and no major regressions, v1.2 may add completion resolve/details, hover, schema refresh/reload code actions, and schema object symbols.
  2. Semantic tokens, inlay hints, `vim.lsp.config()` migration, and multi-client LSP architecture remain deferred unless explicitly re-scoped.
**Plans**: TBD by `$gsd-plan-phase 12` if activated

**Research bullets:**
- Feature work must remain additive and must not reopen Phase 10/11 perf and correctness locks.
- Prefer cache-backed, truthful features over parser-heavy SQL intelligence.

## v1.2 Progress

**Execution Order:**
Phase 10 -> Phase 11. Phase 12 is conditional at Phase 11 ship.

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 10. LSP Perf Harness | 0/TBD | Pending | - |
| 11. LSP Perf Optimization And Correctness | 0/TBD | Pending | - |
| 12. LSP Feature Gap Closure | 0/TBD | Conditional | - |
