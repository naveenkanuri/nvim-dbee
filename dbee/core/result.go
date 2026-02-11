package core

import (
	"context"
	"fmt"
	"sync"
	"time"
)

var ErrInvalidRange = func(from, to int) error { return fmt.Errorf("invalid selection range: %d ... %d", from, to) }

// Result is the cached form of the ResultStream iterator
type Result struct {
	header Header
	meta   *Meta
	rows   []Row

	isDrained  bool
	isFilled   bool
	fillErr    error
	writeMutex sync.Mutex
	readMutex  sync.RWMutex
}

// SetIter sets the ResultStream iterator to result.
// This can be done only once!
func (cr *Result) SetIter(iter ResultStream, onFillStart func()) error {
	// lock write mutex
	cr.writeMutex.Lock()
	defer cr.writeMutex.Unlock()

	// close iterator on return
	defer iter.Close()

	cr.readMutex.Lock()
	cr.header = append(Header{}, iter.Header()...)
	meta := iter.Meta()
	if meta != nil {
		metaCopy := *meta
		cr.meta = &metaCopy
	} else {
		cr.meta = nil
	}
	cr.rows = make([]Row, 0)
	cr.isDrained = false
	cr.isFilled = true
	cr.fillErr = nil
	cr.readMutex.Unlock()

	defer func() {
		cr.readMutex.Lock()
		cr.isDrained = true
		cr.readMutex.Unlock()
	}()

	// trigger callback
	if onFillStart != nil {
		onFillStart()
	}

	// drain the iterator
	for iter.HasNext() {
		row, err := iter.Next()
		cr.readMutex.Lock()
		if err != nil {
			cr.fillErr = err
			cr.readMutex.Unlock()
			return err
		}

		cr.rows = append(cr.rows, row)
		cr.readMutex.Unlock()
	}

	return nil
}

func (cr *Result) Wipe() {
	// lock write and read mutexes
	cr.writeMutex.Lock()
	defer cr.writeMutex.Unlock()
	cr.readMutex.Lock()
	defer cr.readMutex.Unlock()

	// clear everything
	cr.header = Header{}
	cr.meta = &Meta{}
	cr.rows = []Row{}
	cr.isDrained = false
	cr.isFilled = false
	cr.fillErr = nil
}

func (cr *Result) Format(formatter Formatter, from, to int) ([]byte, error) {
	rows, fromAdjusted, _, err := cr.getRows(from, to)
	if err != nil {
		return nil, fmt.Errorf("cr.Rows: %w", err)
	}

	header := cr.Header()
	meta := cr.Meta()
	schemaType := SchemaFul
	if meta != nil {
		schemaType = meta.SchemaType
	}

	opts := &FormatterOptions{
		SchemaType: schemaType,
		ChunkStart: fromAdjusted,
	}

	f, err := formatter.Format(header, rows, opts)
	if err != nil {
		return nil, fmt.Errorf("formatter.Format: %w", err)
	}

	return f, nil
}

func (cr *Result) Len() int {
	cr.readMutex.RLock()
	defer cr.readMutex.RUnlock()
	return len(cr.rows)
}

func (cr *Result) IsEmpty() bool {
	cr.readMutex.RLock()
	defer cr.readMutex.RUnlock()
	return !cr.isFilled
}

func (cr *Result) Header() Header {
	cr.readMutex.RLock()
	defer cr.readMutex.RUnlock()
	header := make(Header, len(cr.header))
	copy(header, cr.header)
	return header
}

func (cr *Result) Meta() *Meta {
	cr.readMutex.RLock()
	defer cr.readMutex.RUnlock()
	if cr.meta == nil {
		return nil
	}
	meta := *cr.meta
	return &meta
}

func (cr *Result) Rows(from, to int) ([]Row, error) {
	rows, _, _, err := cr.getRows(from, to)
	return rows, err
}

// getRows returns the row range and adjusted from-to values
func (cr *Result) getRows(from, to int) (rows []Row, rangeFrom, rangeTo int, err error) {
	// validation
	if (from < 0 && to < 0) || (from >= 0 && to >= 0) {
		if from > to {
			return nil, 0, 0, ErrInvalidRange(from, to)
		}
	}
	// undefined -> error
	if from < 0 && to >= 0 {
		return nil, 0, 0, ErrInvalidRange(from, to)
	}

	// timeout context
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	// Wait for drain, available index or timeout
	for {
		cr.readMutex.RLock()
		isDrained := cr.isDrained
		fillErr := cr.fillErr
		length := len(cr.rows)
		cr.readMutex.RUnlock()

		if fillErr != nil {
			return nil, 0, 0, fmt.Errorf("result fill failed: %w", fillErr)
		}

		if isDrained || (to >= 0 && to <= length) {
			break
		}

		if err := ctx.Err(); err != nil {
			return nil, 0, 0, fmt.Errorf("cache flushing timeout exceeded: %s", err)
		}
		time.Sleep(50 * time.Millisecond)
	}

	cr.readMutex.RLock()
	defer cr.readMutex.RUnlock()
	if cr.fillErr != nil {
		return nil, 0, 0, fmt.Errorf("result fill failed: %w", cr.fillErr)
	}

	// calculate range
	length := len(cr.rows)
	if from < 0 {
		from += length + 1
		if from < 0 {
			from = 0
		}
	}
	if to < 0 {
		to += length + 1
		if to < 0 {
			to = 0
		}
	}

	if from > length {
		from = length
	}
	if to > length {
		to = length
	}

	rows = make([]Row, to-from)
	copy(rows, cr.rows[from:to])
	return rows, from, to, nil
}
