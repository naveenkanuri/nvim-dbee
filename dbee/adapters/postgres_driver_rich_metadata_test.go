package adapters

import (
	"errors"
	"fmt"
	"math"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/kndndrj/nvim-dbee/dbee/core/builders"
	"github.com/lib/pq"
	"github.com/stretchr/testify/require"
)

func newPostgresRichMetadataMock(t *testing.T) (*postgresDriver, sqlmock.Sqlmock) {
	t.Helper()
	db, mock, err := sqlmock.New(sqlmock.QueryMatcherOption(sqlmock.QueryMatcherEqual))
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })
	return &postgresDriver{c: builders.NewClient(db), url: nil}, mock
}

func TestPostgresRichMetadataSupport(t *testing.T) {
	driver := &postgresDriver{}
	support := driver.SupportsRichMetadata()
	require.True(t, support.Columns)
	require.True(t, support.Indexes)
	require.True(t, support.Sequences)

	for _, query := range []string{
		postgresColumnsRichSQL,
		postgresPrimaryKeysSQL,
		postgresForeignKeysSQL,
		postgresIndexesSQL,
		postgresSequencesSQL,
	} {
		require.Contains(t, query, "pg_catalog.")
		require.NotContains(t, query, ":p_schema")
		require.NotContains(t, query, ":p_table")
	}
	require.Contains(t, postgresColumnsRichSQL, "WITH cols AS")
	require.Contains(t, postgresColumnsRichSQL, "n.nspname = $1")
	require.Contains(t, postgresColumnsRichSQL, "c.relname = $2")
	require.Contains(t, postgresColumnsRichSQL, "c.relkind IN ('r', 'p', 'f', 'v', 'm')")
	require.Contains(t, postgresColumnsRichSQL, "pg_catalog.pg_get_expr(d.adbin, d.adrelid, false)")
	require.Contains(t, postgresColumnsRichSQL, "pg_catalog.quote_ident(schema_name) || '.' || pg_catalog.quote_ident(table_name)")
	require.Contains(t, postgresIndexesSQL, "table_cls.relkind IN ('r', 'p', 'v', 'm')")
	require.Contains(t, postgresIndexesSQL, "ix.indnkeyatts")
	require.Contains(t, postgresIndexesSQL, "pg_catalog.pg_get_indexdef")
	require.Contains(t, postgresIndexesSQL, "ix.indisprimary AS pk_backed")
	require.Contains(t, postgresIndexesSQL, "ix.indisready")
	require.Contains(t, postgresIndexesSQL, "ix.indisvalid")
	require.Contains(t, postgresSequencesSQL, "c.relkind = 'S'")
	require.Contains(t, postgresSequencesSQL, "JOIN pg_catalog.pg_sequence")

	t.Log("RICH_PG_SUPPORT_TRUE=true")
	t.Log("RICH_PG_POSITIONAL_BINDS=true")
	t.Log("RICH_PG_CATALOG_SCOPING=true")
}

func TestPostgresPG12FloorBehavior(t *testing.T) {
	driver, mock := newPostgresRichMetadataMock(t)

	mock.ExpectQuery(postgresColumnsRichSQL).
		WithArgs("public", "child_account").
		WillReturnError(&pq.Error{Code: "42703", Message: "column does not exist"})

	_, err := driver.ColumnsRich(&core.TableOptions{
		Schema: "public",
		Table:  "child_account",
	})
	require.Error(t, err)
	var pgErr *pq.Error
	require.True(t, errors.As(err, &pgErr))
	require.Equal(t, pq.ErrorCode("42703"), pgErr.Code)
	require.NoError(t, mock.ExpectationsWereMet())

	t.Log("RICH_PG_PG12_FLOOR_BEHAVIOR_OK=true")
}

func TestPostgresColumnsRichCompositeMetadata(t *testing.T) {
	driver, mock := newPostgresRichMetadataMock(t)

	mock.ExpectQuery(postgresColumnsRichSQL).
		WithArgs("public", "child_account").
		WillReturnRows(sqlmock.NewRows([]string{
			"column_name",
			"data_type",
			"nullable",
			"attgenerated",
			"attidentity",
			"default_expr",
			"serial_sequence",
		}).
			AddRow("tenant_id", "uuid", false, "", "", nil, nil).
			AddRow("parent_id", "bigint", false, "", "", nil, nil).
			AddRow("generated_total", "numeric", true, "s", "", "(amount * tax)", nil).
			AddRow("legacy_serial", "integer", false, "", "", "nextval('public.child_account_legacy_serial_seq'::regclass)", "public.child_account_legacy_serial_seq").
			AddRow("identity_id", "bigint", false, "", "a", nil, nil))
	mock.ExpectQuery(postgresPrimaryKeysSQL).
		WithArgs("public", "child_account").
		WillReturnRows(sqlmock.NewRows([]string{"column_name", "position"}).
			AddRow("parent_id", int64(2)).
			AddRow("tenant_id", int64(1)))
	mock.ExpectQuery(postgresForeignKeysSQL).
		WithArgs("public", "child_account").
		WillReturnRows(sqlmock.NewRows([]string{
			"constraint_name",
			"source_column",
			"ordinal",
			"target_schema",
			"target_table",
			"target_column",
		}).
			AddRow("fk_child_parent", "parent_id", int64(2), "public", "parent_account", "id").
			AddRow("fk_child_parent", "tenant_id", int64(1), "public", "parent_account", "tenant_id"))

	columns, err := driver.ColumnsRich(&core.TableOptions{
		Schema: "public",
		Table:  "child_account",
	})
	require.NoError(t, err)
	require.Len(t, columns, 5)
	require.NoError(t, mock.ExpectationsWereMet())

	byName := postgresColumnsByName(columns)
	require.Equal(t, []string{"tenant_id", "parent_id", "generated_total", "legacy_serial", "identity_id"}, postgresColumnNames(columns))

	require.NotNil(t, byName["tenant_id"].Nullable)
	require.False(t, *byName["tenant_id"].Nullable)
	require.NotNil(t, byName["generated_total"].Nullable)
	require.True(t, *byName["generated_total"].Nullable)
	require.Equal(t, "s", byName["generated_total"].Generated)
	require.Equal(t, "(amount * tax)", byName["generated_total"].Default)
	require.Equal(t, "", byName["legacy_serial"].Identity)
	require.Equal(t, "nextval('public.child_account_legacy_serial_seq'::regclass)", byName["legacy_serial"].Default)
	require.Equal(t, "public.child_account_legacy_serial_seq", byName["legacy_serial"].SerialSequence)
	require.Equal(t, "a", byName["identity_id"].Identity)
	require.Equal(t, "", byName["identity_id"].Default)
	require.Equal(t, "", byName["identity_id"].SerialSequence)

	require.True(t, byName["tenant_id"].PrimaryKey)
	require.Equal(t, 1, byName["tenant_id"].PrimaryKeyOrdinal)
	require.True(t, byName["parent_id"].PrimaryKey)
	require.Equal(t, 2, byName["parent_id"].PrimaryKeyOrdinal)

	tenantFKs := byName["tenant_id"].ForeignKeys
	parentFKs := byName["parent_id"].ForeignKeys
	require.Len(t, tenantFKs, 1)
	require.Len(t, parentFKs, 1)
	require.NotSame(t, tenantFKs[0], parentFKs[0])
	require.Equal(t, "fk_child_parent", tenantFKs[0].ConstraintName)
	require.Equal(t, "public", tenantFKs[0].SourceSchema)
	require.Equal(t, "child_account", tenantFKs[0].SourceTable)
	require.Equal(t, "tenant_id", tenantFKs[0].SourceColumn)
	require.Equal(t, 1, tenantFKs[0].SourceOrdinal)
	require.Equal(t, "public", tenantFKs[0].TargetSchema)
	require.Equal(t, "parent_account", tenantFKs[0].TargetTable)
	require.Equal(t, "tenant_id", tenantFKs[0].TargetColumn)
	require.Equal(t, "parent_id", parentFKs[0].SourceColumn)
	require.Equal(t, "id", parentFKs[0].TargetColumn)
	require.Equal(t, []string{"tenant_id", "parent_id"}, tenantFKs[0].SourceColumns)
	require.Equal(t, []string{"tenant_id", "parent_id"}, parentFKs[0].SourceColumns)
	require.Equal(t, []string{"tenant_id", "id"}, tenantFKs[0].TargetColumns)
	require.Equal(t, []string{"tenant_id", "id"}, parentFKs[0].TargetColumns)

	t.Log("RICH_PG_RICH_COLUMNS_OK=true")
	t.Log("RICH_PG_COMPOSITE_PK_OK=true")
	t.Log("RICH_PG_COMPOSITE_FK_OK=true")
	t.Log("RICH_PG_FK_REF_POINTER_PER_COLUMN_OK=true")
}

func TestPostgresIndexesRichMetadata(t *testing.T) {
	driver, mock := newPostgresRichMetadataMock(t)

	mock.ExpectQuery(postgresIndexesSQL).
		WithArgs("public", "child_account").
		WillReturnRows(sqlmock.NewRows([]string{
			"index_name",
			"index_owner",
			"table_owner",
			"table_name",
			"uniqueness",
			"column_name",
			"descend",
			"column_position",
			"is_include",
			"pk_backed",
		}).
			AddRow("idx_child_expr", "public", "public", "child_account", "NONUNIQUE", "lower(name)", "ASC", int64(1), false, false).
			AddRow("idx_child_lookup", "public", "public", "child_account", "NONUNIQUE", "tenant_id", "ASC", int64(1), false, false).
			AddRow("idx_child_lookup", "public", "public", "child_account", "NONUNIQUE", "parent_id", "DESC", int64(2), false, false).
			AddRow("idx_child_lookup", "public", "public", "child_account", "NONUNIQUE", "updated_at", nil, int64(3), true, false).
			AddRow("idx_child_lookup", "public", "public", "child_account", "NONUNIQUE", "status", nil, int64(4), true, false).
			AddRow("pk_child", "public", "public", "child_account", "UNIQUE", "tenant_id", "ASC", int64(1), false, true).
			AddRow("pk_child", "public", "public", "child_account", "UNIQUE", "parent_id", "ASC", int64(2), false, true))

	indexes, err := driver.Indexes(&core.TableOptions{
		Schema: "public",
		Table:  "child_account",
	})
	require.NoError(t, err)
	require.Len(t, indexes, 3)
	require.NoError(t, mock.ExpectationsWereMet())

	byName := postgresIndexesByName(indexes)
	require.Equal(t, []string{"lower(name)"}, byName["idx_child_expr"].Columns)
	require.Equal(t, []string{"ASC"}, byName["idx_child_expr"].Orders)
	require.False(t, byName["idx_child_expr"].Unique)
	require.False(t, byName["idx_child_expr"].PKBacked)

	lookup := byName["idx_child_lookup"]
	require.Equal(t, "public", lookup.Schema)
	require.Equal(t, "child_account", lookup.Table)
	require.Equal(t, []string{"tenant_id", "parent_id"}, lookup.Columns)
	require.Equal(t, []string{"ASC", "DESC"}, lookup.Orders)
	require.Equal(t, []string{"updated_at", "status"}, lookup.IncludeColumns)
	for _, keyColumn := range lookup.Columns {
		require.NotContains(t, lookup.IncludeColumns, keyColumn)
	}

	pk := byName["pk_child"]
	require.True(t, pk.Unique)
	require.True(t, pk.PKBacked)
	require.Equal(t, []string{"tenant_id", "parent_id"}, pk.Columns)
	require.Empty(t, pk.IncludeColumns)

	mock.ExpectQuery(postgresIndexesSQL).
		WithArgs("public", "foreign_account").
		WillReturnRows(sqlmock.NewRows([]string{
			"index_name",
			"index_owner",
			"table_owner",
			"table_name",
			"uniqueness",
			"column_name",
			"descend",
			"column_position",
			"is_include",
			"pk_backed",
		}))
	foreignIndexes, err := driver.Indexes(&core.TableOptions{
		Schema: "public",
		Table:  "foreign_account",
	})
	require.NoError(t, err)
	require.NotNil(t, foreignIndexes)
	require.Empty(t, foreignIndexes)
	require.NoError(t, mock.ExpectationsWereMet())

	t.Log("RICH_PG_INDEXES_OK=true")
	t.Log("RICH_PG_INCLUDE_COLUMNS_OK=true")
}

func TestPostgresSequencesRichMetadata(t *testing.T) {
	driver, mock := newPostgresRichMetadataMock(t)

	mock.ExpectQuery(postgresSequencesSQL).
		WithArgs("public").
		WillReturnRows(sqlmock.NewRows([]string{"sequence_name", "increment_by", "cache_size"}).
			AddRow("account_seq", int64(1), int64(20)).
			AddRow("audit_seq", int64(10), int64(100)))

	sequences, err := driver.Sequences("public")
	require.NoError(t, err)
	require.Len(t, sequences, 2)
	require.NoError(t, mock.ExpectationsWereMet())

	require.Equal(t, "account_seq", sequences[0].Name)
	require.Equal(t, "public", sequences[0].Schema)
	require.Equal(t, int64(1), sequences[0].Increment)
	require.Equal(t, int64(20), sequences[0].CacheSize)
	require.Equal(t, "audit_seq", sequences[1].Name)
	require.Equal(t, int64(10), sequences[1].Increment)
	require.Equal(t, int64(100), sequences[1].CacheSize)

	t.Log("RICH_PG_SEQUENCES_OK=true")
}

func postgresColumnsByName(columns []*core.Column) map[string]*core.Column {
	byName := map[string]*core.Column{}
	for _, col := range columns {
		byName[col.Name] = col
	}
	return byName
}

func postgresColumnNames(columns []*core.Column) []string {
	names := make([]string, 0, len(columns))
	for _, col := range columns {
		names = append(names, col.Name)
	}
	return names
}

func postgresIndexesByName(indexes []*core.Index) map[string]*core.Index {
	byName := map[string]*core.Index{}
	for _, index := range indexes {
		byName[index.Name] = index
	}
	return byName
}

func TestPostgresRichMetadataNoNamedBindsInTests(t *testing.T) {
	require.False(t, strings.Contains(postgresColumnsRichSQL+postgresPrimaryKeysSQL+postgresForeignKeysSQL+postgresIndexesSQL+postgresSequencesSQL, ":p_"))
}

const (
	postgresRichMetadataBenchRows       = 10000
	postgresRichMetadataBenchIterations = 20
	postgresRichMetadataBenchP95Gate    = 50 * time.Millisecond
)

type postgresRichMetadataMeasureFunc func(testing.TB, int) time.Duration

type postgresRichMetadataMeasure struct {
	method  string
	measure postgresRichMetadataMeasureFunc
}

type postgresRichMetadataBenchResult struct {
	method string
	rows   int
	p50    time.Duration
	p95    time.Duration
}

var postgresRichMetadataMeasures = []postgresRichMetadataMeasure{
	{method: "ColumnsRich", measure: measurePostgresColumnsRichParse},
	{method: "Indexes", measure: measurePostgresIndexesParse},
	{method: "Sequences", measure: measurePostgresSequencesParse},
}

func TestPostgresRichMetadataBenchAggregator(t *testing.T) {
	t.Run("slow_measure_omits_marker", func(t *testing.T) {
		results, ok := aggregatePostgresRichMetadataGoParse(t, 1, 2, []postgresRichMetadataMeasure{
			{
				method: "Slow",
				measure: func(tb testing.TB, _ int) time.Duration {
					tb.Helper()
					time.Sleep(60 * time.Millisecond)
					return 60 * time.Millisecond
				},
			},
		})
		require.False(t, ok)
		require.Len(t, results, 1)
		require.GreaterOrEqual(t, results[0].p95, postgresRichMetadataBenchP95Gate)
	})

	results, ok := aggregatePostgresRichMetadataGoParse(
		t,
		postgresRichMetadataBenchRows,
		postgresRichMetadataBenchIterations,
		postgresRichMetadataMeasures,
	)
	for _, result := range results {
		t.Logf(
			"RICH_PG_PERF_DIAGNOSTIC=go_parse_aggregator method=%s rows=%d p50_ms=%.3f p95_ms=%.3f",
			result.method,
			result.rows,
			float64(result.p50.Microseconds())/1000.0,
			float64(result.p95.Microseconds())/1000.0,
		)
	}
	require.True(t, ok, "postgres rich metadata 10000-row parse p95 must stay below %s for all methods", postgresRichMetadataBenchP95Gate)
	t.Log("RICH_PG_BENCH_GO_PARSE_P95_OK=true")
}

func BenchmarkPostgresRichMetadataGoParseColumnsRich(b *testing.B) {
	benchmarkPostgresRichMetadataGoParse(b, "ColumnsRich", []int{1000, 10000, 50000}, measurePostgresColumnsRichParse)
}

func BenchmarkPostgresRichMetadataGoParseIndexes(b *testing.B) {
	benchmarkPostgresRichMetadataGoParse(b, "Indexes", []int{1000, 10000, 50000}, measurePostgresIndexesParse)
}

func BenchmarkPostgresRichMetadataGoParseSequences(b *testing.B) {
	benchmarkPostgresRichMetadataGoParse(b, "Sequences", []int{1000, 10000, 50000}, measurePostgresSequencesParse)
}

func benchmarkPostgresRichMetadataGoParse(
	b *testing.B,
	method string,
	sizes []int,
	measure postgresRichMetadataMeasureFunc,
) {
	for _, size := range sizes {
		size := size
		b.Run(fmt.Sprintf("%s_%d_rows", method, size), func(b *testing.B) {
			measuredIterations := b.N
			if measuredIterations < postgresRichMetadataBenchIterations {
				measuredIterations = postgresRichMetadataBenchIterations
			}

			// sqlmock measures deterministic Go-side row scanning, grouping, cloning,
			// and field parsing only; it cannot validate PostgreSQL catalog execution cost.
			_ = measure(b, size) // excluded warmup
			durations := make([]time.Duration, 0, measuredIterations)
			b.ResetTimer()
			for i := 0; i < measuredIterations; i++ {
				durations = append(durations, measure(b, size))
			}
			b.StopTimer()

			result := postgresRichMetadataBenchResult{
				method: method,
				rows:   size,
				p50:    postgresDurationPercentile(durations, 0.50),
				p95:    postgresDurationPercentile(durations, 0.95),
			}
			b.ReportMetric(float64(result.p50.Microseconds())/1000.0, "p50_ms")
			b.ReportMetric(float64(result.p95.Microseconds())/1000.0, "p95_ms")
			if b.N >= postgresRichMetadataBenchIterations {
				b.Logf(
					"RICH_PG_PERF_DIAGNOSTIC=go_parse method=%s rows=%d p50_ms=%.3f p95_ms=%.3f",
					method,
					size,
					float64(result.p50.Microseconds())/1000.0,
					float64(result.p95.Microseconds())/1000.0,
				)
				if size == postgresRichMetadataBenchRows && result.p95 >= postgresRichMetadataBenchP95Gate {
					b.Fatalf("postgres %s 10000-row parse p95 %s exceeds %s gate", method, result.p95, postgresRichMetadataBenchP95Gate)
				}
			}
		})
	}
}

func aggregatePostgresRichMetadataGoParse(
	tb testing.TB,
	rowCount int,
	iterations int,
	measures []postgresRichMetadataMeasure,
) ([]postgresRichMetadataBenchResult, bool) {
	tb.Helper()
	results := make([]postgresRichMetadataBenchResult, 0, len(measures))
	allOK := true
	for _, measure := range measures {
		result := measurePostgresRichMetadataP95(tb, measure.method, rowCount, iterations, measure.measure)
		results = append(results, result)
		if result.p95 >= postgresRichMetadataBenchP95Gate {
			allOK = false
		}
	}
	return results, allOK
}

func measurePostgresRichMetadataP95(
	tb testing.TB,
	method string,
	rowCount int,
	iterations int,
	measure postgresRichMetadataMeasureFunc,
) postgresRichMetadataBenchResult {
	tb.Helper()
	if iterations < 1 {
		iterations = 1
	}

	// sqlmock measures deterministic Go-side row scanning, grouping, cloning,
	// and field parsing only; it cannot validate PostgreSQL catalog execution cost.
	_ = measure(tb, rowCount) // excluded warmup
	durations := make([]time.Duration, 0, iterations)
	for i := 0; i < iterations; i++ {
		durations = append(durations, measure(tb, rowCount))
	}

	return postgresRichMetadataBenchResult{
		method: method,
		rows:   rowCount,
		p50:    postgresDurationPercentile(durations, 0.50),
		p95:    postgresDurationPercentile(durations, 0.95),
	}
}

func measurePostgresColumnsRichParse(tb testing.TB, rowCount int) time.Duration {
	tb.Helper()
	driver, mock, cleanup := newPostgresRichMetadataBenchmarkMock(tb)
	defer cleanup()

	columnRows := sqlmock.NewRows([]string{
		"column_name",
		"data_type",
		"nullable",
		"attgenerated",
		"attidentity",
		"default_expr",
		"serial_sequence",
	})
	for i := 0; i < rowCount; i++ {
		generated := ""
		identity := ""
		var defaultExpr any
		var serialSequence any
		if i%97 == 0 {
			generated = "s"
			defaultExpr = "(amount * tax)"
		} else if i%89 == 0 {
			identity = "a"
		} else if i%17 == 0 {
			defaultExpr = fmt.Sprintf("nextval('public.bench_col_%05d_seq'::regclass)", i)
			serialSequence = fmt.Sprintf("public.bench_col_%05d_seq", i)
		}
		columnRows.AddRow(fmt.Sprintf("col_%05d", i), "text", i%3 != 0, generated, identity, defaultExpr, serialSequence)
	}

	mock.ExpectQuery(postgresColumnsRichSQL).WithArgs("public", "bench_table").WillReturnRows(columnRows)
	mock.ExpectQuery(postgresPrimaryKeysSQL).WithArgs("public", "bench_table").
		WillReturnRows(sqlmock.NewRows([]string{"column_name", "position"}))
	mock.ExpectQuery(postgresForeignKeysSQL).WithArgs("public", "bench_table").
		WillReturnRows(sqlmock.NewRows([]string{
			"constraint_name",
			"source_column",
			"ordinal",
			"target_schema",
			"target_table",
			"target_column",
		}))

	start := time.Now()
	columns, err := driver.ColumnsRich(&core.TableOptions{Schema: "public", Table: "bench_table"})
	elapsed := time.Since(start)
	require.NoError(tb, err)
	require.Len(tb, columns, rowCount)
	require.NoError(tb, mock.ExpectationsWereMet())
	return elapsed
}

func measurePostgresIndexesParse(tb testing.TB, rowCount int) time.Duration {
	tb.Helper()
	driver, mock, cleanup := newPostgresRichMetadataBenchmarkMock(tb)
	defer cleanup()

	indexRows := sqlmock.NewRows([]string{
		"index_name",
		"index_owner",
		"table_owner",
		"table_name",
		"uniqueness",
		"column_name",
		"descend",
		"column_position",
		"is_include",
		"pk_backed",
	})
	for i := 0; i < rowCount; i++ {
		position := int64((i % 3) + 1)
		isInclude := position == 3
		var order any = "ASC"
		if isInclude {
			order = nil
		} else if position == 2 {
			order = "DESC"
		}
		indexRows.AddRow(
			fmt.Sprintf("idx_bench_%05d", i/3),
			"public",
			"public",
			"bench_table",
			"NONUNIQUE",
			fmt.Sprintf("col_%05d", i),
			order,
			position,
			isInclude,
			false,
		)
	}

	mock.ExpectQuery(postgresIndexesSQL).WithArgs("public", "bench_table").WillReturnRows(indexRows)

	start := time.Now()
	indexes, err := driver.Indexes(&core.TableOptions{Schema: "public", Table: "bench_table"})
	elapsed := time.Since(start)
	require.NoError(tb, err)
	require.NotEmpty(tb, indexes)
	require.NoError(tb, mock.ExpectationsWereMet())
	return elapsed
}

func measurePostgresSequencesParse(tb testing.TB, rowCount int) time.Duration {
	tb.Helper()
	driver, mock, cleanup := newPostgresRichMetadataBenchmarkMock(tb)
	defer cleanup()

	sequenceRows := sqlmock.NewRows([]string{"sequence_name", "increment_by", "cache_size"})
	for i := 0; i < rowCount; i++ {
		sequenceRows.AddRow(fmt.Sprintf("bench_seq_%05d", i), int64((i%11)+1), int64((i%37)+1))
	}
	mock.ExpectQuery(postgresSequencesSQL).WithArgs("public").WillReturnRows(sequenceRows)

	start := time.Now()
	sequences, err := driver.Sequences("public")
	elapsed := time.Since(start)
	require.NoError(tb, err)
	require.Len(tb, sequences, rowCount)
	require.NoError(tb, mock.ExpectationsWereMet())
	return elapsed
}

func newPostgresRichMetadataBenchmarkMock(tb testing.TB) (*postgresDriver, sqlmock.Sqlmock, func()) {
	tb.Helper()
	db, mock, err := sqlmock.New(sqlmock.QueryMatcherOption(sqlmock.QueryMatcherEqual))
	require.NoError(tb, err)
	return &postgresDriver{c: builders.NewClient(db), url: nil}, mock, func() { _ = db.Close() }
}

func postgresDurationPercentile(values []time.Duration, ratio float64) time.Duration {
	if len(values) == 0 {
		return 0
	}
	sorted := append([]time.Duration(nil), values...)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i] < sorted[j]
	})
	index := int(math.Ceil(float64(len(sorted)) * ratio))
	if index < 1 {
		index = 1
	}
	if index > len(sorted) {
		index = len(sorted)
	}
	return sorted[index-1]
}
