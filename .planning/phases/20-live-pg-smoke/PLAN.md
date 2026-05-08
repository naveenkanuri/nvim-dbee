# Phase 20: Live-PG Smoke Test - Coordination Plan

**Status:** Ready for r5 plan-gate after r4 narrow fold
**Created:** 2026-05-07
**Revised:** 2026-05-08 r4 narrow fold
**Mode:** single-wave plan after combined discuss + research + plan

<objective>
Add a live PostgreSQL smoke lane that catches PostgreSQL SQL-shape regressions for Phase 17 rich metadata queries by running them against a real digest-pinned PostgreSQL 16 container through podman or docker.
</objective>

<coordination>
## Plan Index

| Plan | Wave | Objective | Depends On |
| --- | --- | --- | --- |
| `20-01-PLAN.md` | 1 | Build the live PG fixture, shape preflight, smoke tests, marker rollup, Makefile target, and CI job | Phase 17 shipped |

Single-wave remains intentional. The fixture, live tests, runtime preflight, marker rollup, and CI job are one coupled validation surface. Splitting them would create half-integrated marker and lifecycle states without useful parallelism.
</coordination>

<locked_decisions>
## Locked Decisions

- Runtime: support both podman and docker, with health-aware detection.
- Primary PostgreSQL version: digest-pinned `postgres:16-alpine@sha256:4e6e670bb069649261c9c18031f0aded7bb249a5b6664ddec29c013a89310d50` (manifest digest resolved 2026-05-07).
- Fixture strategy: SQL seed file plus Go assertions, not a Go-only schema builder.
- Isolation: one shared container per smoke suite; tests are read-only after seed except explicitly isolated negative SQL.
- CI gating: local skip when no healthy runtime; CI fails loud with `LIVE_PG20_REQUIRED=1`.
- Rollup: separate `LIVE_PG20_ROLLUP_LOG`; do not contaminate `UX13_ROLLUP_LOG`.
- Scope correction: sequence `current_value` is out of Phase 20 because production SQL/types do not expose it and production SQL must not change.
- Smoke test discovery: live PG smoke files use `*_smoke_test.go` plus Go build tag `live_pg20`; bare `go test ./tests/integration` must not compile or run the smoke.
- Phase 17 SQL constants remain locked; Phase 20 may add same-package shape tests but must not edit `postgres_driver_rich_metadata.go`.
- Historical negative SQL must be the exact pre-fix Phase 17 FK SQL shape from commit `be58045^`, not synthetic multi-array `unnest(ARRAY..., ARRAY...)`.
- Snapshot uses an external readable JSON golden with a narrow allowlist and an explicit `UPDATE_GOLDEN=1 make live-pg-smoke` regeneration flow.
- Runtime health probes are bounded Go subprocesses: `make live-pg-smoke` invokes the shared Go probe command; shell probe fallbacks are forbidden.
- No-runtime paths are non-success paths: do not emit `LIVE_PG20_STRICT_MARKER_COUNT` unless the live suite actually reaches strict-marker verification.
- No-runtime paths run before strict marker emission; they may emit only `LIVE_PG20_SKIPPED_NO_RUNTIME=true`, `LIVE_PG20_DETECT_MS=<ms>`, `PHASE20_ALL_PASS=false`, and the PG20-38 diagnostic.
- SQL-shape preflight seals all five PostgreSQL rich metadata SQL constants with structural assertions, with the foreign-key `ROWS FROM` shape remaining the highest-risk guard.
- The SQL-shape marker is split: source preflight and live ROWS FROM execution emit separate strict markers.
</locked_decisions>

<decision_coverage>
## Decision Coverage Added In r1/r2/r3/r4 Folds

| Decision | Covers |
| --- | --- |
| `PG20-23` | Historical source of truth is commit `be58045`; `c3dd1a8` is not the Phase 17 PG fix commit |
| `PG20-24` | Exact SQL-constant shape preflight over `postgresForeignKeysSQL` after runtime detection and before container start |
| `PG20-25` | Historical negative test uses exact old FK SQL and must be live-verified to fail before marker emission |
| `PG20-26` | Smoke test build tag and `_smoke_test.go` suffix prevent bootstrap matrix auto-enrollment |
| `PG20-27` | Runtime detection selects one provider and passes `LIVE_PG20_CONTAINER_PROVIDER` to Go |
| `PG20-28` | Shared `GetContainerProvider()` signature remains unchanged for existing integration helpers |
| `PG20-29` | New container helper cleans up on every post-start failure and registers cleanup immediately |
| `PG20-30` | Negative SQL uses a dedicated `*sql.DB`, deferred close, and no shared driver pool |
| `PG20-31` | Snapshot golden field allowlist, denylist, and digest pin |
| `PG20-32` | Snapshot update flow keeps readable JSON diffs and avoids binary `.gitattributes` |
| `PG20-33` | Makefile rollup uses `set -eu`, one `emit_marker`, fail-loud marker guards, and false marker on failure |
| `PG20-34` | `LIVE_PG20_STRICT_MARKER_COUNT=19` is the strict count contract |
| `PG20-35` | CI job overrides root working directory and exports a stable rollup artifact path |
| `PG20-36` | CI job has `timeout-minutes: 10`, Go `-timeout=10m`, and container context timeout |
| `PG20-37` | CI invokes non-sudo outer `make live-pg-smoke`; any sudo is confined to the inner live-test target after pre-sudo checks |
| `PG20-38` | Required-mode no-runtime failure message is exact and cross-platform parseable |
| `PG20-39` | Non-strict timing markers record detect/container/seed/suite duration and wall-clock budget |
| `PG20-40` | Phase 21 downstream shape contract is asserted on live `Column`/`FKRef` values |
| `PG20-41` | Provider health probes are subprocess-timeout bounded in the shared Go probe; shell probe fallback removed |
| `PG20-42` | No-runtime marker accounting runs before strict markers and emits only skip/detect-ms/fail evidence |
| `PG20-43` | Shape preflight covers all five PostgreSQL rich metadata SQL constants |
| `PG20-44` | CI fetches enough history and runs locked-helper Git checks before sudo escalation |
| `PG20-45` | Split SQL-shape preflight and live ROWS FROM markers; strict count becomes 19 |
</decision_coverage>

<strict_markers>
## Strict Markers

The implementation plan owns 19 strict rollup records: 18 boolean markers plus the exact count marker. `PHASE20_ALL_PASS` is the rollup gate and is not counted as a strict marker.

| Marker | Expected | Meaning |
| --- | --- | --- |
| `LIVE_PG20_RUNTIME_DETECTED_OK` | `true` | `live-pg-smoke` found one healthy podman/docker provider within bounded health probes |
| `LIVE_PG20_CONTAINER_READY_OK` | `true` | Testcontainers started PostgreSQL and returned a usable connection string |
| `LIVE_PG20_SEED_OK` | `true` | Rich metadata fixture schemas/tables/views/MVs/sequences exist after init |
| `LIVE_PG20_SUPPORT_OK` | `true` | `SupportsRichMetadata()` returns columns/indexes/sequences true |
| `LIVE_PG20_COLUMNS_RICH_OK` | `true` | Live `GetColumnsRich` returns generated/default/identity/nullability fields |
| `LIVE_PG20_COMPOSITE_PK_OK` | `true` | Live composite PK ordinals match fixture order |
| `LIVE_PG20_FK_COMPOSITE_OK` | `true` | Live composite FK pairing returns full source/target column arrays in ordinal order |
| `LIVE_PG20_SQL_SHAPE_PREFLIGHT_OK` | `true` | Same-package SQL-constant preflight passed before any container startup |
| `LIVE_PG20_ROWS_FROM_LIVE_OK` | `true` | Production composite-FK ROWS FROM SQL succeeded on live PostgreSQL |
| `LIVE_PG20_HISTORICAL_UNNEST_NEGATIVE_OK` | `true` | Exact historical broken FK SQL shape fails on live PostgreSQL |
| `LIVE_PG20_INDEXES_OK` | `true` | Live table indexes return key columns, order, uniqueness, PK-backed state, and INCLUDE separation |
| `LIVE_PG20_MV_INDEXES_OK` | `true` | Live materialized-view indexes return through `GetIndexes` |
| `LIVE_PG20_VIEW_NO_INDEXES_OK` | `true` | Regular view index lookup returns empty without failure |
| `LIVE_PG20_SEQUENCE_OK` | `true` | Live schema sequences return name/schema/increment/cache-size only |
| `LIVE_PG20_MULTI_SCHEMA_OK` | `true` | Fixture includes and queries multiple schemas |
| `LIVE_PG20_SCHEMA_SCOPE_OK` | `true` | Same/similar object names in other schemas do not leak into requested schema results |
| `LIVE_PG20_SNAPSHOT_OK` | `true` | Canonical live metadata snapshot matches the expected deterministic fixture |
| `LIVE_PG20_LOCKED_HELPERS_UNTOUCHED_OK` | `true` | Git diff proves the three locked helpers are untouched |
| `LIVE_PG20_STRICT_MARKER_COUNT` | `19` | Rollup reports exact strict record count, including this count record |
| `PHASE20_ALL_PASS` | `true` | Rollup gate after every strict record is present exactly once with the expected value |

Non-strict advisory/gated timing markers: `LIVE_PG20_DETECT_OK`, `LIVE_PG20_DETECT_SLOW`, `LIVE_PG20_DETECT_MS`, `LIVE_PG20_CONTAINER_MS`, `LIVE_PG20_SEED_MS`, `LIVE_PG20_SUITE_DURATION_S`, `LIVE_PG20_WALL_CLOCK_BUDGET_S`, `LIVE_PG20_WALL_CLOCK_OK`.
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
go -C dbee test ./adapters -run 'TestPostgresRichMetadata|TestPostgresForeignKeysSQLRowsFromShape' -v
go -C dbee test ./tests/integration -run '^TestPostgresLiveRichMetadataSmoke$' -count=1 -v
```

The second command above must not run the smoke without `-tags live_pg20`; it is the bootstrap auto-enrollment guard.
</verification>

<scope_fence>
## Scope Fence

Implementation may modify only:
- `Makefile`
- `.github/workflows/test.yml`
- `dbee/cmd/probe-runtime/main.go`
- `dbee/adapters/postgres_driver_rich_metadata_shape_test.go`
- `dbee/tests/testhelpers/helper.go`
- `dbee/tests/testhelpers/postgres_rich_metadata.go`
- `dbee/tests/testdata/postgres_rich_metadata_seed.sql`
- `dbee/tests/testdata/postgres_rich_metadata_snapshot.json`
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
| Podman binary exists but machine is stopped | Shared Go probe uses bounded `podman info` probes with 5s subprocess timeout, not executable checks only |
| Docker available in CI but local podman shadows it | Detection falls back to healthy Docker and passes selected provider to Go |
| Runtime unavailable on a developer machine | Local target emits exact skip marker/message and exits 0 unless `LIVE_PG20_REQUIRED=1` |
| CI silently skips the live smoke | CI sets `LIVE_PG20_REQUIRED=1`; missing runtime exits nonzero |
| Smoke test accidentally joins integration matrix | `_smoke_test.go` suffix plus `live_pg20` build tag; bootstrap glob remains `*_integration_test.go` |
| Fixture contamination | Fresh container per suite plus idempotent `DROP SCHEMA IF EXISTS ... CASCADE`; negative SQL uses dedicated DB |
| Orphaned containers on helper error | Helper cleans up on every post-start error and test registers cleanup immediately |
| Snapshot flakes from unordered catalog rows or PG drift | Canonical sort, field allowlist/denylist, readable text JSON golden, digest-pinned image, explicit update flow |
| False confidence from sqlmock | Shape test validates SQL constant; live tests call public driver methods against real PostgreSQL parser/executor |
| Rollup pollution | Use `LIVE_PG20_ROLLUP_LOG`, not `UX13_ROLLUP_LOG` |
| Rollup false green | `set -eu`, per-marker guards exit nonzero, `PHASE20_ALL_PASS=true` only on success |
| CI runner waste on stalled runtime/pull/container | Runtime health probes timeout at 5s, CI timeout 10m, Go timeout 10m, container context timeout |
| Locked helper accidental edit | `LIVE_PG20_LOCKED_HELPERS_UNTOUCHED_OK` requires clean git diff for all three helpers before any sudo escalation |
| CI shallow checkout hides base ref | `live-pg20-smoke` checkout uses full history or explicit fetch before `git merge-base HEAD origin/master` |
</threat_model>

<acceptance>
## Acceptance Criteria

- `make live-pg-smoke` detects a healthy podman/docker runtime first; no-runtime paths skip/fail before any strict marker, and healthy paths then run source-shape preflight before container startup.
- `LIVE_PG20_REQUIRED=1 make live-pg-smoke` fails with the exact no-runtime message if no healthy runtime exists, including `timeout after 5s` detail for hung probes.
- Successful run emits all 19 strict records listed above and `PHASE20_ALL_PASS=true`.
- The live suite proves the Phase 17 composite FK production SQL succeeds and the exact historical broken FK SQL fails.
- Bare `go -C dbee test ./tests/integration -run '^TestPostgresLiveRichMetadataSmoke$'` does not compile/run the smoke without `-tags live_pg20`.
- No production PostgreSQL SQL constants are modified.
- No locked helper files are modified.
</acceptance>

---

*Phase: 20-live-pg-smoke*
Post-SHIP note: fold the r0/r1/r2/r3/r4 decision trail into `project_v14_phase20_shipped.md` and keep this phase directory as raw review history.

*Coordination plan revised: 2026-05-08 r4 narrow fold*
