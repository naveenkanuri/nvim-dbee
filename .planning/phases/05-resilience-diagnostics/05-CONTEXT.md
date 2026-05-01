# Phase 5: Resilience & Diagnostics - Context

**Gathered:** 2026-04-23
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 5 adds two resilience-facing behaviors to the existing brownfield execution flow:

1. `CONN-01` auto-reconnect prompting when a SQL call fails because the adapter/runtime classified it as `disconnected`
2. `ADPT-02` generic inline diagnostics for SQL adapter errors, extending the current Oracle-only behavior into a reusable framework

This phase is about recovery and error surfacing, not connection pooling, keep-alive, query caching, new adapter support, or non-SQL editor UX redesign.

</domain>

<decisions>
## Implementation Decisions

### CONN-01: Disconnect Recovery Prompt
- **D-01:** Trigger the reconnect UX from `call_state_changed` terminal failures whose `call.error_kind == "disconnected"`. This applies to user-initiated SQL execution paths that already surface through call history/result state, not to unrelated background noise.
- **D-02:** Present the recovery UX with `vim.ui.select` using a simple Yes/No prompt that names the affected connection, matching the existing cancel-confirm interaction style rather than introducing a custom floating UI.
- **D-03:** Prompt ownership is per connection, not global. At most one reconnect prompt may be active for a given connection at a time.
- **D-04:** Debounce/cooldown is connection-episode based. While a reconnect prompt is open, and after the user declines it, later disconnected failures on that same connection are coalesced instead of reopening the prompt repeatedly. The episode resets only after an explicit reconnect attempt or a later successful SQL execution on that connection.
- **D-05:** Confirming the prompt reconnects the affected connection and retries only the newest disconnected failed SQL call for that connection. There is no batch replay of older failed calls.
- **D-06:** Declining the prompt leaves failed calls intact in call history/result status, emits a single WARN-level message, and performs no automatic retry.
- **D-07:** The prompt contract is connection-specific, not current-pane-specific. Planning must preserve the user's current context if implementation needs a connection-specific reconnect helper or a temporary current-connection swap under the hood.

### ADPT-02: Generic SQL Error Diagnostics
- **D-08:** Phase 5 introduces a generic SQL diagnostic framework that spans the Go/Lua seam: Go remains the source of call failure state and error kind, while Lua owns adapter parser registration, fallback placement, namespace management, and `vim.diagnostic` rendering.
- **D-09:** Ship precise location parsers for `postgres`, `mysql`, `sqlite`, and `sqlserver` in Phase 5.
- **D-10:** Keep the existing Oracle diagnostic behavior from Phase 3 as the correctness baseline. Migrate Oracle into the shared framework only if that is trivially compatible; otherwise keep the current Oracle path and record framework unification as deferred cleanup.
- **D-11:** Other SQL adapters (`duck`, `bigquery`, `clickhouse`, `databricks`, `redshift`, and similar SQL-family adapters already supported by nvim-dbee) use the framework's generic fallback: place a diagnostic at line 1, column 1 with the full error message and adapter name.
- **D-12:** Non-SQL adapters (`mongo`, `redis`) remain notify-only in Phase 5. Inline line/column diagnostics are explicitly out of scope for those adapters because their error shapes do not map cleanly onto SQL buffer coordinates.
- **D-13:** For SQL adapters, parseable location-bearing errors get precise diagnostics. Unparseable SQL errors still surface as diagnostics through the fallback path rather than silently disappearing into notifications.
- **D-14:** All shipped Phase 5 diagnostics use severity `ERROR`. The parser interface may expose severity for future use, but Phase 5 does not introduce warning/info diagnostics.

### Diagnostic UX and Lifecycle
- **D-15:** Use `vim.diagnostic.set` in a namespace keyed by connection ID (for example `dbee-<conn_id>`). Do not introduce a plugin-specific sign-column or virtual-text renderer; respect the user's existing Neovim diagnostic presentation.
- **D-16:** Preserve the current Oracle precedent of moving the cursor to the first diagnostic location when the relevant editor buffer is visible.
- **D-17:** Clear stale diagnostics before each execution attempt, on successful rerun/archive of the same query buffer, when switching away from the affected note/buffer, and via an explicit editor-local `clear_diagnostics` action.
- **D-18:** Phase 5 does not require a new default keybinding for `clear_diagnostics`. Exposing the action in the editor action surface is sufficient unless planning finds a compelling existing-pattern slot.
- **D-19:** General diagnostic namespace/parser guidance applies only where execution already participates in the shared note-owned SQL path. For Phase 5 execution scope, D-25 is the controlling lock: Explain Plan does not gain new note ownership or line/column remapping, non-Oracle Explain remains result/notify-only, and Oracle Explain keeps its existing special-case behavior unless reuse is nearly free.

### Framework Shape and Extension Point
- **D-20:** Adding support for a new SQL adapter parser after Phase 5 should require registering one adapter-specific parser function, not editing execution flow, reconnect logic, or diagnostic rendering code in multiple places.
- **D-21:** Prefer additive metadata and bookkeeping over architecture churn. If the framework needs extra execution metadata (for example call-to-connection or call-to-buffer ownership), extend the current metadata tracking rather than rewriting the execution pipeline.
- **D-22:** Prefer minimal Go changes consistent with the existing roadmap constraint. Go-side changes are allowed only where they materially simplify or stabilize diagnostic/reconnect metadata; Lua remains the primary owner of Phase 5 UI behavior.

### Supplemental Locks
- **D-23:** `CONN-01` replay scope is full coverage for the six user-facing SQL execution sites Naveen cares about: `editor` `execute_note`, `editor` `execute_script`, `dbee.execute`, `dbee.execute_script`, `dbee.compile_object`, and `dbee.explain_plan`. Each must register retry metadata via `reconnect.register_call()`. `retry_last_disconnected()` must be refactored to consume the stored `resolved_query + exec_opts` payload instead of re-resolving variables or reconstructing execution state.
- **D-24:** `CONN-01` must support an optional opaque retry callback for execution flows that are not truthfully replayable as raw `resolved_query + exec_opts`. Generic SQL calls may use the default replay payload, but Oracle Explain must register `retry_fn(reconnected_conn_id, meta)` that re-creates its own two-step choreography (`ensure_oracle_explain_listener` + fresh pending-map entry) after reconnect. This callback may capture immutable replay inputs, but it must not depend on stale live state such as prior call IDs, timers, or existing pending-map entries.
- **D-25:** `ADPT-02` Phase 5 diagnostic coverage stops at normal editor-owned query execution. Oracle keeps the existing pre-Phase-5 inline diagnostic baseline for standard execution, but Phase 5 does not add new note-ownership plumbing or line/column remapping for Explain Plan. Non-Oracle Explain failures remain result/notify-only in Phase 5, and Oracle Explain keeps its current special-case behavior unless framework reuse becomes nearly free during execution.
- **D-26:** D-09 clarification: SQLite remains in the Phase 5 SQL diagnostic registry, but the current driver error surface does not provide reliable line/column metadata. Phase 5 therefore treats SQLite as a fallback-only SQL adapter that renders a truthful `1:1` diagnostic with adapter context instead of claiming precise location parsing.
- **D-27:** Legacy `retry_last_disconnected()` fallback is restricted to recognizable flat SQL calls. If reconnect metadata is missing for an opaque or synthetic flow (for example Oracle Explain step-2 `DBMS_XPLAN.DISPLAY`), Phase 5 must WARN and abort rather than replaying raw `call.query` out of context.
- **D-28:** Reconnect-to-editor note reassignment crosses the module boundary only through an additive `api.ui.rebind_note_connection(note_id, new_conn_id, new_conn_name, new_conn_type)` bridge that first checks `ui.is_loaded()` and no-ops when the editor UI is not loaded. Legacy synthetic-call detection is locked to the exact Lua pattern `^%s*SELECT%s+%*%s+FROM%s+TABLE%s*%(%s*DBMS_XPLAN`; matches WARN and abort rather than replaying `call.query` out of context.
- **D-29:** After any connection-identity rewrite, `CONN-01` routes reconnect episode state by `effective_conn_id = retry_meta.conn_id or wire conn_id`, so late call-state events that still arrive with the old wire `conn_id` land on the live rewritten episode instead of recreating dead-ID state. If reconnect resolves to the same `conn_id`, Phase 5 skips `rewrite_connection_identity()` entirely and emits no rewrite signal.

### the agent's Discretion
- Exact prompt copy, as long as it explicitly names the connection and makes reconnect + retry behavior clear
- Exact parser regex/normalization details for Postgres/MySQL/SQLite/SQL Server
- Whether connection-specific reconnect/retry is implemented through a new additive helper API or a tightly-scoped temporary current-connection swap with full restore
- Whether `clear_diagnostics` also appears in `dbee.actions()` in addition to the editor-local action surface

</decisions>

<specifics>
## Specific Ideas

- The reconnect prompt should feel like the existing cancel-confirm flow: a small Yes/No decision, not a new UI subsystem.
- The generic fallback diagnostic must be honest. If the adapter cannot provide a real location, show the error at `1:1` with adapter context rather than fabricating precision.
- Diagnostics should remain additive to Neovim's own `vim.diagnostic` ecosystem; Phase 5 should not impose a plugin-owned visual style on users who already configure diagnostics globally.
- Auto-reconnect is user-confirmed recovery, not silent keep-alive or automatic background reconnection.

</specifics>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase scope and milestone constraints
- `.planning/PROJECT.md` — global QoL milestone constraints, backward-compatibility rule, 2-pane baseline, and minimize-RPC principle
- `.planning/ROADMAP.md` — Phase 5 goal and success criteria, including reconnect debounce/cooldown and generic diagnostics expectations
- `.planning/REQUIREMENTS.md` — `CONN-01` and `ADPT-02` requirement statements plus out-of-scope guardrails
- `.planning/STATE.md` — current project state and known blocker note around reconnect prompt spam

### Prior phase precedents
- `.planning/phases/01-notifications-feedback/01-CONTEXT.md` — `utils.log` level policy and notify wording conventions for WARN/ERROR paths
- `.planning/phases/03-editor-result-actions/03-CONTEXT.md` — cancel-confirm prompt precedent, Explain Plan scope, and Oracle diagnostics precedent
- `.planning/phases/04-drawer-navigation/04-CONTEXT.md` — additive layout/API contract and prior zero-RPC hot-path discipline

### Architecture and integration references
- `.planning/codebase/ARCHITECTURE.md` — event-driven Go↔Lua architecture, `call_state_changed` flow, and ownership boundaries
- `.planning/codebase/INTEGRATIONS.md` — supported adapter inventory and external integration constraints
- `.planning/codebase/CONVENTIONS.md` — Lua/Go extension conventions and additive API expectations

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `dbee/core/call_error_kind.go` — existing `disconnected` / `timeout` / `canceled` classification used by call failures
- `lua/dbee.lua` — existing `reconnect_current_connection()` and `retry_last_disconnected()` helpers, plus actions-picker exposure for manual recovery
- `lua/dbee/ui/editor/init.lua` — existing cancel-confirm `vim.ui.select` pattern and Oracle diagnostic parse/set/reset/cursor-jump flow
- `lua/dbee/ui/result/init.lua` — existing disconnected failure status copy and reconnect hint in the result pane
- `lua/dbee/api/core.lua` + `lua/dbee/handler/__events.lua` — core event listener registration and scheduled event delivery

### Established Patterns
- Query/result UI updates are event-driven from `call_state_changed`; the plugin already avoids polling loops for normal execution feedback
- Execution metadata already lives in Lua (`note_calls`, `note_exec_meta`, `call_note_ids`) and can be extended for reconnect/diagnostic ownership instead of replaced
- `vim.ui.select` is already used for important confirm flows and benefits from user-installed UI providers such as dressing/snacks overrides
- Existing reconnect helpers are current-connection-scoped, not arbitrary-connection-scoped

### Integration Points
- `lua/dbee/ui/editor/init.lua` — reconnect prompt debounce state, execution metadata tracking, diagnostic lifecycle, and `clear_diagnostics`
- `lua/dbee.lua` — additive reconnect/retry helper surface and action-picker alignment
- `lua/dbee/ui/result/init.lua` — status messaging that should stay consistent with reconnect prompt outcomes
- `lua/dbee/doc.lua` and event payload handling — optional expansion point if planners decide structured diagnostic metadata or connection ownership belongs in the event payload
- `dbee/core/call_error_kind.go` — classifier extension point if Phase 5 uncovers missing disconnect patterns during parser/reconnect work

</code_context>

<deferred>
## Deferred Ideas

- Non-SQL inline diagnostics for `mongo` and `redis` — keep notify-based behavior for now
- Rich per-adapter location parsers for lower-traffic SQL adapters (`duck`, `bigquery`, `clickhouse`, `databricks`, `redshift`) — framework fallback covers them in Phase 5
- Full Oracle migration into the shared diagnostic framework if the existing Phase 3 special-case path is not trivially compatible
- Automatic background reconnection / keep-alive / pooling changes — explicitly out of scope for this QoL phase

</deferred>

---

*Phase: 05-resilience-diagnostics*
*Context gathered: 2026-04-23*
