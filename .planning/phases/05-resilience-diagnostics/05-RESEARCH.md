# Phase 5: Resilience & Diagnostics - Research

**Researched:** 2026-04-23
**Domain:** Neovim Lua UI, event-driven reconnect UX, connection-scoped diagnostics, additive Go event metadata
**Confidence:** HIGH

## Summary

Phase 5 splits cleanly into two execution plans:

1. `05-01` implements `CONN-01` by adding a connection-scoped reconnect episode manager, a connection-specific reconnect helper, and a single Yes/No prompt per disconnect episode.
2. `05-02` implements `ADPT-02` by extracting a shared SQL diagnostic framework from the current Oracle-only editor path and adding parser coverage plus fallback behavior for the rest of the SQL adapter surface.

The main technical tension is real: `.planning/ROADMAP.md` still says the milestone is "Lua-only", but the live code does not currently expose enough `call_state_changed` metadata to satisfy the locked Phase 5 contract in Lua alone. Today the Go event payload omits both the affected connection ID and the classified `error_kind`, even though Go already computes the latter and already knows which connection launched the call. The cleanest Phase 5 path is therefore **minimal Go event enrichment only**:

- add `conn_id` to `call_state_changed`
- add `call.error_kind` to the emitted event payload

No new backend workflows, retry loops, or reconnect endpoints are needed. Lua remains the owner of prompt debounce, retry selection, parser registration, diagnostic lifecycle, and UI rendering.

## Current-State Findings

### Reconnect / execution ownership

- `lua/dbee.lua` already has `find_latest_disconnected_call()`, `reconnect_current_connection()`, and `retry_last_disconnected()` helpers, but they are **current-connection-scoped** rather than arbitrary-connection-scoped.
- `lua/dbee.lua` also owns one execution helper, `execute_with_resolved_variables_async(conn, query, opts, on_done)`, which resolves variables and calls `api.core.connection_execute`.
- `lua/dbee/ui/editor/init.lua` duplicates that execution pattern inside `EditorUI:get_actions()` via a local `execute_query_with_variables_async()` helper.
- `EditorUI` already stores note/call ownership in `note_calls`, `call_note_ids`, and `note_exec_meta`, but `note_exec_meta` currently tracks only `{ bufnr, offset, conn_type }`, not `conn_id`, `conn_name`, `resolved_query`, or the start-line/start-column metadata Phase 5 needs for reconnect ownership and precise diagnostics.
- `EditorUI` already contains the exact `vim.ui.select` cancel-confirm UX precedent Phase 5 wants to reuse.

### Event metadata gap

- `dbee/core/call_error_kind.go` already classifies failures as `disconnected`, `timeout`, `canceled`, or `unknown`.
- RPC-returned `CallDetails` already carry `error_kind` through `dbee/handler/marshal.go`.
- `dbee/handler/event_bus.go` does **not** currently include `error_kind` or `conn_id` in the `call_state_changed` Lua event payload.
- `dbee/handler/handler.go` already knows the launching `connID` inside `ConnectionExecute()`, so the missing `conn_id` is an event-serialization problem, not an architectural blocker.

### Diagnostics baseline

- `lua/dbee/ui/editor/init.lua` already applies Oracle diagnostics on `executing_failed` by:
  - finding the note via `call_note_ids`
  - reading `note_exec_meta`
  - resetting the old namespace
  - parsing Oracle line/column
  - calling `vim.diagnostic.set()`
  - jumping the cursor when the note buffer is visible
- The current diagnostic namespace is a single global namespace (`dbee_diagnostics`), not a connection-scoped namespace.
- Successful executions already clear Oracle diagnostics on `archived`.
- There is no shared parser registry or fallback diagnostic path for other SQL adapters.

### Result UX baseline

- `lua/dbee/ui/result/init.lua` already distinguishes disconnected, timeout, and canceled failures in status text.
- The disconnected status text still points users to the manual reconnect action, so Phase 5 should update that copy to avoid contradicting the new prompt flow.

## Recommendations

### R1. Minimal Go change for `call_state_changed`

Use the smallest backend change that unblocks the Lua-owned behavior:

- change `eventBus.CallStateChanged()` to emit:
  - top-level `conn_id`
  - `call.error_kind = call.ErrorKind()`
- pass `connID` from `handler.ConnectionExecute()` into the event bus

This keeps Phase 5 aligned with the locked decision "Go stays source of error classification; Lua owns UI behavior" while avoiding brittle Lua inference from error text.

### R2. Connection-specific reconnect helper behind existing wrappers

Promote reconnect ownership from "current connection only" to "arbitrary connection with context restore":

- move the connection-specific reconnect implementation behind an internal helper (recommended home: `lua/dbee/reconnect.lua`)
- keep `reconnect_current_connection()` as the backward-compatible public wrapper
- keep `retry_last_disconnected()` as a wrapper over the same registry-owned reconnect path, falling back to legacy replay only for recognizable flat SQL when no registry entry exists for the current connection; opaque/synthetic flows warn and abort per D-27
- if reconnecting a non-current connection requires a temporary current-connection swap, capture and restore the previous current connection before returning

This satisfies the locked requirement that the reconnect contract is per connection, not per currently focused pane.

### R3. Shared reconnect episode manager in Lua

Create a narrow new Lua module, recommended path: `lua/dbee/reconnect.lua`, to avoid scattering prompt state across `dbee.lua` and `EditorUI`.

Recommended responsibilities:

- register replayable call metadata keyed by `call_id`
- maintain `call_ids_by_conn[conn_id]` so reset/rewrite paths stay scoped to one connection instead of sweeping the whole registry
- track reconnect episode state keyed by `conn_id`
- open at most one prompt per connection episode
- coalesce newer disconnected failures by replacing the episode's `latest_call_id`
- decline once, then suppress repeat prompts until reset
- reset episode on successful call completion or explicit reconnect attempt
- retry only the newest failed SQL call on confirm
- invoke an optional owner callback after retry creates the replacement call, so editor-owned calls can rebind note state cleanly
- emit a reconnect-local `on_connection_rewritten(old_id, new_id)` signal so diagnostics cleanup can react to connection identity rewrites without depending on `current_connection_changed`

This module should be small and stateful, not a generic execution framework.

### R4. Store replayable execution metadata, not just raw query text

Auto-retry must not reopen variable prompts or drop Oracle bind values. Storing only the original source SQL is insufficient.

Recommended per-call retry payload:

```lua
{
  conn_id = conn.id,
  conn_name = conn.name,
  conn_type = conn.type,
  resolved_query = resolved_query,
  exec_opts = {
    -- shallow-copy top-level keys and deep-copy the mutable binds subtree
    binds = copied_binds,
  },
  note_id = note_id,
  bufnr = bufnr,
  start_line = start_line,
  start_col = start_col,
  on_retry_created = function(new_call, meta) ... end,
}
```

Key point: replay the already-resolved SQL + copied `exec_opts`, not the pre-resolution text. Because Phase 5 bind values live under `exec_opts.binds`, copying only the top-level table is insufficient.

### R5. Shared diagnostic framework, but keep Oracle explain cleanup deferred unless trivial

Recommended new module: `lua/dbee/ui/editor/diagnostics.lua`.

Responsibilities:

- normalize adapter aliases (`pg` -> `postgres`, `mssql` -> `sqlserver`, `sqlite3` -> `sqlite`) through a reverse alias map built at registration time
- register parser functions by canonical adapter name
- expose `is_sql_adapter()`
- expose `build_diagnostic(adapter, err_msg, ctx)` returning either:
  - a precise diagnostic (`line`, `col`, `message`)
  - a SQL fallback diagnostic at `1:1`
  - `nil` for non-SQL adapters
  - always `severity = vim.diagnostic.severity.ERROR` in Phase 5

Recommended parser scope:

- `postgres`: precise parse when error includes line/position context
- `mysql`: line-aware parse when line exists; column defaults to `1` when the driver omits it
- `sqlite`: fallback-only at `1:1` in Phase 5; the current driver surface does not provide reliable line/column metadata
- `sqlserver`: parse line/column when available; line + `col=1` otherwise
- `oracle`: move the existing parser into the shared registry only if extraction is mechanical; do not rewrite the two-step explain-plan listener just to achieve purity
- Explain Plan diagnostic expansion is out of scope for Phase 5 per D-25; Oracle Explain keeps its special-case behavior and non-Oracle Explain stays result/notify-only

This is the most honest reading of the locked decision: preserve Oracle correctness, unify only the part that is nearly free, defer the rest.

### R6. Make 05-02 depend on 05-01

Feature-wise the plans are independent, but execution should still be sequential because:

- both plans modify `lua/dbee/ui/editor/init.lua`
- 05-02 benefits from the connection-aware metadata added in 05-01
- the same `call_state_changed` event payload expansion helps both plans

That makes `05-02 -> depends_on: ["05-01"]` the safer and clearer planner choice.

## Recommended Plan Split

### Plan 05-01 — `CONN-01` auto-reconnect prompt

Scope:

- minimal Go event enrichment (`conn_id`, `call.error_kind`)
- new connection-specific reconnect helper in `lua/dbee.lua`
- reconnect episode manager in Lua
- editor and non-editor execution paths register replayable call metadata
- result status text updated to match the new prompt behavior
- headless reconnect tests

### Plan 05-02 — `ADPT-02` generic diagnostics

Scope:

- new shared SQL diagnostics module
- connection-scoped diagnostic namespaces
- parser-backed diagnostics for postgres/mysql/sqlserver/oracle normal execution, with SQLite registered as a truthful fallback-only SQL adapter
- SQL fallback at `1:1` for other SQL adapters
- Oracle baseline preserved, with parser extraction only if trivial
- explicit `clear_diagnostics` editor action
- note-switch/rerun/success cleanup
- headless diagnostics tests and workflow wiring

## Testing Strategy

### `check_auto_reconnect.lua`

Headless cases should verify:

- prompt opens only for disconnected terminal failures
- prompt is keyed by connection and includes the connection name
- repeat failures on the same connection while a prompt is pending do not open a second prompt
- newest failed call replaces the retry target for that connection
- confirm reconnects only the affected connection and retries only the newest failed call
- decline logs once and suppresses repeat prompts until reset
- a later successful call on the same connection resets the episode
- failures on different connections can prompt independently

### `check_adapter_diagnostics.lua`

Headless cases should verify:

- Oracle baseline behavior still produces diagnostics and cursor jump
- postgres/mysql/sqlserver/oracle parser paths normalize into `vim.diagnostic` items, with SQLite explicitly proving fallback-only behavior
- other SQL adapters produce the `1:1` fallback diagnostic with adapter context
- non-SQL adapters remain notify-only
- diagnostics clear on rerun, success, note switch/remove, and explicit `clear_diagnostics`
- namespaces are keyed by connection ID rather than one global namespace

## Risks And Mitigations

| Risk | Why it matters | Mitigation |
|---|---|---|
| Prompt spam on flapping connections | Requirement explicitly calls this out | Per-connection episode table with pending + declined suppression |
| Retrying the wrong query | Multiple calls can fail during one outage | Always replace episode `latest_call_id` with the newest disconnected failed SQL call |
| Auto-retry reopening variable prompts | Annoying UX, breaks bind-heavy queries | Replay stored `resolved_query + exec_opts` rather than rerunning variable resolution |
| Diagnostics bleeding across connections | Single global namespace is too coarse | Use `dbee-<conn_id>` namespaces and store `conn_id` in note execution metadata |
| Over-refactoring Oracle explain flow | High churn for little value | Keep Oracle explain listener intact unless unification is truly mechanical |

## Research Conclusion

Phase 5 is ready for planning and execution with **two sequential plans**. The only non-Lua work justified by live code is the small `call_state_changed` event payload expansion needed to expose `conn_id` and `error_kind`. Everything else stays additive and Lua-owned, which matches the locked discuss-phase decisions and keeps the feature set within milestone scope.
