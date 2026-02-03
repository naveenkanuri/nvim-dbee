package adapters

import (
	"context"
	"fmt"
	"strings"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/kndndrj/nvim-dbee/dbee/core/builders"
)

var _ core.Driver = (*oracleDriver)(nil)

type oracleDriver struct {
	c *builders.Client
}

func (d *oracleDriver) Query(ctx context.Context, query string) (core.ResultStream, error) {
	// Remove the trailing semicolon from the query - for some reason it isn't supported in go_ora
	query = strings.TrimSuffix(query, ";")

	// Check if this is a PL/SQL block
	if isPLSQL(query) {
		return d.executePLSQL(ctx, query)
	}

	// Use Exec or Query depending on the query
	action := strings.ToLower(strings.Split(query, " ")[0])
	hasReturnValues := strings.Contains(strings.ToLower(query), " returning ")
	if (action == "update" || action == "delete" || action == "insert") && !hasReturnValues {
		return d.c.Exec(ctx, query)
	}

	return d.c.QueryUntilNotEmpty(ctx, query)
}

// executePLSQL handles PL/SQL block execution with DBMS_OUTPUT capture.
// NOTE: This requires all database calls to execute on the same session/connection.
// With the default go-ora connection pool settings, this typically works because
// connections are reused for sequential operations. If you encounter empty output,
// ensure your connection pool is not configured for multiple concurrent connections.
func (d *oracleDriver) executePLSQL(ctx context.Context, query string) (core.ResultStream, error) {
	// Step 1: Enable DBMS_OUTPUT with 1MB buffer
	_, err := d.c.Exec(ctx, "BEGIN DBMS_OUTPUT.ENABLE(1000000); END")
	if err != nil {
		return nil, fmt.Errorf("failed to enable DBMS_OUTPUT: %w", err)
	}

	// Step 2: Execute the PL/SQL block
	_, err = d.c.Exec(ctx, query)
	if err != nil {
		return nil, err
	}

	// Step 3: Fetch DBMS_OUTPUT lines
	output, err := d.fetchDBMSOutput(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch DBMS_OUTPUT: %w", err)
	}

	// Step 4: Return output as result stream
	lines := parseDBMSOutputLines(output)
	return buildDBMSOutputResultStream(lines), nil
}

// fetchDBMSOutput retrieves all lines from the DBMS_OUTPUT buffer using GET_LINE in a loop.
func (d *oracleDriver) fetchDBMSOutput(ctx context.Context) (string, error) {
	var output strings.Builder

	for {
		// Fetch one line at a time using GET_LINE
		// The query returns line text and status (0=success, 1=no more lines)
		result, err := d.c.Query(ctx, `
			SELECT line, status FROM (
				SELECT DBMS_OUTPUT.GET_LINE(line, status) AS dummy, line, status
				FROM (SELECT CAST(NULL AS VARCHAR2(32767)) AS line, CAST(NULL AS INTEGER) AS status FROM dual)
			)`)
		if err != nil {
			// If we can't fetch, return what we have
			return output.String(), nil
		}

		// Read the result
		if !result.HasNext() {
			result.Close()
			break
		}

		row, err := result.Next()
		result.Close()
		if err != nil || len(row) < 2 {
			break
		}

		// Check status - if not "0", no more lines
		status, ok := row[1].(string)
		if !ok || status != "0" {
			break
		}

		// Append the line
		if line, ok := row[0].(string); ok && line != "" {
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
