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
| Reverse-FK index | Lazy scan on resolve; eager in-memory index; serialized cache index | REC-DEFAULT (LOCK): eager in-memory index derived from loaded columns, epoch-keyed, never serialized. |
| Reverse-FK index lifecycle | New `_post_load_index`; fold into existing column-index lifecycle | REC-DEFAULT (LOCK): no `_post_load_index`; update with `_store_columns`, `_drop_column_index`, `_rebuild_column_indexes`, and `_reset_indexes`. |
| Reverse-FK docs surface | Eager completion docs; resolve docs; hover docs too | REC-DEFAULT (LOCK): `completionItem/resolve.documentation` only. Hover behavior is preserved. |
| Internal reverse-FK key | Human colon key; exact tuple with safe separator; folded key | REC-DEFAULT (LOCK): logical `target_schema:target_table:target_column`, implemented with a non-printing separator to avoid identifier collisions; retain display fields exactly. |
| Disk cache version | Bump to v5; stay v4 | REC-DEFAULT (LOCK): stay v4. Derived in-memory index and completion item annotation shape do not change serialized payloads. |
| Capability false behavior | Show unknown tags; omit silently; warn | REC-DEFAULT (LOCK): omit silently for nil/empty rich fields. |
| Test adapter breadth | PG/Oracle only; all adapters; live DB | REC-DEFAULT (LOCK): PG-style lower-case and Oracle-style upper-case Lua fixtures only, plus core Go regression. No live DB in this phase. |

No design fork currently needs user input.

## Hard Questions Answered

1. **Where compute reverse-FK index?**
   No existing `_post_load_index` hook exists. Add `reverse_fk_refs_by_target_key` to the cache object and maintain it through the existing column-index lifecycle.

   Planned hook points:

   ```lua
   self:_rebuild_column_indexes() -- clears/rebuilds column items and reverse_fk_refs_by_target_key
   self:_update_column_index(schema, name) -- pre-bakes column annotations and refreshes source-table reverse refs
   ```

2. **Which reload markers invalidate reverse-FK data?**
   Reuse existing metadata generation/root epoch transitions: `build_from_metadata_rows`, `build_from_structure`, `build_from_schemas`, `load_from_disk`, `on_schema_objects_loaded`, `_store_columns`, `invalidate`, and `set_connection`. Reads route through `epoch_authority.read_with_freshness`.

3. **Build-time vs read-time annotations?**
   Lock build-time pre-bake in `_update_column_index`. The cache already rebuilds `column_items_by_key` when columns change, and `get_column_completion_items` deep-copies items before returning them.

4. **Composite PK ordinals?**
   Use `Column.PrimaryKeyOrdinal`; render `[PK]` when ordinal <= 1 for a non-composite/single unknown ordinal, and `[PKn]` when ordinal > 0 and composite PK evidence exists.

5. **Can completion resolve add reverse-FK docs?**
   Yes. `server.lua:619-624` already calls `resolve.handle`; `resolve.lua:176-183` already guards stale generations; `object_docs.lua:233-247` already returns `documentation`. Add reverse refs to column metadata before `docs.format_resolve`.

6. **Capability false path?**
   Unsupported adapters return empty/nil rich fields (`handler.go:589-600`). Annotation helpers must check truthy/typed fields and omit otherwise.

7. **Bounded fixtures?**
   Add a real-ish headless fixture with 1k tables x 10 columns and 100 FKs, then a separate perf fixture with 10k columns and 1k FKs.

8. **Strict marker discipline?**
   Target exactly 40 `LSP21_*` strict markers plus `LSP21_ALL_PASS=true` as the final rollup sentinel.

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

## Strict Markers

`LSP21_STRICT_MARKER_COUNT` target is **40**. `LSP21_ALL_PASS=true` is the rollup sentinel and is not counted.

1. `LSP21_COMPLETION_LABEL_UNCHANGED_OK`
2. `LSP21_LABELDETAILS_DETAIL_RENDERED_OK`
3. `LSP21_DETAIL_COMPAT_RENDERED_OK`
4. `LSP21_PK_SINGLE_MARKER_OK`
5. `LSP21_PK_COMPOSITE_ORDINAL_OK`
6. `LSP21_NULLABLE_TRUE_MARKER_OK`
7. `LSP21_PK_NULL_SUPPRESSED_OK`
8. `LSP21_NOT_NULL_OMITTED_OK`
9. `LSP21_FK_SINGLE_MARKER_OK`
10. `LSP21_FK_COMPOSITE_TARGET_TUPLE_OK`
11. `LSP21_FK_MULTIPLE_REFS_OK`
12. `LSP21_CAPABILITY_FALSE_EMPTY_RICH_FIELDS_OMIT_OK`
13. `LSP21_REVERSE_FK_INDEX_EMPTY_INIT_OK`
14. `LSP21_REVERSE_FK_INDEX_BUILD_ON_COLUMN_STORE_OK`
15. `LSP21_REVERSE_FK_INDEX_REBUILD_ON_COLUMN_INDEX_REBUILD_OK`
16. `LSP21_REVERSE_FK_INDEX_CLEAR_ON_RESET_INVALIDATE_OK`
17. `LSP21_REVERSE_FK_INDEX_EVICTION_DROPS_REFS_OK`
18. `LSP21_REVERSE_FK_INDEX_EPOCH_FAIL_CLOSED_OK`
19. `LSP21_REVERSE_FK_COMPOSITE_SOURCE_TARGET_OK`
20. `LSP21_REVERSE_FK_DEDUP_SHORTHAND_OK`
21. `LSP21_REVERSE_FK_SIZE_BOUND_OK`
22. `LSP21_RESOLVE_REFERENCED_BY_DOC_OK`
23. `LSP21_RESOLVE_REFERENCED_BY_CONSTRAINT_OK`
24. `LSP21_RESOLVE_REFERENCED_BY_COMPOSITE_OK`
25. `LSP21_RESOLVE_NO_REFS_DOC_UNCHANGED_OK`
26. `LSP21_RESOLVE_MARKDOWN_PLAINTEXT_OK`
27. `LSP21_RESOLVE_MEMO_REVERSE_FK_GENERATION_OK`
28. `LSP21_RESOLVE_STALE_REVERSE_FK_FAIL_CLOSED_OK`
29. `LSP21_RESOLVE_NO_DB_CALLS_OK`
30. `LSP21_HEADLESS_PG_ORACLE_FIXTURES_OK`
31. `LSP21_HEADLESS_CAPABILITY_FALSE_FIXTURE_OK`
32. `LSP21_HEADLESS_1K_TABLES_100_FKS_SMOKE_OK`
33. `LSP21_ROLLUP_EXACTLY_ONCE_OK`
34. `LSP21_LOCKED_HELPERS_UNTOUCHED_OK`
35. `LSP21_LOCKED_HELPERS_ALL_CONSUMERS_ROUTED_OK`
36. `LSP21_CACHE_VERSION4_NO_BUMP_OK`
37. `LSP21_RICH16_UX13_PRESERVED_OK`
38. `LSP21_PERF_COMPLETION_READ_P95_OK`
39. `LSP21_PERF_REVERSE_INDEX_BUILD_50MS_OK`
40. `LSP21_PERF_RESOLVE_LOOKUP_P95_OK`

## Success Gates

After Wave 5, final verification should pass:

```bash
make lsp21
make lsp21-rollup
make lsp21-locked-helpers-guard
go -C dbee test ./core
make perf-lsp
make gn23-rollup
```

`make perf-lsp` remains the broad preservation gate for existing UX13, LSP12, RICH16, FOLDER15, DB18, and ARCH14 coverage. `make gn23-rollup` preserves the recently shipped folder-scoped notes gate.

## Rollback Plan

1. Remove `labelDetails`/annotation detail helpers from `schema_cache.lua`; raw labels and type-only detail remain.
2. Remove `reverse_fk_refs_by_target_key` state and `get_reverse_fk_refs` from `schema_cache.lua`; column cache payloads remain valid v4.
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
  - no new fail-open reverse-FK read path bypasses the cache epoch check.

## Plan Gate

Execution must stop after these planning files are reviewed. Codex does not stage or commit. A later implementation turn may execute Phase 21 under this plan.

