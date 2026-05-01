---
phase: 13-ux-regression-batch
plan: 01
revision: 2
type: execute
wave: 1
depends_on: [11]
files_modified:
  - lua/dbee/lsp/schema_cache.lua
  - lua/dbee/ui/drawer/model.lua
  - lua/dbee/ui/drawer/init.lua
  - lua/dbee/ui/drawer/menu.lua
  - lua/dbee/ui/connection_wizard/init.lua
  - ci/headless/check_lsp_disk_cache_safety.lua
  - ci/headless/check_drawer_filter.lua
  - ci/headless/check_drawer_perf.lua
  - ci/headless/perf_thresholds.lua
  - ci/headless/check_connection_wizard.lua
autonomous: true
requirements: [DBEE-UX-01]
---

# Phase 13: UX Regression Batch Plan

<objective>
Restore the shipped v1.1/v1.2 UX workflows that currently fail on Naveen's daily setup.

By the end of this plan, the Phase 8 connection wizard has explicit floating-window highlights on every wizard-owned `nui.nvim` surface, the Phase 7 drawer filter opens and searches visible connection rows in cold and mixed cached/uncached drawer states, and Phase 11 schema-cache upgrade recovery treats recognizable pre-version cache files as silent migration instead of user-facing corruption.
</objective>

<execution_context>
@/Users/naveenkanuri/Documents/nvim-dbee/.codex/skills/gsd-plan-phase/SKILL.md
@/Users/naveenkanuri/Documents/nvim-dbee/.codex/get-shit-done/workflows/plan-phase.md
@/Users/naveenkanuri/Documents/nvim-dbee/.codex/get-shit-done/references/ui-brand.md
</execution_context>

<context>
@.planning/milestones/v1.3-roadmap.md
@.planning/ROADMAP.md
@.planning/REQUIREMENTS.md
@.planning/STATE.md
@known-issues.md
@.planning/phases/13-ux-regression-batch/13-CONTEXT.md
@.planning/phases/04-drawer-navigation/04-CONTEXT.md
@.planning/phases/06-structure-laziness-notes-picker/06-CONTEXT.md
@.planning/phases/07-connection-only-drawer/07-CONTEXT.md
@.planning/phases/08-type-aware-connection-wizard/08-CONTEXT.md
@.planning/phases/09-real-nui-perf-harness/09-CONTEXT.md
@.planning/phases/10-lsp-optimization/10-CONTEXT.md
@.planning/phases/11-lsp-optimization-correctness/11-CONTEXT.md
</context>

<must_haves>
  <truths>
    - "Honor D-01..D-223 verbatim. Phase 13 may close only the three locked regressions."
    - "D-198 makes this regression closure only: no schema allowlist, no lazy-loading deepening, no LSP hover/resolve/code-action/symbol features, and no Phase 15 polish."
    - "D-202 highlight mapping is exact: Normal:NormalFloat,NormalNC:NormalFloat,EndOfBuffer:NormalFloat,FloatBorder:FloatBorder,FloatTitle:FloatTitle,CursorLine:Visual,Search:IncSearch."
    - "D-208 keeps filter typing zero-RPC. Starting or typing in `/` must not warm structure cache or issue live handler calls."
    - "D-209 through D-213 require filtering whatever is visible: cold connection rows, cached structure rows, and mixed visible connection rows."
    - "D-215 makes schema-index cache version 2. Missing version is legacy only after the decoded payload passes recognizable schema-index shape validation."
    - "D-218 keeps WARN diagnostics for invalid JSON, malformed missing-version payloads, malformed current-version payloads, unsupported future versions, and malformed column cache files."
    - "D-221 through D-223 require deterministic headless tests with no live database dependency."
  </truths>
  <artifacts>
    - path: "lua/dbee/ui/connection_wizard/init.lua"
      provides: "Phase 8 compound wizard; owns main Popup, password Input, multiline popup, and wizard calls into menu.input/menu.select"
      contains: "popup_options"
    - path: "lua/dbee/ui/drawer/menu.lua"
      provides: "shared `nui.input` and `nui.menu` helper options; Phase 13 adds optional winhighlight plumbing only"
      contains: "M.input"
    - path: "lua/dbee/ui/drawer/init.lua"
      provides: "drawer filter lifecycle, snapshot capture, apply/submit/close restore, and current early-return site"
      contains: "capture_filter_snapshot"
    - path: "lua/dbee/ui/drawer/model.lua"
      provides: "search model construction and searchable-type boundaries"
      contains: "build_search_model"
    - path: "lua/dbee/lsp/schema_cache.lua"
      provides: "schema-index disk cache read/write, validation, corruption removal, and cache stats"
      contains: "load_from_disk"
    - path: "ci/headless/check_drawer_perf.lua"
      provides: "Phase 9 real-nui drawer perf harness that must gain fallback filter-start scenarios"
      contains: "DRAW01_REAL_NUI_PERF_ALL_PASS"
  </artifacts>
  <key_links>
    - from: "lua/dbee/ui/connection_wizard/init.lua"
      to: "lua/dbee/ui/drawer/menu.lua"
      via: "wizard field editing calls shared `menu.input()` / `menu.select()` helpers and must pass the locked D-202 mapping explicitly"
      pattern: "menu.select"
    - from: "lua/dbee/ui/drawer/init.lua"
      to: "lua/dbee/ui/drawer/model.lua"
      via: "`capture_filter_snapshot()` builds the cached corpus, then merges visible connection rows from the pre-filter rendered snapshot"
      pattern: "build_search_model"
    - from: "lua/dbee/ui/drawer/init.lua"
      to: "lua/dbee/ui/drawer/convert.lua"
      via: "visible connection row text/source suffix comes from rendered tree nodes already produced by conversion"
      pattern: "raw_name"
    - from: "ci/headless/check_lsp_disk_cache_safety.lua"
      to: "lua/dbee/lsp/schema_cache.lua"
      via: "test captures `vim.notify` and must distinguish recognizable legacy v1 migration from malformed missing-version corruption"
      pattern: "has_warning"
  </key_links>
</must_haves>

<constraints>
- Do not modify Phase 4..11 context files or reinterpret D-01..D-197.
- Do not add schema allowlist, schema/table lazy loading, loading timeout/cancel UX, source-badge polish, or LSP feature-gap APIs.
- Keep fixes direct and regression-shaped. If a deeper bug appears, record it as v1.3 backlog growth instead of widening this plan.
- New tests must use existing headless fakes/stubs, synthetic colorscheme state, isolated temp/cache dirs, and no live databases.
- Revision 2 atomicity contract: each task below is a green, regression-sized commit containing implementation plus its focused tests. Do not commit red-test-only tasks.
- Use `apply_patch` for manual edits and avoid unrelated formatting churn.
</constraints>

<scope_correction>
The original prompt names `lua/dbee/ui/drawer/menu.lua` as the drawer filter path, but current code places the filter corpus and early-return in `lua/dbee/ui/drawer/init.lua` plus `lua/dbee/ui/drawer/model.lua`. `menu.lua` remains in scope for wizard `Input`/`Select` highlight plumbing. The drawer task therefore touches the actual filter model/snapshot files while preserving the locked Phase 13 boundary.
</scope_correction>

<r1_review_closure>
- CRITICAL 1 closed: cache migration now requires recognizable legacy shape validation before silent missing-version recovery, and malformed missing-version JSON keeps WARN diagnostics.
- CRITICAL 2 closed: drawer fallback now runs on every filter start and merges visible connection rows missing from the cached corpus, including mixed cached/uncached states.
- CRITICAL 3 closed: drawer fallback perf scenarios are required in `check_drawer_perf.lua` and threshold candidates are advisory by default.
- HIGH 4 closed: red-test-first tasks were collapsed into green regression-sized tasks.
- HIGH 5 closed: final verification enumerates detailed UX13 markers and the required LSP11 marker families; `UX13_ALL_PASS=true` is fail-closed.
- HIGH 6 closed: drawer perf publishability explicitly records `DRAW01_REAL_NUI_PERF_ALL_PASS=true|unfrozen|false`; false fails and unfrozen is advisory-only.
</r1_review_closure>

<task_graph>
## Wave 1 - Cache Migration UX
- `13-01-01` implements schema-index cache versioning and legacy migration tests in one green commit.

## Wave 2 - Drawer Filter Visible-Row Fallback
- `13-01-02` implements cold and mixed visible-row filtering plus functional tests and perf scenarios in one green commit.

## Wave 3 - Wizard Highlight Regression
- `13-01-03` implements wizard highlight plumbing/application plus render-state tests in one green commit.

Dependency DAG:
```text
13-01-01 -> final verification gate
13-01-02 -> final verification gate
13-01-03 -> final verification gate
```
</task_graph>

<tasks>
  <task id="13-01-01" type="fix" wave="1" commit="fix(13-01-01): version lsp schema cache migration">
    <depends_on>Phase 11 disk-cache harness exists.</depends_on>
    <files>
      - lua/dbee/lsp/schema_cache.lua
      - ci/headless/check_lsp_disk_cache_safety.lua
    </files>
    <read_first>
      - lua/dbee/lsp/schema_cache.lua
      - ci/headless/check_lsp_disk_cache_safety.lua
      - .planning/phases/11-lsp-optimization-correctness/11-CONTEXT.md
      - .planning/phases/13-ux-regression-batch/13-CONTEXT.md
    </read_first>
    <action>
      Add a local schema-index cache version constant set to `2`.
      Write `version = 2` alongside `conn_id`, `schemas`, and `tables` in `save_to_disk()`.

      In `load_from_disk()`, classify decoded schema-index payloads in this order:
      1. Invalid JSON or nil decode result: existing WARN-level corrupt-cache removal and `false`.
      2. Missing `version`: first run the existing Phase 11 schema-index normalizer or an equivalent legacy recognizer over `schemas`, `tables`, and optional `all_table_names`.
      3. Missing `version` with recognizable legacy shape: emit debug/internal-test-observable migration evidence, delete the old schema-index file, and return `false` so structure refresh regenerates version 2, with no WARN.
      4. Missing `version` with malformed or unrecognizable shape, such as `{"schemas":"bad","tables":{}}`: WARN-level corrupt-cache removal and `false`.
      5. `version == 2`: validate through the current schema/table normalizer and warn/remove on malformed current-version data.
      6. Unsupported future versions: fail safely without crashing and WARN because current code cannot treat the file as a known upgrade path.

      Do not alter column-cache corruption handling, atomic writes, disk pruning, LRU behavior, or completion-path disk work boundaries.
      Extend `check_lsp_disk_cache_safety.lua` in the same commit so the new tests pass before committing.
    </action>
    <acceptance_criteria>
      - `grep -n 'SCHEMA_CACHE_VERSION = 2' lua/dbee/lsp/schema_cache.lua`
      - `grep -n 'version = SCHEMA_CACHE_VERSION' lua/dbee/lsp/schema_cache.lua`
      - `grep -n 'UX13_CACHE_VERSION2_WRITTEN=true' ci/headless/check_lsp_disk_cache_safety.lua`
      - `grep -n 'UX13_CACHE_LEGACY_V1_SILENT=true' ci/headless/check_lsp_disk_cache_safety.lua`
      - `grep -n 'UX13_CACHE_TRUE_CORRUPTION_WARN_RETAINED=true' ci/headless/check_lsp_disk_cache_safety.lua`
      - `make perf-bootstrap >/dev/null && NIO_DIR="$(make perf-bootstrap-print | awk -F= '/^NIO_NVIM_DIR=/{print $2}')" && nvim --headless -u NONE -i NONE -n --cmd "set rtp^=${NIO_DIR} | set rtp+=$(pwd)" -c "luafile ci/headless/check_lsp_disk_cache_safety.lua"`
    </acceptance_criteria>
    <d_trace>D-198, D-199, D-200, D-215, D-216, D-217, D-218, D-219, D-220, D-221, D-222, D-223</d_trace>
  </task>

  <task id="13-01-02" type="fix" wave="2" commit="fix(13-01-02): filter visible drawer connection rows">
    <depends_on>Phase 4/6/7 drawer filter harness and Phase 9 drawer perf harness exist.</depends_on>
    <files>
      - lua/dbee/ui/drawer/model.lua
      - lua/dbee/ui/drawer/init.lua
      - ci/headless/check_drawer_filter.lua
      - ci/headless/check_drawer_perf.lua
      - ci/headless/perf_thresholds.lua
    </files>
    <read_first>
      - lua/dbee/ui/drawer/model.lua
      - lua/dbee/ui/drawer/init.lua
      - lua/dbee/ui/drawer/convert.lua
      - ci/headless/check_drawer_filter.lua
      - ci/headless/check_drawer_perf.lua
      - ci/headless/perf_thresholds.lua
      - .planning/phases/04-drawer-navigation/04-CONTEXT.md
      - .planning/phases/06-structure-laziness-notes-picker/06-CONTEXT.md
      - .planning/phases/07-connection-only-drawer/07-CONTEXT.md
      - .planning/phases/09-real-nui-perf-harness/09-CONTEXT.md
    </read_first>
    <action>
      Keep the existing cached-structure corpus as the source of truth for schemas/tables/views/procedures/functions.
      On every filter start, not only when `ready_connections == 0`, also enumerate visible connection rows from the pre-filter rendered snapshot.
      Build a set of connection IDs already represented in the cached corpus.
      Merge visible connection rows that are missing from the cached corpus into the search corpus; when a connection appears in both, keep the cached node with its structure children and do not duplicate the row.
      For merged visible connection rows, preserve node ID, type, raw name, displayed row text, action metadata, source metadata when present, and enough path data for submit restore/refocus to work like the cached path.
      Connection-row matching is case-insensitive substring matching across raw connection name, displayed row text, connection ID, source name/source ID, and currently rendered source suffix/badge text.
      Structure-row matching remains the existing cached-structure behavior and searchable-type boundaries; columns remain out of search.
      `apply_filter()` remains zero-RPC: no `convert.handler_nodes()`, refresh, structure warmup, `connection_get_structure_async()`, `connection_get_columns()`, or handler rebuild per keystroke.
      Coverage copy must distinguish visible-row fallback from full structure coverage, for example `visible rows + N of M structures cached`.

      Extend `ci/headless/check_drawer_filter.lua` in the same commit:
      - Cold connection-only root: zero cached structures, visible connections searchable by name and source badge.
      - Mixed state: connection A bootstrapped/cached and connection B visible-only/uncached; `/conn` or an equivalent substring must match both A and B when both are visible.
      - Submit and escape preserve Phase 4 D-31 restore/refocus behavior.
      - Fake handler call counters prove filter typing remains zero-RPC.

      Extend `ci/headless/check_drawer_perf.lua` and `ci/headless/perf_thresholds.lua`:
      - Add advisory scenarios `FILTER_COLD_CONNECTION_ONLY_10`, `FILTER_COLD_CONNECTION_ONLY_100`, `FILTER_COLD_CONNECTION_ONLY_1000`, and `FILTER_MIXED_VISIBLE_AND_CACHED`.
      - Emit median, p95, heap/allocation delta, and sentinel markers for each fallback scenario.
      - Keep new threshold slots advisory by default and preserve Phase 9 D-108 promotion discipline: four weeks at >=95 percent pass rate per platform before frozen/blocking promotion.
    </action>
    <acceptance_criteria>
      - `grep -n 'UX13_DRAWER_FILTER_CONNECTION_ROOT=true' ci/headless/check_drawer_filter.lua`
      - `grep -n 'UX13_DRAWER_FILTER_SOURCE_BADGE=true' ci/headless/check_drawer_filter.lua`
      - `grep -n 'UX13_DRAWER_FILTER_MIXED_VISIBLE_CACHE=true' ci/headless/check_drawer_filter.lua`
      - `grep -n 'UX13_DRAWER_FILTER_ZERO_RPC=true' ci/headless/check_drawer_filter.lua`
      - `grep -n 'FILTER_COLD_CONNECTION_ONLY_1000' ci/headless/check_drawer_perf.lua`
      - `grep -n 'FILTER_MIXED_VISIBLE_AND_CACHED' ci/headless/check_drawer_perf.lua`
      - `grep -n 'filter_cold_connection_only_1000' ci/headless/perf_thresholds.lua`
      - `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_drawer_filter.lua"`
      - `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_structure_lazy.lua"`
      - `ART_DIR=$(mktemp -d) && LOG="$ART_DIR/draw01-stdout.log" && DRAW01_PERF_GATE_MODE=advisory DRAW01_PERF_ARTIFACT_DIR="$ART_DIR" DRAW01_PERF_SUMMARY_PATH="$ART_DIR/draw01-summary.txt" DRAW01_PERF_TRACE_PATH="$ART_DIR/draw01-trace.json" make perf PERF_PLATFORM=macos | tee "$LOG" && grep -q 'DRAW01_FILTER_COLD_CONNECTION_ONLY_1000_SENTINEL_OK=true' "$LOG" && grep -q 'DRAW01_FILTER_MIXED_VISIBLE_AND_CACHED_SENTINEL_OK=true' "$LOG" && grep -Eq 'DRAW01_REAL_NUI_PERF_ALL_PASS=(true|unfrozen)$' "$LOG" && ! grep -q 'DRAW01_REAL_NUI_PERF_ALL_PASS=false' "$LOG"`
    </acceptance_criteria>
    <d_trace>D-198, D-199, D-200, D-207, D-208, D-209, D-210, D-211, D-212, D-213, D-214, D-221, D-222, D-223</d_trace>
  </task>

  <task id="13-01-03" type="fix" wave="3" commit="fix(13-01-03): apply wizard floating highlight contract">
    <depends_on>Phase 8 wizard harness exists.</depends_on>
    <files>
      - lua/dbee/ui/drawer/menu.lua
      - lua/dbee/ui/connection_wizard/init.lua
      - ci/headless/check_connection_wizard.lua
    </files>
    <read_first>
      - lua/dbee/ui/drawer/menu.lua
      - lua/dbee/ui/connection_wizard/init.lua
      - ci/headless/check_connection_wizard.lua
      - .planning/phases/08-type-aware-connection-wizard/08-CONTEXT.md
      - .planning/phases/13-ux-regression-batch/13-CONTEXT.md
    </read_first>
    <action>
      Add optional `opts.winhighlight` plumbing to `menu.input()` and `menu.select()` so callers can set `win_options.winhighlight` without changing default drawer popups.
      Do not set a global default in `menu.lua`; wizard callers must opt in explicitly per D-203.
      Add a local constant in `connection_wizard/init.lua` for the exact locked D-202 mapping.
      Apply the mapping through `win_options.winhighlight` on the main wizard Popup, password Input, multiline descriptor Popup, and every wizard call to `menu.input()` / `menu.select()`.
      Preserve field order, type/mode/service flow, validation, transient ping, FileSource persistence, raw compatibility behavior, password masking, and all Phase 8 contracts.

      Extend `ci/headless/check_connection_wizard.lua` in the same commit:
      - The `nui` stubs retain each Popup/Input/Menu options table and expose window `win_options`.
      - Assert the exact D-202 mapping appears on the main wizard popup, password input, plain text input, type/mode/service selects, and multiline descriptor popup.
      - Include default/bright baseline and synthetic dark-collision baseline.
      - Support an optional installed daily colorscheme check via an environment variable such as `DBEE_UX13_COLORSCHEME`; do not add a plugin dependency and do not fail CI when that optional colorscheme is unavailable.
      - Assert typed text remains present in the relevant buffer/render state.
    </action>
    <acceptance_criteria>
      - `grep -n 'winhighlight' lua/dbee/ui/drawer/menu.lua`
      - `grep -n 'Normal:NormalFloat,NormalNC:NormalFloat,EndOfBuffer:NormalFloat,FloatBorder:FloatBorder,FloatTitle:FloatTitle,CursorLine:Visual,Search:IncSearch' lua/dbee/ui/connection_wizard/init.lua`
      - `grep -n 'UX13_WIZARD_WINHIGHLIGHT_MAIN=true' ci/headless/check_connection_wizard.lua`
      - `grep -n 'UX13_WIZARD_WINHIGHLIGHT_PASSWORD=true' ci/headless/check_connection_wizard.lua`
      - `grep -n 'UX13_WIZARD_WINHIGHLIGHT_INPUT=true' ci/headless/check_connection_wizard.lua`
      - `grep -n 'UX13_WIZARD_WINHIGHLIGHT_SELECT=true' ci/headless/check_connection_wizard.lua`
      - `grep -n 'UX13_WIZARD_WINHIGHLIGHT_MULTILINE=true' ci/headless/check_connection_wizard.lua`
      - `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_connection_wizard.lua"`
      - `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_filesource_persistence.lua"`
    </acceptance_criteria>
    <d_trace>D-198, D-199, D-200, D-201, D-202, D-203, D-204, D-205, D-206, D-221, D-222, D-223</d_trace>
  </task>
</tasks>

<verification_markers>
Cache migration markers:
- `UX13_CACHE_VERSION2_WRITTEN=true`
- `UX13_CACHE_LEGACY_V1_SILENT=true`
- `UX13_CACHE_LEGACY_V1_REMOVED=true`
- `UX13_CACHE_TRUE_CORRUPTION_WARN=true`
- `UX13_CACHE_TRUE_CORRUPTION_WARN_RETAINED=true`
- `UX13_CACHE_MIGRATION_ALL_PASS=true`

Drawer filter markers:
- `UX13_DRAWER_FILTER_CONNECTION_ROOT=true`
- `UX13_DRAWER_FILTER_SOURCE_BADGE=true`
- `UX13_DRAWER_FILTER_MIXED_VISIBLE_CACHE=true`
- `UX13_DRAWER_FILTER_ZERO_RPC=true`
- `UX13_DRAWER_FILTER_RESTORE_OK=true`
- `UX13_DRAWER_FILTER_PERF_COLD_CONNECTION_ONLY=true`
- `UX13_DRAWER_FILTER_PERF_MIXED_VISIBLE_CACHE=true`
- `UX13_DRAWER_FILTER_ALL_PASS=true`

Wizard highlight markers:
- `UX13_WIZARD_WINHIGHLIGHT_MAIN=true`
- `UX13_WIZARD_WINHIGHLIGHT_PASSWORD=true`
- `UX13_WIZARD_WINHIGHLIGHT_INPUT=true`
- `UX13_WIZARD_WINHIGHLIGHT_SELECT=true`
- `UX13_WIZARD_WINHIGHLIGHT_MULTILINE=true`
- `UX13_WIZARD_BRIGHT_BASELINE_OK=true`
- `UX13_WIZARD_DARK_COLLISION_OK=true`
- `UX13_WIZARD_TEXT_RENDER_STATE_OK=true`
- `UX13_WIZARD_ALL_PASS=true`

Drawer perf fallback markers:
- `DRAW01_FILTER_COLD_CONNECTION_ONLY_10_SENTINEL_OK=true`
- `DRAW01_FILTER_COLD_CONNECTION_ONLY_100_SENTINEL_OK=true`
- `DRAW01_FILTER_COLD_CONNECTION_ONLY_1000_SENTINEL_OK=true`
- `DRAW01_FILTER_MIXED_VISIBLE_AND_CACHED_SENTINEL_OK=true`
- `DRAW01_FILTER_COLD_CONNECTION_ONLY_1000_P95_MS=<number>`
- `DRAW01_FILTER_MIXED_VISIBLE_AND_CACHED_P95_MS=<number>`
- `DRAW01_FILTER_COLD_CONNECTION_ONLY_1000_KB_DELTA=<number>`
- `DRAW01_FILTER_MIXED_VISIBLE_AND_CACHED_KB_DELTA=<number>`

Fail-closed Phase 13 rollup:
- `UX13_ALL_PASS=true` is valid only when every `UX13_*` sub-sentinel above is present and true, every required LSP11 marker in `<verification>` is present and true, existing Phase 4..11 rollups pass, and drawer/LSP perf rollups are either `true` or explicitly `unfrozen` in advisory mode. Any missing/false sub-sentinel makes `UX13_ALL_PASS=false` or absent.
</verification_markers>

<goal_backward_audit>
Target: "v1.1 wizard usable on dark colorschemes."
- D-201 locates the real wizard file.
- D-202/D-203 require explicit highlight mapping on every wizard-owned surface.
- Task `13-01-03` proves and applies that mapping without changing wizard behavior.
- Coverage closes with all detailed `UX13_WIZARD_*` markers and existing `DCFG02_WIZARD_ALL_PASS=true`.

Target: "drawer filter works on connection-only root and mixed visible/cache states."
- D-207 preserves Phase 4 submit/escape restore.
- D-208 preserves zero-RPC typing.
- D-209 through D-214 define visible-row and mixed-state fallback.
- Task `13-01-02` proves and implements the merged cached + visible-row corpus on every filter start.
- Coverage closes with detailed `UX13_DRAWER_FILTER_*` markers, `DRAW01_ALL_PASS=true`, `STRUCT01_FILTER_ZERO_RPC_OK=true`, and fallback perf markers.

Target: "v1.1 to v1.2 cache upgrade is silent when data is recognizable old format."
- D-215 writes version 2.
- D-216/D-217 classify recognizable missing-version files as legacy v1 and recover without WARN.
- D-218/D-219 keep real corruption diagnostic behavior, including malformed missing-version decoded JSON.
- Task `13-01-01` proves version write, recognizable legacy silent recovery, malformed missing-version WARN retention, and true-corruption WARN.
- Coverage closes with detailed `UX13_CACHE_*` markers plus existing Phase 11 disk-cache safety markers.
</goal_backward_audit>

<risk_register>
| Risk | Impact | Mitigation |
| --- | --- | --- |
| Wizard highlight mapping is too aggressive on light colorschemes. | Wizard text/borders could look wrong outside dark setup. | Use only standard float highlight groups; test default/bright baseline plus synthetic dark collision; leave unrelated drawer popups opt-in only. |
| Drawer filter returns false positives when a connection name matches a schema/table name. | Mixed results can show both visible connection and cached structure rows. | Preserve visible-row semantics because D-209 requires filtering whatever is visible; keep node IDs/type metadata intact so submit restores/refocuses correctly. |
| Cache migration deletes data that is actually corrupted. | A true corruption signal could be hidden as upgrade migration. | Silent delete applies only after legacy schema-index recognizer passes; malformed missing-version payloads WARN and remove safely. |
| Drawer fallback accidentally calls handler APIs while typing. | Regresses Phase 6 zero-RPC and perf guarantees. | Build fallback only from pre-filter rendered snapshot; assert fake handler call counts and `STRUCT01_FILTER_ZERO_RPC_OK=true`. |
| Visible-row enumeration slows `/` on large connection lists. | Primary navigation can regress for enterprise users with many connections. | Add advisory `FILTER_COLD_CONNECTION_ONLY_{10,100,1000}` and `FILTER_MIXED_VISIBLE_AND_CACHED` perf scenarios with median/p95/heap markers. |
| Optional menu `winhighlight` plumbing changes drawer prompt visuals. | Unrelated UI redesign in regression phase. | Do not set default in `menu.lua`; require wizard callers to pass mapping explicitly. |
</risk_register>

<verification>
Plan/document hygiene:
```bash
git diff --check
```

New Phase 13 headless gates:
```bash
make perf-bootstrap >/dev/null
NIO_DIR="$(make perf-bootstrap-print | awk -F= '/^NIO_NVIM_DIR=/{print $2}')"
nvim --headless -u NONE -i NONE -n --cmd "set rtp^=${NIO_DIR} | set rtp+=$(pwd)" -c "luafile ci/headless/check_lsp_disk_cache_safety.lua"
nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_drawer_filter.lua"
nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_connection_wizard.lua"
```

Required Phase 4..11 smoke and semantic gates:
```bash
nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_structure_lazy.lua"
nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_notes_picker.lua"
nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_connection_lifecycle.lua"
nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_connection_coordination.lua"
nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_filesource_persistence.lua"
nvim --headless -u NONE -i NONE -n --cmd "set rtp^=${NIO_DIR} | set rtp+=$(pwd)" -c "luafile ci/headless/check_lsp_alias_completion.lua"
nvim --headless -u NONE -i NONE -n --cmd "set rtp^=${NIO_DIR} | set rtp+=$(pwd)" -c "luafile ci/headless/check_lsp_schema_alias_completion.lua"
nvim --headless -u NONE -i NONE -n --cmd "set rtp^=${NIO_DIR} | set rtp+=$(pwd)" -c "luafile ci/headless/check_lsp_alias_rebinding.lua"
nvim --headless -u NONE -i NONE -n --cmd "set rtp^=${NIO_DIR} | set rtp+=$(pwd)" -c "luafile ci/headless/check_lsp_schema_cache_optimization.lua"
nvim --headless -u NONE -i NONE -n --cmd "set rtp^=${NIO_DIR} | set rtp+=$(pwd)" -c "luafile ci/headless/check_lsp_async_completion.lua"
nvim --headless -u NONE -i NONE -n --cmd "set rtp^=${NIO_DIR} | set rtp+=$(pwd)" -c "luafile ci/headless/check_lsp_diagnostics_correctness.lua"
nvim --headless -u NONE -i NONE -n --cmd "set rtp^=${NIO_DIR} | set rtp+=$(pwd)" -c "luafile ci/headless/check_lsp_diagnostics_debounce.lua"
```

Perf gates:
```bash
ART_DIR=$(mktemp -d)
LOG="$ART_DIR/draw01-stdout.log"
DRAW01_PERF_GATE_MODE=advisory DRAW01_PERF_ARTIFACT_DIR="$ART_DIR" DRAW01_PERF_SUMMARY_PATH="$ART_DIR/draw01-summary.txt" DRAW01_PERF_TRACE_PATH="$ART_DIR/draw01-trace.json" make perf PERF_PLATFORM=macos | tee "$LOG"
grep -q 'DRAW01_FILTER_COLD_CONNECTION_ONLY_1000_SENTINEL_OK=true' "$LOG"
grep -q 'DRAW01_FILTER_MIXED_VISIBLE_AND_CACHED_SENTINEL_OK=true' "$LOG"
grep -Eq 'DRAW01_REAL_NUI_PERF_ALL_PASS=(true|unfrozen)$' "$LOG"
! grep -q 'DRAW01_REAL_NUI_PERF_ALL_PASS=false' "$LOG"

ART_DIR=$(mktemp -d)
LOG="$ART_DIR/lsp01-stdout.log"
LSP01_PERF_GATE_MODE=advisory LSP01_PERF_ARTIFACT_DIR="$ART_DIR" LSP01_PERF_SUMMARY_PATH="$ART_DIR/lsp01-summary.txt" LSP01_PERF_TRACE_PATH="$ART_DIR/lsp01-trace.json" LSP01_PERF_STATE_HOME="$ART_DIR/state-home" make perf-lsp PERF_PLATFORM=macos | tee "$LOG"
grep -Eq 'LSP01_REAL_LSP_PERF_ALL_PASS=(true|unfrozen)$' "$LOG"
```

Drawer perf publishability rule:
```text
DRAW01_REAL_NUI_PERF_ALL_PASS=true means publishable/frozen drawer perf pass.
DRAW01_REAL_NUI_PERF_ALL_PASS=unfrozen means advisory-only pass; Phase 13 may ship with advisory fallback scenarios, but must record the caveat.
DRAW01_REAL_NUI_PERF_ALL_PASS=false fails Phase 13 verification.
New fallback scenarios remain advisory until the Phase 9 D-108 four-week >=95 percent pass-rate promotion rule is satisfied.
```

Fail-closed CI marker expectations:
```text
LSP01_SCENARIOS_COUNT=33
33 x LSP01_*_SENTINEL_OK=true
18 x LSP01_*_NO_STALE_CLIENTS=true
3 x LSP01_DIAGNOSTICS_DIDCHANGE_COMPUTE_ONLY=true
LSP01_REAL_LSP_PERF_ALL_PASS=true|unfrozen
DRAW01_REAL_NUI_PERF_ALL_PASS=true|unfrozen
DRAW01_ALL_PASS=true
STRUCT01_ALL_PASS=true
NOTES01_ALL_PASS=true
DCFG01_DRAWER_LIFECYCLE_ALL_PASS=true
DCFG01_COORDINATION_ALL_PASS=true
DCFG02_WIZARD_ALL_PASS=true
DCFG02_FILESOURCE_ALL_PASS=true
```

Required LSP11 marker families:
```text
LSP11_LRU_BOUND_HONORED=true
LSP11_DISK_LOAD_BOUNDED=true
LSP11_ASYNC_FAILURE_HANDLED=true
LSP11_ASYNC_PAYLOAD_ERROR_HANDLED=true
LSP11_ASYNC_MATERIALIZATION_PROBE_CHAIN_OK=true
LSP11_DIAGNOSTIC_NAMESPACE_OK=true
LSP11_DEBOUNCE_DIDCHANGE_OK=true
LSP11_DISK_DEFERRED_GENERATION_FENCED=true
LSP11_DISK_CORRUPT_RECOVERY_OK=true
LSP11_ASYNC_DEDUPE_MATERIALIZATION_AWARE=true
LSP11_DIAGNOSTICS_SINGLE_NAMESPACE_OWNED=true
LSP11_DISK_DISCOVERY_BOUNDED=true
LSP11_DISK_INDEX_CORRUPT_RECOVERY_OK=true
LSP11_DISK_INDEX_CROSS_FIELD_OK=true
LSP11_DISK_DEFERRED_PRUNE_DRAINED=true
LSP11_LSP_SYNC_DELIVERY_OK=true
LSP11_INCREMENTAL_GLOBAL_INDEX_OK=true
LSP11_DISK_DISCOVERY_ADVERSARIAL_OK=true
LSP11_INCREMENTAL_INDEX_EQUIVALENT=true
LSP11_ASYNC_SYNC_DELIVERY_OK=true
```

Required UX13 markers:
```text
UX13_CACHE_VERSION2_WRITTEN=true
UX13_CACHE_LEGACY_V1_SILENT=true
UX13_CACHE_LEGACY_V1_REMOVED=true
UX13_CACHE_TRUE_CORRUPTION_WARN=true
UX13_CACHE_TRUE_CORRUPTION_WARN_RETAINED=true
UX13_CACHE_MIGRATION_ALL_PASS=true
UX13_DRAWER_FILTER_CONNECTION_ROOT=true
UX13_DRAWER_FILTER_SOURCE_BADGE=true
UX13_DRAWER_FILTER_MIXED_VISIBLE_CACHE=true
UX13_DRAWER_FILTER_ZERO_RPC=true
UX13_DRAWER_FILTER_RESTORE_OK=true
UX13_DRAWER_FILTER_PERF_COLD_CONNECTION_ONLY=true
UX13_DRAWER_FILTER_PERF_MIXED_VISIBLE_CACHE=true
UX13_DRAWER_FILTER_ALL_PASS=true
UX13_WIZARD_WINHIGHLIGHT_MAIN=true
UX13_WIZARD_WINHIGHLIGHT_PASSWORD=true
UX13_WIZARD_WINHIGHLIGHT_INPUT=true
UX13_WIZARD_WINHIGHLIGHT_SELECT=true
UX13_WIZARD_WINHIGHLIGHT_MULTILINE=true
UX13_WIZARD_BRIGHT_BASELINE_OK=true
UX13_WIZARD_DARK_COLLISION_OK=true
UX13_WIZARD_TEXT_RENDER_STATE_OK=true
UX13_WIZARD_ALL_PASS=true
UX13_ALL_PASS=true
```
</verification>

<success_criteria>
- All D-198..D-223 locks are traced to at least one task.
- Phase 13 changes are limited to the three locked regression surfaces plus focused tests/perf evidence.
- Revision 2 closes all plan-gate r1 CRITICAL/HIGH findings.
- New UX13 markers prove wizard highlights, drawer visible-row filter fallback, fallback perf coverage, and cache migration UX.
- Existing Phase 4..11 smoke, semantic, and perf gates continue to pass with fail-closed LSP11 marker validation.
- The plan is ready for `$deep-review` plan-gate r2.
</success_criteria>
