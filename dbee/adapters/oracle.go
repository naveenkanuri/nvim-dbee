package adapters

import (
	"database/sql"
	"fmt"

	_ "github.com/sijms/go-ora/v2"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/kndndrj/nvim-dbee/dbee/core/builders"
)

// Register client
func init() {
	_ = register(&Oracle{}, "oracle")
}

var _ core.Adapter = (*Oracle)(nil)

type Oracle struct{}

func (o *Oracle) Connect(url string) (core.Driver, error) {
	db, err := sql.Open("oracle", url)
	if err != nil {
		return nil, fmt.Errorf("unable to connect to oracle database: %v", err)
	}

	return &oracleDriver{
		c: builders.NewClient(db),
	}, nil
}

func (*Oracle) GetHelpers(opts *core.TableOptions) map[string]string {
	from := `
		FROM all_constraints N
		JOIN all_cons_columns L
		ON N.constraint_name = L.constraint_name
		AND N.owner = L.owner `

	qualifyAndOrderBy := func(by string) string {
		return fmt.Sprintf(`
			L.table_name = '%s'
			ORDER BY %s`, opts.Table, by)
	}

	keyCmd := func(constraint string) string {
		return fmt.Sprintf(`
			SELECT
			L.table_name,
			L.column_name
			%s
			WHERE
			N.constraint_type = '%s' AND %s`,

			from,
			constraint,
			qualifyAndOrderBy("L.column_name"),
		)
	}

	return map[string]string{
		"Columns": fmt.Sprintf(`SELECT col.column_id,
				col.owner AS schema_name,
				col.table_name,
				col.column_name,
				col.data_type,
				col.data_length,
				col.data_precision,
				col.data_scale,
				col.nullable
			FROM sys.all_tab_columns col
			WHERE col.owner = '%s'
				AND col.table_name = '%s'
			ORDER BY col.owner, col.table_name, col.column_id `,

			opts.Schema,
			opts.Table,
		),

		"Foreign Keys": keyCmd("R"),

		"Indexes": fmt.Sprintf(`
			SELECT DISTINCT
			N.owner,
			N.index_name,
			N.constraint_type
			%s
			WHERE %s `,

			from,
			qualifyAndOrderBy("N.index_name"),
		),

		"List": fmt.Sprintf("SELECT * FROM %q.%q", opts.Schema, opts.Table),

		"Primary Keys": keyCmd("P"),

		"References": fmt.Sprintf(`
			SELECT
			RFRING.owner,
			RFRING.table_name,
			RFRING.column_name
			FROM all_cons_columns RFRING
			JOIN all_constraints N
			ON RFRING.constraint_name = N.constraint_name
			JOIN all_cons_columns RFRD
			ON N.r_constraint_name = RFRD.constraint_name
			JOIN all_users U
			ON N.owner = U.username
			WHERE
			N.constraint_type = 'R'
			AND
			U.common = 'NO'
			AND
			RFRD.owner = '%s'
			AND
			RFRD.table_name = '%s'
			ORDER BY
			RFRING.owner,
			RFRING.table_name,
			RFRING.column_name`,

			opts.Schema,
			opts.Table,
		),

		"Generate Call": fmt.Sprintf(`
SELECT
  'DECLARE' || CHR(10) ||
  LISTAGG(
    CASE
      WHEN in_out IN ('OUT', 'IN/OUT') THEN '  v_' || LOWER(argument_name) || ' ' || data_type ||
        CASE WHEN data_type IN ('VARCHAR2', 'CHAR', 'NVARCHAR2') THEN '(4000)' ELSE '' END || ';'
      ELSE NULL
    END,
    CHR(10)
  ) WITHIN GROUP (ORDER BY position) || CHR(10) ||
  'BEGIN' || CHR(10) ||
  '  ' || '%s.' || object_name || '(' || CHR(10) ||
  LISTAGG(
    '    ' || LOWER(argument_name) || ' => ' ||
    CASE
      WHEN in_out = 'IN' THEN ':' || LOWER(argument_name)
      ELSE 'v_' || LOWER(argument_name)
    END,
    ',' || CHR(10)
  ) WITHIN GROUP (ORDER BY position) || CHR(10) ||
  '  );' || CHR(10) ||
  LISTAGG(
    CASE
      WHEN in_out IN ('OUT', 'IN/OUT') THEN '  DBMS_OUTPUT.PUT_LINE(''' || LOWER(argument_name) || ': '' || v_' || LOWER(argument_name) || ');'
      ELSE NULL
    END,
    CHR(10)
  ) WITHIN GROUP (ORDER BY position) || CHR(10) ||
  'END;' AS call_template
FROM all_arguments
WHERE owner = '%s'
  AND object_name = '%s'
  AND argument_name IS NOT NULL
GROUP BY object_name`,
			opts.Schema,
			opts.Schema,
			opts.Table,
		),
	}
}
