# Phase 18: DB Nesting UX - Context

**Gathered:** 2026-05-05
**Status:** Ready for planning
**Source:** User-supplied Phase 18 prompt, roadmap entry at `.planning/ROADMAP.md:386-394`, local code scout, and external DB explorer references

<domain>
## Phase Boundary

Phase 18 changes the drawer topology so adapters with a real active database or catalog tier render database context as an expandable container under the connection. For PostgreSQL, this means schemas move from being siblings of the database row to children of the active database row:

```text
> connection
  > current_database
    > schema
      > table/view/materialized_view
```

The phase is shared drawer UX, not PostgreSQL-only. It must consider adapter semantics and avoid blindly adding redundant layers to adapters where "database" already is the schema or where the adapter has no meaningful database tier.

In scope:
- Drawer model/topology changes needed to wrap eligible structure children under a database/catalog node.
- Database switch UX placement in the new topology.
- Refresh replay and in-memory expansion compatibility when schema node IDs gain a database parent.
- Adapter-aware rules for PostgreSQL, SQL Server, Redshift, Databricks, MongoDB, MySQL, ClickHouse, SQLite, DuckDB, BigQuery, Oracle, and Redis.
- Minimal adapter fixes only where existing `ListDatabases()` cannot report the current database for a single-database connection.
- Headless coverage for topology, refresh replay, schema filter compatibility, database switching, and representative adapter semantics.

Out of scope:
- Showing all databases as separate expandable sibling nodes and lazily loading schemas for inactive databases.
- Oracle PDB discovery or new Oracle service/container metadata APIs.
- System-schema grouping under a separate "System" folder.
- Changing schema filter authority, schema name canonicalization, or LSP epoch authority helpers.
- Changing rich metadata RPC key shapes or adding database-qualified table/column yanks.
- Adding new adapters or redesigning adapters whose existing structure semantics are incomplete.

</domain>

<decisions>
## Implementation Decisions

### DB-XX Decision Matrix

| ID | Decision | Rationale |
| --- | --- | --- |
| DB-01 | Use adapter-aware topology, not always-nest. | Some adapters have database -> schema -> object; others use database as schema or have no schema tier. A universal extra layer would be wrong for MySQL/ClickHouse/SQLite. |
| DB-02 | PostgreSQL renders the active/current database as an expandable drawer node; schemas render beneath it. | This is the user-requested DBeaver-style layout and matches PostgreSQL's database -> schema -> relation model. |
| DB-03 | Single-database PostgreSQL connections still show the database node when the current database is known, even if there are no switch targets. | Consistency and explicit context are more valuable than saving one row for PostgreSQL. The connection name may not equal the active database. |
| DB-04 | Do not load or render all visible databases in Phase 18. Show only the active database plus the existing picker-based switch affordance. | Loading all databases' schemas would multiply catalog work and change switch semantics. |
| DB-05 | Replace the visual `database_switch_node` sibling with the active database container for eligible adapters. | Avoids duplicate rows. The database row is both expandable and, when alternatives exist, switch-capable. |
| DB-06 | Keep database switching at the connection/current-database level; do not move a separate switch action inside schema children. | Switching databases invalidates the whole connection subtree, not a schema-local action. |
| DB-07 | The active database node ID must be stable per connection and not include the database name. | Stable IDs simplify refresh replay and avoid churn when a database switch replaces the displayed name. |
| DB-08 | Schema node IDs under a database container may change, but restore logic must support old flat schema IDs during migration/replay. | Existing in-memory expansion state and filter snapshots should not collapse everything after the topology change. |
| DB-09 | Apply the database wrapper to both full-root and `schemas_only` lazy roots. | Phase 14 lazy schema loading must remain visually consistent with eager full-tree loading. |
| DB-10 | Keep `schema_filter_authority.lua` locked and unchanged. Filter scope remains `(connection_id, schema_name)` with the active database implicit in the connection's current driver state. | The helper is a single-source authority and current database switches already invalidate connection metadata. |
| DB-11 | Keep LSP schema cache and rich metadata key shapes unchanged. | LSP and rich metadata are scoped by connection, schema, table, materialization, epoch, and filter signature; database switching bumps/invalidate existing connection state. |
| DB-12 | Do not add a new Go RPC endpoint. Reuse `DbeeConnectionListDatabases*`, `database_selected`, `structure_loaded`, `schemas_loaded`, and `schema_objects_loaded`. | The existing event/API surface already carries current/available databases and root invalidation. |
| DB-13 | Fix eligible `ListDatabases()` implementations that return `current=""` when there are no available alternatives. | PostgreSQL/SQL Server/Redshift style two-column queries currently set `current` only while iterating alternative rows. Single-DB display depends on current being reported. |
| DB-14 | Make the database node searchable. Yanking a database node copies the database name only; table/column yanks stay `schema.table` and `schema.table.column`. | Adds a useful visible row without changing SQL qualification semantics. |
| DB-15 | Do not group system schemas in Phase 18. `pg_catalog` and `information_schema` remain ordinary schema rows if the adapter/root query includes them. | System grouping is useful but independent. It would add filtering/order decisions and should not dilute the DB nesting phase. |
| DB-16 | Do not introduce `core.StructureTypeDatabase` unless planning proves a drawer-only node cannot satisfy the UX. | This is a presentation-layer topology change. Core structure contracts currently represent one active database and schema/object rows. |
| DB-17 | Existing source folders remain unchanged; the database node sits below a connection, not between source folder and connection. | Phase 15 folder grouping operates at connection-source level and should be unaffected. |
| DB-18 | On database switch, clear/reload the wrapped subtree through the existing `database_selected` path. | Current drawer and LSP listeners already invalidate root/cache state on `database_selected`. |
| DB-19 | Use "database" as the semantic drawer node type for the new container, with icon fallback to the existing cylinder/database-switch candy if needed. | `database_switch` as a container type is misleading; icon compatibility can be handled additively. |
| DB-20 | Autopilot lock: no user clarification is needed before planning. | The remaining forks have clear low-risk defaults that preserve existing contracts. |

### Adapter Topology Decisions

| Adapter | Existing code shape | Phase 18 topology decision | Notes |
| --- | --- | --- | --- |
| PostgreSQL | `DatabaseSwitcher`, `ListSchemas`, `StructureForSchema`; structure rows are schemas under current DB (`dbee/adapters/postgres_driver.go:17-23`, `:85-125`). | Nest schemas under active database. | Must fix current-db reporting when no alternatives. |
| SQL Server/MSSQL | `DatabaseSwitcher`, `ListSchemas`, `StructureForSchema` (`dbee/adapters/sqlserver_driver.go:14-19`, `:71-108`). | Nest schemas under active database. | Same single-DB current reporting risk as PG. |
| Redshift | `DatabaseSwitcher`; structure groups by schema in current DB (`dbee/adapters/redshift_driver.go:53-81`). | Nest existing schema rows under active database. | No Phase 14 lazy schema APIs yet; wrapper works with full root. |
| Databricks | `DatabaseSwitcher`; current catalog, structure groups schemas in catalog (`dbee/adapters/databricks_driver.go:46-83`). | Nest schemas under active catalog, displayed as the database container. | Label can stay the catalog name; do not rename UI globally to "catalog". |
| MongoDB | `DatabaseSwitcher`; structure lists collections for current DB with no schema (`dbee/adapters/mongo_driver.go:115-170`). | Nest collections directly under active database. | No schema layer is invented. |
| Oracle | `ListSchemas` only; schemas are users (`dbee/adapters/oracle_driver.go:996-1010`). | Keep flat connection -> schemas. | PDB/container support is deferred. |
| MySQL | `ListSchemas` and `StructureForSchema`; database == schema (`dbee/adapters/mysql_driver.go:53-65`). | Keep flat connection -> database/schema rows. | Adding DB -> schema would duplicate the same concept. |
| ClickHouse | `DatabaseSwitcher`, but structure returns all databases as schema groups (`dbee/adapters/clickhouse_driver.go:41-80`). | Keep flat for Phase 18. | A current-DB wrapper would incorrectly wrap all databases under one database. |
| SQLite | No-op `DatabaseSwitcher`; single file, synthetic `sqlite_schema` (`dbee/adapters/sqlite_driver.go:33-62`). | Keep flat. | Avoid `file -> sqlite_schema -> tables` extra noise. |
| DuckDB | No-op catalog switcher; structure already queries current catalog and schemas (`dbee/adapters/duck_driver.go:33-71`). | Keep flat in Phase 18 unless planner finds a reliable current-catalog path without dummy switch targets. | Future cleanup can revisit DuckDB catalog UX. |
| BigQuery | No `DatabaseSwitcher`; structure is dataset -> tables (`dbee/adapters/bigquery_driver.go:99-142`). | Keep existing dataset tree. | Project/catalog discovery is not represented by current APIs. |
| Redis | Schema-less storage pseudo-table (`dbee/adapters/redis_driver.go:62-79`). | Keep flat. | Database nesting is not meaningful. |

### Cross-Phase Contract Impact

| Phase | Contract | Phase 18 impact |
| --- | --- | --- |
| Phase 14 | `schema_filter_authority.lua` is the single source for schema scope; schema filter signature and lazy root mode are connection-scoped. | No helper edits. The database layer is visual; schema filtering still applies to schema rows before/after wrapping. |
| Phase 14 | Drawer lazy root uses `schemas_loaded` then per-schema `schema_objects_loaded`. | Database wrapper must preserve lazy schema expansion and row-local loading/error/retry behavior. |
| Phase 15 | Folder grouping happens above connection rows. | No contract change. Connection folders stay source-level; database node is below connection. |
| Phase 16 | Rich metadata folders and singleflight keys target table-like nodes by schema/table/materialization/root epoch/filter signature. | No key changes. Table nodes still carry the same schema/materialization fields after gaining a database ancestor. |
| Phase 17 | PostgreSQL materialized views are table-like and receive Columns/Indexes folders. | Database wrapper must not regress `materialized_view` table-like handling or PG rich metadata markers. |
| Phase 11/12 | LSP cache invalidates on `database_selected` and uses connection/schema/table identities. | No database dimension added. Existing database-switch invalidation remains the guard. |

### the agent's Discretion

- Exact helper names and table names for the adapter topology map.
- Whether the new semantic node type is implemented as `database` with icon fallback or as a compatibility alias around `database_switch`, as long as downstream behavior is semantically `database`.
- Exact headless marker names for Phase 18, as long as they cover topology, replay, switch, and adapter-aware exclusions.
- Exact display suffix for unavailable database switching, as long as a current database node can render without alternatives.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase And Prior Contracts
- `.planning/ROADMAP.md:386-394` - Phase 18 roadmap entry and open questions.
- `.planning/PROJECT.md` - adapter diversity, backwards compatibility, and core UX value.
- `.planning/REQUIREMENTS.md` - drawer/LSP/schema browsing requirements and additive-change constraints.
- `.planning/phases/14-enterprise-db-architecture/14-CONTEXT.md` - schema filter authority, lazy schema loading, root cache, and locked helper constraints.
- `.planning/phases/17-rich-table-metadata-postgres/17-CONTEXT.md` - materialized-view propagation and rich metadata contracts that must survive the topology change.

### Drawer Code
- `lua/dbee/ui/drawer/init.lua:1154-1185` - current connection children: cached schema/object nodes plus database switch node inserted as first sibling.
- `lua/dbee/ui/drawer/init.lua:1535-1554` - `_capture_container_expansions`; must capture/restore the new database container.
- `lua/dbee/ui/drawer/init.lua:1564-1660` - async database switch state and current database node construction.
- `lua/dbee/ui/drawer/init.lua:2333-2395` - `schemas_loaded` lazy root construction.
- `lua/dbee/ui/drawer/init.lua:2446-2468` - `database_selected` invalidation and reload.
- `lua/dbee/ui/drawer/convert.lua:32-41` - structure node IDs; schema IDs will gain a database parent for nested adapters.
- `lua/dbee/ui/drawer/convert.lua:359-407` - table-like node decoration and lazy columns.
- `lua/dbee/ui/drawer/model.lua:5-13` - searchable type list to extend with database.
- `lua/dbee/config.lua:142-145` - existing cylinder icon for `database_switch`, candidate fallback for the database node.

### Backend And Adapter Code
- `dbee/core/connection.go:93-97` and `:254-266` - optional `DatabaseSwitcher` interface and connection wrapper.
- `dbee/handler/handler.go:754-821` - database list/select handler methods.
- `dbee/handler/event_bus.go:103-111` and `:330-343` - `database_selected` and `connection_databases_loaded` events.
- `dbee/adapters/postgres_driver.go`, `dbee/adapters/sqlserver_driver.go`, `dbee/adapters/redshift_driver.go`, `dbee/adapters/databricks_driver.go`, `dbee/adapters/mongo_driver.go` - eligible real database/catalog adapters.
- `dbee/adapters/mysql_driver.go`, `dbee/adapters/clickhouse_driver.go`, `dbee/adapters/sqlite_driver.go`, `dbee/adapters/duck_driver.go`, `dbee/adapters/bigquery_driver.go`, `dbee/adapters/oracle_driver.go`, `dbee/adapters/redis_driver.go` - adapters that should remain flat or deferred.

### LSP And Locked Helpers
- `lua/dbee/lsp/init.lua:1188-1198` - LSP invalidation on `database_selected`.
- `lua/dbee/lsp/schema_cache.lua:44-45`, `:377-388`, `:1813-1968` - cache version/materializations and connection/schema/table cache identity.
- `lua/dbee/schema_filter_authority.lua` - locked, read-only.
- `lua/dbee/schema_name_canonical.lua` - locked, read-only.
- `lua/dbee/lsp/epoch_authority.lua` - locked, read-only.

### External Reference Layouts
- DBeaver Database Navigator documentation - reference for database explorer tree conventions: `https://dbeaver.com/docs/dbeaver/Database-Navigator/`
- JetBrains DataGrip Database Explorer documentation - reference for data source/database/schema presentation: `https://www.jetbrains.com/help/datagrip/database-explorer.html`
- pgAdmin Browser/Tree documentation - reference for PostgreSQL server -> database -> schema object hierarchy: `https://www.pgadmin.org/docs/pgadmin4/`

</canonical_refs>

<code_context>
## Existing Code Insights

### Current Drawer Path
- `convert.handler_nodes()` builds connection nodes from sources, and `DrawerUI:refresh()` passes a `connection_children` callback into the model.
- `build_connection_children()` currently returns structure root children directly under the connection, then inserts `_build_database_switch_node()` at index 1 when current DB and available DBs exist.
- `schema_rows_for_connection()` creates schema nodes for lazy roots with `{ name=schema, schema=schema, type="schema" }`; full roots arrive from Go through `core.GetGenericStructure()`.
- `_capture_container_expansions()` currently captures connection/schema-ish containers and excludes table/view/materialized_view/column/load_more nodes. A `database` node must be included.
- `database_selected` already closes filters, captures expansions, clears root/branches, bumps root epoch, and requests a fresh structure load.

### Current Adapter Survey
- PostgreSQL, SQL Server, Redshift, Databricks, MongoDB, ClickHouse, SQLite, and DuckDB implement `DatabaseSwitcher`.
- PostgreSQL, SQL Server, Oracle, and MySQL implement Phase 14 schema list/object lazy interfaces.
- MySQL and ClickHouse expose database names as schema groups in structure results; nesting them under an active database would misrepresent the adapter.
- PostgreSQL/SQL Server/Redshift `ListDatabases()` methods derive `current` from rows that enumerate non-current databases; if none are returned, `current` remains empty. This must be fixed for DB-03.

### Established Patterns
- Drawer topology changes should be Lua-first and additive. Core `Structure` represents the active database's schema/object tree and does not currently need a database structure type.
- Existing connection/database events are asynchronous and epoch-guarded; new behavior should not bypass them.
- Drawer filtering is zero-RPC while typing. The database node must be included in the cached/search model without triggering structure/database fetches from filter input.
- Node IDs use `\x1f` and encoded segments. A stable database parent ID is preferable to name-derived IDs.

### Integration Points
- Add a database wrapper in the path that builds connection children from `_struct_cache.root[conn_id].structures`, not in every adapter.
- Teach render snapshot/hydration/search/yank to preserve the database node's fields.
- Add migration/dual-lookup logic for replaying old schema expansion IDs under the new database parent.
- Keep schema branch state keyed by actual rendered schema node ID; after DB nesting, branch IDs should use the new parent path.
- Fix current database reporting in eligible Go adapters if tests show `current=""` when `available=[]`.

</code_context>

<specifics>
## Specific Ideas

### Target PostgreSQL Shape

```text
> dbee_test (localhost:5433)
  > dbee_test
    > analytics
    > inventory
    > sales
    > pg_catalog
    > information_schema
```

### Recommended Behavioral Tests
- PostgreSQL-like fixture: connection expands to one database node, schemas appear under it, and no schema appears as a direct connection child.
- Single-DB fixture: current database node still renders when `available={}`.
- Switch fixture: database node exposes switch action when alternatives exist; selecting another DB clears old root and reloads under the same stable database node ID.
- Lazy schema fixture: `schemas_only` root renders database -> schemas; expanding a schema still calls `connection_get_schema_objects_singleflight`.
- Full root fixture: eager structure renders database -> schemas -> objects.
- Backward compatibility fixture: old expansion ID `conn_id + sep + schema...` is replayed against `database_node_id(conn_id) + sep + schema...`.
- Adapter exclusion fixtures: MySQL and ClickHouse stay flat; Oracle stays flat; Mongo nests collections under database; SQLite stays flat.
- Zero-RPC filter fixture: filtering visible database/schema/table rows triggers no metadata RPC.

### Effort Estimate

**Medium, cross-cutting UI.** Expected implementation touches roughly 5-8 files:
- Drawer topology/model/rendering: `lua/dbee/ui/drawer/init.lua`, `convert.lua`, `model.lua`.
- Config/icon typing if a new `database` candy is added: `lua/dbee/config.lua`.
- Focused Go adapter fixes for current database reporting: likely `postgres_driver.go`, `sqlserver_driver.go`, `redshift_driver.go` if tests confirm.
- Headless test scaffold for Phase 18.

No new RPC endpoint, no locked helper edits, and no rich metadata/LSP key-shape migration are expected.

</specifics>

<deferred>
## Deferred Ideas

- System schema grouping under a collapsed "System" folder.
- Rendering all visible databases as sibling expandable nodes with lazy per-database schema loading.
- Oracle PDB/container discovery and PDB-aware schema browsing.
- ClickHouse topology cleanup so current database switching and structure results agree.
- DuckDB catalog UX cleanup once catalog switching semantics are clear.
- Core `StructureTypeDatabase` if future phases need database nodes outside drawer presentation.
- Database-qualified object yanks such as `database.schema.table`.

</deferred>

---

*Phase: 18-db-nesting*
*Context gathered: 2026-05-05*
