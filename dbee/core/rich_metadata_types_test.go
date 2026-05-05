package core

import (
	"bytes"
	"encoding/json"
	"testing"

	"github.com/neovim/go-client/msgpack"
)

func TestRichMetadataTypesBackwardCompat(t *testing.T) {
	var col Column
	if err := json.Unmarshal([]byte(`{"name":"ID","type":"NUMBER"}`), &col); err != nil {
		t.Fatalf("old column payload decode: %v", err)
	}
	if col.Name != "ID" || col.Type != "NUMBER" {
		t.Fatalf("old column payload mismatch: %#v", col)
	}
	if col.Nullable != nil || col.PrimaryKey || col.PrimaryKeyOrdinal != 0 || len(col.ForeignKeys) != 0 {
		t.Fatalf("rich fields should default to zero values: %#v", col)
	}
	if col.Generated != "" || col.Identity != "" || col.Default != "" || col.SerialSequence != "" {
		t.Fatalf("phase 17 fields should default to zero values: %#v", col)
	}

	type oldColumnJSON struct {
		Name string `json:"name"`
		Type string `json:"type"`
	}
	var oldJSONCol oldColumnJSON
	if err := json.Unmarshal([]byte(`{"name":"ID","type":"NUMBER","generated":"s","identity":"a","default":"nextval('id_seq'::regclass)","serial_sequence":"public.id_seq"}`), &oldJSONCol); err != nil {
		t.Fatalf("new column json decode into old shape: %v", err)
	}
	if oldJSONCol.Name != "ID" || oldJSONCol.Type != "NUMBER" {
		t.Fatalf("new column json old fields mismatch: %#v", oldJSONCol)
	}

	type oldIndexJSON struct {
		Name    string   `json:"name"`
		Columns []string `json:"columns"`
	}
	var oldJSONIndex oldIndexJSON
	if err := json.Unmarshal([]byte(`{"name":"idx_account","columns":["tenant_id"],"include_columns":["updated_at"]}`), &oldJSONIndex); err != nil {
		t.Fatalf("new index json decode into old shape: %v", err)
	}
	if oldJSONIndex.Name != "idx_account" || len(oldJSONIndex.Columns) != 1 || oldJSONIndex.Columns[0] != "tenant_id" {
		t.Fatalf("new index json old fields mismatch: %#v", oldJSONIndex)
	}

	type oldColumnMsgpack struct {
		Name              string   `msgpack:"name"`
		Type              string   `msgpack:"type"`
		Nullable          *bool    `msgpack:"nullable,omitempty"`
		PrimaryKey        bool     `msgpack:"primary_key,omitempty"`
		PrimaryKeyOrdinal int      `msgpack:"primary_key_ordinal,omitempty"`
		ForeignKeys       []*FKRef `msgpack:"foreign_keys,omitempty"`
	}
	nullable := false
	var columnBuf bytes.Buffer
	if err := msgpack.NewEncoder(&columnBuf).Encode(Column{
		Name:              "ID",
		Type:              "NUMBER",
		Nullable:          &nullable,
		PrimaryKey:        true,
		PrimaryKeyOrdinal: 1,
		Generated:         "s",
		Identity:          "a",
		Default:           "nextval('id_seq'::regclass)",
		SerialSequence:    "public.id_seq",
	}); err != nil {
		t.Fatalf("encode new column msgpack: %v", err)
	}
	var oldMsgpackCol oldColumnMsgpack
	if err := msgpack.NewDecoder(&columnBuf).Decode(&oldMsgpackCol); err != nil {
		t.Fatalf("new column msgpack decode into old shape: %v", err)
	}
	if oldMsgpackCol.Name != "ID" || oldMsgpackCol.Type != "NUMBER" || oldMsgpackCol.Nullable == nil || *oldMsgpackCol.Nullable || !oldMsgpackCol.PrimaryKey || oldMsgpackCol.PrimaryKeyOrdinal != 1 {
		t.Fatalf("new column msgpack old fields mismatch: %#v", oldMsgpackCol)
	}

	type oldIndexMsgpack struct {
		Name     string   `msgpack:"name"`
		Schema   string   `msgpack:"schema,omitempty"`
		Table    string   `msgpack:"table,omitempty"`
		Columns  []string `msgpack:"columns"`
		Orders   []string `msgpack:"orders,omitempty"`
		Unique   bool     `msgpack:"unique,omitempty"`
		PKBacked bool     `msgpack:"pk_backed,omitempty"`
	}
	var indexBuf bytes.Buffer
	if err := msgpack.NewEncoder(&indexBuf).Encode(Index{
		Name:           "idx_account",
		Schema:         "public",
		Table:          "account",
		Columns:        []string{"tenant_id"},
		Orders:         []string{"ASC"},
		Unique:         true,
		PKBacked:       false,
		IncludeColumns: []string{"updated_at"},
	}); err != nil {
		t.Fatalf("encode new index msgpack: %v", err)
	}
	var oldMsgpackIndex oldIndexMsgpack
	if err := msgpack.NewDecoder(&indexBuf).Decode(&oldMsgpackIndex); err != nil {
		t.Fatalf("new index msgpack decode into old shape: %v", err)
	}
	if oldMsgpackIndex.Name != "idx_account" || oldMsgpackIndex.Schema != "public" || oldMsgpackIndex.Table != "account" || len(oldMsgpackIndex.Columns) != 1 || oldMsgpackIndex.Columns[0] != "tenant_id" || len(oldMsgpackIndex.Orders) != 1 || oldMsgpackIndex.Orders[0] != "ASC" || !oldMsgpackIndex.Unique {
		t.Fatalf("new index msgpack old fields mismatch: %#v", oldMsgpackIndex)
	}

	if StructureTypeIndex.String() != "index" || StructureTypeSequence.String() != "sequence" {
		t.Fatalf("rich structure type strings mismatch")
	}
	if StructureTypeFromString("index") != StructureTypeIndex || StructureTypeFromString("sequence") != StructureTypeSequence {
		t.Fatalf("rich structure type round-trip mismatch")
	}

	t.Log("RICH16_GO_TYPES_BACKWARD_COMPAT=true")
	t.Log("RICH_PG_GO_TYPES_BACKWARD_COMPAT=true")
}
