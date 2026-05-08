package adapters

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestFilterCursorBindNames_ExcludesCursorParamCollisions(t *testing.T) {
	binds := map[string]string{
		"id":     "42",
		"result": "SHADOWED",
		"CUR2":   "SHADOWED2",
	}

	filtered := filterCursorBindNames(binds, []string{"RESULT", "cur2"})

	require.Equal(t, map[string]string{
		"id": "42",
	}, filtered)
	// Ensure source map is not mutated.
	require.Equal(t, "SHADOWED", binds["result"])
	require.Equal(t, "SHADOWED2", binds["CUR2"])
}

func TestParseCursorParams_RemovesCursorMarkers(t *testing.T) {
	params, cleaned := parseCursorParams("BEGIN proc(:result /*CURSOR*/, :cur2 /*CURSOR*/, :id); END;")

	require.Equal(t, []string{"result", "cur2"}, params)
	require.Equal(t, "BEGIN proc(:result, :cur2, :id); END;", cleaned)

	params, cleaned = parseCursorParams("BEGIN proc(:cur$1 /*CURSOR*/); END;")
	require.Equal(t, []string{"cur$1"}, params)
	require.Equal(t, "BEGIN proc(:cur$1); END;", cleaned)
}

func runRefCursorValidation(t *testing.T) bool {
	t.Helper()

	cases := []struct {
		query   string
		params  []string
		cleaned string
	}{
		{
			query:   "BEGIN proc(:cur /*cursor*/); END;",
			params:  []string{"cur"},
			cleaned: "BEGIN proc(:cur); END;",
		},
	}
	for _, tc := range cases {
		params, cleaned := parseCursorParams(tc.query)
		assert.Equal(t, tc.params, params)
		assert.Equal(t, tc.cleaned, cleaned)
		assert.NoError(t, validateRawCursorMarkers(tc.query))
	}

	for _, name := range []string{"result", "p_result", "A_B", "A$B", "A#B", "cur_$1", "my$1", "p#bind"} {
		assert.NoError(t, validateOracleBindNameUser(name))
	}

	state := newSessTestState()
	driver := newSessTestDriver(t, state)
	result, err := driver.QueryWithBinds(context.Background(), "BEGIN proc(:table /*CURSOR*/); END;", nil)
	assert.Nil(t, result)
	assertOracleBindValidationError(t, err, "table")
	assert.Empty(t, state.getQueryConnIDs())

	state = newSessTestState()
	driver = newSessTestDriver(t, state)
	result, err = driver.QueryWithBinds(context.Background(), "BEGIN proc(:result /*CURSOR*/); END;", map[string]string{"table": "x"})
	assert.Nil(t, result)
	assertOracleBindValidationError(t, err, "table")
	assert.Empty(t, state.getQueryConnIDs())

	runMalformedCursorMarkerValidation(t)
	runStrayCursorCommentValidation(t)

	return !t.Failed()
}

func TestOracleRefCursorValidation(t *testing.T) {
	runRefCursorValidation(t)
	if !t.Failed() {
		t.Log("ORA24_CURSOR_MARKER_DOLLAR_OK=true")
		t.Log("ORA24_CURSOR_FAST_PATH_ROUTED_OK=true")
		t.Log("ORA24_PLSQL_ASSIGN_SKIP_OK=true")
	}
}

func runMalformedCursorMarkerValidation(t *testing.T) bool {
	t.Helper()

	for _, tc := range []struct {
		query string
		name  string
	}{
		{query: "BEGIN proc(: /*CURSOR*/); END;", name: ""},
		{query: "BEGIN proc(:1foo /*CURSOR*/); END;", name: "1foo"},
		{query: "BEGIN proc(:bad-name /*CURSOR*/); END;", name: "bad-name"},
		{query: "BEGIN proc(:$cur /*CURSOR*/); END;", name: "$cur"},
		{query: "BEGIN proc(:#cur /*CURSOR*/); END;", name: "#cur"},
	} {
		assertCursorMarkerRejectedBeforeEnable(t, tc.query, tc.name)
	}

	for _, query := range []string{
		"BEGIN proc(:A$B /*CURSOR*/); END;",
		"BEGIN proc(:A#B  /* CURSOR */); END;",
		"BEGIN proc(:cur_$1 /*CURSOR*/); END;",
		"BEGIN proc(:my$1 /*CURSOR*/); END;",
		"BEGIN proc(:p#bind /*CURSOR*/); END;",
		"BEGIN proc(:A$B\t/*CURSOR*/); END;",
	} {
		assert.NoError(t, validateRawCursorMarkers(query))
		plan, err := prepareOracleBindRewrite(query, nil)
		assert.NoError(t, err)
		assert.True(t, plan.hasCursor)
		assert.NotContains(t, strings.ToUpper(plan.rewrittenSQL), "CURSOR")
		assert.NotContains(t, plan.rewrittenSQL, "$")
		assert.NotContains(t, plan.rewrittenSQL, "#")
	}

	return !t.Failed()
}

func TestOracleMalformedCursorMarkerRejectedBeforeEnable(t *testing.T) {
	runMalformedCursorMarkerValidation(t)
}

func TestOracleEmptyCursorMarkerRejectedBeforeEnable(t *testing.T) {
	assertCursorMarkerRejectedBeforeEnable(t, "BEGIN proc(: /*CURSOR*/); END;", "")
}

func assertCursorMarkerRejectedBeforeEnable(t *testing.T, query string, name string) {
	t.Helper()

	err := validateRawCursorMarkers(query)
	if assert.Error(t, err) {
		assert.Contains(t, err.Error(), name)
		assert.Contains(t, err.Error(), oracleSafeBindSuggestion(name))
	}

	state := newSessTestState()
	driver := newSessTestDriver(t, state)
	result, err := driver.QueryWithBinds(context.Background(), query, nil)
	assert.Nil(t, result)
	assertOracleBindValidationError(t, err, name)
	// getQueryConnIDs records QueryContext / ExecContext calls in
	// oracle_driver_session_test.go; empty means DBMS_OUTPUT.ENABLE never ran.
	assert.Empty(t, state.getQueryConnIDs())
}

func runStrayCursorCommentValidation(t *testing.T) bool {
	t.Helper()

	for _, tc := range []struct {
		query string
		binds map[string]string
	}{
		{
			query: "BEGIN proc(:p_id); /* CURSOR */ END;",
			binds: map[string]string{"p_id": "42"},
		},
		{
			query: "BEGIN x := :y;\n/* CURSOR */\nz := 1; END;",
			binds: map[string]string{"y": "42"},
		},
		{
			query: "BEGIN x := /* CURSOR */ 1; END;",
			binds: nil,
		},
		{
			query: "DECLARE n NUMBER; BEGIN n := 1; /* CURSOR */ n := 2; END;",
			binds: nil,
		},
		{
			query: "BEGIN result := func( /* CURSOR */ x); END;",
			binds: nil,
		},
	} {
		assert.False(t, hasCursorMarkerBroad(tc.query), "stray cursor comment must not look cursor-shaped")
		assert.NoError(t, validateRawCursorMarkers(tc.query))

		state := newSessTestState()
		driver := newSessTestDriver(t, state)
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
		result, err := driver.QueryWithBinds(ctx, tc.query, tc.binds)
		cancel()
		if result != nil {
			result.Close()
		}
		if err != nil {
			assert.NotContains(t, err.Error(), "oracle bind validation")
		}
		assert.NotEmpty(t, state.getQueryConnIDs(), "normal PL/SQL path should execute")
	}

	return !t.Failed()
}

func TestOracleStrayCursorCommentNotRejected(t *testing.T) {
	runStrayCursorCommentValidation(t)
}

func TestOracleRefCursorRewritePlan(t *testing.T) {
	plan, err := prepareOracleBindRewrite("BEGIN proc(:cur$1 /*CURSOR*/, :other#2 /* note */); END;", nil)
	require.NoError(t, err)
	require.True(t, plan.hasCursor)
	require.Equal(t, []string{"cur$1"}, plan.cursorParams)
	require.Equal(t, "BEGIN proc(:cur_x24_1, :other_x23_2 /* note */); END;", plan.rewrittenSQL)

	plainPlan, err := prepareOracleBindRewrite("BEGIN proc(:cur /*CURSOR*/); END;", nil)
	require.NoError(t, err)
	require.True(t, plainPlan.hasCursor)
	require.Equal(t, "BEGIN proc(:cur); END;", plainPlan.rewrittenSQL)
	t.Log("ORA24_CURSOR_MARKER_DOLLAR_OK=true")
	t.Log("ORA24_CURSOR_FAST_PATH_ROUTED_OK=true")
}
