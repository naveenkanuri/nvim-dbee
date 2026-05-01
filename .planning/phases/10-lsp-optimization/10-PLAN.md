---
phase: 10-lsp-optimization
plan: 01
revision: 6
type: execute
wave: 1
depends_on: [09]
files_modified:
  - ci/headless/perf_bootstrap.mk
  - ci/headless/lsp_perf_thresholds.lua
  - Makefile
  - ci/headless/check_lsp_perf.lua
  - lua/dbee/lsp/bench.lua
  - .github/workflows/test.yml
autonomous: true
requirements: [LSP-PERF-01]
---

<objective>
Create the Phase 10 LSP performance evidence lane before optimizing any LSP code.

By the end of this plan, `make perf-lsp` runs a deterministic `benchmark.nvim` headless harness against the real in-process dbee LSP path, emits `LSP01_*` median/p95/candidate/frozen markers, uploads summary and Chrome trace artifacts in Linux and macOS advisory CI jobs, preserves the existing interactive `lua/dbee/lsp/bench.lua` probe, and leaves all optimization/correctness/feature work for Phase 11/12.
</objective>

<execution_context>
@/Users/naveenkanuri/Documents/nvim-dbee/.codex/skills/gsd-plan-phase/SKILL.md
@/Users/naveenkanuri/Documents/nvim-dbee/.codex/get-shit-done/workflows/plan-phase.md
</execution_context>

<context>
@.planning/ROADMAP.md
@.planning/REQUIREMENTS.md
@.planning/milestones/v1.2-roadmap.md
@.planning/phases/10-lsp-optimization/10-CONTEXT.md
@.planning/phases/10-lsp-optimization/10-RESEARCH.md
@.planning/research/v12-lsp-opus-research.md
@.planning/phases/09-real-nui-perf-harness/09-CONTEXT.md
@.planning/phases/09-real-nui-perf-harness/09-PLAN.md
</context>

<must_haves>
  <truths>
    - "Phase 10 is measurement-only. Do not optimize, debounce, async-rewrite, add features, or fix diagnostics correctness bugs unless an existing crash blocks measurement."
    - "The harness must measure current behavior, including the synchronous cold column miss path, so Phase 11 can prove the async rewrite wins."
    - "Use the real in-process dbee LSP server: startup scenarios drive the production `dbee.lsp` lifecycle, while non-startup scenarios attach via `vim.lsp.start({ cmd = server.create(cache) })`; no standalone `sqls`, no out-of-process rewrite, no helper-only completion microbenchmarks as release evidence."
    - "Reuse Phase 9 perf infrastructure: `ci/headless/perf_bootstrap.mk`, pinned `stevearc/benchmark.nvim`, pinned `profile.nvim`, and the threshold-source-of-truth pattern."
    - "Do not introduce `nvim-nio` in Phase 10. That peer dependency is locked for Phase 11."
    - "Blocking evidence uses deterministic synthetic fixtures, not live DuckDB, SQLite, Oracle, or Go RPC adapters."
    - "Linux and macOS are co-equal perf platforms. Phase 10 lands advisory lanes immediately and prepares later blocking promotion after four weeks at >=95% pass rate per platform."
    - "Threshold persistence is a Lua module, not JSON baselines. Candidate measurements are emitted, but per-run baseline files are not committed."
    - "Completion request timing uses `client:request(...)` callback elapsed time, not `client:request_sync()` as the authoritative path."
    - "Interactive `bench.lua` remains usable; Phase 10 only performs the scoped `vim.loop` to `vim.uv` hygiene update there."
    - "Every measured LSP scenario must carry semantic sentinels so swallowed completion/diagnostic errors cannot publish valid timing evidence."
    - "Cache isolation uses per-run `XDG_STATE_HOME`; Phase 10 does not add production `SchemaCache` constructor options."
  </truths>
  <artifacts>
    - path: "ci/headless/perf_bootstrap.mk"
      provides: "shared pinned perf plugin checkout and runtimepath command fragments"
      contains: "BENCHMARK_NVIM_COMMIT"
    - path: "ci/headless/lsp_perf_thresholds.lua"
      provides: "new LSP-only threshold source of truth, advisory seed budgets, and manual freeze ceremony"
      contains: "startup_cold"
    - path: "ci/headless/check_lsp_perf.lua"
      provides: "headless real-LSP benchmark harness, deterministic fixture generator, marker emitter, summary artifact, and trace artifact"
      contains: "LSP01_PERF_MODE"
    - path: "Makefile"
      provides: "`make perf-lsp` and `make perf-all` local reproduction targets using the shared bootstrap"
      contains: "perf-lsp:"
    - path: ".github/workflows/test.yml"
      provides: "Linux/macOS advisory CI lane and artifact upload"
      contains: "lua-lsp-perf-advisory"
    - path: "lua/dbee/lsp/bench.lua"
      provides: "preserved interactive probe with Neovim 0.12 `vim.uv` hygiene"
      contains: "local uv = vim.uv or vim.loop"
  </artifacts>
  <key_links>
    - from: "ci/headless/perf_bootstrap.mk"
      to: "Makefile"
      via: "`perf-lsp` consumes the same `PERF_NVIM_HEADLESS` runtimepath as drawer perf"
      pattern: "include ci/headless/perf_bootstrap.mk"
    - from: "ci/headless/check_lsp_perf.lua"
      to: "lua/dbee/lsp/server.lua"
      via: "request/notify handlers are measured through `server.create(cache)`, while startup cohorts enter through `dbee.lsp.queue_buffer()` / `_try_start()`"
      pattern: "server.create(cache)"
    - from: "ci/headless/check_lsp_perf.lua"
      to: "lua/dbee/lsp/schema_cache.lua"
      via: "schema/cache build, column fetch, disk load, and disk save paths are benchmarked through current module APIs"
      pattern: "SchemaCache:new"
    - from: "ci/headless/check_lsp_perf.lua"
      to: "ci/headless/lsp_perf_thresholds.lua"
      via: "candidate/frozen threshold status and pass formulas are loaded from the LSP threshold module"
      pattern: "require_lsp_thresholds"
    - from: ".github/workflows/test.yml"
      to: "Makefile"
      via: "CI invokes `make perf-lsp PERF_PLATFORM=${{ matrix.platform }}` after shared bootstrap"
      pattern: "make perf-lsp"
  </key_links>
</must_haves>

<constraints>
- Honor D-01..D-118 and D-119..D-149 verbatim.
- Phase 10 must not add `nvim-nio`, async column fetching, LRU eviction, diagnostics debounce, schema-cache indexes, atomic disk writes, hover, resolve, code actions, symbols, semantic tokens, inlay hints, or multi-client LSP behavior.
- The apparent "cache-miss-async/real-RPC" scenario wording in the dispatch is superseded by D-126 and D-128: Phase 10 measures the current synchronous cold miss through a deterministic stub and defers async/live RPC cohorts.
- `ci/headless/lsp_perf_thresholds.lua` is separate from `ci/headless/perf_thresholds.lua`; do not namespace LSP thresholds into the drawer file.
- `LSP01_PHASE7_BUDGETS_PASS` must not be emitted.
- CI remains advisory and `continue-on-error: true` until the four-week >=95% per-platform promotion rule is met.
- Internal execution uses a four-wave DAG, while the plan frontmatter remains `wave: 1` for execute-phase tooling.
- Phase 9 is an explicit dependency. Execution must verify Phase 9 perf bootstrap outputs exist before any Phase 10 consumer target or CI job is changed.
</constraints>

<interfaces>
Shared local/CI invocation contract:
```sh
make perf-bootstrap
make perf-lsp
make perf-lsp PERF_PLATFORM=macos
make perf-lsp PERF_PLATFORM=linux
make perf-all
```

LSP perf environment knobs:
```sh
NVIM_BIN=nvim
PERF_PLATFORM=macos|linux
LSP01_PERF_GATE_MODE=advisory|blocking
LSP01_PERF_ARTIFACT_DIR=/tmp/path
LSP01_PERF_SUMMARY_PATH=/tmp/path/lsp01-summary.txt
LSP01_PERF_TRACE_PATH=/tmp/path/lsp01-trace.json
LSP01_PERF_THRESHOLD_FILE=ci/headless/lsp_perf_thresholds.lua
XDG_STATE_HOME=/tmp/path/lsp01-state
LSP01_ALLOW_NONPUBLISHABLE_PLATFORM_OVERRIDE=0|1
```

Required scenario slugs:
```text
STARTUP_COLD
STARTUP_WARM
STARTUP_METADATA_FALLBACK
COMPLETION_TABLE_100
COMPLETION_TABLE_1000
COMPLETION_TABLE_10000
COMPLETION_SCHEMA
COMPLETION_KEYWORD
COMPLETION_COLUMN_HIT
COMPLETION_COLUMN_MISS_SYNC
DIAGNOSTICS_DIDCHANGE_100
DIAGNOSTICS_DIDCHANGE_1000
DIAGNOSTICS_DIDCHANGE_10000
DIAGNOSTICS_DIDSAVE_100
DIAGNOSTICS_DIDSAVE_1000
DIAGNOSTICS_DIDSAVE_10000
ALIAS_SIMPLE_SELECT
ALIAS_NESTED_CTE
ALIAS_MULTILINE
ALIAS_MULTI_JOIN
CACHE_BUILD_100
CACHE_BUILD_1000
CACHE_BUILD_10000
CACHE_LOAD_100
CACHE_LOAD_1000
CACHE_LOAD_10000
CACHE_SAVE_100
CACHE_SAVE_1000
CACHE_SAVE_10000
```

Canonical scenario registry contract:
- Each scenario is defined once as `{ slug = "UPPERCASE_MARKER", threshold_key = "lowercase_key", corpus = "...", sentinel = ... }`.
- Threshold lookup, marker emission, summary rows, scenario count, and verification all derive from that registry.
- `threshold_key` is always `slug:lower()` unless a row explicitly documents a different key.
- `LSP01_SCENARIOS_COUNT` must equal the registry length.

Synthetic lifecycle connection fixture contract:
- `STARTUP_COLD` uses a fake current connection whose `type = "dbee-perf-no-metadata"`. This type has no entry in production `METADATA_QUERIES`, so production `_try_start()` must not schedule the metadata fallback timer. This keeps `LSP01_COLD_DISK_DEFERRED_CALLBACK_COUNT=0` satisfiable while measuring the structure-load cold-start path.
- `STARTUP_WARM` may use the same `dbee-perf-no-metadata` fake connection type because the warm disk-cache hit returns before metadata fallback scheduling. Its contract is disk-load startup, not metadata fallback.
- `STARTUP_METADATA_FALLBACK` uses a synthetic current-connection record with a production-supported metadata-capable type, `type = "postgres"`. The connection, handler, result rows, and metadata execution are fake and deterministic; only the type string is production-supported so local production `METADATA_QUERIES[conn.type]` exists without adding a production test hook.
- Do not invent a new metadata-capable type such as `dbee-perf-metadata` unless production code exposes a test-only metadata-query registry. Phase 10 is plan-only for this issue and does not modify `lua/dbee/lsp/init.lua`.
</interfaces>

<measurement_protocol>
Protocol constants:
- Warmup count: `5`
- Measured count: `10`
- Benchmark runner: `benchmark.run({ title = ..., warm_up = 5, iterations = 10 }, run, done)`
- Timeout ceiling per scenario: `30000ms`, with scenario label in the failure marker
- Deterministic scenario order: startup -> completion -> diagnostics -> alias/context -> cache build -> disk load/save
- No randomized ordering

Platform authenticity:
- The harness emits `LSP01_ACTUAL_OS=darwin|linux|other` from `vim.uv.os_uname().sysname` before threshold evaluation.
- The harness emits `LSP01_PLATFORM_AUTHENTIC=true` only when `PERF_PLATFORM` matches the actual OS mapping (`macos` -> `darwin`, `linux` -> `linux`).
- Publishable runs require `LSP01_PLATFORM_AUTHENTIC=true`. If `PERF_PLATFORM` conflicts with the actual OS, the run emits `LSP01_PLATFORM_AUTHENTIC=false` and `LSP01_PUBLISHABLE=false`, exits nonzero unless `LSP01_ALLOW_NONPUBLISHABLE_PLATFORM_OVERRIDE=1`, and does not emit threshold candidate markers.
- Nonpublishable override runs are allowed only for spike/debug output; their summary must state that thresholds cannot be copied from that run.

Fresh-baseline rules:
- Every scenario creates a fresh scratch buffer, fresh deterministic cache object, and fresh fake handler unless the scenario name explicitly says warm cache or the cold-miss sentinel explicitly measures first-sample cache warming.
- The harness runs with `XDG_STATE_HOME=$LSP01_PERF_ARTIFACT_DIR/state-home` before Neovim starts. It must emit `LSP01_STDPATH_STATE=` and fail if `vim.fn.stdpath("state")` is outside that directory.
- Cold startup uses a fresh `XDG_STATE_HOME` with no LSP cache files and drives the production `dbee.lsp.queue_buffer()` / `_try_start()` lifecycle through a fake `dbee.api.state` and handler whose fake current connection has `type = "dbee-perf-no-metadata"`.
- Warm startup seeds the exact JSON files generated from the deterministic fixture under the isolated `XDG_STATE_HOME` before invoking the production lifecycle, then asserts `load_from_disk()` was hit. It may use `type = "dbee-perf-no-metadata"` because the warm disk-cache hit returns before metadata fallback scheduling.
- Lifecycle startup cohorts run under a scoped `vim.defer_fn` capture. The harness monkey-patches `vim.defer_fn` only inside the cohort, records scheduled callbacks instead of arming real timers, and restores the original function during cleanup.
- Lifecycle startup is split into `queue_try_start(handler)`, `wait_running()`, and `wait_metadata_fallback()`. `queue_try_start(handler)` queues the buffer and invokes production `_try_start()` without waiting for LSP startup; `wait_running()` asserts synchronous startup with no deferred metadata callback; `wait_metadata_fallback()` asserts exactly one captured metadata fallback callback, drains it synchronously, processes the fake result, then waits for `status().running`.
- Post-cleanup for each lifecycle cohort drains any remaining captured callbacks and verifies fake metadata execution count is unchanged: `0` for cold/warm disk cohorts and `1` for metadata fallback.
- Completion table/schema/keyword cohorts use a prebuilt cache and must not call `connection_get_columns()`.
- `COMPLETION_COLUMN_HIT` preloads deterministic columns in `SchemaCache.columns`.
- `COMPLETION_COLUMN_MISS_SYNC` uses `SELECT * FROM SCHEMA_001.TABLE_000001 t WHERE t.` with the cursor after the final dot. This scenario has a special lifecycle: warmups use disposable cache/handler state that cannot warm the measured cache; immediately after warmups and before measured sample 1, the harness resets the measured cache and fetch counters; measured sample 1 must fetch columns synchronously once; measured samples 2..10 must observe the warmed cache with zero additional fetches; every measured sample must validate deterministic column labels.
- Diagnostics cohorts set the target buffer text, send a real LSP `textDocument/didChange` or `textDocument/didSave` notification, and wait for `textDocument/publishDiagnostics`.
- Cache build/load/save scenarios use `SchemaCache` public APIs and deterministic temporary cache directories.

Stopwatch boundaries:
- Startup: start immediately before `require("dbee.lsp").queue_buffer(bufnr)` with fake state installed; stop after `require("dbee.lsp").status().running == true`, the scratch buffer is attached, and the expected lifecycle sentinel for that startup mode has fired.
- Completion: start immediately before `client:request("textDocument/completion", params, callback)`; stop inside the callback after validating `result.items` is a table.
- Diagnostics: start immediately before `client:notify("textDocument/didChange", params)` or `client:notify("textDocument/didSave", params)`; stop when the configured publish-diagnostics handler receives diagnostics for the measured URI.
- Alias/context scaling: start immediately before the completion request that invokes `context.analyze(params)` through `server.lua`; stop in the completion callback.
- Cache build: start before `cache:build_from_structure(structs)`; stop at function return.
- Disk save: start before `cache:save_to_disk()` or the column-saving API path used by `get_columns()`; stop after the file exists and is non-empty.
- Disk load: start before `cache:load_from_disk()`; stop after function return and count validation.

Trace capture:
- `benchmark.flame_profile()` runs outside the gated sample set in a separate trace-only pass.
- The trace run writes to `LSP01_PERF_TRACE_PATH` and must not contribute to median/p95 samples.

Cold-miss sample lifecycle:
- `run_benchmark(spec)` supports a scenario-local hook after warmup completion and before the first measured iteration.
- `COMPLETION_COLUMN_MISS_SYNC` must use that hook to clear the target table columns from the measured cache, reset handler fetch counters, and reset the per-sample fetch-delta array.
- The scenario emits `LSP01_COLUMN_MISS_FETCH_DELTAS=1,0,0,0,0,0,0,0,0,0` and `LSP01_COLUMN_MISS_FETCH_DELTAS_OK=true` only when the exact measured-sample pattern is observed.

Deferred metadata callback lifecycle:
- `capture_defer_fn()` replaces `vim.defer_fn` with a local queueing wrapper and records callback labels plus requested delays.
- `drain_deferred(expected_count, label)` executes captured callbacks synchronously in FIFO order and fails if the captured count differs from the cohort expectation.
- `STARTUP_COLD` and `STARTUP_WARM` emit deferred callback count `0`; any captured metadata fallback callback is a harness failure for those cohorts. `STARTUP_COLD` reaches this contract by using `type = "dbee-perf-no-metadata"`, not by suppressing or bypassing production `_try_start()`.
- `STARTUP_METADATA_FALLBACK` emits deferred callback count `1`; the measured metadata execution path is the captured production callback, not a second direct `_execute_metadata_query()` call left alongside a live timer. This cohort uses a synthetic connection record with `type = "postgres"` so production `METADATA_QUERIES[conn.type]` schedules the fallback.
</measurement_protocol>

<semantic_sentinels>
Every measured scenario emits `LSP01_<SCENARIO>_SENTINEL_OK=true|false`.

Sentinel failure policy:
- Any active scenario sentinel failure exits nonzero in advisory and blocking mode after emitting failure markers and writing the summary artifact.
- A publishable run must have exactly 29 `LSP01_<SCENARIO>_SENTINEL_OK=true` markers and zero `LSP01_<SCENARIO>_SENTINEL_OK=false` markers.
- Supporting sentinel families are counted separately from the 29 scenario `_SENTINEL_OK` markers:
  - exactly 17 `LSP01_<SCENARIO>_NO_STALE_CLIENTS=true` markers for the direct `dbee-lsp-perf` scenarios that create standalone in-process clients, and zero `LSP01_<SCENARIO>_NO_STALE_CLIENTS=false` markers;
  - exactly 15 `LSP01_STARTUP_WARM_DISK_LOADED=true` emissions for the `STARTUP_WARM` cohort's 5 warmup + 10 measured iterations, and zero `LSP01_STARTUP_WARM_DISK_LOADED=false` markers;
  - trace-only subprocess diagnostics `LSP01_TRACE_WORKLOAD`, `LSP01_TRACE_WORKLOAD_ITERATIONS`, and `LSP01_TRACE_WORKLOAD_DURATION_MS` are emitted by the trace pass and must not contribute to scenario median/p95 or threshold candidate markers.
- `LSP01_REAL_LSP_PERF_ALL_PASS` must never be `true` or `unfrozen` when any scenario sentinel is false.

Completion sentinels:
- Table completion cohorts require known table labels such as `TABLE_000001` and `TABLE_000100`, require item count `>= table_count` for the cohort, and fail if an impossible label such as `TABLE_999999` appears.
- Schema completion requires `SCHEMA_001` and excludes `_missing_schema`.
- Keyword completion requires `SELECT`, `FROM`, and `WHERE`.
- Column hit and cold miss require `COL_001`, `COL_010`, and no columns from a different table.
- Cold miss also requires `LSP01_COLUMN_MISS_FETCH_DELTAS_OK=true` for the exact measured-sample delta pattern `[1,0,0,0,0,0,0,0,0,0]`.

Diagnostic sentinels:
- Each diagnostics corpus includes at least one known invalid table reference and one known valid table reference.
- `didChange` and `didSave` scenarios fail unless diagnostics include the expected `Unknown table: MISSING_TABLE_<N>` message, expected count, and expected line/range for the invalid reference.
- Diagnostics scenarios fail if the fixture guarantees an unknown table but the diagnostic list is empty.

Startup sentinels:
- `STARTUP_COLD` fails unless the fake handler records one production structure refresh request, `structure_loaded` starts the LSP, and no local user state path is read.
- `STARTUP_WARM` fails unless isolated disk JSON is loaded before start, the seeded schema/table shape is observed from `SchemaCache:load_from_disk()`, `LSP01_STARTUP_WARM_DISK_LOADED=true` is emitted for every warmup/measured iteration, and the background refresh request is recorded.
- `STARTUP_METADATA_FALLBACK` fails unless metadata result processing writes disk cache and starts the LSP from `build_from_metadata_rows()`.
- `STARTUP_COLD` fails unless the fake current connection type is exactly `dbee-perf-no-metadata`.
- `STARTUP_METADATA_FALLBACK` fails unless the fake current connection is synthetic but metadata-capable via `type = "postgres"`.
- Lifecycle startup scenarios fail unless `LSP01_FAKE_STATE_USED=true` and `LSP01_FAKE_HANDLER_LIFECYCLE_COMPLETE=true`.
- `STARTUP_METADATA_FALLBACK` fails unless `LSP01_METADATA_FALLBACK_FAKE_CALL_COUNT=1`; live RPC is forbidden, but fake handler RPC is required for production-path fidelity.
- `STARTUP_COLD` fails unless `LSP01_COLD_DISK_DEFERRED_CALLBACK_COUNT=0`.
- `STARTUP_WARM` fails unless `LSP01_WARM_DISK_DEFERRED_CALLBACK_COUNT=0`.
- `STARTUP_METADATA_FALLBACK` fails unless `LSP01_METADATA_FALLBACK_DEFERRED_CALLBACK_COUNT=1`.
- The three deferred-count markers are part of the 29-scenario sentinel gate: each startup scenario's `LSP01_<SCENARIO>_SENTINEL_OK=true` requires the corresponding deferred-count marker to match exactly.

Client-cleanup sentinels:
- Every direct standalone `dbee-lsp-perf` scenario fails unless its final cleanup emits `LSP01_<SCENARIO>_NO_STALE_CLIENTS=true`.
- The 17 active direct-client scenarios that emit `NO_STALE_CLIENTS` are: `COMPLETION_TABLE_100`, `COMPLETION_TABLE_1000`, `COMPLETION_TABLE_10000`, `COMPLETION_SCHEMA`, `COMPLETION_KEYWORD`, `COMPLETION_COLUMN_HIT`, `COMPLETION_COLUMN_MISS_SYNC`, `DIAGNOSTICS_DIDCHANGE_100`, `DIAGNOSTICS_DIDCHANGE_1000`, `DIAGNOSTICS_DIDCHANGE_10000`, `DIAGNOSTICS_DIDSAVE_100`, `DIAGNOSTICS_DIDSAVE_1000`, `DIAGNOSTICS_DIDSAVE_10000`, `ALIAS_SIMPLE_SELECT`, `ALIAS_NESTED_CTE`, `ALIAS_MULTILINE`, and `ALIAS_MULTI_JOIN`.

Trace workload markers:
- The trace-only pass emits `LSP01_TRACE_WORKLOAD=startup_cold+completion+diagnostics_didchange`, `LSP01_TRACE_WORKLOAD_ITERATIONS=<n>`, and `LSP01_TRACE_WORKLOAD_DURATION_MS=<ms>` from the subprocess that writes `LSP01_PERF_TRACE_PATH`.
- Trace workload markers prove trace content, but they are outside the gated sample set and must not affect scenario sentinel counts, median/p95 samples, or threshold candidates.
</semantic_sentinels>

<threshold_state_machine>
The LSP threshold state machine mirrors Phase 9 and is explicit.

Per-scenario threshold resolution:
- For the active platform, frozen scenario pass is `true` only when `STATUS=frozen`, `LSP01_<SCENARIO>_SENTINEL_OK=true`, `median <= threshold.median_ms`, and `p95 <= threshold.p95_ms`.
- If `STATUS=frozen` and either timing bound fails, emit `_PASS=false`.
- If `STATUS=frozen` and the sentinel fails, emit `_PASS=false` even when timings pass.
- If `STATUS=candidate|missing` and the sentinel passes, emit `_PASS=unfrozen`.
- If `STATUS=candidate|missing` and the sentinel fails, emit `_PASS=false`.
- For inactive platforms in the same job, emit candidate values as `NA` and `_PASS=unfrozen`.
- If `LSP01_PUBLISHABLE=false`, emit no active-platform threshold candidate values; threshold candidate markers for that run must be `NA`, and the run must not be used for freeze decisions.

Per-platform rollup:
- `LSP01_<PLATFORM>_PERF_THRESHOLD_PASS=true` only when every active-platform scenario is frozen and passing.
- `LSP01_<PLATFORM>_PERF_THRESHOLD_PASS=false` when any active-platform frozen scenario fails timing or any active-platform sentinel fails.
- `LSP01_<PLATFORM>_PERF_THRESHOLD_PASS=unfrozen` when at least one active-platform scenario is not frozen and all active-platform sentinels pass.

Overall rollup:
- There is no inherited Phase 7 LSP perf budget rollup.
- `LSP01_REAL_LSP_PERF_ALL_PASS=true` only when all 29 scenario sentinels are true, `LSP01_PLATFORM_AUTHENTIC=true`, `LSP01_PUBLISHABLE=true`, and the active-platform threshold rollup is `true`.
- `LSP01_REAL_LSP_PERF_ALL_PASS=unfrozen` only when all 29 scenario sentinels are true, `LSP01_PLATFORM_AUTHENTIC=true`, `LSP01_PUBLISHABLE=true`, and the active-platform threshold rollup is `unfrozen`.
- `LSP01_REAL_LSP_PERF_ALL_PASS=false` if any sentinel is false, any frozen slot fails, platform authenticity fails, or the run is nonpublishable.
- Advisory mode emits `_MEDIAN_CANDIDATE_MS`, `_P95_CANDIDATE_MS`, and `_STATUS=frozen|candidate|missing` for every scenario.
- Blocking mode fails closed if the active platform is not frozen or any active-platform threshold slot is missing.
</threshold_state_machine>

<alias_corpus_dimensions>
Alias/context scaling corpora are fixed:
- `ALIAS_SIMPLE_SELECT`: 1-line statement, 1 `FROM` alias, cursor after `t.`, expected alias count `1`, expected columns `COL_001` and `COL_010`.
- `ALIAS_NESTED_CTE`: 3 CTE levels, 3 aliases, 40 total lines, cursor in the final SELECT after the latest alias dot, expected alias count `3`.
- `ALIAS_MULTILINE`: 25-line statement with `FROM` and `JOIN` aliases split across lines, 4 aliases, cursor after the fourth alias dot, expected alias count `4`.
- `ALIAS_MULTI_JOIN`: 1-line statement with 5 joined tables and 5 aliases, cursor after alias `t5.`, expected alias count `5`.

Each alias scenario emits a corpus marker such as `LSP01_CORPUS_ALIAS_MULTI_JOIN=lines:1,joins:5,aliases:5,cursor:t5_dot`.
</alias_corpus_dimensions>

<dependency_dag>
Single plan, four internal waves.

Wave 1:
- `10-01-01` -> Phase 9 perf preflight plus shared bootstrap wording and no-`nvim-nio` guard in `ci/headless/perf_bootstrap.mk`
- `10-01-02` -> LSP threshold source of truth in `ci/headless/lsp_perf_thresholds.lua`
- `10-01-03` depends on `10-01-01` and `10-01-02`
- `10-01-04` has no dependency beyond D-147

Wave 2:
- `10-01-05` depends on `10-01-02`
- `10-01-06` depends on `10-01-05`

Wave 3:
- `10-01-07` depends on `10-01-06`
- `10-01-08` depends on `10-01-06`
- `10-01-09` depends on `10-01-08`
- `10-01-10` depends on `10-01-06`
- `10-01-11` depends on `10-01-06`

Wave 4:
- `10-01-12` depends on `10-01-03`, `10-01-07`, `10-01-08`, `10-01-09`, `10-01-10`, and `10-01-11`

Parallelizable lanes:
- `10-01-01`, `10-01-02`, and `10-01-04` can run in parallel because they touch different files.
- After `10-01-06`, scenario tasks touching `ci/headless/check_lsp_perf.lua` must be serialized if one executor owns the file. If multiple workers are used, assign only one worker to `check_lsp_perf.lua`.
- `10-01-12` is intentionally last so CI reflects the final local command and marker contract.
</dependency_dag>

<tasks>
<task type="auto">
  <id>10-01-01</id>
  <title>Verify and extend the shared perf bootstrap contract for LSP use</title>
  <commit>chore(10-01-01): extend perf bootstrap for lsp lane</commit>
  <wave>1</wave>
  <files>ci/headless/perf_bootstrap.mk</files>
  <read_first>
    - ci/headless/perf_bootstrap.mk
    - .planning/phases/09-real-nui-perf-harness/09-CONTEXT.md
    - .planning/phases/10-lsp-optimization/10-CONTEXT.md
  </read_first>
  <action>
    Add a Phase 9 dependency preflight to the shared perf bootstrap contract, then update `ci/headless/perf_bootstrap.mk` so its comments and printed labels describe the shared Phase 9 drawer plus Phase 10 LSP perf bootstrap, while keeping the existing pinned `NUI_NVIM_COMMIT`, `BENCHMARK_NVIM_COMMIT`, and `PROFILE_NVIM_COMMIT` values unchanged.

    The preflight must verify these Phase 9 outputs before downstream Phase 10 consumers run:
    - `ci/headless/perf_bootstrap.mk` exists and contains `NUI_NVIM_COMMIT`, `BENCHMARK_NVIM_COMMIT`, and `PROFILE_NVIM_COMMIT`;
    - `ci/headless/perf_thresholds.lua` exists and returns Linux/macOS threshold tables;
    - `ci/headless/check_drawer_perf.lua` exists and contains `DRAW01_REAL_NUI_PERF_ALL_PASS`;
    - `Makefile` still includes `ci/headless/perf_bootstrap.mk`.

    Add no new runtime dependency pins. In particular, do not add `nvim-nio`, `plenary.nvim`, `mini.test`, or any LSP-specific async/runtime dependency.

    Keep `PERF_RUNTIMEPATH_CMD` and `PERF_NVIM_HEADLESS` as the single local/CI command surface consumed by both drawer and LSP perf targets.
  </action>
  <verify>
    <automated>
      grep -n "BENCHMARK_NVIM_COMMIT\|PROFILE_NVIM_COMMIT\|PERF_RUNTIMEPATH_CMD\|PERF_NVIM_HEADLESS" ci/headless/perf_bootstrap.mk
      grep -n "DRAW01_REAL_NUI_PERF_ALL_PASS" ci/headless/check_drawer_perf.lua
      grep -n "linux = {\|macos = {" ci/headless/perf_thresholds.lua
      ! grep -n "nvim%-nio\|plenary.nvim\|mini.test" ci/headless/perf_bootstrap.mk
    </automated>
  </verify>
  <acceptance_criteria>
    - `ci/headless/perf_bootstrap.mk` still contains `BENCHMARK_NVIM_COMMIT := db5861266656a4a72d2c5a801a8a2ebaf670b47f`.
    - `ci/headless/perf_bootstrap.mk` still contains `PROFILE_NVIM_COMMIT := 30433d7513f0d14665c1cfcea501c90f8a63e003`.
    - `ci/headless/check_drawer_perf.lua` contains `DRAW01_REAL_NUI_PERF_ALL_PASS`.
    - `grep -n "nvim-nio" ci/headless/perf_bootstrap.mk` returns no matches.
  </acceptance_criteria>
</task>

<task type="auto">
  <id>10-01-02</id>
  <title>Add the LSP threshold source of truth</title>
  <commit>feat(10-01-02): add lsp perf thresholds</commit>
  <wave>1</wave>
  <files>ci/headless/lsp_perf_thresholds.lua</files>
  <read_first>
    - ci/headless/perf_thresholds.lua
    - .planning/phases/10-lsp-optimization/10-CONTEXT.md
  </read_first>
  <action>
    Create `ci/headless/lsp_perf_thresholds.lua` as the LSP-only threshold source of truth.

    The file must return a Lua table with `linux` and `macos` entries, each containing `frozen = false` plus one entry for every required scenario threshold key from the canonical registry. Each scenario entry must have `median_ms`, `p95_ms`, and `source`.

    Seed advisory values:
    - `startup_cold.p95_ms = 500`
    - `startup_warm.p95_ms = 100`
    - all cached completion p95 budgets `30`
    - `completion_column_miss_sync.p95_ms = 200`
    - didChange and didSave diagnostics p95 budgets `50`
    - `cache_build_1000.p95_ms = 100`

    For scenario/platform slots without a research seed, set both `median_ms = nil` and `p95_ms = nil`, with `source = "advisory-candidate"`.

    Include a manual freeze ceremony matching Phase 9:
    1. collect four weeks of advisory evidence with >=95% pass rate per platform;
    2. copy adopted Linux and macOS medians/p95s into this file;
    3. set the platform `frozen = true`;
    4. flip `LSP01_PERF_GATE_MODE=blocking` in `.github/workflows/test.yml` in the same change.
  </action>
  <verify>
    <automated>
      grep -n "startup_cold\|completion_table_10000\|completion_column_miss_sync\|diagnostics_didchange_10000\|diagnostics_didsave_10000\|cache_save_10000\|frozen = false" ci/headless/lsp_perf_thresholds.lua
    </automated>
  </verify>
  <acceptance_criteria>
    - `ci/headless/lsp_perf_thresholds.lua` exists and returns `linux` and `macos` tables.
    - The file contains `startup_cold`, `startup_warm`, `completion_column_miss_sync`, `diagnostics_didchange_10000`, `diagnostics_didsave_10000`, `cache_build_1000`, `cache_load_10000`, and `cache_save_10000`.
    - The file contains the string `LSP01_PERF_GATE_MODE=blocking`.
  </acceptance_criteria>
</task>

<task type="auto">
  <id>10-01-03</id>
  <title>Add local LSP perf targets</title>
  <commit>test(10-01-03): add lsp perf make targets</commit>
  <wave>1</wave>
  <files>Makefile</files>
  <read_first>
    - Makefile
    - ci/headless/perf_bootstrap.mk
    - ci/headless/lsp_perf_thresholds.lua
  </read_first>
  <action>
    Extend the existing Makefile with LSP-specific variables and targets without changing the existing `perf` drawer target.

    Add:
    - `LSP01_PERF_GATE_MODE ?= advisory`
    - `LSP01_ALLOW_NONPUBLISHABLE_PLATFORM_OVERRIDE ?= 0`
    - `LSP01_PERF_THRESHOLD_FILE ?= ci/headless/lsp_perf_thresholds.lua`
    - `LSP_PERF_SCRIPT ?= $(CURDIR)/ci/headless/check_lsp_perf.lua`
    - `LSP01_PERF_ARTIFACT_DIR ?= .../lsp01-perf/$(PERF_PLATFORM)`
    - `LSP01_PERF_SUMMARY_PATH ?= $(LSP01_PERF_ARTIFACT_DIR)/lsp01-summary.txt`
    - `LSP01_PERF_TRACE_PATH ?= $(LSP01_PERF_ARTIFACT_DIR)/lsp01-trace.json`
    - `LSP01_PERF_STATE_HOME ?= $(LSP01_PERF_ARTIFACT_DIR)/state-home`

    Add `.PHONY: perf-lsp perf-all`.

    Add `perf-lsp: perf-bootstrap` that:
    - requires Neovim `v0.12.x`, using the same version check shape as `perf`;
    - creates `$(LSP01_PERF_ARTIFACT_DIR)`;
    - prints the exact LSP perf command;
    - exports `LSP01_PERF_GATE_MODE`, `LSP01_ALLOW_NONPUBLISHABLE_PLATFORM_OVERRIDE`, `PERF_PLATFORM`, `LSP01_PERF_ARTIFACT_DIR`, `LSP01_PERF_SUMMARY_PATH`, `LSP01_PERF_TRACE_PATH`, `LSP01_PERF_THRESHOLD_FILE`, and `XDG_STATE_HOME="$(LSP01_PERF_STATE_HOME)"`;
    - runs `$(PERF_NVIM_HEADLESS) -c "luafile $(LSP_PERF_SCRIPT)"`;
    - prints summary and trace paths on failure.

    Add `perf-all: perf perf-lsp`.
  </action>
  <verify>
    <automated>
      grep -n "^perf-lsp:\|^perf-all:\|LSP01_PERF_GATE_MODE\|LSP01_ALLOW_NONPUBLISHABLE_PLATFORM_OVERRIDE\|LSP01_PERF_THRESHOLD_FILE\|LSP_PERF_SCRIPT\|LSP01_PERF_TRACE_PATH\|LSP01_PERF_STATE_HOME\|XDG_STATE_HOME" Makefile
    </automated>
  </verify>
  <acceptance_criteria>
    - `make -n perf-lsp PERF_PLATFORM=macos` includes `ci/headless/check_lsp_perf.lua`.
    - `make -n perf-lsp PERF_PLATFORM=macos` includes `LSP01_PERF_THRESHOLD_FILE=ci/headless/lsp_perf_thresholds.lua`.
    - `make -n perf-lsp PERF_PLATFORM=macos` includes `XDG_STATE_HOME=`.
    - `make -n perf-all PERF_PLATFORM=macos` includes both the existing drawer `perf` target and `perf-lsp`.
  </acceptance_criteria>
</task>

<task type="auto">
  <id>10-01-04</id>
  <title>Migrate the interactive LSP bench probe to vim.uv</title>
  <commit>chore(10-01-04): migrate lsp bench timer to vim uv</commit>
  <wave>1</wave>
  <files>lua/dbee/lsp/bench.lua</files>
  <read_first>
    - lua/dbee/lsp/bench.lua
    - .planning/phases/10-lsp-optimization/10-CONTEXT.md
  </read_first>
  <action>
    Preserve all existing `stepN()` functions and output labels in `lua/dbee/lsp/bench.lua`.

    Add `local uv = vim.uv or vim.loop` near the top of the file and replace both `vim.loop.hrtime()` calls in `timed()` with `uv.hrtime()`.

    Do not convert interactive bench steps into async behavior, do not add `nvim-nio`, and do not change what any step measures.
  </action>
  <verify>
    <automated>
      grep -n "local uv = vim.uv or vim.loop\|uv.hrtime" lua/dbee/lsp/bench.lua
      ! grep -n "vim.loop.hrtime" lua/dbee/lsp/bench.lua
    </automated>
  </verify>
  <acceptance_criteria>
    - `lua/dbee/lsp/bench.lua` contains `local uv = vim.uv or vim.loop`.
    - `grep -n "vim.loop.hrtime" lua/dbee/lsp/bench.lua` returns no matches.
    - Existing strings `function M.step1()` through `function M.step8b()` remain present.
  </acceptance_criteria>
</task>

<task type="auto">
  <id>10-01-05</id>
  <title>Scaffold the LSP perf harness shell, markers, thresholds, and artifacts</title>
  <commit>feat(10-01-05): scaffold lsp perf harness</commit>
  <wave>2</wave>
  <files>ci/headless/check_lsp_perf.lua</files>
  <read_first>
    - ci/headless/check_drawer_perf.lua
    - ci/headless/lsp_perf_thresholds.lua
    - lua/dbee/lsp/server.lua
  </read_first>
  <action>
    Create `ci/headless/check_lsp_perf.lua`.

    Implement:
    - `fail(msg)` that prints `LSP01_FAIL=<msg>` and exits with `cquit 1`;
    - threshold loading from `LSP01_PERF_THRESHOLD_FILE` with `{ linux = ..., macos = ... }` validation;
    - `LSP01_PERF_GATE_MODE=advisory|blocking` validation;
    - platform detection from `PERF_PLATFORM`, falling back to `vim.uv.os_uname().sysname`;
    - actual OS detection from `vim.uv.os_uname().sysname`, emitting `LSP01_ACTUAL_OS=darwin|linux|other`;
    - platform-authenticity checks that emit `LSP01_PLATFORM_AUTHENTIC=true|false` and `LSP01_PUBLISHABLE=true|false`;
    - fail-closed behavior for publishable threshold runs when `PERF_PLATFORM` conflicts with actual OS; `LSP01_ALLOW_NONPUBLISHABLE_PLATFORM_OVERRIDE=1` may continue for debug only, but must suppress threshold candidate emission;
    - blocking fail-closed behavior when the active platform is not frozen or required threshold slots are missing;
    - `emit(label, value)`, `emit_ms(label, ns)`, `median`, `percentile`, and p95 helpers;
    - `run_benchmark(spec)` using `benchmark.run({ warm_up = 5, iterations = 10 })`, with explicit measured-iteration indexes and an optional `after_warmup_before_measured()` hook for scenarios like `COMPLETION_COLUMN_MISS_SYNC`;
    - a canonical scenario registry where each row has `slug`, `threshold_key`, `corpus`, and `sentinel` fields;
    - exact threshold state machine from `<threshold_state_machine>`, including sentinel-aware pass calculation;
    - run-level sentinel aggregation that exits nonzero when any active scenario emits `LSP01_<SCENARIO>_SENTINEL_OK=false`;
    - supporting sentinel marker families from `<semantic_sentinels>`: 17 direct-client `LSP01_<SCENARIO>_NO_STALE_CLIENTS=true|false` markers, 15 `LSP01_STARTUP_WARM_DISK_LOADED=true|false` warm-start emissions, and trace-only `LSP01_TRACE_WORKLOAD*` diagnostics outside the gated sample set;
    - summary file writing to `LSP01_PERF_SUMMARY_PATH`;
    - trace-only `benchmark.flame_profile()` pass writing to `LSP01_PERF_TRACE_PATH`;
    - base markers: `LSP01_PERF_MODE=real-lsp`, `LSP01_PERF_GATE_MODE`, `LSP01_PLATFORM`, `LSP01_ACTUAL_OS`, `LSP01_PLATFORM_AUTHENTIC`, `LSP01_PUBLISHABLE`, `LSP01_NVIM_VERSION`, `LSP01_THRESHOLD_FILE`, `LSP01_SUMMARY_ARTIFACT`, `LSP01_FLAME_TRACE_ARTIFACT`, `LSP01_WARMUP_COUNT`, `LSP01_MEASURED_COUNT`, `LSP01_STDPATH_STATE`, and `LSP01_SCENARIOS_COUNT`.

    Do not add scenario implementations in this task beyond a placeholder scenario registry that fails if empty.
  </action>
  <verify>
    <automated>
      grep -n "LSP01_PERF_MODE\|LSP01_PERF_GATE_MODE\|LSP01_ACTUAL_OS\|LSP01_PLATFORM_AUTHENTIC\|LSP01_PUBLISHABLE\|benchmark.run\|after_warmup_before_measured\|benchmark.flame_profile\|LSP01_REAL_LSP_PERF_ALL_PASS\|SENTINEL_OK\|threshold_key\|LSP01_STDPATH_STATE\|lsp_perf_thresholds" ci/headless/check_lsp_perf.lua
    </automated>
  </verify>
  <acceptance_criteria>
    - `ci/headless/check_lsp_perf.lua` fails with `LSP01_FAIL=` when `benchmark.nvim` is missing.
    - `ci/headless/check_lsp_perf.lua` contains `warm_up = WARMUP_COUNT` and `iterations = MEASURED_COUNT`.
    - `ci/headless/check_lsp_perf.lua` contains `LSP01_STDPATH_STATE`.
    - `ci/headless/check_lsp_perf.lua` contains `LSP01_ACTUAL_OS`, `LSP01_PLATFORM_AUTHENTIC`, and `LSP01_PUBLISHABLE`.
    - `ci/headless/check_lsp_perf.lua` contains `SENTINEL_OK`.
    - `ci/headless/check_lsp_perf.lua` contains `after_warmup_before_measured`.
    - `ci/headless/check_lsp_perf.lua` contains `LSP01_REAL_LSP_PERF_ALL_PASS`.
  </acceptance_criteria>
</task>

<task type="auto">
  <id>10-01-06</id>
  <title>Add deterministic LSP fixture generation and real client attach helpers</title>
  <commit>feat(10-01-06): add lsp perf fixtures</commit>
  <wave>2</wave>
  <files>ci/headless/check_lsp_perf.lua</files>
  <read_first>
    - ci/headless/check_lsp_alias_completion.lua
    - ci/headless/check_lsp_schema_alias_completion.lua
    - lua/dbee/lsp/server.lua
    - lua/dbee/lsp/schema_cache.lua
  </read_first>
  <action>
    Add deterministic fixture and client helpers to `ci/headless/check_lsp_perf.lua`.

    Implement:
    - fixture constants `CONNECTION_TYPE_NO_METADATA = "dbee-perf-no-metadata"` and `CONNECTION_TYPE_METADATA = "postgres"`; the first proves structure-only cold startup has no metadata fallback timer, and the second is a synthetic connection record using a production metadata-capable type because `METADATA_QUERIES` is local to `lua/dbee/lsp/init.lua`;
    - `make_structure(table_count, columns_per_table)` that creates stable schema/table names such as `SCHEMA_001.TABLE_000001` and deterministic table/view materialization labels;
    - `make_columns(schema, table_name, columns_per_table)` that returns deterministic `Column[]` records;
    - `make_handler(opts)` with method-compatible synchronous `connection_get_columns = function(_, conn_id, request_opts)` that records call count, validates `conn_id`, `schema`, `table`, and `materialization`, and returns deterministic columns for `COMPLETION_COLUMN_MISS_SYNC`;
    - deterministic fake lifecycle methods used by `dbee.lsp._try_start()`: `get_current_connection`, `get_authoritative_root_epoch`, `get_connection_state_snapshot`, `begin_connection_invalidated_bootstrap`, `drain_connection_invalidated_bootstrap`, `promote_to_live`, `teardown_connection_invalidated_consumer`, `teardown_structure_consumer`, and `connection_get_structure_singleflight`;
    - `get_current_connection` must return the scenario-selected fake connection type: `dbee-perf-no-metadata` for `STARTUP_COLD` and `STARTUP_WARM`, `postgres` for `STARTUP_METADATA_FALLBACK`;
    - deterministic fake metadata methods `connection_execute` and `call_store_result` for `STARTUP_METADATA_FALLBACK`; live RPC is forbidden, but fake handler RPC is required for production-path fidelity;
    - method invocation counters for every fake lifecycle method, plus `assert_lifecycle_methods_complete(handler, cohort)` that emits `LSP01_FAKE_HANDLER_LIFECYCLE_COMPLETE=true|false` and fails when a startup cohort used compatibility fallback or skipped the expected lifecycle surface;
    - `make_cache(table_count, columns_per_table, opts)` using `require("dbee.lsp.schema_cache"):new(handler, conn_id)` and `cache:build_from_structure(structs)`;
    - `make_buffer(lines)` creating scratch SQL buffers and URIs;
    - `start_lsp(cache, bufnr)` using `vim.lsp.start({ name = "dbee-lsp-perf", cmd = server.create(cache), root_dir = vim.fn.getcwd() }, { bufnr = bufnr })` and waiting for client initialization;
    - `with_fake_lsp_state(handler, fn)` that saves prior `package.loaded["dbee.api.state"]` and `package.loaded["dbee.lsp"]`, installs fake state before requiring `dbee.lsp`, clears `package.loaded["dbee.lsp"]` to force a re-require with the fake state reference, runs `fn(lsp)`, calls `lsp.stop()` before exit, restores both modules, and emits `LSP01_FAKE_STATE_USED=true|false` from fake-state call counts;
    - `capture_defer_fn()` that monkey-patches `vim.defer_fn` inside one lifecycle cohort, records callbacks into a queue instead of arming Neovim timers, and restores the original `vim.defer_fn` in cleanup;
    - `drain_deferred(expected_count, label)` that executes captured callbacks synchronously and fails if the count is not exact;
    - `queue_try_start(bufnr, handler, opts)` that drives `require("dbee.lsp").queue_buffer(bufnr)` / `_try_start()` without waiting for startup;
    - `wait_running(lsp, label)` that waits on `require("dbee.lsp").status().running`;
    - `wait_metadata_fallback(lsp, handler, opts)` that asserts one captured deferred callback, drains it once to invoke the production metadata fallback callback, then invokes `_process_metadata_result(handler, call_id, conn_id)` and waits for running;
    - `start_lsp_via_lifecycle(bufnr, handler, opts)` as a thin coordinator for non-metadata lifecycle cohorts that calls `queue_try_start()` and then `wait_running()`;
    - `assert_isolated_state()` that verifies `vim.fn.stdpath("state")` is under `vim.env.XDG_STATE_HOME` and emits `LSP01_STDPATH_STATE=`;
    - `cleanup_lsp(state)` that calls `require("dbee.lsp").stop()` for lifecycle scenarios, drains remaining captured deferred callbacks, verifies fake metadata execution count stayed at the cohort's expected value, restores `vim.defer_fn`, stops direct-attach clients for non-startup scenarios, deletes scratch buffers, restores fake modules, clears pending buffer state via the production stop path, and asserts `require("dbee.lsp").status().running == false` before the next sample.

    Keep all fixtures hermetic. Do not open live database connections and do not call Go RPC functions. Fake handler methods may be named like production RPC surfaces only when they return deterministic local fixture data and record call counts.
  </action>
  <verify>
    <automated>
      grep -n "make_structure\|make_columns\|make_handler\|start_lsp\|start_lsp_via_lifecycle\|queue_try_start\|wait_running\|wait_metadata_fallback\|capture_defer_fn\|drain_deferred\|with_fake_lsp_state\|assert_lifecycle_methods_complete\|assert_isolated_state\|server.create(cache)\|connection_get_columns\|connection_get_structure_singleflight\|begin_connection_invalidated_bootstrap\|drain_connection_invalidated_bootstrap\|promote_to_live\|connection_execute\|call_store_result\|dbee-perf-no-metadata\|CONNECTION_TYPE_METADATA" ci/headless/check_lsp_perf.lua
    </automated>
  </verify>
  <acceptance_criteria>
    - `ci/headless/check_lsp_perf.lua` contains `function make_structure`.
    - `ci/headless/check_lsp_perf.lua` contains `function start_lsp`.
    - `ci/headless/check_lsp_perf.lua` contains `function start_lsp_via_lifecycle`.
    - `ci/headless/check_lsp_perf.lua` contains `function queue_try_start`, `function wait_running`, and `function wait_metadata_fallback`.
    - `ci/headless/check_lsp_perf.lua` contains `function capture_defer_fn` and `function drain_deferred`.
    - `ci/headless/check_lsp_perf.lua` contains `function with_fake_lsp_state`.
    - `ci/headless/check_lsp_perf.lua` contains `LSP01_FAKE_STATE_USED`.
    - `ci/headless/check_lsp_perf.lua` contains `LSP01_FAKE_HANDLER_LIFECYCLE_COMPLETE`.
    - `ci/headless/check_lsp_perf.lua` contains `connection_get_columns = function(_, conn_id, request_opts)`.
    - `ci/headless/check_lsp_perf.lua` contains fake `connection_execute` and `call_store_result` methods.
    - `ci/headless/check_lsp_perf.lua` contains `dbee-perf-no-metadata` for `STARTUP_COLD`.
    - `ci/headless/check_lsp_perf.lua` contains `CONNECTION_TYPE_METADATA = "postgres"` or equivalent metadata-capable fixture wiring for `STARTUP_METADATA_FALLBACK`.
    - `ci/headless/check_lsp_perf.lua` contains the literal `server.create(cache)`.
    - `grep -n "DuckDB\\|sqlite\\|nvim-nio" ci/headless/check_lsp_perf.lua` returns no matches.
  </acceptance_criteria>
</task>

<task type="auto">
  <id>10-01-07</id>
  <title>Add startup and metadata-fallback scenarios</title>
  <commit>test(10-01-07): add lsp startup perf scenarios</commit>
  <wave>3</wave>
  <files>ci/headless/check_lsp_perf.lua</files>
  <read_first>
    - ci/headless/check_lsp_perf.lua
    - lua/dbee/lsp/schema_cache.lua
    - lua/dbee/lsp/init.lua
  </read_first>
  <action>
    Add startup scenarios to the scenario registry:
    - `STARTUP_COLD`: fresh isolated `XDG_STATE_HOME`, no prior disk JSON, fake state/handler installed through `with_fake_lsp_state(handler, fn)`, fake current connection has `type = "dbee-perf-no-metadata"`, `capture_defer_fn()` active, `queue_try_start(bufnr, handler)` triggers production `_try_start()`, fake handler records one connection-invalidated bootstrap, one current-connection lookup, one authoritative root-epoch lookup, one structure single-flight request with `caller_token = "lsp"`, synthetic `structure_loaded` payload starts the LSP, `wait_running()` completes, and sentinel verifies `LSP01_COLD_DISK_DEFERRED_CALLBACK_COUNT=0`. Metadata fallback in this cohort is a harness bug, and any captured deferred callback fails the sentinel.
    - `STARTUP_WARM`: pre-seeded table/schema and column JSON files generated by current `SchemaCache` save paths under isolated `XDG_STATE_HOME`, fake state/handler installed through `with_fake_lsp_state(handler, fn)`, `capture_defer_fn()` active, `queue_try_start(bufnr, handler)` triggers production disk `load_from_disk()`, connection-invalidated bootstrap and background structure refresh request are recorded, `wait_running()` completes, and sentinel verifies `LSP01_WARM_DISK_DEFERRED_CALLBACK_COUNT=0`. Metadata fallback in this cohort is a harness bug.
    - `STARTUP_METADATA_FALLBACK`: fake state/handler installed through `with_fake_lsp_state(handler, fn)`, fake current connection is synthetic but uses `type = "postgres"` so production `METADATA_QUERIES[conn.type]` exists, `capture_defer_fn()` active, no structure payload delivered, `queue_try_start(bufnr, handler)` captures exactly one production metadata fallback callback from `_try_start()`, `wait_metadata_fallback()` drains that captured callback once to drive fake `connection_execute()` without opening a live adapter/RPC/database, fake `call_store_result()` writes deterministic JSON rows, `_process_metadata_result(handler, call_id, conn_id)` builds from metadata rows and starts the LSP, and sentinels verify disk save, `LSP01_METADATA_FALLBACK_DEFERRED_CALLBACK_COUNT=1`, and `LSP01_METADATA_FALLBACK_FAKE_CALL_COUNT=1`.

    Each startup scenario must emit `LSP01_<SCENARIO>_MEDIAN_MS`, `LSP01_<SCENARIO>_P95_MS`, `LSP01_<SCENARIO>_SENTINEL_OK`, `LSP01_CORPUS_<SCENARIO>`, `LSP01_FAKE_STATE_USED`, `LSP01_FAKE_HANDLER_LIFECYCLE_COMPLETE`, and its deferred-callback-count marker, then evaluate active-platform threshold status through the shared threshold emitter. `STARTUP_WARM` must additionally emit `LSP01_STARTUP_WARM_DISK_LOADED=true|false` for each warmup/measured iteration and fail unless every emitted value is `true`.

    Live metadata SQL execution is forbidden in this task. Fake handler `connection_execute` is required for `STARTUP_METADATA_FALLBACK`; live RPC/adapter/database access remains forbidden.
  </action>
  <verify>
    <automated>
      grep -n "STARTUP_COLD\|STARTUP_WARM\|STARTUP_METADATA_FALLBACK\|dbee-perf-no-metadata\|CONNECTION_TYPE_METADATA\|with_fake_lsp_state\|capture_defer_fn\|drain_deferred\|queue_try_start\|wait_metadata_fallback\|_try_start\|_process_metadata_result\|build_from_metadata_rows\|LSP01_FAKE_STATE_USED\|LSP01_FAKE_HANDLER_LIFECYCLE_COMPLETE\|LSP01_COLD_DISK_DEFERRED_CALLBACK_COUNT\|LSP01_WARM_DISK_DEFERRED_CALLBACK_COUNT\|LSP01_METADATA_FALLBACK_DEFERRED_CALLBACK_COUNT\|LSP01_METADATA_FALLBACK_FAKE_CALL_COUNT" ci/headless/check_lsp_perf.lua
    </automated>
  </verify>
  <acceptance_criteria>
    - `ci/headless/check_lsp_perf.lua` contains `STARTUP_COLD`, `STARTUP_WARM`, and `STARTUP_METADATA_FALLBACK`.
    - The startup scenarios call `start_lsp_via_lifecycle`.
    - The startup scenarios contain `queue_try_start`.
    - The cold startup scenario uses fake connection type `dbee-perf-no-metadata`.
    - The metadata fallback scenario uses a synthetic fake connection with metadata-capable production type `postgres`.
    - The metadata fallback scenario contains `wait_metadata_fallback`.
    - The metadata fallback scenario contains `_process_metadata_result`.
    - The metadata fallback scenario emits `LSP01_METADATA_FALLBACK_FAKE_CALL_COUNT=1`.
    - The metadata fallback scenario emits `LSP01_METADATA_FALLBACK_DEFERRED_CALLBACK_COUNT=1`.
    - The cold and warm startup scenarios emit `LSP01_COLD_DISK_DEFERRED_CALLBACK_COUNT=0` and `LSP01_WARM_DISK_DEFERRED_CALLBACK_COUNT=0`.
    - Warm startup emits exactly 15 `LSP01_STARTUP_WARM_DISK_LOADED=true` markers in a normal 5-warmup/10-measured run and zero `false` values.
    - `STARTUP_COLD` and `STARTUP_WARM` fail their sentinels if fake `connection_execute` is invoked.
    - Cleanup drains remaining deferred callbacks and proves fake metadata execution counts remain `0` for cold/warm and `1` for metadata fallback.
    - `grep -n "DuckDB\\|sqlite\\|go rpc\\|adapter" ci/headless/check_lsp_perf.lua` returns no live-access matches outside explanatory comments.
  </acceptance_criteria>
</task>

<task type="auto">
  <id>10-01-08</id>
  <title>Add table, schema, keyword, and column-hit completion scenarios</title>
  <commit>test(10-01-08): add cached lsp completion perf scenarios</commit>
  <wave>3</wave>
  <files>ci/headless/check_lsp_perf.lua</files>
  <read_first>
    - ci/headless/check_lsp_perf.lua
    - ci/headless/check_lsp_alias_completion.lua
    - lua/dbee/lsp/server.lua
    - lua/dbee/lsp/context.lua
  </read_first>
  <action>
    Add cached completion scenarios to the scenario registry:
    - `COMPLETION_TABLE_100`
    - `COMPLETION_TABLE_1000`
    - `COMPLETION_TABLE_10000`
    - `COMPLETION_SCHEMA`
    - `COMPLETION_KEYWORD`
    - `COMPLETION_COLUMN_HIT`

    Implement `request_completion(state, line_text, character, context)` that:
    - sets the scratch buffer line;
    - starts the stopwatch immediately before `client:request("textDocument/completion", params, callback)`;
    - stops inside the callback after validating `result.items`;
    - records item count in the summary;
    - runs the scenario's semantic sentinel before accepting the sample.

    `COMPLETION_COLUMN_HIT` must preload columns before the request so the fake handler's `connection_get_columns` call count remains `0`.

    Add sentinels:
    - `COMPLETION_TABLE_100`, `COMPLETION_TABLE_1000`, and `COMPLETION_TABLE_10000` require expected table labels from the cohort and fail if the completion list is empty.
    - `COMPLETION_SCHEMA` requires `SCHEMA_001`.
    - `COMPLETION_KEYWORD` requires `SELECT`, `FROM`, and `WHERE`.
    - `COMPLETION_COLUMN_HIT` requires `COL_001` and `COL_010`, excludes columns from another table, and asserts `column_fetch_count == 0`.
    - Every completion scenario emits `LSP01_<SCENARIO>_SENTINEL_OK=true|false`.
  </action>
  <verify>
    <automated>
      grep -n "COMPLETION_TABLE_100\|COMPLETION_TABLE_1000\|COMPLETION_TABLE_10000\|COMPLETION_SCHEMA\|COMPLETION_KEYWORD\|COMPLETION_COLUMN_HIT\|SENTINEL_OK\|COL_001\|textDocument/completion" ci/headless/check_lsp_perf.lua
    </automated>
  </verify>
  <acceptance_criteria>
    - The harness contains all six cached completion scenario slugs.
    - The harness contains `client:request("textDocument/completion"`.
    - The `COMPLETION_COLUMN_HIT` scenario asserts `column_fetch_count == 0`.
    - The harness emits `LSP01_COMPLETION_TABLE_100_SENTINEL_OK`.
  </acceptance_criteria>
</task>

<task type="auto">
  <id>10-01-09</id>
  <title>Add the current synchronous cold column miss scenario</title>
  <commit>test(10-01-09): add sync column miss perf scenario</commit>
  <wave>3</wave>
  <files>ci/headless/check_lsp_perf.lua</files>
  <read_first>
    - ci/headless/check_lsp_perf.lua
    - ci/headless/check_lsp_schema_alias_completion.lua
    - lua/dbee/lsp/schema_cache.lua
    - lua/dbee/lsp/server.lua
  </read_first>
  <action>
    Add `COMPLETION_COLUMN_MISS_SYNC`.

    The scenario must:
    - create a cache with the target table present but target columns absent;
    - set the query to `SELECT * FROM SCHEMA_001.TABLE_000001 t WHERE t.` with the cursor after the final dot;
    - send completion through `client:request("textDocument/completion", ...)`;
    - allow current `SchemaCache:get_columns()` to call the fake handler's synchronous `connection_get_columns()`;
    - use disposable warmup cache/handler state so warmups cannot pre-warm the measured cache;
    - use the `after_warmup_before_measured()` hook to reset the measured cache columns and fetch counters immediately before measured sample 1;
    - record measured-sample fetch deltas, not cumulative counts;
    - assert measured sample 1 has fetch delta `1`;
    - assert measured samples 2..10 have fetch delta `0` because the measured cache is warmed by sample 1;
    - emit `LSP01_COLUMN_MISS_FETCH_DELTAS=1,0,0,0,0,0,0,0,0,0` and `LSP01_COLUMN_MISS_FETCH_DELTAS_OK=true` only for that exact pattern;
    - assert result labels include `COL_001` and `COL_010`;
    - fail if the column list is empty;
    - emit median/p95, `LSP01_COMPLETION_COLUMN_MISS_SYNC_SENTINEL_OK`, fetch-count markers, corpus marker, and threshold status markers.

    Do not add an async miss scenario, do not set `isIncomplete = true`, and do not call `connection_get_columns_async`.
  </action>
  <verify>
    <automated>
      grep -n "COMPLETION_COLUMN_MISS_SYNC\|SELECT \\* FROM SCHEMA_001.TABLE_000001 t WHERE t\\.\|after_warmup_before_measured\|LSP01_COLUMN_MISS_FETCH_DELTAS\|LSP01_COLUMN_MISS_FETCH_DELTAS_OK\|COL_001\|connection_get_columns" ci/headless/check_lsp_perf.lua
      ! grep -n "connection_get_columns_async\|isIncomplete = true\|nvim%-nio" ci/headless/check_lsp_perf.lua
    </automated>
  </verify>
  <acceptance_criteria>
    - `ci/headless/check_lsp_perf.lua` contains `COMPLETION_COLUMN_MISS_SYNC`.
    - `ci/headless/check_lsp_perf.lua` contains `SELECT * FROM SCHEMA_001.TABLE_000001 t WHERE t.`.
    - `ci/headless/check_lsp_perf.lua` contains `LSP01_COLUMN_MISS_FETCH_DELTAS_OK`.
    - `ci/headless/check_lsp_perf.lua` asserts the measured fetch-delta pattern `[1,0,0,0,0,0,0,0,0,0]`.
    - `ci/headless/check_lsp_perf.lua` does not contain `connection_get_columns_async`.
    - `ci/headless/check_lsp_perf.lua` does not contain `isIncomplete = true`.
  </acceptance_criteria>
</task>

<task type="auto">
  <id>10-01-10</id>
  <title>Add diagnostics and alias/context scaling scenarios</title>
  <commit>test(10-01-10): add lsp diagnostics and alias perf scenarios</commit>
  <wave>3</wave>
  <files>ci/headless/check_lsp_perf.lua</files>
  <read_first>
    - ci/headless/check_lsp_perf.lua
    - lua/dbee/lsp/server.lua
    - lua/dbee/lsp/context.lua
  </read_first>
  <action>
    Add diagnostics scenarios:
    - `DIAGNOSTICS_DIDCHANGE_100`
    - `DIAGNOSTICS_DIDCHANGE_1000`
    - `DIAGNOSTICS_DIDCHANGE_10000`
    - `DIAGNOSTICS_DIDSAVE_100`
    - `DIAGNOSTICS_DIDSAVE_1000`
    - `DIAGNOSTICS_DIDSAVE_10000`

    Each diagnostics scenario must populate a scratch SQL buffer with deterministic lines, notify `textDocument/didChange` or `textDocument/didSave`, and stop timing when `textDocument/publishDiagnostics` is received for the measured URI. Every diagnostics corpus must include a known valid table reference and a known invalid table reference such as `MISSING_TABLE_001`.

    Diagnostics sentinels must assert:
    - diagnostics count is non-zero;
    - expected message `Unknown table: MISSING_TABLE_001` is present;
    - expected line/range for the invalid reference is present;
    - valid fixture table references do not produce diagnostics;
    - `LSP01_<SCENARIO>_SENTINEL_OK=true|false` is emitted.

    Add alias/context scaling scenarios:
    - `ALIAS_SIMPLE_SELECT`
    - `ALIAS_NESTED_CTE`
    - `ALIAS_MULTILINE`
    - `ALIAS_MULTI_JOIN`

    Alias scenarios must drive completion requests that invoke `context.analyze(params)` through `server.lua`; they must not call private context functions directly.

    Use the fixed corpus dimensions from `<alias_corpus_dimensions>`. Each alias scenario must:
    - emit `LSP01_CORPUS_<SCENARIO>=...`;
    - validate expected alias count through deterministic expected columns;
    - require `COL_001` and `COL_010` in the completion result;
    - fail if the completion list is empty;
    - emit `LSP01_<SCENARIO>_SENTINEL_OK=true|false`.
  </action>
  <verify>
    <automated>
      grep -n "DIAGNOSTICS_DIDCHANGE_100\|DIAGNOSTICS_DIDCHANGE_1000\|DIAGNOSTICS_DIDCHANGE_10000\|DIAGNOSTICS_DIDSAVE_100\|DIAGNOSTICS_DIDSAVE_1000\|DIAGNOSTICS_DIDSAVE_10000\|ALIAS_SIMPLE_SELECT\|ALIAS_NESTED_CTE\|ALIAS_MULTILINE\|ALIAS_MULTI_JOIN\|MISSING_TABLE_001\|SENTINEL_OK\|publishDiagnostics" ci/headless/check_lsp_perf.lua
    </automated>
  </verify>
  <acceptance_criteria>
    - The harness contains all six diagnostics scenario slugs.
    - The harness contains all four alias scenario slugs.
    - Diagnostics scenarios wait for `textDocument/publishDiagnostics`.
    - Alias scenarios emit `LSP01_CORPUS_ALIAS_MULTI_JOIN`.
  </acceptance_criteria>
</task>

<task type="auto">
  <id>10-01-11</id>
  <title>Add schema-cache build and disk load/save scenarios</title>
  <commit>test(10-01-11): add lsp cache perf scenarios</commit>
  <wave>3</wave>
  <files>ci/headless/check_lsp_perf.lua</files>
  <read_first>
    - ci/headless/check_lsp_perf.lua
    - lua/dbee/lsp/schema_cache.lua
  </read_first>
  <action>
    Add schema-cache build scenarios:
    - `CACHE_BUILD_100`
    - `CACHE_BUILD_1000`
    - `CACHE_BUILD_10000`

    Add disk load scenarios:
    - `CACHE_LOAD_100`
    - `CACHE_LOAD_1000`
    - `CACHE_LOAD_10000`

    Add disk save scenarios:
    - `CACHE_SAVE_100`
    - `CACHE_SAVE_1000`
    - `CACHE_SAVE_10000`

    These scenarios must use `XDG_STATE_HOME=$LSP01_PERF_ARTIFACT_DIR/state-home` and current `SchemaCache` public APIs. They may expose current synchronous `io.open`/`vim.fn.glob` costs, but must not replace them with atomic writes or async file APIs.

    Each cache scenario must assert `vim.fn.stdpath("state")` is inside the run's `XDG_STATE_HOME`, clean the isolated state directory before cold load/build cohorts, and verify no files are read from the user's normal state directory.
  </action>
  <verify>
    <automated>
      grep -n "CACHE_BUILD_100\|CACHE_BUILD_1000\|CACHE_BUILD_10000\|CACHE_LOAD_10000\|CACHE_SAVE_10000\|XDG_STATE_HOME\|stdpath(\"state\")\|save_to_disk\|load_from_disk" ci/headless/check_lsp_perf.lua
    </automated>
  </verify>
  <acceptance_criteria>
    - The harness contains all nine cache scenario slugs.
    - Cache scenarios call `build_from_structure`, `save_to_disk`, and `load_from_disk`.
    - Cache scenarios assert `stdpath("state")` is under `XDG_STATE_HOME`.
    - `grep -n "rename\\|fs_rename\\|uv.fs_open" ci/headless/check_lsp_perf.lua` returns no matches added for cache writes.
  </acceptance_criteria>
</task>

<task type="auto">
  <id>10-01-12</id>
  <title>Add the Linux and macOS LSP perf advisory CI lane</title>
  <commit>test(10-01-12): add lsp perf advisory workflow</commit>
  <wave>4</wave>
  <files>.github/workflows/test.yml</files>
  <read_first>
    - .github/workflows/test.yml
    - Makefile
    - ci/headless/check_lsp_perf.lua
    - ci/headless/lsp_perf_thresholds.lua
  </read_first>
  <action>
    Add a `lua-lsp-perf-advisory` job to `.github/workflows/test.yml` that mirrors the Phase 9 `lua-real-nui-perf-advisory` shape.

    The job must:
    - use the same `NVIM_PERF_VERSION`;
    - run a matrix with `ubuntu-22.04` as `linux` and `macos-14` as `macos`;
    - set `continue-on-error: true`;
    - set `PERF_PLUGIN_ROOT`;
    - set `LSP01_PERF_ARTIFACT_DIR`, `LSP01_PERF_SUMMARY_PATH`, and `LSP01_PERF_TRACE_PATH`;
    - set `XDG_STATE_HOME=${{ runner.temp }}/lsp01-perf/${{ matrix.platform }}/state-home`;
    - run `make perf-bootstrap`;
    - run preserved fast LSP semantic checks: `check_lsp_alias_completion.lua`, `check_lsp_schema_alias_completion.lua`, and `check_lsp_alias_rebinding.lua`;
    - run `LSP01_PERF_GATE_MODE=advisory make perf-lsp PERF_PLATFORM=${{ matrix.platform }}` as the harness-producing step and keep its stdout in a log artifact even when it exits nonzero;
    - assert the summary and trace artifacts are non-empty in an `if: always()` step so failed advisory runs still produce diagnostic evidence;
    - upload artifacts named `linux-lsp-perf-threshold-summary`, `linux-lsp-perf-threshold-trace`, `macos-lsp-perf-threshold-summary`, and `macos-lsp-perf-threshold-trace` or a matrix equivalent that expands to those strings, with `if: always()`;
    - run marker validation as a separate step after artifact upload; that validation asserts `LSP01_PLATFORM_AUTHENTIC=true`, `LSP01_PUBLISHABLE=true`, no `_SENTINEL_OK=false`, exactly 29 `_SENTINEL_OK=true` markers, no `NO_STALE_CLIENTS=false`, exactly 17 `NO_STALE_CLIENTS=true` markers, exactly 15 `LSP01_STARTUP_WARM_DISK_LOADED=true` markers, no `LSP01_STARTUP_WARM_DISK_LOADED=false`, deferred callback counts are exact, and `LSP01_REAL_LSP_PERF_ALL_PASS=true|unfrozen`;
    - print the advisory promotion seam: four weeks, >=95% pass rate per platform, freeze `ci/headless/lsp_perf_thresholds.lua`, then flip `LSP01_PERF_GATE_MODE=blocking`.
  </action>
  <verify>
    <automated>
      grep -n "lua-lsp-perf-advisory\|LSP01_PERF_GATE_MODE=advisory\|make perf-lsp\|XDG_STATE_HOME\|if: always()\|upload-artifact\|LSP01_PLATFORM_AUTHENTIC=true\|LSP01_PUBLISHABLE=true\|SENTINEL_OK=false\|LSP01_METADATA_FALLBACK_DEFERRED_CALLBACK_COUNT=1\|lsp-perf-threshold\|check_lsp_alias_completion.lua\|check_lsp_schema_alias_completion.lua\|check_lsp_alias_rebinding.lua" .github/workflows/test.yml
    </automated>
  </verify>
  <acceptance_criteria>
    - `.github/workflows/test.yml` contains `lua-lsp-perf-advisory`.
    - `.github/workflows/test.yml` contains `continue-on-error: true` under the LSP advisory job.
    - `.github/workflows/test.yml` contains `make perf-lsp PERF_PLATFORM=${{ matrix.platform }}`.
    - `.github/workflows/test.yml` contains `XDG_STATE_HOME`.
    - `.github/workflows/test.yml` uploads summary and trace artifacts with `if: always()` even when marker validation fails.
    - `.github/workflows/test.yml` runs marker validation after artifact upload and fails the advisory job when any sentinel is false or `LSP01_REAL_LSP_PERF_ALL_PASS=false`.
    - `.github/workflows/test.yml` contains both `ubuntu-22.04` and `macos-14` in the LSP perf job matrix.
  </acceptance_criteria>
</task>
</tasks>

<decision_traceability>
- D-119, D-120, D-121 -> constraints, `10-01-07` through `10-01-11`, and deferred exclusions in `10-01-09`.
- D-122 -> `10-01-01`, `10-01-03`, `10-01-05`.
- D-123 -> `10-01-03`, `10-01-05`, `10-01-12`.
- D-124, D-125, D-126 -> `10-01-06`, `10-01-07`, `10-01-08`, `10-01-10`.
- D-127, D-128, D-129, D-130 -> `10-01-06`, `10-01-09`, plus acceptance checks forbidding live DB/RPC and `nvim-nio`.
- D-131 -> `10-01-07`.
- D-132 -> `10-01-08`, `10-01-09`.
- D-133, D-134 -> `10-01-10`, including didChange, didSave, and fixed alias corpus dimensions.
- D-135 -> `10-01-11`.
- D-136, D-137, D-138, D-139, D-140 -> `10-01-02`, `10-01-05`, all scenario tasks.
- D-141, D-142 -> `10-01-12` and final verification.
- D-143, D-144 -> `10-01-03`.
- D-145 -> `10-01-12`.
- D-146, D-147 -> `10-01-04`.
- D-148 -> constraints and every scenario task acceptance criteria.
- D-149 -> measurement protocol, dependency DAG, and scenario implementation discretion.
</decision_traceability>

<threat_model>
- **Threat: CI artifact spoofing or false green perf lane**
  - Severity: medium
  - Mitigation: `make perf-lsp` must fail closed when pinned dependencies, threshold files, summary artifacts, or trace artifacts are missing; CI asserts non-empty artifacts and emits grep-friendly markers.

- **Threat: accidental live database access in CI**
  - Severity: medium
  - Mitigation: deterministic fake handler only; acceptance criteria grep for absence of DuckDB/sqlite/live metadata execution and forbid Go RPC adapter calls in the perf harness.

- **Threat: advisory candidates self-certify as passing**
  - Severity: medium
  - Mitigation: threshold state machine emits `PASS=unfrozen` until active platform thresholds are frozen; blocking mode fails when frozen thresholds are missing.

- **Threat: swallowed completion or diagnostic errors publish fast empty results**
  - Severity: high
  - Mitigation: every scenario emits `LSP01_<SCENARIO>_SENTINEL_OK`; any false sentinel exits nonzero, final verification requires exactly 29 true scenario sentinels, no false scenario sentinels, exact supporting cleanup/disk-load sentinel counts, and rollups fail when sentinels fail.

- **Threat: harness reads or writes the user's real Neovim state**
  - Severity: high
  - Mitigation: `make perf-lsp` sets per-run `XDG_STATE_HOME`, harness emits `LSP01_STDPATH_STATE`, and cache scenarios fail if `stdpath("state")` is outside the artifact directory.

- **Threat: wrong-platform thresholds are published from a local override**
  - Severity: high
  - Mitigation: harness emits `LSP01_ACTUAL_OS`, `LSP01_PLATFORM_AUTHENTIC`, and `LSP01_PUBLISHABLE`; publishable candidate emission is suppressed on platform mismatch; CI/native Linux owns Linux evidence.
</threat_model>

<verification_markers>
Base markers:
- `LSP01_PERF_MODE=real-lsp`
- `LSP01_PERF_GATE_MODE=advisory`
- `LSP01_PLATFORM=linux`
- `LSP01_PLATFORM=macos`
- `LSP01_ACTUAL_OS=darwin|linux|other`
- `LSP01_PLATFORM_AUTHENTIC=true|false`
- `LSP01_PUBLISHABLE=true|false`
- `LSP01_NVIM_VERSION=0.12`
- `LSP01_THRESHOLD_FILE=ci/headless/lsp_perf_thresholds.lua`
- `LSP01_SUMMARY_ARTIFACT=`
- `LSP01_FLAME_TRACE_ARTIFACT=`
- `LSP01_WARMUP_COUNT=5`
- `LSP01_MEASURED_COUNT=10`
- `LSP01_STDPATH_STATE=`
- `LSP01_CORPUS=`
- `LSP01_SCENARIOS_COUNT=29`

For every required scenario slug in `<interfaces>`, emit:
- `LSP01_<SCENARIO>_MEDIAN_MS=`
- `LSP01_<SCENARIO>_P95_MS=`
- `LSP01_<SCENARIO>_SENTINEL_OK=true|false`
- `LSP01_CORPUS_<SCENARIO>=`
- `LSP01_LINUX_PERF_THRESHOLD_<SCENARIO>_MEDIAN_MS=`
- `LSP01_LINUX_PERF_THRESHOLD_<SCENARIO>_P95_MS=`
- `LSP01_LINUX_PERF_THRESHOLD_<SCENARIO>_MEDIAN_CANDIDATE_MS=`
- `LSP01_LINUX_PERF_THRESHOLD_<SCENARIO>_P95_CANDIDATE_MS=`
- `LSP01_LINUX_PERF_THRESHOLD_<SCENARIO>_STATUS=frozen|candidate|missing`
- `LSP01_LINUX_PERF_THRESHOLD_<SCENARIO>_PASS=true|false|unfrozen`
- `LSP01_MACOS_PERF_THRESHOLD_<SCENARIO>_MEDIAN_MS=`
- `LSP01_MACOS_PERF_THRESHOLD_<SCENARIO>_P95_MS=`
- `LSP01_MACOS_PERF_THRESHOLD_<SCENARIO>_MEDIAN_CANDIDATE_MS=`
- `LSP01_MACOS_PERF_THRESHOLD_<SCENARIO>_P95_CANDIDATE_MS=`
- `LSP01_MACOS_PERF_THRESHOLD_<SCENARIO>_STATUS=frozen|candidate|missing`
- `LSP01_MACOS_PERF_THRESHOLD_<SCENARIO>_PASS=true|false|unfrozen`

Rollup markers:
- `LSP01_LINUX_PERF_THRESHOLD_PASS=true|false|unfrozen`
- `LSP01_MACOS_PERF_THRESHOLD_PASS=true|false|unfrozen`
- `LSP01_REAL_LSP_PERF_ALL_PASS=true|false|unfrozen`

Special sentinel markers:
- `LSP01_COLUMN_MISS_FETCH_DELTAS=1,0,0,0,0,0,0,0,0,0`
- `LSP01_COLUMN_MISS_FETCH_DELTAS_OK=true|false`
- `LSP01_FAKE_STATE_USED=true|false`
- `LSP01_FAKE_HANDLER_LIFECYCLE_COMPLETE=true|false`
- `LSP01_METADATA_FALLBACK_FAKE_CALL_COUNT=1`
- `LSP01_COLD_DISK_DEFERRED_CALLBACK_COUNT=0`
- `LSP01_WARM_DISK_DEFERRED_CALLBACK_COUNT=0`
- `LSP01_METADATA_FALLBACK_DEFERRED_CALLBACK_COUNT=1`
- `LSP01_<SCENARIO>_NO_STALE_CLIENTS=true|false` for the 17 direct `dbee-lsp-perf` scenarios listed in `<semantic_sentinels>`
- `LSP01_STARTUP_WARM_DISK_LOADED=true|false` for `STARTUP_WARM` only; normal 5-warmup/10-measured output emits 15 `true` values and zero `false` values
- `LSP01_TRACE_WORKLOAD=startup_cold+completion+diagnostics_didchange`
- `LSP01_TRACE_WORKLOAD_ITERATIONS=<n>`
- `LSP01_TRACE_WORKLOAD_DURATION_MS=<ms>`

Sentinel failures are not advisory-only. A scenario with `LSP01_<SCENARIO>_SENTINEL_OK=false` forces that scenario pass marker to `false`, exits nonzero, and bubbles to the platform and overall rollups even when timing thresholds are unfrozen. Publishable final output requires exactly 29 scenario sentinels with `_SENTINEL_OK=true`, zero `_SENTINEL_OK=false`, exactly 17 `NO_STALE_CLIENTS=true` markers with zero `false`, exactly 15 `LSP01_STARTUP_WARM_DISK_LOADED=true` markers with zero `false`, `LSP01_PLATFORM_AUTHENTIC=true`, `LSP01_PUBLISHABLE=true`, and `LSP01_REAL_LSP_PERF_ALL_PASS=true|unfrozen`. Trace workload markers are emitted by the trace-only subprocess and prove the trace artifact's workload, but they are outside the main threshold and scenario-sentinel count.

Forbidden marker:
- `LSP01_PHASE7_BUDGETS_PASS`

CI artifact marker names:
- `linux-lsp-perf-threshold-summary`
- `linux-lsp-perf-threshold-trace`
- `macos-lsp-perf-threshold-summary`
- `macos-lsp-perf-threshold-trace`
</verification_markers>

<verification>
1. Bootstrap and dependency-scope verification:
   `grep -n "BENCHMARK_NVIM_COMMIT\|PROFILE_NVIM_COMMIT\|PERF_RUNTIMEPATH_CMD\|PERF_NVIM_HEADLESS" ci/headless/perf_bootstrap.mk && ! grep -n "nvim-nio\|plenary.nvim\|mini.test" ci/headless/perf_bootstrap.mk`

2. Threshold source verification:
   `grep -n "startup_cold\|completion_table_10000\|completion_column_miss_sync\|diagnostics_didchange_10000\|diagnostics_didsave_10000\|cache_build_1000\|cache_load_10000\|cache_save_10000\|LSP01_PERF_GATE_MODE=blocking" ci/headless/lsp_perf_thresholds.lua`

3. Local target verification:
   `grep -n "^perf-lsp:\|^perf-all:\|LSP01_PERF_GATE_MODE\|LSP01_PERF_THRESHOLD_FILE\|LSP_PERF_SCRIPT\|LSP01_PERF_TRACE_PATH\|LSP01_PERF_STATE_HOME\|XDG_STATE_HOME\|LSP01_ALLOW_NONPUBLISHABLE_PLATFORM_OVERRIDE" Makefile`

4. Harness marker and scenario verification:
   `grep -n "LSP01_PERF_MODE\|LSP01_REAL_LSP_PERF_ALL_PASS\|LSP01_ACTUAL_OS\|LSP01_PLATFORM_AUTHENTIC\|LSP01_PUBLISHABLE\|LSP01_SCENARIOS_COUNT=29\|LSP01_STDPATH_STATE\|SENTINEL_OK\|NO_STALE_CLIENTS\|LSP01_STARTUP_WARM_DISK_LOADED\|LSP01_TRACE_WORKLOAD\|STARTUP_COLD\|with_fake_lsp_state\|capture_defer_fn\|drain_deferred\|queue_try_start\|wait_metadata_fallback\|_try_start\|LSP01_FAKE_STATE_USED\|LSP01_FAKE_HANDLER_LIFECYCLE_COMPLETE\|LSP01_METADATA_FALLBACK_FAKE_CALL_COUNT\|LSP01_METADATA_FALLBACK_DEFERRED_CALLBACK_COUNT\|LSP01_COLD_DISK_DEFERRED_CALLBACK_COUNT\|LSP01_WARM_DISK_DEFERRED_CALLBACK_COUNT\|COMPLETION_TABLE_10000\|COMPLETION_COLUMN_MISS_SYNC\|SELECT \\* FROM SCHEMA_001.TABLE_000001 t WHERE t\\.\|LSP01_COLUMN_MISS_FETCH_DELTAS_OK\|DIAGNOSTICS_DIDCHANGE_10000\|DIAGNOSTICS_DIDSAVE_10000\|ALIAS_MULTI_JOIN\|LSP01_CORPUS_ALIAS_MULTI_JOIN\|CACHE_SAVE_10000" ci/headless/check_lsp_perf.lua`

5. Scope guard verification:
   `! grep -n "connection_get_columns_async\|isIncomplete = true\|nvim-nio\|DuckDB\|sqlite\|SELECT t\\. FROM\|LSP01_PHASE7_BUDGETS_PASS" ci/headless/check_lsp_perf.lua`

6. Bench hygiene verification:
   `grep -n "local uv = vim.uv or vim.loop\|uv.hrtime" lua/dbee/lsp/bench.lua && ! grep -n "vim.loop.hrtime" lua/dbee/lsp/bench.lua`

7. CI wiring verification:
   `grep -n "lua-lsp-perf-advisory\|LSP01_PERF_GATE_MODE=advisory\|make perf-lsp\|if: always()\|upload-artifact\|marker validation\|lsp-perf-threshold\|ubuntu-22.04\|macos-14" .github/workflows/test.yml`

8. Final local macOS command:
   `ART_DIR=$(mktemp -d) && LOG="$ART_DIR/lsp01-stdout.log" && LSP01_PERF_GATE_MODE=advisory LSP01_PERF_ARTIFACT_DIR="$ART_DIR" LSP01_PERF_SUMMARY_PATH="$ART_DIR/lsp01-summary.txt" LSP01_PERF_TRACE_PATH="$ART_DIR/lsp01-trace.json" make perf-lsp PERF_PLATFORM=macos | tee "$LOG" && test -s "$ART_DIR/lsp01-summary.txt" && test -s "$ART_DIR/lsp01-trace.json" && grep -q "LSP01_SCENARIOS_COUNT=29" "$LOG" && grep -q "LSP01_ACTUAL_OS=darwin" "$LOG" && grep -q "LSP01_PLATFORM_AUTHENTIC=true" "$LOG" && grep -q "LSP01_PUBLISHABLE=true" "$LOG" && grep -q "LSP01_STDPATH_STATE=" "$LOG" && test "$(grep -c 'LSP01_.*_SENTINEL_OK=true' "$LOG")" -eq 29 && ! grep -q "LSP01_.*_SENTINEL_OK=false" "$LOG" && test "$(grep -c 'LSP01_.*_NO_STALE_CLIENTS=true' "$LOG")" -eq 17 && ! grep -q "LSP01_.*_NO_STALE_CLIENTS=false" "$LOG" && test "$(grep -c 'LSP01_STARTUP_WARM_DISK_LOADED=true' "$LOG")" -eq 15 && ! grep -q "LSP01_STARTUP_WARM_DISK_LOADED=false" "$LOG" && grep -q "LSP01_COLUMN_MISS_FETCH_DELTAS_OK=true" "$LOG" && grep -q "LSP01_FAKE_STATE_USED=true" "$LOG" && grep -q "LSP01_FAKE_HANDLER_LIFECYCLE_COMPLETE=true" "$LOG" && grep -q "LSP01_METADATA_FALLBACK_FAKE_CALL_COUNT=1" "$LOG" && grep -q "LSP01_COLD_DISK_DEFERRED_CALLBACK_COUNT=0" "$LOG" && grep -q "LSP01_WARM_DISK_DEFERRED_CALLBACK_COUNT=0" "$LOG" && grep -q "LSP01_METADATA_FALLBACK_DEFERRED_CALLBACK_COUNT=1" "$LOG" && grep -q "LSP01_MACOS_PERF_THRESHOLD_PASS=" "$LOG" && grep -q "LSP01_MACOS_PERF_THRESHOLD_COMPLETION_COLUMN_MISS_SYNC_MEDIAN_CANDIDATE_MS=" "$LOG" && python3 -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$ART_DIR/lsp01-trace.json" && grep -Eq "LSP01_REAL_LSP_PERF_ALL_PASS=(true|unfrozen)$" "$LOG" && ! grep -q "LSP01_PHASE7_BUDGETS_PASS" "$LOG"`

9. Final Linux command shape:
   Linux publishable verification must run on native Linux or in the GitHub Actions `lua-lsp-perf-advisory` job. Local macOS must not publish Linux threshold candidates. Native Linux command: `ART_DIR=$(mktemp -d) && LOG="$ART_DIR/lsp01-stdout.log" && LSP01_PERF_GATE_MODE=advisory LSP01_PERF_ARTIFACT_DIR="$ART_DIR" LSP01_PERF_SUMMARY_PATH="$ART_DIR/lsp01-summary.txt" LSP01_PERF_TRACE_PATH="$ART_DIR/lsp01-trace.json" make perf-lsp PERF_PLATFORM=linux | tee "$LOG" && test -s "$ART_DIR/lsp01-summary.txt" && test -s "$ART_DIR/lsp01-trace.json" && grep -q "LSP01_SCENARIOS_COUNT=29" "$LOG" && grep -q "LSP01_ACTUAL_OS=linux" "$LOG" && grep -q "LSP01_PLATFORM_AUTHENTIC=true" "$LOG" && grep -q "LSP01_PUBLISHABLE=true" "$LOG" && grep -q "LSP01_STDPATH_STATE=" "$LOG" && test "$(grep -c 'LSP01_.*_SENTINEL_OK=true' "$LOG")" -eq 29 && ! grep -q "LSP01_.*_SENTINEL_OK=false" "$LOG" && test "$(grep -c 'LSP01_.*_NO_STALE_CLIENTS=true' "$LOG")" -eq 17 && ! grep -q "LSP01_.*_NO_STALE_CLIENTS=false" "$LOG" && test "$(grep -c 'LSP01_STARTUP_WARM_DISK_LOADED=true' "$LOG")" -eq 15 && ! grep -q "LSP01_STARTUP_WARM_DISK_LOADED=false" "$LOG" && grep -q "LSP01_COLUMN_MISS_FETCH_DELTAS_OK=true" "$LOG" && grep -q "LSP01_FAKE_STATE_USED=true" "$LOG" && grep -q "LSP01_FAKE_HANDLER_LIFECYCLE_COMPLETE=true" "$LOG" && grep -q "LSP01_METADATA_FALLBACK_FAKE_CALL_COUNT=1" "$LOG" && grep -q "LSP01_COLD_DISK_DEFERRED_CALLBACK_COUNT=0" "$LOG" && grep -q "LSP01_WARM_DISK_DEFERRED_CALLBACK_COUNT=0" "$LOG" && grep -q "LSP01_METADATA_FALLBACK_DEFERRED_CALLBACK_COUNT=1" "$LOG" && grep -q "LSP01_LINUX_PERF_THRESHOLD_PASS=" "$LOG" && grep -q "LSP01_LINUX_PERF_THRESHOLD_COMPLETION_COLUMN_MISS_SYNC_MEDIAN_CANDIDATE_MS=" "$LOG" && python3 -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$ART_DIR/lsp01-trace.json" && grep -Eq "LSP01_REAL_LSP_PERF_ALL_PASS=(true|unfrozen)$" "$LOG" && ! grep -q "LSP01_PHASE7_BUDGETS_PASS" "$LOG"`

10. Platform spoof guard verification:
    On macOS, Linux override must fail as nonpublishable: `if [ "$(uname -s)" = Darwin ]; then ART_DIR=$(mktemp -d) && LOG="$ART_DIR/lsp01-spoof.log" && LSP01_PERF_GATE_MODE=advisory LSP01_PERF_ARTIFACT_DIR="$ART_DIR" LSP01_PERF_SUMMARY_PATH="$ART_DIR/lsp01-summary.txt" LSP01_PERF_TRACE_PATH="$ART_DIR/lsp01-trace.json" make perf-lsp PERF_PLATFORM=linux >"$LOG" 2>&1; test $? -ne 0 && grep -q "LSP01_PLATFORM_AUTHENTIC=false" "$LOG" && grep -q "LSP01_PUBLISHABLE=false" "$LOG" && ! grep -q "LSP01_LINUX_PERF_THRESHOLD_.*_MEDIAN_CANDIDATE_MS=[0-9]" "$LOG"; fi`

11. Preserved fast LSP semantic checks:
    - `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_lsp_alias_completion.lua"`
    - `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_lsp_schema_alias_completion.lua"`
    - `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_lsp_alias_rebinding.lua"`
</verification>

<goal_backward_audit>
To claim "v1.2 Phase 10 ships measurable LSP perf evidence on macOS and Linux", the repo must have:

1. Shared pinned perf substrate reused from Phase 9.
   Covered by: `10-01-01`

2. LSP-only threshold source with candidate/frozen state and manual promotion ceremony.
   Covered by: `10-01-02`

3. Local macOS-first reproduction via `make perf-lsp`, plus combined `make perf-all`.
   Covered by: `10-01-03`

4. Interactive `bench.lua` preserved and made Neovim 0.12-clean.
   Covered by: `10-01-04`

5. Real in-process LSP harness with production-lifecycle startup, isolated state, semantic sentinels, median/p95, summary, trace, threshold status, and rollups.
   Covered by: `10-01-05`, `10-01-06`

6. Required startup, completion, didChange diagnostics, didSave diagnostics, alias, schema-cache, and disk-cache scenarios.
   Covered by: `10-01-07`, `10-01-08`, `10-01-09`, `10-01-10`, `10-01-11`

7. Linux and macOS advisory CI lanes with artifacts and promotion seam.
   Covered by: `10-01-12`

8. No drift into Phase 11 optimization or Phase 12 features.
   Covered by: constraints, D traceability, and forbidden-grep verification.

If any one of these eight outputs is missing, Phase 10 does not satisfy `LSP-PERF-01`.
</goal_backward_audit>

<risk_register>
- **Real `vim.lsp.start()` attach flakes in headless Neovim**
  - Mitigation: one helper owns attach/wait/cleanup; startup scenarios validate initialization before timing completion/diagnostics scenarios.

- **Synthetic handler diverges from production enough to hide the P0 hazard**
  - Mitigation: the cold column miss scenario must go through current `SchemaCache:get_columns()` and synchronous `connection_get_columns()` call count, while avoiding live DB noise.

- **Warmups contaminate the cold column-miss measurement**
  - Mitigation: `COMPLETION_COLUMN_MISS_SYNC` uses disposable warmup state, resets measured cache/counters after warmup, emits fetch deltas, and requires `LSP01_COLUMN_MISS_FETCH_DELTAS_OK=true`.

- **Startup lifecycle fake state bypasses production module capture**
  - Mitigation: lifecycle scenarios use `with_fake_lsp_state()` to install fake state before requiring `dbee.lsp`, clear/restore module cache, call `dbee.lsp.stop()`, and require fake-state/lifecycle sentinels.

- **Metadata fallback timer leaks across lifecycle samples**
  - Mitigation: lifecycle scenarios capture `vim.defer_fn`, drain callbacks synchronously by cohort, verify deferred callback counts, and drain/verify again during cleanup so no orphan timer mutates later samples.

- **Cold startup deferred-count sentinel becomes unsatisfiable for metadata-capable connection types**
  - Mitigation: `STARTUP_COLD` is explicitly the structure-load cold-start cohort and uses fake connection type `dbee-perf-no-metadata`, which has no production metadata query entry. `STARTUP_METADATA_FALLBACK` separately covers the metadata-capable path with a synthetic connection record using production type `postgres`.

- **Large 10000-table cohorts make local runs too slow**
  - Mitigation: fixed 5 warmups/10 measured samples, deterministic ordering, 30s per-scenario timeout, and advisory mode first. Threshold freeze waits for platform evidence.

- **macOS/Linux variance causes false failures after promotion**
  - Mitigation: separate per-platform thresholds and four-week >=95% pass rate before blocking promotion.

- **Threshold candidates accidentally become passing gates**
  - Mitigation: `PASS=unfrozen` until active platform thresholds are frozen; blocking mode fails closed on missing thresholds.

- **Wrong-platform threshold candidates contaminate advisory freeze**
  - Mitigation: platform mismatch marks the run nonpublishable and suppresses numeric threshold candidates unless running a declared debug override.

- **Failed advisory runs lose diagnostic artifacts**
  - Mitigation: CI asserts and uploads summary/trace artifacts with `if: always()` before running marker validation, preserving failed-run evidence for debugging.

- **Trace generation contaminates measured samples**
  - Mitigation: flame profile runs in a separate trace-only pass outside the measured sample set.

- **Harness construction reveals an existing LSP crash**
  - Mitigation: fix only the smallest measurement blocker under D-148; record optimization/correctness issues for Phase 11 instead of broadening Phase 10.

- **Schema fixture realism is too weak to represent large-schema completion costs**
  - Mitigation: deterministic 100/1000/10000 table cohorts, fixed aliases/CTE/JOIN dimensions, and corpus markers make the baseline explicit and reviewable.
</risk_register>

<success_criteria>
- `ci/headless/lsp_perf_thresholds.lua` exists and is the only LSP threshold source of truth.
- `ci/headless/check_lsp_perf.lua` drives startup through the production `dbee.lsp` lifecycle, runs non-startup scenarios through real `vim.lsp.start()`, and emits all required `LSP01_*` base, scenario, sentinel, threshold, candidate, status, pass, and rollup markers.
- `ci/headless/check_lsp_perf.lua` proves lifecycle startup with `LSP01_FAKE_STATE_USED=true`, `LSP01_FAKE_HANDLER_LIFECYCLE_COMPLETE=true`, and fake metadata fallback call count `1`.
- Lifecycle startup proves deterministic metadata timer handling with `LSP01_COLD_DISK_DEFERRED_CALLBACK_COUNT=0`, `LSP01_WARM_DISK_DEFERRED_CALLBACK_COUNT=0`, and `LSP01_METADATA_FALLBACK_DEFERRED_CALLBACK_COUNT=1`; cold/warm use the `dbee-perf-no-metadata` fixture where appropriate, while metadata fallback uses a synthetic `postgres`-type fixture.
- `COMPLETION_COLUMN_MISS_SYNC` proves its cold/warm measured-sample lifecycle with `LSP01_COLUMN_MISS_FETCH_DELTAS_OK=true`.
- `make perf-lsp` runs locally with pinned `benchmark.nvim` and `profile.nvim` from the shared bootstrap.
- `make perf-all` runs both drawer and LSP perf lanes without changing the drawer `perf` contract.
- CI has `lua-lsp-perf-advisory` on Linux and macOS, advisory mode, artifact upload, and promotion instructions.
- Every perf run proves isolated cache state via `XDG_STATE_HOME` and `LSP01_STDPATH_STATE`, and never reads or writes the user's real Neovim state directory.
- Publishable threshold evidence proves platform authenticity via `LSP01_ACTUAL_OS`, `LSP01_PLATFORM_AUTHENTIC=true`, and `LSP01_PUBLISHABLE=true`; wrong-platform debug runs emit no numeric threshold candidates.
- `bench.lua` uses `vim.uv` fallback hygiene and keeps existing interactive steps.
- No Phase 11/12 work lands in Phase 10.
</success_criteria>

<output>
After execution, create `.planning/phases/10-lsp-optimization/10-SUMMARY.md` with the advisory baseline command outputs, emitted marker family summary, artifact paths, and any harness-blocking crash fixes performed under D-148.

The summary must include a publishability/validity block with:
- environment: actual OS, runner, Neovim version, `PERF_PLATFORM`, `LSP01_PLATFORM_AUTHENTIC`, `LSP01_PUBLISHABLE`, `LSP01_PERF_GATE_MODE`, warmup count, measured count, and trace path;
- corpus: scenario count, deterministic fixture dimensions, alias corpus dimensions, and didChange/didSave diagnostic corpus descriptions;
- threshold state: candidate/frozen/missing status per active platform, candidate median/p95 values, rollups, and explicit note that advisory candidates do not self-certify;
- semantic checks: sentinel pass/fail summary, exact 29 true scenario-sentinel count, direct-client no-stale-client sentinel count, warm disk-load sentinel count, any failed sentinel details, cold-miss fetch deltas, fake-state usage, lifecycle method coverage, deferred callback counts, metadata fake call count, and trace workload marker summary;
- isolation: emitted `LSP01_STDPATH_STATE` and confirmation that per-run `XDG_STATE_HOME` was used;
- caveats: synthetic handler instead of live DB/Go RPC, fake handler RPC required for metadata fallback fidelity, cold startup uses synthetic non-metadata connection type `dbee-perf-no-metadata`, metadata fallback uses a synthetic connection record with production metadata-capable type `postgres`, current synchronous cold-miss policy, startup lifecycle scope, non-startup attach scope, nonpublishable platform overrides, and deferred multi-client/connection-swap/live-RPC scenarios.
</output>
