# Phase 12: LSP Feature Gap Closure - Discussion

**Gathered:** 2026-05-01
**Status:** Ready for research
**Codex thread:** `019ddb0e-e8d0-7ca1-a4b0-8d4728863630`

## Phase Boundary

Phase 12 adds additive LSP features that can be answered truthfully from current dbee schema/cache state: hover, `completionItem/resolve`, code actions, and document/workspace symbols.

This is the deferred DBEE-FEAT-02 scope. The roadmap also records the same work as conditional v1.3 Phase 16; this artifact follows the user-selected Phase 12 label and treats the scope as activated after Phase 11 r6 shipped cleanly at `9a8b8ff`.

Out of scope:
- Semantic tokens, inlay hints, `vim.lsp.config()` migration, and multi-client/per-buffer LSP architecture.
- Parser-heavy SQL intelligence beyond the current regex/context style.
- External formatter dependency for Phase 12.
- New adapter support or new rich metadata contracts beyond graceful use of data already available in schema cache.

## Carry-Forward Constraints

- Honor D-01..D-305.
- Preserve Phase 10/11 LSP performance and correctness contracts: no synchronous DB metadata work on completion/hover/resolve/code-action request paths.
- Preserve Phase 14 fail-closed authority invariant: schema scoping uses `lua/dbee/schema_filter_authority.lua`.
- Preserve Phase 11 r6 canonical schema-name invariant: schema/table lookup uses `lua/dbee/schema_name_canonical.lua`.
- Built-in dbee LSP remains in-process and singleton-per-current-connection for this phase.
- Existing external completion compatibility must remain additive; do not break `nvim-cmp` or `blink.cmp`.

## Decision Matrix

| Area | Locked Default | Rationale | Deferred |
| --- | --- | --- | --- |
| Hover scope | Hover supports schema, table/view, and column identifiers only. SQL keywords return no hover. | Cache-backed object metadata is useful; keyword docs invite a SQL reference project and parser scope creep. | Keyword reference hover. |
| Hover metadata | Column hover shows name, type, nullable, default, PK/FK flags when cached. Table hover shows schema, object type, loaded column count, PK columns if cached, and row count only if already available. Schema hover shows loaded table count and a truncated table preview. | Truthful minimum from existing cache. Rich metadata can enrich later without changing protocol shape. | Row-count queries and FK graph expansion if not already cached. |
| Hover rendering | Prefer Markdown `MarkupContent`; provide plain text fallback through the same formatter. | Most LSP clients render markdown, and fallback keeps older clients usable. | Client-specific rendering branches. |
| Hover trigger | Standard `textDocument/hover` on cursor token only. Mouse hover is client behavior and not a separate server feature. | Keeps implementation inside standard LSP. | Custom mouse UX. |
| Resolve scope | Enable `completionProvider.resolveProvider=true`. Resolve schema/table/column completion items that carry dbee `data`; keyword items do not resolve. | Object completions can be enriched lazily without changing insert behavior. Keywords have no useful cache-backed detail. | Keyword resolve docs. |
| Resolve data | Resolve adds markdown docs, fully-qualified identity, type/materialization, column signature, and PK/FK/null/default details when cached. | Adds value without eager metadata loading. | Examples generated from SQL templates unless proven cheap. |
| Resolve cache | Cache resolved details once per item identity plus cache generation/root epoch. Invalidate on cache refresh, connection switch, filter change, or authoritative root epoch change. | Prevents stale docs and repeated formatting work. | Cross-session resolved-detail persistence. |
| Resolve fetch policy | Cache-first only on the request path. It may use existing async warm paths only if the reply remains bounded; no synchronous DB call is allowed. | Preserves Phase 11 no-blocking contract. | Long-running resolve fetches. |
| Code action MVP | MUST include `Expand SELECT *`, `Qualify identifier`, and schema/table refresh or reload action where a diagnostic/unloaded schema makes it relevant. | The user-suggested MVP covers pure SQL edits; roadmap DBEE-FEAT-02 also explicitly calls out schema refresh/reload code actions. | Generate JOIN and Format SQL. |
| Code action optional | `Add LIMIT clause` is a SHOULD if it stays pure text edit and adapter-safe. It must not delay the core code-action MVP. | Useful safety net, but not schema-cache-specific. | Dialect-specific LIMIT/TOP/FETCH FIRST expansion if not trivial. |
| Code action data rules | Actions appear only when the required metadata is cached and in-scope. If cache data is missing, omit the action instead of guessing. | Prevents false edits and keeps fail-closed behavior. | Heuristic actions based only on raw identifier strings. |
| Generate JOIN | Defer until richer FK metadata is available. | Current cache may not reliably expose FK edges across adapters. | Phase X.1 rich metadata or later. |
| Format SQL | Defer; do not add formatter dependency in Phase 12. | Formatting is already explicitly out of scope in REQUIREMENTS and better delegated to user formatter tooling. | Future formatter integration phase. |
| Document symbols | Return referenced schemas/tables in the current SQL buffer. Prefer hierarchy `Schema -> Table`; include columns only when explicitly referenced or already loaded. | Useful navigation without whole-file semantic SQL parser. | Full AST symbol tree. |
| Workspace symbols | Search known in-scope schema cache objects for the active/current connection. Return flat symbols with `containerName` for schema/table context. | `workspace/symbol` is naturally global search; flat results are simpler and client-friendly. | Multi-connection workspace symbols. |
| Symbol authority | Workspace symbols must call through schema-filter authority for the active connection. `authority_unavailable` returns empty; `api_absent_legacy` preserves legacy all-schema behavior. | Carries Phase 14 fail-closed invariant into new surface. | Bypassing authority for convenience. |
| Symbol canonicalization | Lookup and display must preserve exact display names but use `schema_name_canonical` for matching and dedupe. | Carries Phase 11 r6 invariant into new surface. | Local lower/upper folding in symbol code. |
| Adapter degradation | All features degrade gracefully: name-only hover/resolve when rich fields are absent, omit unsupported code actions, and return empty symbols if cache is unavailable. | Adapter diversity is a project constraint. | Adapter-specific hard failures. |
| Capability surface | Add an additive LSP capability helper/table if the codebase lacks one. Minimum flags: `lsp.hover`, `lsp.resolve`, `lsp.code_actions`, `lsp.symbols`; capabilities should be data-driven and default to cache-backed support. | Keeps feature gating explicit without forcing Go adapter redesign. | Broad adapter interface redesign. |
| Performance budget | Hover P95 <50ms; document symbols P95 <50ms; resolve P95 <100ms; workspace symbol P95 <200ms on 10k tables. | Matches existing LSP perf posture and user-specified budgets. | Frozen thresholds in this phase unless planning decides enough samples exist. |
| Integration | Use standard LSP methods only: `textDocument/hover`, `completionItem/resolve`, `textDocument/codeAction`, `textDocument/documentSymbol`, `workspace/symbol`. | Works with built-in LSP, `nvim-cmp`, and `blink.cmp` through protocol compatibility. | Custom cmp-only API. |
| Tests | Add LSP12 sentinels for each surface plus perf markers. Headless tests simulate LSP requests and assert response shape, authority behavior, canonical lookup, and no sync DB calls. | Matches Phase 10/11/14 evidence style. | Manual-only validation. |

## Locked Decisions

### LSP Surface
- **D-306:** Phase 12 enables only standard LSP surfaces: hover, completion item resolve, code actions, document symbols, and workspace symbols.
- **D-307:** Existing completion behavior must remain compatible. Completion labels, insert text, trigger characters, and async `isIncomplete` semantics from Phase 11 are not redesigned.
- **D-308:** `completionItem/resolve` is additive. Completion items that cannot be resolved safely are returned unchanged.

### Hover
- **D-309:** Hover is object-only: schemas, tables/views/materialized views where represented, and columns. SQL keyword hover is out of scope.
- **D-310:** Hover output uses markdown by default and plain text fallback from the same data model.
- **D-311:** Hover must be cache-backed and bounded. It must never issue synchronous metadata SQL or Go RPC on the request path.
- **D-312:** Missing metadata is represented honestly: return no hover or a minimal name-only hover, not guessed PK/FK/default/row-count data.
- **D-313:** Schema hover truncates table previews, with exact cutoff left to planning.

### Completion Resolve
- **D-314:** The LSP server advertises `resolveProvider=true` only after it implements a bounded `completionItem/resolve` handler.
- **D-315:** Resolvable completion items carry compact `data` identifying kind, connection/cache generation, schema/table/column identity, and quote/canonical state as needed.
- **D-316:** Resolve details are cached per item identity and invalidated with schema cache refresh, root epoch change, filter change, or connection switch.
- **D-317:** Resolve may enrich from already-loaded cache state. If required data is not loaded, it returns the best cache-truthful detail and does not block waiting for DB metadata.

### Code Actions
- **D-318:** Phase 12 code-action MVP is `Expand SELECT *`, `Qualify identifier`, and schema/table refresh or reload actions for relevant diagnostics or unloaded schema state.
- **D-319:** `Add LIMIT clause` is optional and may be included only if it stays pure text-edit, dialect-safe enough for existing adapters, and does not delay the MVP.
- **D-320:** `Generate JOIN` is deferred until rich FK metadata is available. Do not synthesize joins from naming heuristics.
- **D-321:** `Format SQL` is deferred. Do not add an external formatter dependency in Phase 12.
- **D-322:** Code actions must be omitted when the required object is filtered out, authority is unavailable, or metadata is insufficient.

### Symbols
- **D-323:** `textDocument/documentSymbol` parses the current buffer only and returns referenced schema/table objects. It does not search the database or refresh metadata.
- **D-324:** Document symbols prefer hierarchy `Schema -> Table -> Column` when enough information exists; otherwise they return the most specific truthful symbol.
- **D-325:** `workspace/symbol` searches the active connection's known in-memory/disk-loaded schema cache only and respects schema filter authority.
- **D-326:** Workspace symbols are flat LSP symbols with `containerName` carrying schema/table context.
- **D-327:** Symbols use `schema_name_canonical` for lookup/dedupe and preserve original display names in returned symbols.

### Adapter Capabilities And Degradation
- **D-328:** Feature support is data-driven. A missing rich field degrades that field only; it does not disable the whole LSP feature.
- **D-329:** Add an explicit, additive LSP capability surface if no suitable one exists. It must not require breaking Go adapter interfaces.
- **D-330:** Adapter-specific behavior must stay conservative: no FK/PK/indexed-column claims unless the existing cache payload proves them.

### Performance And Evidence
- **D-331:** Hover, resolve, code actions, and symbols must not introduce synchronous database metadata calls on LSP request paths.
- **D-332:** Extend `make perf-lsp` with Phase 12 scenarios and grep-friendly `LSP12_*` sentinels.
- **D-333:** Required performance targets are advisory initially: hover P95 <50ms, resolve P95 <100ms, document symbols P95 <50ms, workspace symbols P95 <200ms on 10k tables.
- **D-334:** Phase 12 must preserve all ARCH14, UX13, LSP11, DRAW01, STRUCT01, NOTES01, and DCFG rollups.

### Scope Guards
- **D-335:** Do not reopen single-source helper designs. New Phase 12 consumers must route through `schema_filter_authority` and `schema_name_canonical` directly.
- **D-336:** Multi-client/per-buffer connection architecture remains deferred even if workspace symbols would benefit from it.
- **D-337:** If an LSP feature cannot be implemented truthfully from current cache state, ship a narrower truthful version and record the richer version as deferred.

## Recommended Sub-Phase Split

### Phase 12.1 - Hover And Resolve
**Complexity:** Medium

Deliver:
- Capability advertisement updates.
- Completion item `data` model.
- `completionItem/resolve` for schema/table/column completions.
- `textDocument/hover` using cache-backed object lookup.
- Shared markdown/plain formatter for object metadata.
- Initial LSP12 hover/resolve sentinels and perf cases.

Rationale: Hover and resolve share object-identification and documentation formatting. They should land together before code actions consume the same resolution helpers.

### Phase 12.2 - Symbols
**Complexity:** Medium

Deliver:
- `textDocument/documentSymbol` from current buffer references.
- `workspace/symbol` over known in-scope cache objects.
- Authority and canonical-helper routing tests.
- 10k-table workspace symbol perf scenario.

Rationale: Symbol search is cache/index work and should land after object resolution helpers exist, but before edit-producing actions.

### Phase 12.3 - Code Actions
**Complexity:** Large

Deliver:
- `Expand SELECT *`.
- `Qualify identifier`.
- Schema/table refresh or reload code actions.
- Optional `Add LIMIT clause` only if planning proves it is small and adapter-safe.
- Code-action response-shape tests and no-sync-DB tests.

Rationale: Code actions have the highest correctness risk because they edit user SQL. Keep them separate from read-only LSP surfaces.

## MVP Vs Deferred

### MVP For v1.3
- Hover for schema/table/column objects from cache.
- Resolve for schema/table/column completion items.
- Document symbols for referenced objects in the current SQL buffer.
- Workspace symbols over active, in-scope cached schema objects.
- Code actions: `Expand SELECT *`, `Qualify identifier`, schema/table refresh or reload.
- LSP12 sentinel and perf coverage integrated into `make perf-lsp`.

### Defer
- Generate JOIN from FK metadata.
- Format SQL.
- Keyword reference hover.
- Row count queries.
- Rich FK/index/constraint display beyond fields already present in cache.
- Semantic tokens, inlay hints, `vim.lsp.config()` migration, multi-client LSP architecture.

## Surfaced Design Forks

### Code Actions: SQL Refactors Vs Roadmap Refresh Actions
The prompt emphasizes SQL refactors, while DBEE-FEAT-02 explicitly names schema refresh/reload code actions. Locked decision: include both the pure-Lua refactor MVP and the refresh/reload action, but keep Generate JOIN and Format SQL deferred.

### Resolve: Lazy Fetch Vs Cache-Only
Resolve could fetch missing details when a user selects an item, but Phase 11 forbids blocking metadata fetches on LSP request paths. Locked decision: resolve is cache-first and bounded. It may only use existing async paths if response timing stays within budget and does not reintroduce sync DB work.

### Symbols: Hierarchical Vs Flat
Document symbols benefit from hierarchy because they represent one SQL buffer. Workspace symbols should stay flat because LSP clients expect searchable global results. Locked decision: hierarchical document symbols, flat workspace symbols.

## Risks And Dependencies

- Parser limits: current LSP context is regex-oriented. Phase 12 must avoid pretending to understand all SQL grammar.
- Cache truthfulness: hover/resolve/actions must not invent PK/FK/default/row-count metadata when unavailable.
- Edit safety: code actions can damage SQL if ranges are wrong. They need focused tests around quoted identifiers, aliases, schema-qualified references, and multi-line statements.
- Authority leaks: workspace symbols and code actions must fail closed when schema-filter authority is unavailable.
- Canonical leaks: all object lookups must route through `schema_name_canonical` and preserve quoted identifier semantics.
- Performance: workspace symbol search over 10k tables needs bounded indexes or precomputed symbol arrays.
- Dependency on rich metadata: Generate JOIN and richer PK/FK hover are blocked until a later rich-table-metadata phase unless existing cache fields are sufficient.

## Canonical References

Downstream agents must read these before research or planning:

- `.planning/PROJECT.md` - v1.3 milestone focus, constraints, and DBEE-FEAT-02 positioning.
- `.planning/REQUIREMENTS.md` - DBEE-FEAT-02 and out-of-scope LSP exclusions.
- `.planning/ROADMAP.md` - Phase 12 and deferred Phase 16 entries for LSP feature gap closure.
- `.planning/phases/10-lsp-optimization/10-CONTEXT.md` - LSP perf harness and evidence contracts.
- `.planning/phases/11-lsp-optimization-correctness/11-CONTEXT.md` - LSP async, cache, diagnostics, and no-sync request-path contracts.
- `.planning/phases/14-enterprise-db-architecture/14-CONTEXT.md` - schema filter authority, lazy schema loading, and D-224..D-305 constraints.
- `lua/dbee/lsp/server.lua` - in-process LSP request dispatcher and current capability advertisement.
- `lua/dbee/lsp/context.lua` - SQL context parsing and quote metadata.
- `lua/dbee/lsp/schema_cache.lua` - cache indexes, completion items, async column/schema-object miss paths, and object lookup helpers.
- `lua/dbee/lsp/init.lua` - LSP startup, current connection ownership, refresh notifications, and cache lifecycle.
- `lua/dbee/handler/init.lua` - schema filter authority calls, schema/object singleflight, and async metadata events.
- `lua/dbee/schema_filter_authority.lua` - Phase 14 fail-closed authority helper.
- `lua/dbee/schema_name_canonical.lua` - Phase 11 r6 canonical schema-name helper.
- `ci/headless/check_lsp_perf.lua` - LSP perf harness to extend with LSP12 scenarios.
- `ci/headless/check_lsp_schema_cache_optimization.lua` - canonical-helper sentinel precedent.
- `ci/headless/check_lsp_schema_filter_lazy.lua` - schema-filter/lazy LSP behavior precedent.
- `ci/headless/check_ux13_rollup.lua` and `ci/headless/check_arch14_rollup.lua` - rollup marker patterns.
- `Makefile` - `make perf-lsp` integration point.

## Existing Code Insights

### Reusable Assets
- `server.create(cache)` already centralizes LSP request handling and capability advertisement.
- `context.parse_table_ref()` and quote-aware context parsing are the starting point for hover, symbols, and code actions.
- `SchemaCache` already exposes schema/table/column lookup and completion item generation with canonical/quoted semantics.
- `schema_filter_authority.read()` and `schema_name_canonical.*` are the mandatory helpers for new feature paths.
- Existing headless LSP tests already simulate LSP requests against `server.create(cache)`.

### Established Patterns
- LSP features are in-process and cache-backed.
- Perf evidence uses `make perf-lsp`, `LSP01`/`LSP11`/`UX13` marker rollups, and advisory perf thresholds.
- Async metadata work uses handler events and singleflight; request handlers must not call synchronous DB metadata functions.
- New bug-class-prone logic should be centralized behind helper APIs and guarded by grep-like sentinels.

### Integration Points
- Update LSP server capabilities for hover, resolve, code action, document symbol, and workspace symbol providers.
- Add cache/documentation formatting helpers near LSP server/cache code.
- Extend completion item `data` without changing labels/insert text.
- Extend perf and headless rollups with `LSP12_*` markers.

## Ready-For-Research Checklist

- [ ] Confirm exact LSP response shapes for hover, resolve, code actions, document symbols, and workspace symbols.
- [ ] Identify Neovim built-in LSP expectations for `completionItem/resolve` and compatibility with `nvim-cmp` and `blink.cmp`.
- [ ] Inspect current completion item fields and decide minimal stable `data` payload.
- [ ] Map cache fields available today for schema/table/column docs.
- [ ] Identify whether existing cache indexes are enough for 10k-table workspace symbol P95 <200ms.
- [ ] Determine safe text-edit range strategy for `Expand SELECT *` and `Qualify identifier`.
- [ ] Define LSP12 sentinel names and rollup wiring.
- [ ] Verify no feature requires sync DB metadata on request path.

## Deferred Ideas

- Rich table metadata phase: FK edges, indexed columns, row counts, descriptions/comments, richer PK/FK hover.
- SQL formatter integration through user-configured formatter or external plugin.
- Generate JOIN from FK metadata.
- Semantic tokens and inlay hints.
- Multi-connection workspace symbols after multi-client/per-buffer LSP architecture exists.

---

*Phase: 12-lsp-feature-gap-closure*
*Context gathered: 2026-05-01*
