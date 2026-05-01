---
phase: 12-lsp-feature-gap-closure
plan: 03
subsystem: lsp
tags: [lsp, code-actions, execute-command, schema-cache, perf]
requires:
  - phase: 11
    provides: LSP cache optimization, async column miss handling, and diagnostics invariants
  - phase: 14
    provides: schema filter authority, canonical name helpers, lazy schema scope, and handler singleflight invariants
  - phase: "12.1"
    provides: hover/resolve freshness, helper routing, and epoch fail-closed patterns
  - phase: "12.2"
    provides: statement splitting, symbol parsing, and workspace/document symbol gates
provides:
  - Standard LSP textDocument/codeAction support for cache-backed SQL actions
  - Standard workspace/executeCommand support for dbee/refresh_schema and dbee/reload_table
  - Context helpers for select-list stars, table refs, CTE shadows, and code-action statement scope
  - Functional, rollup, and perf evidence for 43 checked / 45 emitted Phase 12.3 markers
affects: [lsp, schema-cache, perf-lsp, docs]
tech-stack:
  added: []
  patterns:
    - Cache-only LSP request paths with versioned WorkspaceEdit.documentChanges
    - Init-owned command callbacks injected into server protocol routing
    - CTE/local relation fail-closed checks before metadata lookup or rendering
key-files:
  created:
    - lua/dbee/lsp/code_actions.lua
    - ci/headless/check_lsp12_3_code_actions.lua
  modified:
    - lua/dbee/config.lua
    - lua/dbee/lsp/context.lua
    - lua/dbee/lsp/server.lua
    - lua/dbee/lsp/init.lua
    - lua/dbee/lsp/schema_cache.lua
    - ci/headless/check_lsp12_rollup.lua
    - ci/headless/check_lsp_perf.lua
    - Makefile
    - README.md
    - doc/dbee.txt
key-decisions:
  - "Implemented Phase 12.3 as standard LSP CodeAction literals plus server-owned workspace/executeCommand callbacks."
  - "Kept textDocument/codeAction cache-only; reload and refresh schedule async work only after executeCommand token rechecks."
  - "Used versioned WorkspaceEdit.documentChanges for all edit actions and omitted edits without a synced document version."
  - "Rejected CTE/local relation shadows before metadata lookup so shadowed SELECT * never copies or renders cached columns."
patterns-established:
  - "code_actions.lua owns action construction and command allow-list validation; init.lua owns active-connection command callbacks."
  - "schema_cache.lua exposes narrow code-action helpers for unique table resolution, bounded cached columns, and forced async reload."
requirements-completed: [DBEE-FEAT-02]
duration: 17min
completed: 2026-05-01T14:06:04Z
---

# Phase 12.3 Plan 03: LSP Code Actions Summary

**Cache-backed LSP code actions with versioned SQL edits, safe refresh/reload commands, CTE-shadow fail-closed guards, and strict Phase 12.3 perf evidence.**

## Performance

- **Duration:** 17 min
- **Started:** 2026-05-01T13:48:56Z
- **Completed:** 2026-05-01T14:06:04Z
- **Tasks:** 12/12
- **Files changed:** 12

## Accomplishments

- Added `textDocument/codeAction` for expanding cached single-table `SELECT *`, qualifying unqualified table refs, refreshing schema cache, and reloading table metadata.
- Added `workspace/executeCommand` dispatch with exact enabled command subsets and token rechecks for command id, config flags, active connection, generation, root epoch, and scope.
- Added parser/context support for code-action statement selection, unqualified select-list star detection, table-ref ranges, single-table checks, and CTE/local relation shadow detection.
- Added cache helpers for unique table resolution, no-copy bounded cached columns, and forced async table metadata reload.
- Added Phase 12.3 functional sentinel, strict rollup checks, four real code-action perf cohorts, Makefile wiring, and docs/config flags.

## Task Commits

The implementation was kept in logical task chunks in the worktree, but commits could not be created because the sandbox cannot write inside `.git`:

| Task | Name | Commit | Files |
| --- | --- | --- | --- |
| 1 | Config flags and docs | blocked by `.git` read-only sandbox | `lua/dbee/config.lua`, `README.md`, `doc/dbee.txt` |
| 2 | Context helpers | blocked by `.git` read-only sandbox | `lua/dbee/lsp/context.lua` |
| 3 | Code-action registry | blocked by `.git` read-only sandbox | `lua/dbee/lsp/code_actions.lua` |
| 4 | Expand SELECT * | blocked by `.git` read-only sandbox | `lua/dbee/lsp/code_actions.lua`, `lua/dbee/lsp/schema_cache.lua` |
| 5 | Qualify identifier | blocked by `.git` read-only sandbox | `lua/dbee/lsp/code_actions.lua`, `lua/dbee/lsp/context.lua` |
| 6 | textDocument/codeAction wiring | blocked by `.git` read-only sandbox | `lua/dbee/lsp/server.lua` |
| 7 | workspace/executeCommand wiring | blocked by `.git` read-only sandbox | `lua/dbee/lsp/server.lua`, `lua/dbee/lsp/init.lua`, `lua/dbee/lsp/code_actions.lua` |
| 8 | Async reload helper | blocked by `.git` read-only sandbox | `lua/dbee/lsp/schema_cache.lua` |
| 9 | Functional sentinel | blocked by `.git` read-only sandbox | `ci/headless/check_lsp12_3_code_actions.lua` |
| 10 | Rollup and Makefile | blocked by `.git` read-only sandbox | `ci/headless/check_lsp12_rollup.lua`, `Makefile` |
| 11 | Perf cohorts | blocked by `.git` read-only sandbox | `ci/headless/check_lsp_perf.lua` |
| 12 | Final docs and verification | blocked by `.git` read-only sandbox | `README.md`, `doc/dbee.txt` |

## Files Created/Modified

- `lua/dbee/lsp/code_actions.lua` - New registry for stable ordered actions, kind-prefix filtering, versioned edits, command tokens, and execute-command dispatch.
- `ci/headless/check_lsp12_3_code_actions.lua` - New functional sentinel covering all non-perf Phase 12.3 markers and the r3 CTE-shadow watchpoint.
- `lua/dbee/lsp/context.lua` - Added code-action statement, star, table-ref, single-table, and CTE/local relation helpers.
- `lua/dbee/lsp/schema_cache.lua` - Added code-action table resolution, no-copy bounded column access, and forced async reload helper.
- `lua/dbee/lsp/server.lua` - Advertises code-action/execute-command capabilities, tracks document versions, and routes protocol requests.
- `lua/dbee/lsp/init.lua` - Owns refresh/reload command callbacks and rechecks active connection/freshness before scheduling.
- `lua/dbee/config.lua` - Adds master/per-action flags and max expand-column validation.
- `ci/headless/check_lsp12_rollup.lua` - Adds strict 43-marker Phase 12.3 rollup.
- `ci/headless/check_lsp_perf.lua` - Adds four real `textDocument/codeAction` perf cohorts with 100 measured samples.
- `Makefile` - Runs the Phase 12.3 sentinel before LSP12 rollup.
- `README.md`, `doc/dbee.txt` - Document code-action behavior and rollback flags.

## Verification

- `make perf-lsp PERF_PLATFORM=macos` passed.
  - `LSP12_3_ROLLUP_MARKERS_CHECKED=43`
  - `LSP12_3_ALL_PASS=true`
  - `LSP12_HOVER_RESOLVE_ALL_PASS=true`
  - `LSP12_2_ALL_PASS=true`
  - `ARCH14_ALL_PASS=true`
  - Phase 4..14, 12.1, and 12.2 smoke gates remained green in the perf-lsp run.
- Phase 12.3 perf cohorts emitted:
  - `LSP12_3_PERF_SCENARIOS_COUNT=4`
  - `LSP12_3_MEASURED_COUNT=100`
  - `LSP12_3_CODEACTION_EMPTY_REFACTOR_RANGE_P95_MS=0.38`
  - `LSP12_3_CODEACTION_EXPAND_SELECT_STAR_P95_MS=0.11`
  - `LSP12_3_CODEACTION_QUALIFY_IDENTIFIER_P95_MS=0.44`
  - `LSP12_3_CODEACTION_SOURCE_COMMANDS_P95_MS=0.21`
  - `LSP12_3_PERF_CODEACTION_BUDGET_50MS=true`
  - `LSP12_3_PERF_EDIT_BUDGET_100MS=true`
- `go -C dbee test ./core ./handler ./adapters` passed:
  - `ok github.com/kndndrj/nvim-dbee/dbee/core 32.786s`
  - `ok github.com/kndndrj/nvim-dbee/dbee/handler 1.133s`
  - `ok github.com/kndndrj/nvim-dbee/dbee/adapters 2.403s`

## Decisions Made

- Kept command execution callbacks injected from `init.lua`, so protocol routing stays in `server.lua` and active-connection refresh ownership stays in LSP init.
- Used cache helper methods instead of direct authority/canonical/epoch interpretation in code-action construction.
- Treated unqualified table matches as ambiguous when more than one in-scope schema resolves the name.
- Omitted edit actions when no current document version is known, forcing clients through synced document lifecycle before edits are offered.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Git metadata is read-only in the sandbox**
- **Found during:** Task 1 commit attempt
- **Issue:** `git add` failed with `Unable to create .../.git/index.lock: Operation not permitted`; a direct write test inside `.git` failed the same way.
- **Fix:** Continued implementation and verification without creating commits. All intended task files remain modified in the worktree and unrelated untracked files were left untouched.
- **Files modified:** None for the fix.
- **Verification:** `make perf-lsp PERF_PLATFORM=macos` and `go -C dbee test ./core ./handler ./adapters` both passed.
- **Committed in:** Not committed; sandbox blocks `.git` writes.

**Total deviations:** 1 blocking environment deviation.
**Impact on plan:** Implementation and verification completed, but per-task and metadata commits could not be created in this sandbox.

## Issues Encountered

- Direct `vim.lsp.util.apply_workspace_edit` in the headless sentinel did not enforce document versions without a real client version gate. The sentinel now verifies the server responsibility directly: edit actions carry version `N`, the document advances to `N+1`, and the stale edit is not applied by the version check path.
- The r3 CTE-shadow watchpoint was implemented by wrapping cached-column lookup and failing if `WITH users AS (...) SELECT * FROM users` reaches metadata lookup. It remained at zero lookups and returned empty actions.

## Known Stubs

None.

## Threat Flags

| Flag | File | Description |
| --- | --- | --- |
| threat_flag: lsp-command-surface | `lua/dbee/lsp/server.lua`, `lua/dbee/lsp/init.lua`, `lua/dbee/lsp/code_actions.lua` | New `workspace/executeCommand` surface for refresh/reload commands; mitigated by exact command allow-list, config rechecks, active connection checks, generation/root-epoch tokens, and schema scope validation. |

## Self-Check: PASSED

- Created files exist: `lua/dbee/lsp/code_actions.lua`, `ci/headless/check_lsp12_3_code_actions.lua`.
- Protected helper files were not modified: `lua/dbee/schema_filter_authority.lua`, `lua/dbee/schema_name_canonical.lua`, `lua/dbee/lsp/epoch_authority.lua`.
- Commits could not be checked because `.git` writes are blocked by the sandbox; this is documented above.

## User Setup Required

None.

## Next Phase Readiness

Phase 12.3 is functionally ready for review. The remaining operational step is to create the logical commits from the current worktree in an environment where `.git` is writable.

---
*Phase: 12-lsp-feature-gap-closure*
*Completed: 2026-05-01*
