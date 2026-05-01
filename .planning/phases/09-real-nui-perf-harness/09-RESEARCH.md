# Phase 9: Real-Nui Drawer Perf Harness - Research

**Researched:** 2026-04-29  
**Status:** Research complete - pre-lock  
**Scope:** Validate the best substrate and runner for `PERF-01` without anchoring on the repo's current dependency graph.

## Summary Recommendation

Use **headless Neovim as the runner** and **real `nui.nvim` as the measured UI substrate** for Phase 9.

That is not because `nui.nvim` is already installed in this repo. It is because the release question for `PERF-01` is narrow and concrete: *does the shipped DRAW-01 drawer stay inside budget on its real UI path?* The shipped path already goes through `DrawerUI`, `drawer/model.lua`, and `menu.filter()` with `NuiInput`; the current headless perf script only looks fast because it stubs `nui.tree`, `nui.popup`, `nui.input`, and `nui.menu`, then hardcodes `DRAW01_PERF_MODE=non-release-smoke`. `ci/headless/check_drawer_filter.lua:227-305,895-910,1228-1232`, `lua/dbee/ui/drawer/menu.lua:151-220`, `lua/dbee/ui/drawer/init.lua:2115-2138,2270-2287,2943-2965`

The open-minded ecosystem result is:

- If the project were building a brand-new tree UI from scratch today, the two serious long-term substrate families are **raw `vim.api.nvim_buf_*` + `nvim_open_win`** and **`nui.nvim`**.
- **`snacks.nvim`** is an excellent active project, but its explorer is explicitly "a file explorer (picker in disguise)", which is a different architecture than this repo's persistent drawer tree. It is a bad apples-to-apples perf target for Phase 9. [N11]
- **`plenary.nvim`** still shows up in many mature plugins, but it is explicitly marked "ARCHIVED SOON", and community guidance now says not to start new plugin testing on Plenary if it can be avoided. It is a runner/library question anyway, not a UI substrate question. [N14] [N15]

One follow-up is worth carrying into the lock pass: current CI installs **Neovim 0.11.6**, but the current stable release is **0.12.2** and there is no official LTS line, only stable and nightly/development prereleases. A release-grade perf gate should decide deliberately whether to keep 0.11.x for milestone stability or align the blocking lane to 0.12.x before thresholds are locked. `.github/workflows/test.yml:84-96` [N1] [N2] [N3]

## Standard Stack

- **Blocking runner:** `nvim --headless -u NONE -i NONE -n` with a single canonical Linux CI lane.
- **Optional runner cleanup:** if Phase 9 wants a cleaner entrypoint than `luafile`, prefer core `nvim -l` over adding new Plenary dependence. [N4] [N14] [N15]
- **Measured UI substrate:** real `nui.nvim` loaded from CI runtimepath, using the same plugin bootstrap path the repo already has. `.github/workflows/test.yml:88-96`
- **Fixture source:** deterministic synthetic drawer fixtures derived from the locked Phase 4 corpus plus Phase 6 `Load more...` and cached-root fixtures. `.planning/phases/04-drawer-navigation/04-02-PLAN.md:296-306`, `ci/headless/check_structure_lazy.lua:1241-1293,1306-1320`
- **Measurement API:** keep `vim.loop.hrtime()` and `collectgarbage("count")` so Phase 9 stays comparable to the locked Phase 4 perf contract. `.planning/phases/04-drawer-navigation/04-02-PLAN.md:297-305`
- **Reporting contract:** stdout markers in grep-friendly form, not committed baseline JSON; raw numbers belong in CI logs and phase summaries, while thresholds and corpus stay in repo docs.

## Neovim Compatibility

### Current release channels

- Current stable is **v0.12.2**. [N1]
- Nightly is a **0.13-dev prerelease** channel. [N2]
- Official install docs talk about the **latest stable release** and the **latest development prerelease**; I did not find an official LTS channel. [N3]

### Practical support horizon

There is no single ecosystem-wide answer to "last N versions". The current pattern across actively used plugins is "support a recent floor, but optimize for current stable":

- Telescope documents support for **latest stable and latest HEAD/nightly only**. [N16]
- nvim-tree documents support for **v0.11.5+**, with **N-0.1 guaranteed**. [N18]
- Snacks requires **Neovim >= 0.9.4**. [N11]
- Neo-tree's current `vim.pack` example says **0.12 or above is required** and depends on both `plenary.nvim` and `nui.nvim`. [N13]
- `nui.nvim` itself still advertises a very low floor (`>= 0.5`), but that says more about library portability than about which Neovim version a release-grade perf gate should target. [N9]

### Breaking-change horizon for a perf harness

Neovim's official news/deprecation docs show active churn across 0.10, 0.11, and 0.12 rather than a "frozen" API window:

- 0.10 introduced major editor/runtime changes and moved more surface into newer APIs. [N6]
- 0.11 continued API and UX changes, including deprecations and rewritten defaults in areas adjacent to plugin integration. [N7]
- 0.12 adds more deprecations and UI/runtime changes. [N5] [N8]

Research conclusion: Phase 9 should treat **one chosen stable Neovim build** as the authoritative perf baseline. Other versions can still run as smoke or compatibility lanes, but the research does **not** support assuming timing parity across 0.10..0.12.

### Headless mode

Headless execution is a first-class Neovim surface:

- `--headless` is documented in core startup docs. [N4]
- `nvim -l` is also documented in core startup docs. [N4]

I did **not** find an official promise that headless timing is identical across Neovim versions or across Linux/macOS runners. That argues for one blocking runner and optional observational cross-checks, not multi-platform threshold locking.

## Substrate Comparison

| Option | Maintenance / community | 0.12 / headless fit | Perf-measurement fit for Phase 9 | Breaking-change risk | Recommendation |
| --- | --- | --- | --- | --- | --- |
| `nui.nvim` | Mature UI component library, latest release `v0.4.0`, ~2.1k stars; used by Neo-tree. [N9] [N10] [N13] | Works fine on current repo headless path; repo already mounts it from CI runtimepath. `.github/workflows/test.yml:88-96` | **Best fit** because it is the actual production substrate for the drawer input/tree path under test. `lua/dbee/ui/drawer/menu.lua:151-220` | Medium: wrapper layer above core, but not abandoned and still released. [N10] | **Recommended Phase 9 substrate** |
| `snacks.nvim` | Very active, latest release `v2.31.0`, ~7.5k stars, tests in repo. [N11] [N12] | Strong general compatibility story (`>= 0.9.4`), headless-friendly in principle. [N11] | Poor fit for this phase because its explorer is "a file explorer (picker in disguise)" rather than the same persistent drawer tree architecture. [N11] | Medium: fast-moving project with broad feature surface | Good ecosystem reference; **not** the right harness target unless the drawer itself is replatformed |
| Raw `vim.api.nvim_buf_*` + `nvim_open_win` | Most future-proof surface because it is core Neovim; common among file/tree plugins such as Oil and nvim-tree. [N17] [N18] | Excellent headless fit | Strong choice for a greenfield or full replatform, but **wrong Phase 9 question** because it would benchmark a different implementation than what ships today | Low-to-medium: core APIs still deprecate/change across releases, but less wrapper risk than third-party libs. [N5] [N6] [N7] [N8] | Best long-term alternative if the project ever rewrites the drawer; **not** the best Phase 9 harness substrate |
| `plenary.nvim` | Historically common, but repo now says **ARCHIVED SOON**; still present in mature ecosystems like Telescope and Neo-tree. [N13] [N14] [N16] | Works in headless test setups | Not a UI substrate. Useful only as runner/helpers, and even there it is no longer the long-term default recommendation. [N14] [N15] | High for new investment because maintenance is winding down | Do **not** introduce as a new Phase 9 dependency |
| `dressing.nvim` | Archived; author recommends Snacks for `vim.ui.*`. [N19] | Fine for `vim.ui.input` / `vim.ui.select`, not tree rendering | Not relevant to drawer tree perf beyond input/select UX | High: archived | Exclude from Phase 9 substrate choices |

## What Similar Plugins Use

### Tree and explorer plugins

- **Neo-tree** is the strongest direct signal that `nui.nvim` is a legitimate ecosystem choice for a real tree UI, not just a form/input helper. It depends on both `plenary.nvim` and `nui.nvim`, requires recent Neovim, and sells "smooth and efficient asynchronous operation". [N13]
- **Oil** is the strongest signal on the other side: serious UI plugins still commonly own their windows/buffers directly via core APIs, and Oil keeps both `tests/` and a `perf/` directory in-repo. [N17]
- **nvim-tree** reinforces the raw-API camp and publishes an explicit support policy (`v0.11.5+`, N-0.1 guaranteed). [N18]

### Picker and input ecosystems

- **Telescope** remains the most visible picker project; it depends on `plenary.nvim`, supports latest stable + nightly, and points performance-sensitive users to `telescope-fzf-native`. That is a useful ecosystem pattern: optimize or benchmark the hotspot you actually care about rather than trying to generalize all UI performance through one abstraction. [N16]
- **Snacks** is the current high-activity "many UI tools in one project" option, but for this phase it is reference material, not a direct target, because its explorer is not the same substrate being shipped here. [N11] [N12]
- **Dressing** being archived and explicitly redirecting people to Snacks is a good reminder that `vim.ui.*` wrappers are a different problem space than tree rendering. [N19]

### Runner and test infrastructure

- Mature plugins still use **Plenary** heavily. Telescope and Neo-tree both prove that. [N13] [N16]
- The newer community direction is: **for new testing infrastructure, avoid starting with Plenary if core Neovim + LuaRocks/busted already covers the job**. [N15]

Research conclusion: there is **no single universal substrate** that "everybody else uses". The actual split is:

1. **Raw core API** for plugins that own the whole UI surface.
2. **`nui.nvim`** for plugins that want structured tree/input/popup components.
3. **Picker frameworks** like Telescope/Snacks for search/select workflows, which are adjacent but not identical to this drawer's architecture.

## Latency Thresholds In The Ecosystem

I did **not** find sampled plugin repos publishing hard CI frame-budget numbers like `<16ms per keystroke` or `<50ms append` in repo-front documentation.

What I did find:

- Telescope documents performance-sensitive paths and points users to native sorters/extensions. [N16]
- Oil keeps a dedicated `perf/` directory. [N17]
- Snacks includes a profiler among its built-in tools. [N11]
- Neo-tree and nvim-tree emphasize responsiveness or efficiency, but not with explicit public CI latency budgets in the surfaces I reviewed. [N13] [N18]

Research conclusion: `nvim-dbee` already has a **more explicit perf contract than most of the sampled ecosystem**. That is a reason to keep the locked Phase 4 corpus and budgets as the initial hard gate, then report stricter frame-budget numbers for lock review rather than pretending the broader ecosystem has already standardized on one public ms threshold.

## Architecture Patterns

### Measure the production path, not a substitute

The current local perf harness is deliberately smoke-only:

- It installs fake `nui.tree`, `nui.popup`, and `nui.input`. `ci/headless/check_drawer_filter.lua:227-305`
- It later swaps in fake `nui.menu` and another fake `nui.input` for filter-path measurements. `ci/headless/check_drawer_filter.lua:895-910`
- It prints only smoke markers and a deferred-note banner. `ci/headless/check_drawer_filter.lua:1228-1232`

Meanwhile, the real drawer path already exists:

- `menu.filter()` mounts the real `NuiInput` with `on_change`, `on_submit`, border text, and forwarded mappings. `lua/dbee/ui/drawer/menu.lua:151-220`
- `DrawerUI:capture_filter_snapshot()` and `DrawerUI:apply_filter()` already own the zero-RPC filter path against cached search/render models. `lua/dbee/ui/drawer/init.lua:2115-2138,2270-2287`
- `check_structure_lazy.lua` already has realistic `Load more...` and cached-root fixtures that Phase 9 can time without inventing new subtree semantics. `ci/headless/check_structure_lazy.lua:1241-1293,1306-1320`

That makes the recommended architecture straightforward: keep the **current headless script/fixture style**, but split the **semantic smoke path** from a **real-nui measurement path** that runs the actual production code.

### Keep runner choice separate from substrate choice

The best long-term answer for "how should Neovim tests run?" is not identical to the best answer for "which UI substrate should this phase measure?"

- **Runner:** core headless Neovim is the safest long-term choice. [N4] [N15]
- **Substrate:** measure the actual shipped substrate (`nui.nvim` in this repo's drawer) rather than migrating the test to a different UI library or rewriting the drawer just to benchmark it.

### Keep deterministic synthetic fixtures

Phase 4 already locked the corpus, queries, and budgets for the release question. `.planning/phases/04-drawer-navigation/04-02-PLAN.md:296-306`

Phase 9 should keep that property:

- deterministic corpus
- deterministic query cohort
- deterministic `Load more...` append case
- deterministic cached-expand case

Live database benchmarking would answer a different question and add transport noise that `PERF-01` explicitly does not need. `.planning/REQUIREMENTS.md:68`, `.planning/ROADMAP.md:191-204`

## Don't Hand-Roll

- Do **not** rewrite the drawer to raw `vim.api` only to get "pure" numbers. That would benchmark a new architecture, not the shipped one.
- Do **not** switch Phase 9's perf target to Snacks unless the drawer itself is being replatformed to Snacks.
- Do **not** introduce new `plenary.nvim` dependence for perf infrastructure.
- Do **not** use live adapters/databases as the blocking perf corpus.
- Do **not** commit a churn-heavy baseline JSON unless the team explicitly decides historical baseline files are worth the maintenance cost.

## Common Pitfalls

- Calling a stubbed UI path "release-grade evidence".
- Locking thresholds on an outdated Neovim release by accident (`0.11.6` in current CI versus `0.12.2` stable now). `.github/workflows/test.yml:84-96` [N1]
- Assuming Linux and macOS timings are directly comparable enough for one shared hard threshold.
- Measuring `Load more...` with synthetic loops instead of the real sentinel/materialization path already proven in Phase 6.
- Letting missing `nui.nvim` silently downgrade the release lane back to smoke instead of failing closed.
- Conflating picker-framework performance with persistent drawer-tree performance.

## Code Examples And Local Seams

### Local files Phase 9 should mine directly

- `ci/headless/check_drawer_filter.lua:227-305,895-910,1228-1232`  
  Current fake-`nui` smoke harness and explicit `non-release-smoke` markers.

- `lua/dbee/ui/drawer/menu.lua:151-220`  
  Real `NuiInput` filter prompt path, including `on_change`.

- `lua/dbee/ui/drawer/init.lua:2115-2138,2270-2287,2943-2965`  
  Real snapshot, session, coverage-label, and zero-RPC typing path.

- `lua/dbee/ui/drawer/model.lua:47-65,155-217`  
  Shared search/render builders that keep filter start and refresh on the same model contract.

- `ci/headless/check_structure_lazy.lua:1241-1293,1306-1320`  
  Existing `Load more...` and cached-root fixtures for append/cached-expand timing.

- `.github/workflows/test.yml:84-96`  
  Current Neovim install, pinned `nui.nvim` checkout, and `runtimepath` wiring.

### Why this matters

This repo is unusually well set up for a real-UI perf harness already:

- the fixture corpus exists
- the real production code path exists
- the CI `runtimepath` seam exists
- the remaining gap is mainly *un-stubbing the release path and measuring it honestly*

## Migration Path For `nvim-dbee`

### If the repo follows the recommendation

Cost: **low-to-medium**

1. Keep the current headless script/fixture style.
2. Split semantic smoke coverage from the real-nui measurement path.
3. Reuse the existing pinned `nui.nvim` install path in CI.
4. Measure the real `menu.filter()` / `DrawerUI` / `drawer/model.lua` path.
5. Keep Linux as the blocking lane.
6. Decide before lock whether the blocking Neovim version remains `0.11.6` or moves to stable `0.12.x`.

This is the cheapest path that still answers the release question honestly.

### If the repo instead pivots to raw `vim.api`

Cost: **high**

You either:

- replatform the drawer, which is out of scope for Phase 9, or
- benchmark a non-production UI path, which weakens the evidence value

Raw `vim.api` remains the strongest long-term alternative if the project ever wants to replace its UI substrate, but that is a different phase.

### If the repo instead pivots to `snacks.nvim`

Cost: **high**

This would measure a different explorer/picker architecture than the drawer that currently ships. It may be a valid future design exploration, but it is weak release evidence for `PERF-01`.

## Risks And Open Questions

- Should the blocking perf lane stay on the current CI Neovim version (`0.11.6`) for milestone stability, or move to stable `0.12.x` for ecosystem alignment before lock?
- Should the real-nui perf path live behind `DRAW01_PERF_MODE=real-nui` in `check_drawer_filter.lua`, or in a close companion script that shares the same fixtures but avoids top-level stub setup?
- Are the proposed `<16ms` typing/restore and `<50ms` append/cached-expand targets realistic on GitHub-hosted runners once real `NuiInput` / `NuiTree` mount and render cost is included?
- Is one Linux blocking lane enough, with macOS retained as advisory only?

## Sources

### Local Evidence

- `.planning/REQUIREMENTS.md:68`
- `.planning/PROJECT.md:20,45`
- `.planning/ROADMAP.md:191-204`
- `.planning/phases/04-drawer-navigation/04-02-PLAN.md:296-306`
- `ci/headless/check_drawer_filter.lua:227-305,895-910,1228-1232`
- `ci/headless/check_structure_lazy.lua:1241-1293,1306-1320`
- `lua/dbee/ui/drawer/menu.lua:151-220`
- `lua/dbee/ui/drawer/init.lua:2115-2138,2270-2287,2943-2965`
- `lua/dbee/ui/drawer/model.lua:47-65,155-217`
- `.github/workflows/test.yml:84-96`

### External References

- [N1] https://github.com/neovim/neovim/releases/tag/v0.12.2
- [N2] https://github.com/neovim/neovim/releases/tag/nightly
- [N3] https://neovim.io/doc/install/
- [N4] https://neovim.io/doc/user/starting/
- [N5] https://neovim.io/doc/user/deprecated/
- [N6] https://neovim.io/doc/user/news-0.10/
- [N7] https://neovim.io/doc/user/news-0.11/
- [N8] https://neovim.io/doc/user/news-0.12/
- [N9] https://github.com/MunifTanjim/nui.nvim
- [N10] https://github.com/MunifTanjim/nui.nvim/releases
- [N11] https://github.com/folke/snacks.nvim
- [N12] https://github.com/folke/snacks.nvim/releases
- [N13] https://github.com/nvim-neo-tree/neo-tree.nvim
- [N14] https://github.com/nvim-lua/plenary.nvim
- [N15] https://github.com/nvim-neorocks/nvim-best-practices
- [N16] https://github.com/nvim-telescope/telescope.nvim
- [N17] https://github.com/stevearc/oil.nvim
- [N18] https://github.com/nvim-tree/nvim-tree.lua
- [N19] https://github.com/stevearc/dressing.nvim
