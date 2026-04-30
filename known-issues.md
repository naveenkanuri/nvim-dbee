# Known Issues

## v1.3 Backlog

### Pending milestone v1.3 candidates

- **Phase 12: LSP feature gap closure** — deferred from v1.2 per "DECIDE AT PHASE 11 SHIP" clause. Scope: `completionItem/resolve` lazy details, hover for table/column metadata, code actions for refresh/reload on stale schema, document/workspace symbol for schema objects. Out: semantic tokens, inlay hints, `vim.lsp.config()` migration, multi-client LSP architecture (those defer further).

### Pre-existing bugs surfaced during v1.2 work (NOT Phase 10/11 caused)

- **`a and nil or b` Lua pattern cleanup**:
  - `lua/dbee/handler/init.lua:780`
  - `lua/dbee/ui/drawer/init.lua:1904`
  - Lua truthiness bugs where middle expression being falsy selects the wrong branch.

- **Pre-existing legacy headless failures**, verified on both `50b53eb` (Phase 10 ship) and `74bd66f` (mid-Phase 11):
  - `check_actions_recovery.lua` — `ACTIONS_RECOVERY_FAIL=recover_execute_timeout`
  - `check_auto_reconnect.lua` — `CONN01_FAIL=deep_copy_retry_ok:false`
  - `check_notifications.lua` — `NOTIF_FAIL=notif04_add_node_not_found`
  - `check_drawer_yank.lua` — `CLIP02_FAIL=a10_connection_node_present`

### Phase 11 r6 residual HIGH (backlogged after diminishing-returns gate at impl-gate r6)

- **Case-colliding schema lookup mismatch** (`lua/dbee/lsp/schema_cache.lua:373`, `lua/dbee/lsp/server.lua:86`):
  Incremental `_upsert_table_index()` is not fully rebuild-equivalent when schemas differ only by case. Existing folded schema representative can survive, causing completion to read `a.T` while async sync-delivery stored `A.T`.
  v1.3 fix: update `schema_lookup` incrementally using the same representative rule as full rebuild; extend equivalence tests to compare lookup indexes.

- **Targeted global index update still walks schemas** (`lua/dbee/lsp/schema_cache.lua:332`):
  `_update_global_table_index_for_label()` avoids full global refresh but still sorts/scans all schemas per async-discovered table.
  v1.3 fix: maintain an incremental representative map per folded label so each upsert only compares the affected schema/table.

### v1.1 Phase 7 drawer UX polish (surfaced 2026-04-29 during v1.1 live test)

- ~~Connection source badge always shown even when single-source~~ — **FIXED 2026-04-30** in `convert.lua`: badge now conditional on `#sources > 1`. Single-source setups render clean `conn_name` only.

- **Drawer cold start lacks visual orientation** (cosmetic, related):
  Connection list starts flat from line 1. Old v1.0 had `connections.json` parent header providing instant context for "what am I looking at". v1.3 candidate: optional section header `Connections` line OR active-connection highlight at top. Lower priority than badge fix.

### v1.1 Phase 7 drawer filter regression (surfaced 2026-04-29 during v1.1 live test) — HIGH

- **`/` filter in drawer fails on connection-only root** (`lua/dbee/ui/drawer/menu.lua` filter path; Phase 4 D-31 + Phase 7 D-67/D-68 inheritance):
  Pressing `/` in the drawer (with no connection bootstrapped yet, just the flat connection list) emits "No cached connections available for filter" and exits filter mode. User can't reach a specific connection by typing.
  Likely root cause: Phase 7 connection-only-root rewrite kept Phase 4 D-31 filter contract that operates over `_struct_cache` (per-connection structure). On the connection list itself (no conn bootstrapped, `_struct_cache` empty), filter early-returns instead of falling back to filtering the visible connection rows by name.
  Expected: `/` filters whatever's currently visible — connection rows pre-bootstrap (by name + source badge), structure rows under expanded conn (by schema/table/column name).
  v1.3 fix: extend filter to operate on visible row set when `_struct_cache` empty for current root. Keep Phase 4 D-31 filter-exit contract intact. New unit test covering connection-list-only filter case.
  Severity: **HIGH** — primary navigation pattern broken. Workaround: scroll/jump manually (`gg`/`G`/`/conn_name` via vim-search not drawer filter).

### v1.1 Phase 8 wizard highlight regression — Phase 13 r1 fix DID NOT WORK (still UNUSABLE 2026-04-30)

- **Wizard input field text STILL invisible** despite Phase 13 commit `1436bdc` (`fix(13-01-03): wizard highlights`):
  Phase 13 r1 fix added `winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder,..."` per Input/Select/Border component. r2 added `UX13_WIZARD_NUI_WIN_OPTIONS_THREADED=true` test stubbing nui constructors and asserting threaded `win_options.winhighlight`. Test gate PASSED. **But real-world rendering on Naveen's daily colorscheme STILL shows invisible text.**
  Test was too shallow: validated `win_options.winhighlight` is THREADED to nui constructor, but didn't validate the resulting rendered text is actually visible.

  **CRITICAL DIAGNOSTIC (live test 2026-04-30 follow-up)**: bug is **colorscheme-INDEPENDENT** (broken on BOTH light AND dark themes) AND **only-while-typing** (text becomes visible after pressing Enter). User reports: cursor moves correctly, text invisible during typing, displayed value visible after Enter submits the prompt line.
  This rules out `Normal:NormalFloat` colorscheme contrast issues. The ACTUAL root cause is in `nui.input` prompt-buffer mode-specific rendering:
  1. `nui.input` may set `conceallevel`/`concealcursor` on prompt buffer → typed text concealed during edit; revealed after submit
  2. nui prompt may use a hardcoded fg=bg hl group (e.g. nui-specific `NuiInput*` group) for the in-progress text region
  3. Buffer-line `cursorline` hl with fg=bg masking only the cursor line where typing happens
  4. Treesitter/highlighter applied to prompt buffer with bad sql-grammar match
  Repro: open Add Conn → type "test" → cursor advances 4 chars; nothing visible; press Enter → "test" appears as the saved Name value. Reproduces on light + dark colorschemes both.

  v1.3 next-attempt fix: investigate `nui.input` prompt-buffer rendering before patching. Likely fix path:
  - Inspect `nui.input` source (or pinned commit) for `conceallevel`/`concealcursor`/special hl on prompt buffer
  - Override via `buf_options` (not just `win_options`) — `vim.b[bufnr].conceallevel = 0`, `vim.b[bufnr].concealcursor = ""`
  - OR define explicit `DbeeWizardInput` hl group with hardcoded contrast and apply to prompt-buffer text via `nvim_buf_add_highlight` on every `TextChangedI` event
  - Headless test must SIMULATE typing via `feedkeys` mode "i" + screenshot OR `vim.api.nvim_buf_get_extmarks` to inspect actual rendered hl on prompt-buffer text — NOT just verify constructor args
  Severity: **HIGH** — confirmed still broken via live testing 2026-04-30 across multiple colorschemes. Phase 13 fix was NOT effective. Workaround unchanged: edit `connections.json` directly.

### v1.2 Phase 11 LSP cache migration UX (surfaced 2026-04-29 during v1.1 live test) — POLISH

- **"corrupt cache" warning fires on first v1.2 run for pre-v1.2 cache files** (`lua/dbee/lsp/schema_cache.lua` `load_from_disk`):
  Phase 11 r2 CRIT 2 fix added schema-index shape validation. Pre-v1.2 cache files at `~/.local/state/nvim/dbee/lsp_cache/<conn_id>.json` were written with a slightly different shape and fail new validation → recovery path fires (warn + delete + structure refresh). The warning text "corrupt cache while loading schema index: <path>" is alarming — sounds like data loss when really it's a one-time format upgrade.
  Expected user impact: warning fires ONCE per connection on first v1.2 run; cache regenerates fresh from structure refresh; subsequent runs silent.
  Repro: any user upgrading from v1.1 → v1.2 with existing `lsp_cache/*.json` files. Naveen hit it on `nkanuri6` and likely others.
  v1.3 fix options:
  1. Add a schema-version field to cache JSON (`{ "version": 2, ... }`). Migrate old → new on first read instead of delete.
  2. Detect missing-version-field as v1 format → silent log (`vim.log.levels.DEBUG`) + delete + refresh, instead of WARN-level "corrupt cache".
  3. Both: detect-and-migrate where field shapes are recoverable, silent-delete-and-refresh where not.
  Severity: **POLISH** — recovery path works correctly (data not lost; cache regenerates). Just bad first-run UX. Pick option 1+3 hybrid for cleanest user experience on v1.3 upgrade path.

### v1.1 Phase 6 lazy-loading deepening (surfaced 2026-04-29 during v1.1 live test) — ARCHITECTURE CHANGE

- **Schema+table eager fetch blocks "loading..." for huge DBs** (Phase 6 D-30..D-63 + Phase 7 D-77 single-flight; touchpoints `lua/dbee/handler/init.lua` `connection_get_structure*`, `lua/dbee/ui/drawer/*` materialization, `dbee/handler/event_bus.go` structure events):
  Phase 6 made column children lazy (per-table column fetch on expand). But schemas+tables are still fetched eagerly in ONE initial structure RPC at connection bootstrap. For huge Oracle/Postgres DBs (10000+ tables across many schemas), that single RPC blocks "loading..." for minutes. User reports `nkanuri6` (Oracle) appears stuck on `<CR>`-bootstrap.
  Phase 6 chose schema+table eager because LSP completion at `schema.` prefix needs table names locally available; going schemas-only would force a per-prefix table-list RPC.
  Naveen's proposal: deepen lazy-loading model — fetch schemas only initially, tables on schema-click, columns on table-click (latter already lazy). Cache + parallel-fetch strategies on top.
  v1.3 design considerations:
  1. **LSP impact**: completion at `schema.` prefix needs table list. Either (a) fetch on first `schema.` keystroke and warm asynchronously (Phase 11 isIncomplete contract), or (b) keep table list eager but parallelize across schemas (1 RPC per schema in parallel) so wall-clock = max(schema_RPC) not sum.
  2. **Cache**: per-schema disk cache (per-table-list) parallel to per-table column cache. Phase 11 LRU + cache migration apply.
  3. **Drawer UX**: schema row collapsed by default with `[+]` indicator; expand triggers async fetch + spinner just on that schema row, not blocking entire drawer.
  4. **Existing `_struct_cache` shape** would need updating to support partial-population per schema (currently full-tree). Phase 6 D-46 single-bump epoch contract preserved.
  5. **Backwards compat**: small-DB users see no behavior change; large-DB users see fast-start with progressive expansion.
  Severity: **ARCHITECTURE CHANGE** — not a quick fix. v1.3 milestone candidate; needs full discuss + research + plan + review cycle.

- **Diagnostic gap: "loading..." has no timeout / error escape** (related):
  If structure RPC genuinely hangs (network failure, adapter crash mid-fetch), drawer shows "loading..." forever with no progress indicator, no timeout, no manual cancel. Should at minimum: (a) show elapsed time on the loading row after 10s, (b) offer manual cancel via key (`q` or `<Esc>`), (c) auto-fail with clear error after configurable timeout (default 5min).
  Severity: **MED** — degrades trust in the connection-only-drawer flow. v1.3 candidate alongside lazy-loading deepening.

### v1.3 rich table metadata (indexes, sequences, FKs, column annotations) — FEATURE

- **Drawer should expose schema/table internals like dbeaver** (`dbee/core/types.go`, `dbee/adapters/*.go`, `lua/dbee/ui/drawer/convert.lua`):
  Today's drawer renders only Name + Type per column under a table. No nullable indicator, no PK marker, no FK relation, no indexes, no sequences. Naveen wants:
  1. **Indexes** as a child folder under each table — list index names, types, columns covered.
  2. **Sequences** as a child folder under schema (sequences are schema-level, not table-level).
  3. **Columns folder** — already exists, but each column row should annotate: `[type] [NOT NULL] [PK] [FK→other_table.col]`.
  4. **FK navigation** — clicking on `FK→target` jumps drawer cursor to the referenced table+column.
  Required scope:
  - Go core: extend `Column` struct with `Nullable bool`, `IsPK bool`, `FKTarget *FKRef` fields. Extend `StructureType` enum with `StructureTypeSequence`, `StructureTypeIndex`.
  - Adapter SQL: each adapter needs new queries to populate these (Oracle: `all_constraints`/`all_indexes`/`all_sequences`, Postgres: `pg_constraint`/`pg_indexes`/`pg_sequences`, MySQL: `information_schema.*`, etc.).
  - New RPC endpoints: `DbeeListIndexes(connID, schema, table)`, `DbeeListSequences(connID, schema)`, `DbeeGetFKTargets(connID, schema, table)` (could fold into structure response).
  - Lua drawer rendering: new node types for index/sequence/fk-link; column row formatter to show annotations inline.
  - Click-to-navigate: drawer keymap dispatches FK target → expand referenced table → set cursor.
  - Backwards compat: adapters that don't implement metadata SQL return empty lists; UI gracefully omits annotations.
  Severity: **FEATURE** — full v1.3+ phase. Discuss + plan + multi-adapter execute. Pairs with #connection folder grouping for DBeaver-parity polish.

### v1.3 Oracle wallet auto-extract — FEATURE

- **dbee should accept `.zip` wallet path and transparently extract on connect** (`dbee/adapters/oracle*.go`):
  Oracle driver expects the EXTRACTED wallet directory (with `cwallet.sso`, `tnsnames.ora`, `sqlnet.ora`, etc.). Currently if user provides a `.zip` path, connect fails with `"open <path>.zip/cwallet.sso: not a directory"`. Workaround: user unzips manually before configuring.
  v1.3 fix: detect `.zip` extension on connect path, extract to a cache dir (`~/.local/share/dbee/wallets/<sha256(zip)>/`) lazily on first use, hand extracted dir to driver. Cache by content-hash so re-extracting unchanged wallets is skipped. Honor zip mtime invalidation.
  Severity: **FEATURE** — quality-of-life. Pairs with #connection folder grouping for dbeaver-parity polish.

### v1.3 connection folder grouping (dbeaver-style) — FEATURE

- **User can group connections into named folders** in the drawer, collapse/expand, move connections between folders.
  Surfaced 2026-04-30 during v1.3 live test. With many connections (~16 in test setup, growing) a flat list is awkward to navigate and find specific environments.
  Naveen's request: dbeaver-style. Examples — folder names like `dev`, `staging`, `prod`, `personal`, etc.
  Design considerations:
  - Persistence: where do folder definitions live? Options: (a) extend `connections.json` schema with optional `folder` field per conn (Phase 8 D-99 atomic-write contract preserved), (b) sidecar `folders.json` mapping `folder_name -> [conn_id, ...]`, (c) per-source override. Pick simplest — (a) `folder` string field on each connection row.
  - Drawer UI: folder nodes appear above ungrouped conns (or sorted alphabetically with conns). Collapsible like schema/table tree nodes. Persist expand/collapse state.
  - CRUD: keymaps to create folder, rename, delete (with reassignment of contained conns), move conn into/out of folder. Plus on-add wizard step "folder (optional)".
  - Filter integration: `/` filter should match conn name regardless of folder; matching results auto-expand parent folders.
  - Backwards compat: connections without `folder` field group under "Ungrouped" or just appear flat alongside folders.
  - Multi-source: each source can have its own folders, OR folders are global. Likely per-source.
  Severity: **FEATURE** — high user-value v1.3 candidate. Discuss + plan cycle. Pairs naturally with #2 schema allowlist for enterprise-DB UX polish.

### v1.3 schema allowlist (per-connection schema filter, dbeaver-style) — FEATURE

- **Per-connection schema allowlist on add/edit** (`lua/dbee/ui/wizard/*` for input, `lua/dbee/handler/*` for filter application, `lua/dbee/lsp/*` schema cache for downstream filtering):
  Enterprise DBs commonly have 100+ schemas where 95% are system/legacy/other-team noise (APEX_*, SYS, OPSS_*, ACTIVE_SET, SCHEMA_VERSION_REGISTRY, etc.). User cares about 1-5 application schemas. Currently dbee shows ALL schemas in completion + drawer + LSP, drowning the actual workspace in irrelevant rows.
  Naveen's proposal (matches dbeaver's "Active schemas" feature): wizard adds schema multi-select step; persists `schema_filter: ["MY_SCHEMA", "ANOTHER_SCHEMA"]` in connection JSON. All downstream consumers honor the filter:
  1. **Drawer**: render only filtered schemas (Phase 7 D-65 connection-only root → schema list under conn limited to allowlist)
  2. **LSP completion**: only return tables/columns from allowed schemas
  3. **LSP diagnostics**: only flag unknown tables in allowed schemas (or skip diagnostic entirely for tables in unfiltered schemas — design fork)
  4. **Schema cache**: only load filtered schemas to disk; faster cold start; less memory
  5. **Wizard**: discover-schemas step requires connection probe (one-time cost) before multi-select renders. Backed-off: if probe fails, allow manual entry of schema name patterns
  Patterns: support `["EXACT_NAME"]` exact match AND `["PREFIX_*"]` glob. dbeaver supports both.
  Implementation considerations:
  - Pairs naturally with lazy-loading deepening (above): if schemas-only initial fetch + filter applied, even cold start is fast for huge DBs
  - Backwards compat: connections without `schema_filter` field show all schemas (preserve current behavior)
  - Edit-existing-connection: wizard pre-populates current filter; user can add/remove
  - Reload + invalidation: schema_filter changes trigger structure refresh + LSP cache invalidation
  Severity: **FEATURE** — high user-value v1.3 candidate. Discuss + plan cycle. Likely highest-impact v1.3 deliverable for users on enterprise DBs.
