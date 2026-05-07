package adapters

import (
	"context"
	"database/sql"
	"errors"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

type mockExecResponse struct {
	line   string
	status int64
	err    error
}

type mockExecConn struct {
	responses []mockExecResponse
	idx       int
	queries   []string
	argNames  [][]string
}

func (m *mockExecConn) ExecContext(_ context.Context, query string, args ...any) (sql.Result, error) {
	if m.idx >= len(m.responses) {
		return mockResult{}, errors.New("no mock response configured")
	}

	m.queries = append(m.queries, query)
	var names []string
	for _, arg := range args {
		if named, ok := arg.(sql.NamedArg); ok {
			names = append(names, named.Name)
		}
	}
	m.argNames = append(m.argNames, names)

	resp := m.responses[m.idx]
	m.idx++
	if resp.err != nil {
		return mockResult{}, resp.err
	}

	for _, arg := range args {
		named, ok := arg.(sql.NamedArg)
		if !ok {
			continue
		}

		out, ok := named.Value.(sql.Out)
		if !ok {
			continue
		}

		switch named.Name {
		case "p_line":
			dest, ok := out.Dest.(*string)
			if ok {
				*dest = resp.line
			}
		case "p_status":
			dest, ok := out.Dest.(*int64)
			if ok {
				*dest = resp.status
			}
		}
	}

	return mockResult{}, nil
}

type mockResult struct{}

func (mockResult) LastInsertId() (int64, error) { return 0, nil }
func (mockResult) RowsAffected() (int64, error) { return 0, nil }

func runDBMSOutputLockstep(t *testing.T) bool {
	t.Helper()

	driver := &oracleDriver{}
	conn := &mockExecConn{
		responses: []mockExecResponse{
			{line: "Hello", status: 0},
			{line: "World", status: 0},
			{line: "", status: 1},
		},
	}

	out, err := driver.fetchDBMSOutputFromConn(context.Background(), conn)
	if !assert.NoError(t, err) {
		return !t.Failed()
	}
	assert.Equal(t, "Hello\nWorld\n", out)

	if !assert.Len(t, conn.queries, 3) || !assert.Len(t, conn.argNames, 3) {
		return !t.Failed()
	}
	for i, query := range conn.queries {
		assert.Contains(t, query, ":p_line")
		assert.Contains(t, query, ":p_status")
		assert.NotContains(t, query, ":line")
		assert.NotContains(t, query, ":status")
		assert.Equal(t, []string{"p_line", "p_status"}, conn.argNames[i])
	}

	return !t.Failed()
}

func TestFetchDBMSOutputFromConn(t *testing.T) {
	runDBMSOutputLockstep(t)
}

func TestFetchDBMSOutputFromConn_StopsOnNoMoreLines(t *testing.T) {
	driver := &oracleDriver{}
	conn := &mockExecConn{
		responses: []mockExecResponse{
			{line: "", status: 1},
		},
	}

	out, err := driver.fetchDBMSOutputFromConn(context.Background(), conn)
	require.NoError(t, err)
	assert.Equal(t, "", out)
}

func TestFetchDBMSOutputFromConn_GetLineErrorReturnsError(t *testing.T) {
	driver := &oracleDriver{}
	conn := &mockExecConn{
		responses: []mockExecResponse{
			{line: "Hello", status: 0},
			{err: errors.New("boom")},
		},
	}

	out, err := driver.fetchDBMSOutputFromConn(context.Background(), conn)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "DBMS_OUTPUT.GET_LINE")
	assert.Equal(t, "Hello\n", out)
}
