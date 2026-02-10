---@mod dbee.ref.api.core Dbee Core API
---@brief [[
---This module contains functions to operate on the backend side.
---
---Access it like this:
--->
---require("dbee").api.core.func()
---<
---@brief ]]

local state = require("dbee.api.state")

local core = {}

---Returns true if dbee core is loaded.
---@return boolean
function core.is_loaded()
  return state.is_core_loaded()
end

---Registers an event handler for core events.
---@param event core_event_name
---@param listener event_listener
function core.register_event_listener(event, listener)
  state.handler():register_event_listener(event, listener)
end

---Add new source and load connections from it.
---@param source Source
function core.add_source(source)
  state.handler():add_source(source)
end

---Get a list of registered sources.
---@return Source[]
function core.get_sources()
  return state.handler():get_sources()
end

---Reload a source by id.
---@param id source_id
function core.source_reload(id)
  state.handler():source_reload(id)
end

---Add connection to the source.
---In case the source cannot add connections, this call fails.
---@param id source_id
---@param details ConnectionParams
---@return connection_id
function core.source_add_connection(id, details)
  return state.handler():source_add_connection(id, details)
end

---Remove a connection from the source.
---In case the source cannot delete connections, this call fails.
---@param id source_id
---@param conn_id connection_id
function core.source_remove_connection(id, conn_id)
  state.handler():source_remove_connection(id, conn_id)
end

---Update an existing connection from the source.
---In case the source cannot edit connections, this call fails.
---@param id source_id
---@param conn_id connection_id
---@param details ConnectionParams
function core.source_update_connection(id, conn_id, details)
  state.handler():source_update_connection(id, conn_id, details)
end

--- Get a list of connections from source.
---@param id source_id
---@return ConnectionParams[]
function core.source_get_connections(id)
  return state.handler():source_get_connections(id)
end

---Register helper queries per database type.
---every helper value is a go-template with values set for
---"Table", "Schema" and "Materialization".
---@param helpers table<string, table<string, string>> extra helpers per type
---@see table_helpers
---@usage lua [[
---{
---  ["postgres"] = {
---    ["List All"] = "SELECT * FROM {{ .Table }}",
---  }
---}
---@usage ]]
function core.add_helpers(helpers)
  state.handler():add_helpers(helpers)
end

---Get helper queries for a specific connection.
---@param id connection_id
---@param opts TableOpts
---@return table<string, string> _ list of table helpers
---@see table_helpers
function core.connection_get_helpers(id, opts)
  return state.handler():connection_get_helpers(id, opts)
end

---Get the currently active connection.
---@return ConnectionParams|nil
function core.get_current_connection()
  return state.handler():get_current_connection()
end

---Set a currently active connection.
---@param id connection_id
function core.set_current_connection(id)
  state.handler():set_current_connection(id)
end

---Execute a query on a connection.
---@param id connection_id
---@param query string
---@param opts? QueryExecuteOpts
---@return CallDetails
function core.connection_execute(id, query, opts)
  return state.handler():connection_execute(id, query, opts)
end

---Get database structure of a connection.
---@param id connection_id
---@return DBStructure[]
function core.connection_get_structure(id)
  return state.handler():connection_get_structure(id)
end

---Get columns of a table
---@param id connection_id
---@param opts { table: string, schema: string, materialization: string }
---@return Column[]
function core.connection_get_columns(id, opts)
  return state.handler():connection_get_columns(id, opts)
end

---Get parameters that define the connection.
---@param id connection_id
---@return ConnectionParams|nil
function core.connection_get_params(id)
  return state.handler():connection_get_params(id)
end

---List databases of a connection.
---Some databases might not support this - in that case, a call to this
---function returns an error.
---@param id connection_id
---@return string currently selected database
---@return string[] other available databases
function core.connection_list_databases(id)
  return state.handler():connection_list_databases(id)
end

---Select an active database of a connection.
---Some databases might not support this - in that case, a call to this
---function returns an error.
---@param id connection_id
---@param database string
function core.connection_select_database(id, database)
  state.handler():connection_select_database(id, database)
end

---Get a list of past calls of a connection.
---@param id connection_id
---@return CallDetails[]
function core.connection_get_calls(id)
  return state.handler():connection_get_calls(id)
end

---Cancel call execution.
---If call is finished, nothing happens.
---@param id call_id
function core.call_cancel(id)
  state.handler():call_cancel(id)
end

---Display the result of a call formatted as a table in a buffer.
---@param id call_id id of the call
---@param bufnr integer
---@param from integer
---@param to integer
---@return integer total number of rows
function core.call_display_result(id, bufnr, from, to)
  return state.handler():call_display_result(id, bufnr, from, to)
end

---Store the result of a call.
---@param id call_id
---@param format string format of the output -> "csv"|"json"|"table"
---@param output string where to pipe the results -> "file"|"yank"|"buffer"
---@param opts { from: integer, to: integer, extra_arg: any }
function core.call_store_result(id, format, output, opts)
  state.handler():call_store_result(id, format, output, opts)
end

--- Get all connections from all sources with metadata.
---@return { id: connection_id, name: string, type: string, database: string?, is_current: boolean }[]
function core.get_all_connections()
  local handler = state.handler()
  local current = handler:get_current_connection()
  local current_id = current and current.id

  local all_conns = {}
  for _, source in ipairs(handler:get_sources()) do
    for _, conn in ipairs(handler:source_get_connections(source:name())) do
      -- Try to get current database
      local db = ""
      pcall(function()
        db, _ = handler:connection_list_databases(conn.id)
      end)

      table.insert(all_conns, {
        id = conn.id,
        name = conn.name or conn.id,
        type = conn.type or "unknown",
        database = db ~= "" and db or nil,
        is_current = conn.id == current_id,
      })
    end
  end

  return all_conns
end

--- Get call history for all connections with display-friendly metadata.
---@return { call: CallDetails, query_preview: string, state_icon: string, duration: string, time: string, date: string, timestamp: number, conn_name: string, conn_id: string }[]
function core.get_call_history()
  local handler = state.handler()
  local all_conns = core.get_all_connections()

  local history = {}
  for _, conn in ipairs(all_conns) do
    local calls = handler:connection_get_calls(conn.id)
    if calls then
      for _, call in ipairs(calls) do
        -- State icon
        local icon = "?"
        if call.state == "archived" then
          icon = "✓"
        elseif call.state == "executing" or call.state == "retrieving" then
          icon = "⏳"
        elseif call.state == "canceled" then
          icon = "⊘"
        elseif call.state:match("failed$") then
          icon = "✗"
        end

        -- Duration
        local duration = "running"
        if call.time_taken_us and call.time_taken_us > 0 then
          duration = string.format("%.1fs", call.time_taken_us / 1000000)
        end

        -- Time (from timestamp_us) — show date if not today
        local time = ""
        local date_str = ""
        if call.timestamp_us then
          local ts = math.floor(call.timestamp_us / 1000000)
          local today = os.date("%Y-%m-%d")
          local call_date = os.date("%Y-%m-%d", ts)
          if call_date == today then
            time = os.date("%H:%M", ts)
          else
            time = os.date("%m-%d %H:%M", ts)
          end
          date_str = os.date("%Y-%m-%d", ts)
        end

        -- Query preview (first 50 chars, single line)
        local preview = (call.query or ""):gsub("\n", " "):sub(1, 50)
        if #(call.query or "") > 50 then
          preview = preview .. "..."
        end

        table.insert(history, {
          call = call,
          query_preview = preview,
          state_icon = icon,
          duration = duration,
          time = time,
          date = date_str,
          timestamp = call.timestamp_us and math.floor(call.timestamp_us / 1000000) or 0,
          conn_name = conn.name,
          conn_id = conn.id,
        })
      end
    end
  end

  -- Sort by timestamp descending (newest first)
  table.sort(history, function(a, b) return a.timestamp > b.timestamp end)

  return history
end

return core
