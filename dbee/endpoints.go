package main

import (
	"fmt"
	"strings"

	"github.com/neovim/go-client/nvim"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/kndndrj/nvim-dbee/dbee/handler"
	"github.com/kndndrj/nvim-dbee/dbee/plugin"
)

func parseAnyMap(raw any, fieldName string) (map[string]any, error) {
	switch cast := raw.(type) {
	case map[string]any:
		return cast, nil
	case map[any]any:
		out := map[string]any{}
		for k, v := range cast {
			key, ok := k.(string)
			if !ok {
				return nil, fmt.Errorf("%s key must be string, got %T", fieldName, k)
			}
			out[key] = v
		}
		return out, nil
	default:
		return nil, fmt.Errorf("%s must be a map, got %T", fieldName, raw)
	}
}

func stringifyBindValue(bindName string, raw any) (string, error) {
	if raw == nil {
		return "", fmt.Errorf("bind value for %q cannot be nil (use \"null\" typed literal instead)", bindName)
	}

	switch cast := raw.(type) {
	case string:
		return cast, nil
	case []byte:
		// msgpack binary payloads may surface as []byte.
		return string(cast), nil
	case bool:
		if cast {
			return "true", nil
		}
		return "false", nil
	case int, int8, int16, int32, int64:
		return fmt.Sprint(cast), nil
	case uint, uint8, uint16, uint32, uint64:
		return fmt.Sprint(cast), nil
	case float32, float64:
		return fmt.Sprint(cast), nil
	default:
		return "", fmt.Errorf("bind value for %q has unsupported type %T", bindName, raw)
	}
}

func parseQueryBinds(raw any) (map[string]string, error) {
	switch cast := raw.(type) {
	case map[string]string:
		// Defense-in-depth: msgpack currently decodes to map[string]any, but
		// accepting this keeps direct/internal callers flexible.
		out := map[string]string{}
		for k, v := range cast {
			out[k] = v
		}
		return out, nil
	case map[string]any:
		out := map[string]string{}
		for k, v := range cast {
			val, err := stringifyBindValue(k, v)
			if err != nil {
				return nil, err
			}
			out[k] = val
		}
		return out, nil
	case map[any]any:
		// Defense-in-depth for callers that bypass msgpack decoding.
		out := map[string]string{}
		for k, v := range cast {
			key, ok := k.(string)
			if !ok {
				return nil, fmt.Errorf("query option \"binds\" key must be string, got %T", k)
			}
			val, err := stringifyBindValue(key, v)
			if err != nil {
				return nil, err
			}
			out[key] = val
		}
		return out, nil
	default:
		return nil, fmt.Errorf("query option \"binds\" must be a map, got %T", raw)
	}
}

func parseQueryExecuteOptions(raw any) (*core.QueryExecuteOptions, error) {
	if raw == nil {
		return nil, nil
	}

	optsMap, err := parseAnyMap(raw, "query options")
	if err != nil {
		return nil, err
	}

	// Keep this allowlist in sync when adding new query execute options.
	for key := range optsMap {
		if key != "binds" {
			return nil, fmt.Errorf("unsupported query option %q", key)
		}
	}

	bindsRaw, ok := optsMap["binds"]
	if !ok || bindsRaw == nil {
		return nil, nil
	}

	binds, err := parseQueryBinds(bindsRaw)
	if err != nil {
		return nil, err
	}

	if len(binds) == 0 {
		return nil, nil
	}

	return &core.QueryExecuteOptions{Binds: binds}, nil
}

func classifyConnectionTestError(err error) string {
	msg := strings.ToLower(err.Error())
	switch {
	case strings.Contains(msg, "password"),
		strings.Contains(msg, "access denied"),
		strings.Contains(msg, "authentication"),
		strings.Contains(msg, "auth"):
		return "auth"
	case strings.Contains(msg, "timeout"),
		strings.Contains(msg, "refused"),
		strings.Contains(msg, "unreachable"),
		strings.Contains(msg, "network"),
		strings.Contains(msg, "dial"):
		return "network"
	case strings.Contains(msg, "driver"),
		strings.Contains(msg, "adapter"),
		strings.Contains(msg, "unsupported"):
		return "driver"
	default:
		return "unknown"
	}
}

func mountEndpoints(p *plugin.Plugin, h *handler.Handler) {
	p.RegisterEndpoint(
		"DbeeCreateConnection",
		func(args *struct {
			Opts *struct {
				ID   string `msgpack:"id"`
				URL  string `msgpack:"url"`
				Type string `msgpack:"type"`
				Name string `msgpack:"name"`
			} `msgpack:",array"`
		},
		) (core.ConnectionID, error) {
			return h.CreateConnection(&core.ConnectionParams{
				ID:   core.ConnectionID(args.Opts.ID),
				Name: args.Opts.Name,
				Type: args.Opts.Type,
				URL:  args.Opts.URL,
			})
		})

	p.RegisterEndpoint(
		"DbeeDeleteConnection",
		func(args *struct {
			ID string `msgpack:",array"`
		},
		) error {
			return h.DeleteConnection(core.ConnectionID(args.ID))
		})

	p.RegisterEndpoint(
		"DbeeGetConnections",
		func(args *struct {
			IDs []core.ConnectionID `msgpack:",array"`
		},
		) (any, error) {
			return handler.WrapConnections(h.GetConnections(args.IDs)), nil
		})

	p.RegisterEndpoint(
		"DbeeAddHelpers",
		func(args *struct {
			Type    string `msgpack:",array"`
			Helpers map[string]string
		},
		) error {
			return h.AddHelpers(args.Type, args.Helpers)
		})

	p.RegisterEndpoint(
		"DbeeConnectionGetHelpers",
		func(args *struct {
			ID   string `msgpack:",array"`
			Opts *struct {
				Table           string `msgpack:"table"`
				Schema          string `msgpack:"schema"`
				Materialization string `msgpack:"materialization"`
			}
		},
		) (any, error) {
			return h.ConnectionGetHelpers(core.ConnectionID(args.ID), &core.TableOptions{
				Table:           args.Opts.Table,
				Schema:          args.Opts.Schema,
				Materialization: core.StructureTypeFromString(args.Opts.Materialization),
			})
		})

	p.RegisterEndpoint(
		"DbeeSetCurrentConnection",
		func(args *struct {
			ID core.ConnectionID `msgpack:",array"`
		},
		) error {
			return h.SetCurrentConnection(args.ID)
		})

	p.RegisterEndpoint(
		"DbeeGetCurrentConnection",
		func() (any, error) {
			conn, err := h.GetCurrentConnection()
			return handler.WrapConnection(conn), err
		})

	p.RegisterEndpoint(
		"DbeeConnectionExecute",
		func(args *struct {
			ID    core.ConnectionID `msgpack:",array"`
			Query string
			Opts  any
		},
		) (any, error) {
			opts, err := parseQueryExecuteOptions(args.Opts)
			if err != nil {
				return nil, err
			}
			call, err := h.ConnectionExecute(args.ID, args.Query, opts)
			return handler.WrapCall(call), err
		})

	p.RegisterEndpoint(
		"DbeeConnectionGetCalls",
		func(args *struct {
			ID core.ConnectionID `msgpack:",array"`
		},
		) (any, error) {
			calls, err := h.ConnectionGetCalls(args.ID)
			return handler.WrapCalls(calls), err
		})

	p.RegisterEndpoint(
		"DbeeConnectionGetParams",
		func(args *struct {
			ID core.ConnectionID `msgpack:",array"`
		},
		) (any, error) {
			params, err := h.ConnectionGetParams(args.ID)
			return handler.WrapConnectionParams(params), err
		})

	p.RegisterEndpoint(
		"DbeeConnectionTest",
		func(args *struct {
			ID core.ConnectionID `msgpack:",array"`
		},
		) (any, error) {
			err := h.ConnectionTest(args.ID)
			if err == nil {
				return nil, nil
			}

			return map[string]any{
				"error_kind": classifyConnectionTestError(err),
				"message":    err.Error(),
			}, nil
		})

	p.RegisterEndpoint(
		"DbeeConnectionGetStructure",
		func(args *struct {
			ID core.ConnectionID `msgpack:",array"`
		},
		) (any, error) {
			str, err := h.ConnectionGetStructure(args.ID)
			return handler.WrapStructures(str), err
		})

	p.RegisterEndpoint(
		"DbeeConnectionGetStructureAsync",
		func(args *struct {
			ID          core.ConnectionID `msgpack:",array"`
			RequestID   int
			RootEpoch   int
			CallerToken string
		},
		) (any, error) {
			h.ConnectionGetStructureAsync(args.ID, args.RequestID, args.RootEpoch, args.CallerToken)
			return nil, nil
		})

	p.RegisterEndpoint("DbeeConnectionGetColumns", func(args *struct {
		ID   core.ConnectionID `msgpack:",array"`
		Opts *struct {
			Table           string `msgpack:"table"`
			Schema          string `msgpack:"schema"`
			Materialization string `msgpack:"materialization"`
		}
	},
	) (any, error) {
		cols, err := h.ConnectionGetColumns(args.ID, &core.TableOptions{
			Table:           args.Opts.Table,
			Schema:          args.Opts.Schema,
			Materialization: core.StructureTypeFromString(args.Opts.Materialization),
		})
		return handler.WrapColumns(cols), err
	})

	p.RegisterEndpoint("DbeeConnectionGetColumnsAsync", func(args *struct {
		ID        core.ConnectionID `msgpack:",array"`
		RequestID int
		BranchID  string
		RootEpoch int
		Opts      *struct {
			Table           string `msgpack:"table"`
			Schema          string `msgpack:"schema"`
			Materialization string `msgpack:"materialization"`
			Kind            string `msgpack:"kind"`
		}
	},
	) (any, error) {
		if args.Opts == nil {
			return nil, fmt.Errorf("missing async column options")
		}

		h.ConnectionGetColumnsAsync(
			args.ID,
			args.RequestID,
			args.BranchID,
			args.RootEpoch,
			args.Opts.Kind,
			&core.TableOptions{
				Table:           args.Opts.Table,
				Schema:          args.Opts.Schema,
				Materialization: core.StructureTypeFromString(args.Opts.Materialization),
			},
		)
		return nil, nil
	})

	p.RegisterEndpoint(
		"DbeeConnectionListDatabases",
		func(args *struct {
			ID core.ConnectionID `msgpack:",array"`
		},
		) (any, error) {
			current, available, err := h.ConnectionListDatabases(args.ID)
			if err != nil {
				return nil, err
			}
			return []any{current, available}, nil
		})

	p.RegisterEndpoint(
		"DbeeConnectionListDatabasesAsync",
		func(args *struct {
			ID        core.ConnectionID `msgpack:",array"`
			RequestID int
			RootEpoch int
		},
		) (any, error) {
			h.ConnectionListDatabasesAsync(args.ID, args.RequestID, args.RootEpoch)
			return nil, nil
		})

	p.RegisterEndpoint(
		"DbeeConnectionSelectDatabase",
		func(args *struct {
			ID       core.ConnectionID `msgpack:",array"`
			Database string
		},
		) (any, error) {
			return nil, h.ConnectionSelectDatabase(args.ID, args.Database)
		})

	p.RegisterEndpoint(
		"DbeeCallCancel",
		func(args *struct {
			ID core.CallID `msgpack:",array"`
		},
		) (any, error) {
			return nil, h.CallCancel(args.ID)
		})

	p.RegisterEndpoint(
		"DbeeCallDisplayResult",
		func(args *struct {
			ID   core.CallID `msgpack:",array"`
			Opts *struct {
				Buffer int `msgpack:"buffer"`
				From   int `msgpack:"from"`
				To     int `msgpack:"to"`
			}
		},
		) (any, error) {
			return h.CallDisplayResult(args.ID, nvim.Buffer(args.Opts.Buffer), args.Opts.From, args.Opts.To)
		})

	p.RegisterEndpoint(
		"DbeeCallStoreResult",
		func(args *struct {
			ID     core.CallID `msgpack:",array"`
			Format string
			Output string
			Opts   *struct {
				From     int `msgpack:"from"`
				To       int `msgpack:"to"`
				ExtraArg any `msgpack:"extra_arg"`
			}
		},
		) (any, error) {
			return nil, h.CallStoreResult(args.ID, args.Format, args.Output, args.Opts.From, args.Opts.To, args.Opts.ExtraArg)
		})
}
