package core_test

import (
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/kndndrj/nvim-dbee/dbee/core/mock"
)

type failingResultStream struct {
	header    core.Header
	meta      *core.Meta
	rows      []core.Row
	failAfter int
	index     int
}

func (s *failingResultStream) Meta() *core.Meta {
	return s.meta
}

func (s *failingResultStream) Header() core.Header {
	return s.header
}

func (s *failingResultStream) Next() (core.Row, error) {
	if s.index >= len(s.rows) {
		return nil, errors.New("no next row")
	}
	if s.index >= s.failAfter {
		return nil, errors.New("stream read failed")
	}

	row := s.rows[s.index]
	s.index++
	return row, nil
}

func (s *failingResultStream) HasNext() bool {
	return s.index < len(s.rows)
}

func (s *failingResultStream) Close() {}

func TestResult(t *testing.T) {
	type testCase struct {
		name          string
		from          int
		to            int
		input         []core.Row
		expected      []core.Row
		expectedError error
	}

	testCases := []testCase{
		{
			name:          "get all",
			from:          0,
			to:            -1,
			input:         mock.NewRows(0, 10),
			expected:      mock.NewRows(0, 10),
			expectedError: nil,
		},
		{
			name:          "get basic range",
			from:          0,
			to:            3,
			input:         mock.NewRows(0, 10),
			expected:      mock.NewRows(0, 3),
			expectedError: nil,
		},
		{
			name:          "get last 2",
			from:          -3,
			to:            -1,
			input:         mock.NewRows(0, 10),
			expected:      mock.NewRows(8, 10),
			expectedError: nil,
		},
		{
			name:          "get only one",
			from:          0,
			to:            1,
			input:         mock.NewRows(0, 10),
			expected:      mock.NewRows(0, 1),
			expectedError: nil,
		},

		{
			name:          "invalid range",
			from:          5,
			to:            1,
			input:         mock.NewRows(0, 10),
			expected:      nil,
			expectedError: core.ErrInvalidRange(5, 1),
		},
		{
			name:          "invalid range (even if 10 can be higher than -1, its undefined and should fail)",
			from:          -5,
			to:            10,
			input:         mock.NewRows(0, 10),
			expected:      nil,
			expectedError: core.ErrInvalidRange(-5, 10),
		},

		{
			name:          "wait for available index",
			from:          0,
			to:            3,
			input:         mock.NewRows(0, 10),
			expected:      mock.NewRows(0, 3),
			expectedError: nil,
		},
		{
			name:          "wait for all to be drained",
			from:          0,
			to:            -1,
			input:         mock.NewRows(0, 10),
			expected:      mock.NewRows(0, 10),
			expectedError: nil,
		},
	}

	result := new(core.Result)

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			r := require.New(t)
			// wipe any previous result
			result.Wipe()

			// set a new iterator with input
			err := result.SetIter(mock.NewResultStream(tc.input, mock.ResultStreamWithNextSleep(300*time.Millisecond)), nil)
			r.NoError(err)

			rows, err := result.Rows(tc.from, tc.to)
			if err != nil {
				r.ErrorContains(err, tc.expectedError.Error())
			}
			r.Equal(tc.expected, rows)
		})
	}
}

func TestResult_ConcurrentReadersDuringFill(t *testing.T) {
	r := require.New(t)
	result := new(core.Result)
	input := mock.NewRows(0, 128)

	fillStarted := make(chan struct{})
	setDone := make(chan error, 1)
	go func() {
		setDone <- result.SetIter(
			mock.NewResultStream(input, mock.ResultStreamWithNextSleep(2*time.Millisecond)),
			func() { close(fillStarted) },
		)
	}()

	<-fillStarted

	var wg sync.WaitGroup
	stop := make(chan struct{})
	readerErr := make(chan error, 1)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
					if _, err := result.Rows(0, 1); err != nil {
						select {
						case readerErr <- err:
						default:
						}
						return
					}
					if _, err := result.Rows(0, 64); err != nil {
						select {
						case readerErr <- err:
						default:
						}
						return
					}
					_ = result.Len()
					_ = result.IsEmpty()
					_ = result.Header()
					_ = result.Meta()
				}
			}
		}()
	}

	err := <-setDone
	close(stop)
	wg.Wait()

	r.NoError(err)
	select {
	case err := <-readerErr:
		r.NoError(err)
	default:
	}
	rows, rowsErr := result.Rows(0, -1)
	r.NoError(rowsErr)
	r.Equal(input, rows)
}

func TestResult_RowsReturnsFillError(t *testing.T) {
	r := require.New(t)

	result := new(core.Result)
	stream := &failingResultStream{
		header:    core.Header{"id", "name"},
		meta:      &core.Meta{},
		rows:      mock.NewRows(0, 3),
		failAfter: 1,
	}

	err := result.SetIter(stream, nil)
	r.ErrorContains(err, "stream read failed")
	r.Equal(1, result.Len())
	r.False(result.IsEmpty())

	rows, rowsErr := result.Rows(0, -1)
	r.Nil(rows)
	r.ErrorContains(rowsErr, "result fill failed")
	r.ErrorContains(rowsErr, "stream read failed")

	boundedRows, boundedErr := result.Rows(0, 1)
	r.Nil(boundedRows)
	r.ErrorContains(boundedErr, "result fill failed")
	r.ErrorContains(boundedErr, "stream read failed")
}
