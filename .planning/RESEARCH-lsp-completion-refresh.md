# LSP Completion Refresh Research

Status: research and implementation input for a v1.3 LSP polish candidate. This is not a locked decision record.

Problem: on a cold `alias.` column completion miss, dbee correctly returns `{ items = {}, isIncomplete = true }` and queues `connection_get_columns_async`, but completion clients such as blink.cmp do not automatically re-request completion when the async cache warms. The user has to backspace and type `.` again.

## Current Code Path

- `lua/dbee/lsp/server.lua` handles `textDocument/completion`.
- `column_completions()` calls `SchemaCache:get_columns_async(schema, table)`.
- On a cold miss, `SchemaCache:_queue_async_probe()` calls `handler.connection_get_columns_async(...)` and returns `is_incomplete = true`.
- `lua/dbee/lsp/init.lua` listens for `structure_children_loaded` with `kind = "columns"` and calls `M._cache:on_columns_loaded(data)`.
- `SchemaCache:on_columns_loaded()` stores columns and rebuilds the per-table column completion index, but it does not notify the active LSP client.

Invariant to preserve: Phase 11 D-156 remains true. Cold misses return `isIncomplete=true` only when async work actually started, joined, or queued. Warm cache hits return `isIncomplete=false`.

## Options

### Option A: Custom `dbee/columnsLoaded`

Wire flow:

1. Server returns the cold completion response:
   ```lua
   { items = {}, isIncomplete = true }
   ```
2. Async column payload lands through `structure_children_loaded`.
3. `SchemaCache:on_columns_loaded()` stores columns.
4. Server sends:
   ```lua
   dispatchers.notification("dbee/columnsLoaded", {
     conn_id = "conn",
     schema = "APP",
     table = "SAS_JOBS",
     materialization = "table",
     root_epoch = 7,
     schema_filter_signature = "..."
   })
   ```
5. dbee's plugin-side Lua handler checks whether the current insert cursor is still in a matching `alias.` / `table.` context. If yes, it asks the completion frontend to refresh.

Pros:

- Precise and schema/table-aware.
- Can avoid refreshing when the user moved away from the original context.
- Easy to test headlessly through the in-process `dispatchers.notification`.

Cons:

- Custom protocol. Generic LSP clients ignore it.
- Requires dbee to install a Neovim-side handler.

### Option B: Standard `workspace/diagnostic/refresh`

Wire flow:

1. Columns load.
2. Server sends a standard server-to-client request:
   ```lua
   dispatchers.server_request("workspace/diagnostic/refresh", vim.empty_dict())
   ```
3. Neovim refreshes pull diagnostics. Some completion frameworks may also refresh their state as a side effect, but this is not guaranteed.

Pros:

- Standard LSP method with a built-in Neovim handler.
- Useful fallback for stale diagnostics after schema cache changes.

Cons:

- The intent is diagnostics, not completion.
- Does not carry schema/table identity.
- Does not guarantee blink.cmp or nvim-cmp will re-request completion.
- If used alone, it leaves the original UX bug unfixed for clients that do not couple diagnostics and completion refresh.

### Option C: Hybrid

Wire flow:

1. Columns load and are stored in cache.
2. Server sends custom `dbee/columnsLoaded` for precise completion refresh.
3. Server also sends `workspace/diagnostic/refresh` as best-effort standard cache invalidation.
4. dbee's plugin handler uses the custom notification to refresh blink.cmp, nvim-cmp, or built-in completion only when the current cursor context still matches the loaded table.

Pros:

- Precise primary path fixes the real blink.cmp UX.
- Standard fallback keeps diagnostics fresh for clients that understand pull diagnostic refresh.
- Custom notification is testable without assuming completion frontend internals.

Cons:

- Two server-to-client paths.
- Requires careful no-op behavior when the cursor context or connection changed.

Recommendation: Option C.

Rationale: Option B alone is not a completion freshness contract. The feature needs a precise schema/table event so dbee can decide whether the current popup should refresh. The standard diagnostic refresh is still useful as a harmless best-effort fallback, but the custom notification is the primary contract.

## Chosen Wire Shape

Method:

```text
dbee/columnsLoaded
```

Params:

```lua
{
  conn_id = string,
  schema = string,
  table = string,
  materialization = "table" | "view" | string,
  root_epoch = integer,
  schema_filter_signature = string?,
  request_id = integer?,
}
```

Emission rules:

- Emit only after `SchemaCache:on_columns_loaded()` accepts the payload and stores columns.
- Do not emit on stale epoch, payload error, empty probe fallback, transport failure, or previous-failure paths.
- Emit only for async misses that previously produced an incomplete completion response. If `connection_get_columns_async` synchronously populates the cache before the first completion response returns warm items, do not emit a refresh.
- Debounce by `(conn_id, schema, table, root_epoch, schema_filter_signature)` so multiple waiters on the same fetch produce one notification.
- Do not emit if `schema_filter.matches(schema, schema_scope)` is false.
- Do not emit if the payload conn_id no longer matches the active cache conn_id.
- Re-check `handler:get_authoritative_root_epoch(conn_id)` inside the cache/notifier path. Caller-side stale checks remain defense in depth, not the only fence.

`workspace/diagnostic/refresh`:

- Send after the custom notification.
- Use `dispatchers.server_request` and ignore errors because clients may not support pull diagnostics.
- Coalesce diagnostic refresh separately: at most one diagnostic refresh server request per scheduler tick, regardless of how many `dbee/columnsLoaded` notifications are emitted in that tick.

## Plugin-Side Handler Contract

dbee installs a default Neovim handler:

```lua
vim.lsp.handlers["dbee/columnsLoaded"] = function(err, params, ctx) ... end
```

Handler rules:

- No-op on `err`.
- No-op if `ctx.client_id` is not the active dbee LSP client.
- No-op if `params.conn_id` does not equal the active dbee LSP connection. This preserves reconnect identity rewrites from Phase 7 D-77.
- No-op if current mode is not insert/select insert.
- No-op if the current buffer is not attached to the active dbee LSP client.
- Analyze the current cursor with `dbee.lsp.context.analyze`.
- Refresh only when the context is `column_of_table` and resolves to `params.schema` + `params.table`.
- Resolution must use the active `SchemaCache`, not raw text comparison:
  - If `alias_info.schema` exists, call `M._cache:find_table_in_schema(alias_info.schema, alias_info.table)`.
  - If no alias schema exists, call `M._cache:find_table(alias_info.table or extra)`.
  - Compare canonical resolved schema/table with notification params after cache fold/canonicalization. This covers lowercase SQL such as `app.sas_jobs j` and Oracle uppercase payloads such as `APP.SAS_JOBS`.
- For filtered-out schemas, there should be no notification; if one appears, the handler no-ops because the table will not resolve in cache.

Completion frontend behavior:

- blink.cmp: call `blink.show({ providers = { "lsp" } })` after the dbee context guard passes. blink may close an empty popup after `{ items = {}, isIncomplete = true }`; the `dbee/columnsLoaded` notification is the proof that a prior dbee incomplete miss is now warm.
- nvim-cmp: if installed and `cmp.visible()` is true, call `cmp.complete()`.
- Built-in Neovim popup fallback: if `vim.fn.pumvisible() == 1`, call `vim.lsp.buf.completion()` when available.
- If no completion frontend is active or available, do nothing. The next user-triggered completion hits the warm cache.

## Contract Updates

Phase 11 D-156:

- Keep existing cold miss response unchanged.
- Add freshness clause: when the async column miss later populates cache, dbee emits `dbee/columnsLoaded` for the accepted table payload so active clients can re-request completion.
- `isIncomplete=false` remains tied to a warm cache response, not to notification delivery.

Phase 14:

- Notification payloads are scoped by current `conn_id`, `root_epoch`, and `schema_filter_signature`.
- Lazy per-schema mode works because table columns still load through the existing per-table async column path after a schema branch/table is known.
- Filtered-out schemas never produce refresh notifications.

Sentinel additions:

- `LSP_COMPLETION_REFRESH_NOTIFY_OK=true`
- Add the sentinel to the UX13 rollup because the rollup already gates LSP11 semantic checks and does not require changing frozen LSP01 scenario counts.

## Implementation Plan

1. Add a notifier hook to `SchemaCache`.
   - New `set_completion_refresh_notifier(fn)` API.
   - `on_columns_loaded()` calls it once after `_store_columns()` and disk save succeed.
   - Debounce same schema/table/root/filter notification in the cache.
   - Track notification eligibility only when a completion call returned `is_incomplete=true` for that async chain.
   - Suppress stale payloads by comparing payload root epoch with the handler's current authoritative root epoch.

2. Emit server notifications from `server.create(cache)`.
   - Register the cache notifier when the in-process LSP transport starts.
   - Send `dbee/columnsLoaded`.
   - Best-effort send `workspace/diagnostic/refresh`.
   - Coalesce diagnostic refresh to one scheduled server request per tick.
   - Clear notifier on `exit` and `terminate`.

3. Add dbee plugin handler in `lua/dbee/lsp/init.lua`.
   - Install idempotently from `register_events()`.
   - Match active client/connection/buffer/cursor context before refreshing.
   - Support blink.cmp, nvim-cmp, and built-in completion fallback.

4. Add headless test `ci/headless/check_lsp_completion_refresh.lua`.
   - Stub `connection_get_columns_async`.
   - Request completion at `j.` with cold cache.
   - Assert empty + `isIncomplete=true`.
   - Deliver `structure_children_loaded` columns payload through cache.
   - Assert `dbee/columnsLoaded` notification payload has `conn_id`, `schema`, `table`.
   - Assert one notification for duplicate waiter/coalesced fetch.
   - Assert sync-delivered columns that make the first completion warm do not emit a refresh notification.
   - Invoke `vim.lsp.handlers["dbee/columnsLoaded"]` with fake active client/conn/buffer state and fake blink/cmp modules.
   - Assert handler refreshes for lowercase `app.sas_jobs j` when the notification is canonical `APP.SAS_JOBS`.
   - Assert handler refreshes blink even when blink hid the empty popup after the prior incomplete miss.
   - Assert handler no-ops for cursor moved, detached buffer, and reconnect `conn_id` mismatch.
   - Assert filtered-out schema aliases do not start async work, emit notifications, or warm the column cache.
   - Assert many accepted column payloads emit at most one `workspace/diagnostic/refresh` request in a scheduler tick.
   - Emit `LSP_COMPLETION_REFRESH_NOTIFY_OK=true`.

5. Wire validation.
   - Add script to `Makefile perf-lsp` headless loop.
   - Add script to CI LSP headless matrix/list.
   - Add sentinel to `ci/headless/check_ux13_rollup.lua`.
   - Keep ARCH14 rollup unchanged except it continues consuming `UX13_ALL_PASS=true`.

## Effort And Envelope

Effort: 0.5 to 1.5 engineering days.

v1.3 fit: small enough for the LSP polish bucket if kept to notification, handler, and headless sentinel. Do not expand into completion-source-specific cache invalidation APIs beyond the minimal blink/cmp/built-in trigger calls.

Non-goals:

- No Go endpoint changes.
- No change to `connection_get_columns_async`.
- No synchronous fetch on completion request.
- No completion refresh if the popup is closed or the cursor context changed.
