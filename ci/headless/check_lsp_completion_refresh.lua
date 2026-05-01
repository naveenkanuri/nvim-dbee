-- Headless checks for LSP column completion refresh notifications.

vim.env.XDG_STATE_HOME = vim.fn.tempname()
vim.fn.mkdir(vim.env.XDG_STATE_HOME, "p")

package.preload["nio"] = package.preload["nio"] or function()
  return {}
end

local server = require("dbee.lsp.server")
local schema_filter = require("dbee.schema_filter")
package.loaded["dbee.api.state"] = {
  is_core_loaded = function()
    return false
  end,
  config = function()
    return {}
  end,
}
local lsp_init = require("dbee.lsp")
local SchemaCache = require("dbee.lsp.schema_cache")

local function fail(msg)
  print("LSP_COMPLETION_REFRESH_NOTIFY_FAIL=" .. msg)
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

local function wait_for(label, predicate)
  local ok = vim.wait(1000, predicate, 10)
  if not ok then
    fail(label .. ": timed out")
  end
end

local function wait_for_quiet()
  vim.wait(80, function()
    return false
  end, 10)
end

local function request_completion(client, bufnr, line)
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
  wait_for("completion response", function()
    return done
  end)
  if response.err then
    fail("completion error: " .. tostring(response.err))
  end
  return response.result
end

local function new_dispatchers()
  local notifications = {}
  local server_requests = {}
  return {
    notifications = notifications,
    server_requests = server_requests,
    dispatchers = {
      notification = function(method, params)
        notifications[#notifications + 1] = {
          method = method,
          params = vim.deepcopy(params),
        }
      end,
      server_request = function(method, params)
        server_requests[#server_requests + 1] = {
          method = method,
          params = vim.deepcopy(params),
        }
        return nil
      end,
    },
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
    columns = columns or {},
    error = extra.error,
  })
end

local function new_cache_env(conn_id, rows, epoch_ref, scope_ref)
  local calls = {}
  local handler = {
    get_authoritative_root_epoch = function()
      return epoch_ref and epoch_ref.value or 1
    end,
    get_schema_filter_normalized = function()
      return scope_ref and scope_ref.value or schema_filter.normalize(nil, nil)
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
  cache:build_from_metadata_rows(rows or {
    { schema_name = "APP", table_name = "SAS_JOBS", obj_type = "table" },
  })
  local transport = new_dispatchers()
  local client = server.create(cache)(transport.dispatchers, {})
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "/tmp/dbee-lsp-completion-refresh-" .. conn_id .. ".sql")
  return {
    handler = handler,
    cache = cache,
    calls = calls,
    client = client,
    bufnr = bufnr,
    notifications = transport.notifications,
    server_requests = transport.server_requests,
  }
end

local main = new_cache_env("refresh-main")
local query = "select * from app.sas_jobs j where j."
local first = request_completion(main.client, main.bufnr, query)
assert_eq("first incomplete", first.isIncomplete, true)
assert_eq("first empty", #first.items, 0)
assert_eq("one async request", #main.calls, 1)

local duplicate = request_completion(main.client, main.bufnr, query)
assert_eq("duplicate incomplete", duplicate.isIncomplete, true)
assert_eq("deduped async request", #main.calls, 1)

assert_true("columns delivered", deliver(main.cache, main.calls[1], {
  { name = "JOB_ID", type = "NUMBER" },
  { name = "STATUS", type = "VARCHAR2" },
}))
wait_for("columnsLoaded notification", function()
  return #main.notifications == 1 and #main.server_requests == 1
end)
assert_eq("notification method", main.notifications[1].method, "dbee/columnsLoaded")
assert_eq("notification conn", main.notifications[1].params.conn_id, "refresh-main")
assert_eq("notification schema", main.notifications[1].params.schema, "APP")
assert_eq("notification table", main.notifications[1].params.table, "SAS_JOBS")
assert_eq("diagnostic refresh method", main.server_requests[1].method, "workspace/diagnostic/refresh")

local sync_cache
local sync_calls = 0
local sync_transport = new_dispatchers()
local sync_handler = {
  get_authoritative_root_epoch = function()
    return 1
  end,
  connection_get_columns_async = function(_, id, request_id, branch_id, root_epoch)
    sync_calls = sync_calls + 1
    sync_cache:on_columns_loaded({
      conn_id = id,
      request_id = request_id,
      branch_id = branch_id,
      root_epoch = root_epoch,
      kind = "columns",
      columns = {
        { name = "SYNC_COL", type = "NUMBER" },
      },
    })
  end,
}
sync_cache = SchemaCache:new(sync_handler, "refresh-sync")
sync_cache:build_from_metadata_rows({
  { schema_name = "APP", table_name = "SYNC_TABLE", obj_type = "table" },
})
local sync_client = server.create(sync_cache)(sync_transport.dispatchers, {})
local sync_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(sync_buf, "/tmp/dbee-lsp-completion-refresh-sync.sql")
local sync_result = request_completion(sync_client, sync_buf, "select * from app.sync_table s where s.")
assert_eq("sync delivery call count", sync_calls, 1)
assert_eq("sync delivery complete", sync_result.isIncomplete, false)
wait_for_quiet()
assert_eq("sync delivery no notification", #sync_transport.notifications, 0)
assert_eq("sync delivery no diagnostic refresh", #sync_transport.server_requests, 0)

local stale_epoch = { value = 1 }
local stale = new_cache_env("refresh-stale", nil, stale_epoch)
local stale_first = request_completion(stale.client, stale.bufnr, query)
assert_eq("stale first incomplete", stale_first.isIncomplete, true)
stale_epoch.value = 2
assert_true("stale delivery rejected", not deliver(stale.cache, stale.calls[1], {
  { name = "STALE_COL", type = "NUMBER" },
}))
wait_for_quiet()
assert_eq("stale no notification", #stale.notifications, 0)

local app_scope = schema_filter.normalize({ include = { "APP" } }, "oracle")
local hr_scope = schema_filter.normalize({ include = { "HR" } }, "oracle")
local filtered = new_cache_env("refresh-filtered", {
  { schema_name = "APP", table_name = "SAS_JOBS", obj_type = "table" },
}, nil, { value = app_scope })
local filtered_result = request_completion(filtered.client, filtered.bufnr, "select * from HR.SECRET s where s.")
assert_eq("filtered schema complete", filtered_result.isIncomplete, false)
assert_eq("filtered schema empty", #filtered_result.items, 0)
assert_eq("filtered schema no async", #filtered.calls, 0)
wait_for_quiet()
assert_eq("filtered schema no notification", #filtered.notifications, 0)
assert_eq("filtered schema no cache", filtered.cache:get_cached_columns()["HR.SECRET"], nil)

local scope_ref = { value = app_scope }
local scoped_delivery = new_cache_env("refresh-scope-change", nil, nil, scope_ref)
local scoped_first = request_completion(scoped_delivery.client, scoped_delivery.bufnr, query)
assert_eq("scope change first incomplete", scoped_first.isIncomplete, true)
assert_eq("scope change async call", #scoped_delivery.calls, 1)
scope_ref.value = hr_scope
scoped_delivery.cache:refresh_schema_scope()
assert_true("scope changed delivery rejected", not deliver(scoped_delivery.cache, scoped_delivery.calls[1], {
  { name = "SHOULD_NOT_CACHE", type = "NUMBER" },
}))
wait_for_quiet()
assert_eq("scope changed no notification", #scoped_delivery.notifications, 0)
assert_eq("scope changed no column cache", scoped_delivery.cache:get_cached_columns()["APP.SAS_JOBS"], nil)

local probe_scope = { value = app_scope }
local scoped_probe = new_cache_env("refresh-probe-scope", {
  { schema_name = "APP", table_name = "SAS_JOBS", obj_type = "table" },
}, nil, probe_scope)
local probe_result = scoped_probe.cache:get_columns_async("APP", "MISSING", {
  probe_if_missing = true,
  materializations = { "table" },
})
assert_eq("probe scoped miss incomplete", probe_result.is_incomplete, true)
assert_eq("probe scoped one async call", #scoped_probe.calls, 1)
assert_eq("probe scoped first schema", scoped_probe.calls[1].opts.schema, "APP")
assert_true("probe scoped exhausted", not deliver(scoped_probe.cache, scoped_probe.calls[1], {}))
assert_eq("probe scoped no default fallback", #scoped_probe.calls, 1)

local fail_closed_calls = 0
local fail_closed_cache = SchemaCache:new({
  get_schema_filter_normalized = function()
    return nil
  end,
  get_authoritative_root_epoch = function()
    return 1
  end,
  connection_get_columns_async = function()
    fail_closed_calls = fail_closed_calls + 1
  end,
}, "refresh-authority-fail-closed")
fail_closed_cache:build_from_metadata_rows({
  { schema_name = "APP", table_name = "SAS_JOBS", obj_type = "table" },
})
assert_eq("authority fail closed schema hidden", fail_closed_cache:find_schema("APP"), nil)
local fail_closed_result = fail_closed_cache:get_columns_async("APP", "SAS_JOBS", {
  probe_if_missing = true,
  materializations = { "table" },
})
assert_eq("authority fail closed complete", fail_closed_result.is_incomplete, false)
assert_eq("authority fail closed no transport", fail_closed_calls, 0)

local mid_session_scope = { value = schema_filter.normalize(nil, nil) }
local mid_session_calls = 0
local mid_session_cache = SchemaCache:new({
  get_schema_filter_normalized = function()
    return mid_session_scope.value
  end,
  get_authoritative_root_epoch = function()
    return 1
  end,
  connection_get_columns_async = function()
    mid_session_calls = mid_session_calls + 1
  end,
}, "refresh-authority-nil-mid-session")
mid_session_cache:build_from_metadata_rows({
  { schema_name = "APP", table_name = "SAS_JOBS", obj_type = "table" },
})
local before_nil = mid_session_cache:get_columns_async("APP", "SAS_JOBS", {
  probe_if_missing = true,
  materializations = { "table" },
})
assert_eq("mid-session starts open incomplete", before_nil.is_incomplete, true)
assert_eq("mid-session starts open transport", mid_session_calls, 1)
mid_session_scope.value = nil
assert_true("mid-session nil authority changes scope", mid_session_cache:refresh_schema_scope())
assert_eq("mid-session nil authority signature", mid_session_cache.schema_filter_signature, "schema-filter-v1|fail-closed")
assert_eq("mid-session nil authority clears schema", mid_session_cache:find_schema("APP"), nil)
local after_nil = mid_session_cache:get_columns_async("APP", "SAS_JOBS", {
  probe_if_missing = true,
  materializations = { "table" },
})
assert_eq("mid-session nil authority complete", after_nil.is_incomplete, false)
assert_eq("mid-session nil authority no new transport", mid_session_calls, 1)

local error_scope_cache = SchemaCache:new({
  get_schema_filter_normalized = function()
    return schema_filter.normalize(nil, nil)
  end,
  get_authoritative_root_epoch = function()
    return 1
  end,
  connection_get_columns_async = function() end,
}, "refresh-authority-error-mid-session")
error_scope_cache:build_from_metadata_rows({
  { schema_name = "APP", table_name = "SAS_JOBS", obj_type = "table" },
})
error_scope_cache.handler.get_schema_filter_normalized = function()
  error("params unavailable")
end
assert_true("mid-session error authority changes scope", error_scope_cache:refresh_schema_scope())
assert_eq("mid-session error authority signature", error_scope_cache.schema_filter_signature, "schema-filter-v1|fail-closed")

local state_module = package.loaded["dbee.api.state"]
local saved_start_lsp = lsp_init._start_lsp
local saved_client_id = lsp_init._client_id
local saved_cache = lsp_init._cache
local saved_conn_id = lsp_init._conn_id
local saved_attached_bufs = lsp_init._attached_bufs
local saved_pending_bufs = lsp_init._pending_bufs
local saved_async_requested = lsp_init._async_requested
local saved_metadata_scheduled = lsp_init._metadata_scheduled
local saved_metadata_call_ids = lsp_init._metadata_call_ids
local saved_connection_consumer_live = lsp_init._connection_invalidated_consumer_live
local saved_pending_invalidations = lsp_init._pending_connection_invalidations
local saved_invalidation_scheduled = lsp_init._connection_invalidation_flush_scheduled
local saved_is_core_loaded = state_module.is_core_loaded
local saved_state_handler = state_module.handler
local saved_defer_fn = vim.defer_fn

local function reset_lsp_startup_state()
  lsp_init._client_id = nil
  lsp_init._cache = nil
  lsp_init._conn_id = nil
  lsp_init._attached_bufs = {}
  lsp_init._pending_bufs = {}
  lsp_init._async_requested = {}
  lsp_init._metadata_scheduled = {}
  lsp_init._metadata_call_ids = {}
  lsp_init._connection_invalidated_consumer_live = false
  lsp_init._pending_connection_invalidations = {}
  lsp_init._connection_invalidation_flush_scheduled = false
end

local function restore_lsp_startup_state()
  lsp_init._start_lsp = saved_start_lsp
  lsp_init._client_id = saved_client_id
  lsp_init._cache = saved_cache
  lsp_init._conn_id = saved_conn_id
  lsp_init._attached_bufs = saved_attached_bufs
  lsp_init._pending_bufs = saved_pending_bufs
  lsp_init._async_requested = saved_async_requested
  lsp_init._metadata_scheduled = saved_metadata_scheduled
  lsp_init._metadata_call_ids = saved_metadata_call_ids
  lsp_init._connection_invalidated_consumer_live = saved_connection_consumer_live
  lsp_init._pending_connection_invalidations = saved_pending_invalidations
  lsp_init._connection_invalidation_flush_scheduled = saved_invalidation_scheduled
  state_module.is_core_loaded = saved_is_core_loaded
  state_module.handler = saved_state_handler
  vim.defer_fn = saved_defer_fn
end

local function make_startup_handler(opts)
  opts = opts or {}
  local handler = {
    structure_requests = 0,
    metadata_requests = 0,
    conn_id = opts.conn_id or "startup-authority",
  }
  function handler:get_current_connection()
    return {
      id = self.conn_id,
      type = "postgres",
    }
  end
  if opts.authority_present then
    function handler:get_schema_filter_normalized()
      if opts.authority_error then
        error("params unavailable")
      end
      if opts.scope_ref then
        return opts.scope_ref.value
      end
      return opts.scope
    end
  end
  function handler:get_authoritative_root_epoch()
    return 1
  end
  function handler:connection_get_structure_singleflight()
    self.structure_requests = self.structure_requests + 1
  end
  function handler:connection_get_columns_async()
    self.column_requests = (self.column_requests or 0) + 1
  end
  function handler:connection_execute(_, _)
    self.metadata_requests = self.metadata_requests + 1
    return {
      id = "startup-metadata-call-" .. tostring(self.metadata_requests),
      state = "archived",
    }
  end
  return handler
end

vim.defer_fn = function(fn, _)
  fn()
end
state_module.is_core_loaded = function()
  return true
end

local startup_started_signature = nil
lsp_init._start_lsp = function(cache, conn_id)
  startup_started_signature = cache and cache.schema_filter_signature or nil
  lsp_init._client_id = 9001
  lsp_init._cache = cache
  lsp_init._conn_id = conn_id
  return true
end

reset_lsp_startup_state()
local authority_nil_handler = make_startup_handler({
  authority_present = true,
  scope = nil,
  conn_id = "startup-authority-nil",
})
state_module.handler = function()
  return authority_nil_handler
end
lsp_init._try_start()
lsp_init._request_root_refresh(authority_nil_handler, "startup-authority-nil")
lsp_init._execute_metadata_query(authority_nil_handler, "startup-authority-nil", "postgres")
assert_eq("startup nil authority fail-closed signature", startup_started_signature, "schema-filter-v1|fail-closed")
assert_eq("startup nil authority no structure refresh", authority_nil_handler.structure_requests, 0)
assert_eq("startup nil authority no metadata SQL", authority_nil_handler.metadata_requests, 0)

local function warm_active_cache(handler, conn_id)
  local cache = SchemaCache:new(handler, conn_id)
  cache:build_from_metadata_rows({
    { schema_name = "APP", table_name = "SAS_JOBS", obj_type = "table" },
  })
  assert_true("active warm cache starts visible " .. conn_id, cache:find_schema("APP") ~= nil)
  lsp_init._client_id = 9002
  lsp_init._cache = cache
  lsp_init._conn_id = conn_id
  lsp_init._attached_bufs = {}
  lsp_init._pending_bufs = {}
  return cache
end

local function assert_active_cache_fail_closed(label, handler, cache)
  assert_eq(label .. " signature", cache.schema_filter_signature, "schema-filter-v1|fail-closed")
  assert_eq(label .. " schema hidden", cache:find_schema("APP"), nil)
  local result = cache:get_columns_async("APP", "SAS_JOBS", {
    probe_if_missing = true,
    materializations = { "table" },
  })
  assert_eq(label .. " completion complete", result.is_incomplete, false)
  assert_eq(label .. " no column transport", handler.column_requests or 0, 0)
  assert_eq(label .. " no structure refresh", handler.structure_requests, 0)
  assert_eq(label .. " no metadata SQL", handler.metadata_requests, 0)
end

reset_lsp_startup_state()
local active_refresh_scope = { value = schema_filter.normalize(nil, nil) }
local active_refresh_handler = make_startup_handler({
  authority_present = true,
  scope_ref = active_refresh_scope,
  conn_id = "startup-active-refresh",
})
local active_refresh_cache = warm_active_cache(active_refresh_handler, "startup-active-refresh")
state_module.handler = function()
  return active_refresh_handler
end
active_refresh_scope.value = nil
lsp_init.refresh()
assert_active_cache_fail_closed("active refresh nil authority", active_refresh_handler, active_refresh_cache)

reset_lsp_startup_state()
local active_invalidation_scope = { value = schema_filter.normalize(nil, nil) }
local active_invalidation_handler = make_startup_handler({
  authority_present = true,
  scope_ref = active_invalidation_scope,
  conn_id = "startup-active-invalidation",
})
local active_invalidation_cache = warm_active_cache(active_invalidation_handler, "startup-active-invalidation")
state_module.handler = function()
  return active_invalidation_handler
end
lsp_init._connection_invalidated_consumer_live = true
lsp_init._pending_connection_invalidations = {
  {
    new_conn_ids = { "startup-active-invalidation" },
    authoritative_root_epoch = 2,
  },
}
active_invalidation_scope.value = nil
lsp_init._flush_connection_invalidations()
assert_active_cache_fail_closed(
  "active invalidation nil authority",
  active_invalidation_handler,
  active_invalidation_cache
)

reset_lsp_startup_state()
startup_started_signature = nil
local legacy_handler = make_startup_handler({
  authority_present = false,
  conn_id = "startup-legacy-api-absent",
})
state_module.handler = function()
  return legacy_handler
end
lsp_init._try_start()
assert_eq("startup legacy root refresh preserved", legacy_handler.structure_requests, 1)
assert_eq("startup legacy metadata preserved", legacy_handler.metadata_requests, 1)

restore_lsp_startup_state()

local root = vim.fn.getcwd()
local drawer_source = table.concat(vim.fn.readfile(root .. "/lua/dbee/ui/drawer/init.lua"), "\n")
local lsp_source = table.concat(vim.fn.readfile(root .. "/lua/dbee/lsp/init.lua"), "\n")
local cache_source = table.concat(vim.fn.readfile(root .. "/lua/dbee/lsp/schema_cache.lua"), "\n")
assert_true("drawer no raw schema filter normalize", drawer_source:find("schema_filter%.normalize%(conn", 1, false) == nil)
assert_true("lsp no raw schema filter normalize", lsp_source:find("schema_filter%.normalize%(conn%.schema_filter", 1, false) == nil)
assert_true("cache no nil fail-open fallback", cache_source:find("normalized_scope%s*=%s*normalized_scope%s*or%s*schema_filter%.normalize%(nil, nil%)") == nil)

local burst_rows = {}
for index = 1, 5 do
  burst_rows[#burst_rows + 1] = {
    schema_name = "S",
    table_name = "T" .. tostring(index),
    obj_type = "table",
  }
end
local burst = new_cache_env("refresh-burst", burst_rows)
for index = 1, 5 do
  local line = "select * from S.T" .. tostring(index) .. " t where t."
  local result = request_completion(burst.client, burst.bufnr, line)
  assert_eq("burst incomplete " .. tostring(index), result.isIncomplete, true)
end
assert_eq("burst async calls", #burst.calls, 5)
for index, call in ipairs(burst.calls) do
  assert_true("burst deliver " .. tostring(index), deliver(burst.cache, call, {
    { name = "C" .. tostring(index), type = "NUMBER" },
  }))
end
wait_for("burst notifications", function()
  return #burst.notifications == 5 and #burst.server_requests >= 1
end)
wait_for_quiet()
assert_eq("burst diagnostic refresh coalesced", #burst.server_requests, 1)

lsp_init._install_completion_refresh_handler()
local old_get_mode = vim.api.nvim_get_mode
vim.api.nvim_get_mode = function()
  return { mode = "i" }
end

local blink_visible = true
local blink_calls = {}
local old_blink = package.loaded["blink.cmp"]
local old_cmp = package.loaded["cmp"]
package.loaded["blink.cmp"] = {
  is_visible = function()
    return blink_visible
  end,
  show = function(opts)
    blink_calls[#blink_calls + 1] = vim.deepcopy(opts or {})
    return true
  end,
}
package.loaded["cmp"] = nil

local handler_cache = SchemaCache:new({
  get_authoritative_root_epoch = function()
    return 1
  end,
}, "handler-conn")
handler_cache:build_from_metadata_rows({
  { schema_name = "APP", table_name = "SAS_JOBS", obj_type = "table" },
})
local handler_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(handler_buf, "/tmp/dbee-lsp-completion-refresh-handler.sql")
vim.api.nvim_set_current_buf(handler_buf)
vim.api.nvim_buf_set_lines(handler_buf, 0, -1, false, { query })
vim.api.nvim_win_set_cursor(0, { 1, #query })

local previous_client_id = lsp_init._client_id
local previous_conn_id = lsp_init._conn_id
local previous_cache = lsp_init._cache
local previous_attached = lsp_init._attached_bufs
lsp_init._client_id = 42
lsp_init._conn_id = "handler-conn"
lsp_init._cache = handler_cache
lsp_init._attached_bufs = { [handler_buf] = true }

local function invoke_handler(params)
  vim.lsp.handlers["dbee/columnsLoaded"](nil, params or {
    conn_id = "handler-conn",
    schema = "APP",
    table = "SAS_JOBS",
    root_epoch = 1,
  }, {
    client_id = 42,
    method = "dbee/columnsLoaded",
  })
end

invoke_handler()
assert_eq("handler blink refresh", #blink_calls, 1)
assert_eq("handler blink provider", blink_calls[1].providers[1], "lsp")

blink_visible = false
invoke_handler()
assert_eq("hidden blink refreshes eligible miss", #blink_calls, 2)

blink_visible = true
vim.api.nvim_buf_set_lines(handler_buf, 0, -1, false, { "select 1" })
vim.api.nvim_win_set_cursor(0, { 1, #"select 1" })
invoke_handler()
assert_eq("moved cursor no refresh", #blink_calls, 2)

vim.api.nvim_buf_set_lines(handler_buf, 0, -1, false, { query })
vim.api.nvim_win_set_cursor(0, { 1, #query })
lsp_init._attached_bufs = {}
invoke_handler()
assert_eq("detached buffer no refresh", #blink_calls, 2)

lsp_init._attached_bufs = { [handler_buf] = true }
invoke_handler({ conn_id = "other-conn", schema = "APP", table = "SAS_JOBS" })
assert_eq("reconnect mismatch no refresh", #blink_calls, 2)

lsp_init._client_id = previous_client_id
lsp_init._conn_id = previous_conn_id
lsp_init._cache = previous_cache
lsp_init._attached_bufs = previous_attached
vim.api.nvim_get_mode = old_get_mode
package.loaded["blink.cmp"] = old_blink
package.loaded["cmp"] = old_cmp

print("ARCH14_LSP_PROBE_SCOPE_OK=true")
print("ARCH14_FILTER_AUTHORITY_SINGLE_SOURCE_OK=true")
print("ARCH14_LSP_CACHE_FAIL_CLOSED_ON_AUTHORITY_NIL=true")
print("ARCH14_LSP_STARTUP_AUTHORITY_NIL_NO_METADATA_SQL=true")
print("ARCH14_LSP_ACTIVE_CACHE_FAIL_CLOSED_ON_AUTHORITY_NIL=true")
print("LSP_COMPLETION_REFRESH_NOTIFY_OK=true")
vim.cmd("qa!")
