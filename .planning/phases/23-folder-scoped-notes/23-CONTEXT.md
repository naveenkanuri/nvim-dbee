# Phase 23: Folder-Scoped Global Notes - Context

**Gathered:** 2026-05-06
**Status:** Ready for planning
**Source:** User-supplied combined discuss/research/plan prompt, `.planning/ROADMAP.md`, local code scout

<domain>
## Phase Boundary

Phase 23 removes installation-wide global notes and re-scopes the picker "Global notes" section to the active connection's folder. The folder namespace is the notes directory name:

```text
<state-home>/dbee/notes/folder:<folder_id>/*.sql
```

Connections assigned to a folder see that folder's global notes. Connections not assigned to any folder show an empty "Global notes" section and cannot create global notes with `<C-g>`. Local notes remain per-connection and unchanged.

This phase is adapter-agnostic. It is a Lua notes/source/drawer lifecycle change, not a Go adapter, schema, LSP, or RPC backend change.

</domain>

<decisions>
## Implementation Decisions

### GN Decision Matrix

| ID | Decision | Evidence / rationale |
| --- | --- | --- |
| GN-01 | Remove installation-wide global notes. No-folder connections show an empty global picker and no fallback to legacy `global`. | Locked by prompt. Current picker reads `namespace_get_notes("global")` in `lua/dbee/api/ui.lua:263`; this must stop. |
| GN-02 | Folder-scoped namespace ID is exactly `"folder:" .. folder_id`; directory name is the same namespace string. | Locked by prompt. Existing editor maps namespace directly to directory via `EditorUI:dir()` at `lua/dbee/ui/editor/init.lua:883-884`. |
| GN-03 | One-time migration clones current `notes/global/*.sql` into every folder namespace that exists at migration time, then removes the `notes/global/` path. | Locked by prompt. Migration must run before editor fallback code can recreate `global`. |
| GN-04 | Local notes remain `namespace_id = connection_id`. | Current local picker path uses `editor:namespace_get_notes(conn_id)` at `lua/dbee/api/ui.lua:277`; preserve this. |
| GN-05 | Folder create/delete/rename/move have note namespace semantics: create -> mkdir, rename -> no move, delete -> delete folder namespace, move connection -> namespace switch only. | Locked by prompt. Phase 15 folder operations are already source-level in `lua/dbee/sources.lua:427-590`. |
| GN-06 | Phase 19 picker contract is preserved: hint row at items[1], dynamic `<C-g>` and `<C-l>`, no source tags in display rows. | Current picker puts the hint first at `lua/dbee.lua:565-576` and wires actions at `lua/dbee.lua:628-645`. |
| GN-07 | Folder lookup should extend the existing Source contract, then expose a Lua Handler facade for UI routing. Do not query drawer caches. Do not add Go RPC endpoints. | `FileSource` owns folder truth in `lua/dbee/sources.lua:407-413`; drawer caches are presentation-only. Handler already provides source folder facades at `lua/dbee/handler/init.lua:2628-2708`. |
| GN-08 | Single-folder membership is the only supported model. No union of multiple folder note sets. | Phase 15 plan states "A connection ID may appear in AT MOST ONE folder"; current normalization keeps the first duplicate and warns at `lua/dbee/sources.lua:311-320`; moves remove from all folders before insert at `lua/dbee/sources.lua:572-586`. |
| GN-09 | If a malformed/manual sidecar creates duplicate membership, picker resolves the normalized single folder and emits/keeps FOLDER15 warning behavior rather than implementing union semantics. | Hard-erroring on duplicate load would regress FOLDER15's corrupt-sidecar display fallback. Plan-gate should verify this tradeoff. |
| GN-10 | Folder created after migration gets an empty namespace directory only. No clone from legacy global notes after the sentinel exists. | Locked by prompt. This follows from deleting `notes/global/`, writing `.notes-migration-v1`, and routing new folder creation through namespace ensure. |
| GN-11 | Picker performance remains O(notes in current folder + local notes). No cross-folder scan on picker open and no source-cache invalidation on read paths. | `pick_notes()` currently consumes prebuilt sections once at `lua/dbee.lua:558-560`; keep that shape. Runtime cross-source collision checks may enumerate folder IDs on folder lookup, namespace creation, and folder delete, but picker note loading still stays folder+local only. The only blessed folder-cache invalidation outside FOLDER15 mutation paths is the migration helper's post-lock reload. |
| GN-12 | Migration requires a lock, sentinel, and fatal-process latch. Sentinel-only check/set is not enough for two simultaneous nvim instances, and migration exceptions must block later UI/editor/drawer construction in the same process. | Two processes can both pass a pre-sentinel check. Use `vim.loop.fs_mkdir(path, 448)` for atomic `.notes-migration-v1.lock` acquisition, handle EEXIST with 5-minute positive stale-age cleanup, treat future-dated lock mtime as fresh, then write `.notes-migration-v1` after staged clone promotion. `setup_handler()` wraps `notes_migration.maybe_run(...)` in `pcall`; on error it sets `m.migration_fatal_failed = true`, rethrows, and all public accessors/setup paths fail with `dbee migration failed; restart nvim to retry` before constructing UI state. |
| GN-13 | Keep a canonical backup of legacy global notes under `notes/global.bak`, falling back to `notes/global.bak.YYYYMMDDHHMMSS` only if `global.bak` already exists. | Backup is not a namespace used by picker. Backup uses `vim.loop.fs_rename` only; no copy fallback. Backup creation failure is non-fatal after clones are promoted, but fatal in the zero-folder legacy path because no clones exist. No backup subdirectory variant is supported; cleanup only matches the two canonical `global.bak` forms. |
| GN-14 | Editor startup must not recreate `notes/global/welcome.sql` after migration and must tolerate an empty notes buffer. | Current fallback creates welcome in `"global"` at `lua/dbee/ui/editor/init.lua:171-177` and `:268-281`; this is a Phase 23 regression risk. If no folder/local note exists, `EditorUI:show()` must keep `current_note_id = nil` without creating a note. |
| GN-15 | Folder namespace filesystem helpers must validate generated folder IDs before constructing paths, with `^folder_[A-Za-z0-9]+$` as the sole gate. All `folder:<id>` construction and folder-note creation must route through `lua/dbee/notes_namespace.lua`. | FOLDER15 generated IDs are `folder_` plus alphanumeric random string (`lua/dbee/sources.lua:447`, `lua/dbee/utils.lua:151-165`). Regex-only validation rejects nil, empty, missing underscore, wrong case, slashes, NUL, dots, `..`, and hyphens without maintaining a redundant substring blacklist. `EditorUI:namespace_create_note("folder:<id>", ...)` throws unless called with an authority flag set only by `notes_namespace.create_note_in_folder(...)`. |
| GN-16 | Folder deletion should stage namespace deletion so handler failure can restore note files, and both delete surfaces must use one notes namespace lifecycle helper. | Current folder delete calls `handler:source_remove_folder()` directly from both drawer action surfaces (`lua/dbee/ui/drawer/init.lua:4094-4096`, `lua/dbee/ui/drawer/convert.lua:496-506`). Direct filesystem operations do not belong in convert/model layers. `EditorUI` may expose thin wrappers, but `lua/dbee/notes_namespace.lua` owns filesystem lifecycle. |
| GN-17 | Do not touch locked helper files. | Prompt constraint: `schema_filter_authority.lua`, `schema_name_canonical.lua`, `lsp/epoch_authority.lua` remain unchanged. |
| GN-18 | Prompt path drift: `lua/dbee/sources/file.lua` does not exist; the implementation target is `lua/dbee/sources.lua`. | `rg --files lua/dbee` shows only `lua/dbee/sources.lua` for source implementations. |
| GN-19 | Folder IDs are source-local in Phase 15. Phase 23 namespace = `folder:<folder_id>` does not include source ID. If two sources have the same `folder_id` via manual sidecar edit, namespace collision would merge notes; if any folder-capable source load is uncertain, uniqueness cannot be proven. | Folder load parse/read failures must surface as `_folders_load_state == "load_failed"` or an explicit error, not silently collapse to `{}`. `Handler:list_all_folder_ids_across_sources()` returns `(counts, error_kind?)`. Migration, lookup, namespace ensure, and namespace delete fail closed if `error_kind` is set or if the requested folder ID appears in more than one source. Lookup/ensure use `vim.notify('dbee: folder_id <id> exists in multiple sources; manual sidecar repair needed', vim.log.levels.ERROR)` for duplicates and a folder-load-failure notify for uncertainty. Delete uses `vim.notify('dbee: folder_id <id> duplicated across sources; refusing delete to prevent shared-namespace data loss', vim.log.levels.ERROR)` and similarly refuses on uncertainty. |
| GN-20 | Staging, trash, backup, and final promotion use same-filesystem `vim.loop.fs_rename` only. Cross-filesystem rename is unsupported, and promote crash recovery uses one pre-recorded manifest rather than per-rename manifest updates. | Before staging, compare `vim.loop.fs_statfs(notes_dir)` with a sibling precheck directory. If devices differ or any rename returns `EXDEV`, abort with `vim.notify('dbee: migration aborted — cross-filesystem rename detected; not supported. Move notes/ off bind mounts and retry, OR set editor.directory in setup() to a same-filesystem path and retry.', vim.log.levels.ERROR)`. Promotion writes `.notes-migration-v1.promote-manifest` once before the first file rename with complete `entries[]`, `expected_count`, `promote_complete=false`, and `migration_run_ts`; after all renames succeed it rewrites the manifest with `promote_complete=true`. No copy+unlink fallback because partial copies would create a harder data-loss surface. |

### Adapter Topology

N/A. Notes namespaces are source/folder scoped and do not depend on database adapter type, schema topology, LSP cache identity, or Go driver behavior.

### Cross-Phase Contract Impact

| Phase | Contract | Phase 23 impact |
| --- | --- | --- |
| Phase 15 / FOLDER15 | Per-source `folders.json` sidecar, copy-on-write writes, `_require_folders_writeable` gate, single-folder membership. | Preserve sidecar format and write gates. Add read-only folder lookup helper and note namespace lifecycle around existing folder mutations. |
| Phase 19 | Snacks picker has hint row first, dynamic `<C-g>`/`<C-l>`, empty-state hints, no tags. | Keep picker layout and key wiring. Change only the global namespace backing data and no-folder `<C-g>` error. |
| Phase 6 / NOTES-01 | Picker visually separates global and local notes. | Preserve section labels. "Global notes" now means active folder namespace. |
| Phase 18 / locked helpers | Do not modify schema filter/canonical/epoch authority helpers. | No expected dependency; include locked-helper guard in validation. |

### the agent's Discretion

- Exact helper names inside `lua/dbee/notes_namespace.lua` and `lua/dbee/notes_migration.lua`, as long as the module boundaries, Source-owned lookup, and Handler facade are clear and no Go RPC endpoint is added.
- Exact timestamp source for backup variants, as long as backup paths are limited to `notes/global.bak` and `notes/global.bak.YYYYMMDDHHMMSS` where timestamp is `os.date('%Y%m%d%H%M%S')`.
- Exact implementation of stale migration-lock cleanup, as long as the stale threshold is 5 minutes, lock acquisition uses `vim.loop.fs_mkdir(path, 448)` with EEXIST handling, future-dated lock mtimes are treated as fresh, and a second nvim instance cannot concurrently clone/delete.
- `Handler:list_all_folder_ids_across_sources()` recomputes per call with no cache and returns `(counts, error_kind?)`. `_ensure_folders_loaded()` already memoizes per-source reads, so Phase 23 duplicate checks are bounded to in-memory counts; load uncertainty still fails closed.
- The migration helper may reset folder-capable sources from `_folders_load_state = "loaded_ok"` to `"unloaded"` only after acquiring the migration lock and rechecking sentinel/manifests. This is the one blessed cache invalidation outside FOLDER15 mutation paths.

</decisions>

<canonical_refs>
## Canonical References

Downstream agents MUST read these before planning or implementing.

### Phase Scope
- `.planning/ROADMAP.md:422-438` - Phase 23 dependencies, locked decisions, and open questions.
- `.planning/phases/15-connection-folder-grouping/PLAN.md` - FOLDER15 source/sidecar contracts, single-folder membership, write gates, and drawer action semantics.

### Notes Picker And Editor
- `lua/dbee.lua:548-650` - Phase 19 `pick_notes()` contract, hint row, section rendering, `<C-g>`/`<C-l>` actions.
- `lua/dbee/api/ui.lua:249-280` - current note picker section source; currently reads legacy `global`.
- `lua/dbee/api/ui.lua:285-317` - flat note search helper used by history picker; must stop searching legacy `global`.
- `lua/dbee/ui/editor/init.lua:53-87` - editor construction, default notes directory and last-note state path.
- `lua/dbee/ui/editor/init.lua:157-177` and `:268-281` - current startup/welcome behavior that can recreate `global`.
- `lua/dbee/ui/editor/init.lua:883-1023` - existing namespace-to-directory mapping, create/get/load note APIs; Phase 23 delegates folder namespace validation/lifecycle to `lua/dbee/notes_namespace.lua`.
- `lua/dbee/ui/editor/init.lua:1025-1108` - namespace remove and note rename filesystem operations.
- `lua/dbee/api/state.lua:35-68` - lazy handler bootstrap path; Phase 23 migration hook runs at the end of `setup_handler()` after `Handler:new()` returns and before first UI/editor creation, with a fatal latch checked before early returns and UI/editor/drawer accessors.
- `lua/dbee/notes_namespace.lua` - new canonical folder namespace validation/lifecycle module.
- `lua/dbee/notes_migration.lua` - new canonical notes migration module.

### Folder Source And Drawer
- `lua/dbee/sources.lua:30-37` - optional Source folder API.
- `lua/dbee/sources.lua:288-320` - folder normalization and duplicate membership warning.
- `lua/dbee/sources.lua:407-590` - load/add/rename/remove/move folder methods.
- `lua/dbee/handler/init.lua:2628-2708` - Handler folder facades and folder mutation events.
- `lua/dbee/ui/drawer/init.lua:3992-4200` - drawer add/rename/delete/move folder actions.
- `lua/dbee/ui/drawer/convert.lua:476-514` - folder row action decoration.
- `lua/dbee/ui/drawer/model.lua:250-310` and `lua/dbee/ui/drawer/convert.lua:685-728` - folder rendering/search model source.

### Tests And Rollups
- `ci/headless/check_notes_picker.lua` - NOTES-01 and Phase 19 picker contract tests.
- `ci/headless/check_folder_persistence.lua` - FOLDER15 source persistence and sidecar safety tests.
- `ci/headless/check_drawer_folders.lua` - FOLDER15 drawer action tests.
- `ci/headless/check_ux13_rollup.lua` - existing rollup pattern for preservation markers.
- `Makefile` - headless check target wiring.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- Source-side folder cache and normalization already exist in `FileSource`; Phase 23 should extend them with a read helper instead of re-scanning drawer render state.
- Handler already tracks `source_conn_lookup` and source IDs, so a Lua-only current-connection folder facade can be implemented without Go RPC.
- Editor namespace APIs already support arbitrary string namespace IDs and directory-backed note loading; Phase 23 centralizes folder namespace validation outside `EditorUI` so migration can run before UI construction. Raw folder namespace creation is blocked unless `notes_namespace` passes an authority flag.

### Established Patterns
- Atomic writes use temp file plus `uv.fs_rename` in `lua/dbee/sources.lua:99-132`.
- User-facing destructive drawer actions use `vim.ui.select` confirmation, then refresh.
- Headless tests emit strict `*_OK=true` markers and rollups assert preservation.

### Integration Points
- Picker global namespace resolution belongs in `api/ui.lua`, because `dbee.pick_notes()` should stay mostly presentation-only.
- Migration belongs in `lua/dbee/notes_migration.lua` because it runs before `EditorUI` exists. Its module header must document the two on-disk manifests (`.notes-migration-v1.promote-manifest`, `.notes-migration-v1.recovery-needed`) plus the in-memory `promote_rollback_paths` list and their crash-recovery semantics. Folder namespace validation and lifecycle filesystem helpers belong in `lua/dbee/notes_namespace.lua`; `EditorUI` delegates thin wrappers to that module when UI actions need the configured notes directory.
- Folder delete confirmation exists in drawer action surfaces, but deletion of the notes namespace needs EditorUI participation.

</code_context>

<migration_safety>
## Migration Safety Analysis

Required migration state:

1. Precondition: `notes/global/*.sql` may exist.
2. Existing folders at migration time are snapshotted inside the migration lock. A pre-lock pass may confirm folder-capable sources exist, but it is not the authoritative snapshot because `_ensure_folders_loaded()` can return cached data.
3. Every folder-capable source must have `_folders_load_state == "loaded_ok"` before any notes data filesystem mutation. If any source has `load_failed`, or if `Handler:list_all_folder_ids_across_sources()` returns `error_kind`, abort without backup, delete, clone promotion, or sentinel.
4. Empty folder lists under `loaded_ok` are valid fresh-user states. If every folder-capable source is `loaded_ok` and the total folder count is zero:
   - if `notes/global/` is absent or contains no readable `*.sql` files, write `.notes-migration-v1` as a no-op success.
   - if `notes/global/` contains readable `*.sql` files, create the canonical backup, delete `notes/global/`, and write `.notes-migration-v1` without clones. Backup creation failure aborts with an ERROR notification before global deletion/sentinel write because backup is the only surviving copy in this branch. After successful backup/delete, notify the user where legacy notes were backed up.
5. Folder IDs are checked for duplicates and load uncertainty across all folder-capable sources before namespace creation. The same fail-closed authority check runs at runtime lookup, namespace creation, folder-note creation, and folder namespace delete.
6. Before staging, remove stale `.notes-migration-v1.staging-<pid>-*` and `.notes-migration-v1.trash-<pid>-*` dirs unless both conditions are true: pid is still alive AND mtime age is <= 1 hour. This avoids pid-reuse keeping old scratch dirs forever. Recursive removal uses `vim.fn.delete(path, "rf")` through `notes_namespace.recursive_rmdir(path)` and checks the `0` success return code.
7. Staging/trash dirs are same-filesystem siblings of final namespace dirs. Verify the invariant with `vim.loop.fs_statfs(notes_dir)` and a sibling precheck dir before creating staging dirs; abort on mismatch with the GN-20 notify text.
   - `notes_dir` top-level cardinality is bounded by total folder count across folder-capable sources plus sentinel/manifest/lock/scratch files. Expected steady-state is <= 100 entries, so readdir cost is O(folders), not O(notes).
8. For each folder ID, stage clones under `notes/.notes-migration-v1.staging-<pid>-<random>/folder:<id>/`; no clone writes directly to final namespace paths.
9. Verify staged file counts, then pre-record the complete promote manifest before any rename. The manifest contains `expected_count`, `promote_complete=false`, `migration_run_ts`, and `entries[]` of `{src_staging, planned_dst, collision_suffix}` where `planned_dst` is the actual collision-resolved final path. Collision suffix decisions happen before the first rename. Then promote staged files into final `notes/folder:<folder_id>/` paths per file using only the pre-recorded `planned_dst` values. Track every successfully-created final path in `promote_rollback_paths` for in-process rollback.
10. If `vim.loop.fs_rename` returns `EXDEV` at any point, abort with the GN-20 notification. Do not attempt copy+unlink fallback.
11. Preserve a backup by atomically renaming legacy `notes/global/` to `notes/global.bak`, or `notes/global.bak.YYYYMMDDHHMMSS` if the default backup already exists. Backup uses `vim.loop.fs_rename` only; no copy fallback. Backup creation failure logs a warning and does not invalidate a completed clone promotion. This non-fatal rule does not apply to the zero-folder legacy path.
12. Remove the original `notes/global/` path. Deletion failure logs a warning; sentinel can still be written because folder clones are in place or legacy notes are backed up for the no-folder path.
13. Atomically write `notes/.notes-migration-v1` through a tmp file then rename. If sentinel write fails after migration is functionally complete, emit a warning and write `notes/.notes-migration-v1.recovery-needed` as a recovery-manifest JSON containing folder IDs, actual final paths, backup path, global deletion state, and timestamp. The next launch recovery path validates exact `final_paths` before writing the missing sentinel. After a normal sentinel write succeeds, delete `.notes-migration-v1.promote-manifest` and clear `promote_rollback_paths`.

Three migration manifest concepts must not be conflated:

1. `promote_rollback_paths` - in-memory list of `planned_dst` values successfully created in this process for rollback on per-file rename failure.
2. `promote-manifest` - on-disk persistent file at `.notes-migration-v1.promote-manifest` written once before the first rename with the complete pre-recorded `entries[]`, then rewritten once with `promote_complete=true` after all renames succeed.
3. `recovery-manifest` - on-disk JSON at `.notes-migration-v1.recovery-needed` written only on sentinel-write failure after promote success.

Concurrency contract:

- Acquire `notes/.notes-migration-v1.lock` via `vim.loop.fs_mkdir(path, 448)` before any clone/delete.
- After lock acquisition, re-check sentinel because another instance may have finished while this instance waited.
- After lock acquisition and sentinel/recovery-manifest recheck, reset folder-capable source caches to `_folders_load_state = "unloaded"` and call `_ensure_folders_loaded()` to re-read folder sidecars under lock. Folders created by other instances after this snapshot are intentionally not seeded.
- If lock acquisition fails with EEXIST, stat the lock and compute `age_seconds = os.time() - stat.mtime.sec`. Negative age means clock skew/future-dated lock and is treated as fresh. Positive age under 300 seconds is fresh. Positive age at or above 300 seconds is stale; attempt `vim.loop.fs_rmdir(lock_path)` and retry mkdir once.
- Write the sentinel only after staged clone promotion completes. Backup and delete failures are warning-only after clones are in place.
- Migration is idempotent: if sentinel exists, do nothing; if `global/` is absent and sentinel missing, write sentinel after ensuring current folder namespace dirs exist. Recovery precedence is locked: if `.notes-migration-v1.recovery-needed` exists, validate exact `final_paths`, write the missing sentinel, delete recovery-needed, and delete promote-manifest if it also exists. Else if `.notes-migration-v1.promote-manifest` exists with `promote_complete=true`, require entry count to equal `expected_count`, validate every persisted `planned_dst` with non-zero size, resume backup/delete/sentinel completion, and delete the promote-manifest only after sentinel succeeds. Else if promote-manifest exists with `promote_complete=false`, validate every persisted `planned_dst`; if all exist, treat it as the complete promote case and resume backup/delete/sentinel completion, otherwise abort with cleanup guidance and keep the manifest for forensics.

Data-loss guard:

- Folder deletion is the only Phase 23 operation that intentionally deletes non-backup user note files. It must require confirmation that mentions note deletion.
- Namespace deletion should first verify folder loads are certain and the folder ID appears in exactly one source, then stage/rename the directory to `.notes-migration-v1.trash-<pid>-<random>/folder:<id>/` before source mutation, then finalize only after folder removal succeeds; restore the staged directory on handler failure. Cross-filesystem rename is unsupported and fails closed before source mutation. After successful trash promotion/removal, clear the editor namespace cache for `folder_namespace_id(folder_id)`.

</migration_safety>

<deferred>
## Deferred Ideas

- Cross-folder global note union.
- Installation-wide/global fallback namespace.
- Automatic cleanup of `global.bak` after 30 days. Phase 23 provides manual cleanup only.
- Marker partition refinement into separate behavior and migration rollup files; Phase 23 keeps one primary suite and records this as a v1.5 cleanup item.
- Future notes migrations use `.notes-migration-v2.*`, `.notes-migration-v3.*`, etc. Users upgrading directly from pre-Phase-23 to later phases must still run the v1 sentinel path before any later migration assumes folder-scoped notes.
- Promote duplicate-folder authority into `lua/dbee/folder_authority.lua` if `Handler:list_all_folder_ids_across_sources()` becomes a redraw or per-keystroke hot path. That future helper must follow the Phase 14 single-source pattern with an `ALL_CONSUMERS_ROUTED` sentinel and explicit invalidation events.

</deferred>

---

*Phase: 23-folder-scoped-notes*
*Context gathered: 2026-05-06*
