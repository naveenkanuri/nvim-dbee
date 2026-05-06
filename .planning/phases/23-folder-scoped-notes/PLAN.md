# Phase 23 - Folder-Scoped Global Notes

**Milestone:** v1.4
**Status:** Planned
**Date:** 2026-05-06
**Requirement:** Re-scope global notes from installation-wide to per-folder. Connections inherit notes from their folder; connections not in any folder show empty global picker.
**Reference:** `.planning/phases/23-folder-scoped-notes/23-CONTEXT.md`

## Goal

Replace legacy installation-wide global notes with folder-scoped global notes:

```text
notes/folder:<folder_id>/*.sql
```

The notes picker keeps the Phase 19 UX contract, but the "Global notes" section reads from the active connection's folder namespace. Local notes remain per-connection.

## Inputs Read

- `.planning/ROADMAP.md:422-438`
- `.planning/phases/23-folder-scoped-notes/23-CONTEXT.md`
- `.planning/phases/15-connection-folder-grouping/PLAN.md`
- `lua/dbee.lua`
- `lua/dbee/api/state.lua`
- `lua/dbee/api/ui.lua`
- `lua/dbee/ui/editor/init.lua`
- `lua/dbee/notes_migration.lua`
- `lua/dbee/notes_namespace.lua`
- `lua/dbee/sources.lua`
- `lua/dbee/handler/init.lua`
- `lua/dbee/ui/drawer/init.lua`
- `lua/dbee/ui/drawer/convert.lua`
- `ci/headless/check_notes_picker.lua`
- `ci/headless/check_folder_persistence.lua`
- `ci/headless/check_drawer_folders.lua`
- `Makefile`

## Locked Contracts

- `namespace_id = "folder:" .. folder_id`; namespace is the directory name.
- No-folder connection has no global fallback.
- Existing `notes/global/*.sql` files are cloned into every current folder namespace exactly once, then `notes/global/` is removed.
- Migration sentinel is `notes/.notes-migration-v1`, not phase-numbered.
- Migration scratch paths are version-coupled, not phase-coupled: `.notes-migration-v1.lock`, `.notes-migration-v1.staging-<pid>-<random>`, `.notes-migration-v1.trash-<pid>-<random>`, `.notes-migration-v1.promote-manifest`, and `.notes-migration-v1.recovery-needed`.
- Migration must abort before any notes data filesystem mutation if any folder-capable source is in `load_failed` state or duplicate folder IDs exist across sources.
- Empty folder lists under `loaded_ok` are valid fresh-user states. If no legacy `global/` exists, write the sentinel as a no-op; if legacy `global/` contains notes but no folders exist, backup creation is mandatory before deleting `global/` and writing the sentinel.
- Local notes stay `namespace_id = connection_id`.
- Folder rename does not move note directories.
- Folder delete deletes the folder namespace and notes after confirmation.
- `<C-g>` creates in active folder namespace; if no folder, notify exactly: `Connection not in any folder; cannot create global note. Add to a folder first.`
- Preserve Phase 19 picker layout: hint row at item 1, "Global notes" section, "Local notes (<conn>)" section, no `[global]` or `[local: ...]` tags.
- Do not edit `lua/dbee/schema_filter_authority.lua`, `lua/dbee/schema_name_canonical.lua`, or `lua/dbee/lsp/epoch_authority.lua`.
- Do not add Go RPC endpoints or backend adapter changes.

## Wave Breakdown

| Wave | Plan | Objective | Depends On |
| --- | --- | --- | --- |
| 1 | `23-01-PLAN.md` | Add source-owned folder lookup and switch picker global note namespace to active folder namespace. | None |
| 2 | `23-02-PLAN.md` | Add migration hook/module, backup/cleanup, editor startup fixes, and folder namespace lifecycle. | Wave 1 |
| 3 | `23-03-PLAN.md` | Add strict headless validation, rollup markers, preservation checks, and locked-helper guards. | Waves 1, 2 |

## Dependency Graph

```text
23-01 -> 23-02 -> 23-03
```

Wave 1 establishes the runtime namespace decision. Wave 2 depends on those helpers for migration and folder lifecycle. Wave 3 verifies both behavior and preservation.

## Decision Coverage

| Decision | Covered By | Success Criterion |
| --- | --- | --- |
| GN-01 | Waves 1, 3 | No picker/API path reads `namespace_get_notes("global")` for active global notes after Phase 23. |
| GN-02 | Waves 1, 2, 3 | Folder namespace helper returns exactly `folder:<folder_id>`. |
| GN-03 | Waves 2, 3 | Legacy global notes clone into every current folder namespace once, then `notes/global/` is gone. |
| GN-04 | Waves 1, 3 | Local notes still use current connection ID. |
| GN-05 | Waves 2, 3 | Create/rename/delete/move folder semantics match prompt. |
| GN-06 | Waves 1, 3 | Phase 19 picker markers remain green. |
| GN-07 | Waves 1, 3 | Folder lookup is Source-owned with Lua Handler facade; no Go RPC endpoint appears. |
| GN-08/GN-09 | Waves 1, 3 | Duplicate/manual folder membership never creates a union. |
| GN-10 | Waves 2, 3 | Post-migration folder creation creates an empty namespace only. |
| GN-11 | Waves 1, 3 | Picker reads only current folder namespace plus local notes. |
| GN-12/GN-13 | Waves 2, 3 | Migration lock/sentinel/backup behavior is covered. |
| GN-14 | Waves 2, 3 | Editor startup never recreates `notes/global/welcome.sql`. |
| GN-15 | Waves 2, 3 | Malformed folder IDs cannot escape the notes directory. |
| GN-16 | Waves 2, 3 | Folder delete stages and restores on handler failure. |
| GN-17 | Wave 3 | Locked helper git diff guard passes. |
| GN-18 | This plan | Execution targets `lua/dbee/sources.lua`, not nonexistent `lua/dbee/sources/file.lua`. |
| GN-19 | Waves 1, 2, 3 | Duplicate folder IDs across folder-capable sources abort migration and fail closed at runtime lookup, namespace creation, and folder delete. |
| GN-20 | Waves 2, 3 | Migration staging/trash directories are same-filesystem siblings of final namespaces; cross-filesystem rename is unsupported and aborts before destructive work. |

## Touchpoint Matrix

| ID | File | Touchpoint | Acceptance Assertion |
| --- | --- | --- | --- |
| A | `lua/dbee/sources.lua` | Optional `get_folder_for_connection(conn_id)` Source method and FileSource implementation. | Returns one normalized folder or nil; no union semantics. |
| B | `lua/dbee/handler/init.lua` | Lua facade for active connection folder lookup. | Uses existing sources/source lookup, no `vim.fn.Dbee*` endpoint. |
| C | `lua/dbee/api/ui.lua` | Picker section builder. | Global notes come from folder namespace or `{}`. Local notes unchanged. |
| D | `lua/dbee.lua` | Picker create action. | `<C-g>` creates in folder namespace or emits exact no-folder error. |
| E | `lua/dbee/notes_namespace.lua` | Folder namespace helper and lifecycle filesystem operations. | Validates folder IDs, checks runtime collisions, owns ensure/delete/list helpers. |
| F | `lua/dbee/notes_migration.lua` / `lua/dbee/api/state.lua` | One-time migration helper and lazy-handler bootstrap hook. | Runs after `Handler:new()` loads sources and before first UI/editor creation. |
| G | `lua/dbee/ui/editor/init.lua` | Startup default note selection and namespace wrapper delegation. | No automatic `global` welcome recreation; EditorUI delegates lifecycle helpers to `notes_namespace`. |
| H | `lua/dbee/ui/drawer/init.lua` | Folder add/delete/move actions. | Add mkdirs namespace with unwind on failure; delete cascades notes with confirmation; move only changes lookup result. |
| I | `lua/dbee/ui/drawer/convert.lua` | Folder row action decoration. | Row-level delete uses same note cascade path. |
| J | `plugin/dbee.lua` / `lua/dbee.lua` / `README.md` | `:Dbee notes_migration_cleanup`. | Completion callback includes the subcommand; deletes canonical backup paths only after prompt/explicit command; README documents the command. |
| K | `ci/headless/check_folder_scoped_notes.lua` | New Phase 23 behavior suite. | Emits 48 behavior/migration markers. |
| L | `ci/headless/check_notes_picker.lua` | Phase 19 preservation. | Emits existing NOTES01 markers plus folder-scoped cases. |
| M | `ci/headless/check_folder_persistence.lua` / `check_drawer_folders.lua` | FOLDER15 preservation. | Existing FOLDER15 markers remain green. |
| N | `Makefile` / `check_ux13_rollup.lua` | Rollup and locked-helper guard. | Emits `GN23_STRICT_MARKER_COUNT=52` and `GN23_ALL_PASS=true`; count check is the last rollup assertion. |

## Strict Markers

`GN23_STRICT_MARKER_COUNT` target is **52**. `GN23_ALL_PASS=true` is the final rollup sentinel and is not counted in the 52 strict markers. `GN23_FOLDER_ID_PATH_GUARD_OK` was already part of r1 and is retained with stricter regex-only coverage, so the 13 r1-review additions net to +12 new marker names. Revision r2 adds five strict markers for fresh-user migration, same-filesystem staging, per-file promotion, runtime cross-source collision checks, and stale scratch-dir GC. Revision r3 adds seven strict markers for persisted promote manifests, final-path recovery validation, zero-folder backup fatality, configured notes-dir migration, re-entry guard timing, README cleanup documentation, and zero-folder backup notification.

Behavior and migration markers:

1. `GN23_SOURCE_FOLDER_LOOKUP_API_OK`
2. `GN23_SINGLE_FOLDER_LOOKUP_OK`
3. `GN23_NO_FOLDER_NAMESPACE_EMPTY_OK`
4. `GN23_PICKER_USES_FOLDER_NAMESPACE_OK`
5. `GN23_PICKER_HINT_ROW_PRESERVED_OK`
6. `GN23_CG_CREATE_FOLDER_NOTE_OK`
7. `GN23_CG_NO_FOLDER_ERROR_OK`
8. `GN23_LOCAL_NOTES_UNCHANGED_OK`
9. `GN23_NO_LEGACY_GLOBAL_FALLBACK_OK`
10. `GN23_MIGRATION_LOCK_SERIALIZES_OK`
11. `GN23_MIGRATION_IDEMPOTENT_OK`
12. `GN23_FRESH_USER_NO_FOLDERS_PROCEED_OK`
13. `GN23_STARTUP_STALE_DIR_GC_OK`
14. `GN23_MIGRATION_SAME_FS_INVARIANT_OK`
15. `GN23_MIGRATION_CLONES_ALL_FOLDERS_OK`
16. `GN23_MIGRATION_BACKUP_CREATED_OK`
17. `GN23_GLOBAL_DIR_DELETED_OK`
18. `GN23_MIGRATION_PARTIAL_FAILURE_ROLLBACK_OK`
19. `GN23_MIGRATION_PER_FILE_PROMOTE_OK`
20. `GN23_NEW_FOLDER_NAMESPACE_EMPTY_OK`
21. `GN23_RENAME_FOLDER_NO_NAMESPACE_MOVE_OK`
22. `GN23_DELETE_FOLDER_NAMESPACE_CASCADE_OK`
23. `GN23_DELETE_FOLDER_NAMESPACE_RESTORE_ON_FAIL_OK`
24. `GN23_MOVE_CONN_NAMESPACE_SWITCH_OK`
25. `GN23_MIGRATION_CLEANUP_COMMAND_OK`
26. `GN23_EDITOR_NO_GLOBAL_WELCOME_RECREATE_OK`
27. `GN23_LAST_NOTE_GLOBAL_BACKUP_IGNORED_OK`
28. `GN23_FOLDER_ID_PATH_GUARD_OK`
29. `GN23_MIGRATION_PRECONDITION_LOAD_OK`
30. `GN23_MIGRATION_STAGED_PROMOTE_OK`
31. `GN23_MIGRATION_BACKUP_FAILURE_NON_FATAL_OK`
32. `GN23_MIGRATION_SENTINEL_RECOVERY_OK`
33. `GN23_HISTORY_SEARCH_NO_GLOBAL_OK`
34. `GN23_HANDLER_FACADE_DEFENSIVE_OK`
35. `GN23_MIGRATION_FOLDER_SNAPSHOT_POST_LOCK_OK`
36. `GN23_NAMESPACE_API_VALIDATES_FOLDER_ID_OK`
37. `GN23_FOLDER_DELETE_CASCADE_LIFECYCLE_OK`
38. `GN23_BULK_FOLDER_CREATE_NAMESPACE_OK`
39. `GN23_CROSS_SOURCE_FOLDER_ID_GUARD_OK`
40. `GN23_RUNTIME_CROSS_SOURCE_COLLISION_OK`
41. `GN23_HISTORY_SEARCH_BY_ROW_CONNECTION_OK`
42. `GN23_PROMOTE_MANIFEST_PERSISTED_OK`
43. `GN23_RECOVERY_MANIFEST_VALIDATES_FINAL_PATHS_OK`
44. `GN23_BACKUP_FAILURE_FATAL_IN_ZERO_FOLDER_PATH_OK`
45. `GN23_MIGRATION_NOTES_DIR_CONFIG_OK`
46. `GN23_REENTRY_GUARD_FAIL_FAST_OK`
47. `GN23_README_MIGRATION_CLEANUP_DOCUMENTED_OK`
48. `GN23_ZERO_FOLDER_BACKUP_NOTIFY_OK`
49. `GN23_FOLDER15_PRESERVED_OK`
50. `GN23_NOTES01_PICKER_CONTRACT_PRESERVED_OK`
51. `GN23_LOCKED_HELPERS_UNTOUCHED_OK`
52. `GN23_NO_GO_RPC_ADDED_OK`

Owner partition:

| Owner | Count | Markers |
| --- | --- | --- |
| `ci/headless/check_folder_scoped_notes.lua` | 48 | GN23 behavior/migration markers 1-48. |
| `ci/headless/check_ux13_rollup.lua` | 4 | Preservation/guard markers 49-52 plus count/all-pass sentinels. |

## Plan-Gate r2 Concerns

- Migration must run from `lua/dbee/api/state.lua` at the end of `setup_handler()`, after `Handler:new()` returns and before the first caller can create `EditorUI`.
- Migration atomicity must use load preconditions, duplicate-folder-id guard, same-filesystem preflight, `vim.loop.fs_mkdir(path, 448)` lock acquisition, post-lock sentinel recheck, staged clone verification, per-file promotion with persisted promote-manifest, rollback of only migration-created files, and final-path recovery-manifest handling.
- Fresh user state is not an error: `loaded_ok` with zero folders writes the sentinel as no-op when `global/` is absent, or backs up/deletes `global/` if legacy notes exist but no folders can receive clones; backup failure is fatal in this zero-folder branch because no clones exist.
- Concurrent nvim instances: folder snapshot happens only after lock acquisition and post-lock sentinel recheck; folders created after that snapshot are intentionally not seeded.
- Folder deletion: both drawer delete surfaces route through one notes namespace lifecycle helper, not direct filesystem work in convert/model.
- History search must use the selected history row's `conn_id`, never active connection and never legacy `global`.
- No-folder connection: empty global section and exact six-state picker/empty/error text matrix.
- Editor startup must not recreate `notes/global/`; empty buffers remain empty with nil `current_note_id`.
- Path safety: `^folder_[A-Za-z0-9]+$` is the sole folder ID gate for every `folder:<id>` namespace construction path.
- Runtime collision safety: lookup, namespace creation, and folder delete fail closed when a folder ID appears in more than one folder-capable source.
- Prompt path drift: implementation must target `lua/dbee/sources.lua`.

<deferred>

## v1.5 Cleanup Backlog

- Refine marker partitioning into separate behavior and migration rollup files if GN23 rollup maintenance becomes noisy. Phase 23 keeps one primary suite because the migration safety surface is tightly coupled.
- Promote a `lua/dbee/folder_authority.lua` helper if `Handler:list_all_folder_ids_across_sources()` becomes called from a redraw or per-keystroke path. Phase 23 keeps the Handler helper uncached because per-source folder loading is already memoized and runtime checks are not note-row loops.

</deferred>

## Verification Commands For Execute Phase

```bash
nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_folder_scoped_notes.lua"
nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_notes_picker.lua"
nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_folder_persistence.lua"
nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_drawer_folders.lua"
make gn23-rollup
```
