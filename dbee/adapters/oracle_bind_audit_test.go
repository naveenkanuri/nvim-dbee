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
)

func discoverOracleProductionFiles(t *testing.T) []string {
	t.Helper()

	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("read adapter dir: %v", err)
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

	if len(files) == 0 {
		t.Fatal("oracle bind audit matched zero production files")
	}

	found := make(map[string]bool, len(files))
	for _, file := range files {
		found[file] = true
	}
	for _, want := range []string{"oracle.go", "oracle_driver.go", "oracle_plsql.go", "oracle_refcursor.go", "oracle_wallet.go"} {
		if !found[want] {
			t.Fatalf("oracle bind audit missing expected production file %s from %v", want, files)
		}
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
	}

	if got, want := cursorIdentifierPattern(), bindIdentifierPattern(); got != want {
		t.Errorf("cursor marker identifier pattern %q does not match oracle bind validator %q", got, want)
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
			want: `oracle bind name "table" is reserved or unsafe`,
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

	okSrc := `package adapters; import "database/sql"; func f() { _ = sql.Named("p_foo", 1) }`
	if errs := auditOracleBindSource("synthetic.go", []byte(okSrc)); len(errs) != 0 {
		t.Fatalf("expected safe synthetic source to pass, got %v", errs)
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

func TestPhase22Rollup(t *testing.T) {
	runOracleBindAuditCore(t)
	runUnsafeBindMatrix(t)
	runRefCursorValidation(t)
	runDBMSOutputLockstep(t)

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
		if err := validateOracleBindName(name); err != nil {
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
	default:
		return fmt.Errorf("unsupported sql.Named first-arg shape at %s", auditLocation(fset, first.Pos()))
	}
}

func sqlNamedIdentIsValidated(name string, call *ast.CallExpr, stack []ast.Node) bool {
	if fn := enclosingFunc(stack); fn != nil && fn.Name.Name == "oracleNamedArgs" {
		if containsValidateOracleBindNameBefore(fn.Body, name, call.Pos()) {
			return true
		}
	}

	if rng := enclosingRange(stack); rng != nil {
		if value, ok := rng.Value.(*ast.Ident); ok && value.Name == name {
			if containsValidateOracleBindNameBefore(rng.Body, name, call.Pos()) {
				return true
			}
		}
	}

	if ifStmt := enclosingIf(stack); ifStmt != nil {
		if containsValidateOracleBindName(ifStmt.Init, name) || containsValidateOracleBindName(ifStmt.Cond, name) {
			return true
		}
	}

	return false
}

func containsValidateOracleBindNameBefore(node ast.Node, name string, before token.Pos) bool {
	found := false
	ast.Inspect(node, func(n ast.Node) bool {
		if n == nil || found {
			return !found
		}
		if n.Pos() >= before {
			return true
		}
		call, ok := n.(*ast.CallExpr)
		if ok && isValidateOracleBindNameCall(call, name) {
			found = true
			return false
		}
		return true
	})
	return found
}

func containsValidateOracleBindName(node ast.Node, name string) bool {
	if node == nil {
		return false
	}
	found := false
	ast.Inspect(node, func(n ast.Node) bool {
		if n == nil || found {
			return !found
		}
		call, ok := n.(*ast.CallExpr)
		if ok && isValidateOracleBindNameCall(call, name) {
			found = true
			return false
		}
		return true
	})
	return found
}

func isValidateOracleBindNameCall(call *ast.CallExpr, name string) bool {
	fun, ok := call.Fun.(*ast.Ident)
	if !ok || fun.Name != "validateOracleBindName" || len(call.Args) == 0 {
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

func cursorIdentifierPattern() string {
	pattern := cursorMarkerPattern.String()
	start := strings.Index(pattern, ":(")
	if start < 0 {
		return ""
	}
	rest := pattern[start+2:]
	end := strings.Index(rest, `)\s*/`)
	if end < 0 {
		return ""
	}
	return rest[:end]
}
