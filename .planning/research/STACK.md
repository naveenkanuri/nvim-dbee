# Technology Stack: QoL Improvements

**Project:** nvim-dbee QoL Improvements
**Researched:** 2026-03-05
**Minimum Neovim:** 0.11.x (CI: v0.11.6)

## Existing Stack (No Changes)

The QoL milestone introduces zero new dependencies. Everything needed is already available through the existing Neovim Lua API and nui.nvim.

| Layer | Technology | Status |
|-------|-----------|--------|
| Go backend | Go 1.23, adapter GetHelpers pattern | Extend, don't replace |
| Lua frontend | Neovim Lua 5.1/LuaJIT | Already in use |
| Tree rendering | nui.nvim (NuiTree, NuiLine, NuiMenu, NuiInput) | Already a dependency |
| Notifications | `vim.notify` with `{ title = "nvim-dbee" }` | Already established pattern |
| Diagnostics | `vim.diagnostic` API | Already used for Oracle error locations |
| Keybindings | `vim.keymap.set` with buffer-local opts | Already established pattern |
| Winbar | `vim.api.nvim_win_set_option(winid, "winbar", ...)` | Already used in ResultUI |

---

## API Reference by Feature Area

### 1. Notifications (`vim.notify`)

**Confidence:** HIGH -- already used extensively throughout the codebase.

**Current pattern** (from `lua/dbee/utils.lua:46-64`):
```lua
function M.log(level, message, subtitle)
  vim.notify(subtitle .. " " .. message, l, { title = "nvim-dbee" })
end
```

**What to use:** Continue using `vim.notify(msg, level, { title = "nvim-dbee" })` directly or `utils.log()` for consistency.

**Relevant items:** 1 (no connection), 2 (empty query), 3 (yank success), 5 (drawer errors), 7 (schema refresh), 13 (replace error() in yanks)

**What NOT to use:**
- `vim.api.nvim_echo` -- cmdline, gets overwritten
- `print()` -- no log level
- `error()` for user-facing messages -- throws exceptions

### 2. Winbar Customization

**Confidence:** HIGH -- already used in ResultUI.

**Enriched format:**
```lua
string.format("Page %d/%d  |  %d rows%%=%.3fs", page + 1, total_pages, total_rows, seconds)
```

**Deprecation note:** `nvim_win_set_option` deprecated since 0.10. Migrate to `vim.wo[win].winbar = value`.

### 3. Keybinding Management

**Confidence:** HIGH -- existing `configure_buffer_mappings` pattern.

**For note cycling:** Add `note_next`/`note_prev` actions to `EditorUI:get_actions()`. Default keys: `]n`/`[n`.

**For pane jumping:** Add `focus_editor`/`focus_result`/`focus_drawer`/`focus_call_log` actions to all UI modules. Default keys: `<C-w>e`/`<C-w>r`/`<C-w>d`/`<C-w>l`.

### 4. Tree Filtering / Drawer Search

**Confidence:** MEDIUM -- NuiTree has no built-in filter API.

**Approach:** Client-side filter using `NuiInput` for capture, store original nodes, filter by name match, `tree:set_nodes(filtered)` + `tree:render()`. Clear with `<Esc>`.

### 5. Inline Diagnostics

**Confidence:** HIGH -- already implemented for Oracle, need to generalize.

Remove Oracle-only gate. Add per-adapter error parsers:

| Adapter | Error format | Parseable? |
|---------|-------------|------------|
| Oracle | `line N, column M` | YES (done) |
| PostgreSQL | `LINE N:` | YES -- add |
| MySQL | `at line N` | YES -- add |
| SQLite | No line info | NO -- use query start |
| SQL Server | `Line N` | PARTIAL |
| DuckDB | `LINE N:` | YES -- add |

### 6. Clipboard / Yank

**Confidence:** HIGH. Use `vim.fn.setreg("+", text)` + `vim.fn.setreg('"', text)`.

### 7. EXPLAIN PLAN Wrapping

**Confidence:** HIGH. Lua-side query wrapping (not Go-side).

```lua
local explain_wrappers = {
  postgres  = function(q) return "EXPLAIN ANALYZE " .. q end,
  mysql     = function(q) return "EXPLAIN " .. q end,
  sqlite    = function(q) return "EXPLAIN QUERY PLAN " .. q end,
  oracle    = function(q) return "EXPLAIN PLAN FOR " .. q end,
  sqlserver = function(q) return "SET SHOWPLAN_TEXT ON;\n" .. q .. ";\nSET SHOWPLAN_TEXT OFF" end,
  duck      = function(q) return "EXPLAIN ANALYZE " .. q end,
}
```

**Oracle caveat:** Two-step -- `EXPLAIN PLAN FOR` + `SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY)`.

### 8. Auto-Reconnect Prompt

**Confidence:** HIGH. Reuse cancel-confirm pattern with `vim.ui.select`.

### 9. Call Log Enrichment

**Confidence:** HIGH. Extend NuiLine rendering with duration/timestamp. Add `copy_query` and `rerun_query` actions.

### 10. Export Results to File

**Confidence:** MEDIUM. Go backend has `call_store_result`. Prompt path with `vim.ui.input`, use existing RPC.

---

## Deprecated APIs to Migrate

| Deprecated | Replacement | Occurrences |
|-----------|-------------|-------------|
| `nvim_buf_set_option(buf, k, v)` | `vim.bo[buf][k] = v` | ~15 calls |
| `nvim_win_set_option(win, k, v)` | `vim.wo[win][k] = v` | ~5 calls |

Migrate in a single mechanical commit, separate from feature work.

---

## Alternatives Considered

| Category | Recommended | Alternative | Why Not |
|----------|-------------|-------------|---------|
| Notifications | `vim.notify` | nvim-notify plugin | Users override globally already |
| Drawer filter | Client-side NuiTree | Telescope | Heavy dependency, loses tree context |
| EXPLAIN | Lua-side wrappers | Go GetHelpers | Wrong abstraction layer |
| Diagnostics | `vim.diagnostic.set` | Raw extmarks | Diagnostic API gives floats/signs for free |
| Clipboard | `vim.fn.setreg` | OSC52/xclip | setreg delegates to clipboard provider |

---

*Stack analysis: 2026-03-05*
