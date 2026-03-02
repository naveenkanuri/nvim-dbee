package adapters

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"io"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/kndndrj/nvim-dbee/dbee/core/builders"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// ---------------------------------------------------------------------------
// Test driver: tracks which connection serves each query via conn IDs.
// ---------------------------------------------------------------------------

const sessDriverName = "oracle-sess-test"

// sessDriverSeq is a monotonic counter for unique driver registration names.
// database/sql.Register is process-global and never unregisters, so pointer
// reuse (%p) could panic on long test runs.
var sessDriverSeq atomic.Int64

// sessTestState controls the fake driver's behavior per test.
type sessTestState struct {
	mu         sync.Mutex
	nextConnID int
	// connID recorded for each QueryContext / ExecContext call
	queryConnIDs []int
	// if non-nil, QueryContext returns this error on the conn whose ID matches failConnID
	failErr    error
	failConnID int
	// if > 0, Next blocks until signaled (to simulate slow row drain)
	blockNext chan struct{}
	// lastQueryCtx captures the context passed to the most recent QueryContext call
	lastQueryCtx context.Context
}

func newSessTestState() *sessTestState {
	return &sessTestState{nextConnID: 1, failConnID: -1}
}

func (s *sessTestState) recordQuery(connID int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.queryConnIDs = append(s.queryConnIDs, connID)
}

func (s *sessTestState) getQueryConnIDs() []int {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]int, len(s.queryConnIDs))
	copy(out, s.queryConnIDs)
	return out
}

// ---------------------------------------------------------------------------
// Fake driver.Driver → produces sessTestConn
// ---------------------------------------------------------------------------

type sessTestDriver struct {
	state *sessTestState
}

func (d *sessTestDriver) Open(string) (driver.Conn, error) {
	d.state.mu.Lock()
	id := d.state.nextConnID
	d.state.nextConnID++
	d.state.mu.Unlock()
	return &sessTestConn{id: id, state: d.state}, nil
}

// ---------------------------------------------------------------------------
// Fake driver.Conn
// ---------------------------------------------------------------------------

type sessTestConn struct {
	id    int
	state *sessTestState
}

func (c *sessTestConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("not supported")
}
func (c *sessTestConn) Close() error                       { return nil }
func (c *sessTestConn) Begin() (driver.Tx, error)          { return nil, errors.New("not supported") }
func (c *sessTestConn) ResetSession(context.Context) error { return nil }

func (c *sessTestConn) QueryContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	// Real drivers (go-ora, etc.) check context before executing.
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	c.state.recordQuery(c.id)
	c.state.mu.Lock()
	c.state.lastQueryCtx = ctx
	failErr := c.state.failErr
	failConnID := c.state.failConnID
	blockNext := c.state.blockNext
	c.state.mu.Unlock()

	if failErr != nil && c.id == failConnID {
		return nil, failErr
	}
	return &sessTestRows{ctx: ctx, blockNext: blockNext}, nil
}

func (c *sessTestConn) ExecContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	c.state.recordQuery(c.id)
	c.state.mu.Lock()
	failErr := c.state.failErr
	failConnID := c.state.failConnID
	c.state.mu.Unlock()

	if failErr != nil && c.id == failConnID {
		return nil, failErr
	}
	return sessTestResult{}, nil
}

var (
	_ driver.QueryerContext  = (*sessTestConn)(nil)
	_ driver.ExecerContext   = (*sessTestConn)(nil)
	_ driver.SessionResetter = (*sessTestConn)(nil)
)

// ---------------------------------------------------------------------------
// Fake driver.Rows — returns a single row with one column
// ---------------------------------------------------------------------------

type sessTestRows struct {
	ctx       context.Context
	sent      bool
	blockNext chan struct{}
}

func (r *sessTestRows) Columns() []string { return []string{"VALUE"} }
func (r *sessTestRows) Close() error      { return nil }
func (r *sessTestRows) Next(dest []driver.Value) error {
	if err := r.ctx.Err(); err != nil {
		return err
	}
	if r.blockNext != nil && !r.sent {
		select {
		case <-r.blockNext:
		case <-r.ctx.Done():
			return r.ctx.Err()
		}
	}
	if r.sent {
		return io.EOF
	}
	dest[0] = int64(1)
	r.sent = true
	return nil
}

// ---------------------------------------------------------------------------
// Fake driver.Result
// ---------------------------------------------------------------------------

type sessTestResult struct{}

func (sessTestResult) LastInsertId() (int64, error) { return 0, nil }
func (sessTestResult) RowsAffected() (int64, error) { return 1, nil }

// ---------------------------------------------------------------------------
// Helper: create an oracleDriver wired to a sessTestState
// ---------------------------------------------------------------------------

func newSessTestDriver(t *testing.T, state *sessTestState) *oracleDriver {
	t.Helper()
	// Each test registers under a unique name to avoid collisions.
	driverName := fmt.Sprintf("%s-%d", sessDriverName, sessDriverSeq.Add(1))
	sql.Register(driverName, &sessTestDriver{state: state})

	db, err := sql.Open(driverName, "test")
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })

	return &oracleDriver{
		c:  builders.NewClient(db),
		db: db,
	}
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

func TestSessionConnReused(t *testing.T) {
	state := newSessTestState()
	d := newSessTestDriver(t, state)

	// Query 1
	r1, err := d.Query(context.Background(), "SELECT 1 FROM dual")
	require.NoError(t, err)
	for r1.HasNext() {
		_, _ = r1.Next()
	}
	r1.Close()

	// Query 2
	r2, err := d.Query(context.Background(), "SELECT 2 FROM dual")
	require.NoError(t, err)
	for r2.HasNext() {
		_, _ = r2.Next()
	}
	r2.Close()

	ids := state.getQueryConnIDs()
	require.GreaterOrEqual(t, len(ids), 2)
	assert.Equal(t, ids[0], ids[1], "both queries should use the same conn ID")
}

func TestSessionConnReconnectsOnQueryError(t *testing.T) {
	state := newSessTestState()
	d := newSessTestDriver(t, state)

	// First query succeeds → creates sessConn with conn ID 1
	r1, err := d.Query(context.Background(), "SELECT 1 FROM dual")
	require.NoError(t, err)
	for r1.HasNext() {
		_, _ = r1.Next()
	}
	r1.Close()

	firstIDs := state.getQueryConnIDs()
	require.Len(t, firstIDs, 1)
	firstID := firstIDs[0]

	// Make conn 1 return ErrBadConn on next query
	state.mu.Lock()
	state.failErr = driver.ErrBadConn
	state.failConnID = firstID
	state.mu.Unlock()

	// This query should fail
	_, err = d.Query(context.Background(), "SELECT 2 FROM dual")
	require.Error(t, err)

	// Reset the failure
	state.mu.Lock()
	state.failErr = nil
	state.failConnID = -1
	state.mu.Unlock()

	// Next query should get a new conn (sessConn was reset in error path)
	r3, err := d.Query(context.Background(), "SELECT 3 FROM dual")
	require.NoError(t, err)
	for r3.HasNext() {
		_, _ = r3.Next()
	}
	r3.Close()

	allIDs := state.getQueryConnIDs()
	lastID := allIDs[len(allIDs)-1]
	assert.NotEqual(t, firstID, lastID, "should use a new conn after ErrBadConn reset")
}

func TestPLSQLSharesSessionConn(t *testing.T) {
	state := newSessTestState()
	d := newSessTestDriver(t, state)

	// PL/SQL block — executePLSQLLocked will ExecContext for DBMS_OUTPUT.ENABLE,
	// then ExecContext for the block, then ExecContext for GET_LINE.
	// All should use the same conn.
	// Note: The test driver's ExecContext doesn't actually handle DBMS_OUTPUT,
	// so we'll get an error on the GET_LINE call (status won't be set).
	// Instead, test by running a SELECT first to establish the conn, then a PL/SQL block.
	r1, err := d.Query(context.Background(), "SELECT 1 FROM dual")
	require.NoError(t, err)
	for r1.HasNext() {
		_, _ = r1.Next()
	}
	r1.Close()

	firstIDs := state.getQueryConnIDs()
	require.Len(t, firstIDs, 1)
	selectConnID := firstIDs[0]

	// PL/SQL block — the DBMS_OUTPUT.ENABLE ExecContext and the block ExecContext
	// should use the same conn ID
	_, _ = d.Query(context.Background(), "BEGIN NULL; END;")

	allIDs := state.getQueryConnIDs()
	// All recorded conn IDs should be the same
	for _, id := range allIDs {
		assert.Equal(t, selectConnID, id, "PL/SQL should reuse the same session conn")
	}
}

func TestStreamOpenBlocksSecondQuery(t *testing.T) {
	state := newSessTestState()
	state.blockNext = make(chan struct{})
	d := newSessTestDriver(t, state)

	// Start query 1 — rows.Next will block until we signal
	ctx1 := context.Background()
	var r1Started atomic.Bool
	var r1Done atomic.Bool

	go func() {
		r1Started.Store(true)
		r1, err := d.Query(ctx1, "SELECT 1 FROM dual")
		if err != nil {
			return
		}
		for r1.HasNext() {
			_, _ = r1.Next()
		}
		r1.Close()
		r1Done.Store(true)
	}()

	// Wait for query 1 to start
	time.Sleep(50 * time.Millisecond)

	// Start query 2 in a goroutine — should block on d.mu.Lock()
	var q2Started atomic.Bool
	var q2Done atomic.Bool
	go func() {
		q2Started.Store(true)
		r2, err := d.Query(context.Background(), "SELECT 2 FROM dual")
		if err == nil {
			for r2.HasNext() {
				_, _ = r2.Next()
			}
			r2.Close()
		}
		q2Done.Store(true)
	}()

	// Give query 2 time to attempt lock
	time.Sleep(50 * time.Millisecond)
	assert.False(t, q2Done.Load(), "second query should be blocked while first stream is open")

	// Unblock query 1's row drain
	close(state.blockNext)

	// Both should complete
	require.Eventually(t, func() bool { return r1Done.Load() }, 2*time.Second, 10*time.Millisecond)
	require.Eventually(t, func() bool { return q2Done.Load() }, 2*time.Second, 10*time.Millisecond)
}

func TestCancelThenNextQuerySucceeds(t *testing.T) {
	state := newSessTestState()
	state.blockNext = make(chan struct{})
	d := newSessTestDriver(t, state)

	// Run a query with a cancelable context
	ctx, cancel := context.WithCancel(context.Background())

	var queryDone atomic.Bool
	go func() {
		r1, err := d.Query(ctx, "SELECT 1 FROM dual")
		if err == nil {
			for r1.HasNext() {
				_, _ = r1.Next()
			}
			r1.Close()
		}
		queryDone.Store(true)
	}()

	// Let it start blocking on Next
	time.Sleep(50 * time.Millisecond)

	// Cancel the context — should unblock the query
	cancel()
	require.Eventually(t, func() bool { return queryDone.Load() }, 2*time.Second, 10*time.Millisecond)

	// Reset blockNext for next query
	state.mu.Lock()
	state.blockNext = nil
	state.mu.Unlock()

	// Next query should succeed on the same conn (cancel is not a conn error)
	r2, err := d.Query(context.Background(), "SELECT 2 FROM dual")
	require.NoError(t, err)
	for r2.HasNext() {
		_, _ = r2.Next()
	}
	r2.Close()

	ids := state.getQueryConnIDs()
	// All should be same conn ID (no reset happened)
	firstID := ids[0]
	lastID := ids[len(ids)-1]
	assert.Equal(t, firstID, lastID, "cancel should not reset sessConn")
}

func TestCloseReleasesSessionConn(t *testing.T) {
	state := newSessTestState()
	d := newSessTestDriver(t, state)

	// Establish sessConn
	r1, err := d.Query(context.Background(), "SELECT 1 FROM dual")
	require.NoError(t, err)
	for r1.HasNext() {
		_, _ = r1.Next()
	}
	r1.Close()

	require.NotNil(t, d.sessConn, "sessConn should be set after query")

	d.Close()
	assert.Nil(t, d.sessConn, "sessConn should be nil after Close")
}

func TestSessionConnErrorResetsOnORACode(t *testing.T) {
	tests := []struct {
		name string
		err  error
	}{
		{"ErrBadConn", driver.ErrBadConn},
		{"ErrConnDone", sql.ErrConnDone},
		{"ORA-03113", errors.New("ORA-03113: end-of-file on communication channel")},
		{"ORA-03114", errors.New("ORA-03114: not connected to ORACLE")},
		{"ORA-03135", errors.New("ORA-03135: connection lost contact")},
		{"ORA-01012", errors.New("ORA-01012: not logged on")},
		{"ORA-02396", errors.New("ORA-02396: exceeded maximum idle time")},
		{"ORA-00028", errors.New("ORA-00028: your session has been killed")},
		{"broken pipe", errors.New("write: broken pipe")},
		{"connection reset", errors.New("read: connection reset by peer")},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			assert.True(t, isSessionConnError(tt.err), "expected isSessionConnError=true for %v", tt.err)
		})
	}

	// Negative cases
	negatives := []struct {
		name string
		err  error
	}{
		{"timeout", errors.New("i/o timeout")},
		{"ORA-00942 table not found", errors.New("ORA-00942: table or view does not exist")},
		{"generic error", errors.New("something went wrong")},
	}
	for _, tt := range negatives {
		t.Run("not_"+tt.name, func(t *testing.T) {
			assert.False(t, isSessionConnError(tt.err), "expected isSessionConnError=false for %v", tt.err)
		})
	}
}

func TestExecStatementClassification(t *testing.T) {
	tests := []struct {
		query string
		want  bool
	}{
		{"ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD'", true},
		{"alter session set statistics_level = all", true},
		{"CREATE TABLE foo (id NUMBER)", true},
		{"DROP TABLE foo", true},
		{"GRANT SELECT ON foo TO bar", true},
		{"REVOKE SELECT ON foo FROM bar", true},
		{"TRUNCATE TABLE foo", true},
		{"MERGE INTO foo USING bar ON (foo.id = bar.id) WHEN MATCHED THEN UPDATE SET foo.name = bar.name", true},
		{"INSERT INTO foo VALUES (1)", true},
		{"UPDATE foo SET name = 'bar'", true},
		{"DELETE FROM foo WHERE id = 1", true},
		{"SELECT * FROM foo", false},
		{"WITH cte AS (SELECT 1) SELECT * FROM cte", false},
		{"-- comment\nALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD'", true},
		{"/* block comment */ CREATE TABLE foo (id NUMBER)", true},
		{"-- comment\nSELECT 1 FROM dual", false},
		{"", false},
		{"-- only a comment", false},
	}

	for _, tt := range tests {
		t.Run(tt.query, func(t *testing.T) {
			got := isExecStatement(tt.query)
			assert.Equal(t, tt.want, got, "isExecStatement(%q)", tt.query)
		})
	}
}

func TestExecPathImmediateUnlock(t *testing.T) {
	state := newSessTestState()
	d := newSessTestDriver(t, state)

	// ALTER SESSION goes through exec path — should unlock immediately
	r1, err := d.Query(context.Background(), "ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD'")
	require.NoError(t, err)
	// Drain the "Rows Affected" result
	for r1.HasNext() {
		_, _ = r1.Next()
	}
	r1.Close()

	// Verify header is "Rows Affected"
	assert.Equal(t, "Rows Affected", r1.Header()[0])

	// Second query should NOT block (mutex was released immediately)
	done := make(chan struct{})
	go func() {
		r2, err := d.Query(context.Background(), "SELECT 1 FROM dual")
		if err == nil {
			for r2.HasNext() {
				_, _ = r2.Next()
			}
			r2.Close()
		}
		close(done)
	}()

	select {
	case <-done:
		// success — second query completed
	case <-time.After(2 * time.Second):
		t.Fatal("second query blocked — exec path should have released mutex immediately")
	}

	// Both should use same conn
	ids := state.getQueryConnIDs()
	assert.Equal(t, ids[0], ids[len(ids)-1])
}

func TestStructureUsesPool(t *testing.T) {
	// Verify Structure() goes through the pool, not the session conn.
	// We do this by locking d.mu manually (simulating a streaming query
	// holding the gate) and checking that Structure() completes anyway.
	state := newSessTestState()
	d := newSessTestDriver(t, state)

	// Simulate a streaming query holding the mutex
	d.mu.Lock()

	done := make(chan error, 1)
	go func() {
		_, err := d.Structure()
		done <- err
	}()

	select {
	case <-done:
		// Structure completed without blocking — success
	case <-time.After(2 * time.Second):
		t.Fatal("Structure() blocked — should use pool, not session conn")
	}

	d.mu.Unlock()
}

func TestColumnsUsesPool(t *testing.T) {
	// Verify Columns() goes through the pool, not the session conn.
	// Mirror TestStructureUsesPool: hold d.mu and confirm Columns completes.
	state := newSessTestState()
	d := newSessTestDriver(t, state)

	d.mu.Lock()

	done := make(chan struct{})
	go func() {
		_, _ = d.Columns(&core.TableOptions{
			Schema: "TEST",
			Table:  "FOO",
		})
		close(done)
	}()

	select {
	case <-done:
		// Columns completed without blocking — success
	case <-time.After(2 * time.Second):
		t.Fatal("Columns() blocked — should use pool, not session conn")
	}

	d.mu.Unlock()
}

func TestEmptyQueryReturnsError(t *testing.T) {
	state := newSessTestState()
	d := newSessTestDriver(t, state)

	_, err := d.Query(context.Background(), ";")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "empty query")
}

func TestContextExpiredDuringMutexWait(t *testing.T) {
	state := newSessTestState()
	state.blockNext = make(chan struct{})
	d := newSessTestDriver(t, state)

	// Start a query that holds the mutex via slow row drain
	go func() {
		r1, err := d.Query(context.Background(), "SELECT 1 FROM dual")
		if err == nil {
			for r1.HasNext() {
				_, _ = r1.Next()
			}
			r1.Close()
		}
	}()

	time.Sleep(50 * time.Millisecond)

	// Start a second query with a short timeout — the parent context will
	// expire while the goroutine is blocked on d.mu.Lock(). Once the first
	// query finishes, QueryContext sees the dead context and returns immediately.
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()

	var queryErr error
	var queryDone atomic.Bool
	go func() {
		_, queryErr = d.Query(ctx, "SELECT 2 FROM dual")
		queryDone.Store(true)
	}()

	// Unblock first query AFTER the short timeout expires, so the second
	// query's parent context is dead by the time it acquires the lock.
	time.Sleep(150 * time.Millisecond)
	close(state.blockNext)

	require.Eventually(t, func() bool { return queryDone.Load() }, 2*time.Second, 10*time.Millisecond)
	require.Error(t, queryErr, "second query should fail after context expiry")
	assert.ErrorIs(t, queryErr, context.DeadlineExceeded)
}

func TestDefaultDeadlineInjectedWhenParentHasNone(t *testing.T) {
	state := newSessTestState()
	d := newSessTestDriver(t, state)

	// Parent context with no deadline — adapter should inject 24h default
	r, err := d.Query(context.Background(), "SELECT 1 FROM dual")
	require.NoError(t, err)
	for r.HasNext() {
		_, _ = r.Next()
	}
	r.Close()

	state.mu.Lock()
	capturedCtx := state.lastQueryCtx
	state.mu.Unlock()

	require.NotNil(t, capturedCtx, "lastQueryCtx should have been captured")
	deadline, hasDeadline := capturedCtx.Deadline()
	assert.True(t, hasDeadline, "adapter should inject a 24h deadline when parent has none")
	remaining := time.Until(deadline)
	assert.Greater(t, remaining, 23*time.Hour+59*time.Minute, "deadline should be ~24h away")
	assert.Less(t, remaining, 24*time.Hour+time.Minute, "deadline should not exceed 24h")
}

func TestParentDeadlinePreserved(t *testing.T) {
	state := newSessTestState()
	d := newSessTestDriver(t, state)

	// Parent context with a 5-minute deadline — adapter should preserve it
	parentDeadline := 5 * time.Minute
	ctx, parentCancel := context.WithTimeout(context.Background(), parentDeadline)
	defer parentCancel()

	r, err := d.Query(ctx, "SELECT 1 FROM dual")
	require.NoError(t, err)
	for r.HasNext() {
		_, _ = r.Next()
	}
	r.Close()

	state.mu.Lock()
	capturedCtx := state.lastQueryCtx
	state.mu.Unlock()

	require.NotNil(t, capturedCtx, "lastQueryCtx should have been captured")
	deadline, hasDeadline := capturedCtx.Deadline()
	assert.True(t, hasDeadline, "parent deadline should be preserved")
	remaining := time.Until(deadline)
	assert.Greater(t, remaining, 4*time.Minute, "should preserve parent's ~5m deadline")
	assert.Less(t, remaining, 5*time.Minute+time.Second, "should use parent deadline, not 24h default")
}
