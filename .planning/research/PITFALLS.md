# Domain Pitfalls

**Domain:** Neovim database explorer plugin QoL improvements
**Researched:** 2026-03-05

---

## Critical Pitfalls

Mistakes that cause rewrites, regressions, or subtle bugs across the 18 QoL items.

### Pitfall 1: Notification Spam and Feedback Loop Storms

**What goes wrong:** Adding `vim.notify` calls to every validation path (items 1-3, 5, 7, 13) creates notification floods. A user pressing `<CR>` on an empty line repeatedly sees a wall of "No SQL statement" toasts. Worse: notification plugins like `nvim-notify` or `noice.nvim` override `vim.notify`, and some users configure aggressive animation/stacking. If the plugin fires `vim.notify` from inside an event callback that triggers a re-render, it can create an infinite feedback loop (ModeChanged -> scheduled callback -> notify -> redraw -> ModeChanged).

**Why it happens:** Each item is implemented independently and nobody tests them in combination. The "add vim.notify" items look trivial so they get copy-pasted without throttling.

**Consequences:** Plugin gains reputation for being noisy. Users file issues asking how to suppress notifications. Interaction with `noice.nvim` can cause z-index conflicts or blank notification windows (known Neovim issue #27467).

**Prevention:**
- Use `vim.log.levels.WARN` only for actionable errors. Use `vim.log.levels.INFO` sparingly (yank success, schema refresh).
- Never call `vim.notify` from inside an event listener callback that triggers tree refresh or buffer redraw. Schedule notifications with `vim.schedule` to decouple from the render cycle.
- Deduplicate: if the same message was shown in the last 2 seconds, skip it. A simple module-level timestamp check is sufficient.
- Existing convention: the codebase already uses `vim.notify(msg, vim.log.levels.WARN)` consistently. Follow this pattern exactly. Do not introduce `utils.log` for user-facing messages (that is for internal debug logging).

**Detection:** Test by holding down a keybinding that triggers a guarded path. If notifications pile up, you have this bug.

**Affects items:** 1, 2, 3, 5, 7, 13

---

### Pitfall 2: Winbar Format String Evaluated in Wrong Window Context

**What goes wrong:** The winbar string (item 6) is set with `vim.api.nvim_win_set_option(self.winid, "winbar", ...)`. Neovim evaluates `%{...}` expressions in winbar strings in the context of the window being drawn, not the window that set the option. If you use dynamic `%{` expressions (e.g., to show live row count), the expression evaluates against whichever window is currently being redrawn, not the result window. This causes cross-window contamination where the editor winbar shows result metadata.

**Why it happens:** Developers familiar with statusline patterns assume winbar works the same way. The subtle difference between `%!` (evaluates for focused window) and `%{` (evaluates for the window being drawn) trips up plugin authors. The current code uses a plain string (`string.format("...")`) without `%` expressions, which is safe. The danger is "improving" it to use dynamic evaluation.

**Consequences:** Wrong metadata displayed in wrong pane. Intermittent visual glitches that only appear in specific window layouts.

**Prevention:**
- Keep the current approach: compute the string value at render time using `string.format` and set it as a static string. Do not use `%{` or `%!` expressions in the winbar value.
- The existing code at `result/init.lua:264` already does this correctly: `string.format("%d/%d (%d)%%=Took %.3fs", ...)`. Extend this pattern.
- For the improved format (`Page 1/1 | 5 rows | 0.035s`), just change the format string. No architecture change needed.
- Always guard `self:has_window()` before setting winbar (already done at line 260).

**Detection:** Open dbee with a split layout showing multiple panes. If result metadata appears in the editor winbar or drawer winbar, you have this bug.

**Affects items:** 6

---

### Pitfall 3: Drawer Filter Destroys Expansion State and Lazy Children

**What goes wrong:** Implementing drawer search/filter (item 17) by rebuilding the NuiTree with only matching nodes destroys the expansion state snapshot. The current `refresh()` method at `drawer/init.lua:553-578` captures expansion with `expansion.get(self.tree)`, rebuilds all nodes, then restores with `expansion.set(self.tree, exp)`. If filtering removes nodes that were expanded, the expansion IDs become orphaned. Worse: connection nodes use `lazy_children` functions that fetch structure from cache. If a filter hides a connection node but its lazy children were already loaded, removing and re-adding the node loses the loaded children, triggering a re-fetch from the database.

**Why it happens:** NuiTree does not have native filter support. The `NuiTree:set_nodes()` call replaces the entire node tree. Neo-tree and nvim-tree both had to solve this independently, and both had significant bugs around filter state (neo-tree issue #1459, nvim-tree issue #1146). The temptation is to filter at the node construction level (`convert.lua`), but this couples filtering logic to every node type.

**Consequences:** Users expand a schema, type a filter, clear the filter, and find all their expansions collapsed. Or: clearing a filter re-fetches structure from the database, causing a visible loading delay.

**Prevention:**
- Filter at the rendering level, not the data level. Keep the full node tree intact. Add a `filter_text` field to `DrawerUI`. In `create_tree`'s `prepare_node`, return an empty/hidden line for nodes that don't match the filter. This preserves expansion state because the tree structure is unchanged.
- Alternative: maintain a parallel `filtered_node_ids` set. During `prepare_node`, check membership. This avoids rebuilding the tree entirely.
- Store the `structure_cache` expansion separately from the visual filter. Never clear `structure_cache` when filtering.
- Provide a keybinding to toggle filter mode (like `/` in the drawer buffer). Use `vim.fn.input` or a prompt buffer at the bottom of the drawer for the filter text. Clear filter on `<Esc>`.
- Match against both `node.name` and `node.schema` for qualified matches. Always use case-insensitive matching (`node.name:lower():find(filter:lower(), 1, true)`) because Oracle stores names in UPPERCASE while PostgreSQL lowercases by default.

**Detection:** Expand a connection with 50+ tables. Filter for a table name. Clear the filter. If the connection is collapsed or shows "loading...", you have this bug.

**Affects items:** 17

---

### Pitfall 4: Cross-Adapter EXPLAIN Syntax is Not Just a Prefix

**What goes wrong:** Implementing Explain Plan (item 15) by simply prepending `EXPLAIN` to the user's query works for PostgreSQL (`EXPLAIN query`) and MySQL (`EXPLAIN query`), but fails for Oracle (requires `EXPLAIN PLAN FOR query` followed by a separate `SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY)`) and SQL Server (requires `SET SHOWPLAN_XML ON; query; SET SHOWPLAN_XML OFF;` or wrapping in `SET STATISTICS PROFILE ON`). SQLite uses `EXPLAIN QUERY PLAN query`. Treating EXPLAIN as a universal prefix produces errors or empty results on half the adapters.

**Why it happens:** The developer tests on PostgreSQL (where it works) and assumes other databases follow the same pattern. The adapter abstraction (`GetHelpers`) returns simple query strings, not multi-step execution workflows.

**Consequences:** EXPLAIN action produces errors on Oracle, SQL Server, ClickHouse. Users on those databases lose trust in the feature. If the EXPLAIN wrapping modifies the original query text and that modification persists (e.g., written back to the note buffer), the user's query is corrupted.

**Prevention:**
- Do NOT modify the user's query text in the buffer. Construct the explain query in a transient variable and execute it without touching the editor buffer.
- Implement EXPLAIN as a per-adapter helper in `GetHelpers()`. Each adapter already has a `GetHelpers(*TableOptions) map[string]string` method. But EXPLAIN operates on a user query, not a table -- so this needs a different mechanism. Add a new Lua-side function that wraps the user's query with per-adapter EXPLAIN syntax.
- For Oracle: the two-step EXPLAIN PLAN pattern needs to execute two statements. Use the existing script execution infrastructure (`execute_script`) or execute them as a PL/SQL block. Oracle's `DBMS_XPLAN.DISPLAY_CURSOR` is the modern alternative that works with `SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR())` after any execution.
- For SQL Server: the XML plan output requires special handling. Consider using `SET SHOWPLAN_TEXT ON` as a simpler alternative.
- For databases where EXPLAIN returns a result set (PostgreSQL, MySQL, SQLite), the existing result pane handles it. For databases where EXPLAIN writes to a plan table (Oracle), the adapter needs a follow-up query.
- The `conn.type` field already exists in `ConnectionParams` to determine which EXPLAIN strategy to use.

**Detection:** Run the Explain action against each supported adapter. If any adapter returns an error or empty result, the implementation is incomplete.

**Affects items:** 15

---

### Pitfall 5: Generic Error Diagnostics Without Adapter-Specific Parsers

**What goes wrong:** Extending Oracle-only error diagnostics (item 16) to all adapters by using a generic line/column parser that assumes all databases report errors the same way. PostgreSQL says `ERROR: syntax error at or near "SELCT" LINE 1: SELCT * FROM...`. MySQL says `ERROR 1064 (42000): You have an error in your SQL syntax; ... near 'SELCT * FROM' at line 1`. Oracle says `ORA-06550: line 2, column 5`. SQL Server says `Msg 102, Level 15, State 1, Line 1`. Each format is different, and a generic regex will match the wrong numbers or miss entirely.

**Why it happens:** The existing `parse_oracle_error_location()` at `editor/init.lua:10-31` works for Oracle because it was purpose-built. Generalizing it looks like "just add more regex patterns." But each adapter reports line numbers differently: some are 1-indexed, some 0-indexed. Some report the line relative to the query, others relative to the batch. SQL Server's `Line 1` means line 1 of the batch, not line 1 of the file.

**Consequences:** Diagnostic markers placed on wrong lines. A line 3 error in the query appears on line 3 of the buffer even though the query started on line 10. The existing Oracle code handles this with `exec_offset` (line 989: `local buf_line = exec_offset + err_line - 1`), but a generic parser might forget this offset adjustment.

**Prevention:**
- Create a per-adapter error parser interface. In Lua, this is a function `parse_error_location(err_msg) -> line?, col?` keyed by adapter type.
- Register parsers: `oracle -> parse_oracle_error_location`, `postgres -> parse_postgres_error_location`, `mysql -> parse_mysql_error_location`, etc.
- Always apply `exec_offset` when converting error line to buffer line. The existing pattern at `editor/init.lua:989` is the model.
- Guard against the adapter type being unknown: fall back to no diagnostic rather than a wrong diagnostic. The current code already does this (line 975: `if not exec_conn_type or exec_conn_type:lower() ~= "oracle" then return end`). Replace the hard return with a parser lookup.
- PostgreSQL format: `LINE (\d+):` with column from caret position in the next line.
- MySQL format: `at line (\d+)` (no column info typically).
- SQL Server format: `Line (\d+)` (no column typically).
- SQLite format: varies widely, often no line info.

**Detection:** Execute a syntax error query on each adapter. If the diagnostic marker appears on the wrong line or doesn't appear at all when it should, the parser is wrong.

**Affects items:** 16

---

### Pitfall 6: Keybinding Conflicts with User Mappings and Plugin Ecosystem

**What goes wrong:** Adding new keybindings (items 11, 12) that conflict with user-configured mappings or other plugins. The dbee drawer already maps `<CR>`, `o`, `cw`, `dd`, `r`, `gC`, `y`, `q`, `<Esc>`. Adding jump-between-panes keybindings (like `<C-h>`, `<C-l>`) conflicts with common split navigation. Adding next/prev note keybindings in the editor buffer conflicts with whatever the user has mapped in normal mode for their regular editing.

**Why it happens:** Dbee keybindings are buffer-local (set via `common.configure_buffer_mappings` with `buffer = bufnr`), but the keymap choices are made without knowing the user's global keymaps. The config system allows users to override mappings, but the defaults must be reasonable. Worse: some users use `which-key.nvim` which detects conflicting keybindings and shows warnings.

**Consequences:** Users' split navigation breaks when focus is in a dbee buffer. `which-key.nvim` shows conflict warnings. Users have to read docs to figure out how to override defaults.

**Prevention:**
- For jump-between-panes (item 12): do NOT add buffer-local keybindings for this. Instead, add it as actions (`focus_editor`, `focus_result`, `focus_drawer`, `focus_call_log`) that users can map themselves. Provide suggested mappings in documentation but don't set them by default.
- For next/prev note (item 11): add as actions in the editor's `get_actions()` method. Add default keybindings using keys that don't conflict with common editor use. `]n` / `[n` (next/prev note) follows Neovim's `]` / `[` convention for "next/prev" and is unlikely to conflict.
- Always make keybindings configurable via the existing `mappings` config pattern. Every default binding must appear in `config.default` so users can override it.
- Never use `<leader>` prefix in plugin keybindings. The leader key belongs to the user.

**Detection:** Open dbee with a fresh config that includes `which-key.nvim`. If any conflict warnings appear, the defaults are wrong. Test with common navigation plugins (vim-tmux-navigator, smart-splits.nvim).

**Affects items:** 11, 12

---

## Moderate Pitfalls

### Pitfall 7: Export to File Blocks the UI on Large Results

**What goes wrong:** Export to file (item 9) calls `handler:call_store_result(call_id, format, "file", { extra_arg = path })` which goes through Go's `CallStoreResult`. This is a synchronous RPC call (`sync = true` in the endpoint registration at `__register.lua:23`). For large result sets (10K+ rows as JSON), the serialization and file write blocks the Neovim event loop. The UI freezes with no progress indication.

**Why it happens:** The existing yank operations use the same synchronous path but they yank small selections (one row, one page). Export-all is the first operation that touches the full result set through this path.

**Consequences:** Multi-second UI freeze on large exports. Users think Neovim crashed. No way to cancel mid-export.

**Prevention:**
- For MVP, accept the synchronous limitation but show a notification before and after: `vim.notify("Exporting...", vim.log.levels.INFO)` before the RPC call, `vim.notify("Exported to " .. path, vim.log.levels.INFO)` after.
- Validate the file path before calling Go: check `vim.fn.isdirectory(vim.fn.fnamemodify(path, ":h"))` to avoid cryptic Go errors.
- If the result set has fewer than 10K rows, synchronous is fine. For larger sets, document the limitation.
- Future improvement: add an async export endpoint. Not needed for QoL pass.

**Detection:** Export a 50K-row result to JSON file. If the UI freezes for more than 2 seconds with no feedback, you have this issue.

**Affects items:** 9

---

### Pitfall 8: Re-Run Query Uses Stale Connection Context

**What goes wrong:** Re-running a past query from call log (item 8) executes the historical query text on the current connection. If the user switched connections since the original execution, the query runs against the wrong database. If the original query used bind variables that were prompted at execution time, the re-run skips the variable prompts because the query text is already resolved.

**Why it happens:** The call log stores the final executed query text (after variable resolution). The call log entry's `conn_id` may differ from the current active connection. The re-run action naturally uses `handler:connection_execute(current_conn_id, historical_query)` rather than re-executing on the original connection.

**Consequences:** Query runs on wrong database. Possible data modification on wrong target (if re-running an UPDATE/INSERT). User sees unexpected results without understanding why.

**Prevention:**
- Show the connection name in the call log entry (item 14 adds duration/timestamp, but connection name is also useful context).
- When re-running, check if current connection matches the original. If not, show a confirmation: "This query was originally run on [conn_A]. Re-run on [conn_B]?"
- For re-run, use the current connection by design (this is the expected behavior for "re-run on current"). Make this explicit in the action label: "Re-run on Current Connection".
- Do NOT try to re-execute on the original connection automatically -- the user may have switched on purpose.

**Detection:** Run a query on Postgres, switch to Oracle, re-run from call log. If it executes without any indication of connection mismatch, the UX is misleading.

**Affects items:** 8

---

### Pitfall 9: Auto-Reconnect Prompt Races with Cancel-Confirm Prompt

**What goes wrong:** The auto-reconnect prompt (item 18) follows the cancel-confirm pattern (which uses `vim.ui.select` with state machine management). If a disconnect happens while a cancel-confirm prompt is already open, two prompts compete for the same UI space. The state machine fields (`_confirm_pending`, `_confirm_conn_id`, `_confirm_resolve`) are designed for one prompt at a time.

**Why it happens:** The cancel-confirm prompt was built as a one-off. Adding a second prompt type using the same pattern requires generalizing the state machine, which is easy to get wrong. The `call_state_changed` event fires for both query failures and disconnections, and both prompt types listen to this event.

**Consequences:** Double prompts confuse the user. One prompt's resolution callback fires and auto-dismisses the other. State corruption in the `_confirm_*` fields leads to orphaned pickers or missed dismiss signals.

**Prevention:**
- Do NOT use the cancel-confirm's state machine fields for auto-reconnect. Create a separate set of state fields (`_reconnect_pending`, `_reconnect_conn_id`, etc.).
- Add a guard: if `_confirm_pending` is true, defer the reconnect prompt until after the cancel-confirm resolves.
- The cancel-confirm prompt already has a double-execution guard (`if resolved then return end`). The reconnect prompt needs the same pattern.
- Consider debouncing disconnect detection. A flaky connection may fire multiple disconnect events in rapid succession. Only show one reconnect prompt per connection per 5 seconds.

**Detection:** Start a long-running query, simulate a disconnect (kill the database container), and observe if both prompts appear simultaneously.

**Affects items:** 18

---

### Pitfall 10: pcall Error Surfacing Breaks Silent Fallback Behavior

**What goes wrong:** Surfacing errors from drawer `pcall`-wrapped operations (item 5) by adding `vim.notify` to the `pcall` failure branch changes behavior that some users depend on. Currently, `pcall(handler.source_add_connection, ...)` at `convert.lua:173` silently ignores failures. If a source's `create` function throws because the file is read-only, the user currently gets no error and the drawer just doesn't update. Adding a notification makes this visible, which is good, but some failures are expected (e.g., canceling the prompt returns nil which causes an error in the handler).

**Why it happens:** `pcall` wrapping was added as a catch-all to prevent Lua tracebacks reaching the user. Some of the wrapped calls legitimately fail on user cancellation (closing a prompt without entering values). Treating all `pcall` failures as errors worth notifying creates false positive error notifications.

**Consequences:** User cancels the "Add Connection" prompt and sees "Error: ..." notification. This is confusing because they intentionally canceled.

**Prevention:**
- Distinguish between user-initiated cancellation and actual errors. After `pcall`, check if the error message indicates cancellation (empty input, nil value) versus a real failure (file permission, invalid URL format).
- Pattern: `local ok, err = pcall(...); if not ok and err and not is_cancellation(err) then vim.notify(tostring(err), vim.log.levels.WARN) end`
- For add/edit/delete operations, validate the input before calling the handler. If name/type/url are empty after the prompt, don't call the handler at all -- just return silently.

**Detection:** Open the "Add Connection" prompt and press Escape without entering anything. If an error notification appears, the surfacing is too aggressive.

**Affects items:** 5

---

## Minor Pitfalls

### Pitfall 11: Copy Table/Column Name Inconsistency Across Adapters

**What goes wrong:** Copying table/column names from the drawer (item 10) uses `node.name` directly. But name formatting varies: Oracle stores names in UPPERCASE. PostgreSQL lowercases by default. Some schemas use qualified names (`schema.table`), others don't. The drawer node has both `name` and `schema` fields, but which combination to copy is ambiguous.

**Prevention:**
- Copy the fully qualified name by default: `schema.name`. If schema is empty, copy just `name`.
- Use the adapter's identifier quoting convention if available (double-quotes for PostgreSQL, backticks for MySQL, brackets for SQL Server). For MVP, just copy the raw name without quoting -- users can add quotes themselves.
- Follow the existing `vim.v.register` pattern used in `result/init.lua` yank actions for register consistency.

**Affects items:** 10

---

### Pitfall 12: Note Cycling Keybindings Lose Unsaved Changes

**What goes wrong:** Next/previous note cycling (item 11) switches the displayed buffer in the editor window. If the current note has unsaved changes and the new note's buffer is loaded, the switch proceeds but the user may not realize they left unsaved work. With `bufhidden = "delete"` (set in editor buffer options), switching away from a modified buffer could trigger a prompt or error.

**Prevention:**
- The editor notes use `bufhidden = "delete"` in `buffer_options`. However, note buffers are tied to files (`note.file`), so they persist to disk. The `modified` flag is cosmetic since notes auto-save. Verify this assumption before relying on it.
- If notes don't auto-save, prompt before switching: `vim.api.nvim_get_option_value("modified", { buf = current_bufnr })`.
- Follow the existing `set_current_note()` pattern which already handles buffer switching safely.

**Affects items:** 11

---

### Pitfall 13: Call Log Duration Display Precision and Timezone

**What goes wrong:** Showing duration and timestamp inline in call log entries (item 14) requires formatting `time_taken_us` (microseconds) and `timestamp_us`. The timestamp is in microseconds since epoch. Converting to human-readable time without considering the user's timezone produces confusing results. Also, displaying "0.000s" for sub-millisecond queries looks like zero.

**Prevention:**
- For duration: use the existing `%.3fs` format (already used in result winbar at `result/init.lua:264`). This is sufficient precision.
- For timestamp: use `os.date("%H:%M:%S", math.floor(timestamp_us / 1000000))` for local time. Do not include the date -- just time. Call log entries are session-scoped so the date is always today.
- Handle missing/zero timestamps gracefully. Old call log entries restored from disk may have `timestamp_us = 0`.

**Affects items:** 14

---

### Pitfall 14: Replace error() Cascading to Caller Exception Handling

**What goes wrong:** Replacing `error()` with `vim.notify` in yank wrappers (item 13) changes the control flow. Currently, `store_current_wrapper` at `result/init.lua:429` calls `error("no call set to result")` which propagates up through `pcall` in the caller. If the caller depends on the error to stop execution, replacing with `vim.notify` + `return` changes the semantics. Any downstream code that used `pcall` on the yank action to detect failure now gets `true` instead of `false`.

**Prevention:**
- Check all callers of the yank actions. They are invoked from `get_actions()` return table, which is called from buffer keymappings. Keymapping callbacks don't use `pcall` -- they are fire-and-forget. So replacing `error()` with `vim.notify() + return` is safe for the keybinding path.
- Verify that `do_action()` at `result/init.lua:326-331` handles the case where the action returns early. Currently it calls `act()` without checking return value, so early return is fine.

**Affects items:** 13

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|-------------|---------------|------------|
| Quick Wins (items 1-7) | Notification spam from combining multiple notify additions | Test all 7 items together, not in isolation. Ensure no feedback loops from event listeners. |
| Yank/Copy additions (items 3, 4, 10, 13) | Inconsistent register usage (`vim.v.register` vs `"+"` hardcoded) | Audit all existing yank code in result/init.lua. Follow the existing `vim.v.register` pattern. |
| Keybindings (items 11, 12) | Conflicts with user's global mappings | Use `]n`/`[n` convention. Don't add jump-between-panes as defaults -- expose as actions only. |
| Winbar (item 6) | Breaking existing tests or automation that parses winbar text | If headless tests or automation rely on the current `1/1 (5)` format, updating the format breaks them. Check CI scripts. |
| Explain Plan (item 15) | Assuming all databases use `EXPLAIN <query>` syntax | Implement per-adapter via Lua-side wrapping function. Oracle requires two-step execution. |
| Error diagnostics (item 16) | Wrong diagnostic line due to missing exec_offset adjustment | Copy the offset-adjustment pattern from existing Oracle diagnostic code verbatim. |
| Drawer filter (item 17) | Filter destroys tree expansion state | Filter at render level (prepare_node), not at data level (set_nodes). |
| Auto-reconnect (item 18) | State machine conflict with cancel-confirm prompt | Separate state fields. Guard against concurrent prompts. |

---

## Sources

- [Neovim diagnostic documentation](https://neovim.io/doc/user/diagnostic.html)
- [Neovim winbar/statusline notes](https://theopark.me/blog/2025-06-08-statusline-notes/)
- [nvim-notify blank notifications issue](https://github.com/neovim/neovim/issues/27467)
- [Neovim keybinding override issue](https://github.com/neovim/neovim/issues/25101)
- [Neo-tree filter bug](https://github.com/nvim-neo-tree/neo-tree.nvim/issues/1459)
- [Neo-tree search scope limitation](https://github.com/nvim-neo-tree/neo-tree.nvim/issues/1637)
- [vim.schedule race conditions discussion](https://github.com/neovim/neovim/issues/22263)
- [EXPLAIN PLAN syntax across databases](https://www.cleverence.com/articles/oracle-documentation/explain-plan-database-7361/)
- [Custom diagnostics in Neovim](https://www.janekbieser.dev/posts/custom-diagnostics-in-neovim/)
- Codebase analysis: `lua/dbee/ui/editor/init.lua` (diagnostic namespace, cancel-confirm state machine), `lua/dbee/ui/result/init.lua` (winbar format, yank wrappers, store_result calls), `lua/dbee/ui/drawer/init.lua` (tree creation, expansion, refresh cycle), `lua/dbee/ui/drawer/convert.lua` (node construction, pcall wrapping), `lua/dbee/ui/drawer/expansion.lua` (expansion state get/set), `lua/dbee/config.lua` (default keybindings), `lua/dbee.lua` (actions palette, execute flow), `dbee/handler/handler.go` (CallStoreResult sync path), `dbee/adapters/adapters.go` (GetHelpers pattern)

---

*Pitfalls audit: 2026-03-05*
