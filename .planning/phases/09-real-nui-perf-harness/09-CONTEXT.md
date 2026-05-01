# Phase 9: Real-Nui Drawer Perf Harness - Context

**Gathered:** 2026-04-28
**Status:** Locked — ready for planning

<domain>
## Phase Boundary

Phase 9 closes the v1.1 milestone by turning DRAW-01 performance validation from stub-only smoke into release-grade evidence that runs against the real `nui.nvim` UI substrate. The phase is measurement-only: it validates the shipped Phase 4/6/7/8 drawer behavior and performance contracts under the real `nui.tree`, `nui.input`, and `nui.menu` implementation, promotes the real-nui path into CI, and leaves prior feature behavior unchanged.

In scope:
- Real-`nui.nvim` headless perf harness for the existing DRAW-01 drawer filter path
- Real render/filter/restore/load-more/cached-expand measurements against a deterministic corpus
- CI/runtimepath wiring that fails closed when release-mode real `nui.nvim` is unavailable
- Release-grade evidence that the locked DRAW-01/STRUCT-01 contracts hold under the real UI substrate

Out of scope:
- New drawer UX or new database-browser features
- Backend transport optimizations, query benchmarks, or live database performance testing
- Reopening Phase 4/6/7/8 behavior contracts
- Rewriting the entire headless suite to use real `nui.nvim`
- New perf work outside the DRAW-01 drawer/filter/materialization path

</domain>

<decisions>
## Implementation Decisions

### Perf Gate Strategy
- **D-107:** Phase 9 keeps the locked Phase 4 corpus and numeric budgets as the blocking contract and adds platform-specific advisory thresholds with separate Linux and macOS marker families. Linux starts with the research seed targets for reporting (`<50ms` initial drawer render with 1000 cached nodes, `<16ms` filter keystroke to first redraw, `<50ms` filter keystroke to stable state, and `<30ms` lazy-expand of a 100-child node), while macOS advisory thresholds are derived empirically from initial baseline runs during the advisory period rather than hardcoded from Linux measurements. Both platforms report median and p95 results per scenario.
- **D-108:** The real-nui perf lane follows the existing advisory-to-blocking promotion policy on both Linux and macOS: it lands advisory immediately, promotes to blocking after four weeks at `>=95%` pass rate per platform, and then both platforms are co-equal blocking gates. A failure on either platform fails the release gate, and `DRAW01_PERF_MODE=non-release-smoke` remains an explicit non-release fallback outside the release gate.
- **D-109:** Phase 9 uses a hybrid harness shape: the current stub-backed drawer tests remain as fast semantic regression coverage, and a separate real-nui perf path becomes the release-evidence lane.

### Harness Architecture
- **D-110:** Phase 9 reuses the locked Phase 4 1000-node filter corpus and the shipped Phase 6 `Load more...` and cached-expand fixtures as the blocking measurement scenarios; additional stress tiers stay advisory and local-only.
- **D-111:** The automated perf environment is `nvim --headless` on both Linux and macOS, measures the buffer-write path only, uses pinned `nui.nvim` on `runtimepath`, and uses pinned `stevearc/benchmark.nvim` for benchmark execution, median/statistical reporting, and sandbox helpers. Phase 9 also requires a local macOS invocation path via `make perf` or an equivalent single command so Naveen can reproduce regressions on his primary platform before pushing.
- **D-112:** Phase 9 emits grep-friendly stdout markers, summary text artifacts, and uploaded `benchmark.nvim` flame-profile Chrome trace JSON artifacts. Perf evidence is reported separately for Linux and macOS, including platform-qualified threshold markers plus median and p95 values per platform. Phase 9 does not commit per-run baseline JSON files, and manual live-UI checks remain optional spot-check guidance rather than blocking evidence.

### Corpus, Scenarios, And Evidence
- **D-113:** Phase 9 measures deterministic synthetic data through the real production drawer path (`DrawerUI`, `drawer/model.lua`, and `menu.filter()`) and does not benchmark live adapters, backend transport, or helper-only microbenchmarks.
- **D-114:** The blocking perf lane runs on Neovim `0.12.x` and records the exact Neovim version in the evidence artifact; older or alternate Neovim versions may remain non-blocking compatibility checks.
- **D-115:** `nui.nvim` remains the measured production substrate for Phase 9. Phase 9 does not pivot the drawer perf harness to Snacks, `mini.test`, or a raw `vim.api` rewrite.
- **D-116:** `stevearc/benchmark.nvim` is the Phase 9 perf runner and must be pinned to a specific commit hash, following the same pinning policy already used for `nui.nvim`; Phase 9 does not add a new `plenary.nvim` dependency for perf infrastructure.

### Scope Guards And Explicit Exclusions
- **D-117:** Phase 9's real-UI scope is the headless buffer-write path only. `nvim_ui_attach`-based true-redraw measurement is explicitly deferred to a future phase.
- **D-118:** `mini.test` is acknowledged as the right tool for future visual-regression coverage, but Phase 9 does not use it for perf timing because its child-process startup cost distorts millisecond-level latency measurements.

### the agent's Discretion
- Whether the real-nui perf path lives in the existing `check_drawer_filter.lua` behind `DRAW01_PERF_MODE=real-nui` or in a closely related companion script, as long as D-110's hybrid split remains intact.
- Exact warmup/sample counts, so long as they are fixed, documented, and consistent across the reported scenario metrics.
- Exact marker names for the new append/cached-expand metrics, as long as they are explicit and map cleanly to the blocking scenarios above.
- Whether optional advisory stress runs (for example, a 10k local-only tier) are exposed via an env var or a separate helper script.

</decisions>

<specifics>
## Specific Ideas

- Keep `DRAW01_PERF_MODE=real-nui` as the release authority and `DRAW01_PERF_MODE=non-release-smoke` as an explicit fallback label rather than silently auto-downgrading.
- Reuse the exact Phase 4 locked corpus/query cohort for filter/startup/restore metrics so Phase 9 evidence is directly comparable to the earlier smoke contract.
- Add one deterministic oversized-branch fixture derived from the shipped Phase 6 `Load more...` chunking contract to measure a real 1000-node append instead of timing a synthetic loop.
- Add one cached-expand fixture that starts from an already-warmed `_struct_cache.root[conn_id]` so the measurement stays UI-side and does not accidentally drift into transport or adapter benchmarking.
- Keep the output diff-friendly: corpus label, perf mode, and scenario metrics should print in a stable format that can be grepped in CI and copied into the phase summary without hand-normalization.
- Publish separate Linux and macOS perf markers and thresholds rather than pretending one cross-platform timing budget is portable.
- Expose a local macOS repro target such as `make perf` so the same real-nui harness can be run before pushing.
- Use the existing pinned `nui.nvim` install path in CI rather than introducing a second plugin fetch path for the harness.

</specifics>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Scope And Milestone Constraints
- `.planning/PROJECT.md` — v1.1 milestone goal, additive-only rule, and the active requirement that real-`nui.nvim` replace stub-only smoke evidence
- `.planning/ROADMAP.md` — Phase 9 goal, success criteria, and research bullets for the real-nui harness
- `.planning/REQUIREMENTS.md` — `PERF-01` requirement text and the out-of-scope guardrail against backend benchmarking or new feature work
- `.planning/STATE.md` — current milestone position and sequencing context

### Locked Prior-Phase Contracts
- `.planning/phases/04-drawer-navigation/04-CONTEXT.md` — locked DRAW-01 filter behavior, snapshot restore, zero-RPC typing, and the existing perf-contract framing
- `.planning/phases/04-drawer-navigation/04-02-PLAN.md` — exact locked corpus, query cohort, perf budgets, summary fields, and smoke-vs-real perf framing that Phase 9 promotes
- `.planning/phases/04-drawer-navigation/04-VALIDATION.md` — current smoke-mode validation contract, manual release gap, and pinned `nui.nvim` scaffolding
- `.planning/phases/04-drawer-navigation/04-02-SUMMARY.md` — current smoke evidence and the unresolved manual live-UI verification gap
- `.planning/phases/06-structure-laziness-notes-picker/06-CONTEXT.md` — D-37/D-47 bounded materialization and `Load more...` semantics, plus D-55's caveat that transport/root payload work stays separate from UI measurement
- `.planning/phases/07-connection-only-drawer/07-CONTEXT.md` — shipped drawer ownership and lifecycle substrate that Phase 9 must measure without changing
- `.planning/phases/08-type-aware-connection-wizard/08-CONTEXT.md` — current locked Phase 8 `nui.nvim` usage remains intact; Phase 9 may borrow patterns but must not reopen D-89..D-106

### Code Seams And Test Infrastructure
- `.planning/codebase/CONVENTIONS.md` — Lua/Go test, headless-script, and additive-change conventions
- `.planning/codebase/STRUCTURE.md` — where drawer UI, handler, headless tests, and workflow files live
- `ci/headless/check_drawer_filter.lua` — current DRAW-01 smoke harness, stubbed `nui.*` seams, and existing marker/report structure
- `ci/headless/check_structure_lazy.lua` — existing large-branch / `Load more...` / cached-root fixture patterns from Phase 6
- `lua/dbee/ui/drawer/init.lua` — real filter, snapshot, restore, cached-search-model, load-more, and cached-expand behavior
- `lua/dbee/ui/drawer/model.lua` — shared rendered/search model builders already used by the real drawer/filter path
- `lua/dbee/ui/drawer/convert.lua` — real `Load more...` sentinel node and materialization-preserving node conversion
- `lua/dbee/ui/drawer/menu.lua` — real `nui.input`-backed filter prompt used in production
- `lua/dbee/ui/connection_wizard/init.lua` — existing real `nui.popup` / `nui.input` compound modal patterns from Phase 8
- `.github/workflows/test.yml` — pinned `nui.nvim` installation path and current headless runtimepath setup

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `ci/headless/check_drawer_filter.lua` already contains the locked DRAW-01 corpus vocabulary, marker style, and the existing smoke perf outputs; it is the natural base for a real-nui perf path rather than a greenfield harness.
- `ci/headless/check_structure_lazy.lua` already builds large branch fixtures, `Load more...` assertions, and cached root/child async fixtures that can seed the append and cached-expand measurements without inventing new subtree semantics.
- `lua/dbee/ui/drawer/menu.lua` and `lua/dbee/ui/connection_wizard/init.lua` already mount real `nui.input`, `nui.menu`, and `nui.popup` primitives in production code, which gives the harness a project-native pattern for running real `nui.nvim` headlessly.
- `.github/workflows/test.yml` already clones `nui.nvim` into `${RUNNER_TEMP}/nui.nvim` and prepends it to `runtimepath` for all headless scripts, so Phase 9 does not need a new plugin install mechanism.

### Established Patterns
- The current DRAW-01 perf evidence is explicitly labeled `non-release-smoke`, and the existing summary/validation docs already distinguish smoke metrics from future release-grade real-nui evidence.
- The real drawer/filter path already lives in `DrawerUI`, `drawer/model.lua`, and `menu.filter()`; the major gap is that `check_drawer_filter.lua` replaces `nui.tree`, `nui.input`, `nui.popup`, and most menu behavior with fakes before measuring.
- Phase 6 already established bounded child materialization and a real `Load more...` sentinel, so Phase 9 should measure that shipped behavior rather than inventing a new append contract.
- Phase 8 proved the repo is comfortable depending on `nui.nvim` directly for compound modal UI, which lowers the risk of a headless harness that mounts the real primitives instead of stubbing them.

### Integration Points
- `ci/headless/check_drawer_filter.lua` is the seam to split smoke semantics from release-mode real-nui perf measurement.
- `lua/dbee/ui/drawer/init.lua`, `model.lua`, and `convert.lua` are the only acceptable measurement targets for filter/startup/restore/load-more/cached-expand timing; helper-only shortcuts would miss the real integration cost.
- `.github/workflows/test.yml` is where the real-nui mode becomes blocking and where fail-closed behavior must be wired if the pinned plugin is missing or unusable.
- Future Phase 9 validation and summary docs should reuse the existing Phase 4 perf field labels where possible so evidence remains comparable across the smoke-to-real transition.

</code_context>

<deferred>
## Deferred Ideas

- 10k-or-larger advisory stress tiers as local-only or nightly benchmarks
- Profiler trace export, flamegraphs, or heap snapshots as required release artifacts
- Real-nui migration of unrelated headless suites outside the DRAW-01 perf path
- Additional blocking perf matrices beyond the co-equal Linux/macOS release gates
- Backend transport or adapter optimizations if real-nui measurements uncover a deeper non-UI bottleneck

</deferred>

---

*Phase: 09-real-nui-perf-harness*
*Context gathered: 2026-04-28*
