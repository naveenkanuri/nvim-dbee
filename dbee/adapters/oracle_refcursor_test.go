package adapters

import (
	"context"
	"testing"

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
}

func runRefCursorValidation(t *testing.T) bool {
	t.Helper()

	cases := []struct {
		query   string
		params  []string
		cleaned string
	}{
		{
			query:   "BEGIN proc(:A$B /*CURSOR*/); END;",
			params:  []string{"A$B"},
			cleaned: "BEGIN proc(:A$B); END;",
		},
		{
			query:   "BEGIN proc(:A#B  /* CURSOR */); END;",
			params:  []string{"A#B"},
			cleaned: "BEGIN proc(:A#B); END;",
		},
		{
			query:   "BEGIN proc(:cur_$1 /*CURSOR*/); END;",
			params:  []string{"cur_$1"},
			cleaned: "BEGIN proc(:cur_$1); END;",
		},
		{
			query:   "BEGIN proc(:p#bind /*CURSOR*/); END;",
			params:  []string{"p#bind"},
			cleaned: "BEGIN proc(:p#bind); END;",
		},
		{
			query:   "BEGIN proc(:A$B\t/*CURSOR*/); END;",
			params:  []string{"A$B"},
			cleaned: "BEGIN proc(:A$B); END;",
		},
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

	for _, name := range []string{"result", "A$B", "A#B"} {
		assert.NoError(t, validateOracleBindName(name))
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

	return !t.Failed()
}

func TestOracleRefCursorValidation(t *testing.T) {
	runRefCursorValidation(t)
}

func runMalformedCursorMarkerValidation(t *testing.T) bool {
	t.Helper()

	for _, tc := range []struct {
		query string
		name  string
	}{
		{query: "BEGIN proc(:1foo /*CURSOR*/); END;", name: "1foo"},
		{query: "BEGIN proc(:bad-name /*CURSOR*/); END;", name: "bad-name"},
	} {
		err := validateRawCursorMarkers(tc.query)
		if assert.Error(t, err) {
			assert.Contains(t, err.Error(), tc.name)
			assert.Contains(t, err.Error(), "p_"+tc.name)
		}

		state := newSessTestState()
		driver := newSessTestDriver(t, state)
		result, err := driver.QueryWithBinds(context.Background(), tc.query, nil)
		assert.Nil(t, result)
		assertOracleBindValidationError(t, err, tc.name)
		assert.Empty(t, state.getQueryConnIDs())
	}

	return !t.Failed()
}

func TestOracleMalformedCursorMarkerRejectedBeforeEnable(t *testing.T) {
	runMalformedCursorMarkerValidation(t)
}
