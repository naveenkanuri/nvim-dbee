# Phase 21 - LSP Completion Annotations + FK Reverse References

**Milestone:** v1.4
**Status:** Planned
**Date:** 2026-05-07
**Requirement:** DBEE-FEAT-05 (LSP completion uses rich metadata)
**Reference:** `.planning/ROADMAP.md:411-415`

## Goal

When a user opens column completion after `SELECT`, `WHERE`, or `tablename.`, column completion rows expose rich metadata without changing inserted text:

- `[PK]` for a single-column primary key and `[PK1]`, `[PK2]`, ... for composite primary keys.
- `[FK→target_table.target_col]` for single-column FKs.
- `[FK→target_table.(a,b)]` for composite FKs.
- `null` only when `Nullable == true`, never for PK columns.
- Reverse FK references in `completionItem/resolve.documentation` for columns referenced by other cached tables:

```text
Referenced by:
  - schema.othertable.othercol  (constraint: fk_xxx)
```

Phase 21 is planning-only here. Implementation must not be executed until the plan gate is approved.

## Scope

Planned implementation scope:

- `lua/dbee/lsp/schema_cache.lua`
- `lua/dbee/lsp/object_docs.lua`
- `lua/dbee/lsp/resolve.lua`
- `lua/dbee/lsp/server.lua` only if tests show capability wiring needs an explicit assertion
- `lua/dbee/lsp/hover.lua` only for preservation tests, not new behavior
- `dbee/core/types.go` read/verify only; no type changes expected
- `ci/headless/check_lsp21*.lua`
- `Makefile`
- `ci/headless/check_ux13_rollup.lua`

Out of scope:

- Adapter SQL changes.
- Serialized cache shape changes.
- New Go RPC endpoints.
- Editing locked helpers.
- Live Neovim manual verification before the later SHIP gate.

## Inputs Read

- `.planning/ROADMAP.md:411-415`
- `.planning/phases/21-lsp-completion-annotations/21-CONTEXT.md`
- `dbee/core/types.go:227-257`
- `lua/dbee/lsp/schema_cache.lua:44`
- `lua/dbee/lsp/schema_cache.lua:1192-1225`
- `lua/dbee/lsp/schema_cache.lua:2750-2768`
- `lua/dbee/lsp/schema_cache.lua:3191-3195`
- `lua/dbee/lsp/schema_cache.lua:3447-3505`
- `lua/dbee/lsp/server.lua:65-128`
- `lua/dbee/lsp/server.lua:619-624`
- `lua/dbee/lsp/resolve.lua:98-128`
- `lua/dbee/lsp/resolve.lua:176-200`
- `lua/dbee/lsp/object_docs.lua:160-186`
- `lua/dbee/lsp/object_docs.lua:233-247`
- `lua/dbee/lsp/epoch_authority.lua:89-95`
- `dbee/adapters/postgres_driver_rich_metadata.go:180-186`
- `dbee/adapters/oracle_driver.go:468-474`
- `dbee/handler/handler.go:589-600`
- `ci/headless/check_lsp12_hover_resolve.lua:454-475`
- `ci/headless/check_lsp12_rollup.lua:15-71`
- `Makefile:161-292`
- `dbee/go.mod:1`

## Challenge-Ups Resolved

| Item | Resolution |
| --- | --- |
| Cache version prompt said v3 | Repo truth is v4 at `schema_cache.lua:44`. Phase 21 locks v4 baseline and plans no v5 bump. |
| Commit instructions conflicted | Codex writes planning files only. No `git add`, no commit. |
| No `_post_load_index` hook exists | Plan uses existing column-index lifecycle instead of a nonexistent hook. |
| Root Go command in prompt is not valid for this module layout | Use `go -C dbee test ./core`; `dbee/go.mod:1` is the module root. |

## Design Forks

| Fork | Options Considered | Decision |
| --- | --- | --- |
| Annotation surface | Mutate `label`; use only `labelDetails`; use only `detail`; hybrid | REC-DEFAULT (LOCK): hybrid. Keep `label` raw, set `labelDetails.detail = " [PK1] [FK→users.id] null"`, and set `detail = "<type> [PK1] [FK→users.id] null"` for older clients. |
| Composite FK rendering | `target.(a,b)`; repeated qualified pairs; first + overflow | REC-DEFAULT (LOCK): `target_table.(a,b)` for `TargetColumns` length > 1. |
| Multiple FK rendering | First only; all refs; overflow | REC-DEFAULT (LOCK): render all distinct FK refs, space-joined, deduped by constraint + target tuple. |
| Null direction | Show `null`; show `NN`; show both | REC-DEFAULT (LOCK): show `null` only when `Nullable == true`; omit false/nil. PK suppresses `null`. |
| Default expression marker | Add popup marker now; docs only; defer entirely | REC-DEFAULT (LOCK): defer popup default marker. Existing docs may keep showing `Default`. |
| Table completion PK count | Annotate table items; leave table items unchanged | REC-DEFAULT (LOCK): leave table items unchanged. Phase 21 is column-completion scoped, and table items can exist before columns are loaded. |
| Reverse-FK index | Lazy scan on resolve; eager in-memory index; serialized cache index | REC-DEFAULT (LOCK): eager in-memory index derived from loaded columns, epoch-keyed, never serialized, except v4 disk-load startup defers reverse-index rebuild out of the synchronous `load_from_disk` path. |
| Reverse-FK index data structure | Target-only map; target map plus forward source map | REC-DEFAULT (LOCK): use both `reverse_fk_refs_by_target_key` and `reverse_fk_refs_by_source_key`. The source map makes source-table drop/eviction O(refs-for-source), not O(total reverse refs). |
| Reverse-FK index lifecycle | New `_post_load_index`; fold into existing column-index lifecycle | REC-DEFAULT (LOCK): no `_post_load_index`; update with `_store_columns`, `_drop_column_index`, `_rebuild_column_indexes`, and `_reset_indexes`. Use `reverse_fk_cache_epoch` for freshness equality and `reverse_fk_index_generation` for mutation identity. |
| Disk-load reverse-FK rebuild | Synchronous rebuild during `load_from_disk`; deferred/lazy in-memory rebuild | REC-DEFAULT (LOCK): defer reverse-FK rebuild on v4 disk load. Rebuild completion indexes synchronously, mark reverse-FK dirty, schedule async/background rebuild when possible, and trigger a non-blocking build on first reverse-FK resolve if still dirty. |
| Reverse-FK docs surface | Eager completion docs; resolve docs; hover docs too | REC-DEFAULT (LOCK): `completionItem/resolve.documentation` only. Hover behavior is preserved. |
| Internal reverse-FK key | Human colon key; exact tuple with safe separator; folded key | REC-DEFAULT (LOCK): logical `target_schema:target_table:target_column`, implemented with a non-printing separator and `schema_name_canonical.canonical(..., quoted=true, self.fold_id)` on writer and reader. Retain display fields exactly. |
| Reverse-FK overflow policy | Global hard-disable; per-target truncate; source/target/global caps | REC-DEFAULT (LOCK): three-tier caps: per-target 50 rendered refs, per-source 1000-ref backstop, total 50k refs. Overflow degrades with truncation text and a once-per-overflow warning, not silent `{}` for every lookup. |
| Reverse-FK overflow bookkeeping | Boolean flag; count only; visible refs plus counted dropped source map | REC-DEFAULT (LOCK): per-target bucket is `{ refs, dropped_count, dropped_sources }`, where `dropped_sources[source_key] = { count, refs }`. Eviction decrements dropped counts and can promote stored dropped refs without a full index walk. |
| Reverse-FK ordering | Sort on insert; sort on read; unsorted | REC-DEFAULT (LOCK): sort on read. Per-target rendered refs are capped at 50, so read-time O(N log N) is bounded and avoids insertion-time sort overhead during large builds. |
| Reverse-FK resolve transfer | Deep-copy in cache and deep-copy into metadata; single ownership transfer | REC-DEFAULT (LOCK): `get_reverse_fk_refs` returns owned sorted refs; `resolve.metadata_for` assigns the returned table directly to `meta.referenced_by` and does not deep-copy again. |
| Resolve memo invalidation | Cache generation only; cache epoch dimension; reverse-index mutation generation dimension | REC-DEFAULT (LOCK): include `reverse_fk_index_generation` in the completion resolve memo key because column eviction can shrink reverse-FK docs without bumping `cache:generation()` or `cache_epoch`. |
| Disk cache version | Bump to v5; stay v4 | REC-DEFAULT (LOCK): stay v4. Derived in-memory index and completion item annotation shape do not change serialized payloads. |
| Capability false behavior | Show unknown tags; omit silently; warn | REC-DEFAULT (LOCK): omit silently for nil/empty rich fields. |
| Test adapter breadth | PG/Oracle only; all adapters; live DB | REC-DEFAULT (LOCK): PG-style lower-case and Oracle-style upper-case Lua fixtures only, plus core Go regression. No live DB in this phase. |

No design fork currently needs user input.

## Hard Questions Answered

1. **Where compute reverse-FK index?**
   No existing `_post_load_index` hook exists. Add `reverse_fk_refs_by_target_key` and `reverse_fk_refs_by_source_key` to the cache object and maintain them through the existing column-index lifecycle. `load_from_disk` remains special: it rebuilds column completion indexes synchronously, marks reverse-FK dirty, and defers reverse-FK rebuild out of startup.

   Planned hook points:

   ```lua
   self:_rebuild_column_indexes({ reverse_fk = true }) -- full rebuild for live metadata paths
   self:_rebuild_column_indexes({ reverse_fk = false, reverse_fk_dirty = true }) -- disk-load startup path
   self:_update_column_index(schema, name) -- pre-bakes column annotations and refreshes source-table reverse refs
   ```

2. **Which reload markers invalidate reverse-FK data?**
   Reuse existing metadata generation/root epoch transitions: `build_from_metadata_rows`, `build_from_structure`, `build_from_schemas`, `load_from_disk`, `on_schema_objects_loaded`, `_store_columns`, `invalidate`, and `set_connection`. Reads route through `epoch_authority.read_with_freshness`, then `_fresh_lsp_scope()` filters returned source refs by current authority scope. Writers stamp `reverse_fk_cache_epoch = epoch_authority.cache_epoch(self)` after successful rebuild/refresh and reset it to 0 on clears. Separately, every reverse-index mutation increments `reverse_fk_index_generation`; resolve memo keys use that generation, not cache epoch.

3. **Build-time vs read-time annotations?**
   Lock build-time pre-bake in `_update_column_index`. The cache already rebuilds `column_items_by_key` when columns change, and `get_column_completion_items` deep-copies items before returning them.

4. **Composite PK ordinals?**
   Use `Column.PrimaryKeyOrdinal` without fabricating ordinals. If exactly one column has `primary_key == true`, render `[PK]`. If two or more PK columns exist and `primary_key_ordinal > 0`, render `[PKn]`. If two or more PK columns exist but ordinal is 0/nil, render `[PK]` as degraded-but-honest output.

5. **Can completion resolve add reverse-FK docs?**
   Yes. `server.lua:619-624` already calls `resolve.handle`; `resolve.lua:176-183` already guards stale generations; `object_docs.lua:233-247` already returns `documentation`. Add reverse refs to column metadata before `docs.format_resolve`.

6. **Capability false path?**
   Unsupported adapters return empty/nil rich fields (`handler.go:589-600`). Annotation helpers must check truthy/typed fields and omit otherwise.

7. **Bounded fixtures?**
   Add a real-ish headless fixture with 1k tables x 10 columns and 100 FKs; explicit edge fixtures for quoted mixed-case, self-FK, cross-schema target out-of-cache, zero-FK, and high-fan-in refs; and perf fixtures at both 10k columns/1k FKs and 250k columns/50k FKs.

8. **Strict marker discipline?**
   Target exactly 65 `LSP21_*` strict markers plus `LSP21_ALL_PASS=true` as the final rollup sentinel. The count is higher than the r1 estimate because each review-requested marker is retained explicitly.

9. **Locked helper routing?**
   No helper edits. All completion/reverse-FK reads must route through `epoch_authority.read_with_freshness`. Identifier canonicalization, if needed, calls `schema_name_canonical` rather than duplicating fold rules.

10. **Plan revision discipline?**
    All forks above are resolved as reversible REC-DEFAULT (LOCK). Future reviews may revise before execution.

## Wave Breakdown

| Wave | Plan | Objective | Depends On |
| --- | --- | --- | --- |
| 1 | `21-01-PLAN.md` | Add build-time column completion annotation rendering with labelDetails/detail compatibility. | None |
| 2 | `21-02-PLAN.md` | Add in-memory reverse-FK index tied to the column-index lifecycle and epoch-gated reads. | Wave 1 |
| 3 | `21-03-PLAN.md` | Enrich `completionItem/resolve` documentation with reverse-FK references. | Wave 2 |
| 4 | `21-04-PLAN.md` | Add strict headless fixtures, rollups, Makefile targets, and locked-helper guards. | Waves 1-3 |
| 5 | `21-05-PLAN.md` | Add performance gates for annotation reads, reverse-index build, and resolve lookups. | Waves 1-4 |

Dependency graph:

```text
21-01 -> 21-02 -> 21-03 -> 21-04 -> 21-05
```

## Disk Payload Shape Lock

Phase 21 does not mutate serialized cache payloads. Annotation strings (`labelDetails.detail`, hybrid completion `detail`, reverse-FK rendered docs, overflow text) are derived only into in-memory completion/documentation structures. They MUST NOT be written onto `Column` records or into `_save_columns_to_disk`. The v4 serialized column cache shape remains closed for Phase 21:

```lua
{ version, schema_filter_signature, root_epoch, columns = Column[] }
```

## Performance Budget Lock

Perf gates use 100 measured iterations per scenario and report p95. Reverse-FK insertion budget is `<= 10us/FK-ref`, which supports `< 50ms` for the 1k-FK mid fixture and `<= 500ms` for the 50k-FK large fixture. Completion read budgets include both the existing hot-table path (`< 1ms`) and a 500-column wide-table path (`< 2.5ms`, `<= 5us/column`). Resolve docs include both cache lookup (`< 1ms`) and E2E formatting/serialization (`< 5ms`).

Disk-load startup budget is protected by the deferred reverse-FK index path. The large v4 disk payload fixture must prove `load_from_disk` does not synchronously build `reverse_fk_refs_by_target_key`/`reverse_fk_refs_by_source_key`; Phase 21 reverse-FK overhead during disk load must be `< 25ms` p95 over baseline column-index load, with reverse docs populated after the deferred build completes.

## Derived-Index Hub Lock

`_drop_column_index(key)` is the sole eviction hub for per-source derived indexes. Phase 21 registers reverse-FK source cleanup there, and future per-source derived indexes must add their drop logic to the same hub instead of creating independent eviction hooks.

## Strict Markers

`LSP21_STRICT_MARKER_COUNT` target is **65**. `LSP21_ALL_PASS=true` is the rollup sentinel and is not counted.

1. `LSP21_COMPLETION_LABEL_UNCHANGED_OK`
2. `LSP21_LABELDETAILS_DETAIL_RENDERED_OK`
3. `LSP21_DETAIL_COMPAT_RENDERED_OK`
4. `LSP21_PK_SINGLE_MARKER_OK`
5. `LSP21_PK_COMPOSITE_ORDINAL_OK`
6. `LSP21_PK_COMPOSITE_NO_ORDINAL_FALLBACK_OK`
7. `LSP21_NULLABLE_TRUE_MARKER_OK`
8. `LSP21_PK_NULL_SUPPRESSED_OK`
9. `LSP21_NOT_NULL_OMITTED_OK`
10. `LSP21_FK_SINGLE_MARKER_OK`
11. `LSP21_FK_COMPOSITE_TARGET_TUPLE_OK`
12. `LSP21_FK_MULTIPLE_REFS_OK`
13. `LSP21_FK_COMPOSITE_PAIRING_PRECEDENCE_OK`
14. `LSP21_CAPABILITY_FALSE_EMPTY_RICH_FIELDS_OMIT_OK`
15. `LSP21_DISK_PAYLOAD_SHAPE_UNCHANGED_OK`
16. `LSP21_COLUMN_RECORDS_UNMUTATED_BY_ANNOTATION_OK`
17. `LSP21_REVERSE_FK_INDEX_EMPTY_INIT_OK`
18. `LSP21_REVERSE_FK_INDEX_BUILD_ON_COLUMN_STORE_OK`
19. `LSP21_REVERSE_FK_INDEX_REBUILD_ON_COLUMN_INDEX_REBUILD_OK`
20. `LSP21_REVERSE_FK_INDEX_CLEAR_ON_RESET_INVALIDATE_OK`
21. `LSP21_REVERSE_FK_INDEX_EVICTION_DROPS_REFS_OK`
22. `LSP21_REVERSE_FK_CACHE_EPOCH_FAIL_CLOSED_OK`
23. `LSP21_REVERSE_FK_CACHE_EPOCH_WRITE_STAMP_OK`
24. `LSP21_REVERSE_FK_COMPOSITE_SOURCE_TARGET_OK`
25. `LSP21_REVERSE_FK_DEDUP_SHORTHAND_OK`
26. `LSP21_REVERSE_FK_SIZE_BOUND_OK`
27. `LSP21_REVERSE_FK_PER_TARGET_CAP_OK`
28. `LSP21_REVERSE_FK_PER_SOURCE_CAP_OK`
29. `LSP21_REVERSE_FK_OVERFLOW_TRUNCATED_DISPLAY_OK`
30. `LSP21_REVERSE_FK_OVERFLOW_NOTIFY_ONCE_OK`
31. `LSP21_REVERSE_FK_KEY_FOLD_AWARE_OK`
32. `LSP21_REVERSE_FK_AUTHORITY_FAIL_CLOSED_OK`
33. `LSP21_REVERSE_FK_DISK_LOAD_DEFERRED_OK`
34. `LSP21_REVERSE_FK_OVERFLOW_CLEARS_AFTER_EVICTION_OK`
35. `LSP21_REVERSE_FK_PER_SOURCE_BACKSTOP_OK`
36. `LSP21_RESOLVE_REFERENCED_BY_DOC_OK`
37. `LSP21_RESOLVE_REFERENCED_BY_CONSTRAINT_OK`
38. `LSP21_RESOLVE_REFERENCED_BY_COMPOSITE_OK`
39. `LSP21_RESOLVE_NO_REFS_DOC_UNCHANGED_OK`
40. `LSP21_RESOLVE_MARKDOWN_PLAINTEXT_OK`
41. `LSP21_RESOLVE_MEMO_REVERSE_FK_GENERATION_OK`
42. `LSP21_RESOLVE_MEMO_REVERSE_FK_GENERATION_DIMENSION_OK`
43. `LSP21_RESOLVE_STALE_REVERSE_FK_FAIL_CLOSED_OK`
44. `LSP21_RESOLVE_NO_DB_CALLS_OK`
45. `LSP21_HEADLESS_PG_ORACLE_FIXTURES_OK`
46. `LSP21_HEADLESS_CAPABILITY_FALSE_FIXTURE_OK`
47. `LSP21_HEADLESS_1K_TABLES_100_FKS_SMOKE_OK`
48. `LSP21_QUOTED_MIXED_CASE_FIXTURE_OK`
49. `LSP21_SELF_FK_FIXTURE_OK`
50. `LSP21_CROSS_SCHEMA_OUT_OF_CACHE_FIXTURE_OK`
51. `LSP21_ZERO_FK_FIXTURE_OK`
52. `LSP21_HIGH_FAN_IN_FIXTURE_OK`
53. `LSP21_ROLLUP_EXACTLY_ONCE_OK`
54. `LSP21_LOCKED_HELPERS_UNTOUCHED_OK`
55. `LSP21_LOCKED_HELPERS_ALL_CONSUMERS_ROUTED_OK`
56. `LSP21_CACHE_VERSION4_NO_BUMP_OK`
57. `LSP21_RICH16_UX13_PRESERVED_OK`
58. `LSP21_PERF_COMPLETION_READ_P95_OK`
59. `LSP21_PERF_COMPLETION_WIDE_TABLE_P95_OK`
60. `LSP21_PERF_REVERSE_INDEX_BUILD_50MS_OK`
61. `LSP21_PERF_REVERSE_INDEX_BUILD_LARGE_OK`
62. `LSP21_PERF_EVICTION_CHURN_OK`
63. `LSP21_PERF_RESOLVE_LOOKUP_P95_OK`
64. `LSP21_PERF_RESOLVE_E2E_P95_OK`
65. `LSP21_PERF_LOAD_FROM_DISK_DEFERRED_LARGE_OK`

## Success Gates

After Wave 5, final verification should pass:

```bash
make lsp21
make lsp21-rollup
make lsp21-locked-helpers-guard
go -C dbee test ./core
make perf-headless ARGS='-l ci/headless/check_lsp21_perf.lua'
make perf-lsp
make gn23-rollup
```

`make perf-lsp` remains the broad preservation gate for existing UX13, LSP12, RICH16, FOLDER15, DB18, and ARCH14 coverage. `make gn23-rollup` preserves the recently shipped folder-scoped notes gate.

## Rollback Plan

1. Remove `labelDetails`/annotation detail helpers from `schema_cache.lua`; raw labels and type-only detail remain.
2. Remove `reverse_fk_refs_by_target_key`, `reverse_fk_refs_by_source_key`, overflow counters, deferred-build flags, reverse-FK epoch/generation state, and `get_reverse_fk_refs` from `schema_cache.lua`; column cache payloads remain valid v4.
3. Remove reverse-reference metadata injection from `resolve.lua` and docs formatting from `object_docs.lua`.
4. Remove `ci/headless/check_lsp21*.lua`, `make lsp21*` targets, and `LSP21_ALL_PASS` rollup requirement.

Rollback does not require cache migration because Phase 21 stores no new disk payload fields.

## Locked-Helper Compliance

- Do not edit:
  - `lua/dbee/schema_filter_authority.lua`
  - `lua/dbee/schema_name_canonical.lua`
  - `lua/dbee/lsp/epoch_authority.lua`
- Add `make lsp21-locked-helpers-guard` to prove:
  - no git diff in those helpers;
  - reverse-FK public reads use `epoch_authority.read_with_freshness`;
  - reverse-FK read bodies call `_fresh_lsp_scope()` and filter to the active authority scope;
  - reverse-FK key writers/readers import and use `schema_name_canonical`;
  - `_drop_column_index` remains the per-source derived-index eviction hub and calls reverse-FK drop logic;
  - `_save_columns_to_disk` rejects annotation-only fields (`labelDetails`, rendered annotation `detail`, `referenced_by`, overflow/truncation strings);
  - no new fail-open reverse-FK read path bypasses the cache epoch check.

## Plan Gate

Execution must stop after these planning files are reviewed. Codex does not stage or commit. A later implementation turn may execute Phase 21 under this plan.
