# Requirements: nvim-dbee QoL Improvements

**Defined:** 2026-03-05
**Core Value:** Every user action should give clear, immediate feedback — no silent failures, no missing affordances, no dead ends.

## v1 Requirements

Requirements for this milestone. Each maps to roadmap phases.

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
- [ ] **CLIP-02**: User can copy table/column qualified names from drawer to clipboard
- [x] **NAV-01**: User can cycle to next/previous note with keybindings without leaving editor
- [ ] **NAV-02**: User can jump between panes (editor/result/drawer/call_log) with dedicated keybindings

### Call Log Enhancements

- [x] **CLOG-01**: User sees duration and timestamp inline on each call log tree entry
- [x] **CLOG-02**: User can re-run a past query from call log on the current connection

### Result Pane

- [x] **RSLT-01**: User can export results to a file (CSV/JSON) from the result pane via path prompt

### Adapter Features

- [ ] **ADPT-01**: User can execute Explain Plan on current query with per-adapter EXPLAIN syntax wrapping
- [ ] **ADPT-02**: User sees inline error diagnostics (line/column markers) for all adapters, not just Oracle

### Drawer

- [ ] **DRAW-01**: User can search/filter tables in the drawer to find objects in large schemas

### Connection Management

- [ ] **CONN-01**: User sees an auto-reconnect prompt when a connection is lost (similar to cancel-confirm)

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
| CLIP-02 | Phase 4 | Pending |
| NAV-01 | Phase 3 | Complete |
| NAV-02 | Phase 4 | Pending |
| CLOG-01 | Phase 2 | Complete |
| CLOG-02 | Phase 2 | Complete |
| RSLT-01 | Phase 3 | Complete |
| ADPT-01 | Phase 3 | Pending |
| ADPT-02 | Phase 5 | Pending |
| DRAW-01 | Phase 4 | Pending |
| CONN-01 | Phase 5 | Pending |

**Coverage:**
- v1 requirements: 18 total
- Mapped to phases: 18
- Unmapped: 0

---
*Requirements defined: 2026-03-05*
*Last updated: 2026-03-05 after roadmap creation*
