# Rich Table Metadata Research

Status: research input for a future discuss/plan phase. This document is not a locked decision record.

Target feature: DBeaver-style drawer metadata in nvim-dbee:

- Under each table: `Indexes` folder with indexes and indexed columns.
- Under each table: `Columns` folder with richer labels: `name [type] [NOT NULL] [PK] [FK->other.col]`.
- On FK link: navigate the drawer cursor to the referenced table and column.
- Under each schema: `Sequences` folder where the adapter has native sequences.

Local reference: the current user connection file is Oracle-heavy: `nkanuri*` ATP-style connections and `fusion_*` Oracle Cloud Manager connections. One local connection currently has a schema allowlist. This makes Oracle the first useful implementation target, with Phase 14 `schema_filter` and `lazy_per_schema` behavior preserved from the start.

Current repo facts:

- `dbee/core/types.go` has `Column { Name string; Type string }` only.
- `StructureType` has table/view/materialized-view/streaming-table/sink/source/managed/schema/procedure/function, but no sequence or index.
- `StructureTypeFromString` only recognizes `table`, `view`, `procedure`, and `function`.
- `dbee/handler/marshal.go` emits column msgpack as `{ name, type }`.
- `lua/dbee/ui/drawer/convert.lua` renders a column as `name   [type]`.
- Existing adapter helper SQL exposes some PK/FK/index/reference information manually, but drawer/LSP do not consume it as metadata.

## 1. Data Model

### Proposed `Column` extension

Use additive fields so old and new clients can coexist:

```go
type Column struct {
    Name string `json:"name" msgpack:"name"`
    Type string `json:"type" msgpack:"type"`

    Nullable *bool `json:"nullable,omitempty" msgpack:"nullable,omitempty"`
    PrimaryKey bool `json:"primary_key,omitempty" msgpack:"primary_key,omitempty"`
    PrimaryKeyOrdinal int `json:"primary_key_ordinal,omitempty" msgpack:"primary_key_ordinal,omitempty"`

    ForeignKeys []*FKRef `json:"foreign_keys,omitempty" msgpack:"foreign_keys,omitempty"`

    // Optional later fields. Do not block the first implementation on them.
    Default *string `json:"default,omitempty" msgpack:"default,omitempty"`
    Ordinal int `json:"ordinal,omitempty" msgpack:"ordinal,omitempty"`
}
```

Nullability semantics:

- `Nullable == nil`: adapter does not know, or the source does not have meaningful nullability.
- `Nullable != nil && *Nullable == true`: database reports nullable.
- `Nullable != nil && *Nullable == false`: database reports NOT NULL.
- Do not model unknown as `false`; that would create false `[NOT NULL]` UI labels on unsupported adapters.

Primary key semantics:

- `PrimaryKey == true` marks the source column as participating in a primary key.
- `PrimaryKeyOrdinal > 0` preserves composite PK order where the adapter can provide it.
- For adapters that only expose "this is part of PK" but not order, set `PrimaryKey = true` and leave ordinal zero.

Foreign key semantics:

- `ForeignKeys` is a slice because one column can participate in multiple FKs in unusual schemas.
- Composite FKs should be represented once per participating column with shared `ConstraintName` and `SourceOrdinal`, plus full source/target column arrays so the drawer can either render compact inline labels or a grouped details node later.
- Inline rendering should use the single target column when the FK is single-column; for composite FKs it should render a compact group label such as `FK(order_fk)` unless the user chooses a composite display policy.

### Proposed `FKRef` shape

```go
type FKRef struct {
    ConstraintName string `json:"constraint_name,omitempty" msgpack:"constraint_name,omitempty"`

    SourceSchema string `json:"source_schema,omitempty" msgpack:"source_schema,omitempty"`
    SourceTable string `json:"source_table,omitempty" msgpack:"source_table,omitempty"`
    SourceColumn string `json:"source_column,omitempty" msgpack:"source_column,omitempty"`
    SourceColumns []string `json:"source_columns,omitempty" msgpack:"source_columns,omitempty"`
    SourceOrdinal int `json:"source_ordinal,omitempty" msgpack:"source_ordinal,omitempty"`

    TargetSchema string `json:"target_schema,omitempty" msgpack:"target_schema,omitempty"`
    TargetTable string `json:"target_table,omitempty" msgpack:"target_table,omitempty"`
    TargetColumn string `json:"target_column,omitempty" msgpack:"target_column,omitempty"`
    TargetColumns []string `json:"target_columns,omitempty" msgpack:"target_columns,omitempty"`

    UpdateRule string `json:"update_rule,omitempty" msgpack:"update_rule,omitempty"`
    DeleteRule string `json:"delete_rule,omitempty" msgpack:"delete_rule,omitempty"`
    Deferrable *bool `json:"deferrable,omitempty" msgpack:"deferrable,omitempty"`
}
```

Recommended v1 implementation:

- Populate `ConstraintName`, source table/schema/column, target schema/table/column, source ordinal, and update/delete rules where available.
- Leave `Deferrable` optional. Oracle/Postgres can support it, but drawer rendering does not need it for the first pass.
- Preserve complete arrays for composite FKs even if the first drawer formatter only shows a compact marker.

### Proposed `Index` shape

Indexes should not be shoehorned into `Column`. They are table-scoped metadata with their own fields and composite column ordering:

```go
type Index struct {
    Schema string `json:"schema,omitempty" msgpack:"schema,omitempty"`
    Table string `json:"table,omitempty" msgpack:"table,omitempty"`
    Name string `json:"name" msgpack:"name"`
    Unique bool `json:"unique,omitempty" msgpack:"unique,omitempty"`
    Primary bool `json:"primary,omitempty" msgpack:"primary,omitempty"`
    Method string `json:"method,omitempty" msgpack:"method,omitempty"`
    Type string `json:"type,omitempty" msgpack:"type,omitempty"`
    Columns []IndexColumn `json:"columns,omitempty" msgpack:"columns,omitempty"`
}

type IndexColumn struct {
    Name string `json:"name,omitempty" msgpack:"name,omitempty"`
    Expression string `json:"expression,omitempty" msgpack:"expression,omitempty"`
    Ordinal int `json:"ordinal,omitempty" msgpack:"ordinal,omitempty"`
    Desc bool `json:"desc,omitempty" msgpack:"desc,omitempty"`
    NullsOrder string `json:"nulls_order,omitempty" msgpack:"nulls_order,omitempty"`
}
```

### Proposed `Sequence` shape

Sequences are schema-level metadata:

```go
type Sequence struct {
    Schema string `json:"schema,omitempty" msgpack:"schema,omitempty"`
    Name string `json:"name" msgpack:"name"`
    DataType string `json:"data_type,omitempty" msgpack:"data_type,omitempty"`
    MinValue *string `json:"min_value,omitempty" msgpack:"min_value,omitempty"`
    MaxValue *string `json:"max_value,omitempty" msgpack:"max_value,omitempty"`
    IncrementBy *string `json:"increment_by,omitempty" msgpack:"increment_by,omitempty"`
    Cycle *bool `json:"cycle,omitempty" msgpack:"cycle,omitempty"`
    CacheSize *string `json:"cache_size,omitempty" msgpack:"cache_size,omitempty"`
    LastValue *string `json:"last_value,omitempty" msgpack:"last_value,omitempty"`
}
```

Use strings for numeric sequence attributes because engines differ in numeric width, signedness, and availability. Drawer rendering can display only the sequence name initially, with details available later.

### `StructureType` extension

Add:

```go
const (
    StructureTypeSequence StructureType = ...
    StructureTypeIndex StructureType = ...
)
```

String forms:

- `sequence`
- `index`

Rationale:

- `sequence` belongs in the structure tree under a schema. It is a first-class schema object in Oracle, Postgres, SQL Server, DuckDB, and some Redshift-like systems.
- `index` is not a root table peer in every database, but it is a first-class drawer node under the table metadata branch. Modeling it as a structure type keeps drawer tree nodes consistent and leaves room for adapters that expose indexes as independent catalog objects.
- `Index` should still have a dedicated payload shape. A `Structure` node can identify an index in the drawer, but the index's columns, uniqueness, method, and expression fields do not fit cleanly into `Structure`.

### Backwards compatibility

Wire formats should degrade additively:

- New Go binary to old Lua: old Lua reads `name` and `type`; extra msgpack fields on column tables are ignored.
- Old Go binary to new Lua: missing `nullable`, `primary_key`, and `foreign_keys` means unknown/unsupported; drawer renders the old `name [type]` row.
- New Lua to old Go: calls to new endpoints must be feature-detected through manifest/RPC existence checks or handler capability probes before use.
- Existing `connection_get_columns` must keep returning an array of tables with at least `name` and `type`.
- Existing `structure_loaded` and `structure_children_loaded` event shapes should stay valid. Add fields rather than replacing `columns`.

Recommended compatibility rule: if metadata is absent or unsupported, omit annotations rather than showing placeholders such as `[NULL?]` or `[FK?]`.

## 2. Per-Adapter SQL Strategy

General rule: do not eager-fetch table-level PK/FK/index metadata for every table during connection expansion. Fetch it lazily per table, keyed by `(conn_id, schema, table, materialization, root_epoch, schema_filter_signature)`.

Use bind arguments where the adapter client supports them. SQL templates below use named placeholders for clarity; implementation should use each driver builder's supported binding style.

### Oracle

Current relevance: highest. Local connections are Oracle-heavy, and existing manual helper SQL already uses `all_constraints`, `all_cons_columns`, `all_indexes`, and `all_tab_columns`.

Column metadata, one table:

```sql
SELECT
  col.owner AS schema_name,
  col.table_name,
  col.column_name,
  col.data_type,
  col.data_length,
  col.data_precision,
  col.data_scale,
  col.nullable,
  col.column_id
FROM sys.all_tab_columns col
WHERE col.owner = :schema
  AND col.table_name = :table
ORDER BY col.column_id
```

Primary key columns:

```sql
SELECT
  c.owner AS schema_name,
  c.table_name,
  cc.column_name,
  cc.position AS key_ordinal,
  c.constraint_name
FROM all_constraints c
JOIN all_cons_columns cc
  ON cc.owner = c.owner
 AND cc.constraint_name = c.constraint_name
 AND cc.table_name = c.table_name
WHERE c.owner = :schema
  AND c.table_name = :table
  AND c.constraint_type = 'P'
ORDER BY cc.position
```

Foreign keys with referenced target columns:

```sql
SELECT
  fk.owner AS source_schema,
  fk.table_name AS source_table,
  fk.constraint_name,
  fk_cols.column_name AS source_column,
  fk_cols.position AS source_ordinal,
  pk.owner AS target_schema,
  pk.table_name AS target_table,
  pk_cols.column_name AS target_column,
  fk.delete_rule,
  fk.deferrable,
  fk.deferred
FROM all_constraints fk
JOIN all_cons_columns fk_cols
  ON fk_cols.owner = fk.owner
 AND fk_cols.constraint_name = fk.constraint_name
 AND fk_cols.table_name = fk.table_name
JOIN all_constraints pk
  ON pk.owner = fk.r_owner
 AND pk.constraint_name = fk.r_constraint_name
JOIN all_cons_columns pk_cols
  ON pk_cols.owner = pk.owner
 AND pk_cols.constraint_name = pk.constraint_name
 AND pk_cols.table_name = pk.table_name
 AND pk_cols.position = fk_cols.position
WHERE fk.owner = :schema
  AND fk.table_name = :table
  AND fk.constraint_type = 'R'
ORDER BY fk.constraint_name, fk_cols.position
```

Indexes:

```sql
SELECT
  i.owner AS schema_name,
  i.table_name,
  i.index_name,
  i.uniqueness,
  i.index_type,
  i.status,
  ic.column_position,
  ic.column_name,
  ic.descend
FROM all_indexes i
JOIN all_ind_columns ic
  ON ic.index_owner = i.owner
 AND ic.index_name = i.index_name
 AND ic.table_owner = i.table_owner
 AND ic.table_name = i.table_name
WHERE i.table_owner = :schema
  AND i.table_name = :table
ORDER BY i.index_name, ic.column_position
```

Sequences under one schema:

```sql
SELECT
  sequence_owner AS schema_name,
  sequence_name,
  min_value,
  max_value,
  increment_by,
  cycle_flag,
  cache_size,
  last_number
FROM all_sequences
WHERE sequence_owner = :schema
ORDER BY sequence_name
```

Performance notes:

- `all_constraints` and `all_cons_columns` are heavy on large Oracle catalogs. Always predicate by `owner` and `table_name` for table metadata.
- For schema-level sequences, predicate by `sequence_owner` and fetch only when the schema's `Sequences` branch expands.
- Oracle folds unquoted names to uppercase. Use Phase 14 adapter-aware fold when matching drawer/LSP targets.
- Avoid joining PK/FK/index metadata into schema root fetches. Oracle ATP users with many schemas need Phase 14 lazy schema behavior to stay fast.

### Postgres

Column metadata:

```sql
SELECT
  table_schema,
  table_name,
  column_name,
  data_type,
  udt_name,
  is_nullable,
  column_default,
  ordinal_position
FROM information_schema.columns
WHERE table_schema = $1
  AND table_name = $2
ORDER BY ordinal_position
```

Primary and foreign keys using `pg_constraint`:

```sql
WITH fk AS (
  SELECT
    nsp.nspname AS source_schema,
    rel.relname AS source_table,
    con.conname AS constraint_name,
    con.confupdtype,
    con.confdeltype,
    con.condeferrable,
    con.condeferred,
    src.attnum AS source_attnum,
    tgt.attnum AS target_attnum,
    src_ord.ordinality AS source_ordinal
  FROM pg_constraint con
  JOIN pg_class rel ON rel.oid = con.conrelid
  JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
  JOIN unnest(con.conkey) WITH ORDINALITY AS src(attnum, ordinality) ON true
  JOIN unnest(con.confkey) WITH ORDINALITY AS tgt(attnum, ordinality)
    ON tgt.ordinality = src.ordinality
  JOIN LATERAL (SELECT src.ordinality) src_ord ON true
  WHERE con.contype = 'f'
    AND nsp.nspname = $1
    AND rel.relname = $2
)
SELECT
  fk.source_schema,
  fk.source_table,
  fk.constraint_name,
  src_col.attname AS source_column,
  fk.source_ordinal,
  tgt_nsp.nspname AS target_schema,
  tgt_rel.relname AS target_table,
  tgt_col.attname AS target_column,
  fk.confupdtype AS update_rule,
  fk.confdeltype AS delete_rule,
  fk.condeferrable,
  fk.condeferred
FROM fk
JOIN pg_attribute src_col
  ON src_col.attrelid = (
    SELECT oid FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = fk.source_schema AND c.relname = fk.source_table
  )
 AND src_col.attnum = fk.source_attnum
JOIN pg_constraint con2 ON con2.conname = fk.constraint_name
JOIN pg_class tgt_rel ON tgt_rel.oid = con2.confrelid
JOIN pg_namespace tgt_nsp ON tgt_nsp.oid = tgt_rel.relnamespace
JOIN pg_attribute tgt_col
  ON tgt_col.attrelid = tgt_rel.oid
 AND tgt_col.attnum = fk.target_attnum
ORDER BY fk.constraint_name, fk.source_ordinal
```

The production query can be simplified, but the important design point is `unnest(conkey) WITH ORDINALITY` matched to `confkey` by ordinal to preserve composite FK order.

Primary key:

```sql
SELECT
  con.conname AS constraint_name,
  a.attname AS column_name,
  ord.ordinality AS key_ordinal
FROM pg_constraint con
JOIN pg_class rel ON rel.oid = con.conrelid
JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
JOIN unnest(con.conkey) WITH ORDINALITY AS ord(attnum, ordinality) ON true
JOIN pg_attribute a
  ON a.attrelid = rel.oid
 AND a.attnum = ord.attnum
WHERE con.contype = 'p'
  AND nsp.nspname = $1
  AND rel.relname = $2
ORDER BY ord.ordinality
```

Indexes:

```sql
SELECT
  n.nspname AS schema_name,
  t.relname AS table_name,
  i.relname AS index_name,
  ix.indisunique,
  ix.indisprimary,
  am.amname AS method,
  ord.ordinality AS column_ordinal,
  a.attname AS column_name,
  pg_get_indexdef(i.oid) AS definition
FROM pg_index ix
JOIN pg_class t ON t.oid = ix.indrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
JOIN pg_class i ON i.oid = ix.indexrelid
JOIN pg_am am ON am.oid = i.relam
LEFT JOIN unnest(ix.indkey) WITH ORDINALITY AS ord(attnum, ordinality) ON true
LEFT JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ord.attnum
WHERE n.nspname = $1
  AND t.relname = $2
ORDER BY i.relname, ord.ordinality
```

Sequences:

```sql
SELECT
  schemaname AS schema_name,
  sequencename AS sequence_name,
  data_type,
  start_value,
  min_value,
  max_value,
  increment_by,
  cycle,
  cache_size,
  last_value
FROM pg_sequences
WHERE schemaname = $1
ORDER BY sequencename
```

Fallback sequence query if `pg_sequences` is unavailable:

```sql
SELECT n.nspname AS schema_name, c.relname AS sequence_name
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'S'
  AND n.nspname = $1
ORDER BY c.relname
```

Performance notes:

- Prefer `pg_catalog` for PK/FK/index precision. `information_schema` is portable but can be slower and loses some ordering/detail.
- Query per table for PK/FK/index. Query per schema for sequences.
- Do not parse `pg_indexes.indexdef` for core behavior if `pg_index`/`pg_attribute` is available; keep `pg_get_indexdef` as display text only.

### MySQL

Column metadata:

```sql
SELECT
  TABLE_SCHEMA AS schema_name,
  TABLE_NAME AS table_name,
  COLUMN_NAME AS column_name,
  COLUMN_TYPE AS column_type,
  DATA_TYPE AS data_type,
  IS_NULLABLE AS is_nullable,
  COLUMN_KEY AS column_key,
  COLUMN_DEFAULT AS column_default,
  ORDINAL_POSITION AS ordinal_position
FROM information_schema.columns
WHERE TABLE_SCHEMA = ?
  AND TABLE_NAME = ?
ORDER BY ORDINAL_POSITION
```

Primary keys:

```sql
SELECT
  CONSTRAINT_NAME AS constraint_name,
  COLUMN_NAME AS column_name,
  ORDINAL_POSITION AS key_ordinal
FROM information_schema.key_column_usage
WHERE TABLE_SCHEMA = ?
  AND TABLE_NAME = ?
  AND CONSTRAINT_NAME = 'PRIMARY'
ORDER BY ORDINAL_POSITION
```

Foreign keys:

```sql
SELECT
  kcu.CONSTRAINT_SCHEMA AS source_schema,
  kcu.TABLE_NAME AS source_table,
  kcu.CONSTRAINT_NAME AS constraint_name,
  kcu.COLUMN_NAME AS source_column,
  kcu.ORDINAL_POSITION AS source_ordinal,
  kcu.REFERENCED_TABLE_SCHEMA AS target_schema,
  kcu.REFERENCED_TABLE_NAME AS target_table,
  kcu.REFERENCED_COLUMN_NAME AS target_column,
  rc.UPDATE_RULE AS update_rule,
  rc.DELETE_RULE AS delete_rule
FROM information_schema.key_column_usage kcu
LEFT JOIN information_schema.referential_constraints rc
  ON rc.CONSTRAINT_SCHEMA = kcu.CONSTRAINT_SCHEMA
 AND rc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
 AND rc.TABLE_NAME = kcu.TABLE_NAME
WHERE kcu.TABLE_SCHEMA = ?
  AND kcu.TABLE_NAME = ?
  AND kcu.REFERENCED_TABLE_NAME IS NOT NULL
ORDER BY kcu.CONSTRAINT_NAME, kcu.ORDINAL_POSITION
```

Indexes:

```sql
SELECT
  TABLE_SCHEMA AS schema_name,
  TABLE_NAME AS table_name,
  INDEX_NAME AS index_name,
  NON_UNIQUE,
  INDEX_TYPE,
  SEQ_IN_INDEX AS column_ordinal,
  COLUMN_NAME AS column_name,
  EXPRESSION AS expression,
  COLLATION
FROM information_schema.statistics
WHERE TABLE_SCHEMA = ?
  AND TABLE_NAME = ?
ORDER BY INDEX_NAME, SEQ_IN_INDEX
```

Sequences:

- MySQL has no native sequence objects in the same sense as Oracle/Postgres.
- MariaDB supports sequences, but the current adapter is named MySQL and should initially report no sequences unless a future MariaDB capability probe is added.

Performance notes:

- `information_schema.statistics` and `key_column_usage` are acceptable per table.
- Avoid schema-wide joins across every table on large MySQL instances.

### SQLite

Columns:

```sql
PRAGMA table_info('<table>');
```

Expected columns:

- `cid`
- `name`
- `type`
- `notnull`
- `dflt_value`
- `pk`

Primary key:

- `pragma_table_info.pk > 0` marks PK participation and gives key order.

Foreign keys:

```sql
PRAGMA foreign_key_list('<table>');
```

Expected columns include:

- `id` as FK group identifier.
- `seq` as column ordinal inside the FK group.
- `table` as target table.
- `from` as source column.
- `to` as target column.
- `on_update`
- `on_delete`

Indexes:

```sql
PRAGMA index_list('<table>');
PRAGMA index_xinfo('<index_name>');
```

Use `index_xinfo` rather than only `index_info` when expression indexes or hidden columns matter.

Sequences:

- No native schema-level sequences.
- `sqlite_sequence` exists for AUTOINCREMENT internals, but it is not a user-facing sequence folder by default.

Performance notes:

- SQLite metadata calls are per table and cheap.
- SQLite has a single pseudo-schema in the current drawer (`sqlite_schema`), so FK navigation target IDs must account for that pseudo-schema.

### SQL Server / MSSQL

Columns:

```sql
SELECT
  s.name AS schema_name,
  t.name AS table_name,
  c.name AS column_name,
  ty.name AS type_name,
  c.max_length,
  c.precision,
  c.scale,
  c.is_nullable,
  c.column_id,
  dc.definition AS default_definition
FROM sys.columns c
JOIN sys.tables t ON t.object_id = c.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
LEFT JOIN sys.default_constraints dc
  ON dc.parent_object_id = c.object_id
 AND dc.parent_column_id = c.column_id
WHERE s.name = @schema
  AND t.name = @table
ORDER BY c.column_id
```

Primary keys:

```sql
SELECT
  kc.name AS constraint_name,
  col.name AS column_name,
  ic.key_ordinal
FROM sys.key_constraints kc
JOIN sys.tables t ON t.object_id = kc.parent_object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.index_columns ic
  ON ic.object_id = kc.parent_object_id
 AND ic.index_id = kc.unique_index_id
JOIN sys.columns col
  ON col.object_id = ic.object_id
 AND col.column_id = ic.column_id
WHERE kc.type = 'PK'
  AND s.name = @schema
  AND t.name = @table
ORDER BY ic.key_ordinal
```

Foreign keys:

```sql
SELECT
  src_schema.name AS source_schema,
  src_table.name AS source_table,
  fk.name AS constraint_name,
  src_col.name AS source_column,
  fkc.constraint_column_id AS source_ordinal,
  tgt_schema.name AS target_schema,
  tgt_table.name AS target_table,
  tgt_col.name AS target_column,
  fk.update_referential_action_desc AS update_rule,
  fk.delete_referential_action_desc AS delete_rule
FROM sys.foreign_keys fk
JOIN sys.foreign_key_columns fkc
  ON fkc.constraint_object_id = fk.object_id
JOIN sys.tables src_table
  ON src_table.object_id = fk.parent_object_id
JOIN sys.schemas src_schema
  ON src_schema.schema_id = src_table.schema_id
JOIN sys.columns src_col
  ON src_col.object_id = src_table.object_id
 AND src_col.column_id = fkc.parent_column_id
JOIN sys.tables tgt_table
  ON tgt_table.object_id = fk.referenced_object_id
JOIN sys.schemas tgt_schema
  ON tgt_schema.schema_id = tgt_table.schema_id
JOIN sys.columns tgt_col
  ON tgt_col.object_id = tgt_table.object_id
 AND tgt_col.column_id = fkc.referenced_column_id
WHERE src_schema.name = @schema
  AND src_table.name = @table
ORDER BY fk.name, fkc.constraint_column_id
```

Indexes:

```sql
SELECT
  s.name AS schema_name,
  t.name AS table_name,
  i.name AS index_name,
  i.is_unique,
  i.is_primary_key,
  i.type_desc,
  ic.key_ordinal,
  ic.is_descending_key,
  col.name AS column_name
FROM sys.indexes i
JOIN sys.tables t ON t.object_id = i.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.index_columns ic
  ON ic.object_id = i.object_id
 AND ic.index_id = i.index_id
JOIN sys.columns col
  ON col.object_id = ic.object_id
 AND col.column_id = ic.column_id
WHERE s.name = @schema
  AND t.name = @table
  AND i.name IS NOT NULL
ORDER BY i.name, ic.key_ordinal, ic.index_column_id
```

Sequences:

```sql
SELECT
  s.name AS schema_name,
  seq.name AS sequence_name,
  TYPE_NAME(seq.system_type_id) AS data_type,
  seq.start_value,
  seq.minimum_value,
  seq.maximum_value,
  seq.increment,
  seq.is_cycling,
  seq.cache_size,
  seq.current_value
FROM sys.sequences seq
JOIN sys.schemas s ON s.schema_id = seq.schema_id
WHERE s.name = @schema
ORDER BY seq.name
```

Performance notes:

- Prefer `sys.*` catalog views over `INFORMATION_SCHEMA` for richer metadata and reliable ordering.
- Keep metadata table-scoped or schema-scoped. Do not use `sp_helpindex` for structured RPC payloads; it is display-oriented.

### ClickHouse

Meaningful subset:

- Columns: yes.
- Nullability: encoded in the type string, e.g. `Nullable(String)`.
- Primary key/order key: available as table metadata, but not relational PK semantics.
- Indexes: data skipping indexes where system tables expose them.
- FKs: no relational FK metadata.
- Sequences: no native sequence folder for this feature.

Columns:

```sql
SELECT
  database AS schema_name,
  table AS table_name,
  name AS column_name,
  type,
  default_kind,
  default_expression,
  position
FROM system.columns
WHERE database = {schema:String}
  AND table = {table:String}
ORDER BY position
```

Data skipping indexes:

```sql
SELECT
  database AS schema_name,
  table AS table_name,
  name AS index_name,
  type AS index_type,
  expr AS expression,
  granularity
FROM system.data_skipping_indices
WHERE database = {schema:String}
  AND table = {table:String}
ORDER BY name
```

Performance notes:

- Treat ClickHouse indexes as "indexes" in the drawer but label method/type clearly so users do not confuse them with B-tree indexes.
- FK/PK annotations should not be fabricated.

### MongoDB

Meaningful subset:

- Collections map to table-like drawer nodes.
- Indexes are meaningful via `listIndexes`.
- Columns, nullability, PK, FK, and sequences are not meaningful unless a collection validator schema is available.

Index strategy:

- Use the MongoDB driver equivalent of `collection.Indexes().List(ctx)` or `listIndexes`.
- Map key document order to `Index.Columns`.
- Set `Unique` from the index options when present.

Column strategy:

- No default column metadata in v1. If a future phase reads JSON schema validators, that should be a separate capability because inferred document fields are probabilistic and expensive.

Performance notes:

- Do not sample documents to infer columns for this feature. That would be a separate, opt-in profiling feature.

### Redis

Meaningful subset:

- No relational table metadata.
- No indexes, FKs, columns, or sequences in the dbee drawer sense.

Strategy:

- Return unsupported/empty metadata for all rich metadata endpoints.
- Drawer should omit metadata folders for Redis.

### DuckDB

Columns:

```sql
SELECT
  table_schema,
  table_name,
  column_name,
  data_type,
  is_nullable,
  column_default,
  ordinal_position
FROM information_schema.columns
WHERE table_schema = ?
  AND table_name = ?
ORDER BY ordinal_position
```

Indexes:

```sql
SELECT *
FROM duckdb_indexes()
WHERE schema_name = ?
  AND table_name = ?
ORDER BY index_name
```

Constraints, including PK/FK where available:

```sql
SELECT *
FROM duckdb_constraints()
WHERE schema_name = ?
  AND table_name = ?
ORDER BY constraint_name
```

Sequences:

```sql
SELECT *
FROM duckdb_sequences()
WHERE schema_name = ?
ORDER BY sequence_name
```

If `duckdb_sequences()` is unavailable in the embedded DuckDB version, fall back to `information_schema.sequences` if present, otherwise return unsupported/empty.

Performance notes:

- DuckDB metadata is local and usually cheap, but keep it lazy to preserve uniform behavior and avoid loading every table's index/constraint metadata on open.

### BigQuery

Meaningful subset:

- Columns: `INFORMATION_SCHEMA.COLUMNS`.
- PK/FK constraints: available in newer BigQuery information schema views for declared constraints, but many datasets do not declare them.
- Indexes: search/vector indexes exist, but they are not equivalent to relational indexes.
- Sequences: no standard sequence folder.

Column template:

```sql
SELECT
  table_schema,
  table_name,
  column_name,
  data_type,
  is_nullable,
  column_default,
  ordinal_position
FROM `<project>.<dataset>.INFORMATION_SCHEMA.COLUMNS`
WHERE table_schema = @schema
  AND table_name = @table
ORDER BY ordinal_position
```

Strategy:

- First implementation can enrich columns/nullability only.
- Treat constraints/indexes/sequences as unsupported unless adapter-specific capability is proven.

### Databricks

Meaningful subset:

- Columns: `information_schema.columns`.
- Constraints: depends on catalog and runtime features; do not assume FK enforcement.
- Indexes/sequences: generally no relational equivalent.

Strategy:

- Enrich columns/nullability.
- Return empty indexes/sequences/FKs unless the active catalog exposes trustworthy metadata.

### Redshift

Meaningful subset:

- Columns: `information_schema.columns` or `pg_table_def`.
- PK/FK constraints may be informational and not enforced.
- Sequences: Postgres-compatible catalog patterns may work depending on engine version.
- Indexes: Redshift does not expose ordinary Postgres-style indexes in the same way; distribution/sort keys are more meaningful.

Strategy:

- Enrich columns/nullability.
- Consider sort/dist key display as a future Redshift-specific metadata family, not as generic indexes in v1.
- Treat constraints as annotations only, not enforcement guarantees.

## 3. RPC Endpoint Design

### Option A: extend columns, add index/sequence endpoints

Description:

- Extend `connection_get_columns` to return richer `Column` fields.
- Add `DbeeListIndexes(conn_id, schema, table)` and `DbeeListSequences(conn_id, schema)`.
- Optionally add `DbeeGetFKTargets(conn_id, schema, table)` only if FK data is not folded into enriched columns.

Pros:

- Minimal disruption to the existing drawer lazy column branch.
- LSP column completion benefits from richer `Column` payload without changing root structure.
- Old column endpoint remains valid because new fields are additive.
- Index and sequence metadata can be lazy and independently unsupported per adapter.

Cons:

- Drawer has to coordinate separate table metadata calls.
- Indexes/sequences are not represented in the root structure tree.
- More endpoint names and manifest registrations.

Fit with contracts:

- Good for D-156 because LSP can keep current async column miss behavior and only use richer payloads when the same in-flight contract succeeds.
- Good for D-77 if new endpoints use handler-owned single-flight registries.
- Good for Phase 14 if every metadata request carries root epoch and schema filter signature.

### Option B: roll all metadata into the structure tree

Description:

- Add `sequence` and `index` as `Structure` children.
- Put columns/indexes/FKs/sequences inside root/schema/table structure payloads.
- The drawer consumes one tree.

Pros:

- Conceptually simple tree navigation.
- One data shape for drawer nodes.
- Easy to show sequences under schemas if structure fetch includes them.

Cons:

- High risk of making root/schema fetches expensive again, especially Oracle.
- Does not fit current `Structure` shape for index columns, FK targets, nullability, or composite keys.
- Forces LSP schema cache to parse metadata it does not need for table/schema completion.
- In `lazy_per_schema=true` mode, table-level metadata still needs a lazy per-table fetch, so the "one tree" model breaks down.

Fit with contracts:

- Risky for D-156 because LSP might be tempted to synchronously fill richer metadata on completion.
- Risky for D-77 because root flights could become overloaded with table metadata.
- Risky for Phase 14 because schema allowlists and partial roots should not imply all table child metadata is loaded.

### Option C: hybrid

Description:

- Extend `connection_get_columns` to return richer `Column` metadata.
- Add table-scoped `connection_list_indexes_async` and schema-scoped `connection_list_sequences_async`.
- Represent `sequence` and `index` drawer nodes with explicit node types.
- Optionally include sequence names in schema structure only for adapters where listing sequences is already cheap, but prefer lazy schema `Sequences` folder expansion for Oracle.
- Keep FK target data inside `Column.ForeignKeys` initially. Add a dedicated FK endpoint later only if FK navigation needs reverse-reference browsing.

Pros:

- Keeps existing lazy branch model intact.
- Gives the drawer first-class folders for `Columns`, `Indexes`, and `Sequences`.
- Lets LSP keep using columns without caring about indexes/sequences.
- Preserves small-DB behavior and avoids new root fetch cost.
- Matches Phase 6 D-39, which reserved child families like columns/indexes/sequences/FKs.
- Matches Phase 14 lazy schema roots: schema expansion lists table-like objects; table expansion lists table metadata.

Cons:

- More handler/cache plumbing than Option A.
- Drawer must distinguish branch families and compose nodes from several metadata payloads.
- Requires strict tests so metadata fetches remain lazy and epoch-fenced.

Recommendation: Option C.

Implementation shape:

- `connection_get_columns_async` stays the source for enriched column rows.
- Add `connection_list_indexes_async(conn_id, request_id, branch_id, root_epoch, opts)`.
- Add `connection_list_sequences_async(conn_id, request_id, branch_id, root_epoch, schema)`.
- Add optional sync wrappers only where existing drawer patterns require them. Prefer async-first for new metadata.
- Add Go interfaces:
  - `ColumnMetadataDriver` is probably unnecessary if `Driver.Columns()` is extended additively.
  - `IndexListDriver` with `Indexes(opts *TableOptions) ([]*Index, error)`.
  - `SequenceListDriver` with `Sequences(schema string, opts *StructureOptions) ([]*Sequence, error)`.
- Unsupported adapters return `ErrMetadataNotSupported` and the drawer omits the folder or renders a non-noisy empty state.

Contract requirements:

- D-156: LSP `isIncomplete=true` only when a column metadata async request actually started, joined, or queued. Index/sequence requests should not affect LSP completion unless a later phase explicitly uses them.
- D-77: handler owns single-flight for new metadata families. Do not let drawer and LSP piggyback directly on each other.
- Phase 14: every metadata key includes normalized schema filter signature and current root epoch. If the table's schema is filtered out, do not fetch.
- Phase 14 lazy mode: indexes/FKs are lazy per table; sequences are lazy per schema.

## 4. Lua Drawer Rendering Pattern

### New node types

Add drawer node types in `lua/dbee/ui/drawer/convert.lua`:

- `metadata_folder`: generic folder node for `Columns`, `Indexes`, and `Sequences`.
- `column`: existing node type, with richer labels and FK metadata.
- `index`: index row under the table's `Indexes` folder.
- `sequence`: sequence row under a schema's `Sequences` folder.
- `fk_link`: optional child/link node for composite or verbose FK rendering.

Initial tree layout:

```text
schema HR
  table EMPLOYEES
    Columns
      EMPLOYEE_ID [NUMBER] [NOT NULL] [PK]
      DEPARTMENT_ID [NUMBER] [FK->HR.DEPARTMENTS.DEPARTMENT_ID]
    Indexes
      EMP_EMP_ID_PK [unique] (EMPLOYEE_ID)
      EMP_DEPT_IX (DEPARTMENT_ID)
  Sequences
    EMPLOYEES_SEQ
```

The current drawer materializes columns directly under tables. This feature should introduce an explicit `Columns` folder before adding more metadata families. That is a visible UI change and should be locked in discuss-phase.

### Column formatter

Target label:

```text
name [type] [NOT NULL] [PK] [FK->target.table.col]
```

Rules:

- Always show `name`.
- Show `[type]` when `column.type` is non-empty.
- Show `[NOT NULL]` only when `nullable == false`.
- Do not show `[NULL]`; nullable is the default in many databases and would add noise.
- Show `[PK]` when `primary_key == true`.
- Show `[FK->target]` for single-column FKs.
- For composite FKs, show `[FK:name]` or `[FK->target_table]` until the composite UI policy is decided.

Fixed-width drawer strategy for a typical 40-column drawer:

- Keep the row stable and single-line.
- Prioritize `name`, then PK/FK badges, then type.
- If the row is too long:
  1. Keep full column name if possible.
  2. Truncate the type first, e.g. `[VARCHAR2(255 CHAR)]` to `[VARCHAR2...]`.
  3. Truncate FK target next, e.g. `[FK->HR.DEPARTMENTS.DEPARTMENT_ID]` to `[FK->DEPARTMENTS...]`.
  4. Never truncate `[PK]` or `[NOT NULL]`.
- Use a helper such as `format_column_label(column, width)` so tests can lock truncation behavior without needing a live UI.

Example for narrow width:

```text
DEPARTMENT_ID [NUMBER] [FK->DEPARTMENTS...]
```

Backwards compatibility:

- If `nullable`, `primary_key`, and `foreign_keys` are all absent, render the current `name   [type]` or the new equivalent `name [type]`.
- Unsupported adapters should not show empty `Indexes` or `Sequences` folders unless the folder was explicitly requested and returned empty.

### Index formatter

Target label:

```text
INDEX_NAME [unique] (COL_A, COL_B DESC)
```

Rules:

- Show `[unique]` for unique indexes.
- Show `[pk]` only if the adapter reports the index is backing a primary key and this is useful; avoid duplicating PK too loudly with the column `[PK]` marker.
- Show expression index parts as expressions if no column name exists.
- Truncate the column list after available width: `(COL_A, COL_B, ...)`.

### Sequence formatter

Initial label:

```text
SEQUENCE_NAME
```

Optional later label if the user wants details:

```text
SEQUENCE_NAME [inc 1] [cache 20]
```

Do not show current/last values by default until the user decides whether those values are useful and safe to query for each adapter.

### FK navigation

Recommended key behavior:

- `<CR>` on a `fk_link` node: reveal target table/column.
- `gd` on a column row with exactly one FK: reveal target table/column.
- `gd` on a column row with multiple FKs: open a small select menu of FK targets.
- `<CR>` on normal column rows should keep the existing behavior unless discuss-phase decides to repurpose it.

Implementation pattern:

- Add drawer API `DrawerUI:reveal_node(node_id_or_target)` rather than directly calling `nvim_win_set_cursor` from formatter code.
- Target shape:

```lua
{
  conn_id = "...",
  schema = "HR",
  table = "DEPARTMENTS",
  column = "DEPARTMENT_ID",
}
```

`reveal_node` responsibilities:

- Ensure the connection is expanded.
- Ensure the target schema is loaded in Phase 14 lazy mode. If unloaded, request schema objects and continue after `schema_objects_loaded` with truthful loading state.
- Ensure the target table's `Columns` branch is loaded. If unloaded, request columns and continue after `structure_children_loaded`.
- Move drawer cursor to the target column with `nvim_win_set_cursor`.
- Preserve root epoch checks; if the epoch changes while navigation is in flight, cancel silently or show a scoped warning.

FK target filtered out:

- If the target schema is outside the active Phase 14 filter, do not bypass the filter.
- Show a non-blocking info message such as `FK target HR.DEPARTMENTS is outside the active schema filter`.
- Do not fetch filtered-out metadata.

## 5. Performance + Caching

### Phase 10/11 LSP budget interaction

Do not add synchronous metadata work to LSP completion or diagnostics.

Allowed:

- LSP consumes richer `Column` payloads after the existing async column cache warms.
- LSP completion details may display PK/FK/nullability if already cached.
- Cache mutation rebuilds only the affected table's column completion index, preserving Phase 11 index invalidation rules.

Not allowed:

- Completion asks for indexes/FKs synchronously.
- Diagnostics request table metadata.
- `schema.` completion waits for sequences or indexes.
- Cache reads scan all tables to discover FK targets.

D-156 rule to preserve: `isIncomplete=true` only when async work actually started, joined, or queued.

### Drawer performance

Drawer behavior should be lazy:

- Connection open:
  - No table-level PK/FK/index fetch.
  - No schema sequence fetch unless explicitly decided for small DBs later.
- Schema expand:
  - Phase 14 lazy mode fetches schema objects only.
  - `Sequences` folder is a lazy child under schema.
- Table expand:
  - Fetch enriched columns.
  - Fetch indexes only when `Indexes` folder expands, or fetch columns+indexes together only if a measured Oracle-first implementation proves it is cheaper and still bounded.

Recommended first pass:

- Table expand renders `Columns` and `Indexes` folders.
- `Columns` folder expansion fetches enriched columns.
- `Indexes` folder expansion fetches indexes.
- This adds one more interaction compared with direct column rows, but it keeps large-table metadata cost explicitly user-driven.

Alternative first pass:

- Table expand fetches enriched columns immediately and renders `Columns` expanded.
- `Indexes` remains lazy.
- This is closer to today's column behavior and likely better UX. It should be performance-tested against Oracle ATP before locking.

### Metadata cache surface

Current `_struct_cache` holds root and branch state, with Phase 14 adding partial schema/object state and schema filter signature. Rich metadata should slot in as branch-level cache entries, not root structure payload.

Suggested drawer cache fields:

```lua
_struct_cache.metadata = {
  columns = {
    [table_key] = {
      root_epoch = 12,
      schema_filter_signature = "...",
      loaded = true,
      columns = {...},
    },
  },
  indexes = {
    [table_key] = {
      root_epoch = 12,
      schema_filter_signature = "...",
      loaded = true,
      indexes = {...},
    },
  },
  sequences = {
    [schema_key] = {
      root_epoch = 12,
      schema_filter_signature = "...",
      loaded = true,
      sequences = {...},
    },
  },
}
```

Key parts:

- `conn_id`
- `schema`
- `table` where applicable
- materialization where applicable
- `root_epoch`
- normalized `schema_filter_signature`

LSP cache:

- Extend per-table column cache to include the richer column fields.
- Bump cache version only if on-disk shape changes in a way old code would misread.
- For Phase 14, cache entries must remain fenced by `schema_filter_signature` or generation.
- Do not cache indexes/sequences in LSP until a concrete LSP feature needs them.

Disk cache:

- Rich columns can reuse existing per-table column-cache files with a version bump if needed.
- Index cache should be drawer-owned and optional. Consider in-memory first; disk caching indexes adds invalidation complexity with limited immediate LSP benefit.
- Sequence cache can be in-memory per schema; disk cache only if real Oracle use shows repeated expansion cost.

### Single-flight and backpressure

New metadata requests should follow Phase 7/14 patterns:

- Handler-owned single-flight.
- Distinct registries for columns, indexes, sequences if their transport calls differ.
- Keys include root epoch and schema filter signature.
- Drawer-driven requests have priority over speculative LSP requests. In v1, LSP should not request indexes/sequences at all.
- Reconnect migration only when connection type, fold rule, schema filter signature, and lazy capability identity match.

### Advisory performance checks

Future plan should add advisory, non-blocking first-run perf markers:

- `RICHMETA_ORACLE_COLUMNS_1_TABLE_OK`
- `RICHMETA_ORACLE_INDEXES_1_TABLE_OK`
- `RICHMETA_ORACLE_SEQUENCES_1_SCHEMA_OK`
- `RICHMETA_DRAWER_TABLE_EXPAND_100_INDEXES_OK`
- `RICHMETA_LSP_COLUMN_COMPLETION_NO_SYNC_METADATA_OK`

Freeze thresholds only after measured local baselines, following Phase 9/10/11 precedent.

## 6. Phasing

### Phase X.1: data model + Oracle first

Goal: make the feature useful for Naveen's daily Oracle ATP/Cloud Manager workflow without broad adapter risk.

Scope:

- Extend Go `Column` with nullable/PK/FK fields.
- Add `FKRef`, `Index`, `IndexColumn`, and `Sequence` shapes.
- Add `StructureTypeSequence` and `StructureTypeIndex`.
- Extend msgpack marshal for columns.
- Add Oracle enriched column metadata using `all_tab_columns`, `all_constraints`, and `all_cons_columns`.
- Add Oracle indexes using `all_indexes` and `all_ind_columns`.
- Add Oracle sequences using `all_sequences`.
- Add Lua drawer `Columns`, `Indexes`, and `Sequences` folders.
- Add FK navigation for single-column FK targets.
- Preserve old behavior when metadata fields are absent.

Sentinel markers:

- `RICHMETA_COLUMN_WIRE_ADDITIVE_OK=true`
- `RICHMETA_ORACLE_COLUMNS_PK_FK_NULL_OK=true`
- `RICHMETA_ORACLE_INDEXES_OK=true`
- `RICHMETA_ORACLE_SEQUENCES_OK=true`
- `RICHMETA_DRAWER_COLUMN_ANNOTATIONS_OK=true`
- `RICHMETA_FK_NAV_SINGLE_COLUMN_OK=true`
- `RICHMETA_PHASE_X1_ALL_PASS=true`

Conservative effort:

- 4 to 6 engineering days if Oracle metadata queries can be validated against local ATP quickly.
- Add 1 to 2 days if FK navigation must handle lazy target expansion and filtered-out targets in the first cut.

v1.3 feasibility:

- Feasible as a focused Oracle-first v1.3+ phase after Phase 14 closes, if scope excludes composite FK polish, triggers, checks, and non-Oracle adapters.

### Phase X.2: Postgres + MySQL + SQLite

Goal: cover the common local/open-source adapters with truthful subsets.

Scope:

- Postgres: columns/nullability/defaults, PK/FK with `pg_constraint`, indexes with `pg_index`, sequences with `pg_sequences` or `pg_class relkind='S'`.
- MySQL: columns, PK/FK via `information_schema.key_column_usage`, indexes via `information_schema.statistics`, no sequences.
- SQLite: columns/PK via `pragma_table_info`, FKs via `pragma_foreign_key_list`, indexes via `pragma_index_list` plus `pragma_index_xinfo`, no sequences.
- Add adapter capability matrix in docs or wizard help if applicable.
- Add tests proving unsupported sequence folders are omitted.

Sentinel markers:

- `RICHMETA_POSTGRES_COLUMNS_PK_FK_NULL_OK=true`
- `RICHMETA_POSTGRES_INDEXES_SEQUENCES_OK=true`
- `RICHMETA_MYSQL_COLUMNS_PK_FK_INDEXES_OK=true`
- `RICHMETA_MYSQL_SEQUENCES_NOOP_OK=true`
- `RICHMETA_SQLITE_COLUMNS_PK_FK_INDEXES_OK=true`
- `RICHMETA_SQLITE_SEQUENCES_NOOP_OK=true`
- `RICHMETA_PHASE_X2_ALL_PASS=true`

Conservative effort:

- 5 to 8 engineering days, mostly due to adapter-specific SQL and test fixtures.

v1.3 feasibility:

- Possible only if Phase X.1 lands cleanly and the milestone still has room. Otherwise defer to v1.4.

### Phase X.3: remaining adapters

Goal: make the feature honest across every registered adapter without pretending every database has relational metadata.

Scope:

- SQL Server: full columns/PK/FK/indexes/sequences through `sys.*`.
- DuckDB: columns, indexes, constraints, sequences where supported.
- ClickHouse: columns and data skipping indexes; no FKs/sequences.
- MongoDB: collection indexes only; no relational columns/FKs/sequences.
- Redis: no-op metadata.
- BigQuery: columns/nullability first; constraints/indexes only if trustworthy.
- Databricks: columns/nullability first; constraints/indexes mostly no-op.
- Redshift: columns/nullability; constraints as informational; indexes no-op or Redshift-specific sort/dist key future work.

Sentinel markers:

- `RICHMETA_MSSQL_COLUMNS_PK_FK_INDEXES_SEQUENCES_OK=true`
- `RICHMETA_DUCKDB_METADATA_OK=true`
- `RICHMETA_CLICKHOUSE_METADATA_SUBSET_OK=true`
- `RICHMETA_MONGO_INDEX_SUBSET_OK=true`
- `RICHMETA_REDIS_METADATA_NOOP_OK=true`
- `RICHMETA_BIGQUERY_METADATA_SUBSET_OK=true`
- `RICHMETA_DATABRICKS_METADATA_SUBSET_OK=true`
- `RICHMETA_REDSHIFT_METADATA_SUBSET_OK=true`
- `RICHMETA_PHASE_X3_ALL_PASS=true`

Conservative effort:

- 7 to 12 engineering days because several adapters have different semantics rather than just different catalog names.

v1.3 feasibility:

- Better as v1.4 unless v1.3 is explicitly extended. The first two phases provide most user-visible value with less risk.

### Overall recommendation

For v1.3+:

1. Do Phase X.1 Oracle first.
2. Decide after live Oracle testing whether X.2 belongs in v1.3 or v1.4.
3. Keep X.3 in v1.4 unless there is a specific user need for one remaining adapter.

Do not combine this with Phase 14 closeout. This feature touches the same drawer/LSP/handler surfaces and should get its own discuss, plan, review, and sentinel family.

## 7. Open Questions For The User

1. Composite FK UI:
   - Should composite FKs render inline as `[FK:constraint_name]`, show one target per column, or expand into a child node listing the full column mapping?

2. Check constraints:
   - Should check constraints be shown under a future `Constraints` folder, or are they out of scope for this feature?

3. Triggers:
   - Should triggers be part of DBeaver parity later, or explicitly out of scope for v1.3?

4. Sequence details:
   - Should sequence rows show only names, or include increment/cache/current value?
   - For Oracle, is `last_number` useful enough to display, or too easy to misread as the current runtime value?

5. Index details:
   - Should index rows show uniqueness, composite columns, order, and method/type in the first release?
   - Should PK-backed indexes be hidden to reduce duplication with `[PK]`, or shown because DBeaver shows them?

6. FK navigation keymap:
   - Should `gd`, `<CR>`, or both navigate FK links?
   - Should `<CR>` on a column with one FK navigate, or only explicit `fk_link` child nodes?

7. Folder shape:
   - Should table expansion show explicit `Columns` and `Indexes` folders, or keep columns directly under the table and add `Indexes` as a sibling folder?
   - Explicit folders are cleaner for DBeaver parity but change today's table expansion shape.

8. Lazy fetch policy:
   - On table expand, should columns fetch immediately as today, or should the user expand a `Columns` folder?
   - Oracle performance should decide this, not aesthetics alone.

9. Performance bound:
   - What table count per schema should define "large enough to require strict per-table laziness": 100, 1000, or 10000?
   - Naveen's Oracle ATP use plus Phase 14 `lazy_per_schema` suggests designing for 10000 without eager table metadata.

10. Unsupported adapters:
    - Should unsupported metadata folders be hidden entirely, or shown as empty/unsupported after expansion?
    - Recommendation: hide them by default and expose capability status in docs or diagnostics, not in the main drawer.

11. LSP use of rich metadata:
    - Should completion details eventually show `[PK]`, `[FK]`, and nullability, or should this remain drawer-only for now?
    - Recommendation: drawer first; LSP details later only from already-cached metadata.

12. Reverse references:
    - The request is FK click to referenced table+column. Should the drawer also show "Referenced by" relationships later?
    - Oracle/Postgres helper SQL can support this, but it is a separate metadata family.
