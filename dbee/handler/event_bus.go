package handler

import (
	"fmt"
	"strings"

	"github.com/neovim/go-client/nvim"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/kndndrj/nvim-dbee/dbee/plugin"
)

type eventBus struct {
	vim *nvim.Nvim
	log *plugin.Logger
}

func luaStringLiteral(value string) string {
	return fmt.Sprintf("%q", value)
}

func (eb *eventBus) callLua(event string, data string) {
	err := eb.vim.ExecLua(fmt.Sprintf(`require("dbee.handler.__events").trigger(%q, %s)`, event, data), nil)
	if err != nil {
		eb.log.Infof("eb.vim.ExecLua: %s", err)
	}
}

func (eb *eventBus) CallStateChanged(connID core.ConnectionID, call *core.Call) {
	errMsg := "nil"
	if err := call.Err(); err != nil {
		errMsg = luaStringLiteral(err.Error())
	}

	data := fmt.Sprintf(`{
		conn_id = %q,
		call = {
			id = %q,
			query = %q,
			state = %q,
			time_taken_us = %d,
			timestamp_us = %d,
			error = %s,
			error_kind = %q,
		},
	}`, connID,
		call.GetID(),
		call.GetQuery(),
		call.GetState().String(),
		call.GetTimeTaken().Microseconds(),
		call.GetTimestamp().UnixMicro(),
		errMsg,
		call.ErrorKind())

	eb.callLua("call_state_changed", data)
}

func (eb *eventBus) CurrentConnectionChanged(id core.ConnectionID) {
	data := fmt.Sprintf(`{
		conn_id = %q,
	}`, id)

	eb.callLua("current_connection_changed", data)
}

// DatabaseSelected is called when the selected database of a connection is changed.
// Sends the new database name along with affected connection ID to the lua event handler.
func (eb *eventBus) DatabaseSelected(id core.ConnectionID, dbname string) {
	data := fmt.Sprintf(`{
		conn_id = %q,
		database_name = %q,
	}`, id, dbname)

	eb.callLua("database_selected", data)
}

// StructureLoaded is called when async structure loading completes.
func (eb *eventBus) StructureLoaded(
	id core.ConnectionID,
	requestID int,
	rootEpoch int,
	callerToken string,
	structures []*core.Structure,
	loadErr error,
) {
	errMsg := "nil"
	if loadErr != nil {
		errMsg = luaStringLiteral(loadErr.Error())
	}

	// Serialize structures as Lua table
	structLua := "nil"
	if structures != nil {
		structLua = structuresToLua(structures)
	}

	rootEpochLua := "nil"
	if rootEpoch > 0 {
		rootEpochLua = fmt.Sprintf("%d", rootEpoch)
	}

	callerTokenLua := "nil"
	if callerToken != "" {
		callerTokenLua = luaStringLiteral(callerToken)
	}

	data := fmt.Sprintf(`{
			conn_id = %q,
			request_id = %d,
			root_epoch = %s,
			caller_token = %s,
			structures = %s,
			error = %s,
		}`, id, requestID, rootEpochLua, callerTokenLua, structLua, errMsg)

	eb.callLua("structure_loaded", data)
}

// StructureChildrenLoaded is called when async child loading completes.
func (eb *eventBus) StructureChildrenLoaded(
	id core.ConnectionID,
	requestID int,
	branchID string,
	rootEpoch int,
	kind string,
	columns []*core.Column,
	loadErr error,
) {
	errMsg := "nil"
	if loadErr != nil {
		errMsg = luaStringLiteral(loadErr.Error())
	}

	columnsLua := "nil"
	if columns != nil {
		columnsLua = columnsToLua(columns)
	}

	data := fmt.Sprintf(`{
		conn_id = %q,
		request_id = %d,
		branch_id = %q,
		root_epoch = %d,
		kind = %q,
		columns = %s,
		error = %s,
	}`, id, requestID, branchID, rootEpoch, kind, columnsLua, errMsg)

	eb.callLua("structure_children_loaded", data)
}

func (eb *eventBus) ConnectionDatabasesLoaded(
	id core.ConnectionID,
	requestID int,
	rootEpoch int,
	current string,
	available []string,
	loadErr error,
) {
	errMsg := "nil"
	if loadErr != nil {
		errMsg = luaStringLiteral(loadErr.Error())
	}

	databasesLua := "nil"
	if loadErr == nil {
		databasesLua = fmt.Sprintf(`{ current = %q, available = %s }`, current, stringsToLua(available))
	}

	data := fmt.Sprintf(`{
		conn_id = %q,
		request_id = %d,
		root_epoch = %d,
		databases = %s,
		error = %s,
	}`, id, requestID, rootEpoch, databasesLua, errMsg)

	eb.callLua("connection_databases_loaded", data)
}

// structuresToLua serializes []*core.Structure to a Lua table literal.
func structuresToLua(structures []*core.Structure) string {
	var b strings.Builder
	b.WriteString("{")
	for i, s := range structures {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(fmt.Sprintf(`{name=%q,schema=%q,type=%q,children=%s}`,
			s.Name, s.Schema, s.Type.String(), structuresToLua(s.Children)))
	}
	b.WriteString("}")
	return b.String()
}

func columnsToLua(columns []*core.Column) string {
	var b strings.Builder
	b.WriteString("{")
	for i, c := range columns {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(fmt.Sprintf(`{name=%q,type=%q}`, c.Name, c.Type))
	}
	b.WriteString("}")
	return b.String()
}

func stringsToLua(values []string) string {
	var b strings.Builder
	b.WriteString("{")
	for i, value := range values {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(fmt.Sprintf("%q", value))
	}
	b.WriteString("}")
	return b.String()
}
