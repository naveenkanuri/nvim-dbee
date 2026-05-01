# LSP Completion Refresh Plan

Status: implementation plan for the LSP completion freshness candidate. No commits during execution.

## Goal

When dbee LSP returns `{ items = {}, isIncomplete = true }` for a cold column completion miss and the async column fetch later succeeds, the active dbee client receives a refresh notification that can re-request completion without requiring the user to backspace and retype `.`.

## Invariants

- Preserve Phase 11 D-156: cold miss returns `isIncomplete=true` only when async work actually started, joined, or queued.
- Preserve Phase 7 reconnect behavior: notification handlers no-op when `conn_id` is no longer the active dbee LSP connection.
- Preserve Phase 14 scope: no notification for filtered-out schemas; notification keys include root epoch and schema filter signature.
- No Go endpoint changes.
- No synchronous column fetch from completion.
- Working tree only; no commit.

## Tasks

### LCR-01: Cache-owned refresh notification hook

Files:

- `lua/dbee/lsp/schema_cache.lua`

Actions:

- Add `completion_refresh_notifier` and `completion_refresh_pending` fields.
- Add `SchemaCache:set_completion_refresh_notifier(fn)`.
- Add cache-side notification eligibility tracking. Mark a column async chain eligible only after `get_columns_async()` returns `is_incomplete=true` to the completion caller.
- After successful `on_columns_loaded()` store/save, call a private debounced notifier with:
  - `conn_id`
  - `schema`
  - `table`
  - `materialization`
  - `root_epoch`
  - `schema_filter_signature`
  - `request_id`
- Gate notification with `schema_filter.matches(schema, self.schema_scope)`.
- Re-check `handler:get_authoritative_root_epoch(self.conn_id)` inside `on_columns_loaded()` or the private notifier; suppress notification when payload epoch is older than the authoritative epoch.
- Do not notify on stale epoch, payload error, empty payload fallback, or failed/advanced probe.
- Do not notify when the async transport synchronously delivered columns and the completion request returned warm items with `isIncomplete=false`.

Acceptance:

- Existing `on_columns_loaded()` callers still receive boolean first return.
- Multiple waiters on the same fetch produce one scheduled notification.
- Sync-delivery warm responses produce no notification.
- Direct stale epoch cache delivery produces no notification.

### LCR-02: In-process LSP transport emits hybrid refresh

Files:

- `lua/dbee/lsp/server.lua`

Actions:

- In `M.create(cache)`, register the cache notifier once dispatchers are available.
- Send custom notification:
  - method `dbee/columnsLoaded`
  - params from LCR-01
- Best-effort call `dispatchers.server_request("workspace/diagnostic/refresh", vim.empty_dict())`.
- Coalesce diagnostic refresh to one scheduled server request per tick even if many column payloads land.
- Clear notifier on `exit` and `terminate`.

Acceptance:

- Notification is sent only after the cache stores columns.
- Missing `server_request` or unsupported diagnostic refresh does not fail completion.
- A burst of accepted column payloads produces one diagnostic refresh request per tick, not one per table.

### LCR-03: dbee client-side completion refresh handler

Files:

- `lua/dbee/lsp/init.lua`

Actions:

- Install `vim.lsp.handlers["dbee/columnsLoaded"]` idempotently from `register_events()`.
- Handler no-ops unless:
  - active dbee LSP client matches `ctx.client_id`;
  - active dbee LSP connection matches `params.conn_id`;
  - current mode is insert/select insert;
  - current buffer is attached to active dbee LSP;
  - `dbee.lsp.context.analyze` at current cursor resolves to `params.schema` + `params.table`.
- Handler canonicalizes through the active cache before comparing:
  - schema-qualified aliases use `M._cache:find_table_in_schema(alias_info.schema, alias_info.table)`;
  - unqualified aliases/direct table refs use `M._cache:find_table(alias_info.table or extra)`;
  - comparisons use canonical resolved schema/table, not raw lowercase SQL text.
- Refresh frontend in order:
  - blink.cmp context-matched refresh -> `blink.show({ providers = { "lsp" } })`, even if blink hid the prior empty incomplete popup;
  - nvim-cmp visible -> `cmp.complete()`;
  - built-in popup visible -> `vim.lsp.buf.completion()`.

Acceptance:

- Handler does not trigger when user moved away from `j.`.
- Handler does not trigger after reconnect to a different conn_id.
- Handler does not require blink.cmp to be installed.
- Handler triggers for `select * from app.sas_jobs j where j.` when notification params are canonical `APP.SAS_JOBS`.
- Handler triggers blink when the prior popup was hidden by an empty incomplete result but the cursor still matches.

### LCR-04: Headless notification test and rollup wiring

Files:

- `ci/headless/check_lsp_completion_refresh.lua`
- `Makefile`
- `.github/workflows/test.yml`
- `ci/headless/check_ux13_rollup.lua`

Actions:

- Add headless test:
  - create cache with table `APP.SAS_JOBS`;
  - create server with custom `dispatchers.notification`;
  - request completion for `select * from app.sas_jobs j where j.`;
  - assert `items=[]` and `isIncomplete=true`;
  - deliver async columns through `cache:on_columns_loaded`;
  - wait for scheduled notifier;
  - assert one `dbee/columnsLoaded` notification with `conn_id`, `schema`, `table`;
  - assert duplicate waiter/coalesced fetch does not double notify before delivery.
  - assert sync-delivered columns that make the first completion warm emit zero refresh notifications/server requests.
  - assert stale cache delivery after authoritative epoch advances emits zero refresh notifications.
  - assert many accepted column payloads emit at most one `workspace/diagnostic/refresh` request in one scheduler tick.
  - assert filtered-out schema alias completion starts no async work, emits no notification, and does not warm cache.
  - assert scope changed before async delivery prevents stale column payload caching.
- Add handler-level test in the same script:
  - install the dbee handler;
  - stub active `M._client_id`, `M._conn_id`, `M._cache`, and attached buffer state;
  - stub blink.cmp and nvim-cmp modules with visibility and refresh counters;
  - invoke `vim.lsp.handlers["dbee/columnsLoaded"]`;
  - assert exactly one blink refresh for lowercase `app.sas_jobs j` with canonical `APP.SAS_JOBS`;
  - assert blink also refreshes when the popup is hidden after the prior empty incomplete miss;
  - assert no refresh for moved cursor, detached buffer, and reconnect `conn_id` mismatch.
- Emit `LSP_COMPLETION_REFRESH_NOTIFY_OK=true`.
- Add script to `perf-lsp` headless loop and CI LSP headless scripts.
- Add sentinel to UX13 rollup required markers.

Acceptance:

- `nvim --headless -l ci/headless/check_lsp_completion_refresh.lua` emits the sentinel.
- `nvim --headless -l ci/headless/check_ux13_rollup.lua` still passes when fed a complete rollup log.

### LCR-05: Focused validation

Commands:

- `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_lsp_completion_refresh.lua"`
- `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_lsp_async_completion.lua"`
- `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_lsp_schema_filter_lazy.lua"`
- If time allows: `make perf-lsp PERF_PLATFORM=macos`

Acceptance:

- `LSP_COMPLETION_REFRESH_NOTIFY_OK=true`
- Existing LSP11 async and ARCH14 lazy sentinels still pass.
- `UX13_ALL_PASS=true` and `ARCH14_ALL_PASS=true` remain passable through the existing rollup flow.
