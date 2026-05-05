package handler

import (
	"bytes"
	"strings"
	"testing"

	"github.com/neovim/go-client/msgpack"

	"github.com/kndndrj/nvim-dbee/dbee/core"
)

func TestRichColumnMarshalPreservesFields(t *testing.T) {
	nullable := false
	columns := []*core.Column{
		{
			Name:              "ACCOUNT_ID",
			Type:              "NUMBER",
			Nullable:          &nullable,
			PrimaryKey:        true,
			PrimaryKeyOrdinal: 1,
			ForeignKeys: []*core.FKRef{
				{
					ConstraintName: "FK_ACCOUNT_CUSTOMER",
					SourceSchema:   "APP",
					SourceTable:    "ACCOUNT",
					SourceColumn:   "CUSTOMER_ID",
					SourceColumns:  []string{"CUSTOMER_ID", "TENANT_ID"},
					SourceOrdinal:  1,
					TargetSchema:   "APP",
					TargetTable:    "CUSTOMER",
					TargetColumn:   "ID",
					TargetColumns:  []string{"ID", "TENANT_ID"},
				},
			},
			Generated:      "s",
			Identity:       "a",
			Default:        "now()",
			SerialSequence: "public.child_account_legacy_serial_seq",
		},
	}

	type fkPayload struct {
		ConstraintName string   `msgpack:"constraint_name"`
		SourceColumn   string   `msgpack:"source_column"`
		SourceColumns  []string `msgpack:"source_columns"`
		SourceOrdinal  int      `msgpack:"source_ordinal"`
		TargetTable    string   `msgpack:"target_table"`
		TargetColumn   string   `msgpack:"target_column"`
		TargetColumns  []string `msgpack:"target_columns"`
	}
	type columnPayload struct {
		Name              string      `msgpack:"name"`
		Type              string      `msgpack:"type"`
		Nullable          *bool       `msgpack:"nullable"`
		PrimaryKey        bool        `msgpack:"primary_key"`
		PrimaryKeyOrdinal int         `msgpack:"primary_key_ordinal"`
		ForeignKeys       []fkPayload `msgpack:"foreign_keys"`
		Generated         string      `msgpack:"generated"`
		Identity          string      `msgpack:"identity"`
		Default           string      `msgpack:"default"`
		SerialSequence    string      `msgpack:"serial_sequence"`
	}
	type oldColumnPayload struct {
		Name              string      `msgpack:"name"`
		Type              string      `msgpack:"type"`
		Nullable          *bool       `msgpack:"nullable"`
		PrimaryKey        bool        `msgpack:"primary_key"`
		PrimaryKeyOrdinal int         `msgpack:"primary_key_ordinal"`
		ForeignKeys       []fkPayload `msgpack:"foreign_keys"`
	}

	var buf bytes.Buffer
	if err := msgpack.NewEncoder(&buf).Encode(WrapColumns(columns)); err != nil {
		t.Fatalf("encode wrapped columns: %v", err)
	}
	encodedColumns := append([]byte(nil), buf.Bytes()...)

	var decoded []columnPayload
	if err := msgpack.NewDecoder(bytes.NewReader(encodedColumns)).Decode(&decoded); err != nil {
		t.Fatalf("decode wrapped columns: %v", err)
	}
	if len(decoded) != 1 || decoded[0].Name != "ACCOUNT_ID" || decoded[0].Type != "NUMBER" {
		t.Fatalf("decoded basic fields mismatch: %#v", decoded)
	}
	if decoded[0].Nullable == nil || *decoded[0].Nullable || !decoded[0].PrimaryKey || decoded[0].PrimaryKeyOrdinal != 1 {
		t.Fatalf("decoded rich column fields mismatch: %#v", decoded[0])
	}
	if len(decoded[0].ForeignKeys) != 1 {
		t.Fatalf("decoded foreign key count mismatch: %#v", decoded[0].ForeignKeys)
	}
	fk := decoded[0].ForeignKeys[0]
	if fk.ConstraintName != "FK_ACCOUNT_CUSTOMER" || fk.SourceColumn != "CUSTOMER_ID" || fk.TargetColumn != "ID" || fk.SourceOrdinal != 1 {
		t.Fatalf("decoded foreign key scalar mismatch: %#v", fk)
	}
	if strings.Join(fk.SourceColumns, ",") != "CUSTOMER_ID,TENANT_ID" || strings.Join(fk.TargetColumns, ",") != "ID,TENANT_ID" {
		t.Fatalf("decoded foreign key arrays mismatch: %#v", fk)
	}
	if decoded[0].Generated != "s" || decoded[0].Identity != "a" || decoded[0].Default != "now()" ||
		decoded[0].SerialSequence != "public.child_account_legacy_serial_seq" {
		t.Fatalf("decoded postgres column fields mismatch: %#v", decoded[0])
	}

	var oldColumns []oldColumnPayload
	if err := msgpack.NewDecoder(bytes.NewReader(encodedColumns)).Decode(&oldColumns); err != nil {
		t.Fatalf("decode wrapped columns into old payload: %v", err)
	}
	if len(oldColumns) != 1 || oldColumns[0].Name != "ACCOUNT_ID" || oldColumns[0].Type != "NUMBER" ||
		oldColumns[0].Nullable == nil || *oldColumns[0].Nullable || !oldColumns[0].PrimaryKey ||
		oldColumns[0].PrimaryKeyOrdinal != 1 || len(oldColumns[0].ForeignKeys) != 1 {
		t.Fatalf("old column payload fields not preserved: %#v", oldColumns)
	}

	luaPayload := columnsToLua(columns)
	for _, want := range []string{
		"nullable=false",
		"primary_key=true",
		"primary_key_ordinal=1",
		"foreign_keys={",
		"constraint_name=\"FK_ACCOUNT_CUSTOMER\"",
		"target_columns={\"ID\",\"TENANT_ID\"}",
		"generated=\"s\"",
		"identity=\"a\"",
		"default=\"now()\"",
		"serial_sequence=\"public.child_account_legacy_serial_seq\"",
	} {
		if !strings.Contains(luaPayload, want) {
			t.Fatalf("async column payload missing %q in %s", want, luaPayload)
		}
	}
	emptyColumnLuaPayload := columnsToLua([]*core.Column{{Name: "EMPTY_FIELD_CHECK", Type: "TEXT"}})
	for _, want := range []string{
		"generated=nil",
		"identity=nil",
		"default=nil",
		"serial_sequence=nil",
	} {
		if !strings.Contains(emptyColumnLuaPayload, want) {
			t.Fatalf("async empty column payload missing %q in %s", want, emptyColumnLuaPayload)
		}
	}

	indexes := []*core.Index{
		{
			Name:           "IDX_ACCOUNT_LOOKUP",
			Schema:         "APP",
			Table:          "ACCOUNT",
			Columns:        []string{"CUSTOMER_ID"},
			Orders:         []string{"ASC"},
			Unique:         true,
			PKBacked:       true,
			IncludeColumns: []string{"payload"},
		},
	}
	type indexPayload struct {
		Name           string   `msgpack:"name"`
		Schema         string   `msgpack:"schema"`
		Table          string   `msgpack:"table"`
		Columns        []string `msgpack:"columns"`
		Orders         []string `msgpack:"orders"`
		Unique         bool     `msgpack:"unique"`
		PKBacked       bool     `msgpack:"pk_backed"`
		IncludeColumns []string `msgpack:"include_columns"`
	}
	type oldIndexPayload struct {
		Name     string   `msgpack:"name"`
		Schema   string   `msgpack:"schema"`
		Table    string   `msgpack:"table"`
		Columns  []string `msgpack:"columns"`
		Orders   []string `msgpack:"orders"`
		Unique   bool     `msgpack:"unique"`
		PKBacked bool     `msgpack:"pk_backed"`
	}

	var indexBuf bytes.Buffer
	if err := msgpack.NewEncoder(&indexBuf).Encode(WrapIndexes(indexes)); err != nil {
		t.Fatalf("encode wrapped indexes: %v", err)
	}
	encodedIndexes := append([]byte(nil), indexBuf.Bytes()...)

	var decodedIndexes []indexPayload
	if err := msgpack.NewDecoder(bytes.NewReader(encodedIndexes)).Decode(&decodedIndexes); err != nil {
		t.Fatalf("decode wrapped indexes: %v", err)
	}
	if len(decodedIndexes) != 1 || decodedIndexes[0].Name != "IDX_ACCOUNT_LOOKUP" ||
		strings.Join(decodedIndexes[0].Columns, ",") != "CUSTOMER_ID" ||
		strings.Join(decodedIndexes[0].Orders, ",") != "ASC" || !decodedIndexes[0].Unique ||
		!decodedIndexes[0].PKBacked || strings.Join(decodedIndexes[0].IncludeColumns, ",") != "payload" {
		t.Fatalf("decoded index fields mismatch: %#v", decodedIndexes)
	}

	var oldIndexes []oldIndexPayload
	if err := msgpack.NewDecoder(bytes.NewReader(encodedIndexes)).Decode(&oldIndexes); err != nil {
		t.Fatalf("decode wrapped indexes into old payload: %v", err)
	}
	if len(oldIndexes) != 1 || oldIndexes[0].Name != "IDX_ACCOUNT_LOOKUP" ||
		oldIndexes[0].Schema != "APP" || oldIndexes[0].Table != "ACCOUNT" ||
		strings.Join(oldIndexes[0].Columns, ",") != "CUSTOMER_ID" ||
		strings.Join(oldIndexes[0].Orders, ",") != "ASC" || !oldIndexes[0].Unique || !oldIndexes[0].PKBacked {
		t.Fatalf("old index payload fields not preserved: %#v", oldIndexes)
	}

	indexLuaPayload := indexesToLua(indexes)
	if !strings.Contains(indexLuaPayload, `include_columns={"payload"}`) {
		t.Fatalf("async index payload missing include_columns in %s", indexLuaPayload)
	}

	t.Log("RICH16_MARSHAL_RICH_FIELDS_PRESERVED_OK=true")
	t.Log("RICH_PG_MARSHAL_ADDITIVE_FIELDS_OK=true")
}
