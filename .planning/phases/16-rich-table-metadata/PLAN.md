# Phase 16 — Rich Table Metadata X.1 (Oracle-First)

**Milestone:** v1.3 LIVING  
**Status:** Plan rev 6 — r1/r2/r3/r4/r5/r6 findings folded inline  
**Author:** autopilot session, 2026-05-01

## Goal

DBeaver-style drawer metadata for Oracle connections:

- Under each table: explicit `Columns` and `Indexes` folders.
- Under each schema: explicit `Sequences` folder.
- Column rows show rich annotations: `[PK]`, `[NOT NULL]`, and `[FK→target.col]`.
- FK navigation through `<CR>` and `gd` jumps to the referenced table/column.

Oracle is the only adapter implemented in this phase. Postgres/MySQL/SQLite are deferred to X.2; remaining adapters are X.3 or capability=false.

## Locked Decisions

Source of truth: `~/.claude/projects/-Users-naveenkanuri-Documents-nvim-dbee/memory/decision_rich_metadata_12_questions.md`.

1. Composite FK UI is inline: `[FK→other.col1+col2]`; single-column FK remains `[FK→other.col]`.
2. Check constraints are out of scope.
3. Triggers are out of scope.
4. Sequence details are name + increment + cache_size only; skip `last_number` / current value.
5. Index details are name + columns + uniqueness + ASC/DESC; skip method/type; hide PK-backed indexes.
6. FK navigation: `<CR>` and `gd` both navigate. Multi-FK columns use a string-only picker.
7. Folder shape: explicit `Columns` and `Indexes` folders under each table.
8. Lazy fetch policy: table expand fetches columns immediately; indexes and sequences fetch only when their folder expands.
9. Must scale to 10000 tables/schema.
10. Unsupported adapters hide rich metadata folders entirely and keep the existing flat legacy column expansion.
11. Drawer-only in v1; LSP annotations are deferred.
12. Reverse references are out of scope.

## Existing Touchpoints

Use these current code anchors when implementing. If line numbers drift, re-run `nl -ba` and update local references before editing.

| Area | Existing anchor | Contract |
|------|-----------------|----------|
| Driver interface | `dbee/core/connection.go:38` | Add optional rich capability/data interfaces here; do not reference non-existent `dbee/core/driver.go`. |
| Column type | `dbee/core/types.go:205` | Extend `Column` additively; old `Name`/`Type` shape remains valid. |
| Structure types | `dbee/core/types.go:72`, `dbee/core/types.go:179` | Add `index` and `sequence` constants/string round-trip. |
| Sync column marshal | `dbee/handler/marshal.go:207`, `dbee/handler/marshal.go:223` | `WrapColumns()` currently emits only `name/type`; rich fields must be preserved. |
| Async column marshal | `dbee/handler/event_bus.go:208`, `dbee/handler/event_bus.go:285` | `structure_children_loaded` and `columnsToLua()` currently emit only column fields; extend this path. |
| Go async columns | `dbee/handler/handler.go:501` | Reuse this async shape for rich metadata instead of inventing separate events. |
| Endpoint registration | `dbee/endpoints.go:488`, `dbee/endpoints.go:505` | Add Go endpoints via `p.RegisterEndpoint`. Regenerate/update generated manifest `lua/dbee/api/__register.lua:27`. There is no `REGISTERED_PLUGIN_METHODS` table in this repo. |
| Lua schema filter gate | `lua/dbee/handler/init.lua:2597`, `lua/dbee/handler/init.lua:2618` | New rich async wrappers must mirror `connection_get_columns(_async)` authority checks. |
| Event dispatch | `lua/dbee/handler/__events.lua:17` | Lua wrappers may emit local no-op `structure_children_loaded` payloads without RPC. |
| Public API columns | `lua/dbee/api/core.lua:142` | Existing public `core.connection_get_columns()` stays unchanged; rich metadata wrappers are handler-internal only in v1. |
| Existing stale guards | `lua/dbee/ui/drawer/init.lua:2256` | Reuse `on_structure_children_loaded` request_id/root_epoch guards by keeping one event type. |
| Branch cache | `lua/dbee/ui/drawer/init.lua:357`, `lua/dbee/ui/drawer/init.lua:1282` | Branch state is keyed by `conn_id + branch_id + kind`; add rich kinds here. |
| Table children | `lua/dbee/ui/drawer/init.lua:1128`, `lua/dbee/ui/drawer/init.lua:1180` | Table expand currently fetches columns directly; replace with metadata folders and column prefetch. |
| Column rendering | `lua/dbee/ui/drawer/convert.lua:61` | Column rows currently render `name   [type]`; extend label and node fields. |
| Drawer action refresh default | `lua/dbee/ui/drawer/init.lua:2861`, `lua/dbee/ui/drawer/init.lua:2906` | Non-connection node action_1 currently refreshes after action; FK navigation must bypass this refresh path. |
| Default `<CR>` | `lua/dbee/config.lua:94`, `lua/dbee/ui/drawer/init.lua:3459` | `<CR>` maps to `toggle`; FK navigation must be context-aware inside toggle, not only action_1. |
| Buffer mappings | `lua/dbee/ui/common/init.lua:61` | Add default `gd` mapping through existing mapping config. |

## Architecture

### Layer 1: Go Data Model

Edit `dbee/core/types.go`.

Extend `Column` additively:

```go
type Column struct {
    Name string `json:"name" msgpack:"name"`
    Type string `json:"type" msgpack:"type"`

    Nullable          *bool    `json:"nullable,omitempty" msgpack:"nullable,omitempty"`
    PrimaryKey        bool     `json:"primary_key,omitempty" msgpack:"primary_key,omitempty"`
    PrimaryKeyOrdinal int      `json:"primary_key_ordinal,omitempty" msgpack:"primary_key_ordinal,omitempty"`
    ForeignKeys       []*FKRef `json:"foreign_keys,omitempty" msgpack:"foreign_keys,omitempty"`
}
```

Add:

```go
type FKRef struct {
    ConstraintName string `json:"constraint_name,omitempty" msgpack:"constraint_name,omitempty"`

    SourceSchema  string   `json:"source_schema,omitempty" msgpack:"source_schema,omitempty"`
    SourceTable   string   `json:"source_table,omitempty" msgpack:"source_table,omitempty"`
    SourceColumn  string   `json:"source_column,omitempty" msgpack:"source_column,omitempty"`
    SourceColumns []string `json:"source_columns,omitempty" msgpack:"source_columns,omitempty"`
    SourceOrdinal int      `json:"source_ordinal,omitempty" msgpack:"source_ordinal,omitempty"`

    TargetSchema  string   `json:"target_schema,omitempty" msgpack:"target_schema,omitempty"`
    TargetTable   string   `json:"target_table,omitempty" msgpack:"target_table,omitempty"`
    TargetColumn  string   `json:"target_column,omitempty" msgpack:"target_column,omitempty"`
    TargetColumns []string `json:"target_columns,omitempty" msgpack:"target_columns,omitempty"`
}

type Index struct {
    Name     string   `json:"name" msgpack:"name"`
    Schema   string   `json:"schema,omitempty" msgpack:"schema,omitempty"`
    Table    string   `json:"table,omitempty" msgpack:"table,omitempty"`
    Columns  []string `json:"columns" msgpack:"columns"`
    Orders   []string `json:"orders,omitempty" msgpack:"orders,omitempty"`
    Unique   bool     `json:"unique,omitempty" msgpack:"unique,omitempty"`
    PKBacked bool     `json:"pk_backed,omitempty" msgpack:"pk_backed,omitempty"`
}

type Sequence struct {
    Name      string `json:"name" msgpack:"name"`
    Schema    string `json:"schema,omitempty" msgpack:"schema,omitempty"`
    Increment int64  `json:"increment,omitempty" msgpack:"increment,omitempty"`
    CacheSize int64  `json:"cache_size,omitempty" msgpack:"cache_size,omitempty"`
}
```

Add `StructureTypeIndex` and `StructureTypeSequence`, with `String()` and `StructureTypeFromString()` round-trip values `index` and `sequence`.

### Layer 2: Driver Capability and Connection Methods

Edit `dbee/core/connection.go`.

Add optional driver interfaces near `Driver` at `connection.go:38`:

```go
type RichMetadataSupport struct {
    Columns   bool `json:"columns" msgpack:"columns"`
    Indexes   bool `json:"indexes" msgpack:"indexes"`
    Sequences bool `json:"sequences" msgpack:"sequences"`
}

type RichMetadataCapability interface {
    SupportsRichMetadata() RichMetadataSupport
}

type RichColumnDriver interface {
    ColumnsRich(opts *TableOptions) ([]*Column, error)
}

type IndexDriver interface {
    Indexes(opts *TableOptions) ([]*Index, error)
}

type SequenceDriver interface {
    Sequences(schema string) ([]*Sequence, error)
}
```

Add `Connection.SupportsRichMetadata()`, `Connection.GetColumnsRich(opts)`, `Connection.GetIndexes(opts)`, and `Connection.GetSequences(schema)`.

Unsupported drivers return `RichMetadataSupport{}` and `core.ErrSchemaMetadataNotSupported` for data methods. Drawer must hide unsupported folders before issuing data requests.

### Layer 3: Oracle Adapter

Edit `dbee/adapters/oracle_driver.go`.

Oracle implements all rich interfaces:

- `SupportsRichMetadata() -> {Columns:true, Indexes:true, Sequences:true}`.
- `ColumnsRich(schema, table)` returns nullable, PK, and FK metadata.
- `Indexes(schema, table)` returns non-PK-backed indexes.
- `Sequences(schema)` returns sequence name, increment, cache_size.

Required SQL contracts:

1. Column base query reads `all_tab_columns` scoped by `owner = :schema AND table_name = :table`, ordered by `column_id`.
2. PK query uses `all_constraints` + `all_cons_columns`, `constraint_type = 'P'`, ordered by `position`.
3. FK query returns one row per FK column, ordered by `constraint_name, position`, and pairs source/target columns by matching ordinal:

```sql
SELECT ac.constraint_name,
       acc.column_name AS source_column,
       acc.position AS ordinal,
       rac.owner AS target_schema,
       rac.table_name AS target_table,
       racc.column_name AS target_column
FROM all_constraints ac
JOIN all_cons_columns acc
  ON ac.owner = acc.owner
 AND ac.constraint_name = acc.constraint_name
JOIN all_constraints rac
  ON ac.r_owner = rac.owner
 AND ac.r_constraint_name = rac.constraint_name
JOIN all_cons_columns racc
  ON rac.owner = racc.owner
 AND rac.constraint_name = racc.constraint_name
 AND racc.position = acc.position
WHERE ac.constraint_type = 'R'
  AND ac.owner = :schema
  AND ac.table_name = :table
ORDER BY ac.constraint_name, acc.position
```

4. Composite FK grouping:
   - Group FK rows by `constraint_name`.
   - Sort grouped rows by `position`.
   - Build full `SourceColumns[]` and `TargetColumns[]` arrays for the constraint.
   - Attach a distinct `*FKRef` instance to each participating source column.
   - Each per-column FKRef copy shares `ConstraintName`, full `SourceColumns[]`, full `TargetColumns[]`, `SourceSchema`, `SourceTable`, `TargetSchema`, and `TargetTable`.
   - Each per-column FKRef copy sets its own `SourceColumn`, `TargetColumn`, and `SourceOrdinal`, where `TargetColumn` is the target column paired by the same ordinal.
5. Oracle index SQL scopes table ownership with `i.table_owner = :schema AND i.table_name = :table`, not `i.owner = :schema`. Index owner can differ from table owner.
6. PK-backed index detection joins constraints by table owner/table name and index owner/name:

```sql
SELECT i.index_name,
       i.owner AS index_owner,
       i.table_owner,
       i.table_name,
       i.uniqueness,
       ic.column_name,
       ic.descend,
       ic.column_position,
       CASE WHEN ac.constraint_name IS NULL THEN 0 ELSE 1 END AS pk_backed
FROM all_indexes i
JOIN all_ind_columns ic
  ON ic.index_owner = i.owner
 AND ic.index_name = i.index_name
LEFT JOIN all_constraints ac
  ON ac.owner = i.table_owner
 AND ac.table_name = i.table_name
 AND ac.index_owner = i.owner
 AND ac.index_name = i.index_name
 AND ac.constraint_type = 'P'
WHERE i.table_owner = :schema
  AND i.table_name = :table
ORDER BY i.index_name, ic.column_position
```

7. Sequence SQL:

```sql
SELECT sequence_name, increment_by, cache_size
FROM all_sequences
WHERE sequence_owner = :schema
ORDER BY sequence_name
```

Schema filter authority is not implemented in Go adapter methods. The Lua handler wrappers block filtered-out schemas before any RPC. Adapter SQL still scopes by explicit schema/table for defense-in-depth and correct catalog use.

### Layer 4: Marshal and Event Surface

Edit `dbee/handler/marshal.go` and `dbee/handler/event_bus.go`.

`WrapColumns()` must preserve new optional fields for sync return paths. `columnsToLua()` must preserve the same rich fields for async event payloads. Add marshal helpers for `FKRef`, `Index`, and `Sequence`.

Reuse the existing `structure_children_loaded` event. Do not add `columns_rich_loaded`, `indexes_loaded`, or `sequences_loaded` event names.

Extend `eventBus.StructureChildrenLoaded` at `event_bus.go:208` so all rich children use the same payload contract:

```lua
{
  conn_id = string,
  supported = boolean,
  request_id = integer,
  branch_id = string,
  root_epoch = integer,
  kind = "columns" | "columns_rich" | "indexes" | "sequences",
  schema = string,
  table = string|nil,
  columns = Column[]|nil,
  indexes = Index[]|nil,
  sequences = Sequence[]|nil,
  error = string|nil,
  error_kind = string|nil,
}
```

Rules:

- Success events set `supported=true`, `error=nil`, and exactly one payload array for the requested `kind`.
- Unsupported no-op events set `supported=false`, `error=nil`, and the requested payload array to `{}`.
- Error events set `supported=true`, requested payload array to `nil`, `error` to a renderable string, and optional `error_kind` to a typed machine-readable string.
- `data.error` must stay string-compatible for existing drawer rendering through `tostring(data.error)`. Do not use table-shaped errors for rich metadata events.
- `data.error_kind` is optional and is the only field used for typed branching, such as `queue_full` or `schema_filter_blocked`.
- Existing Phase 14 drawer authority paths that consume `error_kind` continue to work; rich metadata error paths follow the same string `error` plus typed `error_kind` pattern.
- Payload field mapping is fixed:
  - `kind="columns"` reads `data.columns`.
  - `kind="columns_rich"` reads `data.columns`; entries contain the richer optional fields.
  - `kind="indexes"` reads `data.indexes`.
  - `kind="sequences"` reads `data.sequences`.
- Existing legacy `kind="columns"` may continue for old column paths, but Phase 16 drawer folders use `kind="columns_rich"` for table metadata columns.

### Layer 5: Handler Endpoints, Lua Wrappers, and Singleflight

Edit:

- `dbee/handler/handler.go`
- `dbee/endpoints.go`
- `lua/dbee/api/__register.lua`
- `lua/dbee/handler/init.lua`
- `lua/dbee/doc.lua`

Go handler methods:

- `ConnectionGetRichMetadataSupport(conn_id)`.
- `ConnectionGetColumnsRichAsync(conn_id, request_id, branch_id, root_epoch, opts)`.
- `ConnectionGetIndexesAsync(conn_id, request_id, branch_id, root_epoch, opts)`.
- `ConnectionGetSequencesAsync(conn_id, request_id, branch_id, root_epoch, opts)`.

Go endpoints in `dbee/endpoints.go`:

- `DbeeConnectionGetRichMetadataSupport`
- `DbeeConnectionGetColumnsRichAsync`
- `DbeeConnectionGetIndexesAsync`
- `DbeeConnectionGetSequencesAsync`

Regenerate/update `lua/dbee/api/__register.lua` so those functions are registered in the remote manifest.

`lua/dbee/api/core.lua` is not changed in this phase. Rich columns, indexes, and sequences are drawer/handler-internal in v1 and are not exposed through public `dbee.*` or `api.core` wrappers. LSP/external integrations remain deferred to v1.4 per locked decision 11.

Lua wrappers in `lua/dbee/handler/init.lua`:

- `connection_supports_rich_metadata(conn_id)`.
- `connection_get_columns_rich_async(conn_id, request_id, branch_id, root_epoch, opts)`.
- `connection_get_indexes_async(conn_id, request_id, branch_id, root_epoch, opts)`.
- `connection_get_sequences_async(conn_id, request_id, branch_id, root_epoch, opts)`.

Support wrapper contract:

- `connection_supports_rich_metadata(conn_id)` has no `schema` argument and must not run schema-filter checks.
- It calls `vim.fn.DbeeConnectionGetRichMetadataSupport` at most once per connection lifecycle.
- Cache entries use `_rich_metadata_support_cache[conn_id] = { capability_payload = { columns = bool, indexes = bool, sequences = bool }, generation = integer }`.
- Drop the cache entry on `_source_reload_silent`, any `source_reload` event including `source_reload_reconnect`, `source_update_connection` with preserved `conn_id`, and any other path that re-creates the connection's underlying driver while preserving `conn_id`.
- Capability=false means no rich metadata RPCs are fired, but legacy table column expansion must continue.

Every per-table/per-schema data wrapper mirrors the existing Lua-side authority guard at `handler/init.lua:2597` and `handler/init.lua:2618`:

```lua
local authority = schema_filter_authority.read(self, conn_id)
if schema_filter_authority.is_fail_closed(authority) then return end
if authority.status == "ok" and not schema_filter.matches(schema, authority.scope) then
  event_bus.trigger("structure_children_loaded", unsupported_payload)
  return
end
```

The filtered-out path must not call `vim.fn.DbeeConnection*`. `RICH16_SCHEMA_FILTER_NO_QUERY_OK` asserts no RPC and no DB query.

Singleflight/backpressure lives in Lua Handler, before RPC dispatch:

- Add `_rich_metadata_flights`, `_rich_metadata_request_lookup`, and `_rich_metadata_queues`.
- Table-scoped key for columns_rich/indexes: `(conn_id, schema, table, materialization, root_epoch, schema_filter_signature, kind)`.
- Schema-scoped key for sequences: `(conn_id, schema, root_epoch, schema_filter_signature)`.
- Concurrent identical requests join one in-flight job.
- Same `schema.table` with different `materialization` values must produce distinct table-scoped flights.
- Fan-out joined completion to every waiter by re-emitting `structure_children_loaded` with each waiter's original `request_id` and `branch_id`.
- Per-connection queue: `max_active=8`, `max_queue=128`, drawer-priority entries before background entries.
- Fan-out of 100 table expansions may create at most 8 active metadata RPCs at once; remaining jobs queue and drain as slots free. All 100 jobs must complete with no drops.
- Requests past `max_queue` emit a `structure_children_loaded` event for every rejected waiter using the original `conn_id`, `request_id`, `branch_id`, `root_epoch`, and `kind`.
- Rejected waiter events set `error="queue_full"`, `error_kind="queue_full"`, and the requested payload array (`columns`, `indexes`, or `sequences`) to `nil`.
- Overflow dispatch fixture uses one connection, 200 unique singleflight keys, and 200 unique `request_id` + `branch_id` assignments. It must assert 8 active, 128 queued, 64 rejected with `queue_full`, and zero joined-via-singleflight requests.
- Overflow dispatch example: 200 unique jobs with caps `max_active=8` and `max_queue=128` must produce 8 active jobs, 128 queued jobs that drain in order, and 64 rejected jobs with `queue_full` errors.
- After active and queued jobs drain, capacity is free and a new dispatch succeeds.
- Supersede queued/in-flight metadata jobs on authoritative root epoch bump and schema-filter signature drift, mirroring existing schema-object singleflight concepts at `handler/init.lua:890`.

### Layer 6: Drawer Branch Topology

Edit:

- `lua/dbee/ui/drawer/convert.lua`
- `lua/dbee/ui/drawer/init.lua`
- `lua/dbee/ui/drawer/model.lua`

Branch constants:

```lua
local COLUMNS_RICH_KIND = "columns_rich"
local INDEXES_KIND = "indexes"
local SEQUENCES_KIND = "sequences"
```

Folder branch IDs use existing `ID_SEP`/escaped segment conventions from `convert.lua:6` and `convert.lua:20`:

- Columns folder logical ID: `<table_branch_id>:columns`; implement via helper `metadata_folder_node_id(table_branch_id, "columns")`.
- Indexes folder logical ID: `<table_branch_id>:indexes`; same helper with `"indexes"`.
- Sequences folder logical ID: `<schema_branch_id>:sequences`; same helper with `"sequences"`.

Cache layout uses existing branch cache shape:

- `branch_state(ui, conn_id, columns_folder_id, COLUMNS_RICH_KIND, create)`
- `branch_state(ui, conn_id, indexes_folder_id, INDEXES_KIND, create)`
- `branch_state(ui, conn_id, sequences_folder_id, SEQUENCES_KIND, create)`

Table expansion contract:

1. Expanding a table first reads cached `connection_supports_rich_metadata(conn_id)`.
2. If `columns=false`, preserve the existing legacy behavior: render flat column rows directly under the table via the old column path, with no rich metadata RPC.
3. If `columns=true`, expanding a table renders a `Columns` folder immediately and starts `connection_get_columns_rich_async()` for the `Columns` folder branch.
4. The `Columns` folder itself is a UX wrapper around cached or loading column data; expanding it does not start a second DB request.
5. If `indexes=true`, render an `Indexes` folder; that folder starts `connection_get_indexes_async()` only when expanded.
6. Schema nodes render a `Sequences` folder only when capability says `Sequences=true`; expanding that folder starts `connection_get_sequences_async()`.
7. Unsupported adapters render no rich metadata folders but keep legacy flat columns unchanged.

`on_structure_children_loaded` at `drawer/init.lua:2256` remains the only apply path. It must:

- Select payload array by fixed kind mapping: legacy `kind="columns"` reads `data.columns`; rich `kind="columns_rich"` also reads `data.columns`; `kind="indexes"` reads `data.indexes`; `kind="sequences"` reads `data.sequences`.
- Keep existing `request_id` guard.
- Keep existing `root_epoch` guard.
- Store unsupported payloads as empty branch data and render no child nodes.
- Treat `error="queue_full"` / `error_kind="queue_full"` payloads exactly like successful `structure_children_loaded` events for branch-state lifecycle: clear the loading flag, store an explicit branch error, and render a visible error placeholder under the folder.
- A new successful dispatch after queue drain must clear the queue_full placeholder and replace it with normal branch children.
- Preserve stale rejection for rich metadata by construction.

`build_branch_nodes()` must render:

- `columns_rich` with `convert.column_nodes()`.
- `indexes` with index nodes.
- `sequences` with sequence nodes.
- Existing `structures` behavior unchanged.

### Layer 7: Column Labels and FK Navigation

Edit `lua/dbee/ui/drawer/convert.lua`, `lua/dbee/ui/drawer/init.lua`, and `lua/dbee/config.lua`.

Column node fields:

- `pk: boolean`
- `primary_key_ordinal: integer?`
- `nullable: boolean|nil`
- `fk_refs: FKRef[]`
- `conn_id`, `schema`, `table`, `raw_name`

Column label order:

```text
name   [type] [PK] [NOT NULL] [FK→target.col]
```

Composite FK label uses target column arrays:

```text
[FK→target_table.col1+col2]
```

Multiple distinct FKs render compact comma-separated labels and open a picker for navigation.

Navigation design:

- Add reusable drawer action `fk_navigate`.
- Add default mapping `{ key = "gd", mode = "n", action = "fk_navigate" }` in `lua/dbee/config.lua`.
- FK navigation is a separate drawer-level dispatch. It must not be routed through the node `action_1` slot, `perform_node_action()`, or `perform_action()`, because `perform_action()` invalidates render snapshots even in non-refresh modes.
- `<CR>` keymap path: update `toggle` at `drawer/init.lua:3459` to first check if the current node is a column with FK refs. If yes, call the FK navigation body directly and return. Otherwise keep normal collapse/expand behavior.
- `gd` keymap path: add dedicated `fk_navigate` action in `DrawerUI:get_actions()` that calls the same FK navigation body directly, without the `perform_action()` wrapper.
- FK navigation body is `pcall(set_cursor_to_target_node)` only. It must not call `on_done`, `invalidate_render_snapshot`, `refresh_filter_safe`, or `tree:render`.
- Non-FK column `<CR>` must not navigate; it may no-op or fall through to existing toggle behavior.
- Target resolution traverses the current drawer tree for same connection, schema, target table, target column. If target schema/table/column is not visible due to schema filter or lazy state, warn and do not crash.
- If a single column has multiple FK refs, use `menu.select` with a `string[]` item list and label lookup map.

### Layer 8: Tests

Add `ci/headless/check_rich_metadata.lua` and Go tests under `dbee/adapters/oracle_driver_test.go` or a focused new Oracle rich metadata test file.

Sentinel family target: **51 strict + 1 diagnostic**. `RICH16_ALL_PASS` is the rollup and excludes the diagnostic marker.

| Marker | Asserts |
|--------|---------|
| `RICH16_GO_TYPES_BACKWARD_COMPAT` | Old `{name,type}` Column payload decodes; new fields are additive. |
| `RICH16_MARSHAL_RICH_FIELDS_PRESERVED_OK` | Real sync `WrapColumns()` and async `columnsToLua()` preserve nullable/PK/FK fields end-to-end. |
| `RICH16_ORACLE_COLUMNS_RICH_OK` | Oracle columns query returns PK/FK/nullable correctly. |
| `RICH16_ORACLE_INDEXES_OK` | Oracle indexes query returns name+columns+uniqueness+ASC/DESC and includes cross-owner index on table owner schema. |
| `RICH16_ORACLE_INDEXES_PK_BACKED_FLAG` | PK-backed indexes flagged and hidden input is available. |
| `RICH16_ORACLE_SEQUENCES_OK` | Oracle sequences query returns name+increment+cache_size. |
| `RICH16_ORACLE_COMPOSITE_PK_ORDER_PRESERVED` | Composite PK ordinals follow `all_cons_columns.position`. |
| `RICH16_FK_COMPOSITE_GROUPING_OK` | Shuffled FK SQL rows group by constraint, order by position, and all participating columns share consistent SourceColumns/TargetColumns arrays. |
| `RICH16_FK_COMPOSITE_PER_COLUMN_REF_OK` | Two-column FK gives each source column its own FKRef copy; `SourceColumn` differs, full arrays match, and `TargetColumn` pairs by ordinal. |
| `RICH16_SCHEMA_FILTER_NO_QUERY_OK` | Lua wrapper returns immediately for excluded schema; no RPC and no DB query. |
| `RICH16_HANDLER_CAPABILITY_FALSE_NO_QUERY` | Capability=false emits supported=false payload and performs no DB query. |
| `RICH16_CAPABILITY_FALSE_LEGACY_COLUMNS_OK` | Capability=false table expand uses existing flat legacy column rendering and fires no rich metadata RPC. |
| `RICH16_SUPPORT_QUERY_ONCE_PER_CONN_LIFECYCLE` | Rich support RPC fires exactly once per connection lifecycle until explicit support-cache invalidation. |
| `RICH16_SUPPORT_CACHE_INVALIDATED_ON_SILENT_RECONNECT` | `_source_reload_silent` with same `conn_id` clears support cache and next support query re-fires. |
| `RICH16_SUPPORT_CACHE_INVALIDATED_ON_SOURCE_RELOAD` | Any `source_reload` event clears support cache. |
| `RICH16_SUPPORT_CACHE_INVALIDATED_ON_UPDATE_CONNECTION` | `source_update_connection` with preserved `conn_id` clears support cache because the driver may have changed. |
| `RICH16_HANDLER_COLUMNS_RICH_EVENT_OK` | `structure_children_loaded` `kind="columns_rich"` payload matches schema. |
| `RICH16_HANDLER_INDEXES_EVENT_OK` | `structure_children_loaded` `kind="indexes"` payload matches schema. |
| `RICH16_HANDLER_SEQUENCES_EVENT_OK` | `structure_children_loaded` `kind="sequences"` payload matches schema. |
| `RICH16_EVENT_PAYLOAD_FIELD_MAPPING_OK` | `kind="columns"` and `kind="columns_rich"` both read `data.columns`; indexes/sequences read their matching arrays. |
| `RICH16_STALE_REQUEST_ID_REJECTED_OK` | Rich child payload with stale request_id is ignored by drawer. |
| `RICH16_STALE_ROOT_EPOCH_REJECTED_OK` | Rich child payload with stale root_epoch is ignored by drawer. |
| `RICH16_SINGLEFLIGHT_DEDUPES_CONCURRENT_OK` | Concurrent identical metadata requests join one in-flight RPC. |
| `RICH16_SINGLEFLIGHT_MATERIALIZATION_DISTINCT` | Same schema/name as table and view creates two distinct flights and two distinct queries. |
| `RICH16_BACKPRESSURE_MAX_ACTIVE_BOUNDED` | Metadata queue caps active RPCs at the configured `max_active=8`. |
| `RICH16_BACKPRESSURE_QUEUE_DRAIN_OK` | Queued metadata jobs dispatch as in-flight slots free. |
| `RICH16_BACKPRESSURE_HANDLER_OVERFLOW_REJECTS_OK` | Handler receives 200 unique singleflight keys and produces 8 active, 128 queued, 64 `queue_full` rejected events with original identity, payload nil, and zero joins. |
| `RICH16_BACKPRESSURE_DRAWER_OVERFLOW_CLEARS_LOADING_OK` | Drawer receives a `queue_full` event, clears branch loading into error state, renders a visible placeholder, and a later successful dispatch clears the placeholder. |
| `RICH16_FANOUT_DISPATCH_COUNT_OK` | 100 table burst produces max 8 active jobs at any time, queues the remainder, and completes all 100 with no drops. |
| `RICH16_COLUMNS_RICH_FETCH_ON_TABLE_EXPAND_ONLY` | Column-rich RPC fires on table expand and not on Columns folder expand. |
| `RICH16_INDEXES_FETCH_DEFERRED_UNTIL_FOLDER_EXPAND` | Indexes RPC never fires until the Indexes folder is expanded. |
| `RICH16_SEQUENCES_FETCH_DEFERRED_UNTIL_FOLDER_EXPAND` | Sequences RPC never fires until the Sequences folder is expanded. |
| `RICH16_DUPLICATE_COLUMNS_FETCH_DEDUPED` | Re-expanding the same table reuses cached/singleflight result and does not issue a duplicate column-rich RPC. |
| `RICH16_ERROR_FIELD_STRING_COMPAT_OK` | Rich error event with `error="queue_full"` and `error_kind="queue_full"` renders `queue_full`, not `table: ...`, and does not crash. |
| `RICH16_DRAWER_COLUMNS_FOLDER_RENDERED` | Columns folder appears under supported table. |
| `RICH16_COLUMNS_PREFETCH_TO_COLUMNS_FOLDER_OK` | Table expand starts columns_rich fetch for Columns folder branch; expanding Columns does not issue a duplicate fetch. |
| `RICH16_DRAWER_INDEXES_FOLDER_RENDERED` | Indexes folder appears under supported table. |
| `RICH16_DRAWER_SEQUENCES_FOLDER_RENDERED` | Sequences folder appears under supported schema. |
| `RICH16_DRAWER_PK_ANNOTATION_OK` | Column row shows `[PK]`. |
| `RICH16_DRAWER_NOT_NULL_ANNOTATION_OK` | Column row shows `[NOT NULL]`. |
| `RICH16_DRAWER_FK_INLINE_ANNOTATION_OK` | Single-column FK row shows `[FK→...]`. |
| `RICH16_DRAWER_FK_COMPOSITE_INLINE_OK` | Composite FK row shows `[FK→target.col1+col2]`. |
| `RICH16_DRAWER_FK_MULTI_FK_PICKER_OK` | Column with multiple FKs opens picker. |
| `RICH16_TABLE_EXPAND_NORMAL_OK` | Non-column table expand still expands and loads metadata folders normally. |
| `RICH16_NON_FK_COLUMN_CR_NOOP_OR_TOGGLE` | Non-FK column `<CR>` does not navigate. |
| `RICH16_FK_COLUMN_CR_NAVIGATES_OK` | FK column `<CR>` navigates to target. |
| `RICH16_FK_COLUMN_GD_NAVIGATES_OK` | FK column `gd` navigates to target. |
| `RICH16_FK_NAVIGATE_NO_REFRESH_OK` | FK navigation does not call `invalidate_render_snapshot`, `tree:render`, or `refresh_filter_safe`; it only moves the cursor. |
| `RICH16_DRAWER_INDEXES_LAZY_FETCH_OK` | Indexes and sequences are not fetched until their folders expand. |
| `RICH16_DRAWER_PK_BACKED_INDEX_HIDDEN` | `pk_backed=true` indexes do not render. |
| `RICH16_DRAWER_CAPABILITY_FALSE_HIDES_FOLDERS` | Unsupported adapter renders no Columns/Indexes/Sequences folders. |
| `RICH16_DRAWER_RENDER_PERF_DIAGNOSTIC` | 100 tables x 50 columns x 5 indexes render timing reported; diagnostic only. |
| `RICH16_ALL_PASS` | All strict markers true; diagnostic excluded. |

## Files and Estimated Diffs

| File | Action | LOC |
|------|--------|-----|
| `dbee/core/types.go` | Column extension, FKRef, Index, Sequence, StructureType constants | +150 |
| `dbee/core/connection.go` | Rich metadata optional interfaces and Connection methods | +90 |
| `dbee/adapters/oracle_driver.go` | Oracle rich columns/indexes/sequences SQL and grouping | +390 |
| `dbee/adapters/oracle_driver_test.go` | Oracle rich SQL parsing, cross-owner indexes, composite FK grouping | +320 |
| `dbee/handler/marshal.go` | Rich msgpack wrappers for Column/FKRef/Index/Sequence | +130 |
| `dbee/handler/event_bus.go` | Shared structure_children_loaded payload with supported flag and rich arrays | +150 |
| `dbee/handler/handler.go` | Rich metadata support/data async methods | +180 |
| `dbee/endpoints.go` | RPC bindings for support + 3 async endpoints | +110 |
| `lua/dbee/api/__register.lua` | Generated manifest entries for new RPC functions | +4 |
| `lua/dbee/handler/init.lua` | Lua authority wrappers, generational support cache, local unsupported/error events, rich singleflight/backpressure | +430 |
| `lua/dbee/doc.lua` | Event payload docs | +20 |
| `lua/dbee/ui/drawer/convert.lua` | Metadata folder helpers, rich column/index/sequence nodes, FK labels | +320 |
| `lua/dbee/ui/drawer/init.lua` | Table/folder topology, guarded rich event apply, support fallback, string-compatible errors, direct FK navigation, mappings bridge | +500 |
| `lua/dbee/ui/drawer/model.lua` | Search/snapshot field copying for metadata folders and rich column fields | +80 |
| `lua/dbee/config.lua` | Default `gd` drawer mapping | +2 |
| `ci/headless/check_rich_metadata.lua` | 51 strict markers + diagnostic | +870 |
| `Makefile` + `ci/headless/check_ux13_rollup.lua` | Add RICH16 smoke and rollup marker | +6 |

Estimated total: ~3752 LOC.

## Execute Waves

**Wave 1 — Go types, capability, marshal.**  
Files: `dbee/core/types.go`, `dbee/core/connection.go`, `dbee/handler/marshal.go`, `dbee/handler/event_bus.go`.  
Strict markers:

- `RICH16_GO_TYPES_BACKWARD_COMPAT`
- `RICH16_MARSHAL_RICH_FIELDS_PRESERVED_OK`

**Wave 2 — Oracle adapter.**  
Files: `dbee/adapters/oracle_driver.go`, Oracle tests.  
Strict markers:

- `RICH16_ORACLE_COLUMNS_RICH_OK`
- `RICH16_ORACLE_INDEXES_OK`
- `RICH16_ORACLE_INDEXES_PK_BACKED_FLAG`
- `RICH16_ORACLE_SEQUENCES_OK`
- `RICH16_ORACLE_COMPOSITE_PK_ORDER_PRESERVED`
- `RICH16_FK_COMPOSITE_GROUPING_OK`
- `RICH16_FK_COMPOSITE_PER_COLUMN_REF_OK`

**Wave 3 — RPC endpoints and Lua Handler wrappers.**  
Files: `dbee/handler/handler.go`, `dbee/endpoints.go`, `lua/dbee/api/__register.lua`, `lua/dbee/handler/init.lua`, `lua/dbee/doc.lua`.  
Strict markers:

- `RICH16_SCHEMA_FILTER_NO_QUERY_OK`
- `RICH16_HANDLER_CAPABILITY_FALSE_NO_QUERY`
- `RICH16_SUPPORT_QUERY_ONCE_PER_CONN_LIFECYCLE`
- `RICH16_SUPPORT_CACHE_INVALIDATED_ON_SILENT_RECONNECT`
- `RICH16_SUPPORT_CACHE_INVALIDATED_ON_SOURCE_RELOAD`
- `RICH16_SUPPORT_CACHE_INVALIDATED_ON_UPDATE_CONNECTION`
- `RICH16_HANDLER_COLUMNS_RICH_EVENT_OK`
- `RICH16_HANDLER_INDEXES_EVENT_OK`
- `RICH16_HANDLER_SEQUENCES_EVENT_OK`
- `RICH16_EVENT_PAYLOAD_FIELD_MAPPING_OK`
- `RICH16_ERROR_FIELD_STRING_COMPAT_OK`
- `RICH16_SINGLEFLIGHT_DEDUPES_CONCURRENT_OK`
- `RICH16_SINGLEFLIGHT_MATERIALIZATION_DISTINCT`
- `RICH16_BACKPRESSURE_MAX_ACTIVE_BOUNDED`
- `RICH16_BACKPRESSURE_QUEUE_DRAIN_OK`
- `RICH16_BACKPRESSURE_HANDLER_OVERFLOW_REJECTS_OK`
- `RICH16_FANOUT_DISPATCH_COUNT_OK`

**Wave 4 — Drawer topology and stale guards.**  
Files: `lua/dbee/ui/drawer/convert.lua`, `lua/dbee/ui/drawer/init.lua`, `lua/dbee/ui/drawer/model.lua`.  
Strict markers:

- `RICH16_CAPABILITY_FALSE_LEGACY_COLUMNS_OK`
- `RICH16_STALE_REQUEST_ID_REJECTED_OK`
- `RICH16_STALE_ROOT_EPOCH_REJECTED_OK`
- `RICH16_DRAWER_COLUMNS_FOLDER_RENDERED`
- `RICH16_COLUMNS_PREFETCH_TO_COLUMNS_FOLDER_OK`
- `RICH16_DRAWER_INDEXES_FOLDER_RENDERED`
- `RICH16_DRAWER_SEQUENCES_FOLDER_RENDERED`
- `RICH16_COLUMNS_RICH_FETCH_ON_TABLE_EXPAND_ONLY`
- `RICH16_INDEXES_FETCH_DEFERRED_UNTIL_FOLDER_EXPAND`
- `RICH16_SEQUENCES_FETCH_DEFERRED_UNTIL_FOLDER_EXPAND`
- `RICH16_DUPLICATE_COLUMNS_FETCH_DEDUPED`
- `RICH16_BACKPRESSURE_DRAWER_OVERFLOW_CLEARS_LOADING_OK`
- `RICH16_DRAWER_INDEXES_LAZY_FETCH_OK`
- `RICH16_DRAWER_PK_BACKED_INDEX_HIDDEN`
- `RICH16_DRAWER_CAPABILITY_FALSE_HIDES_FOLDERS`

**Wave 5 — Column labels and FK navigation.**  
Files: `lua/dbee/ui/drawer/convert.lua`, `lua/dbee/ui/drawer/init.lua`, `lua/dbee/config.lua`.  
Strict markers:

- `RICH16_DRAWER_PK_ANNOTATION_OK`
- `RICH16_DRAWER_NOT_NULL_ANNOTATION_OK`
- `RICH16_DRAWER_FK_INLINE_ANNOTATION_OK`
- `RICH16_DRAWER_FK_COMPOSITE_INLINE_OK`
- `RICH16_DRAWER_FK_MULTI_FK_PICKER_OK`
- `RICH16_TABLE_EXPAND_NORMAL_OK`
- `RICH16_NON_FK_COLUMN_CR_NOOP_OR_TOGGLE`
- `RICH16_FK_COLUMN_CR_NAVIGATES_OK`
- `RICH16_FK_COLUMN_GD_NAVIGATES_OK`
- `RICH16_FK_NAVIGATE_NO_REFRESH_OK`

**Wave 6 — Rollup and smoke.**  
Files: `ci/headless/check_rich_metadata.lua`, `Makefile`, `ci/headless/check_ux13_rollup.lua`.  
Existing smoke must remain green.

**Diagnostic marker.**

- `RICH16_DRAWER_RENDER_PERF_DIAGNOSTIC`

**Rollup marker.**

- `RICH16_ALL_PASS`

## Risks and Gotchas

1. **Column wrapper branch IDs.** Columns are fetched on table expand into the Columns folder branch, not under the table branch. Duplicate fetch on Columns folder expand is a bug.
2. **Event reuse.** New metadata must use `structure_children_loaded`; separate rich event names bypass stale guards.
3. **Lua authority.** Schema filtering is enforced in Lua wrappers. Go adapter SQL scoping is not a substitute.
4. **Oracle index owner.** Use `i.table_owner` for table scoping; `i.owner` is index owner and can differ.
5. **Composite FK grouping.** Group by constraint before attaching refs; row order from SQL must not leak into arrays unless sorted by position.
6. **`<CR>` mapping reality.** Default `<CR>` is `toggle`, so FK navigation must intercept toggle for FK columns and leave table expand behavior intact.
7. **String-only pickers.** Multi-FK picker uses `menu.select` with `string[]` and lookup map.
8. **Lazy races.** Singleflight and stale guards are both required; one does not replace the other.
9. **Unsupported adapters.** Hidden rich folders mean no empty placeholders and no rich RPCs, but legacy flat column expansion must remain intact.
10. **Support cache.** Rich support is cached per connection lifecycle only; `_source_reload_silent`, any `source_reload`, `source_update_connection`, and any driver-recreation path must drop it.
11. **Singleflight key.** `materialization` is part of table-scoped keys so table/view name collisions do not dedupe incorrectly.
12. **Backpressure overflow.** Handler overflow emits `structure_children_loaded` rejections with original identity; drawer apply must clear loading and render branch error state. Silent drops and stuck loading states are forbidden.
13. **FK navigation refresh.** FK cursor jumps must bypass `perform_action()` entirely, not only choose a non-refresh mode.
14. **Error compatibility.** Rich metadata events keep `data.error` as a string and put typed routing in `data.error_kind`; table-shaped `data.error` is out of contract.

## Out of Scope

- Postgres, MySQL, SQLite adapters.
- Other adapters.
- Check constraints.
- Triggers.
- Sequence current value / `last_number`.
- Reverse references.
- LSP rich metadata annotations.

## Success Criteria

- All 51 RICH16 strict markers pass; diagnostic perf marker reported but excluded from `RICH16_ALL_PASS`.
- Existing smoke remains green: `DRAW01_ALL_PASS`, `STRUCT01_ALL_PASS`, `DCFG01_DRAWER_LIFECYCLE_ALL_PASS`, `DCFG02_FILESOURCE_ALL_PASS`, `FOLDER15_ALL_PASS`.
- Oracle table expand shows `Columns` and `Indexes`; table expand prefetches columns; indexes/sequences are folder-lazy.
- FK `<CR>` and `gd` navigate when target is visible and warn safely when filtered/lazy target is unavailable.
- Non-Oracle adapters are unchanged because capability=false hides rich metadata folders and preserves legacy flat column rendering.
