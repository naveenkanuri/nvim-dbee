# Phase 20: Live-PG Smoke Test - Context

**Gathered:** 2026-05-07
**Status:** Ready for planning
**Source:** User-supplied Phase 20 task, repo validation, Phase 17 memory, local code scout

<domain>
## Phase Boundary

Phase 20 adds a Docker/podman-gated live PostgreSQL smoke lane for the PostgreSQL rich metadata SQL shipped in Phase 17. It proves the five production SQL shapes in `dbee/adapters/postgres_driver_rich_metadata.go` execute against real PostgreSQL 16 and return the existing `core.Column`, `core.Index`, and `core.Sequence` contracts.

In scope:
- PostgreSQL only.
- Live container fixture for a deterministic rich metadata schema.
- Focused integration tests for `SupportsRichMetadata`, `GetColumnsRich`, `GetIndexes`, and `GetSequences`.
- Makefile target `live-pg-smoke` with runtime detection, skip-graceful local behavior, fail-loud CI behavior when required, marker rollup, and container cleanup.
- GitHub Actions job on Ubuntu that runs the live PG smoke through Docker/testcontainers.

Out of scope:
- Oracle live smoke.
- Any change to Phase 17 production SQL or rich metadata production contracts.
- Any edit to the three locked helpers:
  - `lua/dbee/schema_filter_authority.lua`
  - `lua/dbee/schema_name_canonical.lua`
  - `lua/dbee/lsp/epoch_authority.lua`
- PostgreSQL version matrix beyond one pinned primary version.
- Running through a Neovim UI instance.

Challenge-up:
- The proposed scope mentioned sequence `current_value`, but `core.Sequence` currently exposes only `Name`, `Schema`, `Increment`, and `CacheSize`, and `postgresSequencesSQL` returns only `sequence_name`, `increment_by`, and `cache_size`. Phase 20 must test the existing sequence contract only. Adding `current_value` would require production SQL/type changes and belongs in a separate phase.

</domain>

<decisions>
## Implementation Decisions

### Runtime And Container Strategy
- **PG20-01:** Use the existing testcontainers-go integration pattern instead of hand-rolled `podman run` lifecycle scripts.
- **PG20-02:** Support both podman and docker. Local preference remains podman when healthy; CI uses Docker on Ubuntu runners.
- **PG20-03:** Improve runtime detection so an installed-but-stopped podman does not shadow a healthy Docker runtime. The `live-pg-smoke` target should check `podman info` and `docker info`, not just executable presence.
- **PG20-04:** Local `make live-pg-smoke` skips with `LIVE_PG20_SKIPPED_NO_RUNTIME=true` when no healthy runtime exists. CI runs with `LIVE_PG20_REQUIRED=1`, so missing runtime is a failure.
- **PG20-05:** Pin the primary image to `postgres:16-alpine`, matching the current integration helper and Phase 17 live verification. Expose `LIVE_PG20_POSTGRES_IMAGE` for future local override, but do not add a version matrix in Phase 20.

### Fixture And Isolation
- **PG20-06:** Use a dedicated SQL seed file: `dbee/tests/testdata/postgres_rich_metadata_seed.sql`.
- **PG20-07:** Seed multiple schemas with deterministic names such as `pg20_sales`, `pg20_inventory`, and `pg20_analytics`.
- **PG20-08:** Seed SQL must start with `DROP SCHEMA IF EXISTS ... CASCADE` for every fixture schema, then recreate everything. This makes the fixture idempotent even though the normal lifecycle is a fresh container.
- **PG20-09:** Use one shared container per live smoke suite, not one container per test. Tests are read-only after seed, so shared-container speed is worth the low contamination risk.
- **PG20-10:** The fixture must include composite primary keys, composite foreign keys, generated columns, identity columns, default expressions, serial/sequence defaults, regular indexes, covering indexes with INCLUDE columns, multiple schemas, regular views, materialized views, and schema-local sequences.

### Live Assertions
- **PG20-11:** Exercise the production SQL only through public driver surfaces: `Connection.SupportsRichMetadata`, `Connection.GetColumnsRich`, `Connection.GetIndexes`, and `Connection.GetSequences`.
- **PG20-12:** `GetColumnsRich` must prove composite PK ordinals and composite FK column pairing on live PostgreSQL. This directly guards the Phase 17 `ROWS FROM (unnest(), unnest()) WITH ORDINALITY` bug class.
- **PG20-13:** Add a negative sentinel that runs the historical malformed `pg_catalog.unnest(smallint[], smallint[]) WITH ORDINALITY` shape against live PostgreSQL and asserts it fails. The production `GetColumnsRich` composite-FK path must succeed in the same suite.
- **PG20-14:** `GetIndexes` must assert regular table indexes, PK-backed indexes, INCLUDE-column separation, regular-view no-index behavior, and materialized-view indexes.
- **PG20-15:** `GetSequences` must assert schema scoping plus `Name`, `Schema`, `Increment`, and `CacheSize`. Do not assert `current_value`.
- **PG20-16:** Multi-schema coverage means both adapter SQL scoping and fixture shape. The live test must prove querying one schema does not leak same-named or similarly named objects from another schema.
- **PG20-17:** Schema filter authority itself remains covered by existing headless marker `RICH_PG_SCHEMA_FILTER_NO_QUERY_OK`; Phase 20 must not touch the locked helper or require an nvim instance.
- **PG20-18:** Add a deterministic snapshot assertion over canonicalized live metadata rows for the core fixture. Keep the snapshot narrow enough to avoid encoding unstable PostgreSQL formatting.

### Rollup And CI
- **PG20-19:** Keep live-PG markers in a separate `LIVE_PG20_ROLLUP_LOG`. Do not append env-gated live-smoke evidence into `UX13_ROLLUP_LOG`.
- **PG20-20:** `make live-pg-smoke` owns the rollup gate: it tees verbose Go output, greps every strict `LIVE_PG20_*` marker, emits `LIVE_PG20_STRICT_MARKER_COUNT=<N>`, and emits `PHASE20_ALL_PASS=true` only after all strict markers are present exactly once with `true`.
- **PG20-21:** Add a GitHub Actions `live-pg20-smoke` job on `ubuntu-22.04` that runs `LIVE_PG20_REQUIRED=1 make live-pg-smoke`. Do not add macOS CI for this phase.
- **PG20-22:** Verification for planning/execution includes existing unit tests for Phase 17 SQL plus the new live target. The live lane is not a replacement for sqlmock; it closes the SQL-parser blind spot sqlmock cannot cover.

### the agent's Discretion
- Exact fixture table and column names, as long as every marker has a deterministic live assertion.
- Whether the snapshot golden is inline in the Go test or stored in `dbee/tests/testdata/postgres_rich_metadata_snapshot.json`.
- Exact helper function names in `dbee/tests/testhelpers`, as long as existing adapter integration tests keep working.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase 20 Source Of Truth
- `.planning/ROADMAP.md` - Phase 20 entry and v1.4 ordering.
- `/Users/naveenkanuri/.claude/projects/-Users-naveenkanuri-Documents-nvim-dbee/memory/MEMORY.md` lines 33-38 - Phase 17 lessons: sqlmock blind spot, podman+PG speed, composite FK SQL shape, live testing catch.
- `/Users/naveenkanuri/.claude/projects/-Users-naveenkanuri-Documents-nvim-dbee/memory/project_v14_phase17_shipped.md` - Live PG bug details and Phase 20 backlog rationale.

### Production Code
- `dbee/adapters/postgres_driver_rich_metadata.go` - five production SQL constants and PostgreSQL rich metadata implementation to exercise, not modify.
- `dbee/core/connection.go` - public rich metadata surfaces: `SupportsRichMetadata`, `GetColumnsRich`, `GetIndexes`, `GetSequences`.
- `dbee/core/types.go` - `Column`, `FKRef`, `Index`, and `Sequence` contracts, including the absence of sequence `current_value`.
- `lua/dbee/schema_filter_authority.lua`, `lua/dbee/schema_name_canonical.lua`, `lua/dbee/lsp/epoch_authority.lua` - locked helpers that Phase 20 must not edit.

### Existing Test Infrastructure
- `dbee/tests/integration/postgres_integration_test.go` - current PostgreSQL testcontainer suite shape.
- `dbee/tests/testhelpers/postgres.go` - current `postgres:16-alpine` helper using testcontainers-go postgres module.
- `dbee/tests/testhelpers/helper.go` - provider detection to harden for podman/docker health.
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
- `.github/workflows/test.yml` already runs testcontainers integration tests on `ubuntu-22.04`.

### Established Patterns
- Go adapter tests log strict markers with `t.Log("MARKER=true")`.
- Makefile targets tee logs and grep concrete marker strings before emitting rollups.
- Live database tests live under `dbee/tests/integration`; sqlmock/unit tests stay under `dbee/adapters`.
- Existing helper currently prefers podman by executable presence. Phase 20 should make that health-aware to avoid local false failures.

### Integration Points
- New live suite connects through `adapters.NewConnection` via the testhelper, then calls the public `core.Connection` methods.
- New seed file is mounted through the testcontainers postgres module init-script path.
- New Makefile target runs from repo root but invokes Go through `go -C dbee ...`.
- CI job runs from repo root for `make live-pg-smoke`, while Go package paths remain relative to `dbee`.

</code_context>

<specifics>
## Specific Ideas

- Primary command: `make live-pg-smoke`.
- CI command: `LIVE_PG20_REQUIRED=1 make live-pg-smoke`.
- Focused Go package command inside the target: `go -C dbee test -count=1 ./tests/integration -run '^TestPostgresLiveRichMetadataSmoke$' -v`.
- Default live log path: `LIVE_PG20_ROLLUP_LOG ?= /tmp/nvim-dbee-live-pg20/live-pg20.log`, with `RUNNER_TEMP` preferred in CI.
- Future PostgreSQL matrix can start with `LIVE_PG20_POSTGRES_IMAGE=postgres:14-alpine` / `postgres:16-alpine`; Phase 20 only pins PG16.

</specifics>

<deferred>
## Deferred Ideas

- Sequence `current_value` support in `core.Sequence` and PostgreSQL SQL.
- Multi-version PostgreSQL matrix for PG14/15/16/17.
- Live Oracle smoke for Phase 22.
- End-to-end nvim-driven live rich metadata smoke.
- Promoting the live PG smoke into a required all-platform CI lane.

</deferred>

---

*Phase: 20-live-pg-smoke*
*Context gathered: 2026-05-07*
