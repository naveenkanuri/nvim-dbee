package adapters

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"io"
	"sync"
	"testing"
	"time"

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

func (oracleQueryCtxDriver) Ping(context.Context) error { return nil }

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

func TestOracleNamedArgsTypedLiterals(t *testing.T) {
	args := oracleNamedArgs(map[string]string{
		"aliasBool":   "boolean:false",
		"aliasFloat":  "number:2.5",
		"aliasInt":    "integer:7",
		"aliasString": "string:int:42",
		"aliasTs":     "ts:2026-02-10T11:22:33Z",
		"b":           "bool:true",
		"bad":         "int:not-a-number",
		"badBool":     "bool:yes",
		"d":           "date:2026-02-10",
		"f":           "float:3.5",
		"i":           "int:42",
		"inf":         "float:Inf",
		"n":           "null",
		"nan":         "float:NaN",
		"negInf":      "number:-Inf",
		"nUpper":      "NULL",
		"nullPayload": "null:something",
		"plain":       "keep-me",
		"s":           "str:001",
		"sSpace":      "str: hello ",
		"t":           "timestamp:2026-02-10T11:22:33Z",
		"tz":          "timestamp:2026-02-10 15:04:05+05:30",
	})

	require.Len(t, args, 22)

	valuesByName := map[string]any{}
	for _, argAny := range args {
		arg, ok := argAny.(sql.NamedArg)
		require.True(t, ok)
		valuesByName[arg.Name] = arg.Value
	}

	require.Equal(t, int64(42), valuesByName["i"])
	require.Equal(t, float64(3.5), valuesByName["f"])
	require.Equal(t, true, valuesByName["b"])
	require.Nil(t, valuesByName["n"])
	require.Nil(t, valuesByName["nUpper"])
	require.Equal(t, "001", valuesByName["s"])
	require.Equal(t, "hello", valuesByName["sSpace"])
	require.Equal(t, "keep-me", valuesByName["plain"])
	require.Equal(t, "int:not-a-number", valuesByName["bad"])
	require.Equal(t, "bool:yes", valuesByName["badBool"])
	require.Equal(t, "null:something", valuesByName["nullPayload"])
	require.Equal(t, "float:NaN", valuesByName["nan"])
	require.Equal(t, "float:Inf", valuesByName["inf"])
	require.Equal(t, "number:-Inf", valuesByName["negInf"])
	require.Equal(t, int64(7), valuesByName["aliasInt"])
	require.Equal(t, float64(2.5), valuesByName["aliasFloat"])
	require.Equal(t, false, valuesByName["aliasBool"])
	require.Equal(t, "int:42", valuesByName["aliasString"])

	dateVal, ok := valuesByName["d"].(time.Time)
	require.True(t, ok)
	require.Equal(t, "2026-02-10T00:00:00Z", dateVal.UTC().Format(time.RFC3339))

	tsVal, ok := valuesByName["t"].(time.Time)
	require.True(t, ok)
	require.Equal(t, "2026-02-10T11:22:33Z", tsVal.UTC().Format(time.RFC3339))

	aliasTsVal, ok := valuesByName["aliasTs"].(time.Time)
	require.True(t, ok)
	require.Equal(t, "2026-02-10T11:22:33Z", aliasTsVal.UTC().Format(time.RFC3339))

	tzVal, ok := valuesByName["tz"].(time.Time)
	require.True(t, ok)
	require.Equal(t, "2026-02-10T15:04:05+05:30", tzVal.Format(time.RFC3339))
}
