package adapters

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestPostgresForeignKeysSQLRowsFromShape(t *testing.T) {
	require.Contains(t, postgresColumnsRichSQL, "pg_catalog.pg_attribute")
	require.Contains(t, postgresColumnsRichSQL, "pg_catalog.pg_get_expr")

	require.Contains(t, postgresPrimaryKeysSQL, "pg_catalog.pg_constraint")
	require.Contains(t, postgresPrimaryKeysSQL, "con.contype = 'p'")

	require.Contains(t, postgresForeignKeysSQL, "ROWS FROM (")
	require.Contains(t, postgresForeignKeysSQL, "pg_catalog.unnest(con.conkey)")
	require.Contains(t, postgresForeignKeysSQL, "pg_catalog.unnest(con.confkey)")
	require.Contains(t, postgresForeignKeysSQL, "WITH ORDINALITY AS fk(source_attnum, target_attnum, ordinal)")
	require.NotContains(t, postgresForeignKeysSQL, "pg_catalog.unnest(con.conkey, con.confkey)")

	require.Contains(t, postgresIndexesSQL, "pg_catalog.pg_index")
	require.Contains(t, postgresIndexesSQL, "table_cls.relkind IN ('r', 'p', 'v', 'm')")

	require.Contains(t, postgresSequencesSQL, "pg_catalog.pg_sequence")

	t.Log("LIVE_PG20_SQL_SHAPE_PREFLIGHT_OK=true")
}
