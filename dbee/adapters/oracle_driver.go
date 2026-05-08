package adapters

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"math"
	"regexp"
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

var (
	_ core.Driver                  = (*oracleDriver)(nil)
	_ core.BindDriver              = (*oracleDriver)(nil)
	_ core.FilteredStructureDriver = (*oracleDriver)(nil)
	_ core.SchemaListDriver        = (*oracleDriver)(nil)
	_ core.SchemaStructureDriver   = (*oracleDriver)(nil)
	_ core.RichMetadataCapability  = (*oracleDriver)(nil)
	_ core.RichColumnDriver        = (*oracleDriver)(nil)
	_ core.IndexDriver             = (*oracleDriver)(nil)
	_ core.SequenceDriver          = (*oracleDriver)(nil)
)

var oracleBindNameRe = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

var oracleUnsafeBindNames = map[string]struct{}{
	"ACCESS":          {},
	"ADD":             {},
	"ALL":             {},
	"ALTER":           {},
	"AND":             {},
	"ANY":             {},
	"AS":              {},
	"ASC":             {},
	"AT":              {},
	"AUDIT":           {},
	"BEGIN":           {},
	"BETWEEN":         {},
	"BFILE":           {},
	"BLOB":            {},
	"BOOLEAN":         {},
	"BULK":            {},
	"BY":              {},
	"CASE":            {},
	"CHAR":            {},
	"CHECK":           {},
	"CLOB":            {},
	"CLOSE":           {},
	"CLUSTER":         {},
	"CLUSTERS":        {},
	"COLAUTH":         {},
	"COLUMN":          {},
	"COLUMNS":         {},
	"COLUMN_VALUE":    {},
	"COMMENT":         {},
	"COMMIT":          {},
	"COMPRESS":        {},
	"CONNECT":         {},
	"CONSTANT":        {},
	"CREATE":          {},
	"CRASH":           {},
	"CURRENT":         {},
	"CURSOR":          {},
	"DATE":            {},
	"DECIMAL":         {},
	"DECLARE":         {},
	"DEFAULT":         {},
	"DELETE":          {},
	"DESC":            {},
	"DISTINCT":        {},
	"DO":              {},
	"DROP":            {},
	"DUAL":            {},
	"ELSE":            {},
	"ELSIF":           {},
	"END":             {},
	"EXCEPTION":       {},
	"EXCLUSIVE":       {},
	"EXECUTE":         {},
	"EXISTS":          {},
	"EXIT":            {},
	"FETCH":           {},
	"FILE":            {},
	"FLOAT":           {},
	"FOR":             {},
	"FROM":            {},
	"FUNCTION":        {},
	"GOTO":            {},
	"GRANT":           {},
	"GROUP":           {},
	"HAVING":          {},
	"IDENTIFIED":      {},
	"IF":              {},
	"IMMEDIATE":       {},
	"IN":              {},
	"INCREMENT":       {},
	"INDEX":           {},
	"INDEXES":         {},
	"INITIAL":         {},
	"INSERT":          {},
	"INTEGER":         {},
	"INTERSECT":       {},
	"INTO":            {},
	"IS":              {},
	"LEVEL":           {},
	"LIKE":            {},
	"LINE":            {},
	"LOCK":            {},
	"LOGFILE":         {},
	"LONG":            {},
	"LOOP":            {},
	"MAXEXTENTS":      {},
	"MERGE":           {},
	"MINUS":           {},
	"MLSLABEL":        {},
	"MODE":            {},
	"MODIFY":          {},
	"NCHAR":           {},
	"NCLOB":           {},
	"NESTED_TABLE_ID": {},
	"NOAUDIT":         {},
	"NOCOMPRESS":      {},
	"NOT":             {},
	"NOWAIT":          {},
	"NULL":            {},
	"NUMBER":          {},
	"NVARCHAR2":       {},
	"OF":              {},
	"OFFLINE":         {},
	"ON":              {},
	"ONLINE":          {},
	"OPTION":          {},
	"OR":              {},
	"ORDER":           {},
	"OUT":             {},
	"OVERLAPS":        {},
	"PCTFREE":         {},
	"PRAGMA":          {},
	"PRIOR":           {},
	"PRIVILEGES":      {},
	"PROCEDURE":       {},
	"PUBLIC":          {},
	"RAISE":           {},
	"RAW":             {},
	"RECORD":          {},
	"REF":             {},
	"RELEASE":         {},
	"RENAME":          {},
	"RESOURCE":        {},
	"RETURN":          {},
	"REVOKE":          {},
	"ROLE":            {},
	"ROLLBACK":        {},
	"ROW":             {},
	"ROWID":           {},
	"ROWNUM":          {},
	"ROWS":            {},
	"SAVEPOINT":       {},
	"SCHEMA":          {},
	"SELECT":          {},
	"SEPARATE":        {},
	"SESSION":         {},
	"SET":             {},
	"SHARE":           {},
	"SIZE":            {},
	"SMALLINT":        {},
	"SQL":             {},
	"START":           {},
	"STATUS":          {},
	"SUBTYPE":         {},
	"SUCCESSFUL":      {},
	"SYNONYM":         {},
	"SYSDATE":         {},
	"SYSTIMESTAMP":    {},
	"TABAUTH":         {},
	"TABLE":           {},
	"THEN":            {},
	"TO":              {},
	"TRIGGER":         {},
	"TYPE":            {},
	"UID":             {},
	"UNION":           {},
	"UNIQUE":          {},
	"UPDATE":          {},
	"USER":            {},
	"VALIDATE":        {},
	"VALUES":          {},
	"VARCHAR":         {},
	"VARCHAR2":        {},
	"VIEW":            {},
	"VIEWS":           {},
	"WHEN":            {},
	"WHENEVER":        {},
	"WHERE":           {},
	"WHILE":           {},
	"WITH":            {},
}

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

func (d *oracleDriver) Ping(ctx context.Context) error {
	return d.db.PingContext(ctx)
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
	if strings.IndexAny(raw, ": \t\n\r\f\v") < 0 {
		if strings.EqualFold(raw, "null") {
			return nil
		}
		return raw
	}

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

	rewritePlan, rewriteErr := prepareOracleBindRewrite(query, binds)
	if rewriteErr != nil {
		return nil, fmt.Errorf("oracle bind validation: %w", rewriteErr)
	}
	isPLSQLQuery := isPLSQL(query)
	hasReturning := strings.Contains(strings.ToLower(query), " returning ")
	isExecQuery := isExecStatement(query)

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
	if isPLSQLQuery {
		result, err := d.executePLSQLLocked(queryCtx, conn, rewritePlan, binds)
		cancel()
		return result, err
	}

	// Exec path: statements that don't return result sets
	if isExecQuery && !hasReturning {
		res, err := conn.ExecContext(queryCtx, rewritePlan.rewrittenSQL, rewritePlan.bindArgs...)
		if err != nil {
			if isSessionConnError(err) {
				d.resetSessionConnLocked()
			}
			d.mu.Unlock()
			cancel()
			return nil, wrapOracleError(err, rewritePlan.mapping)
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
	result, err := d.c.QueryOnConn(queryCtx, conn, rewritePlan.rewrittenSQL, rewritePlan.bindArgs...)
	if err != nil {
		if isSessionConnError(err) {
			d.resetSessionConnLocked()
		}
		d.mu.Unlock()
		cancel()
		return nil, wrapOracleError(err, rewritePlan.mapping)
	}
	result.AddCallback(func() { d.mu.Unlock() }) // release gate when rows drained
	result.AddCallback(cancel)
	return result, nil
}

// executePLSQLLocked handles PL/SQL block execution with DBMS_OUTPUT capture.
// Uses the session-pinned connection for all operations.
// Caller MUST hold d.mu. This method releases it via defer.
func (d *oracleDriver) executePLSQLLocked(ctx context.Context, conn *sql.Conn, rewritePlan oracleBindRewritePlan, binds map[string]string) (core.ResultStream, error) {
	defer d.mu.Unlock()

	// Cursor-shaped markers must validate before any DBMS_OUTPUT side effect,
	// including malformed shapes that the strict cursor extractor rejects.
	if rewritePlan.hasCursor {
		return d.executePLSQLWithCursor(ctx, conn, rewritePlan, binds)
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
	plsqlQuery := stripTrailingSQLPlusSlashTerminator(rewritePlan.rewrittenSQL)
	isCall := strings.HasPrefix(strings.ToUpper(stripLeadingSQLComments(plsqlQuery)), "CALL ")
	if !isCall && !strings.HasSuffix(strings.TrimSpace(plsqlQuery), ";") {
		plsqlQuery += ";"
	}
	_, err = conn.ExecContext(ctx, plsqlQuery, rewritePlan.bindArgs...)
	if err != nil {
		if isSessionConnError(err) {
			d.resetSessionConnLocked()
		}
		return nil, wrapOracleError(err, rewritePlan.mapping)
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
		_, err := conn.ExecContext(ctx, `BEGIN DBMS_OUTPUT.GET_LINE(:p_line, :p_status); END;`,
			sql.Named("p_line", sql.Out{Dest: &line}),
			sql.Named("p_status", sql.Out{Dest: &status}))
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

const oracleColumnsRichSQL = `
	SELECT col.column_name,
	       col.data_type,
	       col.nullable
	FROM all_tab_columns col
	WHERE col.owner = :p_schema
	  AND col.table_name = :p_table
	ORDER BY col.column_id`

const oraclePrimaryKeysSQL = `
	SELECT acc.column_name,
	       acc.position
	FROM all_constraints ac
	JOIN all_cons_columns acc
	  ON ac.owner = acc.owner
	 AND ac.constraint_name = acc.constraint_name
	WHERE ac.constraint_type = 'P'
	  AND ac.owner = :p_schema
	  AND ac.table_name = :p_table
	ORDER BY acc.position`

const oracleForeignKeysSQL = `
	SELECT ac.constraint_name,
	       acc.column_name AS source_column,
	       acc.position AS ordinal,
	       rac.owner AS target_schema,
	       rac.table_name AS target_table,
	       racc.column_name AS target_column
	FROM all_constraints ac
	JOIN all_cons_columns acc
	  ON ac.owner = acc.owner
	 AND ac.constraint_name = acc.constraint_name
	JOIN all_constraints rac
	  ON ac.r_owner = rac.owner
	 AND ac.r_constraint_name = rac.constraint_name
	JOIN all_cons_columns racc
	  ON rac.owner = racc.owner
	 AND rac.constraint_name = racc.constraint_name
	 AND racc.position = acc.position
	WHERE ac.constraint_type = 'R'
	  AND ac.owner = :p_schema
	  AND ac.table_name = :p_table
	ORDER BY ac.constraint_name, acc.position`

const oracleIndexesSQL = `
	SELECT i.index_name,
	       i.owner AS index_owner,
	       i.table_owner,
	       i.table_name,
	       i.uniqueness,
	       ic.column_name,
	       ic.descend,
	       ic.column_position,
	       CASE WHEN ac.constraint_name IS NULL THEN 0 ELSE 1 END AS pk_backed
	FROM all_indexes i
	JOIN all_ind_columns ic
	  ON ic.index_owner = i.owner
	 AND ic.index_name = i.index_name
	LEFT JOIN all_constraints ac
	  ON ac.owner = i.table_owner
	 AND ac.table_name = i.table_name
	 AND ac.index_owner = i.owner
	 AND ac.index_name = i.index_name
	 AND ac.constraint_type = 'P'
	WHERE i.table_owner = :p_schema
	  AND i.table_name = :p_table
	ORDER BY i.index_name, ic.column_position`

const oracleSequencesSQL = `
	SELECT sequence_name, increment_by, cache_size
	FROM all_sequences
	WHERE sequence_owner = :p_schema
	ORDER BY sequence_name`

func (d *oracleDriver) SupportsRichMetadata() core.RichMetadataSupport {
	return core.RichMetadataSupport{
		Columns:   true,
		Indexes:   true,
		Sequences: true,
	}
}

func (d *oracleDriver) ColumnsRich(opts *core.TableOptions) ([]*core.Column, error) {
	if opts == nil {
		return nil, fmt.Errorf("opts cannot be nil")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	rows, err := d.c.QueryWithArgs(ctx, oracleColumnsRichSQL, sql.Named("p_schema", opts.Schema), sql.Named("p_table", opts.Table))
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	columns := []*core.Column{}
	byName := map[string]*core.Column{}
	for rows.HasNext() {
		row, err := rows.Next()
		if err != nil {
			return nil, err
		}
		if len(row) < 3 {
			return nil, fmt.Errorf("oracle columns rich: expected 3 columns, got %d", len(row))
		}
		name, err := oracleStringValue(row[0])
		if err != nil {
			return nil, fmt.Errorf("oracle columns rich column name: %w", err)
		}
		typ, err := oracleStringValue(row[1])
		if err != nil {
			return nil, fmt.Errorf("oracle columns rich data type: %w", err)
		}
		nullableRaw, err := oracleStringValue(row[2])
		if err != nil {
			return nil, fmt.Errorf("oracle columns rich nullable: %w", err)
		}
		nullable := !strings.EqualFold(nullableRaw, "N")
		col := &core.Column{
			Name:     name,
			Type:     typ,
			Nullable: &nullable,
		}
		columns = append(columns, col)
		byName[name] = col
	}

	if err := d.applyOraclePrimaryKeys(ctx, opts, byName); err != nil {
		return nil, err
	}
	if err := d.applyOracleForeignKeys(ctx, opts, byName); err != nil {
		return nil, err
	}

	return columns, nil
}

func (d *oracleDriver) applyOraclePrimaryKeys(ctx context.Context, opts *core.TableOptions, byName map[string]*core.Column) error {
	rows, err := d.c.QueryWithArgs(ctx, oraclePrimaryKeysSQL, sql.Named("p_schema", opts.Schema), sql.Named("p_table", opts.Table))
	if err != nil {
		return err
	}
	defer rows.Close()

	for rows.HasNext() {
		row, err := rows.Next()
		if err != nil {
			return err
		}
		if len(row) < 2 {
			return fmt.Errorf("oracle primary keys: expected 2 columns, got %d", len(row))
		}
		name, err := oracleStringValue(row[0])
		if err != nil {
			return fmt.Errorf("oracle primary key column name: %w", err)
		}
		position, err := oracleIntValue(row[1])
		if err != nil {
			return fmt.Errorf("oracle primary key position: %w", err)
		}
		if col := byName[name]; col != nil {
			col.PrimaryKey = true
			col.PrimaryKeyOrdinal = position
		}
	}
	return nil
}

type oracleFKRow struct {
	constraintName string
	sourceColumn   string
	ordinal        int
	targetSchema   string
	targetTable    string
	targetColumn   string
}

func (d *oracleDriver) applyOracleForeignKeys(ctx context.Context, opts *core.TableOptions, byName map[string]*core.Column) error {
	rows, err := d.c.QueryWithArgs(ctx, oracleForeignKeysSQL, sql.Named("p_schema", opts.Schema), sql.Named("p_table", opts.Table))
	if err != nil {
		return err
	}
	defer rows.Close()

	groups := map[string][]oracleFKRow{}
	for rows.HasNext() {
		row, err := rows.Next()
		if err != nil {
			return err
		}
		if len(row) < 6 {
			return fmt.Errorf("oracle foreign keys: expected 6 columns, got %d", len(row))
		}
		constraintName, err := oracleStringValue(row[0])
		if err != nil {
			return fmt.Errorf("oracle foreign key constraint: %w", err)
		}
		sourceColumn, err := oracleStringValue(row[1])
		if err != nil {
			return fmt.Errorf("oracle foreign key source column: %w", err)
		}
		ordinal, err := oracleIntValue(row[2])
		if err != nil {
			return fmt.Errorf("oracle foreign key ordinal: %w", err)
		}
		targetSchema, err := oracleStringValue(row[3])
		if err != nil {
			return fmt.Errorf("oracle foreign key target schema: %w", err)
		}
		targetTable, err := oracleStringValue(row[4])
		if err != nil {
			return fmt.Errorf("oracle foreign key target table: %w", err)
		}
		targetColumn, err := oracleStringValue(row[5])
		if err != nil {
			return fmt.Errorf("oracle foreign key target column: %w", err)
		}
		groups[constraintName] = append(groups[constraintName], oracleFKRow{
			constraintName: constraintName,
			sourceColumn:   sourceColumn,
			ordinal:        ordinal,
			targetSchema:   targetSchema,
			targetTable:    targetTable,
			targetColumn:   targetColumn,
		})
	}

	for constraintName, group := range groups {
		sort.SliceStable(group, func(i, j int) bool {
			return group[i].ordinal < group[j].ordinal
		})
		sourceColumns := make([]string, len(group))
		targetColumns := make([]string, len(group))
		for i, fk := range group {
			sourceColumns[i] = fk.sourceColumn
			targetColumns[i] = fk.targetColumn
		}
		for _, fk := range group {
			col := byName[fk.sourceColumn]
			if col == nil {
				continue
			}
			ref := &core.FKRef{
				ConstraintName: constraintName,
				SourceSchema:   opts.Schema,
				SourceTable:    opts.Table,
				SourceColumn:   fk.sourceColumn,
				SourceColumns:  cloneStrings(sourceColumns),
				SourceOrdinal:  fk.ordinal,
				TargetSchema:   fk.targetSchema,
				TargetTable:    fk.targetTable,
				TargetColumn:   fk.targetColumn,
				TargetColumns:  cloneStrings(targetColumns),
			}
			col.ForeignKeys = append(col.ForeignKeys, ref)
		}
	}

	return nil
}

func (d *oracleDriver) Indexes(opts *core.TableOptions) ([]*core.Index, error) {
	if opts == nil {
		return nil, fmt.Errorf("opts cannot be nil")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	rows, err := d.c.QueryWithArgs(ctx, oracleIndexesSQL, sql.Named("p_schema", opts.Schema), sql.Named("p_table", opts.Table))
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	type indexedRow struct {
		key      string
		position int
		column   string
		order    string
	}

	byKey := map[string]*core.Index{}
	var ordered []*core.Index
	var indexedRows []indexedRow
	for rows.HasNext() {
		row, err := rows.Next()
		if err != nil {
			return nil, err
		}
		if len(row) < 9 {
			return nil, fmt.Errorf("oracle indexes: expected 9 columns, got %d", len(row))
		}
		name, err := oracleStringValue(row[0])
		if err != nil {
			return nil, fmt.Errorf("oracle index name: %w", err)
		}
		owner, err := oracleStringValue(row[1])
		if err != nil {
			return nil, fmt.Errorf("oracle index owner: %w", err)
		}
		tableOwner, err := oracleStringValue(row[2])
		if err != nil {
			return nil, fmt.Errorf("oracle index table owner: %w", err)
		}
		tableName, err := oracleStringValue(row[3])
		if err != nil {
			return nil, fmt.Errorf("oracle index table name: %w", err)
		}
		uniqueness, err := oracleStringValue(row[4])
		if err != nil {
			return nil, fmt.Errorf("oracle index uniqueness: %w", err)
		}
		column, err := oracleStringValue(row[5])
		if err != nil {
			return nil, fmt.Errorf("oracle index column: %w", err)
		}
		order, err := oracleStringValue(row[6])
		if err != nil {
			return nil, fmt.Errorf("oracle index order: %w", err)
		}
		position, err := oracleIntValue(row[7])
		if err != nil {
			return nil, fmt.Errorf("oracle index column position: %w", err)
		}
		pkBacked, err := oracleBoolValue(row[8])
		if err != nil {
			return nil, fmt.Errorf("oracle index pk_backed: %w", err)
		}

		key := owner + "." + name
		index := byKey[key]
		if index == nil {
			index = &core.Index{
				Name:     name,
				Schema:   tableOwner,
				Table:    tableName,
				Unique:   strings.EqualFold(uniqueness, "UNIQUE"),
				PKBacked: pkBacked,
			}
			byKey[key] = index
			ordered = append(ordered, index)
		}
		indexedRows = append(indexedRows, indexedRow{
			key:      key,
			position: position,
			column:   column,
			order:    oracleIndexOrder(order),
		})
	}

	sort.SliceStable(indexedRows, func(i, j int) bool {
		if indexedRows[i].key == indexedRows[j].key {
			return indexedRows[i].position < indexedRows[j].position
		}
		return indexedRows[i].key < indexedRows[j].key
	})
	for _, row := range indexedRows {
		index := byKey[row.key]
		index.Columns = append(index.Columns, row.column)
		index.Orders = append(index.Orders, row.order)
	}

	return ordered, nil
}

func (d *oracleDriver) Sequences(schema string) ([]*core.Sequence, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	rows, err := d.c.QueryWithArgs(ctx, oracleSequencesSQL, sql.Named("p_schema", schema))
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var sequences []*core.Sequence
	for rows.HasNext() {
		row, err := rows.Next()
		if err != nil {
			return nil, err
		}
		if len(row) < 3 {
			return nil, fmt.Errorf("oracle sequences: expected 3 columns, got %d", len(row))
		}
		name, err := oracleStringValue(row[0])
		if err != nil {
			return nil, fmt.Errorf("oracle sequence name: %w", err)
		}
		increment, err := oracleInt64Value(row[1])
		if err != nil {
			return nil, fmt.Errorf("oracle sequence increment: %w", err)
		}
		cacheSize, err := oracleInt64Value(row[2])
		if err != nil {
			return nil, fmt.Errorf("oracle sequence cache size: %w", err)
		}
		sequences = append(sequences, &core.Sequence{
			Name:      name,
			Schema:    schema,
			Increment: increment,
			CacheSize: cacheSize,
		})
	}
	return sequences, nil
}

func oracleStringValue(value any) (string, error) {
	switch v := value.(type) {
	case string:
		return v, nil
	case []byte:
		return string(v), nil
	case fmt.Stringer:
		return v.String(), nil
	case nil:
		return "", fmt.Errorf("expected string, got nil")
	default:
		return "", fmt.Errorf("expected string, got %T", value)
	}
}

func oracleIntValue(value any) (int, error) {
	n, err := oracleInt64Value(value)
	if err != nil {
		return 0, err
	}
	return int(n), nil
}

func oracleInt64Value(value any) (int64, error) {
	switch v := value.(type) {
	case int:
		return int64(v), nil
	case int8:
		return int64(v), nil
	case int16:
		return int64(v), nil
	case int32:
		return int64(v), nil
	case int64:
		return v, nil
	case uint:
		return int64(v), nil
	case uint8:
		return int64(v), nil
	case uint16:
		return int64(v), nil
	case uint32:
		return int64(v), nil
	case uint64:
		if v > math.MaxInt64 {
			return 0, fmt.Errorf("integer overflows int64: %d", v)
		}
		return int64(v), nil
	case float64:
		if math.Trunc(v) != v {
			return 0, fmt.Errorf("expected integer, got %v", v)
		}
		return int64(v), nil
	case string:
		n, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64)
		if err != nil {
			return 0, err
		}
		return n, nil
	case []byte:
		n, err := strconv.ParseInt(strings.TrimSpace(string(v)), 10, 64)
		if err != nil {
			return 0, err
		}
		return n, nil
	default:
		return 0, fmt.Errorf("expected integer, got %T", value)
	}
}

func oracleBoolValue(value any) (bool, error) {
	switch v := value.(type) {
	case bool:
		return v, nil
	case int:
		return v != 0, nil
	case int64:
		return v != 0, nil
	case float64:
		return v != 0, nil
	case string:
		trimmed := strings.TrimSpace(strings.ToUpper(v))
		return trimmed == "1" || trimmed == "Y" || trimmed == "YES" || trimmed == "TRUE", nil
	case []byte:
		return oracleBoolValue(string(v))
	default:
		return false, fmt.Errorf("expected bool-ish value, got %T", value)
	}
}

func oracleIndexOrder(descend string) string {
	if strings.EqualFold(strings.TrimSpace(descend), "DESC") {
		return "DESC"
	}
	return "ASC"
}

func cloneStrings(values []string) []string {
	if len(values) == 0 {
		return nil
	}
	out := make([]string, len(values))
	copy(out, values)
	return out
}

func (d *oracleDriver) Structure() ([]*core.Structure, error) {
	return d.StructureWithOptions(nil)
}

func oracleArmWhere(extra string, predicate string) string {
	parts := []string{"owner IN (SELECT username FROM all_users WHERE common = 'NO')"}
	if extra != "" {
		parts = append(parts, extra)
	}
	if predicate != "" {
		parts = append(parts, predicate)
	}
	return " WHERE " + strings.Join(parts, " AND ")
}

func oracleStructureQuery(predicates []string) string {
	armPredicate := func(index int) string {
		if index < len(predicates) {
			return predicates[index]
		}
		return ""
	}
	return `
			SELECT owner, object_name, object_type
			FROM (
				SELECT owner, table_name as object_name, 'TABLE' as object_type
				FROM all_tables` + oracleArmWhere("", armPredicate(0)) + `
				UNION ALL
				SELECT owner, table_name as object_name, 'EXTERNAL TABLE' as object_type
				FROM all_external_tables` + oracleArmWhere("", armPredicate(1)) + `
				UNION ALL
				SELECT owner, view_name as object_name, 'VIEW' as object_type
				FROM all_views` + oracleArmWhere("", armPredicate(2)) + `
				UNION ALL
				SELECT owner, mview_name as object_name, 'MATERIALIZED VIEW' as object_type
				FROM all_mviews` + oracleArmWhere("", armPredicate(3)) + `
				UNION ALL
				SELECT owner, object_name, object_type
				FROM all_objects
				` + oracleArmWhere("object_type IN ('PROCEDURE', 'FUNCTION')", armPredicate(4)) + `
			)
			ORDER BY owner, object_name
		`
}

func (d *oracleDriver) StructureWithOptions(opts *core.StructureOptions) ([]*core.Structure, error) {
	predicates := make([]string, 5)
	args := []any{}
	next := 1
	for index := range predicates {
		var armArgs []any
		predicates[index], armArgs, next = schemaPredicate("owner", opts, schemaDialectOracle, next)
		args = append(args, armArgs...)
	}
	query := oracleStructureQuery(predicates)

	// Use pool connection, not session conn. Structure queries are fully
	// schema-qualified and don't need session state. Using pool avoids
	// blocking drawer refresh behind a running query.
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	rows, err := d.c.QueryWithArgs(ctx, query, args...)
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

func (d *oracleDriver) ListSchemas() ([]*core.SchemaInfo, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	rows, err := d.c.QueryWithArgs(ctx, `
		SELECT username
		FROM all_users
		WHERE common = 'NO'
		ORDER BY username`)
	if err != nil {
		return nil, err
	}
	return schemasFromRows(rows)
}

func (d *oracleDriver) StructureForSchema(schema string, opts *core.StructureOptions) ([]*core.Structure, error) {
	if !schemaAllowedByOptions(schema, opts) {
		return []*core.Structure{}, nil
	}
	predicates := make([]string, 5)
	args := make([]any, 0, len(predicates))
	for index := range predicates {
		predicates[index] = fmt.Sprintf("owner = :%d", index+1)
		args = append(args, schema)
	}
	query := oracleStructureQuery(predicates)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	rows, err := d.c.QueryWithArgs(ctx, query, args...)
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

	structure, err := oracleGroupedStructure(rows, decodeStructureType)
	if err != nil {
		return nil, err
	}
	return schemaObjectsFromStructure(structure, schema), nil
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
