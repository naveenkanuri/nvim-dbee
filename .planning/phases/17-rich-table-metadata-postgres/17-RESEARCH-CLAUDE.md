# Phase 17 Research — dbee Codebase Integration Points (Claude side)

**Date:** 2026-05-04
**Scope:** existing nvim-dbee integration points relevant to PostgreSQL Rich Table Metadata (Phase 17 / X.2). Complements `17-RESEARCH-CODEX.md` (which covers `pg_catalog` SQL).
**Read-only research** — no production files were edited.

This document traces every Phase 16 contract that Phase 17 will mirror, plus the few additive changes needed to expose PostgreSQL specifics (`materialized_view`, INCLUDE indexes, `[GEN]/[IDENTITY]/[DEFAULT=...]` annotations).

---

## 1. Existing PostgreSQL adapter structure

### Driver in use — `lib/pq` (NOT `pgx`)

Confirmed at three sites:
- `dbee/adapters/postgres.go:9` — `_ "github.com/lib/pq"`
- `dbee/adapters/postgres.go:33` — `sql.Open("postgres", u.String())`
- `dbee/go.mod:16` — `github.com/lib/pq v1.10.9`

Implication for Phase 17: positional `$1, $2, ...` bind syntax only. No `sql.Named(...)` translation in `lib/pq`. Confirmed by `dbee/core/builders/client.go:96-105`:

```go
func (c *Client) QueryWithArgs(ctx context.Context, query string, args ...any) (*ResultStream, error) {
    rows, err := c.db.QueryContext(ctx, query, args...)
    ...
}
```

`builders.Client.QueryWithArgs` passes `args ...any` straight into `db.QueryContext` with no name resolution — exactly matching Codex research §5.

### `Postgres` adapter (`dbee/adapters/postgres.go`)

- Adapter struct `Postgres` registered at `postgres.go:17` for aliases `"postgres"`, `"postgresql"`, `"pg"`.
- `Connect(url)` opens `sql.Open("postgres", ...)` → `postgresDriver` wrapped in `builders.NewClient` with custom JSON / JSONB type processors.
- `GetHelpers(opts)` (lines 56-89) returns the legacy on-screen helper map (`List`, `Columns`, `Indexes`, `Foreign Keys`, `References`, `Primary Keys`) using `information_schema` interpolation. **Note**: these are *user-facing query templates*, NOT the rich metadata path. Phase 17 does NOT touch this map.

### `postgresDriver` — interface assertions (`dbee/adapters/postgres_driver.go:17-23`)

```go
var (
    _ core.Driver                  = (*postgresDriver)(nil)
    _ core.FilteredStructureDriver = (*postgresDriver)(nil)
    _ core.SchemaListDriver        = (*postgresDriver)(nil)
    _ core.SchemaStructureDriver   = (*postgresDriver)(nil)
    _ core.DatabaseSwitcher        = (*postgresDriver)(nil)
)
```

Phase 17 must extend these to add (mirroring Oracle at `oracle_driver.go:33-36`):

```go
_ core.RichMetadataCapability  = (*postgresDriver)(nil)
_ core.RichColumnDriver        = (*postgresDriver)(nil)
_ core.IndexDriver             = (*postgresDriver)(nil)
_ core.SequenceDriver          = (*postgresDriver)(nil)
```

### Existing introspection paths

- `Columns(opts)` — `postgres_driver.go:45-53` — uses `information_schema.columns`, returns `[name, data_type]` only. **This is the legacy path; Phase 16 keeps it untouched as fallback.**
- `Structure()` → `StructureWithOptions(nil)` — `postgres_driver.go:55-83`.
- `StructureWithOptions(opts)` — `postgres_driver.go:59-83` — uses `schemaPredicate("table_schema", opts, schemaDialectPostgres, 1)` for the table query starting at `$1`, then `schemaPredicate("schemaname", opts, schemaDialectPostgres, next)` for matviews continuing the placeholder index. UNION ALL of `information_schema.tables` and `pg_matviews`.
- `ListSchemas()` — `postgres_driver.go:85-95` — `information_schema.schemata WHERE schema_name NOT IN ('pg_catalog', 'information_schema')`.
- `StructureForSchema(schema, opts)` — `postgres_driver.go:97-119` — schema-scoped variant; passes `schema, schema` as `$1, $2`.

### Helpers reusable in Phase 17

- `schema_filter.go` (entire file) is the defense-in-depth filter for `StructureWithOptions`. Phase 17 rich-metadata SQL is single-table-scoped (`WHERE n.nspname = $1 AND c.relname = $2`) so does NOT invoke `schemaPredicate`. The Lua side already blocks via `schema_filter_authority` BEFORE the RPC fires (see §4 / §6).
- `schemaDialectPostgres = "postgres"` (`schema_filter.go:15`) and `placeholder("postgres", index) → "$N"` (`schema_filter.go:91-99`) confirm positional syntax.

### Materialized view rendering today (CRITICAL — see §8)

`postgresDriver.StructureWithOptions` and `StructureForSchema` BOTH issue the matview branch as `'VIEW' AS object_type` (lines 73 and 106):

```go
SELECT schemaname AS schema_name, matviewname AS object_name, 'VIEW' AS object_type FROM pg_matviews
```

Then `getPGStructureType` at `postgres_driver.go:171-186` declares:

```go
case "VIEW", "SYSTEM VIEW":
    return core.StructureTypeView
case "MATERIALIZED VIEW":
    return core.StructureTypeMaterializedView   // ← never taken on Postgres path
```

The `core.StructureTypeMaterializedView` branch is **declared but unreachable** for PostgreSQL because the SELECT hard-codes `'VIEW'`. Per CONTEXT.md OQ-01 (RESOLVED): Phase 17 will fix this to label as `'MATERIALIZED VIEW'`.

---

## 2. Rich metadata interface contracts (Phase 16 reference)

### Interfaces — `dbee/core/connection.go:47-67`

```go
RichMetadataSupport struct {
    Columns   bool `json:"columns" msgpack:"columns"`
    Indexes   bool `json:"indexes" msgpack:"indexes"`
    Sequences bool `json:"sequences" msgpack:"sequences"`
}

RichMetadataCapability interface {
    SupportsRichMetadata() RichMetadataSupport
}

RichColumnDriver interface {
    ColumnsRich(opts *TableOptions) ([]*Column, error)
}

IndexDriver interface {
    Indexes(opts *TableOptions) ([]*Index, error)
}

SequenceDriver interface {
    Sequences(schema string) ([]*Sequence, error)
}
```

### Connection wrappers — `dbee/core/connection.go:284-336`

`Connection.SupportsRichMetadata()` (line 284) probes the optional `RichMetadataCapability` interface; falls back to `RichMetadataSupport{}` (all-false zero value).

`Connection.GetColumnsRich/GetIndexes/GetSequences` (lines 291-336) are thin wrappers that type-assert to `RichColumnDriver/IndexDriver/SequenceDriver` and return `ErrSchemaMetadataNotSupported` when the driver does not implement.

### Type shapes — `dbee/core/types.go:227-269`

```go
type Column struct {
    Name string `json:"name" msgpack:"name"`
    Type string `json:"type" msgpack:"type"`

    Nullable          *bool    `json:"nullable,omitempty" msgpack:"nullable,omitempty"`
    PrimaryKey        bool     `json:"primary_key,omitempty" msgpack:"primary_key,omitempty"`
    PrimaryKeyOrdinal int      `json:"primary_key_ordinal,omitempty" msgpack:"primary_key_ordinal,omitempty"`
    ForeignKeys       []*FKRef `json:"foreign_keys,omitempty" msgpack:"foreign_keys,omitempty"`
}

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

### Additive fields Phase 17 will add

PostgreSQL-specific annotations need NEW optional fields (`omitempty` is mandatory to preserve the locked back-compat contract — see §9):

- `Column.Generated string` — non-empty when `pg_attribute.attgenerated != ''` (`'s'` stored, `'v'` virtual). Drives `[GEN]` rendering.
- `Column.Identity string` — non-empty when `pg_attribute.attidentity != ''` (`'a'` always, `'d'` by default). Drives `[IDENTITY]` rendering.
- `Column.Default string` — `pg_get_expr(pg_attrdef.adbin, ...)` value. Drives `[DEFAULT=expr]` rendering.
- `Column.SerialSequence string` (optional) — output of `pg_get_serial_sequence(...)` for SERIAL detection. Renderer may surface this or not.
- `Index.IncludeColumns []string` — columns from positions `> indnkeyatts`. Rendered as `[INCLUDE col_a, col_b]`. **Critical**: must NOT be merged into `Index.Columns` because Phase 16 drawer already renders `Columns` as key columns with `Orders`.

Each new field MUST use `,omitempty` on the JSON tag AND on the msgpack tag to preserve "old client decoding new struct succeeds" — see §9.

### Phase 16 reference impl pattern — `dbee/adapters/oracle_driver.go:394-800`

SQL constants (lines 394-466):
- `oracleColumnsRichSQL` — base columns query. Oracle uses `:p_schema, :p_table` named binds (`sql.Named` API). Phase 17 uses `$1, $2` positional.
- `oraclePrimaryKeysSQL` — separate query joined by ordinal.
- `oracleForeignKeysSQL` — separate query, paired by `racc.position = acc.position` for composite ordinality.
- `oracleIndexesSQL` — joined `all_indexes` + `all_ind_columns` + LEFT JOIN `all_constraints` for `pk_backed`.
- `oracleSequencesSQL` — `all_sequences` filtered by `sequence_owner`.

Method bodies (lines 468-800):
- `SupportsRichMetadata()` (468-474) returns all-true for Oracle.
- `ColumnsRich(opts)` (476-530) — runs three queries in one 2-minute context, builds `byName map[string]*core.Column`, then calls `applyOraclePrimaryKeys` and `applyOracleForeignKeys` to enrich the same map.
- `applyOraclePrimaryKeys` (532-561) — sets `col.PrimaryKey = true` and `col.PrimaryKeyOrdinal = position`.
- `applyOracleForeignKeys` (572-654) — composite FK pattern Phase 17 must mirror exactly:
  - Group rows by `constraintName`.
  - Sort each group by `ordinal`.
  - Build `sourceColumns []string` + `targetColumns []string` once per constraint.
  - Iterate group AGAIN, attaching one `*core.FKRef` per source column, with `cloneStrings(sourceColumns)` and `cloneStrings(targetColumns)` so each ref carries the FULL composite arrays (line 642-647).
- `Indexes(opts)` (656-759) — groups rows by `owner+name` key, sorts by `position`, populates `Columns[]` and `Orders[]`. PK-backed flag preserved on the index struct (line 734).
- `Sequences(schema)` (761-800) — single-query result builder.

Helpers `oracleStringValue`, `oracleIntValue`, `oracleInt64Value`, `oracleBoolValue` (lines 802-883) — type coercion. Phase 17 should write Postgres equivalents (`pgStringValue` etc.) since `lib/pq` returns slightly different concrete types from go-ora.

### `cloneStrings` definition

Note `cloneStrings` is referenced at `oracle_driver.go:642`. It is NOT in `core/types.go` (which has `cloneStrings` in a different package — see `types.go:271-278`). Search for the exact identifier:
- `dbee/core/types.go:271-278` — package `core` private helper. NOT exported.
- The Oracle adapter must have its own `cloneStrings` somewhere in `oracle_driver.go` or `oracle_helpers_test.go`. Phase 17 should reuse a shared adapter helper or define a local one (search for it during plan-phase).

---

## 3. Handler / RPC integration

### Go RPC methods — `dbee/handler/handler.go:548-752`

`ConnectionGetRichMetadataSupport(connID)` (548-554) — sync probe used by the Lua support cache.

`ConnectionGetColumnsRichAsync(connID, requestID, branchID, rootEpoch, opts)` (556-623):
- Validates `requestID` (auto-assigns from `nextStructureReqID` if `<= 0`).
- Branch-A: unknown connection → emits `structureChildrenPayload` with `Kind: "columns_rich"`, `Supported: true`, `Error: "unknown connection..."`.
- Branch-B: capability returns `Columns=false` → emits payload with `Supported: false`, empty `Columns`. `c.SupportsRichMetadata().Columns` (line 589).
- Else `go func() { columns, err := c.GetColumnsRich(opts); ...emit }`. Empty `Columns` on error, `Error: "c.GetColumnsRich: ..."`.

`ConnectionGetIndexesAsync` (625-692) — same shape, `Kind: "indexes"`, payload field `Indexes`.

`ConnectionGetSequencesAsync` (694-752) — same shape, `Kind: "sequences"`, takes raw `schema string` (not `*TableOptions`), payload field `Sequences`.

**Per-driver type assertions happen INSIDE `c.GetColumnsRich/GetIndexes/GetSequences`** (the `Connection.GetX` wrappers), NOT in the handler. Phase 17 needs only to make `postgresDriver` implement the optional interfaces; handler dispatch is already wired.

### `structure_children_loaded` event payload — `dbee/handler/event_bus.go:18-34, 233-315`

```go
type structureChildrenPayload struct {
    ConnID    core.ConnectionID
    RequestID int
    BranchID  string
    RootEpoch int
    Kind      string         // "columns" | "columns_rich" | "indexes" | "sequences"
    Schema    string
    Table     string
    Supported bool

    Columns   []*core.Column
    Indexes   []*core.Index
    Sequences []*core.Sequence

    Error     string
    ErrorKind string
}
```

`StructureChildrenLoadedPayload` (line 260-315) serializes to a Lua table literal via `vim.fn.ExecLua` calling `require("dbee.handler.__events").trigger("structure_children_loaded", data)`. The serialized payload includes:

```lua
{
    conn_id = ..., request_id = ..., branch_id = ..., root_epoch = ...,
    kind = ..., supported = true|false,
    schema = ..., table = ...,
    columns = {...}, indexes = {...}, sequences = {...},
    error = "..." or nil,
    error_kind = "..." or nil,
}
```

`columnsToLua / fkRefsToLua / indexesToLua / sequencesToLua` (lines 361-462) are the Lua-table serialisers. Phase 17 additive Column / Index fields MUST be added to:
- `columnsToLua` (line 361-384): currently emits `name, type, nullable, primary_key, primary_key_ordinal, foreign_keys`. Needs `generated, identity, default, serial_sequence` (or whatever the planner names them).
- `indexesToLua` (line 415-439): currently emits `name, schema, table, columns, orders, unique, pk_backed`. Needs `include_columns`.

`error_kind` is sent via `luaOptionalString(payload.ErrorKind)` (line 312), so Lua sees `nil` when empty — matches Phase 16 contract that drawer treats `data.error or data.error_kind` as load error (see CONTEXT.md decisions in MEMORY.md).

### msgpack wrappers — `dbee/handler/marshal.go:255-343`

`columnWrap.MarshalMsgPack` (255-274) currently emits inline anonymous struct with msgpack tags `name, type, nullable,omitempty, primary_key,omitempty, primary_key_ordinal,omitempty, foreign_keys,omitempty`.

**Phase 17 must add** `Generated, Identity, Default, SerialSequence` (or chosen names) fields to BOTH the anonymous encoding struct AND propagate from `cw.column.Generated` etc.

`indexWrap.MarshalMsgPack` (305-326) needs `IncludeColumns []string \`msgpack:"include_columns,omitempty"\``.

`sequenceWrap.MarshalMsgPack` (328-343) — Phase 17 makes no changes (no PG-specific sequence fields beyond `increment` and `cache_size`).

### Endpoint registration — `dbee/endpoints.go:537-626`

`DbeeConnectionGetRichMetadataSupport` (537-542): single-arg wrapper.

`DbeeConnectionGetColumnsRichAsync` (544-572):
```go
Opts *struct {
    Table           string `msgpack:"table"`
    Schema          string `msgpack:"schema"`
    Materialization string `msgpack:"materialization"`
}
```
Decodes `Materialization` via `core.StructureTypeFromString(args.Opts.Materialization)`.

`DbeeConnectionGetIndexesAsync` (574-602): identical opts shape.

`DbeeConnectionGetSequencesAsync` (604-626): `Opts *struct { Schema string `msgpack:"schema"` }` only.

**No new endpoints needed for Phase 17.** Materialization decoding via `StructureTypeFromString` already handles `"materialized_view"` (`types.go:191-193`).

### LUA register manifest — `lua/dbee/api/__register.lua:29-34`

All 4 endpoints are listed. No edits required for Phase 17.

---

## 4. Lua handler integration (singleflight + backpressure)

All references in `lua/dbee/handler/init.lua` (≈3439 lines). Key file is the entire singleflight + queue + supersession + waiter-fanout machinery — Phase 17 production code touches NONE of this; it just needs to dispatch through the same async methods that Oracle uses.

### Constants — `lua/dbee/handler/init.lua:8-22`

```lua
local RICH_METADATA_MAX_ACTIVE = 8
local RICH_METADATA_MAX_QUEUE = 128
local RICH_COLUMNS_KIND = "columns_rich"
local RICH_INDEXES_KIND = "indexes"
local RICH_SEQUENCES_KIND = "sequences"
local RICH_METADATA_INTERNAL_BRANCH_PREFIX = "__rich_metadata:"
local RICH_METADATA_WAITER_FANOUT_SOURCE = "rich_metadata_waiter"
local RICH_METADATA_KINDS = { [RICH_COLUMNS_KIND] = true, [RICH_INDEXES_KIND] = true, [RICH_SEQUENCES_KIND] = true }
```

### Singleflight key — `lua/dbee/handler/init.lua:778-797`

```lua
local function rich_metadata_key(kind, conn_id, schema, table_name, materialization, epoch, signature)
  if kind == RICH_SEQUENCES_KIND then
    return table.concat({
      tostring(conn_id or ""),
      tostring(schema or ""),
      tostring(epoch or 0),
      tostring(signature or ""),
      kind,
    }, "\x1f")
  end
  return table.concat({
    tostring(conn_id or ""),
    tostring(schema or ""),
    tostring(table_name or ""),
    tostring(materialization or ""),
    tostring(epoch or 0),
    tostring(signature or ""),
    kind,
  }, "\x1f")
end
```

Confirms CONTEXT.md PG-05 — table-scoped key includes `materialization` (so `(schema, table, table)` and `(schema, table, materialized_view)` are distinct flights), schema-only key for sequences. Separator is `\x1f` (ASCII Unit Separator).

### Support cache — `lua/dbee/handler/init.lua:3075-3097`

```lua
function Handler:connection_supports_rich_metadata(id)
  local cached = self._rich_metadata_support_cache[id]
  if cached and cached.capability_payload then
    return vim.deepcopy(cached.capability_payload)
  end
  local ok, ret = pcall(vim.fn.DbeeConnectionGetRichMetadataSupport, id)
  ...
  local support = self:_normalize_rich_metadata_support(ret)
  self._rich_metadata_support_cache[id] = { capability_payload = support, generation = ... }
  return vim.deepcopy(support)
end
```

Cache invalidated on silent reconnect / source reload / connection update by `_invalidate_rich_metadata_support_cache_for_ids` (line 977-986). Phase 17 inherits this — Postgres returns `{columns=true, indexes=true, sequences=true}` and is cached identically.

### Singleflight + queue admission — `lua/dbee/handler/init.lua:3158-3245`

`Handler:connection_get_rich_metadata_singleflight(opts)` (entry point):
1. Validate kind in `RICH_METADATA_KINDS`, schema non-empty.
2. Resolve `epoch = opts.root_epoch or self:get_authoritative_root_epoch(opts.conn_id)`.
3. Build `waiter` (line 3170).
4. **Schema-filter authority check** via `self:_rich_metadata_schema_allowed(waiter)` (lines 3126-3136 + 3172): calls `schema_filter_authority.read(self, waiter.conn_id)`, fails fail-closed sentinel, blocks RPC when scope says no. Returns `error_kind = "schema_filter_blocked"`.
5. **Capability check** via `self:_rich_metadata_capability_allows(opts.conn_id, opts.kind)` (lines 3142-3154 + 3176): emits `unsupported` event when capability=false. Returns `error_kind = "unsupported"`.
6. `signature = self:_current_schema_filter_signature(opts.conn_id)` — current schema-filter scope hash.
7. `key = rich_metadata_key(...)` — singleflight key per §4.
8. **Active flight join** (line 3192-3196): if existing flight, append waiter, return `{joined=true}`.
9. **Queued flight join** (line 3199-3203): same for queued entries.
10. **Slot admission** (line 3226-3232): if `queue.active < RICH_METADATA_MAX_ACTIVE (8)` → start entry immediately.
11. **Enqueue** (line 3234-3240): otherwise enqueue. `_enqueue_rich_metadata_entry` (line 1155-1166) returns false when `queue.queue >= max_queue (128)`; rejection emits `error="queue_full", error_kind="queue_full"` PER WAITER (line 1163).

### Three async wrappers Phase 17 reuses unchanged

`Handler:connection_get_columns_rich_async(id, request_id, branch_id, root_epoch, opts)` (3252-3260)
`Handler:connection_get_indexes_async(id, ...)` (3267-3275)
`Handler:connection_get_sequences_async(id, ...)` (3282-3290)

All three set `opts.kind` and call `connection_get_rich_metadata_singleflight(opts)`. Phase 17 production code does not touch these.

### Internal RPC dispatch — `_start_rich_metadata_entry` (`init.lua:1065-1116`)

```lua
local internal_branch_id = RICH_METADATA_INTERNAL_BRANCH_PREFIX .. tostring(entry.key)
if entry.kind == RICH_COLUMNS_KIND then
    ok, err = pcall(vim.fn.DbeeConnectionGetColumnsRichAsync, entry.conn_id, entry.request_id, internal_branch_id, entry.epoch, entry.opts)
elseif entry.kind == RICH_INDEXES_KIND then
    ok, err = pcall(vim.fn.DbeeConnectionGetIndexesAsync, ..., entry.opts)
elseif entry.kind == RICH_SEQUENCES_KIND then
    ok, err = pcall(vim.fn.DbeeConnectionGetSequencesAsync, ..., { schema = entry.schema })
end
```

Internal branch IDs are prefixed with `__rich_metadata:` so the completion handler can disambiguate internal Go RPC completions from waiter fanout events.

### `data.fanout_source` waiter isolation — `init.lua:991-1002` and `2057-2123`

Producer side (`_emit_rich_metadata_waiter`):
```lua
function Handler:_emit_rich_metadata_waiter(waiter, payload)
  payload = copy_payload(payload) or {}
  ...
  payload.fanout_source = payload.fanout_source or RICH_METADATA_WAITER_FANOUT_SOURCE
  event_bus.trigger("structure_children_loaded", payload)
end
```

Consumer side (`_on_rich_metadata_loaded`):
```lua
function Handler:_on_rich_metadata_loaded(data)
  if not data or not data.request_id or not RICH_METADATA_KINDS[data.kind] then return end
  if data.fanout_source ~= nil then return end                                -- ignore waiter fanout
  if tostring(data.branch_id or ""):sub(1, #RICH_METADATA_INTERNAL_BRANCH_PREFIX) ~= RICH_METADATA_INTERNAL_BRANCH_PREFIX then
    return                                                                    -- ignore non-internal-branch events
  end
  ...
end
```

This is the Phase 16 impl-fix r1 HIGH-#1 fix (commit `c3dd1a8`): waiter fanout events are tagged with `fanout_source` so the internal completion handler doesn't re-process them, and double dispatch through `_rich_metadata_request_lookup` is impossible.

### Supersession tombstones — `init.lua:1172-1198, 2084-2090`

```lua
function Handler:_supersede_rich_metadata_flights(conn_id, new_epoch, error_kind)
  for _, flight in pairs(self._rich_metadata_flights or {}) do
    if flight.conn_id == conn_id and flight.epoch < new_epoch then
      flight.superseded = true
      flight.superseded_error_kind = flight.superseded_error_kind or error_kind or "superseded"
    end
  end
  ...
```

In `_on_rich_metadata_loaded` (line 2084-2090):
```lua
if flight.superseded then
  local error_kind = flight.superseded_error_kind or "superseded"
  for _, waiter in ipairs(flight.waiters or {}) do
    self:_emit_rich_metadata_error(waiter, error_kind, error_kind)
  end
  return
end
```

This is the Phase 16 impl-fix r1 HIGH-#2 fix: superseded flights stay tombstoned, the active slot stays counted until Go RPC completion returns, and waiters get an error event when the completion arrives. **Phase 17 inherits this pattern unchanged** — Postgres flights will be superseded on schema-filter changes / reconnects exactly like Oracle's.

### Backpressure constants

`max_active = 8` and `max_queue = 128` (lines 1046-1047), enforced in `_rich_metadata_queue` (line 1041-1050). Drainage at flight completion via `_drain_rich_metadata_queue` (line 1118-1132) prefers `priority == "drawer"` entries first.

Phase 17 invokes these unchanged via the three `connection_get_*_async` methods. Drawer always passes `priority = "drawer"`.

---

## 5. Drawer integration (Lua-side rendering)

### `TABLE_LIKE_TYPES` set — `lua/dbee/ui/drawer/init.lua:146-149`

```lua
local TABLE_LIKE_TYPES = {
  table = true,
  view = true,
}
```

**CRITICAL Phase 17 change** (per CONTEXT.md OQ-01 RESOLVED): add `materialized_view = true`. Used at 6 sites:
- `init.lua:597` — node-type check.
- `init.lua:703` — node-type check.
- `init.lua:899` — node-type check.
- `init.lua:1421` — `_materialize_table_like_branch` selection.
- `init.lua:3271` — `find_fk_target_node` predicate (FK navigation).
- `convert.lua:312` (sibling indirection) — `decorate_structure_node`'s legacy branch (`struct.type == "table" or struct.type == "view"`).

ALL six sites must accept `materialized_view` after Phase 17. The `decorate_structure_node` early-return at `convert.lua:278` (`if struct.type ~= "table" and struct.type ~= "view" and struct.type ~= "procedure" and struct.type ~= "function" then`) likewise needs `materialized_view` accepted — otherwise MVs lose `action_1` (helpers picker) and `lazy_children` decoration.

### `rich_metadata_support` cache lookup — `init.lua:400-418`

```lua
local function rich_metadata_support(ui, conn_id)
  if type(ui.handler.connection_supports_rich_metadata) ~= "function" then
    return { columns = false, indexes = false, sequences = false }
  end
  local ok, support = pcall(ui.handler.connection_supports_rich_metadata, ui.handler, conn_id)
  if not ok or type(support) ~= "table" then
    return { columns = false, indexes = false, sequences = false }
  end
  return { columns = support.columns == true, indexes = support.indexes == true, sequences = support.sequences == true }
end
```

Drawer probes the handler before deciding rich-folder vs legacy. Phase 17 requires no change.

### `_ensure_rich_metadata_branch` — `init.lua:1221-1240`

Per-branch state machine (`cached.loading / .raw / .error / .error_kind`). Critical bit: **queue_full is retryable** (line 1225-1226):

```lua
local retry_queue_full = cached.error_kind == "queue_full"
if cached.loading or cached.raw ~= nil or (cached.error ~= nil and not retry_queue_full) then
  return cached
end
```

This is Phase 16 impl-fix r1 MED-#3. `queue_full` clears on re-expand; other error kinds (`schema_filter_blocked`, `unsupported`, `transport`, `superseded`, `filter_changed_during_reconnect`) stay terminal. Phase 17 inherits this as-is.

### `_ensure_columns_rich_prefetch` — `init.lua:1247-1262`

Called once when a table node expands; prefetches columns asynchronously into the `columns_rich` branch ID (the metadata-folder ID for the `columns` kind). The Columns folder's `lazy_children` then just returns `build_branch_nodes(...)` — no second RPC.

### `_build_rich_table_children` — `init.lua:1269-1301`

```lua
function DrawerUI:_build_rich_table_children(conn_id, table_node_id, struct)
  local support = rich_metadata_support(self, conn_id)
  if support.columns ~= true then
    return self:_materialize_legacy_table_like_branch(conn_id, table_node_id, struct)
  end

  local nodes = {}
  local columns_branch_id = self:_ensure_columns_rich_prefetch(conn_id, table_node_id, struct)
  nodes[#nodes + 1] = convert.metadata_folder_node(table_node_id, "columns", "Columns", function() ... end)

  if support.indexes == true then
    local indexes_branch_id = convert.metadata_folder_node_id(table_node_id, "indexes")
    nodes[#nodes + 1] = convert.metadata_folder_node(table_node_id, "indexes", "Indexes", function()
      self:_ensure_rich_metadata_branch(conn_id, indexes_branch_id, INDEXES_KIND, ..., function(request_id)
        self.handler:connection_get_indexes_async(conn_id, request_id, indexes_branch_id, current_root_epoch(self, conn_id), {
          table = struct.name, schema = struct.schema, materialization = struct.type, ...
        })
      end)
      return build_branch_nodes(self, conn_id, indexes_branch_id, INDEXES_KIND)
    end)
  end
  return nodes
end
```

Phase 17 reuses this unchanged. `struct.type` will be `"materialized_view"` for MVs after the OQ-01 fix; it gets passed as `materialization` straight through to Go.

### `_build_sequences_folder` — `init.lua:1308-1328`

Sequences folder lives at the SCHEMA level, NOT per-table. Lazy-fetched on folder expand. Reused unchanged in Phase 17.

### Convert module — column/index/sequence label rendering

`lua/dbee/ui/drawer/convert.lua`:
- `column_label(column)` (lines 88-110) — current annotations:
  - `[PK]` if `column.primary_key == true` (line 90-92).
  - `[NOT NULL]` if `column.nullable == false` (line 93-95).
  - `[FK→target.col]` for each foreign key (line 97-103). Composite uses `target_column1+target_column2` per `fk_ref_label` at line 67-84.
  - Final shape: `name   [type] [PK] [NOT NULL] [FK→...]`.
- `column_nodes(parent_id, columns, opts)` (lines 116-141) — copies `column.foreign_keys` onto the node as `fk_refs` for FK navigation.
- `index_nodes(parent_id, indexes)` (lines 170-197) — emits `name   [UNIQUE] [col1 ASC, col2 DESC]`. **Currently does NOT have INCLUDE column rendering.** Phase 17 must add this.
- `sequence_nodes(parent_id, sequences)` (lines 202-223) — emits `name   [inc N] [cache M]`. No PG-specific changes needed.

**Phase 17 additive renderers**:
- Extend `column_label` to add `[GEN]` (when `column.generated ~= ""` or `column.generated == true`), `[IDENTITY]` (when `column.identity ~= ""`), `[DEFAULT=expr]` (truncated/escaped). Order convention: `[type] [PK] [NOT NULL] [GEN] [IDENTITY] [DEFAULT=...] [FK→...]` per CONTEXT.md §specifics.
- Extend `index_nodes` to render INCLUDE columns separately, e.g. `name   [UNIQUE] [col1 ASC, col2 DESC] [INCLUDE col3, col4]`.

### Default `gd` mapping for FK navigation — `lua/dbee/config.lua:107`

```lua
{ key = "gd", mode = "n", action = "fk_navigate" },
```

Wired Phase 16; no change for Phase 17.

### FK navigation (direct dispatch, no refresh) — `init.lua:3242-3358, 3970-3992`

```lua
local function navigate_current_fk()
  local node = self.tree:get_node()
  local refs = node_fk_refs(node)
  if #refs == 0 then ... return false end
  if #refs == 1 then navigate_fk_ref(node, refs[1]); return true end
  -- multi-FK menu picker
end
```

`<CR>` (`toggle`) is FK-aware at line 3970-3988: if the column has FK refs, navigate; else expand/collapse. `gd` (`fk_navigate`) bypasses to direct dispatch (line 3990-3992). Phase 17 inherits this behaviour. The only Phase 17 concern: `find_fk_target_node` at `init.lua:3262-3289` uses `TABLE_LIKE_TYPES[node.type] == true` (line 3271) — once `materialized_view` is in the set, FK targets that ARE matviews become navigable too.

### Drawer event consumption — `init.lua:1866-1867, 2507-2549`

```lua
handler:register_event_listener("structure_children_loaded", function(data)
  o:on_structure_children_loaded(data)
end)
```

`on_structure_children_loaded` (line 2507-2549):
- Validates `request_id == state.request_gen` (stale rejection).
- Validates `payload_epoch == current_root_epoch(self, data.conn_id)` (epoch rejection).
- Sets `state.error = data.error or data.error_kind` and `state.error_kind = data.error_kind`.
- On success: `state.raw = data[structure_children_payload_field(kind)] or {}`.
- `structure_children_payload_field(kind)` (line 422-430) maps kind → `"columns"` | `"indexes"` | `"sequences"`.

Phase 17 production code touches none of this; new rendered annotations live in `convert.lua` only.

---

## 6. `schema_filter_authority` routing (DO NOT EDIT)

### API — `lua/dbee/schema_filter_authority.lua`

```lua
M.read(handler, conn_id) → SchemaFilterAuthority { status = "ok"|"api_absent_legacy"|"authority_unavailable", scope = table? }
M.is_fail_closed(authority) → boolean
M.fail_closed_scope() → table (FAIL_CLOSED_SIGNATURE = "schema-filter-v1|fail-closed")
M.legacy_implicit_all() → table
```

### Phase 16 routing pattern — used at TWO Lua sites Phase 17 inherits

#### Site A — `lua/dbee/handler/init.lua:3127-3134`

```lua
function Handler:_rich_metadata_schema_allowed(waiter)
  local authority = schema_filter_authority.read(self, waiter.conn_id)
  if schema_filter_authority.is_fail_closed(authority) then
    return false
  end
  if authority.status == "ok" and not schema_filter.matches(waiter.schema or "", authority.scope) then
    self:_emit_rich_metadata_unsupported(waiter)
    return false
  end
  return true
end
```

This is the gate that blocks RPC dispatch BEFORE the Go endpoint is called. Postgres rich-metadata RPCs route through here automatically because `connection_get_columns_rich_async` etc. all pass through `connection_get_rich_metadata_singleflight`.

#### Site B — `lua/dbee/handler/init.lua:3060-3066` (legacy `connection_get_columns_async`)

```lua
function Handler:connection_get_columns_async(id, request_id, branch_id, root_epoch, opts)
  local authority = schema_filter_authority.read(self, id)
  if schema_filter_authority.is_fail_closed(authority) then
    return
  end
  if authority.status == "ok" and not schema_filter.matches(opts and opts.schema or "", authority.scope) then
    return
  end
  vim.fn.DbeeConnectionGetColumnsAsync(id, request_id, branch_id, root_epoch, { ... })
end
```

This pattern is the canonical "block-RPC-on-schema-filter" wrapper. Phase 17 production code DOES NOT modify either site; it just gets the same enforcement automatically via `connection_get_columns_rich_async`.

### `schema_filter_authority` is locked

`lua/dbee/schema_filter_authority.lua` is a Phase 14 single-source helper (one of three: schema_filter_authority, schema_name_canonical, epoch_authority). CONTEXT.md §Phase Boundary explicitly forbids edits. Phase 17 inherits the helper's behaviour by reusing the singleflight wrappers.

---

## 7. Test infrastructure

### Strict unit tests — sqlmock pattern (Oracle reference)

`dbee/adapters/oracle_driver_rich_metadata_test.go` (185 lines, 5 tests):

```go
func newOracleRichMetadataMock(t *testing.T) (*oracleDriver, sqlmock.Sqlmock) {
    t.Helper()
    db, mock, err := sqlmock.New(sqlmock.QueryMatcherOption(sqlmock.QueryMatcherEqual))
    require.NoError(t, err)
    t.Cleanup(func() { _ = db.Close() })
    return &oracleDriver{c: builders.NewClient(db), db: db}, mock
}

func oracleRichTableArgs() []driver.Value {
    return []driver.Value{
        sql.Named("p_schema", "APP"),
        sql.Named("p_table", "ACCOUNT"),
    }
}

mock.ExpectQuery(oracleColumnsRichSQL).
    WithArgs(args...).
    WillReturnRows(sqlmock.NewRows([]string{"column_name", "data_type", "nullable"}).
        AddRow("ID", "NUMBER", "N").
        AddRow("CUSTOMER_ID", "NUMBER", "N").
        ...)
```

Key facts:
- `sqlmock.QueryMatcherEqual` requires EXACT SQL match — Phase 17 must declare SQL constants identical to what the test asserts.
- Args use `[]driver.Value{sql.Named(...)}` for Oracle; **Phase 17 must use `[]driver.Value{"public", "account"}` (positional)** for Postgres.
- `t.Log("RICH16_FOO=true")` markers are emitted from Go tests; they can be aggregated by CI if needed (the headless script does its own assertions independently).

`dbee/go.mod:10` has `github.com/DATA-DOG/go-sqlmock v1.5.2` — already a dependency. Phase 17 needs no new deps.

### Backward-compat unit test — `dbee/core/rich_metadata_types_test.go`

```go
func TestRichMetadataTypesBackwardCompat(t *testing.T) {
    var col Column
    if err := json.Unmarshal([]byte(`{"name":"ID","type":"NUMBER"}`), &col); err != nil { ... }
    if col.Nullable != nil || col.PrimaryKey || col.PrimaryKeyOrdinal != 0 || len(col.ForeignKeys) != 0 {
        t.Fatalf("rich fields should default to zero values: %#v", col)
    }
    ...
    t.Log("RICH16_GO_TYPES_BACKWARD_COMPAT=true")
}
```

Phase 17 should add an analogous test ensuring `Generated`, `Identity`, `Default`, `IncludeColumns` etc. all default to zero values when the JSON payload omits them. This locks in the back-compat contract.

### Marshal preservation test — `dbee/handler/rich_metadata_marshal_test.go`

Encodes `*core.Column` via `WrapColumns(...)` then decodes into a payload struct, verifying every field round-trips. Phase 17 should extend this OR add a parallel `rich_metadata_marshal_postgres_test.go` covering the new additive fields.

### Integration test — `dbee/tests/integration/postgres_integration_test.go`

Uses testcontainer `postgres:16-alpine` via `dbee/tests/testhelpers/postgres.go`. Existing seed at `dbee/tests/testdata/postgres_seed.sql` (currently 22 lines, basic test_table + test_view). Phase 17 may extend with the rich fixture from Codex research §7 (parent_account composite PK, child_account FK, INCLUDE index, expression index, sequence, materialized view).

CONTEXT.md PG-26/PG-27 explicit: **integration tests are optional confidence; strict markers must run without Docker**. So sqlmock unit tests are the gating path.

### Headless marker script — `ci/headless/check_rich_metadata.lua`

Pattern (655 lines for Oracle):
- Import production sources via `read("path")` and assert literal substrings (`assert_contains`).
- Build a fake handler with `vim.fn.DbeeConnection*Async = function(...)` shims.
- Inject events via `_on_rich_metadata_loaded` and assert `captured_events`.
- Each verified property emits `mark("RICH16_FOO_OK")` then enumerated in `strict_markers` list at the end.
- Sentinel: `RICH16_ALL_PASS=true` printed on green.

Phase 17 produces a parallel `ci/headless/check_rich_metadata_postgres.lua` (recommended per Codex §9 + CONTEXT.md PG-29). Required marker themes per CONTEXT.md PG-28:
- `RICH_PG_SUPPORT_TRUE`
- `RICH_PG_POSITIONAL_BINDS`
- `RICH_PG_CATALOG_SCOPING`
- `RICH_PG_RICH_COLUMNS_OK`
- `RICH_PG_GENERATED_LABEL_OK`
- `RICH_PG_DEFAULT_LABEL_OK`
- `RICH_PG_IDENTITY_LABEL_OK`
- `RICH_PG_COMPOSITE_PK_OK`
- `RICH_PG_COMPOSITE_FK_OK`
- `RICH_PG_INDEXES_OK`
- `RICH_PG_INCLUDE_COLUMNS_OK`
- `RICH_PG_PK_BACKED_HIDDEN`
- `RICH_PG_SEQUENCES_OK`
- `RICH_PG_SCHEMA_FILTER_NO_QUERY_OK`
- `RICH_PG_MATERIALIZED_VIEW_FOLDER_OK`
- `RICH_PG_ALL_PASS`

---

## 8. Materialized view rendering today — full trace

### Today's flow (PostgreSQL + matview)

1. `dbee/adapters/postgres_driver.go:69-83` — `StructureWithOptions` query:
   ```sql
   SELECT schema_name, object_name, object_type FROM (
     SELECT table_schema, table_name, table_type FROM information_schema.tables ...
     UNION ALL
     SELECT schemaname, matviewname, 'VIEW' AS object_type FROM pg_matviews ...
   ) ...
   ```
   Matviews are LITERALLY labeled `'VIEW'` in the SELECT.

2. `getPGStructureType("VIEW")` → `core.StructureTypeView` (postgres_driver.go:175). Branch for `"MATERIALIZED VIEW"` exists (line 177-178) but is unreachable on the Postgres data path.

3. msgpack → Lua via `structureWrap.MarshalMsgPack` (`marshal.go:179-194`) → `Type: cw.structure.Type.String()` = `"view"`.

4. Drawer node receives `struct.type = "view"`, treated as a regular view.

5. `TABLE_LIKE_TYPES = { table = true, view = true }` includes view → matviews currently DO get Columns folder rendering (because they show up as views).

### What Phase 17 must change

Per CONTEXT.md OQ-01 RESOLVED:

A. **`postgres_driver.go:73, 106`**: change `'VIEW' AS object_type` → `'MATERIALIZED VIEW' AS object_type` in BOTH the full `StructureWithOptions` UNION ALL branch and the per-schema `StructureForSchema` UNION ALL branch.

B. **`getPGStructureType` (line 171-186)**: existing `case "MATERIALIZED VIEW": return core.StructureTypeMaterializedView` will now actually trigger.

C. **Lua `TABLE_LIKE_TYPES` (`drawer/init.lua:146-149`)**: add `materialized_view = true`.

D. **Lua `convert.decorate_structure_node` (`convert.lua:278`)**: change the gate
   ```lua
   if struct.type ~= "table" and struct.type ~= "view" and struct.type ~= "procedure" and struct.type ~= "function" then
   ```
   to also accept `materialized_view`. AND `convert.lua:312` (`elseif struct.type == "table" or struct.type == "view" then`) to accept `materialized_view` for column-rendering.

E. **Drawer site checks** at `drawer/init.lua:597, 703, 899, 1421, 3271` — use `TABLE_LIKE_TYPES[node.type]` so they auto-pick up matview support.

F. **Icon mapping** at `lua/dbee/config.lua:172-176` already declares an icon for `materialized_view` (`""` Conditional). Existing UI primitives already aware of the type; the only blockers are at the data-source layer.

G. **Rich metadata SQL** (`postgresColumnsRichSQL`, `postgresIndexesSQL`) MUST include `'m'` in the `relkind IN (...)` filter (Codex research already covers this in §6 and SQL constants).

H. **Tests** must cover MV branch: integration seed includes a matview, sqlmock unit test exercises a `c.relkind = 'm'` flow, headless marker `RICH_PG_MATERIALIZED_VIEW_FOLDER_OK` asserts drawer renders Columns/Indexes folders for the new type.

---

## 9. Backward compatibility (additive field rules)

### Locked contract from Phase 16

Per CONTEXT.md §Phase Boundary line 16: "Backward-compat: old client decoding new Column with optional fields succeeds".

### How Phase 16 achieves it

**JSON**: every additive field uses `json:"name,omitempty"`. `encoding/json.Unmarshal` ignores fields the JSON omits, leaving them at Go zero values. Verified in `core/rich_metadata_types_test.go:8-18`.

**msgpack**: every additive field in the `MarshalMsgPack` anonymous structs uses `msgpack:"name,omitempty"`. `neovim/go-client/msgpack` decoder ignores unknown keys by default and treats absent keys as zero. Verified in `handler/rich_metadata_marshal_test.go`.

**Pointer-vs-zero distinction**: `Nullable *bool` is a pointer because `false` is meaningful (column is NOT NULL); a `nil` pointer means "unknown / not provided by old payload". This pattern lets the renderer distinguish "we didn't ask" from "we asked and the column is nullable".

**Slice fields**: `[]*FKRef` and `[]string` default to `nil` slice when absent. `len(nil) == 0` so renderers safely iterate.

### Phase 17 additive fields — concrete tag templates

```go
type Column struct {
    Name string `json:"name" msgpack:"name"`
    Type string `json:"type" msgpack:"type"`

    Nullable          *bool    `json:"nullable,omitempty" msgpack:"nullable,omitempty"`
    PrimaryKey        bool     `json:"primary_key,omitempty" msgpack:"primary_key,omitempty"`
    PrimaryKeyOrdinal int      `json:"primary_key_ordinal,omitempty" msgpack:"primary_key_ordinal,omitempty"`
    ForeignKeys       []*FKRef `json:"foreign_keys,omitempty" msgpack:"foreign_keys,omitempty"`

    // Phase 17 additive fields (PostgreSQL-specific but type-shared).
    Generated      string `json:"generated,omitempty" msgpack:"generated,omitempty"`        // attgenerated
    Identity       string `json:"identity,omitempty" msgpack:"identity,omitempty"`          // attidentity
    Default        string `json:"default,omitempty" msgpack:"default,omitempty"`            // pg_get_expr
    SerialSequence string `json:"serial_sequence,omitempty" msgpack:"serial_sequence,omitempty"` // pg_get_serial_sequence
}

type Index struct {
    Name     string   `json:"name" msgpack:"name"`
    Schema   string   `json:"schema,omitempty" msgpack:"schema,omitempty"`
    Table    string   `json:"table,omitempty" msgpack:"table,omitempty"`
    Columns  []string `json:"columns" msgpack:"columns"`
    Orders   []string `json:"orders,omitempty" msgpack:"orders,omitempty"`
    Unique   bool     `json:"unique,omitempty" msgpack:"unique,omitempty"`
    PKBacked bool     `json:"pk_backed,omitempty" msgpack:"pk_backed,omitempty"`

    // Phase 17 additive — INCLUDE columns separated from key columns.
    IncludeColumns []string `json:"include_columns,omitempty" msgpack:"include_columns,omitempty"`
}
```

### Marshal sites that MUST be extended

1. `dbee/handler/marshal.go:255-274` — `columnWrap.MarshalMsgPack`: add `Generated, Identity, Default, SerialSequence` to the inline anonymous struct AND assign from `cw.column.Generated` etc.
2. `dbee/handler/marshal.go:305-326` — `indexWrap.MarshalMsgPack`: add `IncludeColumns []string \`msgpack:"include_columns,omitempty"\`` and assign from `iw.index.IncludeColumns`.
3. `dbee/handler/event_bus.go:361-384` — `columnsToLua`: extend `Sprintf` template to include `generated=%q, identity=%q, default=%q, serial_sequence=%q` (or use `luaOptionalString` for empty-string-as-nil discipline).
4. `dbee/handler/event_bus.go:415-439` — `indexesToLua`: extend to include `include_columns = stringsToLua(index.IncludeColumns)`.

### Old-client decoding new payload — tested how

The `TestRichMetadataTypesBackwardCompat` pattern asserts old JSON round-trips into new Go struct without losing any data. Phase 17 adds the symmetric assertion: NEW JSON `{"name":"x","type":"y","generated":"s","identity":"a","default":"now()"}` MUST decode in old-style `struct { Name, Type string }` without error (json/msgpack libraries ignore unknown keys by default).

---

## 10. Things that scared the orchestrator about Phase 16 (gotchas to avoid)

### Gotcha A — `epoch_authority.lua` is a locked single-source helper

`lua/dbee/lsp/epoch_authority.lua` (112 lines) provides `check_fresh / read_with_freshness / admit_write`. Phase 16 production rich-metadata code uses `Handler:get_authoritative_root_epoch(conn_id)` and `current_root_epoch(self, conn_id)` to coordinate epochs (see `init.lua:3169` in handler and 1253/1288/1320 in drawer). Phase 17 inherits these patterns; **must NOT add bespoke epoch tracking** — go through `epoch_authority` if any new freshness check is needed.

### Gotcha B — supersession + waiter fanout pattern (Phase 16 impl-fix r1, commit `c3dd1a8`)

This was the SOURCE of three bugs in Phase 16 r1 that all required architectural fixes:

1. **HIGH r1#1 — waiter fanout collision**: queue_full waiter re-emits via `structure_children_loaded` shared `request_id` space with internal flights. Solved by `data.fanout_source = "rich_metadata_waiter"` field; consumer at `_on_rich_metadata_loaded` (line 2063-2065) returns early when `fanout_source ~= nil`.

2. **HIGH r1#2 — supersession decremented active slots while Go RPC ran**: superseded flights tombstoned (Option B) — slot stays counted until completion returns. See `_supersede_rich_metadata_flights` (line 1172-1198) and `_on_rich_metadata_loaded` superseded branch (line 2084-2090).

3. **MED r1#3 — queue_full treated as terminal**: Fix in `_ensure_rich_metadata_branch` (line 1225-1226): `retry_queue_full = cached.error_kind == "queue_full"` clears on re-expand.

**Phase 17 must NOT regress any of these.** All three fixes are in the singleflight + drawer machinery; Phase 17 production code does not touch them, but the ci/headless suite SHOULD include parallel sentinels:
- `RICH_PG_WAITER_FANOUT_ISOLATED` (mirror of `RICH16_WAITER_FANOUT_ISOLATED_FROM_INTERNAL_FLIGHTS`)
- `RICH_PG_SUPERSESSION_PRESERVES_ACTIVE_SLOT` (mirror of `RICH16_SUPERSESSION_PRESERVES_ACTIVE_SLOT_UNTIL_COMPLETION`)
- `RICH_PG_QUEUE_FULL_RETRYABLE` (mirror of `RICH16_QUEUE_FULL_RETRYABLE_ON_REEXPAND_OK`)

OR the existing RICH16 suite could be re-run against the Postgres driver path. Either way, plan-phase should decide.

### Gotcha C — Phase 16 used Oracle-specific named binds

Oracle uses `:p_schema`, `:p_table` (`oracle_driver.go:399, 412, 484, 533, 573`). When Codex first wrote `oracleColumnsRichSQL` it used `:schema, :table` which collided with Oracle reserved word `TABLE` (ORA-01745 — see commit `c769cd0` "fix(16): rename Oracle bind vars to avoid ORA-01745"). Phase 17 sidesteps this entirely — positional `$1, $2`. **No reserved-word-collision risk for Postgres.**

### Gotcha D — `decorate_structure_node` early-return excludes new types

`convert.lua:277-283`:
```lua
function M.decorate_structure_node(node, handler, result, conn_id, struct, lazy_children_factory)
  if struct.type ~= "table" and struct.type ~= "view" and struct.type ~= "procedure" and struct.type ~= "function" then
    if type(lazy_children_factory) == "function" then
      node.lazy_children = lazy_children_factory
    end
    return node
  end
  ...
end
```

Adding `materialized_view` to `TABLE_LIKE_TYPES` is INSUFFICIENT if this function still early-returns. Phase 17 plan must edit BOTH places.

### Gotcha E — `find_fk_target_node` uses `TABLE_LIKE_TYPES`

`init.lua:3271` `return TABLE_LIKE_TYPES[node.type] == true and ...`. Once `materialized_view` is in the set, FK navigation can target matviews. This is desired but should be plan-noted — a matview rarely receives FK references but is technically possible if defined externally.

### Gotcha F — singleflight-key includes materialization

The key includes `tostring(materialization or "")` (`init.lua:792`). PostgreSQL adapter MUST pass `struct.type` as `materialization` when invoking via the drawer (already done — see `drawer/init.lua:1256, 1291`). After Phase 17, `materialization` will be `"materialized_view"` for MVs, `"table"` for tables/partitioned tables, `"view"` for views. Distinct keys → distinct flights → distinct cache slots. No collision.

### Gotcha G — `cloneStrings` namespace

`oracle_driver.go:642, 647` calls `cloneStrings(...)`. The `core/types.go:271-278` `cloneStrings` is package-private. The Oracle adapter must define its own (search the file or reuse a shared one in `dbee/adapters/`). Phase 17 must define or reuse a `cloneStrings` similarly — be explicit in plan-phase.

### Gotcha H — adapter test must use sqlmock with positional placeholders

The Oracle test uses `sql.Named("p_schema", "APP")`. Phase 17 mock args MUST be:

```go
func newPostgresRichMetadataMock(t *testing.T) (*postgresDriver, sqlmock.Sqlmock) {
    db, mock, _ := sqlmock.New(sqlmock.QueryMatcherOption(sqlmock.QueryMatcherEqual))
    t.Cleanup(func() { _ = db.Close() })
    return &postgresDriver{c: builders.NewClient(db), url: nil}, mock
}

mock.ExpectQuery(postgresColumnsRichSQL).
    WithArgs("public", "account").
    WillReturnRows(...)
```

Note `postgresDriver` has a non-pointer `url` field — passing `nil` is fine because rich-metadata methods don't touch `c.url` (only `SelectDatabase` does).

### Gotcha I — `format_type` returns `text[]`, `numeric(10,2)`, etc. — type strings include parens/punctuation

The drawer's column label format is `name   [type] [PK] [...]`. PG types like `numeric(10, 2)` will produce `name   [numeric(10, 2)] [PK]` — the existing `column_label` template wraps in `[...]` so this is fine, but visually busier than Oracle's simpler types. No fix needed; just be aware.

### Gotcha J — JSON / JSONB type processors are at `postgres.go:38-51`

Already wired; rich-metadata path returns no JSON columns (catalog returns text/int/oid). No interaction.

---

## Cross-references and final quotations

### File:line index for plan-phase consumption

**Adapter source files**:
- `dbee/adapters/postgres.go` (90 lines)
- `dbee/adapters/postgres_driver.go` (238 lines)
- `dbee/adapters/oracle_driver.go:394-800` (Phase 16 reference impl)
- `dbee/adapters/schema_filter.go` (helpers)

**Core types**:
- `dbee/core/connection.go:47-67` (interfaces)
- `dbee/core/connection.go:284-336` (Connection wrappers)
- `dbee/core/types.go:227-269` (Column / FKRef / Index / Sequence)
- `dbee/core/builders/client.go:96-105` (QueryWithArgs)

**Handler / RPC**:
- `dbee/handler/handler.go:548-752` (rich-metadata async methods)
- `dbee/handler/event_bus.go:233-462` (StructureChildrenLoaded + serializers)
- `dbee/handler/marshal.go:255-343` (columnWrap / fkRefWrap / indexWrap / sequenceWrap)
- `dbee/endpoints.go:537-626` (RPC registration)

**Lua handler**:
- `lua/dbee/handler/init.lua:8-22` (constants)
- `lua/dbee/handler/init.lua:778-817` (singleflight key + payload-field helper)
- `lua/dbee/handler/init.lua:977-1198` (support cache + flight machinery)
- `lua/dbee/handler/init.lua:2057-2123` (`_on_rich_metadata_loaded`)
- `lua/dbee/handler/init.lua:3060-3097` (legacy + support cache)
- `lua/dbee/handler/init.lua:3158-3290` (singleflight entrypoints)

**Drawer**:
- `lua/dbee/ui/drawer/init.lua:140-149` (TABLE_LIKE_TYPES + kind constants)
- `lua/dbee/ui/drawer/init.lua:400-418` (rich_metadata_support helper)
- `lua/dbee/ui/drawer/init.lua:420-430` (structure_children_payload_field)
- `lua/dbee/ui/drawer/init.lua:1206-1346` (`_materialize_cached_*` / `_ensure_rich_metadata_branch` / `_build_rich_table_children` / `_build_sequences_folder` / `_with_schema_metadata_children`)
- `lua/dbee/ui/drawer/init.lua:2507-2549` (on_structure_children_loaded)
- `lua/dbee/ui/drawer/init.lua:3242-3358` (FK navigation helpers)
- `lua/dbee/ui/drawer/init.lua:3970-3992` (toggle + fk_navigate actions)
- `lua/dbee/ui/drawer/convert.lua:67-223` (label rendering)
- `lua/dbee/ui/drawer/convert.lua:277-319` (decorate_structure_node)
- `lua/dbee/config.lua:107` (gd default mapping)
- `lua/dbee/config.lua:172-176` (materialized_view icon)

**Locked single-source helpers (DO NOT EDIT)**:
- `lua/dbee/schema_filter_authority.lua` (61 lines)
- `lua/dbee/schema_name_canonical.lua` (Phase 11 r6)
- `lua/dbee/lsp/epoch_authority.lua` (112 lines)

**Tests**:
- `dbee/adapters/oracle_driver_rich_metadata_test.go` (185 lines, sqlmock pattern)
- `dbee/handler/rich_metadata_marshal_test.go` (99 lines, msgpack round-trip)
- `dbee/core/rich_metadata_types_test.go` (28 lines, JSON back-compat)
- `dbee/tests/integration/postgres_integration_test.go` (190 lines, testcontainer)
- `dbee/tests/testhelpers/postgres.go` (75 lines, container helper)
- `dbee/tests/testdata/postgres_seed.sql` (22 lines today; Phase 17 may extend)
- `ci/headless/check_rich_metadata.lua` (655 lines, RICH16_* marker template)

---

## Summary checklist (for plan-phase)

Phase 17 production touches these files:

| File | Change kind |
|------|-------------|
| `dbee/adapters/postgres.go` | none (no edit expected) |
| `dbee/adapters/postgres_driver.go` | (a) update interface assertions; (b) change `'VIEW'` → `'MATERIALIZED VIEW'` in two UNION branches; (c) add SQL constants + `SupportsRichMetadata / ColumnsRich / Indexes / Sequences` methods + helper FK grouping. Likely split into new file `postgres_driver_rich_metadata.go`. |
| `dbee/core/types.go` | add `Generated, Identity, Default, SerialSequence` to `Column`; add `IncludeColumns` to `Index` (all `,omitempty` JSON+msgpack) |
| `dbee/handler/marshal.go` | extend `columnWrap` and `indexWrap` MarshalMsgPack inline structs with new fields |
| `dbee/handler/event_bus.go` | extend `columnsToLua` and `indexesToLua` Lua-table emission with new fields |
| `dbee/handler/handler.go` | NONE (already routes through `Connection.GetColumnsRich/GetIndexes/GetSequences`) |
| `dbee/endpoints.go` | NONE |
| `lua/dbee/api/__register.lua` | NONE |
| `lua/dbee/handler/init.lua` | NONE (rich-metadata machinery is adapter-agnostic) |
| `lua/dbee/ui/drawer/init.lua` | (a) add `materialized_view = true` to `TABLE_LIKE_TYPES`; verify all 6 sites pick this up automatically |
| `lua/dbee/ui/drawer/convert.lua` | (a) extend `column_label` with `[GEN] [IDENTITY] [DEFAULT=...]`; (b) extend `index_nodes` with `[INCLUDE col_a, col_b]`; (c) accept `materialized_view` in `decorate_structure_node` early-return AND in column-rendering branch |
| `lua/dbee/config.lua` | NONE (icon already configured) |
| `lua/dbee/schema_filter_authority.lua` | LOCKED — DO NOT EDIT |
| `lua/dbee/schema_name_canonical.lua` | LOCKED |
| `lua/dbee/lsp/epoch_authority.lua` | LOCKED |
| `dbee/adapters/postgres_driver_rich_metadata_test.go` | NEW — sqlmock unit tests |
| `dbee/core/rich_metadata_types_test.go` | EXTEND — back-compat for new fields |
| `dbee/handler/rich_metadata_marshal_test.go` | EXTEND or sibling `rich_metadata_marshal_postgres_test.go` |
| `dbee/tests/testdata/postgres_seed.sql` | OPTIONAL extend with rich fixture |
| `dbee/tests/integration/postgres_integration_test.go` | OPTIONAL adds rich-metadata tests |
| `ci/headless/check_rich_metadata_postgres.lua` | NEW — `RICH_PG_*` marker suite |

---

## Discrepancies between Phase 16 reference and CONTEXT.md (none material)

I checked CONTEXT.md against the actual Phase 16 implementation. No contradictions found.

- CONTEXT.md PG-04 ("positional only") matches `lib/pq` reality.
- CONTEXT.md PG-05 (singleflight key shape) matches `rich_metadata_key` exactly.
- CONTEXT.md PG-18 (`PKBacked=true`, drawer hides) matches `convert.lua` (drawer `index.pk_backed ~= true` filter, asserted at `check_rich_metadata.lua:520`).
- CONTEXT.md OQ-01 RESOLVED matches the empty `MATERIALIZED VIEW` branch I found in `getPGStructureType` — Phase 17 will populate the unreachable branch.
- CONTEXT.md "old client decoding new struct" matches the `TestRichMetadataTypesBackwardCompat` pattern.
- Codex SQL constants (5) align with the 5 Oracle constants pattern.

The only minor item worth surfacing for plan-phase:

- **Codex § 5 says** `dbee/adapters/postgres.go:9` confirms `lib/pq` and `:33` confirms `sql.Open("postgres", ...)`. Both confirmed in this research. ✅
- **Codex SQL `postgresColumnsRichSQL` includes `c.relkind IN ('r', 'p', 'f', 'v', 'm')`**, which Phase 17 needs to implement; CONTEXT.md PG-24 explicitly scopes rich-metadata to "tables and materialized views" but Codex SQL also includes `'v'` (view) and `'f'` (foreign table). Plan-phase decision: should rich `Columns` for plain views run? Probably yes — the Phase 16 drawer already prefetches columns for views (`view` is in `TABLE_LIKE_TYPES`). Phase 17's PG `ColumnsRich` matching Codex's `relkind IN (...)` set is consistent with this.

---

*End of research.*
