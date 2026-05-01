# Phase 1: Notifications & Feedback - Research

**Researched:** 2026-03-05
**Domain:** Neovim Lua notification/feedback patterns in nvim-dbee plugin
**Confidence:** HIGH

## Summary

Phase 1 is a pure Lua refactoring phase. All 7 requirements involve modifying existing Lua files to improve user-facing feedback -- no Go backend changes, no new dependencies, no new modules. The work centers on three areas: (1) migrating ~26 raw `vim.notify` calls in `lua/dbee.lua` to the existing `utils.log()` wrapper for consistent `title: "nvim-dbee"` prefixing, (2) adding error capture and yank feedback in `result/init.lua` and `drawer/convert.lua`, and (3) reformatting the winbar label in `result/init.lua:264`.

The codebase already has all needed infrastructure: `utils.log(level, message, subtitle)` at `lua/dbee/utils.lua:46`, event listeners via `handler:register_event_listener()`, pcall patterns in drawer operations, and the winbar being set via `vim.api.nvim_win_set_option(winid, "winbar", ...)`. No new libraries or patterns are needed.

**Primary recommendation:** Implement each NOTIF requirement as a focused change against the specific files identified in code context. Start with the `utils.log` migration sweep (NOTIF-01, NOTIF-02 + bulk migration), then yank feedback (NOTIF-03, NOTIF-05), then drawer errors (NOTIF-04), schema refresh (NOTIF-06), and winbar (NOTIF-07).

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Use `utils.log()` everywhere (adds `title: "nvim-dbee"` prefix) -- no raw `vim.notify` calls
- Migrate all ~25 existing `vim.notify` calls in `lua/dbee.lua` to `utils.log` for consistency
- Log levels: INFO for success, WARN for user-correctable issues, ERROR for system failures
- Notification wording policy: terse INFO, contextual WARN with next step, concise technical ERROR
- NOTIF-01: Reword to "No connection selected. Select one from the drawer, then run again." + migrate to utils.log
- NOTIF-02: Reword to "No SQL found at cursor. Place cursor on a query and try again." + migrate to utils.log
- NOTIF-03: Show "Yanked 5 rows (CSV)" format. Replace `error()` with pcall + utils.log. Precondition failures -> WARN. RPC exceptions -> ERROR or WARN
- NOTIF-04: Capture pcall return values at `drawer/convert.lua:173,227,244` and surface via utils.log
- NOTIF-05: Covered by NOTIF-03 -- pcall + utils.log replaces all error() calls in yank wrappers
- NOTIF-06: Fire on manual refresh only, not auto-load. Show connection name: "Schema loaded: my-postgres-dev"
- NOTIF-07: Completed results: "Page 1/3 | 42 rows | 0.035s". Adaptive duration: <1s ms, >=1s seconds, >=60s min+sec. Executing: "Executing...". Retrieving: "Retrieving...". Default: "Results"

### Claude's Discretion
- Exact implementation of manual-refresh flag for NOTIF-06 (event data field vs state tracking)
- How to compute row count for yank feedback (Go-side vs Lua-side)
- Whether to batch the vim.notify migration into one commit or split by area

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| NOTIF-01 | User is notified when no connection is selected and a run action is invoked | Existing check at `lua/dbee.lua:700`. Reword + migrate to `utils.log("warn", ...)` |
| NOTIF-02 | User is notified when cursor query is empty/blank | Existing check at `lua/dbee.lua:720`. Reword + migrate to `utils.log("warn", ...)` |
| NOTIF-03 | User is notified on successful yank from result pane | Yank wrappers at `result/init.lua:427-481`. Wrap `call_store_result` with pcall, count rows from `from`/`to` args, notify with `utils.log("info", ...)` |
| NOTIF-04 | User sees error messages from drawer operations instead of silent swallowing | Three pcall sites at `drawer/convert.lua:173,227,244` currently discard error return. Capture and surface via `utils.log("error", ...)` |
| NOTIF-05 | User sees vim.notify messages instead of raw Lua tracebacks on yank failures | Same code path as NOTIF-03. Replace all `error()` calls in yank helpers (`current_row_index`, `current_row_range`, store wrappers) with pcall + utils.log |
| NOTIF-06 | User is notified when schema refresh completes | `structure_loaded` event already fires. Need flag to distinguish manual refresh (user pressed `r`) from auto-load (lazy_children expand). Track via drawer state field |
| NOTIF-07 | User sees self-documenting winbar labels | Winbar set at `result/init.lua:264`. Change format string. Also update `set_default_result_window` for executing/retrieving/default states |
</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `vim.notify` | Neovim 0.11+ | Notification delivery | Built-in, supports nvim-notify/fidget.nvim via override |
| `utils.log` | internal | Consistent notification wrapper | Already exists at `lua/dbee/utils.lua:46`, adds title prefix |
| `pcall` | Lua 5.1 | Error capture without traceback propagation | Lua standard, already used throughout codebase |
| `vim.api.nvim_win_set_option` | Neovim 0.11+ | Winbar content setting | Already used at `result/init.lua:261-264` |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `string.format` | Lua 5.1 | Formatted notification messages | All notification message construction |
| `vim.log.levels` | Neovim built-in | Log level constants (INFO/WARN/ERROR) | Used by `utils.log` internally |

### Alternatives Considered
None -- all infrastructure already exists in the codebase.

## Architecture Patterns

### Recommended Project Structure

No new files needed. All changes are in existing files:

```
lua/dbee/
  utils.lua              # utils.log() -- no changes needed
  dbee.lua               # ~26 vim.notify -> utils.log migrations + rewordings
  ui/result/init.lua     # winbar format (NOTIF-07), yank wrappers (NOTIF-03/05)
  ui/drawer/convert.lua  # pcall error capture (NOTIF-04)
  ui/drawer/init.lua     # manual refresh flag + schema notification (NOTIF-06)
```

### Pattern 1: utils.log migration

**What:** Replace raw `vim.notify(msg, level)` with `utils.log(level_string, msg)`
**When to use:** Every notification in `lua/dbee.lua` and other files

Before:
```lua
vim.notify("no connection currently selected", vim.log.levels.WARN)
```

After:
```lua
utils.log("warn", "No connection selected. Select one from the drawer, then run again.")
```

**Key difference:** `utils.log` maps string levels ("info"/"warn"/"error") to `vim.log.levels.*` and passes `{ title = "nvim-dbee" }` to `vim.notify`. The `subtitle` parameter is optional and adds a `[subtitle]:` prefix.

### Pattern 2: pcall error capture for drawer operations

**What:** Capture pcall return values and surface errors via utils.log
**When to use:** Drawer add/edit/delete connection operations (NOTIF-04)

Before (at `convert.lua:173`):
```lua
pcall(handler.source_add_connection, handler, source_id, spec)
cb()
```

After:
```lua
local ok, err = pcall(handler.source_add_connection, handler, source_id, spec)
if not ok then
  utils.log("error", "Failed to add connection: " .. tostring(err))
end
cb()
```

### Pattern 3: pcall wrapping for yank operations (replaces error())

**What:** Replace `error()` calls with pcall + utils.log for user-friendly feedback
**When to use:** Yank wrappers and their helper functions (NOTIF-03/05)

Before:
```lua
function ResultUI:store_current_wrapper(format, register)
  if not self.current_call then
    error("no call set to result")
  end
  local index = self:current_row_index()
  -- ...
  self.handler:call_store_result(self.current_call.id, format, "yank", ...)
end
```

After:
```lua
function ResultUI:store_current_wrapper(format, register)
  if not self.current_call then
    utils.log("warn", "No results to yank")
    return
  end
  local ok_idx, index = pcall(self.current_row_index, self)
  if not ok_idx then
    utils.log("warn", "Could not determine current row")
    return
  end
  -- ...
  local ok, err = pcall(self.handler.call_store_result, self.handler,
    self.current_call.id, format, "yank", { from = index, to = index + 1, extra_arg = register })
  if not ok then
    utils.log("error", "Yank failed: " .. tostring(err))
    return
  end
  utils.log("info", "Yanked 1 row (" .. string.upper(format) .. ")")
end
```

### Pattern 4: Manual refresh flag for NOTIF-06

**What:** Track when user explicitly requests a schema refresh vs auto-load
**When to use:** NOTIF-06 schema refresh notification

**Recommendation:** Use a Lua-side state flag on the DrawerUI object. The `refresh` action (bound to `r` key) already clears `structure_cache` and calls `self:refresh()`. Before clearing the cache, set `self._manual_refresh_conns` to track which connection IDs are being manually refreshed. Then in `on_structure_loaded`, check this set:

```lua
-- In DrawerUI:get_actions().refresh:
refresh = function()
  -- Mark all cached connections as manual refresh targets
  self._manual_refresh_conns = {}
  for conn_id, _ in pairs(self.structure_cache) do
    self._manual_refresh_conns[conn_id] = true
  end
  self.structure_cache = {}
  self:refresh()  -- this triggers connection_get_structure_async for each connection
end

-- In DrawerUI:on_structure_loaded:
function DrawerUI:on_structure_loaded(data)
  if not data or not data.conn_id then return end

  -- Check if this was a manual refresh
  if self._manual_refresh_conns and self._manual_refresh_conns[data.conn_id] then
    self._manual_refresh_conns[data.conn_id] = nil
    if not data.error then
      local conn = self.handler:connection_get_params(data.conn_id)
      local name = conn and conn.name or data.conn_id
      utils.log("info", "Schema loaded: " .. name)
    end
  end

  self.structure_cache[data.conn_id] = { structures = data.structures, error = data.error }
  self:refresh()
end
```

**Why this approach:** State tracking is simpler than modifying the Go event bus data shape, stays Lua-only, and correctly handles the case where multiple connections refresh simultaneously.

### Pattern 5: Adaptive duration formatting for NOTIF-07

**What:** Format query duration in human-readable adaptive units
**When to use:** Winbar label after query completes

```lua
---@param us number microseconds
---@return string
local function format_duration(us)
  local seconds = us / 1000000
  if seconds >= 60 then
    local minutes = math.floor(seconds / 60)
    local remaining = seconds - (minutes * 60)
    return string.format("%dm %ds", minutes, math.floor(remaining))
  elseif seconds >= 1 then
    return string.format("%.2fs", seconds)
  else
    return string.format("%dms", math.floor(seconds * 1000))
  end
end
```

### Anti-Patterns to Avoid
- **Using `error()` in user-facing code paths:** error() produces raw tracebacks that confuse users. Use pcall + utils.log instead
- **Raw `vim.notify` in new code:** Always use `utils.log()` for consistent title/level handling
- **Silent pcall:** `pcall(fn)` without checking/surfacing the error -- the pattern currently at `convert.lua:173,227,244`
- **Modifying Go code for Lua-only concerns:** All 7 requirements can be implemented in Lua. Do not modify Go event bus or handler

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Notification with title | Custom vim.notify wrapper | `utils.log()` at utils.lua:46 | Already exists, adds "nvim-dbee" title |
| Error capture | Custom try/catch | `pcall()` | Lua standard, used throughout codebase |
| Duration formatting | External library | Local helper function | Simple math, no dependencies needed |
| Event listener | Custom pub/sub | `handler:register_event_listener()` | Already exists in the event bus system |

## Common Pitfalls

### Pitfall 1: utils.log subtitle parameter leading space
**What goes wrong:** `utils.log` at line 63 prepends subtitle with format `[subtitle]: message`. When subtitle is nil, it still prepends a space: `" " .. message`.
**Why it happens:** The code at line 62 sets `subtitle = ""` when nil, then line 63 does `subtitle .. " " .. message`, resulting in `" message"`.
**How to avoid:** This is an existing quirk. For this phase, do NOT pass subtitle unless it adds value. Most notifications should use `utils.log("warn", "message")` without subtitle. The leading space is cosmetic only and consistent across all notifications.
**Warning signs:** Messages appearing with a leading space in vim.notify display.

### Pitfall 2: Row count computation for yank feedback
**What goes wrong:** Yank wrappers pass `from`/`to` to `call_store_result` but the Go side doesn't return how many rows were actually stored.
**Why it happens:** `CallStoreResult` returns `error` only -- no row count.
**How to avoid:** Compute row count from the Lua-side `from`/`to` parameters. For `store_current_wrapper`: always 1 row. For `store_selection_wrapper`: `to - from` rows. For `store_all_wrapper`: use the `length` value from the last `display_result` call (it's the total row count, available as the return value that sets `page_ammount`). Alternatively, track total rows as a field on ResultUI.
**Warning signs:** Yank feedback showing wrong row count for "yank all".

### Pitfall 3: Yank all row count not readily available
**What goes wrong:** `store_all_wrapper` doesn't pass `from`/`to` (defaults to 0/-1 meaning "all"). The total row count isn't stored as a field.
**Why it happens:** The `display_result` method returns `length` (total rows) but it's only used to compute `page_ammount`. The actual total count isn't stored directly.
**How to avoid:** Store the total row count from the last `display_result` call as `self.total_rows`. The `length` return at `result/init.lua:248` is the total row count. Save it: `self.total_rows = length`. Then in `store_all_wrapper`, use `self.total_rows` for the feedback message.
**Warning signs:** "Yanked 0 rows" or "Yanked nil rows" messages.

### Pitfall 4: Winbar set_option deprecation
**What goes wrong:** Code uses `vim.api.nvim_win_set_option(winid, "winbar", ...)` which is deprecated.
**Why it happens:** Neovim deprecated `nvim_win_set_option` in favor of `nvim_set_option_value`.
**How to avoid:** While changing winbar format, also migrate to `vim.api.nvim_set_option_value("winbar", value, { win = winid })`. This is already done in `progress.lua` (line 69 uses `nvim_set_option_value`). Keep consistency.
**Warning signs:** Deprecation warnings in `:messages`.

### Pitfall 5: Multiple notifications from single action
**What goes wrong:** A yank failure could trigger both a WARN from precondition check AND an ERROR from the pcall.
**Why it happens:** Layered error handling without early returns.
**How to avoid:** Use early `return` after each utils.log call. Once an error is surfaced, do not continue to the next operation.
**Warning signs:** Two notification popups for a single user action.

### Pitfall 6: Manual refresh flag race condition
**What goes wrong:** If user presses `r` twice quickly, the second refresh could overwrite `_manual_refresh_conns` before the first response arrives.
**Why it happens:** Async structure loading with multiple pending requests.
**How to avoid:** Use additive tracking -- add conn_ids to the set rather than replacing it. Remove individual entries as responses arrive.
**Warning signs:** Schema loaded notification missing for some connections after rapid refreshes.

## Code Examples

### Complete utils.log migration for execute_context (NOTIF-01, NOTIF-02)

```lua
-- Source: lua/dbee.lua, execute_context function
function dbee.execute_context(opts)
  opts = opts or {}

  local core_ready, core_err = ensure_core_available()
  if not core_ready then
    utils.log("warn", core_err or "dbee core not loaded")
    return
  end

  local conn = api.core.get_current_connection()
  if not conn then
    -- NOTIF-01: user-correctable WARN with next step
    utils.log("warn", "No connection selected. Select one from the drawer, then run again.")
    return
  end

  -- ... query extraction ...

  if query == "" then
    -- NOTIF-02: user-correctable WARN with next step
    utils.log("warn", "No SQL found at cursor. Place cursor on a query and try again.")
    return
  end

  -- ... execution ...
end
```

### Complete yank wrapper with feedback (NOTIF-03, NOTIF-05)

```lua
-- Source: lua/dbee/ui/result/init.lua
function ResultUI:store_current_wrapper(format, register)
  if not self.current_call then
    utils.log("warn", "No results to yank")
    return
  end
  local ok_idx, index = pcall(self.current_row_index, self)
  if not ok_idx then
    utils.log("warn", "Could not determine current row")
    return
  end

  index = index - 1
  if index <= 0 then
    index = 0
  end

  local ok, err = pcall(self.handler.call_store_result, self.handler,
    self.current_call.id, format, "yank",
    { from = index, to = index + 1, extra_arg = register })
  if not ok then
    utils.log("error", "Yank failed: " .. tostring(err))
    return
  end
  utils.log("info", "Yanked 1 row (" .. string.upper(format) .. ")")
end
```

### Winbar format string (NOTIF-07)

```lua
-- Source: lua/dbee/ui/result/init.lua, display_result method
-- Replace the current winbar format string at line 264:
if self:has_window() then
  vim.api.nvim_set_option_value("winbar",
    string.format("Page %d/%d | %d rows | %s",
      page + 1, self.page_ammount + 1, length, format_duration(self.current_call.time_taken_us)),
    { win = self.winid })
end
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `nvim_win_set_option` | `nvim_set_option_value` with opts table | Neovim 0.10 | Deprecated API; should migrate |
| `nvim_buf_set_option` | `nvim_set_option_value` with opts table | Neovim 0.10 | Same deprecation; result/init.lua uses both |
| Raw `vim.notify` | `utils.log` wrapper | Already in codebase | Inconsistent currently; this phase fixes it |

**Deprecated/outdated:**
- `vim.api.nvim_win_set_option`: deprecated in Neovim 0.10+, use `vim.api.nvim_set_option_value` with `{ win = winid }`
- `vim.api.nvim_buf_set_option`: deprecated in Neovim 0.10+, use `vim.api.nvim_set_option_value` with `{ buf = bufnr }`

## Inventory of All vim.notify Calls Requiring Migration

### lua/dbee.lua (26 calls)

| Line | Current Message | Level | Action |
|------|----------------|-------|--------|
| 308 | "Dbee not loaded" | WARN | Migrate to utils.log |
| 314 | "No notes found" | INFO | Migrate to utils.log |
| 355 | "Dbee not loaded" | WARN | Migrate to utils.log |
| 361 | "No connections found" | INFO | Migrate to utils.log |
| 421 | "Dbee not loaded" | WARN | Migrate to utils.log |
| 427 | "No call history" | INFO | Migrate to utils.log |
| 628 | "Query yanked to clipboard" | INFO | Migrate to utils.log |
| 635 | "Results (JSON) yanked to clipboard" | INFO | Migrate to utils.log |
| 643 | "Results (CSV) yanked to clipboard" | INFO | Migrate to utils.log |
| 694 | core_err or "dbee core not loaded" | WARN | Migrate + reword (NOTIF-01 context) |
| 700 | "no connection currently selected" | WARN | NOTIF-01: reword + migrate |
| 720 | "No SQL statement to execute at cursor" | WARN | NOTIF-02: reword + migrate |
| 726 | err (dynamic) | WARN | Migrate to utils.log |
| 826 | "No executable statements found in script" | WARN | Migrate to utils.log |
| 906 | "No running script execution" | INFO | Migrate to utils.log |
| 911 | "Script cancellation already requested" | INFO | Migrate to utils.log |
| 916 | "Script cancellation requested" | INFO | Migrate to utils.log |
| 966 | "Reconnected " .. name | INFO | Migrate to utils.log |
| 1004 | exec_err (dynamic) | WARN | Migrate to utils.log |
| 1007 | "Retried last disconnected query" | INFO | Migrate to utils.log |
| 1043 | err (dynamic) | WARN | Migrate to utils.log |
| 1091 | err (dynamic) | WARN | Migrate to utils.log |
| 1104 | err (dynamic) | WARN | Migrate to utils.log |
| 1128 | err (dynamic) | WARN | Migrate to utils.log |
| 1141 | "unknown or unavailable dbee action" | WARN | Migrate to utils.log |
| 1159 | "snacks.nvim not available..." | WARN | Migrate to utils.log |

### Other files (5 calls, out of NOTIF-01..07 scope but worth noting)

| File | Line | Notes |
|------|------|-------|
| `handler/__events.lua:23` | Event listener error | Keep as-is (internal error reporting) |
| `ui/call_log.lua:202` | Cancel error | Consider migrating |
| `ui/result/init.lua:317` | Cancel error | Consider migrating |
| `ui/editor/init.lua:304,313,422,444` | Editor errors | Consider migrating |

## Open Questions

1. **Total row count for "yank all" feedback**
   - What we know: `display_result` returns `length` (total rows) but it's not stored as a field
   - What's unclear: Whether `self.page_ammount` reliably gives total count (it gives page count)
   - Recommendation: Add `self.total_rows = length` in `display_result` method, use it in `store_all_wrapper`. Total = `self.total_rows` or `(self.page_ammount + 1) * self.page_size` as approximation

2. **Should other-file vim.notify calls also migrate?**
   - What we know: CONTEXT.md says "migrate all ~25 existing vim.notify calls in lua/dbee.lua" -- specifically scoped to dbee.lua
   - What's unclear: Whether `editor/init.lua`, `call_log.lua`, `handler/__events.lua` should also migrate
   - Recommendation: Keep strictly scoped to dbee.lua for this phase per user decision. Note the others for a future pass. The `__events.lua:23` one should probably stay as-is since it's internal error reporting

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Headless Neovim Lua tests (custom, in-repo) |
| Config file | `.github/workflows/test.yml` (CI matrix) |
| Quick run command | `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/<script>.lua"` |
| Full suite command | Run all scripts in `ci/headless/` directory via the CI matrix |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| NOTIF-01 | WARN on no connection selected | unit (headless) | `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_notifications.lua"` | No -- Wave 0 |
| NOTIF-02 | WARN on empty query | unit (headless) | Same script | No -- Wave 0 |
| NOTIF-03 | INFO on yank success with count + format | unit (headless) | Same script | No -- Wave 0 |
| NOTIF-04 | ERROR on drawer op failure | unit (headless) | Same script | No -- Wave 0 |
| NOTIF-05 | utils.log instead of error() on yank fail | unit (headless) | Same script | No -- Wave 0 |
| NOTIF-06 | INFO on manual schema refresh (not auto-load) | unit (headless) | Same script | No -- Wave 0 |
| NOTIF-07 | Winbar format "Page X/Y \| N rows \| duration" | unit (headless) | `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_winbar_format.lua"` | No -- Wave 0 |

### Sampling Rate
- **Per task commit:** `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_notifications.lua"`
- **Per wave merge:** Run all ci/headless scripts
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `ci/headless/check_notifications.lua` -- covers NOTIF-01 through NOTIF-06. Needs to mock handler/api/utils.log to capture notification calls and verify message content + levels
- [ ] `ci/headless/check_winbar_format.lua` -- covers NOTIF-07. Tests `format_duration` helper and verifies winbar format string construction
- [ ] Add new scripts to `.github/workflows/test.yml` matrix

**Note on testability:** Many NOTIF requirements involve `vim.notify` calls embedded in functions that depend on Go RPC (`api.core.get_current_connection`, `handler:call_store_result`, etc.). Headless tests will need to mock these dependencies. The existing headless tests (e.g., `check_query_under_cursor.lua`, `check_result_progress_hints.lua`) already demonstrate this pattern by stubbing `vim.treesitter.get_parser`, `vim.fn.reltimefloat`, and other APIs. Follow the same approach.

## Sources

### Primary (HIGH confidence)
- Direct code reading of all files in `lua/dbee/` -- source of truth for current behavior
- `lua/dbee/utils.lua:46-64` -- `utils.log()` implementation verified
- `lua/dbee/ui/result/init.lua:233-274` -- winbar format and display_result verified
- `lua/dbee/ui/result/init.lua:427-481` -- yank wrapper implementations verified
- `lua/dbee/ui/drawer/convert.lua:152-178,206-232,234-250` -- pcall sites verified
- `lua/dbee/ui/drawer/init.lua:120-174` -- event listener registration and structure_loaded handler verified
- `dbee/handler/handler.go:230-244` -- Go-side ConnectionGetStructureAsync verified
- `dbee/handler/event_bus.go:69-88` -- StructureLoaded event data shape verified
- `.github/workflows/test.yml` -- CI test matrix verified

### Secondary (MEDIUM confidence)
- Neovim API deprecation (nvim_win_set_option -> nvim_set_option_value): well-documented in Neovim changelog since 0.10

### Tertiary (LOW confidence)
- None

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all infrastructure already exists in the codebase, verified by reading source
- Architecture: HIGH -- patterns are direct modifications to existing code, no new modules
- Pitfalls: HIGH -- identified by reading actual code and understanding data flow
- Testability: MEDIUM -- headless test pattern exists but notification-specific mocking needs to be built

**Research date:** 2026-03-05
**Valid until:** Indefinite -- this is internal codebase research, not external dependency research
