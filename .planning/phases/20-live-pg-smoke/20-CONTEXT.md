# Phase 20: Live-PG Smoke Test - Context

**Gathered:** 2026-05-07
**Revised:** 2026-05-08 r4 narrow fold
**Status:** Ready for r5 plan-gate
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
- **PG20-03:** Improve runtime detection so an installed-but-stopped podman does not shadow a healthy Docker runtime. The `live-pg-smoke` target invokes the shared Go runtime probe command, which checks `podman info` and `docker info` with bounded subprocesses and reports one selected provider.
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
- **PG20-20:** `make live-pg-smoke` owns the rollup gate: it tees verbose Go output, emits every Makefile marker through one log-appending helper, greps every strict marker, emits `LIVE_PG20_STRICT_MARKER_COUNT=19`, and emits `PHASE20_ALL_PASS=true` only after all strict records are present exactly once with the expected values.
- **PG20-21:** Add a GitHub Actions `live-pg20-smoke` job on `ubuntu-22.04` that runs required mode. Do not add macOS CI for this phase.
- **PG20-22:** Verification for planning/execution includes existing unit tests for Phase 17 SQL plus the new live target. The live lane is not a replacement for sqlmock; it closes the SQL-parser blind spot sqlmock cannot cover.

### r1 Fold Decisions
- **PG20-23:** Historical fix source is `be58045`, not `c3dd1a8`. Use `git show be58045^:dbee/adapters/postgres_driver_rich_metadata.go` for the broken FK SQL and `git show be58045:dbee/adapters/postgres_driver_rich_metadata.go` for the fixed `ROWS FROM` shape.
- **PG20-24:** Add `dbee/adapters/postgres_driver_rich_metadata_shape_test.go` in package `adapters`. It runs after runtime detection succeeds and before container startup. It asserts `postgresForeignKeysSQL` contains `ROWS FROM (`, `pg_catalog.unnest(con.conkey)`, `pg_catalog.unnest(con.confkey)`, and does not contain `pg_catalog.unnest(con.conkey, con.confkey)`. PG20-43 widens the same test file to structural assertions for all five PostgreSQL rich metadata SQL constants.
- **PG20-25:** Keep `LIVE_PG20_HISTORICAL_UNNEST_NEGATIVE_OK` only for the exact historical broken FK SQL. The live test uses `github.com/lib/pq v1.10.9`, `var pqErr *pq.Error`, `require.ErrorAs(t, err, &pqErr)`, and `require.Equal(t, pq.ErrorCode("42883"), pqErr.Code)`. `database/sql` preserves the `*pq.Error` from `lib/pq`; any non-`42883` error class fails the marker. Empirical PG16 evidence captured 2026-05-08 with `postgres:16-alpine@sha256:4e6e670bb069649261c9c18031f0aded7bb249a5b6664ddec29c013a89310d50`:

```text
ERROR:  42883: function pg_catalog.unnest(smallint[], smallint[]) does not exist
LINE 1: ... * FROM pg_catalog.pg_constraint con JOIN LATERAL pg_catalog...
                                                             ^
HINT:  No function matches the given name and argument types. You might need to add explicit type casts.
LOCATION:  ParseFuncOrColumn, parse_func.c:629
```
- **PG20-26:** The live smoke test file must be named `postgres_rich_metadata_smoke_test.go` and begin with `//go:build live_pg20`. Makefile passes `-tags live_pg20`; bootstrap matrix glob remains `*_integration_test.go`.
- **PG20-27:** Runtime detection produces one selected provider name (`podman` or `docker`) and passes it to Go as `LIVE_PG20_CONTAINER_PROVIDER`. Go must not silently reselect a different provider.
- **PG20-28:** `GetContainerProvider() testcontainers.ProviderType` public signature and presence-only behavior remain unchanged. It continues to return Podman solely on `exec.LookPath("podman")`, else Docker, for existing integration helpers. Only the new `HealthyContainerRuntime` helper is health-aware, and live-PG smoke is its only caller. Current baseline grep count is 9 matches (`8` existing helper callsites plus the `GetContainerProvider` definition); Phase 20 must keep that count unchanged after implementation.
- **PG20-29:** `NewPostgresRichMetadataContainer` must clean up the started container on every post-start error, including connection-string and adapter construction errors. The test registers `t.Cleanup(tc.CleanupContainer)` immediately after creation succeeds. CI checkout for `live-pg20-smoke` must fetch enough history for locked-helper range checks before any marker emission.
- **PG20-30:** The negative SQL sentinel opens a dedicated `sql.Open("postgres", connURL)`, defers `db.Close()`, runs one statement with context timeout, and never uses the shared `core.Connection` pool.
- **PG20-31:** Snapshot contract is external readable JSON only. Allowlist fields: `Name`, `Schema`, `Nullable`, `IsPrimaryKey`, `PrimaryKeyOrdinal`, `IsGenerated` bool, `IsIdentity` bool, FK source/target column names and ordinals, index names, index columns, DESC flags, INCLUDE columns, sequence name/schema/increment/cache. Denylist fields: column type text, default expression text, comments, type aliases/format aliases, `pg_get_expr` output, OIDs, owner names, timestamps. Output uses stable field ordering, sorted rows, and indent=2 so PR diffs remain reviewable.
- **PG20-32:** Golden update workflow is `UPDATE_GOLDEN=1 make live-pg-smoke`, then review the isolated readable JSON snapshot diff. Do not mark `dbee/tests/testdata/postgres_rich_metadata_snapshot.json` as binary in `.gitattributes`.
- **PG20-33:** Rollup gate uses `set -eu`; any missing marker prints `PHASE20_ALL_PASS=false` and exits nonzero. `PHASE20_ALL_PASS=true` is printed only on the success path.
- **PG20-34:** `LIVE_PG20_STRICT_MARKER_COUNT=19` is the only valid count after PG20-45. It includes the count record itself and excludes `PHASE20_ALL_PASS`.
- **PG20-35:** CI job overrides `defaults.run.working-directory: .`, sets `LIVE_PG20_ROLLUP_LOG: ${{ runner.temp }}/live-pg20/live-pg20.log`, and uploads exactly that path with `if: always()`.
- **PG20-36:** CI job sets `timeout-minutes: 10`; Makefile runs Go with `-timeout=10m`; container setup uses `context.WithTimeout`.
- **PG20-37:** CI invokes the outer target as the checkout owner with `make live-pg-smoke`, not `sudo -E make live-pg-smoke`. The outer target performs runtime detection, locked-helper Git checks, and SQL-shape preflight without sudo. CI sets `LIVE_PG20_USE_SUDO=1`, so only the inner `_live-pg-smoke-inner` target is invoked through `sudo -E` after those pre-sudo checks.
- **PG20-38:** Required-mode no-runtime failure message is exact: `no healthy container runtime: tried podman info (status: <status>; stderr: <stderr>) and docker info (status: <status>; stderr: <stderr>); set LIVE_PG20_REQUIRED=0 to skip`.
- **PG20-39:** Add non-strict timing markers: `LIVE_PG20_DETECT_OK=true`, `LIVE_PG20_DETECT_SLOW=true` when detection exceeds 2000ms on success, `LIVE_PG20_DETECT_MS`, `LIVE_PG20_CONTAINER_MS`, `LIVE_PG20_SEED_MS`, `LIVE_PG20_SUITE_DURATION_S`, `LIVE_PG20_WALL_CLOCK_BUDGET_S=180`, `LIVE_PG20_WALL_CLOCK_OK=<true|false>`. Detection duration is hard-gated at `< 6000ms` on both success and no-runtime paths. Wall-clock budget is memory's 120s cold-start note multiplied by 1.5.
- **PG20-40:** Phase 21 cross-impact is part of the live contract: PK columns must have `Nullable != nil`, `PrimaryKey == true`, correct `PrimaryKeyOrdinal`, and FK refs must have equal-length `SourceColumns`/`TargetColumns` arrays in ordinal order.

### r2 Narrow-Fold Decisions (r4 amended)
- **PG20-41:** Every runtime health subprocess is bounded to 5s through the shared Go runtime probe. The Makefile must not implement its own podman/docker shell fallback. It invokes `go -C dbee run ./cmd/probe-runtime` or a compiled equivalent, and that command uses parent `context.WithCancel`, two concurrent probes, child `context.WithTimeout(5*time.Second)`, and `exec.CommandContext`; bare `exec.Command(...).Run()` is forbidden. The command honors `LIVE_PG20_CONTAINER_PROVIDER` by validating only the requested provider when set. Probe result normalization is mandatory: `0=healthy`, `124=timeout after 5s`, `127=binary-not-found`, `>=128=signal-killed`, and any other nonzero status is `unhealthy`. Healthy podman plus hung docker must complete in `< 1500ms` and cancel the loser before its 5s timeout. If any Makefile child process is backgrounded, the recipe must use split signal traps (`trap cleanup EXIT`; `trap 'cleanup; exit 130' INT`; `trap 'cleanup; exit 143' TERM`); the combined `trap 'cleanup' EXIT INT TERM` pattern is forbidden.
- **PG20-42:** No-runtime marker accounting is explicit and restored by ordering runtime detection before SQL-shape preflight. On no-runtime, emit only `LIVE_PG20_SKIPPED_NO_RUNTIME=true`, `LIVE_PG20_DETECT_MS=<ms>`, `PHASE20_ALL_PASS=false`, and the exact PG20-38 diagnostic message as output/rollup records; do not emit any strict success marker or `LIVE_PG20_STRICT_MARKER_COUNT`. The no-runtime detection duration must be asserted below 6000ms before the branch completes. Local no-runtime skip may exit 0, but it is still a skip path and must not print success rollup evidence.
- **PG20-43:** The SQL-shape preflight covers all five locked PostgreSQL rich metadata SQL constants with stable structural anchors only: `postgresColumnsRichSQL` contains `pg_catalog.pg_attribute`, `postgresPrimaryKeysSQL` contains `pg_catalog.pg_constraint` and `contype = 'p'`, `postgresForeignKeysSQL` contains the fixed `ROWS FROM`/split-unnest shape, `postgresIndexesSQL` contains `pg_catalog.pg_index`, and `postgresSequencesSQL` contains `pg_catalog.pg_sequence`. Do not assert alias-fragile strings such as `ix.indisvalid` or `s.seqcache`. Current production code has no separate `postgresMaterializedViewIndexesSQL`; if one exists before implementation, add one stable structural assertion for it too.

### r3 Narrow-Fold Decisions (r4 amended)
- **PG20-44:** CI fetches enough history for the locked-helper range check and keeps Git outside sudo. The `live-pg20-smoke` checkout uses `actions/checkout@v4` with `fetch-depth: 0`, or an explicit `git fetch origin master:refs/remotes/origin/master` before `make live-pg-smoke`. The outer Makefile target, running as the checkout owner, assigns `base="$$(git merge-base HEAD origin/master)"` and fails closed without emitting `LIVE_PG20_LOCKED_HELPERS_UNTOUCHED_OK=true` if merge-base resolution fails. The CI job must not call `sudo -E make live-pg-smoke`; any sudo escalation is limited to `_live-pg-smoke-inner` after locked-helper checks pass.
- **PG20-45:** Split SQL-shape evidence into two strict markers: `LIVE_PG20_SQL_SHAPE_PREFLIGHT_OK=true` after same-package SQL-constant preflight succeeds, and `LIVE_PG20_ROWS_FROM_LIVE_OK=true` after live `GetColumnsRich` exercises production ROWS FROM SQL successfully. Strict count is `19`.

### the agent's Discretion
- Exact fixture table and column names, as long as every marker has a deterministic live assertion.
- Exact helper function names in `dbee/tests/testhelpers`, as long as existing adapter integration tests keep working.
- Exact snapshot struct type names, as long as the allowlist/denylist above is enforced.
- Decision count is allowed to remain at 45 for traceability through plan-gate convergence; consolidation is deferred to post-SHIP docs. Fold consolidated decisions into `project_v14_phase20_shipped.md` and archive raw r0/r1/r2/r3/r4 entries.
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
- Existing helper currently prefers podman by executable presence. Phase 20 keeps that seam presence-only and adds `HealthyContainerRuntime` plus the probe command for the live PG lane.

### Integration Points
- New live suite connects through `adapters.NewConnection` via the testhelper, then calls the public `core.Connection` methods.
- New seed file is mounted through the testcontainers postgres module init-script path.
- New Makefile target runs from repo root but invokes Go through `go -C dbee ...`.
- CI job must override workflow default working directory because the workflow defaults to `dbee`.
</code_context>

<specifics>
## Specific Commands And Surfaces

- Primary command: `make live-pg-smoke`.
- CI command: `LIVE_PG20_REQUIRED=1 make live-pg-smoke` locally and in GitHub Actions; the outer target may invoke `sudo -E make _live-pg-smoke-inner` only after pre-sudo Git checks pass.
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
*Context revised: 2026-05-08 r4 narrow fold*
