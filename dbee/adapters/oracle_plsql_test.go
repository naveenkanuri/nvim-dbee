package adapters

import (
	"testing"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/stretchr/testify/assert"
)

func TestParseDBMSOutputLines(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want []string
	}{
		{"single line", "hello", []string{"hello"}},
		{"multiple lines", "line1\nline2\nline3", []string{"line1", "line2", "line3"}},
		{"empty string", "", []string{}},
		{"only newlines", "\n\n", []string{}},
		{"trailing newline", "hello\n", []string{"hello"}},
		{"leading newline", "\nhello", []string{"hello"}},
		{"mixed empty lines", "line1\n\nline2", []string{"line1", "line2"}},
		{"unicode content", "こんにちは\n世界", []string{"こんにちは", "世界"}},
		{"special chars", "a=1; b='test'", []string{"a=1; b='test'"}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parseDBMSOutputLines(tt.raw)
			assert.Equal(t, tt.want, got)
		})
	}
}

func TestIsPLSQL(t *testing.T) {
	tests := []struct {
		name  string
		query string
		want  bool
	}{
		{"simple select", "SELECT * FROM users", false},
		{"update statement", "UPDATE users SET name = 'test'", false},
		{"begin block", "BEGIN DBMS_OUTPUT.PUT_LINE('hello'); END;", true},
		{"begin lowercase", "begin dbms_output.put_line('hello'); end;", true},
		{"begin with whitespace", "  BEGIN NULL; END;", true},
		{"declare block", "DECLARE x NUMBER; BEGIN x := 1; END;", true},
		{"declare lowercase", "declare x number; begin x := 1; end;", true},
		{"create procedure", "CREATE PROCEDURE test AS BEGIN NULL; END;", true},
		{"create or replace procedure", "CREATE OR REPLACE PROCEDURE test AS BEGIN NULL; END;", true},
		{"create function", "CREATE FUNCTION test RETURN NUMBER AS BEGIN RETURN 1; END;", true},
		{"create or replace function", "CREATE OR REPLACE FUNCTION test RETURN NUMBER AS BEGIN RETURN 1; END;", true},
		{"create package", "CREATE PACKAGE test AS END;", true},
		{"create trigger", "CREATE TRIGGER test BEFORE INSERT ON users BEGIN NULL; END;", true},
		{"create type", "CREATE TYPE test AS OBJECT (id NUMBER);", true},
		{"call statement", "CALL my_procedure()", true},
		{"call lowercase", "call my_procedure()", true},
		{"create table", "CREATE TABLE test (id NUMBER)", false},
		{"create view", "CREATE VIEW test AS SELECT * FROM users", false},
		{"insert statement", "INSERT INTO users VALUES (1)", false},
		{"delete statement", "DELETE FROM users WHERE id = 1", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := isPLSQL(tt.query)
			assert.Equal(t, tt.want, got)
		})
	}
}

func TestBuildDBMSOutputResultStream(t *testing.T) {
	lines := []string{"line1", "line2", "line3"}

	stream := buildDBMSOutputResultStream(lines)

	// Check header
	assert.Equal(t, core.Header{"OUTPUT"}, stream.Header())

	// Check rows
	var rows []core.Row
	for stream.HasNext() {
		row, err := stream.Next()
		assert.NoError(t, err)
		rows = append(rows, row)
	}

	assert.Equal(t, []core.Row{{"line1"}, {"line2"}, {"line3"}}, rows)
}

func TestBuildDBMSOutputResultStream_Empty(t *testing.T) {
	stream := buildDBMSOutputResultStream([]string{})

	assert.Equal(t, core.Header{"OUTPUT"}, stream.Header())
	assert.False(t, stream.HasNext())
}
