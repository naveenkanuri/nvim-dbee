# Phase 2: Call Log Enhancements - Research

**Researched:** 2026-03-06
**Domain:** Neovim Lua UI (NuiTree/NuiLine rendering, buffer keymaps, clipboard, query re-execution)
**Confidence:** HIGH

## Summary

Phase 2 modifies a single primary file (`lua/dbee/ui/call_log.lua`) plus config defaults (`lua/dbee/config.lua`) and a thin public API entry in `lua/dbee.lua`. The call log tree rendering already uses `NuiLine:append()` segments -- adding duration and timestamp columns is a matter of appending two more segments with padding. Yank and re-run are new actions added to `CallLogUI:get_actions()` following the identical pattern used by `show_result` and `cancel_call`. The Phase 1 patterns (`utils.log`, `vim.fn.setreg`, `pcall` wrapping) are directly reusable.

The re-run feature has one architectural decision: the call log UI currently has no reference to the connection params needed by `execute_with_resolved_variables_async`. It only stores `self.current_connection_id`. The re-run action needs to get `ConnectionParams` from the handler (via `handler:get_current_connection()`) and then call into the dbee module's execute path. Two clean approaches exist: (1) add a thin public API function `dbee.rerun_query(query)` that wraps the existing execute flow, or (2) have the call log action call directly through `api.core.connection_execute` + `api.ui.result_set_call` + `dbee.open()`. Option 1 is cleaner because it reuses bind variable resolution.

**Primary recommendation:** Implement all three features (CLOG-01, CLIP-01, CLOG-02) in `call_log.lua` with `format_duration` extracted to a shared utility, re-run routed through a new `dbee.rerun_query()` public function, and headless tests validating display format, yank behavior, and re-run wiring.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- CLOG-01 layout: `[icon] . query_text... | 35ms | 14:32` with adaptive duration and smart date
- CLOG-01 in-progress: show "..." placeholder for duration
- CLOG-01 timestamp: HH:MM for today, MM-DD HH:MM for older
- CLIP-01: yank full original query preserving newlines/formatting
- CLIP-01: target both unnamed (`"`) and system clipboard (`+`) registers
- CLIP-01: keybinding `yy`, notification `"Yanked query (N chars)"` via `utils.log` INFO
- CLOG-02: re-run on currently selected connection (not original)
- CLOG-02: keybinding `R` (shift-R)
- CLOG-02: auto-opens dbee UI if closed
- CLOG-02: bind variables re-prompted via `execute_with_resolved_variables_async`
- CLOG-02: if no connection selected, show WARN notification (NOTIF-01 pattern)
- Cleanup: migrate `call_log.lua:202` raw `vim.notify` to `utils.log`

### Claude's Discretion
- Exact query text truncation length (currently 40 chars, may need adjustment for new columns)
- Column width padding/alignment strategy for duration and timestamp
- Whether to extract `format_duration` to a shared utility or inline it

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| CLOG-01 | User sees duration and timestamp inline on each call log tree entry | `create_tree` prepare_node already builds NuiLine with segments; add two more `line:append()` calls after query text. `format_duration` from `result/init.lua` provides the exact formatting logic. `os.date` handles smart date detection. |
| CLIP-01 | User can copy query text from call log entries to clipboard | New `yank_query` action in `get_actions()`. `vim.fn.setreg('"', text)` + `vim.fn.setreg('+', text)` + `utils.log("info", ...)`. Same pattern as Phase 1 result pane yank. |
| CLOG-02 | User can re-run a past query from call log on the current connection | New `rerun_query` action. Needs `handler:get_current_connection()` for conn params, then calls `execute_with_resolved_variables_async` (from `dbee.lua:661`). Route through new `dbee.rerun_query(query)` public API to reuse bind variable + open + result_set_call flow. |
</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| nui.nvim (NuiLine, NuiTree) | bundled | Tree rendering with styled line segments | Already used by call_log.lua; NuiLine:append(text, highlight) is the rendering primitive |
| dbee.utils | internal | `log()`, `trim()` | Phase 1 established notification pattern |
| dbee.ui.common | internal | `configure_buffer_mappings()` | Maps action names to keybindings on buffer |
| dbee.variables | internal | `resolve_for_execute_async()` | Bind variable resolution for re-run (Oracle support) |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| vim.fn.setreg | Neovim builtin | Register writes for clipboard | CLIP-01 yank to `"` and `+` registers |
| os.date / os.time | Lua stdlib | Timestamp formatting | CLOG-01 smart date display |

## Architecture Patterns

### Modified File Map
```
lua/
  dbee/
    ui/
      call_log.lua          # PRIMARY: modify create_tree, add yank_query + rerun_query actions
      result/
        init.lua             # EXTRACT: move format_duration to shared location
    utils.lua                # ADD: format_duration (shared utility)
    config.lua               # MODIFY: add yy and R default mappings at ~line 306
    dbee.lua                 # ADD: dbee.rerun_query() public API function
ci/
  headless/
    check_call_log_display.lua  # NEW: headless test for CLOG-01 + CLIP-01 + CLOG-02
```

### Pattern 1: NuiLine Segment Rendering (CLOG-01)
**What:** Each call log line is built by `create_tree`'s `prepare_node` function using `NuiLine:append(text, highlight)` calls.
**When to use:** Adding new visual columns to the call log tree.
**Current code (call_log.lua:137-164):**
```lua
-- Current: icon + separator + query (40 chars)
line:append(make_length(state_preview, 3), candy.icon_highlight)
line:append(" . ", "NonText")
line:append(make_length(string.gsub(call.query, "\n", " "), 40), candy.text_highlight)

-- New: icon + separator + query (truncated) + separator + duration + separator + timestamp
line:append(make_length(state_preview, 3), candy.icon_highlight)
line:append(" . ", "NonText")
line:append(make_length(string.gsub(call.query, "\n", " "), QUERY_WIDTH), candy.text_highlight)
line:append(" | ", "NonText")
line:append(make_length(format_duration_for_display(call), DURATION_WIDTH), "Comment")
line:append(" | ", "NonText")
line:append(format_timestamp(call.timestamp_us), "Comment")
```

### Pattern 2: Action Map + Keybinding Registration (CLIP-01, CLOG-02)
**What:** Actions are functions returned by `get_actions()`, then mapped to keys via `config.lua` defaults and `configure_buffer_mappings`.
**Current pattern (call_log.lua:176-206):**
```lua
function CallLogUI:get_actions()
  return {
    show_result = function() ... end,
    cancel_call = function() ... end,
    -- ADD:
    yank_query = function() ... end,
    rerun_query = function() ... end,
  }
end
```
Config defaults (config.lua ~306):
```lua
mappings = {
  { key = "<CR>", mode = "", action = "show_result" },
  { key = "<C-c>", mode = "", action = "cancel_call" },
  -- ADD:
  { key = "yy", mode = "n", action = "yank_query" },
  { key = "R", mode = "n", action = "rerun_query" },
},
```

### Pattern 3: Phase 1 Yank Pattern (CLIP-01)
**What:** `pcall` + `vim.fn.setreg` + `utils.log` for clipboard operations with error handling.
**Source:** `result/init.lua:458-481` (store_current_wrapper)
```lua
-- Phase 1 yank pattern for reuse:
local ok, err = pcall(vim.fn.setreg, '"', query_text)
if not ok then
  utils.log("error", "Yank failed: " .. tostring(err))
  return
end
pcall(vim.fn.setreg, '+', query_text)
utils.log("info", string.format("Yanked query (%d chars)", #query_text))
```

### Pattern 4: Re-run via Public API (CLOG-02)
**What:** Route re-run through `dbee.rerun_query(query)` to reuse the full execute flow.
**Why:** `execute_with_resolved_variables_async` is a local function in `dbee.lua` (not exposed). Creating a thin public wrapper avoids duplicating bind variable resolution, UI open, result_set_call, and error handling.
```lua
-- New public API in dbee.lua:
function dbee.rerun_query(query)
  local core_ready, core_err = ensure_core_available()
  if not core_ready then
    utils.log("warn", core_err or "dbee core not loaded")
    return
  end
  local conn = api.core.get_current_connection()
  if not conn then
    utils.log("warn", "No connection selected. Select one from the drawer, then run again.")
    return
  end
  execute_with_resolved_variables_async(conn, query, {}, function(_, err)
    if err then
      utils.log("warn", err)
    end
  end)
end
```
The call log action then simply calls:
```lua
rerun_query = function()
  local node = self.tree:get_node()
  if not node or not node.call then return end
  local dbee_mod = require("dbee")
  dbee_mod.rerun_query(node.call.query)
end
```

### Anti-Patterns to Avoid
- **Duplicating execute flow in call_log.lua:** Don't copy-paste connection checking, variable resolution, result_set_call, and dbee.open into the action. Route through dbee.lua.
- **Hardcoding column widths in prepare_node:** Use named constants at module top for QUERY_WIDTH, DURATION_WIDTH so they're easy to tune.
- **Using `vim.notify` directly:** The entire point of Phase 1 was standardizing on `utils.log`. The cleanup task (cancel_call line 202) must also migrate.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Duration formatting | Custom ms/s/min logic | Extract `format_duration` from `result/init.lua` | Already battle-tested, adaptive thresholds, handles edge cases (0, nil) |
| Smart date display | Custom date comparison | `os.date("%Y-%m-%d")` comparison with `os.date("%Y-%m-%d", ts)` | Pattern already in `api/core.lua:262-268` for `get_call_history` |
| Bind variable resolution | Manual text substitution | `execute_with_resolved_variables_async` via `dbee.rerun_query` | Handles Oracle :bind and &substitution, prompts user, validates typed literals |
| Buffer keymap registration | Manual `vim.keymap.set` | `common.configure_buffer_mappings(bufnr, actions, mappings)` | Existing infrastructure handles mode, opts, action lookup |

**Key insight:** Every component needed for Phase 2 already exists in the codebase. The work is wiring, not inventing.

## Common Pitfalls

### Pitfall 1: `yy` Mapping Conflict
**What goes wrong:** `yy` in normal mode is Neovim's default "yank line" command. Setting it as a buffer-local mapping on the call log buffer shadows the default.
**Why it happens:** Call log buffer is `nofile`/`nomodifiable` so line yank is meaningless, but users might be surprised.
**How to avoid:** This is intentional per user decision. The `mode = "n"` + `noremap = true` + `nowait = true` default opts from `configure_buffer_mappings` handle this correctly. No additional work needed.
**Warning signs:** If mode is left as `""` (all modes), visual mode `yy` would also be captured. Use `"n"` explicitly.

### Pitfall 2: Stale `self.current_connection_id` vs `handler:get_current_connection()`
**What goes wrong:** The call log tracks `self.current_connection_id` (string ID only) for filtering which connection's calls to display. But re-run needs full `ConnectionParams` (id, name, type, url) for `execute_with_resolved_variables_async`.
**Why it happens:** The call log was designed for display only, not execution.
**How to avoid:** Don't try to resolve ConnectionParams from the stored ID inside call_log.lua. Route through `dbee.rerun_query()` which calls `api.core.get_current_connection()` -- this returns the *currently selected* connection (which may differ from the original call's connection). This matches the user's decision: "re-run on currently selected connection, not the original."
**Warning signs:** If using `self.handler:get_current_connection()` directly in call_log.lua, it returns `ConnectionParams` but the call_log module doesn't import the handler's method signature for this purpose.

### Pitfall 3: Timestamp Division Precision
**What goes wrong:** `call.timestamp_us` is microseconds. Dividing by 1000000 can lose precision with large timestamps if done naively.
**Why it happens:** Lua numbers are doubles (53-bit mantissa), and Unix timestamps in microseconds since epoch are ~17 digits. `os.date` expects seconds as integer.
**How to avoid:** Use `math.floor(call.timestamp_us / 1000000)` before passing to `os.date`. This is already done correctly in `api/core.lua:261`. Follow the same pattern.

### Pitfall 4: In-Progress Duration Display
**What goes wrong:** For calls in `executing` or `retrieving` state, `time_taken_us` may be 0 or stale.
**Why it happens:** Duration is only finalized when the call reaches a terminal state.
**How to avoid:** Per user decision: show "..." for in-progress calls. Check `call.state` before formatting duration:
```lua
local is_running = call.state == "executing" or call.state == "retrieving"
local duration_text = is_running and "..." or format_duration(call.time_taken_us)
```

### Pitfall 5: Circular Require
**What goes wrong:** If `call_log.lua` requires `dbee.lua` at module level, it creates a circular dependency (dbee -> api -> state -> call_log -> dbee).
**Why it happens:** Re-run needs to call `dbee.rerun_query()`.
**How to avoid:** Use lazy require inside the action function: `local dbee_mod = require("dbee")`. Lua's module cache means this is free after first load and breaks the circular require chain.

## Code Examples

### CLOG-01: Duration + Timestamp in prepare_node
```lua
-- Source: call_log.lua prepare_node, to be modified
-- Constants at module top:
local QUERY_WIDTH = 30   -- Reduced from 40 to accommodate new columns
local DURATION_WIDTH = 8  -- Enough for "12m 34s" or "999ms"

-- Inside prepare_node:
local is_running = call.state == "executing" or call.state == "retrieving"

-- Duration column
local duration_text = is_running and "..." or utils.format_duration(call.time_taken_us)

-- Timestamp column (smart date)
local ts_text = ""
if call.timestamp_us then
  local ts = math.floor(call.timestamp_us / 1000000)
  local today = os.date("%Y-%m-%d")
  local call_date = os.date("%Y-%m-%d", ts)
  if call_date == today then
    ts_text = os.date("%H:%M", ts)
  else
    ts_text = os.date("%m-%d %H:%M", ts)
  end
end

line:append(make_length(state_preview, 3), candy.icon_highlight)
line:append(" . ", "NonText")
line:append(make_length(string.gsub(call.query, "\n", " "), QUERY_WIDTH), candy.text_highlight)
line:append(" | ", "NonText")
line:append(make_length(duration_text, DURATION_WIDTH), "Comment")
line:append(" | ", "NonText")
line:append(ts_text, "Comment")
```

### CLIP-01: Yank Query Action
```lua
-- Source: call_log.lua get_actions(), new action
yank_query = function()
  local node = self.tree:get_node()
  if not node or not node.call then
    return
  end
  local query = node.call.query
  if not query or query == "" then
    utils.log("warn", "No query to yank")
    return
  end
  local ok, err = pcall(vim.fn.setreg, '"', query)
  if not ok then
    utils.log("error", "Yank failed: " .. tostring(err))
    return
  end
  pcall(vim.fn.setreg, '+', query)
  utils.log("info", string.format("Yanked query (%d chars)", #query))
end,
```

### CLOG-02: Re-run Action
```lua
-- Source: call_log.lua get_actions(), new action
rerun_query = function()
  local node = self.tree:get_node()
  if not node or not node.call then
    return
  end
  local query = node.call.query
  if not query or query == "" then
    utils.log("warn", "No query to re-run")
    return
  end
  -- Lazy require to avoid circular dependency
  local dbee_mod = require("dbee")
  dbee_mod.rerun_query(query)
end,
```

### Shared format_duration extraction
```lua
-- Move from result/init.lua to utils.lua:
---Format microseconds into adaptive human-readable duration.
---@param us number microseconds
---@return string
function M.format_duration(us)
  us = tonumber(us) or 0
  if us <= 0 then
    return "0ms"
  end
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
Then in `result/init.lua`, replace the local function with:
```lua
local format_duration = utils.format_duration
```

### Cleanup: cancel_call migration
```lua
-- Before (line 202):
vim.notify(err, vim.log.levels.WARN)
-- After:
utils.log("warn", err)
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Call log shows only icon + query preview | Add duration + timestamp columns | Phase 2 | Audit trail without hovering |
| No clipboard access from call log | `yy` yanks full query | Phase 2 | Quick query reuse |
| Re-run requires copy-paste to editor | `R` re-executes on current connection | Phase 2 | Workflow acceleration |
| `format_duration` duplicated per-module | Shared `utils.format_duration` | Phase 2 | Single source of truth |

## Open Questions

1. **Query truncation width**
   - What we know: Currently 40 chars. With 8-char duration + 5-11 char timestamp + separators, the line gets ~20-25 chars wider.
   - What's unclear: Optimal width depends on typical call log window width. Most users have call log in a narrow sidebar.
   - Recommendation: Start with 30 chars for query text. This keeps total line width around ~55-60 chars. Easy to adjust constant later.

2. **format_duration extraction to utils vs dedicated module**
   - What we know: Only two consumers (result winbar, call log display). Utils is the natural shared location.
   - What's unclear: Whether future phases will need more formatting utilities.
   - Recommendation: Put in `utils.lua`. It's a simple function, utils already exists, and result/init.lua already requires utils.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Neovim headless Lua checks (custom, no framework) |
| Config file | ci/headless/ directory, scripts listed in .github/workflows/test.yml |
| Quick run command | `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_call_log_display.lua"` |
| Full suite command | Run all `ci/headless/check_*.lua` scripts (CI matrix handles this) |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| CLOG-01 | Duration + timestamp appear in tree node rendering | unit (headless) | `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_call_log_display.lua"` | Wave 0 |
| CLOG-01 | In-progress calls show "..." for duration | unit (headless) | Same as above | Wave 0 |
| CLOG-01 | Today's calls show HH:MM, older show MM-DD HH:MM | unit (headless) | Same as above | Wave 0 |
| CLIP-01 | Yank sets both `"` and `+` registers | unit (headless) | Same as above | Wave 0 |
| CLIP-01 | Yank notification includes char count | unit (headless) | Same as above | Wave 0 |
| CLOG-02 | Re-run calls dbee.rerun_query with correct query | unit (headless) | Same as above | Wave 0 |
| CLOG-02 | Re-run with no connection shows WARN notification | unit (headless) | Same as above | Wave 0 |
| CLEANUP | cancel_call uses utils.log not vim.notify | unit (headless) | `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_call_log_display.lua"` | Wave 0 |

### Sampling Rate
- **Per task commit:** `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_call_log_display.lua"`
- **Per wave merge:** Run all headless checks in `ci/headless/`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `ci/headless/check_call_log_display.lua` -- covers CLOG-01, CLIP-01, CLOG-02, CLEANUP
- [ ] Update `.github/workflows/test.yml` matrix to include `check_call_log_display.lua`

**Test approach:** Follow `check_notifications.lua` and `check_winbar_format.lua` patterns:
1. Stub `dbee.api`, `dbee.install`, `dbee.config`, `nui.tree`, `nui.line`, `dbee.ui.common`
2. Capture `vim.notify` calls
3. Create mock CallDetails with various states and timestamps
4. Instantiate CallLogUI with mock handler, invoke prepare_node, verify NuiLine content
5. Invoke `yank_query` action, check `vim.fn.getreg('"')` and `vim.fn.getreg('+')`
6. Invoke `rerun_query` action, verify `dbee.rerun_query` was called with correct query
7. Verify cancel_call uses utils.log (no raw vim.notify)

## Sources

### Primary (HIGH confidence)
- Direct code reading: `lua/dbee/ui/call_log.lua` -- complete file, 323 lines
- Direct code reading: `lua/dbee/ui/result/init.lua` -- `format_duration` at lines 8-23, yank pattern at lines 458-533
- Direct code reading: `lua/dbee/config.lua` -- call_log mappings at lines 300-357
- Direct code reading: `lua/dbee.lua` -- `execute_with_resolved_variables_async` at lines 661-683, `dbee.open` at line 276
- Direct code reading: `lua/dbee/doc.lua` -- `CallDetails` type at lines 59-66, `ConnectionParams` at lines 78-82
- Direct code reading: `lua/dbee/api/core.lua` -- `get_call_history` at lines 230-297 (smart date pattern)
- Direct code reading: `lua/dbee/api/ui.lua` -- call_log API surface at lines 131-145
- Direct code reading: `lua/dbee/utils.lua` -- `log()` at lines 43-63
- Direct code reading: `ci/headless/check_notifications.lua` -- headless test pattern, 418 lines
- Direct code reading: `ci/headless/check_winbar_format.lua` -- headless test pattern with result UI stubs

### Secondary (MEDIUM confidence)
- NuiLine/NuiTree API: inferred from usage patterns in codebase (no external docs checked, but usage is consistent and well-established across drawer and call_log)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all libraries already in use, no new dependencies
- Architecture: HIGH -- all patterns established in Phase 1 and existing codebase, direct code inspection
- Pitfalls: HIGH -- identified from actual code paths and type definitions

**Research date:** 2026-03-06
**Valid until:** 2026-04-06 (stable codebase, no external dependency changes expected)
