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

- **Connection source badge always shown even when single-source (visual noise)** (`lua/dbee/ui/drawer/convert.lua` per Phase 7 D-65):
  D-65 wording: "may display a lightweight source badge or suffix **for disambiguation**". Implementation emits `[<source_id>]` suffix on every connection row unconditionally. With a single-source setup (only `connections.json`), every row shows the same `[connections.json]` (truncated to `[connecti...]` in narrow drawer width) — pure noise, no disambiguation value.
  v1.3 fix: make badge conditional on `count(distinct source_id) > 1`. Single-source = clean flat list. Multi-source keeps the badge where it actually disambiguates. Threshold rule itself is a small discuss-phase decision (only-if-multi vs always-on toggle vs config option).

- **Drawer cold start lacks visual orientation** (cosmetic, related):
  Connection list starts flat from line 1. Old v1.0 had `connections.json` parent header providing instant context for "what am I looking at". v1.3 candidate: optional section header `Connections` line OR active-connection highlight at top. Lower priority than badge fix.

### v1.1 Phase 7 drawer filter regression (surfaced 2026-04-29 during v1.1 live test) — HIGH

- **`/` filter in drawer fails on connection-only root** (`lua/dbee/ui/drawer/menu.lua` filter path; Phase 4 D-31 + Phase 7 D-67/D-68 inheritance):
  Pressing `/` in the drawer (with no connection bootstrapped yet, just the flat connection list) emits "No cached connections available for filter" and exits filter mode. User can't reach a specific connection by typing.
  Likely root cause: Phase 7 connection-only-root rewrite kept Phase 4 D-31 filter contract that operates over `_struct_cache` (per-connection structure). On the connection list itself (no conn bootstrapped, `_struct_cache` empty), filter early-returns instead of falling back to filtering the visible connection rows by name.
  Expected: `/` filters whatever's currently visible — connection rows pre-bootstrap (by name + source badge), structure rows under expanded conn (by schema/table/column name).
  v1.3 fix: extend filter to operate on visible row set when `_struct_cache` empty for current root. Keep Phase 4 D-31 filter-exit contract intact. New unit test covering connection-list-only filter case.
  Severity: **HIGH** — primary navigation pattern broken. Workaround: scroll/jump manually (`gg`/`G`/`/conn_name` via vim-search not drawer filter).

### v1.1 Phase 8 wizard highlight regression (surfaced 2026-04-29 during v1.1 live test) — UNUSABLE on dark colorschemes

- **Wizard input field text invisible (text fg = bg)** (`lua/dbee/ui/wizard/*` or wherever Phase 8 compound modal lives):
  Typing into the Name field shows cursor moving but typed characters don't render. Type/Mode dropdown either doesn't render or renders text on dark-on-dark. Repro: open Add Connection wizard, type any name → cursor advances, text invisible.
  Likely root cause: nui.nvim Input/Select components in the wizard lack explicit `winhighlight` config. Inherits `Normal` over `NormalFloat` where fg/bg collide on user's dark colorscheme. Phase 8 D-XX may have defined highlight contract but implementation skipped applying it to child windows.
  v1.3 fix: explicit `winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder,..."` on each wizard Input/Select component. Test against multiple dark colorschemes (Naveen's current scheme + e.g. tokyonight, catppuccin-mocha, gruvbox-dark) before close.
  Severity: **HIGH** — wizard is a headline v1.1 deliverable but unusable on Naveen's daily colorscheme. Workaround: edit `connections.json` directly to add connections.

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
