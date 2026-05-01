# Phase 14: Enterprise DB UX Architecture - Context

**Gathered:** 2026-04-29  
**Status:** Locked — ready for planning  
**Codex thread:** `019ddb0e-e8d0-7ca1-a4b0-8d4728863630`

<domain>
## Phase Boundary

Phase 14 delivers enterprise database schema scoping and deeper structure laziness. It adds a per-connection `schema_filter` metadata contract, optional per-schema lazy loading, schema discovery in the add/edit wizard, schema-aware handler/adapter fetch paths, partial-population drawer/LSP caches, and strict invalidation so filtered-out schemas do not leak into drawer, completion, diagnostics, or disk cache.

In scope:
- Per-connection `schema_filter` object with include/exclude SQL-style patterns and `lazy_per_schema` flag.
- Wizard add/edit flow for optional schema discovery, manual schema-pattern entry, existing-filter editing, and filter validation.
- New Go/Lua schema metadata APIs/events for schema discovery and per-schema object fetch.
- Go-side filter support for Oracle, Postgres, MySQL, and SQL Server/MSSQL; explicit legacy eager fallback for other adapters.
- Drawer schemas-only root mode, row-local schema-object loading, per-row error/retry, and zero-RPC filter preservation.
- LSP `schema.` table completion async-miss behavior, out-of-scope schema diagnostics, schema cache v3, and filter-signature disk invalidation.
- Focused tests plus preservation of Phase 4..13 smoke/perf/semantic gates.

Out of scope:
- Background prefetch of schema object lists; explicit on-demand only in Phase 14.
- Workspace/global schema presets; per-connection only in Phase 14.
- Regex schema filters.
- Loading timeout/elapsed/cancel UX beyond row-local spinner/error/retry for schema object fetch; broader loading UX is Phase 15.
- LSP hover/resolve/code actions/symbols; those remain conditional Phase 16.
- New database adapter support beyond adding Phase 14 schema APIs to already-present top-4 enterprise adapters.

</domain>

<decisions>
## Implementation Decisions

### Phase Shape And Drift Guard
- **D-224:** Phase 14 starts at D-224 and honors D-01..D-223 verbatim. It may extend prior contracts additively but must not reinterpret Phase 6 full-tree structure, Phase 7 handler-owned invalidation/single-flight, Phase 11 LSP async/cache discipline, or Phase 13 regression-closure gates.
- **D-225:** Phase 14 ships schema allowlist and lazy-loading deepening together. They share one metadata scope, one cache-shape migration, one invalidation model, and one drawer/LSP behavior contract.
- **D-226:** Phase 14 is architecture only. Phase 15 drawer/LSP polish, Phase 16 LSP feature closure, and v1.4 background prefetch/preset work must not be pulled into Phase 14 unless directly required to make the locked Phase 14 behavior correct.
- **D-227:** All Phase 14 behavior must be additive and backwards-compatible. Existing connections with no `schema_filter` remain all-schema, full-tree, eager structure connections unless the user explicitly opts into lazy per-schema mode.

### Schema Filter Metadata And Lazy Mode
- **D-228:** The persisted schema scope lives on runtime `ConnectionParams.schema_filter`, not only inside `wizard` metadata. `FileSource`, `EnvSource`, handler snapshots, drawer, LSP, and cache consumers must be able to read the same normalized filter without re-reading raw source records.
- **D-229:** The locked metadata shape is:
  ```json
  {
    "schema_filter": {
      "include": ["HR", "FIN%"],
      "exclude": ["HR_TEMP%"],
      "lazy_per_schema": true
    }
  }
  ```
  `include` and `exclude` are ordered user inputs at rest, but all runtime matching uses normalized sets.
- **D-230:** Missing `schema_filter` or missing `schema_filter.include` means all schemas and `lazy_per_schema=false`. This preserves current behavior.
- **D-231:** `schema_filter.include = []` is invalid in the wizard and source update path. The implementation must reject save with a validation error rather than interpreting an empty include list as "show no schemas."
- **D-232:** `schema_filter.exclude = []` is valid and equivalent to no excludes.
- **D-233:** `lazy_per_schema` defaults to `false` in all cases, including edit flows where the user adds a filter. Phase 14 requires explicit user opt-in for lazy mode; no auto-on behavior based on globs, schema count, or add/edit timing.
- **D-234:** Allowlist without lazy mode is valid and supported. It filters the schema universe but may still use current eager full-tree structure loading, reduced by Go-side adapter filtering where supported.
- **D-235:** Allowlist plus `lazy_per_schema=true` is the enterprise fast-start mode. It uses schemas-only root fetch plus per-schema object fetch for adapters with Phase 14 lazy capabilities.
- **D-236:** Pattern syntax is SQL-style glob only: `%` means any run of characters and `_` means exactly one character. Regex is out of scope.
- **D-237:** Unsupported regex/metacharacter syntax must be rejected at parse/validation time with actionable copy. Literal schema names and SQL-glob patterns are the only accepted filter entries.
- **D-238:** Include/exclude matching is include-then-exclude. A schema is active when it matches at least one include pattern and does not match any exclude pattern. Missing include means implicit include-all; explicit include list means no implicit all.

### Case Semantics And Filter Signature
- **D-239:** Display labels preserve the database-provided schema casing. Matching uses adapter-default folding, resolved from connection type or adapter capability.
- **D-240:** The existing `SchemaCache` fold helper is the seam, not the final global algorithm. Phase 14 must replace or wrap its current uppercase-only behavior so Oracle can fold uppercase, Postgres can fold lowercase, MySQL can use its adapter default, and SQL Server can use a collation-aware or documented case-insensitive fallback.
- **D-241:** The normalized filter signature is deterministic and non-cryptographic; no new hashing dependency is required. It is stored as a string in cache JSON under `schema_filter_signature`.
- **D-242:** Signature input normalization is locked: trim whitespace, drop empty entries before validation, reject empty `include`, normalize pattern case with the adapter fold strategy, sort normalized include patterns lexicographically, sort normalized exclude patterns lexicographically, and normalize absent filter/missing include to the same all-schema/full-mode representation.
- **D-243:** Signature string format is locked as:
  `schema-filter-v1|type=<connection-type>|fold=<fold-id>|lazy=<0|1>|include=<encoded-list>|exclude=<encoded-list>`.
  Each encoded list is a comma-joined sequence of length-prefixed normalized patterns (`<byte-length>:<pattern>`). The empty exclude list is `0:`. The all-schema implicit include is `*`.
- **D-244:** `lazy_per_schema` participates in the signature. Toggling lazy mode invalidates schema cache state even when include/exclude patterns do not change, because root mode and partial-population semantics change.

### Filter Authority And Adapter Support
- **D-245:** Handler middleware owns schema filter authority. Add `Handler:get_schema_filter(conn_id)` or equivalent as the single Lua read point for normalized scope; consumers must not independently parse raw connection records.
- **D-246:** Go adapter queries own cost reduction. Oracle, Postgres, MySQL, and SQL Server/MSSQL must implement Go-side filtering for structure/object metadata paths where the filter can reduce DB/network work.
- **D-247:** Lua drawer and LSP re-check schema scope at render/completion/diagnostic/cache boundaries as defense in depth. This catches stale cache, legacy eager fallback payloads, and adapter bugs.
- **D-248:** Adapters without new Phase 14 schema capabilities run in explicit legacy eager mode. They keep current full-tree behavior and may receive Lua-side filtering, but the UI must not claim per-schema lazy behavior for them.
- **D-249:** Top-4 enterprise adapters in Phase 14 scope are Oracle, Postgres, MySQL, and SQL Server/MSSQL. SQLite, DuckDB, ClickHouse, BigQuery, Databricks, Mongo, Redis, Redshift, and other adapters may keep legacy eager mode unless planning proves a low-risk additive implementation is necessary.
- **D-250:** Adapter capability detection must be explicit and testable. Wizard and drawer may expose lazy mode only when the selected/current connection type supports `ListSchemas` and `StructureForSchema`; unsupported types can still save allowlist metadata for Lua-side filtering.

### Schema APIs And Events
- **D-251:** Existing `connection_get_structure_async()` and `structure_loaded` remain full-tree contracts per Phase 6 D-31. Phase 14 must not narrow, rename, or overload them.
- **D-252:** Add a schema discovery/list API with async Lua wrapper and Go RPC surface. The completion event is `schemas_loaded { conn_id, request_id, root_epoch, caller_token?, schemas, error }`.
- **D-253:** Add a per-schema object API with async Lua wrapper and Go RPC surface. The completion event is `schema_objects_loaded { conn_id, request_id, root_epoch, caller_token?, schema, objects, error }`.
- **D-254:** `structure_children_loaded` remains column-oriented. Phase 14 must not put table/schema object payloads into the existing `columns` field or rely on `kind` alone to reinterpret that event.
- **D-255:** `ListSchemas` returns the full visible schema universe for the connection. It is not filtered by existing `schema_filter` in the adapter. The handler/Lua layer applies the active filter afterward for drawer/LSP/cache use.
- **D-256:** Wizard discovery always uses full-universe `ListSchemas`. On add, no filter exists yet. On edit, rediscovery still shows the full universe with current filter selections preselected, so users can add schemas outside the current scope.
- **D-257:** Structure/object metadata calls are filter-aware. Full `Structure()` in allowlist-only mode and `StructureForSchema(schema)` in lazy mode must apply Go-side filters for supported adapters, with Lua re-checks afterward.
- **D-258:** Schema API payloads carry original schema display labels plus enough normalized identity data for deterministic matching. If only labels are transported, Lua must derive normalized identity using the locked adapter fold strategy.

### Single-Flight And Invalidation
- **D-259:** Existing full-tree single-flight registry/key `(conn_id, authoritative_root_epoch)` remains unchanged for `connection_get_structure_singleflight()`.
- **D-260:** Add separate schema-list single-flight state for `ListSchemas`, keyed by `(conn_id, authoritative_root_epoch, purpose)`, where `purpose` distinguishes wizard discovery from drawer/LSP root bootstrap if needed. This avoids coupling full-root waiters to schema-list waiters.
- **D-261:** Add separate per-schema object single-flight state for `StructureForSchema`, keyed by `(conn_id, folded_schema, authoritative_root_epoch)`. The filter signature is not required in the key because filter changes must bump the authoritative root epoch, but implementations may store it in the flight for diagnostics and stale-payload assertions.
- **D-262:** Schema-list and schema-object waiters follow Phase 7 D-87 cleanup semantics: success/error fan out to all waiters then drop the flight; supersession notifies waiters; consumer teardown removes waiter slots; transport cancellation is not required.
- **D-263:** Schema-object async miss dedupe follows Phase 11 D-158/D-159 discipline. Identical `(conn_id, folded_schema, root_epoch)` misses share one async request; different schemas, connections, or epochs do not share.
- **D-264:** Filter changes are eventful invalidations. They bump `handler.authoritative_root_epoch[conn_id]` once, supersede full/schema in-flight metadata requests, clear drawer root/branches, clear LSP async chains, and invalidate disk cache generation.
- **D-265:** Reconnect identity rewrite remains a same-epoch path per Phase 7 D-86. Schema-filter metadata migrates to the rewritten connection identity only when the rewritten connection is the same semantic connection; otherwise stale schema/list/object payloads drop by conn/epoch mismatch.

### Drawer Behavior
- **D-266:** Drawer root remains Phase 7 connection-only. Schema allowlist and lazy loading affect children under a connection row only.
- **D-267:** In default/full mode, connection expansion may keep current eager structure behavior, with active schema filtering applied before rendering.
- **D-268:** In `lazy_per_schema=true` mode on capable adapters, connection expansion fetches schema names only, applies active schema filtering, and renders schema rows with no table/view/procedure/function children until schema expansion.
- **D-269:** Schema rows are collapsed by default. Expanding a schema starts a per-schema async object fetch when needed and renders a row-local `loading...` child using existing `convert.loading_node` patterns.
- **D-270:** Schema object fetch failure renders row-local error state using existing `convert.error_node` precedent and must expose a retry path by re-expanding or pressing the existing nearest-ancestor reload path. Do not invent a new global modal/error primitive.
- **D-271:** Loaded schema object rows use existing structure node IDs, chunked materialization, and `Load more...` mechanics where large child counts require bounded rendering.
- **D-272:** Drawer `/` filter remains zero-RPC per Phase 6 D-38 and Phase 13 D-208. It searches only currently authoritative cached/visible rows and must never trigger `ListSchemas`, `Structure`, `StructureForSchema`, or column fetches while typing.
- **D-273:** `_struct_cache` gains additive partial-population fields, including `root_mode`, `root_loaded_schemas`, schema branch loading/error state, and cache filter signature. Existing full-tree root fields remain valid for legacy/full mode.

### LSP Completion And Diagnostics
- **D-274:** LSP `schema.` completion extends Phase 11 async-miss machinery. Cache hits return table items with `isIncomplete=false`. A cold schema table-list miss returns `isIncomplete=true` only when a per-schema async object fetch is actually in flight.
- **D-275:** If the schema-object async surface is unavailable or the adapter is legacy eager, LSP completion remains cache-only and non-blocking. It must not fall back to synchronous metadata fetch inside `textDocument/completion`.
- **D-276:** LSP schema and table completions honor the same normalized active schema filter as drawer and handler. Filtered-out schemas are not suggested.
- **D-277:** Qualified references to filtered-out schemas do not produce "Unknown table" warnings. They produce an Information-level diagnostic with message `Schema X is outside this connection's scope. Edit schema_filter to include.`
- **D-278:** The out-of-scope diagnostic uses the existing `dbee/lsp` diagnostic namespace and `vim.diagnostic.set` path. It must not introduce a second diagnostic owner.
- **D-279:** Phase 11 D-177/D-178 remain intact inside active scope: schema-qualified references validate against that schema, and unqualified duplicate behavior remains deterministic.

### Wizard Discovery UX
- **D-280:** Add-connection wizard keeps the fast path. After existing `connection_test_spec` ping succeeds, it offers `Discover schemas now?` with default `No`.
- **D-281:** Edit-connection wizard pre-populates current `schema_filter` and offers `Discover schemas now?` with default `Yes`.
- **D-282:** Discovery failure does not block save. The wizard falls back to manual comma-separated schema pattern entry and displays the probe error as a warning or inline message.
- **D-283:** Manual entry supports comma-separated include and exclude patterns. The planner may choose exact UI syntax for excludes, but it must serialize into the locked `include`/`exclude` arrays.
- **D-284:** Edit flow must support clear-filter behavior that removes `schema_filter` or resets it to absent/all-schemas. It must not persist `include=[]`.
- **D-285:** Lazy mode is an explicit wizard toggle. The wizard may disable or explain the toggle when the selected adapter lacks Phase 14 lazy capabilities.
- **D-286:** Wizard persistence must preserve existing Phase 8 contracts: FileSource atomic writes, raw compatibility, password placeholder behavior, ping-before-save, and existing add/edit flow shape.

### Disk Cache And Migration
- **D-287:** Bump `SCHEMA_CACHE_VERSION` to `3` for Phase 14 schema index cache.
- **D-288:** Schema cache v3 includes `schema_filter_signature`, root mode / lazy mode state, schema list, per-schema object-loaded state, and table/object indexes for loaded active schemas.
- **D-289:** On cache load, signature mismatch is treated as a known scope migration, not true corruption. It must silently invalidate/delete/regenerate using Phase 11/13 safe cache patterns and must not emit WARN-level corrupt-cache notifications.
- **D-290:** True corruption still warns: invalid JSON, malformed current-version fields, unsupported future versions, or unrecognizable shapes keep Phase 13 true-corruption diagnostic behavior.
- **D-291:** Filter change uses strict cache invalidation. It clears the schema-index file and all per-table column cache files for that connection so filtered-out schemas cannot leak stale columns.
- **D-292:** Cache writes remain atomic and isolated. No Phase 14 code may prune or scan user cache files synchronously from the LSP completion request path.

### Adapter Query Scope
- **D-293:** Oracle implementation must support full schema discovery and scoped object fetches for tables, external tables, views, materialized views, procedures, and functions in the same semantic grouping as current `oracleGroupedStructure`.
- **D-294:** Postgres implementation must support schema discovery and scoped object fetches for tables and materialized views at minimum, preserving current table/view materialization semantics.
- **D-295:** MySQL implementation must support schema discovery and scoped table fetches from `information_schema.tables`, preserving current table-only structure behavior unless planning safely adds views from existing semantics.
- **D-296:** SQL Server/MSSQL implementation must support schema discovery and scoped table/view fetches through `INFORMATION_SCHEMA` or equivalent, preserving current `getPGStructureType` mapping behavior.
- **D-297:** Adapter SQL must use parameterized or safely escaped filter values appropriate to each driver; no direct string interpolation of user-provided schema patterns into SQL without a safe quoting/binding path.

### Test And Verification Gates
- **D-298:** Add Phase 14 tests for `schema_filter` persistence/load normalization, include/exclude SQL-glob matching, empty-include rejection, absent-filter backwards compatibility, and signature stability.
- **D-299:** Add tests for wizard add default-no discovery, edit default-yes discovery, probe failure manual fallback, clear-filter behavior, and explicit lazy toggle behavior.
- **D-300:** Add handler/event tests for `schemas_loaded`, `schema_objects_loaded`, schema-list single-flight, per-schema object single-flight, superseded epoch cleanup, and reconnect/filter-change stale-payload drops.
- **D-301:** Add drawer tests for full mode filtering, lazy schemas-only root, row-local schema loading/error/retry, loaded schema branch rendering, zero-RPC drawer filter preservation, and legacy eager fallback.
- **D-302:** Add LSP tests for `schema.` async miss `isIncomplete`, cache-hit completion completeness, no sync fallback, filtered-out completion exclusion, Information-level out-of-scope diagnostics, and active-scope unknown-table warnings.
- **D-303:** Add disk cache tests for v2-to-v3 migration, filter-signature mismatch silent regeneration, strict column-file clearing on filter change, true corruption WARN retention, and no completion-path heavy disk work.
- **D-304:** Add adapter tests for Oracle, Postgres, MySQL, and SQL Server scoped schema/object query generation and result grouping. Headless tests must avoid live database dependencies unless an existing adapter-specific test harness already provides deterministic fixtures.
- **D-305:** Phase 14 verification must continue to run Phase 4..13 smoke/perf/semantic evidence, including Phase 13 `UX13_ALL_PASS=true`, LSP01/LSP11 families, drawer filter/perf gates, and the three LSP semantic alias checks.

### the agent's Discretion
- Exact helper names for normalized schema filters, adapter capability records, schema event handlers, and cache signature functions, as long as D-228..D-244 hold.
- Exact wizard copy and placement of the discovery prompt/manual entry/toggle, as long as add defaults to no, edit defaults to yes, and manual fallback remains available.
- Exact implementation split between Go core optional interfaces and adapter methods, as long as full-tree compatibility and explicit legacy eager mode are preserved.
- Exact row-local retry gesture for schema-object errors, as long as it uses existing drawer patterns and does not add a new UI primitive.

</decisions>

<specifics>
## Specific Ideas

- This phase is meant to make Naveen's `nkanuri6` Oracle-style enterprise setup usable without minutes-long initial `loading...`.
- DBeaver/DataGrip-style "active schemas" is the product reference: users pick the 1-5 schemas they care about out of a much larger enterprise database.
- Allowlist is always useful as noise reduction; lazy mode is the opt-in fast-start architecture.
- The four explicit forks are resolved:
  - `lazy_per_schema` stays explicit opt-in even when a filter is added.
  - Filter signature uses the deterministic `schema-filter-v1|...` normalized string in D-242/D-243.
  - Full-tree, schema-list, and schema-object single-flight registries coexist separately.
  - `ListSchemas` returns full universe for discovery and root schema names; active filtering is applied afterward.

</specifics>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Milestone, Requirements, And Backlog
- `.planning/milestones/v1.3-roadmap.md` — Phase 14 scope, success criteria, sequencing after Phase 13, and Phase 15/16 boundaries.
- `.planning/REQUIREMENTS.md` — `DBEE-ARCH-01` enterprise schema allowlist and progressive browsing requirement.
- `known-issues.md` — v1.3 backlog items #4 and #5 plus related loading UX notes.
- `.planning/PROJECT.md` — v1.3 project focus, backwards compatibility, adapter diversity, and current thread ID.
- `.planning/STATE.md` — current milestone state and continuity notes.

### Research Inputs
- `.planning/phases/14-enterprise-db-architecture/14-RESEARCH.md` — Codex research, Option A+D recommendation, code seams, external ecosystem notes, risks, and verification ideas.
- `.planning/research/v13-phase14-opus-research.md` — Opus research, Option E two-mode tree, handler/adapter seams, root_mode/root_loaded_schemas proposal, and risks.

### Locked Prior Decisions
- `.planning/phases/04-drawer-navigation/04-CONTEXT.md` — Phase 4 drawer filter and restore behavior, especially D-31.
- `.planning/phases/06-structure-laziness-notes-picker/06-CONTEXT.md` — D-30..D-63 structure laziness, D-31 full-tree event preservation, D-38 zero-RPC filter, D-46 root_epoch single-bump, and D-63 nearest-ancestor reload.
- `.planning/phases/07-connection-only-drawer/07-CONTEXT.md` — D-64..D-88 connection-only root, handler-owned single-flight, authoritative root epoch, invalidation backpressure, eventful/silent invalidation, and waiter cleanup.
- `.planning/phases/08-type-aware-connection-wizard/08-CONTEXT.md` — D-89..D-106 wizard flow, ping, FileSource, and wizard metadata contracts.
- `.planning/phases/10-lsp-optimization/10-CONTEXT.md` — D-119..D-149 LSP perf harness and marker expectations.
- `.planning/phases/11-lsp-optimization-correctness/11-CONTEXT.md` — D-150..D-197 LSP async miss, `isIncomplete`, schema cache, diagnostics, disk cache safety, and corrupt recovery.
- `.planning/phases/13-ux-regression-batch/13-CONTEXT.md` — D-198..D-223 Phase 13 regression gates and Phase 14 deferral boundary.
- `.planning/phases/13-ux-regression-batch/13-SUMMARY.md` — Phase 13 shipped evidence, UX13 rollup behavior, and regression-closure summary.

### Production Code
- `lua/dbee/sources.lua` — FileSource/EnvSource connection record loading and additive metadata persistence seam.
- `lua/dbee/doc.lua` — `ConnectionParams`, wizard seed/submission, and public type docs to extend for `schema_filter`.
- `lua/dbee/handler/init.lua` — Lua handler single-flight, authoritative root epoch, source reload/invalidation, wizard submission, and RPC wrappers.
- `dbee/core/connection.go` — Go `Driver` interface, `TableOptions`, and `Connection.GetStructure()` compatibility path.
- `dbee/core/types.go` — `Structure`, `StructureType`, and generic schema -> object grouping helper.
- `dbee/handler/handler.go` — Go RPC handler `ConnectionGetStructureAsync` and `ConnectionGetColumnsAsync` patterns to extend.
- `dbee/handler/event_bus.go` — existing `structure_loaded` and `structure_children_loaded` event serialization patterns.
- `dbee/adapters/oracle_driver.go` — Oracle full structure query/grouping and column fetch.
- `dbee/adapters/postgres_driver.go` — Postgres full structure query and materialized-view handling.
- `dbee/adapters/mysql_driver.go` — MySQL full structure query and table-only schema grouping.
- `dbee/adapters/sqlserver_driver.go` — SQL Server full structure query and table/view mapping.
- `lua/dbee/ui/connection_wizard/init.lua` — add/edit wizard flow, type/mode fields, ping/save, and Phase 13 highlight plumbing.
- `lua/dbee/ui/drawer/init.lua` — drawer structure cache, branch state, root reload, filter lifecycle, row-local lazy columns, and event handlers.
- `lua/dbee/ui/drawer/convert.lua` — node IDs, loading/error/load-more nodes, structure node decoration, and connection children.
- `lua/dbee/ui/drawer/model.lua` — drawer search model and visible-row filter fallback.
- `lua/dbee/lsp/schema_cache.lua` — schema cache indexes, async column miss machinery, disk cache v2, fold helper seam, and atomic writes.
- `lua/dbee/lsp/init.lua` — LSP bootstrap, structure-loaded cache rebuild, connection invalidation handling.
- `lua/dbee/lsp/server.lua` — completion result `isIncomplete`, diagnostics, and in-process LSP server request path.

### Test Harnesses
- `ci/headless/check_connection_wizard.lua` — wizard add/edit harness to extend for schema discovery/manual fallback/lazy toggle.
- `ci/headless/check_drawer_filter.lua` — zero-RPC drawer filter and restore harness that Phase 14 must preserve.
- `ci/headless/check_drawer_perf.lua` — drawer performance harness for root/schema expansion regressions.
- `ci/headless/check_lsp_disk_cache_safety.lua` — schema cache migration/corruption/disk safety harness to extend for v3.
- `ci/headless/check_lsp_alias_completion.lua`, `ci/headless/check_lsp_schema_alias_completion.lua`, `ci/headless/check_lsp_alias_rebinding.lua` — semantic LSP checks that must continue passing.
- `ci/headless/check_lsp_perf.lua`, `ci/headless/lsp_perf_thresholds.lua`, `ci/headless/perf_thresholds.lua` — LSP/drawer perf threshold and advisory-rollup context.
- `ci/headless/check_ux13_rollup.lua` — Phase 13 fail-closed aggregate marker gate that Phase 14 verification must preserve.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- Existing handler authoritative root epoch and `_structure_flights` provide the template for new schema-list and schema-object single-flight registries.
- Existing drawer branch cache and `_materialize_table_like_branch()` provide the row-local loading/error pattern for per-schema object fetch.
- Existing `convert.loading_node()` and `convert.error_node()` are the locked spinner/error primitives for schema rows.
- Existing `SchemaCache` async column miss state provides the model for `schema.` table-list async misses.
- Existing Phase 13 `WIZARD_WINHIGHLIGHT` and wizard/menu plumbing keep new schema discovery UI from regressing dark colorscheme readability.

### Established Patterns
- Full-tree `structure_loaded` is compatibility-sensitive and already has drawer/LSP consumers; Phase 14 should add explicit events rather than overload it.
- Drawer filter is guarded as zero-RPC in code comments and Phase 6/13 locks; all new lazy states must maintain that boundary.
- FileSource write/update already preserves additive raw JSON keys through recursive merge, but runtime load currently strips to id/name/type/url; Phase 14 must extend runtime params.
- Current `SchemaCache:fold()` is uppercase-only; adapter-default folding requires a real fold strategy rather than assuming one global case rule.
- Phase 13 cache migration fixed "missing version" UX. Phase 14 v3 migration should reuse shape-validation and true-corruption warning distinctions.

### Integration Points
- Source/wizard path: `connection_wizard/init.lua` serializes submission, `handler:submit_connection_wizard()` persists it, `sources.lua` reloads runtime params.
- Handler/RPC path: Lua handler wrappers call `vim.fn.Dbee...`; Go handler invokes core connection methods; event bus serializes Lua events.
- Drawer path: connection expansion calls root reload or branch materialization; schema mode adds a schemas-only root and per-schema branch fetch.
- LSP path: structure-loaded rebuilds `SchemaCache`; completion/diagnostics read the cache and need active-filter awareness.
- Disk path: `schema_cache.lua` writes one schema index and many column files; Phase 14 must invalidate both strictly on filter change.

</code_context>

<deferred>
## Deferred Ideas

- Background schema object prefetch and priority warming — v1.4 after lazy mode is dogfooded.
- Workspace-level schema filter presets or shared filter profiles — v1.4 or later.
- Regex filters — intentionally rejected for v1.3.
- Auto-enabling `lazy_per_schema` based on include globs, schema counts, or adapter heuristics — v1.4 once behavior is proven.
- Loading timeout/elapsed/manual cancel beyond row-local schema fetch loading/error/retry — Phase 15.
- LSP code action to add an out-of-scope schema to `schema_filter` from diagnostics — likely Phase 16 or later.
- Adapter-specific lazy support for non-top-4 adapters — future hardening unless planning finds a trivial safe add.

</deferred>

---

*Phase: 14-enterprise-db-architecture*
*Context gathered: 2026-04-29*
