package core

import (
	"fmt"
	"reflect"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

type staticResultStream struct {
	header Header
	meta   *Meta
	rows   []Row
	index  int
}

func (s *staticResultStream) Meta() *Meta {
	return s.meta
}

func (s *staticResultStream) Header() Header {
	return s.header
}

func (s *staticResultStream) Next() (Row, error) {
	row := s.rows[s.index]
	s.index++
	return row, nil
}

func (s *staticResultStream) HasNext() bool {
	return s.index < len(s.rows)
}

func (s *staticResultStream) Close() {}

func TestCallGetResult_ConcurrentArchiveLoadIsSingleflight(t *testing.T) {
	r := require.New(t)

	prevGetArchiveResult := getArchiveResult
	defer func() { getArchiveResult = prevGetArchiveResult }()

	var archiveLoads atomic.Int32
	expectedRows := []Row{
		{int64(1), "row_1"},
		{int64(2), "row_2"},
	}

	getArchiveResult = func(_ *archive) (ResultStream, error) {
		archiveLoads.Add(1)
		// Keep archive load in-flight so concurrent callers contend on GetResult.
		time.Sleep(50 * time.Millisecond)
		return &staticResultStream{
			header: Header{"id", "name"},
			meta:   &Meta{},
			rows:   expectedRows,
		}, nil
	}

	call := &Call{
		result:  new(Result),
		archive: &archive{},
	}

	var wg sync.WaitGroup
	errCh := make(chan error, 32)
	for i := 0; i < 32; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			result, err := call.GetResult()
			if err != nil {
				errCh <- err
				return
			}
			rows, err := result.Rows(0, -1)
			if err != nil {
				errCh <- err
				return
			}
			if !reflect.DeepEqual(expectedRows, rows) {
				errCh <- fmt.Errorf("unexpected rows: %#v", rows)
			}
		}()
	}

	wg.Wait()
	close(errCh)

	for err := range errCh {
		r.NoError(err)
	}
	r.Equal(int32(1), archiveLoads.Load())
}
