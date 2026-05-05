package adapters

import (
	"testing"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/kndndrj/nvim-dbee/dbee/core/builders"
	"github.com/stretchr/testify/require"
)

func newPostgresListDatabasesMock(t *testing.T) (*postgresDriver, sqlmock.Sqlmock) {
	t.Helper()
	db, mock, err := sqlmock.New(sqlmock.QueryMatcherOption(sqlmock.QueryMatcherEqual))
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })
	return &postgresDriver{c: builders.NewClient(db)}, mock
}

func newSQLServerListDatabasesMock(t *testing.T) (*sqlServerDriver, sqlmock.Sqlmock) {
	t.Helper()
	db, mock, err := sqlmock.New(sqlmock.QueryMatcherOption(sqlmock.QueryMatcherEqual))
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })
	return &sqlServerDriver{c: builders.NewClient(db)}, mock
}

func newRedshiftListDatabasesMock(t *testing.T) (*redshiftDriver, sqlmock.Sqlmock) {
	t.Helper()
	db, mock, err := sqlmock.New(sqlmock.QueryMatcherOption(sqlmock.QueryMatcherEqual))
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })
	return &redshiftDriver{c: builders.NewClient(db)}, mock
}

func TestPostgresListDatabasesNoAlternatives(t *testing.T) {
	driver, mock := newPostgresListDatabasesMock(t)
	mock.ExpectQuery(postgresCurrentDatabaseSQL).
		WillReturnRows(sqlmock.NewRows([]string{"current_database"}).AddRow("dbee_test")).
		RowsWillBeClosed()
	mock.ExpectQuery(postgresAvailableDatabasesSQL).
		WillReturnRows(sqlmock.NewRows([]string{"datname"})).
		RowsWillBeClosed()

	current, available, err := driver.ListDatabases()
	require.NoError(t, err)
	require.Equal(t, "dbee_test", current)
	require.Empty(t, available)
	require.NoError(t, mock.ExpectationsWereMet())
}

func TestPostgresListDatabasesWithAlternatives(t *testing.T) {
	driver, mock := newPostgresListDatabasesMock(t)
	mock.ExpectQuery(postgresCurrentDatabaseSQL).
		WillReturnRows(sqlmock.NewRows([]string{"current_database"}).AddRow("dbee_test")).
		RowsWillBeClosed()
	mock.ExpectQuery(postgresAvailableDatabasesSQL).
		WillReturnRows(sqlmock.NewRows([]string{"datname"}).
			AddRow("analytics").
			AddRow("archive")).
		RowsWillBeClosed()

	current, available, err := driver.ListDatabases()
	require.NoError(t, err)
	require.Equal(t, "dbee_test", current)
	require.Equal(t, []string{"analytics", "archive"}, available)
	require.NoError(t, mock.ExpectationsWereMet())
}

func TestSQLServerListDatabasesNoAlternatives(t *testing.T) {
	driver, mock := newSQLServerListDatabasesMock(t)
	mock.ExpectQuery(sqlServerCurrentDatabaseSQL).
		WillReturnRows(sqlmock.NewRows([]string{"DB_NAME"}).AddRow("master")).
		RowsWillBeClosed()
	mock.ExpectQuery(sqlServerAvailableDatabasesSQL).
		WillReturnRows(sqlmock.NewRows([]string{"name"})).
		RowsWillBeClosed()

	current, available, err := driver.ListDatabases()
	require.NoError(t, err)
	require.Equal(t, "master", current)
	require.Empty(t, available)
	require.NoError(t, mock.ExpectationsWereMet())
}

func TestSQLServerListDatabasesWithAlternatives(t *testing.T) {
	driver, mock := newSQLServerListDatabasesMock(t)
	mock.ExpectQuery(sqlServerCurrentDatabaseSQL).
		WillReturnRows(sqlmock.NewRows([]string{"DB_NAME"}).AddRow("master")).
		RowsWillBeClosed()
	mock.ExpectQuery(sqlServerAvailableDatabasesSQL).
		WillReturnRows(sqlmock.NewRows([]string{"name"}).
			AddRow("analytics").
			AddRow("archive")).
		RowsWillBeClosed()

	current, available, err := driver.ListDatabases()
	require.NoError(t, err)
	require.Equal(t, "master", current)
	require.Equal(t, []string{"analytics", "archive"}, available)
	require.NoError(t, mock.ExpectationsWereMet())
}

func TestRedshiftListDatabasesNoAlternatives(t *testing.T) {
	driver, mock := newRedshiftListDatabasesMock(t)
	mock.ExpectQuery(redshiftCurrentDatabaseSQL).
		WillReturnRows(sqlmock.NewRows([]string{"current_database"}).AddRow("analytics")).
		RowsWillBeClosed()
	mock.ExpectQuery(redshiftAvailableDatabasesSQL).
		WillReturnRows(sqlmock.NewRows([]string{"datname"})).
		RowsWillBeClosed()

	current, available, err := driver.ListDatabases()
	require.NoError(t, err)
	require.Equal(t, "analytics", current)
	require.Empty(t, available)
	require.NoError(t, mock.ExpectationsWereMet())
}

func TestRedshiftListDatabasesWithAlternatives(t *testing.T) {
	driver, mock := newRedshiftListDatabasesMock(t)
	mock.ExpectQuery(redshiftCurrentDatabaseSQL).
		WillReturnRows(sqlmock.NewRows([]string{"current_database"}).AddRow("analytics")).
		RowsWillBeClosed()
	mock.ExpectQuery(redshiftAvailableDatabasesSQL).
		WillReturnRows(sqlmock.NewRows([]string{"datname"}).
			AddRow("dev").
			AddRow("prod")).
		RowsWillBeClosed()

	current, available, err := driver.ListDatabases()
	require.NoError(t, err)
	require.Equal(t, "analytics", current)
	require.Equal(t, []string{"dev", "prod"}, available)
	require.NoError(t, mock.ExpectationsWereMet())
}
