# Phase 18 - DB Nesting UX

**Milestone:** v1.5
**Status:** Planned
**Date:** 2026-05-05
**Requirement:** TBD by discuss-phase (cross-adapter drawer UX)
**Reference:** `.planning/phases/18-db-nesting/18-CONTEXT.md`

## Goal

Render schemas beneath the current selected database for adapters with a real database/catalog tier while preserving flat topology for adapters where database already means schema or where no useful database tier exists.

Target PostgreSQL shape:

```text
> connection
  > current_database
    > schema
      > table/view/materialized_view
```

This phase is a shared drawer UX change. It must not add new RPC endpoints, LSP cache dimensions, rich-metadata key dimensions, or core structure types.

## Inputs Read

- `.planning/ROADMAP.md:386-394`
- `.planning/phases/18-db-nesting/18-CONTEXT.md`
- `lua/dbee/ui/drawer/init.lua`
- `lua/dbee/ui/drawer/convert.lua`
- `lua/dbee/ui/drawer/model.lua`
- `lua/dbee/config.lua`
- `dbee/core/connection.go`
- `dbee/handler/handler.go`
- `dbee/handler/event_bus.go`
- `dbee/adapters/postgres_driver.go`
- `dbee/adapters/sqlserver_driver.go`
- `dbee/adapters/redshift_driver.go`
- `Makefile`
- `ci/headless/check_ux13_rollup.lua`

## Locked Contracts

- Do not edit `lua/dbee/schema_filter_authority.lua`, `lua/dbee/schema_name_canonical.lua`, or `lua/dbee/lsp/epoch_authority.lua`.
- Adapter topology is adapter-aware:
  - nested: PostgreSQL, SQL Server/MSSQL, Redshift, Databricks, MongoDB.
  - flat: Oracle, MySQL, ClickHouse, SQLite, DuckDB, BigQuery, Redis.
  - deferred: none currently.
- The adapter topology registry is closed-world: every `*_driver.go` adapter in `dbee/adapters/` must appear in exactly one explicit topology bucket.
- Unknown external adapters that are not represented by a repo `*_driver.go` file fall back to flat topology.
- The database node is drawer-only. Do not add `core.StructureTypeDatabase` unless implementation proves drawer-only is impossible.
- Replace the visual `database_switch_node` sibling with the active database container for nested adapters.
- Keep database switching at connection scope using existing `database_selected`, `structure_loaded`, `schemas_loaded`, and `schema_objects_loaded` events.
- Stable active database node ID is per connection and must not include the database name.
- Schema IDs may gain the database parent, but replay must migrate old flat schema expansion IDs under the database parent.
- Apply the database wrapper to both full-root and `schemas_only` lazy roots.
- Keep schema filter identity `(connection_id, schema_name)` and rich metadata key shapes unchanged.
- Keep LSP cache version, materialization list, and cache identity unchanged.
- `database` is searchable; yanking a database node copies only the database name.
- System schema grouping is deferred.

## Wave Breakdown

| Wave | Plan | Objective | Depends On |
|------|------|-----------|------------|
| 1 | `18-01-PLAN.md` | Add drawer-only database topology, stable DB node IDs, replay migration, search/yank support, and database icon fallback. | None |
| 2 | `18-02-PLAN.md` | Fix current database reporting in eligible Go adapters when no switch alternatives exist. | None |
| 3 | `18-03-PLAN.md` | Add deterministic headless coverage, `DB18_*` strict markers, and `perf-lsp`/UX13 rollup wiring. | Waves 1, 2 |

## Decision Coverage

| Decision | Covered By | Success Criterion |
|----------|------------|-------------------|
| DB-01 | Waves 1, 3 | Nested and flat adapter fixtures match the locked topology map. |
| DB-02 | Waves 1, 3 | PostgreSQL fixture renders schemas under one current database node. |
| DB-03 | Waves 1, 2, 3 | Single-DB PostgreSQL fixture still renders the current DB node with `available=[]`. |
| DB-04 | Waves 1, 3 | No all-database sibling tree is introduced; only active DB is wrapped. |
| DB-05 | Waves 1, 3 | No sibling `database_switch` row remains for nested adapters. |
| DB-06 | Waves 1, 3 | Database switch action remains on the active DB container and reloads the connection subtree. |
| DB-07 | Waves 1, 3 | DB node ID is stable across database name changes for the same connection. |
| DB-08 | Waves 1, 3 | Old flat schema expansion IDs replay under the new DB parent. |
| DB-09 | Waves 1, 3 | Full-root and `schemas_only` roots both render through the DB wrapper. |
| DB-10 | Waves 1, 3 | Locked schema filter helper is untouched and schema filter key shape remains unchanged. |
| DB-11 | Waves 1, 3 | LSP and rich metadata key/cache identity are unchanged. |
| DB-12 | Waves 1, 3 | No new endpoints or event names are added. |
| DB-13 | Waves 2, 3 | PG/MSSQL/Redshift `ListDatabases()` report current DB even when no alternatives exist. |
| DB-14 | Waves 1, 3 | Database node is searchable; database yank returns name only. |
| DB-15 | Wave 3 | System schemas remain ordinary schema rows in fixtures. |
| DB-16 | Waves 1, 3 | No `StructureTypeDatabase` appears in Go core. |
| DB-17 | Wave 3 | Source folder grouping above connection remains unchanged. |
| DB-18 | Waves 1, 3 | Existing `database_selected` path clears and reloads the wrapped subtree. |
| DB-19 | Waves 1, 3 | Semantic node type is `database` with additive icon support/fallback. |
| DB-20 | This plan | No further user clarification is required. |

## DB-Aware Touchpoint Matrix

| ID | File | Touchpoint | Acceptance Assertion |
|----|------|------------|----------------------|
| A | `init.lua` | Adapter topology predicate/map | Canonical nested/flat/deferred driver stems are explicit; alias normalization is separate; unknown external adapters stay flat. |
| B | `init.lua`/`check_db_nesting.lua` | Closed-world topology registry | Union of canonical nested, flat, and deferred stems exactly matches `dbee/adapters/*_driver.go`; aliases resolve to canonical stems. |
| C | `init.lua` | Stable database node ID helper | ID is `conn_id .. ID_SEP .. encode_node_segment({ "__database__" })`, never current DB name and never `_database_switch__`. |
| D | `init.lua` | Render-only database wrapper | `_struct_cache.root[conn_id].structures` remains unchanged; schemas stay top-level in cache. |
| E | `init.lua` | Active DB state loading | Current DB can render when `available` is empty. |
| F | `init.lua` | `_build_database_switch_node` replacement | Nested adapters get a `database` container; flat adapters keep current behavior or no node. |
| G | `init.lua` | `build_connection_children` full root | Full structure children are wrapped under DB for nested adapters. |
| H | `init.lua` | `build_connection_children` `schemas_only` root | Lazy schema rows are wrapped under DB for nested adapters. |
| I | `init.lua` | Top-level branch state | Root `STRUCTURES_KIND` branch remains keyed by `conn_id`; schema branches use rendered schema IDs. |
| J | `init.lua` | Snapshot/hydrate threading | DB-aware ID rewrite is applied at clone, hydrate, searchable tree conversion, filter-restore pre-apply, and search-merge graft sites. |
| K | `init.lua` | `_capture_container_expansions` | `database` nodes are captured/restored; table-like exclusions remain intact. |
| L | `init.lua` | Expansion replay migration | Old-only, new-only, and old+new duplicate schema node IDs map to one rendered DB-parent schema expansion. |
| M | `init.lua` | `loaded_lazy_ids` semantics | Stale old flat IDs are pruned on root drop; replaying cached schema expansion does not force a redundant schema-object fetch. |
| N | `init.lua` | `on_database_selected` | Existing invalidation path clears and reloads the wrapped subtree; switch chains leave exactly one DB node. |
| O | `init.lua` | `on_schema_objects_loaded` | Schema children attach successfully while DB wrapper is active because cache shape remains schema-top-level. |
| P | `init.lua` | `yank_name` | Database yanks return only the database name; table/column yanks unchanged. |
| Q | `model.lua` | `SEARCHABLE_TYPES` | `database = true`. |
| R | `model.lua` | `build_search_struct_nodes` / `merge_visible_connection_rows` | Search-model IDs match rendered IDs for nested and flat adapters; search is zero-RPC. |
| S | `convert.lua` | `structure_node_id`/legacy path | Schema IDs include database parent when wrapped; no duplicate legacy DB switch row. |
| T | `convert.lua` | Legacy `connection_nodes` fallback | Normal drawer flow does not reach the synchronous DB-list fallback; no legacy DB switch row leaks. |
| U | `config.lua` | Node icon/candy | Additive `database` entry or fallback to existing cylinder icon. |
| V | `postgres_driver.go` | `ListDatabases()` | Current DB is reported with no alternatives. |
| W | `sqlserver_driver.go` | `ListDatabases()` | Current DB is reported with no alternatives. |
| X | `redshift_driver.go` | `ListDatabases()` | Current DB is reported with no alternatives. |
| Y | `dbee/adapters/list_databases_test.go` | Single-DB adapter tests | PG/MSSQL/Redshift no-alternatives and alternatives-present paths are covered with sqlmock. |
| Z | `check_db_nesting.lua` | Behavioral fixtures | Adapter topology, replay, switch, search, yank, lazy/full roots, and MV rich folders are exercised with fail-on-call sentinels. |
| AA | `Makefile` | `db18-locked-helpers-guard` | Guard runs before `check_db_nesting.lua`, writes `DB18_LOCKED_HELPERS_GIT_DIFF_OK=true` into `UX13_ROLLUP_LOG`, and fails on locked-helper diff/check output. |
| AA1 | `Makefile`/`check_ux13_rollup.lua` | ARCH14 preservation | `DB18_ARCH14_PRESERVED_OK` requires `ARCH14_ALL_PASS=true` and `arch14-rollup` output before UX13 rollup. |
| AA2 | `Makefile`/`check_ux13_rollup.lua` | FOLDER15 preservation | `DB18_FOLDER15_PRESERVED_OK` requires `FOLDER15_ALL_PASS=true`. |
| AA3 | `Makefile`/`check_ux13_rollup.lua` | RICH16 preservation | `DB18_RICH16_PRESERVED_OK` requires `RICH16_ALL_PASS=true`. |
| AA4 | `Makefile`/`check_ux13_rollup.lua` | RICH_PG preservation | `DB18_RICH_PG_PRESERVED_OK` requires `RICH_PG_ALL_PASS=true`. |
| AA5 | `Makefile`/`check_ux13_rollup.lua` | LSP12 preservation | `DB18_LSP12_PRESERVED_OK` requires `LSP12_HOVER_RESOLVE_ALL_PASS=true`. |

## Strict Markers

`DB18_STRICT_MARKER_COUNT` is **34**. `DB18_ALL_PASS=true` is emitted by the UX13 rollup after the DB18 strict markers and existing all-pass rollups are present in the runtime log. The matrix has 32 rows after splitting the integration rollup and preservation assertions for grep-resistant execution contracts.

DB18 behavior markers:

1. `DB18_TOPOLOGY_POSTGRES_NESTED_OK`
2. `DB18_TOPOLOGY_SQLSERVER_NESTED_OK`
3. `DB18_TOPOLOGY_REDSHIFT_NESTED_OK`
4. `DB18_TOPOLOGY_DATABRICKS_NESTED_OK`
5. `DB18_TOPOLOGY_MONGO_NESTED_OK`
6. `DB18_TOPOLOGY_MYSQL_FLAT_OK`
7. `DB18_TOPOLOGY_CLICKHOUSE_FLAT_OK`
8. `DB18_TOPOLOGY_ORACLE_FLAT_OK`
9. `DB18_TOPOLOGY_SQLITE_FLAT_OK`
10. `DB18_TOPOLOGY_DUCKDB_FLAT_OK`
11. `DB18_TOPOLOGY_BIGQUERY_FLAT_OK`
12. `DB18_TOPOLOGY_REDIS_FLAT_OK`
13. `DB18_SINGLE_DB_CURRENT_RENDER_OK`
14. `DB18_DATABASE_NODE_ID_STABLE_OK`
15. `DB18_SCHEMA_ID_MIGRATION_OK`
16. `DB18_SWITCH_INVALIDATION_OK`
17. `DB18_LAZY_SCHEMA_ROOT_PRESERVED_OK`
18. `DB18_FULL_ROOT_WRAPPED_OK`
19. `DB18_REFRESH_REPLAY_DATABASE_OK`
20. `DB18_CAPTURE_CONTAINER_DATABASE_OK`
21. `DB18_SEARCH_DATABASE_OK`
22. `DB18_YANK_DATABASE_ONLY_OK`
23. `DB18_MV_RICH_FOLDERS_UNDER_DB_OK`
24. `DB18_SCHEMA_FILTER_KEY_UNCHANGED_OK`
25. `DB18_NO_CORE_STRUCTURE_DATABASE_OK`
26. `DB18_LOCKED_HELPERS_UNTOUCHED_OK`
27. `DB18_ADAPTER_CURRENT_DB_FALLBACK_OK`
28. `DB18_TOPOLOGY_REGISTRY_COMPLETE_OK`
29. `DB18_REPLAY_NO_REFETCH_OK`

Existing-rollup preservation markers owned by `check_ux13_rollup.lua`:

30. `DB18_ARCH14_PRESERVED_OK`
31. `DB18_FOLDER15_PRESERVED_OK`
32. `DB18_RICH16_PRESERVED_OK`
33. `DB18_RICH_PG_PRESERVED_OK`
34. `DB18_LSP12_PRESERVED_OK`

Owner partition:

| Owner | Count | Markers |
|-------|-------|---------|
| `ci/headless/check_db_nesting.lua` | 29 | DB18 behavior markers 1-29. |
| `ci/headless/check_ux13_rollup.lua` | 5 | Preservation markers 30-34 plus `DB18_STRICT_MARKER_COUNT=34` and `DB18_ALL_PASS=true`. |

## Verification Summary

Final verification after Wave 3:

```bash
env GOCACHE=/tmp/codex-go-cache go -C dbee test ./adapters
make perf-headless ARGS='-l ci/headless/check_db_nesting.lua'
make perf-lsp
```

`make perf-lsp` must report:

- `ARCH14_ALL_PASS=true`
- `FOLDER15_ALL_PASS=true`
- `RICH16_ALL_PASS=true`
- `RICH_PG_ALL_PASS=true`
- `LSP12_HOVER_RESOLVE_ALL_PASS=true`
- `DB18_STRICT_MARKER_COUNT=34`
- `DB18_ALL_PASS=true`

## Threat Model

Primary risk is semantic drift in shared drawer topology. Adapter-aware gating prevents extra redundant layers for MySQL/ClickHouse/SQLite and prevents PostgreSQL-style expectations from leaking into Oracle or BigQuery. Backward-compat risk is expansion-state churn: replay migration must bridge old flat schema IDs to new DB-parent schema IDs. Performance risk is accidental RPC work during filtering or root rendering; headless fixtures must assert zero new metadata/schema RPCs for search/filter and must preserve Phase 14 lazy root behavior.

## Concerns For Implementation Gate

- `database_switch_node` is currently both a visual row and an action host. Wave 1 must replace the visual row only for nested adapters while preserving the switch action on the active DB container.
- The stable database ID deliberately ignores database name, so implementation must update displayed node name on switch without changing ID.
- `schemas_only` roots are easy to miss because they populate the same root cache with synthetic schema rows. Wave 1 must wrap this mode too.
- `check_db_nesting.lua` should exercise real drawer construction paths, not only static source greps.
- `check_ux13_rollup.lua` will need to validate DB18 behavior markers from the runtime log before emitting `DB18_ALL_PASS=true`; source-only marker presence is not sufficient.

## v1.5 Backlog Notes

- Deferred LOW plan-gate polish: consider a separately published DB-nesting replay microbenchmark if future adapter/schema counts grow beyond the Phase 18 10k replay fixture. Phase 18 already requires O(N) migration and no-refetch replay behavior, but it does not introduce a new standalone DRAW/LSP perf budget marker.
