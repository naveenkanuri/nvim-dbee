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
| GN-10 | Folder created after migration gets an empty namespace directory only. No clone from legacy global notes after the sentinel exists. | Locked by prompt. This follows from deleting `notes/global/` and using a migration sentinel. |
| GN-11 | Picker performance remains O(notes in current folder + local notes). No cross-folder scan on picker open. | `pick_notes()` currently consumes prebuilt sections once at `lua/dbee.lua:558-560`; keep that shape. |
| GN-12 | Migration requires both a lock and a sentinel. Sentinel-only check/set is not enough for two simultaneous nvim instances. | Two processes can both pass a pre-sentinel check. Use `vim.loop.fs_mkdir(path, 448)` for atomic lock directory acquisition, handle EEXIST, treat stale locks as 5 minutes old, then write `.notes-migration-v1` after staged clone promotion. |
| GN-13 | Keep a backup of legacy global notes under `notes/global.bak`, `notes/global.bak.YYYYMMDDHHMMSS`, or `notes/.phase23-backups/global.YYYYMMDDHHMMSS` and add manual cleanup via `:Dbee notes_migration_cleanup`. | GN-OPEN-4 accepted with prompt's manual cleanup path. Backup is not a namespace used by picker, and backup creation failure is non-fatal after clones are promoted. |
| GN-14 | Editor startup must not recreate `notes/global/welcome.sql` after migration and must tolerate an empty notes buffer. | Current fallback creates welcome in `"global"` at `lua/dbee/ui/editor/init.lua:171-177` and `:268-281`; this is a Phase 23 regression risk. If no folder/local note exists, `EditorUI:show()` must keep `current_note_id = nil` without creating a note. |
| GN-15 | Folder namespace filesystem helpers must validate generated folder IDs before constructing paths, with `^folder_[A-Za-z0-9]+$` as the sole gate. | FOLDER15 generated IDs are `folder_` plus alphanumeric random string (`lua/dbee/sources.lua:447`, `lua/dbee/utils.lua:151-165`). Regex-only validation rejects nil, empty, missing underscore, wrong case, slashes, NUL, dots, `..`, and hyphens without maintaining a redundant substring blacklist. |
| GN-16 | Folder deletion should stage namespace deletion so handler failure can restore note files, and both delete surfaces must use one EditorUI-backed lifecycle helper. | Current folder delete calls `handler:source_remove_folder()` directly from both drawer action surfaces (`lua/dbee/ui/drawer/init.lua:4094-4096`, `lua/dbee/ui/drawer/convert.lua:496-506`). Direct filesystem operations do not belong in convert/model layers. |
| GN-17 | Do not touch locked helper files. | Prompt constraint: `schema_filter_authority.lua`, `schema_name_canonical.lua`, `lsp/epoch_authority.lua` remain unchanged. |
| GN-18 | Prompt path drift: `lua/dbee/sources/file.lua` does not exist; the implementation target is `lua/dbee/sources.lua`. | `rg --files lua/dbee` shows only `lua/dbee/sources.lua` for source implementations. |
| GN-19 | Folder IDs are source-local in Phase 15. Phase 23 namespace = `folder:<folder_id>` does not include source ID. If two sources have the same `folder_id` via manual sidecar edit, namespace collision would merge notes. | Migration adds a duplicate-folder-id guard: enumerate folder IDs across all folder-capable sources; if any duplicate exists, abort before filesystem mutation with `vim.notify('dbee: duplicate folder_id detected across sources; migration aborted. Repair sidecars before retry.')`. |

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

- Exact helper names, as long as the Source-owned lookup and Handler facade are clear and no Go RPC endpoint is added.
- Exact timestamp source for backup variants, as long as backup paths are limited to `notes/global.bak`, `notes/global.bak.YYYYMMDDHHMMSS`, or `notes/.phase23-backups/global.YYYYMMDDHHMMSS`.
- Exact implementation of stale migration-lock cleanup, as long as the stale threshold is 5 minutes, lock acquisition uses `vim.loop.fs_mkdir(path, 448)` with EEXIST handling, and a second nvim instance cannot concurrently clone/delete.

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
- `lua/dbee/ui/editor/init.lua:883-1023` - namespace-to-directory mapping, create/get/load note APIs.
- `lua/dbee/ui/editor/init.lua:1025-1108` - namespace remove and note rename filesystem operations.

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
- Editor namespace APIs already support arbitrary string namespace IDs and directory-backed note loading.

### Established Patterns
- Atomic writes use temp file plus `uv.fs_rename` in `lua/dbee/sources.lua:99-132`.
- User-facing destructive drawer actions use `vim.ui.select` confirmation, then refresh.
- Headless tests emit strict `*_OK=true` markers and rollups assert preservation.

### Integration Points
- Picker global namespace resolution belongs in `api/ui.lua`, because `dbee.pick_notes()` should stay mostly presentation-only.
- Migration and namespace filesystem helpers belong in `EditorUI`, because it owns `directory`, note state, and namespace path construction.
- Folder delete confirmation exists in drawer action surfaces, but deletion of the notes namespace needs EditorUI participation.

</code_context>

<migration_safety>
## Migration Safety Analysis

Required migration state:

1. Precondition: `notes/global/*.sql` may exist.
2. Existing folders at migration time are loaded from every folder-capable source.
3. Every folder-capable source must have `_folders_load_state == "loaded_ok"` before any filesystem mutation. If any source has `load_failed` or claims folder capability while returning no folders, abort without backup, delete, or sentinel.
4. Folder IDs are checked for duplicates across all folder-capable sources before namespace creation.
5. For each folder ID, stage clones under `notes/.phase23-staging-<pid>-<random>/folder:<id>/`; no clone writes directly to final namespace paths.
6. Verify staged file counts, then promote staged namespaces into final `notes/folder:<folder_id>/` paths with rollback of any promoted final dirs if a rename fails.
7. Preserve a backup by renaming/copying legacy `notes/global/` to a backup path outside picker use. Backup creation failure logs a warning and does not invalidate a completed clone promotion.
8. Remove the original `notes/global/` path. Deletion failure logs a warning; sentinel can still be written because folder clones are in place.
9. Atomically write `notes/.notes-migration-v1` through a tmp file then rename. If sentinel write fails after clones are promoted, emit a warning and create `notes/.phase23-recovery-needed`; the next launch recovery path writes the missing sentinel.

Concurrency contract:

- Acquire `notes/.phase23-migration.lock` via `vim.loop.fs_mkdir(path, 448)` before any clone/delete.
- After lock acquisition, re-check sentinel because another instance may have finished while this instance waited.
- After lock acquisition and sentinel recheck, enumerate folders via `list_existing_folder_namespaces()`. Folders created by other instances after this snapshot are intentionally not seeded.
- If lock acquisition fails with EEXIST, wait briefly and re-check sentinel. If sentinel appears, skip. If lock is older than 5 minutes, report a warning and avoid destructive migration until the stale lock is resolved.
- Write the sentinel only after staged clone promotion completes. Backup and delete failures are warning-only after clones are in place.
- Migration is idempotent: if sentinel exists, do nothing; if `global/` is absent and sentinel missing, write sentinel after ensuring current folder namespace dirs exist. If `.phase23-recovery-needed` exists, write the missing sentinel and clear the marker.

Data-loss guard:

- Folder deletion is the only Phase 23 operation that intentionally deletes non-backup user note files. It must require confirmation that mentions note deletion.
- Namespace deletion should stage/rename the directory before source mutation, then finalize only after folder removal succeeds; restore the staged directory on handler failure.

</migration_safety>

<deferred>
## Deferred Ideas

- Cross-folder global note union.
- Installation-wide/global fallback namespace.
- Automatic cleanup of `global.bak` after 30 days. Phase 23 provides manual cleanup only.
- Marker partition refinement into separate behavior and migration rollup files; Phase 23 keeps one primary suite and records this as a v1.5 cleanup item.

</deferred>

---

*Phase: 23-folder-scoped-notes*
*Context gathered: 2026-05-06*
