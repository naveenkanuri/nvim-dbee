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
| Disk cache load path | `lua/dbee/lsp/schema_cache.lua:1949-1951` rebuilds structure/column indexes after v4 disk cache load. |
| Async column load path | `lua/dbee/lsp/schema_cache.lua:3191-3195` stores loaded columns and writes them to disk. |
| Rich metadata capability true | `dbee/adapters/postgres_driver_rich_metadata.go:180-186` and `dbee/adapters/oracle_driver.go:468-474` return rich metadata support for Postgres and Oracle. |
| Rich metadata capability false | `dbee/handler/handler.go:589-600` returns an empty column payload with `Supported: false` when columns rich metadata is unsupported. |
| Drawer rich-label precedent | `lua/dbee/ui/drawer/convert.lua:137-154` formats FK labels; `lua/dbee/ui/drawer/convert.lua:158-191` formats PK, nullable false, default, and FK drawer labels. |
| Existing hover/resolve tests | `ci/headless/check_lsp12_hover_resolve.lua:454-475` already verifies schema/table/column completion resolve docs. |
| Existing LSP12 rollup | `ci/headless/check_lsp12_rollup.lua:15-71` demonstrates strict marker lists and exactly-once marker enforcement. |
| Current Makefile LSP loop | `Makefile:161-292` runs the LSP headless and rollup loop; Phase 21 adds new `lsp21*` targets and wires the new rollup. |
| Go module root | `dbee/go.mod:1` is the module root, so Phase 21 Go verification should use `go -C dbee test ./core`, not root `go test ./dbee/core`. |

## Locked Decisions

1. Cache version baseline is v4. No v5 bump unless implementation changes serialized disk-cache shape.
2. Reverse-FK index is derived in memory from already-loaded `Column.ForeignKeys`; it is never serialized.
3. Column completion labels remain the raw column name so `insertText`, `data.column`, and resolve metadata keep working.
4. LSP 3.17 clients get `labelDetails.detail`; older clients get a compatible `detail` string.
5. Reverse-FK docs are added through `completionItem/resolve`, not eager completion item documentation.
6. Completion and resolve request paths stay cache-only and perform no sync or async DB metadata work.
7. The three locked helpers are imported and used but not edited:
   - `lua/dbee/schema_filter_authority.lua`
   - `lua/dbee/schema_name_canonical.lua`
   - `lua/dbee/lsp/epoch_authority.lua`

## Design Notes

- There is no existing `_post_load_index` hook. The practical hook is the existing column-index lifecycle: `_store_columns`, `_drop_column_index`, `_rebuild_column_indexes`, and `_reset_indexes`.
- Reverse-FK docs can only reference FKs from source tables whose columns are already loaded into the schema cache. This preserves the no-DB-work LSP contract.
- Unsupported rich metadata adapters produce nil/empty rich fields. Phase 21 treats nil/empty values as unknown/absent and silently omits annotations.
- Default-expression annotations are deferred from the popup marker surface. Existing hover/resolve docs can still show `Default` because `object_docs.lua` already formats it.

