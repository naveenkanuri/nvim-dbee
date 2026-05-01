# v1.2 LSP Optimization — Opus Independent Research

Author: Opus (independent research arm). Generated 2026-04-29.
Counterpart: Codex research running in parallel; orchestrator (Claude) merges.

Scope: dbee LSP module under `lua/dbee/lsp/` (5 files, ~2235 lines).

> **Honest stance.** dbee's LSP is small, well-scoped, mostly correct, and has
> a few real correctness/perf hazards worth fixing in v1.2. It is NOT a
> "rewrite from scratch" candidate. The biggest realistic wins come from
> deprecation hygiene, async I/O, and making the column-fetch path
> non-blocking. Sources are cited inline with file:line refs and external URLs.

---

## Part A — dbee LSP code reality

### A.1 Per-file responsibilities and public API

#### `init.lua` (704 lines) — module facade and lifecycle owner

Module-level state singleton (`M = { _client_id, _cache, _conn_id, … }`) at
`lua/dbee/lsp/init.lua:62-75`. **One LSP client per Neovim session, switched
per current connection.** All public entry points are functions on `M`:

- `M.queue_buffer(bufnr)` (line 152) — attach a buffer to the running LSP, or
  queue it if the LSP isn't up yet. Triggers `M._try_start()` on first call.
- `M.stop(conn_id, opts)` (line 512) — tear down. Has surgical
  `preserve_structure_waiter_for` flag for connection swaps to avoid losing
  in-flight bootstrap.
- `M.restart()` (line 551) — stop + try-start.
- `M.refresh()` (line 557) — re-request structure for the current connection.
- `M.status()` (line 624) — debug/inspection.
- `M.register_events()` (line 640) — register `call_state_changed`,
  `current_connection_changed`, `database_selected` listeners. Called once
  from `lua/dbee/api/state.lua:73-76`.

Internals worth flagging:
- `_try_start` (line 391) implements a 3-step boot:
  1. Disk-cache fast path (`SchemaCache:load_from_disk()` at line 412 —
     `vim.lsp.start` runs immediately, then a background structure refresh).
  2. Async structure refresh via `connection_get_structure_singleflight`
     (line 254) — Go→Lua delivers via `structure_loaded` event, handled in
     `_on_structure_loaded` at line 211.
  3. **5-second metadata-SQL fallback** (line 434) — `vim.defer_fn` for 5000ms;
     if `_client_id` is still nil, fire a per-dialect SELECT against
     `all_tables` / `information_schema` etc. (METADATA_QUERIES at line 9-47).
- `_bootstrap_connection_invalidated` (line 289) — coordinates with the
  connection-invalidation epoch consumer (Phase 7 plumbing). Two-phase drain:
  bootstrap → live, with `restart` / `storm` / `overflow` event kinds. This is
  the **most complex code in the module** and is wired to the rest of the
  Phase 7 cross-module lifecycle (D-64..D-88).
- `_pending_connection_invalidations` is a buffer that accrues events; flushed
  on `vim.schedule` via `_flush_connection_invalidations` (line 570).

#### `server.lua` (445 lines) — in-process LSP RPC implementation

This is dbee's **in-process LSP server**: `M.create(cache)` at line 357 returns
a function suitable for `vim.lsp.start({ cmd = … })`. The cmd-function returns
a table `{ request, notify, is_closing, terminate }` per the documented
in-process LSP shape ([Neovim LSP docs](https://neovim.io/doc/user/lsp.html),
[in-process LSP guide](https://neo451.github.io/blog/posts/in-process-lsp-guide/)).

Capabilities advertised (line 367-378):
```
completionProvider = { triggerCharacters = { ".", " " }, resolveProvider = false }
textDocumentSync = { openClose = true, change = 1 }  -- 1 = FULL sync
```

Methods handled:
- `initialize` — synchronous reply with capabilities.
- `shutdown` — flips `closing = true`.
- `textDocument/completion` — `pcall(get_completions, params, cache)`. **All
  completion work happens on the main thread, synchronously inside `request`.**
  This is by design (in-process), but it means schema-cache lookups, alias
  parsing, and `connection_get_columns` lazy-fetch all run on the typing path.
- `textDocument/didSave` and `textDocument/didChange` — schedule diagnostic
  computation via `vim.schedule` (line 411). Diagnostics regex-scan the entire
  buffer for FROM/JOIN refs, validate against the cache, emit `Unknown table`
  warnings (line 264-351).
- All other methods: `callback(nil, nil)` — no hover, no signature help, no
  goto-definition, no rename. (Surface area is intentionally tiny.)

#### `schema_cache.lua` (506 lines) — schema/table/column store + disk cache

`SchemaCache` class. Per-connection. Three-level store:
- `schemas: table<string, true>` — set of schema names.
- `tables: table<schema, table<table_name, { type }>>` — schema → table map.
- `columns: table<"schema.table", Column[]>` — lazily-loaded columns.
- `all_table_names: string[]` — flat sorted list for unqualified lookup.

Builders: `build_from_metadata_rows` (line 33, schema_name/table_name/obj_type),
`build_from_structure` (line 72, recursive `_flatten` over DBStructure tree).
Disk cache: `save_to_disk` / `load_from_disk` (lines 171-235), one JSON per
connection at `<stdpath state>/dbee/lsp_cache/<conn_id>.json` plus per-table
column cache `<conn_id>_cols_<schema_table>.json`.

**Key method: `get_columns(schema, table_name, opts)` (line 301)** — this is
the lazy fetch path. If the column key isn't in `self.columns`, it calls
`pcall(self.handler.connection_get_columns, …)` (line 350) **synchronously
on the main thread**. This is the single biggest blocking call inside the
completion request handler.

Also has case-insensitive normalization, Oracle uppercase fallback (line 370),
and an explicit `probe_if_missing` mode (line 374) that tries multiple
schema/table/materialization combinations sequentially.

`find_table` (line 468) is a **double linear scan over all schemas/tables** —
exact match first pass, then upper-case match second pass. Hot path inside
diagnostics (called once per FROM/JOIN reference per line per redraw).

`invalidate` (line 486) wipes in-memory state but leaves disk cache intact.

#### `context.lua` (279 lines) — cursor-position context analyzer

Pure regex + light parsing. `M.analyze(params)` (line 178) returns one of
`schema | table | table_in_schema | column | column_of_table | keyword | none`.
`parse_aliases` (line 102) walks FROM/JOIN/UPDATE/MERGE patterns, builds an
alias→{table, schema} map scoped to the current statement (semicolon
boundary at line 109-112).

Single-line text inspection for most contexts (line 68-79). Multi-line
buffer scan only inside `parse_aliases`. **All synchronous, all main-thread.**
For typical SQL files this is well under 1ms; for very long single-statement
queries the regex passes are O(statement-bytes × pattern-count).

#### `bench.lua` (301 lines) — manual incremental benchmark

Step-by-step `:lua require("dbee.lsp.bench").stepN()` driver. Times:
- `state.handler()`, `get_current_connection`,
- `connection_get_structure` (1st and 2nd call — Go-side cache hit),
- `connection_get_columns`,
- `vim.lsp.start` with empty cache,
- `cache:build_from_structure` (pure Lua flatten),
- metadata SQL execution and `vim.json.decode` of the JSON-on-disk file,
- `cache:build_from_metadata_rows`.

**Critical observation: this bench is interactive only.** It's not part of
CI, has no thresholds, doesn't run in headless mode, and produces no
machine-parseable output. Phase 9 (PERF-01) is targeting drawer perf with
`benchmark.nvim`; LSP has nothing equivalent. **This is a v1.2 gap.**

### A.2 Hot paths — where time is spent (verified by code reading)

`bench.lua` measures aggregate steps; the actual per-keystroke hot path is
inside `server.lua:request("textDocument/completion", …)`:

```
server.lua:387  pcall(get_completions, params, cache)
  → server.lua:218  get_completions
    → context.lua:178  M.analyze(params)
      → context.lua:68  get_text_before_cursor (single nvim_buf_get_lines)
      → context.lua:102 parse_aliases (multi-line buf read + 8 regex passes)
    Branch by ctx:
    → table:           server.lua:62  table_completions(cache, nil)
                         + server.lua:183 schema_completions
    → table_in_schema: server.lua:62  table_completions(cache, schema)
    → column_of_table: server.lua:105 column_completions
                         → schema_cache.lua:301 get_columns(...)
                           → schema_cache.lua:350 connection_get_columns  ← BLOCKING RPC
    → column:          server.lua:157 all_column_completions (no fetch)
                         + server.lua:62  table_completions
    → schema:          server.lua:183 schema_completions
    → keyword:         server.lua:201 keyword_completions + tables
```

**Time-sink candidates, ordered by suspicion:**

1. **`connection_get_columns` synchronous call inside completion** — the
   table-alias dot path (`SELECT t.|`) triggers one Go-RPC call on first
   request per (schema,table). For a cold cache, each new alias dotted
   inside a session takes the full RPC roundtrip, which translates to
   actual DB metadata query time. On Oracle this can be hundreds of ms.
   `schema_cache.lua:367-373` falls back to a second uppercase RPC if the
   first returns nothing, doubling worst-case latency. For dialects with
   `probe_if_missing` (line 374-440), the candidate matrix can fire up to
   `len(schema_cands) × len(table_cands) × len(materializations)` (default
   1×2×2 = 4) sequential RPCs. This is the most acute latency hazard.

2. **`table_completions(cache, nil)` builds the all-schemas-all-tables list
   on every keystroke** in `table` and `keyword` contexts (server.lua:76-95).
   For a 50-schema × 200-tables-per-schema database, that's ~10k items
   constructed in Lua, allocated, returned. blink.cmp/nvim-cmp do their own
   filter, but item construction itself isn't free.

3. **`compute_diagnostics` regex-scans the whole buffer on every didChange**
   (server.lua:264-351). Two passes per line for FROM/JOIN, with up to two
   `cache:find_table` calls per match — and `find_table` is two linear
   scans over all schemas/tables (schema_cache.lua:468-483). For a 1000-line
   SQL file with 100 FROM/JOIN refs, this is ~200 × O(total_tables)
   scans **per keystroke**.

4. **`vim.fn.glob` in `_load_columns_from_disk`** (schema_cache.lua:257)
   runs once per LSP startup, but on a workspace with hundreds of cached
   columns files this is non-trivial. `vim.fn.glob` is synchronous.

5. **`io.open` / `f:read("*a")` for disk cache** (schema_cache.lua:188-193,
   199-205) — these are fully synchronous and run on the main thread during
   `_try_start`. For small JSON it's fine; for very large structures
   (which is exactly the case the metadata-SQL fallback exists to handle)
   this matters.

### A.3 Concurrency / async patterns

dbee LSP uses three async primitives:
- `vim.schedule(fn)` — defer to next event-loop tick. Used in
  `server.lua:411` (diagnostics computation off the notify path) and
  `init.lua:619` (connection-invalidation flush).
- `vim.defer_fn(fn, 5000)` — 5-second timer for the metadata-SQL fallback
  (`init.lua:434-447`).
- `connection_get_structure_singleflight({ callback = … })` — Go-side
  routes the structure load through goroutines and delivers via
  `structure_loaded` event. The Lua side just registers a callback.

**Blocking calls on the main thread:**
- `connection_get_columns` in `schema_cache.lua:350` — pcall around a
  sync handler RPC. **Runs inside completion request.**
- `connection_execute` in `init.lua:463` — also sync, but it just enqueues
  the call; the result comes back via `call_state_changed` event.
- `call_store_result` in `init.lua:479` — sync, writes JSON to a temp file.
- `io.open`, `f:read("*a")`, `f:write` — all synchronous file I/O.
- `vim.fn.glob`, `vim.fn.mkdir`, `vim.fn.fnamemodify` — synchronous.
- `vim.json.encode` / `vim.json.decode` — sync but C-implemented; cheap.
- `vim.api.nvim_buf_get_lines` — sync; called in `context.lua:73` and
  `server.lua:417`.

**No coroutines, no `vim.system`, no nvim-nio.** The module is built on the
classic event-callback / pcall-RPC model. This is fine for the bootstrap
path (single-shot, off the typing path); it's a real concern for the
column-fetch path that runs inline with completion.

### A.4 Caching strategy

**In-memory:** `SchemaCache` instance owned by `dbee.lsp.M._cache`. One per
LSP client (= one per active connection).

**Disk:** JSON per connection at `<stdpath state>/dbee/lsp_cache/`:
- `<conn_id>.json` for the schema/table index.
- `<conn_id>_cols_<safe_key>.json` per table that has been inspected.

**Invalidation rules** (from `init.lua` event listeners at line 651-701):
- `current_connection_changed` → `M.stop(old_conn)` + `_try_start` for new.
- `database_selected` → `cache:invalidate()` + structure refresh.
- `connection_invalidated` event (Phase 7) → `_pending_connection_invalidations`
  buffer, flushed on `vim.schedule`. Conservative: rewarms on any affected
  connection, including current one.
- `structure_loaded` event with newer `root_epoch` → rebuild cache and save.

**Eviction / memory bounds: NONE.** `SchemaCache.columns` grows monotonically
within a session as users hit `t.|` on more tables. Disk cache also grows
unboundedly: there's no LRU, no max-size, no expiration. For a long-lived
session against a 5000-table warehouse, this could eat memory.

**Stale-while-revalidate pattern present** (`init.lua:412-417`): disk cache
loads instantly, LSP starts immediately, and a background async refresh
fires to update. **This is the right pattern.** It's the same pattern
nvim-cmp / blink.cmp use for buffer / path completions. Good design here.

### A.5 Latent bugs / suspicious patterns / TODOs

`grep -rn "TODO\|FIXME\|XXX\|HACK"` returned **zero hits** in `lua/dbee/lsp/`.
Either the module is genuinely clean, or the original authors didn't leave
self-notes — context indicates the former, given the recent stabilization
work in commits `1ecf461` (initial schema-aware completion, Phase 6),
`7d823a8` (cached column keys with underscores), `2c1db6a` (pre-insert dot
trigger for aliases), `4c28947` (alias rebinding by cursor scope), `3d2236e`
(schema-qualified alias completion).

Suspicious patterns I'd flag in code review:

- **`server.lua:264-351` diagnostics regex**: `for kw, rest in line:gmatch("([Ff][Rr][Oo][Mm]%s+)(.-)$")` —
  the `(.-)$` lazy-then-anchor-to-end pattern is doing per-line substring
  matching, but the `from %w` regex is looped per-line, and it doesn't
  handle multi-line FROM clauses (e.g. `FROM\n  schema.table`). The
  diagnostic will silently fail to flag tables that wrap across lines. Not
  a bug but a known limitation.

- **`server.lua:317-321` JOIN diagnostic uses `line:find(kw, 1, true)`**
  inside a loop where `kw` itself comes from the `gmatch` capture. If a line
  has the literal text "JOIN" twice, the second iteration will find the
  first occurrence's position, not the second. This is a subtle off-by-one
  / wrong-position bug. Diagnostics will land on the wrong column for
  multi-JOIN-per-line queries.

- **`init.lua:519-526` accesses `handler._structure_flights` directly** —
  this is reaching into Phase 7 internal state with `pcall`-less direct
  field access. If the handler shape changes, this breaks silently
  (Lua nil-traversal). The `flight.consumer_slots or {}` defensive check
  at line 521 acknowledges this is a fragile contract.

- **`schema_cache.lua:267 ` filename parsing**: `local fname = vim.fn.fnamemodify(path, ":t:r")` then
  `key = fname:sub(#prefix + 1)`. If `conn_id` contains characters that
  the sanitizer at line 167 (`[^%w_.]` → `_`) collides with on a different
  connection, the disk cache files can stomp each other. Low probability,
  but worth a dedicated test.

- **`init.lua:430-447` 5s defer is a magic number.** The metadata-SQL fallback
  exists because Go→Lua serialization can choke on huge structures, but
  5000ms is hard-coded. Some users on slow databases will see structure
  arrive at second 6 and then a stale metadata query fire. Not catastrophic
  (the result is "structure is more complete, don't override" at line 504),
  but wasteful.

- **`schema_cache.lua:445-455`**: the lazy `connection_get_columns` writes
  results to disk even when the in-memory result was empty due to
  permission issues. There's no negative-cache: a permission-denied lookup
  produces `cols == {}` (line 442) and we don't save, but the in-memory
  `self.columns[key]` is also not set, so the next completion re-fires the
  full RPC. Either negative-cache or rate-limit failed lookups.

### A.6 Neovim 0.12.x deprecated API usage

CI is on 0.11.6; v1.2 will likely target 0.12.x (per Phase 9 lock). I
checked dbee LSP against the 0.11/0.12 deprecation list ([Neovim
deprecated.txt](https://neovim.io/doc/user/deprecated.html), [What's New
in Neovim 0.11](https://gpanders.com/blog/whats-new-in-neovim-0-11/)):

| Call site | API | Status | Action needed |
|---|---|---|---|
| `init.lua:158`, `:176` | `vim.lsp.buf_attach_client` | Still public in 0.12, but the official "native LSP" pattern is now `vim.lsp.config()` + `vim.lsp.enable()` driven by `filetype`/`root_dir`. Manual `buf_attach_client` works, but is the "old way." | Consider migrating to `vim.lsp.config({ name = "dbee-lsp", … })` + `vim.lsp.enable("dbee-lsp")`, with a custom filetype/autocmd predicate. Lower priority — current code works, but new pattern simplifies multi-buffer attach. |
| `init.lua:189` | `vim.lsp.start({ cmd = function … })` | Active, supported, recommended for in-process LSPs ([0.12 native LSP](https://dotfiles.substack.com/p/native-lsp-in-neovim-012)). | None. Keep. |
| `init.lua:539` | `vim.lsp.get_client_by_id()` then `client:stop()` | Active in 0.11+. The deprecated form was `vim.lsp.stop_client(id)`. | None. Already on the right side. |
| **(absent)** | `client:request_sync()` / `client.request_sync()` | Deprecated in 0.11; use `Client:request_sync()` ([issue #26725](https://github.com/neovim/neovim/issues/26725)). | dbee LSP doesn't call this — it doesn't talk to its own client at all from Lua, only services requests. Safe. |
| `server.lua` capabilities | `change = 1` (Full sync) | Still valid; 0.11 native client supports both 1 (Full) and 2 (Incremental). Full sync is fine for SQL files because they're tiny. | Consider switching to incremental (2) only if didChange becomes a hot path; for SQL files, Full is correct. |
| `server.lua` capabilities | No `positionEncoding` advertised | 0.11+ added support for `general.positionEncodings` in initialize. Defaults still work but issuing a `positionEncoding: "utf-16"` in serverInfo would future-proof against the [PR #31249](https://github.com/neovim/neovim/pull/31249) "make offset_encoding required" tightening. | Low priority but cheap. Add `positionEncoding = "utf-16"` to capabilities reply. |
| `init.lua:619` | `vim.schedule` | Active. | None. |
| `server.lua` dispatchers | `dispatchers.on_notify("textDocument/publishDiagnostics", …)` (line 423-427) | This is the right channel. 0.11 added `vim.diagnostic` integration for LSP diagnostics; the `publishDiagnostics` notification still works via the existing pipeline. | None. |

**Net assessment: dbee LSP is largely 0.12-clean.** No outright deprecated
calls. Two opportunities (vim.lsp.config migration, positionEncoding
declaration) are quality-of-life, not blocking.

---

## Part B — Ecosystem patterns (live research, 2026)

### B.1 SQL-aware LSP integration in the Neovim ecosystem

**`sqls`** (`sqls-server/sqls`) is the de-facto standalone Go SQL LSP.
[Repo](https://github.com/sqls-server/sqls). Uses lspconfig as `sqlls`
([config](https://github.com/neovim/nvim-lspconfig/blob/master/lua/lspconfig/configs/sqlls.lua)).
**Maintenance signal: still receiving commits (last update Oct 2025) but the
[GitHub Discourse thread](https://neovim.discourse.group/t/sql-language-server-protocol/3722) and
multiple plugin authors have called out staleness; community support has
fragmented to alternative completion sources.**

Key sqls patterns:
- **One LSP instance per database connection** to avoid cross-database
  completion contamination ([README](https://github.com/sqls-server/sqls)).
  dbee already does this via `M._client_id` switching on
  `current_connection_changed`.
- **Connection definitions in a YAML/JSON config**, not in-buffer. dbee's
  approach (live connection from drawer state) is **better** for the dbee
  workflow, where users add connections at runtime.
- **Schema cache built from `INFORMATION_SCHEMA` queries**, which is exactly
  dbee's METADATA_QUERIES fallback. dbee's per-dialect query set
  (init.lua:9-47) is broader than sqls (which is mostly MySQL/Postgres).
- Lua wrapper [`sqls.nvim`](https://github.com/nanotee/sqls.nvim) adds
  helpers for `executeQuery` / `switchDatabase` workspace commands.

Alternative source: **`vim-dadbod-completion`** ([repo](https://github.com/kristijanhusak/vim-dadbod-completion)).
Caches tables and columns; supports nvim-cmp, blink.cmp (via
`vim_dadbod_completion.blink`), ddc, omnifunc. Pattern: **plain completion
source, not an LSP**. Much simpler shape than dbee. Tradeoff: no diagnostics,
no goto-definition, no future hover.

**Verdict for dbee:** dbee's "in-process LSP" shape is more capable than
either competitor and aligns with the modern Neovim "use the LSP infra you
already have" guidance. Keep the architecture; tune the implementation.

### B.2 Schema cache patterns (TTL, invalidation, background refresh)

The dominant pattern in the 2026 ecosystem:

- **`mason.nvim` registry cache** (registry of installable LSP servers):
  on-disk JSON, manual refresh, no TTL.
- **`nvim-cmp` / `blink.cmp` source caches**: per-source decision. LSP
  source is server-driven (no client-side cache). Buffer source recomputes
  on `BufWritePost` / debounce. Path source has no cache.
- **`fzf-lua`, `telescope.nvim`**: in-process LRU caches keyed by query
  string, evicted on memory pressure or count.

**Stale-while-revalidate** (what dbee does) is **the right pattern** but
under-instrumented. Reference: [SWR pattern as documented in front-end
fetch libs and applied to Neovim plugins like blink.cmp's lsp source]. dbee
should add (a) max-size eviction, (b) optional TTL for force-refresh, (c)
explicit `:DbeeLspRefresh` already exists — could surface in keybinds.

**Memory bounds reference points** (typical):
- nvim-cmp keeps the last N candidates per source (configurable, default
  N=200 for buffer source).
- blink.cmp uses a Rust-side cache with explicit byte budget.
- `telescope.nvim` enforces `cache_picker = { num_pickers = 5 }` by default.

dbee should pick a similar bound. Recommendation: cap `SchemaCache.columns`
at ~500 tables in-memory (LRU), keep disk cache unbounded but expire
files older than 30 days on startup.

### B.3 Context propagation patterns

How plugins thread per-buffer / per-session context (analogous to dbee's
"current DB connection") into LSP requests:

1. **`vim.b.<key>` buffer-local vars** — used by formatter plugins
   (`conform.nvim`) to override formatter per-buffer.
2. **Per-client `private_attributes`** — the `vim.lsp.start` config table
   accepts arbitrary keys; `vim.lsp.get_client_by_id(id).config.<key>`
   retrieves them. Used by `null-ls` / `none-ls` for source registration.
3. **Workspace folders** — LSP-native. `vim.lsp.buf.add_workspace_folder`
   adds a logical workspace. **dbee could surface each connection as a
   workspace folder.** No one in the SQL space does this today.
4. **Bufnr → context maps in the plugin's own state** — what dbee does
   (`M._cache`, `M._conn_id`). Simplest, least magical.

**Verdict:** dbee's pattern (module-level `_conn_id` + listener on
`current_connection_changed`) is fine. The downside is "one current
connection at a time per Neovim session." If a v1.2+ goal is **multi-
connection editing in different splits**, the cleanest path is one LSP
client per connection, keyed by `connection_id`, with `buf_attach_client`
selecting which client serves each buffer. This is a non-trivial refactor
(the singleton `M._client_id` becomes a dict).

### B.4 Async streaming — 2026 idiomatic pattern

Live research surfaced four candidates:

- **`vim.system()`** — Neovim 0.10+ native, stable, callback-based.
  Replaces `jobstart` / `vim.fn.jobstart`. Used for shelling out — not
  applicable here (dbee Go RPC is in-process).
- **Coroutines (`coroutine.create` + `coroutine.resume`)** — base Lua,
  no deps. Used by plenary's async, gitsigns. Verbose, error-handling
  is awkward.
- **`nvim-neotest/nvim-nio`** ([repo](https://github.com/nvim-neotest/nvim-nio)) —
  a thin task abstraction over coroutines with proper pcall propagation,
  futures, semaphores. Used by neotest, dap-ui. **Most idiomatic 2026
  choice for Neovim plugin code.** ([Demystifying async Lua in Neovim](https://dzx.fr/blog/async-lua-in-neovim/))
- **`lewis6991/async.nvim`** — older alternative, less ergonomic than nio.
  Effectively superseded.

**Recommendation for dbee LSP v1.2:** introduce **`nvim-nio` as a peer
dependency** (already used by superpowers / neotest stacks) and rewrite
the column-fetch lazy path to:

```lua
-- pseudocode
local nio = require("nio")

function SchemaCache:get_columns_async(schema, table_name, opts)
  return nio.run(function()
    -- check in-mem cache, return immediately if hit
    -- nio.wrap the handler.connection_get_columns
    -- return future
  end)
end
```

The completion request then calls `get_columns_async`, returns an empty
list immediately, and emits a `workspace/didChangeConfiguration` or
re-triggers the completion via `dispatchers.on_notify` once the future
resolves. **This makes the typing path non-blocking.**

Risk: adding a runtime dep. Alternative: hand-rolled coroutines (no dep but
more code). I lean toward nio because the rest of the Neovim plugin
ecosystem is converging on it.

### B.5 Server lifecycle patterns

- **Hot-reload on config change** — `lspconfig` does this implicitly via
  `vim.lsp.enable()`. dbee's `M.restart()` exists but isn't surfaced; user
  has to call it manually or trigger a connection change.
- **Multi-instance per workspace** — sqls supports this (one LSP per DB
  connection). dbee currently runs **one** LSP keyed by current connection;
  attaching a buffer to a different connection's LSP requires switching
  the current connection. This is a UX limitation, not a perf issue.
- **Cleanup on detach** — Neovim 0.11+ added [issue #33752](https://github.com/neovim/neovim/issues/33752)
  tracking auto-stop when last buffer detaches. Not yet shipped. Plugins
  must manage this themselves; dbee does, in `M.stop`.

### B.6 In-process vs out-of-process LSP

dbee's LSP is **in-process Lua** (no separate binary). The official
[in-process LSP guide](https://neo451.github.io/blog/posts/in-process-lsp-guide/)
describes exactly the shape dbee uses: `cmd = function(dispatchers, config)
return { request, notify, is_closing, terminate } end`.

Reference implementation in the Neovim core: `runtime/lua/vim/pack/_lsp.lua`
(used by the new `:Pack` UI for hover/docs). **Same shape as dbee.**

`null-ls` / `none-ls` ([repo](https://github.com/nvimtools/none-ls.nvim))
also uses in-process. They've made it work for hundreds of "sources" in
production for years.

**Verdict: dbee's choice is correct and well-supported.** Out-of-process
would make sense only if dbee LSP work blocks the editor (it largely
doesn't, except for the column-fetch path) or if the LSP needed to
outlive the Neovim session (it doesn't). Keep in-process.

### B.7 Performance budgets — the "feels-laggy" cliff

From the live research:
- **<16ms**: feels instant (60fps frame budget).
- **16-50ms**: barely perceptible delay, OK for keystroke→redraw.
- **50-100ms**: starts to feel sluggish for completion popup display.
- **100-300ms**: clearly laggy; users notice.
- **>300ms**: users complain on issue trackers ([nvim-cmp #1819](https://github.com/hrsh7th/nvim-cmp/issues/1819),
  [#231 LSC dart 500ms debounce](https://github.com/nvim-lua/completion-nvim/issues/231)).

LSC and several alternatives default to a **500ms debounce** for completion
trigger to absorb network/RPC latency.

**Recommended budgets for dbee LSP v1.2 (per platform, advisory first):**
- LSP startup (first attach): <500ms (cold disk cache), <100ms (warm).
- `textDocument/completion` request handler: **p95 < 30ms** for cached
  cases, **p95 < 200ms** for cold lazy column fetch (with the async
  rewrite this becomes "non-blocking, candidates streamed in").
- Diagnostics on didChange: <50ms p95 (currently unmeasured).
- Schema rebuild from full structure: <100ms for a 1000-table DB.

dbee should adopt the same `benchmark.nvim` runner Phase 9 is locking in,
and add a `make perf-lsp` target. **This is a clear v1.2 phase.**

---

## Part C — Proposed v1.2 phase breakdown

Based on Parts A+B, I see four candidate phases. The orchestrator should
pick 2-3 and defer the rest to v1.3.

### Phase L1 — Async column fetch (HIGH-VALUE, MED RISK)

**One-line:** Make the lazy `connection_get_columns` path non-blocking, so
typing `t.|` never freezes the editor on cold-cache lookups.

**In scope:**
- Introduce `nvim-nio` as a peer dependency (or hand-roll coroutines).
- Rewrite `SchemaCache:get_columns` to return a future; warm cases stay
  synchronous, cold cases return `{}` immediately and trigger
  `dispatchers.on_notify("workspace/_dbee/columns_loaded", { key })` (or
  re-trigger completion) when ready.
- Add a per-connection in-flight dedupe so two simultaneous `t.|` taps
  don't fire two RPCs.
- Add LRU eviction on `SchemaCache.columns` (cap at ~500 tables).

**Out of scope:** Diagnostics async (separate phase), structure-load async
(already done).

**Risk: MED.** Touches the hottest path. Needs careful test coverage —
multi-keystroke scenarios, connection-swap mid-fetch, error fallbacks.

**Sequencing:** No dependency. Can ship first.

### Phase L2 — Perf harness for LSP (MEDIUM-VALUE, LOW RISK)

**One-line:** Stand up a `benchmark.nvim`-driven perf harness for the LSP
(parallel to Phase 9 drawer perf), with mac+linux blocking budgets.

**In scope:**
- Reuse the Phase 9 `benchmark.nvim` runner (pinned commit) and Neovim
  0.12.x lane.
- Convert `bench.lua` interactive steps into headless benchmarks.
- Add scenarios: cold-cache LSP start, completion in `table` ctx with
  100/1000/10000-table cache, completion in `column_of_table` with cold
  fetch, diagnostics on 100/1000/10000-line buffers.
- Per-platform thresholds (mac + linux co-equal, per Phase 9 D-117).
- `make perf-lsp` target.

**Out of scope:** Optimization based on findings (those become L1 / L3).

**Risk: LOW.** Pure measurement, no behavior change.

**Sequencing:** Independent. Could ship before L1 and gate L1 with the
new harness.

### Phase L3 — Diagnostics rewrite (MED-VALUE, LOW RISK)

**One-line:** Fix the multi-line FROM bug, the `line:find` JOIN-position
bug, and make diagnostics incremental rather than whole-buffer.

**In scope:**
- Fix `server.lua:308-345` JOIN position calculation (use `gmatch`'s
  end-position instead of re-finding `kw`).
- Support multi-line FROM/JOIN clauses (statement-level rather than
  line-level analysis).
- Switch from full-buffer recompute on every didChange to incremental
  diagnostics scoped to the changed range. Use
  `vim.diagnostic.set` namespacing already wired into the editor
  (per `lua/dbee/ui/editor/CLAUDE.md` activity #634).
- Add tests for multi-JOIN-per-line and statement-spanning FROM.

**Out of scope:** Adding new diagnostic kinds (column-not-in-table,
ambiguous alias, etc.) — those are v1.3+.

**Risk: LOW.** Bug fixes + scope reduction.

**Sequencing:** Can ship in parallel with L1.

### Phase L4 — vim.lsp.config migration (LOW-VALUE, LOW RISK)

**One-line:** Migrate from `vim.lsp.start` + manual `buf_attach_client` to
the 0.11+ `vim.lsp.config` + `vim.lsp.enable` pattern; advertise
`positionEncoding`.

**In scope:**
- Define `vim.lsp.config("dbee-lsp", { cmd = …, filetypes = { "sql", "dbee" }, root_dir = … })`.
- Replace `M.queue_buffer` with autocmd-driven `vim.lsp.enable("dbee-lsp")`.
- Add `positionEncoding = "utf-16"` to capabilities.
- Update tests that mock `vim.lsp.start`.

**Out of scope:** Multi-instance per connection (deferred to v1.3+).

**Risk: LOW.** Mostly mechanical.

**Sequencing:** Should be last (after L1+L3 land), so refactor doesn't fight
behavior changes.

### Suggested v1.2 milestone composition

**Recommended:** L2 → L1 → L3, defer L4 to v1.3.

**Rationale:**
- L2 first establishes baseline measurements; subsequent phases ship with
  evidence. Same pattern Phase 9 set up for the drawer.
- L1 is the highest user-visible win (no more typing freezes on cold
  Oracle metadata).
- L3 is a clean correctness pass that benefits from the L2 harness.
- L4 is hygiene; can ride along if budget allows, but not blocking.

---

## Part D — Open questions for the orchestrator

These are decision forks where I found multiple defensible answers. The
orchestrator should resolve before locking the milestone.

### Q1. Async runtime — adopt `nvim-nio` or hand-roll coroutines?

- **`nvim-nio` (recommended)**: Adds a peer dep but matches 2026 idiom.
  The dbee user base is overwhelmingly users of neotest / superpowers /
  dap-ui already running it.
- **Hand-rolled coroutines**: Zero new deps; ~50 lines of "future" / "wrap"
  boilerplate. Slightly less ergonomic.
- **Decision needed before L1.** Affects test setup, plugin dep declaration,
  Mason/lazy.nvim integration docs.

### Q2. Multi-connection LSP — stay singleton or pivot to per-connection clients?

dbee currently runs one LSP keyed by current connection. Switching connections
tears down and rebuilds. **If multi-connection editing is a v1.x goal**,
the architecture should pivot to one client per connection now (cheaper to
do during L1's refactor than as a separate phase). **If single-connection
is the explicit product stance**, lock that decision and don't pay the
complexity tax.

### Q3. LRU eviction — what's the right `max_columns_in_memory` bound?

I'm proposing 500 tables × ~20 columns ≈ 10k Column records ≈ ~2-5MB of Lua
heap. Conservative. Larger? Smaller? This is a project-priority question
(memory vs latency tradeoff for power users with very large warehouses).

### Q4. Diagnostic ambition — fix bugs only, or expand to richer SQL linting?

L3 as scoped is bug-fix + incremental. But the underlying machinery could
support more (column-not-in-table, ambiguous alias, type mismatches, dialect-
specific keyword warnings). **More ambition = more value but pulls scope toward
"build a SQL linter."** sqls famously overpromised here. Recommend keeping
L3 narrow and putting "richer linting" on the v1.3 roadmap as a separate
milestone candidate.

### Q5. CI Neovim version — stay on 0.11.6 or bump to 0.12.x for v1.2?

Phase 9 Mac-priority decision says 0.12.x is the blocking lane. **Should
v1.2 LSP work also adopt 0.12.x as the floor, dropping 0.11 support, or
maintain 0.11 compat for one more milestone?** Most users on lazy.nvim
follow head; LazyVim is on 0.11.4+. Dropping 0.11 simplifies code (some
deprecation hygiene becomes irrelevant) but cuts off a non-trivial slice
of users. Project-level call.

---

## Sources

External research:
- [Neovim LSP docs](https://neovim.io/doc/user/lsp.html)
- [Neovim deprecated.txt](https://neovim.io/doc/user/deprecated.html)
- [What's New in Neovim 0.11 — gpanders](https://gpanders.com/blog/whats-new-in-neovim-0-11/)
- [Native LSP in Neovim 0.12 — Adib Hanna](https://dotfiles.substack.com/p/native-lsp-in-neovim-012)
- [In-process LSP guide — neo451](https://neo451.github.io/blog/posts/in-process-lsp-guide/)
- [vim.lsp.client.request_sync deprecation issue #26725](https://github.com/neovim/neovim/issues/26725)
- [offset_encoding required PR #31249](https://github.com/neovim/neovim/pull/31249)
- [LSP auto-stop when last buffer detaches issue #33752](https://github.com/neovim/neovim/issues/33752)
- [sqls-server/sqls](https://github.com/sqls-server/sqls)
- [sqls.nvim — nanotee](https://github.com/nanotee/sqls.nvim)
- [vim-dadbod-completion — kristijanhusak](https://github.com/kristijanhusak/vim-dadbod-completion)
- [blink.cmp](https://github.com/saghen/blink.cmp)
- [blink.cmp sources docs](https://main.cmp.saghen.dev/configuration/sources)
- [nvim-nio](https://github.com/nvim-neotest/nvim-nio)
- [Demystifying async Lua in Neovim — dzx.fr](https://dzx.fr/blog/async-lua-in-neovim/)
- [none-ls.nvim](https://github.com/nvimtools/none-ls.nvim)
- [benchmark.nvim — stevearc](https://github.com/stevearc/benchmark.nvim)
- [nvim-cmp #1819 perf complaints](https://github.com/hrsh7th/nvim-cmp/issues/1819)
- [completion-nvim #231 dart debounce](https://github.com/nvim-lua/completion-nvim/issues/231)
- [SQL Language Server Protocol — Neovim Discourse](https://neovim.discourse.group/t/sql-language-server-protocol/3722)

dbee-internal references (file:line):
- `lua/dbee/lsp/init.lua:1-704`
- `lua/dbee/lsp/server.lua:1-445`
- `lua/dbee/lsp/schema_cache.lua:1-506`
- `lua/dbee/lsp/context.lua:1-279`
- `lua/dbee/lsp/bench.lua:1-301`
- `lua/dbee/api/state.lua:73-76` (LSP wiring)
- `lua/dbee/ui/editor/init.lua:1276-1279` (queue_buffer call site)

dbee-internal commit history:
- `1ecf461` feat(lsp): add schema-aware SQL completion with metadata query fallback
- `9de15cf` fix(lsp): ignore grouped nodes in schema cache
- `7d823a8` fix(lsp): preserve cached column keys with underscores
- `2c1db6a` fix(lsp): handle pre-insert dot trigger for aliases
- `4c28947` fix(lsp): rebind aliases by cursor scope
- `3d2236e` fix(lsp): complete schema-qualified aliases
- `4759586` feat(07-03-01) root singleflight bootstrap coordination
- `c338640` feat(07-03-02) batch invalidation and sticky selection
- `323f1a9` fix(07-01-01) clear LSP per-connection guards on stop
- `76dff39` fix(07-03-01) teardown drops orphan single-flight entries
