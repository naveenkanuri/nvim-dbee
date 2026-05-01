package handler

import (
	"github.com/neovim/go-client/msgpack"

	"github.com/kndndrj/nvim-dbee/dbee/core"
)

// callWrap is a wrapper around core.Call with msgpack marshaling capabilities
type callWrap struct {
	call *core.Call
}

func WrapCall(call *core.Call) *callWrap {
	return &callWrap{
		call: call,
	}
}

func WrapCalls(calls []*core.Call) []*callWrap {
	wraps := make([]*callWrap, len(calls))

	for i := range calls {
		wraps[i] = &callWrap{
			call: calls[i],
		}
	}

	return wraps
}

func (cw *callWrap) MarshalMsgPack(enc *msgpack.Encoder) error {
	if cw.call == nil {
		return enc.Encode(nil)
	}

	errMsg := ""
	if err := cw.call.Err(); err != nil {
		errMsg = err.Error()
	}

	return enc.Encode(&struct {
		ID        string `msgpack:"id"`
		Query     string `msgpack:"query"`
		State     string `msgpack:"state"`
		TimeTaken int64  `msgpack:"time_taken_us"`
		Timestamp int64  `msgpack:"timestamp_us"`
		Error     string `msgpack:"error,omitempty"`
		ErrorKind string `msgpack:"error_kind,omitempty"`
	}{
		ID:        string(cw.call.GetID()),
		Query:     cw.call.GetQuery(),
		State:     cw.call.GetState().String(),
		TimeTaken: cw.call.GetTimeTaken().Microseconds(),
		Timestamp: cw.call.GetTimestamp().UnixMicro(),
		Error:     errMsg,
		ErrorKind: cw.call.ErrorKind(),
	})
}

// connectionWrap is wrapper around core.Connection with msgpack marshaling capabilities
type connectionWrap struct {
	connection *core.Connection
}

func WrapConnection(connection *core.Connection) *connectionWrap {
	return &connectionWrap{
		connection: connection,
	}
}

func WrapConnections(connections []*core.Connection) []*connectionWrap {
	wraps := make([]*connectionWrap, len(connections))

	for i := range connections {
		wraps[i] = &connectionWrap{
			connection: connections[i],
		}
	}

	return wraps
}

func (cw *connectionWrap) MarshalMsgPack(enc *msgpack.Encoder) error {
	if cw.connection == nil {
		return enc.Encode(nil)
	}
	return enc.Encode(&struct {
		ID           string                    `msgpack:"id"`
		Name         string                    `msgpack:"name"`
		Type         string                    `msgpack:"type"`
		URL          string                    `msgpack:"url"`
		SchemaFilter *core.SchemaFilterOptions `msgpack:"schema_filter,omitempty"`
	}{
		ID:           string(cw.connection.GetID()),
		Name:         cw.connection.GetName(),
		Type:         cw.connection.GetType(),
		URL:          cw.connection.GetURL(),
		SchemaFilter: cw.connection.GetSchemaFilter(),
	})
}

// connectionParamsWrap is wrapper around core.ConnectionParams with msgpack marshaling capabilities
type connectionParamsWrap struct {
	params *core.ConnectionParams
}

func WrapConnectionParams(params *core.ConnectionParams) *connectionParamsWrap {
	return &connectionParamsWrap{
		params: params,
	}
}

func (cw *connectionParamsWrap) MarshalMsgPack(enc *msgpack.Encoder) error {
	if cw.params == nil {
		return enc.Encode(nil)
	}
	return enc.Encode(&struct {
		ID           string                    `msgpack:"id"`
		Name         string                    `msgpack:"name"`
		Type         string                    `msgpack:"type"`
		URL          string                    `msgpack:"url"`
		SchemaFilter *core.SchemaFilterOptions `msgpack:"schema_filter,omitempty"`
	}{
		ID:           string(cw.params.ID),
		Name:         cw.params.Name,
		Type:         cw.params.Type,
		URL:          cw.params.URL,
		SchemaFilter: cw.params.SchemaFilter.Clone(),
	})
}

// structureWrap is a wrapper around core.Structure with msgpack marshaling capabilities
type structureWrap struct {
	structure *core.Structure
}

func WrapStructure(structure *core.Structure) *structureWrap {
	return &structureWrap{
		structure: structure,
	}
}

func WrapStructures(structures []*core.Structure) []*structureWrap {
	wraps := make([]*structureWrap, len(structures))

	for i := range structures {
		wraps[i] = &structureWrap{
			structure: structures[i],
		}
	}

	return wraps
}

type schemaWrap struct {
	schema *core.SchemaInfo
}

func WrapSchemas(schemas []*core.SchemaInfo) []*schemaWrap {
	wraps := make([]*schemaWrap, len(schemas))
	for i := range schemas {
		wraps[i] = &schemaWrap{schema: schemas[i]}
	}
	return wraps
}

func (sw *schemaWrap) MarshalMsgPack(enc *msgpack.Encoder) error {
	if sw.schema == nil {
		return enc.Encode(nil)
	}
	return enc.Encode(&struct {
		Name string `msgpack:"name"`
	}{
		Name: sw.schema.Name,
	})
}

func (cw *structureWrap) MarshalMsgPack(enc *msgpack.Encoder) error {
	if cw.structure == nil {
		return enc.Encode(nil)
	}
	return enc.Encode(&struct {
		Name     string           `msgpack:"name"`
		Schema   string           `msgpack:"schema"`
		Type     string           `msgpack:"type"`
		Children []*structureWrap `msgpack:"children"`
	}{
		Name:     cw.structure.Name,
		Schema:   cw.structure.Schema,
		Type:     cw.structure.Type.String(),
		Children: WrapStructures(cw.structure.Children),
	})
}

// columnWrap is a wrapper around core.Column with msgpack marshaling capabilities
type columnWrap struct {
	column *core.Column
}

type fkRefWrap struct {
	fk *core.FKRef
}

type indexWrap struct {
	index *core.Index
}

type sequenceWrap struct {
	sequence *core.Sequence
}

func WrapColumn(column *core.Column) *columnWrap {
	return &columnWrap{
		column: column,
	}
}

func WrapColumns(columns []*core.Column) []*columnWrap {
	wraps := make([]*columnWrap, len(columns))

	for i := range columns {
		wraps[i] = &columnWrap{
			column: columns[i],
		}
	}

	return wraps
}

func wrapFKRefs(refs []*core.FKRef) []*fkRefWrap {
	wraps := make([]*fkRefWrap, len(refs))
	for i := range refs {
		wraps[i] = &fkRefWrap{fk: refs[i]}
	}
	return wraps
}

func WrapIndexes(indexes []*core.Index) []*indexWrap {
	wraps := make([]*indexWrap, len(indexes))
	for i := range indexes {
		wraps[i] = &indexWrap{index: indexes[i]}
	}
	return wraps
}

func WrapSequences(sequences []*core.Sequence) []*sequenceWrap {
	wraps := make([]*sequenceWrap, len(sequences))
	for i := range sequences {
		wraps[i] = &sequenceWrap{sequence: sequences[i]}
	}
	return wraps
}

func (cw *columnWrap) MarshalMsgPack(enc *msgpack.Encoder) error {
	if cw.column == nil {
		return enc.Encode(nil)
	}
	return enc.Encode(&struct {
		Name              string       `msgpack:"name"`
		Type              string       `msgpack:"type"`
		Nullable          *bool        `msgpack:"nullable,omitempty"`
		PrimaryKey        bool         `msgpack:"primary_key,omitempty"`
		PrimaryKeyOrdinal int          `msgpack:"primary_key_ordinal,omitempty"`
		ForeignKeys       []*fkRefWrap `msgpack:"foreign_keys,omitempty"`
	}{
		Name:              cw.column.Name,
		Type:              cw.column.Type,
		Nullable:          cw.column.Nullable,
		PrimaryKey:        cw.column.PrimaryKey,
		PrimaryKeyOrdinal: cw.column.PrimaryKeyOrdinal,
		ForeignKeys:       wrapFKRefs(cw.column.ForeignKeys),
	})
}

func (fw *fkRefWrap) MarshalMsgPack(enc *msgpack.Encoder) error {
	if fw.fk == nil {
		return enc.Encode(nil)
	}
	return enc.Encode(&struct {
		ConstraintName string   `msgpack:"constraint_name,omitempty"`
		SourceSchema   string   `msgpack:"source_schema,omitempty"`
		SourceTable    string   `msgpack:"source_table,omitempty"`
		SourceColumn   string   `msgpack:"source_column,omitempty"`
		SourceColumns  []string `msgpack:"source_columns,omitempty"`
		SourceOrdinal  int      `msgpack:"source_ordinal,omitempty"`
		TargetSchema   string   `msgpack:"target_schema,omitempty"`
		TargetTable    string   `msgpack:"target_table,omitempty"`
		TargetColumn   string   `msgpack:"target_column,omitempty"`
		TargetColumns  []string `msgpack:"target_columns,omitempty"`
	}{
		ConstraintName: fw.fk.ConstraintName,
		SourceSchema:   fw.fk.SourceSchema,
		SourceTable:    fw.fk.SourceTable,
		SourceColumn:   fw.fk.SourceColumn,
		SourceColumns:  fw.fk.SourceColumns,
		SourceOrdinal:  fw.fk.SourceOrdinal,
		TargetSchema:   fw.fk.TargetSchema,
		TargetTable:    fw.fk.TargetTable,
		TargetColumn:   fw.fk.TargetColumn,
		TargetColumns:  fw.fk.TargetColumns,
	})
}

func (iw *indexWrap) MarshalMsgPack(enc *msgpack.Encoder) error {
	if iw.index == nil {
		return enc.Encode(nil)
	}
	return enc.Encode(&struct {
		Name     string   `msgpack:"name"`
		Schema   string   `msgpack:"schema,omitempty"`
		Table    string   `msgpack:"table,omitempty"`
		Columns  []string `msgpack:"columns"`
		Orders   []string `msgpack:"orders,omitempty"`
		Unique   bool     `msgpack:"unique,omitempty"`
		PKBacked bool     `msgpack:"pk_backed,omitempty"`
	}{
		Name:     iw.index.Name,
		Schema:   iw.index.Schema,
		Table:    iw.index.Table,
		Columns:  iw.index.Columns,
		Orders:   iw.index.Orders,
		Unique:   iw.index.Unique,
		PKBacked: iw.index.PKBacked,
	})
}

func (sw *sequenceWrap) MarshalMsgPack(enc *msgpack.Encoder) error {
	if sw.sequence == nil {
		return enc.Encode(nil)
	}
	return enc.Encode(&struct {
		Name      string `msgpack:"name"`
		Schema    string `msgpack:"schema,omitempty"`
		Increment int64  `msgpack:"increment,omitempty"`
		CacheSize int64  `msgpack:"cache_size,omitempty"`
	}{
		Name:      sw.sequence.Name,
		Schema:    sw.sequence.Schema,
		Increment: sw.sequence.Increment,
		CacheSize: sw.sequence.CacheSize,
	})
}
