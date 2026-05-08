<phase_overview>
Phase 25 is a single-file performance polish phase for the Phase 23 folder-scoped global notes migration helper. It targets the migration hot path in `lua/dbee/notes_migration.lua` and must preserve all Phase 23 lifecycle, recovery, namespace, command, and marker contracts.

The core change set is limited to:
- one atomic pre-promotion manifest write instead of the current pre-promotion write plus post-promotion rewrite;
- one `ensure_dir` per unique final folder instead of per promoted entry;
- one copy buffer read that returns byte length for `src_size_bytes`, while verification and recovery continue to stat final/staged files.
</phase_overview>

<decisions>
ORA25-01: Scope is only `lua/dbee/notes_migration.lua` for implementation; no other repository file may change during execution.
ORA25-02: Manifest single-flip uses the existing temp-file plus `uv.fs_rename` atomic write path.
ORA25-03: The safe single-flip point is after all manifest entries are built and before the first final rename; a post-promotion-only manifest is forbidden because it loses mid-promote crash evidence.
ORA25-04: Final destination directory creation is hoisted by precomputing unique `dirname(entry.planned_dst)` values and ensuring each once before the promote rename loop.
ORA25-05: Staging directory creation remains unchanged: staging root once, staged namespace directory once per folder, before copy.
ORA25-06: `src_size_bytes` is computed from the copied buffer length and keeps the existing manifest field name and meaning.
ORA25-07: Verification and recovery remain stat-backed; staged/final path and size mismatch detection must not rely only on in-memory copy length.
ORA25-08: Crash safety is preserved by keeping the promote manifest as the in-progress recovery artifact and the `.notes-migration-v1` sentinel as the lifecycle completion artifact.
ORA25-09: Per-connection isolation is preserved; legacy local namespace rename behavior and folder namespace derivation are not changed.
ORA25-10: Bench harness uses synthetic corpora and never the user's real state directory.
ORA25-11: Budgets are locked: small P50 <= 50ms, medium P50 <= 150ms, large P50 <= 500ms, and the Phase 23 diagnostic shape P50 <= 250ms.
ORA25-12: Strict markers are `ORA25_MIGRATION_BUDGET_OK=true` and `PHASE25_ALL_PASS=true`; `LIVE_PG25_MIGRATION_MS`, `ORA25_MIGRATION_MS_P50`, and `ORA25_MIGRATION_MS_P95` are diagnostic.
ORA25-13: The three locked helpers remain untouched: `lua/dbee/schema_filter_authority.lua`, `lua/dbee/schema_name_canonical.lua`, and `lua/dbee/lsp/epoch_authority.lua`.
ORA25-14: Phase 23 GN23 invariants remain required: 94 strict markers still emit and roll up to `GN23_ALL_PASS=true`.
ORA25-15: Existing migration user commands remain compatible: `notes_migration_inspect` is pure-read and `notes_migration_cleanup_backups` cleanup semantics are unchanged.
ORA25-16: Rollback correctness remains bounded to migration-created final files tracked in `promote_rollback_paths`; no cleanup may delete pre-existing folder notes.
</decisions>

<canonical_refs>
- `lua/dbee/notes_migration.lua:83-85` defines `file_size()` as a `uv.fs_stat` wrapper.
- `lua/dbee/notes_migration.lua:135-144` implements atomic temp-file write plus `uv.fs_rename`.
- `lua/dbee/notes_migration.lua:258-270` reads and writes copied SQL file contents.
- `lua/dbee/notes_migration.lua:279-280` defines `ensure_dir()` as `vim.fn.mkdir(path, "p")`.
- `lua/dbee/notes_migration.lua:897-933` stages copied global notes and currently records `src_size_bytes` via `file_size(staged_path)`.
- `lua/dbee/notes_migration.lua:936-954` verifies staged paths and sizes before promotion.
- `lua/dbee/notes_migration.lua:957-999` builds the promote manifest, writes it twice today, ensures final dirs per entry, and promotes staged files.
- `lua/dbee/notes_migration.lua:718-741` writes the migration sentinel after promotion completion and writes recovery-needed on sentinel failure.
- `.planning/phases/23-folder-scoped-notes/23-CONTEXT.md:31` locks global-note cloning into every folder namespace and removal of `notes/global/`.
- `.planning/phases/23-folder-scoped-notes/23-CONTEXT.md:40` locks migration lock, sentinel, pre-register in-progress probe, and fatal-process latch behavior.
- `.planning/phases/23-folder-scoped-notes/23-CONTEXT.md:45` locks the three helper files that Phase 25 must not touch.
- `.planning/phases/23-folder-scoped-notes/23-03-PLAN.md:254-280` names the locked helper guard and rollup markers.
- `.planning/phases/23-folder-scoped-notes/PLAN.md:118` locks the Phase 23 strict marker target at 94.
</canonical_refs>

<scope_fence>
Allowed implementation change:
- `lua/dbee/notes_migration.lua`

Allowed Phase 25 planning artifacts:
- `.planning/phases/25-notes-perf-polish/PLAN.md`
- `.planning/phases/25-notes-perf-polish/25-CONTEXT.md`
- `.planning/phases/25-notes-perf-polish/25-01-PLAN.md`

Forbidden implementation changes:
- `lua/dbee/schema_filter_authority.lua`
- `lua/dbee/schema_name_canonical.lua`
- `lua/dbee/lsp/epoch_authority.lua`
- command registration, cleanup/inspect command bodies, README, Makefile, CI scripts, Go endpoint files, and unrelated Lua modules.
</scope_fence>

<deferred>
- No manifest schema migration.
- No new repository benchmark file unless a later phase explicitly widens scope.
- No changes to Phase 23 command UX or documentation.
- No broader notes namespace refactor.
- No additional folder-source caching or invalidation changes.
</deferred>
