# Phase 12.1: LSP Hover + Completion Resolve - Research

**Gathered:** 2026-05-01  
**Status:** Ready for plan  
**Scope:** `textDocument/hover` and `completionItem/resolve` only  
**Source phase context:** `.planning/DISCUSS-phase12.md`  
**Note:** `gsd-sdk` does not currently recognize `12.1` as a standalone roadmap phase. This research treats Phase 12.1 as the locked sub-phase split from `.planning/DISCUSS-phase12.md`.

## Summary

Phase 12.1 should add two read-only LSP surfaces to the existing in-process dbee LSP: cache-backed object hover and bounded completion item resolve. Both features should reuse the same object-identification and documentation formatting path so that later Phase 12.2 symbols and Phase 12.3 code actions can build on the same truth source.

The central implementation constraint is that current cache data is intentionally thin. `core.Column` exposes only `name` and `type`, and `DBStructure` exposes `name`, `type`, optional `schema`, and child nodes. Hover/resolve can present schema/table/column identity, object type, loaded column count, loaded table preview, and column type today. PK/FK/null/default/row-count details must be shown only when already present in cached payloads later; Phase 12.1 must not invent or synchronously fetch them.

## Standard Stack

- **Protocol:** LSP 3.17 request/response shapes for `textDocument/hover` and `completionItem/resolve`.
- **Server:** Existing in-process Lua LSP server in `lua/dbee/lsp/server.lua`.
- **Client targets:** Neovim built-in LSP, `nvim-cmp` via standard LSP completion, and `blink.cmp` via standard LSP completion.
- **Metadata source:** Existing `SchemaCache`; no new persistent metadata store.
- **Authority source:** `lua/dbee/schema_filter_authority.lua`.
- **Schema/table name source:** `lua/dbee/schema_name_canonical.lua` through existing `SchemaCache` lookup methods.
- **Tests/perf:** Existing headless `make perf-lsp` path and `ci/headless/check_lsp_perf.lua`.

## 1. LSP Protocol Contracts

### `textDocument/hover`

Contract:

```ts
method: "textDocument/hover"
params: TextDocumentPositionParams
result: Hover | null

interface Hover {
  contents: MarkedString | MarkedString[] | MarkupContent
  range?: Range
}

interface MarkupContent {
  kind: "plaintext" | "markdown"
  value: string
}
```

Implementation guidance:

- Return `null` for keywords, whitespace, unknown identifiers, authority failure, and cache misses where a minimal truthful hover would be misleading.
- Use `MarkupContent` instead of legacy `MarkedString`.
- Prefer `kind = "markdown"` when the client advertises markdown support; fall back to `kind = "plaintext"` when it does not.
- Include `range` for the token under the cursor. This lets clients highlight the exact schema/table/column token rather than the whole statement.
- Do not issue DB work from the hover request path.

### `completionItem/resolve`

Contract:

```ts
method: "completionItem/resolve"
params: CompletionItem
result: CompletionItem
```

Implementation guidance:

- Advertise `completionProvider.resolveProvider = true` only after the handler exists.
- Resolve only dbee object completions that carry a compact `data` payload.
- Return non-dbee, keyword, malformed, stale, or unresolved items unchanged.
- Add documentation/detail fields without changing item identity or insertion behavior. Treat `label`, `sortText`, `filterText`, `insertText`, and `textEdit` as stable after completion.
- Use `CompletionItem.data` as the opaque identity bridge from completion to resolve. The LSP contract preserves `data` between the original completion response and the later resolve request.

### Resolve Trigger Semantics

Clients call `completionItem/resolve` after receiving a completion item, usually when the item is selected or documentation is requested in the completion menu. This makes resolve appropriate for formatting additional documentation, but not for long-running metadata fetches. The response is still a single request/response, not a streaming result.

### Hover Range Semantics

The hover `range` should cover only the identifier component under the cursor:

- Schema token for schema hover.
- Table token for table hover.
- Column token for column hover.

For qualified identifiers, the range should not include dots or sibling components unless the hover content describes the full object and the cursor is on ambiguous punctuation. Planning should prefer token-specific ranges because they are easier to test.

### Markdown vs Plain Text In Neovim, nvim-cmp, blink.cmp

- Neovim's built-in hover path renders LSP hover contents through its floating preview utilities and supports markdown content.
- `nvim-cmp` and `blink.cmp` consume standard LSP completion fields. They do not need a dbee-specific protocol if `documentation` is a normal LSP `MarkupContent`.
- Store client markdown support from `initialize` capabilities:
  - Hover: `textDocument.hover.contentFormat`.
  - Resolve/completion docs: `textDocument.completion.completionItem.documentationFormat`.
- Default to markdown when capabilities are absent because current Neovim clients handle it; use plaintext if the client explicitly lists only plaintext.

## 2. Existing Code Touchpoints

### `lua/dbee/lsp/server.lua`

Current state:

- `M.create(cache)` returns the in-process LSP RPC server.
- `initialize` advertises:
  - `completionProvider.triggerCharacters = { ".", " " }`
  - `completionProvider.resolveProvider = false`
  - full sync text document support
- Request handler currently handles:
  - `initialize`
  - `shutdown`
  - `textDocument/completion`
  - diagnostics notifications through `didSave`/`didChange`
- All unknown requests currently return `nil`.

Phase 12.1 touchpoints:

- Capture initialize client capabilities needed for markdown/plaintext selection.
- Advertise `hoverProvider = true`.
- Switch `completionProvider.resolveProvider` to `true` only after `completionItem/resolve` is implemented.
- Add request branches for:
  - `textDocument/hover`
  - `completionItem/resolve`
- Add shared object-doc formatter helpers near the server or in a small LSP-local helper module.

### Existing Completion Code Path

Completion items are produced in:

- `table_completion_item(schema, name, table_type)` in `schema_cache.lua`.
- Inline schema completion construction in `_rebuild_structure_indexes()` / `_upsert_table_index()`.
- Column completion construction in `_update_column_index()`.
- Additional all-column fallback in `server.lua:all_column_completions()`.
- Keyword completion in `server.lua:keyword_completions()`.

Current completion items do not carry `data`. Phase 12.1 should add compact dbee `data` only to schema/table/column object completions. Keyword items should remain unresolved.

### `lua/dbee/lsp/schema_cache.lua`

Current relevant surface:

- Imports both `schema_filter_authority` and `schema_name_canonical`.
- Constructor reads schema-filter authority and fail-closes when unavailable.
- Cache state:
  - `schemas`
  - `tables`
  - `columns`
  - schema/table/column completion indexes
  - async column state
  - 500-table in-memory column LRU (`MAX_COLUMNS_IN_MEMORY = 500`)
- Lookup helpers:
  - `find_schema(schema, { quoted })`
  - `find_table_in_schema(schema, table, { schema_quoted, table_quoted })`
  - `find_table(table, { table_quoted })`
  - `schema_status(schema, opts)`
  - `get_column_completion_items(schema, table, opts)`
  - `get_columns_async(schema, table, opts)`
  - `get_cached_columns()`

Phase 12.1 touchpoints:

- Add cache methods that return metadata snapshots without triggering DB work:
  - schema summary by name/quoted state
  - table summary by schema/table/quoted state
  - column summary by schema/table/column/quoted state
- Add a cache generation/root-epoch accessor for stale resolve detection if no equivalent already exists.
- Add object completion `data` at the completion item construction sites.
- Keep all lookup paths routed through existing canonical-aware `find_*` methods.

### `lua/dbee/lsp/context.lua`

Current relevant surface:

- `parse_identifier(raw)` preserves `{ name, quoted }`.
- `split_identifier_ref(ref)` handles quoted dot-separated refs.
- `parse_table_ref(ref)` returns `{ schema, schema_quoted, table, table_quoted }`.
- `parse_aliases()` carries table/schema quote metadata.
- `analyze(params)` drives completion context.

Phase 12.1 touchpoints:

- Add a token-at-position helper for hover:
  - returns `{ raw, name, quoted, range, kind_hint? }`
  - must work for quoted identifiers and unquoted identifiers
  - must return nil on keywords/whitespace/punctuation-only positions
- Add a nearby object resolver for hover:
  - schema token in table context
  - table token in FROM/JOIN/UPDATE/INTO contexts
  - column token in `alias.column` / `schema.table.column` where detectable
  - alias resolution should reuse current statement-scoped alias parser
- Preserve quoted metadata all the way into schema cache lookups.

### `lua/dbee/lsp/init.lua`

Current relevant surface:

- Owns active singleton LSP state:
  - `M._client_id`
  - `M._cache`
  - `M._conn_id`
- Starts the in-process server with `server.create(cache)`.
- Handles structure refresh and schema-list refresh.
- Handles async column-loaded notifications and completion refresh nudges for completion clients.
- Uses `schema_filter_authority` and `schema_name_canonical`.

Phase 12.1 touchpoints:

- No lifecycle redesign should be needed.
- Cache invalidation already flows through this module; resolve cache invalidation should piggyback on schema cache generation/root epoch changes rather than adding parallel lifecycle state here.
- If resolve cache is server-local, it must be cleared when the server terminates and made stale-safe with cache generation checks.

## 3. Schema-Filter Authority Integration

Phase 14 invariant: new metadata consumers must route through `schema_filter_authority.read(handler, conn_id)`.

Hover and resolve must perform a fresh authority check before returning metadata:

- `authority_unavailable`: return `nil` hover or original completion item unchanged. Do not leak cached schema/table/column docs.
- `api_absent_legacy`: preserve legacy behavior with implicit all-schema scope.
- `ok`: use `authority.scope` to enforce current filter truth.

Recommended implementation shape:

- Add a small `SchemaCache` method such as `read_lsp_authority()` that calls `schema_filter_authority.read(self.handler, self.conn_id)` and returns status/scope. This keeps `server.lua` from reaching into cache internals while still using the helper on each request.
- Add a cache-side helper such as `schema_in_current_authority_scope(schema)` that checks a fresh authority scope. This avoids using a stale `self.schema_scope` if the filter changes before refresh events finish.
- Hover/resolve should fail closed before formatting metadata if the schema is out of scope or authority is unavailable.

Do not rely only on the fact that `SchemaCache` fail-closes during construction. Phase 14 found that warm caches can outlive authority changes; Phase 12.1 should not reintroduce that class on a new read surface.

## 4. Schema-Name Canonical Integration

Phase 11 r6 invariant: schema/table lookup must not add local string-folding logic.

Implementation guidance:

- Context parsing supplies quoted state.
- Server hover/resolve passes quoted state into cache lookup methods.
- Cache lookup methods continue to use `schema_name_canonical` internally.
- New helpers must not use local `:lower()`, `:upper()`, hard-coded `"upper"`, or local `_fold` logic for schema/table identity.

Hover examples:

- Postgres unquoted `Public.users` should resolve through canonical lowercase lookup.
- Postgres quoted `"Public".users` should resolve exact schema `Public`.
- Oracle unquoted `users` should resolve through canonical uppercase lookup.
- ClickHouse should resolve exact names only.
- SQLite/default case-insensitive behavior can use canonical lower-fold semantics.

## 5. Caching Strategy

### Hover

Locked policy: hover is cache-only.

- No DB RPC.
- No async miss scheduling from hover.
- No persistent hover-specific storage.
- Formatting work should be bounded and cheap.
- Schema hover table preview must be truncated. Plan should choose the cutoff; recommendation: first 20 tables with `+N more`.

### Resolve

Locked policy: resolve is cache-truthful and bounded.

- Resolve uses item `data` to look up existing cache metadata.
- If cache data is present, add `detail` and `documentation`.
- If cache data is missing/stale/filtered/unavailable, return the item unchanged or with only already-truthful minimal details.
- Do not block for DB metadata.

Important challenge-up: the prompt suggestion "mark item incomplete" does not map cleanly to LSP `completionItem/resolve`. `isIncomplete` belongs to `CompletionList`, not `CompletionItem`. Keep incomplete signaling in `textDocument/completion`; resolve should return a single item.

Recommended resolve memoization:

- Memoize formatted docs per server session only if profiling shows formatting cost worth caching.
- Key by a stable identity:
  - `source = "dbee"`
  - `version = 1`
  - `kind = "schema" | "table" | "column"`
  - `schema`, `table`, `column`
  - quoted flags
  - connection/cache id
  - cache generation/root epoch
- If item generation does not match current cache generation, return original item unchanged and do not reuse stale docs.

### Cache Invalidation

Use existing cache invalidation flows:

- structure refresh
- schema-list refresh
- schema-object loaded
- column-loaded event
- filter change
- connection switch
- active cache invalidation

Planning should add or identify a lightweight cache generation accessor. Generation should bump on every metadata mutation that can affect docs:

- `build_from_structure`
- `build_from_schemas`
- `on_schema_objects_loaded`
- `on_columns_loaded`
- `invalidate`
- filter-scope refresh that changes visible objects

Do not add cross-session resolve persistence.

## 6. Performance Requirements

Budgets from `.planning/DISCUSS-phase12.md`:

- Hover P95 <50ms.
- Resolve P95 <100ms.
- No synchronous DB metadata calls on LSP request paths.
- No new persistent storage beyond existing schema/column cache.
- Reuse 500-table in-memory column LRU from Phase 11.

Expected performance profile:

- Hover should usually be sub-millisecond for direct cache hits.
- Schema hover over large schemas can become expensive if it formats too many table names. Truncate previews and avoid sorting on the request path when indexes already exist.
- Resolve formatting can be memoized if markdown generation becomes measurable, but do not prebuild docs eagerly during completion.
- Completion item `data` increases completion payload size. Keep it compact.

Perf harness work:

- Extend `ci/headless/check_lsp_perf.lua` with hover and resolve scenarios.
- Include warm cache and cold-but-no-fetch miss cases.
- Emit grep-friendly `LSP12_*` perf markers.
- Keep thresholds advisory initially, consistent with Phase 12 D-333.

## 7. Markdown Rendering Tradeoffs

Locked default: `MarkupContent` markdown with plaintext fallback.

Markdown advantages:

- Clear object headings.
- Code spans for schema/table/column names.
- Small bullet lists for metadata fields.
- Fenced SQL examples later if Phase 12.1 chooses to include examples for resolve.

Markdown costs:

- Slightly larger payloads.
- Client render cost, especially for long column lists.
- Table markdown can be noisy in floating windows.

Recommendation:

- Avoid markdown tables for large column lists.
- Use compact bullets and code spans.
- Truncate schema/table previews.
- Keep generated docs stable for snapshot tests.

Recommended markdown shapes:

Schema:

```markdown
### schema_name

Schema

- Tables loaded: 12
- Preview: `users`, `orders`, `order_items`, ...
```

Table:

```markdown
### public.users

Table

- Columns loaded: 8
- Columns: `id`, `email`, `created_at`, ...
```

Column:

```markdown
### public.users.email

Column

- Type: `text`
```

Only include nullable/default/PK/FK fields when they are actually cached.

## 8. Resolve Item Identification

Current completion items do not carry `data`; Phase 12.1 should add it for object items.

Recommended `data` payload:

```lua
{
  source = "dbee",
  version = 1,
  kind = "schema" | "table" | "column",
  schema = "...",
  table = "...",
  column = "...",
  schema_quoted = true | false,
  table_quoted = true | false,
  column_quoted = true | false,
  conn_id = "...",
  cache_generation = 123,
  root_epoch = 456,
}
```

Notes:

- Do not include connection URLs, usernames, passwords, SQL queries, source config, or display connection names.
- `conn_id` is acceptable only if it is already an internal opaque id; otherwise use a cache identity token.
- Keep `data` versioned so future rich metadata can evolve without ambiguity.
- All object completion constructors should use one helper to create data so schema/table/column payloads stay consistent.

Resolve behavior by item:

- `source ~= "dbee"`: return original.
- missing/invalid data: return original.
- stale generation/root epoch: return original.
- authority unavailable: return original.
- object out of current scope: return original.
- cache hit: add docs/detail and return enriched item.

## 9. Adapter Capability Surface

Discussion decision D-329 allows an additive LSP capability surface, but Phase 12.1 does not need a Go adapter redesign.

Recommendation:

- Default `lsp.hover = true` and `lsp.resolve = true` for all adapters because every adapter with schema cache support can expose at least object name/type.
- Treat rich fields as field-level capability, not feature-level capability:
  - if column `type` exists, show type
  - if PK/FK/default/nullability later exist, show them
  - if not, omit
- Add a Lua-side capability helper only if planning finds an existing config/capability table to extend cleanly.
- Do not block Phase 12.1 on per-adapter Go capability declarations.

Adapter degradation:

- Missing rich metadata -> name/type-only docs.
- Missing column cache -> table docs omit column preview or say only loaded column count if known.
- Authority unavailable -> no docs.
- Legacy handler without authority API -> legacy implicit all behavior.

## 10. Test Coverage

Add a focused headless test file, recommendation:

- `ci/headless/check_lsp12_hover_resolve.lua`

Required sentinel markers:

- `LSP12_HOVER_TABLE_OK=true`
- `LSP12_HOVER_COLUMN_OK=true`
- `LSP12_HOVER_SCHEMA_OK=true`
- `LSP12_RESOLVE_TABLE_DOCS_OK=true`
- `LSP12_HOVER_AUTHORITY_FAIL_CLOSED=true`
- `LSP12_HOVER_CANONICAL_LOOKUP_OK=true`

Recommended additional markers:

- `LSP12_RESOLVE_COLUMN_DOCS_OK=true`
- `LSP12_RESOLVE_SCHEMA_DOCS_OK=true`
- `LSP12_RESOLVE_UNKNOWN_ITEM_PASSTHROUGH=true`
- `LSP12_RESOLVE_STALE_CACHE_SAFE=true`
- `LSP12_HOVER_KEYWORD_NIL_OK=true`
- `LSP12_HOVER_UNKNOWN_NIL_OK=true`
- `LSP12_HOVER_QUOTED_IDENTIFIER_OK=true`
- `LSP12_HOVER_NO_SYNC_DB_WORK=true`
- `LSP12_RESOLVE_NO_SYNC_DB_WORK=true`
- `LSP12_HOVER_RESOLVE_ALL_PASS=true`

Test cases:

- Simulate `initialize`; assert `hoverProvider=true` and `resolveProvider=true`.
- Simulate hover over:
  - schema token
  - table token
  - column token
  - SQL keyword
  - unknown identifier
  - quoted mixed-case schema/table
- Simulate resolve for:
  - table completion item with valid data
  - schema completion item with valid data
  - column completion item with valid data
  - keyword completion item with no data
  - non-dbee item
  - stale generation item
- Authority fail-closed test:
  - warm cache with metadata
  - make authority return nil/error
  - hover/resolve must not return cached object metadata
- Canonical lookup test:
  - Postgres-style unquoted mixed-case lookup uses canonical path
  - quoted identifier uses exact path
- No sync DB work test:
  - instrument handler sync metadata functions
  - hover/resolve request count remains zero

Perf coverage:

- Extend `ci/headless/check_lsp_perf.lua`.
- Add measured scenarios:
  - hover table hit
  - hover column hit
  - hover unknown miss
  - resolve table hit
  - resolve column hit
  - resolve stale item passthrough
- Emit P50/P95 markers and advisory pass markers.

Rollup:

- Wire new `LSP12_*` markers into the existing `perf-lsp` combined log.
- Add a strict rollup marker such as `LSP12_HOVER_RESOLVE_ALL_PASS=true`.
- Include the new marker in the same rollup path used by UX13/LSP11 unless planning chooses to add a dedicated Phase 12 rollup.

## 11. Risks

### Hover On Keyword

Risk: parser classifies SQL keywords as identifiers.

Mitigation:

- Token helper checks keyword set and returns nil.
- Sentinel: `LSP12_HOVER_KEYWORD_NIL_OK`.

### Hover On Unknown Identifier

Risk: hover returns a misleading name-only object.

Mitigation:

- Only return hover if cache lookup resolves an object.
- Unknown token returns nil.

### Resolve Called For Non-LSP-Managed Item

Risk: external client/plugin sends arbitrary completion item.

Mitigation:

- Require `data.source == "dbee"` and `data.version == 1`.
- Otherwise return original item unchanged.

### Cache Invalidated Between Completion And Resolve

Risk: resolve formats stale metadata for an item selected from an old completion popup.

Mitigation:

- Include cache generation/root epoch in data.
- Compare against current cache before resolving.
- Return original item unchanged on mismatch.

### Authority Changes While Cache Is Warm

Risk: hover/resolve leaks metadata after schema-filter authority becomes unavailable.

Mitigation:

- Read `schema_filter_authority` fresh from hover/resolve.
- Fail closed on `authority_unavailable`.
- Check object scope against fresh authority scope.

### Quoted Identifier Regressions

Risk: new hover token parsing loses quoted metadata and reintroduces case-fold bugs.

Mitigation:

- Reuse/extend `context.parse_identifier` style.
- Pass quoted flags into existing cache lookups.
- Add quoted and canonical hover sentinels.

### Markdown Payload Size

Risk: huge schema/table docs degrade hover/resolve UX.

Mitigation:

- Truncate previews.
- Avoid full column dumps by default for very wide tables.
- Keep response formatting bounded.

## 12. References

Primary references for planning:

- Microsoft LSP 3.17 specification: `https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/`
- Hover protocol source: `https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_specifications/lsp/3.17/language/hover.md`
- Neovim LSP docs: `https://neovim.io/doc/user/lsp.html`
- nvim-cmp docs: `https://github.com/hrsh7th/nvim-cmp/blob/main/doc/cmp.txt`
- blink.cmp LSP docs: `https://cmp.saghen.dev/development/lsp-tracker`
- Phase 12 discussion: `.planning/DISCUSS-phase12.md`
- Phase 11 cache/canonical precedent: `ci/headless/check_lsp_schema_cache_optimization.lua`
- Phase 14 authority precedent: `lua/dbee/schema_filter_authority.lua`

## Architecture Patterns

Use this pattern for both hover and resolve:

1. Identify the object from cursor token or completion item data.
2. Read schema-filter authority fresh.
3. Fail closed if authority is unavailable.
4. Resolve schema/table names through canonical-aware cache methods using quoted metadata.
5. Verify object is in current scope.
6. Read existing cache metadata only.
7. Format markdown or plaintext from a shared formatter.
8. Return nil/original item on any uncertain condition.

This keeps Phase 12.1 read-only, cache-backed, and consistent with the two single-source helpers already created for Phase 14 and Phase 11 r6.

## Do Not Hand-Roll

- Do not add a full SQL parser for hover.
- Do not add local schema/table lower/upper folding.
- Do not bypass `schema_filter_authority`.
- Do not call sync metadata RPCs from hover/resolve.
- Do not add client-specific cmp APIs.
- Do not persist resolve docs across sessions.
- Do not synthesize PK/FK/default/nullability/row-count fields when not cached.

## Common Pitfalls

- Advertising `resolveProvider=true` before handler support.
- Returning markdown strings directly instead of proper `MarkupContent`.
- Forgetting hover `range`, making client highlighting sloppy.
- Adding completion item `data` to keywords and then trying to resolve them.
- Losing quoted flags when parsing hover tokens.
- Reusing stale `self.schema_scope` instead of checking fresh authority.
- Resolving stale completion items after cache generation changes.
- Accidentally scheduling async DB work in resolve and racing the response.
- Over-formatting schema/table docs and missing the 50ms hover budget.

## Locked Decisions

- Hover supports schema/table/column objects only; keyword hover returns nil.
- Hover and resolve are cache-backed and do not run DB metadata work.
- Markdown `MarkupContent` is the default; plaintext is a capability fallback.
- Resolve enriches only dbee object items with valid compact `data`.
- Resolve returns the original item unchanged for misses, stale data, authority failure, and non-dbee items.
- Completion item `data` is versioned and contains only object identity/cache identity, not sensitive connection details.
- Existing completion behavior remains unchanged except for additive `data` and later resolve docs.
- Phase 12.1 should add no new persistent storage.
- PK/FK/null/default/row-count are optional future fields, not Phase 12.1 guarantees.

## Surfaced Design Forks

### Resolve Async Fetch vs Cache-Truthful Resolve

The user brief allowed "fetch async with debounce; mark item incomplete." LSP resolve does not have `isIncomplete`, and using resolve to start metadata work risks bringing DB timing back onto a request path. Locked recommendation: resolve is cache-truthful and returns immediately. Existing completion async warm paths remain responsible for loading missing columns.

### Rich Metadata Now vs Future Enrichment

Some adapter SQL files mention constraint/nullability-oriented metadata, but the current shared `core.Column` contract only carries `name` and `type`. Locked recommendation: design formatter keys for future rich fields, but show only fields present in cache today.

### Server Formatter Location

Two viable placements:

- Keep formatter functions in `server.lua` for minimal file churn.
- Add `lua/dbee/lsp/object_docs.lua` for shared hover/resolve formatting and future Phase 12.2/12.3 reuse.

Recommendation: add a small `object_docs.lua` if the implementation exceeds a few local helper functions. This is not a new architecture; it is a shared formatter for Phase 12 LSP surfaces.

### Authority Check Location

Two viable placements:

- Server calls `schema_filter_authority.read()` directly.
- Cache exposes `read_lsp_authority()` / `object_in_current_scope()` wrappers.

Recommendation: cache wrapper. It avoids exposing handler/conn internals to `server.lua` while still calling the Phase 14 helper fresh on each request.

## Recommended Phase 12.1 Task Breakdown

1. **Protocol capability wiring**
   - Capture client markdown/plaintext support during initialize.
   - Advertise `hoverProvider=true`.
   - Keep `resolveProvider=false` until resolve branch is implemented, then flip to `true`.

2. **Completion item data model**
   - Add one helper for dbee object item `data`.
   - Route schema/table/column completion constructors through it.
   - Keep keyword items unchanged.

3. **Cache metadata snapshot helpers**
   - Add cache-only schema/table/column summary lookups.
   - Add/currently identify cache generation/root epoch accessor.
   - Add fresh authority/scope check wrapper.

4. **Shared docs formatter**
   - Build markdown/plaintext object docs from schema/table/column summaries.
   - Truncate previews.
   - Omit absent rich fields.

5. **Hover token resolver and handler**
   - Add quote-aware token-at-position helper in context.
   - Resolve object kind and lookup metadata.
   - Return `Hover | nil` with token range.

6. **Completion item resolve handler**
   - Validate dbee data.
   - Check authority/scope and cache generation.
   - Enrich docs/detail from cache.
   - Return original unchanged on all unsafe paths.

7. **Headless tests and sentinels**
   - Add `check_lsp12_hover_resolve.lua`.
   - Add required and recommended markers.
   - Wire into `make perf-lsp` and rollup.

8. **Perf probes**
   - Extend `check_lsp_perf.lua`.
   - Emit hover/resolve P95 markers.
   - Keep thresholds advisory in this phase.

## Dependencies

- Phase 14 authority helper must remain unchanged and used by new metadata paths.
- Phase 11 r6 canonical helper must remain unchanged and used by new lookup paths.
- Existing schema cache must remain the only metadata source for request handlers.
- `make perf-lsp` remains the validation path.
- No dependency on rich metadata phase for MVP.

## Ready-For-Plan Checklist

- [x] Phase 12.1 scope confirmed from `.planning/DISCUSS-phase12.md`.
- [x] LSP hover and resolve protocol shapes identified.
- [x] Existing LSP server entry point identified.
- [x] Completion item production sites identified.
- [x] Current metadata payload limits identified.
- [x] Authority and canonical helper integration points identified.
- [x] Cache-only/no-sync request-path decision locked.
- [x] Resolve async-fetch fork resolved conservatively.
- [x] Required sentinels named.
- [x] Perf harness extension path identified.

## Open Questions For Plan-Phase

- Exact schema/table preview truncation limit. Recommendation: 20 names.
- Whether to add `object_docs.lua` or keep helpers local to `server.lua`. Recommendation: add file if formatter is shared by both hover and resolve.
- Exact cache generation field name and bump points. Recommendation: one monotonic `metadata_generation`.
- Whether `conn_id` is acceptable in completion item `data` or should be replaced with an opaque cache identity token. Recommendation: use an opaque cache identity token if easy; otherwise use existing internal `conn_id` and never include connection params.

---

**Ready for:** `$gsd-plan-phase 12.1`
