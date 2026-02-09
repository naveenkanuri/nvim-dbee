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
		{"leading newline", "\nhello", []string{"", "hello"}},
		{"mixed empty lines", "line1\n\nline2", []string{"line1", "", "line2"}},
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

func TestStripTrailingSQLPlusSlashTerminator(t *testing.T) {
	tests := []struct {
		name  string
		query string
		want  string
	}{
		{
			name:  "slash terminator line",
			query: "BEGIN\n  NULL;\nEND;\n/",
			want:  "BEGIN\n  NULL;\nEND;",
		},
		{
			name:  "slash terminator with whitespace",
			query: "BEGIN\n  NULL;\nEND;\n  /  \n",
			want:  "BEGIN\n  NULL;\nEND;",
		},
		{
			name:  "no slash terminator",
			query: "BEGIN\n  NULL;\nEND;",
			want:  "BEGIN\n  NULL;\nEND;",
		},
		{
			name:  "slash not last line",
			query: "BEGIN\n  -- comment\n  /\nEND;",
			want:  "BEGIN\n  -- comment\n  /\nEND;",
		},
		{
			name:  "only slash",
			query: "/",
			want:  "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := stripTrailingSQLPlusSlashTerminator(tt.query)
			assert.Equal(t, tt.want, got)
		})
	}
}

func TestParseOracleErrorLocation(t *testing.T) {
	tests := []struct {
		name      string
		errMsg    string
		wantLine  int
		wantCol   int
		wantFound bool
	}{
		{
			name:     "standard ORA error",
			errMsg:   "ORA-06550: line 3, column 5:\nPLS-00103: Encountered the symbol \"END\"",
			wantLine: 3, wantCol: 5, wantFound: true,
		},
		{
			name:     "no line info",
			errMsg:   "ORA-00942: table or view does not exist",
			wantLine: 0, wantCol: 0, wantFound: false,
		},
		{
			name:     "line 1",
			errMsg:   "ORA-06550: line 1, column 7:\nPLS-00201: identifier 'FOO' must be declared",
			wantLine: 1, wantCol: 7, wantFound: true,
		},
		{
			name:     "multiple errors - first wins",
			errMsg:   "ORA-06550: line 5, column 3:\nPLS-00103: error\nORA-06550: line 8, column 1:\nPLS-00103: another",
			wantLine: 5, wantCol: 3, wantFound: true,
		},
		{
			name:     "empty string",
			errMsg:   "",
			wantLine: 0, wantCol: 0, wantFound: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			line, col, found := parseOracleErrorLocation(tt.errMsg)
			assert.Equal(t, tt.wantFound, found)
			assert.Equal(t, tt.wantLine, line)
			assert.Equal(t, tt.wantCol, col)
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
