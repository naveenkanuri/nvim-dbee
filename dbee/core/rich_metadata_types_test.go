package core

import (
	"encoding/json"
	"testing"
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

	if StructureTypeIndex.String() != "index" || StructureTypeSequence.String() != "sequence" {
		t.Fatalf("rich structure type strings mismatch")
	}
	if StructureTypeFromString("index") != StructureTypeIndex || StructureTypeFromString("sequence") != StructureTypeSequence {
		t.Fatalf("rich structure type round-trip mismatch")
	}

	t.Log("RICH16_GO_TYPES_BACKWARD_COMPAT=true")
}
