# Phase 17 - Rich Table Metadata X.2: PostgreSQL Adapter

**Milestone:** v1.4  
**Status:** Planned  
**Date:** 2026-05-04  
**Requirement:** DBEE-FEAT-04 (rich metadata multi-adapter coverage)  
**Reference:** Phase 16 Oracle X.1 is shipped and locked; Phase 17 reuses its handler, event, singleflight, backpressure, drawer, and FK navigation architecture.

## Goal

Enable PostgreSQL connections to use the Phase 16 rich metadata drawer shape:

- Per-table `Columns` and `Indexes` folders, per-regular-view `Columns` folder only, and per-materialized-view `Columns` plus `Indexes` folders when PostgreSQL capability is true.
- Per-schema `Sequences` folder when PostgreSQL capability is true.
- PostgreSQL-specific column/index annotations: `[GEN]`, `[IDENTITY]`, `[DEFAULT=...]`, and `[INCLUDE col_a, col_b]`.
- Composite PK/FK metadata with ordinal pairing equivalent to Oracle X.1.
- Materialized views labeled as `materialized_view` and treated as table-like drawer nodes.

PostgreSQL is the only adapter implemented in this phase. MySQL, SQLite, ClickHouse, MongoDB, and other adapters remain out of scope.

## Inputs Read

- `.planning/phases/17-rich-table-metadata-postgres/17-CONTEXT.md`
- `.planning/phases/17-rich-table-metadata-postgres/17-RESEARCH-CODEX.md`
- `.planning/phases/17-rich-table-metadata-postgres/17-RESEARCH-CLAUDE.md`
- `.planning/phases/16-rich-table-metadata/PLAN.md`
- `dbee/adapters/oracle_driver.go`
- `dbee/adapters/oracle_driver_rich_metadata_test.go`
- `ci/headless/check_rich_metadata.lua`

## Locked Contracts

- Do not edit `lua/dbee/schema_filter_authority.lua`, `lua/dbee/schema_name_canonical.lua`, or `lua/dbee/lsp/epoch_authority.lua`.
- Reuse `structure_children_loaded`; do not add new rich metadata event names.
- Reuse Phase 16 Lua singleflight/backpressure unchanged: table key `(conn_id, schema, table, materialization, root_epoch, schema_filter_signature, kind)`, sequence key schema-scoped, `max_active=8`, `max_queue=128`, loud retryable `queue_full`.
- Reuse direct FK navigation. Do not route FK jumps through `perform_action()`.
- PostgreSQL SQL uses native positional binds only: `$1`, `$2`; never `sql.Named` or named placeholders.
- PostgreSQL rich metadata floor is PostgreSQL 12+.
- Additive fields must preserve old client decoding: `json:",omitempty"` and `msgpack:",omitempty"` for every new optional field.
- `RICH16_*` markers must remain green. Phase 17 adds `RICH_PG_*` markers.

## Wave Breakdown

| Wave | Plan | Objective | Depends On |
|------|------|-----------|------------|
| 1 | `17-01-PLAN.md` | Extend Go core metadata types additively and prove backward compatibility. | None |
| 2 | `17-02-PLAN.md` | Add PostgreSQL `SupportsRichMetadata`, `ColumnsRich`, `Indexes`, and `Sequences` using `pg_catalog` SQL. | Wave 1 |
| 3 | `17-03-PLAN.md` | Relabel PostgreSQL materialized views and admit `materialized_view` through drawer searchable/table-like gates plus LSP metadata/hover/completion paths. | Wave 2 |
| 4 | `17-04-PLAN.md` | Extend msgpack and Lua event serialization for new Column/Index fields. | Wave 1 |
| 5 | `17-05-PLAN.md` | Render PostgreSQL annotations and enforce view-vs-MV index-folder topology. | Waves 1, 3, 4 |
| 6 | `17-06-PLAN.md` | Add strict PostgreSQL Go and headless marker coverage and wire into the real headless loop. | Waves 1, 2, 3, 4, 5 |

## Decision Coverage

| Decision | Covered By | Success Criterion |
|----------|------------|-------------------|
| PG-01 | Wave 2, Wave 6 | Only PostgreSQL production/test files are added for adapter rich metadata. |
| PG-02 | Waves 2-6 | No new endpoints, events, public wrappers, or drawer topology beyond existing rich metadata folders. |
| PG-03 | Wave 2 | `postgresDriver.SupportsRichMetadata()` returns columns/indexes/sequences true. |
| PG-04 | Wave 2, Wave 6 | PostgreSQL SQL constants contain `$1/$2`; tests reject `sql.Named` and named placeholders. |
| PG-05 | Wave 6 | Behavioral `RICH_PG_*` fixtures prove Phase 16 singleflight materialization, fanout, supersession, backpressure caps, queue drain, and queue retry behavior remains present. |
| PG-06 | Waves 3-5 | Lua shared changes are limited to `materialized_view` table-like/search/LSP materialization support and additive rendering/serialization. |
| PG-07 | Wave 2 | Rich PostgreSQL SQL uses `pg_catalog` tables/functions, not `information_schema` or `pg_indexes`. |
| PG-08 | Wave 2 | Column/index/sequence queries scope by `pg_namespace.nspname = $1`. |
| PG-09 | Wave 2 | Adapter compares bound schema/table strings to `nspname`/`relname` without Go case folding. |
| PG-10 | Wave 6 | Schema-filter no-query marker remains green without editing locked authority helpers. |
| PG-11 | Wave 2 | `ColumnsRich()` populates type, nullable, generated, identity, default, and serial-sequence metadata. |
| PG-12 | Wave 5 | Generated columns render `[GEN]` when `generated` is non-empty. |
| PG-13 | Wave 5 | Non-generated columns with non-empty default render deterministic `[DEFAULT=...]` with UTF-8-safe truncation. |
| PG-14 | Waves 2, 5 | Identity columns capture `attidentity` and render `[IDENTITY]`; serial stays column metadata only. |
| PG-15 | Wave 2 | Composite PK ordinals from `conkey WITH ORDINALITY` populate `PrimaryKeyOrdinal`. |
| PG-16 | Wave 2 | Composite FKs pair `conkey/confkey` by parallel ordinality, copy full arrays per source column, and allocate distinct FKRef pointers per source column. |
| PG-17 | Wave 2 | `Indexes()` uses `pg_index`, `pg_class`, `pg_namespace`, `pg_attribute`, and `pg_get_indexdef`. |
| PG-18 | Wave 2, Wave 5 | `indisprimary` maps to `PKBacked`; drawer keeps hiding `pk_backed=true`. |
| PG-19 | Waves 1, 2, 5 | `Index.IncludeColumns` stores INCLUDE columns separately and renders capped `[INCLUDE ...]` labels. |
| PG-20 | Wave 2 | ASC/DESC orders attach only to key columns, never include columns. |
| PG-21 | Wave 2 | Expression index keys use `pg_get_indexdef(indexrelid, ordinal, true)` display strings. |
| PG-22 | Wave 2 | `Sequences(schema)` uses `pg_class.relkind='S'` joined to `pg_sequence`. |
| PG-23 | Wave 2 | Sequences remain schema-folder children only; serial/identity do not create table-local folders. |
| PG-24 | Waves 3, 5 | MVs are labeled `materialized_view`, pass searchable/table-like drawer admission, preserve refresh expansion/yank/LSP materialization parity, and get Columns/Indexes folder treatment; regular views keep Columns-only treatment and do not render an empty Indexes folder or issue index RPCs. |
| PG-25 | Waves 2, 3 | Partitioned tables are included as ordinary table-like relations in rich metadata SQL and LSP metadata fallback; no partition tree is added. |
| PG-26 | Wave 6 | Strict PostgreSQL adapter tests use `go-sqlmock`; no live database required. |
| PG-27 | Wave 6 | Integration testcontainers remain optional; strict markers do not require Docker. |
| PG-28 | Wave 6 | `RICH_PG_*` marker family covers support, PG12 floor behavior, binds, catalog scoping, columns, labels, PK/FK pointer safety, indexes, include width cap, view no-indexes behavior, sequences, schema filter, MV columns/indexes, behavioral backpressure/fanout/supersession, zero-RPC scale, 10k render budget, Go-parse benchmark, and runtime rollup. |
| PG-29 | Wave 6 | `RICH16_*` script still runs and the PostgreSQL script has distinct `RICH_PG_*` names. |

**Success criteria count:** 29.

## Threat Model

<threat_model>
Primary risks are correctness and compatibility, not external input security. SQL injection risk is controlled by positional bind parameters and catalog-bound object identity. Backward-compat risk is controlled by additive JSON/msgpack fields with `omitempty`. UI correctness risk is controlled by preserving Phase 16 lazy loading, stale guards, and FK direct dispatch. Denial-of-service risk is controlled by reusing existing queue caps without changing the locked singleflight implementation.
</threat_model>

## Verification Summary

Required final verification after Wave 6:

```bash
set -o pipefail
RICH_PG_LOG="${TMPDIR:-/tmp}/rich-pg-runtime.log"
: > "$RICH_PG_LOG"
go -C dbee test ./core ./handler ./adapters -v 2>&1 | tee -a "$RICH_PG_LOG"
go -C dbee test ./adapters -run '^$' -bench 'BenchmarkPostgresRichMetadataGoParse' -benchtime=20x -benchmem -v 2>&1 | tee -a "$RICH_PG_LOG"
make perf-headless ARGS='-l ci/headless/check_rich_metadata.lua'
UX13_ROLLUP_LOG="$RICH_PG_LOG" make perf-headless ARGS='-l ci/headless/check_rich_metadata_postgres.lua'
make perf-lsp
```

## PostgreSQL Strict Markers

`RICH_PG_STRICT_MARKER_COUNT` is **35**. `RICH_PG_ALL_PASS` is the rollup and must require all strict markers to be emitted at runtime across the Go marker tests, Go-parse benchmark, and Lua headless script. Source-only marker presence checks do not satisfy the rollup. Owner-only enforcement is required: Lua-owned markers may be emitted by the Lua script, Go/benchmark-owned markers must come from parsed Go stdout, and wrong-source same-value duplicates must fail loud. `RICH_PG_PERF_DIAGNOSTIC` and `RICH_PG_BENCH_PG_RUNTIME_P95_REPORTED` are reported diagnostics and excluded from the strict count.

Strict markers:

1. `RICH_PG_GO_TYPES_BACKWARD_COMPAT`
2. `RICH_PG_MARSHAL_ADDITIVE_FIELDS_OK`
3. `RICH_PG_SUPPORT_TRUE`
4. `RICH_PG_PG12_FLOOR_BEHAVIOR_OK`
5. `RICH_PG_POSITIONAL_BINDS`
6. `RICH_PG_CATALOG_SCOPING`
7. `RICH_PG_RICH_COLUMNS_OK`
8. `RICH_PG_GENERATED_LABEL_OK`
9. `RICH_PG_DEFAULT_LABEL_OK`
10. `RICH_PG_DEFAULT_UTF8_TRUNCATION_OK`
11. `RICH_PG_IDENTITY_LABEL_OK`
12. `RICH_PG_COMPOSITE_PK_OK`
13. `RICH_PG_COMPOSITE_FK_OK`
14. `RICH_PG_FK_REF_POINTER_PER_COLUMN_OK`
15. `RICH_PG_INDEXES_OK`
16. `RICH_PG_INCLUDE_COLUMNS_OK`
17. `RICH_PG_INCLUDE_LABEL_WIDTH_OK`
18. `RICH_PG_PK_BACKED_HIDDEN`
19. `RICH_PG_SEQUENCES_OK`
20. `RICH_PG_SCHEMA_FILTER_NO_QUERY_OK`
21. `RICH_PG_MATERIALIZED_VIEW_FOLDER_OK`
22. `RICH_PG_MATERIALIZED_VIEW_COLUMNS_OK`
23. `RICH_PG_MATERIALIZED_VIEW_INDEXES_OK`
24. `RICH_PG_VIEW_NO_INDEXES_FOLDER_OK`
25. `RICH_PG_WAITER_FANOUT_ISOLATED`
26. `RICH_PG_SUPERSESSION_PRESERVES_ACTIVE_SLOT`
27. `RICH_PG_QUEUE_FULL_RETRYABLE`
28. `RICH_PG_BACKPRESSURE_MAX_ACTIVE_BOUNDED`
29. `RICH_PG_BACKPRESSURE_QUEUE_DRAIN_OK`
30. `RICH_PG_BACKPRESSURE_HANDLER_OVERFLOW_REJECTS_OK`
31. `RICH_PG_FANOUT_DISPATCH_COUNT_OK`
32. `RICH_PG_QUEUE_DRAIN_SLA`
33. `RICH_PG_SCALE_10K_ZERO_RPC_OK`
34. `RICH_PG_SCALE_10K_RENDER_BUDGET_OK`
35. `RICH_PG_BENCH_GO_PARSE_P95_OK`

## Concerns For Implementation Gate

- `gsd-sdk init.plan-phase` only recognizes default `*-RESEARCH.md`, but this phase intentionally has `17-RESEARCH-CODEX.md` and `17-RESEARCH-CLAUDE.md`; plan artifacts treat both as research sources.
- `.planning/REQUIREMENTS.md` has not yet been extended with `DBEE-FEAT-04`; the Phase 17 requirement ID comes from `.planning/ROADMAP.md`.
- PostgreSQL 10/11 are below the rich metadata floor. Phase 17 explicitly fails loud from rich methods below PG12; it does not add a capability-probe fallback.
- `materialized_view` support requires `drawer/model.lua` `SEARCHABLE_TYPES`, `TABLE_LIKE_TYPES`, `_capture_container_expansions`, `yankable_types`, `convert.decorate_structure_node`, and all LSP materialization gates (`lsp/init.lua` PostgreSQL metadata fallback, `schema_cache.lua` completion kind/constant/flatten/load/fallback, `server.lua` probe args, and `object_docs.lua` hover labels); updating only one is insufficient.
- Wave 3 is intentionally larger than the other waves because MV type propagation is cross-cutting. Review it as two slices during impl-gate: drawer admission/action replay and LSP metadata/hover/completion resolution.
- `lua/dbee/ui/drawer/convert.lua` is touched by Wave 3 and Wave 5; Wave 5 depends on Wave 3 and must preserve the Wave 3 materialized-view gates while adding labels.
- Wave 5 must gate `_build_rich_table_children` so regular views receive Columns only while tables and materialized views receive Indexes when capability allows it.
- v1.5 backlog note for implementation summaries: if real-server PostgreSQL rich metadata P95 exceeds 100ms, evaluate raising `max_active` from 8 to 16 instead of changing Phase 17's locked caps.
- Queue-drain SLA is strict for the fast mocked headless fixture: P95 drain time for the 200-job rich metadata queue fixture must be `<= 2s` over at least 20 post-warmup iterations.
- 10k render budget is strict for the warmed headless fixture: P95 render time for exactly 10000 rendered table-like nodes must be `<= 5s` over at least 10 post-warmup iterations, measured with `vim.loop.hrtime()` around the real `tree:set_nodes` plus `tree:render()` path under the `PERF_NVIM_HEADLESS`/`perf-bootstrap` runtimepath.
- PostgreSQL foreign tables remain labeled as `table` by existing `postgres_driver.go` behavior. Phase 17 does not relabel them; rich Columns work, and empty Indexes folders for foreign tables are acceptable because PostgreSQL does not expose `pg_index` rows for foreign tables.
