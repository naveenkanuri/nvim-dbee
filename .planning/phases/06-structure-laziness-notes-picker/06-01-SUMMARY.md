---
phase: 06-structure-laziness-notes-picker
plan: 01
subsystem: structure-lazy
tags: [drawer, structure, async-columns, root-epoch, load-more, headless-tests]

requires:
  - phase: 04-drawer-navigation
    provides: filter snapshot restore and shared drawer model patterns
provides:
  - drawer-owned `_struct_cache` root and branch state
  - async table/view child fetch with preserved `materialization = struct.type`
  - drawer-owned `caller_token` and `root_epoch` fencing for root payloads
  - bounded `Load more...` materialization with targeted tree mutation
  - STRUCT01 headless coverage and CI wiring
affects: [06-structure-laziness-notes-picker]

tech-stack:
  added: []
  patterns:
    - "Canonical `build_tree_from_struct_cache(...)` rebuild path"
    - "Drawer-owned root fencing via `caller_token == \"drawer\"` plus `root_epoch`"
    - "Branch-local additive mutation with deterministic load-more sentinel"

key-files:
  created:
    - ci/headless/check_structure_lazy.lua
  modified:
    - dbee/endpoints.go
    - dbee/handler/event_bus.go
    - dbee/handler/handler.go
    - lua/dbee/api/__register.lua
    - lua/dbee/doc.lua
    - lua/dbee/handler/init.lua
    - lua/dbee/ui/drawer/convert.lua
    - lua/dbee/ui/drawer/init.lua
    - lua/dbee/ui/drawer/model.lua
    - ci/headless/check_drawer_filter.lua
    - ci/headless/check_winbar_format.lua
    - .github/workflows/test.yml

key-decisions:
  - "D-34: connection expansion stays lazy and warms only the next authoritative level"
  - "D-46: drawer-owned reloads bump `root_epoch` exactly once during pre-request clear"
  - "D-50: all Phase 6 structure state lives inside `_struct_cache`"
  - "D-63: manual `R` resolves the nearest owning connection, including `database_switch` rows"

requirements-completed: [STRUCT-01]

duration: 2 sessions
completed: 2026-04-28
---

# Phase 6 Plan 01: Structure-Lazy Summary

**STRUCT-01 shipped as a drawer-local cache and async child-fetch refactor: root payloads are fenced to drawer-owned requests, table/view expansion no longer falls back to synchronous column RPCs, and branch materialization stays bounded through `Load more...`.**

## Performance

- **Completed:** 2026-04-28
- **Tasks:** 3
- **Files modified:** 12

## Accomplishments

- Added additive async child-fetch support across the Go handler, Lua handler API, event bus, and generated manifest, with `materialization = struct.type` preserved end-to-end for table/view branches.
- Replaced the drawer’s scattered structure state with `_struct_cache`, a canonical `build_tree_from_struct_cache(...)` rebuild path, explicit root/branch error storage, and real `tree:set_nodes()` / `tree:add_node()` / `tree:remove_node()` partial mutation paths.
- Landed drawer-owned root fencing using `caller_token == "drawer"` plus the D-46 `root_epoch` single-bump rule so stale root and child payloads are ignored after manual `R` or `database_selected`.
- Added bounded child materialization and deterministic `Load more...` sentinel behavior without global drawer refreshes, while keeping filter-close locked to the Phase 4 D-31 snapshot-restore contract.
- Added `ci/headless/check_structure_lazy.lua` and CI wiring, plus updated regression harnesses for drawer filter and winbar coverage to match the new `_struct_cache` model.

## Task Commits

1. **Task 06-01-01: async child-fetch surface + drawer-owned root fencing** - `59fd188` (feat)
2. **Task 06-01-02: drawer materialization around `_struct_cache`** - `0b62c61` (feat)
3. **Task 06-01-03: structure-lazy headless coverage + CI wiring** - `2b5f0f5` (feat)

## Verification Results

- `06-01-01` grep and manifest verification passed on 2026-04-28, including regenerated `lua/dbee/api/__register.lua` with a clean diff.
- `06-01-02` grep verification passed on 2026-04-28, confirming `_struct_cache`, canonical rebuild usage, real load-more tree primitives, and removal of the legacy top-level drawer structure state.
- `06-01-03` headless verification passed on 2026-04-28 with `STRUCT01_ALL_PASS=true`.
- The STRUCT01 suite emitted all required narrowed markers, including `STRUCT01_CHILD_ASYNC_OK=true`, `STRUCT01_ROOT_EPOCH_OK=true`, `STRUCT01_ERROR_CACHE_OK=true`, `STRUCT01_MANUAL_R_TARGET_OK=true`, `STRUCT01_FILTER_FREEZE_OK=true`, and `STRUCT01_FULLTREE_CONTRACT_OK=true`.

## Manual Structure UX Verification

- **Large-schema root payload delivery on a real adapter:** pending manual verification. This execution turn did not exercise a live Oracle/Postgres schema, so D-55 remains recorded as a caveat until a real adapter run confirms whether root delivery meets the 5s bound or stays on the documented slow path.
- **`Load more...` cursor and expansion feel:** pending manual verification in a live Nui drawer.
- **Drawer reload scoping (`connection`, descendant, `database_switch`, source/note/help rows):** pending manual verification in an interactive session.

## Key Decisions Honored

- Phase 6 stayed inside the narrowed drawer-local scope: no reconnect choreography, no `connection_invalidated` ownership, and no refresh-contract redefinition for `current_connection_changed` or action callbacks.
- Filter close still restores the exact Phase 4 D-31 pre-filter snapshot; deferred branch mutations remain in `_struct_cache` until the next normal refresh or re-expand.
- Manual `R` and `database_selected` are the only authoritative invalidators in Phase 6, and both now force a fresh drawer-owned root request instead of reusing a stale pending request ID.

## Residuals

- The remaining live expand bottleneck at `connection_list_databases()` is unchanged and still belongs to Phase 7 per D-55/D-60.
- Live UX verification remains outstanding even though the automated Phase 6 coverage is green.

## Next Phase Readiness

- `STRUCT-01` code and automated verification are complete.
- Phase 6 is ready for NOTES-01 completion and later `/gsd:verify-work`, with manual live structure checks still to be recorded as pass/fail evidence.
