# Phase 21 - LSP Completion Annotations Context

**Gathered:** 2026-05-07
**Status:** Ready for planning
**Source:** Combined research + plan task

## Phase Boundary

Phase 21 adds rich column metadata to LSP column completion items and adds reverse foreign-key references to `completionItem/resolve` documentation. It does not change adapter SQL, Go metadata structs, disk cache payload shape, or the three locked helper files.

## Code Evidence

Line anchors below are the implementation baseline as of 2026-05-07 and must be rechecked before execution.

| Topic | Evidence |
| --- | --- |
| Roadmap scope | `.planning/ROADMAP.md:411-415` defines Phase 21 as LSP completion annotations + FK reverse references, depends on Phase 17, and maps to DBEE-FEAT-05. |
| Core column metadata | `dbee/core/types.go:227-257` defines `Column.Nullable`, `PrimaryKey`, `PrimaryKeyOrdinal`, `ForeignKeys`, `Default`, and `FKRef.SourceColumns`/`TargetColumns`. |
| Current cache version | `lua/dbee/lsp/schema_cache.lua:44` is `SCHEMA_CACHE_VERSION = 4`. Phase 21 treats v4 as baseline. |
| Completion item build point | `lua/dbee/lsp/schema_cache.lua:1192-1213` builds cached column completion items into `column_items_by_key`. |
| Column item reads are epoch-gated | `lua/dbee/lsp/schema_cache.lua:2750-2768` wraps `get_column_completion_items` in `epoch_authority.read_with_freshness`. |
| All cached-column reads are epoch-gated | `lua/dbee/lsp/schema_cache.lua:3447-3452` wraps `get_cached_columns` in `epoch_authority.read_with_freshness`. |
| Epoch helper contract | `lua/dbee/lsp/epoch_authority.lua:89-95` fail-closes reads when cache epoch is stale. |
| Completion request path | `lua/dbee/lsp/server.lua:65-128` resolves table/alias context and asks the cache for column completion items with `include_data = true`. |
| Completion resolve wiring | `lua/dbee/lsp/server.lua:619-624` routes `completionItem/resolve` to `resolve.handle`. |
| Resolve stale guard | `lua/dbee/lsp/resolve.lua:176-183` rejects stale generation, stale cache identity, and stale root epoch before rendering docs. |
| Resolve metadata lookup | `lua/dbee/lsp/resolve.lua:98-128` gets schema/table/column metadata from cache APIs. |
| Existing docs metadata fields | `lua/dbee/lsp/object_docs.lua:160-186` already formats column `nullable`, `default`, `primary_key`, and `foreign_key` fields in text docs. |
| Resolve detail overwrite risk | `lua/dbee/lsp/object_docs.lua:233-247` currently sets resolved column `detail` to bare type; Phase 21 must not drop richer completion detail after resolve. |
| Cache mutation paths | `lua/dbee/lsp/schema_cache.lua:964-980` stores columns and updates the column index; `lua/dbee/lsp/schema_cache.lua:1217-1225` rebuilds column indexes; `lua/dbee/lsp/schema_cache.lua:3496-3505` invalidates and resets indexes. |
| Disk cache load path | `lua/dbee/lsp/schema_cache.lua:1949-1951` rebuilds structure/column indexes after v4 disk cache load. Phase 21 must keep reverse-FK rebuild deferred on this path. |
| Async column load path | `lua/dbee/lsp/schema_cache.lua:3191-3195` stores loaded columns and writes them to disk. |
| Rich metadata capability true | `dbee/adapters/postgres_driver_rich_metadata.go:180-186` and `dbee/adapters/oracle_driver.go:468-474` return rich metadata support for Postgres and Oracle. |
| Rich metadata capability false | `dbee/handler/handler.go:589-600` returns an empty column payload with `Supported: false` when columns rich metadata is unsupported. |
| Drawer rich-label precedent | `lua/dbee/ui/drawer/convert.lua:137-154` formats FK labels; `lua/dbee/ui/drawer/convert.lua:158-191` formats PK, nullable false, default, and FK drawer labels. |
| Existing hover/resolve tests | `ci/headless/check_lsp12_hover_resolve.lua:454-475` already verifies schema/table/column completion resolve docs. |
| Existing LSP12 rollup | `ci/headless/check_lsp12_rollup.lua:15-71` demonstrates strict marker lists and exactly-once marker enforcement. |
| Current Makefile LSP loop | `Makefile:161-292` runs the LSP headless and rollup loop; Phase 21 adds new `lsp21*` targets and wires the new rollup. |
| Go module root | `dbee/go.mod:1` is the module root, so Phase 21 Go verification should use `go -C dbee test ./core`, not root `go test ./dbee/core`. |

## Locked Decisions

`PLAN.md` Design Forks table is canonical. This section mirrors the resolved forks in summary form for execution context.

1. Annotation surface is hybrid: raw `label`, modern `labelDetails.detail`, legacy-compatible `detail`.
2. Composite FK popup rendering uses `target_table.(a,b)` for multi-column target tuples.
3. Multiple FK markers render all distinct refs, space-joined, deduped by constraint plus target tuple.
4. Null marker direction is `null` only when `Nullable == true`; PK suppresses `null`.
5. Default-expression popup marker is deferred; existing docs can still show `Default`.
6. Table completion items remain unchanged; Phase 21 annotates column completion only.
7. Reverse-FK index is eager in memory for live metadata paths, derived from loaded columns, epoch-keyed, and never serialized.
8. Reverse-FK indexing uses both `reverse_fk_refs_by_target_key` and `reverse_fk_refs_by_source_key`; source-table eviction is O(refs-for-source), not O(total refs).
9. Reverse-FK lifecycle uses existing `_store_columns`, `_drop_column_index`, `_rebuild_column_indexes`, and `_reset_indexes`; there is no `_post_load_index`.
10. Disk-loaded v4 caches rebuild column completion indexes synchronously but defer reverse-FK index rebuild out of startup.
11. Reverse-FK docs are added through `completionItem/resolve`, not eager completion docs or hover changes.
12. Reverse-FK keys are fold-aware through `schema_name_canonical.canonical(..., quoted=true, self.fold_id)` on writer and reader; display fields keep exact adapter text.
13. Reverse-FK overflow caps are per-target 50 refs, per-source 1000-ref backstop, and total 50k refs with visible truncation and once-per-overflow warning.
14. Reverse-FK overflow bookkeeping uses `{ refs, dropped_count, dropped_sources }`, where dropped source entries retain counts and dropped ref summaries for deterministic promotion.
15. Reverse-FK ordering sorts on read by `(src_schema, src_table, src_col, constraint, ordinal, ref_id)`; `ref_id` is the stable tiebreaker.
16. Reverse-FK resolve transfer is single ownership: cache returns owned refs and `resolve.metadata_for` assigns them without a second deep copy.
17. Resolve memo invalidation uses `reverse_fk_index_generation`, not cache epoch, alongside existing generation/root-epoch guards.
18. Cache version baseline is v4. No v5 bump unless implementation changes serialized disk-cache shape.
19. Unsupported rich metadata fields omit annotations silently.
20. Test adapter breadth is Postgres-style and Oracle-style Lua fixtures plus core Go regression; no live DB.
21. Completion and resolve request paths stay cache-only and perform no sync or async DB metadata work.
22. The three locked helpers are imported and used but not edited:
   - `lua/dbee/schema_filter_authority.lua`
   - `lua/dbee/schema_name_canonical.lua`
   - `lua/dbee/lsp/epoch_authority.lua`

## Design Notes

- There is no existing `_post_load_index` hook. The practical hook is the existing column-index lifecycle: `_store_columns`, `_drop_column_index`, `_rebuild_column_indexes`, and `_reset_indexes`.
- Reverse-FK docs can only reference FKs from source tables whose columns are already loaded into the schema cache. This preserves the no-DB-work LSP contract.
- The deferred disk-load path may return no reverse-FK docs on the first resolve while scheduling in-memory rebuild; subsequent resolve after build completion must return docs without DB calls.
- Deferred reverse-FK build is singleflight: the first dirty resolve flips `reverse_fk_index_building` synchronously before `vim.schedule`, later resolves do not schedule duplicates, and stale build results are discarded on cache-epoch mismatch.
- Cross-schema FK targets do not require the target table to be cached during index construction; resolve docs still require the caller to have resolved target column metadata.
- Composite FK pairing precedence is arrays+valid ordinal, exact `SourceColumn` index in `SourceColumns`, shorthand pair, then skip malformed refs with diagnostics.
- Composite PK ordinals are never fabricated. Multiple PK columns with ordinal 0/nil render `[PK]` rather than misleading `[PK1]`.
- Annotation fast-path is `#markers == 0`; unannotated column items have `labelDetails == nil`.
- Annotation marker arrays are append-only and cannot use fixed numeric marker assignments.
- Unsupported rich metadata adapters produce nil/empty rich fields. Phase 21 treats nil/empty values as unknown/absent and silently omits annotations.
- Default-expression annotations are deferred from the popup marker surface. Existing hover/resolve docs can still show `Default` because `object_docs.lua` already formats it.
