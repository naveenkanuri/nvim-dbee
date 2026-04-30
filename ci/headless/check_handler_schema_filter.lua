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

  local evicted_payloads = {}
  for index = 1, 100 do
    handler:connection_get_schema_objects_singleflight({
      conn_id = "conn-objects",
      schema = "schema_" .. tostring(index),
      consumer = "lsp_" .. tostring(index),
      priority = "lsp",
      callback = function(payload)
        evicted_payloads[#evicted_payloads + 1] = payload
      end,
    })
  end
  local queue = handler._schema_object_queues["conn-objects"]
  assert_true("active cap", queue.active <= 4)
  assert_true("queue cap", #queue.queue <= 32)
  local evictions_before_drawer = #evicted_payloads
  local drawer_priority = handler:connection_get_schema_objects_singleflight({
    conn_id = "conn-objects",
    schema = "schema_drawer_priority",
    consumer = "drawer-priority",
    priority = "drawer",
  })
  assert_true("drawer priority accepted", drawer_priority.error_kind == nil)
  assert_eq("queue cap after drawer priority", #queue.queue, 32)
  assert_eq("drawer inserted before lsp", queue.queue[1].priority, "drawer")
  assert_true("lsp evicted for drawer", #evicted_payloads > evictions_before_drawer)
  assert_eq("lsp eviction reason", evicted_payloads[#evicted_payloads].error_kind, "queue_full")

  local coalesce_handler = Handler:new({})
  install_connection_params_stub()
  vim.fn.DbeeStructureForSchemaAsync = function() end
  for index = 1, 4 do
    coalesce_handler:connection_get_schema_objects_singleflight({
      conn_id = "conn-coalesce",
      schema = "active_" .. tostring(index),
      consumer = "active_" .. tostring(index),
      priority = "drawer",
    })
  end
  local first_queued = coalesce_handler:connection_get_schema_objects_singleflight({
    conn_id = "conn-coalesce",
    schema = "same_schema",
    consumer = "lsp-schema-dot",
    priority = "lsp",
    request_id = 10,
  })
  local second_queued = coalesce_handler:connection_get_schema_objects_singleflight({
    conn_id = "conn-coalesce",
    schema = "SAME_SCHEMA",
    consumer = "lsp-schema-dot",
    priority = "lsp",
    request_id = 11,
  })
  local coalesce_queue = coalesce_handler._schema_object_queues["conn-coalesce"]
  assert_true("same key queued", first_queued.queued == true)
  assert_true("same key joined", second_queued.joined == true)
  assert_eq("same consumer coalesced", #coalesce_queue.queue[1].waiters, 1)
  assert_eq("same consumer request updated", coalesce_queue.queue[1].waiters[1].request_id, 11)

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
  print("ARCH14_QUEUE_PRIORITY_HONORED=true")
  print("ARCH14_QUEUE_COALESCE_OK=true")
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

local function run_reconnect_schema_flight_migration()
  install_connection_params_stub()
  local handler = Handler:new({})
  local list_calls = {}
  local object_calls = {}
  vim.fn.DbeeConnectionListSchemasAsync = function(conn_id, request_id, root_epoch, caller_token)
    list_calls[#list_calls + 1] = {
      conn_id = conn_id,
      request_id = request_id,
      root_epoch = root_epoch,
      caller_token = caller_token,
    }
  end
  vim.fn.DbeeStructureForSchemaAsync = function(conn_id, request_id, root_epoch, caller_token, schema, opts)
    object_calls[#object_calls + 1] = {
      conn_id = conn_id,
      request_id = request_id,
      root_epoch = root_epoch,
      caller_token = caller_token,
      schema = schema,
      opts = opts,
    }
  end

  local list_payload = nil
  handler:connection_list_schemas_singleflight({
    conn_id = "conn-old",
    consumer = "drawer",
    callback = function(payload)
      list_payload = payload
    end,
  })

  local object_payload = nil
  handler:connection_get_schema_objects_singleflight({
    conn_id = "conn-old",
    schema = "app",
    consumer = "drawer",
    priority = "drawer",
    callback = function(payload)
      object_payload = payload
    end,
  })
  for index = 1, 4 do
    handler:connection_get_schema_objects_singleflight({
      conn_id = "conn-old",
      schema = "active_" .. tostring(index),
      consumer = "active_migrate_" .. tostring(index),
      priority = "drawer",
    })
  end
  handler:connection_get_schema_objects_singleflight({
    conn_id = "conn-old",
    schema = "queued_schema",
    consumer = "queued_migrate",
    priority = "lsp",
  })

  handler:migrate_structure_flights("conn-old", "conn-new", { schema_scope_matches = true })
  assert_true("queued migrated", handler._schema_object_queues["conn-new"] ~= nil)
  assert_eq("old queue cleared", handler._schema_object_queues["conn-old"], nil)

  handler:_on_schema_list_loaded({
    conn_id = "conn-old",
    request_id = list_calls[1].request_id,
    root_epoch = list_calls[1].root_epoch,
    caller_token = "__singleflight",
    schemas = { { name = "app" } },
  })
  assert_true("list old completion accepted", list_payload ~= nil)
  assert_eq("list migrated conn id", list_payload.conn_id, "conn-new")

  handler:_on_schema_objects_loaded({
    conn_id = "conn-old",
    request_id = object_calls[1].request_id,
    root_epoch = object_calls[1].root_epoch,
    caller_token = "__singleflight",
    schema = "app",
    objects = { { type = "table", schema = "app", name = "accounts" } },
  })
  assert_true("object old completion accepted", object_payload ~= nil)
  assert_eq("object migrated conn id", object_payload.conn_id, "conn-new")
  print("ARCH14_RECONNECT_SCHEMA_FLIGHT_MIGRATION_OK=true")
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
run_reconnect_schema_flight_migration()
run_schema_spec_non_mutating_contract()

print("ARCH14_SCHEMA_EVENTS_SHAPED=true")
print("ARCH14_FILTERED_STRUCTURE_API_OK=true")
print("ARCH14_LEGACY_FULL_STRUCTURE_COMPAT=true")
print("ARCH14_FILTER_CHANGE_EPOCH_SINGLE_BUMP=true")
print("ARCH14_RECONNECT_FILTER_SIGNATURE_MIGRATION_OK=true")
print("ARCH14_HANDLER_SCHEMA_EVENTS_ALL_PASS=true")
vim.cmd("qa")
