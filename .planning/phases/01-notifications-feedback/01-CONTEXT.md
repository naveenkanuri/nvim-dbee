# Phase 1: Notifications & Feedback - Context

**Gathered:** 2026-03-05
**Status:** Ready for planning

<domain>
## Phase Boundary

Every user action produces clear, immediate feedback. Replace silent failures with `vim.notify` messages (via `utils.log`), upgrade winbar labels to be self-documenting, and migrate all existing raw `vim.notify` calls to the consistent `utils.log` pattern. Covers NOTIF-01 through NOTIF-07.

</domain>

<decisions>
## Implementation Decisions

### Notification framework
- Use `utils.log()` everywhere (adds `title: "nvim-dbee"` prefix) — no raw `vim.notify` calls
- Migrate all ~25 existing `vim.notify` calls in `lua/dbee.lua` to `utils.log` for consistency
- Log levels: INFO for success, WARN for user-correctable issues, ERROR for system failures

### Notification wording policy
- **INFO (success):** Terse, scannable. Example: `"Yanked 5 rows (CSV)"`
- **WARN (user-correctable):** Friendly with contextual next step. Example: `"No connection selected. Select one from the drawer, then run again."`
- **ERROR (system failure):** Concise technical cause + action. Example: `"Failed to delete connection: <reason>"`

### NOTIF-01: No connection selected
- Already exists at `lua/dbee.lua:700` — reword to match WARN policy
- New wording: `"No connection selected. Select one from the drawer, then run again."`
- Migrate from raw `vim.notify` to `utils.log`

### NOTIF-02: Empty/blank query
- Already exists at `lua/dbee.lua:720` — reword to match WARN policy
- New wording: `"No SQL found at cursor. Place cursor on a query and try again."`
- Migrate from raw `vim.notify` to `utils.log`

### NOTIF-03: Yank feedback
- Show row count + format on success: `"Yanked 5 rows (CSV)"` / `"Yanked 1 row (JSON)"`
- Replace all `error()` calls in yank wrappers with `pcall` + `utils.log`
- Precondition failures (no results, can't determine row) -> WARN
- RPC/backend exceptions from `call_store_result` -> caught with pcall, surfaced as ERROR or WARN
- No `error()` should remain in yank code paths

### NOTIF-04: Drawer operation failures
- `pcall` calls at `lua/dbee/ui/drawer/convert.lua:173,227,244` currently ignore return values
- Capture pcall error and surface via `utils.log`: `"Failed to add connection: <reason>"`
- Pattern: `local ok, err = pcall(...); if not ok then utils.log("error", ...) end`

### NOTIF-05: Replace error() in yank wrappers
- Covered by NOTIF-03 decision above — pcall + utils.log replaces all error() calls
- Applies to `store_current_wrapper`, `store_selection_wrapper`, `store_all_wrapper` in `result/init.lua`
- Also applies to `current_row_index` and `current_row_range` helper functions

### NOTIF-06: Schema refresh notification
- Fire on manual refresh only, not on initial auto-load
- Show connection name: `"Schema loaded: my-postgres-dev"`
- Uses `structure_loaded` event — need flag to distinguish manual refresh from auto-load

### NOTIF-07: Winbar label format
- Completed results: `"Page 1/3 | 42 rows | 0.035s"` — left-aligned, pipe-separated, human-readable labels
- Adaptive duration formatting: <1s -> ms (35ms), >=1s -> seconds (1.23s), >=60s -> min+sec (2m 15s)
- During executing state: winbar shows `"Executing..."`
- During retrieving state: winbar shows `"Retrieving..."`
- Default/empty state: winbar shows `"Results"`

### Claude's Discretion
- Exact implementation of manual-refresh flag for NOTIF-06 (event data field vs state tracking)
- How to compute row count for yank feedback (Go-side vs Lua-side)
- Whether to batch the vim.notify migration into one commit or split by area

</decisions>

<specifics>
## Specific Ideas

- Notification wording should follow the tiered policy consistently: terse INFO, contextual WARN, technical ERROR
- The ~25 existing vim.notify calls in dbee.lua should all be migrated to utils.log in this phase (clean sweep)

</specifics>

<code_context>
## Existing Code Insights

### Reusable Assets
- `utils.log(level, msg, module)` at `lua/dbee/utils.lua:63` — wraps vim.notify with `title: "nvim-dbee"`
- `structure_loaded` event already fires from Go and is consumed by drawer (`drawer/init.lua:128`)
- Winbar is already set in `result/init.lua:264` — just needs format string change

### Established Patterns
- Event listeners registered via `handler:register_event_listener(event, callback)` — used for schema refresh
- pcall wrapping for RPC calls — established in drawer, needs error capture added
- `vim.log.levels.INFO/WARN/ERROR` used throughout — consistent level semantics

### Integration Points
- `lua/dbee.lua` — migrate ~25 vim.notify calls, reword NOTIF-01/02
- `lua/dbee/ui/result/init.lua` — winbar format (line 264), yank wrappers (lines 427-481)
- `lua/dbee/ui/drawer/convert.lua` — pcall error capture (lines 173, 227, 244)
- `lua/dbee/ui/drawer/init.lua` or event listener — schema refresh notification

</code_context>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 01-notifications-feedback*
*Context gathered: 2026-03-05*
