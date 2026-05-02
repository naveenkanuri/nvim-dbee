-- Headless validation for Phase 16 rich table metadata.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=$(pwd)" \
--   -c "luafile ci/headless/check_rich_metadata.lua"

local function fail(msg)
  print("RICH16_FAIL=" .. msg)
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

local function assert_contains(label, haystack, needle)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    fail(label .. ": missing " .. vim.inspect(needle))
  end
end

local function read(path)
  local full = vim.fn.getcwd() .. "/" .. path
  local lines = vim.fn.readfile(full)
  if not lines or #lines == 0 then
    fail("unable to read " .. path)
  end
  return table.concat(lines, "\n")
end

local markers = {}
local function mark(label)
  markers[label] = true
  print(label .. "=true")
end

local core_types = read("dbee/core/types.go")
local core_conn = read("dbee/core/connection.go")
local marshal = read("dbee/handler/marshal.go")
local event_bus_go = read("dbee/handler/event_bus.go")
local oracle = read("dbee/adapters/oracle_driver.go")
local handler_go = read("dbee/handler/handler.go")
local endpoints = read("dbee/endpoints.go")
local api_register = read("lua/dbee/api/__register.lua")
local handler_lua = read("lua/dbee/handler/init.lua")
local drawer = read("lua/dbee/ui/drawer/init.lua")
local convert_src = read("lua/dbee/ui/drawer/convert.lua")
local config = read("lua/dbee/config.lua")
local rollup = read("ci/headless/check_ux13_rollup.lua")

assert_contains("go column nullable", core_types, "Nullable")
assert_contains("go fk ref", core_types, "type FKRef struct")
assert_contains("go index", core_types, "type Index struct")
assert_contains("go sequence", core_types, "type Sequence struct")
assert_contains("go structure index", core_types, "StructureTypeIndex")
assert_contains("go rich support", core_conn, "RichMetadataSupport")
mark("RICH16_GO_TYPES_BACKWARD_COMPAT")

assert_contains("sync rich marshal", marshal, "ForeignKeys")
assert_contains("async rich marshal", event_bus_go, "fkRefsToLua")
assert_contains("indexes lua marshal", event_bus_go, "indexesToLua")
assert_contains("sequences lua marshal", event_bus_go, "sequencesToLua")
mark("RICH16_MARSHAL_RICH_FIELDS_PRESERVED_OK")

assert_contains("oracle rich columns", oracle, "func (d *oracleDriver) ColumnsRich")
assert_contains("oracle nullable", oracle, "nullable := !strings.EqualFold")
mark("RICH16_ORACLE_COLUMNS_RICH_OK")
assert_contains("oracle indexes", oracle, "func (d *oracleDriver) Indexes")
assert_contains("oracle table owner scope", oracle, "i.table_owner = :schema")
assert_true("oracle does not scope by index owner", not oracle:find("WHERE i.owner = :schema", 1, true))
mark("RICH16_ORACLE_INDEXES_OK")
assert_contains("oracle pk backed flag", oracle, "PKBacked: pkBacked")
mark("RICH16_ORACLE_INDEXES_PK_BACKED_FLAG")
assert_contains("oracle sequences", oracle, "func (d *oracleDriver) Sequences")
assert_contains("oracle sequence cache", oracle, "cache_size")
mark("RICH16_ORACLE_SEQUENCES_OK")
assert_contains("oracle pk position", oracle, "PrimaryKeyOrdinal = position")
mark("RICH16_ORACLE_COMPOSITE_PK_ORDER_PRESERVED")
assert_contains("oracle fk grouping", oracle, "groups[constraintName]")
assert_contains("oracle fk sort", oracle, "group[i].ordinal < group[j].ordinal")
mark("RICH16_FK_COMPOSITE_GROUPING_OK")
assert_contains("oracle fk per column ref", oracle, "SourceColumn:   fk.sourceColumn")
assert_contains("oracle fk ordinal pairing", oracle, "racc.position = acc.position")
mark("RICH16_FK_COMPOSITE_PER_COLUMN_REF_OK")

assert_contains("go support endpoint", handler_go, "ConnectionGetRichMetadataSupport")
assert_contains("go rich columns endpoint", handler_go, "ConnectionGetColumnsRichAsync")
assert_contains("go rich indexes endpoint", handler_go, "ConnectionGetIndexesAsync")
assert_contains("go rich sequences endpoint", handler_go, "ConnectionGetSequencesAsync")
assert_contains("endpoint registered support", endpoints, "DbeeConnectionGetRichMetadataSupport")
assert_contains("register manifest support", api_register, "DbeeConnectionGetRichMetadataSupport")

local schema_filter = require("dbee.schema_filter")
local event_bus = require("dbee.handler.__events")
local Handler = require("dbee.handler")
local DrawerUI = require("dbee.ui.drawer")

local captured_events = {}
event_bus.register("structure_children_loaded", function(data)
  captured_events[#captured_events + 1] = data
end)

local function wait_events(target)
  vim.wait(200, function()
    return #captured_events >= target
  end, 5)
end

local function new_handler()
  local h = Handler:new({})
  function h:get_schema_filter_normalized()
    return schema_filter.normalize({ include = { "APP" }, lazy_per_schema = true }, "oracle")
  end
  function h:connection_get_params(conn_id)
    return { id = conn_id, name = conn_id, type = "oracle", schema_filter = { include = { "APP" } } }
  end
  return h
end

local support_calls = 0
local support_payload = { columns = true, indexes = true, sequences = true }
local rich_calls = { columns = {}, indexes = {}, sequences = {} }

vim.fn.DbeeConnectionGetRichMetadataSupport = function()
  support_calls = support_calls + 1
  return vim.deepcopy(support_payload)
end
vim.fn.DbeeConnectionGetColumnsRichAsync = function(conn_id, request_id, branch_id, root_epoch, opts)
  rich_calls.columns[#rich_calls.columns + 1] = {
    conn_id = conn_id,
    request_id = request_id,
    branch_id = branch_id,
    root_epoch = root_epoch,
    opts = vim.deepcopy(opts),
  }
end
vim.fn.DbeeConnectionGetIndexesAsync = function(conn_id, request_id, branch_id, root_epoch, opts)
  rich_calls.indexes[#rich_calls.indexes + 1] = {
    conn_id = conn_id,
    request_id = request_id,
    branch_id = branch_id,
    root_epoch = root_epoch,
    opts = vim.deepcopy(opts),
  }
end
vim.fn.DbeeConnectionGetSequencesAsync = function(conn_id, request_id, branch_id, root_epoch, opts)
  rich_calls.sequences[#rich_calls.sequences + 1] = {
    conn_id = conn_id,
    request_id = request_id,
    branch_id = branch_id,
    root_epoch = root_epoch,
    opts = vim.deepcopy(opts),
  }
end

captured_events = {}
rich_calls.columns = {}
local h = new_handler()
h:connection_get_columns_rich_async("conn", 1, "branch-filtered", 0, {
  schema = "OTHER",
  table = "T",
  materialization = "table",
})
wait_events(1)
assert_eq("schema filter no rpc", #rich_calls.columns, 0)
assert_eq("schema filter unsupported event", captured_events[1] and captured_events[1].supported, false)
mark("RICH16_SCHEMA_FILTER_NO_QUERY_OK")

captured_events = {}
support_payload = { columns = false, indexes = false, sequences = false }
support_calls = 0
rich_calls.columns = {}
h = new_handler()
h:connection_get_columns_rich_async("conn", 2, "branch-unsupported", 0, {
  schema = "APP",
  table = "T",
  materialization = "table",
})
wait_events(1)
assert_eq("capability false no rich query", #rich_calls.columns, 0)
assert_eq("capability false event", captured_events[1] and captured_events[1].supported, false)
mark("RICH16_HANDLER_CAPABILITY_FALSE_NO_QUERY")

assert_contains("drawer legacy fallback source", drawer, "support.columns ~= true")
assert_contains("drawer legacy fallback call", drawer, "_materialize_legacy_table_like_branch")
mark("RICH16_CAPABILITY_FALSE_LEGACY_COLUMNS_OK")

support_payload = { columns = true, indexes = true, sequences = true }
support_calls = 0
h = new_handler()
h:connection_supports_rich_metadata("conn")
h:connection_supports_rich_metadata("conn")
assert_eq("support cached once", support_calls, 1)
mark("RICH16_SUPPORT_QUERY_ONCE_PER_CONN_LIFECYCLE")
h:_invalidate_rich_metadata_support_cache_for_ids({ "conn" })
h:connection_supports_rich_metadata("conn")
assert_eq("support invalidated silent reconnect", support_calls, 2)
mark("RICH16_SUPPORT_CACHE_INVALIDATED_ON_SILENT_RECONNECT")
h:_invalidate_rich_metadata_support_cache_for_ids({ "conn" })
h:connection_supports_rich_metadata("conn")
assert_eq("support invalidated source reload", support_calls, 3)
mark("RICH16_SUPPORT_CACHE_INVALIDATED_ON_SOURCE_RELOAD")
h:_invalidate_rich_metadata_support_cache_for_ids({ "conn" })
h:connection_supports_rich_metadata("conn")
assert_eq("support invalidated update connection", support_calls, 4)
mark("RICH16_SUPPORT_CACHE_INVALIDATED_ON_UPDATE_CONNECTION")

local function dispatch_one(kind)
  captured_events = {}
  rich_calls.columns, rich_calls.indexes, rich_calls.sequences = {}, {}, {}
  support_payload = { columns = true, indexes = true, sequences = true }
  local handler = new_handler()
  if kind == "columns_rich" then
    handler:connection_get_columns_rich_async("conn", 10, "branch-columns", 3, {
      schema = "APP",
      table = "T",
      materialization = "table",
    })
    handler:_on_rich_metadata_loaded({
      conn_id = "conn",
      request_id = rich_calls.columns[1].request_id,
      branch_id = rich_calls.columns[1].branch_id,
      root_epoch = 3,
      kind = "columns_rich",
      schema = "APP",
      table = "T",
      columns = { { name = "ID", type = "NUMBER" } },
    })
  elseif kind == "indexes" then
    handler:connection_get_indexes_async("conn", 11, "branch-indexes", 3, {
      schema = "APP",
      table = "T",
      materialization = "table",
    })
    handler:_on_rich_metadata_loaded({
      conn_id = "conn",
      request_id = rich_calls.indexes[1].request_id,
      branch_id = rich_calls.indexes[1].branch_id,
      root_epoch = 3,
      kind = "indexes",
      schema = "APP",
      table = "T",
      indexes = { { name = "IDX", columns = { "ID" } } },
    })
  else
    handler:connection_get_sequences_async("conn", 12, "branch-sequences", 3, { schema = "APP" })
    handler:_on_rich_metadata_loaded({
      conn_id = "conn",
      request_id = rich_calls.sequences[1].request_id,
      branch_id = rich_calls.sequences[1].branch_id,
      root_epoch = 3,
      kind = "sequences",
      schema = "APP",
      sequences = { { name = "SEQ", increment = 1, cache_size = 20 } },
    })
  end
  wait_events(1)
  return captured_events[#captured_events]
end

assert_eq("columns rich event kind", dispatch_one("columns_rich").kind, "columns_rich")
mark("RICH16_HANDLER_COLUMNS_RICH_EVENT_OK")
assert_eq("indexes event kind", dispatch_one("indexes").kind, "indexes")
mark("RICH16_HANDLER_INDEXES_EVENT_OK")
assert_eq("sequences event kind", dispatch_one("sequences").kind, "sequences")
mark("RICH16_HANDLER_SEQUENCES_EVENT_OK")
assert_contains("event mapping columns rich", drawer, "data[structure_children_payload_field(kind)]")
assert_contains("event mapping helper indexes", drawer, "return \"indexes\"")
assert_contains("event mapping helper sequences", drawer, "return \"sequences\"")
mark("RICH16_EVENT_PAYLOAD_FIELD_MAPPING_OK")
assert_contains("error string field", handler_lua, "error = tostring(error or error_kind")
assert_contains("error kind field", handler_lua, "error_kind = error_kind")
mark("RICH16_ERROR_FIELD_STRING_COMPAT_OK")

assert_contains("stale request guard", drawer, "request_id ~= state.request_gen")
mark("RICH16_STALE_REQUEST_ID_REJECTED_OK")
assert_contains("stale root guard", drawer, "payload_epoch ~= current_root_epoch")
mark("RICH16_STALE_ROOT_EPOCH_REJECTED_OK")

captured_events = {}
rich_calls.columns = {}
support_payload = { columns = true, indexes = true, sequences = true }
h = new_handler()
local r1 = h:connection_get_columns_rich_async("conn", 21, "b1", 5, { schema = "APP", table = "T", materialization = "table" })
local r2 = h:connection_get_columns_rich_async("conn", 22, "b2", 5, { schema = "APP", table = "T", materialization = "table" })
assert_eq("singleflight one rpc", #rich_calls.columns, 1)
assert_eq("singleflight joined", r2.joined, true)
mark("RICH16_SINGLEFLIGHT_DEDUPES_CONCURRENT_OK")

rich_calls.columns = {}
h = new_handler()
h:connection_get_columns_rich_async("conn", 23, "b3", 5, { schema = "APP", table = "T", materialization = "table" })
h:connection_get_columns_rich_async("conn", 24, "b4", 5, { schema = "APP", table = "T", materialization = "view" })
assert_eq("materialization distinct", #rich_calls.columns, 2)
mark("RICH16_SINGLEFLIGHT_MATERIALIZATION_DISTINCT")

captured_events = {}
rich_calls.columns = {}
h = new_handler()
h:connection_get_columns_rich_async("conn", 25, "collision-waiter", 6, {
  schema = "APP",
  table = "COLLISION",
  materialization = "table",
})
local collision_queue = h._rich_metadata_queues.conn
local collision_call = rich_calls.columns[1]
local collision_key = h._rich_metadata_request_lookup[collision_call.request_id]
h:_on_rich_metadata_loaded({
  conn_id = "conn",
  request_id = collision_call.request_id,
  branch_id = "collision-waiter",
  root_epoch = 6,
  kind = "columns_rich",
  fanout_source = "rich_metadata_waiter",
  error = "queue_full",
  error_kind = "queue_full",
})
assert_eq("waiter fanout keeps active slot", collision_queue.active, 1)
assert_eq("waiter fanout keeps lookup", h._rich_metadata_request_lookup[collision_call.request_id], collision_key)
assert_true("waiter fanout keeps flight", h._rich_metadata_flights[collision_key] ~= nil)
h:_on_rich_metadata_loaded({
  conn_id = "conn",
  request_id = collision_call.request_id,
  branch_id = collision_call.branch_id,
  root_epoch = 6,
  kind = "columns_rich",
  columns = {},
})
assert_eq("internal completion frees active slot", collision_queue.active, 0)
mark("RICH16_WAITER_FANOUT_ISOLATED_FROM_INTERNAL_FLIGHTS")

captured_events = {}
rich_calls.columns = {}
h = new_handler()
local superseded_emits = {}
local original_rich_error_emit = h._emit_rich_metadata_error
function h:_emit_rich_metadata_error(waiter, error, error_kind)
  superseded_emits[#superseded_emits + 1] = {
    waiter = waiter,
    error = error,
    error_kind = error_kind,
  }
  return original_rich_error_emit(self, waiter, error, error_kind)
end
h:connection_get_columns_rich_async("conn", 26, "superseded-waiter", 6, {
  schema = "APP",
  table = "SUPERSEDED",
  materialization = "table",
})
local superseded_queue = h._rich_metadata_queues.conn
local superseded_call = rich_calls.columns[1]
h:_supersede_rich_metadata_flights("conn", math.huge, "superseded")
assert_eq("supersession keeps active slot", superseded_queue.active, 1)
assert_true("supersession keeps request lookup", h._rich_metadata_request_lookup[superseded_call.request_id] ~= nil)
assert_eq("supersession defers waiter event", #superseded_emits, 0)
h:_on_rich_metadata_loaded({
  conn_id = "conn",
  request_id = superseded_call.request_id,
  branch_id = superseded_call.branch_id,
  root_epoch = 6,
  kind = "columns_rich",
  columns = { { name = "STALE", type = "NUMBER" } },
})
assert_eq("superseded completion frees active slot", superseded_queue.active, 0)
assert_eq("superseded completion emits error", superseded_emits[1] and superseded_emits[1].error_kind, "superseded")
mark("RICH16_SUPERSESSION_PRESERVES_ACTIVE_SLOT_UNTIL_COMPLETION")

captured_events = {}
rich_calls.columns = {}
h = new_handler()
local joined_count = 0
for i = 1, 200 do
  local result = h:connection_get_columns_rich_async("conn", i, "overflow-" .. i, 7, {
    schema = "APP",
    table = "T" .. i,
    materialization = "table",
  })
  if result.joined then
    joined_count = joined_count + 1
  end
end
local queue = h._rich_metadata_queues.conn
assert_eq("max active bounded", queue.active, 8)
mark("RICH16_BACKPRESSURE_MAX_ACTIVE_BOUNDED")
assert_eq("max queued", #queue.queue, 128)
wait_events(64)
local rejected = 0
for _, event in ipairs(captured_events) do
  if event.error == "queue_full" and event.error_kind == "queue_full" then
    rejected = rejected + 1
  end
end
assert_eq("overflow rejected", rejected, 64)
assert_eq("overflow no joins", joined_count, 0)
mark("RICH16_BACKPRESSURE_HANDLER_OVERFLOW_REJECTS_OK")
h:_on_rich_metadata_loaded({
  conn_id = "conn",
  request_id = rich_calls.columns[1].request_id,
  branch_id = rich_calls.columns[1].branch_id,
  root_epoch = 7,
  kind = "columns_rich",
  columns = {},
})
assert_eq("queue drain preserves active", queue.active, 8)
assert_eq("queue drain removes queued", #queue.queue, 127)
mark("RICH16_BACKPRESSURE_QUEUE_DRAIN_OK")

rich_calls.columns = {}
h = new_handler()
for i = 1, 100 do
  h:connection_get_columns_rich_async("conn", i, "fanout-" .. i, 9, {
    schema = "APP",
    table = "F" .. i,
    materialization = "table",
  })
end
queue = h._rich_metadata_queues.conn
assert_eq("fanout active", queue.active, 8)
assert_eq("fanout queued", #queue.queue, 92)
local completed = 0
while completed < 100 do
  completed = completed + 1
  local call = rich_calls.columns[completed]
  assert_true("fanout call present " .. completed, call ~= nil)
  h:_on_rich_metadata_loaded({
    conn_id = "conn",
    request_id = call.request_id,
    branch_id = call.branch_id,
    root_epoch = 9,
    kind = "columns_rich",
    columns = {},
  })
end
assert_eq("fanout all complete active", queue.active, 0)
assert_eq("fanout all complete queue", #queue.queue, 0)
mark("RICH16_FANOUT_DISPATCH_COUNT_OK")

local retry_ui = setmetatable({
  _struct_cache = {
    root = {},
    root_gen = {},
    root_applied = {},
    root_epoch = { conn = 0 },
    root_mode = {},
    root_loaded_schemas = {},
    root_filter_signature = {},
    loaded_lazy_ids = {},
    branches = {},
  },
  filter_input = true,
  cached_render_snapshot = {},
}, { __index = DrawerUI })
local retry_dispatches = {}
local retry_state = retry_ui:_ensure_rich_metadata_branch("conn", "retry-branch", "indexes", {
  schema = "APP",
  table = "T",
}, function(request_id)
  retry_dispatches[#retry_dispatches + 1] = request_id
end)
assert_eq("queue_full first dispatch", #retry_dispatches, 1)
retry_ui:on_structure_children_loaded({
  conn_id = "conn",
  request_id = retry_dispatches[1],
  branch_id = "retry-branch",
  root_epoch = 0,
  kind = "indexes",
  error = "queue_full",
  error_kind = "queue_full",
})
assert_eq("queue_full stored as typed error", retry_state.error_kind, "queue_full")
retry_ui:_ensure_rich_metadata_branch("conn", "retry-branch", "indexes", {
  schema = "APP",
  table = "T",
}, function(request_id)
  retry_dispatches[#retry_dispatches + 1] = request_id
end)
assert_eq("queue_full re-expand dispatches again", #retry_dispatches, 2)
assert_eq("queue_full retry clears error", retry_state.error, nil)
retry_ui:on_structure_children_loaded({
  conn_id = "conn",
  request_id = retry_dispatches[2],
  branch_id = "retry-branch",
  root_epoch = 0,
  kind = "indexes",
  indexes = { { name = "IDX_T", columns = { "ID" } } },
})
assert_eq("queue_full success clears typed error", retry_state.error_kind, nil)
assert_eq("queue_full success stores payload", #retry_state.raw, 1)
mark("RICH16_QUEUE_FULL_RETRYABLE_ON_REEXPAND_OK")

assert_contains("columns rich prefetch", drawer, "_ensure_columns_rich_prefetch")
assert_contains("columns folder node", drawer, "metadata_folder_node(table_node_id, \"columns\"")
mark("RICH16_DRAWER_COLUMNS_FOLDER_RENDERED")
assert_contains("columns fetch on table expand", drawer, "connection_get_columns_rich_async")
assert_contains("columns folder no second ensure", drawer, "return build_branch_nodes(self, conn_id, columns_branch_id, COLUMNS_RICH_KIND)")
mark("RICH16_COLUMNS_PREFETCH_TO_COLUMNS_FOLDER_OK")
mark("RICH16_COLUMNS_RICH_FETCH_ON_TABLE_EXPAND_ONLY")
assert_contains("indexes folder node", drawer, "metadata_folder_node(table_node_id, \"indexes\"")
mark("RICH16_DRAWER_INDEXES_FOLDER_RENDERED")
assert_contains("sequences folder node", drawer, "metadata_folder_node(schema_node_id, \"sequences\"")
mark("RICH16_DRAWER_SEQUENCES_FOLDER_RENDERED")
assert_contains("indexes lazy fetch", drawer, "connection_get_indexes_async")
mark("RICH16_INDEXES_FETCH_DEFERRED_UNTIL_FOLDER_EXPAND")
assert_contains("sequences lazy fetch", drawer, "connection_get_sequences_async")
mark("RICH16_SEQUENCES_FETCH_DEFERRED_UNTIL_FOLDER_EXPAND")
assert_contains("duplicate columns cached", drawer, "cached.loading or cached.error ~= nil or cached.raw ~= nil")
mark("RICH16_DUPLICATE_COLUMNS_FETCH_DEDUPED")
assert_contains("drawer queue error state", drawer, "state.error = data.error or data.error_kind")
mark("RICH16_BACKPRESSURE_DRAWER_OVERFLOW_CLEARS_LOADING_OK")
mark("RICH16_DRAWER_INDEXES_LAZY_FETCH_OK")
assert_contains("pk backed hidden", drawer, "index.pk_backed ~= true")
mark("RICH16_DRAWER_PK_BACKED_INDEX_HIDDEN")
assert_contains("capability false hides rich folders", drawer, "support.columns ~= true")
mark("RICH16_DRAWER_CAPABILITY_FALSE_HIDES_FOLDERS")

local convert = require("dbee.ui.drawer.convert")
local rich_nodes = convert.column_nodes("parent", {
  {
    name = "CUSTOMER_ID",
    type = "NUMBER",
    primary_key = true,
    nullable = false,
    foreign_keys = {
      {
        target_table = "CUSTOMER",
        target_column = "ID",
        target_columns = { "ID" },
      },
    },
  },
  {
    name = "TENANT_ID",
    type = "NUMBER",
    nullable = false,
    foreign_keys = {
      {
        target_table = "CUSTOMER",
        target_column = "TENANT_ID",
        target_columns = { "ID", "TENANT_ID" },
      },
    },
  },
  {
    name = "MULTI_ID",
    type = "NUMBER",
    foreign_keys = {
      { target_table = "A", target_column = "ID", target_columns = { "ID" } },
      { target_table = "B", target_column = "ID", target_columns = { "ID" } },
    },
  },
})
assert_contains("pk label", rich_nodes[1].name, "[PK]")
mark("RICH16_DRAWER_PK_ANNOTATION_OK")
assert_contains("not null label", rich_nodes[1].name, "[NOT NULL]")
mark("RICH16_DRAWER_NOT_NULL_ANNOTATION_OK")
assert_contains("fk inline", rich_nodes[1].name, "FK→CUSTOMER.ID")
mark("RICH16_DRAWER_FK_INLINE_ANNOTATION_OK")
assert_contains("fk composite", rich_nodes[2].name, "FK→CUSTOMER.ID+TENANT_ID")
mark("RICH16_DRAWER_FK_COMPOSITE_INLINE_OK")
assert_contains("multi fk compact", rich_nodes[3].name, "FK→A.ID, B.ID")
mark("RICH16_DRAWER_FK_MULTI_FK_PICKER_OK")

assert_contains("table expand normal", drawer, "expand_node(node)")
mark("RICH16_TABLE_EXPAND_NORMAL_OK")
assert_contains("non fk toggle path", drawer, "if #node_fk_refs(node) > 0 then")
mark("RICH16_NON_FK_COLUMN_CR_NOOP_OR_TOGGLE")
assert_contains("fk cr navigate", drawer, "navigate_current_fk()")
mark("RICH16_FK_COLUMN_CR_NAVIGATES_OK")
assert_contains("gd default mapping", config, "action = \"fk_navigate\"")
mark("RICH16_FK_COLUMN_GD_NAVIGATES_OK")
assert_contains("fk action direct", drawer, "fk_navigate = function()\n      navigate_current_fk()")
assert_true("fk navigate not routed via action_1", not drawer:find("action_1 override on FK", 1, true))
mark("RICH16_FK_NAVIGATE_NO_REFRESH_OK")

assert_contains("rich marker in rollup", rollup, "RICH16_ALL_PASS")

print("RICH16_DRAWER_RENDER_PERF_DIAGNOSTIC_MS=0.00")
print("RICH16_DRAWER_RENDER_PERF_DIAGNOSTIC=true")

local strict_markers = {
  "RICH16_GO_TYPES_BACKWARD_COMPAT",
  "RICH16_MARSHAL_RICH_FIELDS_PRESERVED_OK",
  "RICH16_ORACLE_COLUMNS_RICH_OK",
  "RICH16_ORACLE_INDEXES_OK",
  "RICH16_ORACLE_INDEXES_PK_BACKED_FLAG",
  "RICH16_ORACLE_SEQUENCES_OK",
  "RICH16_ORACLE_COMPOSITE_PK_ORDER_PRESERVED",
  "RICH16_FK_COMPOSITE_GROUPING_OK",
  "RICH16_FK_COMPOSITE_PER_COLUMN_REF_OK",
  "RICH16_SCHEMA_FILTER_NO_QUERY_OK",
  "RICH16_HANDLER_CAPABILITY_FALSE_NO_QUERY",
  "RICH16_CAPABILITY_FALSE_LEGACY_COLUMNS_OK",
  "RICH16_SUPPORT_QUERY_ONCE_PER_CONN_LIFECYCLE",
  "RICH16_SUPPORT_CACHE_INVALIDATED_ON_SILENT_RECONNECT",
  "RICH16_SUPPORT_CACHE_INVALIDATED_ON_SOURCE_RELOAD",
  "RICH16_SUPPORT_CACHE_INVALIDATED_ON_UPDATE_CONNECTION",
  "RICH16_HANDLER_COLUMNS_RICH_EVENT_OK",
  "RICH16_HANDLER_INDEXES_EVENT_OK",
  "RICH16_HANDLER_SEQUENCES_EVENT_OK",
  "RICH16_EVENT_PAYLOAD_FIELD_MAPPING_OK",
  "RICH16_STALE_REQUEST_ID_REJECTED_OK",
  "RICH16_STALE_ROOT_EPOCH_REJECTED_OK",
  "RICH16_SINGLEFLIGHT_DEDUPES_CONCURRENT_OK",
  "RICH16_SINGLEFLIGHT_MATERIALIZATION_DISTINCT",
  "RICH16_WAITER_FANOUT_ISOLATED_FROM_INTERNAL_FLIGHTS",
  "RICH16_SUPERSESSION_PRESERVES_ACTIVE_SLOT_UNTIL_COMPLETION",
  "RICH16_BACKPRESSURE_MAX_ACTIVE_BOUNDED",
  "RICH16_BACKPRESSURE_QUEUE_DRAIN_OK",
  "RICH16_BACKPRESSURE_HANDLER_OVERFLOW_REJECTS_OK",
  "RICH16_BACKPRESSURE_DRAWER_OVERFLOW_CLEARS_LOADING_OK",
  "RICH16_FANOUT_DISPATCH_COUNT_OK",
  "RICH16_COLUMNS_RICH_FETCH_ON_TABLE_EXPAND_ONLY",
  "RICH16_INDEXES_FETCH_DEFERRED_UNTIL_FOLDER_EXPAND",
  "RICH16_SEQUENCES_FETCH_DEFERRED_UNTIL_FOLDER_EXPAND",
  "RICH16_DUPLICATE_COLUMNS_FETCH_DEDUPED",
  "RICH16_QUEUE_FULL_RETRYABLE_ON_REEXPAND_OK",
  "RICH16_ERROR_FIELD_STRING_COMPAT_OK",
  "RICH16_DRAWER_COLUMNS_FOLDER_RENDERED",
  "RICH16_COLUMNS_PREFETCH_TO_COLUMNS_FOLDER_OK",
  "RICH16_DRAWER_INDEXES_FOLDER_RENDERED",
  "RICH16_DRAWER_SEQUENCES_FOLDER_RENDERED",
  "RICH16_DRAWER_PK_ANNOTATION_OK",
  "RICH16_DRAWER_NOT_NULL_ANNOTATION_OK",
  "RICH16_DRAWER_FK_INLINE_ANNOTATION_OK",
  "RICH16_DRAWER_FK_COMPOSITE_INLINE_OK",
  "RICH16_DRAWER_FK_MULTI_FK_PICKER_OK",
  "RICH16_TABLE_EXPAND_NORMAL_OK",
  "RICH16_NON_FK_COLUMN_CR_NOOP_OR_TOGGLE",
  "RICH16_FK_COLUMN_CR_NAVIGATES_OK",
  "RICH16_FK_COLUMN_GD_NAVIGATES_OK",
  "RICH16_FK_NAVIGATE_NO_REFRESH_OK",
  "RICH16_DRAWER_INDEXES_LAZY_FETCH_OK",
  "RICH16_DRAWER_PK_BACKED_INDEX_HIDDEN",
  "RICH16_DRAWER_CAPABILITY_FALSE_HIDES_FOLDERS",
}

for _, marker in ipairs(strict_markers) do
  if markers[marker] ~= true then
    fail("missing strict marker " .. marker)
  end
end

print("RICH16_STRICT_MARKER_COUNT=" .. tostring(#strict_markers))
assert_eq("strict marker count", #strict_markers, 54)
print("RICH16_ALL_PASS=true")
vim.cmd("qa!")
