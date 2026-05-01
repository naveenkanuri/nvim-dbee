---
phase: 08-type-aware-connection-wizard
plan: 01
subsystem: persistence
tags: [filesource, persistence, metadata, editing]

requires:
  - phase: 07-connection-only-drawer
    provides: handler-owned source lifecycle wrappers and eventful reload/invalidation flows
provides:
  - atomic FileSource raw-record CRUD with explicit `__remove_keys` deletion
  - recursive unknown-field preservation for additive `wizard` metadata
  - additive raw-record lookup for metadata-first edit seeding
affects: [08-02, 08-03, 08-04]

tech-stack:
  added: []
  patterns:
    - "Same-directory temp-file-plus-rename writes for FileSource persistence"
    - "Recursive merge with explicit top-level delete contract for raw compatibility"
    - "Optional source-owned raw-record lookup without widening runtime ConnectionParams"

key-files:
  created: []
  modified:
    - lua/dbee/sources.lua
    - lua/dbee/api/core.lua
    - lua/dbee/handler/init.lua
    - lua/dbee/doc.lua

key-decisions:
  - "D-99/D-100: FileSource now mutates raw records atomically and preserves unknown sibling plus nested metadata fields unless explicitly deleted"
  - "D-97: runtime ConnectionParams stays `{ id, name, type, url }`; raw persisted records are exposed through an additive helper only"
  - "FileSource raw compatibility deletes stale `wizard` metadata through `__remove_keys` rather than merge omission"

requirements-completed: [DCFG-02]

duration: 1 session
completed: 2026-04-28
---

# Phase 8 Plan 01: Persistence Foundation Summary

**Phase 8 now has the FileSource and handler foundation needed for metadata-first wizard editing without widening the runtime connection shape.**

## Performance

- **Completed:** 2026-04-28
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments

- Rebuilt `FileSource` create/update/delete around raw JSON records so atomic temp-file-plus-rename writes and recursive unknown-field preservation happen in the source layer instead of the drawer.
- Added explicit `__remove_keys = { "wizard" }` delete semantics so raw-compatibility edits can physically remove stale wizard metadata without violating merge-preserve rules.
- Added an additive `source_get_connection_record(...)` handler/API seam for metadata-first edit seeding while keeping `source_get_connections()` and `connection_get_params()` on the existing runtime `{ id, name, type, url }` contract.

## Task Commits

1. **Task 08-01-01: Refactor FileSource CRUD around atomic raw-record writes** - `7bd639f` (feat)
2. **Task 08-01-02: Add raw-record access for metadata-first edit seeding** - `f22e00b` (feat)

## Verification Results

- `08-01-01` verify block passed on 2026-04-28: `create(conn)`, `update(id, details)`, `delete(id)`, `uv.fs_rename`, `wizard`, and `__remove_keys` are present in `lua/dbee/sources.lua`.
- `08-01-01` module load sanity check passed with `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "lua require('dbee.sources')" -c qall`.
- `08-01-02` verify block passed on 2026-04-28: `get_record` and `source_get_connection_record` are present in `lua/dbee/sources.lua`, `lua/dbee/handler/init.lua`, `lua/dbee/api/core.lua`, and `lua/dbee/doc.lua`.

## Decisions Made

- `FileSource:load()` now strips raw records back down to runtime connection params so source-local metadata never leaks into the live handler connection contract.
- Raw-record helper failures are non-fatal: sources without `get_record()` simply return `nil`, and source implementations that error during raw lookup log a warning and fall back cleanly.

## Deviations from Plan

None - plan executed as written.

## Issues Encountered

- Parser-only checks with `luac` are not reliable for the repo’s LuaJIT-style code, and bare `require("dbee.api.core")` under `-u NONE` pulls the drawer stack without `nui.nvim`; verification stayed on the plan’s structural grep checks plus a direct `dbee.sources` load sanity check.

## User Setup Required

None.

## Next Phase Readiness

- `08-02` can build the wizard module against a concrete raw-record helper instead of trying to smuggle metadata through runtime connection params.
- `08-03` can route raw compatibility updates through the explicit delete contract when it strips stale wizard metadata.

---
*Phase: 08-type-aware-connection-wizard*
*Completed: 2026-04-28*
