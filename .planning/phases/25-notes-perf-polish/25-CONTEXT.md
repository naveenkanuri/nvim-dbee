<phase_overview>
Phase 25 is a single-file performance polish phase for the Phase 23 folder-scoped global notes migration helper. It targets the migration hot path in `lua/dbee/notes_migration.lua` and must preserve all Phase 23 lifecycle, recovery, namespace, command, marker, and manifest contracts.

The r1 fold removes O1 because the single-flip manifest optimization conflicts with GN23's `promote_complete` contract. The core change set is limited to:
- one `ensure_dir` per unique final folder instead of per promoted entry;
- one copy buffer read that returns byte length for `src_size_bytes`, while verification and recovery continue to stat final/staged files;
- a zero-byte recovery fix that accepts size `0` only when the recorded expected size is also `0`;
- a stricter paired benchmark harness with correctness assertions.
</phase_overview>

<decisions>
ORA25-01: Scope is only `lua/dbee/notes_migration.lua` for implementation; no other repository file may change during execution.
ORA25-02: O1 manifest single-flip is dropped. Phase 25 must preserve the Phase 23 dual protocol: write `promote_complete=false` before promotion, then rewrite the same manifest with `promote_complete=true` after all renames succeed.
ORA25-03: The first manifest write stays before final-directory hoist and before the first final rename. Hoist must not create final dirs before the persisted promote manifest exists.
ORA25-04: Final destination directory creation is hoisted by precomputing unique `dirname(entry.planned_dst)` values and ensuring each once before the promote rename loop.
ORA25-05: Hoist failure returns the same error kind as today, `final_dir_mkdir_failed`, and no final rename occurs after a hoist failure.
ORA25-06: Staging directory creation remains unchanged: staging root once, staged namespace directory once per folder, before copy.
ORA25-07: `src_size_bytes` is computed from the copied buffer length and keeps the existing manifest field name and meaning.
ORA25-08: Verification and recovery remain stat-backed; staged/final path and size mismatch detection must not rely only on in-memory copy length.
ORA25-09: The staging tree is private to the migration process between `stage_global_notes()` and `verify_staging()` by notes-dir lock plus randomized staging token; no external writer is part of the supported contract.
ORA25-10: Crash safety is preserved by keeping the promote manifest as the in-progress recovery artifact and the `.notes-migration-v1` sentinel as the lifecycle completion artifact.
ORA25-11: Per-connection isolation is preserved; legacy local namespace rename behavior and folder namespace derivation are not changed.
ORA25-12: Bench harness uses synthetic corpora and never the user's real state directory.
ORA25-13: Budgets are locked: small `G=5,F=2,C=10` P50 <= 80ms; medium `G=20,F=5,C=100` P50 <= 200ms; large `G=50,F=10,C=500` P50 <= 700ms. The Phase 23 diagnostic shape target is about 280ms and is diagnostic-only unless measured proof supports making it strict.
ORA25-14: Strict markers are `ORA25_ZERO_BYTE_OK=true`, `ORA25_MIGRATION_BUDGET_OK=true`, and `PHASE25_ALL_PASS=true`; `LIVE_PG25_MIGRATION_MS`, `ORA25_MIGRATION_MS_P50`, and `ORA25_MIGRATION_MS_P95` are diagnostic and cohort-qualified.
ORA25-15: The three locked helpers remain untouched: `lua/dbee/schema_filter_authority.lua`, `lua/dbee/schema_name_canonical.lua`, and `lua/dbee/lsp/epoch_authority.lua`.
ORA25-16: Phase 23 GN23 invariants remain required: 94 strict markers still emit and roll up to `GN23_ALL_PASS=true`.
ORA25-17: Zero-byte `.sql` notes are valid. Recovery validation treats `nil` size as missing but accepts `0` when it equals `src_size_bytes` or the recovery manifest expected size.
ORA25-18: Benchmark success requires paired baseline-vs-optimized runs on identical corpora plus correctness assertions: `maybe_run == true`, sentinel exists, global notes are removed/backed up, and each generated folder has exactly `G` migrated files.
</decisions>

<canonical_refs>
- `lua/dbee/notes_migration.lua:83-85` defines `file_size()` as a `uv.fs_stat` wrapper.
- `lua/dbee/notes_migration.lua:135-144` implements atomic temp-file write plus `uv.fs_rename`.
- `lua/dbee/notes_migration.lua:239-255` lists readable `.sql` files and does not exclude zero-byte files.
- `lua/dbee/notes_migration.lua:258-270` reads and writes copied SQL file contents.
- `lua/dbee/notes_migration.lua:279-280` defines `ensure_dir()` as `vim.fn.mkdir(path, "p")`.
- `lua/dbee/notes_migration.lua:673-678` validates promote-manifest final path sizes.
- `lua/dbee/notes_migration.lua:763-768` validates recovery-manifest final path sizes.
- `lua/dbee/notes_migration.lua:884-894` scans existing final folders for reserved destination names.
- `lua/dbee/notes_migration.lua:897-933` stages copied global notes and currently records `src_size_bytes` via `file_size(staged_path)`.
- `lua/dbee/notes_migration.lua:936-954` verifies staged paths and sizes before promotion.
- `lua/dbee/notes_migration.lua:957-999` builds the promote manifest, writes it twice today, ensures final dirs per entry, and promotes staged files.
- `lua/dbee/notes_migration.lua:718-741` writes the migration sentinel after promotion completion and writes recovery-needed on sentinel failure.
- `ci/headless/check_folder_scoped_notes.lua:897` asserts a persisted promote manifest has `promote_complete == true`.
- `.planning/phases/23-folder-scoped-notes/23-CONTEXT.md:178` locks the two-write promote-manifest protocol.
- `.planning/phases/23-folder-scoped-notes/23-CONTEXT.md:188` locks recovery handling for both `promote_complete=true` and `promote_complete=false` manifests.
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
- No removal of the post-promotion `promote_complete=true` rewrite.
- No new repository benchmark file unless a later phase explicitly widens scope.
- No changes to Phase 23 command UX or documentation.
- No broader notes namespace refactor.
- No additional folder-source caching or invalidation changes.
</deferred>
