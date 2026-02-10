package builders

import (
	"context"
	"regexp"
	"testing"

	sqlmock "github.com/DATA-DOG/go-sqlmock"
	"github.com/stretchr/testify/require"
)

func TestQueryUntilNotEmptyWithArgs_RejectsMultipleQueries(t *testing.T) {
	db, mock, err := sqlmock.New()
	require.NoError(t, err)
	defer db.Close()

	client := NewClient(db)

	_, err = client.QueryUntilNotEmptyWithArgs(context.Background(), []any{"42"}, "SELECT 1", "SELECT 2")
	require.ErrorContains(t, err, "single query")
	require.NoError(t, mock.ExpectationsWereMet())
}

func TestQueryUntilNotEmptyWithArgs_SingleQueryPassesArgs(t *testing.T) {
	db, mock, err := sqlmock.New()
	require.NoError(t, err)
	defer db.Close()

	client := NewClient(db)
	mockRows := sqlmock.NewRows([]string{"value"}).AddRow("42")
	mock.ExpectQuery(regexp.QuoteMeta("SELECT ?")).
		WithArgs("42").
		WillReturnRows(mockRows)

	result, err := client.QueryUntilNotEmptyWithArgs(context.Background(), []any{"42"}, "SELECT ?")
	require.NoError(t, err)
	require.Equal(t, "value", result.Header()[0])
	require.True(t, result.HasNext())

	row, err := result.Next()
	require.NoError(t, err)
	require.Equal(t, "42", row[0])
	result.Close()

	require.NoError(t, mock.ExpectationsWereMet())
}
