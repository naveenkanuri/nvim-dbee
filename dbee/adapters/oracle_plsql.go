package adapters

import (
	"regexp"
	"strconv"
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
	trimmed := stripLeadingSQLComments(query)
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

// stripLeadingSQLComments removes leading SQL line comments (-- ...)
// and block comments (/* ... */) so that isPLSQL can detect the first keyword.
func stripLeadingSQLComments(query string) string {
	s := strings.TrimSpace(query)
	for len(s) > 0 {
		if strings.HasPrefix(s, "--") {
			// Line comment: skip to end of line
			if idx := strings.IndexByte(s, '\n'); idx >= 0 {
				s = strings.TrimSpace(s[idx+1:])
			} else {
				return "" // entire query is a comment
			}
		} else if strings.HasPrefix(s, "/*") {
			// Block comment: skip to closing */
			if idx := strings.Index(s, "*/"); idx >= 0 {
				s = strings.TrimSpace(s[idx+2:])
			} else {
				return "" // unclosed block comment
			}
		} else {
			break
		}
	}
	return s
}

// stripTrailingSQLPlusSlashTerminator removes a trailing SQL*Plus "/"
// command terminator line if present.
//
// Example input:
//
//	BEGIN ... END;
//	/
//
// Returns:
//
//	BEGIN ... END;
func stripTrailingSQLPlusSlashTerminator(query string) string {
	s := strings.TrimSpace(query)
	if s == "" {
		return s
	}

	lines := strings.Split(s, "\n")
	last := len(lines) - 1
	if last >= 0 && strings.TrimSpace(lines[last]) == "/" {
		lines = lines[:last]
		// Drop any blank trailing lines left after removing "/"
		for len(lines) > 0 && strings.TrimSpace(lines[len(lines)-1]) == "" {
			lines = lines[:len(lines)-1]
		}
		return strings.Join(lines, "\n")
	}

	return s
}

// parseDBMSOutputLines splits DBMS_OUTPUT content into individual lines.
// Preserves intentional empty lines but strips trailing empty lines
// (which may be artifacts from NEW_LINE flush).
func parseDBMSOutputLines(raw string) []string {
	if raw == "" {
		return []string{}
	}

	// Trim trailing newlines, then split
	raw = strings.TrimRight(raw, "\n")
	if raw == "" {
		return []string{}
	}
	return strings.Split(raw, "\n")
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

// oracleErrorLocationPattern matches "line N, column M" in Oracle error messages.
var oracleErrorLocationPattern = regexp.MustCompile(`line\s+(\d+),?\s*column\s+(\d+)`)

// parseOracleErrorLocation extracts the first line and column number from an Oracle error message.
// Returns (line, column, found). Line and column are 1-based.
func parseOracleErrorLocation(errMsg string) (int, int, bool) {
	matches := oracleErrorLocationPattern.FindStringSubmatch(errMsg)
	if matches == nil || len(matches) < 3 {
		return 0, 0, false
	}

	line, err := strconv.Atoi(matches[1])
	if err != nil {
		return 0, 0, false
	}
	col, err := strconv.Atoi(matches[2])
	if err != nil {
		return 0, 0, false
	}

	return line, col, true
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
