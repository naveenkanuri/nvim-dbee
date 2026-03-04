package core_test

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/kndndrj/nvim-dbee/dbee/core/mock"
)

type retrievalFailDriver struct{}

func (*retrievalFailDriver) Query(_ context.Context, _ string) (core.ResultStream, error) {
	return &failingResultStream{
		header:    core.Header{"id", "name"},
		meta:      &core.Meta{},
		rows:      mock.NewRows(0, 3),
		failAfter: 1,
	}, nil
}

func (*retrievalFailDriver) Structure() ([]*core.Structure, error) {
	return nil, nil
}

func (*retrievalFailDriver) Columns(_ *core.TableOptions) ([]*core.Column, error) {
	return []*core.Column{{Name: "id", Type: "NUMBER"}}, nil
}

func (*retrievalFailDriver) Close() {}

func TestCall_Success(t *testing.T) {
	r := require.New(t)

	rows := mock.NewRows(0, 10)

	connection, err := core.NewConnection(&core.ConnectionParams{}, mock.NewAdapter(rows,
		mock.AdapterWithResultStreamOpts(mock.ResultStreamWithNextSleep(300*time.Millisecond)),
	))
	r.NoError(err)

	expectedEvents := []core.CallState{
		core.CallStateExecuting,
		core.CallStateRetrieving,
		core.CallStateArchived,
	}

	var eventIndex atomic.Int32
	call := connection.Execute("_", func(state core.CallState, c *core.Call) {
		// make sure events were in order
		idx := int(eventIndex.Load())
		r.Less(idx, len(expectedEvents))
		r.Equal(expectedEvents[idx], state)
		eventIndex.Add(1)

		if state == core.CallStateRetrieving {
			result, err := c.GetResult()
			r.NoError(err)

			actualRows, err := result.Rows(0, len(rows))
			r.NoError(err)

			r.Equal(rows, actualRows)
		}
	})

	// wait for call to finish
	select {
	case <-call.Done():
	case <-time.After(5 * time.Second):
		t.Error("call did not finish in expected time")
	}

	r.Eventually(func() bool {
		return eventIndex.Load() == int32(len(expectedEvents))
	}, 2*time.Second, 10*time.Millisecond)
}

func TestCall_Cancel(t *testing.T) {
	r := require.New(t)

	rows := mock.NewRows(0, 10)

	adapter := mock.NewAdapter(rows,
		mock.AdapterWithQuerySideEffect("wait", func(ctx context.Context) error {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(10 * time.Second):
			}
			return nil
		}),
		mock.AdapterWithResultStreamOpts(mock.ResultStreamWithNextSleep(300*time.Millisecond)),
	)

	connection, err := core.NewConnection(&core.ConnectionParams{}, adapter)
	r.NoError(err)

	expectedEvents := []core.CallState{
		core.CallStateExecuting,
		core.CallStateCanceled,
	}

	var eventIndex atomic.Int32
	call := connection.Execute("wait", func(state core.CallState, c *core.Call) {
		// wait for first event and cancel request
		c.Cancel()
		// make sure events were in order
		idx := int(eventIndex.Load())
		r.Less(idx, len(expectedEvents))
		r.Equal(expectedEvents[idx], state)
		eventIndex.Add(1)
	})

	// wait for call to finish
	select {
	case <-call.Done():
	case <-time.After(5 * time.Second):
		t.Error("call did not finish in expected time")
	}

	r.Eventually(func() bool {
		return eventIndex.Load() == int32(len(expectedEvents))
	}, 2*time.Second, 10*time.Millisecond)
}

func TestCall_Cancel_Idempotent(t *testing.T) {
	r := require.New(t)

	rows := mock.NewRows(0, 10)
	adapter := mock.NewAdapter(rows,
		mock.AdapterWithQuerySideEffect("wait", func(ctx context.Context) error {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(10 * time.Second):
			}
			return nil
		}),
		mock.AdapterWithResultStreamOpts(mock.ResultStreamWithNextSleep(300*time.Millisecond)),
	)

	connection, err := core.NewConnection(&core.ConnectionParams{}, adapter)
	r.NoError(err)

	var cancelEvents atomic.Int32
	call := connection.Execute("wait", func(state core.CallState, c *core.Call) {
		if state == core.CallStateExecuting {
			var wg sync.WaitGroup
			for i := 0; i < 16; i++ {
				wg.Add(1)
				go func() {
					defer wg.Done()
					c.Cancel()
				}()
			}
			wg.Wait()
		}
		if state == core.CallStateCanceled {
			cancelEvents.Add(1)
		}
	})

	select {
	case <-call.Done():
	case <-time.After(5 * time.Second):
		t.Error("call did not finish in expected time")
	}

	r.Eventually(func() bool {
		return cancelEvents.Load() == 1
	}, 2*time.Second, 10*time.Millisecond)
	r.Equal(core.CallStateCanceled, call.GetState())
}

func TestCall_Cancel_DuringRetrieving(t *testing.T) {
	r := require.New(t)

	rows := mock.NewRows(0, 32)
	connection, err := core.NewConnection(&core.ConnectionParams{}, mock.NewAdapter(rows,
		mock.AdapterWithResultStreamOpts(mock.ResultStreamWithNextSleep(10*time.Millisecond)),
	))
	r.NoError(err)

	expectedEvents := []core.CallState{
		core.CallStateExecuting,
		core.CallStateRetrieving,
		core.CallStateCanceled,
	}

	var (
		eventIndex      atomic.Int32
		retrievingCount atomic.Int32
		canceledCount   atomic.Int32
	)
	call := connection.Execute("_", func(state core.CallState, c *core.Call) {
		if state == core.CallStateRetrieving {
			retrievingCount.Add(1)
			c.Cancel()
		}
		if state == core.CallStateCanceled {
			canceledCount.Add(1)
		}

		idx := int(eventIndex.Load())
		r.Less(idx, len(expectedEvents))
		r.Equal(expectedEvents[idx], state)
		eventIndex.Add(1)
	})

	select {
	case <-call.Done():
	case <-time.After(5 * time.Second):
		t.Error("call did not finish in expected time")
	}

	r.Eventually(func() bool {
		return eventIndex.Load() == int32(len(expectedEvents))
	}, 2*time.Second, 10*time.Millisecond)
	r.Equal(int32(1), retrievingCount.Load())
	r.Equal(int32(1), canceledCount.Load())
	r.Equal(core.CallStateCanceled, call.GetState())
}

func TestCall_Cancel_AfterDone_NoPanic(t *testing.T) {
	r := require.New(t)

	rows := mock.NewRows(0, 2)
	connection, err := core.NewConnection(&core.ConnectionParams{}, mock.NewAdapter(rows))
	r.NoError(err)

	call := connection.Execute("_", nil)
	select {
	case <-call.Done():
	case <-time.After(5 * time.Second):
		t.Error("call did not finish in expected time")
	}

	r.NotPanics(func() {
		call.Cancel()
		call.Cancel()
	})
}

func TestCall_RetrievingFlood_DoesNotDeadlock(t *testing.T) {
	r := require.New(t)

	rows := mock.NewRows(0, 64)
	connection, err := core.NewConnection(&core.ConnectionParams{}, mock.NewAdapter(rows))
	r.NoError(err)

	var fetched atomic.Bool
	call := connection.Execute("_", func(state core.CallState, c *core.Call) {
		if state == core.CallStateRetrieving && !fetched.Swap(true) {
			result, getErr := c.GetResult()
			r.NoError(getErr)

			_, rowsErr := result.Rows(0, len(rows))
			r.NoError(rowsErr)
		}
	})

	select {
	case <-call.Done():
	case <-time.After(5 * time.Second):
		t.Error("call did not finish in expected time")
	}

	r.Eventually(func() bool {
		return call.GetState() == core.CallStateArchived
	}, 2*time.Second, 10*time.Millisecond)
}

func TestCall_Cancel_PreservesCancelTimeTaken(t *testing.T) {
	r := require.New(t)

	rows := mock.NewRows(0, 2)
	adapter := mock.NewAdapter(rows,
		mock.AdapterWithQuerySideEffect("wait_cancel", func(ctx context.Context) error {
			<-ctx.Done()
			time.Sleep(900 * time.Millisecond)
			return ctx.Err()
		}),
	)

	connection, err := core.NewConnection(&core.ConnectionParams{}, adapter)
	r.NoError(err)

	call := connection.Execute("wait_cancel", func(state core.CallState, c *core.Call) {
		if state == core.CallStateExecuting {
			c.Cancel()
		}
	})

	select {
	case <-call.Done():
	case <-time.After(5 * time.Second):
		t.Error("call did not finish in expected time")
	}

	r.Equal(core.CallStateCanceled, call.GetState())
	r.Less(call.GetTimeTaken(), 500*time.Millisecond)
}

func TestCall_FailedQuery(t *testing.T) {
	r := require.New(t)

	rows := mock.NewRows(0, 10)

	adapter := mock.NewAdapter(rows,
		mock.AdapterWithQuerySideEffect("fail", func(ctx context.Context) error {
			return errors.New("query failed")
		}),
		mock.AdapterWithResultStreamOpts(mock.ResultStreamWithNextSleep(300*time.Millisecond)),
	)

	connection, err := core.NewConnection(&core.ConnectionParams{}, adapter)
	r.NoError(err)

	expectedEvents := []core.CallState{
		core.CallStateExecuting,
		core.CallStateExecutingFailed,
	}

	var eventIndex atomic.Int32
	call := connection.Execute("fail", func(state core.CallState, c *core.Call) {
		// make sure events were in order
		idx := int(eventIndex.Load())
		r.Less(idx, len(expectedEvents))
		r.Equal(expectedEvents[idx], state)
		eventIndex.Add(1)

		if state == core.CallStateExecutingFailed {
			r.NotNil(c.Err())
		}
	})

	// wait for call to finish
	select {
	case <-call.Done():
	case <-time.After(5 * time.Second):
		t.Error("call did not finish in expected time")
	}

	r.Eventually(func() bool {
		return eventIndex.Load() == int32(len(expectedEvents))
	}, 2*time.Second, 10*time.Millisecond)
	r.Equal("unknown", call.ErrorKind())
}

func TestCall_FailedQuery_DisconnectedKind(t *testing.T) {
	r := require.New(t)

	rows := mock.NewRows(0, 10)
	adapter := mock.NewAdapter(rows,
		mock.AdapterWithQuerySideEffect("fail", func(ctx context.Context) error {
			return errors.New("dial tcp: lookup db.internal: no such host")
		}),
	)

	connection, err := core.NewConnection(&core.ConnectionParams{}, adapter)
	r.NoError(err)

	call := connection.Execute("fail", nil)

	select {
	case <-call.Done():
	case <-time.After(5 * time.Second):
		t.Error("call did not finish in expected time")
	}

	r.Error(call.Err())
	r.Equal("disconnected", call.ErrorKind())
}

func TestCall_GetResult_OnExecutingFailure_ReturnsCallError(t *testing.T) {
	r := require.New(t)

	rows := mock.NewRows(0, 10)
	adapter := mock.NewAdapter(rows,
		mock.AdapterWithQuerySideEffect("fail", func(ctx context.Context) error {
			return errors.New("query failed")
		}),
	)

	connection, err := core.NewConnection(&core.ConnectionParams{}, adapter)
	r.NoError(err)

	call := connection.Execute("fail", nil)
	select {
	case <-call.Done():
	case <-time.After(5 * time.Second):
		t.Error("call did not finish in expected time")
	}
	r.Eventually(func() bool {
		return call.GetState() == core.CallStateExecutingFailed
	}, 2*time.Second, 10*time.Millisecond)

	_, getErr := call.GetResult()
	r.Error(getErr)
	r.ErrorContains(getErr, "call has no result in state executing_failed")
	if call.Err() != nil {
		r.ErrorContains(getErr, call.Err().Error())
	}
}

func TestCall_GetResult_OnCanceledCall_ReturnsStateError(t *testing.T) {
	r := require.New(t)

	rows := mock.NewRows(0, 10)
	adapter := mock.NewAdapter(rows,
		mock.AdapterWithQuerySideEffect("wait_cancel", func(ctx context.Context) error {
			<-ctx.Done()
			return ctx.Err()
		}),
	)

	connection, err := core.NewConnection(&core.ConnectionParams{}, adapter)
	r.NoError(err)

	call := connection.Execute("wait_cancel", func(state core.CallState, c *core.Call) {
		if state == core.CallStateExecuting {
			c.Cancel()
		}
	})

	select {
	case <-call.Done():
	case <-time.After(5 * time.Second):
		t.Error("call did not finish in expected time")
	}
	r.Eventually(func() bool {
		return call.GetState() == core.CallStateCanceled
	}, 2*time.Second, 10*time.Millisecond)

	_, getErr := call.GetResult()
	r.Error(getErr)
	r.ErrorContains(getErr, "call has no result in state canceled")
	if call.Err() != nil {
		r.ErrorContains(getErr, call.Err().Error())
	}
}

func TestCall_GetResult_OnRetrievingFailure_DoesNotFallbackToArchive(t *testing.T) {
	r := require.New(t)

	conn, err := core.NewConnection(&core.ConnectionParams{
		ID:   "retr-fail",
		Type: "oracle",
		URL:  "mock://retr-fail",
	}, &singleDriverAdapter{driver: &retrievalFailDriver{}})
	r.NoError(err)
	defer conn.Close()

	call := conn.Execute("SELECT 1 FROM dual", nil)
	<-call.Done()

	r.Error(call.Err())
	r.Eventually(func() bool {
		return call.GetState() == core.CallStateRetrievingFailed
	}, 2*time.Second, 10*time.Millisecond)

	result, getErr := call.GetResult()
	r.NoError(getErr)
	r.NotNil(result)

	rows, rowsErr := result.Rows(0, -1)
	r.Nil(rows)
	r.ErrorContains(rowsErr, "result fill failed")
	r.ErrorContains(rowsErr, "stream read failed")
}

func TestCall_Archive(t *testing.T) {
	r := require.New(t)

	rows := mock.NewRows(0, 10)

	connection, err := core.NewConnection(&core.ConnectionParams{}, mock.NewAdapter(rows,
		mock.AdapterWithResultStreamOpts(mock.ResultStreamWithNextSleep(300*time.Millisecond)),
	))
	r.NoError(err)

	call := connection.Execute("_", nil)

	// wait for call to finish
	select {
	case <-call.Done():
		// wait a bit for event index to stabilize
		time.Sleep(100 * time.Millisecond)
	case <-time.After(5 * time.Second):
		t.Error("call did not finish in expected time")
	}

	// check result
	result, err := call.GetResult()
	r.NoError(err)
	actualRows, err := result.Rows(0, len(rows))
	r.NoError(err)
	r.Equal(rows, actualRows)

	// marshal to json
	b, err := json.Marshal(call)
	r.NoError(err)

	// marshal back
	restoredCall := new(core.Call)
	err = json.Unmarshal(b, restoredCall)
	r.NoError(err)

	// check result again
	result, err = restoredCall.GetResult()
	r.NoError(err)
	actualRows, err = result.Rows(0, len(rows))
	r.NoError(err)
	r.Equal(rows, actualRows)
}
