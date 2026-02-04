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

// cursorData holds the results from a single REF CURSOR
type cursorData struct {
	name   string
	header core.Header
	rows   []core.Row
}

// executePLSQLWithCursor handles PL/SQL execution with REF CURSOR OUT parameters.
// The cursor results are returned as a proper ResultStream grid.
// Multiple cursors are displayed sequentially with separator rows.
func (d *oracleDriver) executePLSQLWithCursor(ctx context.Context, query string) (core.ResultStream, error) {
	// Parse cursor parameters
	cursorParams, cleanQuery := parseCursorParams(query)
	if len(cursorParams) == 0 {
		return nil, errors.New("no cursor parameters found")
	}

	// Get raw database connection for go-ora specific features
	rawConn, err := d.db.Conn(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get connection: %w", err)
	}

	// Enable DBMS_OUTPUT first (same connection)
	_, err = rawConn.ExecContext(ctx, "BEGIN DBMS_OUTPUT.ENABLE(NULL); END;")
	if err != nil {
		rawConn.Close()
		return nil, fmt.Errorf("failed to enable DBMS_OUTPUT: %w", err)
	}

	// Create cursor variables and build named parameters
	cursors := make([]go_ora.RefCursor, len(cursorParams))
	args := make([]interface{}, len(cursorParams))
	for i, param := range cursorParams {
		args[i] = sql.Named(param, sql.Out{Dest: &cursors[i]})
	}

	// Add semicolon if needed
	execQuery := cleanQuery
	isCall := strings.HasPrefix(strings.ToUpper(strings.TrimSpace(cleanQuery)), "CALL ")
	if !isCall && !strings.HasSuffix(strings.TrimSpace(cleanQuery), ";") {
		execQuery = cleanQuery + ";"
	}

	// Execute with all cursor OUT parameters
	_, err = rawConn.ExecContext(ctx, execQuery, args...)
	if err != nil {
		rawConn.Close()
		return nil, formatOracleError(err)
	}

	// Collect results from all cursors
	var allResults []cursorData
	for i, cursor := range cursors {
		result, err := collectCursorData(cursorParams[i], &cursor)
		if err != nil {
			rawConn.Close()
			return nil, fmt.Errorf("failed to read cursor %s: %w", cursorParams[i], err)
		}
		allResults = append(allResults, result)
	}

	rawConn.Close()

	// Build combined ResultStream
	return buildMultiCursorResultStream(allResults), nil
}

// collectCursorData reads all rows from a cursor into memory
func collectCursorData(name string, cursor *go_ora.RefCursor) (cursorData, error) {
	ds, err := cursor.Query()
	if err != nil {
		return cursorData{}, err
	}
	defer ds.Close()

	cols := ds.Columns()
	header := make(core.Header, len(cols))
	for i, col := range cols {
		header[i] = col
	}

	var rows []core.Row
	for {
		rowBuffer := make([]driver.Value, len(cols))
		err := ds.Next(rowBuffer)
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return cursorData{}, err
		}
		row := make(core.Row, len(rowBuffer))
		for i, v := range rowBuffer {
			row[i] = v
		}
		rows = append(rows, row)
	}

	return cursorData{name: name, header: header, rows: rows}, nil
}

// buildMultiCursorResultStream creates a ResultStream from multiple cursor results.
// Each cursor section starts with a header row showing the cursor name.
func buildMultiCursorResultStream(results []cursorData) core.ResultStream {
	if len(results) == 0 {
		return builders.NewResultStreamBuilder().
			WithHeader(core.Header{"(no results)"}).
			WithNextFunc(func() (core.Row, error) { return nil, nil }, func() bool { return false }).
			Build()
	}

	// For single cursor, use simple format (no separator needed)
	if len(results) == 1 {
		idx := 0
		rows := results[0].rows
		return builders.NewResultStreamBuilder().
			WithHeader(results[0].header).
			WithNextFunc(
				func() (core.Row, error) {
					if idx >= len(rows) {
						return nil, nil
					}
					row := rows[idx]
					idx++
					return row, nil
				},
				func() bool { return idx < len(rows) },
			).
			Build()
	}

	// For multiple cursors, find max column count and build unified stream
	maxCols := 0
	for _, r := range results {
		if len(r.header) > maxCols {
			maxCols = len(r.header)
		}
	}

	// Build flattened rows: separator + header + data for each cursor
	var allRows []core.Row
	for i, r := range results {
		// Add separator row (except for first cursor)
		if i > 0 {
			sep := make(core.Row, maxCols)
			sep[0] = "───────────────"
			for j := 1; j < maxCols; j++ {
				sep[j] = ""
			}
			allRows = append(allRows, sep)
		}

		// Add cursor name row
		nameRow := make(core.Row, maxCols)
		nameRow[0] = fmt.Sprintf("▶ %s", strings.ToUpper(r.name))
		for j := 1; j < maxCols; j++ {
			nameRow[j] = ""
		}
		allRows = append(allRows, nameRow)

		// Add header row
		headerRow := make(core.Row, maxCols)
		for j := 0; j < maxCols; j++ {
			if j < len(r.header) {
				headerRow[j] = r.header[j]
			} else {
				headerRow[j] = ""
			}
		}
		allRows = append(allRows, headerRow)

		// Add data rows (pad if needed)
		for _, row := range r.rows {
			paddedRow := make(core.Row, maxCols)
			for j := 0; j < maxCols; j++ {
				if j < len(row) {
					paddedRow[j] = row[j]
				} else {
					paddedRow[j] = nil
				}
			}
			allRows = append(allRows, paddedRow)
		}
	}

	// Use first cursor's header as the stream header (for column count)
	streamHeader := make(core.Header, maxCols)
	for i := 0; i < maxCols; i++ {
		if i < len(results[0].header) {
			streamHeader[i] = results[0].header[i]
		} else {
			streamHeader[i] = fmt.Sprintf("COL%d", i+1)
		}
	}

	idx := 0
	return builders.NewResultStreamBuilder().
		WithHeader(streamHeader).
		WithNextFunc(
			func() (core.Row, error) {
				if idx >= len(allRows) {
					return nil, nil
				}
				row := allRows[idx]
				idx++
				return row, nil
			},
			func() bool { return idx < len(allRows) },
		).
		Build()
}

