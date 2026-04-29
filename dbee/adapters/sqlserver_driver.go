package adapters

import (
	"context"
	"database/sql"
	"fmt"
	nurl "net/url"
	"time"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/kndndrj/nvim-dbee/dbee/core/builders"
)

var (
	_ core.Driver                  = (*sqlServerDriver)(nil)
	_ core.FilteredStructureDriver = (*sqlServerDriver)(nil)
	_ core.SchemaListDriver        = (*sqlServerDriver)(nil)
	_ core.SchemaStructureDriver   = (*sqlServerDriver)(nil)
	_ core.DatabaseSwitcher        = (*sqlServerDriver)(nil)
)

type sqlServerDriver struct {
	c   *builders.Client
	url *nurl.URL
}

func (c *sqlServerDriver) Query(ctx context.Context, query string) (core.ResultStream, error) {
	// run query, fallback to affected rows
	return c.c.QueryUntilNotEmpty(ctx, query, "select @@ROWCOUNT as 'Rows Affected'")
}

func (c *sqlServerDriver) Ping(ctx context.Context) error {
	return c.c.PingContext(ctx)
}

func (c *sqlServerDriver) Columns(opts *core.TableOptions) ([]*core.Column, error) {
	return c.c.ColumnsFromQuery(`
		SELECT
			column_name,
			data_type
		FROM information_schema.columns
			WHERE table_name='%s' AND
			table_schema = '%s'`,
		opts.Table,
		opts.Schema,
	)
}

func (c *sqlServerDriver) Structure() ([]*core.Structure, error) {
	return c.StructureWithOptions(nil)
}

func (c *sqlServerDriver) StructureWithOptions(opts *core.StructureOptions) ([]*core.Structure, error) {
	where, args, _ := schemaPredicate("table_schema", opts, schemaDialectSQLServer, 1)
	if where != "" {
		where = " WHERE " + where
	}
	query := `
    SELECT table_schema, table_name, table_type
    FROM INFORMATION_SCHEMA.TABLES` + where + `
    ORDER BY table_schema, table_name`

	rows, err := c.c.QueryWithArgs(context.TODO(), query, args...)
	if err != nil {
		return nil, err
	}

	return core.GetGenericStructure(rows, getPGStructureType)
}

func (c *sqlServerDriver) ListSchemas() ([]*core.SchemaInfo, error) {
	rows, err := c.c.QueryWithArgs(context.TODO(), `
		SELECT name
		FROM sys.schemas
		ORDER BY name`)
	if err != nil {
		return nil, err
	}
	return schemasFromRows(rows)
}

func (c *sqlServerDriver) StructureForSchema(schema string, opts *core.StructureOptions) ([]*core.Structure, error) {
	if !schemaAllowedByOptions(schema, opts) {
		return []*core.Structure{}, nil
	}
	rows, err := c.c.QueryWithArgs(
		context.TODO(),
		`SELECT table_schema, table_name, table_type
		FROM INFORMATION_SCHEMA.TABLES
		WHERE table_schema = @p1
		ORDER BY table_schema, table_name`,
		schema,
	)
	if err != nil {
		return nil, err
	}
	structure, err := core.GetGenericStructure(rows, getPGStructureType)
	if err != nil {
		return nil, err
	}
	return schemaObjectsFromStructure(structure, schema), nil
}

func (c *sqlServerDriver) Close() {
	c.c.Close()
}

func (c *sqlServerDriver) ListDatabases() (current string, available []string, err error) {
	query := `
		SELECT DB_NAME(), name
		FROM sys.databases
		WHERE name != DB_NAME();
	`

	rows, err := c.Query(context.TODO(), query)
	if err != nil {
		return "", nil, err
	}

	for rows.HasNext() {
		row, err := rows.Next()
		if err != nil {
			return "", nil, err
		}

		// We know for a fact there are 2 string fields (see query above)
		current = row[0].(string)
		available = append(available, row[1].(string))
	}

	return current, available, nil
}

func (c *sqlServerDriver) SelectDatabase(name string) error {
	q := c.url.Query()
	q.Set("database", name)
	c.url.RawQuery = q.Encode()

	db, err := sql.Open("sqlserver", c.url.String())
	if err != nil {
		return fmt.Errorf("unable to switch databases: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := db.PingContext(ctx); err != nil {
		return fmt.Errorf("unable to switch databases: %w", err)
	}

	c.c.Swap(db)

	return nil
}
