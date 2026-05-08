# Phase 25 - Notes Migration Perf Polish

Status: plan-only, ready for plan-gate r2 after r1 narrow fold.

## Phase Summary

Phase 25 tightens the Phase 23 notes migration hot path in `lua/dbee/notes_migration.lua` only. The original 250ms target depended on removing the post-promotion manifest rewrite, but r1 review found that O1 conflicts with the Phase 23 `promote_complete` recovery contract and GN23 tests. Phase 25 now drops O1, keeps O2 and O3, and relaxes the diagnostic target from 250ms to about 280ms for the Phase 23 diagnostic shape.

Implementation scope remains intentionally narrow:

- Modify only `lua/dbee/notes_migration.lua`.
- Do not edit tests, Makefile, command registration, README, helper modules, or Go files.
- Benchmark harnesses may be inline headless commands or temporary `/tmp` files only.

## Current Profile

Evidence from the current migration helper:

| Hotspot | Current evidence | Current behavior | Phase 25 action |
| --- | --- | --- | --- |
| Manifest writes | `write_json_atomic()` uses temp file plus `uv.fs_rename` at `lua/dbee/notes_migration.lua:135-144`; promotion writes at `:969` and rewrites at `:993-994`. | Two atomic manifest writes on the success path: pre-promotion `promote_complete=false`, then post-promotion `promote_complete=true`. GN23 asserts this persisted true state. | **Drop O1.** Keep the dual-flip protocol unchanged. Manifest first write stays before final-dir hoist and before any rename; the `promote_complete=true` rewrite stays after all renames. |
| Directory creation | `ensure_dir()` is `vim.fn.mkdir(path, "p")` at `lua/dbee/notes_migration.lua:279-280`; staging root is ensured at `:899`, each staged folder at `:908`, and each final directory inside the per-entry promote loop at `:974-977`. | Final destination dirs are ensured `C` times for `C = global_notes * folder_count`, even though unique final dirs are only `F`. | **Keep O2.** Precompute unique `dirname(entry.planned_dst)` values after the first manifest write and call `ensure_dir` once per final folder before the rename loop. |
| File size | `copy_file()` reads each source into memory at `lua/dbee/notes_migration.lua:258-270`; staged entry size then calls `file_size(staged_path)` at `:929`; verification calls `exists(entry.src_staging)` at `:944` and `file_size(entry.src_staging)` at `:950`. | Each copied entry does a read/write plus an avoidable staged-size stat before the later verification stat. | **Keep O3.** Return byte length from the copy operation and store it as `src_size_bytes`; keep later verification/recovery stat checks. |
| Zero-byte recovery | `list_sql_files()` accepts readable `.sql` files at `lua/dbee/notes_migration.lua:239-255`, but recovery validation rejects `size <= 0` at `:673-675` and `:763-765`. | Empty SQL notes migrate on the normal success path but can fail recovery after crash/sentinel failure. | Fold the fix into Phase 25: treat `nil` as missing, but accept `0` when it matches the recorded size. |

## Syscall Model

This is a targeted high-level filesystem-call model for empty-destination non-empty migrations, not an OS-level `dtruss` trace. Existing destination notes add scan cost through `build_reserved_set()`, so benchmark coverage must include a collision/existing-note cohort.

Let:

- `G` = legacy `notes/global/*.sql` files.
- `F` = folder IDs at migration time.
- `C = G * F` = copied/promoted entries.

Tracked calls include copy read/write streams, migration size/existence stats, final mkdir calls, promotion renames, and atomic manifest writes.

| Shape | Current tracked calls | Optimized tracked calls | Avoided calls |
| --- | ---: | ---: | ---: |
| Formula | `7C + F + 3` | `5C + 2F + 3` | `2C - F` |
| Small: `G=5`, `F=2`, `C=10` | 75 | 57 | 18 |
| Medium: `G=20`, `F=5`, `C=100` | 708 | 513 | 195 |
| Large: `G=50`, `F=10`, `C=500` | 3513 | 2523 | 990 |
| Phase 23 diagnostic shape: `G=100`, `F=10`, `C=1000` | 7013 | 5023 | 1990 |

Savings come from `C` removed staged-size stats and `C - F` removed redundant final-dir mkdirs. The manifest write count is unchanged.

## Strict Markers

Strict marker count target: **3**. Diagnostic timing markers are emitted but not counted.

| Marker | Type | Gate |
| --- | --- | --- |
| `ORA25_ZERO_BYTE_OK=true` | strict | Printed only after zero-byte migration and recovery validation pass. |
| `ORA25_MIGRATION_BUDGET_OK=true` | strict | Printed only when all revised cohort budgets pass and required cohort summaries are present. |
| `PHASE25_ALL_PASS=true` | strict final | Printed after zero-byte, scope, helper, GN23, benchmark assertion, and budget checks pass. |
| `LIVE_PG25_MIGRATION_MS=<cohort>:<variant>:<n>` | diagnostic | Printed per measured iteration with cohort and baseline/optimized variant. |
| `ORA25_MIGRATION_MS_P50=<cohort>:<variant>:<n>` | diagnostic | Printed per cohort/variant. |
| `ORA25_MIGRATION_MS_P95=<cohort>:<variant>:<n>` | diagnostic | Printed per cohort/variant. |

Latency budgets:

| Cohort | Corpus | Budget |
| --- | --- | --- |
| Small | `G=5`, `F=2`, `C=10` | P50 <= 80ms |
| Medium | `G=20`, `F=5`, `C=100` | P50 <= 200ms |
| Large | `G=50`, `F=10`, `C=500` | P50 <= 700ms |
| Phase 23 diagnostic shape | `G=100`, `F=10`, `C=1000` | P50 target about 280ms; diagnostic-only unless measured proof supports a stricter gate. |

## Decision Coverage

| Decision | Locked coverage |
| --- | --- |
| D1 | Implementation modifies only `lua/dbee/notes_migration.lua`; plan artifacts are the only Phase 25 docs. |
| D2 | O1 is dropped. The Phase 23 dual manifest protocol remains unchanged. |
| D3 | Final destination directories are deduped by unique directory path and ensured once after the first manifest write and before the rename loop. |
| D4 | Copy returns byte length; `src_size_bytes` comes from the read buffer length. |
| D5 | Crash safety is preserved by retaining Phase 23 manifest ordering and sentinel lifecycle semantics. |
| D6 | Per-connection local-note isolation and legacy local namespace rename behavior stay unchanged. |
| D7 | Headless benchmark harness uses paired synthetic corpora and never the user's real state directory. |
| D8 | Revised per-cohort latency budgets are locked in this plan. |
| D9 | Strict and diagnostic markers are locked, with zero-byte recovery as a strict marker. |
| D10 | `schema_filter_authority.lua`, `schema_name_canonical.lua`, and `lsp/epoch_authority.lua` remain untouched. |
| D11 | Phase 23 GN23 strict marker target remains 94 and must still roll up green. |
| D12 | Existing rollback path remains entry-based and deletes only promoted files in `promote_rollback_paths`. |
| D13 | `:Dbee notes_migration_inspect` remains pure-read and compatible with unchanged manifest fields. |
| D14 | Pre-migration -> in-progress -> migration_complete sentinel lifecycle remains atomic. |
| D15 | File path and file size mismatch detection remains stat-backed during verify/recovery and accepts zero-byte files only when the recorded size is zero. |
| D16 | `:Dbee notes_migration_cleanup_backups` remains unchanged and must still work. |
| D17 | Benchmark success requires correctness assertions: `maybe_run == true`, sentinel exists, legacy global is removed/backed up, and each generated folder has exactly `G` migrated SQL files. |
| D18 | Paired baseline and optimized measurements run on identical generated corpora with cohort-qualified diagnostics and no missing-cohort false success. |

## Scope Fence

Implementation file allowed:

- `lua/dbee/notes_migration.lua`

Files explicitly forbidden:

- `lua/dbee/schema_filter_authority.lua`
- `lua/dbee/schema_name_canonical.lua`
- `lua/dbee/lsp/epoch_authority.lua`
- Phase 23 command files, README, Makefile, CI/headless scripts, Go endpoint files, and all other runtime modules.

Plan artifacts written for Phase 25:

- `.planning/phases/25-notes-perf-polish/PLAN.md`
- `.planning/phases/25-notes-perf-polish/25-CONTEXT.md`
- `.planning/phases/25-notes-perf-polish/25-01-PLAN.md`
