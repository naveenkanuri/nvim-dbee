# Phase 17 Research - PostgreSQL Rich Metadata SQL

**Date:** 2026-05-04  
**Scope:** PostgreSQL `pg_catalog` SQL for Phase 17 rich metadata planning  
**Output:** paste-ready SQL constants and implementation notes for `dbee/adapters/postgres_driver.go` or a new PostgreSQL rich metadata file

## 1. `ColumnsRich(opts)` SQL

Recommended shape: mirror Phase 16 Oracle and keep three constants: base columns, primary keys, and foreign keys. This keeps row parsing simple, keeps composite ordinal logic explicit, and avoids a single wide query with duplicate column rows per FK.

### `postgresColumnsRichSQL`

```go
const postgresColumnsRichSQL = `
	WITH cols AS (
	  SELECT n.nspname AS schema_name,
	         c.relname AS table_name,
	         a.attname AS column_name,
	         pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type,
	         NOT a.attnotnull AS nullable,
	         a.attgenerated,
	         a.attidentity,
	         pg_catalog.pg_get_expr(d.adbin, d.adrelid, false) AS default_expr,
	         a.attnum
	  FROM pg_catalog.pg_class c
	  JOIN pg_catalog.pg_namespace n
	    ON n.oid = c.relnamespace
	  JOIN pg_catalog.pg_attribute a
	    ON a.attrelid = c.oid
	  LEFT JOIN pg_catalog.pg_attrdef d
	    ON d.adrelid = c.oid
	   AND d.adnum = a.attnum
	  WHERE n.nspname = $1
	    AND c.relname = $2
	    AND c.relkind IN ('r', 'p', 'f', 'v', 'm')
	    AND a.attnum > 0
	    AND NOT a.attisdropped
	)
	SELECT column_name,
	       data_type,
	       nullable,
	       attgenerated,
	       attidentity,
	       default_expr,
	       CASE
	         WHEN default_expr LIKE 'nextval(%' THEN
	           pg_catalog.pg_get_serial_sequence(
	             pg_catalog.quote_ident(schema_name) || '.' || pg_catalog.quote_ident(table_name),
	             column_name
	           )
	         ELSE NULL
	       END AS serial_sequence
	FROM cols
	ORDER BY attnum`
```

Notes:
- `$1` = schema, `$2` = table or view name.
- `format_type(atttypid, atttypmod)` gives natural PostgreSQL type text, including arrays, domains, and user-defined types.
- `pg_get_expr(d.adbin, d.adrelid, false)` is the supported replacement for `pg_attrdef.adsrc`; do not use `adsrc`.
- `attgenerated != ''` drives `[GEN]`; `attidentity != ''` drives `[IDENTITY]`.
- `default_expr` is also populated for generated expressions. Renderer/parser should avoid showing `[DEFAULT=...]` for generated columns unless explicitly desired.
- `pg_get_serial_sequence()` is guarded behind `default_expr LIKE 'nextval(%'` so non-serial defaults do not pay that catalog lookup cost.
- The guard uses a CTE because PostgreSQL cannot reference a sibling SELECT-list alias in the same SELECT.
- `pg_get_serial_sequence()` needs a schema-qualified, quoted table string to preserve mixed-case identifiers.
- Serial strategy decision: the CTE-guarded CASE shape is the Phase 17 strict-gate default because it keeps the existing column query simple and limits `pg_get_serial_sequence()` to rows whose default is a `nextval(...)` expression. A `pg_depend` join remains a valid confidence-benchmark comparison, but it adds catalog joins and should not replace the CASE shape without live PostgreSQL evidence.

### `postgresPrimaryKeysSQL`

```go
const postgresPrimaryKeysSQL = `
	SELECT a.attname AS column_name,
	       pk.ordinal::int AS position
	FROM pg_catalog.pg_class c
	JOIN pg_catalog.pg_namespace n
	  ON n.oid = c.relnamespace
	JOIN pg_catalog.pg_constraint con
	  ON con.conrelid = c.oid
	 AND con.contype = 'p'
	JOIN LATERAL pg_catalog.unnest(con.conkey) WITH ORDINALITY AS pk(attnum, ordinal)
	  ON true
	JOIN pg_catalog.pg_attribute a
	  ON a.attrelid = c.oid
	 AND a.attnum = pk.attnum
	WHERE n.nspname = $1
	  AND c.relname = $2
	  AND c.relkind IN ('r', 'p', 'f', 'm')
	  AND a.attnum > 0
	  AND NOT a.attisdropped
	ORDER BY pk.ordinal`
```

This is the cleaner approach versus folding PK data into the base column query. It mirrors Oracle's `oraclePrimaryKeysSQL` and gives one row per PK column ordered by constraint ordinal.

### `postgresForeignKeysSQL`

```go
const postgresForeignKeysSQL = `
	SELECT con.conname AS constraint_name,
	       source_attr.attname AS source_column,
	       fk.ordinal::int AS ordinal,
	       target_ns.nspname AS target_schema,
	       target_cls.relname AS target_table,
	       target_attr.attname AS target_column
	FROM pg_catalog.pg_class source_cls
	JOIN pg_catalog.pg_namespace source_ns
	  ON source_ns.oid = source_cls.relnamespace
	JOIN pg_catalog.pg_constraint con
	  ON con.conrelid = source_cls.oid
	 AND con.contype = 'f'
	JOIN pg_catalog.pg_class target_cls
	  ON target_cls.oid = con.confrelid
	JOIN pg_catalog.pg_namespace target_ns
	  ON target_ns.oid = target_cls.relnamespace
	JOIN LATERAL pg_catalog.unnest(con.conkey, con.confkey)
	     WITH ORDINALITY AS fk(source_attnum, target_attnum, ordinal)
	  ON true
	JOIN pg_catalog.pg_attribute source_attr
	  ON source_attr.attrelid = source_cls.oid
	 AND source_attr.attnum = fk.source_attnum
	JOIN pg_catalog.pg_attribute target_attr
	  ON target_attr.attrelid = target_cls.oid
	 AND target_attr.attnum = fk.target_attnum
	WHERE source_ns.nspname = $1
	  AND source_cls.relname = $2
	  AND source_cls.relkind IN ('r', 'p', 'f')
	  AND source_attr.attnum > 0
	  AND NOT source_attr.attisdropped
	  AND target_attr.attnum > 0
	  AND NOT target_attr.attisdropped
	ORDER BY con.conname, fk.ordinal`
```

Composite FK handling:
- `unnest(con.conkey, con.confkey) WITH ORDINALITY` pairs source and target arrays by parallel position.
- Group rows by `constraint_name`, sort by `ordinal`, then build `SourceColumns[]` and `TargetColumns[]`.
- Attach one distinct `*core.FKRef` per source column, copying the full arrays into every ref, matching the Phase 16 Oracle pattern.

## 2. `Indexes(opts)` SQL

### `postgresIndexesSQL`

```go
const postgresIndexesSQL = `
	SELECT index_cls.relname AS index_name,
	       index_ns.nspname AS index_owner,
	       table_ns.nspname AS table_owner,
	       table_cls.relname AS table_name,
	       CASE WHEN ix.indisunique THEN 'UNIQUE' ELSE 'NONUNIQUE' END AS uniqueness,
	       COALESCE(
	         attr.attname,
	         pg_catalog.pg_get_indexdef(ix.indexrelid, key_pos.column_position, true)
	       ) AS column_name,
	       CASE
	         WHEN key_pos.column_position <= ix.indnkeyatts THEN
	           CASE WHEN (ix.indoption[key_pos.zero_based]::int & 1) = 1 THEN 'DESC' ELSE 'ASC' END
	         ELSE NULL
	       END AS descend,
	       key_pos.column_position,
	       (key_pos.column_position > ix.indnkeyatts) AS is_include,
	       ix.indisprimary AS pk_backed
	FROM pg_catalog.pg_index ix
	JOIN pg_catalog.pg_class table_cls
	  ON table_cls.oid = ix.indrelid
	JOIN pg_catalog.pg_namespace table_ns
	  ON table_ns.oid = table_cls.relnamespace
	JOIN pg_catalog.pg_class index_cls
	  ON index_cls.oid = ix.indexrelid
	JOIN pg_catalog.pg_namespace index_ns
	  ON index_ns.oid = index_cls.relnamespace
	JOIN LATERAL (
	  SELECT gs AS zero_based,
	         gs + 1 AS column_position,
	         ix.indkey[gs] AS attnum
	  FROM pg_catalog.generate_series(0, ix.indnatts - 1) AS gs
	) AS key_pos
	  ON true
	LEFT JOIN pg_catalog.pg_attribute attr
	  ON attr.attrelid = table_cls.oid
	 AND attr.attnum = key_pos.attnum
	WHERE table_ns.nspname = $1
	  AND table_cls.relname = $2
	  AND table_cls.relkind IN ('r', 'p', 'm')
	  AND ix.indislive
	  AND ix.indisready
	  AND ix.indisvalid
	ORDER BY index_cls.relname, key_pos.column_position`
```

Parsing recommendations:
- `indkey` and `indoption` are vector types with zero-based subscripting in catalog queries; `pg_get_indexdef(indexrelid, column_no, true)` uses one-based `column_position`.
- Rows with `is_include=true` should populate a new additive `core.Index.IncludeColumns []string` field, not `Columns` or `Orders`.
- Rows with `is_include=false` populate `Columns` and `Orders`.
- Expression indexes have `indkey[position] = 0`; `attr.attname` is null, so `pg_get_indexdef(indexrelid, column_position, true)` becomes the display string.
- `indoption & 1` is the DESC flag for key columns. INCLUDE rows have no key order; `descend` is intentionally null there.
- Filtering `indislive AND indisready AND indisvalid` hides dropped or in-progress concurrent indexes.

## 3. `Sequences(schema)` SQL

### `postgresSequencesSQL`

```go
const postgresSequencesSQL = `
	SELECT c.relname AS sequence_name,
	       s.seqincrement AS increment_by,
	       s.seqcache AS cache_size
	FROM pg_catalog.pg_class c
	JOIN pg_catalog.pg_namespace n
	  ON n.oid = c.relnamespace
	JOIN pg_catalog.pg_sequence s
	  ON s.seqrelid = c.oid
	WHERE n.nspname = $1
	  AND c.relkind = 'S'
	ORDER BY c.relname`
```

Notes:
- `$1` = schema.
- This returns true sequence objects only. Serial/identity ownership is column metadata via `pg_get_serial_sequence`, not a table-local child.

## 4. PG Version Compatibility Notes

Recommended rich metadata floor: **PostgreSQL 12+**.

Reasons:
- `attidentity` and `pg_sequence` are available from PostgreSQL 10, matching identity columns and sequence catalog support.
- Covering indexes with INCLUDE columns are available in PostgreSQL 11, and `pg_index.indnkeyatts` distinguishes key columns from included columns.
- Generated columns and `pg_attribute.attgenerated` are the deciding factor for Phase 17's `[GEN]` lock; PostgreSQL 12 is the practical floor for one static query.
- `pg_attrdef.adsrc` was removed in PostgreSQL 12. Use `pg_get_expr(adbin, adrelid, false)` exclusively.
- Current PostgreSQL 18 docs mention `attgenerated='v'` for virtual generated columns. PG12-17 mostly produce stored generated columns (`'s'`). Phase 17 should treat any non-empty `attgenerated` as generated.

If PostgreSQL 10/11 must remain supported with rich metadata enabled, planning needs a version probe and alternate column query that omits `attgenerated`. Otherwise, set PostgreSQL rich metadata capability false or return a typed error for servers below 12. That is a planning decision, not a SQL change.

## 5. Driver-Level Details

Local dbee facts:
- `dbee/adapters/postgres.go:9` imports `github.com/lib/pq`; `dbee/adapters/postgres.go:33` opens the driver with `sql.Open("postgres", ...)`.
- `dbee/core/builders/client.go:98-104` passes `args ...any` directly to `db.QueryContext(ctx, query, args...)` in `QueryWithArgs` and then parses returned rows.
- `lib/pq` documents PostgreSQL-native ordinal markers (`$1`, `$2`, reused markers allowed).
- `lib/pq`'s `QueryContext` copies `driver.NamedValue.Value` into a plain `[]driver.Value` and discards the name. It does not translate `sql.Named("p_schema", value)` into named SQL placeholders.

Implementation rule:

```go
rows, err := c.c.QueryWithArgs(ctx, postgresColumnsRichSQL, opts.Schema, opts.Table)
```

Do not use:

```go
rows, err := c.c.QueryWithArgs(ctx, postgresColumnsRichSQL, sql.Named("p_schema", opts.Schema))
```

PostgreSQL has no `:p_schema` named-placeholder syntax in `lib/pq`, and dbee has no translation layer for named PostgreSQL bind arguments.

## 6. Materialized View Handling

Facts:
- `pg_class.relkind = 'm'` identifies materialized views.
- Materialized views are relations with `pg_attribute` rows, so `ColumnsRich()` works naturally when `c.relkind IN (..., 'm')`.
- PostgreSQL `CREATE INDEX` supports indexes on a table or materialized view, so `Indexes()` should include `relkind='m'`.
- Materialized views do not normally own serial/identity sequences; `pg_get_serial_sequence()` should return null, which is acceptable.

Planning caveat:
- Existing `postgres_driver.go` currently maps `pg_matviews` rows as `'VIEW'` in both full and per-schema structure queries. Phase 17 can still query rich MV metadata by catalog name when invoked, but a planner should decide whether to preserve existing drawer type behavior or fix MVs to `materialized_view` and add that type to drawer table-like handling.

## 7. Test SQL Fixtures

Use this as the semantic fixture for sqlmock row setup and optional PostgreSQL integration coverage.

```sql
CREATE SCHEMA rich_pg;

CREATE DOMAIN rich_pg.email_domain AS text
  CHECK (position('@' in VALUE) > 1);

CREATE TYPE rich_pg.status_t AS ENUM ('new', 'active', 'disabled');

CREATE TABLE rich_pg.parent_account (
  tenant_id integer NOT NULL,
  parent_id integer GENERATED ALWAYS AS IDENTITY,
  code text NOT NULL DEFAULT 'P',
  code_upper text GENERATED ALWAYS AS (upper(code)) STORED,
  contact_email rich_pg.email_domain,
  tags text[],
  status rich_pg.status_t DEFAULT 'new',
  PRIMARY KEY (tenant_id, parent_id)
);

CREATE TABLE rich_pg.child_account (
  tenant_id integer NOT NULL,
  child_id integer GENERATED BY DEFAULT AS IDENTITY,
  parent_id integer NOT NULL,
  legacy_serial serial,
  payload text NOT NULL DEFAULT 'payload',
  payload_len integer GENERATED ALWAYS AS (length(payload)) STORED,
  created_at timestamptz DEFAULT now(),
  PRIMARY KEY (tenant_id, child_id),
  CONSTRAINT child_account_parent_fk
    FOREIGN KEY (tenant_id, parent_id)
    REFERENCES rich_pg.parent_account (tenant_id, parent_id)
);

CREATE UNIQUE INDEX child_account_parent_payload_uq
  ON rich_pg.child_account (tenant_id ASC, parent_id DESC)
  INCLUDE (payload);

CREATE INDEX child_account_payload_expr_idx
  ON rich_pg.child_account ((lower(payload)));

CREATE SEQUENCE rich_pg.audit_seq
  INCREMENT BY 5
  CACHE 20;

CREATE MATERIALIZED VIEW rich_pg.parent_account_mv AS
  SELECT tenant_id, parent_id, code
  FROM rich_pg.parent_account
  WITH NO DATA;

CREATE INDEX parent_account_mv_lookup_idx
  ON rich_pg.parent_account_mv (tenant_id, parent_id);
```

Coverage mapping:
- Composite PK: `parent_account(tenant_id, parent_id)` and `child_account(tenant_id, child_id)`.
- Composite FK: `child_account_parent_fk` pairs `(tenant_id, parent_id)` to `(tenant_id, parent_id)`.
- Generated columns: `code_upper`, `payload_len`.
- Identity columns: `parent_id`, `child_id`.
- Serial detection: `legacy_serial`.
- Defaults: `code`, `status`, `payload`, `created_at`.
- INCLUDE index: `child_account_parent_payload_uq`.
- Expression index: `child_account_payload_expr_idx`.
- Sequence folder: `audit_seq`.
- Materialized view columns and indexes: `parent_account_mv`, `parent_account_mv_lookup_idx`.
- Domain, enum, and array type rendering: `contact_email`, `status`, `tags`.

## 8. Edge Cases / Pitfalls

- Quoted identifiers: `pg_class.relname` and `pg_namespace.nspname` preserve mixed case for quoted objects. Always compare bound `$1/$2` values directly; never lower/upper-case them in Go.
- `pg_get_serial_sequence`: first argument is parsed as a possibly schema-qualified table name and lowercases unquoted names. Build it with `quote_ident(schema) || '.' || quote_ident(table)` so mixed-case tables work.
- Dropped columns: PostgreSQL keeps tombstone `pg_attribute` rows. Always filter `a.attnum > 0 AND NOT a.attisdropped`.
- Many-column indexes: use `generate_series(0, ix.indnatts - 1)` over the vector rather than parsing `indkey::text`.
- Expression indexes: `indkey[position] = 0`; use `pg_get_indexdef(indexrelid, column_position, true)` as the display string.
- INCLUDE columns: positions greater than `indnkeyatts` are payload columns, not key columns. Do not append them to `Index.Columns`.
- Concurrent index builds: `indisvalid=false` or `indisready=false` can appear while an index is being built. The recommended SQL hides those rows.
- PK-backed indexes: return them with `pk_backed=true`; let drawer rendering hide them, preserving Phase 16 behavior.
- Domain types: `format_type` returns the domain type name, which is correct for Phase 17. Domain introspection remains out of scope.
- Array types: `format_type` naturally returns forms like `text[]`.
- User-defined types: `format_type` returns a displayable SQL type name, schema-qualified when needed.
- Materialized views: support columns and indexes, but serial-sequence ownership normally returns null.
- Partitioned tables: `relkind='p'` appears in column and index queries. Phase 17 treats them as ordinary table-like relations and does not render partition hierarchy.
- Benchmarking caveat: `go-sqlmock` benchmarks can measure Go row scanning and grouping cost only. They cannot validate PostgreSQL planner/runtime cost for `pg_get_serial_sequence()` versus a `pg_depend` join. Any CASE-vs-`pg_depend` runtime comparison must use a live PostgreSQL confidence lane, not the strict sqlmock gate.

## 9. Recommended Phase 17 File Layout

Use separate files:

- `dbee/adapters/postgres_driver_rich_metadata.go`
  - `SupportsRichMetadata()`, `ColumnsRich()`, `Indexes()`, `Sequences()`.
  - SQL constants above.
  - PostgreSQL-specific row parsing and composite FK grouping helpers.
- `dbee/adapters/postgres_driver_rich_metadata_test.go`
  - `go-sqlmock` unit tests mirroring `oracle_driver_rich_metadata_test.go`.
  - Explicit assertions for positional `$1/$2`, composite PK/FK ordinal pairing, INCLUDE split, expression index display strings, and sequence rows.
- `ci/headless/check_rich_metadata_postgres.lua`
  - New `RICH_PG_*` marker suite.
  - Keep `RICH16_*` stable and avoid a shared script becoming too hard to diagnose.

Recommendation: separate files for clarity. Phase 17 will add parser fields (`attgenerated`, `attidentity`, `default_expr`, `serial_sequence`, `include_columns`) plus SQL-heavy tests; separate files keep impl-gate review bounded and avoid burying PostgreSQL rich logic inside the already broad `postgres_driver.go`.

## Research Summary

SQL constants count: **5**.

- `postgresColumnsRichSQL`
- `postgresPrimaryKeysSQL`
- `postgresForeignKeysSQL`
- `postgresIndexesSQL`
- `postgresSequencesSQL`

Version floor: **PostgreSQL 12+** for one static rich metadata implementation with generated columns.

Blockers against `17-CONTEXT.md`: **none**. The only planning caveat is explicit: if Phase 17 must support PostgreSQL 10/11 rich metadata, it needs version-gated fallback because the locked `[GEN]` annotation depends on `attgenerated`.
