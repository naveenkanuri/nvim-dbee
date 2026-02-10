package adapters

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"io"
	"sync"
	"testing"

	"github.com/kndndrj/nvim-dbee/dbee/core/builders"
	"github.com/stretchr/testify/require"
)

const oracleQueryCtxDriverName = "oracle-query-ctx-test"

var (
	oracleQueryCtxRegisterOnce sync.Once
	oracleQueryCtxState        = &oracleQueryCtxCapture{}
)

type oracleQueryCtxCapture struct {
	mu   sync.Mutex
	ctx  context.Context
	args []driver.NamedValue
}

func (c *oracleQueryCtxCapture) set(ctx context.Context, args []driver.NamedValue) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.ctx = ctx
	if args == nil {
		c.args = nil
		return
	}
	c.args = make([]driver.NamedValue, len(args))
	copy(c.args, args)
}

func (c *oracleQueryCtxCapture) get() context.Context {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.ctx
}

func (c *oracleQueryCtxCapture) getArgs() []driver.NamedValue {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]driver.NamedValue, len(c.args))
	copy(out, c.args)
	return out
}

func (c *oracleQueryCtxCapture) reset() {
	c.set(nil, nil)
}

type oracleQueryCtxDriver struct{}

func (oracleQueryCtxDriver) Open(string) (driver.Conn, error) {
	return &oracleQueryCtxConn{}, nil
}

type oracleQueryCtxConn struct{}

func (oracleQueryCtxConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("prepare is not supported in this test driver")
}

func (oracleQueryCtxConn) Close() error { return nil }

func (oracleQueryCtxConn) Begin() (driver.Tx, error) {
	return nil, errors.New("transactions are not supported in this test driver")
}

func (oracleQueryCtxConn) QueryContext(ctx context.Context, _ string, args []driver.NamedValue) (driver.Rows, error) {
	oracleQueryCtxState.set(ctx, args)
	return &oracleQueryCtxRows{ctx: ctx}, nil
}

var _ driver.QueryerContext = (*oracleQueryCtxConn)(nil)

type oracleQueryCtxRows struct {
	ctx  context.Context
	sent bool
}

func (r *oracleQueryCtxRows) Columns() []string {
	return []string{"VALUE"}
}

func (r *oracleQueryCtxRows) Close() error {
	return nil
}

func (r *oracleQueryCtxRows) Next(dest []driver.Value) error {
	if err := r.ctx.Err(); err != nil {
		return err
	}
	if r.sent {
		return io.EOF
	}
	dest[0] = int64(1)
	r.sent = true
	return nil
}

func TestOracleQueryContextLivesUntilResultClose(t *testing.T) {
	oracleQueryCtxRegisterOnce.Do(func() {
		sql.Register(oracleQueryCtxDriverName, oracleQueryCtxDriver{})
	})
	oracleQueryCtxState.reset()

	db, err := sql.Open(oracleQueryCtxDriverName, "oracle-query-ctx-test")
	require.NoError(t, err)
	t.Cleanup(func() {
		_ = db.Close()
	})

	d := &oracleDriver{
		c:  builders.NewClient(db),
		db: db,
	}

	result, err := d.Query(context.Background(), "SELECT 1 FROM dual")
	require.NoError(t, err)
	require.NotNil(t, result)

	capturedCtx := oracleQueryCtxState.get()
	require.NotNil(t, capturedCtx)
	require.NoError(t, capturedCtx.Err(), "query context was canceled before stream consumption")

	require.True(t, result.HasNext())
	row, err := result.Next()
	require.NoError(t, err)
	require.Equal(t, int64(1), row[0])

	result.Close()
	require.ErrorIs(t, capturedCtx.Err(), context.Canceled)
}

func TestOracleQueryWithBindsPassesNamedArgs(t *testing.T) {
	oracleQueryCtxRegisterOnce.Do(func() {
		sql.Register(oracleQueryCtxDriverName, oracleQueryCtxDriver{})
	})
	oracleQueryCtxState.reset()

	db, err := sql.Open(oracleQueryCtxDriverName, "oracle-query-ctx-test")
	require.NoError(t, err)
	t.Cleanup(func() {
		_ = db.Close()
	})

	d := &oracleDriver{
		c:  builders.NewClient(db),
		db: db,
	}

	result, err := d.QueryWithBinds(context.Background(), "SELECT 1 FROM dual WHERE :id = :id AND :name = :name", map[string]string{
		"name": "ALICE",
		"id":   "42",
	})
	require.NoError(t, err)
	require.NotNil(t, result)
	result.Close()

	args := oracleQueryCtxState.getArgs()
	require.Len(t, args, 2)
	require.Equal(t, "id", args[0].Name)
	require.Equal(t, "42", args[0].Value)
	require.Equal(t, "name", args[1].Name)
	require.Equal(t, "ALICE", args[1].Value)
}
