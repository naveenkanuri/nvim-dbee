# Architecture Patterns

**Domain:** QoL improvements for nvim-dbee (Go+Lua Neovim database explorer)
**Researched:** 2026-03-05

## Existing Architecture Summary

nvim-dbee is a two-process plugin:
- **Go backend** (`dbee/`): Database I/O, result caching, call state machine, adapter registry
- **Lua frontend** (`lua/dbee/`): All UI (editor, result, drawer, call_log), keybindings, event dispatch
- **Communication**: Bidirectional RPC over msgpack. Lua calls Go via `vim.fn.DbeeXxx()`. Go fires events to Lua via `ExecLua` into the event bus at `lua/dbee/handler/__events.lua`.
- **Events**: `call_state_changed`, `current_connection_changed`, `database_selected`, `structure_loaded`
- **UI Components**: EditorUI, ResultUI, DrawerUI, CallLogUI -- each registers event listeners and manages its own buffer/window

## Layer Map for All 18 QoL Items

### Layer Classification Key

| Layer | Description | Requires Go? | Requires Recompile? |
|-------|-------------|-------------|-------------------|
| **L1: Lua-only, single file** | Add `vim.notify`, tweak format string | No | No |
| **L2: Lua-only, cross-component** | New actions, keybindings, component interaction | No | No |
| **L3: Lua + config** | New mappings in config defaults, new config options | No | No |
| **L4: Go helpers** | Add EXPLAIN queries to adapter `GetHelpers()` | Yes | Yes |
| **L5: Go + Lua** | New RPC endpoints, new events, error parsing changes | Yes | Yes |

### Item-by-Layer Matrix

| # | Item | Layer | Files Affected | Go Change? |
|---|------|-------|---------------|-----------|
| 1 | Notify on no connection | L1 | `editor/init.lua` (3 actions) | No |
| 2 | Notify on empty cursor query | L1 | `editor/init.lua` (run_under_cursor) | No |
| 3 | Notify on yank success | L1 | `result/init.lua` (3 store wrappers) | No |
| 4 | Copy query from call log | L2 | `call_log.lua` (new action + mapping) | No |
| 5 | Show errors from drawer pcall | L1 | `drawer/convert.lua` (3 pcall sites) | No |
| 6 | Better winbar labels | L1 | `result/init.lua` (display_result) | No |
| 7 | Schema refresh notification | L1 | `drawer/init.lua` (refresh action) | No |
| 8 | Re-run query from call log | L2 | `call_log.lua`, `handler/init.lua` | No |
| 9 | Export to file from result | L2 | `result/init.lua` (new action) | No |
| 10 | Copy table/column names from drawer | L2 | `drawer/init.lua` or `convert.lua` | No |
| 11 | Next/previous note keybinding | L2+L3 | `editor/init.lua`, `config.lua` | No |
| 12 | Jump-between-panes keybindings | L3 | `config.lua`, `layouts/init.lua` | No |
| 13 | Replace `error()` with `vim.notify` in yank | L1 | `result/init.lua` (store wrappers) | No |
| 14 | Duration/timestamp in call log tree | L1 | `call_log.lua` (prepare_node) | No |
| 15 | Explain Plan action | L2 | `editor/init.lua`, `dbee.lua`, `config.lua` | No |
| 16 | Generic adapter error diagnostics | L2 | `editor/init.lua` (generalize parser) | No |
| 17 | Drawer search/filter | L2 | `drawer/init.lua`, `drawer/convert.lua`, `config.lua` | No |
| 18 | Auto-reconnect prompt on disconnect | L2 | `editor/init.lua` or `result/init.lua`, `dbee.lua` | No |

### Summary

- **14 of 18 items are L1** (single-file, trivial changes)
- **4 items are L2/L3** (cross-component but still Lua-only)
- **0 items require Go changes** (see analysis below)

## Detailed Component Analysis Per Item

### Quick Wins (L1) -- Items 1, 2, 3, 5, 6, 7, 13, 14

These are all single-file changes within existing component boundaries.

**Item 1: Notify on no connection**
- **Where**: `EditorUI:get_actions()` in `lua/dbee/ui/editor/init.lua`
- **What**: All three actions (`run_file`, `run_selection`, `run_under_cursor`) silently `return` when `conn` is nil. Add `vim.notify("No connection selected", vim.log.levels.WARN)` before each return.
- **Lines**: ~474, ~503, ~524
- **Boundary**: EditorUI only. No cross-component interaction.

**Item 2: Notify on empty cursor query**
- **Where**: `run_under_cursor` action in `EditorUI:get_actions()`
- **What**: When `query == ""` (line ~531), the action silently returns. Add `vim.notify("No SQL statement under cursor", vim.log.levels.INFO)`.
- **Boundary**: EditorUI only.

**Item 3: Notify on yank success**
- **Where**: `ResultUI:store_current_wrapper()`, `store_selection_wrapper()`, `store_all_wrapper()` in `result/init.lua`
- **What**: After successful `handler:call_store_result()` calls, add `vim.notify("Yanked to register ...", vim.log.levels.INFO)`.
- **Boundary**: ResultUI only. The store call is synchronous RPC, so notify after return.

**Item 5: Show errors from drawer pcall**
- **Where**: `drawer/convert.lua` lines ~173, ~228, ~244
- **What**: Three `pcall(handler.source_add_connection, ...)`, `pcall(handler.source_update_connection, ...)`, `pcall(handler.source_remove_connection, ...)` calls discard errors. Capture the second return and show via `vim.notify`.
- **Boundary**: drawer/convert.lua only.

**Item 6: Better winbar labels**
- **Where**: `ResultUI:display_result()` in `result/init.lua` line ~260
- **Current**: `string.format("%d/%d (%d)%%=Took %.3fs", page+1, total_pages, length, seconds)`
- **New**: `string.format("Page %d/%d | %d rows%%=%.3fs", page+1, total_pages, length, seconds)`
- **Boundary**: ResultUI only. Pure format string change.

**Item 7: Schema refresh notification**
- **Where**: `DrawerUI:get_actions()` `refresh` action in `drawer/init.lua` line ~427
- **What**: After clearing cache and calling `self:refresh()`, add notification.
- **Consideration**: The actual refresh is async (structure_loaded event). Two options:
  - (a) Notify immediately ("Refreshing...") -- simpler, slightly misleading
  - (b) Listen for `structure_loaded` event and notify on completion -- correct but needs tracking
- **Recommendation**: Option (b) -- register a one-shot listener that clears after first fire.
- **Boundary**: DrawerUI, uses existing event system.

**Item 13: Replace error() with vim.notify in yank**
- **Where**: `ResultUI:store_current_wrapper()`, `store_selection_wrapper()`, `store_all_wrapper()`, `current_row_index()`, `current_row_range()` in `result/init.lua`
- **What**: These methods use `error()` which produces raw Lua tracebacks. Wrap in pcall or replace with `vim.notify` + early return.
- **Pattern**: `local ok, err = pcall(self.handler.call_store_result, ...) ; if not ok then vim.notify(err, WARN) end`
- **Boundary**: ResultUI only.

**Item 14: Duration/timestamp in call log tree**
- **Where**: `CallLogUI:create_tree()` `prepare_node` callback in `call_log.lua` line ~140
- **Current**: Shows state icon + query preview (40 chars)
- **New**: Add duration and timestamp columns. Data already available in `call.time_taken_us` and `call.timestamp_us` -- both are in the `CallDetails` payload from Go.
- **Boundary**: CallLogUI only. No new data needed.

### Small Effort (L2/L3) -- Items 4, 8, 9, 10, 11, 12

These involve new actions, keybindings, or cross-component coordination but stay in Lua.

**Item 4: Copy query from call log**
- **Where**: `CallLogUI:get_actions()` in `call_log.lua`, config defaults
- **What**: New `yank_query` action that copies `node.call.query` to clipboard register
- **Implementation**: `vim.fn.setreg(vim.v.register, call.query)` + `vim.notify`
- **Config**: Add default mapping `{ key = "yy", mode = "n", action = "yank_query" }` to `call_log.mappings`
- **Boundary**: CallLogUI + config.lua

**Item 8: Re-run query from call log**
- **Where**: `CallLogUI:get_actions()` in `call_log.lua`
- **What**: New `rerun_query` action that takes `node.call.query`, gets current connection, calls `handler:connection_execute()`
- **Dependency**: Needs access to `self.handler` (already available) and result (already available as `self.result`)
- **Config**: Add default mapping, e.g., `{ key = "R", mode = "n", action = "rerun_query" }`
- **Boundary**: CallLogUI (handler and result already injected)

**Item 9: Export to file from result pane**
- **Where**: `ResultUI:get_actions()` in `result/init.lua`
- **What**: New `export_csv` and `export_json` actions. Use `vim.ui.input` for file path, then call `self.handler:call_store_result(call_id, format, "file", { extra_arg = path })`.
- **Note**: The Go side already supports `output = "file"` in `CallStoreResult`. No Go changes needed.
- **Config**: Add default mappings, e.g., `{ key = "EC", mode = "n", action = "export_csv" }`, `{ key = "EJ", mode = "n", action = "export_json" }`
- **Boundary**: ResultUI + config.lua

**Item 10: Copy table/column names from drawer**
- **Where**: `drawer/convert.lua` in `connection_nodes()` and `column_nodes()`
- **What**: Add a yank action to table/view/column nodes. When triggered, copies qualified name (`schema.table` or `column`) to register.
- **Implementation options**:
  - (a) Add an `action_2` on table/column nodes (currently action_2 is unused for these)
  - (b) Add a new `yank_name` drawer action that reads current node type and copies accordingly
- **Recommendation**: (a) -- fits the existing action_1/action_2/action_3 pattern. action_2 on table/view nodes could yank `schema.table`, action_2 on column nodes could yank `column_name`.
- **Config**: Document that `cw` (default action_2) copies name on table/column nodes.
- **Boundary**: drawer/convert.lua

**Item 11: Next/previous note keybinding**
- **Where**: `EditorUI` in `editor/init.lua`, config defaults
- **What**: New `next_note` and `prev_note` actions in `EditorUI:get_actions()`. Walk the note list for the current namespace, find current note index, advance/retreat, call `self:set_current_note()`.
- **Implementation**: Need ordered list of notes. `self:namespace_get_notes()` already returns sorted lists. Need to determine which namespace (current connection or global) the current note belongs to.
- **Config**: Add default mappings, e.g., `{ key = "]n", mode = "n", action = "next_note" }`, `{ key = "[n", mode = "n", action = "prev_note" }`
- **Boundary**: EditorUI + config.lua

**Item 12: Jump-between-panes keybindings**
- **Where**: Layout-level or per-component keybindings
- **Challenge**: The pane windows are managed by Layout, not individual components. Components know their `winid` but not each other's windows.
- **Implementation options**:
  - (a) Add global keybindings in `dbee.lua` that call layout methods (e.g., `focus_editor()`, `focus_result()`)
  - (b) Add methods to Layout interface: `focus_editor()`, `focus_result()`, etc.
  - (c) Use `dbee.actions()` palette -- already has editor/result/drawer as accessible targets
- **Recommendation**: (a) -- add convenience functions in `dbee.lua` that look up component window IDs via the state manager, then `vim.api.nvim_set_current_win()`. These become mappable actions.
- **Boundary**: `dbee.lua`, `api/state.lua` (expose winids), config

### Medium Effort (L2) -- Items 15, 16, 17, 18

**Item 15: Explain Plan action**
- **Initial assessment**: Looked like L4 (Go adapter helpers). After analysis: **L2 (Lua-only)**.

**Why not Go helpers**: The helper system (`GetHelpers(TableOptions)`) is table-centric -- it generates queries about a specific table/schema. Explain Plan is query-centric -- it wraps an arbitrary user query. These are fundamentally different.

**Recommended approach -- Lua-only with adapter-type dispatch:**
```lua
local explain_prefix = {
  postgres = "EXPLAIN ANALYZE ",
  mysql = "EXPLAIN ",
  oracle = "EXPLAIN PLAN FOR ",
  sqlite = "EXPLAIN QUERY PLAN ",
  sqlserver = "SET SHOWPLAN_XML ON;\nGO\n",
  bigquery = "EXPLAIN ",
  clickhouse = "EXPLAIN ",
  duck = "EXPLAIN ANALYZE ",
}
```

This keeps it Lua-only. The adapter type is available via `conn.type`. Add as an action in `EditorUI:get_actions()` or in `dbee.actions()`.

- **Files**: `editor/init.lua` (new action), `dbee.lua` (new action in palette), `config.lua` (mapping)
- **Go changes**: None needed

**Item 16: Generic adapter error diagnostics**
- **Current state**: Oracle error diagnostics are implemented in `EditorUI:on_call_state_changed()`. The code parses Oracle-specific error location patterns (`line X, column Y`, `at line X`).
- **Goal**: Show inline diagnostics for all adapters, not just Oracle.

**Recommended approach -- Lua-only with adapter-aware parsers:**

The current `on_call_state_changed` handler guards on `exec_conn_type:lower() ~= "oracle"`. Remove this guard and add pattern matchers for each adapter:

```lua
local error_parsers = {
  oracle = parse_oracle_error_location,  -- existing function
  postgres = function(msg)
    local line = msg:match("LINE (%d+)")
    return line and tonumber(line), 1
  end,
  mysql = function(msg)
    local line = msg:match("at line (%d+)")
    return line and tonumber(line), 1
  end,
  -- fallback: show error at line 1 if no location found
}
```

For adapters without line info in errors: show diagnostic at line 1 of the executed query as a fallback (still useful -- shows the error message inline).

- **Files**: `editor/init.lua` (generalize `on_call_state_changed`)
- **Go changes**: None needed -- error strings already contain adapter-specific location info

**Item 17: Drawer search/filter**
- **Current state**: DrawerUI uses NuiTree for rendering. Tree is rebuilt on each `refresh()` from `handler_nodes()` + `editor_nodes()`.
- **Implementation approach**:
  1. Add filter state to DrawerUI: `self.filter_text = ""`
  2. Add `search` action that opens a one-line input (like the existing menu system)
  3. When filter is active, `refresh()` filters nodes by name match before setting them on the tree
  4. Add `clear_search` action to reset
  5. Show filter indicator in drawer (e.g., winbar or first line)

- **Key consideration**: NuiTree.Node filtering must happen at the Lua level -- NuiTree does not have built-in filtering. Filter during `refresh()` by walking the tree and excluding non-matching nodes (but keeping parent nodes that have matching children).
- **Files**: `drawer/init.lua` (filter state, actions), `drawer/convert.lua` (filter logic in node creation), `config.lua` (mappings)
- **Layer**: L2 (Lua cross-component, moderate complexity)

**Item 18: Auto-reconnect prompt on disconnect**
- **Current state**: `error_kind = "disconnected"` is already classified in Go (`call_error_kind.go`). The result pane already shows a hint for disconnected errors. `dbee.reconnect_current_connection()` and `dbee.retry_last_disconnected()` already exist.
- **Implementation**: Similar to cancel-confirm pattern in EditorUI. On `call_state_changed` with `error_kind == "disconnected"`, trigger a `vim.ui.select` prompt: "Connection lost. Reconnect and retry?"
- **Files**: `editor/init.lua` or `result/init.lua` (event listener), `dbee.lua` (uses existing reconnect functions)
- **Layer**: L2 (Lua cross-component, follows cancel-confirm pattern)

## Component Boundaries Affected

| Component | Items Touching It | Nature of Changes |
|-----------|------------------|-------------------|
| **EditorUI** (`editor/init.lua`) | 1, 2, 11, 15, 16, 18 | New notifications, new actions, generalized diagnostics |
| **ResultUI** (`result/init.lua`) | 3, 6, 9, 13 | Notifications, format, new actions, error handling |
| **DrawerUI** (`drawer/init.lua`) | 7, 10, 17 | Notifications, yank actions, filter system |
| **drawer/convert.lua** | 5, 10 | Error surfacing, yank on nodes |
| **CallLogUI** (`call_log.lua`) | 4, 8, 14 | New actions, tree format |
| **config.lua** | 4, 8, 9, 10, 11, 12 | New default mappings |
| **dbee.lua** | 12, 15, 18 | New public API functions, actions palette entries |
| **Go adapters** | None | No changes needed |
| **Go handler/event_bus** | None | No changes needed |

## Key Finding: All 18 Items Are Lua-Only

After detailed analysis, **all 18 items can be implemented in Lua only**. The two items initially appearing to need Go changes:

- **Explain Plan**: String prefixing in Lua based on `conn.type`, not Go helper system. The helper system is table-scoped; Explain is query-scoped.
- **Generic Diagnostics**: Pattern matching on error strings in Lua per adapter type. Error strings from Go already contain adapter-native location info (PostgreSQL's `LINE N:`, MySQL's `at line N`).

This means **zero Go recompilation** for the entire QoL milestone.

## Dependency Graph and Build Order

```
Independent (no dependencies between them):
  Items 1, 2, 5, 6, 7, 14  -- all L1, can be done in any order

Sequential dependencies:
  Item 13 (fix yank error handling) --> Item 3 (notify on yank success)
    Reason: Fix error() calls first, then add success notifications

  Item 16 (generic diagnostics) --> Item 15 (explain plan)
    Reason: Explain plan results benefit from diagnostic display

  Item 11 (next/prev note) -- independent but same file as Item 1, 2
    Recommendation: batch with other editor changes

  Item 4 (copy query) --> Item 8 (re-run query)
    Both touch call_log.lua, 4 is simpler, establishes the pattern

  Item 17 (drawer filter) -- independent but largest single item
    Recommendation: do after simpler drawer items (5, 7, 10)
```

## Suggested Build Order (for roadmap phases)

**Phase 1 -- Notifications and Feedback (Items 1, 2, 3, 5, 6, 7, 13)**
- All L1, single-file changes
- Establish consistent `vim.notify` pattern across all components
- Fix error handling (13) before adding success notifications (3)
- Highest density of quick user-visible improvements

**Phase 2 -- Call Log Enhancements (Items 4, 8, 14)**
- All in `call_log.lua`
- Batch changes to one component
- Item 14 (formatting) first, then 4 (yank), then 8 (re-run)

**Phase 3 -- Result and Editor Actions (Items 9, 11, 15)**
- New actions in result (export) and editor (note cycling, explain)
- Each adds new keybindings, so batch config.lua changes

**Phase 4 -- Drawer and Navigation (Items 10, 12, 17)**
- Drawer search is the most complex single item
- Copy names (10) is simple, do first
- Jump-between-panes (12) is layout-level, independent

**Phase 5 -- Resilience and Diagnostics (Items 16, 18)**
- Generic diagnostics and auto-reconnect
- Both are event-driven patterns building on existing infrastructure
- Most complex items, benefit from all prior changes being stable

## Patterns to Follow

### Pattern 1: Notification Consistency
**What**: Use `vim.notify(msg, level)` uniformly. Never `error()` for user-facing messages. Never silent failure.
**Standard levels**:
- `vim.log.levels.INFO` -- success confirmations (yank, refresh)
- `vim.log.levels.WARN` -- user error (no connection, empty query)
- `vim.log.levels.ERROR` -- system error (RPC failure, adapter error)

### Pattern 2: Action Registration
**What**: New actions follow the existing `get_actions()` -> `do_action()` pattern on each component.
**When adding new action**:
1. Add function to component's `get_actions()` return table
2. Add default mapping in `config.lua` under the component's mappings section
3. Keep action name snake_case, matching existing convention

### Pattern 3: Event Listener for Async Feedback
**What**: For operations with async completion (refresh, reconnect), register a one-shot event listener.
**Example**:
```lua
-- One-shot listener for structure_loaded
local notified = false
handler:register_event_listener("structure_loaded", function(data)
  if not notified and data.conn_id == target_conn_id then
    notified = true
    vim.notify("Schema refreshed for " .. conn_name, vim.log.levels.INFO)
  end
end)
```

### Pattern 4: Drawer Node Filtering
**What**: Filter at `refresh()` time by walking the assembled node tree and pruning non-matching branches.
**Keep**: Parent nodes with matching children (so the tree structure remains navigable).
**Example**: If filter is "users", keep `schema > users` but hide `schema > orders`.

## Anti-Patterns to Avoid

### Anti-Pattern 1: Breaking Existing Keybindings
**What**: Overwriting default mappings that users rely on.
**Why bad**: Users have muscle memory for `BB`, `<CR>`, `H/L`.
**Instead**: New actions get new mappings. Never change existing defaults.

### Anti-Pattern 2: RPC Calls in Notification Code
**What**: Making synchronous RPC calls (vim.fn.DbeeXxx) inside notification/formatting paths.
**Why bad**: Blocks Neovim's main thread, causes UI freezes.
**Instead**: Use data already available in the event payload or cached locally.

### Anti-Pattern 3: Modifying Go Event Payloads for Lua Convenience
**What**: Adding fields to Go event payloads just because Lua wants them for display.
**Why bad**: Increases RPC message size, couples Go to Lua display concerns.
**Instead**: Derive display data from existing payload fields in Lua.

### Anti-Pattern 4: Drawer Filter via Buffer Replacement
**What**: Implementing search by creating a new filtered buffer instead of filtering NuiTree nodes.
**Why bad**: Loses tree state (expansion, cursor position), breaks node identity.
**Instead**: Filter within the NuiTree node set, preserve expansion state using existing `expansion.get/set` pattern.

## Scalability Considerations

| Concern | Current Scale | At 100 tables | At 1000 tables |
|---------|--------------|---------------|----------------|
| Drawer filter | N/A | String match on ~100 nodes, instant | Need debounced input, filter on 1000+ nodes |
| Call log entries | Unbounded growth | Fine | Consider capping display to recent N (keep full log) |
| Notification spam | N/A | Fine | Consider deduplication for rapid repeated actions |
| Winbar updates | Every page change | Fine | Fine (single format string) |

## Sources

- All findings derived from direct codebase analysis (HIGH confidence)
- Architecture patterns verified against actual source code in the repository
- No external sources needed -- this is analysis of existing brownfield code

---

*Architecture analysis: 2026-03-05*
