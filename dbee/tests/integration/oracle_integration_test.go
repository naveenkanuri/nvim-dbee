package integration

import (
	"context"
	"log"
	"testing"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	th "github.com/kndndrj/nvim-dbee/dbee/tests/testhelpers"
	"github.com/stretchr/testify/assert"
	tsuite "github.com/stretchr/testify/suite"
	tc "github.com/testcontainers/testcontainers-go"
)

// OracleTestSuite is the test suite for the oracle adapter.
type OracleTestSuite struct {
	tsuite.Suite
	ctr *th.OracleContainer
	ctx context.Context
	d   *core.Connection
}

func TestOracleTestSuite(t *testing.T) {
	tsuite.Run(t, new(OracleTestSuite))
}

func (suite *OracleTestSuite) SetupSuite() {
	suite.ctx = context.Background()
	ctr, err := th.NewOracleContainer(suite.ctx, &core.ConnectionParams{
		ID:   "test-oracle",
		Name: "test-oracle",
	})
	if err != nil {
		log.Fatal(err)
	}

	suite.ctr = ctr
	suite.d = ctr.Driver
}

func (suite *OracleTestSuite) TeardownSuite() {
	tc.CleanupContainer(suite.T(), suite.ctr)
}

func (suite *OracleTestSuite) TestShouldErrorInvalidQuery() {
	t := suite.T()

	want := "ORA-00900: invalid SQL statement"

	call := suite.d.Execute("invalid sql", func(cs core.CallState, c *core.Call) {
		if cs == core.CallStateExecutingFailed {
			assert.ErrorContains(t, c.Err(), want)
		}
	})
	assert.NotNil(t, call)
}

func (suite *OracleTestSuite) TestShouldCancelQuery() {
	t := suite.T()
	want := []core.CallState{core.CallStateExecuting, core.CallStateCanceled}

	_, got, err := th.GetResultWithCancel(t, suite.d, "SELECT 1")
	assert.NoError(t, err)

	assert.Equal(t, want, got)
}

func (suite *OracleTestSuite) TestShouldReturnManyRows() {
	t := suite.T()

	wantStates := []core.CallState{
		core.CallStateExecuting, core.CallStateRetrieving, core.CallStateArchived,
	}
	wantCols := []string{"ID", "USERNAME"}
	wantRows := []core.Row{
		{"1", "john_doe"},
		{"2", "jane_smith"},
		{"3", "bob_wilson"},
	}

	query := "SELECT ID, USERNAME FROM test_table"

	gotRows, gotCols, gotStates, err := th.GetResult(t, suite.d, query)
	assert.NoError(t, err)

	assert.ElementsMatch(t, wantCols, gotCols)
	assert.ElementsMatch(t, wantStates, gotStates)
	assert.Equal(t, wantRows, gotRows)
}

func (suite *OracleTestSuite) TestShouldReturnOneRow() {
	t := suite.T()

	wantStates := []core.CallState{
		core.CallStateExecuting, core.CallStateRetrieving, core.CallStateArchived,
	}
	wantCols := []string{"ID", "USERNAME"}
	wantRows := []core.Row{{"2", "jane_smith"}}

	query := "SELECT ID, USERNAME FROM test_view"

	gotRows, gotCols, gotStates, err := th.GetResult(t, suite.d, query)
	assert.NoError(t, err)

	assert.ElementsMatch(t, wantCols, gotCols)
	assert.ElementsMatch(t, wantStates, gotStates)
	assert.Equal(t, wantRows, gotRows)
}

func (suite *OracleTestSuite) TestShouldReturnStructure() {
	t := suite.T()

	var (
		wantSomeSchema = "TESTER"
		wantSomeTable  = "TEST_TABLE"
		wantSomeView   = "TEST_VIEW"
	)

	structure, err := suite.d.GetStructure()
	assert.NoError(t, err)

	gotSchemas := th.GetSchemas(t, structure)
	assert.Contains(t, gotSchemas, wantSomeSchema)

	gotTables := th.GetModels(t, structure, core.StructureTypeTable)
	assert.Contains(t, gotTables, wantSomeTable)

	gotViews := th.GetModels(t, structure, core.StructureTypeView)
	assert.Contains(t, gotViews, wantSomeView)
}

func (suite *OracleTestSuite) TestShouldReturnColumns() {
	t := suite.T()

	want := []*core.Column{
		{Name: "ID", Type: "NUMBER"},
		{Name: "USERNAME", Type: "VARCHAR2"},
		{Name: "EMAIL", Type: "VARCHAR2"},
	}

	got, err := suite.d.GetColumns(&core.TableOptions{
		Table:           "TEST_TABLE",
		Schema:          "TESTER",
		Materialization: core.StructureTypeTable,
	})

	assert.NoError(t, err)
	assert.Equal(t, want, got)
}

func (suite *OracleTestSuite) TestPLSQL_AnonymousBlock_WithOutput() {
	t := suite.T()

	query := `
BEGIN
  DBMS_OUTPUT.PUT_LINE('Hello from PL/SQL!');
  DBMS_OUTPUT.PUT_LINE('Second line');
END;`

	wantCols := []string{"OUTPUT"}
	wantRows := []core.Row{
		{"Hello from PL/SQL!"},
		{"Second line"},
	}

	gotRows, gotCols, _, err := th.GetResult(t, suite.d, query)
	assert.NoError(t, err)

	assert.Equal(t, wantCols, gotCols)
	assert.Equal(t, wantRows, gotRows)
}

func (suite *OracleTestSuite) TestPLSQL_AnonymousBlock_NoOutput() {
	t := suite.T()

	query := `
BEGIN
  NULL;
END;`

	wantCols := []string{"OUTPUT"}

	gotRows, gotCols, _, err := th.GetResult(t, suite.d, query)
	assert.NoError(t, err)

	assert.Equal(t, wantCols, gotCols)
	assert.Empty(t, gotRows)
}

func (suite *OracleTestSuite) TestPLSQL_DeclareBlock() {
	t := suite.T()

	query := `
DECLARE
  v_msg VARCHAR2(100) := 'Declared variable';
BEGIN
  DBMS_OUTPUT.PUT_LINE(v_msg);
END;`

	wantCols := []string{"OUTPUT"}
	wantRows := []core.Row{{"Declared variable"}}

	gotRows, gotCols, _, err := th.GetResult(t, suite.d, query)
	assert.NoError(t, err)

	assert.Equal(t, wantCols, gotCols)
	assert.Equal(t, wantRows, gotRows)
}

func (suite *OracleTestSuite) TestPLSQL_CallProcedure() {
	t := suite.T()

	// First create the procedure
	createProc := `
CREATE OR REPLACE PROCEDURE test_hello(p_name IN VARCHAR2) AS
BEGIN
  DBMS_OUTPUT.PUT_LINE('Hello, ' || p_name || '!');
END;`

	_, _, _, err := th.GetResult(t, suite.d, createProc)
	assert.NoError(t, err)

	// Now call it using BEGIN block
	query := `
BEGIN
  test_hello('World');
END;`

	wantCols := []string{"OUTPUT"}
	wantRows := []core.Row{{"Hello, World!"}}

	gotRows, gotCols, _, err := th.GetResult(t, suite.d, query)
	assert.NoError(t, err)

	assert.Equal(t, wantCols, gotCols)
	assert.Equal(t, wantRows, gotRows)
}

func (suite *OracleTestSuite) TestPLSQL_Error() {
	t := suite.T()

	query := `
BEGIN
  INVALID_PROCEDURE();
END;`

	call := suite.d.Execute(query, func(cs core.CallState, c *core.Call) {
		if cs == core.CallStateExecutingFailed {
			// Should contain PLS error
			assert.ErrorContains(t, c.Err(), "PLS-")
		}
	})
	assert.NotNil(t, call)
}

func (suite *OracleTestSuite) TestRegularSQL_NoRegression() {
	t := suite.T()

	// Regular SELECT should still work without OUTPUT column
	query := "SELECT 1 AS num FROM dual"

	wantCols := []string{"NUM"}
	wantRows := []core.Row{{"1"}}

	gotRows, gotCols, _, err := th.GetResult(t, suite.d, query)
	assert.NoError(t, err)

	assert.Equal(t, wantCols, gotCols)
	assert.Equal(t, wantRows, gotRows)
}
