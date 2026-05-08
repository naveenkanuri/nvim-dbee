//go:build live_pg20

package integration

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"testing"
	"time"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	th "github.com/kndndrj/nvim-dbee/dbee/tests/testhelpers"
	"github.com/lib/pq"
	"github.com/stretchr/testify/require"
	tc "github.com/testcontainers/testcontainers-go"
)

const historicalBrokenFKSQL = `
	SELECT con.conname AS constraint_name,
	       source_attr.attname AS source_column,
	       fk.ordinal::int AS ordinal,
	       target_ns.nspname AS target_schema,
	       target_cls.relname AS target_table,
	       target_attr.attname AS target_column
	FROM pg_catalog.pg_class source_cls
	JOIN pg_catalog.pg_namespace source_ns
	  ON source_ns.oid = source_cls.relnamespace
	JOIN pg_catalog.pg_constraint con
	  ON con.conrelid = source_cls.oid
	 AND con.contype = 'f'
	JOIN pg_catalog.pg_class target_cls
	  ON target_cls.oid = con.confrelid
	JOIN pg_catalog.pg_namespace target_ns
	  ON target_ns.oid = target_cls.relnamespace
	JOIN LATERAL pg_catalog.unnest(con.conkey, con.confkey)
	     WITH ORDINALITY AS fk(source_attnum, target_attnum, ordinal)
	  ON true
	JOIN pg_catalog.pg_attribute source_attr
	  ON source_attr.attrelid = source_cls.oid
	 AND source_attr.attnum = fk.source_attnum
	JOIN pg_catalog.pg_attribute target_attr
	  ON target_attr.attrelid = target_cls.oid
	 AND target_attr.attnum = fk.target_attnum
	WHERE source_ns.nspname = $1
	  AND source_cls.relname = $2
	  AND source_cls.relkind IN ('r', 'p', 'f')
	ORDER BY con.conname, fk.ordinal`

func TestPostgresLiveRichMetadataSmoke(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	startContainer := time.Now()
	ctr, err := th.NewPostgresRichMetadataContainer(ctx, &core.ConnectionParams{
		ID:   "live-pg20-postgres",
		Name: "live-pg20-postgres",
	})
	require.NoError(t, err)
	t.Cleanup(func() { tc.CleanupContainer(t, ctr) })
	t.Logf("LIVE_PG20_CONTAINER_MS=%d", time.Since(startContainer).Milliseconds())

	startSeed := time.Now()
	verifyPostgresRichMetadataFixture(t, ctx, ctr.ConnURL)
	t.Logf("LIVE_PG20_SEED_MS=%d", time.Since(startSeed).Milliseconds())
	t.Log("LIVE_PG20_CONTAINER_READY_OK=true")
	t.Log("LIVE_PG20_SEED_OK=true")

	var (
		orderItemColumns   []*core.Column
		tableIndexes       []*core.Index
		mvIndexes          []*core.Index
		salesSequences     []*core.Sequence
		inventorySequences []*core.Sequence
	)

	t.Run("Support", func(t *testing.T) {
		support := ctr.Driver.SupportsRichMetadata()
		require.True(t, support.Columns)
		require.True(t, support.Indexes)
		require.True(t, support.Sequences)
		t.Log("LIVE_PG20_SUPPORT_OK=true")
	})

	t.Run("ColumnsRich", func(t *testing.T) {
		cols, err := ctr.Driver.GetColumnsRich(&core.TableOptions{
			Schema:          "pg20_sales",
			Table:           "order_items",
			Materialization: core.StructureTypeTable,
		})
		require.NoError(t, err)
		orderItemColumns = cols

		byName := columnsByName(cols)
		require.ElementsMatch(t, []string{
			"tenant_id", "order_id", "line_no", "item_id", "sku", "quantity", "unit_price", "line_total",
		}, columnNames(cols))
		require.Equal(t, "s", byName["line_total"].Generated)
		require.Equal(t, "a", byName["item_id"].Identity)
		require.NotEmpty(t, byName["quantity"].Default)

		for name, ordinal := range map[string]int{"tenant_id": 1, "order_id": 2, "line_no": 3} {
			col := byName[name]
			require.NotNil(t, col)
			require.NotNil(t, col.Nullable)
			require.False(t, *col.Nullable)
			require.True(t, col.PrimaryKey)
			require.Equal(t, ordinal, col.PrimaryKeyOrdinal)
		}
		t.Log("LIVE_PG20_COMPOSITE_PK_OK=true")

		for name, ordinal := range map[string]int{"tenant_id": 1, "order_id": 2} {
			fk := requireSingleFK(t, byName[name], ordinal)
			require.Equal(t, []string{"tenant_id", "order_id"}, fk.SourceColumns)
			require.Equal(t, []string{"tenant_id", "order_id"}, fk.TargetColumns)
			require.Len(t, fk.SourceColumns, len(fk.TargetColumns))
			require.Equal(t, "pg20_sales", fk.TargetSchema)
			require.Equal(t, "orders", fk.TargetTable)
		}
		require.Empty(t, byName["line_no"].ForeignKeys)
		t.Log("LIVE_PG20_FK_COMPOSITE_OK=true")
		t.Log("LIVE_PG20_ROWS_FROM_LIVE_OK=true")
		t.Log("LIVE_PG20_COLUMNS_RICH_OK=true")
	})

	t.Run("Indexes", func(t *testing.T) {
		indexes, err := ctr.Driver.GetIndexes(&core.TableOptions{
			Schema:          "pg20_sales",
			Table:           "order_items",
			Materialization: core.StructureTypeTable,
		})
		require.NoError(t, err)
		tableIndexes = indexes
		byName := indexesByName(indexes)

		lookup := byName["idx_order_items_lookup"]
		require.NotNil(t, lookup)
		require.False(t, lookup.Unique)
		require.False(t, lookup.PKBacked)
		require.Equal(t, []string{"tenant_id", "order_id"}, lookup.Columns)
		require.Equal(t, []string{"ASC", "DESC"}, lookup.Orders)
		require.Equal(t, []string{"sku", "quantity"}, lookup.IncludeColumns)

		pk := byName["order_items_pkey"]
		require.NotNil(t, pk)
		require.True(t, pk.Unique)
		require.True(t, pk.PKBacked)
		require.Equal(t, []string{"tenant_id", "order_id", "line_no"}, pk.Columns)
		t.Log("LIVE_PG20_INDEXES_OK=true")
	})

	t.Run("MaterializedViewIndexes", func(t *testing.T) {
		indexes, err := ctr.Driver.GetIndexes(&core.TableOptions{
			Schema:          "pg20_analytics",
			Table:           "customer_order_summary",
			Materialization: core.StructureTypeMaterializedView,
		})
		require.NoError(t, err)
		mvIndexes = indexes
		byName := indexesByName(indexes)
		require.NotNil(t, byName["idx_customer_order_summary_customer"])
		lookup := byName["idx_customer_order_summary_lookup"]
		require.NotNil(t, lookup)
		require.Equal(t, []string{"tenant_id", "order_count"}, lookup.Columns)
		require.Equal(t, []string{"ASC", "DESC"}, lookup.Orders)
		require.Equal(t, []string{"total_items"}, lookup.IncludeColumns)
		t.Log("LIVE_PG20_MV_INDEXES_OK=true")
	})

	t.Run("ViewNoIndexes", func(t *testing.T) {
		indexes, err := ctr.Driver.GetIndexes(&core.TableOptions{
			Schema:          "pg20_analytics",
			Table:           "active_customers",
			Materialization: core.StructureTypeView,
		})
		require.NoError(t, err)
		require.Empty(t, indexes)
		t.Log("LIVE_PG20_VIEW_NO_INDEXES_OK=true")
	})

	t.Run("Sequences", func(t *testing.T) {
		var err error
		salesSequences, err = ctr.Driver.GetSequences("pg20_sales")
		require.NoError(t, err)
		inventorySequences, err = ctr.Driver.GetSequences("pg20_inventory")
		require.NoError(t, err)

		invoice := sequencesByName(salesSequences)["invoice_number_seq"]
		require.NotNil(t, invoice)
		require.Equal(t, "pg20_sales", invoice.Schema)
		require.Equal(t, int64(7), invoice.Increment)
		require.Equal(t, int64(11), invoice.CacheSize)

		stock := sequencesByName(inventorySequences)["stock_movement_seq"]
		require.NotNil(t, stock)
		require.Equal(t, "pg20_inventory", stock.Schema)
		require.Equal(t, int64(3), stock.Increment)
		require.Equal(t, int64(5), stock.CacheSize)
		t.Log("LIVE_PG20_SEQUENCE_OK=true")
	})

	t.Run("SchemaScope", func(t *testing.T) {
		salesOrders, err := ctr.Driver.GetColumnsRich(&core.TableOptions{
			Schema:          "pg20_sales",
			Table:           "orders",
			Materialization: core.StructureTypeTable,
		})
		require.NoError(t, err)
		inventoryOrders, err := ctr.Driver.GetColumnsRich(&core.TableOptions{
			Schema:          "pg20_inventory",
			Table:           "orders",
			Materialization: core.StructureTypeTable,
		})
		require.NoError(t, err)
		require.Contains(t, columnNames(salesOrders), "customer_id")
		require.NotContains(t, columnNames(salesOrders), "warehouse_code")
		require.Contains(t, columnNames(inventoryOrders), "warehouse_code")
		require.NotContains(t, columnNames(inventoryOrders), "customer_id")
		require.NotContains(t, sequencesByName(inventorySequences), "invoice_number_seq")
		t.Log("LIVE_PG20_MULTI_SCHEMA_OK=true")
		t.Log("LIVE_PG20_SCHEMA_SCOPE_OK=true")
	})

	t.Run("SnapshotGolden", func(t *testing.T) {
		snapshot := buildPostgresRichMetadataSnapshot(orderItemColumns, tableIndexes, mvIndexes, salesSequences, inventorySequences)
		got, err := json.MarshalIndent(snapshot, "", "  ")
		require.NoError(t, err)
		got = append(got, '\n')

		testdata, err := th.GetTestDataPath()
		require.NoError(t, err)
		path := filepath.Join(testdata, "postgres_rich_metadata_snapshot.json")
		if os.Getenv("UPDATE_GOLDEN") == "1" {
			require.NoError(t, os.WriteFile(path, got, 0o644))
		}
		want, err := os.ReadFile(path)
		require.NoError(t, err)
		require.Equal(t, string(want), string(got))
		t.Log("LIVE_PG20_SNAPSHOT_OK=true")
	})

	t.Run("HistoricalUnnestNegative", func(t *testing.T) {
		db, err := sql.Open("postgres", ctr.ConnURL)
		require.NoError(t, err)
		defer db.Close()

		_, err = db.QueryContext(ctx, historicalBrokenFKSQL, "pg20_sales", "order_items")
		require.Error(t, err)
		var pqErr *pq.Error
		require.True(t, errors.As(err, &pqErr))
		require.Equal(t, pq.ErrorCode("42883"), pqErr.Code)
		require.Contains(t, pqErr.Message, "function pg_catalog.unnest(smallint[], smallint[]) does not exist")
		t.Logf("captured SQLSTATE 42883: %s", pqErr.Code)
		t.Log("LIVE_PG20_NEGATIVE_SQLSTATE_42883_OK=true")
		t.Log("LIVE_PG20_HISTORICAL_UNNEST_NEGATIVE_OK=true")
	})
}

func verifyPostgresRichMetadataFixture(t *testing.T, ctx context.Context, connURL string) {
	t.Helper()
	db, err := sql.Open("postgres", connURL)
	require.NoError(t, err)
	defer db.Close()
	require.NoError(t, db.PingContext(ctx))

	var orderItems, mv, view, salesSeq, inventorySeq bool
	err = db.QueryRowContext(ctx, `
		SELECT to_regclass('pg20_sales.order_items') IS NOT NULL,
		       to_regclass('pg20_analytics.customer_order_summary') IS NOT NULL,
		       to_regclass('pg20_analytics.active_customers') IS NOT NULL,
		       to_regclass('pg20_sales.invoice_number_seq') IS NOT NULL,
		       to_regclass('pg20_inventory.stock_movement_seq') IS NOT NULL`).Scan(
		&orderItems,
		&mv,
		&view,
		&salesSeq,
		&inventorySeq,
	)
	require.NoError(t, err)
	require.True(t, orderItems)
	require.True(t, mv)
	require.True(t, view)
	require.True(t, salesSeq)
	require.True(t, inventorySeq)
}

func requireSingleFK(t *testing.T, col *core.Column, ordinal int) *core.FKRef {
	t.Helper()
	require.NotNil(t, col)
	require.Len(t, col.ForeignKeys, 1)
	fk := col.ForeignKeys[0]
	require.Equal(t, "fk_order_items_order", fk.ConstraintName)
	require.Equal(t, "pg20_sales", fk.SourceSchema)
	require.Equal(t, "order_items", fk.SourceTable)
	require.Equal(t, col.Name, fk.SourceColumn)
	require.Equal(t, ordinal, fk.SourceOrdinal)
	return fk
}

func columnsByName(columns []*core.Column) map[string]*core.Column {
	out := make(map[string]*core.Column, len(columns))
	for _, col := range columns {
		out[col.Name] = col
	}
	return out
}

func columnNames(columns []*core.Column) []string {
	out := make([]string, 0, len(columns))
	for _, col := range columns {
		out = append(out, col.Name)
	}
	return out
}

func indexesByName(indexes []*core.Index) map[string]*core.Index {
	out := make(map[string]*core.Index, len(indexes))
	for _, idx := range indexes {
		out[idx.Name] = idx
	}
	return out
}

func sequencesByName(sequences []*core.Sequence) map[string]*core.Sequence {
	out := make(map[string]*core.Sequence, len(sequences))
	for _, seq := range sequences {
		out[seq.Name] = seq
	}
	return out
}

type pg20Snapshot struct {
	Columns   []pg20ColumnSnapshot   `json:"columns"`
	Indexes   []pg20IndexSnapshot    `json:"indexes"`
	Sequences []pg20SequenceSnapshot `json:"sequences"`
}

type pg20ColumnSnapshot struct {
	Name              string           `json:"name"`
	Schema            string           `json:"schema"`
	Nullable          bool             `json:"nullable"`
	IsPrimaryKey      bool             `json:"is_primary_key"`
	PrimaryKeyOrdinal int              `json:"primary_key_ordinal"`
	IsGenerated       bool             `json:"is_generated"`
	IsIdentity        bool             `json:"is_identity"`
	ForeignKeys       []pg20FKSnapshot `json:"foreign_keys,omitempty"`
}

type pg20FKSnapshot struct {
	SourceColumn  string   `json:"source_column"`
	SourceColumns []string `json:"source_columns"`
	SourceOrdinal int      `json:"source_ordinal"`
	TargetSchema  string   `json:"target_schema"`
	TargetTable   string   `json:"target_table"`
	TargetColumn  string   `json:"target_column"`
	TargetColumns []string `json:"target_columns"`
}

type pg20IndexSnapshot struct {
	Name           string   `json:"name"`
	Schema         string   `json:"schema"`
	Columns        []string `json:"columns"`
	Orders         []string `json:"orders,omitempty"`
	IncludeColumns []string `json:"include_columns,omitempty"`
}

type pg20SequenceSnapshot struct {
	Name      string `json:"name"`
	Schema    string `json:"schema"`
	Increment int64  `json:"increment"`
	CacheSize int64  `json:"cache_size"`
}

func buildPostgresRichMetadataSnapshot(
	columns []*core.Column,
	tableIndexes []*core.Index,
	mvIndexes []*core.Index,
	salesSequences []*core.Sequence,
	inventorySequences []*core.Sequence,
) pg20Snapshot {
	snapshot := pg20Snapshot{}
	for _, col := range columns {
		nullable := false
		if col.Nullable != nil {
			nullable = *col.Nullable
		}
		colSnap := pg20ColumnSnapshot{
			Name:              col.Name,
			Schema:            "pg20_sales",
			Nullable:          nullable,
			IsPrimaryKey:      col.PrimaryKey,
			PrimaryKeyOrdinal: col.PrimaryKeyOrdinal,
			IsGenerated:       col.Generated != "",
			IsIdentity:        col.Identity != "",
		}
		for _, fk := range col.ForeignKeys {
			colSnap.ForeignKeys = append(colSnap.ForeignKeys, pg20FKSnapshot{
				SourceColumn:  fk.SourceColumn,
				SourceColumns: append([]string(nil), fk.SourceColumns...),
				SourceOrdinal: fk.SourceOrdinal,
				TargetSchema:  fk.TargetSchema,
				TargetTable:   fk.TargetTable,
				TargetColumn:  fk.TargetColumn,
				TargetColumns: append([]string(nil), fk.TargetColumns...),
			})
		}
		sort.Slice(colSnap.ForeignKeys, func(i, j int) bool {
			return colSnap.ForeignKeys[i].SourceOrdinal < colSnap.ForeignKeys[j].SourceOrdinal
		})
		snapshot.Columns = append(snapshot.Columns, colSnap)
	}

	for _, idx := range append(append([]*core.Index{}, tableIndexes...), mvIndexes...) {
		snapshot.Indexes = append(snapshot.Indexes, pg20IndexSnapshot{
			Name:           idx.Name,
			Schema:         idx.Schema,
			Columns:        append([]string(nil), idx.Columns...),
			Orders:         append([]string(nil), idx.Orders...),
			IncludeColumns: append([]string(nil), idx.IncludeColumns...),
		})
	}

	for _, seq := range append(append([]*core.Sequence{}, salesSequences...), inventorySequences...) {
		switch seq.Name {
		case "invoice_number_seq", "stock_movement_seq":
			snapshot.Sequences = append(snapshot.Sequences, pg20SequenceSnapshot{
				Name:      seq.Name,
				Schema:    seq.Schema,
				Increment: seq.Increment,
				CacheSize: seq.CacheSize,
			})
		}
	}

	sort.Slice(snapshot.Columns, func(i, j int) bool {
		return snapshot.Columns[i].Name < snapshot.Columns[j].Name
	})
	sort.Slice(snapshot.Indexes, func(i, j int) bool {
		if snapshot.Indexes[i].Schema == snapshot.Indexes[j].Schema {
			return snapshot.Indexes[i].Name < snapshot.Indexes[j].Name
		}
		return snapshot.Indexes[i].Schema < snapshot.Indexes[j].Schema
	})
	sort.Slice(snapshot.Sequences, func(i, j int) bool {
		if snapshot.Sequences[i].Schema == snapshot.Sequences[j].Schema {
			return snapshot.Sequences[i].Name < snapshot.Sequences[j].Name
		}
		return snapshot.Sequences[i].Schema < snapshot.Sequences[j].Schema
	})
	return snapshot
}
