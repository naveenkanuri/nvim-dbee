package core

import (
	"errors"
	"strings"
)

type SchemaType int

const (
	SchemaFul SchemaType = iota
	SchemaLess
)

type (
	// FormatterOptions provide various options for formatters
	FormatterOptions struct {
		SchemaType SchemaType
		ChunkStart int
	}

	// Formatter converts header and rows to bytes
	Formatter interface {
		Format(header Header, rows []Row, opts *FormatterOptions) ([]byte, error)
	}
)

type (
	// SchemaFilterOptions is persisted on ConnectionParams. Missing Include means
	// all schemas; an explicitly empty Include is rejected by Lua validation.
	SchemaFilterOptions struct {
		Include       []string `json:"include,omitempty" msgpack:"include,omitempty"`
		Exclude       []string `json:"exclude,omitempty" msgpack:"exclude,omitempty"`
		LazyPerSchema bool     `json:"lazy_per_schema,omitempty" msgpack:"lazy_per_schema,omitempty"`
	}

	// StructureOptions is the normalized schema scope passed from Lua handler
	// middleware into Go metadata calls. Adapters must not rebuild it from raw
	// ConnectionParams.schema_filter.
	StructureOptions struct {
		SchemaFilter          *SchemaFilterOptions `json:"schema_filter,omitempty" msgpack:"schema_filter,omitempty"`
		SchemaFilterSignature string               `json:"schema_filter_signature,omitempty" msgpack:"schema_filter_signature,omitempty"`
		Fold                  string               `json:"fold,omitempty" msgpack:"fold,omitempty"`
		ConnectionType        string               `json:"connection_type,omitempty" msgpack:"connection_type,omitempty"`
	}

	// SchemaInfo is the schema discovery payload for ListSchemas.
	SchemaInfo struct {
		Name string
	}

	// Row and Header are attributes of IterResult iterator
	Row    []any
	Header []string

	// Meta holds metadata
	Meta struct {
		// type of schema (schemaful or schemaless)
		SchemaType SchemaType
	}

	// ResultStream is a result from executed query and has a form of an iterator
	ResultStream interface {
		Meta() *Meta
		Header() Header
		Next() (Row, error)
		HasNext() bool
		Close()
	}
)

type StructureType int

const (
	StructureTypeNone StructureType = iota
	StructureTypeTable
	StructureTypeView
	StructureTypeMaterializedView
	StructureTypeStreamingTable
	StructureTypeSink
	StructureTypeSource
	StructureTypeManaged
	StructureTypeSchema
	StructureTypeProcedure
	StructureTypeFunction
	StructureTypeIndex
	StructureTypeSequence
)

// String returns the string representation of the StructureType
func (s StructureType) String() string {
	switch s {
	case StructureTypeNone:
		return ""
	case StructureTypeTable:
		return "table"
	case StructureTypeView:
		return "view"
	case StructureTypeMaterializedView:
		return "materialized_view"
	case StructureTypeStreamingTable:
		return "streaming_table"
	case StructureTypeSink:
		return "sink"
	case StructureTypeSource:
		return "source"
	case StructureTypeManaged:
		return "managed"
	case StructureTypeSchema:
		return "schema"
	case StructureTypeProcedure:
		return "procedure"
	case StructureTypeFunction:
		return "function"
	case StructureTypeIndex:
		return "index"
	case StructureTypeSequence:
		return "sequence"
	default:
		return ""
	}
}

// ErrInsufficienStructureInfo is returned when the structure info is insufficient
var ErrInsufficienStructureInfo = errors.New("structure info is insufficient. Expected at least 'schema', 'table' and 'type' columns in that order")

// GetGenericStructure returns a generic structure for an adapter.
// The rows `ResultStream` need to be a query which returns at least 3 string columns:
//  1. schema
//  2. table
//  3. type
//
// in this order.
//
// The `structTypeFn` function is used to determine the `StructureType` based on the type string.
// `structTypeFn` is adapter specific based on `type` pattern.
// The function should return `StructureTypeNone` if the type is unknown.
func GetGenericStructure(rows ResultStream, structTypeFn func(string) StructureType) ([]*Structure, error) {
	children := make(map[string][]*Structure)

	for rows.HasNext() {
		row, err := rows.Next()
		if err != nil {
			return nil, err
		}
		if len(row) < 3 {
			return nil, ErrInsufficienStructureInfo
		}

		errCast := errors.New("expected string, got %T")
		schema, ok := row[0].(string)
		if !ok {
			return nil, errCast
		}
		table, ok := row[1].(string)
		if !ok {
			return nil, errCast
		}
		typ, ok := row[2].(string)
		if !ok {
			return nil, errCast
		}

		children[schema] = append(children[schema], &Structure{
			Name:   table,
			Schema: schema,
			Type:   structTypeFn(typ),
		})
	}

	structure := make([]*Structure, 0, len(children))

	for schema, models := range children {
		structure = append(structure, &Structure{
			Name:     schema,
			Schema:   schema,
			Type:     StructureTypeSchema,
			Children: models,
		})
	}

	return structure, nil
}

func StructureTypeFromString(s string) StructureType {
	switch strings.ToLower(s) {
	case "table":
		return StructureTypeTable
	case "view":
		return StructureTypeView
	case "materialized_view":
		return StructureTypeMaterializedView
	case "streaming_table":
		return StructureTypeStreamingTable
	case "sink":
		return StructureTypeSink
	case "source":
		return StructureTypeSource
	case "managed":
		return StructureTypeManaged
	case "schema":
		return StructureTypeSchema
	case "procedure":
		return StructureTypeProcedure
	case "function":
		return StructureTypeFunction
	case "index":
		return StructureTypeIndex
	case "sequence":
		return StructureTypeSequence
	default:
		return StructureTypeNone
	}
}

// Structure represents the structure of a single database
type Structure struct {
	// Name to be displayed
	Name   string
	Schema string
	// Type of layout
	Type StructureType
	// Children layout nodes
	Children []*Structure
}

type Column struct {
	// Column name
	Name string `json:"name" msgpack:"name"`
	// Database data type
	Type string `json:"type" msgpack:"type"`

	Nullable          *bool    `json:"nullable,omitempty" msgpack:"nullable,omitempty"`
	PrimaryKey        bool     `json:"primary_key,omitempty" msgpack:"primary_key,omitempty"`
	PrimaryKeyOrdinal int      `json:"primary_key_ordinal,omitempty" msgpack:"primary_key_ordinal,omitempty"`
	ForeignKeys       []*FKRef `json:"foreign_keys,omitempty" msgpack:"foreign_keys,omitempty"`
}

type FKRef struct {
	ConstraintName string `json:"constraint_name,omitempty" msgpack:"constraint_name,omitempty"`

	SourceSchema  string   `json:"source_schema,omitempty" msgpack:"source_schema,omitempty"`
	SourceTable   string   `json:"source_table,omitempty" msgpack:"source_table,omitempty"`
	SourceColumn  string   `json:"source_column,omitempty" msgpack:"source_column,omitempty"`
	SourceColumns []string `json:"source_columns,omitempty" msgpack:"source_columns,omitempty"`
	SourceOrdinal int      `json:"source_ordinal,omitempty" msgpack:"source_ordinal,omitempty"`

	TargetSchema  string   `json:"target_schema,omitempty" msgpack:"target_schema,omitempty"`
	TargetTable   string   `json:"target_table,omitempty" msgpack:"target_table,omitempty"`
	TargetColumn  string   `json:"target_column,omitempty" msgpack:"target_column,omitempty"`
	TargetColumns []string `json:"target_columns,omitempty" msgpack:"target_columns,omitempty"`
}

type Index struct {
	Name     string   `json:"name" msgpack:"name"`
	Schema   string   `json:"schema,omitempty" msgpack:"schema,omitempty"`
	Table    string   `json:"table,omitempty" msgpack:"table,omitempty"`
	Columns  []string `json:"columns" msgpack:"columns"`
	Orders   []string `json:"orders,omitempty" msgpack:"orders,omitempty"`
	Unique   bool     `json:"unique,omitempty" msgpack:"unique,omitempty"`
	PKBacked bool     `json:"pk_backed,omitempty" msgpack:"pk_backed,omitempty"`
}

type Sequence struct {
	Name      string `json:"name" msgpack:"name"`
	Schema    string `json:"schema,omitempty" msgpack:"schema,omitempty"`
	Increment int64  `json:"increment,omitempty" msgpack:"increment,omitempty"`
	CacheSize int64  `json:"cache_size,omitempty" msgpack:"cache_size,omitempty"`
}

func cloneStrings(values []string) []string {
	if len(values) == 0 {
		return nil
	}
	out := make([]string, len(values))
	copy(out, values)
	return out
}

func (f *SchemaFilterOptions) Clone() *SchemaFilterOptions {
	if f == nil {
		return nil
	}
	return &SchemaFilterOptions{
		Include:       cloneStrings(f.Include),
		Exclude:       cloneStrings(f.Exclude),
		LazyPerSchema: f.LazyPerSchema,
	}
}

func (o *StructureOptions) Clone() *StructureOptions {
	if o == nil {
		return nil
	}
	return &StructureOptions{
		SchemaFilter:          o.SchemaFilter.Clone(),
		SchemaFilterSignature: o.SchemaFilterSignature,
		Fold:                  o.Fold,
		ConnectionType:        o.ConnectionType,
	}
}
