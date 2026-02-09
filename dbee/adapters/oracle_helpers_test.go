package adapters

import (
	"testing"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/stretchr/testify/assert"
)

func TestOracleGetHelpers_AddsRoutineCoverageHelpers(t *testing.T) {
	oracle := &Oracle{}

	tests := []struct {
		name          string
		material      core.StructureType
		expectedType  string
		objectName    string
		expectedTable string
	}{
		{
			name:          "procedure helpers",
			material:      core.StructureTypeProcedure,
			expectedType:  "PROCEDURE",
			objectName:    "ADDERRMSG",
			expectedTable: "ADDERRMSG",
		},
		{
			name:          "function helpers",
			material:      core.StructureTypeFunction,
			expectedType:  "FUNCTION",
			objectName:    "GETERRMSG",
			expectedTable: "GETERRMSG",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			helpers := oracle.GetHelpers(&core.TableOptions{
				Schema:          "FUSION",
				Table:           tt.objectName,
				Materialization: tt.material,
			})

			assert.Contains(t, helpers, "Generate Call")
			assert.Contains(t, helpers, "Source")
			assert.Contains(t, helpers, "Arguments")
			assert.Contains(t, helpers, "DDL")

			assert.Contains(t, helpers["Source"], "AND type = '"+tt.expectedType+"'")
			assert.Contains(t, helpers["Source"], "AND name = '"+tt.expectedTable+"'")
			assert.Contains(t, helpers["Arguments"], "FROM all_arguments")
			assert.Contains(t, helpers["DDL"], "DBMS_METADATA.GET_DDL('"+tt.expectedType+"'")
		})
	}
}

func TestOracleGetHelpers_AddsDDLForTableAndView(t *testing.T) {
	oracle := &Oracle{}

	tableHelpers := oracle.GetHelpers(&core.TableOptions{
		Schema:          "FUSION",
		Table:           "SAS_PRINCIPALS",
		Materialization: core.StructureTypeTable,
	})
	viewHelpers := oracle.GetHelpers(&core.TableOptions{
		Schema:          "FUSION",
		Table:           "SAS_PRINCIPALS_V",
		Materialization: core.StructureTypeView,
	})

	assert.Contains(t, tableHelpers, "DDL")
	assert.Contains(t, tableHelpers["DDL"], "DBMS_METADATA.GET_DDL('TABLE'")
	assert.NotContains(t, tableHelpers, "Source")
	assert.NotContains(t, tableHelpers, "Arguments")

	assert.Contains(t, viewHelpers, "DDL")
	assert.Contains(t, viewHelpers["DDL"], "DBMS_METADATA.GET_DDL('VIEW'")
	assert.NotContains(t, viewHelpers, "Source")
	assert.NotContains(t, viewHelpers, "Arguments")
}
