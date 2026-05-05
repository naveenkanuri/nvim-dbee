package adapters

import (
	"context"
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/kndndrj/nvim-dbee/dbee/core"
)

var (
	_ core.RichMetadataCapability = (*postgresDriver)(nil)
	_ core.RichColumnDriver       = (*postgresDriver)(nil)
	_ core.IndexDriver            = (*postgresDriver)(nil)
	_ core.SequenceDriver         = (*postgresDriver)(nil)
)

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
	JOIN LATERAL ROWS FROM (
	       pg_catalog.unnest(con.conkey),
	       pg_catalog.unnest(con.confkey)
	     ) WITH ORDINALITY AS fk(source_attnum, target_attnum, ordinal)
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
	  AND table_cls.relkind IN ('r', 'p', 'v', 'm')
	  AND ix.indislive
	  AND ix.indisready
	  AND ix.indisvalid
	ORDER BY index_cls.relname, key_pos.column_position`

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

func (d *postgresDriver) SupportsRichMetadata() core.RichMetadataSupport {
	return core.RichMetadataSupport{
		Columns:   true,
		Indexes:   true,
		Sequences: true,
	}
}

func (d *postgresDriver) ColumnsRich(opts *core.TableOptions) ([]*core.Column, error) {
	if opts == nil {
		return nil, fmt.Errorf("opts cannot be nil")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	rows, err := d.c.QueryWithArgs(ctx, postgresColumnsRichSQL, opts.Schema, opts.Table)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	columns := []*core.Column{}
	byName := map[string]*core.Column{}
	for rows.HasNext() {
		row, err := rows.Next()
		if err != nil {
			return nil, err
		}
		if len(row) < 7 {
			return nil, fmt.Errorf("postgres columns rich: expected 7 columns, got %d", len(row))
		}
		name, err := postgresStringValue(row[0])
		if err != nil {
			return nil, fmt.Errorf("postgres columns rich column name: %w", err)
		}
		typ, err := postgresStringValue(row[1])
		if err != nil {
			return nil, fmt.Errorf("postgres columns rich data type: %w", err)
		}
		nullable, err := postgresBoolValue(row[2])
		if err != nil {
			return nil, fmt.Errorf("postgres columns rich nullable: %w", err)
		}
		generated, err := postgresNullableStringValue(row[3])
		if err != nil {
			return nil, fmt.Errorf("postgres columns rich generated: %w", err)
		}
		identity, err := postgresNullableStringValue(row[4])
		if err != nil {
			return nil, fmt.Errorf("postgres columns rich identity: %w", err)
		}
		defaultExpr, err := postgresNullableStringValue(row[5])
		if err != nil {
			return nil, fmt.Errorf("postgres columns rich default: %w", err)
		}
		serialSequence, err := postgresNullableStringValue(row[6])
		if err != nil {
			return nil, fmt.Errorf("postgres columns rich serial sequence: %w", err)
		}

		col := &core.Column{
			Name:           name,
			Type:           typ,
			Nullable:       &nullable,
			Generated:      generated,
			Identity:       identity,
			Default:        defaultExpr,
			SerialSequence: serialSequence,
		}
		columns = append(columns, col)
		byName[name] = col
	}

	if err := d.applyPostgresPrimaryKeys(ctx, opts, byName); err != nil {
		return nil, err
	}
	if err := d.applyPostgresForeignKeys(ctx, opts, byName); err != nil {
		return nil, err
	}

	return columns, nil
}

func (d *postgresDriver) applyPostgresPrimaryKeys(ctx context.Context, opts *core.TableOptions, byName map[string]*core.Column) error {
	rows, err := d.c.QueryWithArgs(ctx, postgresPrimaryKeysSQL, opts.Schema, opts.Table)
	if err != nil {
		return err
	}
	defer rows.Close()

	for rows.HasNext() {
		row, err := rows.Next()
		if err != nil {
			return err
		}
		if len(row) < 2 {
			return fmt.Errorf("postgres primary keys: expected 2 columns, got %d", len(row))
		}
		name, err := postgresStringValue(row[0])
		if err != nil {
			return fmt.Errorf("postgres primary key column name: %w", err)
		}
		position, err := postgresIntValue(row[1])
		if err != nil {
			return fmt.Errorf("postgres primary key position: %w", err)
		}
		if col := byName[name]; col != nil {
			col.PrimaryKey = true
			col.PrimaryKeyOrdinal = position
		}
	}
	return nil
}

type postgresFKRow struct {
	constraintName string
	sourceColumn   string
	ordinal        int
	targetSchema   string
	targetTable    string
	targetColumn   string
}

func (d *postgresDriver) applyPostgresForeignKeys(ctx context.Context, opts *core.TableOptions, byName map[string]*core.Column) error {
	rows, err := d.c.QueryWithArgs(ctx, postgresForeignKeysSQL, opts.Schema, opts.Table)
	if err != nil {
		return err
	}
	defer rows.Close()

	groups := map[string][]postgresFKRow{}
	for rows.HasNext() {
		row, err := rows.Next()
		if err != nil {
			return err
		}
		if len(row) < 6 {
			return fmt.Errorf("postgres foreign keys: expected 6 columns, got %d", len(row))
		}
		constraintName, err := postgresStringValue(row[0])
		if err != nil {
			return fmt.Errorf("postgres foreign key constraint: %w", err)
		}
		sourceColumn, err := postgresStringValue(row[1])
		if err != nil {
			return fmt.Errorf("postgres foreign key source column: %w", err)
		}
		ordinal, err := postgresIntValue(row[2])
		if err != nil {
			return fmt.Errorf("postgres foreign key ordinal: %w", err)
		}
		targetSchema, err := postgresStringValue(row[3])
		if err != nil {
			return fmt.Errorf("postgres foreign key target schema: %w", err)
		}
		targetTable, err := postgresStringValue(row[4])
		if err != nil {
			return fmt.Errorf("postgres foreign key target table: %w", err)
		}
		targetColumn, err := postgresStringValue(row[5])
		if err != nil {
			return fmt.Errorf("postgres foreign key target column: %w", err)
		}

		key := opts.Schema + "." + opts.Table + "." + constraintName
		groups[key] = append(groups[key], postgresFKRow{
			constraintName: constraintName,
			sourceColumn:   sourceColumn,
			ordinal:        ordinal,
			targetSchema:   targetSchema,
			targetTable:    targetTable,
			targetColumn:   targetColumn,
		})
	}

	keys := make([]string, 0, len(groups))
	for key := range groups {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		group := groups[key]
		sort.SliceStable(group, func(i, j int) bool {
			return group[i].ordinal < group[j].ordinal
		})
		sourceColumns := make([]string, len(group))
		targetColumns := make([]string, len(group))
		for i, fk := range group {
			sourceColumns[i] = fk.sourceColumn
			targetColumns[i] = fk.targetColumn
		}
		for _, fk := range group {
			col := byName[fk.sourceColumn]
			if col == nil {
				continue
			}
			ref := &core.FKRef{
				ConstraintName: fk.constraintName,
				SourceSchema:   opts.Schema,
				SourceTable:    opts.Table,
				SourceColumn:   fk.sourceColumn,
				SourceColumns:  cloneStrings(sourceColumns),
				SourceOrdinal:  fk.ordinal,
				TargetSchema:   fk.targetSchema,
				TargetTable:    fk.targetTable,
				TargetColumn:   fk.targetColumn,
				TargetColumns:  cloneStrings(targetColumns),
			}
			col.ForeignKeys = append(col.ForeignKeys, ref)
		}
	}

	return nil
}

func (d *postgresDriver) Indexes(opts *core.TableOptions) ([]*core.Index, error) {
	if opts == nil {
		return nil, fmt.Errorf("opts cannot be nil")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	rows, err := d.c.QueryWithArgs(ctx, postgresIndexesSQL, opts.Schema, opts.Table)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	type indexedRow struct {
		key       string
		position  int
		column    string
		order     string
		isInclude bool
	}

	byKey := map[string]*core.Index{}
	ordered := []*core.Index{}
	var indexedRows []indexedRow
	for rows.HasNext() {
		row, err := rows.Next()
		if err != nil {
			return nil, err
		}
		if len(row) < 10 {
			return nil, fmt.Errorf("postgres indexes: expected 10 columns, got %d", len(row))
		}
		name, err := postgresStringValue(row[0])
		if err != nil {
			return nil, fmt.Errorf("postgres index name: %w", err)
		}
		owner, err := postgresStringValue(row[1])
		if err != nil {
			return nil, fmt.Errorf("postgres index owner: %w", err)
		}
		tableOwner, err := postgresStringValue(row[2])
		if err != nil {
			return nil, fmt.Errorf("postgres index table owner: %w", err)
		}
		tableName, err := postgresStringValue(row[3])
		if err != nil {
			return nil, fmt.Errorf("postgres index table name: %w", err)
		}
		uniqueness, err := postgresStringValue(row[4])
		if err != nil {
			return nil, fmt.Errorf("postgres index uniqueness: %w", err)
		}
		column, err := postgresStringValue(row[5])
		if err != nil {
			return nil, fmt.Errorf("postgres index column: %w", err)
		}
		order, err := postgresNullableStringValue(row[6])
		if err != nil {
			return nil, fmt.Errorf("postgres index order: %w", err)
		}
		position, err := postgresIntValue(row[7])
		if err != nil {
			return nil, fmt.Errorf("postgres index column position: %w", err)
		}
		isInclude, err := postgresBoolValue(row[8])
		if err != nil {
			return nil, fmt.Errorf("postgres index include flag: %w", err)
		}
		pkBacked, err := postgresBoolValue(row[9])
		if err != nil {
			return nil, fmt.Errorf("postgres index pk_backed: %w", err)
		}

		key := owner + "." + name
		index := byKey[key]
		if index == nil {
			index = &core.Index{
				Name:     name,
				Schema:   tableOwner,
				Table:    tableName,
				Unique:   strings.EqualFold(uniqueness, "UNIQUE"),
				PKBacked: pkBacked,
			}
			byKey[key] = index
			ordered = append(ordered, index)
		}
		indexedRows = append(indexedRows, indexedRow{
			key:       key,
			position:  position,
			column:    column,
			order:     postgresIndexOrder(order),
			isInclude: isInclude,
		})
	}

	sort.SliceStable(indexedRows, func(i, j int) bool {
		if indexedRows[i].key == indexedRows[j].key {
			return indexedRows[i].position < indexedRows[j].position
		}
		return indexedRows[i].key < indexedRows[j].key
	})
	for _, row := range indexedRows {
		index := byKey[row.key]
		if row.isInclude {
			index.IncludeColumns = append(index.IncludeColumns, row.column)
			continue
		}
		index.Columns = append(index.Columns, row.column)
		index.Orders = append(index.Orders, row.order)
	}

	return ordered, nil
}

func (d *postgresDriver) Sequences(schema string) ([]*core.Sequence, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	rows, err := d.c.QueryWithArgs(ctx, postgresSequencesSQL, schema)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	sequences := []*core.Sequence{}
	for rows.HasNext() {
		row, err := rows.Next()
		if err != nil {
			return nil, err
		}
		if len(row) < 3 {
			return nil, fmt.Errorf("postgres sequences: expected 3 columns, got %d", len(row))
		}
		name, err := postgresStringValue(row[0])
		if err != nil {
			return nil, fmt.Errorf("postgres sequence name: %w", err)
		}
		increment, err := postgresInt64Value(row[1])
		if err != nil {
			return nil, fmt.Errorf("postgres sequence increment: %w", err)
		}
		cacheSize, err := postgresInt64Value(row[2])
		if err != nil {
			return nil, fmt.Errorf("postgres sequence cache size: %w", err)
		}
		sequences = append(sequences, &core.Sequence{
			Name:      name,
			Schema:    schema,
			Increment: increment,
			CacheSize: cacheSize,
		})
	}
	return sequences, nil
}

func postgresStringValue(value any) (string, error) {
	switch v := value.(type) {
	case string:
		return v, nil
	case []byte:
		return string(v), nil
	case fmt.Stringer:
		return v.String(), nil
	case nil:
		return "", fmt.Errorf("expected string, got nil")
	default:
		return "", fmt.Errorf("expected string, got %T", value)
	}
}

func postgresNullableStringValue(value any) (string, error) {
	if value == nil {
		return "", nil
	}
	return postgresStringValue(value)
}

func postgresIntValue(value any) (int, error) {
	n, err := postgresInt64Value(value)
	if err != nil {
		return 0, err
	}
	return int(n), nil
}

func postgresInt64Value(value any) (int64, error) {
	switch v := value.(type) {
	case int:
		return int64(v), nil
	case int8:
		return int64(v), nil
	case int16:
		return int64(v), nil
	case int32:
		return int64(v), nil
	case int64:
		return v, nil
	case uint:
		return int64(v), nil
	case uint8:
		return int64(v), nil
	case uint16:
		return int64(v), nil
	case uint32:
		return int64(v), nil
	case uint64:
		if v > math.MaxInt64 {
			return 0, fmt.Errorf("integer overflows int64: %d", v)
		}
		return int64(v), nil
	case float64:
		if math.Trunc(v) != v {
			return 0, fmt.Errorf("expected integer, got %v", v)
		}
		return int64(v), nil
	case string:
		n, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64)
		if err != nil {
			return 0, err
		}
		return n, nil
	case []byte:
		n, err := strconv.ParseInt(strings.TrimSpace(string(v)), 10, 64)
		if err != nil {
			return 0, err
		}
		return n, nil
	default:
		return 0, fmt.Errorf("expected integer, got %T", value)
	}
}

func postgresBoolValue(value any) (bool, error) {
	switch v := value.(type) {
	case bool:
		return v, nil
	case int:
		return v != 0, nil
	case int64:
		return v != 0, nil
	case float64:
		return v != 0, nil
	case string:
		trimmed := strings.TrimSpace(strings.ToUpper(v))
		return trimmed == "1" || trimmed == "Y" || trimmed == "YES" || trimmed == "T" || trimmed == "TRUE", nil
	case []byte:
		return postgresBoolValue(string(v))
	default:
		return false, fmt.Errorf("expected bool-ish value, got %T", value)
	}
}

func postgresIndexOrder(descend string) string {
	if strings.EqualFold(strings.TrimSpace(descend), "DESC") {
		return "DESC"
	}
	return "ASC"
}
