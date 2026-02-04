package adapters

import (
	"regexp"
	"strings"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/kndndrj/nvim-dbee/dbee/core/builders"
)

// plsqlCreatePattern matches CREATE [OR REPLACE] PROCEDURE|FUNCTION|PACKAGE|TRIGGER|TYPE
var plsqlCreatePattern = regexp.MustCompile(`(?i)^CREATE\s+(OR\s+REPLACE\s+)?(PROCEDURE|FUNCTION|PACKAGE|TRIGGER|TYPE)\b`)

// isPLSQL detects if a query is a PL/SQL block that may produce DBMS_OUTPUT.
// Returns true for:
// - Anonymous blocks: BEGIN...END, DECLARE...BEGIN...END
// - DDL: CREATE [OR REPLACE] PROCEDURE|FUNCTION|PACKAGE|TRIGGER|TYPE
// - Procedure calls: CALL procedure_name()
func isPLSQL(query string) bool {
	// Trim whitespace and get first word
	trimmed := strings.TrimSpace(query)
	if trimmed == "" {
		return false
	}

	upper := strings.ToUpper(trimmed)

	// Check for BEGIN or DECLARE (anonymous blocks)
	if strings.HasPrefix(upper, "BEGIN") || strings.HasPrefix(upper, "DECLARE") {
		return true
	}

	// Check for CALL statement
	if strings.HasPrefix(upper, "CALL") {
		return true
	}

	// Check for CREATE [OR REPLACE] PROCEDURE|FUNCTION|PACKAGE|TRIGGER|TYPE
	if strings.HasPrefix(upper, "CREATE") {
		return plsqlCreatePattern.MatchString(trimmed)
	}

	return false
}

// parseDBMSOutputLines splits DBMS_OUTPUT content into individual lines,
// filtering out empty lines.
func parseDBMSOutputLines(raw string) []string {
	if raw == "" {
		return []string{}
	}

	lines := strings.Split(raw, "\n")
	result := make([]string, 0, len(lines))

	for _, line := range lines {
		if line != "" {
			result = append(result, line)
		}
	}

	return result
}

// formatOracleError formats Oracle error messages for better readability.
// Converts wall of text into separate lines per error.
func formatOracleError(err error) error {
	if err == nil {
		return nil
	}

	errStr := err.Error()

	// Check if it looks like an Oracle error
	if !strings.Contains(errStr, "ORA-") && !strings.Contains(errStr, "PLS-") {
		return err
	}

	formatted := errStr

	// Step 1: Format "line X, column Y:" to compact form FIRST
	// (must happen before newline insertion so we don't consume the newlines)
	formatted = regexp.MustCompile(`line\s+(\d+),?\s*column\s+(\d+):\s*`).ReplaceAllString(formatted, "[L$1:C$2] ")

	// Step 2: Add newlines before each error code (except the first)
	formatted = regexp.MustCompile(`\s+(ORA-\d+:)`).ReplaceAllString(formatted, "\n$1")
	formatted = regexp.MustCompile(`\s+(PLS-\d+:)`).ReplaceAllString(formatted, "\n$1")

	// Trim each line
	lines := strings.Split(formatted, "\n")
	var cleaned []string
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line != "" {
			cleaned = append(cleaned, line)
		}
	}

	if len(cleaned) == 0 {
		return err
	}

	return &formattedError{original: err, formatted: strings.Join(cleaned, "\n")}
}

// formattedError wraps an error with formatted message
type formattedError struct {
	original  error
	formatted string
}

func (e *formattedError) Error() string {
	return e.formatted
}

func (e *formattedError) Unwrap() error {
	return e.original
}

// buildDBMSOutputResultStream creates a ResultStream from DBMS_OUTPUT lines.
func buildDBMSOutputResultStream(lines []string) core.ResultStream {
	idx := 0

	return builders.NewResultStreamBuilder().
		WithHeader(core.Header{"OUTPUT"}).
		WithNextFunc(
			func() (core.Row, error) {
				if idx >= len(lines) {
					return nil, nil
				}
				row := core.Row{lines[idx]}
				idx++
				return row, nil
			},
			func() bool {
				return idx < len(lines)
			},
		).
		Build()
}
