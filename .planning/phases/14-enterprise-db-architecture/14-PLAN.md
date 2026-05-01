---
phase: 14-enterprise-db-architecture
plan: 01
revision: 4
type: execute
wave: 1
depends_on: [13]
files_modified:
  - .planning/REQUIREMENTS.md
  - dbee/core/connection_params.go
  - dbee/core/connection.go
  - dbee/core/types.go
  - dbee/handler/marshal.go
  - dbee/handler/handler.go
  - dbee/handler/event_bus.go
  - dbee/endpoints.go
  - dbee/adapters/oracle_driver.go
  - dbee/adapters/postgres_driver.go
  - dbee/adapters/mysql_driver.go
  - dbee/adapters/sqlserver_driver.go
  - dbee/adapters/adapters.go
  - lua/dbee/doc.lua
  - lua/dbee/api/__register.lua
  - lua/dbee/sources.lua
  - lua/dbee/schema_filter.lua
  - lua/dbee/handler/init.lua
  - lua/dbee/lsp/schema_cache.lua
  - lua/dbee/lsp/init.lua
  - lua/dbee/lsp/server.lua
  - lua/dbee/ui/drawer/init.lua
  - lua/dbee/ui/drawer/model.lua
  - lua/dbee/ui/drawer/convert.lua
  - lua/dbee/ui/connection_wizard/init.lua
  - ci/headless/check_schema_filter.lua
  - ci/headless/check_handler_schema_filter.lua
  - ci/headless/check_adapter_schema_filter.lua
  - ci/headless/check_drawer_filter.lua
  - ci/headless/check_drawer_perf.lua
  - ci/headless/check_connection_wizard.lua
  - ci/headless/check_lsp_schema_filter_lazy.lua
  - ci/headless/check_lsp_disk_cache_safety.lua
  - ci/headless/check_lsp_perf.lua
  - ci/headless/lsp_perf_thresholds.lua
  - ci/headless/check_arch14_rollup.lua
  - Makefile
  - .github/workflows/test.yml
autonomous: true
requirements: [DBEE-ARCH-01]
---

<objective>
Ship Phase 14 enterprise database UX architecture while preserving all Phase 4..13 contracts.

By the end of this plan, each connection can persist a normalized `schema_filter` with SQL-style include/exclude patterns and an explicit `lazy_per_schema` flag; Oracle, Postgres, MySQL, and SQL Server/MSSQL reduce metadata cost through Go-side schema filtering plus `ListSchemas` and `StructureForSchema`; capable lazy connections expand to a schemas-only root and fetch schema objects on demand; drawer, LSP completion, diagnostics, and disk cache honor the same active schema scope; filtered-out qualified references produce an Information-level out-of-scope diagnostic; cache v3 safely invalidates on filter signature changes; unsupported adapters remain in explicit legacy eager mode; and `ARCH14_ALL_PASS=true` is emitted only by a fail-closed rollup gate that also requires preserved `UX13_ALL_PASS=true` and Phase 4..13 smoke/perf/semantic evidence.
</objective>

<execution_context>
@/Users/naveenkanuri/Documents/nvim-dbee/.codex/skills/gsd-plan-phase/SKILL.md
@/Users/naveenkanuri/Documents/nvim-dbee/.codex/get-shit-done/workflows/plan-phase.md
</execution_context>

<context>
@.planning/phases/14-enterprise-db-architecture/14-CONTEXT.md
@.planning/phases/14-enterprise-db-architecture/14-RESEARCH.md
@.planning/research/v13-phase14-opus-research.md
@.planning/milestones/v1.3-roadmap.md
@.planning/REQUIREMENTS.md
@known-issues.md
@.planning/phases/06-structure-laziness-notes-picker/06-CONTEXT.md
@.planning/phases/07-connection-only-drawer/07-CONTEXT.md
@.planning/phases/08-type-aware-connection-wizard/08-CONTEXT.md
@.planning/phases/11-lsp-optimization-correctness/11-CONTEXT.md
@.planning/phases/13-ux-regression-batch/13-CONTEXT.md
@.planning/phases/13-ux-regression-batch/13-SUMMARY.md
</context>

<must_haves>
  <truths>
    - "Honor D-01..D-305 verbatim. Phase 14 may add schema-filter and schema-lazy surfaces, but it must not reinterpret existing full-tree, zero-RPC filter, root-epoch, LSP async, cache corruption, or UX13 rollup contracts."
    - "`lazy_per_schema` defaults to false everywhere, including edit flows where a user adds a filter. Lazy mode is explicit opt-in only."
    - "Missing `schema_filter` or missing `schema_filter.include` means all schemas and full-tree eager behavior."
    - "`schema_filter.include = []` is invalid; it is not a no-schema connection."
    - "Pattern syntax is SQL-style glob only: `%` any run, `_` one char. Regex and unsupported metacharacters are rejected at validation boundaries."
    - "Handler middleware owns normalized schema-filter authority through `Handler:get_schema_filter(conn_id)` or an equivalent single read point."
    - "Go-side cost reduction is mandatory for Oracle, Postgres, MySQL, and SQL Server/MSSQL. Other adapters remain explicit legacy eager mode."
    - "Existing `connection_get_structure_async()` and `structure_loaded` remain full-tree contracts."
    - "New events are explicit: `schemas_loaded` and `schema_objects_loaded`; `structure_children_loaded` stays column-oriented."
    - "Three single-flight registries coexist: full-tree, schema-list, and schema-object."
    - "Schema-object single-flight dedupe is not enough for enterprise scale. Phase 14 also requires per-connection metadata backpressure for distinct schema-object requests."
    - "Drawer `/` filter remains zero-RPC and must not trigger schema list, full structure, schema object, or column fetches."
    - "LSP completion never performs synchronous metadata fetch for `schema.` cold misses. `isIncomplete=true` is truthful only when async schema-object work is actually in flight."
    - "Filtered-out schema references are Information-level out-of-scope hints, not unknown-table warnings and not silent."
    - "`SCHEMA_CACHE_VERSION` bumps to 3, with `schema_filter_signature` stored in cache JSON and strict disk invalidation on filter change."
    - "Per-row spinner/error UX uses existing `convert.loading_node` and `convert.error_node`; no new drawer UI primitive is introduced."
  </truths>
  <artifacts>
    - path: "lua/dbee/schema_filter.lua"
      provides: "new shared Lua normalization, SQL-glob validation, matching, fold, and signature helpers"
      contains: "schema-filter-v1"
    - path: "dbee/core/connection_params.go"
      provides: "runtime persisted `ConnectionParams.schema_filter` shape carried through Go params"
      contains: "SchemaFilter"
    - path: "lua/dbee/handler/init.lua"
      provides: "single schema-filter read point plus schema-list/schema-object single-flight registries"
      contains: "connection_get_schema_objects_singleflight"
    - path: "lua/dbee/api/__register.lua"
      provides: "Neovim remote manifest entries for new schema-list and schema-object RPC functions"
      contains: "DbeeConnectionListSchemasSpec"
    - path: "dbee/core/connection.go"
      provides: "compatibility-preserving filter-aware metadata API surface for Go adapters"
      contains: "StructureOptions"
    - path: "dbee/handler/event_bus.go"
      provides: "new `schemas_loaded` and `schema_objects_loaded` event serialization"
      contains: "SchemasLoaded"
    - path: "lua/dbee/ui/drawer/init.lua"
      provides: "mode-aware root expansion, partial `_struct_cache`, row-local schema loading/error/retry"
      contains: "root_mode"
    - path: "lua/dbee/lsp/schema_cache.lua"
      provides: "cache v3, adapter-aware fold, partial-population state, signature mismatch invalidation"
      contains: "SCHEMA_CACHE_VERSION = 3"
    - path: "ci/headless/check_arch14_rollup.lua"
      provides: "fail-closed aggregate gate for ARCH14 markers and preserved Phase 4..13 evidence"
      contains: "ARCH14_ALL_PASS"
    - path: "ci/headless/check_lsp_perf.lua"
      provides: "advisory ARCH14 LSP schema-dot hot-path measurements"
      contains: "LSP_SCHEMA_DOT_COMPLETION_MISS_ASYNC"
  </artifacts>
  <key_links>
    - from: "lua/dbee/sources.lua"
      to: "lua/dbee/handler/init.lua"
      via: "runtime params carry raw schema filter; handler normalizes once for consumers"
      pattern: "record_to_connection_params"
    - from: "lua/dbee/handler/init.lua"
      to: "dbee/handler/handler.go"
      via: "Lua async wrappers pass handler-normalized StructureOptions into Go endpoints and route explicit schema events through single-flight waiters"
      pattern: "connection_get_schema_objects_singleflight"
    - from: "dbee/adapters/*_driver.go"
      to: "lua/dbee/ui/drawer/init.lua"
      via: "capable adapters expose schema list/object payloads; drawer chooses lazy root only for capable lazy connections"
      pattern: "StructureForSchema"
    - from: "lua/dbee/lsp/server.lua"
      to: "lua/dbee/lsp/schema_cache.lua"
      via: "`schema.` completion and diagnostics consume the same scoped cache and fold strategy"
      pattern: "schema_filter_signature"
    - from: "Makefile"
      to: ".github/workflows/test.yml"
      via: "local `make perf-lsp` and blocking CI jobs both run UX13 then ARCH14 rollup gates against captured logs"
      pattern: "ARCH14_ROLLUP_LOG"
  </key_links>
</must_haves>

<constraints>
- Honor D-01..D-305. Do not edit prior CONTEXT files during execution.
- Scope is Phase 14 only: no background prefetch, no workspace presets, no regex filters, no loading timeout/cancel UX, no LSP hover/resolve/code-actions/symbols.
- Atomic commits are TDD-style green commits: implementation and tests land together; no red-test-only commits.
- Each task has one primary ownership slice and associated tests. When Go API compile boundaries require companion files, the task must keep the repo buildable and must not hide unrelated changes.
- Do not run live database integration tests unless explicitly requested. Adapter tests use query builders, fakes, or existing deterministic harnesses.
- New perf scenarios are advisory until the existing four-week >=95% promotion rule is satisfied.
- Do not duplicate Phase 9/10/11 perf infrastructure; extend existing DRAW01/LSP01/UX13 bootstrap and rollup patterns.
- `ARCH14_ALL_PASS=true` must be emitted by `ci/headless/check_arch14_rollup.lua`, not by a summary document or manual claim.
</constraints>

<interfaces>
Schema filter JSON:
```json
{
  "schema_filter": {
    "include": ["HR", "FIN%"],
    "exclude": ["HR_TEMP%"],
    "lazy_per_schema": true
  }
}
```

Normalized signature:
```text
schema-filter-v1|type=<connection-type>|fold=<fold-id>|lazy=<0|1>|include=<encoded-list>|exclude=<encoded-list>
```

Encoding rules:
```text
trim whitespace
drop empty entries before validation
reject explicit empty include
reject regex/metacharacter syntax outside SQL glob `%` and `_`
fold patterns with adapter fold strategy
sort include/exclude lexicographically after fold
length-prefix each normalized pattern as <byte-length>:<pattern>
empty exclude list = 0:
implicit all-schema include = *
```

Go capability surface:
```go
type SchemaFilterOptions struct {
    Include       []string
    Exclude       []string
    LazyPerSchema bool
    Signature     string
    FoldID        string
}

type StructureOptions struct {
    SchemaFilter *SchemaFilterOptions
}

type SchemaListDriver interface {
    ListSchemas() ([]*core.SchemaInfo, error)
}

type FilteredStructureDriver interface {
    StructureWithOptions(opts *core.StructureOptions) ([]*core.Structure, error)
}

type SchemaStructureDriver interface {
    StructureForSchema(schema string, opts *core.StructureOptions) ([]*core.Structure, error)
}
```

Compatibility contract:
```text
legacy Driver.Structure() remains unchanged
Connection.GetStructure(opts *core.StructureOptions) accepts handler-emitted options and dispatches to StructureWithOptions(opts) only when the driver implements FilteredStructureDriver
capable top-4 adapters receive the normalized filter through StructureOptions for full eager allowlist mode
StructureForSchema receives the same StructureOptions so excludes and signature/fold assertions are available
unsupported adapters keep Driver.Structure() and run legacy eager mode with Lua-side defense-in-depth filtering
```

Options authority contract:
```text
Handler:get_schema_filter(conn_id) returns the normalized StructureOptions-compatible shape for structure/object RPC calls
Lua RPC wrappers pass that exact options table into full-structure and per-schema object endpoints
Go RPC endpoints decode the passed options into *core.StructureOptions and do not rebuild options from raw ConnectionParams.schema_filter
fake driver tests assert folded include/exclude/signature/fold/lazy fields received by StructureWithOptions and StructureForSchema equal the handler-emitted options
```

Lua handler surfaces:
```lua
handler:get_schema_filter(conn_id)
handler:connection_list_schemas_singleflight({ conn_id, consumer, purpose, request_id?, caller_token?, callback? })
handler:connection_list_schemas_spec_async({ spec, request_id?, caller_token = "wizard", callback? })
handler:connection_get_schema_objects_singleflight({ conn_id, schema, consumer, request_id?, caller_token?, callback? })
```

Transient wizard discovery:
```text
add-flow discovery uses DbeeConnectionListSchemasSpec plus connection_list_schemas_spec_async(spec, callback)
the spec endpoint builds a temporary adapter connection from unsaved ConnectionParams, calls full-universe ListSchemas(), closes the adapter connection, and reports result/error to the wizard callback
the spec endpoint emits schemas_loaded with wizard caller_token/request_id metadata for the waiting wizard path only
the spec endpoint is strictly non-mutating per Phase 8 D-94: no source mutation, no active-connection change, no _struct_cache writes, no LSP rebootstrap/cache mutation, no root_epoch bump, no persisted file writes, and no event-bus invalidation
edit-flow discovery uses the persisted connection-id schema-list path, not the transient spec path
```

Schema-object backpressure:
```text
per-connection active schema-object RPC cap = 4 by default
per-connection queued distinct-schema cap = 32 by default
queue is generation-fenced by root_epoch + schema_filter_signature
same (conn_id, folded_schema, root_epoch) requests coalesce into one queued/in-flight entry with multiple waiters
drawer expansion priority > LSP schema-dot miss priority
when queue is full, admit drawer requests by dropping the oldest queued LSP request and notifying its waiter with error_kind = "queue_full"
never drop a queued drawer request to admit an LSP miss
if queue is full of drawer requests, reject the newest requester with error_kind = "queue_full"
epoch/filter supersession drops queued requests and notifies waiters with an explicit non-corrupt error_kind
```

Event payloads:
```lua
schemas_loaded = {
  conn_id = "...",
  request_id = 1,
  root_epoch = 7,
  caller_token = "drawer" | "lsp" | "wizard" | nil,
  schemas = { { name = "HR", folded_name = "HR" } },
  error = nil,
}

schema_objects_loaded = {
  conn_id = "...",
  request_id = 2,
  root_epoch = 7,
  caller_token = "drawer" | "lsp" | nil,
  schema = "HR",
  objects = { ... DBStructure children ... },
  error = nil,
}
```

Drawer partial cache additions:
```lua
_struct_cache.root_mode[conn_id] = "full" | "schemas_only" | "legacy_eager"
_struct_cache.root_loaded_schemas[conn_id][folded_schema] = true
_struct_cache.schema_branch_state[conn_id][folded_schema] = { loading = false, error = nil }
_struct_cache.root_filter_signature[conn_id] = "schema-filter-v1|..."
```

LSP completion contract:
```text
schema. cache hit -> table items, isIncomplete=false
schema. cold miss with async schema-object fetch queued -> empty items, isIncomplete=true
legacy adapter or unavailable async surface -> cache-only result, isIncomplete=false
filtered-out schema -> no completion suggestions; diagnostic path may emit Information hint on references
```
</interfaces>

<task_graph>
## Wave 1 - Foundation, Filter Contract, And Cache v3
- `14-01-01` extends runtime connection params/source persistence and requirement trace.
- `14-01-02` adds shared Lua schema-filter normalization, SQL-glob matching, and signature helpers.
- `14-01-03` bumps schema cache to v3 with partial-population fields and signature-aware migration.

## Wave 2 - Handler Middleware, Events, And Single-Flight
- `14-01-04` adds Go schema API surface, RPC option-bearing endpoint signatures, transient spec schema-list endpoint, remote manifest registration, and explicit schema events/endpoints.
- `14-01-05` adds Lua handler filter authority, passes handler-normalized `StructureOptions` into Go RPC calls, schema-list/schema-object single-flight registries, and per-connection schema-object backpressure.
- `14-01-06` adds handler/event stale-payload, epoch, reconnect, option round-trip, queue overflow, and capability tests.

## Wave 3 - Top-4 Adapter Implementations
- `14-01-07` implements Oracle `ListSchemas`, `StructureForSchema`, and filter pushdown.
- `14-01-08` implements Postgres `ListSchemas`, `StructureForSchema`, and filter pushdown.
- `14-01-09` implements MySQL `ListSchemas`, `StructureForSchema`, and filter pushdown.
- `14-01-10` implements SQL Server/MSSQL `ListSchemas`, `StructureForSchema`, and filter pushdown.
- `14-01-11` adds legacy eager capability matrix and non-top-4 fallback tests.

## Wave 4 - Drawer Mode-Aware Rendering
- `14-01-12` adds drawer partial root mode state and schema-only root rendering.
- `14-01-13` adds per-schema branch lazy load, row-local loading/error, retry, and chunked rendering.
- `14-01-14` preserves zero-RPC drawer filter under full, schemas-only, mixed-loaded, and legacy modes.
- `14-01-15` adds advisory drawer perf scenarios for schema-only root and schema branch expansion.

## Wave 5 - LSP Scope, Completion, Diagnostics, And Cache Invalidation
- `14-01-16` adds adapter-aware fold and partial schema/object indexes in `SchemaCache`.
- `14-01-17` wires LSP lifecycle to new schema events, invalidation, and v3 disk cache rules.
- `14-01-18` implements `schema.` async incomplete completion and no-sync fallback.
- `14-01-19` implements Information-level out-of-scope diagnostics.

## Wave 6 - Wizard, Rollup, CI Gate, And Final Verification
- `14-01-20` adds wizard schema filter edit/manual/clear/lazy-toggle persistence.
- `14-01-21` adds optional schema discovery, add default-no, edit default-yes, and probe failure fallback.
- `14-01-24` emits the adapter aggregate marker from adapter sub-sentinels.
- `14-01-25` emits the drawer aggregate marker from drawer semantic/perf sub-sentinels.
- `14-01-26` emits the LSP aggregate marker from LSP semantic/perf sub-sentinels.
- `14-01-27` emits the wizard aggregate marker from wizard sub-sentinels.
- `14-01-22` adds fail-closed ARCH14 rollup script, Makefile wiring, and blocking CI job.
- `14-01-23` performs final verification, docs/requirements alignment, and smoke gate integration.

Dependency DAG:
```text
14-01-01 -> 14-01-02 -> 14-01-03
14-01-01 -> 14-01-04 -> 14-01-05 -> 14-01-06
14-01-02,14-01-04,14-01-05 -> 14-01-07,14-01-08,14-01-09,14-01-10
14-01-07,14-01-08,14-01-09,14-01-10 -> 14-01-11
14-01-03,14-01-05,14-01-11 -> 14-01-12 -> 14-01-13 -> 14-01-14 -> 14-01-15
14-01-03,14-01-05,14-01-11 -> 14-01-16 -> 14-01-17 -> 14-01-18 -> 14-01-19
14-01-01,14-01-02,14-01-04,14-01-11 -> 14-01-20 -> 14-01-21
14-01-11 -> 14-01-24
14-01-14,14-01-15 -> 14-01-25
14-01-18,14-01-19 -> 14-01-26
14-01-20,14-01-21 -> 14-01-27
14-01-06,14-01-24,14-01-25,14-01-26,14-01-27 -> 14-01-22 -> 14-01-23
```
</task_graph>

<measurement_protocol>
Phase 14 reuses existing Phase 9/10/11 measurement infrastructure. No new timing runner is introduced.

Drawer advisory scenarios added to `ci/headless/check_drawer_perf.lua`:
- `SCHEMA_ONLY_ROOT_100` - expand a lazy-capable connection with 100 schema rows and zero object rows fetched.
- `SCHEMA_ONLY_ROOT_1000` - expand a lazy-capable connection with 1000 schema rows and zero object rows fetched.
- `SCHEMA_ONLY_ROOT_10000` - expand a lazy-capable connection with 10000 schema rows and zero object rows fetched.
- `SCHEMA_BRANCH_LAZY_1000_OBJECTS` - expand one schema branch with 1000 table-like objects using the row-local async object path.
- `DRAWER_FILTER_SCOPED_10`, `DRAWER_FILTER_SCOPED_100`, `DRAWER_FILTER_SCOPED_1000`, and `DRAWER_FILTER_SCOPED_10000` - open/apply drawer filter over scoped schema corpora without RPC.
- `DRAWER_FILTER_MIXED_VISIBLE_AND_LAZY` - filter while some schema branches are loaded and others remain unloaded lazy branches.

Measurement rules:
- Root scenarios time drawer materialization after a deterministic `schemas_loaded` payload; they must not include Go/database time.
- Branch scenario times schema branch materialization after deterministic `schema_objects_loaded` payload; it must validate chunked rendering and load-more behavior.
- Filter scenarios time filter-open corpus capture and filter-apply over deterministic visible/cached rows; they must validate zero RPC and emit heap/allocation counters.
- Root, branch, and filter scenarios are advisory and emit DRAW01-style median/p95/heap markers plus `ARCH14_SCHEMA_ONLY_ROOT_FAST=true`, `ARCH14_SCHEMA_BRANCH_LAZY_OK=true`, and `ARCH14_PERF_DRAWER_FILTER_SCOPED_OK=true|unfrozen|false` when semantic and timing sentinels pass.
- `DRAW01_REAL_NUI_PERF_ALL_PASS=true|unfrozen` remains accepted by rollups; `false` fails `ARCH14_ALL_PASS`.
- LSP `schema.` behavior is verified semantically and with no-sync counters in `ci/headless/check_lsp_schema_filter_lazy.lua`; Phase 14 also adds advisory ARCH14 LSP perf scenarios without changing the LSP01 scenario count.

LSP advisory scenarios added to `ci/headless/check_lsp_perf.lua`:
- `LSP_SCHEMA_DOT_COMPLETION_HIT` - schema table-list cache hit returns table items and `isIncomplete=false`.
- `LSP_SCHEMA_DOT_COMPLETION_MISS_ASYNC` - cold active schema miss returns promptly with `isIncomplete=true` and queues at most one schema-object request.
- `LSP_SCHEMA_DOT_COMPLETION_DEDUPE` - duplicate misses for one schema share one request.
- `LSP_SCHEMA_DOT_COMPLETION_WARM` - warm retry after schema-object payload returns table labels and `isIncomplete=false`.
- `LSP_SCHEMA_DOT_FILTERED_OUT` - filtered-out schema classification returns no suggestions without metadata fetch.

LSP perf markers:
- `ARCH14_PERF_LSP_SCHEMA_DOT_OK=true|unfrozen|false`
- `ARCH14_LSP_PERF_STATUS=unfrozen|publishable|false`
- `ARCH14_PERF_DRAWER_FILTER_SCOPED_OK=true|unfrozen|false`
</measurement_protocol>

<tasks>
  <task id="14-01-01" type="feat" wave="1" commit="feat(14-01-01): persist schema filter params">
    <depends_on>Phase 13 shipped.</depends_on>
    <files>dbee/core/connection_params.go; dbee/endpoints.go; dbee/handler/marshal.go; lua/dbee/sources.lua; lua/dbee/doc.lua; lua/dbee/handler/init.lua; .planning/REQUIREMENTS.md; ci/headless/check_schema_filter.lua</files>
    <read_first>
      - dbee/core/connection_params.go
      - dbee/endpoints.go
      - dbee/handler/marshal.go
      - lua/dbee/sources.lua
      - lua/dbee/doc.lua
      - lua/dbee/handler/init.lua
      - .planning/REQUIREMENTS.md
      - .planning/phases/14-enterprise-db-architecture/14-CONTEXT.md
    </read_first>
    <action>
      Add the persisted/runtime `schema_filter` shape to Go `ConnectionParams`, Lua source loading, and Lua public type docs.
      Extend Go RPC decode/encode and msgpack marshal boundaries so `DbeeCreateConnection`, `DbeeConnectionTestSpec`, `DbeeGetConnections`, `DbeeConnectionGetParams`, `WrapConnection`, and `WrapConnectionParams` all preserve `schema_filter`.
      Extend Lua handler connection snapshot/copy/bootstrap/source-reload paths so runtime state carries `schema_filter` to `Handler:get_schema_filter(conn_id)`.
      Preserve additive raw JSON fields and existing id/name/type/url behavior.
      Expand and marshal `schema_filter` losslessly without expanding user pattern text.
      Keep absent filter equal to all schemas and `lazy_per_schema=false`.
      Reject explicit `include=[]` in the source update path before save.
      Update `DBEE-ARCH-01` trace text only if the placeholder does not already name schema allowlist plus lazy loading.
      Add persistence/load tests that cover missing filter, include/exclude round-trip, empty include rejection, clear-filter absence, and lazy flag default false.
    </action>
    <acceptance_criteria>
      - `rg -n "SchemaFilter" dbee/core/connection_params.go lua/dbee/doc.lua`
      - `rg -n "schema_filter" dbee/endpoints.go dbee/handler/marshal.go lua/dbee/handler/init.lua`
      - `rg -n "schema_filter" lua/dbee/sources.lua ci/headless/check_schema_filter.lua`
      - `rg -n "ARCH14_SCHEMA_FILTER_PERSISTED=true" ci/headless/check_schema_filter.lua`
      - `rg -n "ARCH14_SCHEMA_FILTER_RPC_ROUNDTRIP_OK=true" ci/headless/check_schema_filter.lua`
      - `rg -n "ARCH14_LAZY_PER_SCHEMA_FLAG_GATED=true" ci/headless/check_schema_filter.lua`
    </acceptance_criteria>
    <d_trace>D-224,D-227,D-228,D-229,D-230,D-231,D-232,D-233,D-234,D-235,D-298,D-305</d_trace>
  </task>

  <task id="14-01-02" type="feat" wave="1" commit="feat(14-01-02): normalize schema filters">
    <depends_on>14-01-01</depends_on>
    <files>lua/dbee/schema_filter.lua; ci/headless/check_schema_filter.lua</files>
    <read_first>
      - lua/dbee/lsp/schema_cache.lua
      - .planning/phases/14-enterprise-db-architecture/14-CONTEXT.md
    </read_first>
    <action>
      Add a shared Lua helper module for schema-filter validation, adapter fold selection, SQL-glob matching, include-then-exclude evaluation, deterministic signature construction, and capability-safe normalized filter objects.
      Implement the exact signature normalization and string format from D-242/D-243.
      Reject regex/metacharacter inputs at validation time while allowing `%` and `_`.
      Treat absent filter and missing include as the same implicit all-schema/full-mode representation.
      Add focused tests for exact matching, `%`, `_`, exclude precedence, case folding by adapter type, length-prefix encoding, sorted signature stability, empty exclude, implicit all include, and invalid pattern rejection.
    </action>
    <acceptance_criteria>
      - `test -f lua/dbee/schema_filter.lua`
      - `rg -n "schema-filter-v1" lua/dbee/schema_filter.lua ci/headless/check_schema_filter.lua`
      - `rg -n "ARCH14_SCHEMA_FILTER_MATCHING_OK=true" ci/headless/check_schema_filter.lua`
      - `rg -n "ARCH14_SCHEMA_FILTER_SIGNATURE_STABLE=true" ci/headless/check_schema_filter.lua`
      - `rg -n "ARCH14_SCHEMA_FILTER_INVALID_PATTERN_REJECTED=true" ci/headless/check_schema_filter.lua`
    </acceptance_criteria>
    <d_trace>D-236,D-237,D-238,D-239,D-240,D-241,D-242,D-243,D-244,D-298</d_trace>
  </task>

  <task id="14-01-03" type="feat" wave="1" commit="feat(14-01-03): migrate schema cache to version 3">
    <depends_on>14-01-01,14-01-02</depends_on>
    <files>lua/dbee/lsp/schema_cache.lua; ci/headless/check_lsp_disk_cache_safety.lua</files>
    <read_first>
      - lua/dbee/lsp/schema_cache.lua
      - ci/headless/check_lsp_disk_cache_safety.lua
      - lua/dbee/schema_filter.lua
      - .planning/phases/13-ux-regression-batch/13-CONTEXT.md
    </read_first>
    <action>
      Bump `SCHEMA_CACHE_VERSION` to 3.
      Add v3 schema index fields: `schema_filter_signature`, root mode/lazy mode state, schema list, per-schema object-loaded state, and table/object indexes for loaded active schemas.
      Load v2 caches through a known migration path and preserve Phase 13 missing-version true-corruption distinction.
      Treat signature mismatch as silent known scope migration: delete/regenerate without WARN.
      Preserve WARN for invalid JSON, malformed v3 fields, unsupported future versions, and unrecognizable shapes.
      Add strict filter-change deletion for schema index plus all per-table column files for that connection.
      Make filter-change column-file deletion generation-fenced and bounded: delete at most 100 files synchronously, drain the remainder in scheduled/deferred chunks, and no-op stale chunks when the filter signature or root epoch changes again.
      Expose test stats for `total_files_to_delete`, `sync_deleted_count`, and `deferred_drain_count`.
      Assert no disk scan/prune occurs from completion request path.
    </action>
    <acceptance_criteria>
      - `rg -n "SCHEMA_CACHE_VERSION = 3" lua/dbee/lsp/schema_cache.lua`
      - `rg -n "schema_filter_signature" lua/dbee/lsp/schema_cache.lua ci/headless/check_lsp_disk_cache_safety.lua`
      - `rg -n "ARCH14_CACHE_V3_MIGRATION_OK=true" ci/headless/check_lsp_disk_cache_safety.lua`
      - `rg -n "ARCH14_FILTER_CHANGE_INVALIDATES=true" ci/headless/check_lsp_disk_cache_safety.lua`
      - `rg -n "ARCH14_FILTER_CHANGE_CACHE_DELETION_BOUNDED=true" ci/headless/check_lsp_disk_cache_safety.lua`
      - `rg -n "ARCH14_CACHE_TRUE_CORRUPTION_WARN_RETAINED=true" ci/headless/check_lsp_disk_cache_safety.lua`
    </acceptance_criteria>
    <d_trace>D-287,D-288,D-289,D-290,D-291,D-292,D-303</d_trace>
  </task>

  <task id="14-01-04" type="feat" wave="2" commit="feat(14-01-04): add schema metadata rpc events">
    <depends_on>14-01-01</depends_on>
    <files>dbee/core/connection.go; dbee/core/types.go; dbee/handler/handler.go; dbee/handler/event_bus.go; dbee/endpoints.go; lua/dbee/api/__register.lua; ci/headless/check_handler_schema_filter.lua</files>
    <read_first>
      - dbee/core/connection.go
      - dbee/core/types.go
      - dbee/handler/handler.go
      - dbee/handler/event_bus.go
      - dbee/endpoints.go
      - lua/dbee/api/__register.lua
      - .planning/phases/14-enterprise-db-architecture/14-CONTEXT.md
    </read_first>
    <action>
      Add optional Go driver capability interfaces for schema listing and per-schema structure.
      Define `SchemaFilterOptions` and `StructureOptions` in Go so normalized include/exclude/lazy/signature/fold metadata can cross from Lua handler RPC calls into adapter metadata calls.
      Define compatibility-preserving optional interfaces: legacy `Driver.Structure()` remains unchanged, top-4 capable adapters implement `FilteredStructureDriver.StructureWithOptions(opts)` and `SchemaStructureDriver.StructureForSchema(schema, opts)`.
      Update `Connection.GetStructure(opts *core.StructureOptions)` and schema-object paths to pass the decoded normalized scope to capable drivers and fall back to legacy `Driver.Structure()` when unsupported.
      Extend full-structure and per-schema object Go RPC endpoint signatures to accept `StructureOptions` from Lua. These endpoints must not rebuild options from raw `ConnectionParams.schema_filter`.
      Add schema info payload types that preserve display labels and normalized identity fields.
      Add Go endpoints and async handler methods for `ListSchemas` and `StructureForSchema`.
      Add `DbeeConnectionListSchemasSpec` for wizard add-flow discovery from unsaved `ConnectionParams`: build a temporary adapter connection, call full-universe `ListSchemas()`, close it, and return schemas/errors without touching sources, current connection, root epoch, drawer state, LSP state, disk cache, or event-bus invalidation.
      Regenerate or manually update `lua/dbee/api/__register.lua` so the new connection-id schema RPC functions and the transient spec discovery RPC function are registered in the Neovim remote manifest.
      Add `SchemasLoaded` and `SchemaObjectsLoaded` event serializers with `conn_id`, `request_id`, `root_epoch`, optional `caller_token`, payload, and `error`.
      Do not narrow or rename existing `StructureLoaded` and `StructureChildrenLoaded`.
      Add deterministic handler tests or Lua-headless endpoint fakes proving payload shape, event names, manifest registration, option payload forwarding through the endpoint boundary, and non-mutating transient spec discovery.
    </action>
    <acceptance_criteria>
      - `rg -n "ListSchemas|StructureForSchema" dbee/core dbee/handler dbee/endpoints.go`
      - `rg -n "StructureOptions|SchemaFilterOptions|FilteredStructureDriver|StructureWithOptions" dbee/core/connection.go dbee/core/types.go`
      - `rg -n "DbeeConnectionListSchemas|DbeeStructureForSchema|DbeeConnectionListSchemasSpec" lua/dbee/api/__register.lua`
      - `nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "lua assert(vim.fn.exists('*DbeeConnectionListSchemas') == 2); assert(vim.fn.exists('*DbeeStructureForSchema') == 2); assert(vim.fn.exists('*DbeeConnectionListSchemasSpec') == 2); vim.cmd('qa')"`
      - `rg -n "schemas_loaded|schema_objects_loaded" dbee/handler/event_bus.go ci/headless/check_handler_schema_filter.lua`
      - `rg -n "ARCH14_SCHEMA_EVENTS_SHAPED=true" ci/headless/check_handler_schema_filter.lua`
      - `rg -n "ARCH14_FILTERED_STRUCTURE_API_OK=true" ci/headless/check_handler_schema_filter.lua`
      - `rg -n "ARCH14_RPC_MANIFEST_REGISTERED=true" ci/headless/check_handler_schema_filter.lua`
      - `rg -n "ARCH14_WIZARD_ADD_DISCOVERY_NON_MUTATING=true" ci/headless/check_handler_schema_filter.lua ci/headless/check_connection_wizard.lua`
      - `rg -n "ARCH14_LEGACY_FULL_STRUCTURE_COMPAT=true" ci/headless/check_handler_schema_filter.lua`
    </acceptance_criteria>
    <d_trace>D-251,D-252,D-253,D-254,D-255,D-256,D-257,D-258,D-300</d_trace>
  </task>

  <task id="14-01-05" type="feat" wave="2" commit="feat(14-01-05): add schema metadata singleflight">
    <depends_on>14-01-02,14-01-04</depends_on>
    <files>lua/dbee/handler/init.lua; ci/headless/check_handler_schema_filter.lua</files>
    <read_first>
      - lua/dbee/handler/init.lua
      - lua/dbee/schema_filter.lua
      - .planning/phases/07-connection-only-drawer/07-CONTEXT.md
      - .planning/phases/14-enterprise-db-architecture/14-CONTEXT.md
    </read_first>
    <action>
      Add `Handler:get_schema_filter(conn_id)` as the single Lua read point for normalized schema scope.
      Return a normalized `StructureOptions`-compatible table from `Handler:get_schema_filter(conn_id)` for structure/object RPC calls; no downstream caller may pass raw `ConnectionParams.schema_filter` to Go.
      Add separate schema-list and schema-object single-flight registries without mutating the existing full-tree registry.
      Key schema-list flights by `(conn_id, authoritative_root_epoch, purpose)`.
      Key schema-object flights by `(conn_id, folded_schema, authoritative_root_epoch)`.
      Add a per-connection schema-object metadata limiter: default max 4 active schema-object RPCs, max 32 queued distinct schemas, drawer priority ahead of LSP priority, same-key waiter coalescing, and generation fencing by root epoch plus schema filter signature.
      When the queue is full, drop the oldest queued low-priority LSP miss to admit a drawer request and notify the dropped waiter with `error_kind = "queue_full"`; never drop a queued drawer request for an LSP miss; if the queue is full of drawer requests, reject the newest requester with `error_kind = "queue_full"`.
      Ensure the full-structure RPC and schema-object RPC call sites pass options from `Handler:get_schema_filter(conn_id)` exactly as emitted, not from raw connection params.
      Fan out success/error to waiters, drop flights on completion, supersede old epochs, clean up consumer teardown, and migrate flights across same-semantic reconnect rewrites.
      Migrate schema-list/schema-object/full-tree flights across reconnect only when connection type, normalized `schema_filter_signature`, fold rule, and `lazy_per_schema` capability identity all match. Otherwise supersede/drop schema metadata flights with explicit `error_kind = "filter_changed"` or `error_kind = "reconnect_migration_dropped"`.
      Ensure filter changes bump authoritative root epoch exactly once and clear full/schema metadata flights plus drawer/LSP/disk consumers through existing invalidation channels.
    </action>
    <acceptance_criteria>
      - `rg -n "get_schema_filter" lua/dbee/handler/init.lua`
      - `rg -n "connection_list_schemas_singleflight|connection_get_schema_objects_singleflight" lua/dbee/handler/init.lua`
      - `rg -n "ARCH14_SCHEMA_LIST_SINGLEFLIGHT_OK=true" ci/headless/check_handler_schema_filter.lua`
      - `rg -n "ARCH14_SCHEMA_OBJECT_SINGLEFLIGHT_OK=true" ci/headless/check_handler_schema_filter.lua`
      - `rg -n "ARCH14_SCHEMA_OBJECT_BACKPRESSURE_OK=true" ci/headless/check_handler_schema_filter.lua`
      - `rg -n "ARCH14_SCHEMA_OBJECT_QUEUE_BOUNDED=true" ci/headless/check_handler_schema_filter.lua`
      - `rg -n "ARCH14_OPTIONS_LUA_GO_ROUNDTRIP_OK=true" ci/headless/check_handler_schema_filter.lua`
      - `rg -n "ARCH14_FILTER_CHANGE_EPOCH_SINGLE_BUMP=true" ci/headless/check_handler_schema_filter.lua`
      - `rg -n "ARCH14_RECONNECT_FILTER_SIGNATURE_MIGRATION_OK=true" ci/headless/check_handler_schema_filter.lua`
    </acceptance_criteria>
    <d_trace>D-245,D-259,D-260,D-261,D-262,D-263,D-264,D-265,D-300</d_trace>
  </task>

  <task id="14-01-06" type="test" wave="2" commit="test(14-01-06): cover schema metadata handler races">
    <depends_on>14-01-04,14-01-05</depends_on>
    <files>ci/headless/check_handler_schema_filter.lua</files>
    <read_first>
      - lua/dbee/handler/init.lua
      - dbee/handler/event_bus.go
      - .planning/phases/07-connection-only-drawer/07-CONTEXT.md
    </read_first>
    <action>
      Complete handler/event tests for schema-list and schema-object success, error, dedupe, superseded epoch cleanup, stale payload drops, teardown cleanup, and reconnect alias migration.
      Simulate 100 simultaneous schema-object requests across distinct schemas and assert max active RPC count never exceeds the configured per-connection cap, max queued distinct schemas never exceeds 32, drawer-priority requests are dispatched before queued LSP requests, oldest LSP misses are dropped first under overflow, queued drawer requests are preserved, all-drawer overflow returns `error_kind = "queue_full"` to the newest requester, same-key requests coalesce into additional waiters, and queued requests are dropped on epoch/filter supersession.
      Add fake driver endpoint tests proving folded include/exclude/signature/fold/lazy fields captured by Go-side `StructureWithOptions` and `StructureForSchema` are identical to the options emitted by `Handler:get_schema_filter(conn_id)`.
      Test reconnect migration in two cases: same normalized filter signature migrates flights; edited filter signature supersedes flights and prevents stale schema data from landing.
      Assert `structure_children_loaded` still carries only column payloads and is not used for schema object lists.
      Assert filter-change invalidation clears all three metadata flight families and preserves Phase 7 single-bump semantics.
      Emit an aggregate handler marker.
    </action>
    <acceptance_criteria>
      - `rg -n "ARCH14_HANDLER_SCHEMA_EVENTS_ALL_PASS=true" ci/headless/check_handler_schema_filter.lua`
      - `rg -n "ARCH14_SCHEMA_FLIGHT_SUPERSEDED_OK=true" ci/headless/check_handler_schema_filter.lua`
      - `rg -n "ARCH14_SCHEMA_RECONNECT_STALE_DROP_OK=true" ci/headless/check_handler_schema_filter.lua`
      - `rg -n "ARCH14_SCHEMA_OBJECT_BACKPRESSURE_OK=true" ci/headless/check_handler_schema_filter.lua`
      - `rg -n "ARCH14_SCHEMA_OBJECT_QUEUE_BOUNDED=true" ci/headless/check_handler_schema_filter.lua`
      - `rg -n "ARCH14_OPTIONS_LUA_GO_ROUNDTRIP_OK=true" ci/headless/check_handler_schema_filter.lua`
      - `rg -n "ARCH14_RECONNECT_FILTER_SIGNATURE_MIGRATION_OK=true" ci/headless/check_handler_schema_filter.lua`
      - `rg -n "ARCH14_STRUCTURE_CHILDREN_COLUMN_ONLY_PRESERVED=true" ci/headless/check_handler_schema_filter.lua`
    </acceptance_criteria>
    <d_trace>D-251,D-254,D-260,D-261,D-262,D-263,D-264,D-265,D-300</d_trace>
  </task>

  <task id="14-01-07" type="feat" wave="3" commit="feat(14-01-07): add oracle schema lazy metadata">
    <depends_on>14-01-02,14-01-04</depends_on>
    <files>dbee/adapters/oracle_driver.go; ci/headless/check_adapter_schema_filter.lua</files>
    <read_first>
      - dbee/adapters/oracle_driver.go
      - dbee/adapters/oracle.go
      - .planning/phases/14-enterprise-db-architecture/14-CONTEXT.md
    </read_first>
    <action>
      Implement Oracle `ListSchemas`, `StructureForSchema`, and filter-aware full `Structure()` query paths.
      Implement `StructureWithOptions(opts)` and `StructureForSchema(schema, opts)` so include/exclude SQL-glob filters are pushed into Oracle metadata SQL before rows are scanned/grouped.
      Preserve current `oracleGroupedStructure` semantics for tables, external tables, views, materialized views, procedures, and functions.
      Use safe binds or driver-appropriate quoting for filter values; no direct user pattern interpolation.
      Add deterministic adapter tests that inspect query generation/grouping without requiring a live Oracle DB. Tests must prove every relevant Oracle metadata source/UNION arm applies owner predicates or LIKE patterns, excluded schemas are not scanned/grouped, and a 100-schema fixture filtered to 5 emits lower cardinality than the full-catalog path.
    </action>
    <acceptance_criteria>
      - `rg -n "ListSchemas|StructureForSchema" dbee/adapters/oracle_driver.go`
      - `rg -n "ARCH14_ORACLE_SCHEMA_DISCOVERY_OK=true" ci/headless/check_adapter_schema_filter.lua`
      - `rg -n "ARCH14_ORACLE_SCHEMA_OBJECTS_OK=true" ci/headless/check_adapter_schema_filter.lua`
      - `rg -n "ARCH14_ORACLE_FILTER_BIND_SAFE=true" ci/headless/check_adapter_schema_filter.lua`
      - `rg -n "ARCH14_ADAPTER_ORACLE_PUSHDOWN_OK=true" ci/headless/check_adapter_schema_filter.lua`
    </acceptance_criteria>
    <d_trace>D-246,D-249,D-250,D-255,D-257,D-293,D-297,D-304</d_trace>
  </task>

  <task id="14-01-08" type="feat" wave="3" commit="feat(14-01-08): add postgres schema lazy metadata">
    <depends_on>14-01-02,14-01-04</depends_on>
    <files>dbee/adapters/postgres_driver.go; ci/headless/check_adapter_schema_filter.lua</files>
    <read_first>
      - dbee/adapters/postgres_driver.go
      - dbee/adapters/postgres.go
      - .planning/phases/14-enterprise-db-architecture/14-CONTEXT.md
    </read_first>
    <action>
      Implement Postgres `ListSchemas`, `StructureForSchema`, and filter-aware full `Structure()` query paths.
      Implement `StructureWithOptions(opts)` and `StructureForSchema(schema, opts)` so include/exclude SQL-glob filters are pushed into Postgres metadata SQL before rows are scanned/grouped.
      Preserve current table/view/materialized-view materialization semantics.
      Use safe parameter binding for schema filters where supported.
      Add deterministic adapter tests for lower-case folding, materialized views, and safe filter query generation. Tests must prove schema predicates or LIKE patterns appear in every relevant information_schema/pg_matviews branch, excluded schemas are not scanned/grouped, and a 100-schema fixture filtered to 5 emits lower cardinality than the full-catalog path.
    </action>
    <acceptance_criteria>
      - `rg -n "ListSchemas|StructureForSchema" dbee/adapters/postgres_driver.go`
      - `rg -n "ARCH14_POSTGRES_SCHEMA_DISCOVERY_OK=true" ci/headless/check_adapter_schema_filter.lua`
      - `rg -n "ARCH14_POSTGRES_SCHEMA_OBJECTS_OK=true" ci/headless/check_adapter_schema_filter.lua`
      - `rg -n "ARCH14_POSTGRES_FILTER_BIND_SAFE=true" ci/headless/check_adapter_schema_filter.lua`
      - `rg -n "ARCH14_ADAPTER_POSTGRES_PUSHDOWN_OK=true" ci/headless/check_adapter_schema_filter.lua`
    </acceptance_criteria>
    <d_trace>D-246,D-249,D-250,D-255,D-257,D-294,D-297,D-304</d_trace>
  </task>

  <task id="14-01-09" type="feat" wave="3" commit="feat(14-01-09): add mysql schema lazy metadata">
    <depends_on>14-01-02,14-01-04</depends_on>
    <files>dbee/adapters/mysql_driver.go; ci/headless/check_adapter_schema_filter.lua</files>
    <read_first>
      - dbee/adapters/mysql_driver.go
      - dbee/adapters/mysql.go
      - .planning/phases/14-enterprise-db-architecture/14-CONTEXT.md
    </read_first>
    <action>
      Implement MySQL `ListSchemas`, scoped table fetch from `information_schema.tables`, and filter-aware full `Structure()` query paths.
      Implement `StructureWithOptions(opts)` and `StructureForSchema(schema, opts)` so include/exclude SQL-glob filters are pushed into MySQL metadata SQL before rows are scanned/grouped.
      Preserve current table-only structure behavior unless the existing semantics already safely include views.
      Use safe parameter binding or driver-safe escaping for schema filters.
      Add deterministic adapter tests for MySQL schema/table semantics and safe filter query generation. Tests must prove schema predicates or LIKE patterns appear in every relevant `information_schema.tables` query, excluded schemas are not scanned/grouped, and a 100-schema fixture filtered to 5 emits lower cardinality than the full-catalog path.
    </action>
    <acceptance_criteria>
      - `rg -n "ListSchemas|StructureForSchema" dbee/adapters/mysql_driver.go`
      - `rg -n "ARCH14_MYSQL_SCHEMA_DISCOVERY_OK=true" ci/headless/check_adapter_schema_filter.lua`
      - `rg -n "ARCH14_MYSQL_SCHEMA_OBJECTS_OK=true" ci/headless/check_adapter_schema_filter.lua`
      - `rg -n "ARCH14_MYSQL_FILTER_BIND_SAFE=true" ci/headless/check_adapter_schema_filter.lua`
      - `rg -n "ARCH14_ADAPTER_MYSQL_PUSHDOWN_OK=true" ci/headless/check_adapter_schema_filter.lua`
    </acceptance_criteria>
    <d_trace>D-246,D-249,D-250,D-255,D-257,D-295,D-297,D-304</d_trace>
  </task>

  <task id="14-01-10" type="feat" wave="3" commit="feat(14-01-10): add sqlserver schema lazy metadata">
    <depends_on>14-01-02,14-01-04</depends_on>
    <files>dbee/adapters/sqlserver_driver.go; ci/headless/check_adapter_schema_filter.lua</files>
    <read_first>
      - dbee/adapters/sqlserver_driver.go
      - dbee/adapters/sqlserver.go
      - .planning/phases/14-enterprise-db-architecture/14-CONTEXT.md
    </read_first>
    <action>
      Implement SQL Server/MSSQL `ListSchemas`, `StructureForSchema`, and filter-aware full `Structure()` query paths through `INFORMATION_SCHEMA` or an equivalent existing-safe source.
      Implement `StructureWithOptions(opts)` and `StructureForSchema(schema, opts)` so include/exclude SQL-glob filters are pushed into SQL Server metadata SQL before rows are scanned/grouped.
      Preserve current table/view mapping behavior and `getPGStructureType` semantics.
      Use safe parameter binding or driver-safe escaping for schema filters.
      Add deterministic adapter tests for schema discovery, table/view mapping, collation-aware fallback, and safe filter query generation. Tests must prove schema predicates or LIKE patterns appear in every relevant `INFORMATION_SCHEMA` query, excluded schemas are not scanned/grouped, and a 100-schema fixture filtered to 5 emits lower cardinality than the full-catalog path.
    </action>
    <acceptance_criteria>
      - `rg -n "ListSchemas|StructureForSchema" dbee/adapters/sqlserver_driver.go`
      - `rg -n "ARCH14_MSSQL_SCHEMA_DISCOVERY_OK=true" ci/headless/check_adapter_schema_filter.lua`
      - `rg -n "ARCH14_MSSQL_SCHEMA_OBJECTS_OK=true" ci/headless/check_adapter_schema_filter.lua`
      - `rg -n "ARCH14_MSSQL_FILTER_BIND_SAFE=true" ci/headless/check_adapter_schema_filter.lua`
      - `rg -n "ARCH14_ADAPTER_MSSQL_PUSHDOWN_OK=true" ci/headless/check_adapter_schema_filter.lua`
    </acceptance_criteria>
    <d_trace>D-246,D-249,D-250,D-255,D-257,D-296,D-297,D-304</d_trace>
  </task>

  <task id="14-01-11" type="test" wave="3" commit="test(14-01-11): verify adapter lazy capability matrix">
    <depends_on>14-01-07,14-01-08,14-01-09,14-01-10</depends_on>
    <files>ci/headless/check_adapter_schema_filter.lua; lua/dbee/handler/init.lua</files>
    <read_first>
      - lua/dbee/handler/init.lua
      - dbee/adapters/oracle_driver.go
      - dbee/adapters/postgres_driver.go
      - dbee/adapters/mysql_driver.go
      - dbee/adapters/sqlserver_driver.go
    </read_first>
    <action>
      Add explicit capability detection exposed to Lua so wizard/drawer/LSP know whether a connection can use lazy per-schema mode.
      Verify top-4 adapters report list-schema and structure-for-schema support.
      Verify non-top-4 adapters remain legacy eager and can save allowlist metadata for Lua-side filtering without claiming lazy behavior.
    </action>
    <acceptance_criteria>
      - `rg -n "schema.*capab" lua/dbee/handler/init.lua ci/headless/check_adapter_schema_filter.lua`
      - `rg -n "ARCH14_TOP4_ADAPTER_CAPABILITIES_OK=true" ci/headless/check_adapter_schema_filter.lua`
      - `rg -n "ARCH14_LEGACY_EAGER_FALLBACK_OK=true" ci/headless/check_adapter_schema_filter.lua`
      - `rg -n "ARCH14_ADAPTER_ORACLE_PUSHDOWN_OK=true" ci/headless/check_adapter_schema_filter.lua`
      - `rg -n "ARCH14_ADAPTER_POSTGRES_PUSHDOWN_OK=true" ci/headless/check_adapter_schema_filter.lua`
      - `rg -n "ARCH14_ADAPTER_MYSQL_PUSHDOWN_OK=true" ci/headless/check_adapter_schema_filter.lua`
      - `rg -n "ARCH14_ADAPTER_MSSQL_PUSHDOWN_OK=true" ci/headless/check_adapter_schema_filter.lua`
    </acceptance_criteria>
    <d_trace>D-246,D-248,D-249,D-250,D-293,D-294,D-295,D-296,D-297,D-304</d_trace>
  </task>

  <task id="14-01-12" type="feat" wave="4" commit="feat(14-01-12): render lazy schema roots">
    <depends_on>14-01-03,14-01-05,14-01-11</depends_on>
    <files>lua/dbee/ui/drawer/init.lua; lua/dbee/ui/drawer/convert.lua; ci/headless/check_drawer_filter.lua</files>
    <read_first>
      - lua/dbee/ui/drawer/init.lua
      - lua/dbee/ui/drawer/convert.lua
      - lua/dbee/handler/init.lua
      - .planning/phases/06-structure-laziness-notes-picker/06-CONTEXT.md
      - .planning/phases/07-connection-only-drawer/07-CONTEXT.md
    </read_first>
    <action>
      Add additive `_struct_cache` partial-population fields for root mode, loaded schemas, schema branch loading/error state, and root filter signature.
      Keep Phase 7 connection-only root.
      In default/full mode, keep current eager structure expansion with active schema filtering before render.
      In capable `lazy_per_schema=true` mode, connection expansion calls schema-list single-flight, applies active filter, and renders collapsed schema rows without object children.
      Preserve existing full-tree `structure_loaded` consumer behavior for legacy/full mode.
      Add drawer tests for full mode filtering, schemas-only root, absent filter compatibility, and lazy flag gating.
    </action>
    <acceptance_criteria>
      - `rg -n "root_mode|root_loaded_schemas|root_filter_signature" lua/dbee/ui/drawer/init.lua`
      - `rg -n "ARCH14_SCHEMA_ONLY_ROOT_FAST=true" ci/headless/check_drawer_filter.lua`
      - `rg -n "ARCH14_LAZY_PER_SCHEMA_FLAG_GATED=true" ci/headless/check_drawer_filter.lua`
      - `rg -n "ARCH14_LEGACY_FULL_STRUCTURE_COMPAT=true" ci/headless/check_drawer_filter.lua`
    </acceptance_criteria>
    <d_trace>D-247,D-266,D-267,D-268,D-273,D-301</d_trace>
  </task>

  <task id="14-01-13" type="feat" wave="4" commit="feat(14-01-13): lazy load schema branches in drawer">
    <depends_on>14-01-12</depends_on>
    <files>lua/dbee/ui/drawer/init.lua; lua/dbee/ui/drawer/convert.lua; ci/headless/check_drawer_filter.lua</files>
    <read_first>
      - lua/dbee/ui/drawer/init.lua
      - lua/dbee/ui/drawer/convert.lua
      - lua/dbee/handler/init.lua
    </read_first>
    <action>
      On schema expansion in lazy mode, start per-schema object single-flight when branch state is missing or retry is requested.
      Render `convert.loading_node` under only that schema while the request is pending.
      Render `convert.error_node` under only that schema on failure and expose retry by re-expanding or existing nearest-ancestor reload path.
      Materialize loaded schema objects with existing structure node IDs, branch cache, chunking, and `Load more...` mechanics.
      Do not add global modal/error UX.
      Add tests for branch success, error, retry, stale payload drop, chunked materialization, and load-more preservation.
    </action>
    <acceptance_criteria>
      - `rg -n "schema_objects_loaded|connection_get_schema_objects_singleflight" lua/dbee/ui/drawer/init.lua`
      - `rg -n "loading_node|error_node" lua/dbee/ui/drawer/init.lua`
      - `rg -n "ARCH14_SCHEMA_BRANCH_LAZY_OK=true" ci/headless/check_drawer_filter.lua`
      - `rg -n "ARCH14_SCHEMA_BRANCH_ERROR_RETRY_OK=true" ci/headless/check_drawer_filter.lua`
      - `rg -n "ARCH14_SCHEMA_BRANCH_CHUNKING_OK=true" ci/headless/check_drawer_filter.lua`
    </acceptance_criteria>
    <d_trace>D-269,D-270,D-271,D-301</d_trace>
  </task>

  <task id="14-01-14" type="fix" wave="4" commit="fix(14-01-14): preserve zero rpc drawer filtering">
    <depends_on>14-01-12,14-01-13</depends_on>
    <files>lua/dbee/ui/drawer/model.lua; lua/dbee/ui/drawer/init.lua; ci/headless/check_drawer_filter.lua</files>
    <read_first>
      - lua/dbee/ui/drawer/model.lua
      - lua/dbee/ui/drawer/init.lua
      - .planning/phases/13-ux-regression-batch/13-CONTEXT.md
    </read_first>
    <action>
      Extend drawer search model to handle full roots, schemas-only roots, loaded schema branches, visible connection/schema rows, and legacy eager roots without triggering RPC.
      Preserve Phase 13 visible-row fallback on every filter start.
      Ensure unloaded schema object rows are not fetched while typing and false negatives are limited to unloaded objects by design.
      Add tests for filter matching active schemas, loaded objects, visible uncached schema rows, mixed loaded/unloaded branches, source badge/name fallback, exit restore, and zero handler calls.
    </action>
    <acceptance_criteria>
      - `rg -n "ARCH14_ZERO_RPC_DRAWER_FILTER_PRESERVED=true" ci/headless/check_drawer_filter.lua`
      - `rg -n "ARCH14_DRAWER_FILTER_LOADED_SCHEMA_BRANCH_OK=true" ci/headless/check_drawer_filter.lua`
      - `rg -n "UX13_DRAWER_FILTER_ALL_PASS=true" ci/headless/check_drawer_filter.lua`
      - `rg -n "connection_get_schema_objects" ci/headless/check_drawer_filter.lua`
    </acceptance_criteria>
    <d_trace>D-247,D-272,D-273,D-301,D-305</d_trace>
  </task>

  <task id="14-01-15" type="test" wave="4" commit="test(14-01-15): add lazy drawer perf scenarios">
    <depends_on>14-01-12,14-01-13,14-01-14</depends_on>
    <files>ci/headless/check_drawer_perf.lua; ci/headless/perf_thresholds.lua</files>
    <read_first>
      - ci/headless/check_drawer_perf.lua
      - ci/headless/perf_thresholds.lua
      - .planning/phases/09-real-nui-perf-harness/09-CONTEXT.md
    </read_first>
    <action>
      Add advisory scenarios `SCHEMA_ONLY_ROOT_100`, `SCHEMA_ONLY_ROOT_1000`, `SCHEMA_ONLY_ROOT_10000`, `SCHEMA_BRANCH_LAZY_1000_OBJECTS`, `DRAWER_FILTER_SCOPED_{10,100,1000,10000}`, and `DRAWER_FILTER_MIXED_VISIBLE_AND_LAZY`.
      Emit median, p95, heap/allocation, no-RPC, and scenario sentinel markers.
      Keep `DRAW01_REAL_NUI_PERF_ALL_PASS=true|unfrozen|false` semantics unchanged.
      Emit `ARCH14_PERF_DRAWER_FILTER_SCOPED_OK=true|unfrozen|false` and require `unfrozen|true` in the ARCH14 rollup.
      New thresholds start advisory/unfrozen; no blocking threshold promotion occurs in Phase 14 execution.
    </action>
    <acceptance_criteria>
      - `rg -n "SCHEMA_ONLY_ROOT_10000|SCHEMA_BRANCH_LAZY_1000_OBJECTS" ci/headless/check_drawer_perf.lua`
      - `rg -n "DRAWER_FILTER_SCOPED_10000|DRAWER_FILTER_MIXED_VISIBLE_AND_LAZY" ci/headless/check_drawer_perf.lua`
      - `rg -n "ARCH14_SCHEMA_ONLY_ROOT_FAST=true" ci/headless/check_drawer_perf.lua`
      - `rg -n "ARCH14_SCHEMA_BRANCH_LAZY_OK=true" ci/headless/check_drawer_perf.lua`
      - `rg -n "ARCH14_PERF_DRAWER_FILTER_SCOPED_OK" ci/headless/check_drawer_perf.lua`
      - `rg -n "DRAW01_REAL_NUI_PERF_ALL_PASS" ci/headless/check_drawer_perf.lua`
    </acceptance_criteria>
    <d_trace>D-268,D-269,D-271,D-272,D-301,D-305</d_trace>
  </task>

  <task id="14-01-16" type="feat" wave="5" commit="feat(14-01-16): index partial schema cache">
    <depends_on>14-01-02,14-01-03,14-01-11</depends_on>
    <files>lua/dbee/lsp/schema_cache.lua; ci/headless/check_lsp_schema_filter_lazy.lua</files>
    <read_first>
      - lua/dbee/lsp/schema_cache.lua
      - lua/dbee/schema_filter.lua
      - .planning/phases/11-lsp-optimization-correctness/11-CONTEXT.md
    </read_first>
    <action>
      Replace or wrap the current uppercase-only fold seam with adapter-aware fold strategies.
      Add APIs for active schema filter, schema list cache, per-schema object loaded state, partial table indexes, and filtered-out schema classification.
      Ensure cache hits for loaded active schema table lists return complete items and unloaded schema table lists report miss state without disk or sync handler work.
      Preserve Phase 11 indexes, LRU, disk load bounds, and column async state.
      Add tests for adapter fold behavior, active-scope inclusion/exclusion, duplicate table handling inside active scope, and unloaded schema state.
    </action>
    <acceptance_criteria>
      - `rg -n "fold.*oracle|fold.*postgres|schema_filter" lua/dbee/lsp/schema_cache.lua`
      - `rg -n "ARCH14_SCHEMA_CACHE_PARTIAL_INDEX_OK=true" ci/headless/check_lsp_schema_filter_lazy.lua`
      - `rg -n "ARCH14_SCHEMA_FILTER_DOWNSTREAM_ALL_PASS=true" ci/headless/check_lsp_schema_filter_lazy.lua`
      - `rg -n "LSP11_LRU_BOUND_HONORED=true" ci/headless/check_lsp_schema_filter_lazy.lua`
    </acceptance_criteria>
    <d_trace>D-239,D-240,D-247,D-276,D-279,D-288,D-292,D-302,D-303</d_trace>
  </task>

  <task id="14-01-17" type="feat" wave="5" commit="feat(14-01-17): wire lsp schema lazy lifecycle">
    <depends_on>14-01-05,14-01-16</depends_on>
    <files>lua/dbee/lsp/init.lua; lua/dbee/lsp/schema_cache.lua; ci/headless/check_lsp_schema_filter_lazy.lua</files>
    <read_first>
      - lua/dbee/lsp/init.lua
      - lua/dbee/lsp/schema_cache.lua
      - lua/dbee/handler/init.lua
    </read_first>
    <action>
      Subscribe the LSP lifecycle to `schemas_loaded`, `schema_objects_loaded`, and existing connection invalidation.
      Route schema-list and schema-object payloads into `SchemaCache` only when conn_id, root_epoch, and filter signature match.
      Cancel async schema-object chains on filter change, root epoch bump, source reload, and connection identity rewrite mismatch.
      Strictly clear disk cache generation when filter signature changes while preserving Phase 11/13 corrupt cache behavior. The clear path must use the bounded, generation-fenced deletion protocol from `14-01-03` and must never scan/delete unbounded files from completion or immediate invalidation paths.
      Add tests for stale payload drops, signature mismatch drops, async dedupe, reconnect path, and disk generation fencing.
    </action>
    <acceptance_criteria>
      - `rg -n "schemas_loaded|schema_objects_loaded" lua/dbee/lsp/init.lua`
      - `rg -n "ARCH14_LSP_SCHEMA_EVENT_WIRING_OK=true" ci/headless/check_lsp_schema_filter_lazy.lua`
      - `rg -n "ARCH14_FILTER_CHANGE_INVALIDATES=true" ci/headless/check_lsp_schema_filter_lazy.lua`
      - `rg -n "ARCH14_LSP_STALE_SCHEMA_PAYLOAD_DROPPED=true" ci/headless/check_lsp_schema_filter_lazy.lua`
      - `rg -n "ARCH14_FILTER_CHANGE_CACHE_DELETION_BOUNDED=true" ci/headless/check_lsp_schema_filter_lazy.lua ci/headless/check_lsp_disk_cache_safety.lua`
    </acceptance_criteria>
    <d_trace>D-263,D-264,D-265,D-274,D-276,D-287,D-289,D-291,D-302,D-303</d_trace>
  </task>

  <task id="14-01-18" type="feat" wave="5" commit="feat(14-01-18): complete schema dot asynchronously">
    <depends_on>14-01-16,14-01-17</depends_on>
    <files>lua/dbee/lsp/server.lua; lua/dbee/lsp/schema_cache.lua; ci/headless/check_lsp_schema_filter_lazy.lua; ci/headless/check_lsp_perf.lua; ci/headless/lsp_perf_thresholds.lua</files>
    <read_first>
      - lua/dbee/lsp/server.lua
      - lua/dbee/lsp/schema_cache.lua
      - .planning/phases/11-lsp-optimization-correctness/11-CONTEXT.md
    </read_first>
    <action>
      Extend completion parsing for `schema.` table-list requests.
      On active-scope cache hit, return table items with `isIncomplete=false`.
      On cold active-scope schema miss with async schema-object fetch queued, return empty items with `isIncomplete=true`.
      On legacy/unsupported async surface, return cache-only `isIncomplete=false` and do not call synchronous metadata APIs.
      Deduplicate identical schema misses by `(conn_id, folded_schema, root_epoch)`.
      Exclude filtered-out schemas from suggestions.
      Add semantic tests for first miss, warm retry, no sync fallback, filtered-out exclusion, unsupported adapter cache-only behavior, and stale async payload drop.
      Add advisory LSP perf scenarios for schema-dot cache hit, cold async miss, duplicate miss dedupe, warm retry, and filtered-out classification. Emit median/p95/allocation markers plus `ARCH14_PERF_LSP_SCHEMA_DOT_OK=true|unfrozen|false` and `ARCH14_LSP_PERF_STATUS=unfrozen|publishable|false`.
    </action>
    <acceptance_criteria>
      - `rg -n "schema.*isIncomplete|isIncomplete.*schema" lua/dbee/lsp/server.lua ci/headless/check_lsp_schema_filter_lazy.lua`
      - `rg -n "ARCH14_LSP_SCHEMA_DOT_INCOMPLETE_OK=true" ci/headless/check_lsp_schema_filter_lazy.lua`
      - `rg -n "ARCH14_LSP_SCHEMA_DOT_WARM_OK=true" ci/headless/check_lsp_schema_filter_lazy.lua`
      - `rg -n "ARCH14_LSP_SCHEMA_DOT_NO_SYNC_FETCH=true" ci/headless/check_lsp_schema_filter_lazy.lua`
      - `rg -n "LSP_SCHEMA_DOT_COMPLETION_MISS_ASYNC|LSP_SCHEMA_DOT_COMPLETION_HIT" ci/headless/check_lsp_perf.lua`
      - `rg -n "ARCH14_PERF_LSP_SCHEMA_DOT_OK|ARCH14_LSP_PERF_STATUS" ci/headless/check_lsp_perf.lua`
    </acceptance_criteria>
    <d_trace>D-274,D-275,D-276,D-279,D-302,D-305</d_trace>
  </task>

  <task id="14-01-19" type="feat" wave="5" commit="feat(14-01-19): hint filtered schema references">
    <depends_on>14-01-16,14-01-18</depends_on>
    <files>lua/dbee/lsp/server.lua; ci/headless/check_lsp_schema_filter_lazy.lua</files>
    <read_first>
      - lua/dbee/lsp/server.lua
      - lua/dbee/lsp/schema_cache.lua
      - ci/headless/check_lsp_diagnostics_correctness.lua
    </read_first>
    <action>
      Detect qualified references to schemas outside the active filter.
      Emit an Information-level diagnostic with exact message `Schema X is outside this connection's scope. Edit schema_filter to include.`
      Do not also emit an unknown-table warning for the same filtered-out reference.
      Lock and implement the three-state lazy diagnostic matrix: filtered-out qualified reference emits Information; active loaded schema with actually missing table emits current Warning; active but unloaded lazy schema emits no diagnostic and performs no sync metadata fetch.
      Add a diagnostic suppression check in diagnostics computation for active-but-unloaded schemas/tables.
      Use the existing `dbee/lsp` namespace and `vim.diagnostic.set` path.
      Preserve active-scope unknown-table warnings and Phase 11 schema-qualified diagnostics.
      Add tests for filtered-out schema, active loaded missing table, active unloaded schema with qualified and unqualified references, post-fetch present table, post-fetch missing table, unqualified duplicate behavior, source/namespace/severity, and diagnostics clearing.
    </action>
    <acceptance_criteria>
      - `rg -n "outside this connection.s scope" lua/dbee/lsp/server.lua ci/headless/check_lsp_schema_filter_lazy.lua`
      - `rg -n "vim.diagnostic.severity.INFO|severity.*INFO" lua/dbee/lsp/server.lua`
      - `rg -n "ARCH14_OUT_OF_SCOPE_HINT_OK=true" ci/headless/check_lsp_schema_filter_lazy.lua`
      - `rg -n "ARCH14_LSP_LAZY_UNLOADED_NO_FALSE_WARN=true" ci/headless/check_lsp_schema_filter_lazy.lua`
      - `rg -n "LSP11_DIAGNOSTIC_NAMESPACE_OK=true" ci/headless/check_lsp_schema_filter_lazy.lua`
    </acceptance_criteria>
    <d_trace>D-277,D-278,D-279,D-302,D-305</d_trace>
  </task>

  <task id="14-01-20" type="feat" wave="6" commit="feat(14-01-20): edit schema filter in wizard">
    <depends_on>14-01-01,14-01-02,14-01-11</depends_on>
    <files>lua/dbee/ui/connection_wizard/init.lua; ci/headless/check_connection_wizard.lua</files>
    <read_first>
      - lua/dbee/ui/connection_wizard/init.lua
      - lua/dbee/schema_filter.lua
      - .planning/phases/08-type-aware-connection-wizard/08-CONTEXT.md
      - .planning/phases/13-ux-regression-batch/13-CONTEXT.md
    </read_first>
    <action>
      Add schema-filter section to add/edit wizard while preserving Phase 8 flow and Phase 13 winhighlight plumbing.
      Support manual comma-separated include/exclude entry, clear-filter behavior, pre-populated edit values, and explicit lazy toggle.
      Disable or explain lazy toggle when adapter lacks Phase 14 lazy capability.
      Reject `include=[]` and invalid patterns with actionable validation text.
      Serialize only absent/all-schemas or valid locked shape; never persist `include=[]`.
      Preserve FileSource atomic writes, raw compatibility, password placeholder, ping-before-save, and add/edit flow shape.
    </action>
    <acceptance_criteria>
      - `rg -n "schema_filter|lazy_per_schema" lua/dbee/ui/connection_wizard/init.lua ci/headless/check_connection_wizard.lua`
      - `rg -n "ARCH14_WIZARD_SCHEMA_FILTER_EDIT_OK=true" ci/headless/check_connection_wizard.lua`
      - `rg -n "ARCH14_WIZARD_CLEAR_FILTER_OK=true" ci/headless/check_connection_wizard.lua`
      - `rg -n "UX13_WIZARD_ALL_PASS=true" ci/headless/check_connection_wizard.lua`
    </acceptance_criteria>
    <d_trace>D-280,D-281,D-283,D-284,D-285,D-286,D-299</d_trace>
  </task>

  <task id="14-01-21" type="feat" wave="6" commit="feat(14-01-21): discover schemas in wizard">
    <depends_on>14-01-04,14-01-20</depends_on>
    <files>lua/dbee/ui/connection_wizard/init.lua; lua/dbee/handler/init.lua; ci/headless/check_connection_wizard.lua</files>
    <read_first>
      - lua/dbee/ui/connection_wizard/init.lua
      - lua/dbee/handler/init.lua
      - ci/headless/check_connection_wizard.lua
      - .planning/phases/08-type-aware-connection-wizard/08-CONTEXT.md
    </read_first>
    <action>
      After add-flow `connection_test_spec` succeeds, offer `Discover schemas now?` default No.
      Add and use `connection_list_schemas_spec_async(spec, callback)` for add-flow discovery because no persisted `conn_id` exists yet.
      The add-flow spec path calls `DbeeConnectionListSchemasSpec`, uses full-universe `ListSchemas()`, closes its temporary adapter connection, and inherits Phase 8 D-94 non-mutating guarantees: it must not create/select/persist a connection, mutate any source state, touch `_struct_cache`, trigger LSP rebootstrap/cache mutation, bump root epoch, write persisted files, or emit event-bus invalidations.
      In edit flow, pre-populate current schema filter and offer discovery default Yes.
      Edit-flow discovery uses the persisted connection-id schema-list path, uses full-universe `ListSchemas`, and then preselects current filter entries.
      Probe failure does not block save and falls back to manual entry with visible warning/inline error.
      Add tests for add default-no fast path, add spec discovery success, add spec discovery failure fallback, add discovery not creating/selecting/persisting a connection, add discovery not mutating `_struct_cache` or LSP cache, edit default-yes path, edit discovery success, discovery failure fallback, manual save after failure, and lazy toggle capability messaging.
    </action>
    <acceptance_criteria>
      - `rg -n "Discover schemas now" lua/dbee/ui/connection_wizard/init.lua ci/headless/check_connection_wizard.lua`
      - `rg -n "connection_list_schemas_spec_async|DbeeConnectionListSchemasSpec" lua/dbee/handler/init.lua lua/dbee/ui/connection_wizard/init.lua ci/headless/check_connection_wizard.lua`
      - `rg -n "ARCH14_SCHEMA_DISCOVERY_MANUAL_FALLBACK=true" ci/headless/check_connection_wizard.lua`
      - `rg -n "ARCH14_WIZARD_ADD_DISCOVERY_NON_MUTATING=true" ci/headless/check_connection_wizard.lua`
      - `rg -n "ARCH14_WIZARD_ADD_DISCOVERY_DEFAULT_NO=true" ci/headless/check_connection_wizard.lua`
      - `rg -n "ARCH14_WIZARD_EDIT_DISCOVERY_DEFAULT_YES=true" ci/headless/check_connection_wizard.lua`
    </acceptance_criteria>
    <d_trace>D-255,D-256,D-280,D-281,D-282,D-283,D-285,D-286,D-299</d_trace>
  </task>

  <task id="14-01-24" type="test" wave="6" commit="test(14-01-24): aggregate arch14 adapter markers">
    <depends_on>14-01-11</depends_on>
    <files>ci/headless/check_adapter_schema_filter.lua</files>
    <read_first>
      - ci/headless/check_adapter_schema_filter.lua
      - .planning/phases/14-enterprise-db-architecture/14-CONTEXT.md
    </read_first>
    <action>
      Add the adapter harness aggregate. Emit `ARCH14_ADAPTER_ALL_PASS=true` only when all top-4 schema discovery, object fetch, bind-safety, SQL pushdown, cardinality, and legacy eager fallback sub-sentinels are true.
      Emit `ARCH14_ADAPTER_ALL_PASS=false` with failing submarker names on any missing/false sub-sentinel.
    </action>
    <acceptance_criteria>
      - `rg -n "ARCH14_ADAPTER_ALL_PASS" ci/headless/check_adapter_schema_filter.lua`
      - `rg -n "ARCH14_ADAPTER_ORACLE_PUSHDOWN_OK" ci/headless/check_adapter_schema_filter.lua`
      - `rg -n "ARCH14_ADAPTER_POSTGRES_PUSHDOWN_OK" ci/headless/check_adapter_schema_filter.lua`
      - `rg -n "ARCH14_ADAPTER_MYSQL_PUSHDOWN_OK" ci/headless/check_adapter_schema_filter.lua`
      - `rg -n "ARCH14_ADAPTER_MSSQL_PUSHDOWN_OK" ci/headless/check_adapter_schema_filter.lua`
    </acceptance_criteria>
    <d_trace>D-246,D-248,D-249,D-250,D-293,D-294,D-295,D-296,D-297,D-304,D-305</d_trace>
  </task>

  <task id="14-01-25" type="test" wave="6" commit="test(14-01-25): aggregate arch14 drawer markers">
    <depends_on>14-01-14, 14-01-15</depends_on>
    <files>ci/headless/check_drawer_filter.lua; ci/headless/check_drawer_perf.lua</files>
    <read_first>
      - ci/headless/check_drawer_filter.lua
      - ci/headless/check_drawer_perf.lua
    </read_first>
    <action>
      Add the drawer harness aggregate. Emit `ARCH14_DRAWER_ALL_PASS=true` only when root mode, schemas-only root, schema branch loading, error/retry, zero-RPC filter, mixed lazy/loaded filter, legacy fallback, and advisory drawer perf status sub-sentinels are true or unfrozen where allowed.
      Emit `ARCH14_DRAWER_ALL_PASS=false` with failing submarker names on any missing/false/unsupported sub-sentinel.
    </action>
    <acceptance_criteria>
      - `rg -n "ARCH14_DRAWER_ALL_PASS" ci/headless/check_drawer_filter.lua ci/headless/check_drawer_perf.lua`
      - `rg -n "ARCH14_ZERO_RPC_DRAWER_FILTER_PRESERVED" ci/headless/check_drawer_filter.lua`
      - `rg -n "ARCH14_PERF_DRAWER_FILTER_SCOPED_OK" ci/headless/check_drawer_perf.lua`
    </acceptance_criteria>
    <d_trace>D-266,D-267,D-268,D-269,D-270,D-271,D-272,D-273,D-301,D-305</d_trace>
  </task>

  <task id="14-01-26" type="test" wave="6" commit="test(14-01-26): aggregate arch14 lsp markers">
    <depends_on>14-01-18, 14-01-19</depends_on>
    <files>ci/headless/check_lsp_schema_filter_lazy.lua; ci/headless/check_lsp_perf.lua</files>
    <read_first>
      - ci/headless/check_lsp_schema_filter_lazy.lua
      - ci/headless/check_lsp_perf.lua
    </read_first>
    <action>
      Add the LSP harness aggregate. Emit `ARCH14_LSP_ALL_PASS=true` only when schema-dot hit/miss/warm/no-sync markers, downstream filter markers, active-unloaded diagnostic suppression, out-of-scope hint, namespace preservation, and advisory LSP perf status markers are true or unfrozen where allowed.
      Emit `ARCH14_LSP_ALL_PASS=false` with failing submarker names on any missing/false/unsupported sub-sentinel.
    </action>
    <acceptance_criteria>
      - `rg -n "ARCH14_LSP_ALL_PASS" ci/headless/check_lsp_schema_filter_lazy.lua ci/headless/check_lsp_perf.lua`
      - `rg -n "ARCH14_LSP_LAZY_UNLOADED_NO_FALSE_WARN" ci/headless/check_lsp_schema_filter_lazy.lua`
      - `rg -n "ARCH14_PERF_LSP_SCHEMA_DOT_OK" ci/headless/check_lsp_perf.lua`
    </acceptance_criteria>
    <d_trace>D-274,D-275,D-276,D-277,D-278,D-279,D-302,D-305</d_trace>
  </task>

  <task id="14-01-27" type="test" wave="6" commit="test(14-01-27): aggregate arch14 wizard markers">
    <depends_on>14-01-20, 14-01-21</depends_on>
    <files>ci/headless/check_connection_wizard.lua</files>
    <read_first>
      - ci/headless/check_connection_wizard.lua
    </read_first>
    <action>
      Add the wizard harness aggregate. Emit `ARCH14_WIZARD_ALL_PASS=true` only when schema-filter edit, clear-filter, add default-no discovery, edit default-yes discovery, manual fallback, lazy toggle, invalid pattern rejection, and preserved UX13 wizard sub-sentinels are true.
      Emit `ARCH14_WIZARD_ALL_PASS=false` with failing submarker names on any missing/false sub-sentinel.
    </action>
    <acceptance_criteria>
      - `rg -n "ARCH14_WIZARD_ALL_PASS" ci/headless/check_connection_wizard.lua`
      - `rg -n "ARCH14_WIZARD_ADD_DISCOVERY_DEFAULT_NO" ci/headless/check_connection_wizard.lua`
      - `rg -n "ARCH14_WIZARD_EDIT_DISCOVERY_DEFAULT_YES" ci/headless/check_connection_wizard.lua`
      - `rg -n "UX13_WIZARD_ALL_PASS" ci/headless/check_connection_wizard.lua`
    </acceptance_criteria>
    <d_trace>D-280,D-281,D-282,D-283,D-284,D-285,D-286,D-299,D-305</d_trace>
  </task>

  <task id="14-01-22" type="chore" wave="6" commit="chore(14-01-22): gate arch14 verification fail closed">
    <depends_on>14-01-06,14-01-24,14-01-25,14-01-26,14-01-27</depends_on>
    <files>ci/headless/check_arch14_rollup.lua; Makefile; .github/workflows/test.yml</files>
    <read_first>
      - ci/headless/check_ux13_rollup.lua
      - Makefile
      - .github/workflows/test.yml
      - .planning/phases/13-ux-regression-batch/13-SUMMARY.md
    </read_first>
    <action>
      Add `ci/headless/check_arch14_rollup.lua` as a fail-closed marker aggregator.
      The script reads `ARCH14_ROLLUP_LOG`, rejects missing markers, rejects unsupported values, accepts advisory rollups only when value is `true` or `unfrozen`, and emits `ARCH14_ALL_PASS=true` only after all required markers pass.
      Require `UX13_ALL_PASS=true`, all ARCH14 required submarkers, producer-owned aggregate markers (`ARCH14_DRAWER_ALL_PASS`, `ARCH14_LSP_ALL_PASS`, `ARCH14_WIZARD_ALL_PASS`, `ARCH14_ADAPTER_ALL_PASS`), full LSP11 family, LSP01 count markers, DRAW01/STRUCT01/NOTES01/DCFG01/DCFG02 rollups, three LSP semantic alias checks, and non-false advisory perf rollups.
      Treat `ARCH14_PERF_LSP_SCHEMA_DOT_OK` and `ARCH14_PERF_DRAWER_FILTER_SCOPED_OK` as pass only when `true` or `unfrozen`; `false`, missing, or unsupported duplicate values fail closed.
      Add script self-tests for valid synthetic log, missing marker, false marker, unsupported duplicate value, count mismatch, and advisory `unfrozen`.
      Wire local `make perf-lsp` to run UX13 rollup then ARCH14 rollup against the same captured evidence log.
      Add a separate blocking CI job `phase14-arch14-rollup-gate` outside advisory `continue-on-error`, downloading Linux and macOS evidence artifacts and failing the workflow if the rollup fails.
    </action>
    <acceptance_criteria>
      - `test -f ci/headless/check_arch14_rollup.lua`
      - `rg -n "ARCH14_ALL_PASS" ci/headless/check_arch14_rollup.lua Makefile .github/workflows/test.yml`
      - `rg -n "UX13_ALL_PASS" ci/headless/check_arch14_rollup.lua`
      - `rg -n "ARCH14_DRAWER_ALL_PASS|ARCH14_LSP_ALL_PASS|ARCH14_WIZARD_ALL_PASS|ARCH14_ADAPTER_ALL_PASS" ci/headless/check_arch14_rollup.lua`
      - `rg -n "ARCH14_PERF_LSP_SCHEMA_DOT_OK|ARCH14_PERF_DRAWER_FILTER_SCOPED_OK" ci/headless/check_arch14_rollup.lua`
      - `rg -n "phase14-arch14-rollup-gate" .github/workflows/test.yml`
      - `rg -n "continue-on-error: true" .github/workflows/test.yml` verifies only advisory jobs, not the blocking gate, carry advisory behavior.
    </acceptance_criteria>
    <d_trace>D-224,D-298,D-299,D-300,D-301,D-302,D-303,D-304,D-305</d_trace>
  </task>

  <task id="14-01-23" type="chore" wave="6" commit="chore(14-01-23): finalize phase 14 verification evidence">
    <depends_on>14-01-22</depends_on>
    <files>.planning/REQUIREMENTS.md; ci/headless/check_arch14_rollup.lua; .github/workflows/test.yml</files>
    <read_first>
      - .planning/REQUIREMENTS.md
      - .planning/milestones/v1.3-roadmap.md
      - .planning/phases/14-enterprise-db-architecture/14-CONTEXT.md
      - ci/headless/check_arch14_rollup.lua
    </read_first>
    <action>
      Verify `DBEE-ARCH-01` remains mapped to Phase 14 and no Phase 15/16 scope has been pulled in.
      Ensure final verification commands enumerate Phase 4..13 smoke, UX13 gate, adapter tests, drawer perf advisory, LSP semantic checks, and ARCH14 rollup.
      Add or update only planning/requirements trace text if necessary; do not add user-facing feature docs unless execution discovers an existing docs requirement.
      Produce final execution summary evidence after implementation, including marker snippets and deviations.
    </action>
    <acceptance_criteria>
      - `rg -n "DBEE-ARCH-01" .planning/REQUIREMENTS.md .planning/phases/14-enterprise-db-architecture/14-PLAN.md`
      - `rg -n "ARCH14_ALL_PASS=true" .planning/phases/14-enterprise-db-architecture/14-PLAN.md ci/headless/check_arch14_rollup.lua`
      - `rg -n "Phase 15|Phase 16|background prefetch|hover|resolve|code actions|workspace presets|regex" .planning/phases/14-enterprise-db-architecture/14-PLAN.md` only finds scope guards/deferred notes.
    </acceptance_criteria>
    <d_trace>D-224,D-225,D-226,D-298,D-299,D-300,D-301,D-302,D-303,D-304,D-305</d_trace>
  </task>
</tasks>

<traceability>
| Decisions | Task coverage |
| --- | --- |
| D-224 | 14-01-22, 14-01-23, all scope guards |
| D-225, D-226 | 14-01-23, objective, constraints |
| D-227..D-235 | 14-01-01, 14-01-20 |
| D-236..D-244 | 14-01-02, 14-01-03, 14-01-16 |
| D-245..D-250 | 14-01-04, 14-01-05, 14-01-07, 14-01-08, 14-01-09, 14-01-10, 14-01-11 |
| D-251..D-258 | 14-01-04, 14-01-06 |
| D-259..D-265 | 14-01-05, 14-01-06, 14-01-17 |
| D-266..D-273 | 14-01-12, 14-01-13, 14-01-14, 14-01-15 |
| D-274..D-279 | 14-01-16, 14-01-17, 14-01-18, 14-01-19 |
| D-280..D-286 | 14-01-20, 14-01-21 |
| D-287..D-292 | 14-01-03, 14-01-16, 14-01-17 |
| D-293..D-297 | 14-01-07, 14-01-08, 14-01-09, 14-01-10, 14-01-11, 14-01-24 |
| D-298 | 14-01-01, 14-01-02, 14-01-22 |
| D-299 | 14-01-20, 14-01-21, 14-01-22, 14-01-27 |
| D-300 | 14-01-04, 14-01-05, 14-01-06, 14-01-22 |
| D-301 | 14-01-12, 14-01-13, 14-01-14, 14-01-15, 14-01-22, 14-01-25 |
| D-302 | 14-01-16, 14-01-17, 14-01-18, 14-01-19, 14-01-22, 14-01-26 |
| D-303 | 14-01-03, 14-01-16, 14-01-17, 14-01-22 |
| D-304 | 14-01-07, 14-01-08, 14-01-09, 14-01-10, 14-01-11, 14-01-22, 14-01-24 |
| D-305 | 14-01-14, 14-01-18, 14-01-19, 14-01-22, 14-01-23, 14-01-24, 14-01-25, 14-01-26, 14-01-27 |
</traceability>

<verification_markers>
Required ARCH14 semantic markers:
- `ARCH14_SCHEMA_FILTER_PERSISTED=true`
- `ARCH14_SCHEMA_FILTER_RPC_ROUNDTRIP_OK=true`
- `ARCH14_SCHEMA_FILTER_MATCHING_OK=true`
- `ARCH14_SCHEMA_FILTER_SIGNATURE_STABLE=true`
- `ARCH14_SCHEMA_FILTER_INVALID_PATTERN_REJECTED=true`
- `ARCH14_LAZY_PER_SCHEMA_FLAG_GATED=true`
- `ARCH14_CACHE_V3_MIGRATION_OK=true`
- `ARCH14_FILTER_CHANGE_CACHE_DELETION_BOUNDED=true`
- `ARCH14_CACHE_TRUE_CORRUPTION_WARN_RETAINED=true`
- `ARCH14_FILTERED_STRUCTURE_API_OK=true`
- `ARCH14_OPTIONS_LUA_GO_ROUNDTRIP_OK=true`
- `ARCH14_RPC_MANIFEST_REGISTERED=true`
- `ARCH14_SCHEMA_EVENTS_SHAPED=true`
- `ARCH14_SCHEMA_LIST_SINGLEFLIGHT_OK=true`
- `ARCH14_SCHEMA_OBJECT_SINGLEFLIGHT_OK=true`
- `ARCH14_SCHEMA_OBJECT_BACKPRESSURE_OK=true`
- `ARCH14_SCHEMA_OBJECT_QUEUE_BOUNDED=true`
- `ARCH14_FILTER_CHANGE_EPOCH_SINGLE_BUMP=true`
- `ARCH14_RECONNECT_FILTER_SIGNATURE_MIGRATION_OK=true`
- `ARCH14_HANDLER_SCHEMA_EVENTS_ALL_PASS=true`
- `ARCH14_TOP4_ADAPTER_CAPABILITIES_OK=true`
- `ARCH14_LEGACY_EAGER_FALLBACK_OK=true`
- `ARCH14_SCHEMA_ONLY_ROOT_FAST=true`
- `ARCH14_SCHEMA_BRANCH_LAZY_OK=true`
- `ARCH14_SCHEMA_BRANCH_ERROR_RETRY_OK=true`
- `ARCH14_ZERO_RPC_DRAWER_FILTER_PRESERVED=true`
- `ARCH14_SCHEMA_FILTER_DOWNSTREAM_ALL_PASS=true`
- `ARCH14_LSP_SCHEMA_DOT_INCOMPLETE_OK=true`
- `ARCH14_LSP_SCHEMA_DOT_WARM_OK=true`
- `ARCH14_LSP_SCHEMA_DOT_NO_SYNC_FETCH=true`
- `ARCH14_LSP_LAZY_UNLOADED_NO_FALSE_WARN=true`
- `ARCH14_FILTER_CHANGE_INVALIDATES=true`
- `ARCH14_OUT_OF_SCOPE_HINT_OK=true`
- `ARCH14_SCHEMA_DISCOVERY_MANUAL_FALLBACK=true`
- `ARCH14_WIZARD_ADD_DISCOVERY_NON_MUTATING=true`
- `ARCH14_WIZARD_ADD_DISCOVERY_DEFAULT_NO=true`
- `ARCH14_WIZARD_EDIT_DISCOVERY_DEFAULT_YES=true`
- `ARCH14_WIZARD_SCHEMA_FILTER_EDIT_OK=true`
- `ARCH14_WIZARD_CLEAR_FILTER_OK=true`
- `ARCH14_LEGACY_FULL_STRUCTURE_COMPAT=true`

Required adapter markers:
- `ARCH14_ORACLE_SCHEMA_DISCOVERY_OK=true`
- `ARCH14_ORACLE_SCHEMA_OBJECTS_OK=true`
- `ARCH14_ORACLE_FILTER_BIND_SAFE=true`
- `ARCH14_ADAPTER_ORACLE_PUSHDOWN_OK=true`
- `ARCH14_POSTGRES_SCHEMA_DISCOVERY_OK=true`
- `ARCH14_POSTGRES_SCHEMA_OBJECTS_OK=true`
- `ARCH14_POSTGRES_FILTER_BIND_SAFE=true`
- `ARCH14_ADAPTER_POSTGRES_PUSHDOWN_OK=true`
- `ARCH14_MYSQL_SCHEMA_DISCOVERY_OK=true`
- `ARCH14_MYSQL_SCHEMA_OBJECTS_OK=true`
- `ARCH14_MYSQL_FILTER_BIND_SAFE=true`
- `ARCH14_ADAPTER_MYSQL_PUSHDOWN_OK=true`
- `ARCH14_MSSQL_SCHEMA_DISCOVERY_OK=true`
- `ARCH14_MSSQL_SCHEMA_OBJECTS_OK=true`
- `ARCH14_MSSQL_FILTER_BIND_SAFE=true`
- `ARCH14_ADAPTER_MSSQL_PUSHDOWN_OK=true`

Required aggregate markers:
- `ARCH14_SCHEMA_FILTER_DOWNSTREAM_ALL_PASS=true`
- `ARCH14_DRAWER_ALL_PASS=true`
- `ARCH14_LSP_ALL_PASS=true`
- `ARCH14_WIZARD_ALL_PASS=true`
- `ARCH14_ADAPTER_ALL_PASS=true`
- `ARCH14_ROLLUP_MARKERS_CHECKED=<n>`
- `ARCH14_ROLLUP_LSP01_COUNTS_OK=true`
- `ARCH14_PERF_LSP_SCHEMA_DOT_OK=true|unfrozen`
- `ARCH14_LSP_PERF_STATUS=unfrozen|publishable`
- `ARCH14_PERF_DRAWER_FILTER_SCOPED_OK=true|unfrozen`
- `ARCH14_ALL_PASS=true`

Preserved Phase 4..13 markers required by ARCH14 rollup:
- `UX13_ALL_PASS=true`
- `DRAW01_ALL_PASS=true`
- `DRAW01_REAL_NUI_PERF_ALL_PASS=true|unfrozen`
- `STRUCT01_ALL_PASS=true`
- `NOTES01_ALL_PASS=true`
- `DCFG01_DRAWER_LIFECYCLE_ALL_PASS=true`
- `DCFG01_COORDINATION_ALL_PASS=true`
- `DCFG02_WIZARD_ALL_PASS=true`
- `DCFG02_FILESOURCE_ALL_PASS=true`
- `LSP01_REAL_LSP_PERF_ALL_PASS=true|unfrozen`
- `LSP01_SCENARIOS_COUNT=33`
- exactly 33 distinct `LSP01_*_SENTINEL_OK=true`
- exactly 18 distinct `LSP01_*_NO_STALE_CLIENTS=true`
- exactly 3 `LSP01_DIAGNOSTICS_DIDCHANGE_COMPUTE_ONLY=true`
- full Phase 11 LSP11 family currently enforced by `check_ux13_rollup.lua`
- `LSP_ALIAS_NO_SYNC_FETCH=true`
- `LSP_SCHEMA_ALIAS_NO_SYNC_FETCH=true`
- `LSP_SCHEMA_ALIAS_VIEW_FALLBACK_OK=true`
- `LSP_REBIND_NO_SYNC_FETCH=true`
</verification_markers>

<verification>
Final local verification after execution:

1. Static scope guard:
   `! rg -n "background prefetch|workspace preset|regex schema|completionItem/resolve|textDocument/hover|codeAction|documentSymbol|workspace/symbol" lua/dbee dbee ci/headless`

2. Go unit compile/test without live integration:
   `go test ./dbee/core ./dbee/handler ./dbee/adapters`

3. Schema filter and handler checks:
   `make perf-bootstrap >/dev/null && nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_schema_filter.lua" && nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_handler_schema_filter.lua" && nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_adapter_schema_filter.lua"`

4. Drawer and wizard checks:
   `make perf-bootstrap >/dev/null && NUI_DIR="$(make perf-bootstrap-print | awk -F= '/^NUI_NVIM_DIR=/{print $2}')" && nvim --headless -u NONE -i NONE -n --cmd "set rtp^=${NUI_DIR} | set rtp+=$(pwd)" -c "luafile ci/headless/check_drawer_filter.lua" && nvim --headless -u NONE -i NONE -n --cmd "set rtp^=${NUI_DIR} | set rtp+=$(pwd)" -c "luafile ci/headless/check_connection_wizard.lua"`

5. LSP and disk checks:
   `make perf-bootstrap >/dev/null && NIO_DIR="$(make perf-bootstrap-print | awk -F= '/^NIO_NVIM_DIR=/{print $2}')" && nvim --headless -u NONE -i NONE -n --cmd "set rtp^=${NIO_DIR} | set rtp+=$(pwd)" -c "luafile ci/headless/check_lsp_schema_filter_lazy.lua" && nvim --headless -u NONE -i NONE -n --cmd "set rtp^=${NIO_DIR} | set rtp+=$(pwd)" -c "luafile ci/headless/check_lsp_disk_cache_safety.lua"`

6. Preserved full smoke/perf/semantic lane:
   `make perf-lsp PERF_PLATFORM=macos`

7. Drawer advisory perf lane:
   `make perf PERF_PLATFORM=macos DRAW01_PERF_GATE_MODE=advisory`

8. Fail-closed ARCH14 rollup negative test:
   `ARCH14_ROLLUP_SELFTEST=1 nvim --headless -u NONE -i NONE -n --cmd "set rtp+=$(pwd)" -c "luafile ci/headless/check_arch14_rollup.lua"`

9. Final positive evidence:
   `rg -n "UX13_ALL_PASS=true|ARCH14_ALL_PASS=true|ARCH14_ROLLUP_LSP01_COUNTS_OK=true|ARCH14_SCHEMA_FILTER_DOWNSTREAM_ALL_PASS=true|ARCH14_OPTIONS_LUA_GO_ROUNDTRIP_OK=true|ARCH14_RPC_MANIFEST_REGISTERED=true|ARCH14_SCHEMA_OBJECT_QUEUE_BOUNDED=true|ARCH14_WIZARD_ADD_DISCOVERY_NON_MUTATING=true|ARCH14_OUT_OF_SCOPE_HINT_OK=true" "$ARCH14_ROLLUP_LOG"`
</verification>

<goal_backward_audit>
Goal: "v1.3 Phase 14 ships allowlist plus lazy mode for top-4 enterprise adapters; small-DB users unaffected."

- Small-DB no-op path is covered by D-227, D-230, D-233 and tasks `14-01-01`, `14-01-12`, `14-01-18`, and marker `ARCH14_LAZY_PER_SCHEMA_FLAG_GATED=true`: absent filter and `lazy_per_schema=false` preserve full eager behavior.
- Allowlist persistence is covered by tasks `14-01-01`, `14-01-02`, `14-01-20`, and `14-01-21`: the same runtime `schema_filter` reaches FileSource/EnvSource, handler, wizard, drawer, LSP, and cache, while add-flow schema discovery remains transient and non-mutating before save.
- Lazy fast-start is covered by tasks `14-01-04`, `14-01-05`, `14-01-11`, `14-01-12`, and `14-01-13`: capable adapters expose registered schema-list/object APIs, handler single-flight dedupes them, and drawer renders schemas-only root plus row-local schema branch loading.
- Top-4 cost reduction is covered by tasks `14-01-04` and `14-01-07` through `14-01-11`: the Go API accepts handler-emitted `StructureOptions`, each enterprise adapter implements discovery/object fetch/filter pushdown, and SQL-level pushdown/cardinality markers prove the DB does not scan the full catalog before filtering.
- LSP correctness is covered by tasks `14-01-16` through `14-01-19`: cache scope, `schema.` async incomplete behavior, filtered-out exclusions, active-unloaded diagnostic suppression, and Information-level out-of-scope hints are verified without sync fallback.
- Cache safety is covered by tasks `14-01-03` and `14-01-17`: cache v3, deterministic signatures, strict invalidation, bounded generation-fenced column-file deletion, true-corruption WARN retention, and no completion-path disk scans are verified.
- Enterprise backpressure is covered by tasks `14-01-05` and `14-01-06`: distinct schema-object requests are deduped, active RPCs are capped per connection, queued distinct schemas are bounded at 32, priority overflow is deterministic, and requests are dropped safely on epoch/filter supersession.
- Regression preservation is covered by task `14-01-22`: `ARCH14_ALL_PASS` cannot pass unless UX13, Phase 4..13 smoke, Phase 10/11 perf families, and LSP semantic checks are present and non-false.
</goal_backward_audit>

<risk_register>
| Risk | Severity | Mitigation |
| --- | --- | --- |
| Phase 6/7 invariant drift around `_struct_cache.root[conn_id].structures` full-tree assumptions | High | `14-01-12` adds explicit `root_mode`; `14-01-14` tests full, schemas-only, mixed, and legacy filter/search; execution must audit root read sites before implementation. |
| LSP non-blocking contract regression from `schema.` completion | High | `14-01-18` forbids sync fallback, reuses Phase 11 async-miss discipline, and emits `ARCH14_LSP_SCHEMA_DOT_NO_SYNC_FETCH=true`. |
| Adapter divergence across Oracle/Postgres/MySQL/MSSQL | High | Split adapter tasks with shared marker harness; legacy fallback task prevents unsupported adapters from claiming lazy capability. |
| Adapter filter pushdown false-pass | High | `14-01-07`..`14-01-11` require SQL-level predicate/UNION-arm assertions and `ARCH14_ADAPTER_<TYPE>_PUSHDOWN_OK=true` cardinality markers. |
| Lua/Go schema scope divergence | High | `14-01-04` and `14-01-05` require handler-emitted `StructureOptions` to cross RPC boundaries unchanged and emit `ARCH14_OPTIONS_LUA_GO_ROUNDTRIP_OK=true`. |
| New schema RPC endpoints are not callable from Neovim | High | `14-01-04` updates `lua/dbee/api/__register.lua`, asserts `vim.fn.exists()` for both new functions, and emits `ARCH14_RPC_MANIFEST_REGISTERED=true`. |
| Add-flow schema discovery mutates unsaved connection state | High | `14-01-04` adds transient `DbeeConnectionListSchemasSpec`; `14-01-21` routes add wizard discovery through `connection_list_schemas_spec_async` and emits `ARCH14_WIZARD_ADD_DISCOVERY_NON_MUTATING=true`. |
| Distinct schema-object RPC fanout overloads an enterprise DB | High | `14-01-05` adds per-connection active RPC cap, bounded queue, priority, and generation-fenced drop semantics; `14-01-06` tests 100 simultaneous requests. |
| Cache migration version cascade hides corruption | High | `14-01-03` reuses Phase 11/13 migration patterns: known signature mismatch is silent, malformed v3/future/corrupt remains WARN. |
| Filter-change cache deletion blocks the UI/LSP on large cache directories | High | `14-01-03` and `14-01-17` require sync delete cap 100, deferred chunks, generation tokens, drain stats, and 10000-file tests. |
| Filter signature footgun from whitespace/case/list-order differences | Medium | `14-01-02` locks deterministic normalization tests and explicit length-prefix encoding. |
| Discovery probe failure blocks users from saving | Medium | `14-01-21` keeps add fast path default-no and verifies manual fallback after probe failure. |
| Lazy mode reconnect leaks stale schema-object payloads | High | `14-01-05`, `14-01-06`, and `14-01-17` test root epoch supersession, same-semantic alias migration, and stale conn/epoch drops. |
| Out-of-scope diagnostic noise | Medium | `14-01-19` uses Information severity, exact targeted message, and suppresses duplicate unknown-table warnings for filtered-out qualified refs. |
| Active-but-unloaded lazy schemas produce false unknown-table warnings | High | `14-01-19` locks a three-state diagnostic matrix and emits `ARCH14_LSP_LAZY_UNLOADED_NO_FALSE_WARN=true`. |
| Drawer perf regression for 10000-schema roots | Medium | `14-01-15` adds advisory root/branch perf scenarios and keeps promotion unfrozen until soak. |
| LSP schema-dot hot path has no timing evidence | Medium | `14-01-18` adds advisory schema-dot hit/miss/dedupe/warm/filter perf scenarios and rollup-required `ARCH14_PERF_LSP_SCHEMA_DOT_OK`. |
| Rollup false-pass risk | High | `14-01-22` implements a separate fail-closed ARCH14 gate with missing/false/unsupported/count mismatch self-tests and blocking CI job outside advisory `continue-on-error`. |
</risk_register>

<success_criteria>
- `14-PLAN.md` revision 3 has D-224..D-305 trace coverage and task ownership for all production/test surfaces.
- Implementation produces green commits `feat(14-01-XX)` / `fix(14-01-XX)` / `test(14-01-XX)` / `chore(14-01-XX)` with no red-test-only commits.
- All required `ARCH14_*` markers emit true and `ARCH14_ALL_PASS=true` comes from `ci/headless/check_arch14_rollup.lua`.
- `UX13_ALL_PASS=true` and Phase 4..13 smoke/perf/semantic evidence remain present.
- Phase 14 does not introduce Phase 15/16/v1.4 deferred features.
</success_criteria>
