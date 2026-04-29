package adapters

import (
	"testing"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/kndndrj/nvim-dbee/dbee/core/builders"
	"github.com/stretchr/testify/require"
)

func scopedStructureOptions(fold string, include, exclude []string) *core.StructureOptions {
	return &core.StructureOptions{
		Fold: fold,
		SchemaFilter: &core.SchemaFilterOptions{
			Include: include,
			Exclude: exclude,
		},
		SchemaFilterSignature: "test-signature",
	}
}

func TestPostgresStructureWithOptionsPushesSchemaFilterIntoSQL(t *testing.T) {
	db, mock, err := sqlmock.New(sqlmock.QueryMatcherOption(sqlmock.QueryMatcherRegexp))
	require.NoError(t, err)
	t.Cleanup(func() { db.Close() })

	driver := &postgresDriver{c: builders.NewClient(db)}
	mock.ExpectQuery(`(?s)WHERE \(\(schema_name = \$1 OR schema_name LIKE \$2\) AND NOT \(schema_name LIKE \$3\)\)`).
		WithArgs("hr", "fin%", "hr_tmp%").
		WillReturnRows(sqlmock.NewRows([]string{"schema_name", "object_name", "object_type"}).
			AddRow("hr", "employees", "BASE TABLE"))

	structure, err := driver.StructureWithOptions(scopedStructureOptions("lower", []string{"hr", "fin%"}, []string{"hr_tmp%"}))
	require.NoError(t, err)
	require.Len(t, structure, 1)
	require.NoError(t, mock.ExpectationsWereMet())
}

func TestMySQLStructureWithOptionsPushesSchemaFilterIntoSQL(t *testing.T) {
	db, mock, err := sqlmock.New(sqlmock.QueryMatcherOption(sqlmock.QueryMatcherRegexp))
	require.NoError(t, err)
	t.Cleanup(func() { db.Close() })

	driver := &mySQLDriver{c: builders.NewClient(db)}
	mock.ExpectQuery(`(?s)FROM information_schema\.tables WHERE \(\(table_schema = \? OR table_schema LIKE \?\) AND NOT \(table_schema LIKE \?\)\)`).
		WithArgs("hr", "fin%", "hr_tmp%").
		WillReturnRows(sqlmock.NewRows([]string{"table_schema", "table_name", "object_type"}).
			AddRow("hr", "employees", "TABLE"))

	structure, err := driver.StructureWithOptions(scopedStructureOptions("lower", []string{"hr", "fin%"}, []string{"hr_tmp%"}))
	require.NoError(t, err)
	require.Len(t, structure, 1)
	require.NoError(t, mock.ExpectationsWereMet())
}

func TestSQLServerStructureWithOptionsPushesSchemaFilterIntoSQL(t *testing.T) {
	db, mock, err := sqlmock.New(sqlmock.QueryMatcherOption(sqlmock.QueryMatcherRegexp))
	require.NoError(t, err)
	t.Cleanup(func() { db.Close() })

	driver := &sqlServerDriver{c: builders.NewClient(db)}
	mock.ExpectQuery(`(?s)FROM INFORMATION_SCHEMA\.TABLES WHERE \(\(table_schema = @p1 OR table_schema LIKE @p2\) AND NOT \(table_schema LIKE @p3\)\)`).
		WithArgs("hr", "fin%", "hr_tmp%").
		WillReturnRows(sqlmock.NewRows([]string{"table_schema", "table_name", "table_type"}).
			AddRow("hr", "employees", "BASE TABLE"))

	structure, err := driver.StructureWithOptions(scopedStructureOptions("case_insensitive", []string{"hr", "fin%"}, []string{"hr_tmp%"}))
	require.NoError(t, err)
	require.Len(t, structure, 1)
	require.NoError(t, mock.ExpectationsWereMet())
}

func TestOracleStructureWithOptionsPushesSchemaFilterIntoSQL(t *testing.T) {
	db, mock, err := sqlmock.New(sqlmock.QueryMatcherOption(sqlmock.QueryMatcherRegexp))
	require.NoError(t, err)
	t.Cleanup(func() { db.Close() })

	driver := &oracleDriver{c: builders.NewClient(db), db: db}
	mock.ExpectQuery(`(?s)WHERE owner IN \(SELECT username FROM all_users WHERE common = 'NO'\) AND \(\(owner = :1 OR owner LIKE :2\) AND NOT \(owner LIKE :3\)\)`).
		WithArgs("HR", "FIN%", "HR_TEMP%").
		WillReturnRows(sqlmock.NewRows([]string{"owner", "object_name", "object_type"}).
			AddRow("HR", "EMPLOYEES", "TABLE"))

	structure, err := driver.StructureWithOptions(scopedStructureOptions("upper", []string{"HR", "FIN%"}, []string{"HR_TEMP%"}))
	require.NoError(t, err)
	require.Len(t, structure, 1)
	require.NoError(t, mock.ExpectationsWereMet())
}

func TestStructureForSchemaRejectsFilteredOutSchemaBeforeQuery(t *testing.T) {
	db, mock, err := sqlmock.New()
	require.NoError(t, err)
	t.Cleanup(func() { db.Close() })

	driver := &postgresDriver{c: builders.NewClient(db)}
	objects, err := driver.StructureForSchema("audit", scopedStructureOptions("lower", []string{"app%"}, nil))
	require.NoError(t, err)
	require.Empty(t, objects)
	require.NoError(t, mock.ExpectationsWereMet())
}
