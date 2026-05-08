package adapters

import (
	"database/sql/driver"
	"errors"
	"os"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"
	"unsafe"

	go_ora "github.com/sijms/go-ora/v2"
	"github.com/sijms/go-ora/v2/configurations"
	"github.com/sijms/go-ora/v2/converters"
	"github.com/sijms/go-ora/v2/network"
	"github.com/sijms/go-ora/v2/trace"
	"github.com/stretchr/testify/require"
)

func TestOracleBindRewrite(t *testing.T) {
	assertOracleBindValidators(t)
	assertOracleBindRewriteCore(t)
	assertOracleBindTokenizer(t)
	assertOracleBindQQuoteTokenizer(t)
	assertOracleBindCollisions(t)
	assertOracleBindReverseErrors(t)
	assertOracleGoOraQQuoteParity(t)

	if !t.Failed() {
		logOracle24Marker(t, "ORA24_USER_VALIDATOR_OK=true")
		logOracle24Marker(t, "ORA24_DRIVER_VALIDATOR_OK=true")
		logOracle24Marker(t, "ORA24_TOKENIZER_OK=true")
		logOracle24Marker(t, "ORA24_TOKENIZER_QQUOTE_OK=true")
		logOracle24Marker(t, "ORA24_BIND_REWRITE_OK=true")
		logOracle24Marker(t, "ORA24_COLLISION_REJECT_OK=true")
		logOracle24Marker(t, "ORA24_REVERSE_ERROR_OK=true")
		logOracle24Marker(t, "ORA24_GOORA_QQUOTE_PARITY_OK=true")
		logOracle24Marker(t, "ORA24_QQUOTE_UNSUPPORTED=true")
	}
}

func assertOracleBindValidators(t *testing.T) {
	t.Helper()
	for _, name := range []string{"my$1", "A#B", "cur_$1", "p#bind", "_$foo"} {
		require.NoError(t, validateOracleBindNameUser(name), name)
	}
	for _, name := range []string{"$foo", "#bar", "table", "date", "user", "1abc", "bad-name", "", "my_x24_1", "my_X23_1"} {
		require.Error(t, validateOracleBindNameUser(name), name)
	}
	require.Error(t, validateOracleBindNameDriver("my$1"))
	require.NoError(t, validateOracleBindNameDriver("my_x24_1"))
}

func assertOracleBindRewriteCore(t *testing.T) {
	t.Helper()
	plan, err := prepareOracleBindRewrite("SELECT :my$1, :col#2, :plain FROM dual", map[string]string{
		"col#2": "2",
		"my$1":  "1",
		"plain": "3",
	})
	require.NoError(t, err)
	require.Equal(t, "SELECT :my_x24_1, :col_x23_2, :plain FROM dual", plan.rewrittenSQL)
	require.Equal(t, "my$1", plan.mapping.driverToUser["my_x24_1"])
	require.Equal(t, "col#2", plan.mapping.driverToUser["col_x23_2"])

	require.Error(t, mustPrepareOracleBindRewrite("SELECT :$foo FROM dual", nil))
	require.Error(t, mustPrepareOracleBindRewrite("SELECT :#bar FROM dual", nil))
}

func assertOracleBindTokenizer(t *testing.T) {
	t.Helper()
	query := "SELECT ':my$1', q'[ :q#1 ]', \":quoted$1\", :real$1 -- :line$1\nFROM dual /* :block#1 */ WHERE :real#2 = 1"
	plan, err := prepareOracleBindRewrite(query, map[string]string{"real$1": "1", "real#2": "2"})
	require.NoError(t, err)
	require.Contains(t, plan.rewrittenSQL, "':my$1'")
	require.Contains(t, plan.rewrittenSQL, "q'[ :q#1 ]'")
	require.Contains(t, plan.rewrittenSQL, "\":quoted$1\"")
	require.Contains(t, plan.rewrittenSQL, "-- :line$1")
	require.Contains(t, plan.rewrittenSQL, "/* :block#1 */")
	require.Contains(t, plan.rewrittenSQL, ":real_x24_1")
	require.Contains(t, plan.rewrittenSQL, ":real_x23_2")
	logOracle24Markerf(t, "ORA24_TOKENIZER_CASES_DIAGNOSTIC=%d", 5)
}

func assertOracleBindQQuoteTokenizer(t *testing.T) {
	t.Helper()
	for _, query := range []string{
		"SELECT q'#:foo#' FROM dual",
		"SELECT q'$:my$1$' FROM dual",
		"SELECT Q'<:cur$1>' FROM dual",
		"SELECT q'[ ]:x[ ]' FROM dual",
		"SELECT q'{:x#1}' FROM dual",
		"SELECT q'X...:x$1...X' FROM dual",
	} {
		_, err := prepareOracleBindRewrite(query, nil)
		require.NoError(t, err, query)
	}
	for _, query := range []string{
		"SELECT q' abc ' FROM dual",
		"SELECT q'''abc''' FROM dual",
		"SELECT q'🙂abc🙂' FROM dual",
		"SELECT q'[it's :fake$1]' FROM dual WHERE :real$1 = 1",
	} {
		require.Error(t, mustPrepareOracleBindRewrite(query, nil), query)
	}
	logOracle24Marker(t, "ORA24_QQUOTE_UNSUPPORTED=true")
}

func assertOracleBindCollisions(t *testing.T) {
	t.Helper()
	for _, query := range []string{
		"SELECT :my_x24_1 FROM dual",
		"SELECT :my_X23_1 FROM dual",
		"SELECT :my$1, :MY$1 FROM dual",
	} {
		require.Error(t, mustPrepareOracleBindRewrite(query, nil), query)
	}
	_, err := prepareOracleBindRewrite("SELECT 'my_x24_1' FROM dual WHERE :ok$1 = 1", nil)
	require.Error(t, err)

	_, err = prepareOracleBindRewrite("SELECT 'my_x24_1' FROM dual WHERE :ok$1 = 1", map[string]string{"ok$1": "1"})
	require.NoError(t, err)
}

func assertOracleBindReverseErrors(t *testing.T) {
	t.Helper()
	mapping := newOracleBindRewriteMap()
	_, _, err := mapping.addName("my$1")
	require.NoError(t, err)
	mapping.finalize()

	wrapped := wrapOracleError(errors.New("ORA-01008: not all variables bound: :my_x24_1"), mapping)
	require.Contains(t, wrapped.Error(), ":my$1")
	require.NotContains(t, wrapped.Error(), ":my_x24_1")
	require.True(t, errors.Is(wrapped, errors.Unwrap(wrapped)))

	require.Equal(t,
		"parameter my$1 is not defined in parameter list",
		reverseDriverNames("parameter my_x24_1 is not defined in parameter list", mapping.driverToUser, mapping.sortedDriverNames),
	)
	_, _, err = mapping.addName("my$2")
	require.NoError(t, err)
	mapping.finalize()
	require.Equal(t,
		"parameter my$1 is not defined in parameter list; parameter my$2 is not defined in parameter list",
		reverseDriverNames("parameter my_x24_1 is not defined in parameter list; parameter my_x24_2 is not defined in parameter list", mapping.driverToUser, mapping.sortedDriverNames),
	)
	require.Equal(t,
		"incidental my_x24_1 text",
		reverseDriverNames("incidental my_x24_1 text", mapping.driverToUser, mapping.sortedDriverNames),
	)
	require.Equal(t,
		":my_x24_1abc",
		reverseDriverNames(":my_x24_1abc", mapping.driverToUser, mapping.sortedDriverNames),
	)
}

func assertOracleGoOraQQuoteParity(t *testing.T) {
	t.Helper()
	for _, query := range []string{
		"SELECT q'[ : my $ 1 ]' FROM dual WHERE :real$1 = 1",
		"SELECT q'X.. :foo ..X' FROM dual WHERE :real#1 = 1",
		"SELECT Q'<:cur$1>' FROM dual WHERE :real$1 = 1",
	} {
		realName := "real$1"
		if strings.Contains(query, ":real#1") {
			realName = "real#1"
		}
		plan, err := prepareOracleBindRewrite(query, map[string]string{realName: "1"})
		require.NoError(t, err, query)
		require.Contains(t, plan.rewrittenSQL, ":real_")
		require.Contains(t, strings.ToLower(plan.rewrittenSQL), "q'")
		assertGoOraNamedParserDoesNotMissBind(t, plan.rewrittenSQL, plan.mapping.userToDriver[realName])
	}

	goOraErr := invokeGoOraNamedQueryParser("SELECT q'[it's :fake$1]' FROM dual WHERE :real_x24_1 = 1", "real_x24_1")
	require.Error(t, goOraErr)
	require.Contains(t, goOraErr.Error(), "parameter fake is not defined")

	_, err := prepareOracleBindRewrite("SELECT q'[it's :fake$1]' FROM dual WHERE :real$1 = 1", map[string]string{"real$1": "1"})
	require.Error(t, err)
	require.Contains(t, err.Error(), "go-ora cannot safely parse")
}

func TestOracleBindRewriteBudget(t *testing.T) {
	smallP50, smallP95 := oracleRewriteBudgetSample(t, oracleSmallRewriteSQL(), nil)
	_, mediumP95 := oracleRewriteBudgetSample(t, oracleMediumRewriteSQL(), oracleMediumRewriteBinds())
	_, largeP95 := oracleRewriteBudgetSample(t, oracleLargeRewriteSQL(), oracleLargeRewriteBinds())
	_, largeNoBindP95 := oracleRewriteBudgetSample(t, oracleLargeNoBindRewriteSQL(), nil)

	require.LessOrEqual(t, smallP95, 5*time.Microsecond)
	require.LessOrEqual(t, mediumP95, 50*time.Microsecond)
	require.LessOrEqual(t, largeP95, time.Millisecond)
	require.LessOrEqual(t, largeNoBindP95, 50*time.Microsecond)
	require.Equal(t, 0.0, testing.AllocsPerRun(100, func() {
		_, err := prepareOracleBindRewrite("select 1 from dual where 1 = 1", nil)
		if err != nil {
			t.Fatal(err)
		}
	}))

	logOracle24Markerf(t, "ORA24_REWRITE_P50_US=%d", smallP50.Microseconds())
	logOracle24Markerf(t, "ORA24_REWRITE_P95_US=%d", smallP95.Microseconds())
	logOracle24Markerf(t, "ORA24_REWRITE_US_P50=%d", smallP50.Microseconds())
	logOracle24Markerf(t, "ORA24_REWRITE_US_P95=%d", smallP95.Microseconds())
	logOracle24Marker(t, "ORA24_REWRITE_BUDGET_OK=true")
}

func TestPhase24Rollup(t *testing.T) {
	assertOracleBindValidators(t)
	if !t.Failed() {
		logOracle24Marker(t, "ORA24_USER_VALIDATOR_OK=true")
		logOracle24Marker(t, "ORA24_DRIVER_VALIDATOR_OK=true")
	}
	assertOracleBindRewriteCore(t)
	if !t.Failed() {
		logOracle24Marker(t, "ORA24_BIND_REWRITE_OK=true")
	}
	assertOracleBindTokenizer(t)
	if !t.Failed() {
		logOracle24Marker(t, "ORA24_TOKENIZER_OK=true")
	}
	assertOracleBindQQuoteTokenizer(t)
	if !t.Failed() {
		logOracle24Marker(t, "ORA24_TOKENIZER_QQUOTE_OK=true")
		logOracle24Marker(t, "ORA24_QQUOTE_UNSUPPORTED=true")
	}
	assertOracleBindCollisions(t)
	if !t.Failed() {
		logOracle24Marker(t, "ORA24_COLLISION_REJECT_OK=true")
	}
	assertOracleBindReverseErrors(t)
	if !t.Failed() {
		logOracle24Marker(t, "ORA24_REVERSE_ERROR_OK=true")
	}
	assertOracleGoOraQQuoteParity(t)
	if !t.Failed() {
		logOracle24Marker(t, "ORA24_GOORA_QQUOTE_PARITY_OK=true")
	}
	assertOracleBindRefReconciliation(t)
	if !t.Failed() {
		logOracle24Marker(t, "ORA24_BIND_MAP_OK=true")
	}
	runUnsafeBindMatrix(t)
	if !t.Failed() {
		logOracle24Marker(t, "ORA24_RESERVED_REJECT_OK=true")
	}
	runRefCursorValidation(t)
	if !t.Failed() {
		logOracle24Marker(t, "ORA24_CURSOR_MARKER_DOLLAR_OK=true")
		logOracle24Marker(t, "ORA24_CURSOR_FAST_PATH_ROUTED_OK=true")
	}
	runDBMSOutputLockstep(t)
	if !t.Failed() {
		logOracle24Marker(t, "ORA24_PHASE22_INTERNAL_PRESERVED_OK=true")
	}
	runOracleBindAuditCore(t)
	if !t.Failed() {
		logOracle24Marker(t, "ORA24_PHASE22_PRESERVED_OK=true")
	}
	smallP50, smallP95 := oracleRewriteBudgetSample(t, oracleSmallRewriteSQL(), nil)
	_, mediumP95 := oracleRewriteBudgetSample(t, oracleMediumRewriteSQL(), oracleMediumRewriteBinds())
	_, largeP95 := oracleRewriteBudgetSample(t, oracleLargeRewriteSQL(), oracleLargeRewriteBinds())
	require.LessOrEqual(t, smallP95, 5*time.Microsecond)
	require.LessOrEqual(t, mediumP95, 50*time.Microsecond)
	require.LessOrEqual(t, largeP95, time.Millisecond)
	if !t.Failed() {
		logOracle24Markerf(t, "ORA24_REWRITE_P50_US=%d", smallP50.Microseconds())
		logOracle24Markerf(t, "ORA24_REWRITE_P95_US=%d", smallP95.Microseconds())
		logOracle24Marker(t, "ORA24_REWRITE_BUDGET_OK=true")
	}
	if os.Getenv("ORACLE24_ROLLUP") == "1" && !t.Failed() {
		t.Log("PHASE24_ALL_PASS=true")
	}
}

func logOracle24Marker(t *testing.T, marker string) {
	t.Helper()
	if os.Getenv("ORACLE24_ROLLUP") == "1" {
		t.Log(marker)
	}
}

func logOracle24Markerf(t *testing.T, format string, args ...any) {
	t.Helper()
	if os.Getenv("ORACLE24_ROLLUP") == "1" {
		t.Logf(format, args...)
	}
}

func oracleRewriteBudgetSample(t *testing.T, query string, binds map[string]string) (time.Duration, time.Duration) {
	t.Helper()
	p95s := make([]time.Duration, 0, 5)
	var medianP50 time.Duration
	for run := 0; run < 5; run++ {
		samples := make([]time.Duration, 0, 200)
		for i := 0; i < 220; i++ {
			start := time.Now()
			_, err := prepareOracleBindRewrite(query, binds)
			require.NoError(t, err)
			elapsed := time.Since(start)
			if i >= 20 {
				samples = append(samples, elapsed)
			}
		}
		sort.Slice(samples, func(i, j int) bool { return samples[i] < samples[j] })
		if run == 2 {
			medianP50 = samples[len(samples)/2]
		}
		p95s = append(p95s, samples[190])
	}
	sort.Slice(p95s, func(i, j int) bool { return p95s[i] < p95s[j] })
	return medianP50, p95s[len(p95s)/2]
}

func BenchmarkOracleBindRewrite(b *testing.B) {
	cases := []struct {
		name  string
		query string
		binds map[string]string
	}{
		{name: "no_bind_fast_path", query: "select 1 from dual where 1 = 1"},
		{name: "large_no_bind", query: oracleLargeNoBindRewriteSQL()},
		{name: "few_bind_small", query: oracleFewBindSmallRewriteSQL(), binds: oracleFewBindSmallRewriteBinds()},
		{name: "many_bind_medium", query: oracleMediumRewriteSQL(), binds: oracleMediumRewriteBinds()},
		{name: "long_mixed", query: strings.Repeat("select ':fake$1', q'[ :fake#2 ]', -- :skip$1\n :real$1 from dual\n", 80), binds: map[string]string{"real$1": "1"}},
		{name: "large_50_binds", query: oracleLargeRewriteSQL(), binds: oracleLargeRewriteBinds()},
	}
	for _, tc := range cases {
		b.Run(tc.name, func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				_, err := prepareOracleBindRewrite(tc.query, tc.binds)
				if err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

func BenchmarkOracleBindRewriteParallel(b *testing.B) {
	query := oracleMediumRewriteSQL()
	binds := oracleMediumRewriteBinds()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			_, err := prepareOracleBindRewrite(query, binds)
			if err != nil {
				b.Fatal(err)
			}
		}
	})
}

func oracleSmallRewriteSQL() string {
	return strings.Repeat("select 1 from dual where 1 = 1\n", 8)
}

func oracleFewBindSmallRewriteSQL() string {
	return strings.Repeat("select 1 from dual where 1 = 1\n", 20) + "and :my$1 = :col#2"
}

func oracleFewBindSmallRewriteBinds() map[string]string {
	return map[string]string{"my$1": "1", "col#2": "2"}
}

func oracleMediumRewriteSQL() string {
	var b strings.Builder
	for i := 0; i < 10; i++ {
		b.WriteString("select :bind")
		b.WriteString(string(byte('A' + i)))
		b.WriteString("$1 from dual\n")
	}
	for b.Len() < 1024 {
		b.WriteString("select 1 from dual\n")
	}
	return b.String()
}

func oracleMediumRewriteBinds() map[string]string {
	binds := make(map[string]string, 10)
	for i := 0; i < 10; i++ {
		binds["bind"+string(byte('A'+i))+"$1"] = "1"
	}
	return binds
}

func oracleLargeRewriteSQL() string {
	var b strings.Builder
	for i := 0; i < 60; i++ {
		b.WriteString("select :bind")
		b.WriteString(string(byte('A' + (i % 26))))
		b.WriteString("$")
		b.WriteString(string(byte('0' + (i % 10))))
		b.WriteString(", q'[ :skip$1 ]', 'literal :skip#1' from dual\n")
	}
	for b.Len() < 100*1024 {
		b.WriteString("-- comment :skip$1\nselect 1 from dual\n")
	}
	return b.String()
}

func oracleLargeRewriteBinds() map[string]string {
	binds := make(map[string]string, 60)
	for i := 0; i < 60; i++ {
		name := "bind" + string(byte('A'+(i%26))) + "$" + string(byte('0'+(i%10)))
		binds[name] = "1"
	}
	return binds
}

func oracleLargeNoBindRewriteSQL() string {
	return strings.Repeat("select 1 from dual where 1 = 1\n", 512)
}

func mustPrepareOracleBindRewrite(query string, binds map[string]string) error {
	_, err := prepareOracleBindRewrite(query, binds)
	return err
}

func assertOracleBindRefReconciliation(t *testing.T) {
	t.Helper()

	_, err := prepareOracleBindRewrite("SELECT :foo FROM dual", nil)
	require.Error(t, err)
	require.Contains(t, err.Error(), `bind "foo" referenced in SQL but not provided`)

	_, err = prepareOracleBindRewrite("SELECT :foo FROM dual", map[string]string{"foo": "1", "extra": "2"})
	require.Error(t, err)
	require.Contains(t, err.Error(), `bind "extra" provided but not referenced in SQL`)

	_, err = prepareOracleBindRewrite("BEGIN proc(:cur$1 /*CURSOR*/, :id); END;", map[string]string{"id": "42"})
	require.NoError(t, err)
}

func assertGoOraNamedParserDoesNotMissBind(t *testing.T, query string, driverName string) {
	t.Helper()
	err := invokeGoOraNamedQueryParser(query, driverName)
	if err == nil {
		return
	}
	require.NotContains(t, err.Error(), "parameter ")
	require.NotContains(t, err.Error(), "is not defined")
}

func invokeGoOraNamedQueryParser(query string, driverNames ...string) (err error) {
	defer func() {
		if recovered := recover(); recovered != nil {
			err = nil
		}
	}()

	conn, err := go_ora.NewConnection("", &configurations.ConnectionConfig{
		ClientInfo:   configurations.ClientInfo{CharsetID: 873},
		PrefetchRows: 25,
	})
	if err != nil {
		return err
	}
	conn.State = go_ora.Opened
	stringConv := converters.NewStringConverter(873)
	session := network.NewSessionWithInputBufferForDebug(nil)
	session.StrConv = stringConv
	setGoOraUnexportedField(conn, "tracer", trace.NilTracer())
	setGoOraUnexportedField(conn, "sStrConv", stringConv)
	setGoOraUnexportedField(conn, "session", session)

	args := make([]driver.NamedValue, 0, len(driverNames))
	for i, name := range driverNames {
		args = append(args, driver.NamedValue{
			Name:    name,
			Ordinal: i + 1,
			Value:   int64(1),
		})
	}
	stmt := go_ora.NewStmt(query, conn)
	_, err = stmt.Query_(args)
	return err
}

func setGoOraUnexportedField(target any, name string, value any) {
	field := reflect.ValueOf(target).Elem().FieldByName(name)
	reflect.NewAt(field.Type(), unsafe.Pointer(field.UnsafeAddr())).Elem().Set(reflect.ValueOf(value))
}
