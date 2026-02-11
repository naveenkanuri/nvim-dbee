package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
)

type (
	CallID string

	Call struct {
		id        CallID
		query     string
		state     CallState
		timeTaken time.Duration
		timestamp time.Time

		result     *Result
		archive    *archive
		cancelFunc func()

		// any error that might occur during execution
		err       error
		errorKind string
		done      chan struct{}

		mu         sync.RWMutex
		cancelOnce sync.Once
		doneOnce   sync.Once
		doneClosed atomic.Bool
	}
)

// callPersistent is used for marshaling and unmarshaling the call
type callPersistent struct {
	ID        string `json:"id"`
	Query     string `json:"query"`
	State     string `json:"state"`
	TimeTaken int64  `json:"time_taken_us"`
	Timestamp int64  `json:"timestamp_us"`
	Error     string `json:"error,omitempty"`
	ErrorKind string `json:"error_kind,omitempty"`
}

func (c *Call) toPersistent() *callPersistent {
	c.mu.RLock()
	id := c.id
	query := c.query
	state := c.state
	timeTaken := c.timeTaken
	timestamp := c.timestamp
	callErr := c.err
	errorKind := c.errorKind
	c.mu.RUnlock()

	errMsg := ""
	if callErr != nil {
		errMsg = callErr.Error()
	}

	return &callPersistent{
		ID:        string(id),
		Query:     query,
		State:     state.String(),
		TimeTaken: timeTaken.Microseconds(),
		Timestamp: timestamp.UnixMicro(),
		Error:     errMsg,
		ErrorKind: errorKind,
	}
}

func (s *Call) MarshalJSON() ([]byte, error) {
	return json.Marshal(s.toPersistent())
}

func (c *Call) UnmarshalJSON(data []byte) error {
	var alias callPersistent

	if err := json.Unmarshal(data, &alias); err != nil {
		return err
	}

	done := make(chan struct{})
	close(done)

	archive := newArchive(CallID(alias.ID))
	state := CallStateFromString(alias.State)
	if state == CallStateArchived && archive.isEmpty() {
		state = CallStateUnknown
	}

	var callErr error
	if alias.Error != "" {
		callErr = errors.New(alias.Error)
	}
	errorKind := alias.ErrorKind
	if errorKind == "" && callErr != nil {
		errorKind = classifyCallError(callErr)
	}

	*c = Call{
		id:        CallID(alias.ID),
		query:     alias.Query,
		state:     state,
		timeTaken: time.Duration(alias.TimeTaken) * time.Microsecond,
		timestamp: time.UnixMicro(alias.Timestamp),
		err:       callErr,
		errorKind: errorKind,

		result:  new(Result),
		archive: newArchive(CallID(alias.ID)),

		done: done,
	}

	return nil
}

func newCallFromExecutor(executor func(context.Context) (ResultStream, error), query string, onEvent func(CallState, *Call)) *Call {
	id := CallID(uuid.New().String())
	c := &Call{
		id:    id,
		query: query,
		state: CallStateUnknown,

		result:  new(Result),
		archive: newArchive(id),

		done: make(chan struct{}),
	}

	eventsCh := make(chan CallState, 10)
	emitEvent := func(state CallState) bool {
		if c.doneClosed.Load() {
			return false
		}
		if state == CallStateRetrieving {
			// Retrieving can fire often; if the event queue is saturated
			// we drop duplicate retrieving ticks instead of blocking callers.
			select {
			case eventsCh <- state:
				return true
			default:
				return false
			}
		}
		select {
		case eventsCh <- state:
			return true
		case <-c.done:
			return false
		}
	}

	ctx, cancel := context.WithCancel(context.Background())
	c.timestamp = time.Now()
	c.cancelFunc = func() {
		c.cancelOnce.Do(func() {
			cancel()
			c.setTimeTaken(time.Since(c.timestamp))
			emitEvent(CallStateCanceled)
		})
	}

	// event function handler
	go func() {
		processState := func(state CallState) {
			currentState := c.GetState()
			if currentState == CallStateExecutingFailed ||
				currentState == CallStateRetrievingFailed ||
				currentState == CallStateArchived ||
				currentState == CallStateCanceled ||
				currentState == CallStateArchiveFailed {
				return
			}
			c.setState(state)

			// trigger event callback
			if onEvent != nil {
				onEvent(state, c)
			}
		}

		for {
			select {
			case state := <-eventsCh:
				processState(state)
			case <-c.done:
				for {
					select {
					case state := <-eventsCh:
						processState(state)
					default:
						return
					}
				}
			}
		}
	}()

	go func() {
		defer c.markDone()

		// execute the function
		emitEvent(CallStateExecuting)
		iter, err := executor(ctx)
		// Preserve cancel timing captured in Cancel(); only write here for non-canceled paths.
		if ctx.Err() == nil {
			c.setTimeTaken(time.Since(c.timestamp))
		}
		if err != nil {
			c.setError(err)
			c.setErrorKind(classifyCallError(err))
			emitEvent(CallStateExecutingFailed)
			return
		}

		// set iterator to result
		err = c.result.SetIter(iter, func() {
			emitEvent(CallStateRetrieving)
		})
		if err != nil {
			c.setError(err)
			c.setErrorKind(classifyCallError(err))
			emitEvent(CallStateRetrievingFailed)
			return
		}

		// archive the result
		err = c.archive.setResult(c.result)
		if err != nil {
			c.setError(err)
			c.setErrorKind(classifyCallError(err))
			emitEvent(CallStateArchiveFailed)
			return
		}

		emitEvent(CallStateArchived)
	}()

	return c
}

func (c *Call) setState(state CallState) {
	c.mu.Lock()
	c.state = state
	c.mu.Unlock()
}

func (c *Call) setTimeTaken(t time.Duration) {
	c.mu.Lock()
	c.timeTaken = t
	c.mu.Unlock()
}

func (c *Call) setError(err error) {
	c.mu.Lock()
	c.err = err
	c.mu.Unlock()
}

func (c *Call) setErrorKind(kind string) {
	c.mu.Lock()
	c.errorKind = kind
	c.mu.Unlock()
}

func (c *Call) markDone() {
	c.doneOnce.Do(func() {
		c.doneClosed.Store(true)
		close(c.done)
	})
}

func (c *Call) GetID() CallID {
	return c.id
}

func (c *Call) GetQuery() string {
	return c.query
}

func (c *Call) GetState() CallState {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.state
}

func (c *Call) GetTimeTaken() time.Duration {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.timeTaken
}

func (c *Call) GetTimestamp() time.Time {
	return c.timestamp
}

func (c *Call) Err() error {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.err
}

func (c *Call) ErrorKind() string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.errorKind
}

// Done returns a non-buffered channel that is closed when
// call finishes.
func (c *Call) Done() chan struct{} {
	return c.done
}

func (c *Call) Cancel() {
	select {
	case <-c.done:
		return
	default:
	}

	if c.GetState() > CallStateExecuting {
		return
	}
	if c.cancelFunc != nil {
		c.cancelFunc()
	}
}

func (c *Call) GetResult() (*Result, error) {
	if c.result.IsEmpty() {
		iter, err := c.archive.getResult()
		if err != nil {
			return nil, fmt.Errorf("c.archive.getResult: %w", err)
		}
		err = c.result.SetIter(iter, nil)
		if err != nil {
			return nil, fmt.Errorf("c.result.setIter: %w", err)
		}
	}

	return c.result, nil
}
