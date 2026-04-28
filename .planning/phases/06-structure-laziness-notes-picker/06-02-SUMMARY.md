---
phase: 06-structure-laziness-notes-picker
plan: 02
subsystem: notes-picker
tags: [notes, picker, snacks, sections, headless-tests]

requires:
  - phase: 06-structure-laziness-notes-picker
    provides: milestone CI lane already expanded for new Phase 6 headless scripts
provides:
  - picker-specific note section helper in `api.ui`
  - sectioned single-picker `dbee.pick_notes()` flow with guarded pseudo-rows
  - headless NOTES01 coverage and CI wiring
affects: [06-structure-laziness-notes-picker]

tech-stack:
  added: []
  patterns:
    - "Structured picker snapshot helper that leaves the flat note helper untouched"
    - "Pseudo-header and hint rows inside one Snacks picker with guarded confirm"

key-files:
  created:
    - ci/headless/check_notes_picker.lua
  modified:
    - lua/dbee.lua
    - lua/dbee/api/ui.lua
    - .github/workflows/test.yml

key-decisions:
  - "D-40: keep `dbee.pick_notes()` as the public single-picker entrypoint"
  - "D-41: ordering is fixed to Global first and Local second, with `[global]` / `[local: <conn_name>]` tags"
  - "D-44: no notes stays an info log; globals-only, local-empty, and local-only states stay explicit"

requirements-completed: [NOTES-01]

duration: 1 session
completed: 2026-04-28
---

# Phase 6 Plan 02: Notes Picker Summary

**NOTES-01 shipped as a sectioned single-picker upgrade: `dbee.pick_notes()` now snapshots structured note sections once per open, renders Global and Local groupings in one picker, and guards non-note rows from selection without changing the flat helper used elsewhere.**

## Performance

- **Completed:** 2026-04-28
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments

- Added `api.ui.editor_get_note_picker_sections()` so the picker can consume structured Global/Local note sections while `editor_get_all_notes()` stays flat and untouched for existing callers.
- Refactored `dbee.pick_notes()` to build one Snacks picker from a single snapshot per open, using pseudo-header and hint rows, fixed Global-first/Local-second ordering, and `[global]` / `[local: <conn_name>]` row tags.
- Added strict confirm guarding so nil payloads, headers, hint rows, and malformed note rows without `note_id` warn and no-op instead of closing the picker or mutating editor state.
- Added `ci/headless/check_notes_picker.lua` and CI workflow coverage for empty states, local-only/global-only rendering, row-tag output, guarded pseudo-rows, unchanged note-open behavior, and single-snapshot semantics.

## Task Commits

1. **Task 06-02-01: sectioned notes helper + public picker refactor** - `a6dbb8a` (feat)
2. **Task 06-02-02: notes-picker headless coverage + CI wiring** - `a6dbb8a` (feat; landed in the same verified NOTES-01 commit)

## Verification Results

- `06-02-01` grep verification passed on 2026-04-28, confirming the new structured helper, the section labels/tags, the exact confirm guard, and the unchanged `editor_set_current_note()` note-open path.
- `06-02-02` headless verification passed on 2026-04-28 with `NOTES01_ALL_PASS=true`.
- The NOTES01 suite emitted all required markers: `NOTES01_SECTION_ORDER_OK=true`, `NOTES01_EMPTY_STATE_OK=true`, `NOTES01_TAGS_OK=true`, `NOTES01_HEADER_GUARD_OK=true`, `NOTES01_LOCAL_ONLY_OK=true`, `NOTES01_GLOBAL_ONLY_OK=true`, `NOTES01_FLAT_HELPER_COMPAT_OK=true`, and `NOTES01_SNAPSHOT_OK=true`.

## Manual Notes-Picker UX Verification

- **Pseudo-header and hint row clarity in the current Snacks build:** pending manual verification. The headless suite confirms the row model and guard behavior, but not whether the current Snacks theme makes those rows visually obvious to users.
- **One-picker interaction feel:** pending manual verification. This execution turn did not manually drive `<leader>ef` in a live UI session.

## Key Decisions Honored

- NOTES-01 stayed on the existing public `dbee.pick_notes()` path and did not introduce a second picker or a new command.
- Local note membership remains namespace-based via `namespace_get_notes(tostring(current_connection.id))`; no reconnect or execution metadata was used to infer locality.
- The flat `editor_get_all_notes()` helper remains intact for unrelated callers even though the picker now uses the structured section helper.

## Residuals

- Manual live UI verification is still outstanding for the visual clarity of pseudo-header and hint rows in the installed Snacks build.
- NOTES-01 and its headless coverage landed together in one verified commit because the row model and the public-entrypoint harness were implemented and verified as one tightly coupled change set.

## Next Phase Readiness

- NOTES-01 code and automated verification are complete.
- Phase 6 now has both new headless suites in CI; remaining release work is manual live verification plus any later `/gsd:verify-work` sign-off.
