package adapters

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/kndndrj/nvim-dbee/dbee/core/builders"
)

// oracleQueryTimeout is the default timeout for Oracle query execution.
// go-ora defaults to 30s which is too short for many queries.
const oracleQueryTimeout = 30 * time.Minute

var _ core.Driver = (*oracleDriver)(nil)

type oracleDriver struct {
	c  *builders.Client
	db *sql.DB
}

func (d *oracleDriver) Query(ctx context.Context, query string) (core.ResultStream, error) {
	// Create a context with longer timeout for Oracle queries.
	// go-ora defaults to 30s which is too short for many queries.
	// The parent context can still cancel early if user requests it.
	// Note: We don't defer cancel() because the ResultStream may still need
	// the context after Query() returns. The context will be cleaned up when
	// the parent ctx is cancelled or the timeout expires.
	queryCtx, _ := context.WithTimeout(ctx, oracleQueryTimeout)

	// Remove the trailing semicolon from the query - for some reason it isn't supported in go_ora
	query = strings.TrimSuffix(query, ";")

	// Check if this is a PL/SQL block
	if isPLSQL(query) {
		return d.executePLSQL(queryCtx, query)
	}

	// Use Exec or Query depending on the query
	action := strings.ToLower(strings.Split(query, " ")[0])
	hasReturnValues := strings.Contains(strings.ToLower(query), " returning ")
	if (action == "update" || action == "delete" || action == "insert") && !hasReturnValues {
		return d.c.Exec(queryCtx, query)
	}

	return d.c.QueryUntilNotEmpty(queryCtx, query)
}

// executePLSQL handles PL/SQL block execution with DBMS_OUTPUT capture.
// Uses a dedicated connection to ensure all operations happen in the same Oracle session,
// since DBMS_OUTPUT is session-scoped.
// If the query contains /*CURSOR*/ markers, returns cursor results as a grid.
func (d *oracleDriver) executePLSQL(ctx context.Context, query string) (core.ResultStream, error) {
	// Check for cursor markers - if present, use cursor execution path
	if hasCursorMarker(query) {
		return d.executePLSQLWithCursor(ctx, query)
	}

	// Get a dedicated connection from the pool - CRITICAL for DBMS_OUTPUT
	// which is session-scoped. All operations must happen on the same connection.
	conn, err := d.db.Conn(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get connection: %w", err)
	}
	defer conn.Close()

	// Step 1: Enable DBMS_OUTPUT with 1MB buffer
	_, err = conn.ExecContext(ctx, "BEGIN DBMS_OUTPUT.ENABLE(1000000); END;")
	if err != nil {
		return nil, fmt.Errorf("failed to enable DBMS_OUTPUT: %w", err)
	}

	// Step 2: Execute the PL/SQL block
	// Note: Query() strips trailing semicolons, but PL/SQL blocks need them.
	// Exception: CALL statements don't use semicolons in Oracle.
	plsqlQuery := query
	isCall := strings.HasPrefix(strings.ToUpper(strings.TrimSpace(query)), "CALL ")
	if !isCall && !strings.HasSuffix(strings.TrimSpace(query), ";") {
		plsqlQuery = query + ";"
	}
	_, err = conn.ExecContext(ctx, plsqlQuery)
	if err != nil {
		return nil, formatOracleError(err)
	}

	// Step 3: Fetch DBMS_OUTPUT lines (using same connection)
	output, err := d.fetchDBMSOutputFromConn(ctx, conn)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch DBMS_OUTPUT: %w", err)
	}

	// Step 4: Return output as result stream
	lines := parseDBMSOutputLines(output)
	return buildDBMSOutputResultStream(lines), nil
}

// fetchDBMSOutputFromConn retrieves all lines from the DBMS_OUTPUT buffer using GET_LINE.
// Must use the same connection that executed the PL/SQL block.
func (d *oracleDriver) fetchDBMSOutputFromConn(ctx context.Context, conn *sql.Conn) (string, error) {
	var output strings.Builder

	for {
		// Pre-allocate buffer for line - DBMS_OUTPUT lines can be up to 32767 chars
		// go-ora needs this hint for OUT parameter sizing
		line := strings.Repeat(" ", 32767)
		var status int64

		// Call DBMS_OUTPUT.GET_LINE as a procedure with OUT parameters
		// Using named parameters as required by go-ora for OUT binds
		_, err := conn.ExecContext(ctx, `BEGIN DBMS_OUTPUT.GET_LINE(:line, :status); END;`,
			sql.Named("line", sql.Out{Dest: &line}),
			sql.Named("status", sql.Out{Dest: &status}))
		if err != nil {
			// Return error info as output for debugging
			return output.String() + "[GET_LINE error: " + err.Error() + "]", nil
		}

		// status 0 = success, 1 = no more lines
		if status != 0 {
			break
		}

		// Trim the pre-allocated spaces and add to output
		line = strings.TrimRight(line, " ")
		if line != "" {
			output.WriteString(line)
			output.WriteString("\n")
		}
	}

	return output.String(), nil
}

func (d *oracleDriver) Columns(opts *core.TableOptions) ([]*core.Column, error) {
	return d.c.ColumnsFromQuery(`
		SELECT
			col.column_name,
			col.data_type
		FROM sys.all_tab_columns col
		WHERE col.owner = '%s'
			AND col.table_name = '%s'
		ORDER BY col.owner, col.table_name, col.column_id `,

		opts.Schema,
		opts.Table)
}

func (d *oracleDriver) Structure() ([]*core.Structure, error) {
	query := `
		SELECT owner, object_name, type
		FROM (
			SELECT owner, table_name as object_name, 'TABLE' as type
			FROM all_tables
			UNION ALL
			SELECT owner, table_name as object_name, 'EXTERNAL TABLE' as type
			FROM all_external_tables
			UNION ALL
			SELECT owner, view_name as object_name, 'VIEW' as type
			FROM all_views
			UNION ALL
			SELECT owner, mview_name as object_name, 'MATERIALIZED VIEW' as type
			FROM all_mviews
		)
		WHERE owner IN (SELECT username FROM all_users WHERE common = 'NO')
		ORDER BY owner, object_name
	`

	rows, err := d.Query(context.TODO(), query)
	if err != nil {
		return nil, err
	}

	decodeStructureType := func(s string) core.StructureType {
		switch s {
		case "TABLE", "EXTERNAL TABLE":
			return core.StructureTypeTable
		case "VIEW":
			return core.StructureTypeView
		case "MATERIALIZED VIEW":
			return core.StructureTypeMaterializedView
		default:
			return core.StructureTypeNone
		}
	}

	return core.GetGenericStructure(rows, decodeStructureType)
}

func (d *oracleDriver) Close() { d.c.Close() }
