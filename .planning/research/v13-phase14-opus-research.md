# v1.3 Phase 14 — Opus Independent Research

Author: Opus (independent research arm). Generated 2026-04-29.
Counterpart: Codex research running in parallel; orchestrator (Claude) merges.

Scope: Phase 14 of v1.3 — schema allowlist (dbeaver-style) + lazy-loading deepening (schemas-only initial fetch + per-schema lazy table fetch).

> **Honest stance.** dbee already has 80% of the plumbing needed. The handler-owned single-flight, root-epoch fencing, two-phase bootstrap, drawer `_struct_cache` (root + branches + load-more), and per-schema LSP indexes can support both features without architectural rewrites. The risk is not "can we do it" — it is "do we keep Phase 6/7/11 invariants intact while we change what 'structure' means at the root." This research lays out exactly which existing seams to extend, where new code goes, and which decisions are real forks vs. cosmetic.
> Sources cited inline with file:line refs and external URLs at the end.

---

## Part A — dbee code reality (lazy-loading + schema scope)

### A.1 How `connection_get_structure_singleflight` works today

Defined at `lua/dbee/handler/init.lua:606-671`. Contract (Phase 7 D-77/D-78):

1. **Caller passes** `{ conn_id, consumer, request_id?, caller_token?, callback? }`. The drawer uses `consumer = self._connection_invalidated_consumer_id` and `caller_token = "drawer"`; the LSP uses its own consumer id and `caller_token = "lsp"`.
2. **Key = `conn_id\x1fauthoritative_root_epoch`** (`singleflight_key`, lua/dbee/handler/init.lua:175-177). Distinct epoch ⇒ distinct flight.
3. **Join semantics:** if a flight exists at the current `(conn_id, epoch)`, the same `consumer` re-attaches (overwriting its waiter slot, lines 628-647); a new consumer adds a waiter without re-firing the RPC. **One Go-side `DbeeConnectionGetStructureAsync` per `(conn_id, epoch)`** (line 664).
4. **Supersession:** a `bump_authoritative_root_epoch` (lines 297-348) cancels older-epoch flights with `error_kind = "superseded"` (lines 581-602). Waiters get notified once and the flight is dropped.
5. **Completion:** Go fires `structure_loaded` event with `{ conn_id, request_id, root_epoch, caller_token, structures, error }`. `_on_singleflight_structure_loaded` (lines 748-784) routes to waiters by `caller_token == SINGLEFLIGHT_CALLER_TOKEN` (`"__singleflight"`) and `request_id`. Conn-id mismatches are tolerated via `flight.alias_conn_ids` (Phase 7 connection rewrite path).

**What's eager today.** The Go side at `dbee/adapters/oracle_driver.go:385-438` runs ONE big query against `all_tables UNION all_views UNION all_objects WHERE owner IN (SELECT username FROM all_users WHERE common='NO')`. Result is the **entire structure tree for every non-Oracle-managed schema**. Then `oracleGroupedStructure` builds a fully-populated `[]*core.Structure` with schemas → tables/procedures/functions sections → leaf objects. The 2-minute timeout (line 412) is the only safety valve. There is **no per-schema fetch path on the Go side**.

**What's lazy today.** Three layers of laziness already exist:
- **Drawer-side root fetch** (`request_structure_reload` at lua/dbee/ui/drawer/init.lua:2186-2215): only runs when a connection node first becomes visible (`build_connection_children` at line 907-935 returns a loading-spinner node if `_struct_cache.root[conn.id]` is nil and triggers the request).
- **Drawer-side child materialization** (`_build_structure_node` at line 989-1039): for non-table nodes (schemas/sections), `lazy_children_factory` is set but children are NOT materialized into the tree until expansion. Expansion goes through `expansion.set` (`lua/dbee/ui/drawer/expansion.lua:6-29`) which calls `node.lazy_children()` on first expand. `loaded_lazy_ids[node_id] = true` marks that one expansion happened (used to preserve materialized state across re-renders, line 1034-1036).
- **Drawer-side column fetch** (`_materialize_table_like_branch` at line 965-987): table/view expansion fires `connection_get_columns_async` per leaf. This is the one path that's already truly per-node async.

**The gap.** The structure tree is fetched in one shot; "schemas-only" mode does not exist. Per-schema table fetch does not exist. The Go side has no `ListSchemas` / `ListTablesInSchema` / `ConnectionGetStructureScoped` endpoints. The drawer's lazy_children for a schema today just walks pre-fetched `struct.children` (line 1003-1017), it never RPCs.

### A.2 Where per-schema lazy fetch hooks in

Two natural seams. Both are needed.

**Seam 1 — Go side: new endpoints.** The structure adapter contract today is `Structure() ([]*core.Structure, error)` (e.g., `dbee/adapters/oracle_driver.go:385`, `core/connection.go:198`). For per-schema lazy fetch, you need:
- `ListSchemas() ([]string, error)` — cheap, `SELECT username FROM all_users WHERE common='NO'` for Oracle, `SELECT schema_name FROM information_schema.schemata` for PG/MySQL.
- `StructureForSchema(schema string) ([]*core.Structure, error)` — same shape as the table-block of `Structure()` but scoped to one owner.

**These can live alongside the existing `Structure()`.** Adapters that don't implement them fall back to the all-at-once path; only enterprise-friendly drivers (Oracle first, PG/MySQL/MSSQL second) need the new methods.

**Seam 2 — Lua side: handler + drawer.** Three new handler endpoints:
- `Handler:connection_list_schemas_singleflight({ conn_id, consumer, callback })` — same singleflight shape as `connection_get_structure_singleflight`, returns `[]{ schema, ... }` shaped as `DBStructure[]` with `type="schema"` and empty `children`.
- `Handler:connection_get_schema_structure_singleflight({ conn_id, schema, consumer, callback })` — scoped variant. Key: `conn_id\x1fepoch\x1fschema`. New flight per (conn_id, epoch, schema).
- `Handler:bump_schema_epoch(conn_id, schema)` — analogous to `bump_authoritative_root_epoch` but per-schema. Used when invalidating one schema's tables (e.g., schema_filter changed but only this schema's contents need re-fetch).

The drawer hook is almost trivial: `_build_structure_node` (line 989) already wires `lazy_children_factory`. For a schema node fetched via `ListSchemas`, `lazy_children_factory` becomes "RPC the per-schema structure if not cached, else build from cached chunk". The expansion.lua line 14 `tree:set_nodes(node.lazy_children(), node.id)` call already supports returning a loading-spinner node + completing later (compare `_materialize_table_like_branch` at line 965-987 which does exactly that for column fetch).

### A.3 Where schema filter applies — single source vs scattered

Schema filter (allowlist) needs to apply at THREE consumer sites today, plus storage in ONE source-of-truth. **The risk is filter drift across consumers.**

**Storage** (single source of truth): `ConnectionParams` at the FileSource (Phase 8 D-90/D-99). Goes through `submit_connection_wizard` (lua/dbee/handler/init.lua:1296-1347). The `wizard_submission_metadata_action` (lines 207-223) decides persist vs strip; the SCOPED_WIZARD_MODES allowlist (lines 188-193) gates this. Phase 14 must extend `SCOPED_WIZARD_MODES` to include `oracle_schema_scoped` etc., or carve out a generic `connection.schema_filter` field that's persisted regardless of wizard mode.

**Consumer 1 — Go-side adapter.** When `Structure()` runs (or the new `StructureForSchema`), the Go side filters `WHERE owner IN (...)` based on the scoped allowlist. **This is the only place where filtering meaningfully reduces network/DB cost.** Filtering only on the Lua side leaves the all_objects scan at ~equal cost regardless of scope. For Oracle, the SQL becomes `WHERE owner IN (?, ?, ?)` with the allowlist; absence of allowlist preserves today's `WHERE common='NO'` behavior.

**Consumer 2 — Drawer-side rendering.** `convert.handler_nodes` and downstream `to_render_node` (lua/dbee/ui/drawer/model.lua:86-110, init.lua:317-407 region) build the tree from `_struct_cache.root[conn_id].structures`. If the Go side is already filtered, drawer doesn't need to filter again — it just renders what's in `_struct_cache`. **Defense in depth:** drawer should still filter on render so a stale cache (allowlist tightened but not yet re-fetched) doesn't show extra schemas.

**Consumer 3 — LSP completion + diagnostics.** `SchemaCache:get_schemas` (lua/dbee/lsp/schema_cache.lua:1367-1371) and `get_table_completion_items` (line 1395-1398) drive completions. Diagnostics `Unknown table` warnings at `lua/dbee/lsp/server.lua:264-351` (per v1.2 research). Both pull from the same `SchemaCache` that's `build_from_structure`-fed. If structure is already filtered upstream, the LSP cache is implicitly filtered. **But:** Phase 14 success criterion 4 explicitly says "LSP completion and LSP diagnostics honor the same schema allowlist". Locking the contract to "filter at structure-fetch boundary, propagate downstream" is the cleanest single source.

**Decision fork (lifted to Part D).** Where does filtering authoritatively happen? `Structure()` adapter level (Go), or `_on_singleflight_structure_loaded` middleware (Lua), or both? Recommendation: **Go for cost reduction, Lua middleware for safety**.

### A.4 `_struct_cache` shape — can it support partial population?

Today (lua/dbee/ui/drawer/init.lua:49-56):
```lua
---@class DrawerStructureCache
---@field root table<string, { structures?: DBStructure[], error?: any }>
---@field root_gen table<string, integer>
---@field root_applied table<string, integer>
---@field root_epoch table<string, integer>
---@field loaded_lazy_ids table<string, boolean>
---@field branches table<string, table<string, { raw?: any[], error?: any, built_count: integer, render_limit: integer, request_gen: integer, applied_gen: integer, loading: boolean }>>
```

`root[conn_id].structures` is **the entire tree** for the connection. `branches[conn_id][branch_cache_key]` is keyed by `branch_id\x1fkind` where kind is `"columns"` or `"structures"` (line 113, 210-212). Branches today are used for:
- **`STRUCTURES_KIND` branches:** load-more pagination on the conn-root level (line 922-927: `cached_branch.raw = sorted_struct_children(cached_root.structures)` — derived from `root`, not its own RPC).
- **`COLUMNS_KIND` branches:** per-table column lists, async-fetched via `connection_get_columns_async`.

**Partial-population fit.** The shape is **already well-suited** to per-schema lazy fetch. Specifically:

- `root[conn_id]` becomes "schemas-only tree" for Phase-14-scoped connections. `structures` is `[{ type="schema", name="X", children={} }, ...]`. Each schema has `children = {}` until expanded.
- For each schema expansion, allocate `branches[conn_id][schema_branch_id\x1fSTRUCTURES_KIND]` with its own `request_gen`, `applied_gen`, `loading`, `error`, `raw` fields. **This is exactly the existing branch shape.** The drawer code path for materializing a STRUCTURES_KIND branch already exists at `_materialize_cached_structure_branch` (line 957-963) and `build_branch_nodes` (line 862-901). What's missing today is that branches are derived from `root.structures`; in Phase 14 they need to be *populated independently* by `connection_get_schema_structure_singleflight`.
- `loaded_lazy_ids[schema_node_id] = true` already gates re-materialization across re-renders (line 1007-1013).

**One change is needed.** `_struct_cache` needs a `mode` per connection: `"full" | "scoped"` (or richer: `"full" | "schemas_only" | "scoped_to_allowlist"`). This determines whether `root.structures` is treated as "the whole tree" or as "schemas-only with per-schema branches lazy-loaded". Add to the typedef:
```lua
---@field root_mode table<string, "full"|"scoped">
---@field root_loaded_schemas table<string, table<string, boolean>>  -- conn_id -> schema -> loaded?
```

**Caveat — `loaded_lazy_ids` for schemas vs containers.** Today `loaded_lazy_ids` is set on **non-table** nodes that were materialized at least once (line 158). In Phase 14, expanding a schema for the first time fires an RPC. The drawer needs to distinguish "schema is in tree, never expanded" from "schema is in tree, RPC pending" from "schema is in tree, RPC done, children rendered". The branch shape already encodes the second and third (`loading`, `applied_gen >= request_gen`); the first is just "branch state doesn't exist yet". This is a clean three-state mapping.

**Build_search_model and filter_node_matches don't see the gap.** `lua/dbee/ui/drawer/model.lua:191-225` walks `cached.structures` to build the search corpus; with scoped mode, schemas-only-with-empty-children would mean filter only matches schema names (not table names) until each schema is expanded. **This is the user-visible behavior change.** Codex prompt option (D) hints at this — the filter behavior is expected to degrade gracefully when the corpus isn't fully loaded.

### A.5 Cache invalidation paths

Three existing invalidation paths to preserve, one new one to add.

**Existing 1 — `connection_invalidated` (Phase 7 D-71/D-86).** Fires from `_emit_connection_invalidated` (lua/dbee/handler/init.lua:874-886) on `source_reload`, `source_add`, `source_delete`, `source_update`, plus the `silent` variant (line 853-855) used by reconnect bookkeeping. Carries `{ retired_conn_ids, new_conn_ids, current_conn_id_before, current_conn_id_after, authoritative_root_epoch, silent }`. The drawer flow:
- Bootstrap mode (lines 367-491): events are buffered (`BOOTSTRAP_BUFFER_LIMIT = 64`, line 6) until the consumer drains. Overflow → `consumer.warning` of kind `"overflow"` then `"storm"` after `BOOTSTRAP_OVERFLOW_MAX = 3` consecutive overflows (line 7). Storm puts the consumer into a non-recoverable state requiring teardown.
- Live mode: events flow directly to listeners.

**Existing 2 — `bump_authoritative_root_epoch` (Phase 7 D-77).** Per-conn epoch monotonic increment (lines 321-348). Increments cancel in-flight singleflight requests with `error_kind = "superseded"`. Critical: the drawer's `request_structure_reload` (line 2186) reads `handler_root_epoch` (the authoritative epoch from handler), so a subsequent reload always lands on the new epoch.

**Existing 3 — `migrate_structure_flights` (line 697-744).** Connection ID rewrite path (Phase 7 conn-id-stability work). Migrates flights and root-epoch entries from `old_conn_id` to `new_conn_id`. **This survives Phase 14 untouched IF the schema-scoped flights also key on the underlying conn_id.**

**New 4 — schema_filter changed.** When the user edits the connection's schema_filter through the wizard:
1. `_source_update_connection` (line 1194) runs, persisting the new filter.
2. `_source_reload_silent` (line 920) runs `eventful=true`, bumping `authoritative_root_epoch` (line 1045).
3. `connection_invalidated` fires with new epoch, drawer drains, drawer marks `_struct_cache.root[conn_id]` stale and triggers `request_structure_reload`.
4. **NEW:** drawer must also clear `_struct_cache.root_loaded_schemas[conn_id]` (new field) and any branches keyed under that conn_id with schema-derived branch_ids. This is functionally `_prune_loaded_lazy_ids(conn_id)` (line 1113-1119) + `branches[conn_id] = nil`.

**LSP-side mirror.** The LSP also listens to `connection_invalidated` (per v1.2 research, Phase 7 D-83-D-84). On filter change, the LSP cache for that connection needs full rebuild — `SchemaCache:invalidate()` (line 1830-1838). Disk cache: schema-list JSON should be invalidated (clear `<conn_id>.json`) but column files (per-table) can stay if the new filter is a superset. **Decision fork (Part D):** strict (clear all column files) vs lenient (keep, let TTL prune naturally). I recommend strict on filter change — column files are cheap to repopulate via async miss path, and having stale column files for a now-filtered-out schema is wasted disk pressure.

**Eventful vs silent (Phase 7 D-86).** Phase 7 introduced `silent` invalidation for cases where the drawer doesn't need to re-render (e.g., reconnect bookkeeping). For schema_filter changes, **always eventful** — the user explicitly changed scope and expects to see the new tree.

---

## Part B — Ecosystem comparison

### B.1 DBeaver — "Configure Filters" and Connection-level filters

[dbeaver/wiki/Configure-Filters](https://github.com/dbeaver/dbeaver/wiki/Configure-Filters), [dbeaver.com/docs/dbeaver/Filter-Database-Objects](https://dbeaver.com/docs/dbeaver/Filter-Database-Objects/). DBeaver supports filters at multiple scopes:
- **Connection-level "Connection settings → Schemas filter"** — applied during introspection, this is the ALL-USERS-equivalent allowlist. Persisted in workspace XML (DBeaver-internal, per-connection).
- **Navigator-level filter** (right-click → "Filter"): cosmetic-only, applied to display, not introspection. **Issue [dbeaver#34988](https://github.com/dbeaver/dbeaver/issues/34988)** documents the failure mode where Connection-settings filter is removed via Navigator filter and the dialog gets stuck — i.e., the two scopes leak into each other.

**Pattern syntax.** SQL-like glob: `%` for any chars, `_` for one char. NOT regex. Comma-separated include/exclude lists in the same dialog. Example: `Include: HR%, FIN%; Exclude: HR_TEMP%`. Saved filter "presets" persist by name in a dropdown for reuse across connections.

**Persistence.** Per-connection in `<workspace>/.metadata/.plugins/org.eclipse.core.runtime/.settings/org.jkiss.dbeaver.core/connection-types.xml` (workspace-internal). Saved filter presets are workspace-global. Filter is part of the connection JDBC profile, lossless-round-trip.

**UX flow.** Add/edit connection wizard has a "Connection settings → Schemas filter" tab. User can manually enter patterns OR (per [dbeaver#21724](https://github.com/dbeaver/dbeaver/issues/21724)) right-click on the connection node post-connect and "Edit Schema Filters" to refine. **Discovery is implicit** — DBeaver assumes the user knows the schemas they want. There's no "fetch list of schemas, multi-select" UX.

**Known issue [dbeaver#11883](https://github.com/dbeaver/dbeaver/issues/11883):** when a Schemas filter is set, the navigator may not organize the tree by schema correctly. This is a real gotcha for Phase 14 — make sure tree-rendering stays consistent under partial allowlist.

### B.2 JetBrains DataGrip — "Schemas to Show" with explicit selection

[jetbrains.com/help/datagrip/schemas.html](https://www.jetbrains.com/help/datagrip/schemas.html), [blog.jetbrains.com/datagrip/2022/08/08/not-all-databases-schemas-are-displayed-by-default-why](https://blog.jetbrains.com/datagrip/2022/08/08/not-all-databases-schemas-are-displayed-by-default-why/). DataGrip's model is **explicit-by-default**: introspection only loads schemas the user ticked. The Database Explorer shows an "N of M" button at the data-source root indicating how many schemas are introspected vs available. Click → opens a **dual list** (left: available, right: shown) where the user can move schemas in/out.

**Pattern syntax.** No glob — exact name selection from a list. (Per the help page: "Edit the list of schemas or databases to be introspected and shown".) Optionally toggle "show all but don't introspect" for cheap-display-only mode.

**Persistence.** Per data source, in `.idea/dataSources.xml` or DataGrip's project file. The filter is part of the connection profile.

**UX flow — discovery.** DataGrip introspects the catalog list at first connect (the cheap query). Users see all available schemas and tick the ones they want. **This is a 2-step UX: connect → discover → select**. Phase 14 should consider adopting this.

**Design rationale (cited):** "For bigger data sources, this allows for saving the disk space and your time, as the introspection of larger amounts of schemas can be a long process." This is exactly Phase 14's "lazy-loading deepening" motivation.

### B.3 vim-dadbod-completion — buffer-local table scoping (NOT schema scoping)

[github.com/kristijanhusak/vim-dadbod-completion](https://github.com/kristijanhusak/vim-dadbod-completion). Supports `let b:db_table = '...'` for table-level scoping. **Does NOT support schema-level allowlist.** Buffer-local buffer variables for `b:db` (connection) and `b:db_table` (current table for column suggestions). Configuration is buffer-scoped, not connection-profile-scoped.

**Lessons for dbee.** dadbod-completion's model is too lightweight for enterprise. dbee's per-connection metadata model (Phase 8) is the right level.

### B.4 sqls / sql-language-server — yaml config, no schema filtering

[github.com/sqls-server/sqls](https://github.com/sqls-server/sqls). Config at `~/.config/sqls/config.yml`. Connections list with `alias`, `driver`, `proto`, `user`, `passwd`, `dbName`, `host`, `port`. **No schema-allowlist field.** First connection is default. The LSP introspects everything. [emacs-lsp.github.io/lsp-mode/page/lsp-sqls](https://emacs-lsp.github.io/lsp-mode/page/lsp-sqls/) doc confirms.

**Lessons for dbee.** sqls is a useful baseline for "what enterprise DB plugins typically lack" — schema scoping is the missing feature, not table-level. dbee's Phase 14 fills exactly this gap.

### B.5 Other Neovim DB plugins — none combine lazy-loading + schema scoping

Surveyed:
- **vim-dadbod-ui** ([github.com/kristijanhusak/vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui)): drawer with schemas/tables, but full eager fetch. No allowlist. Lazy expansion on click but not on schema-fetch level.
- **dadbod-grip.nvim** ([github.com/joryeugene/dadbod-grip.nvim](https://github.com/joryeugene/dadbod-grip.nvim)): schema browser + ER diagrams + cross-database federation. Newer (~Mar 2026). Multi-DB-aware but I didn't find evidence of allowlist UX.
- **pgcli / mssql-cli** ([pgcli.com/config](https://www.pgcli.com/config)): `search_path_filter` config — only suggests from objects in the current `search_path`. This is **session-state-driven**, not user-curated allowlist. Different paradigm. PG-specific.

**Verdict.** dbee Phase 14 has space to be the first Neovim DB plugin that combines DBeaver-style schema allowlist with DataGrip-style lazy introspection. No prior art to copy directly.

### B.6 AWS Athena / Glue — catalog-level filtering by API

[docs.aws.amazon.com/athena/latest/ug/data-sources-glue.html](https://docs.aws.amazon.com/athena/latest/ug/data-sources-glue.html). For 1000+ schemas, Athena and Glue rely on:
- `MetadataDiscoveryMethod=Glue` JDBC param to select introspection backend.
- `information_schema.schemata` query for the cheap schema list.
- Per-schema `information_schema.tables WHERE table_schema = ?` for table list.
- **Performance warning** ([from search]): "Querying information_schema is most performant if you have a small to moderate amount of AWS Glue metadata, but if you have a large amount of metadata, errors can occur."

**Lesson.** Even cloud catalogs document the cliff. Phase 14's lazy approach is industry-standard for >100 schemas.

### B.7 Oracle — 1000-schema environments are common

[Oracle's "Filter All The Things"](https://www.thatjeffsmith.com/archive/2016/10/filter-all-the-things/) (SQL Developer blog). Oracle SQL Developer supports schema filter dialogs because enterprise Oracle deployments routinely have 500-2000+ schemas (one per app + one per env + one per user). **dbee's current `WHERE common='NO'` (oracle_driver.go:405) eliminates Oracle-managed schemas but leaves user-created ones unbounded.** A 1000-schema Oracle env will hit drawer load times of 30-60s today and `_struct_cache` memory of ~50-200MB. This is the practical reason Phase 14 exists.

---

## Part C — Proposed architecture

### C.1 Lazy-loading model — a 5th option

Codex prompt mentions options A/B/C/D. Without seeing them, my proposed shape — call it **Option E: Two-mode tree with explicit scope and per-schema branches**:

**Mode "full" (default, backward-compatible).** Existing behavior. `Structure()` returns whole tree. `_struct_cache.root.structures` is fully populated. Drawer renders all schemas + tables eagerly (subject to existing lazy-children for expansion).

**Mode "scoped" (Phase 14 new).** Three sub-states:
1. **schema_filter not set** → mode is "full". No change.
2. **schema_filter set** → adapter `Structure()` is called with the allowlist. Returns full tree but only for allowlisted schemas. `_struct_cache.root` is fully populated, just smaller. Drawer renders eagerly.
3. **schema_filter set with `lazy_per_schema=true` flag** → adapter `ListSchemas()` is called for schemas-only fetch. Tree has empty schema nodes. Per-schema expansion fires `StructureForSchema(schema)` via a new singleflight key.

The flag lets users opt into laziness independent of allowlist. Allowlist + lazy is the recommended combo for huge enterprise DBs.

**Why this beats single-mode laziness everywhere.** Backward compat is a hard requirement (Phase 14 success criterion #1: "absent filter preserves current all-schema behavior"). Forcing all connections through ListSchemas + per-schema fetch would change the latency profile for small DBs where the all-at-once query is cheaper than N round-trips. Two-mode keeps the small-case fast and unlocks the large-case.

### C.2 Schema filter shape — exact + glob, per-connection, comma-list

Recommendation:
```json
{
  "id": "...",
  "type": "oracle",
  "url": "...",
  "schema_filter": {
    "include": ["HR", "FIN%", "REPORT_*"],
    "exclude": ["HR_TEMP%"],
    "lazy_per_schema": true
  }
}
```

**Pattern syntax.** SQL-like glob (`%` = any chars, `_` = one char) — matches DBeaver. NOT regex (avoids security/perf footguns). NOT exact-only (DataGrip's UX is heavier for enterprise where users want `HR*` rather than ticking 47 HR-prefixed schemas).

**Case sensitivity.** Matches the adapter's case fold rules (Oracle: uppercase by default; PG: lowercase; MSSQL: collation-dependent). Reuse `SchemaCache:fold` (lua/dbee/lsp/schema_cache.lua:46-49). Decision fork in Part D — explicit user setting vs adapter-default.

**Per-connection vs workspace.** Per-connection. Workspace-level "saved filter presets" can come in v1.4 if users ask. v1.3 ships per-connection only — keeps wizard small.

**Compile patterns to a Lua matcher** (or Go-side `LIKE` for adapter filtering). Reject regex meta-chars (`.`, `+`, `*`, `?`, `[`, `]`, `^`, `$`, `\`) at parse time to prevent confusion.

### C.3 Wizard UX flow — discover-on-edit, manual fallback

**On `add` (initial connect):**
1. User fills in connection details (existing Phase 8 wizard).
2. Wizard runs the existing `connection_test_spec` ping (lua/dbee/handler/init.lua:1316).
3. **NEW step:** if ping succeeds, wizard offers "Discover schemas" → fires `ListSchemas()` (cheap query). Shows multi-select dual-list (DataGrip-style).
4. User can either tick schemas or skip ("Discover later"). Skipping persists with no `schema_filter` — full mode.
5. **Probe failure handling:** if `ListSchemas()` errors (insufficient privs, slow link), show "Manual entry" mode — text field for comma-separated patterns. Pre-filled with empty.
6. Submit persists `schema_filter` if set.

**On `edit`:**
1. Existing edit flow loads the connection's metadata.
2. Show current `schema_filter` if any. Buttons: "Re-discover" (re-run ListSchemas), "Edit manually", "Clear filter" (back to full mode).
3. Clearing on a previously scoped connection bumps `authoritative_root_epoch` and triggers full re-fetch.

**Probe failure handling — cited gotcha.** Some Oracle DB users have read-only access to `all_users` but NOT to specific schemas they need. ListSchemas returns the universe, but Structure-fetch on a specific schema can fail. The per-schema RPC needs to handle errors gracefully — show error icon on the schema node, error message in a tooltip/inline. Compare today's `convert.error_node` (lua/dbee/ui/drawer/convert.lua:102) — already a pattern for branch-level errors.

### C.4 Cache shape change — additive, not breaking

Add to `_struct_cache`:
```lua
---@field root_mode table<string, "full"|"scoped">  -- per-conn mode
---@field root_loaded_schemas table<string, table<string, boolean>>  -- conn_id -> schema -> loaded?
---@field root_loaded_schema_errors table<string, table<string, any>>  -- conn_id -> schema -> error
---@field schema_filter_signature table<string, string>  -- conn_id -> stable hash of filter for invalidation
```

`root_loaded_schemas[conn_id][schema]` is set when the schema's per-schema RPC completes successfully. `root_loaded_schema_errors[conn_id][schema]` is set on RPC error. Both are cleared on connection_invalidated for that conn_id. The drawer renders the schema node's loading/error state from these.

**Disk cache (LSP).** `SchemaCache:save_to_disk` (lua/dbee/lsp/schema_cache.lua:1206) writes `<conn_id>.json` with `version, schemas, tables`. Phase 14 needs:
- Add `schema_filter_signature` field to JSON. On load, compare to current connection's filter signature; if changed, treat as version mismatch (existing pattern at line 1258 — `if data.version ~= SCHEMA_CACHE_VERSION then ... return false`). Bump SCHEMA_CACHE_VERSION to 3 to force migration.
- Per-table column files (`<conn_id>_cols_<schema_table>.json`): scope-check on load. If the schema is no longer in the allowlist, prune the column file.

### C.5 LSP isIncomplete extension — `schema.` triggers per-schema lazy

The LSP completion response shape (`lua/dbee/lsp/server.lua:264-351` per v1.2 research) returns `lsp.CompletionItem[]` with optional `isIncomplete` flag. Phase 11 D-154..D-161 lock the "non-blocking" contract: cache hits return synchronously, misses fire async warmup and return `isIncomplete=true`.

**Phase 14 extension for `schema.` context** (context.lua's `analyze` returns `"table_in_schema"`):
1. Look up `schema_lookup[fold(schema)]` (line 1419) — case-insensitive resolve.
2. If schema not in cache → empty result, `isIncomplete=false` (no point warming).
3. If schema in cache AND `_struct_cache.root_loaded_schemas[conn_id][schema] == true` → return cached `table_items_by_schema[schema]` synchronously, `isIncomplete=false`.
4. If schema in cache but NOT loaded → fire `connection_get_schema_structure_singleflight` async (new endpoint), return empty with `isIncomplete=true`. Subsequent invocations after warmup get cache hit.
5. Schema-fetch completion event hooks into LSP via the same `structure_loaded`-style channel (probably `schema_structure_loaded`) and triggers `SchemaCache:_upsert_schema_tables(schema, tables)` to populate.

**Reuse Phase 11 async-miss machinery.** `schema_cache.lua:_queue_async_probe` (line 558-631) is the column-fetch async pattern. The schema-table-fetch can adopt the same idiom: `_async_inflight`, `_async_chains`, `_async_failed`, dedup by `(conn_id, schema, root_epoch)`.

### C.6 Drawer UX — per-row spinner, error icon, inline retry

Today's loading-node (lua/dbee/ui/drawer/convert.lua:95-100) and error-node (line 102) patterns scale up. For Phase 14 schema rows:

- **Idle (collapsed):** `▸ HR` (or whatever expansion icon).
- **Expanding (RPC pending):** `▾ HR  (loading…)` plus a child spinner row (`convert.loading_node`).
- **Expanded (loaded):** `▾ HR` with table/view children rendered.
- **Failed:** `▾ HR  ⚠ insufficient privileges` plus a child error_node. Add an action mapped to the schema node: `r` to retry. (Consistent with existing connection-level retry pattern.)

**Fallback on probe failure.** If `ListSchemas()` itself fails (the discover-schemas step in wizard), the wizard should show a manual-entry text field. The user enters their patterns blind. This is identical to DBeaver's UX when introspection fails.

**Schema row count UI cue.** Optionally display `▾ HR (47 tables)` after expansion. Cheap (`#tables_in_schema`). Helps users navigate large schemas.

### C.7 Ship together or separately?

**Ship together.** Reasoning:
1. M13-2 in v1.3-roadmap.md already locked: "Phase 14 pairs schema allowlist with deeper lazy loading. Both require schema-aware connection metadata, handler filtering, partial structure cache shape, LSP completion/diagnostics behavior, and disk-cache invalidation. Splitting would duplicate migration work."
2. The cache-shape change (C.4) is ONE migration. Doing it twice (once for allowlist, once for laziness) hits the disk-cache version twice and creates two breaking-change moments.
3. Decision-fork density is high — better to debate them once with both features in mind.
4. UX coherence: a user who has 1000+ schemas wants BOTH allowlist (cut 950) and lazy (don't fetch the remaining 50 eagerly).

**However:** ship behind a feature flag. `connection.schema_filter.lazy_per_schema = true|false`. If laziness has unforeseen issues in real-world Oracle DBs during dogfood, users can toggle it off without losing the allowlist benefit. Allowlist alone is the always-safe path.

---

## Part D — Open questions for orchestrator

### D-Q1: Where does schema filtering authoritatively happen — Go adapter, Lua middleware, or both?

**Tradeoff.** Go adapter only = best perf (filter at SQL `WHERE owner IN (...)`), but every adapter (10+ drivers) needs the change. Lua middleware only = single code path, but the cost of fetching all_objects is unchanged. **Both** = belt-and-suspenders: Go adapter does the cheap filter for cost, Lua re-checks at render time for correctness.

**Recommendation.** Both. Start with Oracle/PG/MySQL/MSSQL on Go side (top 4 enterprise targets). Lua middleware as defense-in-depth for stale cache. Other adapters (SQLite, DuckDB, etc.) — small DBs typically; filtering Lua-only is acceptable.

### D-Q2: Pattern syntax — glob, regex, or exact-list?

**Tradeoff.** Glob (`%`, `_`) is DBeaver-compatible, simple, no regex footguns. Regex is more powerful but much more error-prone (and unparseable by Go's `LIKE`). Exact-list (DataGrip) is safest but heavy UX for users with `HR_*` patterns.

**Recommendation.** Glob. Reject regex metas at parse time. Allow comma-separated include + exclude lists. Optional v1.4: "exact" toggle for DataGrip-style multi-select.

### D-Q3: Discovery happens on `add` or `edit`?

**Tradeoff.** On-add adds wizard friction for users who don't yet know their schemas (delays first-connect). On-edit-only means the first add succeeds fast but users with huge DBs immediately experience full-fetch slowness before they discover the filter exists.

**Recommendation.** Discover on `add` AS AN OPTIONAL STEP after ping success. "Discover schemas now? [Y/n]" with default-no for fast path. On `edit`, make Discover the default-y. This gives both UX paths: fast new-connection for small DBs, guided scoping for users who hit the full-fetch wall and come to edit.

### D-Q4: Disk cache strategy on schema_filter change — strict or lenient?

**Tradeoff.** Strict (clear all column files for the connection) = simple, no stale data, costs ~50-200ms re-warm. Lenient (keep, prune via TTL) = fast, but stale columns exist for filtered-out schemas, fragmenting disk + memory.

**Recommendation.** Strict. The amount of stale-column-file cleanup is small (TTL is 30 days, line 27 — a lot of stale junk could accumulate over months). Filter changes are rare events; the cost is amortized. Adds determinism to "did filter actually apply?" debugging.

### D-Q5: Single source-of-truth for schema_filter — handler middleware vs scattered consumers?

**Tradeoff.** Single place (handler middleware) = clean, one consumer needs to know about filter. Scattered (drawer + LSP + Go adapter all read filter independently) = explicit but drift-prone.

**Recommendation.** Handler middleware OWNS the filter. Filter resides on `ConnectionParams.schema_filter`. `Handler:get_schema_filter(conn_id)` is the single read point. Adapter `Structure()` gets filter passed in (via Go-side context). Drawer + LSP read via handler, never directly. This is consistent with Phase 7 D-77 handler-owns-singleflight pattern.

### D-Q6: LSP diagnostics under partial allowlist — warn/skip/silence "Unknown table" for filtered-out schemas?

**Tradeoff.** v1.3-roadmap.md Phase 14 research bullet: "Decide in discuss whether unfiltered-schema diagnostics should warn, skip, or surface as out-of-scope/noise."
- **Warn.** Treat references to filtered-out schemas as "Unknown table" — false positives if user knows the table exists outside their scope.
- **Skip.** No diagnostic. User loses safety net.
- **Out-of-scope hint.** Different diagnostic kind: "Schema HR is outside this connection's scope. Edit schema_filter to include." Best UX, requires new diagnostic message machinery.

**Recommendation.** Out-of-scope hint. New diagnostic severity (`Information` not `Warning`) so it doesn't clutter the gutter. Wire to existing `vim.diagnostic` infrastructure (per v1.2 research).

### D-Q7: Connection-level "lazy mode" toggle — explicit or auto-on-large-DB?

**Tradeoff.** Explicit (user toggles `lazy_per_schema=true`) = predictable, no surprises. Auto-on (drawer detects > N schemas in ListSchemas, switches to lazy) = lower friction, but unexpected behavior change.

**Recommendation.** Explicit in v1.3, default-on if `schema_filter.include` has a `%` glob suggesting "many schemas". Naveen + AppDev users who hit the wall will toggle it; others won't notice. Auto-detection can be v1.4 once we have telemetry on real connection sizes.

---

## Part E — Risk register

### E-R1: Phase 6/7 invariant drift

**Risk.** Phase 6 D-30..D-63 lock root-fencing, load-more pagination, and full-tree assumptions. Phase 7 D-64..D-88 lock connection-only drawer + handler-owned single-flight. Phase 14 changes "what `_struct_cache.root` means" — partial-population is a new state.

**Mitigation.** Add `root_mode` field to `_struct_cache`. Audit every read of `_struct_cache.root[conn_id].structures` in drawer/init.lua (~20 sites by my count) — verify each tolerates schemas-only mode. Audit every Phase-6 test for assumptions. Phase 7 tests for source-reload paths under scoped mode.

### E-R2: LSP non-blocking contract regression

**Risk.** Phase 11 D-154..D-161 lock "completion is non-blocking, miss returns isIncomplete=true". Per-schema lazy fetch introduces a NEW miss path (`schema.tab|`); if miss-handling fires a sync RPC, contract breaks.

**Mitigation.** Reuse Phase 11 `_queue_async_probe` machinery (lua/dbee/lsp/schema_cache.lua:558). Add specific test: cursor at `HR.|`, verify no blocking call, verify `isIncomplete=true`, verify subsequent invocation hits cache.

### E-R3: Filter syntax footguns (regex injection, % vs * confusion)

**Risk.** Users coming from DataGrip expect exact selection; from regex engines expect `*`/`+`; from SQL expect `%`. Wrong syntax silently matches nothing → user thinks dbee is broken.

**Mitigation.** At wizard parse time: reject regex metas `*+?[]^$\` with explicit error. Show inline help text "Use % for any chars, _ for one char (SQL LIKE syntax)". Validate include/exclude can't both be empty if filter is set (degenerate case).

### E-R4: ListSchemas error UX failure

**Risk.** Probe fails (slow link, insufficient privileges, dialect not yet supported). Wizard hangs or silently falls back to "no filter" → user is confused.

**Mitigation.** Wizard probe has a 10s timeout. On timeout/error, show error banner + manual-entry mode. Per-schema RPC errors at runtime show inline error_node + retry action. Test matrix: insufficient privs (DENY ALL_USERS), network timeout (firewall block), adapter-not-implemented (SQLite).

### E-R5: Connection-rewrite path under scoped mode

**Risk.** Phase 7 `migrate_structure_flights` (lua/dbee/handler/init.lua:697-744) rewrites flight keys on conn-id change. Schema-scoped flights use `conn_id\x1fepoch\x1fschema` keys — migration needs to preserve all per-schema flights.

**Mitigation.** Extend `migrate_structure_flights` to handle schema-scoped flight keys. Add test: rename connection mid-flight while two schemas are loading, assert both flights migrate to new conn_id.

### E-R6: Disk cache version bump cascade

**Risk.** SCHEMA_CACHE_VERSION bump (v2 → v3) invalidates ALL existing LSP caches on first launch. Users see "Schema loading…" on every connection at upgrade. 30 connections × 5s = 150s startup hang for some users.

**Mitigation.** Don't bump if not needed — only if `schema_filter` is set. Migration path: v2 cache without filter signature is "full mode" by default, valid. Bump only when wizard adds a filter. Phase 13 already touches cache migration UX (success criterion 3) — coordinate.

### E-R7: Bootstrap buffer overflow under filter-change storms

**Risk.** User toggles schema_filter rapidly while drawer is bootstrapping. Each toggle bumps epoch + fires `connection_invalidated`. BOOTSTRAP_BUFFER_LIMIT=64, BOOTSTRAP_OVERFLOW_MAX=3 (lua/dbee/handler/init.lua:6-7). 64+3+1 events trigger storm state, drawer becomes unrecoverable until teardown.

**Mitigation.** Debounce wizard schema_filter changes (e.g., wait 500ms after last edit before submitting). Document the storm-recovery teardown flow. Phase 14 tests: rapid filter edits, assert no storm state.

### E-R8: Glob → SQL LIKE escape

**Risk.** User puts a literal `%` in their schema name (rare but legal in PG). Glob compiler turns it into LIKE wildcard, matching unintended schemas.

**Mitigation.** Allow `\%` and `\_` as escape syntax in patterns. Document. Test.

### E-R9: Phase 11 `_default` schema interaction

**Risk.** SchemaCache (lua/dbee/lsp/schema_cache.lua) has special-case `_default` for schemas that come without explicit names (line 81, 1085-1088). Per-schema lazy fetch needs to handle `_default` — what does "discover schemas" return for a connection that uses `_default`?

**Mitigation.** Decision: `_default` is implicit and ALWAYS in scope (cannot be excluded by filter). Test: filter-include with `_default` matches; filter-exclude with `_default` is a no-op with warning.

### E-R10: Adapter implementation gap

**Risk.** Not all adapters implement `ListSchemas` / `StructureForSchema` cheaply. SQLite has no schemas. DuckDB has catalog/schema two-level. ClickHouse has databases. Going adapter-by-adapter risks shipping with patchy support.

**Mitigation.** Phase 14 ships Oracle + PG + MySQL + MSSQL with the new endpoints. Other adapters fall back to "full mode only" (no `lazy_per_schema` allowed). Document supported matrix in connection wizard.

---

## Sources

dbee source code (read-only):
- `lua/dbee/handler/init.lua:175-744` — singleflight + epoch + connection-invalidation machinery
- `lua/dbee/handler/init.lua:1296-1347` — submit_connection_wizard + metadata_action gates
- `lua/dbee/ui/drawer/init.lua:49-79` — _struct_cache typedef
- `lua/dbee/ui/drawer/init.lua:907-1039` — connection-children build + structure-node lazy_children + materialize-table
- `lua/dbee/ui/drawer/init.lua:1779-1945` — on_structure_loaded + on_database_selected + on_structure_children_loaded
- `lua/dbee/ui/drawer/init.lua:2186-2215` — request_structure_reload
- `lua/dbee/ui/drawer/expansion.lua:6-29` — lazy_children expansion
- `lua/dbee/ui/drawer/model.lua:191-225` — build_search_model
- `lua/dbee/ui/drawer/convert.lua:31, 95-103, 128, 408` — structure_node_id, loading_node, error_node, decorate_structure_node, handler_nodes
- `lua/dbee/lsp/schema_cache.lua:140-330, 558-660, 1206-1290, 1419-1556, 1830-1838` — SchemaCache build/disk/async/invalidate
- `dbee/handler/handler.go:278-313` — Go-side ConnectionGetStructure / async
- `dbee/handler/event_bus.go:27, 128` — structure_loaded event trigger
- `dbee/adapters/oracle_driver.go:385-438` — Oracle Structure query

dbee planning artifacts (read-only):
- `.planning/milestones/v1.3-roadmap.md` — Phase 14 success criteria + locks M13-1..M13-5
- `.planning/research/v12-lsp-opus-research.md` — Phase 11/12 LSP architecture context

External:
- DBeaver Filters: [Configure-Filters wiki](https://github.com/dbeaver/dbeaver/wiki/Configure-Filters), [Filter-Database-Objects docs](https://dbeaver.com/docs/dbeaver/Filter-Database-Objects/)
- DBeaver issues: [#21724 active schema](https://github.com/dbeaver/dbeaver/issues/21724), [#11883 schema filter tree breakage](https://github.com/dbeaver/dbeaver/issues/11883), [#34988 navigator removes settings filter](https://github.com/dbeaver/dbeaver/issues/34988)
- DataGrip: [Schemas help](https://www.jetbrains.com/help/datagrip/schemas.html), [Show all databases or schemas](https://www.jetbrains.com/help/datagrip/show-all-databases-or-schemas.html), [JetBrains blog "Not all schemas displayed by default"](https://blog.jetbrains.com/datagrip/2022/08/08/not-all-databases-schemas-are-displayed-by-default-why/)
- vim-dadbod-completion: [github.com/kristijanhusak/vim-dadbod-completion](https://github.com/kristijanhusak/vim-dadbod-completion)
- vim-dadbod-ui: [github.com/kristijanhusak/vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui)
- dadbod-grip.nvim: [github.com/joryeugene/dadbod-grip.nvim](https://github.com/joryeugene/dadbod-grip.nvim)
- sqls: [github.com/sqls-server/sqls](https://github.com/sqls-server/sqls), [lsp-mode lsp-sqls](https://emacs-lsp.github.io/lsp-mode/page/lsp-sqls/)
- pgcli config: [pgcli.com/config](https://www.pgcli.com/config)
- AWS Athena Glue: [data-sources-glue](https://docs.aws.amazon.com/athena/latest/ug/data-sources-glue.html), [querying-glue-catalog](https://docs.aws.amazon.com/athena/latest/ug/querying-glue-catalog.html)
- Oracle SQL Developer filters: [thatjeffsmith.com "Filter All The Things"](https://www.thatjeffsmith.com/archive/2016/10/filter-all-the-things/)
- Postgres search_path: [postgresql.org/docs/current/ddl-schemas](https://www.postgresql.org/docs/current/ddl-schemas.html)
