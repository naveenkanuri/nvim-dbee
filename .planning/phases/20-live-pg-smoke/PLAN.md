# Phase 20: Live-PG Smoke Test - Coordination Plan

**Status:** Ready to execute
**Created:** 2026-05-07
**Mode:** single-wave plan after combined discuss + research + plan

<objective>
Add a live PostgreSQL smoke lane that catches PostgreSQL SQL-shape regressions for Phase 17 rich metadata queries by running them against a real `postgres:16-alpine` container through podman or docker.
</objective>

<coordination>
## Plan Index

| Plan | Wave | Objective | Depends On |
| --- | --- | --- | --- |
| `20-01-PLAN.md` | 1 | Build the live PG fixture, smoke tests, marker rollup, Makefile target, and CI job | Phase 17 shipped |

Single-wave is intentional. The implementation is cohesive and touches one test surface; splitting fixture, tests, and Makefile/CI would create coordination overhead without enabling useful parallelism.

</coordination>

<locked_decisions>
## Locked Decisions

- Runtime: support both podman and docker, with health-aware detection.
- Primary PostgreSQL version: `postgres:16-alpine`.
- Fixture strategy: SQL seed file plus Go assertions, not a Go-only schema builder.
- Isolation: one shared container per smoke suite; tests are read-only after seed.
- CI gating: local skip when no healthy runtime; CI fails loud with `LIVE_PG20_REQUIRED=1`.
- Rollup: separate `LIVE_PG20_ROLLUP_LOG`; do not contaminate `UX13_ROLLUP_LOG`.
- Scope correction: sequence `current_value` is out of Phase 20 because production SQL/types do not expose it and production SQL must not change.

</locked_decisions>

<strict_markers>
## Strict Markers

The implementation plan owns these strict markers:

| Marker | Meaning |
| --- | --- |
| `LIVE_PG20_RUNTIME_DETECTED_OK` | `live-pg-smoke` found a healthy podman or docker runtime, or failed required mode before tests |
| `LIVE_PG20_CONTAINER_READY_OK` | Testcontainers started PostgreSQL and returned a usable connection string |
| `LIVE_PG20_SEED_OK` | Rich metadata fixture schemas/tables/views/MVs/sequences exist after init |
| `LIVE_PG20_SUPPORT_OK` | `SupportsRichMetadata()` returns columns/indexes/sequences true |
| `LIVE_PG20_COLUMNS_RICH_OK` | Live `GetColumnsRich` returns generated/default/identity/nullability fields |
| `LIVE_PG20_COMPOSITE_PK_OK` | Live composite PK ordinals match fixture order |
| `LIVE_PG20_FK_COMPOSITE_OK` | Live composite FK pairing returns full source/target column arrays in ordinal order |
| `LIVE_PG20_ROWS_FROM_SQL_SHAPE_OK` | Production composite-FK SQL succeeds on live PostgreSQL |
| `LIVE_PG20_HISTORICAL_UNNEST_NEGATIVE_OK` | Historical malformed multi-array `pg_catalog.unnest` shape fails on live PostgreSQL |
| `LIVE_PG20_INDEXES_OK` | Live table indexes return key columns, order, uniqueness, PK-backed state, and INCLUDE separation |
| `LIVE_PG20_MV_INDEXES_OK` | Live materialized-view indexes return through `GetIndexes` |
| `LIVE_PG20_VIEW_NO_INDEXES_OK` | Regular view index lookup returns empty without failure |
| `LIVE_PG20_SEQUENCE_OK` | Live schema sequences return name/schema/increment/cache-size only |
| `LIVE_PG20_MULTI_SCHEMA_OK` | Fixture includes and queries multiple schemas |
| `LIVE_PG20_SCHEMA_SCOPE_OK` | Same/similar object names in other schemas do not leak into requested schema results |
| `LIVE_PG20_SNAPSHOT_OK` | Canonical live metadata snapshot matches the expected deterministic fixture |
| `LIVE_PG20_LOCKED_HELPERS_UNTOUCHED_OK` | Git diff proves the three locked helpers are untouched |
| `LIVE_PG20_STRICT_MARKER_COUNT` | Rollup reports exact strict marker count, expected `17` |
| `PHASE20_ALL_PASS` | Rollup gate after every strict marker is present exactly once with value `true` |

</strict_markers>

<verification>
## Verification Commands

Primary:

```bash
make live-pg-smoke
```

CI-shaped:

```bash
LIVE_PG20_REQUIRED=1 make live-pg-smoke
```

Preservation:

```bash
go -C dbee test ./adapters -run 'TestPostgresRichMetadata' -v
```

</verification>

<scope_fence>
## Scope Fence

Implementation may modify only:
- `Makefile`
- `.github/workflows/test.yml`
- `dbee/tests/testhelpers/helper.go`
- `dbee/tests/testhelpers/postgres_rich_metadata.go`
- `dbee/tests/testdata/postgres_rich_metadata_seed.sql`
- `dbee/tests/testdata/postgres_rich_metadata_snapshot.json` if an external golden is chosen
- `dbee/tests/integration/postgres_rich_metadata_smoke_test.go`

Implementation must read but not modify:
- `dbee/adapters/postgres_driver_rich_metadata.go`
- `dbee/core/types.go`
- `lua/dbee/schema_filter_authority.lua`
- `lua/dbee/schema_name_canonical.lua`
- `lua/dbee/lsp/epoch_authority.lua`

</scope_fence>

<threat_model>
## Threat Model

| Threat | Mitigation |
| --- | --- |
| Podman binary exists but machine is stopped | Makefile and helper use health checks, not executable checks only |
| Docker available in CI but local podman shadows it | Provider detection falls back to healthy Docker when podman is unhealthy |
| Runtime unavailable on a developer machine | Local target emits skip marker and exits 0 unless `LIVE_PG20_REQUIRED=1` |
| CI silently skips the live smoke | CI sets `LIVE_PG20_REQUIRED=1`; missing runtime fails |
| Fixture contamination | Fresh container per suite plus idempotent `DROP SCHEMA IF EXISTS ... CASCADE` seed |
| Snapshot flakes from unordered catalog rows | Canonicalize and sort all snapshot data before comparison |
| PostgreSQL version drift | Pin PG16 image; defer version matrix |
| False confidence from sqlmock | Live tests call public driver methods against real PostgreSQL parser/executor |
| Rollup pollution | Use `LIVE_PG20_ROLLUP_LOG`, not `UX13_ROLLUP_LOG` |
| Locked helper accidental edit | `LIVE_PG20_LOCKED_HELPERS_UNTOUCHED_OK` requires clean git diff for all three helpers |

</threat_model>

<acceptance>
## Acceptance Criteria

- `make live-pg-smoke` starts PostgreSQL through a healthy podman/docker runtime or skips locally with `LIVE_PG20_SKIPPED_NO_RUNTIME=true`.
- `LIVE_PG20_REQUIRED=1 make live-pg-smoke` fails if no healthy runtime exists.
- Successful run emits every `LIVE_PG20_*` strict marker listed above and `PHASE20_ALL_PASS=true`.
- The live suite proves the Phase 17 composite FK production SQL succeeds and the historical malformed SQL fails.
- No production PostgreSQL SQL constants are modified.
- No locked helper files are modified.

</acceptance>

---

*Phase: 20-live-pg-smoke*
*Coordination plan created: 2026-05-07*
