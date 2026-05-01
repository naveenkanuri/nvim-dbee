# Phase 12.2: LSP Symbols - Research

**Researched:** 2026-05-01
**Status:** Aligned with plan revision 2

## Protocol Facts

### `textDocument/documentSymbol`

- Request method: `textDocument/documentSymbol`.
- Client capability to check: `textDocument.documentSymbol.hierarchicalDocumentSymbolSupport`.
- Result shape: `DocumentSymbol[] | SymbolInformation[] | null`.
- `DocumentSymbol` supports nested `children`, making it the right shape for `Schema -> Table -> Column`.
- `SymbolInformation` is the compatibility fallback. It is flat and uses `containerName` for hierarchy context.
- `DocumentSymbol.range` covers the full symbol extent; `selectionRange` covers the identifier users select/jump to. Phase 12.2 can use the identifier range for both when only an identifier span is available.

### `workspace/symbol`

- Request method: `workspace/symbol`.
- Result shape: `SymbolInformation[] | WorkspaceSymbol[] | null`.
- `WorkspaceSymbol` is the newer shape and can represent non-file workspace symbols more naturally.
- `workspace/symbol` does not return a `CompletionList`-like object and has no standard top-level `isIncomplete` field. Deterministic result caps are the MVP paging/truncation mechanism.
- Client query matching is intentionally loose by convention. Phase 12.2 locks case-insensitive canonical substring matching for v1.3; ordered-character relaxed matching is useful but deferred to v1.4 to avoid adding fuzzy ranking scope.

### Symbol Kinds

Use the standard `SymbolKind` numeric enum:

| dbee object | LSP kind | Value |
| --- | --- | --- |
| Schema | Namespace | 3 |
| Table/view/materialized view | Class | 5 |
| Column | Field | 8 |

## Local Integration Research

### Server

`lua/dbee/lsp/server.lua` currently advertises hover and completion resolve:

- `hoverProvider = feature_config.hover`
- `completionProvider.resolveProvider = feature_config.resolve`
- `textDocumentSync.openClose = true`
- `textDocumentSync.change = 1` full sync

Phase 12.2 should add:

- `documentSymbolProvider = true` behind `lsp.document_symbols`.
- `workspaceSymbolProvider = true` behind `lsp.workspace_symbols`.
- Request branches for `textDocument/documentSymbol` and `workspace/symbol`.
- Notify handling for `textDocument/didChange` and `textDocument/didClose` to invalidate document-symbol parse cache.

### Config

`lua/dbee/config.lua` currently exposes:

- `lsp.diagnostics_mode`
- `lsp.diagnostics_debounce_ms`
- `lsp.hover`
- `lsp.resolve`

Phase 12.2 should add:

- `lsp.document_symbols = true`
- `lsp.workspace_symbols = true`

No adapter API change is needed because symbols are based on SQL text and existing cache state.

### SQL Context Parsing

`lua/dbee/lsp/context.lua` already provides:

- Quote-aware identifier parsing.
- `extract_statements(text)` with absolute offsets.
- `statement_offset_to_position`.
- Table-reference parsing for `FROM`, comma `FROM` lists, `JOIN`, `UPDATE`, and `INTO`.
- Hover-specific statement extraction and semicolon handling.

Research conclusion: add document-symbol scanning as a new full-buffer wrapper. Reuse identifier/table-ref primitives where possible, but keep hover's 200-line cursor scan separate.

### Schema Cache

Workspace symbols must not walk raw cache tables from the handler directly. Add a schema-cache helper such as `get_workspace_symbols_snapshot(opts)` that:

- Calls `epoch_authority.read_with_freshness(self, self.handler, self.conn_id, ...)`.
- Reads current LSP authority using the existing schema-cache authority wrapper.
- Filters schemas through `schema_filter_authority`.
- Uses `schema_name_canonical` for query matching and dedupe.
- Returns exact display names, object type, and deterministic sort keys.
- Applies result cap before copying large result sets.

### Helper Composition

Phase 12.2 uses the three existing helpers as independent sources of truth:

| Bug class | Helper | Phase 12.2 application |
| --- | --- | --- |
| Schema authority fail-open | `schema_filter_authority.lua` | Workspace symbol cache reads fail closed if authority is unavailable. |
| Case-folding / quoted-name leaks | `schema_name_canonical.lua` | Query matching and dedupe use canonical helper; display names stay exact. |
| Epoch-coherency leaks | `epoch_authority.lua` | Workspace cache snapshots return nil/empty when cache root is stale. |

Document symbols are source-text references, so they do not require schema-filter authority for emission. Any optional cache enrichment for document symbols must be helper-routed and must degrade to name-only when stale/unavailable.

## Response Shape Choices

### Document Symbols

Preferred result:

```lua
{
  {
    name = "public",
    kind = 3,
    range = schema_range,
    selectionRange = schema_range,
    children = {
      {
        name = "users",
        kind = 5,
        range = table_range,
        selectionRange = table_range,
        children = {
          { name = "id", kind = 8, range = column_range, selectionRange = column_range },
        },
      },
    },
  },
}
```

Fallback result:

```lua
{
  {
    name = "users",
    kind = 5,
    location = { uri = params.textDocument.uri, range = table_range },
    containerName = "public",
  },
}
```

### Workspace Symbols

Preferred shape when accepted by client capabilities:

```lua
{
  {
    name = "users",
    kind = 5,
    containerName = "public",
    location = { uri = "dbee://<conn-id>/public/users" },
  },
}
```

Compatibility fallback:

```lua
{
  {
    name = "users",
    kind = 5,
    containerName = "public",
    location = {
      uri = "dbee://<conn-id>/public/users",
      range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
    },
  },
}
```

## Performance Research

- Document symbols parse current buffer text only. With a 10,000-line / 1 MiB cap and a regex-oriented scanner, P95 <50ms is realistic in the existing headless harness.
- Workspace symbols over 10,000 tables should stay <100ms if the cache helper filters and caps before deep-copying and avoids sorting full rich metadata. Deterministic sorting by canonical schema/table is acceptable if it is done over compact name records.
- Workspace symbols should not add a persistent cache layer in Phase 12.2. The existing schema cache is already the persistence and freshness boundary.

## Test Strategy

- New functional sentinel file: `ci/headless/check_lsp12_2_symbols.lua`.
- Extend `ci/headless/check_lsp12_rollup.lua` with a Phase 12.2 marker set and exactly-once checks.
- Extend `ci/headless/check_lsp_perf.lua` with a separate Phase 12.2 perf section:
  - documentSymbol cold parse.
  - documentSymbol cached parse for the same buffer.
  - workspace/symbol empty-query all-match over 10,000 cached tables.
  - workspace/symbol selective canonical substring query over 10,000 cached tables.
- Preserve `LSP12_PERF_SCENARIOS_COUNT=10` for Phase 12.1. Emit `LSP12_2_PERF_SCENARIOS_COUNT=5` for Phase 12.2, including the dense-reference documentSymbol cohort added during impl-gate r1.

## Open Implementation Notes For Planner

- Prefer a new `lua/dbee/lsp/symbols.lua` module that owns both handlers and parse cache.
- Keep any schema-cache workspace-symbol snapshot helper small and bounded.
- Do not extend `object_docs.lua`; symbols are name-only and do not render markdown.
- Add grep/static sentinels for no sync DB, no async DB, no direct epoch reads, and no local canonical folding in symbol paths.

## References

- Official Language Server Protocol 3.17 specification: `textDocument/documentSymbol`, `DocumentSymbol`, `SymbolInformation`, `workspace/symbol`, `WorkspaceSymbol`, and `SymbolKind`.
- `.planning/DISCUSS-phase12.md`
- `.planning/phases/12-lsp-feature-gap-closure/12-01-PLAN.md`
- `lua/dbee/lsp/server.lua`
- `lua/dbee/lsp/context.lua`
- `lua/dbee/lsp/schema_cache.lua`
- `lua/dbee/lsp/epoch_authority.lua`
- `lua/dbee/schema_filter_authority.lua`
- `lua/dbee/schema_name_canonical.lua`
