# Phase 2: Call Log Enhancements - Context

**Gathered:** 2026-03-06
**Status:** Ready for planning

<domain>
## Phase Boundary

Call log becomes a useful audit trail with queryable history. Add duration and timestamp inline on each tree entry, copy query SQL to clipboard, and re-run past queries from history. Covers CLIP-01, CLOG-01, CLOG-02.

</domain>

<decisions>
## Implementation Decisions

### CLOG-01: Inline display format
- Layout: append duration + timestamp after query text: `[icon] ┃ query_text... | 35ms | 14:32`
- Reuse Phase 1's adaptive `format_duration()` logic: <1s -> ms, >=1s -> seconds, >=60s -> min+sec
- In-progress calls (executing/retrieving): show "..." placeholder for duration
- Timestamp format: HH:MM for today's calls, MM-DD HH:MM for older calls (smart date detection)
- Query text column shrinks to accommodate duration + timestamp columns

### CLIP-01: Query yank behavior
- Yank the full original query, preserving newlines and formatting
- Target both unnamed (`"`) and system clipboard (`+`) registers — same behavior as result pane yank
- Keybinding: `yy` (double-tap, intentional action)
- Notification: `"Yanked query (N chars)"` via `utils.log` INFO — consistent with Phase 1 yank notifications

### CLOG-02: Re-run from history
- Re-run executes on the **currently selected** connection, not the original connection
- Keybinding: `R` (shift-R) — intentional, distinct from `<CR>` (show_result)
- Auto-opens dbee UI if closed, same as `execute_context` behavior
- Bind variables: re-prompt via `execute_with_resolved_variables_async` — user can update values before re-running
- If no connection selected: show WARN notification (same as NOTIF-01 pattern)

### Cleanup
- Migrate `call_log.lua:202` raw `vim.notify` in `cancel_call` to `utils.log` for consistency with Phase 1

### Claude's Discretion
- Exact query text truncation length (currently 40 chars, may need adjustment for new columns)
- Column width padding/alignment strategy for duration and timestamp
- Whether to extract `format_duration` to a shared utility or inline it

</decisions>

<specifics>
## Specific Ideas

- Call log line preview chosen by user: `󰑐 ┃ SELECT * FROM users WHERE...  | 35ms  | 14:32`
- Duration and timestamp should be right-aligned and consistently spaced for visual scanning
- `yy` for yank was chosen over single `y` to avoid accidental triggers

</specifics>

<code_context>
## Existing Code Insights

### Reusable Assets
- `format_duration(time_taken_us)` in `result/init.lua` — adaptive ms/s/min formatting, reusable for CLOG-01
- `utils.log()` — notification framework from Phase 1
- `execute_with_resolved_variables_async()` in `dbee.lua:661` — handles bind variable resolution, reusable for CLOG-02
- `core.get_call_history()` in `api/core.lua:230` — already formats call metadata for display

### Established Patterns
- `CallLogUI:get_actions()` returns action map, consumed by `common.configure_buffer_mappings` — new actions (yank, re-run) follow this pattern
- `NuiLine:append()` for tree node rendering — duration/timestamp added as additional appends in `create_tree`
- `call_log_config.mappings` in `config.lua:306` — default keybindings configured here
- Phase 1 yank pattern: `pcall` + `utils.log` for error handling, `vim.fn.setreg` for register writes

### Integration Points
- `lua/dbee/ui/call_log.lua` — primary file: modify `create_tree` (display), add `yank_query` and `rerun_query` actions
- `lua/dbee/config.lua:300` — add default mappings for `yy` and `R`
- `lua/dbee.lua` — may need public API entry point for re-run (to access `execute_with_resolved_variables_async`)
- `CallDetails` type provides: `query`, `time_taken_us`, `timestamp_us`, `state` — all fields needed for Phase 2

</code_context>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 02-call-log-enhancements*
*Context gathered: 2026-03-06*
