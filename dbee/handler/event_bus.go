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

func shortID(raw string) string {
	if len(raw) <= 8 {
		return raw
	}
	return raw[:8]
}

func (eb *eventBus) callLua(event string, data string) {
	luaCode := fmt.Sprintf(`require("dbee.handler.__events").trigger(%q, %s)`, event, data)
	eb.log.Infof("[TRACE] callLua: event=%s, lua_len=%d", event, len(luaCode))
	err := eb.vim.ExecLua(luaCode, nil)
	if err != nil {
		eb.log.Infof("[TRACE] callLua FAILED: event=%s, err=%s", event, err)
	}
}

func (eb *eventBus) CallStateChanged(call *core.Call) {
	state := call.GetState().String()
	callID := string(call.GetID())
	eb.log.Infof("[TRACE] CallStateChanged: id=%s state=%s", shortID(callID), state)

	errMsg := "nil"
	if err := call.Err(); err != nil {
		errMsg = fmt.Sprintf("[[%s]]", err.Error())
	}

	data := fmt.Sprintf(`{
		call = {
			id = %q,
			query = %q,
			state = %q,
			time_taken_us = %d,
			timestamp_us = %d,
			error = %s,
		},
	}`, call.GetID(),
		call.GetQuery(),
		state,
		call.GetTimeTaken().Microseconds(),
		call.GetTimestamp().UnixMicro(),
		errMsg)

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
func (eb *eventBus) StructureLoaded(id core.ConnectionID, structures []*core.Structure, loadErr error) {
	errMsg := "nil"
	if loadErr != nil {
		errMsg = fmt.Sprintf("[[%s]]", loadErr.Error())
	}

	// Serialize structures as Lua table
	structLua := "nil"
	if structures != nil {
		structLua = structuresToLua(structures)
	}

	data := fmt.Sprintf(`{
		conn_id = %q,
		structures = %s,
		error = %s,
	}`, id, structLua, errMsg)

	eb.callLua("structure_loaded", data)
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
