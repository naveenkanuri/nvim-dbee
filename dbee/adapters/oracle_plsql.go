package adapters

import (
	"regexp"
	"strings"
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
