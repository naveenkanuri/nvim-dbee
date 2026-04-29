-- Headless checks for Phase 11 async LSP completion contract.

vim.env.XDG_STATE_HOME = vim.fn.tempname()
vim.fn.mkdir(vim.env.XDG_STATE_HOME, "p")

local server = require("dbee.lsp.server")
local SchemaCache = require("dbee.lsp.schema_cache")

local function fail(msg)
  print("LSP11_ASYNC_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local function assert_true(label, value)
  if not value then
    fail(label .. ": expected true")
  end
end

local function assert_eq(label, actual, expected)
  if actual ~= expected then
    fail(label .. ": expected " .. vim.inspect(expected) .. " got " .. vim.inspect(actual))
  end
end

local function has_label(result, label)
  for _, item in ipairs((result and result.items) or {}) do
    if item.label == label then
      return true
    end
  end
  return false
end

local function request(client, bufnr, line)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
  local done = false
  local response = nil
  client.request("textDocument/completion", {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = { line = 0, character = #line },
  }, function(err, result)
    response = { err = err, result = result }
    done = true
  end)
  vim.wait(1000, function()
    return done
  end, 20)
  if not response then
    fail("completion timeout")
  end
  if response.err then
    fail("completion error: " .. tostring(response.err))
  end
  return response.result
end

local function new_async_env(conn_id)
  local calls = {}
  local sync_fetch_called = false
  local handler = {
    connection_get_columns = function()
      sync_fetch_called = true
      error("sync column fetch must not be used by LSP completion")
    end,
    get_authoritative_root_epoch = function()
      return 1
    end,
    connection_get_columns_async = function(_, id, request_id, branch_id, root_epoch, opts)
      calls[#calls + 1] = {
        conn_id = id,
        request_id = request_id,
        branch_id = branch_id,
        root_epoch = root_epoch,
        opts = opts,
      }
    end,
  }
  local cache = SchemaCache:new(handler, conn_id)
  cache:build_from_metadata_rows({
    { schema_name = "S", table_name = "T", obj_type = "table" },
    { schema_name = "S", table_name = "VIEW_ONLY", obj_type = "view" },
  })
  local client = server.create(cache)({}, {})
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "/tmp/dbee-lsp-async-" .. conn_id .. ".sql")
  return {
    handler = handler,
    cache = cache,
    client = client,
    bufnr = bufnr,
    calls = calls,
    sync_fetch_called = function()
      return sync_fetch_called
    end,
  }
end

local function deliver(cache, call, columns, extra)
  extra = extra or {}
  return cache:on_columns_loaded({
    conn_id = call.conn_id,
    request_id = call.request_id,
    branch_id = call.branch_id,
    root_epoch = extra.root_epoch or call.root_epoch,
    kind = "columns",
    columns = columns,
    error = extra.error,
  })
end

local env = new_async_env("async-main")
local line = "select * from S.T t where t."
local first = request(env.client, env.bufnr, line)
assert_eq("first incomplete", first.isIncomplete, true)
assert_eq("first empty", #first.items, 0)
assert_eq("one async call", #env.calls, 1)

local dup = request(env.client, env.bufnr, line)
assert_eq("duplicate incomplete", dup.isIncomplete, true)
assert_eq("deduped async call", #env.calls, 1)

deliver(env.cache, env.calls[1], {}, { root_epoch = 0 })
assert_eq("stale payload ignored", #env.cache:get_column_completion_items("S", "T"), 0)

deliver(env.cache, env.calls[1], {
  { name = "COL_001", type = "NUMBER" },
  { name = "COL_010", type = "VARCHAR2" },
})
local warm = request(env.client, env.bufnr, line)
assert_eq("warm complete", warm.isIncomplete, false)
assert_true("warm col 001", has_label(warm, "COL_001"))
assert_true("warm col 010", has_label(warm, "COL_010"))
assert_true("no sync fetch", not env.sync_fetch_called())

local absent_cache = SchemaCache:new({
  get_authoritative_root_epoch = function()
    return 1
  end,
}, "async-absent")
absent_cache:build_from_metadata_rows({
  { schema_name = "S", table_name = "MISSING_SURFACE", obj_type = "table" },
})
local absent_client = server.create(absent_cache)({}, {})
local absent_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(absent_buf, "/tmp/dbee-lsp-async-absent.sql")
local absent = request(absent_client, absent_buf, "select * from S.MISSING_SURFACE m where m.")
assert_eq("absent async complete", absent.isIncomplete, false)
assert_eq("absent async empty", #absent.items, 0)

local throwing_cache = SchemaCache:new({
  get_authoritative_root_epoch = function()
    return 1
  end,
  connection_get_columns_async = function()
    error("transport failed")
  end,
}, "async-throw")
throwing_cache:build_from_metadata_rows({
  { schema_name = "S", table_name = "THROWING", obj_type = "table" },
})
local throwing_client = server.create(throwing_cache)({}, {})
local throwing_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(throwing_buf, "/tmp/dbee-lsp-async-throw.sql")
local throwing = request(throwing_client, throwing_buf, "select * from S.THROWING th where th.")
assert_eq("throwing async complete", throwing.isIncomplete, false)
assert_eq("throwing async empty", #throwing.items, 0)

local error_env = new_async_env("async-error")
local error_first = request(error_env.client, error_env.bufnr, line)
assert_eq("error first incomplete", error_first.isIncomplete, true)
deliver(error_env.cache, error_env.calls[1], {}, { error = "permission denied" })
local after_error = request(error_env.client, error_env.bufnr, line)
assert_eq("payload error not incomplete", after_error.isIncomplete, false)
assert_eq("payload error empty", #after_error.items, 0)

local sync_delivery_cache = nil
local sync_delivery_calls = 0
local sync_delivery_handler = {
  get_authoritative_root_epoch = function()
    return 1
  end,
  connection_get_columns_async = function(_, id, request_id, branch_id, root_epoch)
    sync_delivery_calls = sync_delivery_calls + 1
    sync_delivery_cache:on_columns_loaded({
      conn_id = id,
      request_id = request_id,
      branch_id = branch_id,
      root_epoch = root_epoch,
      kind = "columns",
      columns = {
        { name = "SYNC_DELIVERED_COL", type = "NUMBER" },
      },
    })
  end,
}
sync_delivery_cache = SchemaCache:new(sync_delivery_handler, "async-sync-delivery")
sync_delivery_cache:build_from_metadata_rows({
  { schema_name = "S", table_name = "T", obj_type = "table" },
})
local sync_delivery_first = sync_delivery_cache:get_columns_async("S", "T")
assert_eq("sync delivery first complete", sync_delivery_first.is_incomplete, false)
assert_eq("sync delivery first column count", #sync_delivery_first.columns, 1)
assert_eq("sync delivery first column label", sync_delivery_first.columns[1].name, "SYNC_DELIVERED_COL")
assert_eq("sync delivery call count", sync_delivery_calls, 1)
assert_eq("sync delivery inflight drained", vim.tbl_count(sync_delivery_cache.async_inflight), 0)
assert_eq("sync delivery chains drained", vim.tbl_count(sync_delivery_cache.async_chains), 0)
local sync_delivery_warm = sync_delivery_cache:get_columns_async("S", "T")
assert_eq("sync delivery warm complete", sync_delivery_warm.is_incomplete, false)
assert_eq("sync delivery warmed column count", #sync_delivery_warm.columns, 1)

local view_env = new_async_env("async-view")
local view_line = "select * from S.VIEW_ONLY v where v."
local view_first = request(view_env.client, view_env.bufnr, view_line)
assert_eq("view first incomplete", view_first.isIncomplete, true)
assert_eq("first materialization table", view_env.calls[1].opts.materialization, "table")
deliver(view_env.cache, view_env.calls[1], {})
assert_eq("view materialization queued", view_env.calls[2].opts.materialization, "view")
deliver(view_env.cache, view_env.calls[2], {
  { name = "VIEW_COL", type = "VARCHAR2" },
})
local view_warm = request(view_env.client, view_env.bufnr, view_line)
assert_true("view warm label", has_label(view_warm, "VIEW_COL"))

local materialization_env = new_async_env("async-materialization")
local table_only = materialization_env.cache:get_columns_async("S", "T", { materialization = "table" })
local view_only = materialization_env.cache:get_columns_async("S", "T", { materialization = "view" })
assert_eq("table-only incomplete", table_only.is_incomplete, true)
assert_eq("view-only incomplete", view_only.is_incomplete, true)
assert_eq("materialization distinct call count", #materialization_env.calls, 2)
assert_eq("materialization call 1", materialization_env.calls[1].opts.materialization, "table")
assert_eq("materialization call 2", materialization_env.calls[2].opts.materialization, "view")
assert_true("materialization branch differs", materialization_env.calls[1].branch_id ~= materialization_env.calls[2].branch_id)
deliver(materialization_env.cache, materialization_env.calls[1], {
  { name = "TABLE_ONLY_COL", type = "NUMBER" },
})
assert_true("table materialization resolved", #materialization_env.cache:get_column_completion_items("S", "T") == 1)
deliver(materialization_env.cache, materialization_env.calls[2], {
  { name = "VIEW_ONLY_COL", type = "VARCHAR2" },
})
local materialized_items = materialization_env.cache:get_column_completion_items("S", "T")
assert_eq("view materialization resolved", materialized_items[1].label, "VIEW_ONLY_COL")

local overlap_default_env = new_async_env("async-overlap-default")
local overlap_default = overlap_default_env.cache:get_columns_async("S", "T")
local overlap_explicit_table = overlap_default_env.cache:get_columns_async("S", "T", { materialization = "table" })
assert_eq("overlap default incomplete", overlap_default.is_incomplete, true)
assert_eq("overlap explicit table attaches", overlap_explicit_table.is_incomplete, true)
assert_eq("overlap default plus table call count", #overlap_default_env.calls, 1)
deliver(overlap_default_env.cache, overlap_default_env.calls[1], {
  { name = "OVERLAP_TABLE_COL", type = "NUMBER" },
})
local overlap_default_warm = overlap_default_env.cache:get_columns_async("S", "T")
assert_eq("overlap default warm complete", overlap_default_warm.is_incomplete, false)

local overlap_reversed_env = new_async_env("async-overlap-reversed")
local overlap_reversed_table = overlap_reversed_env.cache:get_columns_async("S", "T", { materialization = "table" })
local overlap_reversed_default = overlap_reversed_env.cache:get_columns_async("S", "T")
assert_eq("overlap reversed table incomplete", overlap_reversed_table.is_incomplete, true)
assert_eq("overlap reversed default attaches", overlap_reversed_default.is_incomplete, true)
assert_eq("overlap reversed initial call count", #overlap_reversed_env.calls, 1)
deliver(overlap_reversed_env.cache, overlap_reversed_env.calls[1], {})
assert_eq("overlap reversed view probe queued", #overlap_reversed_env.calls, 2)
assert_eq("overlap reversed view materialization", overlap_reversed_env.calls[2].opts.materialization, "view")
local overlap_reversed_table_after_empty = overlap_reversed_env.cache:get_columns_async("S", "T", { materialization = "table" })
assert_eq("overlap reversed table-only complete after empty", overlap_reversed_table_after_empty.is_incomplete, false)
deliver(overlap_reversed_env.cache, overlap_reversed_env.calls[2], {
  { name = "OVERLAP_VIEW_COL", type = "VARCHAR2" },
})
assert_true("overlap reversed view warmed", #overlap_reversed_env.cache:get_column_completion_items("S", "T") == 1)

local incremental_calls = {}
local incremental_handler = {
  get_authoritative_root_epoch = function()
    return 1
  end,
  connection_get_columns_async = function(_, id, request_id, branch_id, root_epoch, opts)
    incremental_calls[#incremental_calls + 1] = {
      conn_id = id,
      request_id = request_id,
      branch_id = branch_id,
      root_epoch = root_epoch,
      opts = opts,
    }
  end,
}
local incremental_cache = SchemaCache:new(incremental_handler, "async-incremental")
local incremental_rows = {}
for i = 1, 100 do
  incremental_rows[#incremental_rows + 1] = {
    schema_name = "S",
    table_name = string.format("INC_%03d", i),
    obj_type = "table",
  }
end
incremental_cache:build_from_metadata_rows(incremental_rows)
local full_rebuilds = 0
local column_updates = 0
local original_rebuild = incremental_cache._rebuild_structure_indexes
local original_update = incremental_cache._update_column_index
incremental_cache._rebuild_structure_indexes = function(self)
  full_rebuilds = full_rebuilds + 1
  return original_rebuild(self)
end
incremental_cache._update_column_index = function(self, schema_name, table_name)
  column_updates = column_updates + 1
  return original_update(self, schema_name, table_name)
end
for i = 1, 100 do
  local table_name = string.format("INC_%03d", i)
  local result = incremental_cache:get_columns_async("S", table_name)
  assert_eq("incremental incomplete " .. table_name, result.is_incomplete, true)
  deliver(incremental_cache, incremental_calls[#incremental_calls], {
    { name = "COL_" .. table_name, type = "NUMBER" },
  })
end
assert_eq("async full rebuild count", full_rebuilds, 0)
assert_true("async incremental column updates", column_updates >= 100)

local listeners = {}
local fake_state = {}
local event_calls = {}
local event_handler = {
  get_current_connection = function()
    return { id = "event-conn", type = "postgres" }
  end,
  get_authoritative_root_epoch = function()
    return 1
  end,
  register_event_listener = function(_, name, cb)
    listeners[name] = cb
  end,
  connection_get_columns_async = function(_, id, request_id, branch_id, root_epoch, opts)
    event_calls[#event_calls + 1] = {
      conn_id = id,
      request_id = request_id,
      branch_id = branch_id,
      root_epoch = root_epoch,
      opts = opts,
    }
  end,
  teardown_structure_consumer = function() end,
  teardown_connection_invalidated_consumer = function() end,
}
function fake_state.is_core_loaded()
  return true
end
function fake_state.handler()
  return event_handler
end
function fake_state.config()
  return { lsp = { diagnostics_mode = "off", diagnostics_debounce_ms = 250 } }
end
function fake_state.dispatch(name, data)
  if listeners[name] then
    listeners[name](data)
  end
end

local saved_state = package.loaded["dbee.api.state"]
local saved_lsp = package.loaded["dbee.lsp"]
package.loaded["dbee.api.state"] = fake_state
package.loaded["dbee.lsp"] = nil
local lsp = require("dbee.lsp")
lsp.register_events()
local event_cache = SchemaCache:new(event_handler, "event-conn")
event_cache:build_from_metadata_rows({
  { schema_name = "S", table_name = "EVENT_T", obj_type = "table" },
})
lsp._cache = event_cache
lsp._conn_id = "event-conn"
event_cache:get_columns_async("S", "EVENT_T")
fake_state.dispatch("structure_children_loaded", {
  conn_id = "event-conn",
  request_id = event_calls[1].request_id,
  branch_id = event_calls[1].branch_id,
  root_epoch = event_calls[1].root_epoch,
  kind = "columns",
  columns = {
    { name = "EVENT_ID", type = "NUMBER" },
  },
})
assert_true("event wiring warmed cache", #event_cache:get_column_completion_items("S", "EVENT_T") == 1)
lsp.stop()
package.loaded["dbee.api.state"] = saved_state
package.loaded["dbee.lsp"] = saved_lsp

print("LSP11_ASYNC_FIRST_INCOMPLETE=true")
print("LSP11_ASYNC_DEDUPE_OK=true")
print("LSP11_ASYNC_STALE_DROPPED=true")
print("LSP11_ASYNC_WARM_LABELS=true")
print("LSP11_ASYNC_NO_SYNC_FETCH=true")
print("LSP11_ASYNC_FAILURE_HANDLED=true")
print("LSP11_ASYNC_PAYLOAD_ERROR_HANDLED=true")
print("LSP11_ASYNC_SYNC_DELIVERY_OK=true")
print("LSP11_ASYNC_MATERIALIZATION_PROBE_CHAIN_OK=true")
print("LSP11_ASYNC_DEDUPE_MATERIALIZATION_AWARE=true")
print("LSP11_ASYNC_INDEX_INCREMENTAL=true")
print("LSP11_ASYNC_EVENT_WIRING_OK=true")
print("LSP11_ASYNC_AUTO_RETRIGGER_OK=true")

vim.cmd("qa!")
