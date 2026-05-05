# Phase 17: Rich Table Metadata X.2 - PostgreSQL Adapter Context

**Gathered:** 2026-05-04  
**Status:** Ready for planning after Phase 17 is registered in the roadmap  
**Source:** User-supplied Phase 17 task plus local codebase scout

<domain>
## Phase Boundary

Phase 17 delivers the PostgreSQL adapter implementation for the rich table metadata architecture shipped in Phase 16. It enables PostgreSQL connections to render table/materialized-view `Columns` and `Indexes` folders plus schema-level `Sequences` folders through the existing rich metadata capability, event, singleflight, backpressure, drawer, and FK-navigation surfaces.

In scope:
- PostgreSQL only: `dbee/adapters/postgres*.go`, focused adapter tests, and `RICH_PG_*` marker coverage.
- Add PostgreSQL `SupportsRichMetadata()`, `ColumnsRich()`, `Indexes()`, and `Sequences()` using native PostgreSQL catalog queries.
- Extend shared additive metadata only where PostgreSQL-specific annotations require it, such as generated/default/identity column labels or INCLUDE-index columns.
- Preserve Phase 16 architecture exactly: folders, lazy fetch timing, capability=false legacy rendering, `structure_children_loaded`, string `data.error`, `data.error_kind`, waiter fanout isolation, queue-full retry, supersession tombstones, composite FK copies, and direct FK navigation.

Out of scope:
- MySQL, SQLite, ClickHouse, MongoDB, SQL Server, DuckDB, BigQuery, Databricks, Redis, Redshift, or other adapter rich metadata.
- Partitioned-table-specific UI or inheritance/partition tree rendering. PostgreSQL partitioned tables are treated as ordinary tables for Phase 17.
- Composite types, domains, reverse references, triggers, check constraints, exclusion constraint details, public API exposure, and LSP consumption of rich metadata.
- Edits to `lua/dbee/schema_filter_authority.lua`, `lua/dbee/schema_name_canonical.lua`, or `lua/dbee/lsp/epoch_authority.lua`.

### Orchestration Caveat

`gsd-sdk query init.phase-op 17` currently returns `phase_found=false` because local `.planning/ROADMAP.md` and `.planning/STATE.md` still describe v1.3-era phase state. This context file was written at the explicit requested path. Downstream `$gsd-plan-phase 17` will likely fail until the v1.4/Phase 17 roadmap registry is updated or the orchestrator supplies an explicit bypass.

</domain>

<decisions>
## Implementation Decisions

### Phase Shape And Locked Architecture
- **PG-01:** Phase 17 is PostgreSQL-only. Any non-PostgreSQL rich metadata work remains backlog and must not be planned in this phase.
- **PG-02:** PostgreSQL must implement the existing rich metadata optional interfaces; it must not introduce new Lua event names, public API wrappers, or drawer topology.
- **PG-03:** Capability true for PostgreSQL is `{ columns=true, indexes=true, sequences=true }`. Unsupported adapters keep the Phase 16 capability=false legacy flat-column path.
- **PG-04:** Use PostgreSQL native positional placeholders only: `$1`, `$2`, etc. Do not use named binds.
- **PG-05:** Reuse the Phase 16 singleflight key shape: table metadata key includes `(conn_id, schema, table, materialization, root_epoch, schema_filter_signature, kind)`; sequence metadata key is schema-scoped.
- **PG-06:** Handler and drawer production behavior should stay mostly unchanged. Touch Lua shared code only for additive field marshal/render support or `RICH_PG_*` tests.

### Catalog And Schema Scoping
- **PG-07:** Use `pg_catalog` for rich metadata queries. `information_schema` is acceptable for existing legacy columns/structure paths, but rich metadata needs `pg_attribute`, `pg_constraint`, `pg_index`, `pg_class`, `pg_namespace`, `pg_sequence`, and helper functions for completeness and performance.
- **PG-08:** Every rich metadata query scopes by `pg_namespace.nspname = $1` and table/index/sequence catalog identity, not by search path.
- **PG-09:** Compare against `pg_class.relname` / `pg_namespace.nspname` using bound values from the drawer. Do not lowercase, uppercase, or quote-build identifiers in Go; the catalog already returns canonical case for quoted and unquoted objects.
- **PG-10:** Adapter SQL is defense-in-depth scoped by schema/table, but Lua schema-filter authority remains the gate that blocks filtered-out schemas before any RPC.

### Columns, PKs, FKs, And Column Labels
- **PG-11:** `ColumnsRich()` should read base column rows from `pg_class` + `pg_namespace` + `pg_attribute`, with `format_type(a.atttypid, a.atttypmod)` for type, `NOT a.attnotnull` for nullable, `a.attgenerated`, `a.attidentity`, `pg_attrdef`, and `pg_get_serial_sequence()` where useful.
- **PG-12:** Generated columns are rendered with `[GEN]` when `pg_attribute.attgenerated != ''`.
- **PG-13:** Default expressions are rendered with `[DEFAULT=...]` when `pg_attrdef` returns a non-empty expression. Exact truncation/escaping is planner discretion, but the stored field must be additive and old `{name,type}` column payloads must still decode.
- **PG-14:** Identity columns are captured from `pg_attribute.attidentity`; render a compact `[IDENTITY]` annotation. SERIAL remains represented by its `nextval(...)` default and optional serial-sequence metadata, not by a separate table child folder.
- **PG-15:** Primary keys use `pg_constraint.contype = 'p'` and `conkey` with ordinality. Composite PK ordinal must be preserved and copied into `PrimaryKeyOrdinal`.
- **PG-16:** Foreign keys use `pg_constraint.contype = 'f'`, pairing `conkey` and `confkey` by parallel ordinality. Composite FKs must produce per-source-column `FKRef` copies sharing full `SourceColumns` and `TargetColumns`, matching Phase 16 behavior.

### Indexes
- **PG-17:** `Indexes()` uses `pg_index` joined to table/index `pg_class`, table/index `pg_namespace`, and `pg_attribute`. It must not use `pg_indexes` as the primary data source because INCLUDE columns, PK-backed detection, and order metadata need `pg_index`.
- **PG-18:** PK-backed indexes are detected with `pg_index.indisprimary` and returned with `PKBacked=true`; drawer rendering continues to hide `pk_backed=true`.
- **PG-19:** Key columns and INCLUDE columns must not be merged. Add an optional `include_columns` field to `core.Index` / marshal / drawer rendering, and render INCLUDE data separately, for example `[INCLUDE col_a, col_b]`.
- **PG-20:** Preserve ASC/DESC order for key columns only. INCLUDE columns have no key order.
- **PG-21:** Expression index keys are best-effort: use `pg_get_indexdef(indexrelid, ordinal, true)` as the display string when no simple `pg_attribute` column exists. Partial predicates, access method/type, and exclusion-constraint details remain out of scope.

### Sequences
- **PG-22:** `Sequences(schema)` uses `pg_class.relkind = 'S'` scoped by namespace and joins `pg_sequence` for `seqincrement` and `seqcache`.
- **PG-23:** Sequences render only in the schema-level `Sequences` folder. Serial/identity linkage can be captured on columns, but Phase 17 does not add table-local sequence children or sequence navigation.

### Materialized Views And Table-Like Objects
- **PG-24:** Rich columns and indexes apply to PostgreSQL tables and materialized views. Views keep the same Columns folder behavior as Phase 16 table-like drawer behavior, but PostgreSQL view indexes are not expected.
- **PG-25:** Partitioned tables are ordinary tables in Phase 17. No partition hierarchy, inheritance expansion, or partition-specific annotations.

### Tests And Markers
- **PG-26:** Add deterministic Go adapter tests for PostgreSQL rich metadata query behavior using `go-sqlmock` or equivalent unit-test doubles. Do not require a live database for strict Phase 17 rich metadata gates.
- **PG-27:** Keep the existing PostgreSQL testcontainer integration pattern available for optional/manual adapter confidence, but do not make new rich metadata strict markers depend on Docker unless planning finds an existing CI lane already suitable.
- **PG-28:** Produce a strict `RICH_PG_*` marker family mirroring the `RICH16_*` Oracle suite shape. Required marker themes: support=true, positional binds, catalog scoping, rich columns, generated/default/identity labels, composite PK, composite FK, indexes, INCLUDE columns, PK-backed hidden flag, sequences, schema-filter no-query, materialized-view folder treatment, and `RICH_PG_ALL_PASS`.
- **PG-29:** Preserve existing `RICH16_*` Oracle markers and Phase 16 behavior while adding PostgreSQL coverage. If a shared marker script is extended, failures must clearly identify `RICH16_*` versus `RICH_PG_*`.

### Open Questions For Orchestrator
- **OQ-01:** PostgreSQL materialized views are currently queried from `pg_matviews` but labeled as `'VIEW'` in `dbee/adapters/postgres_driver.go`, and drawer `TABLE_LIKE_TYPES` only includes `table` and `view`. Should Phase 17 preserve this existing behavior to stay narrow, or fix PostgreSQL MVs to `materialized_view` and add table-like drawer support for that type?
- **OQ-02:** Before planning, should the orchestrator update `.planning/ROADMAP.md` / `.planning/STATE.md` for v1.4 Phase 17, or should planning consume this context by explicit path despite `gsd-sdk init.phase-op 17` failing?

### the agent's Discretion
- Exact helper names, SQL constant names, row structs, and grouping helpers in `postgres_driver.go`.
- Exact default-expression truncation length and display escaping, as long as `[DEFAULT=...]` stays readable and deterministic in tests.
- Exact marker file split: extend `ci/headless/check_rich_metadata.lua` or create a PostgreSQL-specific companion script, as long as `RICH_PG_*` markers are strict and CI-addressable.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase 17 Input And Prior Architecture
- `.planning/phases/17-rich-table-metadata-postgres/17-CONTEXT.md` — this phase context and locked PostgreSQL decisions.
- `.planning/phases/16-rich-table-metadata/PLAN.md` — shipped Oracle X.1 architecture, event contracts, singleflight/backpressure rules, drawer topology, FK navigation, and `RICH16_*` marker pattern.
- `known-issues.md` — rich table metadata backlog item describing indexes, sequences, FK navigation, and adapter SQL expectations.

### Project And Prior Context
- `.planning/PROJECT.md` — adapter diversity, backwards compatibility, additive-change constraints, and current project scope.
- `.planning/REQUIREMENTS.md` — validated adapter/LSP/schema requirements and out-of-scope backlog.
- `.planning/STATE.md` — local state caveat; currently stale relative to the user-supplied v1.4 task.
- `.planning/phases/14-enterprise-db-architecture/14-CONTEXT.md` — schema filter authority, PostgreSQL schema/object scope decisions, adapter folding/case behavior, and lazy architecture contracts.
- `.planning/phases/13-ux-regression-batch/13-CONTEXT.md` — headless marker discipline and zero-RPC drawer/filter constraints that rich metadata must preserve.

### Production Code
- `dbee/adapters/postgres.go` — PostgreSQL adapter registration, `lib/pq` import, `sql.Open("postgres", ...)`, and existing helper SQL.
- `dbee/adapters/postgres_driver.go` — current PostgreSQL structure/columns/ListSchemas/StructureForSchema implementation and materialized-view query behavior.
- `dbee/adapters/oracle_driver.go` — Phase 16 reference implementation for `SupportsRichMetadata`, `ColumnsRich`, `Indexes`, and `Sequences`.
- `dbee/core/connection.go` — rich metadata optional interfaces and `Connection.GetColumnsRich/GetIndexes/GetSequences`.
- `dbee/core/types.go` — additive `Column`, `FKRef`, `Index`, `Sequence`, and `StructureType` fields.
- `dbee/core/builders/client.go` — `QueryWithArgs` path for positional PostgreSQL binds.
- `dbee/handler/handler.go` — Go async rich metadata RPC methods and `structure_children_loaded` emission.
- `dbee/handler/event_bus.go` — shared payload fields for columns, indexes, sequences, string errors, and optional `error_kind`.
- `dbee/handler/marshal.go` — msgpack wrappers that must be extended if `Column` or `Index` receives additive fields.
- `dbee/endpoints.go` — RPC endpoint registration and `TableOptions` materialization decoding.
- `lua/dbee/handler/init.lua` — schema filter authority wrappers, rich metadata support cache, singleflight, max-active/max-queue, queue_full, waiter fanout, and supersession logic.
- `lua/dbee/ui/drawer/init.lua` — rich table children, sequences folder, branch state, payload field mapping, queue_full retry, and direct FK navigation.
- `lua/dbee/ui/drawer/convert.lua` — column/index/sequence label rendering and metadata folder node IDs.
- `lua/dbee/config.lua` — default `gd` mapping for FK navigation.
- `lua/dbee/schema_filter_authority.lua`, `lua/dbee/schema_name_canonical.lua`, `lua/dbee/lsp/epoch_authority.lua` — locked single-source helpers that Phase 17 must not edit.

### Test Harnesses
- `ci/headless/check_rich_metadata.lua` — Oracle `RICH16_*` marker suite to mirror for PostgreSQL.
- `dbee/adapters/oracle_driver_rich_metadata_test.go` — sqlmock-based Oracle rich metadata test pattern.
- `dbee/tests/integration/postgres_integration_test.go` — existing PostgreSQL testcontainer integration suite.
- `dbee/tests/testhelpers/postgres.go` — PostgreSQL container helper using `postgres:16-alpine`.
- `dbee/tests/testdata/postgres_seed.sql` — current PostgreSQL seed; extend only if integration coverage is intentionally added.
- `.planning/codebase/ARCHITECTURE.md`, `.planning/codebase/STACK.md`, `.planning/codebase/TESTING.md` — codebase map for architecture, dependency, and test-pattern grounding.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- PostgreSQL already uses `database/sql` with `github.com/lib/pq` and `builders.Client.QueryWithArgs`, so positional `$1/$2` catalog queries fit the current driver.
- `postgresDriver` already implements filtered structure, schema list, per-schema structure, and database switching interfaces; Phase 17 only needs rich metadata optional interfaces.
- Phase 16 already added shared rich metadata types, Go async endpoints, Lua handler wrappers, support cache, singleflight/backpressure, drawer folders, sequence folders, and FK navigation.
- Oracle rich tests already use `go-sqlmock` with exact SQL matching and row fixtures. PostgreSQL can mirror that without a live database.
- Existing PostgreSQL testcontainer coverage is available for optional integration confidence and already runs against `postgres:16-alpine`.

### Established Patterns
- Lua handler wrappers block filtered-out schemas before RPC through `schema_filter_authority`; adapters still scope SQL explicitly as defense in depth.
- `structure_children_loaded` is the only rich metadata event. `kind` chooses payload field: columns/columns_rich use `columns`, indexes use `indexes`, sequences use `sequences`.
- Queue-full is loud and retryable: handler emits `error="queue_full"` / `error_kind="queue_full"`, drawer clears loading into an error placeholder, and re-expand can retry.
- Drawer hides `index.pk_backed == true`, so PostgreSQL must return PK-backed indexes rather than silently dropping them in the adapter.
- Current `convert.column_nodes()` renders PK, NOT NULL, and FK annotations only. `[GEN]`, `[IDENTITY]`, and `[DEFAULT=...]` require additive label support.
- Current `core.Index` lacks INCLUDE-column storage. PostgreSQL covering indexes require an additive field and renderer support to avoid misrepresenting INCLUDE columns as key columns.

### Integration Points
- Adapter path: `postgresDriver` methods call `builders.Client.QueryWithArgs`, group rows into `core.Column`, `core.Index`, and `core.Sequence`, then surface through existing `Connection` methods.
- RPC path: existing endpoints in `dbee/endpoints.go` decode materialization and call Go handler async methods; no new endpoints are expected.
- Lua path: existing handler methods `connection_get_columns_rich_async`, `connection_get_indexes_async`, and `connection_get_sequences_async` already provide authority, singleflight, and backpressure.
- Drawer path: `_build_rich_table_children()` prefetches columns on table expand, defers indexes to folder expand, and `_build_sequences_folder()` defers sequences to folder expand.
- Test path: strict marker suite can assert code presence and run headless behavior fakes without Docker; Go adapter unit tests can assert catalog SQL, row parsing, and composite grouping.

</code_context>

<specifics>
## Specific Ideas

- Use compact labels: `name   [type] [PK] [NOT NULL] [GEN] [IDENTITY] [DEFAULT=expr] [FK→target.col]`.
- Recommended PostgreSQL catalog sources:
  - Columns: `pg_class`, `pg_namespace`, `pg_attribute`, `pg_attrdef`.
  - PK/FK: `pg_constraint` with `conkey` / `confkey` unnested `WITH ORDINALITY`.
  - Indexes: `pg_index`, table/index `pg_class`, namespaces, `pg_attribute`, and `pg_get_indexdef` for expression keys.
  - Sequences: `pg_class relkind='S'` plus `pg_sequence`.
- `pg_class.relname` and `pg_namespace.nspname` are the canonical names to compare against the drawer-provided schema/table values.
- PostgreSQL rich metadata should improve correctness without changing existing query execution, helper query, or legacy `Columns()` behavior.

</specifics>

<deferred>
## Deferred Ideas

- MySQL, SQLite, ClickHouse, MongoDB, SQL Server/MSSQL, DuckDB, BigQuery, Databricks, Redis, Redshift, and other adapter rich metadata.
- Partition hierarchy rendering, inherited indexes/constraints nuance, and partition-specific annotations.
- Composite type and domain introspection.
- Exclusion constraint details, partial index predicate labels, index method/type labels, triggers, and check constraints.
- Reverse-reference navigation and LSP use of rich table metadata.
- Public API wrappers for rich metadata outside drawer/handler internals.

</deferred>

---

## Discuss-lock decisions (Claude orchestrator, 2026-05-04)

Both open questions resolved by orchestrator (autopilot mode); no user escalation needed.

- **OQ-01 RESOLVED — `materialized_view` IN SCOPE.** Phase 17 will:
  - Relabel PostgreSQL MVs from `'VIEW'` to `materialized_view` in `dbee/adapters/postgres_driver.go` (the `pg_matviews` query path).
  - Add `materialized_view` to `lua/dbee/ui/drawer/init.lua` `TABLE_LIKE_TYPES` set so MVs receive Columns/Indexes folder treatment.
  - Verify existing MV rendering still works (icon, expansion, etc.) — likely cosmetic but call out in plan-gate.
  - Rationale: future LSP/completion features depend on accurate type labels; doing it during the rich-meta phase that already touches MV rendering is the lowest-friction window.

- **OQ-02 RESOLVED — ROADMAP/STATE updated by orchestrator.** `.planning/ROADMAP.md` now contains v1.4 milestone + Phase 17/18/19 entries. `.planning/STATE.md` flipped to `milestone: v1.4` with v1.3 in `previous_milestones`. Plan-phase consumes this CONTEXT.md by explicit path; gsd-sdk `init.phase-op 17` failure is acknowledged as harmless.

## Next step (orchestrator)

Dispatch parallel research:
- **Codex side**: pg_catalog SQL deep-dive — exact ColumnsRich / Indexes / Sequences queries with caveats (PG version differences, INCLUDE columns, generated/identity attribute handling).
- **Claude side (general-purpose subagent)**: existing dbee Postgres adapter integration points — `lib/pq` driver, sqlmock patterns from Oracle test infrastructure, drawer rendering hooks for `materialized_view`.

Both write to `.planning/phases/17-rich-table-metadata-postgres/17-RESEARCH-CODEX.md` and `17-RESEARCH-CLAUDE.md` respectively. Plan-phase consumes both.

---

*Phase: 17-rich-table-metadata-postgres*  
*Context gathered: 2026-05-04*  
*Discuss-lock applied: 2026-05-04*
