# Phase 3: Editor & Result Actions - Context

**Gathered:** 2026-03-08
**Status:** Ready for planning

<domain>
## Phase Boundary

Users can cycle notes in the editor, export results to file, and execute explain plans without leaving nvim-dbee. Covers NAV-01, RSLT-01, ADPT-01.

</domain>

<decisions>
## Implementation Decisions

### NAV-01: Note cycling
- Cycle within current namespace only (global OR current connection's notes, not across)
- Wrap around at boundaries (last -> first, first -> last)
- Switching note restores its last query result in the result pane (existing `set_current_note` behavior)
- No notification on cycle -- buffer change is sufficient visual feedback
- Keybindings: `]n` (next note), `[n` (previous note) in editor.mappings
- Uses `namespace_get_notes()` sorted list to determine order

### RSLT-01: File export
- Path input via `vim.ui.input()` prompt (benefits from snacks/dressing overrides)
- Default pre-filled path: `CWD/result.csv`
- Format inferred from file extension: `.csv` -> CSV, `.json` -> JSON, unknown -> warn and abort
- Confirm before overwrite if file already exists (vim.ui.select Yes/No prompt)
- Uses existing Go backend `call_store_result(id, format, "file", { extra_arg = path })` -- no backend changes needed
- Exports all rows (not just current page)
- Success notification: `"Exported N rows to /path/to/file.csv"` via utils.log INFO
- Keybinding: `ge` in result.mappings

### ADPT-01: Explain plan
- Supported adapters: Postgres, MySQL, SQLite, Oracle (top 4)
- Postgres: `EXPLAIN <query>` (no ANALYZE -- safe, no side effects)
- MySQL: `EXPLAIN <query>`
- SQLite: `EXPLAIN QUERY PLAN <query>`
- Oracle: Auto singleton-listener two-step -- execute `EXPLAIN PLAN FOR <query>`, track pending state by call ID, then on archived state auto-execute `SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY)` and show that result
- Oracle lifecycle: Use a singleton `call_state_changed` listener + pending map + timeout cleanup to avoid callback leaks and UI blocking
- Unsupported adapter: WARN notification `"Explain Plan not supported for <adapter-type>"`, no-op
- Works on both query under cursor (normal mode) and visual selection
- Keybinding: `gE` in editor.mappings (normal + visual)
- Result displayed in result pane like any query execution

### Claude's Discretion
- How to determine current namespace for note cycling (from current_note_id or active connection)
- Oracle explain lifecycle details (singleton async listener + pending map + timeout cleanup)
- Whether to add explain_plan to the dbee.actions() picker menu

</decisions>

<specifics>
## Specific Ideas

- `]n`/`[n` follows standard vim bracket-motion convention (like `]d`/`[d` for diagnostics)
- `ge` mnemonic: "get export" or "go export"
- `gE` mnemonic: "go Explain" -- shift-E distinguishes from regular execute
- File export should export ALL rows, not just the current page visible in the result pane
- Oracle EXPLAIN PLAN should feel seamless -- user presses gE, sees plan output, doesn't need to know about the two-step internally

</specifics>

<code_context>
## Existing Code Insights

### Reusable Assets
- `EditorUI:namespace_get_notes(id)` at `editor/init.lua:699` -- returns sorted note list for a namespace
- `EditorUI:set_current_note(id)` at `editor/init.lua:841` -- switches note + restores result
- `EditorUI:search_note(id)` at `editor/init.lua:615` -- finds note across all namespaces, returns namespace
- `call_store_result(id, format, "file", { extra_arg = path })` -- Go backend file export already works
- `dbee.store(format, output, opts)` at `dbee.lua:1265` -- public API wrapper for call_store_result
- `utils.query_under_cursor(bufnr, opts)` at `utils.lua` -- extracts query at cursor position
- `utils.visual_selection()` -- gets visual selection coordinates
- `execute_with_resolved_variables_async()` at `dbee.lua:661` -- handles variable resolution + execution

### Established Patterns
- Actions registered via `get_actions()` -> consumed by `common.configure_buffer_mappings` (editor + result)
- Default keybindings in `config.lua` with `{ key, mode, action }` format
- `utils.log(level, msg)` for all user notifications (Phase 1 pattern)
- `pcall` wrapping for RPC/backend calls with error surfacing

### Integration Points
- `lua/dbee/ui/editor/init.lua` -- add `note_next`/`note_prev` actions to `get_actions()`
- `lua/dbee/ui/result/init.lua` -- add `export_result` action to `get_actions()`
- `lua/dbee/config.lua` -- add default mappings: `]n`/`[n` (editor), `ge` (result), `gE` (editor)
- `lua/dbee.lua` -- add `dbee.explain_plan()` public API function with adapter dispatch
- Adapter type available via `conn.type` from `get_current_connection()`

</code_context>

<deferred>
## Deferred Ideas

None -- discussion stayed within phase scope

</deferred>

---

*Phase: 03-editor-result-actions*
*Context gathered: 2026-03-08*
