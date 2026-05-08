# Phase 25 - Notes Migration Perf Polish

Status: plan-only, ready for plan-gate r1.

## Phase Summary

Phase 25 tightens the Phase 23 notes migration hot path in `lua/dbee/notes_migration.lua` only. The goal is to reduce the shipped median migration latency from the Phase 23 diagnostic baseline of 391ms toward the 250ms target without changing manifest schema, folder-scoped global notes lifecycle semantics, or the three locked helper files.

Implementation scope is intentionally narrow:

- Modify only `lua/dbee/notes_migration.lua`.
- Do not edit tests, Makefile, command registration, README, helper modules, or Go files.
- Benchmark harnesses may be inline headless commands or temporary `/tmp` files only.

## Current Profile

Evidence from the current migration helper:

| Hotspot | Current evidence | Current behavior | Phase 25 optimization |
| --- | --- | --- | --- |
| Manifest writes | `write_json_atomic()` uses temp file plus `uv.fs_rename` at `lua/dbee/notes_migration.lua:135-144`; promotion writes at `:969` and rewrites at `:993-994`. | Two atomic manifest writes on the success path: pre-promotion `promote_complete=false`, then post-promotion `promote_complete=true`. It is not per-copy today, but the second write is avoidable. | Keep one atomic pre-promotion manifest write after all entries are built and before any final rename. Remove the post-promotion rewrite. Treat manifest existence plus final-path validation as the recovery contract. |
| Directory creation | `ensure_dir()` is `vim.fn.mkdir(path, "p")` at `lua/dbee/notes_migration.lua:279-280`; staging root is ensured at `:899`, each staged folder at `:908`, and each final directory inside the per-entry promote loop at `:974-977`. | Final destination dirs are ensured `C` times for `C = global_notes * folder_count`, even though unique final dirs are only `F`. | Precompute unique `dirname(entry.planned_dst)` values inside `promote_staging()` and call `ensure_dir` once per folder before the rename loop. Keep staging-dir creation unchanged. |
| File size | `copy_file()` reads each source into memory at `lua/dbee/notes_migration.lua:258-270`; staged entry size then calls `file_size(staged_path)` at `:929`; verification calls `exists(entry.src_staging)` at `:944` and `file_size(entry.src_staging)` at `:950`. | Each copied entry does a read/write plus an avoidable staged-size stat before the later verification stat. | Return byte length from the copy operation and store that as `src_size_bytes`; keep the later verification stat so mismatch detection remains robust. |
| Recovery and sentinel | `complete_after_promotion()` writes sentinel only after backup/delete work and writes recovery-needed if sentinel write fails at `lua/dbee/notes_migration.lua:718-741`. Promote recovery validates manifests before completion at `:818-846`. | The Phase 23 lifecycle is pre-migration -> in-progress lock/promote manifest -> migration_complete sentinel. | Preserve ordering. The sentinel remains the lifecycle-complete marker; the single manifest write remains the promote crash-recovery marker. |

## Syscall Model

This is a targeted high-level filesystem-call model for the non-empty successful migration path, not an OS-level `dtruss` trace. Let:

- `G` = legacy `notes/global/*.sql` files.
- `F` = folder IDs at migration time.
- `C = G * F` = copied/promoted entries.

Tracked calls include copy read/write streams, migration size/existence stats, final mkdir calls, promotion renames, and atomic manifest writes.

| Shape | Current tracked calls | Optimized tracked calls | Avoided calls |
| --- | ---: | ---: | ---: |
| Formula | `7C + F + 3` | `5C + 2F + 2` | `2C - F + 1` |
| Small: `G=5`, `F=1`, `C=5` | 39 | 29 | 10 |
| Medium: `G=10`, `F=5`, `C=50` | 358 | 262 | 96 |
| Large: `G=50`, `F=10`, `C=500` | 3513 | 2522 | 991 |
| Phase 23 diagnostic shape: `G=100`, `F=10`, `C=1000` | 7013 | 5022 | 1991 |

Savings come from `C` removed staged-size stats, `C - F` removed redundant final-dir mkdirs, and one removed atomic manifest rewrite.

## Strict Markers

Strict marker count target: **2**. Diagnostic timing markers are emitted but not counted.

| Marker | Type | Gate |
| --- | --- | --- |
| `ORA25_MIGRATION_BUDGET_OK=true` | strict | Printed only when all Phase 25 latency budgets pass. |
| `PHASE25_ALL_PASS=true` | strict final | Printed after scope, helper, GN23, manifest, and budget checks pass. |
| `LIVE_PG25_MIGRATION_MS=<n>` | diagnostic | Printed once per benchmark iteration. |
| `ORA25_MIGRATION_MS_P50=<n>` | diagnostic | Printed per cohort and for the Phase 23 diagnostic shape. |
| `ORA25_MIGRATION_MS_P95=<n>` | diagnostic | Printed per cohort and for the Phase 23 diagnostic shape. |

Latency budgets:

| Cohort | Corpus | Budget |
| --- | --- | --- |
| Small | `G=5`, `F=1`, `C=5` | P50 <= 50ms |
| Medium | `G=10`, `F=5`, `C=50` | P50 <= 150ms |
| Large | `G=50`, `F=10`, `C=500` | P50 <= 500ms |
| Phase 23 target | `G=100`, `F=10`, `C=1000` | P50 <= 250ms |

## Decision Coverage

| Decision | Locked coverage |
| --- | --- |
| D1 | Implementation modifies only `lua/dbee/notes_migration.lua`; plan artifacts are the only Phase 25 docs. |
| D2 | Manifest single-flip uses the existing temp-write plus atomic rename helper. |
| D3 | Final destination directories are deduped by unique directory path and ensured once. |
| D4 | Copy returns byte length; `src_size_bytes` comes from the read buffer length. |
| D5 | Crash safety is preserved by writing the manifest before final renames and keeping sentinel as lifecycle completion. |
| D6 | Per-connection local-note isolation and legacy local namespace rename behavior stay unchanged. |
| D7 | Headless benchmark harness uses synthetic notes corpus fixtures. |
| D8 | Per-cohort latency budgets are locked in this plan. |
| D9 | Strict and diagnostic markers are locked. |
| D10 | `schema_filter_authority.lua`, `schema_name_canonical.lua`, and `lsp/epoch_authority.lua` remain untouched. |
| D11 | Phase 23 GN23 strict marker target remains 94 and must still roll up green. |
| D12 | Existing rollback path remains entry-based and deletes only promoted files in `promote_rollback_paths`. |
| D13 | `:Dbee notes_migration_inspect` remains pure-read and compatible with unchanged manifest fields. |
| D14 | Pre-migration -> in-progress -> migration_complete sentinel lifecycle remains atomic. |
| D15 | File path and file size mismatch detection remains stat-backed during verify/recovery. |
| D16 | `:Dbee notes_migration_cleanup_backups` remains unchanged and must still work. |

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
