-- Headless release-grade perf harness for Phase 10 LSP01 evidence.
--
-- Usage:
--   make perf-lsp
--   LSP01_PERF_GATE_MODE=advisory make perf-lsp PERF_PLATFORM=macos
--   LSP01_PERF_GATE_MODE=advisory make perf-lsp PERF_PLATFORM=linux

local uv = vim.uv or vim.loop

local WARMUP_COUNT = 5
local MEASURED_COUNT = 10
local SCENARIO_TIMEOUT_MS = 30000

local emitted_markers = {}
local summary_rows = {}
local scenario_results = {}
local scenario_sentinels = {}

local function fail(msg)
  print("LSP01_FAIL=" .. tostring(msg))
  vim.cmd("cquit 1")
end

local function emit(label, value)
  local line = label .. "=" .. tostring(value)
  emitted_markers[#emitted_markers + 1] = line
  print(line)
end

local function format_float(value)
  if value == nil then
    return "NA"
  end
  return string.format("%.2f", value)
end

local function ns_to_ms(value)
  return value / 1e6
end

local function deepcopy(value)
  return vim.deepcopy(value)
end

local function median(values)
  if #values == 0 then
    return 0
  end
  local sorted = deepcopy(values)
  table.sort(sorted)
  local mid = math.floor(#sorted / 2) + 1
  if #sorted % 2 == 1 then
    return sorted[mid]
  end
  return (sorted[mid - 1] + sorted[mid]) / 2
end

local function percentile(values, ratio)
  if #values == 0 then
    return 0
  end
  local sorted = deepcopy(values)
  table.sort(sorted)
  local index = math.max(1, math.ceil(#sorted * ratio))
  return sorted[index]
end

local function marker_value(value)
  if value == nil then
    return "NA"
  end
  return format_float(value)
end

local function current_script_path()
  local source = debug.getinfo(1, "S").source or ""
  if source:sub(1, 1) == "@" then
    return source:sub(2)
  end
  return source
end

local function write_lines(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local ok, result = pcall(vim.fn.writefile, lines, path)
  if not ok or result ~= 0 then
    fail("failed to write artifact: " .. path)
  end
end

local function load_threshold_file(path)
  local chunk, err = loadfile(path)
  if not chunk then
    fail("failed to load threshold file: " .. tostring(err))
  end
  local ok, loaded = pcall(chunk)
  if not ok then
    fail("failed to execute threshold file: " .. tostring(loaded))
  end
  if type(loaded) ~= "table" or type(loaded.linux) ~= "table" or type(loaded.macos) ~= "table" then
    fail("threshold file must return { linux = {...}, macos = {...} }: " .. path)
  end
  return loaded
end

local benchmark_ok, benchmark = pcall(require, "benchmark")
if not benchmark_ok then
  fail("benchmark.nvim missing from runtimepath")
end

local benchmark_ui_ok, benchmark_ui = pcall(require, "benchmark.ui")
if benchmark_ui_ok and benchmark_ui then
  benchmark_ui.show_message = function() end
end

local threshold_path = vim.env.LSP01_PERF_THRESHOLD_FILE or "ci/headless/lsp_perf_thresholds.lua"
if not uv.fs_stat(threshold_path) then
  fail("missing threshold file: " .. threshold_path)
end
local thresholds = load_threshold_file(threshold_path)

local gate_mode = vim.env.LSP01_PERF_GATE_MODE or "advisory"
if gate_mode ~= "advisory" and gate_mode ~= "blocking" then
  fail("unsupported LSP01_PERF_GATE_MODE=" .. tostring(gate_mode))
end

local uname = uv.os_uname() or {}
local sysname = uname.sysname or ""
local actual_os = sysname == "Darwin" and "darwin" or (sysname:lower():match("linux") and "linux" or "other")
local platform = vim.env.PERF_PLATFORM
if platform ~= "linux" and platform ~= "macos" then
  platform = actual_os == "darwin" and "macos" or "linux"
end
local expected_os = platform == "macos" and "darwin" or "linux"
local platform_authentic = actual_os == expected_os
local allow_nonpublishable = vim.env.LSP01_ALLOW_NONPUBLISHABLE_PLATFORM_OVERRIDE == "1"
local publishable = platform_authentic

local artifact_dir = vim.env.LSP01_PERF_ARTIFACT_DIR or ("/tmp/nvim-dbee-lsp01-perf/" .. platform)
local summary_path = vim.env.LSP01_PERF_SUMMARY_PATH or (artifact_dir .. "/lsp01-summary.txt")
local trace_path = vim.env.LSP01_PERF_TRACE_PATH or (artifact_dir .. "/lsp01-trace.json")
local trace_only = vim.env.LSP01_PERF_TRACE_ONLY == "1"

vim.fn.mkdir(artifact_dir, "p")

local nvim_version = vim.version()
local nvim_version_string = string.format("%d.%d.%d", nvim_version.major, nvim_version.minor, nvim_version.patch)

emit("LSP01_PERF_MODE", "real-lsp")
emit("LSP01_PERF_GATE_MODE", gate_mode)
emit("LSP01_PLATFORM", platform)
emit("LSP01_ACTUAL_OS", actual_os)
emit("LSP01_PLATFORM_AUTHENTIC", platform_authentic and "true" or "false")
emit("LSP01_PUBLISHABLE", publishable and "true" or "false")
emit("LSP01_NVIM_VERSION", nvim_version_string)
emit("LSP01_THRESHOLD_FILE", threshold_path)
emit("LSP01_SUMMARY_ARTIFACT", summary_path)
emit("LSP01_FLAME_TRACE_ARTIFACT", trace_path)
emit("LSP01_WARMUP_COUNT", WARMUP_COUNT)
emit("LSP01_MEASURED_COUNT", MEASURED_COUNT)
emit("LSP01_STDPATH_STATE", vim.fn.stdpath("state"))

if not platform_authentic and not allow_nonpublishable then
  emit("LSP01_REAL_LSP_PERF_ALL_PASS", "false")
  write_lines(summary_path, {
    "LSP01 Phase 10 perf summary",
    "platform_authentic=false",
    "publishable=false",
    "markers:",
    unpack(emitted_markers),
  })
  fail("PERF_PLATFORM does not match actual OS")
end

local SCENARIOS = {}

local function register(spec)
  SCENARIOS[#SCENARIOS + 1] = spec
  return spec
end

local CONNECTION_TYPE_NO_METADATA = "dbee-perf-no-metadata"
local CONNECTION_TYPE_METADATA = "postgres"
local DEFAULT_CONN_ID = "lsp01-conn"
local DEFAULT_COLUMNS_PER_TABLE = 10

local function schema_for_index(index)
  return string.format("SCHEMA_%03d", ((index - 1) % 10) + 1)
end

local function table_for_index(index)
  return string.format("TABLE_%06d", index)
end

local function make_columns(_, _, columns_per_table)
  local columns = {}
  for i = 1, columns_per_table or DEFAULT_COLUMNS_PER_TABLE do
    columns[#columns + 1] = {
      name = string.format("COL_%03d", i),
      type = i % 2 == 0 and "NUMBER" or "VARCHAR2",
    }
  end
  return columns
end

local function make_structure(table_count, columns_per_table)
  local by_schema = {}
  for i = 1, table_count do
    local schema = schema_for_index(i)
    by_schema[schema] = by_schema[schema] or {
      name = schema,
      type = "schema",
      schema = schema,
      children = {},
    }
    local table_name = table_for_index(i)
    by_schema[schema].children[#by_schema[schema].children + 1] = {
      name = table_name,
      type = (i % 17 == 0) and "view" or "table",
      schema = schema,
      children = {},
      column_count = columns_per_table or DEFAULT_COLUMNS_PER_TABLE,
    }
  end

  local schemas = {}
  for _, schema_node in pairs(by_schema) do
    table.sort(schema_node.children, function(a, b)
      return a.name < b.name
    end)
    schemas[#schemas + 1] = schema_node
  end
  table.sort(schemas, function(a, b)
    return a.name < b.name
  end)
  return schemas
end

local function make_metadata_rows(table_count)
  local rows = {}
  for i = 1, table_count do
    rows[#rows + 1] = {
      schema_name = schema_for_index(i),
      table_name = table_for_index(i),
      obj_type = (i % 17 == 0) and "view" or "table",
    }
  end
  return rows
end

local function table_index_from_name(table_name)
  return tonumber((table_name or ""):match("TABLE_(%d+)$")) or 1
end

local function make_handler(opts)
  opts = opts or {}
  local conn_id = opts.conn_id or DEFAULT_CONN_ID
  local connection_type = opts.connection_type or CONNECTION_TYPE_NO_METADATA
  local table_count = opts.table_count or 100
  local columns_per_table = opts.columns_per_table or DEFAULT_COLUMNS_PER_TABLE
  local structure = opts.structure or make_structure(table_count, columns_per_table)
  local metadata_rows = opts.metadata_rows or make_metadata_rows(math.min(table_count, 100))
  local handler = {
    conn_id = conn_id,
    connection_type = connection_type,
    counters = {},
    column_fetch_deltas = {},
    metadata_execute_count = 0,
    metadata_call_id = nil,
    last_singleflight_opts = nil,
    structure = structure,
  }

  local function bump(name)
    handler.counters[name] = (handler.counters[name] or 0) + 1
  end

  function handler:get_current_connection()
    bump("get_current_connection")
    return {
      id = conn_id,
      name = "LSP01 perf connection",
      type = connection_type,
    }
  end

  function handler:get_authoritative_root_epoch()
    bump("get_authoritative_root_epoch")
    return 1
  end

  function handler:get_connection_state_snapshot()
    bump("get_connection_state_snapshot")
    return {
      current_connection = {
        id = conn_id,
        type = connection_type,
      },
      snapshot_authoritative_epoch = {
        [conn_id] = 1,
      },
    }
  end

  function handler:begin_connection_invalidated_bootstrap(_, _)
    bump("begin_connection_invalidated_bootstrap")
    return 1
  end

  function handler:drain_connection_invalidated_bootstrap(_, _)
    bump("drain_connection_invalidated_bootstrap")
    return {
      kind = "ok",
      events = {},
    }
  end

  function handler:promote_to_live(_, _)
    bump("promote_to_live")
    return {
      kind = "ok",
      events = {},
    }
  end

  function handler:teardown_connection_invalidated_consumer()
    bump("teardown_connection_invalidated_consumer")
  end

  function handler:teardown_structure_consumer()
    bump("teardown_structure_consumer")
  end

  function handler:connection_get_structure_singleflight(request)
    bump("connection_get_structure_singleflight")
    handler.last_singleflight_opts = request
    if opts.auto_structure ~= false and request and type(request.callback) == "function" then
      request.callback({
        conn_id = conn_id,
        caller_token = request.caller_token or "lsp",
        root_epoch = 1,
        structures = structure,
      })
    end
  end

  handler.connection_get_columns = function(_, request_conn_id, request_opts)
    bump("connection_get_columns")
    if request_conn_id ~= conn_id then
      error("unexpected conn_id: " .. tostring(request_conn_id))
    end
    if type(request_opts) ~= "table" or not request_opts.table then
      error("missing column request table")
    end
    local table_index = table_index_from_name(request_opts.table)
    local expected_schema = schema_for_index(table_index)
    local request_schema = request_opts.schema == "" and expected_schema or request_opts.schema
    if request_schema ~= expected_schema and request_opts.schema ~= "" then
      error(("unexpected schema for %s: %s"):format(request_opts.table, tostring(request_opts.schema)))
    end
    handler.column_fetch_deltas[#handler.column_fetch_deltas + 1] = 1
    return make_columns(request_schema, request_opts.table, columns_per_table)
  end

  function handler:connection_execute(request_conn_id, _)
    bump("connection_execute")
    if request_conn_id ~= conn_id then
      error("unexpected metadata conn_id: " .. tostring(request_conn_id))
    end
    handler.metadata_execute_count = handler.metadata_execute_count + 1
    handler.metadata_call_id = "lsp01-metadata-call-" .. tostring(handler.metadata_execute_count)
    return {
      id = handler.metadata_call_id,
      state = "archived",
    }
  end

  function handler:call_store_result(call_id, format, target, store_opts)
    bump("call_store_result")
    if call_id ~= handler.metadata_call_id then
      error("unexpected metadata call_id: " .. tostring(call_id))
    end
    if format ~= "json" or target ~= "file" or type(store_opts) ~= "table" or not store_opts.extra_arg then
      error("unexpected metadata result store request")
    end
    write_lines(store_opts.extra_arg, { vim.json.encode(metadata_rows) })
  end

  function handler:register_event_listener()
    bump("register_event_listener")
  end

  function handler:assert_lifecycle_methods_complete(cohort)
    local required = {
      "get_current_connection",
      "get_authoritative_root_epoch",
      "get_connection_state_snapshot",
      "begin_connection_invalidated_bootstrap",
      "drain_connection_invalidated_bootstrap",
      "promote_to_live",
      "connection_get_structure_singleflight",
    }
    local ok = true
    for _, name in ipairs(required) do
      if (handler.counters[name] or 0) == 0 then
        ok = false
      end
    end
    if cohort == "STARTUP_METADATA_FALLBACK" and handler.metadata_execute_count ~= 1 then
      ok = false
    end
    emit("LSP01_FAKE_HANDLER_LIFECYCLE_COMPLETE", ok and "true" or "false")
    return ok
  end

  return handler
end

local function make_cache(table_count, columns_per_table, opts)
  opts = opts or {}
  local SchemaCache = require("dbee.lsp.schema_cache")
  local handler = opts.handler or make_handler({
    table_count = table_count,
    columns_per_table = columns_per_table,
    conn_id = opts.conn_id,
  })
  local cache = SchemaCache:new(handler, opts.conn_id or DEFAULT_CONN_ID)
  cache:build_from_structure(opts.structure or make_structure(table_count, columns_per_table))
  if opts.preload_columns then
    for i = 1, table_count do
      local schema = schema_for_index(i)
      local table_name = table_for_index(i)
      cache.columns[schema .. "." .. table_name] = make_columns(schema, table_name, columns_per_table)
    end
  end
  return cache, handler
end

local buffer_counter = 0
local function make_buffer(lines)
  buffer_counter = buffer_counter + 1
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "/tmp/dbee-lsp01-" .. buffer_counter .. ".sql")
  vim.api.nvim_buf_set_option(bufnr, "filetype", "sql")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or { "" })
  return bufnr, vim.uri_from_bufnr(bufnr)
end

local function stop_client(client_id)
  if not client_id then
    return
  end
  local client = vim.lsp.get_client_by_id(client_id)
  if client then
    client:stop(true)
  end
end

local function start_lsp(cache, bufnr)
  local server = require("dbee.lsp.server")
  local client_id = vim.lsp.start({
    name = "dbee-lsp-perf",
    cmd = server.create(cache),
    root_dir = vim.fn.getcwd(),
  }, {
    bufnr = bufnr,
  })
  if not client_id then
    fail("vim.lsp.start returned nil")
  end
  local client = vim.lsp.get_client_by_id(client_id)
  local ok = vim.wait(1000, function()
    client = vim.lsp.get_client_by_id(client_id)
    return client ~= nil
  end, 5)
  if not ok or not client then
    fail("LSP client did not initialize")
  end
  return client, client_id
end

local active_defer_capture = nil
local function capture_defer_fn()
  local original = vim.defer_fn
  local capture = {
    queue = {},
    original = original,
  }
  vim.defer_fn = function(callback, timeout)
    capture.queue[#capture.queue + 1] = {
      callback = callback,
      timeout = timeout,
    }
  end
  active_defer_capture = capture
  return capture
end

local function drain_deferred(expected_count, label)
  local capture = active_defer_capture
  if not capture then
    fail("drain_deferred without active capture: " .. tostring(label))
  end
  local count = #capture.queue
  if count ~= expected_count then
    fail(("deferred callback count mismatch for %s: expected %d got %d"):format(label, expected_count, count))
  end
  while #capture.queue > 0 do
    local item = table.remove(capture.queue, 1)
    item.callback()
  end
  return count
end

local function restore_defer_fn()
  if active_defer_capture then
    vim.defer_fn = active_defer_capture.original
    active_defer_capture = nil
  end
end

local function with_fake_lsp_state(handler, fn)
  local prior_state = package.loaded["dbee.api.state"]
  local prior_lsp = package.loaded["dbee.lsp"]
  local fake_state_calls = {
    is_core_loaded = 0,
    handler = 0,
  }
  local fake_state = {
    is_core_loaded = function()
      fake_state_calls.is_core_loaded = fake_state_calls.is_core_loaded + 1
      return true
    end,
    handler = function()
      fake_state_calls.handler = fake_state_calls.handler + 1
      return handler
    end,
  }
  package.loaded["dbee.api.state"] = fake_state
  package.loaded["dbee.lsp"] = nil
  local lsp = require("dbee.lsp")
  local ok, result = xpcall(function()
    return fn(lsp)
  end, debug.traceback)
  pcall(lsp.stop)
  package.loaded["dbee.api.state"] = prior_state
  package.loaded["dbee.lsp"] = prior_lsp
  local fake_used = fake_state_calls.is_core_loaded > 0 and fake_state_calls.handler > 0
  emit("LSP01_FAKE_STATE_USED", fake_used and "true" or "false")
  if not ok then
    fail(result)
  end
  if not fake_used then
    fail("fake state was not used")
  end
  return result
end

local function queue_try_start(bufnr)
  local lsp = require("dbee.lsp")
  -- Production queue_buffer() invokes the private _try_start() lifecycle.
  lsp.queue_buffer(bufnr)
  return lsp
end

local function wait_running(lsp, label)
  local ok = vim.wait(1000, function()
    return lsp.status().running == true
  end, 5)
  if not ok then
    fail("LSP did not start: " .. tostring(label))
  end
end

local function wait_metadata_fallback(lsp, handler, opts)
  opts = opts or {}
  drain_deferred(1, opts.label or "metadata-fallback")
  if not handler.metadata_call_id then
    fail("metadata fallback did not create fake call")
  end
  -- _process_metadata_result() calls SchemaCache:build_from_metadata_rows().
  lsp._process_metadata_result(handler, handler.metadata_call_id, opts.conn_id or DEFAULT_CONN_ID)
  wait_running(lsp, opts.label or "metadata-fallback")
end

local function start_lsp_via_lifecycle(bufnr, handler, opts)
  opts = opts or {}
  local lsp = queue_try_start(bufnr, handler, opts)
  wait_running(lsp, opts.label)
  return lsp
end

local function assert_isolated_state()
  local state_dir = vim.fn.stdpath("state")
  local expected = vim.env.XDG_STATE_HOME
  if not expected or expected == "" or state_dir:sub(1, #expected) ~= expected then
    fail("stdpath(state) is outside XDG_STATE_HOME: " .. tostring(state_dir))
  end
  emit("LSP01_STDPATH_STATE", state_dir)
end

local function cleanup_lsp(state)
  state = state or {}
  if state.lsp then
    pcall(state.lsp.stop)
  else
    pcall(function()
      require("dbee.lsp").stop()
    end)
  end
  if state.expected_remaining_deferred ~= nil and active_defer_capture then
    drain_deferred(state.expected_remaining_deferred, state.label or "cleanup")
  end
  restore_defer_fn()
  if state.expected_metadata_execute_count ~= nil and state.handler
    and state.handler.metadata_execute_count ~= state.expected_metadata_execute_count then
    fail(("metadata fake call count mismatch for %s: expected %d got %d"):format(
      state.label or "cleanup",
      state.expected_metadata_execute_count,
      state.handler.metadata_execute_count
    ))
  end
  if state.client_id then
    stop_client(state.client_id)
  end
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
  end
  pcall(function()
    local lsp = require("dbee.lsp")
    if lsp.status().running then
      fail("LSP still running after cleanup")
    end
  end)
end

local function has_label(items, label)
  for _, item in ipairs(items or {}) do
    if item.label == label then
      return true
    end
  end
  return false
end

local function request_completion(state, line_text, character, context)
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, { line_text })
  local params = {
    textDocument = { uri = state.uri },
    position = { line = 0, character = character or #line_text },
  }
  if context then
    params.context = context
  end

  local done = false
  local response = nil
  local start_ns = uv.hrtime()
  state.client:request("textDocument/completion", params, function(err, result)
    response = {
      err = err,
      result = result,
      elapsed_ns = uv.hrtime() - start_ns,
    }
    done = true
  end, state.bufnr)

  local ok = vim.wait(1000, function()
    return done
  end, 5)
  if not ok or not response then
    error("completion timeout")
  end
  if response.err then
    error("completion error: " .. tostring(response.err))
  end
  if type(response.result) ~= "table" or type(response.result.items) ~= "table" then
    error("invalid completion response")
  end
  return response.result.items, response.elapsed_ns
end

local function completion_before(table_count, opts)
  opts = opts or {}
  local cache = make_cache(table_count, DEFAULT_COLUMNS_PER_TABLE, {
    preload_columns = opts.preload_columns,
  })
  local bufnr, uri = make_buffer({ "" })
  local client, client_id = start_lsp(cache, bufnr)
  return {
    cache = cache,
    bufnr = bufnr,
    uri = uri,
    client = client,
    client_id = client_id,
    table_count = table_count,
  }
end

local function completion_after(state)
  cleanup_lsp(state)
end

local function require_completion_labels(slug, items, required, forbidden)
  if #items == 0 then
    scenario_sentinels[slug] = false
    error(slug .. " returned empty completion list")
  end
  for _, label in ipairs(required or {}) do
    if not has_label(items, label) then
      scenario_sentinels[slug] = false
      error(slug .. " missing completion label " .. label)
    end
  end
  for _, label in ipairs(forbidden or {}) do
    if has_label(items, label) then
      scenario_sentinels[slug] = false
      error(slug .. " returned forbidden completion label " .. label)
    end
  end
end

local function cached_completion_run(state, finish, _, spec)
  local items, elapsed_ns = request_completion(state, spec.line, #spec.line, spec.context)
  require_completion_labels(spec.slug, items, spec.required, spec.forbidden)
  if spec.min_count and #items < spec.min_count then
    scenario_sentinels[spec.slug] = false
    error(("%s expected at least %d items, got %d"):format(spec.slug, spec.min_count, #items))
  end
  if spec.assert_no_column_fetch and state.cache.handler and (state.cache.handler.counters.connection_get_columns or 0) ~= 0 then
    scenario_sentinels[spec.slug] = false
    error(spec.slug .. " unexpectedly fetched columns")
  end
  finish(elapsed_ns)
end

local function register_cached_completion(slug, threshold_key, table_count, line, required, opts)
  opts = opts or {}
  register({
    slug = slug,
    threshold_key = threshold_key,
    corpus = opts.corpus or ("tables:" .. tostring(table_count) .. ",columns:10"),
    before = function()
      return completion_before(table_count, {
        preload_columns = opts.preload_columns,
      })
    end,
    run = function(state, finish, iteration)
      cached_completion_run(state, finish, iteration, {
        slug = slug,
        line = line,
        context = opts.context,
        required = required,
        forbidden = opts.forbidden,
        min_count = opts.min_count,
        assert_no_column_fetch = opts.assert_no_column_fetch,
      })
    end,
    after = completion_after,
  })
end

register_cached_completion(
  "COMPLETION_TABLE_100",
  "completion_table_100",
  100,
  "select * from T",
  { "TABLE_000001", "TABLE_000100" },
  {
    forbidden = { "TABLE_999999" },
    min_count = 100,
    corpus = "tables:100,context:table",
  }
)

register_cached_completion(
  "COMPLETION_TABLE_1000",
  "completion_table_1000",
  1000,
  "select * from T",
  { "TABLE_000001", "TABLE_001000" },
  {
    forbidden = { "TABLE_999999" },
    min_count = 1000,
    corpus = "tables:1000,context:table",
  }
)

register_cached_completion(
  "COMPLETION_TABLE_10000",
  "completion_table_10000",
  10000,
  "select * from T",
  { "TABLE_000001", "TABLE_010000" },
  {
    forbidden = { "TABLE_999999" },
    min_count = 10000,
    corpus = "tables:10000,context:table",
  }
)

register_cached_completion(
  "COMPLETION_SCHEMA",
  "completion_schema",
  100,
  "select * from S",
  { "SCHEMA_001" },
  {
    forbidden = { "_missing_schema" },
    corpus = "tables:100,context:schema-via-table",
  }
)

register_cached_completion(
  "COMPLETION_KEYWORD",
  "completion_keyword",
  100,
  "",
  { "SELECT", "FROM", "WHERE" },
  {
    corpus = "tables:100,context:keyword",
  }
)

register_cached_completion(
  "COMPLETION_COLUMN_HIT",
  "completion_column_hit",
  100,
  "SELECT * FROM SCHEMA_001.TABLE_000001 t WHERE t.",
  { "COL_001", "COL_010" },
  {
    preload_columns = true,
    forbidden = { "COL_999" },
    assert_no_column_fetch = true,
    corpus = "tables:100,context:column-hit,alias:t",
  }
)

local function reset_column_fetch_tracking(handler)
  handler.counters.connection_get_columns = 0
  handler.column_fetch_deltas = {}
end

local function register_column_miss_completion()
  local shared_cache = nil
  local shared_handler = nil
  local fetch_deltas = {}
  local expected_deltas = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
  local query = "SELECT * FROM SCHEMA_001.TABLE_000001 t WHERE t."

  local function ensure_shared_cache()
    if not shared_cache then
      shared_cache, shared_handler = make_cache(100, DEFAULT_COLUMNS_PER_TABLE, {
        preload_columns = false,
      })
      reset_column_fetch_tracking(shared_handler)
    end
  end

  local function make_miss_request_state()
    ensure_shared_cache()
    local bufnr, uri = make_buffer({ "" })
    local client, client_id = start_lsp(shared_cache, bufnr)
    return {
      cache = shared_cache,
      bufnr = bufnr,
      uri = uri,
      client = client,
      client_id = client_id,
    }
  end

  register({
    slug = "COMPLETION_COLUMN_MISS_SYNC",
    threshold_key = "completion_column_miss_sync",
    corpus = "tables:100,context:column-miss-sync,alias:t,fetch_deltas:1-then-0",
    after_warmup_before_measured = function()
      ensure_shared_cache()
      shared_cache.columns = {}
      reset_column_fetch_tracking(shared_handler)
      fetch_deltas = {}
    end,
    before = function()
      return make_miss_request_state()
    end,
    run = function(state, finish, iteration)
      local handler = state.cache.handler
      local before_count = handler.counters.connection_get_columns or 0
      local items, elapsed_ns = request_completion(state, query, #query)
      require_completion_labels("COMPLETION_COLUMN_MISS_SYNC", items, { "COL_001", "COL_010" }, { "COL_999" })
      if iteration > WARMUP_COUNT then
        local after_count = handler.counters.connection_get_columns or 0
        fetch_deltas[#fetch_deltas + 1] = after_count - before_count
      end
      finish(elapsed_ns)
    end,
    after = function(state, iteration)
      completion_after(state)
      if iteration == WARMUP_COUNT + MEASURED_COUNT then
        shared_cache = nil
        shared_handler = nil
      end
    end,
    on_complete = function()
      local delta_text = table.concat(vim.tbl_map(tostring, fetch_deltas), ",")
      local ok = #fetch_deltas == #expected_deltas
      for i, expected in ipairs(expected_deltas) do
        if fetch_deltas[i] ~= expected then
          ok = false
          break
        end
      end
      emit("LSP01_COLUMN_MISS_FETCH_DELTAS", delta_text)
      emit("LSP01_COLUMN_MISS_FETCH_DELTAS_OK", ok and "true" or "false")
      if not ok then
        scenario_sentinels.COMPLETION_COLUMN_MISS_SYNC = false
        fail("COMPLETION_COLUMN_MISS_SYNC fetch deltas mismatch: " .. delta_text)
      end
    end,
  })
end

register_column_miss_completion()

local function make_diagnostic_lines(line_count)
  local lines = {}
  for i = 1, line_count do
    lines[i] = "SELECT 1"
  end
  lines[1] = "FROM TABLE_000001"
  local invalid_index = math.max(2, math.floor(line_count / 2))
  lines[invalid_index] = "FROM MISSING_TABLE_001"
  return lines, invalid_index - 1
end

local function request_diagnostics(state, method, lines, expected_line)
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  local prior_handler = vim.lsp.handlers["textDocument/publishDiagnostics"]
  local done = false
  local response = nil
  local start_ns = uv.hrtime()
  vim.lsp.handlers["textDocument/publishDiagnostics"] = function(err, result, ctx, config)
    if result and result.uri == state.uri then
      response = {
        err = err,
        result = result,
        elapsed_ns = uv.hrtime() - start_ns,
      }
      done = true
    elseif prior_handler then
      prior_handler(err, result, ctx, config)
    end
  end

  local params = {
    textDocument = {
      uri = state.uri,
      version = state.iteration or 1,
    },
  }
  if method == "textDocument/didChange" then
    params.contentChanges = {
      { text = table.concat(lines, "\n") },
    }
  end

  state.client:notify(method, params)

  local ok = vim.wait(1000, function()
    return done
  end, 5)
  vim.lsp.handlers["textDocument/publishDiagnostics"] = prior_handler
  if not ok or not response then
    error("diagnostics timeout")
  end
  if response.err then
    error("diagnostics error: " .. tostring(response.err))
  end
  local diagnostics = response.result and response.result.diagnostics
  if type(diagnostics) ~= "table" then
    error("invalid diagnostics response")
  end

  local found_missing = false
  local found_valid = false
  local found_range = false
  for _, diagnostic in ipairs(diagnostics) do
    if diagnostic.message == "Unknown table: MISSING_TABLE_001" then
      found_missing = true
      local range = diagnostic.range or {}
      local start = range.start or {}
      local finish = range["end"] or {}
      if start.line == expected_line and start.character == 5
        and finish.line == expected_line and finish.character == 22 then
        found_range = true
      end
    end
    if diagnostic.message == "Unknown table: TABLE_000001" then
      found_valid = true
    end
  end

  if #diagnostics ~= 1 or not found_missing or not found_range or found_valid then
    error(("unexpected diagnostics: count=%d found_missing=%s found_range=%s found_valid=%s"):format(
      #diagnostics,
      tostring(found_missing),
      tostring(found_range),
      tostring(found_valid)
    ))
  end

  return diagnostics, response.elapsed_ns
end

local function register_diagnostics(slug, threshold_key, line_count, method)
  register({
    slug = slug,
    threshold_key = threshold_key,
    corpus = ("lines:%d,method:%s,invalid:MISSING_TABLE_001"):format(line_count, method:match("did(%w+)$") or method),
    before = function()
      return completion_before(100, {
        preload_columns = false,
      })
    end,
    run = function(state, finish)
      local lines, expected_line = make_diagnostic_lines(line_count)
      local _, elapsed_ns = request_diagnostics(state, method, lines, expected_line)
      finish(elapsed_ns)
    end,
    after = completion_after,
  })
end

register_diagnostics("DIAGNOSTICS_DIDCHANGE_100", "diagnostics_didchange_100", 100, "textDocument/didChange")
register_diagnostics("DIAGNOSTICS_DIDCHANGE_1000", "diagnostics_didchange_1000", 1000, "textDocument/didChange")
register_diagnostics("DIAGNOSTICS_DIDCHANGE_10000", "diagnostics_didchange_10000", 10000, "textDocument/didChange")
register_diagnostics("DIAGNOSTICS_DIDSAVE_100", "diagnostics_didsave_100", 100, "textDocument/didSave")
register_diagnostics("DIAGNOSTICS_DIDSAVE_1000", "diagnostics_didsave_1000", 1000, "textDocument/didSave")
register_diagnostics("DIAGNOSTICS_DIDSAVE_10000", "diagnostics_didsave_10000", 10000, "textDocument/didSave")

local function request_completion_lines(state, lines, line_index, character, context)
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  local params = {
    textDocument = { uri = state.uri },
    position = {
      line = line_index,
      character = character or #lines[line_index + 1],
    },
  }
  if context then
    params.context = context
  end

  local done = false
  local response = nil
  local start_ns = uv.hrtime()
  state.client:request("textDocument/completion", params, function(err, result)
    response = {
      err = err,
      result = result,
      elapsed_ns = uv.hrtime() - start_ns,
    }
    done = true
  end, state.bufnr)

  local ok = vim.wait(1000, function()
    return done
  end, 5)
  if not ok or not response then
    error("completion timeout")
  end
  if response.err then
    error("completion error: " .. tostring(response.err))
  end
  if type(response.result) ~= "table" or type(response.result.items) ~= "table" then
    error("invalid completion response")
  end
  return response.result.items, response.elapsed_ns
end

local function alias_nested_cte_lines()
  local lines = {
    "WITH c1 AS (",
    "  SELECT * FROM " .. schema_for_index(1) .. ".TABLE_000001 t1",
    "),",
    "c2 AS (",
    "  SELECT * FROM " .. schema_for_index(2) .. ".TABLE_000002 t2",
    "),",
    "c3 AS (",
    "  SELECT * FROM " .. schema_for_index(3) .. ".TABLE_000003 t3",
    ")",
  }
  while #lines < 39 do
    lines[#lines + 1] = "  -- deterministic filler"
  end
  lines[#lines + 1] = "SELECT * FROM " .. schema_for_index(3) .. ".TABLE_000003 t3 WHERE t3."
  return lines
end

local function alias_multiline_lines()
  local lines = {
    "SELECT",
    "  t1.COL_001,",
    "  t2.COL_001,",
    "  t3.COL_001,",
    "  t4.COL_001",
    "FROM",
    "  " .. schema_for_index(1) .. ".TABLE_000001 t1",
    "JOIN",
    "  " .. schema_for_index(2) .. ".TABLE_000002 t2",
    "ON t2.COL_001 = t1.COL_001",
    "JOIN",
    "  " .. schema_for_index(3) .. ".TABLE_000003 t3",
    "ON t3.COL_001 = t2.COL_001",
    "JOIN",
    "  " .. schema_for_index(4) .. ".TABLE_000004 t4",
    "ON t4.COL_001 = t3.COL_001",
  }
  while #lines < 24 do
    lines[#lines + 1] = "  -- deterministic filler"
  end
  lines[#lines + 1] = "WHERE t4."
  return lines
end

local function register_alias_completion(slug, threshold_key, lines_factory, expected_line, corpus)
  register({
    slug = slug,
    threshold_key = threshold_key,
    corpus = corpus,
    before = function()
      return completion_before(100, {
        preload_columns = true,
      })
    end,
    run = function(state, finish)
      local lines = lines_factory()
      local line_index = expected_line or (#lines - 1)
      local items, elapsed_ns = request_completion_lines(state, lines, line_index, #lines[line_index + 1])
      require_completion_labels(slug, items, { "COL_001", "COL_010" }, { "COL_999" })
      finish(elapsed_ns)
    end,
    after = completion_after,
  })
end

register_alias_completion(
  "ALIAS_SIMPLE_SELECT",
  "alias_simple_select",
  function()
    return { "SELECT * FROM SCHEMA_001.TABLE_000001 t WHERE t." }
  end,
  0,
  "lines:1,aliases:1,cursor:t_dot"
)

register_alias_completion(
  "ALIAS_NESTED_CTE",
  "alias_nested_cte",
  alias_nested_cte_lines,
  nil,
  "lines:40,cte_depth:3,aliases:3,cursor:t3_dot"
)

register_alias_completion(
  "ALIAS_MULTILINE",
  "alias_multiline",
  alias_multiline_lines,
  nil,
  "lines:25,joins:3,aliases:4,cursor:t4_dot"
)

register_alias_completion(
  "ALIAS_MULTI_JOIN",
  "alias_multi_join",
  function()
    return {
      table.concat({
        "SELECT * FROM " .. schema_for_index(1) .. ".TABLE_000001 t1",
        "JOIN " .. schema_for_index(2) .. ".TABLE_000002 t2 ON t2.COL_001 = t1.COL_001",
        "JOIN " .. schema_for_index(3) .. ".TABLE_000003 t3 ON t3.COL_001 = t2.COL_001",
        "JOIN " .. schema_for_index(4) .. ".TABLE_000004 t4 ON t4.COL_001 = t3.COL_001",
        "JOIN " .. schema_for_index(5) .. ".TABLE_000005 t5 ON t5.COL_001 = t4.COL_001",
        "WHERE t5.",
      }, " "),
    }
  end,
  0,
  "lines:1,joins:5,aliases:5,cursor:t5_dot"
)

local function clear_lsp_cache_dir()
  vim.fn.delete(vim.fn.stdpath("state") .. "/dbee/lsp_cache", "rf")
end

local function new_empty_cache(table_count, conn_id)
  local SchemaCache = require("dbee.lsp.schema_cache")
  local handler = make_handler({
    table_count = table_count,
    columns_per_table = DEFAULT_COLUMNS_PER_TABLE,
    conn_id = conn_id,
  })
  return SchemaCache:new(handler, conn_id), handler
end

local function count_cached_tables(cache)
  return #cache:get_all_table_names()
end

local function cache_index_path(conn_id)
  return vim.fn.stdpath("state") .. "/dbee/lsp_cache/" .. conn_id .. ".json"
end

local function assert_cache_file(conn_id)
  local path = cache_index_path(conn_id)
  local stat = uv.fs_stat(path)
  if not stat or stat.size <= 0 then
    error("cache file missing or empty: " .. path)
  end
end

local function register_cache_build(slug, threshold_key, table_count)
  register({
    slug = slug,
    threshold_key = threshold_key,
    corpus = ("tables:%d,cache:build_from_structure"):format(table_count),
    before = function()
      assert_isolated_state()
      clear_lsp_cache_dir()
      local conn_id = "lsp01-build-" .. tostring(table_count)
      local cache = new_empty_cache(table_count, conn_id)
      return {
        cache = cache,
        structure = make_structure(table_count, DEFAULT_COLUMNS_PER_TABLE),
        table_count = table_count,
      }
    end,
    run = function(state, finish)
      local start_ns = uv.hrtime()
      state.cache:build_from_structure(state.structure)
      local elapsed_ns = uv.hrtime() - start_ns
      if count_cached_tables(state.cache) ~= state.table_count then
        error(("cache build expected %d tables, got %d"):format(state.table_count, count_cached_tables(state.cache)))
      end
      finish(elapsed_ns)
    end,
  })
end

local function register_cache_load(slug, threshold_key, table_count)
  register({
    slug = slug,
    threshold_key = threshold_key,
    corpus = ("tables:%d,cache:load_from_disk"):format(table_count),
    before = function()
      assert_isolated_state()
      clear_lsp_cache_dir()
      local conn_id = "lsp01-load-" .. tostring(table_count)
      local seed_cache = make_cache(table_count, DEFAULT_COLUMNS_PER_TABLE, {
        conn_id = conn_id,
      })
      seed_cache:save_to_disk()
      assert_cache_file(conn_id)
      local cache = new_empty_cache(table_count, conn_id)
      return {
        cache = cache,
        conn_id = conn_id,
        table_count = table_count,
      }
    end,
    run = function(state, finish)
      local start_ns = uv.hrtime()
      local loaded = state.cache:load_from_disk()
      local elapsed_ns = uv.hrtime() - start_ns
      if not loaded then
        error("cache load returned false")
      end
      if count_cached_tables(state.cache) ~= state.table_count then
        error(("cache load expected %d tables, got %d"):format(state.table_count, count_cached_tables(state.cache)))
      end
      finish(elapsed_ns)
    end,
  })
end

local function register_cache_save(slug, threshold_key, table_count)
  register({
    slug = slug,
    threshold_key = threshold_key,
    corpus = ("tables:%d,cache:save_to_disk"):format(table_count),
    before = function()
      assert_isolated_state()
      clear_lsp_cache_dir()
      local conn_id = "lsp01-save-" .. tostring(table_count)
      local cache = make_cache(table_count, DEFAULT_COLUMNS_PER_TABLE, {
        conn_id = conn_id,
      })
      return {
        cache = cache,
        conn_id = conn_id,
        table_count = table_count,
      }
    end,
    run = function(state, finish)
      local start_ns = uv.hrtime()
      state.cache:save_to_disk()
      local elapsed_ns = uv.hrtime() - start_ns
      assert_cache_file(state.conn_id)
      if count_cached_tables(state.cache) ~= state.table_count then
        error(("cache save expected %d tables, got %d"):format(state.table_count, count_cached_tables(state.cache)))
      end
      finish(elapsed_ns)
    end,
  })
end

register_cache_build("CACHE_BUILD_100", "cache_build_100", 100)
register_cache_build("CACHE_BUILD_1000", "cache_build_1000", 1000)
register_cache_build("CACHE_BUILD_10000", "cache_build_10000", 10000)
register_cache_load("CACHE_LOAD_100", "cache_load_100", 100)
register_cache_load("CACHE_LOAD_1000", "cache_load_1000", 1000)
register_cache_load("CACHE_LOAD_10000", "cache_load_10000", 10000)
register_cache_save("CACHE_SAVE_100", "cache_save_100", 100)
register_cache_save("CACHE_SAVE_1000", "cache_save_1000", 1000)
register_cache_save("CACHE_SAVE_10000", "cache_save_10000", 10000)

local function run_benchmark(spec)
  local iteration = 0
  local state = nil
  local samples = {}
  local complete = false

  benchmark.run({
    title = spec.slug,
    warm_up = WARMUP_COUNT,
    iterations = MEASURED_COUNT,
    before = function()
      iteration = iteration + 1
      if iteration == WARMUP_COUNT + 1 and spec.after_warmup_before_measured then
        spec.after_warmup_before_measured()
      end
      state = spec.before and spec.before(iteration) or {}
      state.iteration = iteration
    end,
    after = function()
      if spec.after then
        spec.after(state, iteration)
      elseif state and state.cleanup then
        state.cleanup()
      end
      state = nil
    end,
  }, function(done)
    local finished = false
    local function finish(sample_ns)
      if finished then
        return
      end
      finished = true
      if iteration > WARMUP_COUNT then
        samples[#samples + 1] = sample_ns
      end
      done()
    end

    local ok, err = xpcall(function()
      spec.run(state, finish, iteration)
    end, debug.traceback)
    if not ok then
      scenario_sentinels[spec.slug] = false
      fail(err)
    end
  end, function()
    complete = true
  end)

  local timed_out = not vim.wait(SCENARIO_TIMEOUT_MS, function()
    return complete
  end, 5)
  if timed_out then
    scenario_sentinels[spec.slug] = false
    fail("benchmark timeout: " .. spec.slug)
  end

  return samples
end

local function marker_threshold_prefix(platform_name)
  if platform_name == "linux" then
    return "LSP01_LINUX_PERF_THRESHOLD_"
  end
  return "LSP01_MACOS_PERF_THRESHOLD_"
end

local function resolve_threshold(platform_name, spec, measurement)
  local platform_thresholds = thresholds[platform_name] or {}
  local slot = deepcopy(platform_thresholds[spec.threshold_key] or {})
  local frozen = platform_thresholds.frozen == true
  local is_frozen_slot = frozen and slot.median_ms ~= nil and slot.p95_ms ~= nil
  local active = platform_name == platform
  local candidate_median_ms = (active and publishable) and measurement.median_ms or nil
  local candidate_p95_ms = (active and publishable) and measurement.p95_ms or nil
  local status = is_frozen_slot and "frozen"
    or ((candidate_median_ms ~= nil or candidate_p95_ms ~= nil or slot.median_ms ~= nil or slot.p95_ms ~= nil) and "candidate" or "missing")

  if gate_mode == "blocking" and active and not is_frozen_slot then
    fail(("blocking threshold missing for %s:%s"):format(platform_name, spec.threshold_key))
  end

  return {
    median_ms = slot.median_ms,
    p95_ms = slot.p95_ms,
    candidate_median_ms = candidate_median_ms,
    candidate_p95_ms = candidate_p95_ms,
    status = status,
  }
end

local function scenario_threshold_pass(threshold, measurement, sentinel_ok)
  if not sentinel_ok then
    return "false"
  end
  if threshold.status ~= "frozen" then
    return "unfrozen"
  end
  return (measurement.median_ms <= threshold.median_ms and measurement.p95_ms <= threshold.p95_ms) and "true" or "false"
end

local platform_rollups = {}

local function emit_thresholds(spec, measurement, sentinel_ok)
  for _, platform_name in ipairs({ "linux", "macos" }) do
    local threshold = resolve_threshold(platform_name, spec, measurement)
    local active = platform_name == platform
    local pass = active and scenario_threshold_pass(threshold, measurement, sentinel_ok) or "unfrozen"
    local prefix = marker_threshold_prefix(platform_name) .. spec.slug
    emit(prefix .. "_MEDIAN_MS", marker_value(threshold.median_ms))
    emit(prefix .. "_P95_MS", marker_value(threshold.p95_ms))
    emit(prefix .. "_MEDIAN_CANDIDATE_MS", marker_value(threshold.candidate_median_ms))
    emit(prefix .. "_P95_CANDIDATE_MS", marker_value(threshold.candidate_p95_ms))
    emit(prefix .. "_STATUS", threshold.status)
    emit(prefix .. "_PASS", pass)

    if active then
      if pass == "false" then
        platform_rollups[platform_name] = "false"
      elseif pass == "unfrozen" and platform_rollups[platform_name] ~= "false" then
        platform_rollups[platform_name] = "unfrozen"
      elseif pass == "true" and platform_rollups[platform_name] == nil then
        platform_rollups[platform_name] = "true"
      end
    end
  end
end

local function run_scenario(spec)
  local samples = run_benchmark(spec)
  if spec.on_complete then
    spec.on_complete()
  end
  if #samples ~= MEASURED_COUNT then
    scenario_sentinels[spec.slug] = false
    fail(("scenario %s expected %d measured samples, got %d"):format(spec.slug, MEASURED_COUNT, #samples))
  end
  local measurement = {
    median_ns = median(samples),
    p95_ns = percentile(samples, 0.95),
  }
  measurement.median_ms = ns_to_ms(measurement.median_ns)
  measurement.p95_ms = ns_to_ms(measurement.p95_ns)
  local sentinel_ok = scenario_sentinels[spec.slug] ~= false
  scenario_sentinels[spec.slug] = sentinel_ok
  scenario_results[spec.slug] = measurement
  emit("LSP01_" .. spec.slug .. "_MEDIAN_MS", format_float(measurement.median_ms))
  emit("LSP01_" .. spec.slug .. "_P95_MS", format_float(measurement.p95_ms))
  emit("LSP01_" .. spec.slug .. "_SENTINEL_OK", sentinel_ok and "true" or "false")
  emit("LSP01_CORPUS_" .. spec.slug, spec.corpus or "unspecified")
  emit_thresholds(spec, measurement, sentinel_ok)
  summary_rows[#summary_rows + 1] = string.format(
    "%s median_ms=%s p95_ms=%s sentinel=%s corpus=%s",
    spec.slug,
    format_float(measurement.median_ms),
    format_float(measurement.p95_ms),
    sentinel_ok and "true" or "false",
    spec.corpus or "unspecified"
  )
end

local function write_summary(real_lsp_perf_all_pass)
  local lines = {
    "LSP01 Phase 10 real-LSP perf summary",
    "platform=" .. platform,
    "actual_os=" .. actual_os,
    "platform_authentic=" .. tostring(platform_authentic),
    "publishable=" .. tostring(publishable),
    "gate_mode=" .. gate_mode,
    "nvim_version=" .. nvim_version_string,
    "warmup_count=" .. tostring(WARMUP_COUNT),
    "measured_count=" .. tostring(MEASURED_COUNT),
    "threshold_file=" .. threshold_path,
    "summary_artifact=" .. summary_path,
    "flame_trace_artifact=" .. trace_path,
    "real_lsp_perf_all_pass=" .. real_lsp_perf_all_pass,
    "",
    "scenario_summary:",
  }
  vim.list_extend(lines, summary_rows)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "markers:"
  vim.list_extend(lines, emitted_markers)
  write_lines(summary_path, lines)
end

local function run_flame_trace_subprocess()
  pcall(vim.fn.delete, trace_path)
  local env = vim.fn.environ()
  env.LSP01_PERF_GATE_MODE = gate_mode
  env.PERF_PLATFORM = platform
  env.LSP01_PERF_ARTIFACT_DIR = artifact_dir
  env.LSP01_PERF_SUMMARY_PATH = summary_path
  env.LSP01_PERF_TRACE_PATH = trace_path
  env.LSP01_PERF_THRESHOLD_FILE = threshold_path
  env.LSP01_PERF_TRACE_ONLY = "1"
  env.XDG_STATE_HOME = vim.env.XDG_STATE_HOME

  local result = vim.system({
    vim.v.progpath,
    "--headless",
    "-u",
    "NONE",
    "-i",
    "NONE",
    "-n",
    "--cmd",
    "set runtimepath=" .. vim.o.runtimepath,
    "-c",
    "luafile " .. vim.fn.fnameescape(current_script_path()),
  }, {
    cwd = vim.fn.getcwd(),
    env = env,
    text = true,
  }):wait()

  if result.code ~= 0 then
    fail(("flame trace subprocess failed (%s): %s %s"):format(
      tostring(result.code),
      tostring(result.stdout or ""),
      tostring(result.stderr or "")
    ))
  end
  if not uv.fs_stat(trace_path) then
    fail("flame trace artifact missing: " .. trace_path)
  end
end

local function run_trace_only_mode()
  local real_install_plugin = benchmark.install_plugin
  benchmark.install_plugin = function(path)
    if path == "stevearc/profile.nvim" then
      return
    end
    return real_install_plugin(path)
  end
  local flame_profile_start, flame_profile_stop = benchmark.flame_profile({
    pattern = "*",
    filename = trace_path,
  })
  benchmark.install_plugin = real_install_plugin

  local complete = false
  flame_profile_start()
  local start = uv.hrtime()
  while ns_to_ms(uv.hrtime() - start) < 1 do
    -- keep a tiny deterministic trace body
  end
  flame_profile_stop(function()
    complete = true
  end)
  local wrote_trace = vim.wait(5000, function()
    return complete and uv.fs_stat(trace_path) ~= nil
  end, 10)
  if not wrote_trace then
    fail("flame trace timeout: " .. trace_path)
  end
  vim.cmd("qa!")
end

local function seed_warm_disk_cache(handler)
  clear_lsp_cache_dir()
  local cache = make_cache(100, DEFAULT_COLUMNS_PER_TABLE, {
    handler = handler,
    conn_id = DEFAULT_CONN_ID,
  })
  cache:save_to_disk()
  local key = schema_for_index(1) .. "." .. table_for_index(1)
  local cols = make_columns(schema_for_index(1), table_for_index(1), DEFAULT_COLUMNS_PER_TABLE)
  cache.columns[key] = cols
  cache:_save_columns_to_disk(key, cols)
end

local function startup_before(kind)
  assert_isolated_state()
  local connection_type = kind == "metadata" and CONNECTION_TYPE_METADATA or CONNECTION_TYPE_NO_METADATA
  local handler = make_handler({
    table_count = 100,
    columns_per_table = DEFAULT_COLUMNS_PER_TABLE,
    connection_type = connection_type,
    auto_structure = kind ~= "metadata",
  })
  if kind == "warm" then
    seed_warm_disk_cache(handler)
  else
    clear_lsp_cache_dir()
  end
  local bufnr = make_buffer({ "select * from " .. table_for_index(1) })
  capture_defer_fn()
  return {
    label = kind,
    handler = handler,
    bufnr = bufnr,
    connection_type = connection_type,
  }
end

local function startup_after(state)
  local expected_metadata_count = state.label == "metadata" and 1 or 0
  if state.handler.metadata_execute_count ~= expected_metadata_count then
    fail(("metadata fake call count mismatch for %s: expected %d got %d"):format(
      state.label,
      expected_metadata_count,
      state.handler.metadata_execute_count
    ))
  end
  restore_defer_fn()
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
  end
end

local function startup_run(state, finish, _, slug)
  local start_ns = uv.hrtime()
  with_fake_lsp_state(state.handler, function()
    local lsp
    if state.label == "metadata" then
      lsp = queue_try_start(state.bufnr, state.handler, { label = slug })
      wait_metadata_fallback(lsp, state.handler, {
        label = slug,
        conn_id = DEFAULT_CONN_ID,
      })
      local count = 1
      emit("LSP01_METADATA_FALLBACK_DEFERRED_CALLBACK_COUNT", count)
      if state.handler.metadata_execute_count ~= 1 then
        scenario_sentinels[slug] = false
      end
      emit("LSP01_METADATA_FALLBACK_FAKE_CALL_COUNT", state.handler.metadata_execute_count)
    else
      lsp = start_lsp_via_lifecycle(state.bufnr, state.handler, { label = slug })
      local count = drain_deferred(0, slug)
      if slug == "STARTUP_COLD" then
        emit("LSP01_COLD_DISK_DEFERRED_CALLBACK_COUNT", count)
        if state.connection_type ~= CONNECTION_TYPE_NO_METADATA then
          scenario_sentinels[slug] = false
        end
      else
        emit("LSP01_WARM_DISK_DEFERRED_CALLBACK_COUNT", count)
      end
      if state.handler.metadata_execute_count ~= 0 then
        scenario_sentinels[slug] = false
      end
    end

    local lifecycle_ok = state.handler:assert_lifecycle_methods_complete(slug)
    if not lifecycle_ok then
      scenario_sentinels[slug] = false
    end
    local status = lsp.status()
    if status.running ~= true or not status.client_id then
      scenario_sentinels[slug] = false
    end
  end)
  finish(uv.hrtime() - start_ns)
end

register({
  slug = "STARTUP_COLD",
  threshold_key = "startup_cold",
  corpus = "conn_type:dbee-perf-no-metadata,tables:100,columns:10,state:fresh",
  before = function()
    return startup_before("cold")
  end,
  run = function(state, finish, iteration)
    startup_run(state, finish, iteration, "STARTUP_COLD")
  end,
  after = startup_after,
})

register({
  slug = "STARTUP_WARM",
  threshold_key = "startup_warm",
  corpus = "conn_type:dbee-perf-no-metadata,tables:100,columns:10,state:warm-disk",
  before = function()
    return startup_before("warm")
  end,
  run = function(state, finish, iteration)
    startup_run(state, finish, iteration, "STARTUP_WARM")
  end,
  after = startup_after,
})

register({
  slug = "STARTUP_METADATA_FALLBACK",
  threshold_key = "startup_metadata_fallback",
  corpus = "conn_type:postgres,tables:100,columns:10,state:metadata-fallback",
  before = function()
    return startup_before("metadata")
  end,
  run = function(state, finish, iteration)
    startup_run(state, finish, iteration, "STARTUP_METADATA_FALLBACK")
  end,
  after = startup_after,
})

if trace_only then
  run_trace_only_mode()
  return
end

if #SCENARIOS == 0 then
  fail("no LSP01 scenarios registered")
end

emit("LSP01_SCENARIOS_COUNT", #SCENARIOS)

for _, spec in ipairs(SCENARIOS) do
  run_scenario(spec)
end

run_flame_trace_subprocess()

local true_sentinels = 0
local false_sentinels = 0
for _, spec in ipairs(SCENARIOS) do
  if scenario_sentinels[spec.slug] == true then
    true_sentinels = true_sentinels + 1
  else
    false_sentinels = false_sentinels + 1
  end
end

local active_rollup = platform_rollups[platform]
if active_rollup ~= "false" and active_rollup ~= "true" then
  active_rollup = "unfrozen"
end
local real_lsp_perf_all_pass = "false"
if true_sentinels == #SCENARIOS and false_sentinels == 0 and platform_authentic and publishable then
  real_lsp_perf_all_pass = active_rollup == "true" and "true" or (active_rollup == "unfrozen" and "unfrozen" or "false")
end

emit("LSP01_LINUX_PERF_THRESHOLD_PASS", platform == "linux" and active_rollup or "unfrozen")
emit("LSP01_MACOS_PERF_THRESHOLD_PASS", platform == "macos" and active_rollup or "unfrozen")
emit("LSP01_REAL_LSP_PERF_ALL_PASS", real_lsp_perf_all_pass)

write_summary(real_lsp_perf_all_pass)

if true_sentinels ~= #SCENARIOS or false_sentinels > 0 then
  fail("LSP01 sentinel failure")
end
if real_lsp_perf_all_pass == "false" then
  fail("LSP01_REAL_LSP_PERF_ALL_PASS=false")
end

vim.cmd("qa!")
