-- Headless release-grade perf harness for Phase 9 DRAW-01 real-nui evidence.
--
-- Usage:
--   make perf
--   DRAW01_PERF_GATE_MODE=advisory make perf PERF_PLATFORM=macos
--   DRAW01_PERF_GATE_MODE=advisory make perf PERF_PLATFORM=linux

local unpack = table.unpack or unpack
local uv = vim.uv or vim.loop

local function fail(msg)
  print("DRAW01_FAIL=" .. tostring(msg))
  vim.cmd("cquit 1")
end

local function assert_true(label, value)
  if not value then
    fail(label .. ": expected truthy, got " .. vim.inspect(value))
  end
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

local function maximum(values)
  local max_value = 0
  for _, value in ipairs(values) do
    max_value = math.max(max_value, value)
  end
  return max_value
end

local function ns_to_ms(value)
  return value / 1e6
end

local function format_float(value)
  return string.format("%.2f", value)
end

local function emit(label, value)
  print(label .. "=" .. tostring(value))
end

local function emit_ms(label, value_ns)
  emit(label, format_float(ns_to_ms(value_ns)))
end

local function with_window(width, height)
  local host_buf = vim.api.nvim_create_buf(false, true)
  local winid = vim.api.nvim_open_win(host_buf, true, {
    relative = "editor",
    width = width or 180,
    height = height or 60,
    row = 1,
    col = 1,
    style = "minimal",
    border = "single",
  })
  return host_buf, winid
end

local function close_window_and_buffer(bufnr, winid)
  if winid and vim.api.nvim_win_is_valid(winid) then
    pcall(vim.api.nvim_win_close, winid, true)
  end
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

local benchmark_ok, benchmark = pcall(require, "benchmark")
if not benchmark_ok then
  fail("benchmark.nvim missing from runtimepath")
end

local benchmark_ui_ok, benchmark_ui = pcall(require, "benchmark.ui")
if benchmark_ui_ok and benchmark_ui then
  benchmark_ui.show_message = function() end
end

if not pcall(require, "nui.tree") then
  fail("nui.nvim missing from runtimepath")
end

local DrawerUI = require("dbee.ui.drawer")
local convert = require("dbee.ui.drawer.convert")
local drawer_model = require("dbee.ui.drawer.model")

local threshold_path = vim.env.DRAW01_PERF_THRESHOLD_FILE or "ci/headless/perf_thresholds.lua"
if not uv.fs_stat(threshold_path) then
  fail("missing threshold file: " .. threshold_path)
end

local thresholds_ok, thresholds = pcall(require, "ci.headless.perf_thresholds")
if not thresholds_ok then
  fail("failed to load threshold file: " .. tostring(thresholds))
end

local gate_mode = vim.env.DRAW01_PERF_GATE_MODE or "advisory"
if gate_mode ~= "advisory" and gate_mode ~= "blocking" then
  fail("unsupported DRAW01_PERF_GATE_MODE=" .. tostring(gate_mode))
end

local platform = vim.env.PERF_PLATFORM
if platform ~= "linux" and platform ~= "macos" then
  local sysname = (uv.os_uname() or {}).sysname or ""
  platform = sysname == "Darwin" and "macos" or "linux"
end

if type(thresholds[platform]) ~= "table" then
  fail("threshold table missing active platform entry: " .. platform)
end

if gate_mode == "blocking" and thresholds[platform].frozen ~= true then
  fail("blocking thresholds are not frozen for " .. platform)
end

local artifact_dir = vim.env.DRAW01_PERF_ARTIFACT_DIR or ("/tmp/nvim-dbee-draw01-perf/" .. platform)
local summary_path = vim.env.DRAW01_PERF_SUMMARY_PATH or (artifact_dir .. "/draw01-summary.txt")
local trace_path = vim.env.DRAW01_PERF_TRACE_PATH or (artifact_dir .. "/draw01-trace.json")

vim.fn.mkdir(artifact_dir, "p")

local nvim_version = vim.version()
local nvim_version_string = string.format("%d.%d.%d", nvim_version.major, nvim_version.minor, nvim_version.patch)

emit("DRAW01_PERF_MODE", "real-nui")
emit("DRAW01_PERF_GATE_MODE", gate_mode)
emit("DRAW01_PLATFORM", platform)
emit("DRAW01_NVIM_VERSION", nvim_version_string)
emit("DRAW01_THRESHOLD_FILE", threshold_path)
emit("DRAW01_SUMMARY_ARTIFACT", summary_path)
emit("DRAW01_FLAME_TRACE_ARTIFACT", trace_path)

local WARMUP_COUNT = 5
local MEASURED_COUNT = 10

local active_buffer_watch = nil
local real_set_lines = vim.api.nvim_buf_set_lines

vim.api.nvim_buf_set_lines = function(bufnr, start, stop, strict_indexing, replacement)
  local result = { real_set_lines(bufnr, start, stop, strict_indexing, replacement) }
  local watch = active_buffer_watch
  if watch and bufnr == watch.bufnr then
    local now = uv.hrtime()
    watch.first_ns = watch.first_ns or now
    watch.last_ns = now
  end
  return unpack(result)
end

local function visible_row(tree, target_id)
  local line_count = vim.api.nvim_buf_line_count(tree.bufnr)
  for row = 1, line_count do
    local node = tree:get_node(row)
    if node and node:get_id() == target_id then
      return row
    end
  end
end

local function set_current_node(winid, tree, node_id)
  local row = visible_row(tree, node_id)
  assert_true("visible row for " .. node_id, row ~= nil)
  vim.api.nvim_win_set_cursor(winid, { row, 0 })
end

local LOCKED_QUERY_COHORT = {
  max_hit_query = "_",
  broad_query = "ledger_",
  secondary_broad_query = "acct_",
  narrow_query = "table_003_042",
  miss_query = "zzzzzz",
}

local function corpus_table_name(index)
  if index <= 400 then
    return string.format("acct_%04d", index)
  end
  if index <= 999 then
    return string.format("ledger_%04d", index - 400)
  end
  return "table_003_042"
end

local function build_locked_corpus()
  local root_cache = {}
  local source_connections = {
    source1 = {
      { id = "conn-ready", name = "Ready Connection", type = "postgres" },
      { id = "conn-alt", name = "Alt Connection", type = "postgres" },
    },
  }
  local ids = {
    connection_ids = { "conn-ready", "conn-alt" },
    schemas_by_conn = {},
    tables_by_conn = {},
  }

  local ordinal = 0
  for conn_index, conn_id in ipairs(ids.connection_ids) do
    local structures = {}
    ids.schemas_by_conn[conn_id] = {}
    ids.tables_by_conn[conn_id] = {}

    for schema_index = 1, 5 do
      local schema_name = string.format("schema_%d_%d", conn_index, schema_index)
      local schema_struct = {
        type = "schema",
        name = schema_name,
        schema = schema_name,
        children = {},
      }

      local schema_id = convert.structure_node_id(conn_id, {
        type = "schema",
        name = schema_name,
        schema = schema_name,
      })

      ids.schemas_by_conn[conn_id][#ids.schemas_by_conn[conn_id] + 1] = {
        id = schema_id,
        name = schema_name,
      }

      for _ = 1, 100 do
        ordinal = ordinal + 1
        local table_name = corpus_table_name(ordinal)
        local table_id = convert.structure_node_id(schema_id, {
          type = "table",
          name = table_name,
          schema = schema_name,
        })

        schema_struct.children[#schema_struct.children + 1] = {
          type = "table",
          name = table_name,
          schema = schema_name,
        }

        ids.tables_by_conn[conn_id][#ids.tables_by_conn[conn_id] + 1] = {
          id = table_id,
          name = table_name,
          schema = schema_name,
        }
      end

      structures[#structures + 1] = schema_struct
    end

    root_cache[conn_id] = { structures = structures }
  end

  ids.empty_tables = {
    ["conn-ready|" .. ids.tables_by_conn["conn-ready"][10].schema .. "|" .. ids.tables_by_conn["conn-ready"][10].name] = true,
    ["conn-alt|" .. ids.tables_by_conn["conn-alt"][10].schema .. "|" .. ids.tables_by_conn["conn-alt"][10].name] = true,
  }

  return {
    root_cache = root_cache,
    source_connections = source_connections,
    ids = ids,
  }
end

local LOCKED_CORPUS = build_locked_corpus()

local function locked_corpus_columns(conn_id, table_opts)
  local key = table.concat({
    conn_id,
    tostring(table_opts and table_opts.schema or ""),
    tostring(table_opts and table_opts.table or ""),
  }, "|")
  if LOCKED_CORPUS.ids.empty_tables[key] then
    return {}
  end
  return {
    { name = "id", type = "NUMBER" },
    { name = "name", type = "TEXT" },
  }
end

local DEFAULT_MAPPINGS = {
  { key = "<CR>", mode = "n", action = "action_1" },
  { key = "e", mode = "n", action = "expand" },
  { key = "c", mode = "n", action = "collapse" },
  { key = "o", mode = "n", action = "toggle" },
  { key = "/", mode = "n", action = "filter" },
}

local function new_drawer_fixture(opts)
  opts = opts or {}
  local listeners = {}
  local sources = opts.sources or {
    {
      name = function()
        return "source1"
      end,
      create = function() end,
      update = function() end,
      delete = function() end,
      file = function()
        return "source1.json"
      end,
    },
  }

  local source_connections = deepcopy(opts.source_connections or LOCKED_CORPUS.source_connections)
  local get_columns = opts.get_columns or locked_corpus_columns

  local handler = {
    register_event_listener = function(_, event, cb)
      listeners[event] = cb
    end,
    get_current_connection = function()
      return source_connections.source1[1]
    end,
    get_sources = function()
      return sources
    end,
    source_get_connections = function(_, source_id)
      return source_connections[source_id] or {}
    end,
    connection_get_columns = function(_, conn_id, table_opts)
      return deepcopy(get_columns(conn_id, table_opts or {}))
    end,
    connection_get_columns_async = function(_, conn_id, request_id, branch_id, root_epoch, table_opts)
      local payload = {
        conn_id = conn_id,
        request_id = request_id,
        branch_id = branch_id,
        root_epoch = root_epoch,
        kind = table_opts and table_opts.kind or "columns",
        columns = deepcopy(get_columns(conn_id, table_opts or {})),
      }
      vim.schedule(function()
        if listeners.structure_children_loaded then
          listeners.structure_children_loaded(payload)
        end
      end)
    end,
    connection_list_databases = function()
      return "", {}
    end,
    connection_get_helpers = function()
      return {}
    end,
    connection_execute = function()
      return { id = "call-1", state = "archived" }
    end,
    connection_get_params = function(_, conn_id)
      for _, conn in ipairs(source_connections.source1) do
        if conn.id == conn_id then
          return {
            id = conn.id,
            name = conn.name,
            type = conn.type,
            url = "postgres://example/" .. conn.id,
          }
        end
      end
      return nil
    end,
    set_current_connection = function() end,
    source_add_connection = function() end,
    source_update_connection = function() end,
    source_remove_connection = function() end,
    source_reload = function() end,
  }

  local editor = {
    register_event_listener = function() end,
    get_current_note = function()
      return nil
    end,
    namespace_get_notes = function()
      return {}
    end,
    search_note = function()
      return nil
    end,
    set_current_note = function() end,
    namespace_create_note = function()
      return "note-1"
    end,
  }

  local result = {
    set_call = function() end,
  }

  local drawer = DrawerUI:new(handler, editor, result, {
    mappings = deepcopy(opts.mappings or DEFAULT_MAPPINGS),
    disable_help = opts.disable_help ~= false,
  })

  drawer._struct_cache.root = deepcopy(opts.root_cache or LOCKED_CORPUS.root_cache)
  drawer._struct_cache.root_gen = {}
  drawer._struct_cache.root_applied = {}
  drawer._struct_cache.root_epoch = {}
  drawer._struct_cache.loaded_lazy_ids = deepcopy(opts.loaded_lazy_ids or {})
  drawer._struct_cache.branches = deepcopy(opts.branches or {})

  local host_buf, winid = with_window()
  if opts.show_immediately ~= false then
    drawer:show(winid)
  end

  local function cleanup()
    if drawer and drawer.bufnr and vim.api.nvim_buf_is_valid(drawer.bufnr) then
      pcall(drawer.prepare_close, drawer)
      pcall(vim.api.nvim_buf_delete, drawer.bufnr, { force = true })
    end
    close_window_and_buffer(host_buf, winid)
  end

  return {
    drawer = drawer,
    winid = winid,
    host_buf = host_buf,
    handler = handler,
    listeners = listeners,
    source_connections = source_connections,
    cleanup = cleanup,
  }
end

local function run_benchmark(spec)
  local iteration = 0
  local state = nil
  local samples = {}
  local extra_metrics = {}
  local complete = false

  benchmark.run({
    title = spec.title,
    warm_up = WARMUP_COUNT,
    iterations = MEASURED_COUNT,
    before = function()
      iteration = iteration + 1
      state = spec.before and spec.before() or {}
    end,
    after = function()
      if spec.after then
        spec.after(state)
      elseif state and state.cleanup then
        state.cleanup()
      end
      state = nil
      active_buffer_watch = nil
    end,
  }, function(done)
    local finished = false
    local function finish(sample_ns, extras)
      if finished then
        return
      end
      finished = true
      if iteration > WARMUP_COUNT then
        samples[#samples + 1] = sample_ns
        for key, value in pairs(extras or {}) do
          extra_metrics[key] = extra_metrics[key] or {}
          extra_metrics[key][#extra_metrics[key] + 1] = value
        end
      end
      done()
    end

    local ok, err = xpcall(function()
      spec.run(state, finish)
    end, debug.traceback)
    if not ok then
      fail(err)
    end
  end, function()
    complete = true
  end)

  local timed_out = not vim.wait(30000, function()
    return complete
  end, 5)
  if timed_out then
    fail("benchmark timeout: " .. tostring(spec.title))
  end

  return samples, extra_metrics
end

local function measure_sync_drawer_write(bufnr, action)
  local start_ns = uv.hrtime()
  local watch = { bufnr = bufnr }
  active_buffer_watch = watch
  action()
  active_buffer_watch = nil
  return (watch.last_ns or uv.hrtime()) - start_ns
end

emit("DRAW01_CORPUS", 'connections:2 schemas_per_conn:5 tables_per_schema:100 naming_distribution:"acct_ x400, ledger_ x599, table_003_042 x1" max_hit_query:"' .. LOCKED_QUERY_COHORT.max_hit_query .. '" max_hit_expected_matches:1000 broad_query:"' .. LOCKED_QUERY_COHORT.broad_query .. '" broad_expected_matches:599 secondary_broad_query:"' .. LOCKED_QUERY_COHORT.secondary_broad_query .. '" secondary_broad_expected_matches:400 narrow_query:"' .. LOCKED_QUERY_COHORT.narrow_query .. '" narrow_expected_matches:1 miss_query:"' .. LOCKED_QUERY_COHORT.miss_query .. '" miss_expected_matches:0 empty_restore_expected_nodes:1000')

local initial_render_samples = run_benchmark({
  title = "DRAW01 initial render",
  before = function()
    return new_drawer_fixture({
      show_immediately = false,
    })
  end,
  run = function(state, finish)
    local sample_ns = measure_sync_drawer_write(state.drawer.bufnr, function()
      state.drawer:show(state.winid)
    end)
    finish(sample_ns)
  end,
})

emit("DRAW01_INITIAL_RENDER_MEDIAN_MS", format_float(ns_to_ms(median(initial_render_samples))))
emit("DRAW01_INITIAL_RENDER_P95_MS", format_float(ns_to_ms(percentile(initial_render_samples, 0.95))))

vim.cmd("qa!")
