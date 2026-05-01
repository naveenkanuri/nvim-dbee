---
phase: 11-lsp-optimization-correctness
plan: 01
revision: 3
type: execute
wave: 1
depends_on: [10]
files_modified:
  - ci/headless/perf_bootstrap.mk
  - ci/headless/lsp_perf_thresholds.lua
  - ci/headless/check_lsp_perf.lua
  - .github/workflows/test.yml
  - lua/dbee/config.lua
  - lua/dbee/lsp/schema_cache.lua
  - lua/dbee/lsp/init.lua
  - lua/dbee/lsp/server.lua
  - lua/dbee/lsp/context.lua
  - ci/headless/check_lsp_schema_cache_optimization.lua
  - ci/headless/check_lsp_disk_cache_safety.lua
  - ci/headless/check_lsp_async_completion.lua
  - ci/headless/check_lsp_diagnostics_correctness.lua
  - ci/headless/check_lsp_diagnostics_debounce.lua
  - ci/headless/check_lsp_alias_completion.lua
  - ci/headless/check_lsp_schema_alias_completion.lua
  - ci/headless/check_lsp_alias_rebinding.lua
  - README.md
  - doc/dbee.txt
autonomous: true
requirements: [LSP-OPT-01, LSP-CORR-01]
---

<objective>
Ship Phase 11 LSP production optimization and correctness fixes while preserving the Phase 10 perf evidence lane.

By the end of this plan, cold alias/table dot completion no longer calls synchronous `handler.connection_get_columns()` from `textDocument/completion`; missing columns warm through the existing `connection_get_columns_async()` / `structure_children_loaded` surface; `SchemaCache` has precomputed indexes, 500-table in-memory LRU, disk pruning, and atomic writes; LSP diagnostics are debounced/configurable and correct for multi-line/schema-qualified table references; Phase 10 LSP perf keeps passing with an added async miss scenario; and all new behavior is covered by deterministic headless checks.
</objective>

<execution_context>
@/Users/naveenkanuri/Documents/nvim-dbee/.codex/skills/gsd-plan-phase/SKILL.md
@/Users/naveenkanuri/Documents/nvim-dbee/.codex/get-shit-done/workflows/plan-phase.md
</execution_context>

<context>
@.planning/ROADMAP.md
@.planning/REQUIREMENTS.md
@.planning/milestones/v1.2-roadmap.md
@.planning/phases/11-lsp-optimization-correctness/11-CONTEXT.md
@.planning/phases/10-lsp-optimization/10-CONTEXT.md
@.planning/phases/10-lsp-optimization/10-PLAN.md
@.planning/phases/10-lsp-optimization/10-RESEARCH.md
@.planning/research/v12-lsp-opus-research.md
@.planning/phases/07-connection-only-drawer/07-CONTEXT.md
@.planning/phases/08-type-aware-connection-wizard/08-CONTEXT.md
@.planning/phases/09-real-nui-perf-harness/09-CONTEXT.md
</context>

<must_haves>
  <truths>
    - "Honor D-01..D-197 verbatim. Phase 11 may optimize and fix correctness, but it must not add Phase 12 feature surfaces."
    - "Keep in-process LSP and singleton-per-current-connection architecture. No standalone `sqls`, no out-of-process server, no multi-client/per-buffer connection refactor."
    - "Use `connection_get_columns_async()` plus `structure_children_loaded` for cold column misses. Do not wrap synchronous `connection_get_columns()` in coroutine/timer/nvim-nio code."
    - "Cold `column_of_table` completion miss returns promptly with empty items and `isIncomplete = true` only when an async miss is actually in flight."
    - "In-flight async column work dedupes by `(conn_id, schema, table_name, materialization, root_epoch)` and stale results are ignored on reconnect/source/database/root-epoch changes."
    - "Adopt pinned `nvim-nio` as a peer dependency. Pin: `21f5324bfac14e22ba26553caf69ec76ae8a7662` from `nvim-neotest/nvim-nio`."
    - "Cap in-memory `SchemaCache.columns` at 500 table entries with LRU-on-access; disk cache remains unbounded by count but prunes files older than 30 days."
    - "LSP diagnostics default to 250ms debounced `didChange`; save-only/off modes are user configurable; `didSave` remains immediate when diagnostics are not off."
    - "LSP diagnostics source is `dbee-lsp`, namespace is `dbee/lsp`, severity is WARN for unknown table/schema warnings. Adapter execution diagnostics remain separate."
    - "Phase 10 `COMPLETION_COLUMN_MISS_SYNC` evidence is preserved as historical baseline; active Phase 11 gates are `COMPLETION_COLUMN_MISS_ASYNC_FIRST`, `COMPLETION_COLUMN_MISS_ASYNC_WARM`, bounded large-disk startup cohorts, and compute-only didChange diagnostics timing."
    - "Existing LSP semantic checks continue to pass after migrating alias, schema-qualified alias, and alias-rebinding checks away from synchronous column fakes."
  </truths>
  <artifacts>
    - path: "ci/headless/perf_bootstrap.mk"
      provides: "shared pinned plugin bootstrap; gains pinned `nvim-nio` checkout and runtimepath"
      contains: "NIO_NVIM_COMMIT := 21f5324bfac14e22ba26553caf69ec76ae8a7662"
    - path: "lua/dbee/lsp/schema_cache.lua"
      provides: "cache indexes, LRU, disk persistence, async column miss state, and schema-aware lookup APIs"
      contains: "MAX_COLUMNS_IN_MEMORY = 500"
    - path: "lua/dbee/lsp/init.lua"
      provides: "event wiring for `structure_children_loaded`, current-connection invalidation, and active cache cancellation"
      contains: "connection_get_columns_async"
    - path: "lua/dbee/lsp/server.lua"
      provides: "completion result contract, debounce diagnostics, diagnostics parser, and LSP publish behavior"
      contains: "isIncomplete"
    - path: "lua/dbee/config.lua"
      provides: "default and validated `lsp` config"
      contains: "diagnostics_mode"
    - path: "ci/headless/check_lsp_perf.lua"
      provides: "Phase 10/11 real-LSP perf harness with split async miss scenarios and bounded large-disk startup scenario"
      contains: "COMPLETION_COLUMN_MISS_ASYNC_FIRST"
    - path: "ci/headless/lsp_perf_thresholds.lua"
      provides: "LSP01 threshold source with async miss and bounded large-disk advisory candidates"
      contains: "completion_column_miss_async_first"
    - path: ".github/workflows/test.yml"
      provides: "0.12.x headless lane, pinned nvim-nio runtimepath, new Phase 11 checks, and updated LSP perf marker validation"
      contains: "check_lsp_async_completion.lua"
  </artifacts>
  <key_links>
    - from: "lua/dbee/lsp/server.lua"
      to: "lua/dbee/lsp/schema_cache.lua"
      via: "`server.lua` calls async-aware cache APIs and consumes `{ items, isIncomplete }` semantics"
      pattern: "get_columns_async"
    - from: "lua/dbee/lsp/init.lua"
      to: "lua/dbee/lsp/schema_cache.lua"
      via: "`structure_children_loaded` events are routed to the active cache and stale payloads are dropped by epoch"
      pattern: "on_columns_loaded"
    - from: "ci/headless/perf_bootstrap.mk"
      to: "Makefile"
      via: "`PERF_RUNTIMEPATH_CMD` includes pinned `nvim-nio` for `make perf-lsp`"
      pattern: "NIO_NVIM_DIR"
    - from: ".github/workflows/test.yml"
      to: "ci/headless/perf_bootstrap.mk"
      via: "ordinary Lua headless checks clone/use the same pinned `nvim-nio` revision, and perf jobs keep using shared bootstrap"
      pattern: "NIO_NVIM_COMMIT"
    - from: "README.md"
      to: "doc/dbee.txt"
      via: "user-facing dependency/config docs are mirrored in generated vimdoc"
      pattern: "nvim-nio"
  </key_links>
</must_haves>

<constraints>
- Honor all D-01..D-197. Do not revise locked prior context documents during execution.
- No new LSP features: no hover, resolve, code actions, symbols, semantic tokens, inlay hints, or richer SQL validation.
- No multi-connection/per-buffer architecture changes and no `vim.lsp.config()` migration.
- No live database/RPC perf evidence. Tests use deterministic fake handlers and isolated state.
- Do not call synchronous `handler.connection_get_columns()` from completion fallback or async wrappers after Phase 11.
- Keep Phase 10 marker semantics and advisory-to-blocking threshold model. Additive Phase 11 markers must not self-certify.
- Use `apply_patch` or normal formatter/test commands during execution; do not rewrite unrelated files.
- Every task below is atomic commit-sized and should be committed as `chore(...)`, `feat(...)`, `fix(...)`, or `test(...)` with the task ID in the subject.
</constraints>

<interfaces>
New dependency pin:
```make
NIO_NVIM_REPO := https://github.com/nvim-neotest/nvim-nio
NIO_NVIM_COMMIT := 21f5324bfac14e22ba26553caf69ec76ae8a7662
NIO_NVIM_DIR := $(PERF_PLUGIN_ROOT)/nvim-nio
```

User config contract:
```lua
require("dbee").setup({
  lsp = {
    diagnostics_mode = "debounce_didchange", -- "debounce_didchange" | "save_only" | "off"
    diagnostics_debounce_ms = 250,
  },
})
```

Async completion contract:
```lua
-- Cache hit:
{ items = { ...columns... }, isIncomplete = false }

-- Cold miss with async request successfully queued:
{ items = {}, isIncomplete = true }

-- Unsupported async surface or unresolvable table:
{ items = {}, isIncomplete = false }
```

Async miss dedupe key:
```text
conn_id | schema | table_name | materialization | root_epoch
```

Phase 11 perf scenario:
```text
COMPLETION_COLUMN_MISS_ASYNC_FIRST
threshold_key = completion_column_miss_async_first
timed work: first cold request returns empty + isIncomplete=true + exactly one async request

COMPLETION_COLUMN_MISS_ASYNC_WARM
threshold_key = completion_column_miss_async_warm
timed work: post-structure_children_loaded completion request returns expected labels + isIncomplete=false

stale epoch payload: ignored
```

Built-in completion readiness contract:
```text
LSP11_ASYNC_AUTO_RETRIGGER_OK=true proves the operational pattern:
1. cold completion returns isIncomplete=true;
2. structure_children_loaded warms the cache;
3. a second built-in-client-compatible completion request, equivalent to Neovim retrying on the next completion trigger, returns complete columns with isIncomplete=false.
```

Async materialization probe contract:
```text
MATERIALIZATIONS = { "table", "view" }
first async probe: materialization = "table"
if structure_children_loaded returns empty columns without error: probe "view"
first non-empty success wins
all empty/error paths complete truthfully with isIncomplete=false
```

Large disk-cache startup scenarios:
```text
STARTUP_LARGE_DISK_CACHE_100
STARTUP_LARGE_DISK_CACHE_1000
STARTUP_LARGE_DISK_CACHE_10000
threshold_key = startup_large_disk_cache_<count>
synchronous column-file load cap = 100 most-recent column files
remaining prune/load work = scheduled outside startup/completion timing
```
</interfaces>

<task_graph>
## Wave 1 — Dependency, Config, And CI Substrate
- `11-01-01` pins `nvim-nio` in shared perf bootstrap.
- `11-01-02` adds LSP diagnostics config defaults/validation.
- `11-01-03` updates early CI runtime substrate for Neovim 0.12.x and pinned `nvim-nio` in ordinary Lua headless checks.
- `11-01-04` adds async miss and large-disk threshold slots.

## Wave 2 — Schema Cache Refactor
- `11-01-05` adds precomputed schema/table/column indexes and schema-aware lookup APIs.
- `11-01-06` adds 500-table in-memory LRU and disk pruning.
- `11-01-07` adds atomic disk writes, warning logs, and corrupt JSON recovery.
- `11-01-08` adds schema cache index/LRU test.
- `11-01-09` adds disk safety/pruning/corruption test.

## Wave 3 — Async Column Fetch And Completion Semantics
- `11-01-10` adds async column miss state/API in `SchemaCache`.
- `11-01-11` wires `structure_children_loaded` and invalidation cancellation in `init.lua`.
- `11-01-12` makes `server.lua` completion async-aware and truthful about `isIncomplete`.
- `11-01-13` migrates schema-qualified alias semantic check to async expectations.
- `11-01-23` migrates unqualified alias semantic check to Phase 11 cache-hit/async expectations.
- `11-01-24` migrates alias rebinding semantic check to Phase 11 cache-hit/async expectations.
- `11-01-14` adds async completion/dedupe/stale-cancel integration test.
- `11-01-15` extends Phase 10 perf harness with split async miss scenarios.
- `11-01-26` extends Phase 10 perf harness with bounded large-disk startup cohorts.

## Wave 4 — Diagnostics Correctness, Docs, And Final Gates
- `11-01-16` adds statement-range helpers in `context.lua` for diagnostics.
- `11-01-17` rewrites diagnostics parsing for multi-line/schema-aware correctness.
- `11-01-18` adds diagnostics debounce/config modes.
- `11-01-19` adds diagnostics correctness test.
- `11-01-20` adds diagnostics debounce/config test.
- `11-01-21` updates README user docs.
- `11-01-22` updates vimdoc mirror.
- `11-01-27` updates LSP perf diagnostics timing to preserve Phase 10 compute-only comparability.
- `11-01-25` adds final CI marker validation after all Phase 11 scripts and perf markers exist.

Dependency DAG:
```text
11-01-01 -> 11-01-03
11-01-02 -> 11-01-18 -> 11-01-20
11-01-04 -> 11-01-15 -> 11-01-26
11-01-05 -> 11-01-06 -> 11-01-07 -> 11-01-08,11-01-09
11-01-05 -> 11-01-10 -> 11-01-11 -> 11-01-12 -> 11-01-13,11-01-14,11-01-15,11-01-23,11-01-24
11-01-06,11-01-09 -> 11-01-26
11-01-16 -> 11-01-17 -> 11-01-18 -> 11-01-19,11-01-20
11-01-02 -> 11-01-18
11-01-15,11-01-18,11-01-26 -> 11-01-27
11-01-12,11-01-18 -> 11-01-21 -> 11-01-22
11-01-03,11-01-13,11-01-14,11-01-15,11-01-19,11-01-20,11-01-21,11-01-22,11-01-23,11-01-24,11-01-26,11-01-27 -> 11-01-25
```
</task_graph>

<measurement_protocol>
Phase 11 inherits Phase 10 `LSP01_*` rules:
- same `benchmark.nvim` runner, 5 warmups, 10 measured samples, platform authenticity gates, candidate/frozen state machine, and artifact upload policy;
- same Phase 10 existing scenario semantics for all scenarios except the cold column miss behavior that Phase 11 intentionally changes and the added large-disk startup cohorts;
- no per-run JSON baselines committed.

Async miss measurement extension:
- Add `COMPLETION_COLUMN_MISS_ASYNC_FIRST` and `COMPLETION_COLUMN_MISS_ASYNC_WARM` after `COMPLETION_COLUMN_HIT` in the completion scenario group.
- `COMPLETION_COLUMN_MISS_ASYNC_FIRST` timer starts immediately before `client:request("textDocument/completion", ...)` for the first cold request and stops in that callback after validating the result table.
- First measured request must return `items = {}` and `isIncomplete = true` while exactly one fake `connection_get_columns_async()` request is recorded.
- The harness then delivers a deterministic `structure_children_loaded` payload with matching `(conn_id, request_id, branch_id, root_epoch)` and waits for cache readiness outside the first-request timer.
- `COMPLETION_COLUMN_MISS_ASYNC_WARM` timer starts immediately before the second completion request after cache readiness and stops in that callback after validating expected labels such as `COL_001` and `COL_010` with `isIncomplete = false`.
- A stale payload with older `root_epoch` or retired connection ID is injected and must be ignored before the valid payload is delivered.
- Existing `COMPLETION_COLUMN_MISS_SYNC` threshold history remains in `ci/headless/lsp_perf_thresholds.lua`, but the active publishable Phase 11 gates are the split async scenarios. If the sync scenario remains in the script, it must be marked legacy/baseline-only and excluded from current-code pass/fail rollup.

Large disk-cache startup measurement extension:
- Add `STARTUP_LARGE_DISK_CACHE_100`, `STARTUP_LARGE_DISK_CACHE_1000`, and `STARTUP_LARGE_DISK_CACHE_10000`.
- Each cohort seeds the requested number of column cache files under isolated state, starts the production LSP lifecycle, and proves startup does not synchronously load/prune more than the first 100 most-recent column files.
- Timer excludes any scheduled deferred prune/load continuation; continuation work emits markers but does not contribute to startup median/p95.
- `LSP11_DISK_LOAD_BOUNDED=true` requires the sync file-load count to be `<=100`, old-file pruning to be scheduled outside completion timing, and no completion handler to run disk pruning.

Diagnostics measurement extension:
- Phase 10 `DIAGNOSTICS_DIDCHANGE_*` measurements remain comparable by measuring compute cost only: timer starts when the debounce callback fires and stops when diagnostics publish. The configured 250ms debounce wait is validated by semantic tests, not included in those Phase 10 threshold samples.
- Task `11-01-27` owns the required `ci/headless/check_lsp_perf.lua` change: current Phase 10 `client:notify(...)` timing must not survive for didChange samples after debounce lands.
- Each `DIAGNOSTICS_DIDCHANGE_*` scenario emits `LSP01_DIAGNOSTICS_DIDCHANGE_COMPUTE_ONLY=true`; that marker is required by the scenario sentinel and by final CI validation.
- Save-only/off behavior is tested in semantic checks, not in the perf sample set, unless the planner/executor chooses to add non-threshold markers.
- Diagnostics sentinels validate message text, source, severity, and ranges after timer stop.
</measurement_protocol>

<tasks>
  <task id="11-01-01" type="chore" wave="1" commit="chore(11-01-01): pin nvim-nio for lsp optimization">
    <depends_on>Phase 10 shipped.</depends_on>
    <files>ci/headless/perf_bootstrap.mk</files>
    <read_first>
      - ci/headless/perf_bootstrap.mk
      - .planning/phases/11-lsp-optimization-correctness/11-CONTEXT.md
      - .planning/phases/10-lsp-optimization/10-PLAN.md
    </read_first>
    <action>
      Add the pinned peer dependency checkout to the shared perf bootstrap:
      `NIO_NVIM_REPO := https://github.com/nvim-neotest/nvim-nio`,
      `NIO_NVIM_COMMIT := 21f5324bfac14e22ba26553caf69ec76ae8a7662`,
      `NIO_NVIM_DIR := $(PERF_PLUGIN_ROOT)/nvim-nio`.
      Update `PERF_RUNTIMEPATH_CMD` so `$(NIO_NVIM_DIR)` is prepended before repo code.
      Extend `perf-bootstrap` preflight to grep `NIO_NVIM_COMMIT`, clone/fetch/checkout the pin, and verify `rev-parse HEAD`.
      Extend `perf-bootstrap-print` with `NIO_NVIM_DIR=` and update `PERF_BOOTSTRAP_CONSUMERS=draw01,lsp01,lsp11`.
    </action>
    <acceptance_criteria>
      - `grep -n "NIO_NVIM_REPO := https://github.com/nvim-neotest/nvim-nio" ci/headless/perf_bootstrap.mk`
      - `grep -n "NIO_NVIM_COMMIT := 21f5324bfac14e22ba26553caf69ec76ae8a7662" ci/headless/perf_bootstrap.mk`
      - `grep -n 'NIO_NVIM_DIR.*PERF_RUNTIMEPATH_CMD' ci/headless/perf_bootstrap.mk`
      - `grep -n 'PERF_BOOTSTRAP_CONSUMERS=draw01,lsp01,lsp11' ci/headless/perf_bootstrap.mk`
    </acceptance_criteria>
    <d_trace>D-153, D-194</d_trace>
  </task>

  <task id="11-01-02" type="feat" wave="1" commit="feat(11-01-02): add lsp diagnostics config">
    <depends_on>None.</depends_on>
    <files>lua/dbee/config.lua</files>
    <read_first>
      - lua/dbee/config.lua
      - lua/dbee/api/state.lua
      - .planning/phases/11-lsp-optimization-correctness/11-CONTEXT.md
    </read_first>
    <action>
      Add `---@field lsp? lsp_config` to `Config`.
      Add `---@alias lsp_config { diagnostics_mode: "debounce_didchange"|"save_only"|"off", diagnostics_debounce_ms: integer }`.
      Add default config:
      `lsp = { diagnostics_mode = "debounce_didchange", diagnostics_debounce_ms = 250 }`.
      Validate `cfg.lsp` as a table, `cfg.lsp.diagnostics_mode` as a string, and `cfg.lsp.diagnostics_debounce_ms` as a number.
      Validation must reject diagnostics modes other than `debounce_didchange`, `save_only`, or `off`, and reject negative debounce values.
    </action>
    <acceptance_criteria>
      - `grep -n 'lsp_config' lua/dbee/config.lua`
      - `grep -n 'diagnostics_mode = "debounce_didchange"' lua/dbee/config.lua`
      - `grep -n 'diagnostics_debounce_ms = 250' lua/dbee/config.lua`
      - `grep -n 'save_only' lua/dbee/config.lua`
      - `grep -n 'off' lua/dbee/config.lua`
    </acceptance_criteria>
    <d_trace>D-168, D-169, D-170, D-171</d_trace>
  </task>

  <task id="11-01-03" type="chore" wave="1" commit="chore(11-01-03): prepare lsp ci runtime with pinned nio">
    <depends_on>11-01-01</depends_on>
    <files>.github/workflows/test.yml</files>
    <read_first>
      - .github/workflows/test.yml
      - ci/headless/perf_bootstrap.mk
      - ci/headless/check_lsp_alias_completion.lua
    </read_first>
    <action>
      Bump ordinary `lua-headless-regression` Neovim install to `env.NVIM_PERF_VERSION` (`v0.12.2`) so v1.2 LSP tests run on the supported floor.
      Install pinned `nvim-nio` for ordinary Lua headless checks by invoking the shared `perf-bootstrap` / `perf-bootstrap-print` surface from `ci/headless/perf_bootstrap.mk`; do not hardcode a second independent pin in workflow YAML.
      Add the printed `NIO_NVIM_DIR` to the ordinary headless `rtp` before `${GITHUB_WORKSPACE}`.
      Add placeholders or matrix entries for the new Phase 11 scripts only where the files already exist by the time the final CI validation task (`11-01-25`) runs.
      Leave LSP01 perf marker validation to task `11-01-25` to avoid the r1 dependency cycle.
    </action>
    <acceptance_criteria>
      - `grep -n 'NVIM_PERF_VERSION' .github/workflows/test.yml`
      - `grep -n 'nvim-neotest/nvim-nio' .github/workflows/test.yml`
      - `grep -n 'perf-bootstrap-print' .github/workflows/test.yml`
      - `grep -n 'NIO_NVIM_DIR' .github/workflows/test.yml`
    </acceptance_criteria>
    <d_trace>D-153, D-190, D-193, D-194</d_trace>
  </task>

  <task id="11-01-04" type="chore" wave="1" commit="chore(11-01-04): add phase 11 perf threshold slots">
    <depends_on>None.</depends_on>
    <files>ci/headless/lsp_perf_thresholds.lua</files>
    <read_first>
      - ci/headless/lsp_perf_thresholds.lua
      - .planning/phases/10-lsp-optimization/10-PLAN.md
      - .planning/phases/11-lsp-optimization-correctness/11-CONTEXT.md
    </read_first>
    <action>
      Add `completion_column_miss_async_first = seeded_p95(5, "phase11-advisory-seed")` and `completion_column_miss_async_warm = seeded_p95(15, "phase11-advisory-seed")` or stricter empirical candidate placeholders to both platform threshold tables through the shared `thresholds()` function.
      Add `startup_large_disk_cache_100`, `startup_large_disk_cache_1000`, and `startup_large_disk_cache_10000` advisory slots to both platform threshold tables.
      Keep `completion_column_miss_sync = seeded_p95(200)` present for historical Phase 10 evidence and do not delete any existing threshold key.
      Document in a comment that `completion_column_miss_sync` is Phase 10 historical baseline and the split async keys are the active Phase 11 cold-miss gates.
    </action>
    <acceptance_criteria>
      - `grep -n 'completion_column_miss_sync' ci/headless/lsp_perf_thresholds.lua`
      - `grep -n 'completion_column_miss_async_first' ci/headless/lsp_perf_thresholds.lua`
      - `grep -n 'completion_column_miss_async_warm' ci/headless/lsp_perf_thresholds.lua`
      - `grep -n 'startup_large_disk_cache_10000' ci/headless/lsp_perf_thresholds.lua`
      - `grep -n 'Phase 10 historical' ci/headless/lsp_perf_thresholds.lua`
    </acceptance_criteria>
    <d_trace>D-184, D-185, D-186, D-187</d_trace>
  </task>

  <task id="11-01-05" type="feat" wave="2" commit="feat(11-01-05): precompute schema cache indexes">
    <depends_on>None.</depends_on>
    <files>lua/dbee/lsp/schema_cache.lua</files>
    <read_first>
      - lua/dbee/lsp/schema_cache.lua
      - lua/dbee/lsp/server.lua
      - .planning/phases/11-lsp-optimization-correctness/11-CONTEXT.md
    </read_first>
    <action>
      Add private index state to `SchemaCache`: `schema_items`, `table_items_by_schema`, `all_table_items`, `column_items_by_key`, `schema_lookup`, `table_lookup_by_schema`, and `table_lookup_global`.
      Replace `_build_name_list()` with structure-index helpers such as `_rebuild_structure_indexes()` for schema/table mutations and `_update_column_index(schema, table)` / `_drop_column_index(key)` for per-table column mutations.
      Do not rebuild schema/table indexes after a single async column payload lands; update only that table's column-item array.
      Add public read APIs for precomputed arrays: `get_schema_completion_items()`, `get_table_completion_items(schema)`, `get_all_table_completion_items()`, `get_column_completion_items(schema, table)`, `find_schema(schema_name)`, and `find_table_in_schema(schema_name, table_name)`.
      Completion item getter APIs return caller-owned arrays or documented read-only arrays that `server.lua` copies before composing; cache-owned arrays must not be mutated by `vim.list_extend`.
      Preserve existing APIs `get_schemas()`, `get_tables()`, `get_all_table_names()`, `get_cached_columns()`, and `find_table()` for compatibility, but implement them through or alongside the new indexes.
      Ensure schema/table lookup is case-insensitive and deterministic for duplicates.
    </action>
    <acceptance_criteria>
      - `grep -n 'function SchemaCache:_rebuild_structure_indexes' lua/dbee/lsp/schema_cache.lua`
      - `grep -n 'function SchemaCache:_update_column_index' lua/dbee/lsp/schema_cache.lua`
      - `grep -n 'schema_lookup' lua/dbee/lsp/schema_cache.lua`
      - `grep -n 'table_lookup_by_schema' lua/dbee/lsp/schema_cache.lua`
      - `grep -n 'function SchemaCache:find_table_in_schema' lua/dbee/lsp/schema_cache.lua`
      - `grep -n 'function SchemaCache:get_all_table_completion_items' lua/dbee/lsp/schema_cache.lua`
    </acceptance_criteria>
    <d_trace>D-165, D-166, D-167, D-177, D-178</d_trace>
  </task>

  <task id="11-01-06" type="feat" wave="2" commit="feat(11-01-06): bound lsp column cache with lru">
    <depends_on>11-01-05</depends_on>
    <files>lua/dbee/lsp/schema_cache.lua</files>
    <read_first>
      - lua/dbee/lsp/schema_cache.lua
      - .planning/phases/11-lsp-optimization-correctness/11-CONTEXT.md
    </read_first>
    <action>
      Add `MAX_COLUMNS_IN_MEMORY = 500`.
      Track LRU state with a monotonically increasing touch counter and per-table key touch map.
      Touch a column entry on `get_columns` cache hit, disk-load insertion, and async-load completion.
      Evict least-recently-used in-memory column entries after insertion when the cap exceeds 500.
      Do not delete disk cache files during LRU eviction.
      Add `SYNC_COLUMN_FILE_LOAD_LIMIT = 100`: `load_from_disk()` may synchronously load at most the 100 most-recent column files for the connection, then schedules any remaining disk-load/prune work outside startup/completion timing.
      Add disk pruning helper that deletes LSP column cache files older than 30 days through bounded scheduled work after startup or first cache startup access; pruning must never run from `textDocument/completion`.
      Expose a test-visible stats method such as `get_stats()` returning `column_entry_count`, `column_evictions`, `disk_pruned`, `sync_column_files_loaded`, and `deferred_column_files_scheduled`.
    </action>
    <acceptance_criteria>
      - `grep -n 'MAX_COLUMNS_IN_MEMORY = 500' lua/dbee/lsp/schema_cache.lua`
      - `grep -n 'SYNC_COLUMN_FILE_LOAD_LIMIT = 100' lua/dbee/lsp/schema_cache.lua`
      - `grep -n 'column_evictions' lua/dbee/lsp/schema_cache.lua`
      - `grep -n 'column_entry_count' lua/dbee/lsp/schema_cache.lua`
      - `grep -n 'disk_pruned' lua/dbee/lsp/schema_cache.lua`
      - `grep -n '30 \\* 24 \\* 60 \\* 60' lua/dbee/lsp/schema_cache.lua`
      - `grep -n 'touch' lua/dbee/lsp/schema_cache.lua`
    </acceptance_criteria>
    <d_trace>D-162, D-163, D-164, D-167</d_trace>
  </task>

  <task id="11-01-07" type="fix" wave="2" commit="fix(11-01-07): make lsp disk cache writes atomic">
    <depends_on>11-01-05</depends_on>
    <files>lua/dbee/lsp/schema_cache.lua</files>
    <read_first>
      - lua/dbee/lsp/schema_cache.lua
      - .planning/phases/08-type-aware-connection-wizard/08-CONTEXT.md
      - lua/dbee/utils.lua
    </read_first>
    <action>
      Replace direct `io.open(path, "w")` writes in `save_to_disk()` and `_save_columns_to_disk()` with a same-directory temp file, write, flush/close, then `os.rename(tmp, path)`.
      On encode/write/close/rename failure, leave the existing cache file untouched and call `vim.notify(message, vim.log.levels.WARN)` with the path and operation.
      On JSON parse failure in `load_from_disk()` or `_load_columns_from_disk()`, call `vim.notify(..., WARN)`, delete the corrupt file with `os.remove(path)` when safe, and continue with refresh/fallback instead of crashing.
      Ensure temp files are removed after failed writes.
    </action>
    <acceptance_criteria>
      - `grep -n 'os.rename' lua/dbee/lsp/schema_cache.lua`
      - `grep -n 'vim.log.levels.WARN' lua/dbee/lsp/schema_cache.lua`
      - `grep -n 'os.remove' lua/dbee/lsp/schema_cache.lua`
      - `grep -n 'corrupt' lua/dbee/lsp/schema_cache.lua`
    </acceptance_criteria>
    <d_trace>D-180, D-181, D-182, D-183</d_trace>
  </task>

  <task id="11-01-08" type="test" wave="2" commit="test(11-01-08): cover schema cache indexes and lru">
    <depends_on>11-01-05, 11-01-06</depends_on>
    <files>ci/headless/check_lsp_schema_cache_optimization.lua</files>
    <read_first>
      - lua/dbee/lsp/schema_cache.lua
      - ci/headless/check_lsp_perf.lua
      - ci/headless/check_lsp_alias_completion.lua
    </read_first>
    <action>
      Create a headless test that builds deterministic schema data with duplicate table names across schemas.
      Assert schema/table completion arrays are sorted and reused through public index APIs.
      Assert repeated completion API calls do not mutate or grow cache-owned precomputed arrays.
      Assert `find_table_in_schema("wrong_schema", "valid_table")` returns no table when the table exists only in another schema.
      Insert 501 column-cache entries, touch one old entry, insert one more, and assert `cache:get_stats().column_entry_count <= 500` (or `vim.tbl_count(cache:get_cached_columns()) <= 500`), `column_evictions > 0`, the expected evicted key is absent, and the touched key survives.
      Assert async column payload handling updates only the affected table's column index and does not rescan all 10k table indexes.
      Emit markers:
      `LSP11_SCHEMA_INDEX_SORTED=true`,
      `LSP11_SCHEMA_LOOKUP_SCHEMA_AWARE=true`,
      `LSP11_LRU_EVICTION_COUNT=<n>`,
      `LSP11_LRU_EVICTION_OK=true`,
      `LSP11_LRU_BOUND_HONORED=true`,
      `LSP11_COMPLETION_INDEX_IMMUTABLE=true`,
      `LSP11_INDEX_INCREMENTAL_OK=true`.
    </action>
    <acceptance_criteria>
      - `test -f ci/headless/check_lsp_schema_cache_optimization.lua`
      - `grep -n 'LSP11_SCHEMA_INDEX_SORTED=true' ci/headless/check_lsp_schema_cache_optimization.lua`
      - `grep -n 'LSP11_SCHEMA_LOOKUP_SCHEMA_AWARE=true' ci/headless/check_lsp_schema_cache_optimization.lua`
      - `grep -n 'LSP11_LRU_EVICTION_OK=true' ci/headless/check_lsp_schema_cache_optimization.lua`
      - `grep -n 'LSP11_LRU_BOUND_HONORED=true' ci/headless/check_lsp_schema_cache_optimization.lua`
      - `grep -n 'LSP11_COMPLETION_INDEX_IMMUTABLE=true' ci/headless/check_lsp_schema_cache_optimization.lua`
      - `grep -n 'LSP11_INDEX_INCREMENTAL_OK=true' ci/headless/check_lsp_schema_cache_optimization.lua`
    </acceptance_criteria>
    <d_trace>D-162, D-164, D-165, D-166, D-167, D-177, D-178, D-192</d_trace>
  </task>

  <task id="11-01-09" type="test" wave="2" commit="test(11-01-09): cover lsp disk cache safety">
    <depends_on>11-01-06, 11-01-07</depends_on>
    <files>ci/headless/check_lsp_disk_cache_safety.lua</files>
    <read_first>
      - lua/dbee/lsp/schema_cache.lua
      - ci/headless/check_lsp_perf.lua
    </read_first>
    <action>
      Create a headless test that runs with an isolated `XDG_STATE_HOME` or temp `stdpath("state")` setup.
      Assert successful writes leave valid JSON files and no temp file residue.
      Pre-create an original cache file, simulate a rename/write failure if feasible by monkey-patching the local helper boundary or using an invalid temp path, and assert the original file remains unchanged.
      Write corrupt JSON for table cache and column cache, call load, assert no crash, warning capture occurred, corrupt file was removed, and cache falls back empty.
      Create old column cache files with mtime older than 30 days and assert prune count increments only after scheduled bounded prune work runs.
      Seed 10,000 column files, call `load_from_disk()`, and assert synchronous load count is `<= 100`, deferred work is scheduled, and no completion request triggers disk pruning.
      Emit markers:
      `LSP11_ATOMIC_WRITE_OK=true`,
      `LSP11_CORRUPT_CACHE_RECOVERED=true`,
      `LSP11_DISK_PRUNE_COUNT=<n>`,
      `LSP11_DISK_CACHE_ISOLATED=true`,
      `LSP11_DISK_LOAD_BOUNDED=true`.
    </action>
    <acceptance_criteria>
      - `test -f ci/headless/check_lsp_disk_cache_safety.lua`
      - `grep -n 'LSP11_ATOMIC_WRITE_OK=true' ci/headless/check_lsp_disk_cache_safety.lua`
      - `grep -n 'LSP11_CORRUPT_CACHE_RECOVERED=true' ci/headless/check_lsp_disk_cache_safety.lua`
      - `grep -n 'LSP11_DISK_PRUNE_COUNT' ci/headless/check_lsp_disk_cache_safety.lua`
      - `grep -n 'LSP11_DISK_CACHE_ISOLATED=true' ci/headless/check_lsp_disk_cache_safety.lua`
      - `grep -n 'LSP11_DISK_LOAD_BOUNDED=true' ci/headless/check_lsp_disk_cache_safety.lua`
    </acceptance_criteria>
    <d_trace>D-163, D-180, D-181, D-182, D-183, D-192</d_trace>
  </task>

  <task id="11-01-10" type="feat" wave="3" commit="feat(11-01-10): add async column miss state to schema cache">
    <depends_on>11-01-05, 11-01-06</depends_on>
    <files>lua/dbee/lsp/schema_cache.lua</files>
    <read_first>
      - lua/dbee/lsp/schema_cache.lua
      - lua/dbee/handler/init.lua
      - .planning/phases/07-connection-only-drawer/07-CONTEXT.md
    </read_first>
    <action>
      Require `nio` for future/event orchestration.
      Add `get_columns_async(schema, table_name, opts)` or equivalent async-aware API that returns cached columns immediately when present and otherwise queues one `connection_get_columns_async()` request.
      Build the dedupe key from `conn_id`, resolved schema, table name, materialization, and `root_epoch`.
      Store in-flight entries with request id, branch id, root epoch, future/waiters, and status.
      Preserve bounded materialization fallback with `MATERIALIZATIONS = { "table", "view" }`: first async probe uses `materialization = "table"`; if the matching `structure_children_loaded` payload returns empty columns without `error`, queue the next materialization probe (`"view"`); first non-empty success wins; all-empty completion marks the chain complete with `isIncomplete=false`.
      Wrap the handler async queue call in `pcall` (or equivalent success check). Mark an entry in-flight only after the async surface call succeeds; if the surface is absent or throws, remove the entry, clean waiters, and return a non-incomplete cache-only result.
      Add `on_columns_loaded(data)` to accept `structure_children_loaded` payloads with `kind = "columns"` and matching request/branch/epoch, update `self.columns`, touch LRU, update only that table's column index, save columns to disk atomically, resolve waiters, and mark the future done.
      If `data.error` is present, clear/reject the matching in-flight entry, resolve waiters, record a failed/empty result for that root epoch, and ensure subsequent completion returns `{ items = {}, isIncomplete = false }` until the next root-epoch bump or invalidation.
      Add `cancel_async(reason, opts)` or equivalent to reject/ignore all in-flight entries on invalidation/connection change.
      Preserve legacy `get_columns()` for non-completion callers if still needed, but completion must not call it for misses after task `11-01-12`.
    </action>
    <acceptance_criteria>
      - `grep -n 'require("nio")\\|require("nio' lua/dbee/lsp/schema_cache.lua`
      - `grep -n 'function SchemaCache:get_columns_async' lua/dbee/lsp/schema_cache.lua`
      - `grep -n 'connection_get_columns_async' lua/dbee/lsp/schema_cache.lua`
      - `grep -n 'function SchemaCache:on_columns_loaded' lua/dbee/lsp/schema_cache.lua`
      - `grep -n 'function SchemaCache:cancel_async' lua/dbee/lsp/schema_cache.lua`
      - `grep -n 'pcall.*connection_get_columns_async\\|connection_get_columns_async.*pcall' lua/dbee/lsp/schema_cache.lua`
      - `grep -n 'MATERIALIZATIONS.*table.*view\\|table.*view.*MATERIALIZATIONS' lua/dbee/lsp/schema_cache.lua`
      - `grep -n 'data.error' lua/dbee/lsp/schema_cache.lua`
      - `grep -n 'root_epoch' lua/dbee/lsp/schema_cache.lua`
    </acceptance_criteria>
    <d_trace>D-153, D-154, D-155, D-156, D-158, D-159, D-160, D-161, D-162, D-167, D-192, D-194</d_trace>
  </task>

  <task id="11-01-11" type="feat" wave="3" commit="feat(11-01-11): route async column events through lsp lifecycle">
    <depends_on>11-01-10</depends_on>
    <files>lua/dbee/lsp/init.lua</files>
    <read_first>
      - lua/dbee/lsp/init.lua
      - lua/dbee/lsp/schema_cache.lua
      - lua/dbee/handler/init.lua
      - .planning/phases/07-connection-only-drawer/07-CONTEXT.md
    </read_first>
    <action>
      Register a `structure_children_loaded` event listener in `register_events()` for LSP column payloads.
      Route matching current-connection payloads to `M._cache:on_columns_loaded(data)` and ignore stale or non-current payloads.
      On `current_connection_changed`, `database_selected`, eventful `connection_invalidated`, `stop()`, and cache invalidate/restart paths, call `M._cache:cancel_async(...)` before dropping/rebuilding cache state.
      Use handler `get_authoritative_root_epoch(conn_id)` as the root epoch source for async miss requests.
      Preserve D-77/D-78/D-87 behavior: do not add a second root structure single-flight, do not transport-cancel handler flights, and clean waiter slots on teardown.
    </action>
    <acceptance_criteria>
      - `grep -n 'structure_children_loaded' lua/dbee/lsp/init.lua`
      - `grep -n 'on_columns_loaded' lua/dbee/lsp/init.lua`
      - `grep -n 'cancel_async' lua/dbee/lsp/init.lua`
      - `grep -n 'get_authoritative_root_epoch' lua/dbee/lsp/init.lua`
      - `grep -n 'teardown_structure_consumer' lua/dbee/lsp/init.lua`
    </acceptance_criteria>
    <d_trace>D-151, D-154, D-158, D-159, D-160, D-161, D-192</d_trace>
  </task>

  <task id="11-01-12" type="feat" wave="3" commit="feat(11-01-12): make lsp completion async-aware">
    <depends_on>11-01-05, 11-01-10, 11-01-11</depends_on>
    <files>lua/dbee/lsp/server.lua</files>
    <read_first>
      - lua/dbee/lsp/server.lua
      - lua/dbee/lsp/schema_cache.lua
      - lua/dbee/lsp/context.lua
    </read_first>
    <action>
      Change completion helpers to return `{ items = table, isIncomplete = boolean }` instead of only item arrays.
      Replace per-request schema/table completion construction with `SchemaCache` precomputed completion item APIs.
      Copy cache-owned completion arrays before composing response items unless the cache API already returns caller-owned copies.
      Change `column_completions()` so cache hits return column items with `isIncomplete=false`; cold async miss with queued/in-flight request returns `{}` and `isIncomplete=true`; unresolvable/missing async surface returns `{}` and `isIncomplete=false`.
      Ensure `textDocument/completion` callback forwards the truthful `isIncomplete` from `get_completions()`.
      Add a defensive grep-visible guard/comment near completion miss code that `connection_get_columns()` must not be called from completion.
      Keep `CompletionItemKind` and existing labels/details compatible with current users.
    </action>
    <acceptance_criteria>
      - `grep -n 'isIncomplete' lua/dbee/lsp/server.lua`
      - `grep -n 'get_columns_async' lua/dbee/lsp/server.lua`
      - `grep -n 'get_all_table_completion_items' lua/dbee/lsp/server.lua`
      - `grep -n 'deepcopy\\|copy' lua/dbee/lsp/server.lua`
      - `! grep -n 'connection_get_columns' lua/dbee/lsp/server.lua`
      - `grep -n 'resolveProvider = false' lua/dbee/lsp/server.lua`
    </acceptance_criteria>
    <d_trace>D-155, D-156, D-157, D-160, D-161, D-165, D-166, D-167, D-188, D-189</d_trace>
  </task>

  <task id="11-01-13" type="test" wave="3" commit="test(11-01-13): update schema alias check for async miss">
    <depends_on>11-01-12</depends_on>
    <files>ci/headless/check_lsp_schema_alias_completion.lua</files>
    <read_first>
      - ci/headless/check_lsp_schema_alias_completion.lua
      - lua/dbee/lsp/server.lua
      - lua/dbee/lsp/schema_cache.lua
    </read_first>
    <action>
      Replace the synchronous `connection_get_columns` fake with a fake `connection_get_columns_async` plus controlled `structure_children_loaded` delivery.
      Monkey-patch any synchronous `connection_get_columns` fake to fail loudly if production completion calls it.
      Update assertions so first `d.` / `p.` request for an uncached schema-qualified alias returns no labels and `isIncomplete=true`.
      Deliver deterministic columns, issue a second request, and assert expected labels are present with `isIncomplete=false`.
      Add a view-only schema-qualified alias fixture: the first table materialization probe returns empty, the bounded view probe returns columns, and warm completion returns the view columns.
      Emit existing `LSP_SCHEMA_ALIAS_*` markers plus new markers:
      `LSP_SCHEMA_ALIAS_FIRST_INCOMPLETE=true`,
      `LSP_SCHEMA_ALIAS_ASYNC_CALLS=<n>`,
      `LSP_SCHEMA_ALIAS_WARM_LABELS=true`,
      `LSP_SCHEMA_ALIAS_NO_SYNC_FETCH=true`,
      `LSP_SCHEMA_ALIAS_VIEW_FALLBACK_OK=true`.
    </action>
    <acceptance_criteria>
      - `grep -n 'connection_get_columns_async' ci/headless/check_lsp_schema_alias_completion.lua`
      - `grep -n 'LSP_SCHEMA_ALIAS_FIRST_INCOMPLETE=true' ci/headless/check_lsp_schema_alias_completion.lua`
      - `grep -n 'LSP_SCHEMA_ALIAS_ASYNC_CALLS' ci/headless/check_lsp_schema_alias_completion.lua`
      - `grep -n 'LSP_SCHEMA_ALIAS_NO_SYNC_FETCH=true' ci/headless/check_lsp_schema_alias_completion.lua`
      - `grep -n 'LSP_SCHEMA_ALIAS_VIEW_FALLBACK_OK=true' ci/headless/check_lsp_schema_alias_completion.lua`
      - `! grep -n 'connection_get_columns = function' ci/headless/check_lsp_schema_alias_completion.lua`
    </acceptance_criteria>
    <d_trace>D-154, D-156, D-157, D-188, D-189, D-193</d_trace>
  </task>

  <task id="11-01-23" type="test" wave="3" commit="test(11-01-23): migrate alias completion check to async contract">
    <depends_on>11-01-12</depends_on>
    <files>ci/headless/check_lsp_alias_completion.lua</files>
    <read_first>
      - ci/headless/check_lsp_alias_completion.lua
      - lua/dbee/lsp/server.lua
      - lua/dbee/lsp/schema_cache.lua
    </read_first>
    <action>
      Replace synchronous `get_columns()` fake behavior with Phase 11-safe fixtures.
      Cover the cache-hit path by pre-populating column cache entries for the queried tables so alias completion returns labels immediately with `isIncomplete=false`.
      Cover the cold async path by issuing a first `sp.` request that returns empty items with `isIncomplete=true`, delivering deterministic `structure_children_loaded`, then issuing a second built-in-compatible completion request that returns warmed labels with `isIncomplete=false`.
      Monkey-patch `connection_get_columns` to fail loudly if production completion calls it.
      Preserve existing `LSP_ALIAS_*` markers and add:
      `LSP_ALIAS_FIRST_INCOMPLETE=true`,
      `LSP_ALIAS_WARM_LABELS=true`,
      `LSP_ALIAS_NO_SYNC_FETCH=true`.
    </action>
    <acceptance_criteria>
      - `grep -n 'connection_get_columns_async' ci/headless/check_lsp_alias_completion.lua`
      - `grep -n 'LSP_ALIAS_FIRST_INCOMPLETE=true' ci/headless/check_lsp_alias_completion.lua`
      - `grep -n 'LSP_ALIAS_WARM_LABELS=true' ci/headless/check_lsp_alias_completion.lua`
      - `grep -n 'LSP_ALIAS_NO_SYNC_FETCH=true' ci/headless/check_lsp_alias_completion.lua`
    </acceptance_criteria>
    <d_trace>D-154, D-156, D-157, D-188, D-189, D-193</d_trace>
  </task>

  <task id="11-01-24" type="test" wave="3" commit="test(11-01-24): migrate alias rebinding check to async contract">
    <depends_on>11-01-12</depends_on>
    <files>ci/headless/check_lsp_alias_rebinding.lua</files>
    <read_first>
      - ci/headless/check_lsp_alias_rebinding.lua
      - lua/dbee/lsp/server.lua
      - lua/dbee/lsp/schema_cache.lua
    </read_first>
    <action>
      Replace synchronous `get_columns()` fake behavior with Phase 11-safe fixtures.
      Cover rebinding cache-hit behavior by pre-populating columns for both rebound tables and asserting each statement returns the current alias target with `isIncomplete=false`.
      Cover one cold rebinding request by asserting first incomplete, delivering `structure_children_loaded`, retriggering completion, and asserting warm labels match the latest alias binding.
      Monkey-patch `connection_get_columns` to fail loudly if production completion calls it.
      Preserve existing `LSP_REBIND_*` markers and add:
      `LSP_REBIND_FIRST_INCOMPLETE=true`,
      `LSP_REBIND_WARM_LABELS=true`,
      `LSP_REBIND_NO_SYNC_FETCH=true`.
    </action>
    <acceptance_criteria>
      - `grep -n 'connection_get_columns_async' ci/headless/check_lsp_alias_rebinding.lua`
      - `grep -n 'LSP_REBIND_FIRST_INCOMPLETE=true' ci/headless/check_lsp_alias_rebinding.lua`
      - `grep -n 'LSP_REBIND_WARM_LABELS=true' ci/headless/check_lsp_alias_rebinding.lua`
      - `grep -n 'LSP_REBIND_NO_SYNC_FETCH=true' ci/headless/check_lsp_alias_rebinding.lua`
    </acceptance_criteria>
    <d_trace>D-154, D-156, D-157, D-188, D-189, D-193</d_trace>
  </task>

  <task id="11-01-14" type="test" wave="3" commit="test(11-01-14): cover async completion contract">
    <depends_on>11-01-10, 11-01-11, 11-01-12</depends_on>
    <files>ci/headless/check_lsp_async_completion.lua</files>
    <read_first>
      - lua/dbee/lsp/init.lua
      - lua/dbee/lsp/server.lua
      - lua/dbee/lsp/schema_cache.lua
      - ci/headless/check_lsp_schema_alias_completion.lua
    </read_first>
    <action>
      Create a headless test that has a production-event lane and a direct-client lane.
      Production-event lane installs fake `dbee.api.state` before requiring `dbee.lsp`, calls `dbee.lsp.register_events()`, starts the active LSP cache through production lifecycle, triggers the real `structure_children_loaded` event via the state/handler dispatch path, and verifies warm completion through the active cache.
      Direct-client lane may use `vim.lsp.start({ cmd = server.create(cache) })` only for isolated server response assertions that do not claim to test `init.lua` event routing.
      Use a fake handler implementing `connection_get_columns_async`, `get_authoritative_root_epoch`, and current connection methods.
      Assert first cold alias dot completion returns `isIncomplete=true`, zero items, and exactly one async request.
      Assert duplicate requests before payload delivery do not issue another async request.
      Assert absent `connection_get_columns_async` surface and throwing async surface both return empty results with `isIncomplete=false` and leave no in-flight entry.
      Deliver a matching `structure_children_loaded` payload with `data.error = "permission denied"` and assert the in-flight entry is cleared, waiters resolve, and the next completion returns empty items with `isIncomplete=false`.
      Deliver a stale payload with older root epoch and assert no columns are cached.
      Deliver the valid payload and assert the next request returns `COL_001` and `COL_010` with `isIncomplete=false`.
      Exercise the bounded materialization probe chain with a view-only schema-qualified alias: table probe returns empty, view probe returns columns, first success wins, and the chain stops without unbounded retries.
      Validate the built-in-client-compatible auto-retrigger pattern: cold completion returns `isIncomplete=true`; `structure_children_loaded` warms the cache; the next completion trigger returns complete labels with `isIncomplete=false`.
      Simulate reconnect/source invalidation by bumping epoch and calling the cancellation path; assert late old payload does not resolve.
      Emit markers:
      `LSP11_ASYNC_FIRST_INCOMPLETE=true`,
      `LSP11_ASYNC_DEDUPE_OK=true`,
      `LSP11_ASYNC_STALE_DROPPED=true`,
      `LSP11_ASYNC_WARM_LABELS=true`,
      `LSP11_ASYNC_NO_SYNC_FETCH=true`,
      `LSP11_ASYNC_FAILURE_HANDLED=true`,
      `LSP11_ASYNC_PAYLOAD_ERROR_HANDLED=true`,
      `LSP11_ASYNC_MATERIALIZATION_PROBE_CHAIN_OK=true`,
      `LSP11_ASYNC_EVENT_WIRING_OK=true`,
      `LSP11_ASYNC_AUTO_RETRIGGER_OK=true`.
    </action>
    <acceptance_criteria>
      - `test -f ci/headless/check_lsp_async_completion.lua`
      - `grep -n 'LSP11_ASYNC_FIRST_INCOMPLETE=true' ci/headless/check_lsp_async_completion.lua`
      - `grep -n 'LSP11_ASYNC_DEDUPE_OK=true' ci/headless/check_lsp_async_completion.lua`
      - `grep -n 'LSP11_ASYNC_STALE_DROPPED=true' ci/headless/check_lsp_async_completion.lua`
      - `grep -n 'LSP11_ASYNC_NO_SYNC_FETCH=true' ci/headless/check_lsp_async_completion.lua`
      - `grep -n 'LSP11_ASYNC_FAILURE_HANDLED=true' ci/headless/check_lsp_async_completion.lua`
      - `grep -n 'LSP11_ASYNC_PAYLOAD_ERROR_HANDLED=true' ci/headless/check_lsp_async_completion.lua`
      - `grep -n 'LSP11_ASYNC_MATERIALIZATION_PROBE_CHAIN_OK=true' ci/headless/check_lsp_async_completion.lua`
      - `grep -n 'LSP11_ASYNC_EVENT_WIRING_OK=true' ci/headless/check_lsp_async_completion.lua`
      - `grep -n 'LSP11_ASYNC_AUTO_RETRIGGER_OK=true' ci/headless/check_lsp_async_completion.lua`
    </acceptance_criteria>
    <d_trace>D-153, D-154, D-155, D-156, D-157, D-158, D-159, D-160, D-161, D-192, D-193</d_trace>
  </task>

  <task id="11-01-15" type="test" wave="3" commit="test(11-01-15): add split async miss lsp perf scenarios">
    <depends_on>11-01-04, 11-01-12, 11-01-14</depends_on>
    <files>ci/headless/check_lsp_perf.lua</files>
    <read_first>
      - ci/headless/check_lsp_perf.lua
      - ci/headless/lsp_perf_thresholds.lua
      - lua/dbee/lsp/server.lua
      - lua/dbee/lsp/schema_cache.lua
    </read_first>
    <action>
      Add `COMPLETION_COLUMN_MISS_ASYNC_FIRST` to the completion scenario registry with `threshold_key = "completion_column_miss_async_first"` and corpus `tables:100,context:column-miss-async-first,alias:t`.
      Add `COMPLETION_COLUMN_MISS_ASYNC_WARM` to the completion scenario registry with `threshold_key = "completion_column_miss_async_warm"` and corpus `tables:100,context:column-miss-async-warm,alias:t`.
      Implement sentinel checks for first request incomplete, one async request, duplicate miss dedupe, stale payload drop, warm labels, no synchronous fetch call, and auto-retrigger-compatible second request.
      Emit markers:
      `LSP01_COMPLETION_COLUMN_MISS_ASYNC_FIRST_SENTINEL_OK=true|false`,
      `LSP01_COMPLETION_COLUMN_MISS_ASYNC_FIRST_INCOMPLETE=true|false`,
      `LSP01_COMPLETION_COLUMN_MISS_ASYNC_FIRST_ASYNC_CALLS=1`,
      `LSP01_COMPLETION_COLUMN_MISS_ASYNC_WARM_SENTINEL_OK=true|false`,
      `LSP01_COMPLETION_COLUMN_MISS_ASYNC_WARM_LABELS=true|false`,
      `LSP01_COMPLETION_COLUMN_MISS_ASYNC_STALE_DROPPED=true|false`,
      `LSP01_COMPLETION_COLUMN_MISS_ASYNC_AUTO_RETRIGGER_OK=true|false`.
      Preserve `COMPLETION_COLUMN_MISS_SYNC` code/threshold history as a legacy/baseline fixture. If the sync fixture is not compatible with current production code, exclude it from active publishable rollup and emit `LSP01_COMPLETION_COLUMN_MISS_SYNC_LEGACY_STATUS=historical`.
      Update scenario count and final verification count to match the active registry exactly.
    </action>
    <acceptance_criteria>
      - `grep -n 'COMPLETION_COLUMN_MISS_ASYNC_FIRST' ci/headless/check_lsp_perf.lua`
      - `grep -n 'COMPLETION_COLUMN_MISS_ASYNC_WARM' ci/headless/check_lsp_perf.lua`
      - `grep -n 'completion_column_miss_async_first' ci/headless/check_lsp_perf.lua`
      - `grep -n 'completion_column_miss_async_warm' ci/headless/check_lsp_perf.lua`
      - `grep -n 'LSP01_COMPLETION_COLUMN_MISS_ASYNC_FIRST_INCOMPLETE' ci/headless/check_lsp_perf.lua`
      - `grep -n 'LSP01_COMPLETION_COLUMN_MISS_ASYNC_STALE_DROPPED' ci/headless/check_lsp_perf.lua`
      - `grep -n 'COMPLETION_COLUMN_MISS_SYNC' ci/headless/check_lsp_perf.lua`
    </acceptance_criteria>
    <d_trace>D-152, D-184, D-185, D-186, D-187, D-192, D-193</d_trace>
  </task>

  <task id="11-01-26" type="test" wave="3" commit="test(11-01-26): add bounded large disk startup perf cohorts">
    <depends_on>11-01-04, 11-01-06, 11-01-09</depends_on>
    <files>ci/headless/check_lsp_perf.lua</files>
    <read_first>
      - ci/headless/check_lsp_perf.lua
      - ci/headless/lsp_perf_thresholds.lua
      - lua/dbee/lsp/schema_cache.lua
    </read_first>
    <action>
      Add `STARTUP_LARGE_DISK_CACHE_100`, `STARTUP_LARGE_DISK_CACHE_1000`, and `STARTUP_LARGE_DISK_CACHE_10000` to the startup scenario registry with threshold keys `startup_large_disk_cache_100`, `startup_large_disk_cache_1000`, and `startup_large_disk_cache_10000`.
      Each scenario seeds the requested number of deterministic column cache files under isolated state, then times production startup through the same lifecycle as Phase 10 startup cohorts.
      Assert synchronous column-file load count is bounded by `SYNC_COLUMN_FILE_LOAD_LIMIT = 100`, deferred prune/load work is scheduled outside the timed startup window, and completion handlers do not run disk pruning.
      Emit markers:
      `LSP01_STARTUP_LARGE_DISK_CACHE_100_SENTINEL_OK=true|false`,
      `LSP01_STARTUP_LARGE_DISK_CACHE_1000_SENTINEL_OK=true|false`,
      `LSP01_STARTUP_LARGE_DISK_CACHE_10000_SENTINEL_OK=true|false`,
      `LSP01_STARTUP_LARGE_DISK_CACHE_SYNC_LOAD_COUNT=<n>`,
      `LSP11_DISK_LOAD_BOUNDED=true|false`.
    </action>
    <acceptance_criteria>
      - `grep -n 'STARTUP_LARGE_DISK_CACHE_100' ci/headless/check_lsp_perf.lua`
      - `grep -n 'STARTUP_LARGE_DISK_CACHE_1000' ci/headless/check_lsp_perf.lua`
      - `grep -n 'STARTUP_LARGE_DISK_CACHE_10000' ci/headless/check_lsp_perf.lua`
      - `grep -n 'startup_large_disk_cache_10000' ci/headless/check_lsp_perf.lua`
      - `grep -n 'LSP11_DISK_LOAD_BOUNDED' ci/headless/check_lsp_perf.lua`
    </acceptance_criteria>
    <d_trace>D-152, D-163, D-184, D-185, D-186, D-192, D-193</d_trace>
  </task>

  <task id="11-01-16" type="feat" wave="4" commit="feat(11-01-16): expose statement ranges for lsp diagnostics">
    <depends_on>None.</depends_on>
    <files>lua/dbee/lsp/context.lua</files>
    <read_first>
      - lua/dbee/lsp/context.lua
      - lua/dbee/lsp/server.lua
    </read_first>
    <action>
      Add a helper such as `M.statement_text_with_map(text)` or `M.extract_statements(text)` that splits SQL text into statement chunks while preserving absolute line/character offsets.
      The helper must support incomplete statements and multi-line `FROM`/`JOIN` references.
      Keep existing `context.analyze(params)` behavior unchanged for completion.
      Export the helper from `context.lua` for diagnostics use in `server.lua`.
    </action>
    <acceptance_criteria>
      - `grep -n 'extract_statements\\|statement_text_with_map' lua/dbee/lsp/context.lua`
      - `grep -n 'line' lua/dbee/lsp/context.lua`
      - `grep -n 'character' lua/dbee/lsp/context.lua`
      - `grep -n 'function M.analyze' lua/dbee/lsp/context.lua`
    </acceptance_criteria>
    <d_trace>D-172, D-175, D-176, D-196</d_trace>
  </task>

  <task id="11-01-17" type="fix" wave="4" commit="fix(11-01-17): make lsp table diagnostics statement-aware">
    <depends_on>11-01-05, 11-01-16</depends_on>
    <files>lua/dbee/lsp/server.lua</files>
    <read_first>
      - lua/dbee/lsp/server.lua
      - lua/dbee/lsp/context.lua
      - lua/dbee/lsp/schema_cache.lua
    </read_first>
    <action>
      Replace line-only `compute_diagnostics()` scanning with statement-aware scanning using the context helper from task `11-01-16`.
      Match `FROM` and all `JOIN` occurrences independently with each match's absolute start/end positions.
      For qualified `schema.table`, call `cache:find_table_in_schema(schema, table)` and warn when that exact schema/table is absent.
      For unqualified table names, call case-insensitive global `cache:find_table(table)`.
      Preserve diagnostic source `dbee-lsp`, severity Warning, and message formats `Unknown table: <table>` / `Unknown table: <schema>.<table>`.
      Do not add unknown-column, syntax, ambiguous-table, or parser diagnostics.
    </action>
    <acceptance_criteria>
      - `grep -n 'find_table_in_schema' lua/dbee/lsp/server.lua`
      - `grep -n 'Unknown table: %s.%s' lua/dbee/lsp/server.lua`
      - `grep -n 'context.*statement\\|extract_statements\\|statement_text_with_map' lua/dbee/lsp/server.lua`
      - `! grep -n 'line:find(kw, 1, true)' lua/dbee/lsp/server.lua`
    </acceptance_criteria>
    <d_trace>D-173, D-174, D-175, D-176, D-177, D-178, D-179, D-192</d_trace>
  </task>

  <task id="11-01-18" type="feat" wave="4" commit="feat(11-01-18): debounce lsp diagnostics">
    <depends_on>11-01-02, 11-01-17</depends_on>
    <files>lua/dbee/lsp/server.lua</files>
    <read_first>
      - lua/dbee/lsp/server.lua
      - lua/dbee/config.lua
      - lua/dbee/api/state.lua
    </read_first>
    <action>
      Read LSP diagnostics config from `require("dbee.api.state").config().lsp`, defaulting to `diagnostics_mode = "debounce_didchange"` and `diagnostics_debounce_ms = 250` if config is unavailable.
      For `textDocument/didChange`, debounce diagnostics by buffer URI when mode is `debounce_didchange`.
      For `textDocument/didSave`, publish diagnostics immediately when mode is not `off`.
      For `save_only`, ignore `didChange` diagnostics and keep immediate `didSave`.
      For `off`, suppress diagnostics and publish an empty diagnostic list for the URI when appropriate.
      Create and own `local DIAGNOSTIC_NS = vim.api.nvim_create_namespace("dbee/lsp")`.
      Resolve diagnostic URI to bufnr and call `vim.diagnostic.set(DIAGNOSTIC_NS, bufnr, diagnostics)` for LSP table-reference diagnostics; keep the existing `dispatchers.notification or dispatchers.on_notify` compatibility path only where needed for in-process client compatibility.
      Clear `DIAGNOSTIC_NS` for attached buffers on `off`, `stop()`, reconnect/current-connection change, and source/database invalidation where appropriate.
      Clean debounce timers on shutdown/exit/terminate.
    </action>
    <acceptance_criteria>
      - `grep -n 'diagnostics_mode' lua/dbee/lsp/server.lua`
      - `grep -n 'diagnostics_debounce_ms' lua/dbee/lsp/server.lua`
      - `grep -n 'debounce_didchange' lua/dbee/lsp/server.lua`
      - `grep -n 'save_only' lua/dbee/lsp/server.lua`
      - `grep -n 'create_namespace(\"dbee/lsp\")' lua/dbee/lsp/server.lua`
      - `grep -n 'vim.diagnostic.set' lua/dbee/lsp/server.lua`
      - `grep -n 'dispatchers.notification or dispatchers.on_notify' lua/dbee/lsp/server.lua`
    </acceptance_criteria>
    <d_trace>D-168, D-169, D-170, D-171, D-172, D-173, D-174, D-192</d_trace>
  </task>

  <task id="11-01-19" type="test" wave="4" commit="test(11-01-19): cover lsp diagnostic correctness">
    <depends_on>11-01-17, 11-01-18</depends_on>
    <files>ci/headless/check_lsp_diagnostics_correctness.lua</files>
    <read_first>
      - lua/dbee/lsp/server.lua
      - lua/dbee/lsp/context.lua
      - lua/dbee/lsp/schema_cache.lua
    </read_first>
    <action>
      Create a headless test that uses real `server.create(cache)` and publishDiagnostics capture.
      Build cache with `VALID_SCHEMA.VALID_TABLE`, `OTHER_SCHEMA.VALID_TABLE`, and one valid join table.
      Assert multi-line `FROM\n  MISSING_TABLE` produces one warning with expected line/range.
      Assert one-line SQL with multiple joins reports the second missing join at the second join's actual column, not the first join.
      Assert `WRONG_SCHEMA.VALID_TABLE` warns even when `VALID_TABLE` exists in another schema.
      Assert diagnostics source is `dbee-lsp` and severity is Warning.
      Resolve `vim.api.nvim_create_namespace("dbee/lsp")`, call `vim.diagnostic.get(bufnr, { namespace = ns })`, and assert the expected diagnostics are present in that namespace.
      Call `dbee.lsp.stop()` or the server stop path and assert diagnostics in `dbee/lsp` namespace are cleared.
      Emit markers:
      `LSP11_DIAGNOSTICS_MULTILINE_FROM_OK=true`,
      `LSP11_DIAGNOSTICS_MULTI_JOIN_RANGE_OK=true`,
      `LSP11_DIAGNOSTICS_SCHEMA_AWARE_OK=true`,
      `LSP11_DIAGNOSTICS_SOURCE_WARN_OK=true`,
      `LSP11_DIAGNOSTIC_NAMESPACE_OK=true`.
    </action>
    <acceptance_criteria>
      - `test -f ci/headless/check_lsp_diagnostics_correctness.lua`
      - `grep -n 'LSP11_DIAGNOSTICS_MULTILINE_FROM_OK=true' ci/headless/check_lsp_diagnostics_correctness.lua`
      - `grep -n 'LSP11_DIAGNOSTICS_MULTI_JOIN_RANGE_OK=true' ci/headless/check_lsp_diagnostics_correctness.lua`
      - `grep -n 'LSP11_DIAGNOSTICS_SCHEMA_AWARE_OK=true' ci/headless/check_lsp_diagnostics_correctness.lua`
      - `grep -n 'LSP11_DIAGNOSTICS_SOURCE_WARN_OK=true' ci/headless/check_lsp_diagnostics_correctness.lua`
      - `grep -n 'LSP11_DIAGNOSTIC_NAMESPACE_OK=true' ci/headless/check_lsp_diagnostics_correctness.lua`
    </acceptance_criteria>
    <d_trace>D-173, D-174, D-175, D-176, D-177, D-178, D-179, D-192</d_trace>
  </task>

  <task id="11-01-20" type="test" wave="4" commit="test(11-01-20): cover lsp diagnostic modes">
    <depends_on>11-01-02, 11-01-18</depends_on>
    <files>ci/headless/check_lsp_diagnostics_debounce.lua</files>
    <read_first>
      - lua/dbee/lsp/server.lua
      - lua/dbee/config.lua
      - ci/headless/check_lsp_diagnostics_correctness.lua
    </read_first>
    <action>
      Create a headless test with a fake `dbee.api.state.config()` provider for each diagnostics mode.
      For `debounce_didchange`, send rapid didChange notifications and assert only one publish occurs after the configured debounce window.
      For `save_only`, assert didChange publishes zero diagnostics and didSave publishes immediately.
      For `off`, assert didChange and didSave publish no schema warnings, any clearing publish contains an empty diagnostics list, and the `dbee/lsp` namespace is empty for the attached buffer.
      Assert timers are cleaned up after shutdown/exit.
      Emit markers:
      `LSP11_DEBOUNCE_DIDCHANGE_OK=true`,
      `LSP11_DIDSAVE_IMMEDIATE_OK=true`,
      `LSP11_SAVE_ONLY_OK=true`,
      `LSP11_DIAGNOSTICS_OFF_OK=true`,
      `LSP11_DEBOUNCE_CLEANUP_OK=true`.
    </action>
    <acceptance_criteria>
      - `test -f ci/headless/check_lsp_diagnostics_debounce.lua`
      - `grep -n 'LSP11_DEBOUNCE_DIDCHANGE_OK=true' ci/headless/check_lsp_diagnostics_debounce.lua`
      - `grep -n 'LSP11_DIDSAVE_IMMEDIATE_OK=true' ci/headless/check_lsp_diagnostics_debounce.lua`
      - `grep -n 'LSP11_SAVE_ONLY_OK=true' ci/headless/check_lsp_diagnostics_debounce.lua`
      - `grep -n 'LSP11_DIAGNOSTICS_OFF_OK=true' ci/headless/check_lsp_diagnostics_debounce.lua`
    </acceptance_criteria>
    <d_trace>D-168, D-169, D-170, D-171, D-172, D-174, D-192</d_trace>
  </task>

  <task id="11-01-21" type="chore" wave="4" commit="chore(11-01-21): document lsp optimization behavior">
    <depends_on>11-01-02, 11-01-12, 11-01-18</depends_on>
    <files>README.md</files>
    <read_first>
      - README.md
      - lua/dbee/config.lua
      - .planning/phases/11-lsp-optimization-correctness/11-CONTEXT.md
    </read_first>
    <action>
      Update install docs to say `requires nvim>=0.12`.
      Add `nvim-neotest/nvim-nio` as a dependency in both packer and lazy examples.
      Add config docs showing:
      `lsp = { diagnostics_mode = "debounce_didchange", diagnostics_debounce_ms = 250 }`.
      Add a short upgrade note: cold schema-qualified alias/table dot completion now returns promptly with incomplete results while columns warm asynchronously; retry/trigger completion after warmup returns full columns.
      Preserve the existing `cmp-dbee` mention as an alternate/custom completion stack and do not deprecate it.
      Do not add a CHANGELOG task because this repo currently has no `CHANGELOG` file.
    </action>
    <acceptance_criteria>
      - `grep -n 'requires nvim>=0.12' README.md`
      - `grep -n 'nvim-neotest/nvim-nio' README.md`
      - `grep -n 'diagnostics_mode = "debounce_didchange"' README.md`
      - `grep -n 'diagnostics_debounce_ms = 250' README.md`
      - `grep -n 'cold.*completion.*async\\|asynchronously' README.md`
      - `grep -n 'cmp-dbee' README.md`
    </acceptance_criteria>
    <d_trace>D-153, D-168, D-169, D-188, D-189, D-190, D-191</d_trace>
  </task>

  <task id="11-01-22" type="chore" wave="4" commit="chore(11-01-22): sync vimdoc for lsp config">
    <depends_on>11-01-21</depends_on>
    <files>doc/dbee.txt</files>
    <read_first>
      - doc/dbee.txt
      - README.md
      - lua/dbee/config.lua
    </read_first>
    <action>
      Mirror the README/config updates in `doc/dbee.txt`: Neovim `0.12` requirement, `nvim-nio` dependency in install examples, LSP diagnostics config defaults, cold completion async behavior note, and existing `cmp-dbee` alternate completion mention.
      If the repo's docgen tooling is available during execution, use it; otherwise edit the vimdoc directly with the same text.
    </action>
    <acceptance_criteria>
      - `grep -n 'requires nvim>=0.12' doc/dbee.txt`
      - `grep -n 'nvim-neotest/nvim-nio' doc/dbee.txt`
      - `grep -n 'diagnostics_mode = "debounce_didchange"' doc/dbee.txt`
      - `grep -n 'diagnostics_debounce_ms = 250' doc/dbee.txt`
      - `grep -n 'cold.*completion.*async\\|asynchronously' doc/dbee.txt`
      - `grep -n 'cmp-dbee' doc/dbee.txt`
    </acceptance_criteria>
    <d_trace>D-153, D-168, D-169, D-188, D-189, D-190</d_trace>
  </task>

  <task id="11-01-27" type="test" wave="4" commit="test(11-01-27): preserve compute-only diagnostics perf timing">
    <depends_on>11-01-15, 11-01-18, 11-01-26</depends_on>
    <files>ci/headless/check_lsp_perf.lua</files>
    <read_first>
      - ci/headless/check_lsp_perf.lua
      - lua/dbee/lsp/server.lua
      - .planning/phases/10-lsp-optimization/10-PLAN.md
    </read_first>
    <action>
      Update the LSP01 diagnostics timing path so `DIAGNOSTICS_DIDCHANGE_*` samples remain Phase 10-comparable compute-cost measurements after debounce is introduced.
      For didChange diagnostics, do not start timing before `client:notify("textDocument/didChange", ...)`; instead, start timing at the debounce-fire boundary or the synchronous diagnostic compute entry point, and stop timing at `vim.diagnostic.set(DIAGNOSTIC_NS, bufnr, diagnostics)` / publish completion.
      Preserve didSave timing as immediate notification-to-publish measurement because didSave is not debounced.
      Emit `LSP01_DIAGNOSTICS_DIDCHANGE_COMPUTE_ONLY=true|false` once per active didChange diagnostic scenario (`100`, `1000`, `10000`).
      Each `DIAGNOSTICS_DIDCHANGE_*` scenario's `LSP01_<SCENARIO>_SENTINEL_OK=true` requires `LSP01_DIAGNOSTICS_DIDCHANGE_COMPUTE_ONLY=true`; any false compute-only marker fails the 33-scenario sentinel gate.
    </action>
    <acceptance_criteria>
      - `grep -n 'LSP01_DIAGNOSTICS_DIDCHANGE_COMPUTE_ONLY' ci/headless/check_lsp_perf.lua`
      - `grep -n 'debounce.*compute\\|compute.*debounce' ci/headless/check_lsp_perf.lua`
      - `grep -n 'DIAGNOSTICS_DIDCHANGE_10000' ci/headless/check_lsp_perf.lua`
    </acceptance_criteria>
    <d_trace>D-152, D-168, D-186, D-192, D-193</d_trace>
  </task>

  <task id="11-01-25" type="chore" wave="4" commit="chore(11-01-25): wire final phase 11 ci marker validation">
    <depends_on>11-01-03, 11-01-13, 11-01-14, 11-01-15, 11-01-19, 11-01-20, 11-01-21, 11-01-22, 11-01-23, 11-01-24, 11-01-26, 11-01-27</depends_on>
    <files>.github/workflows/test.yml</files>
    <read_first>
      - .github/workflows/test.yml
      - ci/headless/check_lsp_perf.lua
      - .planning/phases/10-lsp-optimization/10-PLAN.md
    </read_first>
    <action>
      Add all final Phase 11 headless scripts to the ordinary Lua headless matrix: `check_lsp_schema_cache_optimization.lua`, `check_lsp_disk_cache_safety.lua`, `check_lsp_async_completion.lua`, `check_lsp_diagnostics_correctness.lua`, and `check_lsp_diagnostics_debounce.lua`.
      Keep perf dependency ownership in `make perf-bootstrap` and do not duplicate `nvim-nio` pin ownership in the workflow.
      Update `lua-lsp-perf-advisory` marker validation after artifact upload to assert exact Phase 11 active counts: `LSP01_SCENARIOS_COUNT=33`, exactly 33 `LSP01_<SCENARIO>_SENTINEL_OK=true`, zero false scenario sentinels, exactly 18 active direct-client `NO_STALE_CLIENTS=true` markers, and non-false `LSP01_REAL_LSP_PERF_ALL_PASS`.
      Assert exactly three `LSP01_DIAGNOSTICS_DIDCHANGE_COMPUTE_ONLY=true` markers and zero false compute-only markers.
      Validate split async markers, bounded large-disk markers, legacy sync marker, and key `LSP11_*` semantic markers in the job logs.
      Artifact upload remains `if: always()` and marker validation remains a separate step after upload.
    </action>
    <acceptance_criteria>
      - `grep -n 'check_lsp_async_completion.lua' .github/workflows/test.yml`
      - `grep -n 'check_lsp_diagnostics_debounce.lua' .github/workflows/test.yml`
      - `grep -n 'LSP01_SCENARIOS_COUNT=33' .github/workflows/test.yml`
      - `grep -n 'COMPLETION_COLUMN_MISS_ASYNC_FIRST' .github/workflows/test.yml`
      - `grep -n 'COMPLETION_COLUMN_MISS_ASYNC_WARM' .github/workflows/test.yml`
      - `grep -n 'STARTUP_LARGE_DISK_CACHE_10000' .github/workflows/test.yml`
      - `grep -n 'LSP01_DIAGNOSTICS_DIDCHANGE_COMPUTE_ONLY' .github/workflows/test.yml`
      - `grep -n 'LSP11_ASYNC_AUTO_RETRIGGER_OK' .github/workflows/test.yml`
      - `grep -n 'LSP11_ASYNC_PAYLOAD_ERROR_HANDLED' .github/workflows/test.yml`
      - `grep -n 'LSP11_ASYNC_MATERIALIZATION_PROBE_CHAIN_OK' .github/workflows/test.yml`
      - `grep -n 'LSP11_DIAGNOSTIC_NAMESPACE_OK' .github/workflows/test.yml`
    </acceptance_criteria>
    <d_trace>D-152, D-153, D-185, D-186, D-190, D-193, D-194</d_trace>
  </task>
</tasks>

<traceability>
| Decision | Task coverage |
| --- | --- |
| D-150 | 11-01-21, scope guards |
| D-151 | 11-01-11, 11-01-14, verification |
| D-152 | 11-01-15, 11-01-25, 11-01-26, 11-01-27, verification |
| D-153 | 11-01-01, 11-01-03, 11-01-10, 11-01-14, 11-01-21, 11-01-22, 11-01-25 |
| D-154 | 11-01-10, 11-01-11, 11-01-12, 11-01-13, 11-01-14, 11-01-23, 11-01-24 |
| D-155 | 11-01-10, 11-01-12, 11-01-14 |
| D-156 | 11-01-10, 11-01-12, 11-01-13, 11-01-14, 11-01-15, 11-01-23, 11-01-24 |
| D-157 | 11-01-12, 11-01-13, 11-01-14, 11-01-21, 11-01-23, 11-01-24 |
| D-158 | 11-01-10, 11-01-11, 11-01-14 |
| D-159 | 11-01-10, 11-01-11, 11-01-14 |
| D-160 | 11-01-10, 11-01-11, 11-01-12, 11-01-14 |
| D-161 | 11-01-10, 11-01-12, 11-01-14 |
| D-162 | 11-01-06, 11-01-08 |
| D-163 | 11-01-06, 11-01-09, 11-01-26 |
| D-164 | 11-01-06, 11-01-08 |
| D-165 | 11-01-05, 11-01-08, 11-01-12 |
| D-166 | 11-01-05, 11-01-08, 11-01-12 |
| D-167 | 11-01-05, 11-01-06, 11-01-08, 11-01-10, 11-01-12 |
| D-168 | 11-01-02, 11-01-18, 11-01-20, 11-01-21, 11-01-27 |
| D-169 | 11-01-02, 11-01-18, 11-01-20, 11-01-21 |
| D-170 | 11-01-02, 11-01-18, 11-01-20 |
| D-171 | 11-01-02, 11-01-18, 11-01-20 |
| D-172 | 11-01-16, 11-01-18, 11-01-20 |
| D-173 | 11-01-17, 11-01-18, 11-01-19 |
| D-174 | 11-01-17, 11-01-18, 11-01-19, 11-01-20 |
| D-175 | 11-01-16, 11-01-17, 11-01-19 |
| D-176 | 11-01-16, 11-01-17, 11-01-19 |
| D-177 | 11-01-05, 11-01-17, 11-01-19 |
| D-178 | 11-01-05, 11-01-17, 11-01-19 |
| D-179 | 11-01-17, 11-01-19 |
| D-180 | 11-01-07, 11-01-09 |
| D-181 | 11-01-07, 11-01-09 |
| D-182 | 11-01-07, 11-01-09 |
| D-183 | 11-01-07, 11-01-09 |
| D-184 | 11-01-04, 11-01-15 |
| D-185 | 11-01-04, 11-01-15 |
| D-186 | 11-01-04, 11-01-15, 11-01-25, 11-01-26, 11-01-27 |
| D-187 | 11-01-04, 11-01-15 |
| D-188 | 11-01-12, 11-01-21, 11-01-22 |
| D-189 | 11-01-12, 11-01-13, 11-01-21, 11-01-22 |
| D-190 | 11-01-03, 11-01-21, 11-01-22, 11-01-25 |
| D-191 | verification |
| D-192 | 11-01-08, 11-01-09, 11-01-14, 11-01-19, 11-01-20, 11-01-23, 11-01-24, 11-01-26, 11-01-27 |
| D-193 | 11-01-03, 11-01-13, 11-01-14, 11-01-15, 11-01-23, 11-01-24, 11-01-25, 11-01-26, 11-01-27, verification |
| D-194 | 11-01-01, 11-01-03, 11-01-10, 11-01-25 |
| D-195 | already completed in discuss; requirements verified here |
| D-196 | all implementation tasks |
| D-197 | 11-01-12, 11-01-14, 11-01-15 risk register |
</traceability>

<verification_markers>
Inherited Phase 10 LSP markers remain authoritative:
- `LSP01_PERF_MODE=real-lsp`
- `LSP01_SCENARIOS_COUNT=33`
- `LSP01_<SCENARIO>_SENTINEL_OK=true|false`
- `LSP01_LINUX_PERF_THRESHOLD_<SCENARIO>_{MEDIAN_MS,P95_MS,MEDIAN_CANDIDATE_MS,P95_CANDIDATE_MS,STATUS,PASS}`
- `LSP01_MACOS_PERF_THRESHOLD_<SCENARIO>_{MEDIAN_MS,P95_MS,MEDIAN_CANDIDATE_MS,P95_CANDIDATE_MS,STATUS,PASS}`
- `LSP01_{LINUX|MACOS}_PERF_THRESHOLD_PASS=true|false|unfrozen`
- `LSP01_REAL_LSP_PERF_ALL_PASS=true|false|unfrozen`

New/changed Phase 11 LSP perf markers:
- `LSP01_COMPLETION_COLUMN_MISS_ASYNC_FIRST_MEDIAN_MS=`
- `LSP01_COMPLETION_COLUMN_MISS_ASYNC_FIRST_P95_MS=`
- `LSP01_COMPLETION_COLUMN_MISS_ASYNC_FIRST_SENTINEL_OK=true|false`
- `LSP01_COMPLETION_COLUMN_MISS_ASYNC_FIRST_INCOMPLETE=true|false`
- `LSP01_COMPLETION_COLUMN_MISS_ASYNC_FIRST_ASYNC_CALLS=1`
- `LSP01_COMPLETION_COLUMN_MISS_ASYNC_WARM_MEDIAN_MS=`
- `LSP01_COMPLETION_COLUMN_MISS_ASYNC_WARM_P95_MS=`
- `LSP01_COMPLETION_COLUMN_MISS_ASYNC_WARM_SENTINEL_OK=true|false`
- `LSP01_COMPLETION_COLUMN_MISS_ASYNC_WARM_LABELS=true|false`
- `LSP01_COMPLETION_COLUMN_MISS_ASYNC_STALE_DROPPED=true|false`
- `LSP01_COMPLETION_COLUMN_MISS_ASYNC_AUTO_RETRIGGER_OK=true|false`
- `LSP01_COMPLETION_COLUMN_MISS_SYNC_LEGACY_STATUS=historical` if sync is excluded from active rollup
- `LSP01_STARTUP_LARGE_DISK_CACHE_{100,1000,10000}_SENTINEL_OK=true|false`
- `LSP01_STARTUP_LARGE_DISK_CACHE_SYNC_LOAD_COUNT=<n>`
- `LSP01_DIAGNOSTICS_DIDCHANGE_COMPUTE_ONLY=true|false` (exactly three `true` emissions, one each for `DIAGNOSTICS_DIDCHANGE_{100,1000,10000}`)
- `LSP01_LINUX_PERF_THRESHOLD_COMPLETION_COLUMN_MISS_ASYNC_FIRST_STATUS=frozen|candidate|missing`
- `LSP01_MACOS_PERF_THRESHOLD_COMPLETION_COLUMN_MISS_ASYNC_FIRST_STATUS=frozen|candidate|missing`
- `LSP01_LINUX_PERF_THRESHOLD_COMPLETION_COLUMN_MISS_ASYNC_WARM_STATUS=frozen|candidate|missing`
- `LSP01_MACOS_PERF_THRESHOLD_COMPLETION_COLUMN_MISS_ASYNC_WARM_STATUS=frozen|candidate|missing`
- `LSP01_{LINUX|MACOS}_PERF_THRESHOLD_STARTUP_LARGE_DISK_CACHE_{100,1000,10000}_STATUS=frozen|candidate|missing`

New Phase 11 semantic markers:
- `LSP11_SCHEMA_INDEX_SORTED=true`
- `LSP11_SCHEMA_LOOKUP_SCHEMA_AWARE=true`
- `LSP11_LRU_EVICTION_COUNT=<n>`
- `LSP11_LRU_EVICTION_OK=true`
- `LSP11_LRU_BOUND_HONORED=true`
- `LSP11_COMPLETION_INDEX_IMMUTABLE=true`
- `LSP11_INDEX_INCREMENTAL_OK=true`
- `LSP11_ATOMIC_WRITE_OK=true`
- `LSP11_CORRUPT_CACHE_RECOVERED=true`
- `LSP11_DISK_PRUNE_COUNT=<n>`
- `LSP11_DISK_CACHE_ISOLATED=true`
- `LSP11_DISK_LOAD_BOUNDED=true`
- `LSP11_ASYNC_FIRST_INCOMPLETE=true`
- `LSP11_ASYNC_DEDUPE_OK=true`
- `LSP11_ASYNC_STALE_DROPPED=true`
- `LSP11_ASYNC_WARM_LABELS=true`
- `LSP11_ASYNC_NO_SYNC_FETCH=true`
- `LSP11_ASYNC_FAILURE_HANDLED=true`
- `LSP11_ASYNC_PAYLOAD_ERROR_HANDLED=true`
- `LSP11_ASYNC_MATERIALIZATION_PROBE_CHAIN_OK=true`
- `LSP11_ASYNC_EVENT_WIRING_OK=true`
- `LSP11_ASYNC_AUTO_RETRIGGER_OK=true`
- `LSP11_DIAGNOSTICS_MULTILINE_FROM_OK=true`
- `LSP11_DIAGNOSTICS_MULTI_JOIN_RANGE_OK=true`
- `LSP11_DIAGNOSTICS_SCHEMA_AWARE_OK=true`
- `LSP11_DIAGNOSTICS_SOURCE_WARN_OK=true`
- `LSP11_DIAGNOSTIC_NAMESPACE_OK=true`
- `LSP11_DEBOUNCE_DIDCHANGE_OK=true`
- `LSP11_DIDSAVE_IMMEDIATE_OK=true`
- `LSP11_SAVE_ONLY_OK=true`
- `LSP11_DIAGNOSTICS_OFF_OK=true`
- `LSP11_DEBOUNCE_CLEANUP_OK=true`

Existing LSP semantic markers that must continue or migrate truthfully:
- `LSP_ALIAS_*` from `check_lsp_alias_completion.lua`
- `LSP_SCHEMA_ALIAS_*` from `check_lsp_schema_alias_completion.lua`
- `LSP_REBIND_*` from `check_lsp_alias_rebinding.lua`
- `LSP_ALIAS_FIRST_INCOMPLETE=true`
- `LSP_ALIAS_WARM_LABELS=true`
- `LSP_ALIAS_NO_SYNC_FETCH=true`
- `LSP_SCHEMA_ALIAS_FIRST_INCOMPLETE=true`
- `LSP_SCHEMA_ALIAS_ASYNC_CALLS=<n>`
- `LSP_SCHEMA_ALIAS_WARM_LABELS=true`
- `LSP_SCHEMA_ALIAS_NO_SYNC_FETCH=true`
- `LSP_SCHEMA_ALIAS_VIEW_FALLBACK_OK=true`
- `LSP_REBIND_FIRST_INCOMPLETE=true`
- `LSP_REBIND_WARM_LABELS=true`
- `LSP_REBIND_NO_SYNC_FETCH=true`

Exact final marker contract:
- Active Phase 11 perf registry has 33 publishable scenarios: the 29 Phase 10 scenarios minus active `COMPLETION_COLUMN_MISS_SYNC`, plus `COMPLETION_COLUMN_MISS_ASYNC_FIRST`, `COMPLETION_COLUMN_MISS_ASYNC_WARM`, and `STARTUP_LARGE_DISK_CACHE_{100,1000,10000}`.
- Final validation requires exactly 33 `LSP01_<SCENARIO>_SENTINEL_OK=true` markers, zero `LSP01_<SCENARIO>_SENTINEL_OK=false` markers, exactly three `LSP01_DIAGNOSTICS_DIDCHANGE_COMPUTE_ONLY=true` markers, zero compute-only false markers, exactly 18 active direct-client `NO_STALE_CLIENTS=true` markers, zero active direct-client `NO_STALE_CLIENTS=false` markers, and `LSP01_REAL_LSP_PERF_ALL_PASS=true|unfrozen`.
</verification_markers>

<verification>
1. Static dependency and scope checks:
   `grep -n "NIO_NVIM_COMMIT := 21f5324bfac14e22ba26553caf69ec76ae8a7662" ci/headless/perf_bootstrap.mk && grep -n "nvim-neotest/nvim-nio" README.md doc/dbee.txt .github/workflows/test.yml && ! grep -R "vim.lsp.config\\|semanticTokensProvider\\|inlayHintProvider\\|completionItem/resolve\\|textDocument/hover" lua/dbee/lsp ci/headless/check_lsp_*.lua`

2. Async completion scope guard:
   `grep -n "connection_get_columns_async" lua/dbee/lsp/schema_cache.lua lua/dbee/lsp/init.lua ci/headless/check_lsp_async_completion.lua && grep -n "get_columns_async" lua/dbee/lsp/server.lua && ! grep -n "connection_get_columns" lua/dbee/lsp/server.lua`

3. Schema cache verification:
   `make perf-bootstrap >/dev/null && NIO_DIR="$(make perf-bootstrap-print | awk -F= '/^NIO_NVIM_DIR=/{print $2}')" && nvim --headless -u NONE -i NONE -n --cmd "set rtp^=${NIO_DIR} | set rtp+=$(pwd)" -c "luafile ci/headless/check_lsp_schema_cache_optimization.lua"`

4. Disk cache verification:
   `make perf-bootstrap >/dev/null && NIO_DIR="$(make perf-bootstrap-print | awk -F= '/^NIO_NVIM_DIR=/{print $2}')" && nvim --headless -u NONE -i NONE -n --cmd "set rtp^=${NIO_DIR} | set rtp+=$(pwd)" -c "luafile ci/headless/check_lsp_disk_cache_safety.lua"`

5. Async completion verification:
   `make perf-bootstrap >/dev/null && NIO_DIR="$(make perf-bootstrap-print | awk -F= '/^NIO_NVIM_DIR=/{print $2}')" && nvim --headless -u NONE -i NONE -n --cmd "set rtp^=${NIO_DIR} | set rtp+=$(pwd)" -c "luafile ci/headless/check_lsp_async_completion.lua"`

6. Diagnostics correctness verification:
   `make perf-bootstrap >/dev/null && NIO_DIR="$(make perf-bootstrap-print | awk -F= '/^NIO_NVIM_DIR=/{print $2}')" && nvim --headless -u NONE -i NONE -n --cmd "set rtp^=${NIO_DIR} | set rtp+=$(pwd)" -c "luafile ci/headless/check_lsp_diagnostics_correctness.lua"`

7. Diagnostics debounce verification:
   `make perf-bootstrap >/dev/null && NIO_DIR="$(make perf-bootstrap-print | awk -F= '/^NIO_NVIM_DIR=/{print $2}')" && nvim --headless -u NONE -i NONE -n --cmd "set rtp^=${NIO_DIR} | set rtp+=$(pwd)" -c "luafile ci/headless/check_lsp_diagnostics_debounce.lua"`

8. Existing LSP semantic checks:
   `make perf-bootstrap >/dev/null && NIO_DIR="$(make perf-bootstrap-print | awk -F= '/^NIO_NVIM_DIR=/{print $2}')" && nvim --headless -u NONE -i NONE -n --cmd "set rtp^=${NIO_DIR} | set rtp+=$(pwd)" -c "luafile ci/headless/check_lsp_alias_completion.lua" && nvim --headless -u NONE -i NONE -n --cmd "set rtp^=${NIO_DIR} | set rtp+=$(pwd)" -c "luafile ci/headless/check_lsp_schema_alias_completion.lua" && nvim --headless -u NONE -i NONE -n --cmd "set rtp^=${NIO_DIR} | set rtp+=$(pwd)" -c "luafile ci/headless/check_lsp_alias_rebinding.lua"`

9. Phase 10/11 LSP perf smoke on macOS:
   `ART_DIR=$(mktemp -d) && LOG="$ART_DIR/lsp01-stdout.log" && LSP01_PERF_GATE_MODE=advisory LSP01_PERF_ARTIFACT_DIR="$ART_DIR" LSP01_PERF_SUMMARY_PATH="$ART_DIR/lsp01-summary.txt" LSP01_PERF_TRACE_PATH="$ART_DIR/lsp01-trace.json" LSP01_PERF_STATE_HOME="$ART_DIR/state-home" make perf-lsp PERF_PLATFORM=macos | tee "$LOG" && grep -q "LSP01_SCENARIOS_COUNT=33" "$LOG" && test "$(grep -c 'LSP01_.*_SENTINEL_OK=true' "$LOG")" -eq 33 && ! grep -q 'LSP01_.*_SENTINEL_OK=false' "$LOG" && test "$(grep -c 'LSP01_DIAGNOSTICS_DIDCHANGE_COMPUTE_ONLY=true' "$LOG")" -eq 3 && ! grep -q 'LSP01_DIAGNOSTICS_DIDCHANGE_COMPUTE_ONLY=false' "$LOG" && test "$(grep -c 'LSP01_.*_NO_STALE_CLIENTS=true' "$LOG")" -eq 18 && ! grep -q 'LSP01_.*_NO_STALE_CLIENTS=false' "$LOG" && grep -q "COMPLETION_COLUMN_MISS_ASYNC_FIRST" "$LOG" && grep -q "COMPLETION_COLUMN_MISS_ASYNC_WARM" "$LOG" && grep -q "STARTUP_LARGE_DISK_CACHE_10000" "$LOG" && grep -q "LSP01_COMPLETION_COLUMN_MISS_ASYNC_FIRST_SENTINEL_OK=true" "$LOG" && grep -q "LSP01_COMPLETION_COLUMN_MISS_ASYNC_WARM_SENTINEL_OK=true" "$LOG" && grep -q "LSP11_DISK_LOAD_BOUNDED=true" "$LOG" && grep -Eq "LSP01_REAL_LSP_PERF_ALL_PASS=(true|unfrozen)$" "$LOG" && ! grep -q "LSP01_PHASE7_BUDGETS_PASS" "$LOG"`

10. Phase 9 perf smoke still wired:
   `make -n perf && grep -n "DRAW01_REAL_NUI_PERF_ALL_PASS" ci/headless/check_drawer_perf.lua`

11. Phase 4..9 smoke marker preservation:
   `rg -n "DRAW01_ALL_PASS|STRUCT01_ALL_PASS|DCFG01_|DCFG02_|NOTES01_" ci/headless .github/workflows/test.yml`

12. Config/docs verification:
   `grep -n 'diagnostics_mode = "debounce_didchange"' lua/dbee/config.lua README.md doc/dbee.txt && grep -n 'requires nvim>=0.12' README.md doc/dbee.txt`
</verification>

<goal_backward_audit>
To claim "v1.2 Phase 11 ships LSP optimization + correctness with Phase 10 baselines preserved", the repo must prove:

1. Cold column miss completion is non-blocking and async.
   Covered by: `11-01-10`, `11-01-11`, `11-01-12`, `11-01-13`, `11-01-14`, `11-01-15`, `11-01-23`, `11-01-24`.

2. Async miss work uses the existing handler async event surface and stale-drop epoch contracts.
   Covered by: `11-01-10`, `11-01-11`, `11-01-14`, including payload-error handling and bounded table/view materialization probing.

3. Schema cache hot paths are bounded.
   Covered by: `11-01-05`, `11-01-06`, `11-01-08`, `11-01-26`.

4. Disk cache is safer and recoverable.
   Covered by: `11-01-07`, `11-01-09`, `11-01-26`.

5. Diagnostics are configurable, debounced, and still immediate on save.
   Covered by: `11-01-02`, `11-01-18`, `11-01-20`, `11-01-27`.

6. Diagnostics correctness bugs are fixed.
   Covered by: `11-01-16`, `11-01-17`, `11-01-19`.

7. Phase 10 perf evidence remains usable while adding Phase 11 async evidence.
   Covered by: `11-01-04`, `11-01-15`, `11-01-25`, `11-01-26`, `11-01-27`, final perf verification.

8. Users know the dependency/config/behavior change.
   Covered by: `11-01-21`, `11-01-22`.

9. Phase 4..10 smoke and semantic checks still pass.
   Covered by: `11-01-03`, `11-01-23`, `11-01-24`, `11-01-25`, and final verification commands.

If any one of these outputs is missing, Phase 11 does not satisfy `LSP-OPT-01` and `LSP-CORR-01`.
</goal_backward_audit>

<threat_model>
- **Threat: `nvim-nio` peer dependency breaks user plugin-manager setup**
  - Severity: medium
  - Mitigation: pin in CI/perf bootstrap, document lazy/packer dependency snippets, and run ordinary headless LSP checks with pinned `nvim-nio` on runtimepath.

- **Threat: async cancellation race during reconnect or source reload**
  - Severity: high
  - Mitigation: dedupe key includes `root_epoch`; `init.lua` routes invalidations to `cache:cancel_async`; tests inject stale payloads and error payloads and assert in-flight state is cleared without cache update.

- **Threat: async materialization probing loses view-only completion**
  - Severity: high
  - Mitigation: async miss handling preserves the bounded `MATERIALIZATIONS = { "table", "view" }` probe chain and tests a view-only schema-qualified alias with `LSP11_ASYNC_MATERIALIZATION_PROBE_CHAIN_OK=true`.

- **Threat: completion silently falls back to sync fetch**
  - Severity: high
  - Mitigation: server-side grep guard forbids `connection_get_columns`; async tests emit `LSP11_ASYNC_NO_SYNC_FETCH=true`; perf async scenario asserts fake sync fetch count is zero.

- **Threat: debounce window causes lost diagnostics**
  - Severity: medium
  - Mitigation: save remains immediate, debounce tests cover rapid changes and cleanup, off/save-only modes are explicit config values.

- **Threat: LRU evicts an entry while async fetch is completing**
  - Severity: medium
  - Mitigation: async completion inserts/touches atomically in cache state, eviction runs after insertion, stale payloads are ignored before insertion, LRU test covers true map count, evicted-key absence, and touched-entry survival.

- **Threat: bounded disk load/prune still blocks startup on large cache directories**
  - Severity: high
  - Mitigation: synchronous startup load is capped at 100 most-recent column files, remaining load/prune work is scheduled outside startup/completion timing, and `STARTUP_LARGE_DISK_CACHE_{100,1000,10000}` perf cohorts enforce `LSP11_DISK_LOAD_BOUNDED=true`.

- **Threat: atomic disk write leaves temp files or corrupts existing cache**
  - Severity: medium
  - Mitigation: same-dir temp+rename, cleanup on failure, corrupt recovery test verifies original preservation and corrupt-file deletion.

- **Threat: Phase 10 perf sync-miss scenario conflicts with Phase 11 behavior**
  - Severity: high
  - Mitigation: preserve threshold/history but make `COMPLETION_COLUMN_MISS_ASYNC_FIRST` and `COMPLETION_COLUMN_MISS_ASYNC_WARM` the active Phase 11 gates; legacy sync marker is explicitly historical or isolated from current-code rollup.

- **Threat: diagnostics regex grows into a parser rewrite**
  - Severity: medium
  - Mitigation: statement-level scanning only, no new diagnostic classes, no parser dependency without explicit planning justification.
</threat_model>

<risk_register>
- **Risk: `nvim-nio` pin changes or repository fetch fails**
  - Mitigation: fixed commit hash in `perf_bootstrap.mk`; CI and docs both use the same pin; bootstrap fails closed on mismatch.

- **Risk: Neovim 0.12 ordinary headless bump exposes old smoke issues**
  - Mitigation: update CI in a dedicated task, keep Phase 4..9 smoke marker grep in final verification, and fix only compatibility issues required to keep existing contracts intact.

- **Risk: async completion retrigger primitive is not reliable across built-in clients**
  - Mitigation: Phase 11 locks the operational built-in-compatible retry pattern: first request returns `isIncomplete=true`, `structure_children_loaded` warms the cache, and the next completion trigger returns columns. `LSP11_ASYNC_AUTO_RETRIGGER_OK=true` proves this pattern without adding an `nvim-cmp`/`blink.cmp` dependency. If that pattern cannot be made reliable during execution, stop and surface a plan-gate decision instead of restoring sync fetch.

- **Risk: schema-aware duplicate table behavior is ambiguous**
  - Mitigation: qualified lookup is strict by schema; unqualified lookup remains deterministic via precomputed case-folded index and test coverage.

- **Risk: perf harness scenario count drift causes CI false fail**
  - Mitigation: tasks `11-01-15`, `11-01-26`, `11-01-27`, and `11-01-25` update the scenario registry, exact `LSP01_SCENARIOS_COUNT=33`, exact 33 scenario sentinel count, exact three compute-only didChange markers, exact 18 active direct-client sentinel count, and workflow validation before final verification.
</risk_register>

<success_criteria>
- `11-PLAN.md` revision 3 exists and traces D-150..D-197.
- `nvim-nio` is pinned and available in perf and ordinary Lua headless CI.
- `SchemaCache` indexes, LRU, pruning, atomic writes, and corrupt recovery are implemented and tested.
- Completion cold miss uses async handler transport, returns truthful `isIncomplete`, handles absent/throwing async transport and async payload errors without getting stuck incomplete, preserves bounded table/view materialization fallback, and proves the built-in-compatible retry pattern.
- Diagnostics debounce/config and correctness fixes are implemented and tested.
- Phase 10 LSP perf lane still emits a non-false rollup, has exact `LSP01_SCENARIOS_COUNT=33`, preserves sync-miss historical evidence, includes split async plus large-disk evidence, and proves didChange diagnostics timing is compute-only.
- Phase 4..10 smoke and existing LSP semantic checks pass after all three LSP semantic checks migrate away from sync column fakes.
</success_criteria>
