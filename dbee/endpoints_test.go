package main

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestParseQueryExecuteOptions_NilRaw(t *testing.T) {
	opts, err := parseQueryExecuteOptions(nil)
	require.NoError(t, err)
	require.Nil(t, opts)
}

func TestParseQueryExecuteOptions_ValidBinds(t *testing.T) {
	opts, err := parseQueryExecuteOptions(map[string]any{
		"binds": map[string]any{
			"id":    42,
			"name":  "ALICE",
			"flag":  true,
			"score": 3.5,
			"blob":  []byte("A\x00B"),
		},
	})
	require.NoError(t, err)
	require.NotNil(t, opts)
	require.Equal(t, map[string]string{
		"id":    "42",
		"name":  "ALICE",
		"flag":  "true",
		"score": "3.5",
		"blob":  "A\x00B",
	}, opts.Binds)
}

func TestParseQueryExecuteOptions_ValidAnyMapShape(t *testing.T) {
	opts, err := parseQueryExecuteOptions(map[any]any{
		"binds": map[any]any{
			"id":   "42",
			"name": "ALICE",
		},
	})
	require.NoError(t, err)
	require.NotNil(t, opts)
	require.Equal(t, map[string]string{
		"id":   "42",
		"name": "ALICE",
	}, opts.Binds)
}

func TestParseQueryExecuteOptions_UnknownOption(t *testing.T) {
	opts, err := parseQueryExecuteOptions(map[string]any{
		"unknown": true,
	})
	require.ErrorContains(t, err, "unsupported query option")
	require.Nil(t, opts)
}

func TestParseQueryExecuteOptions_InvalidOptsType(t *testing.T) {
	opts, err := parseQueryExecuteOptions("bad")
	require.ErrorContains(t, err, "query options must be a map")
	require.Nil(t, opts)
}

func TestParseQueryExecuteOptions_InvalidOptsKeyType(t *testing.T) {
	opts, err := parseQueryExecuteOptions(map[any]any{
		1: "bad",
	})
	require.ErrorContains(t, err, "query options key must be string")
	require.Nil(t, opts)
}

func TestParseQueryExecuteOptions_InvalidBindsType(t *testing.T) {
	opts, err := parseQueryExecuteOptions(map[string]any{
		"binds": []any{"a"},
	})
	require.ErrorContains(t, err, "query option \"binds\" must be a map")
	require.Nil(t, opts)
}

func TestParseQueryExecuteOptions_InvalidBindsKeyType(t *testing.T) {
	opts, err := parseQueryExecuteOptions(map[string]any{
		"binds": map[any]any{
			1: "x",
		},
	})
	require.ErrorContains(t, err, "query option \"binds\" key must be string")
	require.Nil(t, opts)
}

func TestParseQueryExecuteOptions_InvalidBindValueType(t *testing.T) {
	opts, err := parseQueryExecuteOptions(map[string]any{
		"binds": map[string]any{
			"id": map[string]any{"nested": true},
		},
	})
	require.ErrorContains(t, err, "bind value for \"id\" has unsupported type")
	require.Nil(t, opts)
}

func TestParseQueryExecuteOptions_NilBindValueRejected(t *testing.T) {
	opts, err := parseQueryExecuteOptions(map[string]any{
		"binds": map[string]any{
			"id": nil,
		},
	})
	require.ErrorContains(t, err, "cannot be nil")
	require.Nil(t, opts)
}

func TestParseQueryExecuteOptions_EmptyBinds(t *testing.T) {
	opts, err := parseQueryExecuteOptions(map[string]any{
		"binds": map[string]any{},
	})
	require.NoError(t, err)
	require.Nil(t, opts)
}
