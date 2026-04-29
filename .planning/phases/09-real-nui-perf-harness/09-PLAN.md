---
phase: 09-real-nui-perf-harness
plan: 01
revision: 5
type: execute
wave: 1
depends_on: []
files_modified:
  - ci/headless/perf_bootstrap.mk
  - Makefile
  - .github/workflows/test.yml
  - ci/headless/perf_thresholds.lua
  - ci/headless/check_drawer_perf.lua
autonomous: true
requirements: [PERF-01]
---

<objective>
Replace DRAW-01's current smoke-only perf evidence with a release-grade real-nui advisory perf harness that runs on both macOS and Linux, preserves the existing stubbed regression suite, and prepares the co-equal blocking gate that Phase 9 promotes only after the locked four-week, `>=95%` advisory window.

Purpose: answer the exact release question in `PERF-01` without changing drawer behavior. By the end of this plan, the repo has a companion real-nui perf harness, a shared bootstrap surface with pinned `benchmark.nvim` + pinned `nui.nvim`, a non-JSON threshold source of truth, Neovim `0.12.x` perf lanes on macOS and Linux, explicit Phase 4 inherited real-nui markers plus additive Phase 9 scenario evidence, per-platform median+p95 thresholds, flame trace artifacts, and a local `make perf` macOS repro path.
</objective>

<execution_context>
@/Users/naveenkanuri/Documents/nvim-dbee/.codex/skills/gsd-plan-phase/SKILL.md
@/Users/naveenkanuri/Documents/nvim-dbee/.codex/get-shit-done/workflows/plan-phase.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/REQUIREMENTS.md
@.planning/phases/04-drawer-navigation/04-CONTEXT.md
@.planning/phases/04-drawer-navigation/04-02-PLAN.md
@.planning/phases/04-drawer-navigation/04-VALIDATION.md
@.planning/phases/06-structure-laziness-notes-picker/06-CONTEXT.md
@.planning/phases/08-type-aware-connection-wizard/08-CONTEXT.md
@.planning/phases/09-real-nui-perf-harness/09-CONTEXT.md
@.planning/phases/09-real-nui-perf-harness/09-RESEARCH.md
</context>

<must_haves>
  <truths>
    - "Phase 9 measures the shipped DRAW-01 production path, not a substitute. The real perf path must exercise the real `DrawerUI`, `drawer/model.lua`, and `menu.filter()` flow through real `nui.nvim` primitives."
    - "The existing fake-nui smoke path remains in place as fast regression coverage. Phase 9 adds a companion real-nui perf path; it does not rewrite or broaden the whole headless suite."
    - "Pinned `stevearc/benchmark.nvim` is the only new perf helper dependency. Do not add `plenary.nvim` for perf infrastructure."
    - "The perf harness runs on `nvim --headless` with buffer-write measurement only. `nvim_ui_attach` is explicitly out of scope."
    - "The perf lane runs on Neovim `0.12.x` and records the exact Neovim version in the emitted evidence."
    - "macOS and Linux are co-equal perf platforms. Advisory jobs run on both immediately, thresholds and summary artifacts are emitted per platform, and the later promoted blocking gate fails if either platform fails."
    - "Phase 4's locked corpus and numeric budgets remain the blocking contract. The inherited Phase 4 metric family stays explicit and grep-able on the real-nui path, and `DRAW01_PHASE4_BUDGETS_PASS` is only a reduction over named outputs."
    - "Threshold persistence uses one authoritative non-JSON source at `ci/headless/perf_thresholds.lua`. Advisory runs may derive macOS candidate thresholds, but blocking mode reads frozen values from that file and fails closed if they are missing."
    - "Shared local/CI pinning and bootstrap live in `ci/headless/perf_bootstrap.mk`. `Makefile` and `.github/workflows/test.yml` both consume that one surface instead of inventing separate plugin bootstrap logic."
    - "Local reproduction on macOS is part of the contract. Naveen must be able to run the real-nui harness via `make perf` before pushing."
    - "Scope stays DRAW-01 perf only. Do not pull in wizard perf, full drawer benchmark programs, backend benchmarking, or visual-regression tooling."
  </truths>
  <artifacts>
    - path: "ci/headless/perf_bootstrap.mk"
      provides: "shared pinned plugin refs, bootstrap recipes, and canonical runtimepath command shape for local + CI perf runs"
      contains: "BENCHMARK_NVIM_COMMIT"
    - path: "ci/headless/perf_thresholds.lua"
      provides: "authoritative non-JSON threshold source of truth and the manual advisory-to-blocking freeze contract"
      contains: "linux = {"
    - path: "ci/headless/check_drawer_perf.lua"
      provides: "real-nui advisory perf harness, inherited Phase 4 real-nui metrics, additive Phase 9 scenarios, pass reduction, and artifact generation"
      contains: "DRAW01_PERF_MODE=real-nui"
    - path: ".github/workflows/test.yml"
      provides: "macOS+Linux perf jobs, Neovim 0.12.x setup, shared bootstrap usage, advisory gating, smoke reruns, and artifact upload"
      contains: "check_drawer_perf.lua"
    - path: "Makefile"
      provides: "local `make perf` entrypoint for macOS reproduction with the same bootstrap contract as CI"
      contains: "perf:"
  </artifacts>
  <key_links>
    - from: "ci/headless/perf_bootstrap.mk"
      to: "Makefile"
      via: "local macOS perf command consumes the exact pinned plugin refs and runtimepath contract used by CI"
      pattern: "include ci/headless/perf_bootstrap.mk"
    - from: "ci/headless/perf_bootstrap.mk"
      to: ".github/workflows/test.yml"
      via: "CI invokes the same bootstrap target rather than cloning pinned plugins through an unrelated shell path"
      pattern: "make perf-bootstrap"
    - from: "ci/headless/check_drawer_perf.lua"
      to: "lua/dbee/ui/drawer/init.lua"
      via: "real-nui perf harness must call the shipped filter/render/load-more/cached-expand path rather than helper-only shims"
      pattern: "DrawerUI"
    - from: "ci/headless/check_drawer_perf.lua"
      to: "ci/headless/perf_thresholds.lua"
      via: "advisory runs emit per-platform thresholds, and blocking mode reads frozen values from the threshold source of truth"
      pattern: "require(\"ci.headless.perf_thresholds\")"
    - from: "ci/headless/check_drawer_perf.lua"
      to: "ci/headless/check_structure_lazy.lua"
      via: "Phase 6 large-branch, cached-expand, and Load-more fixtures seed the structure-path perf scenarios"
      pattern: "Load more..."
  </key_links>
</must_haves>

<constraints>
- Honor Phase 4 D-31, Phase 5 D-29, Phase 6 D-30 through D-63, Phase 7 D-64 through D-88, Phase 8 D-89 through D-106, and Phase 9 D-107 through D-118 verbatim.
- Do not introduce Snacks, `mini.test`, `plenary.nvim`, or a raw `vim.api` rewrite as alternative perf substrates.
- Keep the existing `ci/headless/check_drawer_filter.lua` smoke semantics intact; the real-nui perf path must be additive.
- Perf threshold markers are platform-qualified. Do not pretend Linux and macOS can share one hard budget.
- Linux seed advisory thresholds use the locked research starting points. macOS advisory thresholds are derived from initial baseline runs during the advisory period; do not hardcode Linux numbers as macOS thresholds.
- `ci/headless/perf_thresholds.lua` is the only source of frozen additive thresholds once promotion happens. Do not invent a second config file, JSON baseline dump, or workflow-only copy of those values.
- Promotion remains manual. This phase prepares the freeze/read path and documents the ceremony, but it does not auto-promote CI after the soak window.
- Local macOS repro must not depend on CI-only environment variables. The target must be runnable by Naveen directly from the repo checkout.
- Artifact output is text summary + Chrome trace JSON only. Do not commit generated traces or baselines into the repo.
- Internal task execution remains a four-wave DAG even though the plan frontmatter correctly stays `wave: 1` for execute-phase tooling.
</constraints>

<interfaces>
Shared local/CI perf invocation contract:
```sh
make perf-bootstrap
make perf
make perf PERF_PLATFORM=macos
make perf PERF_PLATFORM=linux
```

Expected local/CI environment knobs:
```sh
NVIM_BIN=nvim
PERF_PLATFORM=macos|linux
DRAW01_PERF_GATE_MODE=advisory|blocking
DRAW01_PERF_ARTIFACT_DIR=/tmp/path
DRAW01_PERF_TRACE_PATH=/tmp/path/draw01-trace.json
DRAW01_PERF_THRESHOLD_FILE=ci/headless/perf_thresholds.lua
```

Required stdout marker contract:
```text
DRAW01_PERF_MODE=real-nui
DRAW01_PERF_GATE_MODE=advisory|blocking
DRAW01_PLATFORM=linux|macos
DRAW01_NVIM_VERSION=0.12.x
DRAW01_THRESHOLD_FILE=ci/headless/perf_thresholds.lua
DRAW01_SUMMARY_ARTIFACT=<path>
DRAW01_FLAME_TRACE_ARTIFACT=<path>

DRAW01_CORPUS=connections:2 schemas_per_conn:5 tables_per_schema:100 naming_distribution:"acct_ x400, ledger_ x599, table_003_042 x1" max_hit_query:"_" max_hit_expected_matches:1000 broad_query:"ledger_" broad_expected_matches:599 secondary_broad_query:"acct_" secondary_broad_expected_matches:400 narrow_query:"table_003_042" narrow_expected_matches:1 miss_query:"zzzzzz" miss_expected_matches:0 empty_restore_expected_nodes:1000
DRAW01_FILTER_START_MS=<median>
DRAW01_FILTER_START_MAX_MS=<max>
DRAW01_FILTER_START_KB_DELTA=<kb>
DRAW01_SNAPSHOT_MS=<median>
DRAW01_MODEL_BUILD_MS=<median>
DRAW01_PROMPT_MOUNT_MS=<median>
DRAW01_REFRESH_MS=<median>/<max>
DRAW01_FILTER_RESTART_MS=<median>
DRAW01_APPLY_MAX_HIT_MS=<median>/<max>
DRAW01_APPLY_BROAD_MS=<median>/<max>
DRAW01_APPLY_SECONDARY_BROAD_MS=<median>/<max>
DRAW01_APPLY_NARROW_MS=<median>/<max>
DRAW01_APPLY_MISS_MS=<median>/<max>
DRAW01_APPLY_EMPTY_MS=<median>/<max>
DRAW01_CANCEL_RESTORE_MS=<median>/<max>
DRAW01_SUBMIT_RESTORE_MS=<median>/<max>
DRAW01_LARGE_EXPANSION_RESTORE_OK=true|false
DRAW01_APPLY_P95_MS=<value>
DRAW01_APPLY_SOAK_MAX_MS=<value>
DRAW01_APPLY_SOAK_KB_HIGH_WATER=<kb>
DRAW01_APPLY_SOAK_RETAINED_KB=<kb>
DRAW01_PHASE4_BUDGETS_PASS=true|false

DRAW01_INITIAL_RENDER_MEDIAN_MS=<float>
DRAW01_INITIAL_RENDER_P95_MS=<float>
DRAW01_FILTER_FIRST_REDRAW_MEDIAN_MS=<float>
DRAW01_FILTER_FIRST_REDRAW_P95_MS=<float>
DRAW01_FILTER_STABLE_MEDIAN_MS=<float>
DRAW01_FILTER_STABLE_P95_MS=<float>
DRAW01_LAZY_EXPAND_MEDIAN_MS=<float>
DRAW01_LAZY_EXPAND_P95_MS=<float>
DRAW01_CACHED_EXPAND_MEDIAN_MS=<float>
DRAW01_CACHED_EXPAND_P95_MS=<float>
DRAW01_LOAD_MORE_MEDIAN_MS=<float>
DRAW01_LOAD_MORE_P95_MS=<float>

DRAW01_LINUX_PERF_THRESHOLD_INITIAL_RENDER_MEDIAN_MS=<float>|NA
DRAW01_LINUX_PERF_THRESHOLD_INITIAL_RENDER_P95_MS=<float>|NA
DRAW01_LINUX_PERF_THRESHOLD_INITIAL_RENDER_MEDIAN_CANDIDATE_MS=<float>|NA
DRAW01_LINUX_PERF_THRESHOLD_INITIAL_RENDER_P95_CANDIDATE_MS=<float>|NA
DRAW01_LINUX_PERF_THRESHOLD_INITIAL_RENDER_STATUS=frozen|candidate|missing
DRAW01_LINUX_PERF_THRESHOLD_INITIAL_RENDER_PASS=true|false|unfrozen
DRAW01_LINUX_PERF_THRESHOLD_FILTER_FIRST_REDRAW_MEDIAN_MS=<float>|NA
DRAW01_LINUX_PERF_THRESHOLD_FILTER_FIRST_REDRAW_P95_MS=<float>|NA
DRAW01_LINUX_PERF_THRESHOLD_FILTER_FIRST_REDRAW_MEDIAN_CANDIDATE_MS=<float>|NA
DRAW01_LINUX_PERF_THRESHOLD_FILTER_FIRST_REDRAW_P95_CANDIDATE_MS=<float>|NA
DRAW01_LINUX_PERF_THRESHOLD_FILTER_FIRST_REDRAW_STATUS=frozen|candidate|missing
DRAW01_LINUX_PERF_THRESHOLD_FILTER_FIRST_REDRAW_PASS=true|false|unfrozen
DRAW01_LINUX_PERF_THRESHOLD_FILTER_STABLE_MEDIAN_MS=<float>|NA
DRAW01_LINUX_PERF_THRESHOLD_FILTER_STABLE_P95_MS=<float>|NA
DRAW01_LINUX_PERF_THRESHOLD_FILTER_STABLE_MEDIAN_CANDIDATE_MS=<float>|NA
DRAW01_LINUX_PERF_THRESHOLD_FILTER_STABLE_P95_CANDIDATE_MS=<float>|NA
DRAW01_LINUX_PERF_THRESHOLD_FILTER_STABLE_STATUS=frozen|candidate|missing
DRAW01_LINUX_PERF_THRESHOLD_FILTER_STABLE_PASS=true|false|unfrozen
DRAW01_LINUX_PERF_THRESHOLD_LAZY_EXPAND_MEDIAN_MS=<float>|NA
DRAW01_LINUX_PERF_THRESHOLD_LAZY_EXPAND_P95_MS=<float>|NA
DRAW01_LINUX_PERF_THRESHOLD_LAZY_EXPAND_MEDIAN_CANDIDATE_MS=<float>|NA
DRAW01_LINUX_PERF_THRESHOLD_LAZY_EXPAND_P95_CANDIDATE_MS=<float>|NA
DRAW01_LINUX_PERF_THRESHOLD_LAZY_EXPAND_STATUS=frozen|candidate|missing
DRAW01_LINUX_PERF_THRESHOLD_LAZY_EXPAND_PASS=true|false|unfrozen
DRAW01_LINUX_PERF_THRESHOLD_CACHED_EXPAND_MEDIAN_MS=<float>|NA
DRAW01_LINUX_PERF_THRESHOLD_CACHED_EXPAND_P95_MS=<float>|NA
DRAW01_LINUX_PERF_THRESHOLD_CACHED_EXPAND_MEDIAN_CANDIDATE_MS=<float>|NA
DRAW01_LINUX_PERF_THRESHOLD_CACHED_EXPAND_P95_CANDIDATE_MS=<float>|NA
DRAW01_LINUX_PERF_THRESHOLD_CACHED_EXPAND_STATUS=frozen|candidate|missing
DRAW01_LINUX_PERF_THRESHOLD_CACHED_EXPAND_PASS=true|false|unfrozen
DRAW01_LINUX_PERF_THRESHOLD_LOAD_MORE_MEDIAN_MS=<float>|NA
DRAW01_LINUX_PERF_THRESHOLD_LOAD_MORE_P95_MS=<float>|NA
DRAW01_LINUX_PERF_THRESHOLD_LOAD_MORE_MEDIAN_CANDIDATE_MS=<float>|NA
DRAW01_LINUX_PERF_THRESHOLD_LOAD_MORE_P95_CANDIDATE_MS=<float>|NA
DRAW01_LINUX_PERF_THRESHOLD_LOAD_MORE_STATUS=frozen|candidate|missing
DRAW01_LINUX_PERF_THRESHOLD_LOAD_MORE_PASS=true|false|unfrozen
DRAW01_LINUX_PERF_THRESHOLD_PASS=true|false|unfrozen

DRAW01_MACOS_PERF_THRESHOLD_INITIAL_RENDER_MEDIAN_MS=<float>|NA
DRAW01_MACOS_PERF_THRESHOLD_INITIAL_RENDER_P95_MS=<float>|NA
DRAW01_MACOS_PERF_THRESHOLD_INITIAL_RENDER_MEDIAN_CANDIDATE_MS=<float>|NA
DRAW01_MACOS_PERF_THRESHOLD_INITIAL_RENDER_P95_CANDIDATE_MS=<float>|NA
DRAW01_MACOS_PERF_THRESHOLD_INITIAL_RENDER_STATUS=frozen|candidate|missing
DRAW01_MACOS_PERF_THRESHOLD_INITIAL_RENDER_PASS=true|false|unfrozen
DRAW01_MACOS_PERF_THRESHOLD_FILTER_FIRST_REDRAW_MEDIAN_MS=<float>|NA
DRAW01_MACOS_PERF_THRESHOLD_FILTER_FIRST_REDRAW_P95_MS=<float>|NA
DRAW01_MACOS_PERF_THRESHOLD_FILTER_FIRST_REDRAW_MEDIAN_CANDIDATE_MS=<float>|NA
DRAW01_MACOS_PERF_THRESHOLD_FILTER_FIRST_REDRAW_P95_CANDIDATE_MS=<float>|NA
DRAW01_MACOS_PERF_THRESHOLD_FILTER_FIRST_REDRAW_STATUS=frozen|candidate|missing
DRAW01_MACOS_PERF_THRESHOLD_FILTER_FIRST_REDRAW_PASS=true|false|unfrozen
DRAW01_MACOS_PERF_THRESHOLD_FILTER_STABLE_MEDIAN_MS=<float>|NA
DRAW01_MACOS_PERF_THRESHOLD_FILTER_STABLE_P95_MS=<float>|NA
DRAW01_MACOS_PERF_THRESHOLD_FILTER_STABLE_MEDIAN_CANDIDATE_MS=<float>|NA
DRAW01_MACOS_PERF_THRESHOLD_FILTER_STABLE_P95_CANDIDATE_MS=<float>|NA
DRAW01_MACOS_PERF_THRESHOLD_FILTER_STABLE_STATUS=frozen|candidate|missing
DRAW01_MACOS_PERF_THRESHOLD_FILTER_STABLE_PASS=true|false|unfrozen
DRAW01_MACOS_PERF_THRESHOLD_LAZY_EXPAND_MEDIAN_MS=<float>|NA
DRAW01_MACOS_PERF_THRESHOLD_LAZY_EXPAND_P95_MS=<float>|NA
DRAW01_MACOS_PERF_THRESHOLD_LAZY_EXPAND_MEDIAN_CANDIDATE_MS=<float>|NA
DRAW01_MACOS_PERF_THRESHOLD_LAZY_EXPAND_P95_CANDIDATE_MS=<float>|NA
DRAW01_MACOS_PERF_THRESHOLD_LAZY_EXPAND_STATUS=frozen|candidate|missing
DRAW01_MACOS_PERF_THRESHOLD_LAZY_EXPAND_PASS=true|false|unfrozen
DRAW01_MACOS_PERF_THRESHOLD_CACHED_EXPAND_MEDIAN_MS=<float>|NA
DRAW01_MACOS_PERF_THRESHOLD_CACHED_EXPAND_P95_MS=<float>|NA
DRAW01_MACOS_PERF_THRESHOLD_CACHED_EXPAND_MEDIAN_CANDIDATE_MS=<float>|NA
DRAW01_MACOS_PERF_THRESHOLD_CACHED_EXPAND_P95_CANDIDATE_MS=<float>|NA
DRAW01_MACOS_PERF_THRESHOLD_CACHED_EXPAND_STATUS=frozen|candidate|missing
DRAW01_MACOS_PERF_THRESHOLD_CACHED_EXPAND_PASS=true|false|unfrozen
DRAW01_MACOS_PERF_THRESHOLD_LOAD_MORE_MEDIAN_MS=<float>|NA
DRAW01_MACOS_PERF_THRESHOLD_LOAD_MORE_P95_MS=<float>|NA
DRAW01_MACOS_PERF_THRESHOLD_LOAD_MORE_MEDIAN_CANDIDATE_MS=<float>|NA
DRAW01_MACOS_PERF_THRESHOLD_LOAD_MORE_P95_CANDIDATE_MS=<float>|NA
DRAW01_MACOS_PERF_THRESHOLD_LOAD_MORE_STATUS=frozen|candidate|missing
DRAW01_MACOS_PERF_THRESHOLD_LOAD_MORE_PASS=true|false|unfrozen
DRAW01_MACOS_PERF_THRESHOLD_PASS=true|false|unfrozen

DRAW01_REAL_NUI_PERF_ALL_PASS=true|false|unfrozen
```

Phase 4 inherited pass reduction:
```text
DRAW01_PHASE4_BUDGETS_PASS := true iff the real-nui harness reports the locked corpus,
`DRAW01_FILTER_START_MS < 150ms`, `DRAW01_FILTER_START_MAX_MS < 250ms`,
`DRAW01_FILTER_START_KB_DELTA < 4096`, `DRAW01_SNAPSHOT_MS < 50ms`,
`DRAW01_FILTER_RESTART_MS < 150ms`, every required `DRAW01_APPLY_*` cohort median < 100ms,
`DRAW01_CANCEL_RESTORE_MS` and `DRAW01_SUBMIT_RESTORE_MS` both satisfy median < 150ms and max < 250ms,
`DRAW01_LARGE_EXPANSION_RESTORE_OK=true`,
`DRAW01_APPLY_P95_MS < 150ms`, `DRAW01_APPLY_SOAK_MAX_MS < 250ms`,
`DRAW01_APPLY_SOAK_KB_HIGH_WATER < 8192`, and `DRAW01_APPLY_SOAK_RETAINED_KB < 2048`.
`DRAW01_REFRESH_MS` remains warning-only exactly as in Phase 4 and is excluded from this reduction.
```

Additive Phase 9 pass formula:
```text
Per-scenario active-platform verdicts:
- `DRAW01_{LINUX|MACOS}_PERF_THRESHOLD_<SCENARIO>_PASS=true|false` is emitted only when that active-platform slot has `STATUS=frozen`.
- A frozen slot prints `true` iff `measurement.median_ms <= threshold.median_ms` AND `measurement.p95_ms <= threshold.p95_ms`; otherwise it prints `false`.
- If the active-platform slot is `STATUS=candidate` or `STATUS=missing`, the per-scenario `*_PASS` marker is `unfrozen`.
- Inactive-platform slots still emit `*_MEDIAN_CANDIDATE_MS`, `*_P95_CANDIDATE_MS`, and `*_STATUS`, but they do not participate in the active-platform pass calculation and their absence does not bubble `unfrozen`.

Per-platform rollups:
- `DRAW01_{LINUX|MACOS}_PERF_THRESHOLD_PASS=true` only when every active-platform additive slot (`initial_render`, `filter_first_redraw`, `filter_stable`, `lazy_expand`, `cached_expand`, `load_more`) is `STATUS=frozen` and every per-scenario `*_PASS=true`.
- `DRAW01_{LINUX|MACOS}_PERF_THRESHOLD_PASS=false` when the active platform has no `unfrozen` slots and at least one frozen per-scenario `*_PASS=false`.
- `DRAW01_{LINUX|MACOS}_PERF_THRESHOLD_PASS=unfrozen` when any active-platform additive slot is not frozen.

Overall rollup:
- `DRAW01_REAL_NUI_PERF_ALL_PASS=true` only when `DRAW01_PHASE4_BUDGETS_PASS=true` and the active-platform rollup is `true`.
- `DRAW01_REAL_NUI_PERF_ALL_PASS=unfrozen` when `DRAW01_PHASE4_BUDGETS_PASS=true` and the active-platform rollup is `unfrozen`.
- `DRAW01_REAL_NUI_PERF_ALL_PASS=false` otherwise.

Once the workflow flips to blocking after the locked four-week, >=95% soak,
both platform jobs must independently print `DRAW01_REAL_NUI_PERF_ALL_PASS=true`.
```

Threshold persistence and promotion contract:
```text
Authoritative non-JSON threshold source: ci/headless/perf_thresholds.lua

Advisory state in this phase:
- Linux additive thresholds are seeded in ci/headless/perf_thresholds.lua from the locked research values.
- macOS additive thresholds are emitted from empirical advisory runs and written into summary artifacts as freeze candidates.
- `make perf` and CI both load ci/headless/perf_thresholds.lua on every run.

Manual freeze ceremony after the advisory window:
1. Collect four weeks of advisory evidence with >=95% pass rate per platform.
2. Copy the adopted Linux + macOS additive threshold tables into ci/headless/perf_thresholds.lua.
3. Flip DRAW01_PERF_GATE_MODE=blocking in .github/workflows/test.yml in the same change.
4. Keep the marker names unchanged; only the threshold source changes from seed/candidate to frozen file values.

Blocking read rule:
- If DRAW01_PERF_GATE_MODE=blocking and the active platform lacks frozen threshold entries in ci/headless/perf_thresholds.lua, the harness fails closed before evaluating pass/fail.
```
</interfaces>

<measurement_protocol>
All gated measurements follow one explicit protocol so the reported medians and p95s are repeatable and comparable to Phase 4.

Protocol constants:
- Warmup count: `5`
- Measured count: `10`
- Benchmark runner: `benchmark.nvim.run({ warmup = 5, runs = 10 })`
- Deterministic scenario order: initial render -> Phase 4 startup/restart -> Phase 4 raw apply cohorts -> Phase 4 restore/large-expansion/soak -> filter first redraw -> filter stable -> lazy expand -> cached expand -> load more
- No randomized ordering

Fresh-baseline rules:
- Every inherited Phase 4 startup/raw apply/restore cohort starts from a fresh `DrawerUI` instance built from the locked corpus, or from the exact locked expanded baseline where the inherited contract already requires that fixture.
- Filter first-redraw and filter stable-state scenarios each start from a fresh locked corpus with no pending timer state.
- Lazy-expand starts from a fresh bounded 100-child branch baseline.
- Cached-expand starts from a fresh warmed-cache baseline seeded from Phase 6 cached fixture semantics.
- Load-more starts from a fresh sentinel baseline with unmaterialized continuation state.
- The soak cohort alone intentionally reuses one fixed baseline restored once before the 100 alternating applies, matching the inherited Phase 4 contract.

Stopwatch boundaries:
- Initial render: start immediately before the harness mounts the first real drawer render for the locked ready-cached corpus; stop on the final `vim.api.nvim_buf_set_lines()` call that completes that initial drawer-buffer population.
- Phase 4 raw apply cohorts: set `filter_debounce_ms=0`; start at `DrawerUI:apply_filter()` entry; stop at function return after the real tree/model update path completes.
- Filter first redraw: drive a real `NuiInput` `on_change`; start at accepted keystroke handler entry; stop at the first `vim.api.nvim_buf_set_lines()` call that redraws the drawer buffer for that keystroke.
- Filter stable state: start at the same accepted keystroke handler entry; stop at the last drawer-buffer `vim.api.nvim_buf_set_lines()` caused by that keystroke after the debounce window expires and after an additional `50ms` idle window confirms no pending filter timer remains.
- Restore metrics: start at cancel/submit action dispatch; stop at the final drawer-buffer `vim.api.nvim_buf_set_lines()` that restores the snapshot.
- Lazy-expand, cached-expand, and load-more: start at the corresponding user action callback entry; stop at the final drawer-buffer `vim.api.nvim_buf_set_lines()` for that action.

Trace capture:
- `benchmark.nvim.flame_profile()` runs outside the gated sample set in a separate single-run profile pass.
- The trace run writes to `DRAW01_FLAME_TRACE_ARTIFACT` and must not contaminate the warmup or measured samples used for threshold evaluation.

Heap rules:
- Heap measurements use `collectgarbage("count")` only.
- The harness performs `collectgarbage("collect")` before each inherited Phase 4 baseline capture and again after the soak sequence before retained-heap capture.
</measurement_protocol>

<dependency_dag>
Single plan, four internal waves.

Wave 1:
- `09-01-01` -> shared bootstrap surface in `ci/headless/perf_bootstrap.mk`
- `09-01-02` depends on `09-01-01`
- `09-01-03` depends on `09-01-02`
- `09-01-04` depends on `09-01-01`

Wave 2:
- `09-01-05` depends on `09-01-01` and `09-01-04`
- `09-01-06` depends on `09-01-05`
- `09-01-07` depends on `09-01-06`

Wave 3:
- `09-01-08` depends on `09-01-07`
- `09-01-09` depends on `09-01-04`, `09-01-06`, `09-01-07`, and `09-01-08`

Wave 4:
- `09-01-10` depends on `09-01-03` and `09-01-09`

Parallelizable lanes:
- After `09-01-01`, `09-01-02` and `09-01-04` can run in parallel because they touch different files and both consume the shared bootstrap surface.
- `09-01-03` is intentionally serial after `09-01-02` so CI cannot drift from the local bootstrap contract.
- All harness-authoring tasks remain serial in practice because they touch the same perf script and the threshold semantics build cumulatively.
</dependency_dag>

<tasks>
<task type="auto">
  <id>09-01-01</id>
  <title>Create the shared perf bootstrap surface</title>
  <commit>feat(09-01-01): add shared perf bootstrap include</commit>
  <wave>1</wave>
  <files>ci/headless/perf_bootstrap.mk</files>
  <read_first>
    - .planning/phases/09-real-nui-perf-harness/09-CONTEXT.md
    - .github/workflows/test.yml
  </read_first>
  <action>
    Create the one canonical bootstrap owner for local and CI perf runs.

    1. Add `ci/headless/perf_bootstrap.mk`.
       - define exact pinned repo URLs and commit hashes for `nui.nvim` and `stevearc/benchmark.nvim`
       - define the deterministic checkout root used by both local and CI runs
       - export the canonical runtimepath and `nvim --headless` command fragments for the perf harness

    2. Add bootstrap recipes.
       - fetch or refresh pinned plugin checkouts into the deterministic root
       - fail closed when the requested pin is missing or checkout refresh fails
       - keep the bootstrap surface compatible with both macOS and Linux shells
  </action>
  <verify>
    <automated>
      grep -n "NUI_NVIM_COMMIT\|BENCHMARK_NVIM_COMMIT\|perf-bootstrap\|PERF_PLUGIN_ROOT" ci/headless/perf_bootstrap.mk
    </automated>
  </verify>
  <acceptance_criteria>
    - One file owns pinned plugin refs and bootstrap behavior for both local and CI perf runs.
    - The bootstrap surface exposes deterministic plugin paths and command fragments rather than duplicating them in the workflow.
    - Missing or stale plugin pins fail closed.
  </acceptance_criteria>
</task>

<task type="auto">
  <id>09-01-02</id>
  <title>Add the local macOS perf entrypoint on top of the shared bootstrap</title>
  <commit>test(09-01-02): add local make perf entrypoint</commit>
  <wave>1</wave>
  <files>Makefile</files>
  <read_first>
    - ci/headless/perf_bootstrap.mk
    - .planning/phases/09-real-nui-perf-harness/09-CONTEXT.md
  </read_first>
  <action>
    Add a root `Makefile` that consumes the shared bootstrap contract.

    1. Create `make perf-bootstrap` and `make perf`.
       - include `ci/headless/perf_bootstrap.mk`
       - `perf-bootstrap` fetches pinned `nui.nvim` and `benchmark.nvim`
       - `perf` runs `ci/headless/check_drawer_perf.lua` via the canonical runtimepath shape

    2. Make the local target self-checking.
       - verify Neovim `0.12.x`
       - accept `PERF_PLATFORM`, `NVIM_BIN`, `DRAW01_PERF_GATE_MODE`, and artifact-dir overrides
       - pass `DRAW01_PERF_THRESHOLD_FILE=ci/headless/perf_thresholds.lua`
       - print the exact command and artifact paths on failure
  </action>
  <verify>
    <automated>
      grep -n "^include ci/headless/perf_bootstrap.mk$\|^perf-bootstrap:\|^perf:\|DRAW01_PERF_THRESHOLD_FILE\|PERF_PLATFORM\|NVIM_BIN" Makefile
    </automated>
  </verify>
  <acceptance_criteria>
    - `make perf` and `make perf-bootstrap` exist and consume the shared pinned bootstrap surface.
    - Local macOS reproduction does not depend on CI-only environment variables.
    - The Makefile passes the threshold source-of-truth path into the perf harness explicitly.
  </acceptance_criteria>
</task>

<task type="auto">
  <id>09-01-03</id>
  <title>Wire dual-platform advisory CI through the shared bootstrap path</title>
  <commit>test(09-01-03): add macos and linux advisory perf jobs</commit>
  <wave>1</wave>
  <files>.github/workflows/test.yml</files>
  <read_first>
    - ci/headless/perf_bootstrap.mk
    - Makefile
    - .planning/phases/09-real-nui-perf-harness/09-CONTEXT.md
  </read_first>
  <action>
    Extend CI with the Phase 9 advisory perf lane using the same bootstrap path as local repro.

    1. Add dedicated Linux and macOS perf jobs.
       - install Neovim `0.12.x`
       - invoke `make perf-bootstrap`
       - invoke `make perf PERF_PLATFORM=<linux|macos> DRAW01_PERF_GATE_MODE=advisory`

    2. Keep the rollout advisory now and promotion-ready later.
       - run immediately on both platforms
       - record pass/fail markers but do not yet block the release gate
       - leave the existing smoke/regression matrix intact

    3. Document the promotion seam in the workflow comments.
       - later blocking flip changes gate mode after the threshold file is frozen
       - CI never becomes the source of truth for frozen thresholds
  </action>
  <verify>
    <automated>
      grep -n "v0.12\|make perf-bootstrap\|make perf\|DRAW01_PERF_GATE_MODE=advisory\|macos\|ubuntu" .github/workflows/test.yml
    </automated>
  </verify>
  <acceptance_criteria>
    - CI has dedicated macOS and Linux advisory perf jobs on Neovim `0.12.x`.
    - CI consumes the shared bootstrap contract rather than duplicating plugin clone logic.
    - The workflow makes it explicit that blocking promotion later depends on a frozen threshold file plus a gate-mode flip.
  </acceptance_criteria>
</task>

<task type="auto">
  <id>09-01-04</id>
  <title>Create the non-JSON threshold source of truth</title>
  <commit>feat(09-01-04): add perf threshold source of truth</commit>
  <wave>1</wave>
  <files>ci/headless/perf_thresholds.lua</files>
  <read_first>
    - .planning/phases/09-real-nui-perf-harness/09-CONTEXT.md
    - .planning/phases/09-real-nui-perf-harness/09-RESEARCH.md
  </read_first>
  <action>
    Create the authoritative threshold file that later blocking mode will read.

    1. Add `ci/headless/perf_thresholds.lua`.
       - return a table keyed by `linux` and `macos`
       - define additive scenario threshold slots for `initial_render`, `filter_first_redraw`, `filter_stable`, `lazy_expand`, `cached_expand`, and `load_more`
       - each scenario stores `median_ms` and `p95_ms`

    2. Encode the advisory-to-blocking freeze contract.
       - seed Linux additive thresholds from the locked research values
       - leave macOS as explicitly unfrozen advisory slots until the empirical freeze ceremony is performed
       - document the manual freeze step: after four weeks at `>=95%` pass rate per platform, copy adopted Linux/macOS thresholds into this file and flip the workflow gate mode in the same change

    3. Define fail-closed blocking semantics.
       - if blocking mode is requested and the active platform lacks frozen threshold entries, the harness must abort rather than silently derive or default
  </action>
  <verify>
    <automated>
      grep -n "linux = {\|macos = {\|initial_render\|filter_first_redraw\|filter_stable\|lazy_expand\|cached_expand\|load_more\|median_ms\|p95_ms" ci/headless/perf_thresholds.lua
    </automated>
  </verify>
  <acceptance_criteria>
    - `ci/headless/perf_thresholds.lua` is the named non-JSON threshold source of truth.
    - The file already carries the advisory-to-blocking freeze ceremony in comments or structure, with no second config surface.
    - Blocking mode has a concrete fail-closed read rule.
  </acceptance_criteria>
</task>

<task type="auto">
  <id>09-01-05</id>
  <title>Create the real-nui perf harness scaffold, initial render scenario, and protocol hooks</title>
  <commit>test(09-01-05): scaffold real-nui drawer perf harness</commit>
  <wave>2</wave>
  <files>ci/headless/check_drawer_perf.lua</files>
  <read_first>
    - ci/headless/perf_bootstrap.mk
    - ci/headless/perf_thresholds.lua
    - ci/headless/check_drawer_filter.lua
    - ci/headless/check_structure_lazy.lua
  </read_first>
  <action>
    Create the companion perf harness with explicit measurement hooks.

    1. Add the harness scaffold.
       - require real `nui.nvim` and real `benchmark.nvim` from `runtimepath`
       - require `ci.headless.perf_thresholds`
       - fail closed when `DRAW01_PERF_MODE=real-nui` is requested and a dependency or threshold file is missing
       - emit invariant markers: perf mode, gate mode, platform, Neovim version, threshold file path, and artifact paths

    2. Encode the measurement protocol in code-level constants and helpers.
       - use `benchmark.nvim.run({ warmup = 5, runs = 10 })`
       - instrument the drawer buffer's `vim.api.nvim_buf_set_lines()` path for buffer-write timing boundaries
       - keep deterministic scenario ordering and separate profile-run output paths

    3. Add the additive initial-render scenario.
       - build the ready-cached 1000-node baseline
       - emit `DRAW01_INITIAL_RENDER_MEDIAN_MS` and `DRAW01_INITIAL_RENDER_P95_MS`
  </action>
  <verify>
    <automated>
      grep -n "benchmark.nvim\|require(\"ci.headless.perf_thresholds\")\|warmup = 5\|runs = 10\|nvim_buf_set_lines\|DRAW01_INITIAL_RENDER_MEDIAN_MS\|DRAW01_INITIAL_RENDER_P95_MS\|DRAW01_THRESHOLD_FILE" ci/headless/check_drawer_perf.lua
    </automated>
  </verify>
  <acceptance_criteria>
    - The repo has a dedicated real-nui perf entrypoint.
    - The harness loads the threshold source of truth and codifies the explicit measurement protocol.
    - Initial render emits additive median and p95 markers on the real-nui path.
  </acceptance_criteria>
</task>

<task type="auto">
  <id>09-01-06</id>
  <title>Port the inherited Phase 4 blocking metric family through the real-nui path</title>
  <commit>test(09-01-06): port inherited phase4 perf markers to real nui</commit>
  <wave>2</wave>
  <files>ci/headless/check_drawer_perf.lua</files>
  <read_first>
    - .planning/phases/04-drawer-navigation/04-02-PLAN.md
    - ci/headless/check_drawer_perf.lua
  </read_first>
  <action>
    Carry the full inherited Phase 4 blocking contract into the real-nui harness.

    1. Emit the locked corpus and startup family.
       - `DRAW01_CORPUS`
       - `DRAW01_FILTER_START_MS`, `DRAW01_FILTER_START_MAX_MS`, `DRAW01_FILTER_START_KB_DELTA`
       - `DRAW01_SNAPSHOT_MS`, `DRAW01_MODEL_BUILD_MS`, `DRAW01_PROMPT_MOUNT_MS`
       - `DRAW01_REFRESH_MS` as warning-only reporting
       - `DRAW01_FILTER_RESTART_MS`

    2. Emit the six raw apply cohorts with debounce disabled.
       - `DRAW01_APPLY_MAX_HIT_MS`
       - `DRAW01_APPLY_BROAD_MS`
       - `DRAW01_APPLY_SECONDARY_BROAD_MS`
       - `DRAW01_APPLY_NARROW_MS`
       - `DRAW01_APPLY_MISS_MS`
       - `DRAW01_APPLY_EMPTY_MS`

    3. Emit restore and soak evidence.
       - `DRAW01_CANCEL_RESTORE_MS`, `DRAW01_SUBMIT_RESTORE_MS`
       - `DRAW01_LARGE_EXPANSION_RESTORE_OK`
       - `DRAW01_APPLY_P95_MS`, `DRAW01_APPLY_SOAK_MAX_MS`, `DRAW01_APPLY_SOAK_KB_HIGH_WATER`, `DRAW01_APPLY_SOAK_RETAINED_KB`

    4. Define `DRAW01_PHASE4_BUDGETS_PASS` as a reduction over those named outputs only.
       - exclude `DRAW01_REFRESH_MS` from the reduction because Phase 4 made it warning-only
       - do not hand-set the reduction flag
  </action>
  <verify>
    <automated>
      grep -n "DRAW01_CORPUS\|DRAW01_FILTER_START_MS\|DRAW01_FILTER_START_MAX_MS\|DRAW01_FILTER_START_KB_DELTA\|DRAW01_SNAPSHOT_MS\|DRAW01_MODEL_BUILD_MS\|DRAW01_PROMPT_MOUNT_MS\|DRAW01_REFRESH_MS\|DRAW01_FILTER_RESTART_MS\|DRAW01_APPLY_MAX_HIT_MS\|DRAW01_APPLY_BROAD_MS\|DRAW01_APPLY_SECONDARY_BROAD_MS\|DRAW01_APPLY_NARROW_MS\|DRAW01_APPLY_MISS_MS\|DRAW01_APPLY_EMPTY_MS\|DRAW01_CANCEL_RESTORE_MS\|DRAW01_SUBMIT_RESTORE_MS\|DRAW01_LARGE_EXPANSION_RESTORE_OK\|DRAW01_APPLY_P95_MS\|DRAW01_APPLY_SOAK_MAX_MS\|DRAW01_APPLY_SOAK_KB_HIGH_WATER\|DRAW01_APPLY_SOAK_RETAINED_KB\|DRAW01_PHASE4_BUDGETS_PASS" ci/headless/check_drawer_perf.lua
    </automated>
  </verify>
  <acceptance_criteria>
    - All inherited Phase 4 markers are explicit on the real-nui path.
    - `DRAW01_PHASE4_BUDGETS_PASS` is a computed reduction over named outputs, not an opaque rollup.
    - The inherited Phase 4 contract remains comparable and grep-able in Phase 9.
  </acceptance_criteria>
</task>

<task type="auto">
  <id>09-01-07</id>
  <title>Measure filter first-redraw and stable-state latencies with explicit buffer-write boundaries</title>
  <commit>test(09-01-07): benchmark filter redraw and stable latencies</commit>
  <wave>2</wave>
  <files>ci/headless/check_drawer_perf.lua</files>
  <read_first>
    - lua/dbee/ui/drawer/menu.lua
    - lua/dbee/ui/drawer/init.lua
    - ci/headless/check_drawer_perf.lua
  </read_first>
  <action>
    Add the additive filter timing scenarios without weakening the inherited raw-apply contract.

    1. Implement first-redraw timing.
       - drive a real `NuiInput` `on_change`
       - start timing at accepted keystroke handler entry
       - stop on the first drawer-buffer `vim.api.nvim_buf_set_lines()` caused by that keystroke
       - emit `DRAW01_FILTER_FIRST_REDRAW_MEDIAN_MS` and `DRAW01_FILTER_FIRST_REDRAW_P95_MS`

    2. Implement stable-state timing.
       - start at the same accepted keystroke handler entry
       - stop on the last drawer-buffer `vim.api.nvim_buf_set_lines()` after the debounce window expires and after the extra `50ms` idle confirmation
       - emit `DRAW01_FILTER_STABLE_MEDIAN_MS` and `DRAW01_FILTER_STABLE_P95_MS`

    3. Keep the contracts separate.
       - inherited raw apply remains measured separately with `filter_debounce_ms=0`
       - additive first-redraw/stable scenarios never replace the inherited `DRAW01_APPLY_*` gates
  </action>
  <verify>
    <automated>
      grep -n "DRAW01_FILTER_FIRST_REDRAW_MEDIAN_MS\|DRAW01_FILTER_FIRST_REDRAW_P95_MS\|DRAW01_FILTER_STABLE_MEDIAN_MS\|DRAW01_FILTER_STABLE_P95_MS\|filter_debounce_ms = 0\|nvim_buf_set_lines" ci/headless/check_drawer_perf.lua
    </automated>
  </verify>
  <acceptance_criteria>
    - First-redraw and stable-state timing boundaries are explicit and buffer-write scoped.
    - The inherited raw-apply measurements remain separate and debounce-free.
    - Both additive filter scenarios emit median and p95 markers.
  </acceptance_criteria>
</task>

<task type="auto">
  <id>09-01-08</id>
  <title>Measure structure-path scenarios and define per-scenario threshold formulas</title>
  <commit>test(09-01-08): benchmark structure perf scenarios and threshold formulas</commit>
  <wave>3</wave>
  <files>ci/headless/check_drawer_perf.lua</files>
  <read_first>
    - ci/headless/check_structure_lazy.lua
    - ci/headless/check_drawer_perf.lua
    - ci/headless/perf_thresholds.lua
  </read_first>
  <action>
    Add the remaining blocking additive scenarios and make their pass semantics explicit.

    1. Measure structure scenarios.
       - emit `DRAW01_LAZY_EXPAND_MEDIAN_MS` and `DRAW01_LAZY_EXPAND_P95_MS`
       - emit `DRAW01_CACHED_EXPAND_MEDIAN_MS` and `DRAW01_CACHED_EXPAND_P95_MS`
       - emit `DRAW01_LOAD_MORE_MEDIAN_MS` and `DRAW01_LOAD_MORE_P95_MS`

    2. Emit per-platform threshold markers for every blocking additive scenario.
       - Linux + macOS threshold markers for `initial_render`, `filter_first_redraw`, `filter_stable`, `lazy_expand`, `cached_expand`, and `load_more`
       - each scenario emits both `median_ms` and `p95_ms` threshold markers

    3. Define the platform pass formula in code.
       - `scenario_pass := median <= threshold.median_ms AND p95 <= threshold.p95_ms`
       - `platform_threshold_pass := all six blocking additive scenarios pass`
       - emit `DRAW01_LINUX_PERF_THRESHOLD_PASS` and `DRAW01_MACOS_PERF_THRESHOLD_PASS`
  </action>
  <verify>
    <automated>
      grep -n "DRAW01_LAZY_EXPAND_MEDIAN_MS\|DRAW01_LAZY_EXPAND_P95_MS\|DRAW01_CACHED_EXPAND_MEDIAN_MS\|DRAW01_CACHED_EXPAND_P95_MS\|DRAW01_LOAD_MORE_MEDIAN_MS\|DRAW01_LOAD_MORE_P95_MS\|DRAW01_LINUX_PERF_THRESHOLD_INITIAL_RENDER_MEDIAN_MS\|DRAW01_LINUX_PERF_THRESHOLD_LOAD_MORE_P95_MS\|DRAW01_MACOS_PERF_THRESHOLD_INITIAL_RENDER_MEDIAN_MS\|DRAW01_MACOS_PERF_THRESHOLD_LOAD_MORE_P95_MS\|DRAW01_LINUX_PERF_THRESHOLD_PASS\|DRAW01_MACOS_PERF_THRESHOLD_PASS" ci/headless/check_drawer_perf.lua
    </automated>
  </verify>
  <acceptance_criteria>
    - Cached-expand and load-more participate in the same threshold contract as the other blocking additive scenarios.
    - Every blocking additive scenario has explicit per-platform median and p95 threshold markers.
    - The pass formula is explicit in code and matches the plan text.
  </acceptance_criteria>
</task>

<task type="auto">
  <id>09-01-09</id>
  <title>Emit advisory artifacts and enforce threshold-source-aware gate behavior</title>
  <commit>test(09-01-09): emit perf artifacts and threshold-source aware results</commit>
  <wave>3</wave>
  <files>ci/headless/check_drawer_perf.lua</files>
  <read_first>
    - ci/headless/perf_thresholds.lua
    - .planning/phases/09-real-nui-perf-harness/09-CONTEXT.md
    - ci/headless/check_drawer_perf.lua
  </read_first>
  <action>
    Turn the measured results into promotion-ready advisory evidence.

    1. Respect threshold source-of-truth rules.
       - advisory mode reads Linux seed thresholds from `ci/headless/perf_thresholds.lua`
       - advisory mode emits macOS threshold markers from empirical advisory values when frozen macOS entries are absent
       - blocking mode reads frozen thresholds for the active platform from `ci/headless/perf_thresholds.lua` and fails closed if they are missing

    2. Emit artifact files.
       - text summary artifact with inherited Phase 4 markers, additive scenario medians/p95s, threshold values, threshold source notes, platform, gate mode, exact Neovim version, and the four-week `>=95%` promotion reminder
       - `benchmark.nvim.flame_profile()` Chrome trace JSON via a separate profile-only run

    3. Emit overall result markers.
       - `DRAW01_SUMMARY_ARTIFACT`
       - `DRAW01_FLAME_TRACE_ARTIFACT`
       - `DRAW01_PHASE4_BUDGETS_PASS`
       - `DRAW01_LINUX_PERF_THRESHOLD_PASS`
       - `DRAW01_MACOS_PERF_THRESHOLD_PASS`
       - `DRAW01_REAL_NUI_PERF_ALL_PASS`
  </action>
  <verify>
    <automated>
      grep -n "DRAW01_SUMMARY_ARTIFACT\|DRAW01_FLAME_TRACE_ARTIFACT\|DRAW01_REAL_NUI_PERF_ALL_PASS\|flame_profile\|DRAW01_PERF_GATE_MODE\|DRAW01_THRESHOLD_FILE\|DRAW01_LINUX_PERF_THRESHOLD_PASS\|DRAW01_MACOS_PERF_THRESHOLD_PASS" ci/headless/check_drawer_perf.lua
    </automated>
  </verify>
  <acceptance_criteria>
    - Advisory runs already emit the same marker names that blocking mode will later reuse.
    - The harness names the threshold source file and enforces the fail-closed blocking read rule.
    - Summary text and Chrome trace artifacts are written to deterministic paths.
  </acceptance_criteria>
</task>

<task type="auto">
  <id>09-01-10</id>
  <title>Finalize CI reporting, artifact checks, smoke reruns, and promotion documentation</title>
  <commit>test(09-01-10): finalize advisory perf verification in CI</commit>
  <wave>4</wave>
  <files>.github/workflows/test.yml</files>
  <read_first>
    - .github/workflows/test.yml
    - Makefile
    - ci/headless/check_drawer_perf.lua
    - ci/headless/perf_thresholds.lua
  </read_first>
  <action>
    Finish the advisory CI integration with execution-based verification instead of source-only greps.

    1. Upload Linux and macOS artifacts.
       - upload summary text and flame trace JSON for both platforms
       - assert those files exist before upload

    2. Preserve the additive smoke contract.
       - rerun `ci/headless/check_drawer_filter.lua`
       - rerun `ci/headless/check_structure_lazy.lua`
       - keep those suites separate from the real-nui perf lane

    3. Add execution-based verification steps.
       - local macOS command: `DRAW01_PERF_GATE_MODE=advisory make perf PERF_PLATFORM=macos`
       - Linux command shape: `DRAW01_PERF_GATE_MODE=advisory make perf PERF_PLATFORM=linux` on a Linux dev box, or a documented `act` invocation for CI-shaped local replay
       - explicit artifact existence assertions for summary text and trace JSON after each run

    4. Document the later promotion ceremony in workflow comments.
       - after four weeks at `>=95%` pass rate per platform, freeze thresholds in `ci/headless/perf_thresholds.lua`
       - flip `DRAW01_PERF_GATE_MODE=blocking`
       - once blocking is enabled, either platform failure blocks the release
  </action>
  <verify>
    <automated>
      grep -n "upload-artifact\|check_drawer_perf.lua\|check_drawer_filter.lua\|check_structure_lazy.lua\|DRAW01_PERF_GATE_MODE\|make perf PERF_PLATFORM=macos\|make perf PERF_PLATFORM=linux\|act " .github/workflows/test.yml
    </automated>
  </verify>
  <acceptance_criteria>
    - CI uploads Linux and macOS perf summaries and flame traces only after confirming the files exist.
    - The preserved smoke suites are rerun explicitly so the additive contract is tested, not assumed.
    - The workflow documents the exact manual promotion ceremony and the co-equal blocking rule.
  </acceptance_criteria>
</task>
</tasks>

<verification_markers>
Required grep targets for plan-gate and execute-phase verification:

- `DRAW01_PERF_MODE=real-nui`
- `DRAW01_PERF_GATE_MODE=advisory`
- `DRAW01_PLATFORM=linux`
- `DRAW01_PLATFORM=macos`
- `DRAW01_NVIM_VERSION=0.12`
- `DRAW01_THRESHOLD_FILE=ci/headless/perf_thresholds.lua`
- `DRAW01_SUMMARY_ARTIFACT=`
- `DRAW01_FLAME_TRACE_ARTIFACT=`
- `DRAW01_CORPUS=`
- `DRAW01_FILTER_START_MS=`
- `DRAW01_FILTER_START_MAX_MS=`
- `DRAW01_FILTER_START_KB_DELTA=`
- `DRAW01_SNAPSHOT_MS=`
- `DRAW01_MODEL_BUILD_MS=`
- `DRAW01_PROMPT_MOUNT_MS=`
- `DRAW01_REFRESH_MS=`
- `DRAW01_FILTER_RESTART_MS=`
- `DRAW01_APPLY_MAX_HIT_MS=`
- `DRAW01_APPLY_BROAD_MS=`
- `DRAW01_APPLY_SECONDARY_BROAD_MS=`
- `DRAW01_APPLY_NARROW_MS=`
- `DRAW01_APPLY_MISS_MS=`
- `DRAW01_APPLY_EMPTY_MS=`
- `DRAW01_CANCEL_RESTORE_MS=`
- `DRAW01_SUBMIT_RESTORE_MS=`
- `DRAW01_LARGE_EXPANSION_RESTORE_OK=`
- `DRAW01_APPLY_P95_MS=`
- `DRAW01_APPLY_SOAK_MAX_MS=`
- `DRAW01_APPLY_SOAK_KB_HIGH_WATER=`
- `DRAW01_APPLY_SOAK_RETAINED_KB=`
- `DRAW01_PHASE4_BUDGETS_PASS=`
- `DRAW01_INITIAL_RENDER_MEDIAN_MS=`
- `DRAW01_INITIAL_RENDER_P95_MS=`
- `DRAW01_FILTER_FIRST_REDRAW_MEDIAN_MS=`
- `DRAW01_FILTER_FIRST_REDRAW_P95_MS=`
- `DRAW01_FILTER_STABLE_MEDIAN_MS=`
- `DRAW01_FILTER_STABLE_P95_MS=`
- `DRAW01_LAZY_EXPAND_MEDIAN_MS=`
- `DRAW01_LAZY_EXPAND_P95_MS=`
- `DRAW01_CACHED_EXPAND_MEDIAN_MS=`
- `DRAW01_CACHED_EXPAND_P95_MS=`
- `DRAW01_LOAD_MORE_MEDIAN_MS=`
- `DRAW01_LOAD_MORE_P95_MS=`
- `DRAW01_LINUX_PERF_THRESHOLD_INITIAL_RENDER_MEDIAN_MS=`
- `DRAW01_LINUX_PERF_THRESHOLD_INITIAL_RENDER_P95_MS=`
- `DRAW01_LINUX_PERF_THRESHOLD_INITIAL_RENDER_MEDIAN_CANDIDATE_MS=`
- `DRAW01_LINUX_PERF_THRESHOLD_INITIAL_RENDER_P95_CANDIDATE_MS=`
- `DRAW01_LINUX_PERF_THRESHOLD_INITIAL_RENDER_STATUS=`
- `DRAW01_LINUX_PERF_THRESHOLD_INITIAL_RENDER_PASS=`
- `DRAW01_LINUX_PERF_THRESHOLD_FILTER_FIRST_REDRAW_MEDIAN_MS=`
- `DRAW01_LINUX_PERF_THRESHOLD_FILTER_FIRST_REDRAW_P95_MS=`
- `DRAW01_LINUX_PERF_THRESHOLD_FILTER_FIRST_REDRAW_MEDIAN_CANDIDATE_MS=`
- `DRAW01_LINUX_PERF_THRESHOLD_FILTER_FIRST_REDRAW_P95_CANDIDATE_MS=`
- `DRAW01_LINUX_PERF_THRESHOLD_FILTER_FIRST_REDRAW_STATUS=`
- `DRAW01_LINUX_PERF_THRESHOLD_FILTER_FIRST_REDRAW_PASS=`
- `DRAW01_LINUX_PERF_THRESHOLD_FILTER_STABLE_MEDIAN_MS=`
- `DRAW01_LINUX_PERF_THRESHOLD_FILTER_STABLE_P95_MS=`
- `DRAW01_LINUX_PERF_THRESHOLD_FILTER_STABLE_MEDIAN_CANDIDATE_MS=`
- `DRAW01_LINUX_PERF_THRESHOLD_FILTER_STABLE_P95_CANDIDATE_MS=`
- `DRAW01_LINUX_PERF_THRESHOLD_FILTER_STABLE_STATUS=`
- `DRAW01_LINUX_PERF_THRESHOLD_FILTER_STABLE_PASS=`
- `DRAW01_LINUX_PERF_THRESHOLD_LAZY_EXPAND_MEDIAN_MS=`
- `DRAW01_LINUX_PERF_THRESHOLD_LAZY_EXPAND_P95_MS=`
- `DRAW01_LINUX_PERF_THRESHOLD_LAZY_EXPAND_MEDIAN_CANDIDATE_MS=`
- `DRAW01_LINUX_PERF_THRESHOLD_LAZY_EXPAND_P95_CANDIDATE_MS=`
- `DRAW01_LINUX_PERF_THRESHOLD_LAZY_EXPAND_STATUS=`
- `DRAW01_LINUX_PERF_THRESHOLD_LAZY_EXPAND_PASS=`
- `DRAW01_LINUX_PERF_THRESHOLD_CACHED_EXPAND_MEDIAN_MS=`
- `DRAW01_LINUX_PERF_THRESHOLD_CACHED_EXPAND_P95_MS=`
- `DRAW01_LINUX_PERF_THRESHOLD_CACHED_EXPAND_MEDIAN_CANDIDATE_MS=`
- `DRAW01_LINUX_PERF_THRESHOLD_CACHED_EXPAND_P95_CANDIDATE_MS=`
- `DRAW01_LINUX_PERF_THRESHOLD_CACHED_EXPAND_STATUS=`
- `DRAW01_LINUX_PERF_THRESHOLD_CACHED_EXPAND_PASS=`
- `DRAW01_LINUX_PERF_THRESHOLD_LOAD_MORE_MEDIAN_MS=`
- `DRAW01_LINUX_PERF_THRESHOLD_LOAD_MORE_P95_MS=`
- `DRAW01_LINUX_PERF_THRESHOLD_LOAD_MORE_MEDIAN_CANDIDATE_MS=`
- `DRAW01_LINUX_PERF_THRESHOLD_LOAD_MORE_P95_CANDIDATE_MS=`
- `DRAW01_LINUX_PERF_THRESHOLD_LOAD_MORE_STATUS=`
- `DRAW01_LINUX_PERF_THRESHOLD_LOAD_MORE_PASS=`
- `DRAW01_LINUX_PERF_THRESHOLD_PASS=`
- `DRAW01_LINUX_PERF_THRESHOLD_PASS=unfrozen`
- `DRAW01_MACOS_PERF_THRESHOLD_INITIAL_RENDER_MEDIAN_MS=`
- `DRAW01_MACOS_PERF_THRESHOLD_INITIAL_RENDER_P95_MS=`
- `DRAW01_MACOS_PERF_THRESHOLD_INITIAL_RENDER_MEDIAN_CANDIDATE_MS=`
- `DRAW01_MACOS_PERF_THRESHOLD_INITIAL_RENDER_P95_CANDIDATE_MS=`
- `DRAW01_MACOS_PERF_THRESHOLD_INITIAL_RENDER_STATUS=`
- `DRAW01_MACOS_PERF_THRESHOLD_INITIAL_RENDER_PASS=`
- `DRAW01_MACOS_PERF_THRESHOLD_FILTER_FIRST_REDRAW_MEDIAN_MS=`
- `DRAW01_MACOS_PERF_THRESHOLD_FILTER_FIRST_REDRAW_P95_MS=`
- `DRAW01_MACOS_PERF_THRESHOLD_FILTER_FIRST_REDRAW_MEDIAN_CANDIDATE_MS=`
- `DRAW01_MACOS_PERF_THRESHOLD_FILTER_FIRST_REDRAW_P95_CANDIDATE_MS=`
- `DRAW01_MACOS_PERF_THRESHOLD_FILTER_FIRST_REDRAW_STATUS=`
- `DRAW01_MACOS_PERF_THRESHOLD_FILTER_FIRST_REDRAW_PASS=`
- `DRAW01_MACOS_PERF_THRESHOLD_FILTER_STABLE_MEDIAN_MS=`
- `DRAW01_MACOS_PERF_THRESHOLD_FILTER_STABLE_P95_MS=`
- `DRAW01_MACOS_PERF_THRESHOLD_FILTER_STABLE_MEDIAN_CANDIDATE_MS=`
- `DRAW01_MACOS_PERF_THRESHOLD_FILTER_STABLE_P95_CANDIDATE_MS=`
- `DRAW01_MACOS_PERF_THRESHOLD_FILTER_STABLE_STATUS=`
- `DRAW01_MACOS_PERF_THRESHOLD_FILTER_STABLE_PASS=`
- `DRAW01_MACOS_PERF_THRESHOLD_LAZY_EXPAND_MEDIAN_MS=`
- `DRAW01_MACOS_PERF_THRESHOLD_LAZY_EXPAND_P95_MS=`
- `DRAW01_MACOS_PERF_THRESHOLD_LAZY_EXPAND_MEDIAN_CANDIDATE_MS=`
- `DRAW01_MACOS_PERF_THRESHOLD_LAZY_EXPAND_P95_CANDIDATE_MS=`
- `DRAW01_MACOS_PERF_THRESHOLD_LAZY_EXPAND_STATUS=`
- `DRAW01_MACOS_PERF_THRESHOLD_LAZY_EXPAND_PASS=`
- `DRAW01_MACOS_PERF_THRESHOLD_CACHED_EXPAND_MEDIAN_MS=`
- `DRAW01_MACOS_PERF_THRESHOLD_CACHED_EXPAND_P95_MS=`
- `DRAW01_MACOS_PERF_THRESHOLD_CACHED_EXPAND_MEDIAN_CANDIDATE_MS=`
- `DRAW01_MACOS_PERF_THRESHOLD_CACHED_EXPAND_P95_CANDIDATE_MS=`
- `DRAW01_MACOS_PERF_THRESHOLD_CACHED_EXPAND_STATUS=`
- `DRAW01_MACOS_PERF_THRESHOLD_CACHED_EXPAND_PASS=`
- `DRAW01_MACOS_PERF_THRESHOLD_LOAD_MORE_MEDIAN_MS=`
- `DRAW01_MACOS_PERF_THRESHOLD_LOAD_MORE_P95_MS=`
- `DRAW01_MACOS_PERF_THRESHOLD_LOAD_MORE_MEDIAN_CANDIDATE_MS=`
- `DRAW01_MACOS_PERF_THRESHOLD_LOAD_MORE_P95_CANDIDATE_MS=`
- `DRAW01_MACOS_PERF_THRESHOLD_LOAD_MORE_STATUS=`
- `DRAW01_MACOS_PERF_THRESHOLD_LOAD_MORE_PASS=`
- `DRAW01_MACOS_PERF_THRESHOLD_PASS=`
- `DRAW01_MACOS_PERF_THRESHOLD_PASS=unfrozen`
- `DRAW01_REAL_NUI_PERF_ALL_PASS=`
- `DRAW01_REAL_NUI_PERF_ALL_PASS=unfrozen`
</verification_markers>

<verification>
1. `grep -n "NUI_NVIM_COMMIT\|BENCHMARK_NVIM_COMMIT\|perf-bootstrap\|PERF_PLUGIN_ROOT" ci/headless/perf_bootstrap.mk` proves the shared bootstrap owner exists and carries the exact pinned refs.
2. `grep -n "^include ci/headless/perf_bootstrap.mk$\|^perf-bootstrap:\|^perf:\|DRAW01_PERF_THRESHOLD_FILE\|PERF_PLATFORM\|NVIM_BIN" Makefile` proves local macOS reproduction uses the same bootstrap and threshold source as CI.
3. `grep -n "v0.12\|make perf-bootstrap\|make perf\|DRAW01_PERF_GATE_MODE=advisory\|upload-artifact\|check_drawer_filter.lua\|check_structure_lazy.lua\|act " .github/workflows/test.yml` proves the dual-platform advisory jobs, artifact handling, smoke reruns, and promotion seam are wired.
4. `grep -n "DRAW01_CORPUS\|DRAW01_FILTER_START_MS\|DRAW01_APPLY_MAX_HIT_MS\|DRAW01_CANCEL_RESTORE_MS\|DRAW01_LARGE_EXPANSION_RESTORE_OK\|DRAW01_APPLY_SOAK_RETAINED_KB\|DRAW01_PHASE4_BUDGETS_PASS\|DRAW01_INITIAL_RENDER_MEDIAN_MS\|DRAW01_FILTER_FIRST_REDRAW_MEDIAN_MS\|DRAW01_FILTER_STABLE_MEDIAN_MS\|DRAW01_LAZY_EXPAND_MEDIAN_MS\|DRAW01_CACHED_EXPAND_MEDIAN_MS\|DRAW01_LOAD_MORE_MEDIAN_MS\|DRAW01_LINUX_PERF_THRESHOLD_INITIAL_RENDER_MEDIAN_MS\|DRAW01_LINUX_PERF_THRESHOLD_INITIAL_RENDER_MEDIAN_CANDIDATE_MS\|DRAW01_LINUX_PERF_THRESHOLD_INITIAL_RENDER_STATUS\|DRAW01_LINUX_PERF_THRESHOLD_INITIAL_RENDER_PASS\|DRAW01_MACOS_PERF_THRESHOLD_LOAD_MORE_P95_MS\|DRAW01_MACOS_PERF_THRESHOLD_LOAD_MORE_P95_CANDIDATE_MS\|DRAW01_MACOS_PERF_THRESHOLD_LOAD_MORE_STATUS\|DRAW01_MACOS_PERF_THRESHOLD_LOAD_MORE_PASS\|DRAW01_LINUX_PERF_THRESHOLD_PASS\|DRAW01_MACOS_PERF_THRESHOLD_PASS\|DRAW01_REAL_NUI_PERF_ALL_PASS" ci/headless/check_drawer_perf.lua` proves the inherited, additive, candidate, status, scenario-pass, and rollup marker families are explicit in the harness.
5. Final local macOS verification command:
   `ART_DIR=$(mktemp -d) && DRAW01_PERF_GATE_MODE=advisory DRAW01_PERF_ARTIFACT_DIR="$ART_DIR" make perf PERF_PLATFORM=macos && test -f "$ART_DIR"/draw01-summary.txt && test -f "$ART_DIR"/draw01-trace.json`
6. Final Linux verification command shape:
   - native Linux dev box: `ART_DIR=$(mktemp -d) && DRAW01_PERF_GATE_MODE=advisory DRAW01_PERF_ARTIFACT_DIR="$ART_DIR" make perf PERF_PLATFORM=linux && test -f "$ART_DIR"/draw01-summary.txt && test -f "$ART_DIR"/draw01-trace.json`
   - or CI-shaped replay: `act -W .github/workflows/test.yml -j lua-real-nui-perf-advisory`
7. Preserved smoke verification commands:
   - `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_drawer_filter.lua"`
   - `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_structure_lazy.lua"`
</verification>

<goal_backward_audit>
To claim "v1.1 ships with real-nui perf evidence on macOS and Linux", the repo must have:

1. A real production-path perf harness with explicit measurement protocol hooks.
   Covered by: `09-01-05`

2. The full inherited Phase 4 real-nui metric family, still explicit and reduction-backed.
   Covered by: `09-01-06`

3. Additive Phase 9 redraw and structure-path scenarios with explicit median+p95 pass formulas.
   Covered by: `09-01-07`, `09-01-08`

4. One frozen-threshold source of truth plus a concrete advisory-to-blocking ceremony.
   Covered by: `09-01-04`, `09-01-09`, `09-01-10`

5. Co-equal macOS and Linux CI execution on Neovim `0.12.x` plus a local macOS repro path.
   Covered by: `09-01-02`, `09-01-03`, `09-01-10`

6. Artifact evidence, execution-based verification, and preserved smoke reruns.
   Covered by: `09-01-09`, `09-01-10`

7. No drift into unrelated UI benchmarking or alternative substrates.
   Covered by: constraints + task scoping throughout

If any one of those seven outputs is missing, the phase does not satisfy `PERF-01`.
</goal_backward_audit>

<risk_register>
- **macOS runner variance or flake**
  Mitigation: separate Linux/macOS thresholds, explicit median+p95 bounds, advisory soak before blocking promotion, deterministic synthetic fixtures, and platform-specific frozen threshold tables.

- **Frozen thresholds drift from the advisory evidence**
  Mitigation: `ci/headless/perf_thresholds.lua` is the only source of truth; the manual freeze ceremony requires copying threshold values from advisory artifacts and flipping gate mode in the same change.

- **Shared bootstrap drifts between local and CI**
  Mitigation: `ci/headless/perf_bootstrap.mk` owns exact plugin pins and bootstrap behavior; CI and local both invoke it rather than cloning plugins separately.

- **`benchmark.nvim` upstream churn**
  Mitigation: pin to an exact commit hash in the bootstrap include; fail closed if the pinned runtimepath is missing or broken.

- **Neovim `0.12.x` compatibility gaps**
  Mitigation: isolate the new perf lane to `0.12.x`, record the exact version in artifacts, and keep older-version compatibility checks out of the blocking perf contract.

- **Real-nui perf path silently downgrades back to smoke**
  Mitigation: separate companion script, explicit `DRAW01_PERF_MODE=real-nui`, explicit threshold-file load, fail-closed dependency checks, and smoke reruns kept as a separate preserved lane.

- **Artifact upload obscures actual regressions**
  Mitigation: require execution-based file existence assertions and grep-friendly stdout markers in addition to uploaded summary and trace artifacts.
</risk_register>

<success_criteria>
- Dedicated real-nui perf harness exists and keeps the smoke suite intact.
- `benchmark.nvim` is pinned and used for median/p95/flame-profile evidence.
- `ci/headless/perf_bootstrap.mk` is the shared bootstrap owner for local and CI perf runs.
- `ci/headless/perf_thresholds.lua` is the named non-JSON threshold source of truth and documents the later freeze ceremony.
- All inherited Phase 4 real-nui markers are explicit, and `DRAW01_PHASE4_BUDGETS_PASS` is computed from them.
- Initial render, filter first redraw, filter stable state, lazy-expand, cached-expand, and load-more all emit real-nui perf markers plus per-platform median+p95 thresholds.
- macOS and Linux both run the advisory perf lane on Neovim `0.12.x`.
- Local macOS reproduction exists via `make perf`.
- CI uploads summary text and Chrome trace JSON artifacts and reruns the preserved smoke suites.
- Promotion to blocking after the locked advisory window is a threshold-file freeze plus workflow gate-mode flip, not a harness rewrite.
</success_criteria>

<output>
After completion, create `.planning/phases/09-real-nui-perf-harness/09-SUMMARY.md`
</output>
