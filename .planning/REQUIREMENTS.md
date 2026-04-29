# Requirements: nvim-dbee Connection UX & Performance Improvements

**Defined:** 2026-03-05
**Core Value:** Every user action should give clear, immediate feedback — no silent failures, no missing affordances, no dead ends.

## v1.0 Requirements

Completed requirements from the v1.0 QoL milestone. Each maps to roadmap phases.

### Notifications

- [x] **NOTIF-01**: User is notified when no connection is selected and a run action is invoked
- [x] **NOTIF-02**: User is notified when cursor query is empty/blank
- [x] **NOTIF-03**: User is notified on successful yank from result pane
- [x] **NOTIF-04**: User sees error messages from drawer operations (add/edit/delete connections) instead of silent swallowing
- [x] **NOTIF-05**: User sees `vim.notify` messages instead of raw Lua tracebacks on yank failures
- [x] **NOTIF-06**: User is notified when schema refresh completes
- [x] **NOTIF-07**: User sees self-documenting winbar labels: `Page 1/1 | 5 rows | 0.035s` instead of cryptic `1/1 (5)`

### Clipboard & Navigation

- [x] **CLIP-01**: User can copy query text from call log entries to clipboard
- [x] **CLIP-02**: User can copy qualified database object names from drawer to clipboard
- [x] **NAV-01**: User can cycle to next/previous note with keybindings without leaving editor
- [x] **NAV-02**: User can jump between panes (editor/result/drawer/call_log) with dedicated keybindings

### Call Log Enhancements

- [x] **CLOG-01**: User sees duration and timestamp inline on each call log tree entry
- [x] **CLOG-02**: User can re-run a past query from call log on the current connection

### Result Pane

- [x] **RSLT-01**: User can export results to a file (CSV/JSON) from the result pane via path prompt

### Adapter Features

- [x] **ADPT-01**: User can execute Explain Plan on current query with per-adapter EXPLAIN syntax wrapping
- [x] **ADPT-02**: User sees inline error diagnostics (line/column markers) for all adapters, not just Oracle

### Drawer

- [x] **DRAW-01**: User can search/filter searchable database objects in the drawer to find objects in large schemas

### Connection Management

- [x] **CONN-01**: User sees an auto-reconnect prompt when a connection is lost (similar to cancel-confirm)

## v1.1 Requirements

Requirements for the Drawer Connection Config + Structure Perf + Notes UX milestone.

### Drawer Connection Config

- [x] **DCFG-01**: User can manage saved connections from a connection-only drawer tree with add, edit, delete, test, activate, reload-structure, expand/collapse, and filter controls, and Phase 7 owns the deferred cross-module lifecycle contracts for `connection_invalidated` ownership, public source-lifecycle invalidation/failure choreography, source-action close-vs-refresh dispatch, connection-selection/current-connection behavior, reconnect/source-reload coordination, reload/current-selection semantics, drawer/LSP root-load coordination, drawer-visible reconnect continuity after `connection_rewritten`, invalidation backpressure, startup invalidation safety, and the remaining `connection_list_databases()` expand seam
- [x] **DCFG-02**: User can add or edit Oracle and Postgres connections through type-aware forms that round-trip existing URL formats, test the real driver connection before save, and persist atomically to FileSource-backed JSON

### Structure Browser Performance

- [x] **STRUCT-01**: User gets drawer-owned async table/view child fetch with truthful `materialization = struct.type`, bounded in-drawer child materialization, and drawer-owned root fencing via `caller_token` plus `root_epoch`; reconnect continuity and the remaining `connection_list_databases()` connection-expand seam are explicitly deferred to Phase 7 (`DCFG-01`)

### Notes Picker

- [x] **NOTES-01**: User can open a single-select notes picker that visually separates global notes from current-connection local notes and tags each item with its source

### Drawer Performance Harness

- [x] **PERF-01**: User can rely on DRAW-01 release readiness because headless performance tests load real `nui.nvim` from `RUNNER_TEMP/nui.nvim` and enforce realistic frame-budget metrics instead of stub-only smoke evidence

## v1.2 Requirements

Requirements for the built-in dbee LSP optimization milestone.

### LSP Performance Harness

- [x] **LSP-PERF-01**: User can rely on built-in dbee LSP optimization work because Phase 10 provides deterministic headless macOS and Linux perf evidence for production LSP startup, completion, diagnostics, alias parsing, schema-cache build, and disk-cache load/save, using pinned Phase 9 perf infrastructure, `LSP01_*` markers, semantic sentinels, and advisory-to-blocking threshold persistence.

### LSP Optimization

- [x] **LSP-OPT-01**: User gets a bounded built-in dbee LSP editing path because Phase 11 removes synchronous column metadata fetches from completion, warms missing columns through the existing async handler event surface, dedupes in-flight misses by connection/schema/table/materialization/root epoch, caps in-memory column cache with a 500-table LRU, precomputes schema/table/column completion indexes, debounces `didChange` diagnostics by default, and writes/prunes LSP disk cache safely.

### LSP Correctness

- [x] **LSP-CORR-01**: User gets truthful static LSP schema diagnostics because Phase 11 validates multi-line `FROM`/`JOIN` references, fixes multi-JOIN-per-line diagnostic ranges, treats schema-qualified `schema.table` references as schema-aware, separates LSP schema warnings from adapter execution diagnostics by namespace/source/severity, and ignores stale async column results across reconnect/source/database invalidations.

## v1.3 Requirements

Requirements for the Enterprise DB UX + v1.2 Closure milestone.

### Regression Closure

- [ ] **DBEE-UX-01**: User can rely on primary v1.1/v1.2 workflows because the add/edit connection wizard renders typed text and selects visibly on dark colorschemes, drawer `/` filters the connection-only root when structure cache is empty, and first-run pre-v1.2 LSP cache recovery does not present routine migration as corrupt-cache data loss.

### Enterprise DB Architecture

- [ ] **DBEE-ARCH-01**: User can constrain large enterprise connections to an explicit schema allowlist and browse progressively because connection JSON persists additive `schema_filter` metadata, initial structure loading fetches schemas only, table lists load lazily per schema, and drawer, LSP completion, diagnostics, and schema cache all honor the same filter.

### Polish

- [ ] **DBEE-POLISH-01**: User sees bounded, coherent LSP and drawer polish because case-colliding schema lookup indexes match full rebuild behavior, targeted global-index updates avoid walking unrelated schemas, source badges show only when multiple sources need disambiguation, cold drawer start has visual orientation, and long loading states expose elapsed/timeout/cancel affordances.

### Conditional LSP Features

- [ ] **DBEE-FEAT-02**: User can use additive built-in dbee LSP feature surfaces deferred from Phase 12: completion item resolve/details, hover for table/column metadata, schema refresh/reload code actions, and document/workspace symbols for cached schema objects, only if mandatory v1.3 phases finish with budget headroom and no major regressions.

## v2 Requirements

Deferred to future milestone. Tracked but not in current roadmap.

### Visual Enhancements

- **VIS-01**: Graphical explain plan visualization (flame graph / cost tree)
- **VIS-02**: Multi-format export wizard with preview

### Editor Intelligence

- **EDIT-01**: Query autocompletion from schema metadata
- **EDIT-02**: SQL formatting integration

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| New database adapter support | Separate effort, not QoL |
| Result set editing (UPDATE via grid) | Massive feature with transaction safety concerns |
| Full-text search across query results | Neovim's native `/` search works on result buffer |
| Connection pooling / keep-alive | Auto-reconnect prompt (#CONN-01) handles user-facing concern |
| Query formatting / beautifier | Separate concern — sql-formatter.nvim and conform.nvim handle this |
| Breaking API changes | All improvements must be additive/backward-compatible |
| Bulk connection import/export UI | Single-connection CRUD addresses the dominant pain point first |
| Wizard support for every adapter type | v1.1 focuses on Oracle and Postgres because those are the observed real configurations |
| Notes CRUD redesign | v1.1 moves note discovery to picker sections but leaves note creation/rename/delete flows unchanged unless required by drawer extraction |
| Pre-existing `a and nil or b` Lua pattern cleanup | Deferred to v1.4 per v1.3 scope guard |
| Four pre-existing legacy headless failures | Deferred to v1.4; not caused by Phase 10/11 and not part of v1.3 primary UX scope |
| Semantic tokens, inlay hints, `vim.lsp.config()` migration, multi-client LSP architecture | Explicitly outside v1.3; conditional Phase 16 is limited to resolve, hover, code actions, and symbols |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| NOTIF-01 | Phase 1 | Complete |
| NOTIF-02 | Phase 1 | Complete |
| NOTIF-03 | Phase 1 | Complete |
| NOTIF-04 | Phase 1 | Complete |
| NOTIF-05 | Phase 1 | Complete |
| NOTIF-06 | Phase 1 | Complete |
| NOTIF-07 | Phase 1 | Complete |
| CLIP-01 | Phase 2 | Complete |
| CLIP-02 | Phase 4 | Complete |
| NAV-01 | Phase 3 | Complete |
| NAV-02 | Phase 4 | Complete |
| CLOG-01 | Phase 2 | Complete |
| CLOG-02 | Phase 2 | Complete |
| RSLT-01 | Phase 3 | Complete |
| ADPT-01 | Phase 3 | Complete |
| ADPT-02 | Phase 5 | Complete |
| DRAW-01 | Phase 4 | Complete |
| CONN-01 | Phase 5 | Complete |
| DCFG-01 | Phase 7 | Complete |
| DCFG-02 | Phase 8 | Complete |
| STRUCT-01 | Phase 6 | Complete |
| NOTES-01 | Phase 6 | Complete |
| PERF-01 | Phase 9 | Complete |
| LSP-PERF-01 | Phase 10 | Complete |
| LSP-OPT-01 | Phase 11 | Complete |
| LSP-CORR-01 | Phase 11 | Complete |
| DBEE-UX-01 | Phase 13 | Pending |
| DBEE-ARCH-01 | Phase 14 | Pending |
| DBEE-POLISH-01 | Phase 15 | Pending |
| DBEE-FEAT-02 | Phase 16 | Conditional |

**Coverage:**
- v1.0 requirements: 18 total, 18 complete
- v1.1 requirements: 5 total, 5 complete
- v1.2 requirements: 3 total, 3 complete
- v1.3 requirements: 4 total, 4 mapped
- Unmapped: 0

---
*Requirements defined: 2026-03-05*
*Last updated: 2026-04-29 after v1.3 milestone definition*
