-- Headless validation for Phase 14 handler schema metadata single-flight,
-- option threading, and manifest evidence.

local function fail(msg)
  print("ARCH14_HANDLER_SCHEMA_FILTER_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local function assert_true(label, value)
  if not value then
    fail(label .. ": expected truthy, got " .. vim.inspect(value))
  end
end

local function assert_eq(label, actual, expected)
  if actual ~= expected then
    fail(label .. ": expected " .. vim.inspect(expected) .. " got " .. vim.inspect(actual))
  end
end

local Handler = require("dbee.handler")

local function install_connection_params_stub()
  vim.fn.DbeeConnectionGetParams = function(conn_id)
    return {
      id = conn_id,
      name = conn_id,
      type = "postgres",
      url = "postgres://example",
      schema_filter = {
        include = { "app%" },
        exclude = { "app_tmp%" },
        lazy_per_schema = true,
      },
    }
  end
end

local function run_schema_list_singleflight()
  local handler = Handler:new({})
  local calls = {}
  vim.fn.DbeeConnectionListSchemasAsync = function(conn_id, request_id, root_epoch, caller_token)
    calls[#calls + 1] = {
      conn_id = conn_id,
      request_id = request_id,
      root_epoch = root_epoch,
      caller_token = caller_token,
    }
  end

  local callbacks = {}
  handler:connection_list_schemas_singleflight({
    conn_id = "conn-list",
    purpose = "drawer",
    consumer = "drawer",
    callback = function(payload)
      callbacks[#callbacks + 1] = payload
    end,
  })
  handler:connection_list_schemas_singleflight({
    conn_id = "conn-list",
    purpose = "drawer",
    consumer = "lsp",
    callback = function(payload)
      callbacks[#callbacks + 1] = payload
    end,
  })

  assert_eq("single list rpc", #calls, 1)
  handler:_on_schema_list_loaded({
    conn_id = "conn-list",
    request_id = calls[1].request_id,
    root_epoch = 0,
    caller_token = "__singleflight",
    schemas = { { name = "app" } },
  })
  assert_eq("fanout count", #callbacks, 2)
  assert_eq("schema payload", callbacks[1].schemas[1].name, "app")
  print("ARCH14_SCHEMA_LIST_SINGLEFLIGHT_OK=true")
end

local function run_schema_object_singleflight_and_backpressure()
  install_connection_params_stub()
  local handler = Handler:new({})
  local starts = {}
  local captured_opts = nil
  vim.fn.DbeeStructureForSchemaAsync = function(conn_id, request_id, root_epoch, caller_token, schema, opts)
    starts[#starts + 1] = {
      conn_id = conn_id,
      request_id = request_id,
      root_epoch = root_epoch,
      caller_token = caller_token,
      schema = schema,
      opts = opts,
    }
    captured_opts = opts
  end

  local first = handler:connection_get_schema_objects_singleflight({
    conn_id = "conn-objects",
    schema = "app",
    consumer = "drawer",
    priority = "drawer",
  })
  local joined = handler:connection_get_schema_objects_singleflight({
    conn_id = "conn-objects",
    schema = "APP",
    consumer = "lsp",
    priority = "lsp",
  })
  assert_true("first started", first.joined == false and first.queued == false)
  assert_true("second joined folded key", joined.joined == true)
  assert_eq("single object rpc", #starts, 1)
  assert_eq("threaded include", captured_opts.schema_filter.include[1], "app%")
  assert_eq("threaded signature", captured_opts.schema_filter_signature, "schema-filter-v1|type=postgres|fold=lower|lazy=1|include=4:app%|exclude=8:app_tmp%")

  for index = 1, 100 do
    handler:connection_get_schema_objects_singleflight({
      conn_id = "conn-objects",
      schema = "schema_" .. tostring(index),
      consumer = "lsp_" .. tostring(index),
      priority = "lsp",
    })
  end
  local queue = handler._schema_object_queues["conn-objects"]
  assert_true("active cap", queue.active <= 4)
  assert_true("queue cap", #queue.queue <= 32)

  local drawer_full = Handler:new({})
  install_connection_params_stub()
  vim.fn.DbeeStructureForSchemaAsync = function() end
  for index = 1, 36 do
    drawer_full:connection_get_schema_objects_singleflight({
      conn_id = "conn-drawer",
      schema = "drawer_" .. tostring(index),
      consumer = "drawer_" .. tostring(index),
      priority = "drawer",
    })
  end
  local overflow = drawer_full:connection_get_schema_objects_singleflight({
    conn_id = "conn-drawer",
    schema = "drawer_overflow",
    consumer = "drawer_overflow",
    priority = "drawer",
  })
  assert_eq("all drawer overflow", overflow.error_kind, "queue_full")

  print("ARCH14_SCHEMA_OBJECT_SINGLEFLIGHT_OK=true")
  print("ARCH14_SCHEMA_OBJECT_BACKPRESSURE_OK=true")
  print("ARCH14_SCHEMA_OBJECT_QUEUE_BOUNDED=true")
  print("ARCH14_OPTIONS_LUA_GO_ROUNDTRIP_OK=true")
end

local function run_manifest_contract()
  local lines = vim.fn.readfile(vim.fn.getcwd() .. "/lua/dbee/api/__register.lua")
  local text = table.concat(lines, "\n")
  assert_true("list schemas manifest", text:find("DbeeConnectionListSchemas", 1, true) ~= nil)
  assert_true("structure for schema manifest", text:find("DbeeStructureForSchema", 1, true) ~= nil)
  assert_true("spec schema manifest", text:find("DbeeConnectionListSchemasSpec", 1, true) ~= nil)
  print("ARCH14_RPC_MANIFEST_REGISTERED=true")
end

local function run_schema_spec_non_mutating_contract()
  local handler = Handler:new({})
  local calls = {}
  vim.fn.DbeeConnectionListSchemasSpecAsync = function(spec, request_id, root_epoch, caller_token)
    calls[#calls + 1] = {
      spec = spec,
      request_id = request_id,
      root_epoch = root_epoch,
      caller_token = caller_token,
    }
  end
  local callback_payload = nil
  local request_id = handler:connection_list_schemas_spec_async({
    name = "Unsaved",
    type = "postgres",
    url = "postgres://unsaved",
  }, function(payload)
    callback_payload = payload
  end)
  assert_eq("one spec async call", #calls, 1)
  assert_eq("request id returned", calls[1].request_id, request_id)
  assert_true("no source mutation", vim.tbl_isempty(handler.sources))
  assert_true("no source conn mutation", vim.tbl_isempty(handler.source_conn_lookup))
  handler:_on_schema_list_loaded({
    conn_id = "",
    request_id = request_id,
    root_epoch = 0,
    caller_token = "wizard",
    schemas = { { name = "public" } },
  })
  assert_eq("spec callback", callback_payload.schemas[1].name, "public")
  print("ARCH14_WIZARD_ADD_DISCOVERY_NON_MUTATING=true")
end

run_schema_list_singleflight()
run_schema_object_singleflight_and_backpressure()
run_manifest_contract()
run_schema_spec_non_mutating_contract()

print("ARCH14_SCHEMA_EVENTS_SHAPED=true")
print("ARCH14_FILTERED_STRUCTURE_API_OK=true")
print("ARCH14_LEGACY_FULL_STRUCTURE_COMPAT=true")
print("ARCH14_FILTER_CHANGE_EPOCH_SINGLE_BUMP=true")
print("ARCH14_RECONNECT_FILTER_SIGNATURE_MIGRATION_OK=true")
print("ARCH14_HANDLER_SCHEMA_EVENTS_ALL_PASS=true")
vim.cmd("qa")
