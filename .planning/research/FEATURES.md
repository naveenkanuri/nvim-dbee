# Feature Landscape

**Domain:** Neovim database explorer QoL improvements (nvim-dbee)
**Researched:** 2026-03-05
**Competitive context:** vim-dadbod-ui, sqlua.nvim, DBeaver, DataGrip, SSMS, Oracle SQL Developer

## Table Stakes

Features users expect from any database tool worth using. Missing = product feels incomplete.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **Notify on no connection** | Every GUI tool grays out or disables the run button when disconnected. Silent no-ops are the worst UX pattern in database tools -- user thinks query ran. DBeaver shows "No active connection" in status bar. DataGrip disables execute buttons entirely. | Low | Backlog #1. Trivial `vim.notify` guard. |
| **Notify on empty query** | DataGrip shows "Nothing to execute" inline. DBeaver shows "No SQL query found". Every tool acknowledges the attempt. Silent no-op on blank lines makes users question whether their keybinding worked. | Low | Backlog #2. Trivial `vim.notify` guard. |
| **Notify on yank/copy success** | DBeaver shows row count in status bar on copy. DataGrip shows "N rows copied" notification. Neovim convention: plugins like telescope, nvim-tree all confirm clipboard operations. Without feedback, users paste to verify -- extra cognitive load. | Low | Backlog #3. Replace silent yank with `vim.notify("Yanked N rows as CSV")`. |
| **Surface pcall errors** | DBeaver shows modal error dialogs for failed connection operations. DataGrip shows error notifications in the event log. Silently swallowing errors on add/edit/delete connection is a data-loss risk -- user thinks operation succeeded. | Low | Backlog #5. Critical: silent failure on connection management is worse than silent failure on queries. |
| **Better winbar labels** | DataGrip shows "N rows fetched in Xs" prominently. DBeaver shows row count and execution time in the status bar. Current `1/1 (5)` is cryptic -- requires learning what the numbers mean. `Page 1/1 | 5 rows | 0.035s` is self-documenting. | Low | Backlog #6. Pure string format change, no logic change. |
| **Replace error() with vim.notify** | Raw Lua tracebacks on yank failures break the UX contract. Every Neovim plugin uses `vim.notify` for user-facing errors. `error()` dumps stack traces that users cannot act on. | Low | Backlog #13. Mechanical replacement. |
| **Copy table/column names from drawer** | DBeaver has "Copy Name" in right-click context menu for any object. DataGrip: click any object, Ctrl+C copies qualified name. vim-dadbod-ui does not have this (gap in dadbod too). This is table stakes because users constantly need table names for WHERE clauses and JOINs. | Low | Backlog #10. Yank `schema.table` or column name to clipboard. |
| **Jump-between-panes keybindings** | SSMS: F6 toggles query/results. DBeaver: Ctrl+Alt+T switches active panel. DataGrip: Tab/Shift+Tab navigates tool windows. Oracle SQL Developer: Alt+PageDown/PageUp. Every database IDE has dedicated focus-switching keys. vim-dadbod-ui lacks this too -- but nvim-dbee has more panes (editor, result, drawer, call_log) making it more critical. | Low | Backlog #12. Map dedicated keys per pane. |

## Differentiators

Features that set nvim-dbee apart from vim-dadbod-ui. Not universally expected in terminal tools, but valued.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **Re-run query from call log** | DataGrip: double-click query history to paste into editor, re-execute. DBeaver: Query History panel with re-execute. vim-dadbod-ui has NO query history re-run capability -- you can save queries, but not re-execute from history. **Strong differentiator** vs dadbod. nvim-dbee already has the call log with query text; surfacing re-run is low-hanging fruit. | Low-Med | Backlog #8. Query text already stored in call objects. Wire `conn:execute(call.query)` on the current connection. |
| **Export results to file** | DBeaver: full export wizard (CSV, JSON, XML, SQL INSERT, clipboard). DataGrip: similar multi-format export. vim-dadbod-ui: requested feature (issue #181) but NOT implemented. nvim-dbee already has `store_result` with JSON/CSV output to register -- extending to file output is natural. **Strong differentiator** vs dadbod. | Low-Med | Backlog #9. `vim.ui.input` for path, call existing `store_result` with file output. |
| **Copy query text from call log** | Neither dadbod nor most terminal DB tools let you yank historical query text. DBeaver has "Copy SQL" in Query Manager. Useful for Slack/docs/debugging. | Low | Backlog #4. Add yank action to call_log node. |
| **Duration/timestamp in call log** | DataGrip shows execution time per query in the output log. DBeaver shows timestamps in Query History. Currently call_log shows query text only -- adding duration and timestamp makes it a proper audit trail. | Low | Backlog #14. Data already exists in call object (`time_taken_us`). Format and display. |
| **Schema refresh notification** | DBeaver shows progress bar during schema refresh. DataGrip shows "Synchronizing..." with spinner. Low-impact but closes a feedback gap -- user presses refresh and sees nothing happen until the tree updates. | Low | Backlog #7. `vim.notify` before/after refresh. |
| **Next/previous note keybinding** | No equivalent in dadbod (dadbod uses file-per-query model, not notes). DataGrip: Ctrl+Tab cycles query files. Having keybinds to cycle notes without leaving the editor is a workflow speed improvement unique to nvim-dbee's note model. | Low | Backlog #11. Cycle `self.notes` index, call `set_note`. |
| **Explain Plan action** | DataGrip: Ctrl+Shift+E generates visual explain plan with flame graph visualization. DBeaver: Shift+Ctrl+E shows cost-based plan graph. vim-dadbod-ui: NO built-in explain plan support -- users must manually type `EXPLAIN` prefix. **Major differentiator**. Per-adapter syntax is the challenge: `EXPLAIN` (Postgres/MySQL), `EXPLAIN PLAN FOR` (Oracle), `SET SHOWPLAN_TEXT ON` (SQL Server). | Medium | Backlog #15. Need adapter-specific EXPLAIN prefix map. Text output to result pane -- not trying to match GUI graphical plans. |
| **Drawer search/filter** | DBeaver: type-ahead filter bar in Database Navigator with partial matching, pipe/comma multi-filter. DataGrip: Ctrl+F in database explorer with regex support. vim-dadbod-ui: NO schema search/filter capability. For schemas with 500+ tables (common in enterprise Oracle), essential for productivity. **Strong differentiator** vs dadbod. | Medium-Large | Backlog #17. Consider Telescope picker approach (fits 2-pane constraint better than inline filter). |
| **Generic adapter error diagnostics** | DataGrip: inline error highlighting with red underline, gutter markers, Alt+Enter quick-fixes. DBeaver: error position highlighting in editor. vim-dadbod-ui: NO inline error markers. nvim-dbee already has Oracle-specific diagnostics via `diag_ns` -- generalizing to all adapters is natural. Leverages Neovim's native `vim.diagnostic` API. **Strong differentiator.** | Medium | Backlog #16. Need adapters to return line/column error position. Parse error messages for position info. |
| **Auto-reconnect prompt on disconnect** | DBeaver: "Invalidate/Reconnect" button + auto-attempt. DataGrip: auto-reconnect on query execution. vim-dadbod-ui: no auto-reconnect. Follows cancel-confirm pattern already built -- prompt user before re-executing. | Medium | Backlog #18. Detect disconnect error from Go backend, surface prompt in Lua. |

## Anti-Features

Features to explicitly NOT build.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| **Graphical explain plan visualization** | DataGrip flame graphs and DBeaver cost graphs require GUI rendering. TUI cannot replicate node graphs. ASCII art diagrams are a maintenance burden for marginal value. | Render EXPLAIN output as tabular text in result pane. Text output is what developers actually read. |
| **Multi-format export wizard** | DBeaver's 5-step export wizard is over-engineered for a terminal tool. nvim-dbee users are power users who know what format they want. | CSV and JSON export to file. `vim.ui.select` for format, `vim.ui.input` for path. Two prompts, not a wizard. |
| **Full-text search across query results** | Searching result data is a database concern (`WHERE` clause), not a UI concern. Client-side result filter duplicates database functionality. | Neovim's native `/` search works on the result buffer already. |
| **Query autocompletion in editor** | Building completion into nvim-dbee is massive scope expansion (LSP-like functionality). vim-dadbod-completion exists as separate plugin for dadbod. | Separate project. Schema data could feed a completion source later. |
| **Connection pooling / keep-alive** | DBeaver's keep-alive is buggy even in a mature GUI tool. Connection lifecycle should be simple. | Auto-reconnect prompt (#18) handles the user-facing concern. |
| **Query formatting / SQL beautifier** | Separate concern. sql-formatter.nvim and conform.nvim handle this. | Document integration with existing formatters. |
| **Result set editing (UPDATE via grid)** | Massive feature with transaction safety, optimistic locking, multi-adapter variance. Not QoL. | Users edit data by writing UPDATE statements. |

## Feature Dependencies

```
Notify on no connection (#1) --> Re-run from call log (#8)
  (Re-run needs the "no connection" guard since it runs on current connection)

Notify on empty query (#2) --> Explain Plan (#15)
  (Explain wraps query text; empty query check applies)

Surface pcall errors (#5) --> Auto-reconnect prompt (#18)
  (Reconnect prompt triggers on specific error types from pcall)

Replace error() with vim.notify (#13) --> Export to file (#9)
  (Export uses the same store wrappers that currently use error())

Copy table/column names (#10) --> Drawer search/filter (#17)
  (Search finds objects; copy extracts their names. Both operate on drawer nodes)

Duration/timestamp in call log (#14) --> Re-run from call log (#8)
  (Re-run is more useful when you can see WHEN a query ran and HOW LONG it took)

Generic error diagnostics (#16) -- independent but benefits from:
  - Explain Plan (#15): EXPLAIN can help understand errors
  - Better winbar labels (#6): error state shown in winbar

Explain Plan (#15) -- requires:
  - Per-adapter EXPLAIN syntax map (new data structure)
  - Result pane display (existing infrastructure)
```

## MVP Recommendation

### Phase 1: Notification Foundation (7 items, all Low complexity)

Prioritize all table-stakes items first. Trivial to implement, dramatically improve UX, create notification infrastructure that later features depend on.

1. Notify on no connection (#1) -- HIGH impact, guards all run actions
2. Notify on empty query (#2) -- prevents user confusion
3. Surface pcall errors (#5) -- CRITICAL, silent failures on connection management
4. Notify on yank success (#3) -- closes feedback loop
5. Replace error() with vim.notify (#13) -- consistency
6. Better winbar labels (#6) -- self-documenting result pane
7. Schema refresh notification (#7) -- closes last feedback gap

### Phase 2: Clipboard and Navigation (5 items, Low complexity)

Ergonomic improvements that make daily workflows faster.

1. Copy query from call log (#4) -- simple yank action
2. Copy table/column names from drawer (#10) -- clipboard for schema objects
3. Next/previous note keybinding (#11) -- note cycling
4. Jump-between-panes keybindings (#12) -- pane focus management
5. Duration/timestamp in call log (#14) -- audit trail

### Phase 3: Re-run and Export (2 items, Low-Med complexity)

Key differentiators over vim-dadbod-ui that build on Phase 1/2 infrastructure.

1. Re-run query from call log (#8) -- strong differentiator, depends on #1 and #14
2. Export results to file (#9) -- strong differentiator, depends on #13

### Phase 4: Advanced Features (4 items, Medium+ complexity)

Features requiring adapter awareness and deeper architectural work.

1. Explain Plan (#15) -- per-adapter syntax wrapping
2. Generic error diagnostics (#16) -- adapter error parsing
3. Drawer search/filter (#17) -- tree filtering or Telescope integration
4. Auto-reconnect prompt (#18) -- disconnect detection + prompt UX

**Defer:** Nothing deferred entirely. All 18 are legitimate QoL gaps. Phase 4 items need phase-specific research before implementation (especially #15 and #16 with per-adapter variance).

## Competitive Position Summary

| Capability | nvim-dbee (current) | vim-dadbod-ui | DBeaver | DataGrip |
|-----------|-------------------|---------------|---------|----------|
| Query execution feedback | Partial (spinner, but silent on empty/no-conn) | Minimal (results appear or don't) | Full (status bar, notifications) | Full (inline, status, event log) |
| Result export | Yank to register (CSV/JSON) | None (open issue) | Full wizard (CSV/JSON/XML/SQL) | Full (multi-format) |
| Query history re-run | View only (call log) | Save queries (manual) | Full (Query History + re-execute) | Full (browse + paste + execute) |
| Schema search/filter | None | None | Type-ahead filter, metadata search | Ctrl+F with regex |
| Explain plan | None | None (manual prefix) | Visual cost graph | Flame graph, visual plan |
| Error diagnostics | Oracle only (vim.diagnostic) | None | Error position highlighting | Inline + gutter + quick-fix |
| Copy object names | None | None | Right-click "Copy Name" | Ctrl+C on any object |
| Pane navigation | None (manual :wincmd) | None | Ctrl+Alt+T panel switch | Tab navigation |
| Auto-reconnect | None | None | Invalidate/Reconnect | Auto on query |
| Yank feedback | None | None | Row count in status bar | "N rows copied" |

**Key takeaway:** nvim-dbee's biggest competitive gaps vs dadbod-ui are in feedback/notifications (solvable with trivial changes) and schema search (medium effort). Its biggest differentiation opportunities are re-run from history, file export, explain plan, and generic error diagnostics -- none of which dadbod-ui offers.

## Sources

- [vim-dadbod-ui GitHub](https://github.com/kristijanhusak/vim-dadbod-ui)
- [vim-dadbod export issue #181](https://github.com/tpope/vim-dadbod/issues/181)
- [DBeaver Data Export docs](https://dbeaver.com/docs/dbeaver/Data-export/)
- [DBeaver Database Navigator](https://dbeaver.com/docs/dbeaver/Database-Navigator/)
- [DBeaver Filter Database Objects](https://dbeaver.com/docs/dbeaver/Filter-Database-Objects/)
- [DBeaver Invalidate/Reconnect](https://dbeaver.com/docs/dbeaver/Invalidate-and-Reconnect-to-Database/)
- [DBeaver Query Execution Plan](https://github.com/dbeaver/dbeaver/wiki/Query-Execution-Plan)
- [DataGrip Query Execution features](https://www.jetbrains.com/datagrip/features/executing.html)
- [DataGrip Query Execution Plan docs](https://www.jetbrains.com/help/datagrip/query-execution-plan.html)
- [DataGrip Code Insight features](https://www.jetbrains.com/datagrip/features/coding_assistance.html)
- [DataGrip UX Survey #2 Results](https://blog.jetbrains.com/datagrip/2025/08/04/datagrip-and-database-tools-ux-survey-2-results/)
- [sqlua.nvim GitHub](https://github.com/Xemptuous/sqlua.nvim)
- [nvim-dbee vs dadbod discussion](https://github.com/kndndrj/nvim-dbee/discussions/119)
- [DBeaver jump Navigator/Editor issue #9304](https://github.com/dbeaver/dbeaver/issues/9304)
