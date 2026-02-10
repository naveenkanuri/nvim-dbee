package main

import (
	"fmt"

	"github.com/neovim/go-client/nvim"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/kndndrj/nvim-dbee/dbee/handler"
	"github.com/kndndrj/nvim-dbee/dbee/plugin"
)

func parseQueryExecuteOptions(raw any) *core.QueryExecuteOptions {
	if raw == nil {
		return nil
	}

	var optsMap map[string]any
	switch cast := raw.(type) {
	case map[string]any:
		optsMap = cast
	case map[any]any:
		optsMap = map[string]any{}
		for k, v := range cast {
			key, ok := k.(string)
			if !ok {
				continue
			}
			optsMap[key] = v
		}
	default:
		return nil
	}

	bindsRaw, ok := optsMap["binds"]
	if !ok || bindsRaw == nil {
		return nil
	}

	binds := map[string]string{}
	switch cast := bindsRaw.(type) {
	case map[string]string:
		for k, v := range cast {
			binds[k] = v
		}
	case map[string]any:
		for k, v := range cast {
			binds[k] = fmt.Sprint(v)
		}
	case map[any]any:
		for k, v := range cast {
			key, ok := k.(string)
			if !ok {
				continue
			}
			binds[key] = fmt.Sprint(v)
		}
	default:
		return nil
	}

	if len(binds) == 0 {
		return nil
	}

	return &core.QueryExecuteOptions{Binds: binds}
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
			opts := parseQueryExecuteOptions(args.Opts)
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
			ID core.ConnectionID `msgpack:",array"`
		},
		) (any, error) {
			h.ConnectionGetStructureAsync(args.ID)
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
