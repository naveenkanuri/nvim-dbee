# Phase 10: LSP Optimization - Research

**Researched:** 2026-04-29  
**Status:** Research complete - pre-lock  
**Scope:** `lua/dbee/lsp/*`, LSP-adjacent editor/API integration, headless LSP coverage, and current Neovim/ecosystem alignment.

## Summary Recommendation

Make v1.2 a focused LSP optimization milestone with three phases:

1. **Phase 10: LSP performance and lifecycle optimization** - fix the hot paths that can block typing or duplicate metadata work.
2. **Phase 11: LSP intelligence feature closure** - add the most useful LSP-native features after the cache/lifecycle substrate is stable.
3. **Phase 12: LSP real-harness and regression coverage** - promote LSP validation from alias-only hermetic checks into measurable startup/completion/diagnostic evidence on Neovim `0.12.x`.

The strongest first phase is performance/lifecycle, not feature expansion. The current implementation already has a real in-process LSP and a cache, but its expensive paths are still too broad: full-buffer diagnostics on `didChange`, completion-time scans over unsorted schema/table maps, synchronous `connection_get_columns()` probes during completion, and ad hoc disk-cache writes. `lua/dbee/lsp/server.lua:218-250`, `lua/dbee/lsp/server.lua:264-350`, `lua/dbee/lsp/server.lua:409-429`, `lua/dbee/lsp/schema_cache.lua:301-456`

## Current Architecture

### Module Map

| File | Role | Producers | Consumers |
| --- | --- | --- | --- |
| `lua/dbee/lsp/init.lua` | Public lifecycle/controller module. Tracks the active LSP client, current connection, attached/pending buffers, structure requests, metadata fallback calls, and connection-invalidation bootstrap state. | `state.handler()`, handler events, disk cache, metadata SQL fallback. | `lua/dbee/api/state.lua`, `lua/dbee/ui/editor/init.lua`, headless lifecycle tests. |
| `lua/dbee/lsp/server.lua` | In-process LSP transport implementation passed as `cmd = server.create(cache)` to `vim.lsp.start()`. Handles `initialize`, `shutdown`, `textDocument/completion`, `didChange`, and `didSave`. | `context.analyze()`, `SchemaCache` lookups. | Neovim LSP client, direct headless tests. |
| `lua/dbee/lsp/schema_cache.lua` | Per-connection flattened schema/table/column cache plus disk persistence under `stdpath("state")/dbee/lsp_cache`. | Handler structure payloads, metadata SQL rows, synchronous column RPCs, disk JSON. | `server.lua` completion/diagnostic logic, `bench.lua`. |
| `lua/dbee/lsp/context.lua` | Regex-based SQL cursor context and alias parser. Determines schema/table/column/keyword completion mode from the current buffer before cursor. | Buffer text via `vim.api.nvim_buf_get_lines()`. | `server.lua` completion dispatch. |
| `lua/dbee/lsp/bench.lua` | Manual, incremental benchmark helper for live dbee sessions. Measures handler availability, current connection, full structure RPC, columns RPC, empty-cache `vim.lsp.start()`, cache flattening, metadata query execution, JSON export/decode, and metadata cache build. | Live dbee handler and current connection. | Human-run `:lua require("dbee.lsp.bench").stepN()` sessions only. |

### Public API Surface

Only two production call sites consume the LSP module directly:

- `state.setup_ui()` loads `dbee.lsp` and calls `register_events()` once after UI components are created. `lua/dbee/api/state.lua:72-75`
- `EditorUI:open_note()` queues the note buffer through `lsp.queue_buffer(bufnr)` after buffer options/mappings are configured. `lua/dbee/ui/editor/init.lua:1275-1278`

The module also exposes `stop(conn_id, opts)`, `restart()`, `refresh()`, and `status()` for lifecycle/debug use, while tests reach internal helpers such as `_try_start()` and `_request_structure_refresh()` through hermetic harnesses. `lua/dbee/lsp/init.lua:512-566`, `lua/dbee/lsp/init.lua:622-635`

### Data Flow

1. Editor opens a note buffer and queues it for LSP attach. If the LSP is already running, the buffer attaches immediately; otherwise it goes into `_pending_bufs`. `lua/dbee/lsp/init.lua:150-167`
2. `_try_start()` requires core to be loaded, ensures the connection-invalidation consumer is bootstrapped, reads the current connection, then attempts disk cache first. `lua/dbee/lsp/init.lua:391-418`
3. If disk cache is missing, `_try_start()` requests handler-owned `connection_get_structure_singleflight()` with `consumer = "lsp"` and `caller_token = "lsp"`. `lua/dbee/lsp/init.lua:252-261`
4. When the structure payload returns, `_on_structure_loaded()` filters non-LSP payloads, stale epochs, non-current connections, errors, and missing structures, then builds/saves a `SchemaCache` and starts or refreshes the LSP. `lua/dbee/lsp/init.lua:211-246`
5. If structure loading does not produce a cache within 5 seconds, `_try_start()` executes an adapter-specific metadata SQL fallback and later exports the result to JSON, decodes it, builds a table/schema-only cache, and starts the LSP. `lua/dbee/lsp/init.lua:426-507`
6. `server.create(cache)` returns the in-process RPC object. Completion requests call `get_completions()`, which calls `context.analyze()` and then asks the cache for schema/table/column items. `lua/dbee/lsp/server.lua:357-401`, `lua/dbee/lsp/server.lua:218-250`
7. Full-sync `didChange` and `didSave` notifications schedule whole-buffer table-reference diagnostics and publish warnings through the LSP client. `lua/dbee/lsp/server.lua:374-377`, `lua/dbee/lsp/server.lua:409-429`

### Locked Prior Contracts To Preserve

The v1.2 LSP work must not reopen Phase 4-9 decisions:

- Phase 6 preserved the full-tree `connection_get_structure_async()` / `structure_loaded` payload and explicitly warned that LSP already consumes it. `.planning/phases/06-structure-laziness-notes-picker/06-CONTEXT.md:22`
- Phase 7 made `current_connection_changed` presentation-focused and assigned LSP retargeting to that event without treating it as passive cache invalidation. `.planning/phases/07-connection-only-drawer/07-CONTEXT.md:48`
- Phase 7 locked handler-owned drawer/LSP single-flight, with `(conn_id, authoritative_root_epoch)` as coalescing key and per-waiter callback fan-out. `.planning/phases/07-connection-only-drawer/07-CONTEXT.md:52`
- Phase 7 locked visibility-aware invalidation backpressure and "LSP rewarms only the current connection." `.planning/phases/07-connection-only-drawer/07-CONTEXT.md:53`
- Phase 9 locked Neovim `0.12.x` as the blocking perf lane for release evidence. `.planning/phases/09-real-nui-perf-harness/09-CONTEXT.md:41`

## Existing Performance Work

`bench.lua` is useful but incomplete. It measures the right broad categories:

- handler/core availability and current connection lookup. `lua/dbee/lsp/bench.lua:21-45`
- synchronous full structure fetch and second-call cached structure fetch. `lua/dbee/lsp/bench.lua:47-86`
- synchronous column fetch for one table. `lua/dbee/lsp/bench.lua:88-121`
- empty-cache `vim.lsp.start()` overhead. `lua/dbee/lsp/bench.lua:123-150`
- pure Lua `build_from_structure()` flattening. `lua/dbee/lsp/bench.lua:152-189`
- metadata query execution, JSON export, decode, and `build_from_metadata_rows()`. `lua/dbee/lsp/bench.lua:197-299`

Gaps:

- No completion latency measurement for table, schema, column, alias, and fallback contexts.
- No `didChange`/diagnostic latency measurement across realistic buffer sizes.
- No cold vs warm disk-cache read/write timing or cache file-count stress.
- No typed-throughput measurement that simulates a completion client issuing repeated requests while the user types.
- No Neovim version capture, machine/platform labels, median/p95, CI marker contract, or threshold policy.
- It uses `vim.loop.hrtime()`, while newer Neovim guidance prefers `vim.uv` for libuv access.

The first perf phase should preserve `bench.lua` as an interactive probe but add a headless, deterministic benchmark path with stable markers.

## Hot Paths And Latent Bugs

### P0/P1 Candidates

| Candidate | Evidence | Risk | Suggested direction |
| --- | --- | --- | --- |
| Whole-buffer diagnostics on every full-sync `didChange` | Server advertises full sync and recomputes diagnostics from every buffer line on `didChange` and `didSave`. `lua/dbee/lsp/server.lua:374-377`, `lua/dbee/lsp/server.lua:409-429` | Typing in large SQL buffers can schedule O(buffer) work per change. | Debounce diagnostics, move default diagnostics to save/idle, or implement incremental text tracking before publishing on change. |
| Synchronous column fetch during completion | `SchemaCache:get_columns()` calls `handler.connection_get_columns()` inside the completion request path on cache miss/probe. `lua/dbee/lsp/schema_cache.lua:348-456`; schema-qualified alias completion depends on this. `ci/headless/check_lsp_schema_alias_completion.lua:18-38` | Completion can block on RPC/DB metadata fetch. | Return cached results immediately and schedule async column warmup; mark completion `isIncomplete = true` only when truthful. |
| Repeated unsorted table/schema scans | `table_completions()`, `schema_completions()`, `find_table()`, and `find_table_in_schema()` scan maps/lists on each request. `lua/dbee/lsp/server.lua:26-98`, `lua/dbee/lsp/schema_cache.lua:465-483` | Large schemas multiply CPU and allocation per keystroke. | Precompute sorted completion item arrays and case-folded lookup indexes in `SchemaCache`, invalidated only on cache mutation. |
| Cache disk writes are non-atomic and silent | `save_to_disk()` and `_save_columns_to_disk()` write JSON directly and ignore encode/write/close failures. `lua/dbee/lsp/schema_cache.lua:170-193`, `lua/dbee/lsp/schema_cache.lua:237-250` | Corrupt cache can cause slow fallback loops; silent failures are hard to diagnose. | Use temp-file-plus-rename pattern from Phase 8 FileSource work, and log read/write failures as debug/warn. |
| Metadata fallback temp file cleanup can leak | `_process_metadata_result()` returns early after `io.open(tmp)` failure and removes only after successful open/read. `lua/dbee/lsp/init.lua:477-490` | Stale temp files on export/open errors. | Wrap temp-file lifecycle with a local cleanup helper. |
| Qualified diagnostics ignore schema | `compute_diagnostics()` validates `schema.table` by calling `cache:find_table(tbl)`, which can find the same table in any schema. `lua/dbee/lsp/server.lua:271-286`, `lua/dbee/lsp/server.lua:308-321` | False negatives for `wrong_schema.valid_table`. | Use schema-aware lookup for qualified references. |
| Completion diagnostics duplicate editor diagnostics conceptually | Phase 5 adapter diagnostics own execution errors; LSP diagnostics currently warn about unknown tables on buffer changes. `lua/dbee/doc.lua:210-213`, `lua/dbee/lsp/server.lua:264-350` | Two diagnostic sources can confuse users if severity/source semantics diverge. | Keep LSP diagnostics as static schema warnings, but gate them behind clear namespace/source and throttle. |

### Lower-Risk Cleanups

- `col_start` in the `FROM schema.table` branch is computed but unused. `lua/dbee/lsp/server.lua:277`
- `CompletionItemKind` uses `Class` for views and `Struct` for tables; Neovim supports richer kinds but this is cosmetic. `lua/dbee/lsp/server.lua:5-20`, `lua/dbee/lsp/server.lua:68-74`
- `get_text_before_cursor()` and `get_buffer_text_before_cursor()` use LSP `position.character` as a Lua string byte index. This is usually fine for ASCII SQL but can be wrong for non-ASCII text because LSP character offsets are negotiated encodings, not always byte offsets. `lua/dbee/lsp/context.lua:65-94`
- `parse_aliases()` scans from statement start to cursor for every alias completion. `lua/dbee/lsp/context.lua:96-171` This is acceptable for short statements, but a benchmark should define the upper bound before optimizing.

## Known Issues And TODOs

- I did not find `known-issues.md` in this repo (`find . -maxdepth 3 -iname '*known*issue*'` returned nothing).
- There are no `TODO`, `FIXME`, `HACK`, or `XXX` markers under `lua/dbee/lsp/` or the three `check_lsp*` files.
- Existing documented concern adjacent to LSP: adapter metadata calls can be uncancellable/unbounded in Go drivers, but the immediate LSP Lua path should first avoid issuing synchronous metadata work from completion. `.planning/codebase/CONCERNS.md:19-23`

## Test Coverage

### Direct LSP Tests

| Test | Coverage | Gaps |
| --- | --- | --- |
| `ci/headless/check_lsp_alias_completion.lua` | Alias dot-completion for pre-insert and post-insert trigger timing. `ci/headless/check_lsp_alias_completion.lua:1-11`, `ci/headless/check_lsp_alias_completion.lua:119-148` | No lifecycle, no real client attach, no perf timing. |
| `ci/headless/check_lsp_schema_alias_completion.lua` | Schema-qualified aliases and on-demand column probing for tables absent from the metadata cache. `ci/headless/check_lsp_schema_alias_completion.lua:1-9`, `ci/headless/check_lsp_schema_alias_completion.lua:106-156` | Enshrines synchronous probe behavior; needs a new expected contract if async warmup lands. |
| `ci/headless/check_lsp_alias_rebinding.lua` | Alias rebinding across statements and pre-insert trigger timing. `ci/headless/check_lsp_alias_rebinding.lua:1-9`, `ci/headless/check_lsp_alias_rebinding.lua:123-163` | No multi-line CTE/subquery coverage. |

These three tests are in the main Lua headless matrix. `.github/workflows/test.yml:63-65`

### Indirect LSP Coverage

`ci/headless/check_connection_coordination.lua` already covers drawer/LSP single-flight fan-out, LSP error preservation, LSP rebootstrap, retarget rewarm, reconnect migration, and metadata scheduling. `ci/headless/check_connection_coordination.lua:729-805`, `ci/headless/check_connection_coordination.lua:1075-1104`, `ci/headless/check_connection_coordination.lua:1721-1756`

Gaps for v1.2:

- No deterministic LSP performance harness.
- No disk-cache corruption/recovery tests.
- No unknown-table diagnostics tests.
- No current Neovim `0.12.x` lane for the ordinary Lua headless matrix; only the Phase 9 real-nui perf job uses `NVIM_PERF_VERSION=v0.12.2`. `.github/workflows/test.yml:16-18`, `.github/workflows/test.yml:84-97`, `.github/workflows/test.yml:125-141`
- No tests for completion item ordering stability.
- No tests for multi-buffer attachment lifecycle, buffer detach/delete cleanup, or stale `_attached_bufs` pruning.

## Neovim 0.12.x Alignment

Current code is close to compatible, but not aligned with the newest ecosystem shape.

Local observations:

- `README.md` still says `requires nvim>=0.10`, while Phase 9 perf already requires `v0.12.x` for `make perf`. `README.md:49`, `Makefile:17-27`
- The normal Lua headless CI lane installs `v0.11.6`; the perf lane installs `v0.12.2`. `.github/workflows/test.yml:84-97`, `.github/workflows/test.yml:125-141`
- LSP startup uses `vim.lsp.start({ name, cmd = server.create(cache), root_dir = vim.fn.getcwd() })`. `lua/dbee/lsp/init.lua:188-193`
- `bench.lua` uses `vim.loop.hrtime()` rather than `vim.uv.hrtime()`. `lua/dbee/lsp/bench.lua:9-12`
- No deprecated `nvim_buf_set_option`, `nvim_win_set_option`, `vim.lsp.get_active_clients`, or `vim.lsp.start_client` usage exists in `lua/dbee/lsp/`.

0.12-era research conclusions:

- Prefer retaining direct `vim.lsp.start()` for this in-process, per-current-connection server unless the milestone chooses a broader plugin-level `vim.lsp.config()` / `vim.lsp.enable()` registration strategy. `vim.lsp.config()` is more natural for project-root language servers; dbee's server is connection-scoped and cache-backed.
- `client.request_sync()` is not a better path for completions. The server side is already synchronous because it is in-process; the fix is to make completion handlers non-blocking with respect to database metadata, not to add sync client requests.
- Built-in LSP completion and newer client features make completion item correctness, `isIncomplete`, `triggerCharacters`, and capability shape more important on 0.12 than on older handwritten completion stacks.
- Semantic tokens, inlay hints, and code actions are plausible latent enhancements, but only after diagnostics/completion/cache behavior has a measured budget.
- The most actionable compatibility cleanup is `vim.loop` -> `vim.uv` in `bench.lua`, plus deciding whether v1.2 changes the ordinary headless matrix to run LSP tests on Neovim `0.12.x`.

## Ecosystem Comparison

### SQL Completion Plugins

- `vim-dadbod-completion` is the closest Neovim SQL-completion analogue. Its model is a completion source integrated into completion engines, not an embedded LSP. That suggests dbee should keep completion latency tightly bounded and return cache-backed results first.
- `cmp-dbee` already exists as an external nvim-dbee completion bridge. Since this repo now has a built-in LSP, v1.2 should decide whether the LSP is the primary supported path or whether external completion sources remain equally blessed.
- `sqls` and other SQL language servers treat schema metadata as language-server state. That maps well to dbee's `SchemaCache`, but dbee has a unique advantage: it already owns the active connection and structure cache through the handler.
- `lspsaga.nvim` is mostly LSP UI around hover, diagnostics, code actions, and navigation, not a SQL schema provider. It is useful as a feature-surface reference, not a cache architecture reference.
- `nvim-cmp` and `blink.cmp` both reinforce that completion providers should be cheap, cancellable, cache-friendly, and able to provide incomplete/updated results rather than blocking the editing loop.

### Schema Cache Patterns

- SchemaStore-style plugins separate a large static schema corpus from LSP config and expose deterministic filtered data to language servers. dbee's equivalent should be precomputed schema/table/column indexes inside `SchemaCache`, not repeated table walks in `server.lua`.
- Treesitter-style parser ecosystems use explicit install/update/cache boundaries. The analogous dbee boundary is "cache mutation rebuilds indexes; completion reads immutable arrays."
- The cache should distinguish transport freshness from UI/completion readiness. Phase 6/7 already made structure loading async and epoch-gated; LSP should keep that contract instead of inventing TTL polling.

### Context Propagation

dbee has a stronger context source than most plugins: the handler already owns current connection, source reload, database selection, reconnect rewrite, and authoritative root epoch. The LSP should continue to consume that context through:

- `current_connection_changed` for retarget/restart. `lua/dbee/lsp/init.lua:676-690`
- `database_selected` for same-connection cache invalidation/refresh. `lua/dbee/lsp/init.lua:692-700`
- `connection_invalidated` bootstrap and batched rewarm. `lua/dbee/lsp/init.lua:289-385`, `lua/dbee/lsp/init.lua:568-620`
- handler-owned single-flight for root payloads. `lua/dbee/lsp/init.lua:252-261`

Avoid passing current connection through completion params or buffer-local globals unless a future multi-connection-per-buffer feature explicitly requires it.

### Async And Streaming

Community pattern: do not block the UI path for cache misses. dbee currently violates that at column completion cache misses. `lua/dbee/lsp/schema_cache.lua:348-456`

Recommended pattern:

1. Completion reads only in-memory indexed cache and returns immediately.
2. Cache misses enqueue async warmups keyed by `(conn_id, schema, table, materialization, root_epoch)`.
3. Warmup completion updates the cache and optionally notifies clients through a light refresh/incomplete-completion path.
4. Reconnect/source/database invalidations cancel or ignore stale warmups by epoch, following Phase 6/7 stale-drop rules.

### Server Lifecycle And Cross-Buffer State

Current lifecycle is one LSP client per current connection, attached to all queued note buffers. This matches the "current logical connection" product model and Phase 7 lock. `lua/dbee/lsp/init.lua:49-75`, `lua/dbee/lsp/init.lua:150-180`

Potential improvements:

- Prune `_attached_bufs` when buffers are invalid or no longer SQL note buffers.
- Preserve pending buffers through retargets but avoid duplicate attach attempts.
- Record client/root/cache version in `status()` for debugging.
- Decide if v1.2 should support multiple simultaneous dbee LSP clients for buffers tied to different connections. This is useful but conflicts with the current "current connection" model and should be a later design fork unless user pain demands it.

## Latent Enhancements

| Enhancement | Value | Dependency |
| --- | --- | --- |
| Completion item `data` plus `completionItem/resolve` | Lazy details/docs without bloating every completion item. | Stable cache indexes. |
| Code actions for unknown table/schema diagnostics | Useful quick navigation to activate connection, refresh cache, or reload structure. | Throttled diagnostics and action command surface. |
| Inlay hints for active connection/schema | Helps users understand which connection backs completions. | Clear UX decision: avoid noisy hints in SQL buffers. |
| Semantic tokens for tables, columns, aliases, keywords | Visual SQL intelligence beyond completions. | Robust parsing or treesitter integration; regex may be too weak. |
| Workspace symbol / document symbol for schema objects | Fast object lookup through LSP UI. | Indexed schema/table cache. |
| Hover for table/column metadata | Show table type, schema, column type, maybe source connection. | Cached detail fields beyond current `{name,type}` columns. |
| `workspace/didChangeConfiguration` or custom command refresh | Let users refresh LSP cache from LSP-aware UI. | Public refresh command and notification contract. |

Do not start with semantic tokens. They require a better SQL parser or treesitter-backed analysis to avoid misleading highlights.

## Candidate Phase Breakdown

### Phase 10: LSP Performance And Lifecycle Optimization

Goal: Make built-in dbee LSP cheap during typing and stable across connection lifecycle events.

Candidate deliverables:

- Headless microbench harness for completion/diagnostics/cache operations with stable stdout markers.
- Precomputed cache indexes and completion item arrays.
- Debounced or save/idle-gated diagnostics.
- Async column warmup or at least a no-blocking-completion policy.
- Atomic disk-cache writes and better cache read/write diagnostics.
- Fix schema-qualified unknown-table diagnostics.
- `vim.loop` -> `vim.uv` in `bench.lua`.

### Phase 11: LSP Feature Gap Closure

Goal: Expose high-value LSP features that dbee can support truthfully from schema/cache state.

Candidate deliverables:

- Completion resolve/details.
- Hover for table/column metadata.
- Code actions for refresh/reload on stale or unknown schema diagnostics.
- Optional inlay hint for active connection/schema if UX is judged useful.
- Document/workspace symbol support for cached schema objects.

### Phase 12: LSP Test Harness And 0.12 CI Alignment

Goal: Turn LSP correctness/performance into release evidence, matching the Phase 9 precedent.

Candidate deliverables:

- Neovim `0.12.x` LSP headless lane or targeted LSP matrix.
- Real `vim.lsp.start()` attach tests, not only direct `server.create()` requests.
- Cache corruption/recovery tests.
- Diagnostics tests for qualified/unqualified table warnings.
- Completion latency budget tests with median/p95 markers.
- Retarget/multi-buffer lifecycle tests.

## Open Questions / Decision Forks

1. **Completion cache-miss policy:** Should `alias.table.` completion ever block to fetch columns, or must it return cached results immediately and warm asynchronously?
2. **Diagnostics policy:** Should unknown-table LSP diagnostics run on every change after debounce, save only, idle only, or behind an opt-in setting?
3. **Primary completion surface:** Is the built-in LSP now the canonical dbee completion path, or should external sources like `cmp-dbee` remain the recommended default?
4. **Neovim support floor:** Keep README's `nvim>=0.10` while only LSP/perf gates optimize for `0.12.x`, or raise the supported floor in v1.2?
5. **Feature priority:** After perf, should v1.2 prioritize hover/resolve/code actions or deeper parser-backed SQL intelligence?
6. **Connection model:** Stay with one active-connection LSP client, or plan a future multi-client model for buffers intentionally pinned to different connections?

## Sources Reviewed

### Local

- `lua/dbee/lsp/init.lua`
- `lua/dbee/lsp/server.lua`
- `lua/dbee/lsp/schema_cache.lua`
- `lua/dbee/lsp/context.lua`
- `lua/dbee/lsp/bench.lua`
- `lua/dbee/api/state.lua`
- `lua/dbee/ui/editor/init.lua`
- `lua/dbee/handler/init.lua`
- `ci/headless/check_lsp_alias_completion.lua`
- `ci/headless/check_lsp_schema_alias_completion.lua`
- `ci/headless/check_lsp_alias_rebinding.lua`
- `ci/headless/check_connection_coordination.lua`
- `.github/workflows/test.yml`
- `.planning/phases/04-*` through `.planning/phases/09-*` contexts/research

### External Primary Sources

- Neovim release/docs: `https://github.com/neovim/neovim/releases/tag/v0.12.2`, `https://neovim.io/doc/user/lsp.html`, `https://neovim.io/doc/user/news-0.12.html`, `https://neovim.io/doc/user/deprecated.html`
- SQL/LSP completion: `https://github.com/kristijanhusak/vim-dadbod-completion`, `https://github.com/MattiasMTS/cmp-dbee`, `https://github.com/sqls-server/sqls`, `https://github.com/hrsh7th/nvim-cmp`, `https://github.com/Saghen/blink.cmp`, `https://github.com/neovim/nvim-lspconfig`, `https://github.com/nvimdev/lspsaga.nvim`
- Cache/context/UI-adjacent patterns: `https://github.com/b0o/SchemaStore.nvim`, `https://github.com/nvim-treesitter/nvim-treesitter`, `https://github.com/nvim-telescope/telescope.nvim`, `https://github.com/stevearc/oil.nvim`, `https://github.com/nvim-neo-tree/neo-tree.nvim`

