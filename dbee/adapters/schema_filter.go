package adapters

import (
	"fmt"
	"regexp"
	"sort"
	"strings"

	"github.com/kndndrj/nvim-dbee/dbee/core"
)

const (
	schemaDialectMySQL     = "mysql"
	schemaDialectOracle    = "oracle"
	schemaDialectPostgres  = "postgres"
	schemaDialectSQLServer = "sqlserver"
)

func schemaFilter(opts *core.StructureOptions) *core.SchemaFilterOptions {
	if opts == nil || opts.SchemaFilter == nil {
		return nil
	}
	filter := opts.SchemaFilter
	if len(filter.Include) == 0 && len(filter.Exclude) == 0 {
		return nil
	}
	return filter
}

func schemaFold(value string, opts *core.StructureOptions) string {
	fold := ""
	if opts != nil {
		fold = strings.ToLower(opts.Fold)
	}
	switch fold {
	case "upper":
		return strings.ToUpper(value)
	case "lower", "case_insensitive":
		return strings.ToLower(value)
	default:
		return value
	}
}

func sqlGlobMatches(pattern, value string) bool {
	var b strings.Builder
	b.WriteString("^")
	for _, r := range pattern {
		switch r {
		case '%':
			b.WriteString(".*")
		case '_':
			b.WriteString(".")
		default:
			b.WriteString(regexp.QuoteMeta(string(r)))
		}
	}
	b.WriteString("$")
	ok, err := regexp.MatchString(b.String(), value)
	return err == nil && ok
}

func schemaAllowedByOptions(schema string, opts *core.StructureOptions) bool {
	filter := schemaFilter(opts)
	if filter == nil {
		return true
	}

	folded := schemaFold(schema, opts)
	included := len(filter.Include) == 0
	for _, pattern := range filter.Include {
		if sqlGlobMatches(schemaFold(pattern, opts), folded) {
			included = true
			break
		}
	}
	if !included {
		return false
	}

	for _, pattern := range filter.Exclude {
		if sqlGlobMatches(schemaFold(pattern, opts), folded) {
			return false
		}
	}
	return true
}

func placeholder(dialect string, index int) string {
	switch dialect {
	case schemaDialectPostgres:
		return fmt.Sprintf("$%d", index)
	case schemaDialectOracle:
		return fmt.Sprintf(":%d", index)
	case schemaDialectSQLServer:
		return fmt.Sprintf("@p%d", index)
	default:
		return "?"
	}
}

func usesSQLGlob(pattern string) bool {
	return strings.ContainsAny(pattern, "%_")
}

func schemaPredicate(column string, opts *core.StructureOptions, dialect string, startIndex int) (string, []any, int) {
	filter := schemaFilter(opts)
	if filter == nil {
		return "", nil, startIndex
	}

	args := []any{}
	next := startIndex
	parts := []string{}
	if len(filter.Include) > 0 {
		include := []string{}
		for _, pattern := range filter.Include {
			op := "="
			if usesSQLGlob(pattern) {
				op = "LIKE"
			}
			include = append(include, fmt.Sprintf("%s %s %s", column, op, placeholder(dialect, next)))
			args = append(args, pattern)
			next++
		}
		parts = append(parts, "("+strings.Join(include, " OR ")+")")
	}

	for _, pattern := range filter.Exclude {
		op := "="
		if usesSQLGlob(pattern) {
			op = "LIKE"
		}
		parts = append(parts, fmt.Sprintf("NOT (%s %s %s)", column, op, placeholder(dialect, next)))
		args = append(args, pattern)
		next++
	}

	if len(parts) == 0 {
		return "", nil, next
	}
	return "(" + strings.Join(parts, " AND ") + ")", args, next
}

func schemasFromRows(rows core.ResultStream) ([]*core.SchemaInfo, error) {
	defer rows.Close()

	seen := map[string]bool{}
	var schemas []*core.SchemaInfo
	for rows.HasNext() {
		row, err := rows.Next()
		if err != nil {
			return nil, err
		}
		if len(row) < 1 {
			continue
		}
		name, ok := row[0].(string)
		if !ok || name == "" || seen[name] {
			continue
		}
		seen[name] = true
		schemas = append(schemas, &core.SchemaInfo{Name: name})
	}
	sort.Slice(schemas, func(i, j int) bool {
		return schemas[i].Name < schemas[j].Name
	})
	return schemas, nil
}

func schemaObjectsFromStructure(structure []*core.Structure, schema string) []*core.Structure {
	for _, node := range structure {
		if node == nil {
			continue
		}
		if strings.EqualFold(node.Schema, schema) || strings.EqualFold(node.Name, schema) {
			return node.Children
		}
	}
	return nil
}
