# Phase 3: Editor & Result Actions - Research

**Researched:** 2026-03-08
**Domain:** Neovim plugin Lua -- editor note cycling, result export, explain plan dispatch
**Confidence:** HIGH

## Summary

Phase 3 adds three independent features to nvim-dbee: note cycling in the editor pane, file export from the result pane, and adapter-aware explain plan execution. All three are Lua-only changes with no Go backend modifications required.

The codebase has well-established patterns for all three features. Note cycling leverages existing `namespace_get_notes()` and `set_current_note()`. File export leverages the existing `call_store_result(id, format, "file", { extra_arg = path })` Go backend. Explain plan requires a new query-wrapping layer that dispatches per `conn.type`, then feeds the wrapped query through the existing `connection_execute` path.

**Primary recommendation:** Implement as three independent tasks (NAV-01, RSLT-01, ADPT-01) since they touch different files with no interdependencies.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- NAV-01: Cycle within current namespace only, wrap at boundaries, `]n`/`[n` keybindings, uses `namespace_get_notes()` sorted list
- RSLT-01: Path via `vim.ui.input()`, default `CWD/result.csv`, format from extension, confirm overwrite, `ge` keybinding, exports all rows, uses existing Go backend
- ADPT-01: Postgres/MySQL `EXPLAIN <query>`, SQLite `EXPLAIN QUERY PLAN <query>`, Oracle singleton-listener two-step (EXPLAIN PLAN FOR + DBMS_XPLAN.DISPLAY), unsupported adapter warns, `gE` keybinding (normal + visual)

### Claude's Discretion
- How to determine current namespace for note cycling (from current_note_id or active connection)
- Oracle singleton-listener two-step explain lifecycle details (singleton async listener + pending map + timeout cleanup)
- Whether to add explain_plan to the dbee.actions() picker menu

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| NAV-01 | User can cycle to next/previous note with keybindings without leaving editor | `namespace_get_notes()` returns sorted list; `set_current_note()` switches + restores result; `search_note()` finds namespace from note_id |
| RSLT-01 | User can export results to a file (CSV/JSON) from the result pane via path prompt | `call_store_result(id, format, "file", { extra_arg = path })` already works in Go backend; `ResultUI.current_call` holds active call |
| ADPT-01 | User can execute Explain Plan on current query with per-adapter EXPLAIN syntax wrapping | `conn.type` available from `get_current_connection()`; query extraction via `query_under_cursor()` and `visual_selection()` already in codebase |
</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| nvim-dbee internal APIs | current | All three features | Existing architecture, no external deps |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| vim.ui.input | built-in | File path prompt for RSLT-01 | Benefits from snacks/dressing overrides |
| vim.ui.select | built-in | Overwrite confirmation for RSLT-01 | Consistent with cancel-confirm pattern |
| vim.fn.filereadable | built-in | Check if export path already exists | Overwrite guard |
| vim.fn.fnamemodify | built-in | Extract file extension | Format inference |

### Alternatives Considered
None -- all features use existing infrastructure.

## Architecture Patterns

### Recommended Project Structure

No new files needed. Changes go into existing files:
```
lua/dbee/ui/editor/init.lua   -- note_next/note_prev actions in get_actions()
lua/dbee/ui/result/init.lua   -- export_result action in get_actions()
lua/dbee/config.lua            -- default keybindings: ]n, [n, ge, gE
lua/dbee.lua                   -- dbee.explain_plan() public API
ci/headless/                   -- test scripts for each requirement
```

### Pattern 1: Action Registration via get_actions()

**What:** Each UI component (EditorUI, ResultUI) exposes a `get_actions()` method returning a table of `{ action_name = function }`. These are wired to keybindings via `common.configure_buffer_mappings(bufnr, actions, mappings)`.

**When to use:** All three features follow this pattern.

**Example (existing pattern from result/init.lua):**
```lua
function ResultUI:get_actions()
  return {
    page_next = function()
      self:page_next()
    end,
    -- ... more actions
    cancel_call = function()
      if self.current_call then
        local ok, err = self.handler:call_cancel(self.current_call.id)
        if ok == false and err then
          utils.log("warn", err)
        end
      end
    end,
  }
end
```

**Keybinding registration (config.lua):**
```lua
mappings = {
  { key = "L", mode = "", action = "page_next" },
  -- mode="" means all modes, mode="n" means normal only
  -- mode="v" for visual
}
```

### Pattern 2: Query Extraction (Normal + Visual)

**What:** `dbee.execute_context()` already handles both normal mode (query_under_cursor) and visual mode (visual_selection). Explain plan reuses this exact pattern.

**Existing code at dbee.lua:706-717:**
```lua
local mode = vim.api.nvim_get_mode().mode
if mode:match("^[vV\22]") then
  local srow, scol, erow, ecol = utils.visual_selection()
  local selection = vim.api.nvim_buf_get_text(0, srow, scol, erow, ecol, {})
  query = utils.trim(table.concat(selection, "\n"))
else
  local under_cursor = utils.query_under_cursor(vim.api.nvim_get_current_buf(), {
    adapter_type = conn.type,
  })
  query = utils.trim(under_cursor)
end
```

### Pattern 3: Adapter Type Dispatch

**What:** `conn.type` is a string like `"postgres"`, `"mysql"`, `"sqlite"`, `"oracle"`. Use simple table lookup for explain syntax mapping.

**Recommended pattern:**
```lua
local explain_wrappers = {
  postgres = function(q) return "EXPLAIN " .. q end,
  mysql    = function(q) return "EXPLAIN " .. q end,
  sqlite   = function(q) return "EXPLAIN QUERY PLAN " .. q end,
  -- Oracle is special: two-step, handled separately
}
```

### Anti-Patterns to Avoid
- **Don't add explain logic to EditorUI:get_actions() directly:** The explain plan has adapter dispatch logic and Oracle singleton-listener two-step complexity. Keep it in `dbee.lua` as a public API function (`dbee.explain_plan()`), then have the editor action call it. This matches the pattern of `dbee.execute_context()` being called from editor actions.
- **Don't modify Go backend for file export:** `call_store_result(id, "csv", "file", { extra_arg = path })` already works. The Lua side just needs to prompt for path and call it.
- **Don't use vim.notify directly:** All notifications go through `utils.log(level, msg)` per Phase 1 convention.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| File export | Custom CSV/JSON writer | `call_store_result(id, format, "file", { extra_arg = path })` | Go backend already handles all formatting, pagination, file I/O |
| Note ordering | Custom sort | `namespace_get_notes(id)` | Already returns name-sorted list |
| Query extraction | Custom parser | `utils.query_under_cursor()` + `utils.visual_selection()` | Already handles tree-sitter, block detection, SQL filetype check |
| Path input UI | Custom floating window | `vim.ui.input()` | Benefits from user's snacks/dressing overrides |

**Key insight:** Every complex operation already exists in the codebase. Phase 3 is purely orchestration and wiring.

## Common Pitfalls

### Pitfall 1: Namespace Determination for Note Cycling
**What goes wrong:** Using `handler:get_current_connection()` to determine namespace, but the "global" namespace notes aren't tied to any connection.
**Why it happens:** Notes live in namespaces (connection ID or "global"), but the current namespace isn't tracked explicitly.
**How to avoid:** Use `self:search_note(self.current_note_id)` which returns `(note, namespace)`. The second return value is the namespace of the current note. Cycle within that namespace.
**Warning signs:** Notes from wrong namespace appearing in cycle.

### Pitfall 2: Export When No Results Exist
**What goes wrong:** Calling `call_store_result` when `self.current_call` is nil causes an error.
**Why it happens:** User presses `ge` before running any query.
**How to avoid:** Guard with `if not self.current_call then utils.log("warn", "No results to export") return end` -- same pattern as existing yank actions.

### Pitfall 3: Oracle Two-Step Explain Timing
**What goes wrong:** The `EXPLAIN PLAN FOR <query>` must complete before `SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY)` is executed, but `connection_execute` is async.
**Why it happens:** Go backend executes queries asynchronously with call state callbacks.
**How to avoid:** Use non-blocking async chaining: execute step 1, track it in a pending map keyed by call ID, and have a singleton `call_state_changed` listener fire step 2 only when step 1 reaches `archived`.
**Recommendation:** Do NOT register one listener per explain call (event bus has no unregister API). Use one shared listener + pending map + timeout cleanup (`timer:stop()` / `timer:close()`) to avoid callback leaks and false timeout warnings.

### Pitfall 4: File Overwrite Race Condition
**What goes wrong:** Between the `filereadable` check and the actual write, another process could create the file.
**Why it happens:** TOCTOU race.
**How to avoid:** Accept this as a non-issue for a development tool. The confirmation prompt is a UX courtesy, not a safety guarantee.

### Pitfall 5: Visual Mode gE Keybinding
**What goes wrong:** Visual selection marks (`'<`, `'>`) aren't set until after leaving visual mode.
**Why it happens:** Neovim sets visual marks only on mode exit.
**How to avoid:** `utils.visual_selection()` already handles this -- it calls `nvim_feedkeys("<esc>", "x", false)` first. But the keybinding mode must be `"v"` (not `""`), and the action must check mode before extracting query. Pattern: register `gE` twice in config.lua -- once for `mode="n"` and once for `mode="v"`.

## Code Examples

### NAV-01: Note Cycling Implementation

```lua
-- In EditorUI:get_actions(), add:
note_next = function()
  if not self.current_note_id then return end
  local _, namespace = self:search_note(self.current_note_id)
  if namespace == "" then return end
  local notes = self:namespace_get_notes(namespace)
  if #notes <= 1 then return end

  local current_idx = nil
  for i, note in ipairs(notes) do
    if note.id == self.current_note_id then
      current_idx = i
      break
    end
  end
  if not current_idx then return end

  local next_idx = current_idx % #notes + 1  -- wraps: last -> first
  self:set_current_note(notes[next_idx].id)
end,

note_prev = function()
  -- Same logic but: (current_idx - 2) % #notes + 1
  -- wraps: first -> last
end,
```

### RSLT-01: File Export Implementation

```lua
-- In ResultUI:get_actions(), add:
export_result = function()
  if not self.current_call then
    utils.log("warn", "No results to export")
    return
  end

  local default_path = vim.fn.getcwd() .. "/result.csv"
  vim.ui.input({ prompt = "Export to: ", default = default_path }, function(path)
    if not path or path == "" then return end

    local ext = vim.fn.fnamemodify(path, ":e"):lower()
    local format_map = { csv = "csv", json = "json" }
    local format = format_map[ext]
    if not format then
      utils.log("warn", "Unsupported format '." .. ext .. "'. Use .csv or .json")
      return
    end

    local function do_export()
      local ok, err = pcall(self.handler.call_store_result, self.handler,
        self.current_call.id, format, "file", { extra_arg = path })
      if not ok then
        utils.log("error", "Export failed: " .. tostring(err))
        return
      end
      local count = self.total_rows or 0
      utils.log("info", string.format("Exported %d rows to %s", count, path))
    end

    if vim.fn.filereadable(path) == 1 then
      vim.ui.select({ "No", "Yes" }, {
        prompt = "File exists. Overwrite?",
      }, function(choice)
        if choice == "Yes" then do_export() end
      end)
    else
      do_export()
    end
  end)
end,
```

### ADPT-01: Explain Plan Dispatch

```lua
-- In dbee.lua, module-level singleton listener state:
local explain_oracle_pending = {} -- [step1_call_id] = { conn_id, timer }
local explain_oracle_listener_registered = false

local function stop_timeout_timer(timer)
  if not timer then return end
  pcall(function()
    if timer.stop then timer:stop() end
    if timer.close then timer:close() end
  end)
end

local function ensure_oracle_explain_listener()
  if explain_oracle_listener_registered then return end
  explain_oracle_listener_registered = true
  api.core.register_event_listener("call_state_changed", function(data)
    if not data or not data.call or not data.call.id then return end
    local pending = explain_oracle_pending[data.call.id]
    if not pending then return end
    local state = data.call.state
    if not terminal_states[state] then
      return
    end
    stop_timeout_timer(pending.timer)
    explain_oracle_pending[data.call.id] = nil
    if state ~= "archived" then
      utils.log("warn", "Explain plan failed (step 1): " .. (data.call.error or state))
      return
    end
    local ok2, step2_call = pcall(api.core.connection_execute, pending.conn_id,
      "SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY)")
    if not ok2 then
      utils.log("warn", "Explain plan failed (step 2): " .. tostring(step2_call))
      return
    end
    api.ui.result_set_call(step2_call)
    dbee.open()
  end)
end

-- In dbee.lua, new public API function:
function dbee.explain_plan(opts)
  opts = opts or {}
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

  -- Extract query via shared helper:
  -- 1) opts.query override, 2) opts.is_visual explicit path,
  -- 3) runtime visual-mode fallback, 4) query_under_cursor.
  local query = extract_query_from_context(conn, opts)

  if query == "" then
    utils.log("warn", "No SQL found at cursor. Place cursor on a query and try again.")
    return
  end

  local adapter = conn.type:lower()
  local wrappers = {
    postgres = function(q) return "EXPLAIN " .. q end,
    mysql    = function(q) return "EXPLAIN " .. q end,
    sqlite   = function(q) return "EXPLAIN QUERY PLAN " .. q end,
  }

  if adapter == "oracle" then
    ensure_oracle_explain_listener()

    local step1 = "EXPLAIN PLAN FOR " .. query
    local ok1, step1_call = pcall(api.core.connection_execute, conn.id, step1)
    if not ok1 then
      utils.log("warn", "Explain plan failed (step 1)")
      return
    end

    local step1_id = step1_call.id
    local timeout_timer = vim.defer_fn(function()
      explain_oracle_pending[step1_id] = nil
      utils.log("warn", "Explain plan timed out (step 1 took >10s)")
    end, 10000)
    explain_oracle_pending[step1_id] = {
      conn_id = conn.id,
      timer = timeout_timer,
    }
    return
  end

  local wrapper = wrappers[adapter]
  if not wrapper then
    utils.log("warn", "Explain Plan not supported for " .. conn.type)
    return
  end

  local explain_query = wrapper(query)
  local ok, call = pcall(api.core.connection_execute, conn.id, explain_query)
  if not ok then
    utils.log("warn", "Explain plan failed: " .. tostring(call))
    return
  end
  api.ui.result_set_call(call)
  dbee.open()
end
```

**Oracle singleton-listener two-step note:** This uses a non-blocking singleton-listener design. It avoids `vim.wait()` UI blocking and avoids callback leaks from per-call listener registration.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `vim.notify()` direct calls | `utils.log(level, msg)` | Phase 1 (2026-03-06) | All notifications unified |
| Raw `vim.fn.input()` | `vim.ui.input()` with callback | Neovim 0.6+ | Allows snacks/dressing overrides |

**Deprecated/outdated:**
- None relevant to this phase.

## Implementation Notes

1. **Oracle EXPLAIN PLAN listener lifecycle**
   - `connection_execute` is async and event listeners are register-only (no unregister API in event bus).
   - Required design: one singleton `call_state_changed` listener + pending map keyed by step1 call id.
   - Always clean pending entries and stop/close timers on terminal state or timeout.

2. **Explain Plan in actions() picker**
   - Include `explain_plan` in `dbee.actions()` for supported adapters only (postgres/mysql/sqlite/oracle).
   - Keep insertion near "Execute Script" for discoverability.

3. **Editor gE wiring**
   - Keep Explain Plan logic in `dbee.lua` as public API.
   - Editor actions use lazy `require("dbee").explain_plan()` with separate normal/visual action IDs.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Neovim headless Lua (custom, no plenary) |
| Config file | none -- scripts self-contained |
| Quick run command | `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_<name>.lua"` |
| Full suite command | `for f in ci/headless/check_*.lua; do nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile $f"; done` |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| NAV-01 | Note cycling wraps, stays in namespace, restores result | unit | `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_note_cycling.lua"` | No -- Wave 0 |
| RSLT-01 | Export prompts path, infers format, guards no-call, overwrite confirm | unit | `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_result_export.lua"` | No -- Wave 0 |
| ADPT-01 | Explain wraps query per adapter, Oracle singleton-listener two-step, visual extraction path, unsupported warns | unit | `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_explain_plan.lua"` | No -- Wave 0 |

### Sampling Rate
- **Per task commit:** run the specific check script for that task
- **Per wave merge:** run all `ci/headless/check_*.lua` scripts
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `ci/headless/check_note_cycling.lua` -- covers NAV-01: mock EditorUI with notes, verify cycling wraps, stays in namespace
- [ ] `ci/headless/check_result_export.lua` -- covers RSLT-01: mock handler/call, verify format inference, no-call guard, path prompt flow
- [ ] `ci/headless/check_explain_plan.lua` -- covers ADPT-01: wrapper dispatch, visual extraction path, Oracle singleton-listener + pending-map + timeout cleanup, unsupported adapter warning

## Sources

### Primary (HIGH confidence)
- Direct code reading of `lua/dbee/ui/editor/init.lua` -- namespace_get_notes, set_current_note, search_note, get_actions pattern
- Direct code reading of `lua/dbee/ui/result/init.lua` -- store_all_wrapper, get_actions pattern, current_call state
- Direct code reading of `lua/dbee/handler/init.lua` -- call_store_result with "file" output and extra_arg
- Direct code reading of `lua/dbee.lua` -- execute_context query extraction, actions() picker, rerun_query pattern
- Direct code reading of `lua/dbee/config.lua` -- keybinding format, mode conventions
- Direct code reading of `lua/dbee/ui/common/init.lua` -- configure_buffer_mappings implementation
- Direct code reading of `lua/dbee/doc.lua` -- ConnectionParams type (id, name, type, url)
- Direct code reading of `ci/headless/check_call_log_display.lua` -- headless test pattern

### Secondary (MEDIUM confidence)
- None needed -- all findings from direct code analysis

### Tertiary (LOW confidence)
- Oracle DBMS_XPLAN.DISPLAY availability assumed standard (Oracle 9i+)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - all APIs verified in source code
- Architecture: HIGH - three features follow established patterns exactly
- Pitfalls: HIGH - identified from code structure analysis, edge cases visible in existing guards

**Research date:** 2026-03-08
**Valid until:** 2026-04-08 (stable codebase, no external deps)
