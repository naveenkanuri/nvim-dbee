package adapters

import (
	"database/sql"
	"database/sql/driver"
	"strings"
	"testing"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/kndndrj/nvim-dbee/dbee/core/builders"
	"github.com/stretchr/testify/require"
)

func newOracleRichMetadataMock(t *testing.T) (*oracleDriver, sqlmock.Sqlmock) {
	t.Helper()
	db, mock, err := sqlmock.New(sqlmock.QueryMatcherOption(sqlmock.QueryMatcherEqual))
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })
	return &oracleDriver{c: builders.NewClient(db), db: db}, mock
}

func oracleRichTableArgs() []driver.Value {
	return []driver.Value{
		sql.Named("schema", "APP"),
		sql.Named("table", "ACCOUNT"),
	}
}

func TestOracleColumnsRichCompositeMetadata(t *testing.T) {
	driver, mock := newOracleRichMetadataMock(t)

	args := oracleRichTableArgs()
	mock.ExpectQuery(oracleColumnsRichSQL).
		WithArgs(args...).
		WillReturnRows(sqlmock.NewRows([]string{"column_name", "data_type", "nullable"}).
			AddRow("ID", "NUMBER", "N").
			AddRow("CUSTOMER_ID", "NUMBER", "N").
			AddRow("TENANT_ID", "NUMBER", "N").
			AddRow("DESCRIPTION", "VARCHAR2(100)", "Y"))
	mock.ExpectQuery(oraclePrimaryKeysSQL).
		WithArgs(args...).
		WillReturnRows(sqlmock.NewRows([]string{"column_name", "position"}).
			AddRow("TENANT_ID", int64(2)).
			AddRow("CUSTOMER_ID", int64(1)))
	mock.ExpectQuery(oracleForeignKeysSQL).
		WithArgs(args...).
		WillReturnRows(sqlmock.NewRows([]string{
			"constraint_name",
			"source_column",
			"ordinal",
			"target_schema",
			"target_table",
			"target_column",
		}).
			AddRow("FK_ACCOUNT_CUSTOMER", "TENANT_ID", int64(2), "APP", "CUSTOMER", "TENANT_ID").
			AddRow("FK_ACCOUNT_CUSTOMER", "CUSTOMER_ID", int64(1), "APP", "CUSTOMER", "ID"))

	columns, err := driver.ColumnsRich(&core.TableOptions{
		Schema: "APP",
		Table:  "ACCOUNT",
	})
	require.NoError(t, err)
	require.Len(t, columns, 4)
	require.NoError(t, mock.ExpectationsWereMet())

	byName := map[string]*core.Column{}
	for _, col := range columns {
		byName[col.Name] = col
	}

	require.NotNil(t, byName["ID"].Nullable)
	require.False(t, *byName["ID"].Nullable)
	require.NotNil(t, byName["DESCRIPTION"].Nullable)
	require.True(t, *byName["DESCRIPTION"].Nullable)

	require.True(t, byName["CUSTOMER_ID"].PrimaryKey)
	require.Equal(t, 1, byName["CUSTOMER_ID"].PrimaryKeyOrdinal)
	require.True(t, byName["TENANT_ID"].PrimaryKey)
	require.Equal(t, 2, byName["TENANT_ID"].PrimaryKeyOrdinal)

	customerFKs := byName["CUSTOMER_ID"].ForeignKeys
	tenantFKs := byName["TENANT_ID"].ForeignKeys
	require.Len(t, customerFKs, 1)
	require.Len(t, tenantFKs, 1)
	require.NotSame(t, customerFKs[0], tenantFKs[0])
	require.Equal(t, "CUSTOMER_ID", customerFKs[0].SourceColumn)
	require.Equal(t, "ID", customerFKs[0].TargetColumn)
	require.Equal(t, "TENANT_ID", tenantFKs[0].SourceColumn)
	require.Equal(t, "TENANT_ID", tenantFKs[0].TargetColumn)
	require.Equal(t, []string{"CUSTOMER_ID", "TENANT_ID"}, customerFKs[0].SourceColumns)
	require.Equal(t, customerFKs[0].SourceColumns, tenantFKs[0].SourceColumns)
	require.Equal(t, []string{"ID", "TENANT_ID"}, customerFKs[0].TargetColumns)
	require.Equal(t, customerFKs[0].TargetColumns, tenantFKs[0].TargetColumns)

	require.Contains(t, oracleForeignKeysSQL, "racc.position = acc.position")
	t.Log("RICH16_ORACLE_COLUMNS_RICH_OK=true")
	t.Log("RICH16_ORACLE_COMPOSITE_PK_ORDER_PRESERVED=true")
	t.Log("RICH16_FK_COMPOSITE_GROUPING_OK=true")
	t.Log("RICH16_FK_COMPOSITE_PER_COLUMN_REF_OK=true")
}

func TestOracleIndexesRichMetadata(t *testing.T) {
	driver, mock := newOracleRichMetadataMock(t)

	require.Contains(t, oracleIndexesSQL, "i.table_owner = :schema")
	require.NotContains(t, oracleIndexesSQL, "i.owner = :schema")

	args := oracleRichTableArgs()
	mock.ExpectQuery(oracleIndexesSQL).
		WithArgs(args...).
		WillReturnRows(sqlmock.NewRows([]string{
			"index_name",
			"index_owner",
			"table_owner",
			"table_name",
			"uniqueness",
			"column_name",
			"descend",
			"column_position",
			"pk_backed",
		}).
			AddRow("IDX_ACCOUNT_NAME", "REPORTING", "APP", "ACCOUNT", "UNIQUE", "NAME", "DESC", int64(2), int64(0)).
			AddRow("IDX_ACCOUNT_NAME", "REPORTING", "APP", "ACCOUNT", "UNIQUE", "TENANT_ID", "ASC", int64(1), int64(0)).
			AddRow("PK_ACCOUNT", "APP", "APP", "ACCOUNT", "UNIQUE", "ID", "ASC", int64(1), int64(1)))

	indexes, err := driver.Indexes(&core.TableOptions{
		Schema: "APP",
		Table:  "ACCOUNT",
	})
	require.NoError(t, err)
	require.Len(t, indexes, 2)
	require.NoError(t, mock.ExpectationsWereMet())

	require.Equal(t, "IDX_ACCOUNT_NAME", indexes[0].Name)
	require.Equal(t, "APP", indexes[0].Schema)
	require.Equal(t, "ACCOUNT", indexes[0].Table)
	require.True(t, indexes[0].Unique)
	require.False(t, indexes[0].PKBacked)
	require.Equal(t, []string{"TENANT_ID", "NAME"}, indexes[0].Columns)
	require.Equal(t, []string{"ASC", "DESC"}, indexes[0].Orders)

	require.Equal(t, "PK_ACCOUNT", indexes[1].Name)
	require.True(t, indexes[1].PKBacked)

	t.Log("RICH16_ORACLE_INDEXES_OK=true")
	t.Log("RICH16_ORACLE_INDEXES_PK_BACKED_FLAG=true")
}

func TestOracleSequencesRichMetadata(t *testing.T) {
	driver, mock := newOracleRichMetadataMock(t)

	mock.ExpectQuery(oracleSequencesSQL).
		WithArgs(sql.Named("schema", "APP")).
		WillReturnRows(sqlmock.NewRows([]string{"sequence_name", "increment_by", "cache_size"}).
			AddRow("ACCOUNT_SEQ", int64(1), int64(20)).
			AddRow("AUDIT_SEQ", int64(10), int64(100)))

	sequences, err := driver.Sequences("APP")
	require.NoError(t, err)
	require.Len(t, sequences, 2)
	require.NoError(t, mock.ExpectationsWereMet())

	require.Equal(t, "ACCOUNT_SEQ", sequences[0].Name)
	require.Equal(t, "APP", sequences[0].Schema)
	require.Equal(t, int64(1), sequences[0].Increment)
	require.Equal(t, int64(20), sequences[0].CacheSize)

	t.Log("RICH16_ORACLE_SEQUENCES_OK=true")
}

func TestOracleRichMetadataSupport(t *testing.T) {
	driver := &oracleDriver{}
	support := driver.SupportsRichMetadata()
	require.True(t, support.Columns)
	require.True(t, support.Indexes)
	require.True(t, support.Sequences)
}

func TestOracleIndexSQLScopesByTableOwner(t *testing.T) {
	require.Contains(t, oracleIndexesSQL, "i.table_owner = :schema")
	require.Contains(t, oracleIndexesSQL, "i.table_name = :table")
	require.Contains(t, oracleIndexesSQL, "ac.owner = i.table_owner")
	require.False(t, strings.Contains(oracleIndexesSQL, "WHERE i.owner = :schema"))
}
