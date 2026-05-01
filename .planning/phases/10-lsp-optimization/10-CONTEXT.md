# Phase 10: LSP Perf Harness - Context

**Gathered:** 2026-04-29  
**Status:** Locked — ready for planning  
**Codex thread:** `019dd836-27d3-7c51-ad48-d06a7851133b`

<domain>
## Phase Boundary

Phase 10 opens v1.2 by landing a deterministic, headless LSP performance harness before any LSP behavior changes. It extends the Phase 9 perf substrate to the built-in dbee LSP so Phase 11 can optimize against baseline evidence and regression gates.

In scope:
- Headless `nvim --headless` LSP perf harness using pinned Phase 9 benchmark infrastructure
- Real in-process dbee LSP startup and request/notification paths through `vim.lsp.start()`
- Deterministic synthetic schema/cache/handler fixtures for startup, completion, diagnostics, alias parsing, cache build, and disk-cache timing
- Linux and macOS advisory CI lanes with platform-qualified median/p95 markers and artifacts
- Local `make perf-lsp` command, plus a combined perf convenience target
- Preservation of the existing interactive `lua/dbee/lsp/bench.lua` probe

Out of scope:
- LSP optimization, async rewrite, debounced diagnostics, LRU eviction, cache index precomputation, or diagnostics correctness fixes
- New LSP user-facing features such as hover, resolve, code actions, symbols, semantic tokens, or inlay hints
- Pivoting to standalone `sqls`, an out-of-process server, or multi-client/per-buffer connection architecture
- Live adapter or live database benchmarking as blocking release evidence
- Adding `nvim-nio`; that peer dependency is locked for Phase 11, not Phase 10

</domain>

<decisions>
## Implementation Decisions

### Phase Boundary And Sequencing
- **D-119:** Phase 10 is measurement-only. It must not optimize LSP behavior, add LSP features, or fix the Phase 11 correctness bugs unless an existing crash makes the harness impossible to run; any such fix must be the smallest harness-enabling change and documented as such.
- **D-120:** Phase 10 ships before Phase 11 and must preserve the current synchronous completion cold-miss behavior so Phase 11 can prove the async rewrite improves it.
- **D-121:** Phase 10 honors the v1.2 roadmap order: Phase 10 harness, Phase 11 optimization/correctness, and conditional Phase 12 feature work. Phase 10 does not re-open v1.0/v1.1 decisions D-01..D-118 or v1.2 roadmap fork locks.

### Harness Substrate And LSP Path
- **D-122:** The harness reuses Phase 9's pinned perf substrate: `ci/headless/perf_bootstrap.mk`, `stevearc/benchmark.nvim`, `profile.nvim`, and the same fail-closed bootstrap style. Phase 10 does not introduce `plenary.nvim`, `mini.test`, or a lighter one-off timing runner for perf measurement.
- **D-123:** Automated perf runs use `nvim --headless` on Neovim `0.12.x` and record the exact Neovim version, platform, sample count, corpus label, median, and p95 in the emitted evidence.
- **D-124:** The harness starts the real in-process dbee LSP through `vim.lsp.start({ cmd = server.create(cache) })` and attaches a real buffer/client. Measurements must exercise production LSP request/notification handlers rather than helper-only microbenchmarks or a standalone `sqls` process.
- **D-125:** Completion timing uses asynchronous `client:request("textDocument/completion", ...)` callback elapsed time, because that matches production client behavior. `client:request_sync()` is deferred as a non-authoritative helper only; it must not define the Phase 10 perf contract.
- **D-126:** Real-LSP scope includes startup, attach, completion request timing, `didChange`/`didSave` diagnostics notifications, schema-cache build/load/save, and alias parsing through current modules. Multi-client setup, rapid connection swap mid-request, `nvim_ui_attach`, live DB/RPC adapters, and true UI redraw measurement are deferred.

### Fixtures And Isolation
- **D-127:** Blocking perf evidence uses deterministic synthetic fixtures, not live DuckDB, SQLite, Oracle, or external adapter state. The fixture supplies a realistic current connection and handler/cache surface while keeping data generation stable and local.
- **D-128:** The cold `column_of_table` completion scenario must include a synthetic stub of the current synchronous `handler.connection_get_columns()` path so the Phase 10 baseline captures the existing main-thread blocking hazard. The stub may return deterministic data instantly or with controlled latency, but it must not introduce Phase 11's async policy.
- **D-129:** Schema fixtures are generated as stable `N tables x M columns` corpora with deterministic names, schema distribution, aliases, and materialization labels. Corpus sizes must include 100, 1000, and 10000 table cohorts where specified.
- **D-130:** The harness may use existing LSP headless-test fake-handler patterns, but it must keep the benchmark fixture separate enough that semantic LSP tests remain fast and do not inherit perf-specific threshold logic.

### Scenario Corpus
- **D-131:** Startup scenarios include cold disk-cache startup with a fresh state directory, warm disk-cache startup with existing JSON, and metadata-fallback result processing through synthetic deterministic data. Live metadata SQL execution is not part of blocking Phase 10 evidence.
- **D-132:** Completion scenarios include table-context completion with 100, 1000, and 10000 cached tables; schema-context completion; keyword-context completion; `column_of_table` cache-hit completion; and cold `column_of_table` completion through the current synchronous miss path.
- **D-133:** Diagnostics scenarios include `didChange` timing for 100, 1000, and 10000 line buffers. The benchmark records current full-buffer diagnostic cost; debouncing and incremental validation are Phase 11 work.
- **D-134:** Alias/context scenarios include simple `SELECT`, nested CTE, multi-line query, and multi-JOIN-per-line corpora so Phase 11 can quantify both performance and known parser-correctness risk.
- **D-135:** Schema-cache scenarios include build-from-structure timing for 100, 1000, and 10000 table corpora and disk-cache load/save timing for 100, 1000, and 10000 table JSON payloads.

### Thresholds, Markers, And Promotion
- **D-136:** LSP thresholds live in a new `ci/headless/lsp_perf_thresholds.lua` source-of-truth file, separate from drawer thresholds, to avoid coupling DRAW-01 and LSP perf gates while preserving the Phase 9 threshold-table pattern.
- **D-137:** Each frozen scenario threshold is platform-specific and must bound both median and p95. Advisory seed budgets are: startup p95 `<500ms` cold and `<100ms` warm; cached completion p95 `<30ms`; cold column miss p95 `<200ms` as advisory-only baseline; diagnostics p95 `<50ms`; schema rebuild `<100ms` for 1000 tables. Final frozen values are derived empirically during advisory.
- **D-138:** Marker names use the `LSP01_` prefix. Per-scenario output includes `LSP01_<PLATFORM>_PERF_THRESHOLD_<SCENARIO>_MEDIAN_MS`, `_P95_MS`, `_MEDIAN_CANDIDATE_MS`, `_P95_CANDIDATE_MS`, `_STATUS=frozen|candidate|missing`, and `_PASS=true|false|unfrozen`.
- **D-139:** Rollup markers include `LSP01_<PLATFORM>_PERF_THRESHOLD_PASS=true|false|unfrozen` and `LSP01_REAL_LSP_PERF_ALL_PASS=true|false|unfrozen`. Phase 10 must not emit `LSP01_PHASE7_BUDGETS_PASS` because there is no inherited Phase 7 LSP perf budget.
- **D-140:** Advisory mode emits candidate medians/p95s when thresholds are missing and never silently reports success without threshold status. Blocking mode fails closed when pinned benchmark/profile dependencies or required threshold definitions are unavailable.
- **D-141:** CI promotion follows Phase 9 D-108: LSP perf lanes land advisory immediately, promote to blocking after four weeks at `>=95%` pass rate per platform, and then Linux and macOS become co-equal blocking gates.
- **D-142:** Perf evidence is emitted as grep-friendly stdout markers, stable summary text artifacts, and uploaded trace/profile artifacts where available. Per-run baseline JSON files are not committed.

### CI And Local Developer Flow
- **D-143:** The Makefile adds `make perf-lsp` for local macOS-first reproduction using the same bootstrap and Neovim `0.12.x` expectations as Phase 9's `make perf`.
- **D-144:** The Makefile adds `make perf-all` as a convenience target that runs drawer perf and LSP perf without duplicating bootstrap logic or changing either lane's marker contract.
- **D-145:** GitHub Actions adds a `lua-lsp-perf-advisory` job that mirrors the Phase 9 real-nui perf advisory shape, uses `NVIM_PERF_VERSION`, runs on Linux and macOS, uploads artifacts per platform, and remains `continue-on-error` until the promotion criteria are met.

### Bench.lua And Neovim 0.12 Hygiene
- **D-146:** `lua/dbee/lsp/bench.lua` remains a developer-friendly interactive probe via `:lua require("dbee.lsp.bench").stepN()`. Phase 10 may reuse or factor its scenario setup, but the new CI authority is the deterministic headless harness.
- **D-147:** `bench.lua` migrates `vim.loop` to `vim.uv` in Phase 10 as low-risk Neovim `0.12.x` harness hygiene. This is not treated as an LSP optimization and must not expand into broader API migration work.

### Scope Guards And Agent Discretion
- **D-148:** If the harness exposes existing LSP crashes or impossible setup states, Phase 10 records them and only fixes what blocks measurement. Performance improvements, debounce policy, async column fetch, LRU eviction, disk-write atomicity, diagnostics parser fixes, and feature work remain Phase 11/12 scope.
- **D-149:** The planner may choose exact warmup/sample counts, timeout ceilings, fixture column counts, scenario slug names, helper-module extraction, and whether the headless entry point is a single `ci/headless/check_lsp_perf.lua` script or a script plus support module, as long as all D-119..D-148 contracts hold.

</decisions>

<specifics>
## Specific Ideas

- Match Phase 9's release-evidence posture: deterministic synthetic data through production paths, platform-specific markers, artifacts, and advisory-to-blocking promotion rather than ad hoc local timing.
- Keep cold column-miss completion visibly bad in the Phase 10 baseline if that is what current code does; the harness is useful because it captures the P0 sync-blocking hazard before Phase 11 removes it.
- Prefer scenario names that make the source of latency obvious in CI logs, such as `STARTUP_COLD`, `STARTUP_WARM`, `COMPLETION_TABLE_1000`, `COMPLETION_COLUMN_MISS_SYNC`, `DIAGNOSTICS_DIDCHANGE_10000`, and `CACHE_SAVE_10000`.
- Keep marker output diff-friendly enough to paste into a phase summary without manual normalization.
- Preserve existing fast LSP semantic tests; the perf harness is a separate evidence lane, not a replacement for correctness tests.

</specifics>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### v1.2 Scope And Research
- `.planning/milestones/v1.2-roadmap.md` — locked v1.2 phase shape, fork locks, and Phase 10 success criteria
- `.planning/ROADMAP.md` — active roadmap entry for v1.2 and Phase 10
- `.planning/phases/10-lsp-optimization/10-RESEARCH.md` — Codex LSP architecture/performance research
- `.planning/research/v12-lsp-opus-research.md` — independent Opus research and corroborating perf/correctness findings

### Prior Perf Harness Precedent
- `.planning/phases/09-real-nui-perf-harness/09-CONTEXT.md` — D-107..D-118 perf threshold, marker, CI, and advisory-promotion precedent
- `.planning/phases/09-real-nui-perf-harness/09-PLAN.md` — Phase 9 implementation task shape and review history
- `ci/headless/perf_bootstrap.mk` — pinned perf dependency bootstrap
- `ci/headless/perf_thresholds.lua` — existing threshold-table pattern for drawer perf
- `ci/headless/check_drawer_perf.lua` — reference marker/artifact/scenario shape for the real-nui perf harness
- `Makefile` — local perf target pattern to extend with `perf-lsp` and `perf-all`
- `.github/workflows/test.yml` — perf advisory job pattern, `NVIM_PERF_VERSION`, platform matrix, and artifact upload wiring

### LSP Code And Existing Tests
- `lua/dbee/lsp/init.lua` — LSP lifecycle, `vim.lsp.start`, buffer queueing, structure refresh, and metadata fallback wiring
- `lua/dbee/lsp/server.lua` — completion request handlers and diagnostics notification paths to measure
- `lua/dbee/lsp/schema_cache.lua` — schema/table/column cache, sync column fetch, and disk-cache paths to benchmark
- `lua/dbee/lsp/context.lua` — alias/context parsing paths for scaling scenarios
- `lua/dbee/lsp/bench.lua` — existing interactive LSP benchmark probe to preserve and modernize
- `lua/dbee/handler/init.lua` — current connection metadata APIs, including existing async column surfaces that Phase 11 will use but Phase 10 must not adopt
- `ci/headless/check_lsp_alias_completion.lua` — existing LSP fake-handler and completion-test patterns
- `ci/headless/check_lsp_schema_alias_completion.lua` — schema-qualified alias completion test patterns
- `ci/headless/check_lsp_alias_rebinding.lua` — alias rebinding coverage and buffer setup patterns
- `ci/headless/check_connection_coordination.lua` — indirect LSP lifecycle and connection-coordination test patterns

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `ci/headless/perf_bootstrap.mk` already pins and installs `benchmark.nvim` and `profile.nvim`; Phase 10 should extend it rather than creating a second fetch path.
- `ci/headless/check_drawer_perf.lua` already demonstrates Phase 9's marker/status/artifact style and should be the closest shape reference for `check_lsp_perf.lua`.
- Existing LSP headless tests already stub handler/current-connection behavior and can inform deterministic fixture construction without importing perf thresholds into semantic tests.
- `lua/dbee/lsp/bench.lua` already contains interactive timing helpers; Phase 10 should preserve it as a fast local probe while moving CI authority to headless deterministic benchmarks.

### Established Patterns
- Phase 9 established Linux and macOS as co-equal perf evidence platforms, with advisory thresholds before blocking promotion.
- Perf bootstrap and threshold definitions are source-controlled, but per-run baseline measurements are artifacts rather than committed JSON.
- The project uses synthetic deterministic corpora for release perf evidence when live adapters would make timing noisy or environment-dependent.
- v1.2 keeps the built-in in-process dbee LSP as canonical and keeps the singleton current-connection model.

### Integration Points
- New `ci/headless/check_lsp_perf.lua` or equivalent entry point owns LSP perf scenario execution and marker emission.
- New `ci/headless/lsp_perf_thresholds.lua` owns LSP-specific platform thresholds and candidate/frozen status lookup.
- `Makefile` gains `perf-lsp` and `perf-all` without changing the existing drawer `perf` contract.
- `.github/workflows/test.yml` gains `lua-lsp-perf-advisory` by mirroring the Phase 9 perf job pattern.
- `lua/dbee/lsp/bench.lua` receives the scoped `vim.uv` hygiene update and remains interactive.

</code_context>

<deferred>
## Deferred Ideas

- Phase 11: `nvim-nio` peer dependency, async column fetch, in-flight dedupe, `isIncomplete` cache-miss policy, column-cache LRU, cache index precomputation, debounced diagnostics, diagnostics parser fixes, atomic disk writes, and disk-cache pruning.
- Phase 12: completion item `data` plus `completionItem/resolve`, hover, code actions, and document/workspace symbols.
- v1.3 or later: semantic tokens, inlay hints, `vim.lsp.config()` migration, multi-client/per-buffer connection model, live adapter performance lanes, rapid connection-swap stress benchmarks, and `nvim_ui_attach` redraw timing.

</deferred>

---

*Phase: 10-lsp-optimization*  
*Context gathered: 2026-04-29*
