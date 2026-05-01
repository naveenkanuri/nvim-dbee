# Phase 12.2: LSP Document And Workspace Symbols - Discussion

**Gathered:** 2026-05-01
**Status:** Aligned with plan revision 2
**Codex thread:** `019de2ac-edf7-76a1-ba1a-c3f738a2dd10`

## Phase Boundary

Phase 12.2 ships the read-only symbol portion of Phase 12:

- `textDocument/documentSymbol` for referenced schemas, tables, and safely-associated columns in the current SQL buffer.
- `workspace/symbol` for schemas and tables already known in the active connection's schema cache.

This phase does not add code actions, semantic tokens, inlay hints, a SQL AST dependency, multi-client/per-buffer connection architecture, or database refresh behavior. Symbols are cache/source-text views only.

## Carry-Forward Constraints

- Honor D-01..D-395, especially Phase 12.1 helper invariants.
- Preserve singleton-per-current-connection LSP behavior.
- Preserve Phase 10/11 no-sync/no-blocking LSP request-path contracts.
- Preserve Phase 14 schema-filter authority through `lua/dbee/schema_filter_authority.lua`.
- Preserve Phase 11 r6 canonical-name handling through `lua/dbee/schema_name_canonical.lua`.
- Preserve Phase 12.1 epoch coherency through `lua/dbee/lsp/epoch_authority.lua`.
- Do not touch existing helper modules unless a later gate explicitly asks for helper work.

## Locked Decisions

### Document Symbols

- Use `DocumentSymbol[]` when the client advertises hierarchical document symbol support.
- Fall back to flat `SymbolInformation[]` when hierarchical document symbols are not supported.
- Default hierarchy is `Schema -> Table -> Column`.
- Tables and schemas are required MVP output. Columns are emitted only when the parser can associate the column with a table unambiguously, such as `table.column`, alias-qualified columns, or a single-table statement.
- Unknown referenced tables still appear as document symbols because document symbols reflect source references, not cached database truth.
- Ranges use the identifier span in the SQL buffer. Grouping ranges use the first source occurrence for the grouped symbol.
- Repeated references are deduped by canonical schema/table/column identity within the document, with display names preserved from the first occurrence.

### Document Parse Scope

- `documentSymbol` is a whole-document request, so Phase 12.2 will not reuse the 200-line cursor hover scan as the primary symbol scan.
- The parser scans the full buffer up to an explicit hard cap: 10,000 lines or 1 MiB of joined text, whichever is hit first.
- If the cap is hit, the handler returns the truthful subset discovered within the cap and must stay under the performance budget. No database work is started.
- A per-buffer parse cache is allowed and should be keyed by URI, bufnr, changedtick, and symbol response mode. It is invalidated on `textDocument/didChange`, `textDocument/didClose`, buffer deletion, or changedtick mismatch.

### Workspace Symbols

- `workspace/symbol` searches the active connection only. Multi-connection workspace symbols stay deferred until multi-client/per-buffer connection ownership exists.
- Source is schema cache only: known schemas and tables from memory or already-loaded disk cache.
- Workspace symbols must fail closed through `schema_filter_authority.read()` and `epoch_authority.read_with_freshness()`.
- Display names preserve exact schema/table names. Matching and dedupe use `schema_name_canonical`.
- Query semantics are case-insensitive canonical substring matching only for v1.3. Ordered-character relaxed matching is deferred to v1.4 so Phase 12.2 can stay cache-only and deterministic.
- Results are deterministically capped, default 200 symbols. LSP `workspace/symbol` returns a plain symbol array or `null`; it does not provide a standard `isIncomplete` wrapper. Phase 12.2 therefore uses a fixed cap and deterministic ordering, not a protocol `isIncomplete` field.
- Response shape is flat. Prefer `WorkspaceSymbol[]` when usable; otherwise return `SymbolInformation[]` with `containerName` and a synthetic `dbee://` URI plus zero range.
- No `workspaceSymbol/resolve` handler is in MVP.

### Symbol Kinds

- Schema: `SymbolKind.Namespace` (`3`)
- Table/view/materialized view: `SymbolKind.Class` (`5`)
- Column: `SymbolKind.Field` (`8`)

### Capability And Config Surface

- Add `lsp.document_symbols = true` and `lsp.workspace_symbols = true`, both defaulting to enabled.
- Advertise `documentSymbolProvider = true` and `workspaceSymbolProvider = true` only when corresponding flags are enabled.
- No Go adapter capability change is required. Symbols are name-only/cache-only and degrade by available schema cache content.

### Performance And Evidence

- `documentSymbol` P95 target: <50ms on the headless Phase 12.2 corpus.
- `workspace/symbol` P95 target: <100ms for a 10,000-table cached connection.
- Add a separate Phase 12.2 perf section with five cohorts: documentSymbol cold parse, documentSymbol cached parse, documentSymbol dense references, workspace/symbol empty-query all-match, and workspace/symbol selective substring query. Emit `LSP12_2_PERF_SCENARIOS_COUNT=5` so Phase 12.1 `LSP12_PERF_SCENARIOS_COUNT=10` remains stable.
- Add strict `LSP12_2_*` sentinels and wire them into the existing LSP12 rollup and UX13 aggregate flow.

## Deferred Ideas

- `workspaceSymbol/resolve` for richer object details.
- Multi-connection workspace symbol search.
- SQL AST parser dependency for exact column scoping in arbitrary SQL.
- Code actions, including schema refresh/reload and SQL edits, remain Phase 12.3.
- Semantic tokens, inlay hints, and `vim.lsp.config()` migration remain out of scope.

## Canonical References

- `.planning/DISCUSS-phase12.md` - Phase 12 umbrella decisions D-306..D-337.
- `.planning/phases/12-lsp-feature-gap-closure/12-01-PLAN.md` - Phase 12.1 decisions D-338..D-395 and helper invariants.
- `.planning/REQUIREMENTS.md` - DBEE-FEAT-02 and LSP exclusions.
- `.planning/ROADMAP.md` - Phase 12 / Phase 16 feature-gap scope.
- `lua/dbee/lsp/server.lua` - LSP dispatcher, capability advertisement, diagnostics, and text document sync.
- `lua/dbee/lsp/context.lua` - existing SQL token, range, alias, and table-reference parsing.
- `lua/dbee/lsp/schema_cache.lua` - cache indexes, metadata helpers, and helper-routed freshness reads.
- `lua/dbee/lsp/epoch_authority.lua` - Phase 12.1 epoch source of truth.
- `lua/dbee/schema_filter_authority.lua` - Phase 14 schema filter source of truth.
- `lua/dbee/schema_name_canonical.lua` - Phase 11 r6 canonical-name source of truth.
- `ci/headless/check_lsp12_rollup.lua` - strict marker and exactly-once rollup pattern.
- `ci/headless/check_lsp_perf.lua` - perf harness to extend with Phase 12.2 scenarios.

## Existing Code Insights

- `server.create(cache)` already has initialize, hover, completion, resolve, diagnostics, and full text sync hooks.
- `context.extract_statements`, `statement_offset_to_position`, `token_at_position`, and hover table-ref parsing are the right starting point for symbol extraction, but document symbols need a full-document scanner wrapper instead of cursor-bounded hover extraction.
- `schema_cache.lua` already centralizes epoch freshness, authority, canonical lookup, and bounded metadata snapshots. Workspace symbols should add a dedicated cache snapshot helper instead of reading raw tables directly from `symbols.lua`.
- Phase 12.1 review history shows repeated bug-class leakage when new metadata consumers bypass helper APIs. Phase 12.2 must route workspace symbols, diagnostics-adjacent reads, and any cache snapshots through the three helpers from the start.

---

*Phase: 12.2-lsp-symbols*
*Context gathered: 2026-05-01*
