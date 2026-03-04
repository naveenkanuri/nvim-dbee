-- This package is used for triggering lua callbacks from go.
-- It uses unique ids to register the callbacks and trigger them.
local M = {}

---@type table<core_event_name, event_listener[]>
local callbacks = {}

---@param event core_event_name event name to register the callback for
---@param cb event_listener callback function - "data" argument type depends on the event
function M.register(event, cb)
  callbacks[event] = callbacks[event] or {}
  table.insert(callbacks[event], cb)
end

---@param event core_event_name
---@param data any
function M.trigger(event, data)
  if event == "call_state_changed" and data and data.call then
    print(string.format("[TRACE] __events.trigger: event=%s state=%s id=%s",
      event, tostring(data.call.state), tostring(data.call.id):sub(1, 8)))
  end
  vim.schedule(function()
    if event == "call_state_changed" and data and data.call then
      print(string.format("[TRACE] __events.scheduled: state=%s id=%s cbs=%d",
        tostring(data.call.state), tostring(data.call.id):sub(1, 8), #(callbacks[event] or {})))
    end
    local cbs = callbacks[event] or {}
    for _, cb in ipairs(cbs) do
      local ok, err = pcall(cb, data)
      if not ok then
        vim.notify(
          string.format("dbee event listener error (%s): %s", tostring(event), tostring(err)),
          vim.log.levels.ERROR
        )
      end
    end
  end)
end

return M
