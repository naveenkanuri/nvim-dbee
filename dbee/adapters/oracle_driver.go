package adapters

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/kndndrj/nvim-dbee/dbee/core/builders"
)

// oracleDefaultQueryTimeout is the fallback timeout when the caller's context
// has no deadline. go-ora's internal default (~30s) is too short for many
// queries; this provides a practical "no limit" that still gives go-ora a
// deadline to work with. Starts after mutex acquisition so queue wait time
// is excluded.
const oracleDefaultQueryTimeout = 24 * time.Hour

var _ core.Driver = (*oracleDriver)(nil)
var _ core.BindDriver = (*oracleDriver)(nil)

type oracleDriver struct {
	c        *builders.Client
	db       *sql.DB
	mu       sync.Mutex // execution gate + sessConn pointer protection
	sessConn *sql.Conn  // pinned session connection, lazily created
}

type oracleExecContexter interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
}

func (d *oracleDriver) Query(ctx context.Context, query string) (core.ResultStream, error) {
	return d.QueryWithBinds(ctx, query, nil)
}

func parseOracleTimestamp(value string) (time.Time, error) {
	layouts := []string{
		time.RFC3339Nano,
		"2006-01-02 15:04:05",
		"2006-01-02 15:04:05.999999999",
		"2006-01-02 15:04:05Z07:00",
		"2006-01-02 15:04:05.999999999Z07:00",
		"2006-01-02T15:04:05",
		"2006-01-02T15:04:05.999999999",
	}
	trimmed := strings.TrimSpace(value)
	for _, layout := range layouts {
		ts, err := time.Parse(layout, trimmed)
		if err == nil {
			return ts, nil
		}
	}
	return time.Time{}, fmt.Errorf("invalid timestamp literal: %q", value)
}

// coerceOracleBindValue converts explicit typed bind literals into Go values.
// Unrecognized literals remain strings for backward compatibility.
func coerceOracleBindValue(raw string) any {
	trimmed := strings.TrimSpace(raw)
	if strings.EqualFold(trimmed, "null") {
		return nil
	}

	parts := strings.SplitN(trimmed, ":", 2)
	if len(parts) != 2 {
		return raw
	}

	kind := strings.ToLower(strings.TrimSpace(parts[0]))
	payload := parts[1]
	switch kind {
	case "str", "string":
		return strings.TrimSpace(payload)
	case "int", "integer":
		n, err := strconv.ParseInt(strings.TrimSpace(payload), 10, 64)
		if err != nil {
			return raw
		}
		return n
	case "float", "number":
		n, err := strconv.ParseFloat(strings.TrimSpace(payload), 64)
		if err != nil {
			return raw
		}
		if math.IsNaN(n) || math.IsInf(n, 0) {
			return raw
		}
		return n
	case "bool", "boolean":
		b, err := strconv.ParseBool(strings.TrimSpace(payload))
		if err != nil {
			return raw
		}
		return b
	case "date":
		date, err := time.Parse("2006-01-02", strings.TrimSpace(payload))
		if err != nil {
			return raw
		}
		return date
	case "timestamp", "ts":
		ts, err := parseOracleTimestamp(strings.TrimSpace(payload))
		if err != nil {
			return raw
		}
		return ts
	default:
		return raw
	}
}

func oracleNamedArgs(binds map[string]string) []any {
	if len(binds) == 0 {
		return nil
	}

	keys := make([]string, 0, len(binds))
	for name := range binds {
		keys = append(keys, name)
	}
	sort.Strings(keys)

	args := make([]any, 0, len(keys))
	for _, name := range keys {
		args = append(args, sql.Named(name, coerceOracleBindValue(binds[name])))
	}
	return args
}

// getSessionConnLocked returns the pinned session connection, creating it
// lazily if needed. Caller MUST hold d.mu.
func (d *oracleDriver) getSessionConnLocked(ctx context.Context) (*sql.Conn, error) {
	if d.sessConn != nil {
		return d.sessConn, nil
	}
	conn, err := d.db.Conn(ctx)
	if err != nil {
		return nil, err
	}
	d.sessConn = conn
	return conn, nil
}

// resetSessionConnLocked closes the pinned session connection and sets it to
// nil so the next call creates a fresh one. Caller MUST hold d.mu.
func (d *oracleDriver) resetSessionConnLocked() {
	if d.sessConn != nil {
		_ = d.sessConn.Close()
		d.sessConn = nil
	}
}

// isSessionConnError returns true for errors that indicate the underlying
// Oracle session is dead and should be replaced. Transient timeouts do NOT
// trigger a reset — only hard disconnect signatures.
func isSessionConnError(err error) bool {
	if errors.Is(err, driver.ErrBadConn) || errors.Is(err, sql.ErrConnDone) {
		return true
	}
	upper := strings.ToUpper(err.Error())
	for _, code := range []string{
		"ORA-03113", // end-of-file on communication channel
		"ORA-03114", // not connected to ORACLE
		"ORA-03135", // connection lost contact
		"ORA-01012", // not logged on
		"ORA-02396", // exceeded maximum idle time
		"ORA-00028", // your session has been killed
	} {
		if strings.Contains(upper, code) {
			return true
		}
	}
	return strings.Contains(upper, "BROKEN PIPE") ||
		strings.Contains(upper, "CONNECTION RESET")
}

// isExecStatement returns true for SQL statements that don't return result
// sets. These use conn.ExecContext instead of conn.QueryContext.
// Strips leading SQL comments before classifying.
func isExecStatement(query string) bool {
	stripped := stripLeadingSQLComments(query)
	fields := strings.Fields(stripped)
	if len(fields) == 0 {
		return false
	}
	switch strings.ToLower(fields[0]) {
	case "insert", "update", "delete", "merge", "alter", "create", "drop",
		"grant", "revoke", "truncate":
		return true
	}
	return false
}

func (d *oracleDriver) QueryWithBinds(ctx context.Context, query string, binds map[string]string) (core.ResultStream, error) {
	// Remove the trailing semicolon — go-ora doesn't support it for plain SQL
	query = strings.TrimSpace(query)
	query = strings.TrimSuffix(query, ";")

	if len(strings.TrimSpace(query)) == 0 {
		return nil, errors.New("empty query")
	}

	d.mu.Lock()

	// Create query context AFTER acquiring mutex so queue wait time is excluded.
	// If the parent already has a deadline, preserve it. Otherwise apply a 24h
	// default so go-ora doesn't fall back to its own short timeout (~30s).
	var queryCtx context.Context
	var cancel context.CancelFunc
	if _, hasDeadline := ctx.Deadline(); hasDeadline {
		queryCtx, cancel = context.WithCancel(ctx)
	} else {
		queryCtx, cancel = context.WithTimeout(ctx, oracleDefaultQueryTimeout)
	}

	conn, err := d.getSessionConnLocked(queryCtx)
	if err != nil {
		d.mu.Unlock()
		cancel()
		return nil, err
	}

	// PL/SQL path — executePLSQLLocked owns d.mu via defer
	if isPLSQL(query) {
		result, err := d.executePLSQLLocked(queryCtx, conn, query, binds)
		cancel()
		return result, err
	}

	bindArgs := oracleNamedArgs(binds)
	hasReturning := strings.Contains(strings.ToLower(query), " returning ")

	// Exec path: statements that don't return result sets
	if isExecStatement(query) && !hasReturning {
		res, err := conn.ExecContext(queryCtx, query, bindArgs...)
		if err != nil {
			if isSessionConnError(err) {
				d.resetSessionConnLocked()
			}
			d.mu.Unlock()
			cancel()
			return nil, err
		}
		// Read metadata BEFORE unlock — driver may reference conn internally
		affected, err := res.RowsAffected()
		d.mu.Unlock()
		if err != nil {
			cancel()
			return nil, fmt.Errorf("RowsAffected: %w", err)
		}
		result := builders.NewResultStreamBuilder().
			WithNextFunc(builders.NextSingle(affected)).
			WithHeader(core.Header{"Rows Affected"}).
			Build()
		result.AddCallback(cancel)
		return result, nil
	}

	// Query path: SELECT / RETURNING / unknown
	result, err := d.c.QueryOnConn(queryCtx, conn, query, bindArgs...)
	if err != nil {
		if isSessionConnError(err) {
			d.resetSessionConnLocked()
		}
		d.mu.Unlock()
		cancel()
		return nil, err
	}
	result.AddCallback(func() { d.mu.Unlock() }) // release gate when rows drained
	result.AddCallback(cancel)
	return result, nil
}

// executePLSQLLocked handles PL/SQL block execution with DBMS_OUTPUT capture.
// Uses the session-pinned connection for all operations.
// Caller MUST hold d.mu. This method releases it via defer.
func (d *oracleDriver) executePLSQLLocked(ctx context.Context, conn *sql.Conn, query string, binds map[string]string) (core.ResultStream, error) {
	defer d.mu.Unlock()

	// Cursor path — worker does NOT touch the mutex
	if hasCursorMarker(query) {
		return d.executePLSQLWithCursor(ctx, conn, query, binds)
	}

	// Enable DBMS_OUTPUT with unlimited buffer (session-scoped)
	_, err := conn.ExecContext(ctx, "BEGIN DBMS_OUTPUT.ENABLE(NULL); END;")
	if err != nil {
		if isSessionConnError(err) {
			d.resetSessionConnLocked()
		}
		return nil, fmt.Errorf("failed to enable DBMS_OUTPUT: %w", err)
	}

	// Execute the PL/SQL block
	plsqlQuery := stripTrailingSQLPlusSlashTerminator(query)
	isCall := strings.HasPrefix(strings.ToUpper(stripLeadingSQLComments(plsqlQuery)), "CALL ")
	if !isCall && !strings.HasSuffix(strings.TrimSpace(plsqlQuery), ";") {
		plsqlQuery += ";"
	}
	_, err = conn.ExecContext(ctx, plsqlQuery, oracleNamedArgs(binds)...)
	if err != nil {
		if isSessionConnError(err) {
			d.resetSessionConnLocked()
		}
		return nil, formatOracleError(err)
	}

	// Fetch DBMS_OUTPUT lines (same session connection)
	output, err := d.fetchDBMSOutputFromConn(ctx, conn)
	if err != nil {
		if isSessionConnError(err) {
			d.resetSessionConnLocked()
		}
		return nil, fmt.Errorf("failed to fetch DBMS_OUTPUT: %w", err)
	}

	lines := parseDBMSOutputLines(output)
	return buildDBMSOutputResultStream(lines), nil
}

// fetchDBMSOutputFromConn retrieves all lines from the DBMS_OUTPUT buffer using GET_LINE.
// Must use the same connection that executed the PL/SQL block.
// Note: DBMS_OUTPUT.PUT (without PUT_LINE) content is only captured if followed by PUT_LINE.
func (d *oracleDriver) fetchDBMSOutputFromConn(ctx context.Context, conn oracleExecContexter) (string, error) {

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
			return output.String(), fmt.Errorf("DBMS_OUTPUT.GET_LINE: %w", err)
		}

		// status 0 = success, 1 = no more lines
		if status != 0 {
			break
		}

		// Trim the pre-allocated spaces and add to output
		// Preserve empty lines for formatted output
		line = strings.TrimRight(line, " ")
		output.WriteString(line)
		output.WriteString("\n")
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
		SELECT owner, object_name, object_type
		FROM (
			SELECT owner, table_name as object_name, 'TABLE' as object_type
			FROM all_tables
			UNION ALL
			SELECT owner, table_name as object_name, 'EXTERNAL TABLE' as object_type
			FROM all_external_tables
			UNION ALL
			SELECT owner, view_name as object_name, 'VIEW' as object_type
			FROM all_views
			UNION ALL
			SELECT owner, mview_name as object_name, 'MATERIALIZED VIEW' as object_type
			FROM all_mviews
			UNION ALL
			SELECT owner, object_name, object_type
			FROM all_objects
			WHERE object_type IN ('PROCEDURE', 'FUNCTION')
		)
		WHERE owner IN (SELECT username FROM all_users WHERE common = 'NO')
		ORDER BY owner, object_name
	`

	// Use pool connection, not session conn. Structure queries are fully
	// schema-qualified and don't need session state. Using pool avoids
	// blocking drawer refresh behind a running query.
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	rows, err := d.c.QueryWithArgs(ctx, query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	decodeStructureType := func(s string) core.StructureType {
		switch s {
		case "TABLE", "EXTERNAL TABLE":
			return core.StructureTypeTable
		case "VIEW":
			return core.StructureTypeView
		case "MATERIALIZED VIEW":
			return core.StructureTypeMaterializedView
		case "PROCEDURE":
			return core.StructureTypeProcedure
		case "FUNCTION":
			return core.StructureTypeFunction
		default:
			return core.StructureTypeNone
		}
	}

	return oracleGroupedStructure(rows, decodeStructureType)
}

// oracleGroupedStructure builds a grouped structure tree:
// schema -> tables/procedures/functions sections -> objects.
// Empty sections are omitted.
func oracleGroupedStructure(rows core.ResultStream, structTypeFn func(string) core.StructureType) ([]*core.Structure, error) {
	type schemaData struct {
		tables     []*core.Structure
		procedures []*core.Structure
		functions  []*core.Structure
	}
	schemas := make(map[string]*schemaData)

	for rows.HasNext() {
		row, err := rows.Next()
		if err != nil {
			return nil, err
		}
		if len(row) < 3 {
			return nil, core.ErrInsufficienStructureInfo
		}

		schema, ok := row[0].(string)
		if !ok {
			return nil, fmt.Errorf("expected string for schema, got %T", row[0])
		}
		name, ok := row[1].(string)
		if !ok {
			return nil, fmt.Errorf("expected string for name, got %T", row[1])
		}
		typ, ok := row[2].(string)
		if !ok {
			return nil, fmt.Errorf("expected string for type, got %T", row[2])
		}

		if schemas[schema] == nil {
			schemas[schema] = &schemaData{}
		}

		obj := &core.Structure{
			Name:   name,
			Schema: schema,
			Type:   structTypeFn(typ),
		}

		switch obj.Type {
		case core.StructureTypeProcedure:
			schemas[schema].procedures = append(schemas[schema].procedures, obj)
		case core.StructureTypeFunction:
			schemas[schema].functions = append(schemas[schema].functions, obj)
		default:
			schemas[schema].tables = append(schemas[schema].tables, obj)
		}
	}

	var structure []*core.Structure
	for schema, data := range schemas {
		var children []*core.Structure

		if len(data.tables) > 0 {
			children = append(children, &core.Structure{
				Name:     "tables",
				Schema:   schema,
				Type:     core.StructureTypeNone,
				Children: data.tables,
			})
		}
		if len(data.procedures) > 0 {
			children = append(children, &core.Structure{
				Name:     "procedures",
				Schema:   schema,
				Type:     core.StructureTypeNone,
				Children: data.procedures,
			})
		}
		if len(data.functions) > 0 {
			children = append(children, &core.Structure{
				Name:     "functions",
				Schema:   schema,
				Type:     core.StructureTypeNone,
				Children: data.functions,
			})
		}

		structure = append(structure, &core.Structure{
			Name:     schema,
			Schema:   schema,
			Type:     core.StructureTypeSchema,
			Children: children,
		})
	}

	return structure, nil
}

func (d *oracleDriver) Close() {
	d.mu.Lock()
	if d.sessConn != nil {
		_ = d.sessConn.Close()
		d.sessConn = nil
	}
	d.mu.Unlock()
	d.c.Close()
}
