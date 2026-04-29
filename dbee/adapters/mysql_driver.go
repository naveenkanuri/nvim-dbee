package adapters

import (
	"context"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/kndndrj/nvim-dbee/dbee/core/builders"
)

var (
	_ core.Driver                  = (*mySQLDriver)(nil)
	_ core.FilteredStructureDriver = (*mySQLDriver)(nil)
	_ core.SchemaListDriver        = (*mySQLDriver)(nil)
	_ core.SchemaStructureDriver   = (*mySQLDriver)(nil)
)

type mySQLDriver struct {
	c *builders.Client
}

func (c *mySQLDriver) Query(ctx context.Context, query string) (core.ResultStream, error) {
	// run query, fallback to affected rows
	return c.c.QueryUntilNotEmpty(ctx, query, "select ROW_COUNT() as 'Rows Affected'")
}

func (c *mySQLDriver) Ping(ctx context.Context) error {
	return c.c.PingContext(ctx)
}

func (c *mySQLDriver) Columns(opts *core.TableOptions) ([]*core.Column, error) {
	return c.c.ColumnsFromQuery("DESCRIBE `%s`.`%s`", opts.Schema, opts.Table)
}

func (c *mySQLDriver) Structure() ([]*core.Structure, error) {
	return c.StructureWithOptions(nil)
}

func (c *mySQLDriver) StructureWithOptions(opts *core.StructureOptions) ([]*core.Structure, error) {
	where, args, _ := schemaPredicate("table_schema", opts, schemaDialectMySQL, 1)
	if where != "" {
		where = " WHERE " + where
	}
	query := `SELECT table_schema, table_name, 'TABLE' FROM information_schema.tables` + where + ` ORDER BY table_schema, table_name`

	rows, err := c.c.QueryWithArgs(context.TODO(), query, args...)
	if err != nil {
		return nil, err
	}

	return core.GetGenericStructure(rows, getPGStructureType)
}

func (c *mySQLDriver) ListSchemas() ([]*core.SchemaInfo, error) {
	rows, err := c.c.QueryWithArgs(context.TODO(), `
		SELECT schema_name
		FROM information_schema.schemata
		WHERE schema_name NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
		ORDER BY schema_name`)
	if err != nil {
		return nil, err
	}
	return schemasFromRows(rows)
}

func (c *mySQLDriver) StructureForSchema(schema string, opts *core.StructureOptions) ([]*core.Structure, error) {
	if !schemaAllowedByOptions(schema, opts) {
		return []*core.Structure{}, nil
	}
	rows, err := c.c.QueryWithArgs(
		context.TODO(),
		`SELECT table_schema, table_name, 'TABLE'
		FROM information_schema.tables
		WHERE table_schema = ?
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

func (c *mySQLDriver) Close() {
	c.c.Close()
}
