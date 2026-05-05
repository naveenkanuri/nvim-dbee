package adapters

import (
	"errors"
	"strings"
	"testing"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/kndndrj/nvim-dbee/dbee/core/builders"
	"github.com/lib/pq"
	"github.com/stretchr/testify/require"
)

func newPostgresRichMetadataMock(t *testing.T) (*postgresDriver, sqlmock.Sqlmock) {
	t.Helper()
	db, mock, err := sqlmock.New(sqlmock.QueryMatcherOption(sqlmock.QueryMatcherEqual))
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })
	return &postgresDriver{c: builders.NewClient(db), url: nil}, mock
}

func TestPostgresRichMetadataSupport(t *testing.T) {
	driver := &postgresDriver{}
	support := driver.SupportsRichMetadata()
	require.True(t, support.Columns)
	require.True(t, support.Indexes)
	require.True(t, support.Sequences)

	for _, query := range []string{
		postgresColumnsRichSQL,
		postgresPrimaryKeysSQL,
		postgresForeignKeysSQL,
		postgresIndexesSQL,
		postgresSequencesSQL,
	} {
		require.Contains(t, query, "pg_catalog.")
		require.NotContains(t, query, ":p_schema")
		require.NotContains(t, query, ":p_table")
	}
	require.Contains(t, postgresColumnsRichSQL, "WITH cols AS")
	require.Contains(t, postgresColumnsRichSQL, "n.nspname = $1")
	require.Contains(t, postgresColumnsRichSQL, "c.relname = $2")
	require.Contains(t, postgresColumnsRichSQL, "c.relkind IN ('r', 'p', 'f', 'v', 'm')")
	require.Contains(t, postgresColumnsRichSQL, "pg_catalog.pg_get_expr(d.adbin, d.adrelid, false)")
	require.Contains(t, postgresColumnsRichSQL, "pg_catalog.quote_ident(schema_name) || '.' || pg_catalog.quote_ident(table_name)")
	require.Contains(t, postgresIndexesSQL, "table_cls.relkind IN ('r', 'p', 'v', 'm')")
	require.Contains(t, postgresIndexesSQL, "ix.indnkeyatts")
	require.Contains(t, postgresIndexesSQL, "pg_catalog.pg_get_indexdef")
	require.Contains(t, postgresIndexesSQL, "ix.indisprimary AS pk_backed")
	require.Contains(t, postgresIndexesSQL, "ix.indisready")
	require.Contains(t, postgresIndexesSQL, "ix.indisvalid")
	require.Contains(t, postgresSequencesSQL, "c.relkind = 'S'")
	require.Contains(t, postgresSequencesSQL, "JOIN pg_catalog.pg_sequence")

	t.Log("RICH_PG_SUPPORT_TRUE=true")
	t.Log("RICH_PG_POSITIONAL_BINDS=true")
	t.Log("RICH_PG_CATALOG_SCOPING=true")
}

func TestPostgresPG12FloorBehavior(t *testing.T) {
	driver, mock := newPostgresRichMetadataMock(t)

	mock.ExpectQuery(postgresColumnsRichSQL).
		WithArgs("public", "child_account").
		WillReturnError(&pq.Error{Code: "42703", Message: "column does not exist"})

	_, err := driver.ColumnsRich(&core.TableOptions{
		Schema: "public",
		Table:  "child_account",
	})
	require.Error(t, err)
	var pgErr *pq.Error
	require.True(t, errors.As(err, &pgErr))
	require.Equal(t, pq.ErrorCode("42703"), pgErr.Code)
	require.NoError(t, mock.ExpectationsWereMet())

	t.Log("RICH_PG_PG12_FLOOR_BEHAVIOR_OK=true")
}

func TestPostgresColumnsRichCompositeMetadata(t *testing.T) {
	driver, mock := newPostgresRichMetadataMock(t)

	mock.ExpectQuery(postgresColumnsRichSQL).
		WithArgs("public", "child_account").
		WillReturnRows(sqlmock.NewRows([]string{
			"column_name",
			"data_type",
			"nullable",
			"attgenerated",
			"attidentity",
			"default_expr",
			"serial_sequence",
		}).
			AddRow("tenant_id", "uuid", false, "", "", nil, nil).
			AddRow("parent_id", "bigint", false, "", "", nil, nil).
			AddRow("generated_total", "numeric", true, "s", "", "(amount * tax)", nil).
			AddRow("legacy_serial", "integer", false, "", "", "nextval('public.child_account_legacy_serial_seq'::regclass)", "public.child_account_legacy_serial_seq").
			AddRow("identity_id", "bigint", false, "", "a", nil, nil))
	mock.ExpectQuery(postgresPrimaryKeysSQL).
		WithArgs("public", "child_account").
		WillReturnRows(sqlmock.NewRows([]string{"column_name", "position"}).
			AddRow("parent_id", int64(2)).
			AddRow("tenant_id", int64(1)))
	mock.ExpectQuery(postgresForeignKeysSQL).
		WithArgs("public", "child_account").
		WillReturnRows(sqlmock.NewRows([]string{
			"constraint_name",
			"source_column",
			"ordinal",
			"target_schema",
			"target_table",
			"target_column",
		}).
			AddRow("fk_child_parent", "parent_id", int64(2), "public", "parent_account", "id").
			AddRow("fk_child_parent", "tenant_id", int64(1), "public", "parent_account", "tenant_id"))

	columns, err := driver.ColumnsRich(&core.TableOptions{
		Schema: "public",
		Table:  "child_account",
	})
	require.NoError(t, err)
	require.Len(t, columns, 5)
	require.NoError(t, mock.ExpectationsWereMet())

	byName := postgresColumnsByName(columns)
	require.Equal(t, []string{"tenant_id", "parent_id", "generated_total", "legacy_serial", "identity_id"}, postgresColumnNames(columns))

	require.NotNil(t, byName["tenant_id"].Nullable)
	require.False(t, *byName["tenant_id"].Nullable)
	require.NotNil(t, byName["generated_total"].Nullable)
	require.True(t, *byName["generated_total"].Nullable)
	require.Equal(t, "s", byName["generated_total"].Generated)
	require.Equal(t, "(amount * tax)", byName["generated_total"].Default)
	require.Equal(t, "", byName["legacy_serial"].Identity)
	require.Equal(t, "nextval('public.child_account_legacy_serial_seq'::regclass)", byName["legacy_serial"].Default)
	require.Equal(t, "public.child_account_legacy_serial_seq", byName["legacy_serial"].SerialSequence)
	require.Equal(t, "a", byName["identity_id"].Identity)
	require.Equal(t, "", byName["identity_id"].Default)
	require.Equal(t, "", byName["identity_id"].SerialSequence)

	require.True(t, byName["tenant_id"].PrimaryKey)
	require.Equal(t, 1, byName["tenant_id"].PrimaryKeyOrdinal)
	require.True(t, byName["parent_id"].PrimaryKey)
	require.Equal(t, 2, byName["parent_id"].PrimaryKeyOrdinal)

	tenantFKs := byName["tenant_id"].ForeignKeys
	parentFKs := byName["parent_id"].ForeignKeys
	require.Len(t, tenantFKs, 1)
	require.Len(t, parentFKs, 1)
	require.NotSame(t, tenantFKs[0], parentFKs[0])
	require.Equal(t, "fk_child_parent", tenantFKs[0].ConstraintName)
	require.Equal(t, "public", tenantFKs[0].SourceSchema)
	require.Equal(t, "child_account", tenantFKs[0].SourceTable)
	require.Equal(t, "tenant_id", tenantFKs[0].SourceColumn)
	require.Equal(t, 1, tenantFKs[0].SourceOrdinal)
	require.Equal(t, "public", tenantFKs[0].TargetSchema)
	require.Equal(t, "parent_account", tenantFKs[0].TargetTable)
	require.Equal(t, "tenant_id", tenantFKs[0].TargetColumn)
	require.Equal(t, "parent_id", parentFKs[0].SourceColumn)
	require.Equal(t, "id", parentFKs[0].TargetColumn)
	require.Equal(t, []string{"tenant_id", "parent_id"}, tenantFKs[0].SourceColumns)
	require.Equal(t, []string{"tenant_id", "parent_id"}, parentFKs[0].SourceColumns)
	require.Equal(t, []string{"tenant_id", "id"}, tenantFKs[0].TargetColumns)
	require.Equal(t, []string{"tenant_id", "id"}, parentFKs[0].TargetColumns)

	t.Log("RICH_PG_RICH_COLUMNS_OK=true")
	t.Log("RICH_PG_COMPOSITE_PK_OK=true")
	t.Log("RICH_PG_COMPOSITE_FK_OK=true")
	t.Log("RICH_PG_FK_REF_POINTER_PER_COLUMN_OK=true")
}

func TestPostgresIndexesRichMetadata(t *testing.T) {
	driver, mock := newPostgresRichMetadataMock(t)

	mock.ExpectQuery(postgresIndexesSQL).
		WithArgs("public", "child_account").
		WillReturnRows(sqlmock.NewRows([]string{
			"index_name",
			"index_owner",
			"table_owner",
			"table_name",
			"uniqueness",
			"column_name",
			"descend",
			"column_position",
			"is_include",
			"pk_backed",
		}).
			AddRow("idx_child_expr", "public", "public", "child_account", "NONUNIQUE", "lower(name)", "ASC", int64(1), false, false).
			AddRow("idx_child_lookup", "public", "public", "child_account", "NONUNIQUE", "tenant_id", "ASC", int64(1), false, false).
			AddRow("idx_child_lookup", "public", "public", "child_account", "NONUNIQUE", "parent_id", "DESC", int64(2), false, false).
			AddRow("idx_child_lookup", "public", "public", "child_account", "NONUNIQUE", "updated_at", nil, int64(3), true, false).
			AddRow("idx_child_lookup", "public", "public", "child_account", "NONUNIQUE", "status", nil, int64(4), true, false).
			AddRow("pk_child", "public", "public", "child_account", "UNIQUE", "tenant_id", "ASC", int64(1), false, true).
			AddRow("pk_child", "public", "public", "child_account", "UNIQUE", "parent_id", "ASC", int64(2), false, true))

	indexes, err := driver.Indexes(&core.TableOptions{
		Schema: "public",
		Table:  "child_account",
	})
	require.NoError(t, err)
	require.Len(t, indexes, 3)
	require.NoError(t, mock.ExpectationsWereMet())

	byName := postgresIndexesByName(indexes)
	require.Equal(t, []string{"lower(name)"}, byName["idx_child_expr"].Columns)
	require.Equal(t, []string{"ASC"}, byName["idx_child_expr"].Orders)
	require.False(t, byName["idx_child_expr"].Unique)
	require.False(t, byName["idx_child_expr"].PKBacked)

	lookup := byName["idx_child_lookup"]
	require.Equal(t, "public", lookup.Schema)
	require.Equal(t, "child_account", lookup.Table)
	require.Equal(t, []string{"tenant_id", "parent_id"}, lookup.Columns)
	require.Equal(t, []string{"ASC", "DESC"}, lookup.Orders)
	require.Equal(t, []string{"updated_at", "status"}, lookup.IncludeColumns)
	for _, keyColumn := range lookup.Columns {
		require.NotContains(t, lookup.IncludeColumns, keyColumn)
	}

	pk := byName["pk_child"]
	require.True(t, pk.Unique)
	require.True(t, pk.PKBacked)
	require.Equal(t, []string{"tenant_id", "parent_id"}, pk.Columns)
	require.Empty(t, pk.IncludeColumns)

	mock.ExpectQuery(postgresIndexesSQL).
		WithArgs("public", "foreign_account").
		WillReturnRows(sqlmock.NewRows([]string{
			"index_name",
			"index_owner",
			"table_owner",
			"table_name",
			"uniqueness",
			"column_name",
			"descend",
			"column_position",
			"is_include",
			"pk_backed",
		}))
	foreignIndexes, err := driver.Indexes(&core.TableOptions{
		Schema: "public",
		Table:  "foreign_account",
	})
	require.NoError(t, err)
	require.NotNil(t, foreignIndexes)
	require.Empty(t, foreignIndexes)
	require.NoError(t, mock.ExpectationsWereMet())

	t.Log("RICH_PG_INDEXES_OK=true")
	t.Log("RICH_PG_INCLUDE_COLUMNS_OK=true")
}

func TestPostgresSequencesRichMetadata(t *testing.T) {
	driver, mock := newPostgresRichMetadataMock(t)

	mock.ExpectQuery(postgresSequencesSQL).
		WithArgs("public").
		WillReturnRows(sqlmock.NewRows([]string{"sequence_name", "increment_by", "cache_size"}).
			AddRow("account_seq", int64(1), int64(20)).
			AddRow("audit_seq", int64(10), int64(100)))

	sequences, err := driver.Sequences("public")
	require.NoError(t, err)
	require.Len(t, sequences, 2)
	require.NoError(t, mock.ExpectationsWereMet())

	require.Equal(t, "account_seq", sequences[0].Name)
	require.Equal(t, "public", sequences[0].Schema)
	require.Equal(t, int64(1), sequences[0].Increment)
	require.Equal(t, int64(20), sequences[0].CacheSize)
	require.Equal(t, "audit_seq", sequences[1].Name)
	require.Equal(t, int64(10), sequences[1].Increment)
	require.Equal(t, int64(100), sequences[1].CacheSize)

	t.Log("RICH_PG_SEQUENCES_OK=true")
}

func postgresColumnsByName(columns []*core.Column) map[string]*core.Column {
	byName := map[string]*core.Column{}
	for _, col := range columns {
		byName[col.Name] = col
	}
	return byName
}

func postgresColumnNames(columns []*core.Column) []string {
	names := make([]string, 0, len(columns))
	for _, col := range columns {
		names = append(names, col.Name)
	}
	return names
}

func postgresIndexesByName(indexes []*core.Index) map[string]*core.Index {
	byName := map[string]*core.Index{}
	for _, index := range indexes {
		byName[index.Name] = index
	}
	return byName
}

func TestPostgresRichMetadataNoNamedBindsInTests(t *testing.T) {
	require.False(t, strings.Contains(postgresColumnsRichSQL+postgresPrimaryKeysSQL+postgresForeignKeysSQL+postgresIndexesSQL+postgresSequencesSQL, ":p_"))
}
