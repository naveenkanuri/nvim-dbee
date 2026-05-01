# Phase 14 Research: Enterprise DB UX Architecture

Status: Research only - no D-224+ locks  
Phase: 14 - Enterprise DB UX Architecture  
Requirement: DBEE-ARCH-01  
Codex session: 019ddb0e-e8d0-7ca1-a4b0-8d4728863630

## Executive Recommendation

Ship schema allowlist and lazy-loading deepening together in Phase 14, implemented in staged waves. They touch the same connection metadata, handler transport, drawer cache, LSP schema cache, disk cache, and invalidation surfaces. Splitting them would duplicate migration work and still leave one half of the enterprise-DB problem unsolved: allowlist alone reduces noise but can still block on eager table fetch; lazy loading alone improves startup but still floods drawer/completion with system schemas.

Recommended lazy-loading architecture: hybrid **Option A + Option D**.

| Option | Summary | Recommendation |
| --- | --- | --- |
| A | Schemas-only initial fetch; tables/views/procs/functions load per schema on expand or LSP demand. | Use as the structural baseline. It directly removes the full schema+table startup blocker. |
| B | Schemas plus first-N tables per schema; rest on demand. | Reject. It creates misleading partial lists and complicates completion correctness, counts, and filter/search semantics. |
| C | Parallel per-schema RPCs; wall-clock approaches slowest schema RPC. | Use only as an optional background-prefetch implementation detail. It still starts many RPCs and can overload large shared DBs if used as the initial UX. |
| D | Background prefetch while user can interact with cache-as-it-grows. | Use as a bounded enhancer for active/allowlisted schemas, lower priority than explicit drawer expansion and LSP `schema.` misses. |

Recommended schema-filter syntax: connection-local `schema_filter` with exact names and simple glob patterns, initially `*` wildcard with prefix-glob support as the mandatory subset. Do not add regex in v1.3. Treat missing `schema_filter` as all schemas for backwards compatibility. Empty array semantics should be locked in discuss; this research recommends normalizing empty array to absent/all-schemas or disallowing save to avoid a useless no-schema connection.

Recommended LSP contract: `schema.` completion remains cache/async-only. Cache hits return full table items with `isIncomplete=false`; first table-list miss starts a deduped async table-list warmup and returns `isIncomplete=true`; if no async surface is available, return cache-only with `isIncomplete=false` rather than doing a synchronous metadata RPC.

Recommended cache strategy: add a new partial schema index shape, likely disk `version = 3`, with per-schema table-list population state and a schema-filter signature. Preserve Phase 13 v2 migration handling and Phase 11 disk-safety guards.

## Inputs And Local Constraints

Phase 14 is already scoped in the v1.3 roadmap as per-connection schema allowlists plus schemas-only initial structure loading, with per-schema lazy table fetch and shared honoring by drawer, LSP completion, diagnostics, schema cache, and disk cache (`.planning/milestones/v1.3-roadmap.md:97`). DBEE-ARCH-01 states the same user-visible requirement (`.planning/REQUIREMENTS.md:96`).

The known issue is not speculative: Phase 6 made columns lazy, but schemas and tables still load eagerly in one structure RPC; the backlog calls out huge Oracle/Postgres DBs where 10000+ tables can leave the drawer stuck on `loading...` for minutes (`known-issues.md:72`).

Prior contracts that Phase 14 must preserve:

- Phase 6 D-31: `connection_get_structure_async(conn_id, request_id)` -> `structure_loaded{...structures}` remains a full-tree contract. Phase 14 may add schema/table-specific helpers/events, but must not repurpose the existing event (`.planning/phases/06-structure-laziness-notes-picker/06-CONTEXT.md:22`).
- Phase 6 D-38: drawer filter typing is zero-RPC and uses authoritative cached structure only (`.planning/phases/06-structure-laziness-notes-picker/06-CONTEXT.md:29`).
- Phase 6 D-46: child fetches carry `root_epoch`; stale child payloads are dropped silently, and the single-bump rule remains intact (`.planning/phases/06-structure-laziness-notes-picker/06-CONTEXT.md:31`).
- Phase 7 D-77/D-78/D-84/D-87: root coordination stays handler-owned single-flight, with authoritative root epoch, backpressure, and waiter cleanup (`.planning/phases/07-connection-only-drawer/07-CONTEXT.md:52`).
- Phase 11 D-154..D-161: LSP metadata misses use async transport, do not fake `isIncomplete`, dedupe by connection/schema/table/materialization/root_epoch, and never fall back to sync if async transport is absent (`.planning/phases/11-lsp-optimization-correctness/11-CONTEXT.md:41`).

## Current State

The Go core builds full schema -> object trees today. `GetGenericStructure` consumes rows with schema/table/type columns and returns schema nodes whose `Children` already contain all objects (`dbee/core/types.go:98`). Postgres `Structure()` executes a full `information_schema.tables UNION pg_matviews` query and feeds the complete row stream into that helper (`dbee/adapters/postgres_driver.go:52`). Oracle does the same shape over `all_tables`, `all_external_tables`, `all_views`, `all_mviews`, and procedures/functions, ordered by owner and object name (`dbee/adapters/oracle_driver.go:385`).

The Lua handler exposes full structure sync/async wrappers and one child async surface for columns. There is no schema-only or table-list-by-schema wrapper yet (`lua/dbee/handler/init.lua:1430`, `lua/dbee/handler/init.lua:1442`, `lua/dbee/handler/init.lua:1467`).

The drawer root cache is typed as full root structures plus branch state (`lua/dbee/ui/drawer/init.lua:49`). Connection expansion currently requests full structure if there is no cached root, shows a connection-level loading row, then materializes schema/table children from the full root payload (`lua/dbee/ui/drawer/init.lua:907`). Table-like rows are already lazy at the column level through `connection_get_columns_async`, with a row-local loading node (`lua/dbee/ui/drawer/init.lua:965`).

`structure_children_loaded` currently carries `columns`, even though it has a `kind` field. That makes it an attractive additive event for schema-object children only if Phase 14 either generalizes the payload safely or adds a parallel event rather than overloading column semantics ambiguously (`dbee/handler/event_bus.go:131`, `lua/dbee/ui/drawer/init.lua:1907`).

The LSP schema cache is full-tree-indexed. `build_from_structure()` resets schema/table/column indexes and flattens the supplied full structure tree; comments explicitly say it never calls `connection_get_structure()` itself (`lua/dbee/lsp/schema_cache.lua:222`). Disk schema cache is currently `SCHEMA_CACHE_VERSION = 2`, with `schemas` and `tables` and Phase 13 migration/corruption handling (`lua/dbee/lsp/schema_cache.lua:28`, `lua/dbee/lsp/schema_cache.lua:745`).

LSP completion already has a `CompletionList` wrapper and `isIncomplete` field (`lua/dbee/lsp/server.lua:23`). The request path forbids synchronous column misses (`lua/dbee/lsp/server.lua:424`). Diagnostics currently warn for missing schema-qualified or unqualified table references by consulting the cache, so Phase 14 must decide how cache scope and filtered-out schemas affect "unknown table" semantics (`lua/dbee/lsp/server.lua:264`).

FileSource can persist additive metadata in raw JSON records, but runtime `ConnectionParams` loading currently strips records down to id/name/type/url (`lua/dbee/sources.lua:162`). Wizard metadata is persisted only for FileSource and only under `wizard` today (`lua/dbee/handler/init.lua:1321`). Phase 14 must decide whether `schema_filter` is runtime `ConnectionParams` metadata, raw source metadata, or both; downstream consumers need access at runtime, so this research recommends adding it to `ConnectionParams` and source loading, not burying it only in `wizard`.

## Ecosystem Comparison

| Tool | Observed pattern | Implication for Phase 14 |
| --- | --- | --- |
| DBeaver | Object filters can include/exclude database objects using masks/patterns in the navigator/filter UI. Docs describe object filtering as a way to limit displayed database objects. Source: https://dbeaver.com/docs/dbeaver/Filter-Database-Objects/ and https://dbeaver.com/docs/team-edition/desktop/Configure-Filters/ | Schema allowlist should be persisted per connection/source and should support simple pattern syntax, not require SQL users to hand-edit every query context. |
| DataGrip / IntelliJ DB tools | JetBrains database tooling has explicit schema/database visibility and introspection scope. JetBrains describes that non-introspected schemas are not available for completion/resolution until selected/introspected. Source: https://www.jetbrains.com/help/datagrip/introspection.html and https://blog.jetbrains.com/datagrip/2022/08/08/not-all-databases-schemas-are-displayed-by-default-why/ | Treat active schemas as the metadata universe for completion and resolution; do not eagerly introspect everything by default on enterprise connections. |
| LSP specification | `CompletionList.isIncomplete` means the completion list is incomplete and further typing should retrigger completion. Source: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#completionList | Use `isIncomplete=true` only when a schema table-list warmup is actually in flight. This matches Phase 11's column miss discipline. |
| vim-dadbod / vim-dadbod-completion | `vim-dadbod` is query-command oriented, and `vim-dadbod-completion` provides completion using dadbod metadata, but the public README does not expose a DBeaver-style active-schema wizard or drawer-scoped progressive metadata model. Sources: https://github.com/tpope/vim-dadbod and https://github.com/kristijanhusak/vim-dadbod-completion | nvim-dbee can differentiate by making schema scope first-class in the drawer and LSP surfaces instead of a buffer/manual workflow only. |
| sqls / sql-language-server | sqls config is connection-centric and LSP-centric. It supports completion/hover/diagnostics against configured DB connections, but not a Neovim drawer UX or connection-wizard schema allowlist. Source: https://github.com/sqls-server/sqls | Keep schema scope in dbee's connection metadata and cache, then feed the LSP from the same source of truth. Do not fork LSP-only config. |

Confidence: high for DBeaver/DataGrip/LSP patterns based on official docs; medium for vim-dadbod/sqls negative claims because they are README-level checks rather than exhaustive code archaeology.

## Lazy-Loading Architecture Options

### Option A: Schemas-Only Initial Fetch

Initial connection bootstrap fetches schema rows only. Drawer renders schema rows collapsed by default. Expanding a schema triggers an async request for that schema's tables/views/procedures/functions. Columns remain table-row lazy as in Phase 6.

Benefits:

- Directly fixes the observed startup blocker: initial RPC cost scales with schema count, not table count.
- Aligns with active-schema allowlist: apply allowlist before table fetch, so unneeded schemas never allocate table cache.
- Keeps drawer UX honest: collapsed schema means object list unknown; row-local loading means only that schema is busy.
- Fits LSP `schema.` cold-miss behavior through async warm + `isIncomplete`.

Costs:

- Requires new backend APIs for schema list and schema-object list.
- Requires partial-population state in drawer and schema cache.
- Search/filter cannot find unloaded table rows without violating Phase 6 D-38. This must be a documented UX tradeoff, not a hidden RPC.

### Option B: Schemas + First-N Tables Per Schema

Initial bootstrap fetches all schemas plus a bounded prefix of object rows per schema.

Benefits:

- Gives users some immediate table rows under every schema.
- Can seed completion with popular/alphabetical rows.

Costs:

- Partial lists look authoritative unless every UI marks them incomplete.
- Completion correctness becomes difficult: users can see no result even though the table exists past the first N.
- Filter/search can produce false negatives without every query carrying "partial" semantics.
- It does not solve noisy enterprise DBs without allowlist; it spreads a small amount of noise across many schemas.

Recommendation: reject for Phase 14.

### Option C: Parallel Per-Schema RPCs

Initial bootstrap fetches schema list, then starts one RPC per schema in parallel. Wall-clock approaches the slowest schema rather than the sum.

Benefits:

- Useful as a background prefetch engine for allowed schemas.
- Can exploit independent database metadata queries for selected schemas.

Costs:

- Dangerous as default startup behavior against large shared DBs: 100+ schemas could mean 100+ concurrent metadata queries.
- Needs concurrency limits, cancellation, and priority to avoid making drawer expansion compete with background work.
- Still does unnecessary work when the user only cares about 1-5 schemas.

Recommendation: use as a bounded implementation detail inside Option D, never as the primary initial loading contract.

### Option D: Background Prefetch With Progressive Cache

After schemas load and allowlist is applied, background workers prefetch active schemas in priority order while UI remains usable.

Benefits:

- Gives small/medium DBs near-current behavior after a short warmup.
- Lets LSP completion become cache-hit-heavy after the first interaction.
- Prioritization can favor current drawer expansion, current SQL buffer schema prefixes, and recently used schemas.

Costs:

- Needs strict generation fences and per-schema dedupe.
- Needs advisory perf coverage so prefetch does not regress startup or LSP latency.
- Requires a clear policy for max concurrent metadata RPCs.

Recommendation: pair with Option A. Default to explicit demand first; background prefetch second.

## Handler And Transport Shape

Recommended additive Go/Lua surface:

```lua
handler:connection_get_schemas_async(conn_id, request_id, root_epoch, caller_token, opts)
handler:connection_get_schema_objects_async(conn_id, schema, request_id, branch_id, root_epoch, opts)
```

The first returns schema rows only. The second returns object rows for one schema. Both must be genuinely async from the LSP/drawer perspective and must preserve root_epoch. Existing `connection_get_structure_async()` remains a full-tree compatibility path for old tests, legacy adapters, and any consumers not moved in Phase 14.

Adapter interface options:

- Add optional adapter methods `Schemas()` and `StructureForSchema(schema, opts)` with fallback to full `Structure()` only where unavoidable.
- For first-class Phase 14 adapters, implement Postgres and Oracle schema/object queries natively. These are the enterprise-critical paths from the backlog.
- For adapters without new methods, retain current full-tree path but mark that connection as "legacy eager" so the UI does not claim schema-level lazy semantics falsely.

Recommended transport event shape:

- Either add `schemas_loaded` and `schema_objects_loaded` events, or generalize `structure_children_loaded` with explicit fields like `structures` while keeping `columns` for column loads.
- Do not put table objects into the `columns` field. That would create hard-to-review ambiguity and increase false-pass risk in existing column tests.
- Single-flight/dedupe should be handler-owned for root schema list and schema-object fetches. Keys should include `(conn_id, root_epoch, schema, object_kind/filter_signature)`.

## Drawer UX Research

Recommended drawer behavior:

- Connection row expansion triggers schemas-only fetch when needed.
- Schema rows are collapsed by default.
- Expanding a schema inserts a row-local `loading...` child under only that schema.
- Loaded object rows use existing chunked materialization and `Load more...` mechanics where object count is high.
- Sort schemas and objects alphabetically. Table-count sorting is not reliable before table lists load.
- Use existing tree expand affordances rather than adding literal `[+]` text unless visual testing shows the expand icon is invisible. The backlog mentions `[+]` as an indicator, but the current tree already has expansion state; discuss should decide whether text is necessary.
- Search/filter remains zero-RPC. It searches loaded schema/object data plus visible connection/schema rows. It must not fetch unloaded schema objects while typing.

Drawer cache shape should evolve from "root full tree" to "root schemas plus per-branch schema object state":

```lua
_struct_cache = {
  root = {
    [conn_id] = {
      schemas = { ... },
      structures = { schema_nodes_without_object_children },
      schema_filter_signature = "...",
      partial = true,
      error = nil,
    },
  },
  branches = {
    [conn_id] = {
      [schema_branch_id] = {
        kind = "schema_objects",
        schema = "APP",
        loading = false,
        raw = { ... table/view/proc/function structures ... },
        request_gen = 2,
        applied_gen = 2,
        root_epoch = 7,
        complete = true,
      },
    },
  },
}
```

Keep branch IDs based on stable identity, not display strings, matching Phase 6 D-33. Schema branch ID should include conn id + schema type/name/schema using the existing escaped node ID encoder, or a similarly stable helper.

## LSP isIncomplete And Completion Strategy

The LSP specification says `CompletionList.isIncomplete` tells the client the list is incomplete and future typing should retrigger completion. Phase 14 should extend Phase 11's truthful incomplete behavior from column misses to schema table-list misses.

Recommended `schema.` completion state machine:

| State | Completion result | Async action |
| --- | --- | --- |
| Schema not known and schema list not loaded | `items = {}`, `isIncomplete = true` only if schema-list async request starts | Start/dedupe schema-list request |
| Schema known, table list loaded | Table items, `isIncomplete = false` | None |
| Schema known, table list not loaded | Existing cached partial items if any, otherwise empty; `isIncomplete = true` | Start/dedupe per-schema table-list request |
| Schema filtered out | Open fork: skip/no warning vs out-of-scope diagnostic/code action | Usually no table-list request |
| Async transport unavailable | Cache-only result, `isIncomplete = false` | None; never sync RPC |

Predictive warmup should be conservative:

- Drawer schema expansion has highest priority.
- LSP explicit `schema.` completion miss has next priority.
- Background prefetch only uses allowlisted schemas and a small concurrency limit.
- Do not issue per-keystroke RPCs. Use a schema-level dedupe key so repeated completion requests join the same in-flight request.

Schema cache should gain table-list state APIs:

```lua
cache:has_schema_table_list(schema) -> boolean
cache:is_schema_table_list_inflight(schema, root_epoch) -> boolean
cache:request_schema_table_list_async(schema, opts) -> boolean started
cache:on_schema_objects_loaded(payload)
cache:get_table_completion_items(schema) -- unchanged for callers, but returns cache state only
```

Diagnostics fork:

- Option 1: Diagnostics only validate within active schemas. Schema-qualified references to excluded schemas are skipped. This treats allowlist as "my workspace universe" and avoids enterprise noise.
- Option 2: Excluded schema references get a specific warning: "Schema X is outside active schemas." This is discoverable but can annoy users who intentionally query one-off external schemas.
- Option 3: Unknown-table warning remains unchanged. This is simplest but makes filtered-out schemas look like missing tables, which is misleading.

Research recommendation: lock Option 1 for v1.3 and leave Option 2 as a Phase 16/15 code-action opportunity. Discuss should decide because this is user-visible.

## Schema Allowlist Research

### Storage

Recommended persisted form:

```json
{
  "id": "file_source_/...",
  "name": "prod app",
  "type": "oracle",
  "url": "oracle://...",
  "schema_filter": ["APP", "REPORTING", "MY_*"],
  "wizard": {
    "db_kind": "oracle",
    "mode": "oracle_cloud_wallet",
    "fields": {},
    "schema_filter": ["APP", "REPORTING", "MY_*"]
  }
}
```

`schema_filter` must be available on runtime `ConnectionParams`, not only inside `wizard`, because drawer, handler, LSP, cache, and invalidation need it without re-reading raw source records. This requires extending `record_to_connection_params()` and `ConnectionParams` docs, because the loader currently returns only id/name/type/url.

Backwards compatibility:

- Missing `schema_filter` means all schemas.
- Existing `wizard` metadata remains valid.
- FileSource update should preserve unrelated JSON keys through the existing recursive merge path.
- EnvSource can accept `schema_filter` if present in its JSON payload, but add/edit wizard persistence is FileSource-only as today.

### Pattern Semantics

Recommended v1.3 syntax:

- Exact: `APP` matches only `APP` after chosen case-normalization policy.
- Glob: `MY_*` matches names with `MY_` prefix; `*` may appear anywhere only if implementation stays simple and well-tested.
- No regex in Phase 14.
- Whitespace-trim entries; drop empty strings.
- Duplicate entries normalize away in wizard submission.

Case-sensitivity fork:

- Oracle usually exposes unquoted identifiers upper-case; Postgres frequently exposes lower-case. The current LSP lookup folds names with `upper()` for matching. This research recommends case-insensitive matching for unquoted/common paths while preserving original schema labels in UI/cache. If quoted case-sensitive schema support matters, discuss should lock an escape or exact-case mode.

### Wizard UX

Recommended flow:

1. User fills connection details.
2. Wizard can run existing non-mutating connection test (`connection_test_spec`) before schema discovery.
3. Discovery step calls a new schema-list probe using the same params, not a saved connection mutation.
4. If discovery succeeds, show multi-select with discovered schemas and manual pattern entry.
5. If discovery fails, show manual pattern entry with the probe error surfaced as a warning, not a hard blocker.
6. Edit-existing flow pre-populates current `schema_filter`.

The wizard already has a compound modal architecture and per-field select/input plumbing, so schema selection can reuse the same `menu.select`/`menu.input` pattern. For more than a small number of schemas, a checkbox-style picker or filterable list will be needed; do not overload repeated single-select for 100+ schemas.

### Downstream Consumer Matrix

| Consumer | Required behavior |
| --- | --- |
| Source loading | Runtime `ConnectionParams` includes `schema_filter`; absent field preserved as all. |
| Handler | Metadata fetch APIs accept normalized active-schema filter and pass schema where supported by adapter queries. |
| Drawer | Render only allowed schemas under a connection; schema expansion fetches only that schema's object list. |
| Drawer filter | Zero-RPC; search loaded active schemas/objects and visible rows only. |
| LSP completion | Schema and table completions only expose active schemas; unfiltered schemas are not suggested. |
| LSP diagnostics | Discuss fork: skip excluded schemas or warn as out-of-scope. |
| Schema cache | Store allowed schemas and table-list loaded state; disk files include filter signature. |
| Disk cache | Filter change invalidates or namespaces old schema/table indexes to avoid stale completions. |
| Reload/invalidation | Changing `schema_filter` triggers eventful invalidation, root_epoch bump, drawer root/branches clear, LSP async cancellation, and disk-cache generation fence. |

## Cache Shape And Migration

Recommended disk schema cache version: `3`.

Proposed schema index payload:

```json
{
  "version": 3,
  "conn_id": "file_source_/...",
  "schema_filter": ["APP", "MY_*"],
  "schema_filter_signature": "sha256-or-stable-json",
  "schemas": ["APP", "MY_APP"],
  "schema_state": {
    "APP": { "objects_loaded": true, "updated_at": 1770000000 },
    "MY_APP": { "objects_loaded": false, "updated_at": 1770000000 }
  },
  "tables": {
    "APP": {
      "ORDERS": { "type": "table" }
    }
  }
}
```

Migration:

- v1/v2 full-tree-derived schema indexes can be read as `objects_loaded=true` for every schema when filter signature is absent and current filter means all schemas.
- If a connection now has a restrictive `schema_filter`, do not trust old all-schema table indexes as active results. Either filter them strictly in memory and rewrite v3, or discard table lists and keep only schema names.
- If fields are malformed, keep Phase 13's WARN-level true-corruption path.
- Column cache files can remain separate, but table-list invalidation must prevent columns for filtered-out schemas from leaking into completion.

Invalidation policy:

- Filter change should do a full metadata reload for the affected connection in v1.3. Incremental add/remove is attractive but has more stale-state risk.
- Eventful invalidation should bump authoritative root epoch once, clear drawer root/branches, cancel LSP async chains, and bump disk work generation.
- Reconnect rewrite must carry or recompute schema filter under the new connection id and drop stale branch payloads whose root_epoch no longer matches.

## Pairing Evaluation

| Shipping model | Pros | Cons | Recommendation |
| --- | --- | --- | --- |
| Allowlist only | Smaller first change; reduces drawer/completion noise. | Initial full structure fetch can still block for minutes on filtered enterprise DBs unless adapter queries apply filter before full fetch. | Not enough for DBEE-ARCH-01. |
| Lazy loading only | Fixes startup speed. | User still sees 100+ system/legacy schemas and LSP suggestions remain noisy. | Not enough for enterprise UX. |
| Ship together in one phase, staged internally | One metadata scope model, one cache migration, one invalidation contract, coherent UX. | Larger implementation and review surface. | Recommended. |
| Split into Phase 14a/14b | Easier review chunks. | Duplicates migration/invalidations and creates temporary half-correct behavior. | Only if plan-gate says Phase 14 is too large; keep both within v1.3 architecture arc. |

## Standard Stack

Use existing project primitives:

- Lua handler wrappers and Go RPC/event bus for async metadata transport.
- Existing handler authoritative root epoch and single-flight model for generation fencing.
- Existing drawer branch cache, loading/error/load-more nodes, and row-local lazy column machinery.
- Existing LSP SchemaCache, async miss tracking, disk-generation fencing, and `CompletionList.isIncomplete` wrapper.
- Existing FileSource JSON persistence and wizard submission path.
- Existing headless harness families for drawer, LSP cache, LSP semantic checks, and perf scenarios.

No new third-party Lua dependency is recommended for glob matching or schema picker state. Implement glob matching with a small local helper, but keep it isolated and table-driven. If a large checkbox UI is needed, build it on existing nui primitives already in the project.

## Architecture Patterns

- Additive transport, not repurposed transport: preserve full `structure_loaded`; add schema-specific requests/events or strictly typed `kind` payloads.
- Cache state is explicit: distinguish `schema known`, `schema object list not loaded`, `schema object list loading`, `schema object list loaded empty`, and `schema object list error`.
- One metadata scope source of truth: normalized active schema filter lives on connection params and is used by drawer, LSP, schema cache, and adapter queries.
- Demand fetch beats background fetch: explicit drawer expansion and explicit LSP `schema.` miss get priority.
- Every async payload carries `conn_id`, `request_id`, `root_epoch`, `schema`, and a filter signature or equivalent generation fence.
- Disk cache is namespaced or validated by filter signature before it can serve completions.
- Filter/search stays zero-RPC and never warms unloaded schemas.

## Don't Hand-Roll

- Do not invent a second LSP metadata cache outside `SchemaCache`.
- Do not add regex-level schema filters for v1.3.
- Do not create a new drawer tree model independent of `_struct_cache`; evolve the current branch cache.
- Do not synchronously fetch schema object lists from completion or drawer render paths.
- Do not use a timer-only "background fetch complete" assumption; rely on explicit loaded events and root_epoch/schema generation checks.
- Do not treat missing cache entries as empty loaded lists. Unknown/unloaded and loaded-empty must be separate states.

## Common Pitfalls

- False completion completeness: returning `isIncomplete=false` for a schema whose table list is not loaded.
- Stale cache leakage after `schema_filter` changes: old all-schema table lists can silently repopulate completion.
- Root epoch drift: bumping on both request and accept paths would violate Phase 6 D-46.
- Filter/search regression: invoking table-list fetch during `/` filter would violate Phase 6 D-38.
- Adapter fallback surprise: if a driver lacks schema-only methods and silently falls back to full eager `Structure()`, large DB users will still see old loading behavior.
- Empty filter ambiguity: `[]` can mean "no schemas" or "all schemas"; leaving it ambiguous will create diagnostics/completion bugs.
- Case mismatch: applying case-sensitive filters blindly will break Oracle-style upper-case schemas or Postgres lower-case schemas.
- Background prefetch overload: unconstrained per-schema parallelism can make shared enterprise DBs slower, not faster.

## Code Examples

Sketch only; not locked.

```lua
local function normalize_schema_filter(filter)
  if type(filter) ~= "table" or #filter == 0 then
    return nil -- all schemas, pending discuss lock for [] semantics
  end
  local out, seen = {}, {}
  for _, item in ipairs(filter) do
    local value = vim.trim(tostring(item or ""))
    if value ~= "" and not seen[value] then
      seen[value] = true
      out[#out + 1] = value
    end
  end
  return #out > 0 and out or nil
end
```

```lua
local function schema_table_completion(cache, schema, opts)
  if cache:has_schema_table_list(schema) then
    return completion_result(cache:get_table_completion_items(schema), false)
  end

  if cache:request_schema_table_list_async(schema, opts) then
    return completion_result(cache:get_table_completion_items(schema), true)
  end

  return completion_result(cache:get_table_completion_items(schema), false)
end
```

```lua
function DrawerUI:_materialize_schema_branch(conn_id, node_id, schema)
  local state = branch_state(self, conn_id, node_id, "schema_objects", true)
  if state.loading or state.error ~= nil or state.raw ~= nil then
    return build_branch_nodes(self, conn_id, node_id, "schema_objects")
  end

  state.request_gen = math.max(state.request_gen or 0, state.applied_gen or 0) + 1
  state.loading = true
  state.error = nil
  state.raw = nil
  self.handler:connection_get_schema_objects_async(conn_id, schema, state.request_gen, node_id, current_root_epoch(self, conn_id), {
    schema_filter_signature = self:_schema_filter_signature(conn_id),
  })
  return { convert.loading_node(node_id) }
end
```

## Open Forks For Discuss

1. **Diagnostics outside allowlist:** skip excluded schemas, warn "outside active schemas", or keep current unknown-table warning. Research recommends skip for v1.3.
2. **Empty `schema_filter`:** normalize/disallow as all-schemas, or let it mean show no schemas. Research recommends normalize/disallow to avoid a useless connection.
3. **Event shape:** add new `schemas_loaded`/`schema_objects_loaded` events, or generalize `structure_children_loaded` with `structures` payload. Research recommends new or clearly typed payload fields, not overloading `columns`.
4. **Adapter fallback policy:** legacy eager fallback for unsupported adapters vs hard-disable Phase 14 lazy claims. Research recommends explicit legacy eager mode.
5. **Case semantics:** case-insensitive matching with original labels preserved vs exact case-sensitive matching. Research recommends case-insensitive default with future quoted-identifier escape if needed.
6. **Background prefetch default:** off by default, on for allowlisted schemas, or auto-enabled below a schema/table threshold. Research recommends bounded on for allowlisted schemas after explicit demand priority is implemented.

## Risk Register

| Risk | Severity | Mitigation |
| --- | --- | --- |
| Stale completions after filter change | High | Filter signature in disk cache; eventful invalidation; root_epoch and disk generation fences; tests that old filtered-out schema never appears after edit. |
| `schema.` completion blocks on RPC | High | Completion path only calls cache/async request starter; no sync wrapper; cold miss test asserts prompt `isIncomplete=true`. |
| Drawer filter warms unloaded schemas | High | Preserve zero-RPC filter contract; tests assert no handler calls during filter. |
| Full-tree contract broken for legacy consumers | High | Keep `connection_get_structure_async` and `structure_loaded` full-tree behavior; add new APIs/events. |
| Adapter query divergence | Medium | Implement Postgres/Oracle first with shared tests; legacy adapters use explicit eager mode. |
| Background prefetch overload | Medium | Concurrency limit, prioritization, cancellation on epoch/filter change, perf harness scenarios. |
| Cache migration hides true corruption | Medium | Reuse Phase 13 two-step shape validation and WARN for malformed payloads. |
| Case-sensitive schema filter surprises | Medium | Normalize matching; preserve display labels; add Oracle/Postgres case tests. |
| Wizard probe failure blocks save | Medium | Manual entry fallback; probe error as warning. |
| Empty filter creates unusable connection | Medium | Discuss lock; recommended save validation/normalization. |

## Verification Ideas For Plan Phase

- `ARCH14_SCHEMA_FILTER_PERSISTED=true`: FileSource create/update/load round-trips `schema_filter`.
- `ARCH14_SCHEMA_DISCOVERY_MANUAL_FALLBACK=true`: wizard can save manual patterns when discovery fails.
- `ARCH14_SCHEMA_ONLY_ROOT_FAST=true`: initial drawer expansion renders schema rows without table rows and without full `Structure()` on lazy-capable adapters.
- `ARCH14_SCHEMA_BRANCH_LAZY_OK=true`: expanding schema A fetches only A objects and shows row-local loading.
- `ARCH14_SCHEMA_FILTER_DOWNSTREAM_ALL_PASS=true`: drawer, LSP completion, diagnostics, schema cache, and disk cache all apply the same filter.
- `ARCH14_LSP_SCHEMA_DOT_INCOMPLETE_OK=true`: first `schema.` table-list miss starts async warmup and returns `isIncomplete=true`; cache hit returns `false`.
- `ARCH14_FILTER_CHANGE_INVALIDATES=true`: editing filter clears stale drawer/LSP/disk state.
- `ARCH14_ZERO_RPC_DRAWER_FILTER_PRESERVED=true`: `/` filter does not trigger schema/table metadata fetch.
- `ARCH14_LEGACY_FULL_STRUCTURE_COMPAT=true`: old full-tree structure path still works.

## Source Notes

External sources checked:

- DBeaver object filtering docs: https://dbeaver.com/docs/dbeaver/Filter-Database-Objects/
- DBeaver filter configuration docs: https://dbeaver.com/docs/team-edition/desktop/Configure-Filters/
- JetBrains DataGrip introspection docs: https://www.jetbrains.com/help/datagrip/introspection.html
- JetBrains DataGrip schema visibility blog: https://blog.jetbrains.com/datagrip/2022/08/08/not-all-databases-schemas-are-displayed-by-default-why/
- LSP 3.17 CompletionList specification: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#completionList
- vim-dadbod: https://github.com/tpope/vim-dadbod
- vim-dadbod-completion: https://github.com/kristijanhusak/vim-dadbod-completion
- sqls SQL language server: https://github.com/sqls-server/sqls

Local source evidence checked:

- Current eager structures: `dbee/core/types.go`, `dbee/adapters/postgres_driver.go`, `dbee/adapters/oracle_driver.go`
- Handler async seams: `lua/dbee/handler/init.lua`, `dbee/handler/handler.go`, `dbee/handler/event_bus.go`
- Drawer cache/render/lazy columns: `lua/dbee/ui/drawer/init.lua`, `lua/dbee/ui/drawer/convert.lua`, `lua/dbee/ui/drawer/model.lua`
- LSP cache/server: `lua/dbee/lsp/schema_cache.lua`, `lua/dbee/lsp/init.lua`, `lua/dbee/lsp/server.lua`
- Source and wizard persistence: `lua/dbee/sources.lua`, `lua/dbee/handler/init.lua`, `lua/dbee/ui/connection_wizard/init.lua`, `lua/dbee/doc.lua`
