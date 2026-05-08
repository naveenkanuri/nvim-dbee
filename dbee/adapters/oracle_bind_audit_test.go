package adapters

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
)

func discoverOracleProductionFiles(t *testing.T) []string {
	t.Helper()

	entries, err := os.ReadDir(".")
	if !assert.NoError(t, err, "read adapter dir") {
		return nil
	}

	var files []string
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !strings.HasPrefix(name, "oracle") || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		files = append(files, name)
	}
	sort.Strings(files)

	if !assert.NotEmpty(t, files, "oracle bind audit matched zero production files") {
		return nil
	}

	found := make(map[string]bool, len(files))
	for _, file := range files {
		found[file] = true
	}
	for _, want := range []string{"oracle.go", "oracle_driver.go", "oracle_plsql.go", "oracle_refcursor.go", "oracle_wallet.go"} {
		assert.True(t, found[want], "oracle bind audit missing expected production file %s from %v", want, files)
	}

	return files
}

func runOracleBindAuditCore(t *testing.T) bool {
	t.Helper()

	files := discoverOracleProductionFiles(t)
	for _, file := range files {
		src, err := os.ReadFile(file)
		if err != nil {
			t.Errorf("read %s: %v", file, err)
			continue
		}

		source := string(src)
		for _, forbidden := range []string{
			`sql.Named("` + `line"`,
			`sql.Named("` + `status"`,
			`DBMS_OUTPUT.GET_LINE(:` + `line, :` + `status)`,
			`bindArgs := oracle` + `NamedArgs(`,
			`oracle` + `NamedArgs(binds)...`,
			`func oracle` + `NamedArgs(binds map[string]string) []any`,
		} {
			if strings.Contains(source, forbidden) {
				t.Errorf("%s contains forbidden legacy bind pattern %q", file, forbidden)
			}
		}

		for _, err := range auditOracleBindSource(file, src) {
			t.Error(err)
		}
		if file == "oracle_bind_rewrite.go" && strings.Contains(source, "regexp.") {
			t.Errorf("%s imports or calls regexp in the per-query rewrite path", file)
		}
		if file == "oracle_bind_rewrite.go" && strings.Contains(source, "strings.NewReplacer") {
			t.Errorf("%s uses strings.NewReplacer in production reverse mapping", file)
		}
		legacyValidatorDecl := "func validateOracle" + "BindName("
		if strings.Contains(source, legacyValidatorDecl) {
			t.Errorf("%s reintroduced legacy oracle bind validator helper", file)
		}
	}

	if got, want := userIdentifierPattern(), `[A-Za-z_][A-Za-z0-9_$#]*`; got != want {
		t.Errorf("user bind identifier pattern %q does not match expected %q", got, want)
	}
	if got, want := bindIdentifierPattern(), `[A-Za-z_][A-Za-z0-9_]*`; got != want {
		t.Errorf("driver bind identifier pattern %q does not match expected %q", got, want)
	}
	if !cursorBroadGrammarSupersetsUserGrammar() {
		t.Errorf("cursor broad grammar must superset strict user grammar and exclude assignment")
	}

	for _, query := range []string{
		"BEGIN proc(:cur /*CURSOR*/); END;",
		"BEGIN proc(:cur /* CURSOR */); END;",
		"BEGIN proc(:cur /* cursor */); END;",
	} {
		_, cleaned := parseCursorParams(query)
		if strings.Contains(strings.ToUpper(cleaned), "CURSOR") {
			t.Errorf("cursor cleanup left marker in %q -> %q", query, cleaned)
		}
	}

	return !t.Failed()
}

func TestOracleBindAudit(t *testing.T) {
	start := time.Now()
	ok := runOracleBindAuditCore(t)
	t.Logf("ORACLE22_BIND_AUDIT_MS=%d", time.Since(start).Milliseconds())
	if ok && !t.Failed() {
		t.Log("ORACLE22_BIND_AUDIT_OK=true")
	}
}

func TestOracleBindAuditDetectsViolations(t *testing.T) {
	cases := []struct {
		name string
		src  string
		want string
	}{
		{
			name: "unsafe literal",
			src:  `package adapters; import "database/sql"; func f() { _ = sql.Named("table", 1) }`,
			want: `oracle driver bind name "table" is reserved or unsafe after rewrite`,
		},
		{
			name: "unsupported selector",
			src:  `package adapters; import "database/sql"; var SomeStruct = struct{ Field string }{}; func f() { _ = sql.Named(SomeStruct.Field, 1) }`,
			want: "unsupported sql.Named first-arg shape",
		},
		{
			name: "unvalidated dynamic",
			src:  `package adapters; import "database/sql"; func f(name string) { _ = sql.Named(name, 1) }`,
			want: `unvalidated sql.Named first-arg ident "name"`,
		},
		{
			name: "ignored validation",
			src:  `package adapters; import "database/sql"; func f(params []string) { var args []any; for _, p := range params { _ = validateOracleBindNameDriver(p); args = append(args, sql.Named(p, 1)) }; _ = args }`,
			want: `unvalidated sql.Named first-arg ident "p"`,
		},
		{
			name: "validation in earlier conditional branch does not whitelist",
			src: `package adapters
import "database/sql"
func f(params []string, cond bool) {
	var args []any
	for _, p := range params {
		if cond {
			if err := validateOracleBindNameDriver(p); err != nil { return }
		}
		args = append(args, sql.Named(p, 1))
	}
	_ = args
}`,
			want: `unvalidated sql.Named first-arg ident "p"`,
		},
		{
			name: "sql.Named inside if-err-branch rejected",
			src: `package adapters
import "database/sql"
func f(params []string) {
	var args []any
	for _, p := range params {
		if err := validateOracleBindNameDriver(p); err != nil {
			args = append(args, sql.Named(p, 1))
			continue
		}
		args = append(args, sql.Named(p, 1))
	}
	_ = args
}`,
			want: `unvalidated sql.Named first-arg ident "p"`,
		},
	}

	for _, tc := range cases {
		errs := auditOracleBindSource("synthetic.go", []byte(tc.src))
		if len(errs) == 0 {
			t.Fatalf("%s: expected audit errors", tc.name)
		}
		var got []string
		for _, err := range errs {
			got = append(got, err.Error())
		}
		if !strings.Contains(strings.Join(got, "\n"), tc.want) {
			t.Fatalf("%s: expected %q in %q", tc.name, tc.want, strings.Join(got, "\n"))
		}
	}

	okCases := []struct {
		name string
		src  string
	}{
		{
			name: "safe literal",
			src:  `package adapters; import "database/sql"; func f() { _ = sql.Named("p_foo", 1) }`,
		},
		{
			name: "assign-then-check form accepted",
			src: `package adapters
import "database/sql"
func f(params []string) {
	var args []any
	for _, p := range params {
		err := validateOracleBindNameDriver(p)
		if err != nil { continue }
		args = append(args, sql.Named(p, 1))
	}
	_ = args
}`,
		},
	}
	for _, tc := range okCases {
		if errs := auditOracleBindSource("synthetic.go", []byte(tc.src)); len(errs) != 0 {
			t.Fatalf("%s: expected safe synthetic source to pass, got %v", tc.name, errs)
		}
	}
}

func TestOracleUnsafeBindNamesAllUppercase(t *testing.T) {
	for name := range oracleUnsafeBindNames {
		if name == "" {
			t.Fatal("oracleUnsafeBindNames contains empty key")
		}
		for _, r := range name {
			if r > 127 {
				t.Fatalf("oracleUnsafeBindNames key %q is not ASCII", name)
			}
		}
		if name != strings.ToUpper(name) {
			t.Fatalf("oracleUnsafeBindNames key %q is not uppercase", name)
		}
	}
}

func TestOracleSafeBindSuggestionAlwaysValidates(t *testing.T) {
	corpus := []string{
		"my$1",   // dollar present
		"col#2",  // hash present
		"$$$",    // pure stripped chars
		"###",    // pure stripped chars
		"$#$#",   // mixed stripped chars
		"1abc",   // leading digit
		"1$abc",  // leading digit + dollar
		"select", // reserved word
		"LEVEL",  // reserved word, uppercase
		"rownum", // reserved word
		"order",  // reserved word
		"with",   // reserved word
		"",       // empty
		" ",      // whitespace
		"name with spaces",
		"name-with-dash",
		"name.with.dots",
		"_$_",   // underscore + stripped
		"a$b#c", // alphanumerics + stripped
		"verylongname$$$1234",
	}

	for _, raw := range corpus {
		suggestion := oracleSafeBindSuggestion(raw)
		if !assert.NotEmpty(t, suggestion, "suggestion for %q is empty", raw) {
			continue
		}
		err := validateOracleBindNameUser(suggestion)
		assert.NoErrorf(t, err, "oracleSafeBindSuggestion(%q) = %q must itself pass user validation", raw, suggestion)
	}

	t.Log("ORACLE22_BIND_SUGGESTION_OK=true")
}

func TestPhase22Rollup(t *testing.T) {
	runOracleBindAuditCore(t)
	runUnsafeBindMatrix(t)
	runRefCursorValidation(t)
	runDBMSOutputLockstep(t)

	t.Run("safe_bind_suggestion", TestOracleSafeBindSuggestionAlwaysValidates)

	if os.Getenv("ORACLE22_ROLLUP") == "1" && !t.Failed() {
		t.Log("PHASE22_ALL_PASS=true")
	}
}

func auditOracleBindSource(filename string, src []byte) []error {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, filename, src, 0)
	if err != nil {
		return []error{fmt.Errorf("parse %s: %w", filename, err)}
	}

	var errs []error
	var stack []ast.Node
	ast.Inspect(file, func(n ast.Node) bool {
		if n == nil {
			if len(stack) > 0 {
				stack = stack[:len(stack)-1]
			}
			return true
		}

		stack = append(stack, n)
		call, ok := n.(*ast.CallExpr)
		if !ok || !isSQLNamedCall(call) {
			return true
		}
		if len(call.Args) == 0 {
			errs = append(errs, fmt.Errorf("sql.Named with no args at %s", auditLocation(fset, call.Pos())))
			return true
		}
		if err := classifySQLNamedFirstArg(fset, call.Args[0], call, stack); err != nil {
			errs = append(errs, err)
		}
		return true
	})

	return errs
}

func classifySQLNamedFirstArg(fset *token.FileSet, expr ast.Expr, call *ast.CallExpr, stack []ast.Node) error {
	for {
		paren, ok := expr.(*ast.ParenExpr)
		if !ok {
			break
		}
		expr = paren.X
	}

	switch first := expr.(type) {
	case *ast.BasicLit:
		if first.Kind != token.STRING {
			return fmt.Errorf("unsupported sql.Named first-arg shape at %s", auditLocation(fset, first.Pos()))
		}
		name, err := strconv.Unquote(first.Value)
		if err != nil {
			return fmt.Errorf("invalid sql.Named literal at %s: %w", auditLocation(fset, first.Pos()), err)
		}
		if err := validateOracleBindNameDriver(name); err != nil {
			return fmt.Errorf("sql.Named literal %q at %s failed validation: %w", name, auditLocation(fset, first.Pos()), err)
		}
		if !strings.HasPrefix(name, "p_") {
			return fmt.Errorf("sql.Named literal %q at %s lacks p_ prefix", name, auditLocation(fset, first.Pos()))
		}
		return nil
	case *ast.Ident:
		if sqlNamedIdentIsValidated(first.Name, call, stack) {
			return nil
		}
		return fmt.Errorf("unvalidated sql.Named first-arg ident %q at %s", first.Name, auditLocation(fset, first.Pos()))
	case *ast.IndexExpr:
		if sqlNamedIndexExprIsPrecomputedCursorDriver(first, stack) {
			return nil
		}
		return fmt.Errorf("unsupported sql.Named first-arg shape at %s", auditLocation(fset, first.Pos()))
	default:
		return fmt.Errorf("unsupported sql.Named first-arg shape at %s", auditLocation(fset, first.Pos()))
	}
}

// sqlNamedIdentIsValidated checks Patterns A/B from ORA22-20.
//
// Trust assumption: Pattern B only trusts same-block validation statements that
// dominate sql.Named(ident, ...), but it does not prove the loop variable is
// unreassigned between those points. Today's dynamic production sites do not
// mutate the loop var. If a future dynamic site reassigns it, extend this
// walker to reject AssignStmt targets for the validated ident between
// validation and sql.Named in the same RangeStmt body.
func sqlNamedIdentIsValidated(name string, call *ast.CallExpr, stack []ast.Node) bool {
	if fn := enclosingFunc(stack); fn != nil && (fn.Name.Name == "oracleNamedArgs" || fn.Name.Name == "oracleNamedArgsWithRewrite" || fn.Name.Name == "executePLSQLWithCursor") {
		if block := enclosingBlock(stack); blockHasDominatingValidateOracleBindSurfaceBefore(block, name, call.Pos()) {
			return true
		}
		if fn.Name.Name == "oracleNamedArgsWithRewrite" {
			if block := enclosingBlock(stack); blockHasDominatingOracleBindMapAddNameBefore(block, name, call.Pos()) {
				return true
			}
		}
	}

	if rng := enclosingRange(stack); rng != nil {
		if value, ok := rng.Value.(*ast.Ident); ok && value.Name == name {
			if blockHasDominatingValidateOracleBindSurfaceBefore(rng.Body, name, call.Pos()) {
				return true
			}
		}
	}

	return false
}

func sqlNamedIndexExprIsPrecomputedCursorDriver(expr *ast.IndexExpr, stack []ast.Node) bool {
	fn := enclosingFunc(stack)
	if fn == nil || fn.Name.Name != "executePLSQLWithCursor" {
		return false
	}
	selector, ok := unwrapParen(expr.X).(*ast.SelectorExpr)
	if !ok || selector.Sel.Name != "cursorDriverNames" {
		return false
	}
	ident, ok := unwrapParen(selector.X).(*ast.Ident)
	return ok && ident.Name == "rewritePlan"
}

func blockHasDominatingValidateOracleBindSurfaceBefore(block *ast.BlockStmt, name string, before token.Pos) bool {
	if block == nil {
		return false
	}
	for i := 0; i < len(block.List); i++ {
		stmt := block.List[i]
		if stmt.Pos() >= before || (stmt.Pos() <= before && before <= stmt.End()) {
			return false
		}
		if ifStmt, ok := stmt.(*ast.IfStmt); ok && ifStmtHandlesValidateOracleBindSurface(ifStmt, name) {
			return true
		}
		errName, ok := validateOracleBindSurfaceAssignErrName(stmt, name)
		if !ok || i+1 >= len(block.List) {
			continue
		}
		nextIf, ok := block.List[i+1].(*ast.IfStmt)
		if ok && nextIf.Pos() < before && ifStmtChecksErrAndStops(nextIf, errName) {
			return true
		}
	}
	return false
}

func blockHasDominatingOracleBindMapAddNameBefore(block *ast.BlockStmt, name string, before token.Pos) bool {
	if block == nil {
		return false
	}
	for i := 0; i < len(block.List); i++ {
		stmt := block.List[i]
		if stmt.Pos() >= before || (stmt.Pos() <= before && before <= stmt.End()) {
			return false
		}
		errName, ok := oracleBindMapAddNameAssignErrName(stmt, name)
		if !ok || i+1 >= len(block.List) {
			continue
		}
		nextIf, ok := block.List[i+1].(*ast.IfStmt)
		if ok && nextIf.Pos() < before && ifStmtChecksErrAndStops(nextIf, errName) {
			return true
		}
	}
	return false
}

func oracleBindMapAddNameAssignErrName(node ast.Node, name string) (string, bool) {
	assign, ok := node.(*ast.AssignStmt)
	if !ok {
		return "", false
	}
	for i, rhs := range assign.Rhs {
		call, ok := unwrapParen(rhs).(*ast.CallExpr)
		if !ok || !isOracleBindMapAddNameCall(call) || i >= len(assign.Lhs) {
			continue
		}
		lhs, ok := unwrapParen(assign.Lhs[i]).(*ast.Ident)
		if !ok || lhs.Name != name {
			continue
		}
		errIndex := i + 2
		if errIndex >= len(assign.Lhs) {
			return "", false
		}
		errIdent, ok := unwrapParen(assign.Lhs[errIndex]).(*ast.Ident)
		if ok && errIdent.Name != "_" {
			return errIdent.Name, true
		}
	}
	return "", false
}

func isOracleBindMapAddNameCall(call *ast.CallExpr) bool {
	selector, ok := unwrapParen(call.Fun).(*ast.SelectorExpr)
	return ok && selector.Sel.Name == "addName"
}

func ifStmtHandlesValidateOracleBindSurface(ifStmt *ast.IfStmt, name string) bool {
	if ifStmt == nil {
		return false
	}
	errName, ok := validateOracleBindSurfaceAssignErrName(ifStmt.Init, name)
	return ok && ifStmtChecksErrAndStops(ifStmt, errName)
}

func ifStmtChecksErrAndStops(ifStmt *ast.IfStmt, errName string) bool {
	return ifStmt != nil && isIdentNotNilCond(ifStmt.Cond, errName) && blockStopsUnsafeBind(ifStmt.Body)
}

func isIdentNotNilCond(expr ast.Expr, errName string) bool {
	binary, ok := unwrapParen(expr).(*ast.BinaryExpr)
	if !ok || binary.Op != token.NEQ {
		return false
	}
	left, leftOK := unwrapParen(binary.X).(*ast.Ident)
	right, rightOK := unwrapParen(binary.Y).(*ast.Ident)
	return (leftOK && left.Name == errName && rightOK && right.Name == "nil") ||
		(leftOK && left.Name == "nil" && rightOK && right.Name == errName)
}

func blockStopsUnsafeBind(block *ast.BlockStmt) bool {
	if block == nil {
		return false
	}
	for _, stmt := range block.List {
		switch s := stmt.(type) {
		case *ast.ReturnStmt:
			return true
		case *ast.BranchStmt:
			if s.Tok == token.CONTINUE {
				return true
			}
		case *ast.ExprStmt:
			call, ok := unwrapParen(s.X).(*ast.CallExpr)
			if ok {
				if ident, ok := call.Fun.(*ast.Ident); ok && ident.Name == "panic" {
					return true
				}
			}
		}
	}
	return false
}

func validateOracleBindSurfaceAssignErrName(node ast.Node, name string) (string, bool) {
	assign, ok := node.(*ast.AssignStmt)
	if !ok {
		return "", false
	}
	for i, rhs := range assign.Rhs {
		call, ok := unwrapParen(rhs).(*ast.CallExpr)
		if !ok || !isValidateOracleBindSurfaceCall(call, name) || i >= len(assign.Lhs) {
			continue
		}
		lhs, ok := unwrapParen(assign.Lhs[i]).(*ast.Ident)
		if ok && lhs.Name != "_" {
			return lhs.Name, true
		}
	}
	return "", false
}

func isValidateOracleBindSurfaceCall(call *ast.CallExpr, name string) bool {
	fun, ok := call.Fun.(*ast.Ident)
	if !ok || (fun.Name != "validateOracleBindNameUser" && fun.Name != "validateOracleBindNameDriver") || len(call.Args) == 0 {
		return false
	}
	arg := unwrapParen(call.Args[0])
	ident, ok := arg.(*ast.Ident)
	return ok && ident.Name == name
}

func unwrapParen(expr ast.Expr) ast.Expr {
	for {
		paren, ok := expr.(*ast.ParenExpr)
		if !ok {
			return expr
		}
		expr = paren.X
	}
}

func isSQLNamedCall(call *ast.CallExpr) bool {
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel.Name != "Named" {
		return false
	}
	pkg, ok := sel.X.(*ast.Ident)
	return ok && pkg.Name == "sql"
}

func enclosingFunc(stack []ast.Node) *ast.FuncDecl {
	for i := len(stack) - 1; i >= 0; i-- {
		if fn, ok := stack[i].(*ast.FuncDecl); ok {
			return fn
		}
	}
	return nil
}

func enclosingRange(stack []ast.Node) *ast.RangeStmt {
	for i := len(stack) - 1; i >= 0; i-- {
		if rng, ok := stack[i].(*ast.RangeStmt); ok {
			return rng
		}
	}
	return nil
}

func enclosingBlock(stack []ast.Node) *ast.BlockStmt {
	for i := len(stack) - 1; i >= 0; i-- {
		if block, ok := stack[i].(*ast.BlockStmt); ok {
			return block
		}
	}
	return nil
}

func enclosingIf(stack []ast.Node) *ast.IfStmt {
	for i := len(stack) - 1; i >= 0; i-- {
		if ifStmt, ok := stack[i].(*ast.IfStmt); ok {
			return ifStmt
		}
	}
	return nil
}

func auditLocation(fset *token.FileSet, pos token.Pos) string {
	position := fset.Position(pos)
	return fmt.Sprintf("%s:%d", filepath.Base(position.Filename), position.Line)
}

func bindIdentifierPattern() string {
	pattern := strings.TrimPrefix(oracleBindNameRe.String(), "^")
	return strings.TrimSuffix(pattern, "$")
}

func userIdentifierPattern() string {
	return `[A-Za-z_][A-Za-z0-9_$#]*`
}

func cursorBroadGrammarSupersetsUserGrammar() bool {
	for _, ch := range []byte("Az_09$#") {
		if !isOracleCursorBroadNameByte(ch) {
			return false
		}
	}
	return !isOracleCursorBroadNameByte('=')
}
