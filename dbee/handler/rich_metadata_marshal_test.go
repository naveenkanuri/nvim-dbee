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
	}

	var buf bytes.Buffer
	if err := msgpack.NewEncoder(&buf).Encode(WrapColumns(columns)); err != nil {
		t.Fatalf("encode wrapped columns: %v", err)
	}

	var decoded []columnPayload
	if err := msgpack.NewDecoder(&buf).Decode(&decoded); err != nil {
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

	luaPayload := columnsToLua(columns)
	for _, want := range []string{
		"nullable=false",
		"primary_key=true",
		"primary_key_ordinal=1",
		"foreign_keys={",
		"constraint_name=\"FK_ACCOUNT_CUSTOMER\"",
		"target_columns={\"ID\",\"TENANT_ID\"}",
	} {
		if !strings.Contains(luaPayload, want) {
			t.Fatalf("async column payload missing %q in %s", want, luaPayload)
		}
	}

	t.Log("RICH16_MARSHAL_RICH_FIELDS_PRESERVED_OK=true")
}
