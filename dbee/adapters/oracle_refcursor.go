package adapters

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strings"

	go_ora "github.com/sijms/go-ora/v2"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/kndndrj/nvim-dbee/dbee/core/builders"
)

// cursorMarkerPattern matches bind variables marked as cursors: :name /*CURSOR*/
var cursorMarkerPattern = regexp.MustCompile(`:\w+\s*/\*CURSOR\*/`)

// hasCursorMarker checks if the query contains any /*CURSOR*/ markers
func hasCursorMarker(query string) bool {
	return cursorMarkerPattern.MatchString(query)
}

// parseCursorParams extracts cursor parameter names and returns the cleaned query
// Example: "BEGIN proc(:result /*CURSOR*/); END;" -> ["result"], "BEGIN proc(:result); END;"
func parseCursorParams(query string) ([]string, string) {
	var params []string
	// Find all :name /*CURSOR*/ patterns
	matches := cursorMarkerPattern.FindAllString(query, -1)
	for _, match := range matches {
		// Extract param name (everything between : and space)
		name := strings.TrimSpace(match)
		name = strings.TrimPrefix(name, ":")
		name = strings.Split(name, " ")[0]
		params = append(params, name)
	}
	// Remove /*CURSOR*/ markers from query
	cleanQuery := regexp.MustCompile(`\s*/\*CURSOR\*/`).ReplaceAllString(query, "")
	return params, cleanQuery
}

// executePLSQLWithCursor handles PL/SQL execution with REF CURSOR OUT parameters.
// The cursor results are returned as a proper ResultStream grid.
func (d *oracleDriver) executePLSQLWithCursor(ctx context.Context, query string) (core.ResultStream, error) {
	// Parse cursor parameters
	cursorParams, cleanQuery := parseCursorParams(query)
	if len(cursorParams) == 0 {
		return nil, errors.New("no cursor parameters found")
	}

	// We only support one cursor for now
	if len(cursorParams) > 1 {
		return nil, fmt.Errorf("multiple cursors not supported, found: %v", cursorParams)
	}
	cursorParam := cursorParams[0]

	// Get raw database connection for go-ora specific features
	rawConn, err := d.db.Conn(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get connection: %w", err)
	}

	// Enable DBMS_OUTPUT first (same connection)
	_, err = rawConn.ExecContext(ctx, "BEGIN DBMS_OUTPUT.ENABLE(1000000); END;")
	if err != nil {
		rawConn.Close()
		return nil, fmt.Errorf("failed to enable DBMS_OUTPUT: %w", err)
	}

	// Prepare cursor binding
	var cursor go_ora.RefCursor

	// Add semicolon if needed
	execQuery := cleanQuery
	isCall := strings.HasPrefix(strings.ToUpper(strings.TrimSpace(cleanQuery)), "CALL ")
	if !isCall && !strings.HasSuffix(strings.TrimSpace(cleanQuery), ";") {
		execQuery = cleanQuery + ";"
	}

	// Execute with cursor OUT parameter
	_, err = rawConn.ExecContext(ctx, execQuery,
		sql.Named(cursorParam, sql.Out{Dest: &cursor}))
	if err != nil {
		rawConn.Close()
		return nil, formatOracleError(err)
	}

	// Query the cursor to get DataSet
	dataSet, err := cursor.Query()
	if err != nil {
		rawConn.Close()
		return nil, fmt.Errorf("failed to query cursor: %w", err)
	}

	// Build ResultStream from DataSet
	return buildRefCursorResultStream(dataSet, rawConn), nil
}

// buildRefCursorResultStream converts a go-ora DataSet to a core.ResultStream
func buildRefCursorResultStream(ds *go_ora.DataSet, conn *sql.Conn) core.ResultStream {
	// Get column names
	cols := ds.Columns()
	header := make(core.Header, len(cols))
	for i, col := range cols {
		header[i] = col
	}

	// Buffer for prefetched row
	var prefetchedRow core.Row
	var prefetchErr error
	hasPrefetched := false

	// hasNext prefetches the next row
	hasNextFunc := func() bool {
		if hasPrefetched {
			return prefetchedRow != nil
		}

		// Fetch next row into driver.Value slice
		rowBuffer := make([]driver.Value, len(cols))
		err := ds.Next(rowBuffer)
		if err != nil {
			if errors.Is(err, io.EOF) {
				prefetchedRow = nil
				prefetchErr = nil
			} else {
				prefetchedRow = nil
				prefetchErr = err
			}
			hasPrefetched = true
			return false
		}

		// Convert to core.Row
		prefetchedRow = make(core.Row, len(rowBuffer))
		for i, v := range rowBuffer {
			prefetchedRow[i] = v
		}
		prefetchErr = nil
		hasPrefetched = true
		return true
	}

	// next returns the prefetched row
	nextFunc := func() (core.Row, error) {
		if !hasPrefetched {
			// Should not happen if hasNext is called first
			return nil, errors.New("next called without hasNext")
		}
		row := prefetchedRow
		err := prefetchErr
		// Reset for next iteration
		hasPrefetched = false
		prefetchedRow = nil
		prefetchErr = nil
		return row, err
	}

	return builders.NewResultStreamBuilder().
		WithHeader(header).
		WithNextFunc(nextFunc, hasNextFunc).
		WithCloseFunc(func() {
			ds.Close()
			conn.Close()
		}).
		Build()
}
