# Phase 20: Live-PG Smoke Test - Context

**Gathered:** 2026-05-07
**Revised:** 2026-05-07 r1 fold
**Status:** Ready for r2 plan-gate
**Source:** User-supplied Phase 20 task, repo validation, Phase 17 memory, local code scout, plan-gate r1 findings

<domain>
## Phase Boundary

Phase 20 adds a Docker/podman-gated live PostgreSQL smoke lane for the PostgreSQL rich metadata SQL shipped in Phase 17. It proves the five production SQL shapes in `dbee/adapters/postgres_driver_rich_metadata.go` execute against real PostgreSQL 16 and return the existing `core.Column`, `core.Index`, and `core.Sequence` contracts.

In scope:
- PostgreSQL only.
- Live container fixture for a deterministic rich metadata schema.
- Same-package adapter shape test for the locked `postgresForeignKeysSQL` constant.
- Focused live integration test for `SupportsRichMetadata`, `GetColumnsRich`, `GetIndexes`, and `GetSequences`.
- Makefile target `live-pg-smoke` with runtime detection, skip-graceful local behavior, fail-loud CI behavior when required, marker rollup, timing diagnostics, and container cleanup.
- GitHub Actions job on Ubuntu that runs the live PG smoke through Docker/testcontainers.

Out of scope:
- Oracle live smoke.
- Any change to Phase 17 production SQL or rich metadata production contracts.
- Any edit to the three locked helpers:
  - `lua/dbee/schema_filter_authority.lua`
  - `lua/dbee/schema_name_canonical.lua`
  - `lua/dbee/lsp/epoch_authority.lua`
- PostgreSQL version matrix beyond one digest-pinned primary version.
- Running through a Neovim UI instance.

Challenge-up:
- The proposed scope mentioned sequence `current_value`, but `core.Sequence` currently exposes only `Name`, `Schema`, `Increment`, and `CacheSize`, and `postgresSequencesSQL` returns only `sequence_name`, `increment_by`, and `cache_size`. Phase 20 must test the existing sequence contract only. Adding `current_value` would require production SQL/type changes and belongs in a separate phase.
- r1 asked for Phase 17 historical SQL from commit `c3dd1a8`, but this repo shows `c3dd1a8` is Phase 16. The Phase 17 composite-FK fix commit is `be58045` (`fix(17): composite FK SQL - use ROWS FROM...`). Phase 20 uses `be58045^` and `be58045` as the historical source pair.
- r1 suggested `dbee/adapters/export_test.go` for cross-package constant introspection. `_test.go` files in `dbee/adapters` do not expose symbols to `dbee/tests/integration`; Phase 20 instead adds a same-package adapter shape test and runs it before live container startup.
- r1 requested raw catalog `Type` in the snapshot, but `core.Column.Type` is populated from `pg_catalog.format_type` in the locked production SQL. Adding raw catalog type would require extra SQL outside the public driver path. Phase 20 excludes type text from the golden snapshot and keeps any stable type checks as direct live assertions, not snapshot drift inputs.
</domain>

<decisions>
## Implementation Decisions

### Runtime And Container Strategy
- **PG20-01:** Use the existing testcontainers-go integration pattern instead of hand-rolled `podman run` / `docker run` lifecycle scripts.
- **PG20-02:** Support both podman and docker. Local preference remains podman when healthy; CI uses Docker on Ubuntu runners.
- **PG20-03:** Improve runtime detection so an installed-but-stopped podman does not shadow a healthy Docker runtime. The `live-pg-smoke` target checks `command -v podman && podman info`, then `command -v docker && docker info`.
- **PG20-04:** Local `make live-pg-smoke` skips with `LIVE_PG20_SKIPPED_NO_RUNTIME=true` when no healthy runtime exists. CI runs with `LIVE_PG20_REQUIRED=1`, so missing runtime is a failure.
- **PG20-05:** Pin the primary image to `postgres:16-alpine@sha256:4e6e670bb069649261c9c18031f0aded7bb249a5b6664ddec29c013a89310d50`. Expose `LIVE_PG20_POSTGRES_IMAGE` for explicit local override, but do not add a version matrix in Phase 20.

### Fixture And Isolation
- **PG20-06:** Use a dedicated SQL seed file: `dbee/tests/testdata/postgres_rich_metadata_seed.sql`.
- **PG20-07:** Seed multiple schemas with deterministic names such as `pg20_sales`, `pg20_inventory`, and `pg20_analytics`.
- **PG20-08:** Seed SQL must start with `DROP SCHEMA IF EXISTS ... CASCADE` for every fixture schema, then recreate everything. This makes the fixture idempotent even though the normal lifecycle is a fresh container.
- **PG20-09:** Use one shared container per live smoke suite, not one container per assertion. Positive assertions are read-only after seed; the only deliberately failing SQL uses a dedicated `*sql.DB`.
- **PG20-10:** The fixture must include composite primary keys, composite foreign keys, generated columns, identity columns, default expressions, serial/sequence defaults, regular indexes, covering indexes with INCLUDE columns, multiple schemas, regular views, materialized views, and schema-local sequences.

### Live Assertions
- **PG20-11:** Exercise production SQL only through public driver surfaces: `Connection.SupportsRichMetadata`, `Connection.GetColumnsRich`, `Connection.GetIndexes`, and `Connection.GetSequences`.
- **PG20-12:** `GetColumnsRich` must prove composite PK ordinals and composite FK column pairing on live PostgreSQL. This directly guards the Phase 17 `ROWS FROM (unnest(), unnest()) WITH ORDINALITY` bug class.
- **PG20-13:** The historical negative sentinel uses the exact pre-fix FK SQL shape from `be58045^`: `JOIN LATERAL pg_catalog.unnest(con.conkey, con.confkey) WITH ORDINALITY ...`. Synthetic `pg_catalog.unnest(ARRAY[...], ARRAY[...])` is forbidden because it is not the historical failure class.
- **PG20-14:** `GetIndexes` must assert regular table indexes, PK-backed indexes, INCLUDE-column separation, regular-view no-index behavior, and materialized-view indexes.
- **PG20-15:** `GetSequences` must assert schema scoping plus `Name`, `Schema`, `Increment`, and `CacheSize`. Do not assert `current_value`.
- **PG20-16:** Multi-schema coverage means both adapter SQL scoping and fixture shape. The live test must prove querying one schema does not leak same-named or similarly named objects from another schema.
- **PG20-17:** Schema filter authority itself remains covered by existing headless marker `RICH_PG_SCHEMA_FILTER_NO_QUERY_OK`; Phase 20 must not touch the locked helper or require an nvim instance.
- **PG20-18:** Add a deterministic snapshot assertion over canonicalized live metadata rows for the core fixture. Keep the snapshot narrow enough to avoid encoding unstable PostgreSQL formatting.

### Rollup And CI
- **PG20-19:** Keep live-PG markers in a separate `LIVE_PG20_ROLLUP_LOG`. Do not append env-gated live-smoke evidence into `UX13_ROLLUP_LOG`.
- **PG20-20:** `make live-pg-smoke` owns the rollup gate: it tees verbose Go output, emits every Makefile marker through one log-appending helper, greps every strict marker, emits `LIVE_PG20_STRICT_MARKER_COUNT=18`, and emits `PHASE20_ALL_PASS=true` only after all strict records are present exactly once with the expected values.
- **PG20-21:** Add a GitHub Actions `live-pg20-smoke` job on `ubuntu-22.04` that runs required mode. Do not add macOS CI for this phase.
- **PG20-22:** Verification for planning/execution includes existing unit tests for Phase 17 SQL plus the new live target. The live lane is not a replacement for sqlmock; it closes the SQL-parser blind spot sqlmock cannot cover.

### r1 Fold Decisions
- **PG20-23:** Historical fix source is `be58045`, not `c3dd1a8`. Use `git show be58045^:dbee/adapters/postgres_driver_rich_metadata.go` for the broken FK SQL and `git show be58045:dbee/adapters/postgres_driver_rich_metadata.go` for the fixed `ROWS FROM` shape.
- **PG20-24:** Add `dbee/adapters/postgres_driver_rich_metadata_shape_test.go` in package `adapters`. It asserts `postgresForeignKeysSQL` contains `ROWS FROM (`, `pg_catalog.unnest(con.conkey)`, `pg_catalog.unnest(con.confkey)`, and does not contain `pg_catalog.unnest(con.conkey, con.confkey)`.
- **PG20-25:** Keep `LIVE_PG20_HISTORICAL_UNNEST_NEGATIVE_OK` only for the exact historical broken FK SQL. Before execute, the implementer must run that SQL against `postgres:16-alpine`/the digest image and confirm it fails. If it succeeds, Phase 20 must be replanned and this marker removed.
- **PG20-26:** The live smoke test file must be named `postgres_rich_metadata_smoke_test.go` and begin with `//go:build live_pg20`. Makefile passes `-tags live_pg20`; bootstrap matrix glob remains `*_integration_test.go`.
- **PG20-27:** Runtime detection produces one selected provider name (`podman` or `docker`) and passes it to Go as `LIVE_PG20_CONTAINER_PROVIDER`. Go must not silently reselect a different provider.
- **PG20-28:** `GetContainerProvider() testcontainers.ProviderType` public signature remains unchanged. On hosts where exactly one provider is healthy, return value stays the corresponding provider. No-runtime details live in the new health helper used by the smoke target.
- **PG20-29:** `NewPostgresRichMetadataContainer` must clean up the started container on every post-start error, including connection-string and adapter construction errors. The test registers `t.Cleanup(tc.CleanupContainer)` immediately after creation succeeds.
- **PG20-30:** The negative SQL sentinel opens a dedicated `sql.Open("postgres", connURL)`, defers `db.Close()`, runs one statement with context timeout, and never uses the shared `core.Connection` pool.
- **PG20-31:** Snapshot contract is external JSON only. Allowlist fields: `Name`, `Schema`, `Nullable`, `IsPrimaryKey`, `PrimaryKeyOrdinal`, `IsGenerated` bool, `IsIdentity` bool, FK source/target column names and ordinals, index names, index columns, DESC flags, INCLUDE columns, sequence name/schema/increment/cache. Denylist fields: column type text, default expression text, comments, type aliases/format aliases, `pg_get_expr` output, OIDs, owner names, timestamps.
- **PG20-32:** Add `.gitattributes` entry `dbee/tests/testdata/postgres_rich_metadata_snapshot.json binary` and an explicit golden update workflow: `UPDATE_GOLDEN=1 make live-pg-smoke`, then review the isolated snapshot diff.
- **PG20-33:** Rollup gate uses `set -eu`; any missing marker prints `PHASE20_ALL_PASS=false` and exits nonzero. `PHASE20_ALL_PASS=true` is printed only on the success path.
- **PG20-34:** `LIVE_PG20_STRICT_MARKER_COUNT=18` is the only valid count. It includes the count record itself and excludes `PHASE20_ALL_PASS`.
- **PG20-35:** CI job overrides `defaults.run.working-directory: .`, sets `LIVE_PG20_ROLLUP_LOG: ${{ runner.temp }}/live-pg20/live-pg20.log`, and uploads exactly that path with `if: always()`.
- **PG20-36:** CI job sets `timeout-minutes: 10`; Makefile runs Go with `-timeout=10m`; container setup uses `context.WithTimeout`.
- **PG20-37:** CI uses `sudo -E make live-pg-smoke` to match the existing testcontainers job's sudo posture while preserving `LIVE_PG20_*`, `PATH`, and Go cache environment.
- **PG20-38:** Required-mode no-runtime failure message is exact: `no healthy container runtime: tried podman info (status: <status>; stderr: <stderr>) and docker info (status: <status>; stderr: <stderr>); set LIVE_PG20_REQUIRED=0 to skip`.
- **PG20-39:** Add non-strict timing markers: `LIVE_PG20_DETECT_MS`, `LIVE_PG20_CONTAINER_MS`, `LIVE_PG20_SEED_MS`, `LIVE_PG20_SUITE_DURATION_S`, `LIVE_PG20_WALL_CLOCK_BUDGET_S=180`, `LIVE_PG20_WALL_CLOCK_OK=<true|false>`. Wall-clock budget is memory's 120s cold-start note multiplied by 1.5.
- **PG20-40:** Phase 21 cross-impact is part of the live contract: PK columns must have `Nullable != nil`, `PrimaryKey == true`, correct `PrimaryKeyOrdinal`, and FK refs must have equal-length `SourceColumns`/`TargetColumns` arrays in ordinal order.

### the agent's Discretion
- Exact fixture table and column names, as long as every marker has a deterministic live assertion.
- Exact helper function names in `dbee/tests/testhelpers`, as long as existing adapter integration tests keep working.
- Exact snapshot struct type names, as long as the allowlist/denylist above is enforced.
</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before implementing.**

### Phase 20 Source Of Truth
- `.planning/ROADMAP.md` - Phase 20 entry and v1.4 ordering.
- `/Users/naveenkanuri/.claude/projects/-Users-naveenkanuri-Documents-nvim-dbee/memory/MEMORY.md` lines 33-38 - Phase 17 lessons: sqlmock blind spot, podman+PG speed, composite FK SQL shape, live testing catch.
- `/Users/naveenkanuri/.claude/projects/-Users-naveenkanuri-Documents-nvim-dbee/memory/project_v14_phase17_shipped.md` - Live PG bug details and Phase 20 backlog rationale.
- `git show be58045 -- dbee/adapters/postgres_driver_rich_metadata.go` - exact Phase 17 SQL-shape fix.

### Production Code
- `dbee/adapters/postgres_driver_rich_metadata.go` - five production SQL constants and PostgreSQL rich metadata implementation to exercise, not modify.
- `dbee/core/connection.go` - public rich metadata surfaces: `SupportsRichMetadata`, `GetColumnsRich`, `GetIndexes`, `GetSequences`.
- `dbee/core/types.go` - `Column`, `FKRef`, `Index`, and `Sequence` contracts, including the absence of sequence `current_value`.
- `lua/dbee/schema_filter_authority.lua`, `lua/dbee/schema_name_canonical.lua`, `lua/dbee/lsp/epoch_authority.lua` - locked helpers that Phase 20 must not edit.

### Existing Test Infrastructure
- `dbee/tests/integration/postgres_integration_test.go` - current PostgreSQL testcontainer suite shape.
- `dbee/tests/testhelpers/postgres.go` - current `postgres:16-alpine` helper using testcontainers-go postgres module.
- `dbee/tests/testhelpers/helper.go` - provider detection to harden for podman/docker health while preserving signature.
- `dbee/tests/testdata/postgres_seed.sql` - existing simple seed pattern.
- `dbee/tests/README.md` - integration test runtime notes.
- `dbee/adapters/postgres_driver_rich_metadata_test.go` - existing sqlmock marker coverage that live PG supplements.
- `.github/workflows/test.yml` - current Go unit and testcontainers CI jobs.
- `Makefile` - existing marker rollup and focused audit target patterns.
</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `dbee/tests/testhelpers.NewPostgresContainer` already uses testcontainers-go, `postgres:16-alpine`, `WithInitScripts`, and `ConnectionString(ctx, "sslmode=disable")`.
- Existing integration tests use testify suites and shared containers with `tc.CleanupContainer`.
- `Makefile` already has strict marker patterns such as `oracle-bind-audit`, `lsp21`, and DB18 locked-helper guards.
- `.github/workflows/test.yml` already runs testcontainers integration tests on `ubuntu-22.04`; that job uses `sudo go test` and `timeout-minutes: 10`.

### Established Patterns
- Go adapter tests log strict markers with `t.Log("MARKER=true")`.
- Makefile targets tee logs and grep concrete marker strings before emitting rollups.
- Live database tests live under `dbee/tests/integration`; sqlmock/unit tests stay under `dbee/adapters`.
- Existing helper currently prefers podman by executable presence. Phase 20 makes that health-aware to avoid local false failures.

### Integration Points
- New live suite connects through `adapters.NewConnection` via the testhelper, then calls the public `core.Connection` methods.
- New seed file is mounted through the testcontainers postgres module init-script path.
- New Makefile target runs from repo root but invokes Go through `go -C dbee ...`.
- CI job must override workflow default working directory because the workflow defaults to `dbee`.
</code_context>

<specifics>
## Specific Commands And Surfaces

- Primary command: `make live-pg-smoke`.
- CI command: `LIVE_PG20_REQUIRED=1 make live-pg-smoke` locally; GitHub Actions uses `sudo -E make live-pg-smoke`.
- SQL-shape preflight: `go -C dbee test ./adapters -run '^TestPostgresForeignKeysSQLRowsFromShape$' -count=1 -v`.
- Focused Go live command inside the target: `go -C dbee test -tags live_pg20 -count=1 -timeout=10m ./tests/integration -run '^TestPostgresLiveRichMetadataSmoke$' -v`.
- Default live log path: `LIVE_PG20_ROLLUP_LOG ?= $(LIVE_PG20_ARTIFACT_ROOT)/live-pg20.log`, with CI setting it explicitly under `RUNNER_TEMP`.
- Future PostgreSQL matrix can start with additional digest-pinned image refs; Phase 20 only pins PG16.
</specifics>

<deferred>
## Deferred Ideas

- Sequence `current_value` support in `core.Sequence` and PostgreSQL SQL.
- Multi-version PostgreSQL matrix for PG14/15/16/17.
- Live Oracle smoke for Phase 22.
- End-to-end nvim-driven live rich metadata smoke.
- Promoting the live PG smoke into a required all-platform CI lane.
- Phase 22-class live driver parser discovery for PostgreSQL driver behavior beyond this SQL-shape smoke, unless surfaced by Phase 20 execution.
</deferred>

---

*Phase: 20-live-pg-smoke*
*Context revised: 2026-05-07 r1 fold*
