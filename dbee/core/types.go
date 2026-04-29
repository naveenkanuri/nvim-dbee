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
	case "procedure":
		return StructureTypeProcedure
	case "function":
		return StructureTypeFunction
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
	Name string
	// Database data type
	Type string
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
