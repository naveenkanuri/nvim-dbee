package adapters

import (
	"context"
	"database/sql"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/kndndrj/nvim-dbee/dbee/core/builders"
)

// oracleQueryTimeout is the default timeout for Oracle query execution.
// go-ora defaults to 30s which is too short for many queries.
const oracleQueryTimeout = 30 * time.Minute

var _ core.Driver = (*oracleDriver)(nil)
var _ core.BindDriver = (*oracleDriver)(nil)

type oracleDriver struct {
	c  *builders.Client
	db *sql.DB
}

type oracleExecContexter interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
}

func (d *oracleDriver) Query(ctx context.Context, query string) (core.ResultStream, error) {
	return d.QueryWithBinds(ctx, query, nil)
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
		args = append(args, sql.Named(name, binds[name]))
	}
	return args
}

func (d *oracleDriver) QueryWithBinds(ctx context.Context, query string, binds map[string]string) (core.ResultStream, error) {
	// Create a context with longer timeout for Oracle queries.
	// go-ora defaults to 30s which is too short for many queries.
	// The parent context can still cancel early if user requests it.
	queryCtx, cancel := context.WithTimeout(ctx, oracleQueryTimeout)

	// Remove the trailing semicolon from the query - for some reason it isn't supported in go_ora
	query = strings.TrimSpace(query)
	query = strings.TrimSuffix(query, ";")

	// Check if this is a PL/SQL block
	if isPLSQL(query) {
		result, err := d.executePLSQL(queryCtx, query, binds)
		cancel()
		return result, err
	}

	bindArgs := oracleNamedArgs(binds)

	// Use Exec or Query depending on the query
	action := strings.ToLower(strings.Split(query, " ")[0])
	hasReturnValues := strings.Contains(strings.ToLower(query), " returning ")
	if (action == "update" || action == "delete" || action == "insert") && !hasReturnValues {
		result, err := d.c.ExecWithArgs(queryCtx, query, bindArgs...)
		if err != nil {
			cancel()
			return nil, err
		}
		result.AddCallback(cancel)
		return result, nil
	}

	result, err := d.c.QueryUntilNotEmptyWithArgs(queryCtx, bindArgs, query)
	if err != nil {
		cancel()
		return nil, err
	}
	result.AddCallback(cancel)
	return result, nil
}

// executePLSQL handles PL/SQL block execution with DBMS_OUTPUT capture.
// Uses a dedicated connection to ensure all operations happen in the same Oracle session,
// since DBMS_OUTPUT is session-scoped.
// If the query contains /*CURSOR*/ markers, returns cursor results as a grid.
func (d *oracleDriver) executePLSQL(ctx context.Context, query string, binds map[string]string) (core.ResultStream, error) {
	// Check for cursor markers - if present, use cursor execution path
	if hasCursorMarker(query) {
		return d.executePLSQLWithCursor(ctx, query, binds)
	}

	// Get a dedicated connection from the pool - CRITICAL for DBMS_OUTPUT
	// which is session-scoped. All operations must happen on the same connection.
	conn, err := d.db.Conn(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get connection: %w", err)
	}
	defer conn.Close()

	// Step 1: Enable DBMS_OUTPUT with unlimited buffer (uses session memory)
	_, err = conn.ExecContext(ctx, "BEGIN DBMS_OUTPUT.ENABLE(NULL); END;")
	if err != nil {
		return nil, fmt.Errorf("failed to enable DBMS_OUTPUT: %w", err)
	}

	// Step 2: Execute the PL/SQL block
	// Note: Query() strips trailing semicolons, but PL/SQL blocks need them.
	// Exception: CALL statements don't use semicolons in Oracle.
	plsqlQuery := stripTrailingSQLPlusSlashTerminator(query)
	isCall := strings.HasPrefix(strings.ToUpper(stripLeadingSQLComments(plsqlQuery)), "CALL ")
	if !isCall && !strings.HasSuffix(strings.TrimSpace(plsqlQuery), ";") {
		plsqlQuery += ";"
	}
	_, err = conn.ExecContext(ctx, plsqlQuery, oracleNamedArgs(binds)...)
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

func (d *oracleDriver) Close() { d.c.Close() }
