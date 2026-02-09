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
		c:  builders.NewClient(db),
		db: db,
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

	helpers := map[string]string{
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
      WHEN in_out IN ('OUT', 'IN/OUT') THEN
        '  v_' || LOWER(argument_name) || ' ' ||
        CASE
          WHEN data_type = 'REF CURSOR' THEN 'SYS_REFCURSOR;' || CHR(10) ||
            '  -- Cursor fetch variables (adjust types to match cursor columns):' || CHR(10) ||
            '  v_col1 VARCHAR2(4000);' || CHR(10) ||
            '  v_col2 VARCHAR2(4000)'
          WHEN data_type IN ('VARCHAR2', 'CHAR', 'NVARCHAR2') THEN data_type || '(4000)'
          ELSE data_type
        END || ';'
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
      WHEN in_out IN ('OUT', 'IN/OUT') AND data_type = 'REF CURSOR' THEN
        '  -- Fetch from cursor (adjust v_col variables to match cursor columns):' || CHR(10) ||
        '  LOOP' || CHR(10) ||
        '    FETCH v_' || LOWER(argument_name) || ' INTO v_col1, v_col2;' || CHR(10) ||
        '    EXIT WHEN v_' || LOWER(argument_name) || '%%NOTFOUND;' || CHR(10) ||
        '    DBMS_OUTPUT.PUT_LINE(v_col1 || ''|'' || v_col2);' || CHR(10) ||
        '  END LOOP;' || CHR(10) ||
        '  CLOSE v_' || LOWER(argument_name) || ';'
      WHEN in_out IN ('OUT', 'IN/OUT') THEN
        '  DBMS_OUTPUT.PUT_LINE(''' || LOWER(argument_name) || ': '' || v_' || LOWER(argument_name) || ');'
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

	if opts.Materialization == core.StructureTypeProcedure || opts.Materialization == core.StructureTypeFunction {
		objectType := "PROCEDURE"
		if opts.Materialization == core.StructureTypeFunction {
			objectType = "FUNCTION"
		}

		helpers["Source"] = fmt.Sprintf(`
			SELECT text AS source_line
			FROM all_source
			WHERE owner = '%s'
				AND name = '%s'
				AND type = '%s'
			ORDER BY line`,

			opts.Schema,
			opts.Table,
			objectType,
		)

		helpers["Arguments"] = fmt.Sprintf(`
			SELECT position, argument_name, in_out, data_type, data_length, data_precision, data_scale
			FROM all_arguments
			WHERE owner = '%s'
				AND object_name = '%s'
				AND argument_name IS NOT NULL
			ORDER BY position`,

			opts.Schema,
			opts.Table,
		)
	}

	var ddlObjectType string
	switch opts.Materialization {
	case core.StructureTypeTable:
		ddlObjectType = "TABLE"
	case core.StructureTypeView:
		ddlObjectType = "VIEW"
	case core.StructureTypeProcedure:
		ddlObjectType = "PROCEDURE"
	case core.StructureTypeFunction:
		ddlObjectType = "FUNCTION"
	}
	if ddlObjectType != "" {
		helpers["DDL"] = fmt.Sprintf(
			"SELECT DBMS_METADATA.GET_DDL('%s', '%s', '%s') AS ddl FROM dual",
			ddlObjectType,
			opts.Table,
			opts.Schema,
		)
	}

	return helpers
}
