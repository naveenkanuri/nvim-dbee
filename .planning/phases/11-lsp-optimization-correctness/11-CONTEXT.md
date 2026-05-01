# Phase 11: LSP Perf Optimization And Correctness - Context

**Gathered:** 2026-04-29  
**Status:** Locked — ready for planning  
**Codex thread:** `019dd836-27d3-7c51-ad48-d06a7851133b`

<domain>
## Phase Boundary

Phase 11 is the production LSP optimization and correctness phase for v1.2. It consumes the Phase 10 headless perf harness and changes the built-in dbee LSP so typing and completion paths stay bounded while known table-reference diagnostic bugs are fixed.

In scope:
- Async, non-blocking column-cache misses for `column_of_table` completion using the existing handler async event surface
- In-memory column-cache LRU, disk-cache pruning, cache index precomputation, and atomic cache writes
- Debounced/static-schema LSP diagnostics with save-only/off configuration
- Correct diagnostics for multi-line `FROM`/`JOIN`, multi-JOIN-per-line ranges, and schema-qualified table references
- Phase 10 harness reuse with additive Phase 11 async-miss evidence
- Documentation and requirements updates for LSP optimization and correctness behavior changes

Out of scope:
- New LSP features such as hover, completion resolve/details, code actions, symbols, semantic tokens, or inlay hints
- Multi-client, per-buffer connection, or out-of-process LSP architecture
- `vim.lsp.config()` / `vim.lsp.enable()` migration
- Pivoting to standalone `sqls`, live database perf evidence, or external completion-source deprecation
- Reopening v1.0/v1.1/v1.2 locked decisions D-01..D-149

</domain>

<decisions>
## Implementation Decisions

### Phase Boundary And Prior Contracts
- **D-150:** Phase 11 is optimization plus correctness only. It must not add Phase 12 feature surfaces, semantic tokens, inlay hints, hover, completion resolve, code actions, workspace symbols, multi-client LSP architecture, or `vim.lsp.config()` migration.
- **D-151:** Phase 11 preserves the in-process LSP server, singleton-per-current-connection model, stale-while-revalidate disk cache pattern, handler-owned lifecycle, root-epoch fencing, and Phase 7 drawer/LSP single-flight contracts from D-77, D-78, D-84, D-87, and related v1.1 decisions.
- **D-152:** Phase 10 remains the baseline and regression harness. Phase 11 must run against the shipped Phase 10 perf lane rather than replacing it with ad hoc timing or helper-only microbenchmarks.

### Async Column Fetch
- **D-153:** Phase 11 adopts `nvim-nio` as a required peer dependency for LSP async orchestration. It is documented for users and test/bootstrap environments, but it is not vendored and is not introduced as a Phase 10 dependency.
- **D-154:** Column-cache miss work must use the existing handler async transport: `connection_get_columns_async()` requests and `structure_children_loaded` responses. Phase 11 must not wrap synchronous `handler.connection_get_columns()` in coroutines, timers, or `nvim-nio` jobs and call that a non-blocking path.
- **D-155:** Completion handlers read cached columns synchronously but never fetch missing columns synchronously. `SchemaCache` gains an async column miss API that returns cached columns immediately when available and otherwise returns an in-flight future/status without blocking the LSP request handler.
- **D-156:** A cold `column_of_table` completion miss returns an empty item list with `isIncomplete = true` only when an async miss is actually in flight. Cache hits and no-op misses must not claim incompleteness. After the async warmup lands, a later completion request returns the full cached columns.
- **D-157:** Phase 11 changes current cold-miss user behavior intentionally: the first alias/table dot completion request no longer blocks on Go RPC or database metadata; it returns promptly and warms columns in the background.
- **D-158:** In-flight column miss dedupe is keyed by `(conn_id, schema, table_name, materialization, root_epoch)`. Identical misses share one async request and waiter set; materially different schema/table/materialization/epoch misses do not share.
- **D-159:** Reconnect, source reload, database selection, eventful invalidation, or root-epoch changes cancel or ignore stale async column futures by epoch and connection identity. Transport cancellation is not required; stale completions are dropped and waiters are cleaned up per the Phase 7 D-87 cleanup model.
- **D-160:** Async column readiness must be observable by the LSP completion surface and tests. The exact retrigger primitive is planner discretion, but it must be bounded, testable, client-compatible with built-in LSP completion users, and must not require `nvim-cmp` or `blink.cmp`.
- **D-161:** If the handler async column surface is absent in a test or compatibility environment, completion must remain cache-only and non-blocking. It must not fall back to `connection_get_columns()` inside `textDocument/completion`.

### Schema Cache LRU And Indexes
- **D-162:** `SchemaCache.columns` is capped at 500 table entries in memory. The cache uses LRU-on-access: cache hits touch entries, and successful async-load completion inserts/touches the loaded table.
- **D-163:** Disk column cache remains unbounded by entry count, but LSP startup or first cache access prunes column cache files older than 30 days. Pruning must not delete current-run writes and must not block completion handlers.
- **D-164:** Phase 11 tests must expose LRU behavior with deterministic markers or assertions, including an eviction count/path that proves entries beyond the 500-table cap are removed from memory while disk cache remains available.
- **D-165:** `SchemaCache` owns precomputed completion indexes: a sorted schema completion list, sorted table completion lists per schema plus all-schemas table list, and sorted column completion lists per table.
- **D-166:** `SchemaCache` owns case-folded lookup indexes for schemas and tables so completion and diagnostics do not perform repeated per-request map scans.
- **D-167:** Cache indexes are invalidated and rebuilt only on cache mutation: structure/metadata build, disk load, async column success, explicit invalidate, connection change, LRU eviction, or corruption recovery. Read-only completion and diagnostics paths consume precomputed arrays/indexes.

### Diagnostics Policy
- **D-168:** LSP diagnostics default to `didChange` debounce with a 250ms delay.
- **D-169:** LSP diagnostics configuration lives in the existing central config surface as `dbee.setup({ lsp = { diagnostics_mode = "debounce_didchange" | "save_only" | "off", diagnostics_debounce_ms = 250 } })`. Phase 11 extends `lua/dbee/config.lua`; it does not create a separate config module unless planning proves extraction is needed for local organization only.
- **D-170:** `diagnostics_mode = "save_only"` disables `didChange` diagnostics and runs diagnostics immediately on `didSave`. `diagnostics_mode = "off"` disables LSP diagnostics and clears the LSP diagnostics namespace for attached buffers where appropriate.
- **D-171:** `didSave` fires diagnostics immediately whenever diagnostics mode is not `"off"`, independent of the `didChange` debounce setting.
- **D-172:** Full-buffer diagnostic recompute after a fired debounce/save event is acceptable for Phase 11. Incremental range validation is optional only if it stays simple, correct, and does not weaken multi-line statement correctness.
- **D-173:** LSP diagnostics remain static schema warnings only. Adapter/execution diagnostics from Phase 5 keep their existing namespace, severity, source, and ownership.
- **D-174:** LSP table-reference diagnostics use a distinct namespace named `dbee/lsp`, severity `WARN`, and source `dbee-lsp`.

### Diagnostics Correctness
- **D-175:** Table-reference diagnostics operate at statement scope rather than single-line scope, so multi-line `FROM` and `JOIN` clauses are detected.
- **D-176:** The multi-JOIN-per-line range bug is fixed by using each regex match's actual start/end positions instead of `line:find()` from the beginning of the line.
- **D-177:** Qualified table references are schema-aware. `schema.table` validates against that schema, and `wrong_schema.valid_table` must warn even when `valid_table` exists in a different schema.
- **D-178:** Unqualified table references may continue to use case-insensitive cross-schema lookup, but implementation must preserve deterministic behavior when duplicate table names exist across schemas.
- **D-179:** Phase 11 does not add new diagnostic classes such as unknown column, ambiguous table, parser errors, or query syntax validation.

### Disk Cache Reliability
- **D-180:** `SchemaCache:save_to_disk()` and column cache writes use the Phase 8 D-99 temp-file-plus-rename pattern in the same directory. Encode, write, close, or rename failure must leave the previous cache file untouched.
- **D-181:** Cache read/write failures that affect correctness or persistence are surfaced with `vim.notify(..., vim.log.levels.WARN)` and enough path/action context to debug the failure. Routine cache miss noise should not spam users.
- **D-182:** Corrupt disk JSON is recovered by logging a warning, deleting the corrupt cache file when safe, and falling back to structure refresh / metadata rebuild. Corruption must not crash LSP startup.
- **D-183:** Atomic disk-write and corruption-recovery tests use isolated `XDG_STATE_HOME` or equivalent harness state and must not touch the user's real Neovim state directory.

### Phase 10 Harness Reuse
- **D-184:** Phase 11 preserves Phase 10's `COMPLETION_COLUMN_MISS_SYNC` evidence as historical baseline data. It must not delete the Phase 10 marker or threshold history.
- **D-185:** Phase 11 adds an active async miss scenario, `COMPLETION_COLUMN_MISS_ASYNC`, to prove the new cold-miss behavior: first request returns promptly with truthful `isIncomplete = true`, exactly one async request is in flight, stale epochs are ignored, and a later request returns deterministic column labels from cache.
- **D-186:** Phase 11 perf evidence continues to use the Phase 10 `LSP01_*` harness and threshold-source pattern for shared performance scenarios. Phase 11-specific correctness or LRU markers may use `LSP11_*` when they are not part of the Phase 10 threshold rollup.
- **D-187:** The Phase 10 sync cold-miss scenario must not remain an active current-code gate that contradicts Phase 11's async behavior. If retained in the harness, it is explicitly legacy/baseline-only or isolated to a compatibility fixture; the active Phase 11 gate is the async scenario.

### Compatibility, Docs, And Neovim Alignment
- **D-188:** External `cmp-dbee` users remain supported. Phase 11 does not deprecate external completion stacks, but built-in dbee LSP remains the canonical in-repo completion path.
- **D-189:** Existing built-in LSP users should see behavior changes only on cold column completion misses: first result may be empty/incomplete instead of blocking, followed by complete results after warmup.
- **D-190:** Phase 11 documentation must call out the cold completion behavior change, the `nvim-nio` peer dependency, the new diagnostics config, and the v1.2 Neovim `0.12.x` support floor.
- **D-191:** `lua/dbee/lsp/bench.lua` was migrated to `vim.uv` in Phase 10. Phase 11 only verifies that state and does not spend scope on additional bench.lua migration unless tests reveal drift.

### Verification Gates
- **D-192:** Phase 11 adds tests for async column cache misses, in-flight dedupe, stale epoch/reconnect cancellation, LRU eviction, disk pruning, precomputed cache indexes, debounced diagnostics, save-only/off diagnostics modes, multi-line `FROM`/`JOIN`, multi-JOIN range placement, schema-aware qualified diagnostics, atomic disk writes, and corrupt cache recovery.
- **D-193:** Phase 4..9 smoke suites and Phase 10 LSP perf evidence remain required gates. Existing LSP semantic checks (`check_lsp_alias_completion.lua`, `check_lsp_schema_alias_completion.lua`, and `check_lsp_alias_rebinding.lua`) must be updated only as needed to reflect the async cold-miss contract and must continue to pass.
- **D-194:** `nvim-nio` is allowed in Phase 11 production/test dependencies, but no other async runtime or SQL parser dependency is locked by discuss. Additional dependencies require explicit planning justification and must not implement Phase 12 feature scope.
- **D-195:** `.planning/REQUIREMENTS.md` gains `LSP-OPT-01` for Phase 11 performance optimization and `LSP-CORR-01` for Phase 11 correctness fixes.

### Agent Discretion
- **D-196:** The planner may choose exact module/function names, helper extraction boundaries, retry/timeout constants, debounce timer implementation details, and marker names for Phase 11-only tests as long as D-150..D-195 hold.
- **D-197:** If planning discovers that the requested completion retrigger primitive has no reliable Neovim built-in mechanism, it must preserve the non-blocking + `isIncomplete` contract and surface the retrigger mechanism as a plan-gate risk rather than reintroducing synchronous column fetch.

</decisions>

<specifics>
## Specific Ideas

- The most important behavior change is the cold alias dot path: `SELECT * FROM schema.table t WHERE t.|` must no longer block the main thread on `connection_get_columns()`.
- LRU should be conservative: 500 table column entries in memory, disk cache retained for reuse and pruned only by age.
- Diagnostics should remain useful but quiet: warnings for unknown schema/table references, debounced on typing, immediate on save, and disabled cleanly when configured off.
- Schema-aware diagnostics must make `wrong_schema.valid_table` a warning when `valid_table` exists only outside `wrong_schema`.
- Phase 11 success is measured by better Phase 10 perf evidence plus new correctness tests, not by adding richer LSP feature surfaces.

</specifics>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### v1.2 Scope And Decisions
- `.planning/milestones/v1.2-roadmap.md` — locked v1.2 phase order, fork decisions, and Phase 11 success criteria
- `.planning/ROADMAP.md` — Phase 11 roadmap entry and requirement mapping
- `.planning/phases/10-lsp-optimization/10-CONTEXT.md` — D-119..D-149 Phase 10 harness decisions that Phase 11 must preserve
- `.planning/phases/10-lsp-optimization/10-PLAN.md` — shipped Phase 10 marker, scenario, and verification contract
- `.planning/REQUIREMENTS.md` — v1.2 requirements, including `LSP-PERF-01`, `LSP-OPT-01`, and `LSP-CORR-01`

### Research Inputs
- `.planning/phases/10-lsp-optimization/10-RESEARCH.md` — Codex research on LSP hot paths, lifecycle, cache, diagnostics, and test gaps
- `.planning/research/v12-lsp-opus-research.md` — independent Opus research confirming async fetch, LRU, debounce, correctness, and threshold direction

### Prior Contracts
- `.planning/phases/07-connection-only-drawer/07-CONTEXT.md` — D-77, D-78, D-84, D-87 handler-owned single-flight, backpressure, root epoch, and waiter cleanup contracts
- `.planning/phases/08-type-aware-connection-wizard/08-CONTEXT.md` — D-99 atomic FileSource write precedent to mirror for LSP cache writes
- `.planning/phases/09-real-nui-perf-harness/09-CONTEXT.md` — perf lane promotion and platform parity precedent

### LSP Production Code
- `lua/dbee/lsp/init.lua` — LSP lifecycle, `_try_start()`, structure refresh, metadata fallback, root epoch handling, and event subscriptions
- `lua/dbee/lsp/server.lua` — completion, diagnostics, dispatcher notification, and LSP request/notification surfaces
- `lua/dbee/lsp/schema_cache.lua` — schema/table/column cache, disk cache, sync column fetch hazard, and lookup/index ownership
- `lua/dbee/lsp/context.lua` — cursor context and alias parsing used by completion
- `lua/dbee/lsp/bench.lua` — existing interactive probe, already migrated to `vim.uv`
- `lua/dbee/handler/init.lua` — `connection_get_columns_async()`, `structure_children_loaded`, root epoch, and lifecycle invalidation APIs
- `lua/dbee/config.lua` — central configuration surface that gains `lsp.diagnostics_mode` and `lsp.diagnostics_debounce_ms`

### Phase 10 Harness And Tests
- `ci/headless/check_lsp_perf.lua` — Phase 10 real-LSP perf harness to extend for async miss evidence
- `ci/headless/lsp_perf_thresholds.lua` — LSP threshold source-of-truth
- `ci/headless/check_lsp_alias_completion.lua` — alias completion semantic coverage
- `ci/headless/check_lsp_schema_alias_completion.lua` — schema-qualified alias completion coverage that must migrate from sync miss expectations
- `ci/headless/check_lsp_alias_rebinding.lua` — alias rebinding semantic coverage
- `ci/headless/check_connection_coordination.lua` — drawer/LSP lifecycle and connection-coordination coverage

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- The handler already exposes `connection_get_columns_async()` and emits `structure_children_loaded` payloads with `conn_id`, `request_id`, `branch_id`, `root_epoch`, `kind`, and `columns`; Phase 11 should reuse this transport for LSP column misses.
- Phase 10's `check_lsp_perf.lua` already has real `vim.lsp.start()` attach, isolated `XDG_STATE_HOME`, fake handler/state helpers, and semantic sentinels that can be extended for async miss evidence.
- `lua/dbee/config.lua` already centralizes user config and validation, so LSP diagnostics config belongs there instead of a parallel config entry point.
- Phase 8's FileSource atomic write pattern is the local precedent for temp-file-plus-rename behavior.

### Established Patterns
- Handler-owned root epoch is the stale-data boundary; LSP async column work must use the same stale-drop logic rather than inventing a separate generation scheme.
- Phase 10 marker evidence is grep-friendly stdout plus artifacts; Phase 11 should extend that rather than creating JSON baselines.
- Existing adapter diagnostics and LSP diagnostics are separate concepts. Phase 11 makes the separation explicit through namespace/source/severity rather than collapsing them.

### Integration Points
- `SchemaCache` becomes the owner of indexes, LRU state, async column miss bookkeeping, disk pruning, and atomic cache persistence.
- `server.lua` consumes cache indexes and async miss status, emits `isIncomplete` truthfully, and debounces diagnostics notifications.
- `init.lua` continues to own LSP lifecycle, current connection retargeting, structure refresh, and invalidation handling.
- `ci/headless/check_lsp_perf.lua` gains `COMPLETION_COLUMN_MISS_ASYNC` evidence without deleting Phase 10 historical sync evidence.

</code_context>

<deferred>
## Deferred Ideas

- Phase 12 conditional: completion item `data` plus `completionItem/resolve`, hover, schema refresh/reload code actions, and document/workspace symbols.
- v1.3 or later: semantic tokens, inlay hints, multi-client/per-buffer connection model, `vim.lsp.config()` migration, live adapter perf lanes, richer SQL parsing, unknown-column diagnostics, and syntax diagnostics.

</deferred>

---

*Phase: 11-lsp-optimization-correctness*  
*Context gathered: 2026-04-29*
