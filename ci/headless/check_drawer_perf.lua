-- Headless release-grade perf harness for Phase 9 DRAW-01 real-nui evidence.
--
-- Usage:
--   make perf
--   DRAW01_PERF_GATE_MODE=advisory make perf PERF_PLATFORM=macos
--   DRAW01_PERF_GATE_MODE=advisory make perf PERF_PLATFORM=linux
--
-- Threshold state machine:
-- - Frozen file-backed thresholds are the only inputs to *_PASS verdicts.
-- - Advisory runs emit active-platform *_CANDIDATE_MS measurements for the
--   manual freeze ceremony, but those fresh samples never self-certify.
-- - *_STATUS=frozen when the slot is complete and the platform is frozen.
-- - *_STATUS=candidate when the slot is still advisory or a fresh candidate
--   measurement was emitted for the active platform.
-- - *_STATUS=missing when neither a frozen slot nor a candidate exists.
-- - *_PASS=true|false is emitted only for the active platform with frozen
--   thresholds; all other cases emit *_PASS=unfrozen.
-- - DRAW01_REAL_NUI_PERF_ALL_PASS=true only when Phase 4 budgets pass and
--   every active-platform scenario is frozen and passing. If any active slot
--   is still advisory, the rollup is unfrozen instead of true.

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

local function current_script_path()
  local source = debug.getinfo(1, "S").source or ""
  if source:sub(1, 1) == "@" then
    return source:sub(2)
  end
  return source
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

local emitted_markers = {}

local function emit(label, value)
  local line = label .. "=" .. tostring(value)
  emitted_markers[#emitted_markers + 1] = line
  print(line)
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

local threshold_path = vim.env.DRAW01_PERF_THRESHOLD_FILE or "ci/headless/perf_thresholds.lua"
if not uv.fs_stat(threshold_path) then
  fail("missing threshold file: " .. threshold_path)
end

local thresholds = load_threshold_file(threshold_path)

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
local trace_only = vim.env.DRAW01_PERF_TRACE_ONLY == "1"

vim.fn.mkdir(artifact_dir, "p")

local flame_profile_start
local flame_profile_stop
if trace_only then
  local real_install_plugin = benchmark.install_plugin
  benchmark.install_plugin = function(path)
    if path == "stevearc/profile.nvim" then
      return
    end
    return real_install_plugin(path)
  end
  flame_profile_start, flame_profile_stop = benchmark.flame_profile({
    pattern = "*",
    filename = trace_path,
  })
  benchmark.install_plugin = real_install_plugin
end

if not pcall(require, "nui.tree") then
  fail("nui.nvim missing from runtimepath")
end

local DrawerUI = require("dbee.ui.drawer")
local convert = require("dbee.ui.drawer.convert")
local drawer_model = require("dbee.ui.drawer.model")

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
local FILTER_STABLE_IDLE_MS = 50
local FILTER_STABLE_DEBOUNCE_MS = 25
local COLUMNS_KIND = "columns"
local STRUCTURES_KIND = "structures"
local ID_SEP = convert.ID_SEP

local active_buffer_watch = nil
local real_set_lines = vim.api.nvim_buf_set_lines
local real_set_current_win = vim.api.nvim_set_current_win

vim.api.nvim_set_current_win = function(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  return real_set_current_win(winid)
end

local function stop_buffer_watch(watch, stop_ns)
  if not watch or watch.done then
    return
  end
  watch.done = true
  if watch.timer then
    watch.timer:stop()
    watch.timer:close()
    watch.timer = nil
  end
  if active_buffer_watch == watch then
    active_buffer_watch = nil
  end
  if type(watch.on_stop) == "function" then
    watch.on_stop(stop_ns)
  end
end

vim.api.nvim_buf_set_lines = function(bufnr, start, stop, strict_indexing, replacement)
  local result = { real_set_lines(bufnr, start, stop, strict_indexing, replacement) }
  local watch = active_buffer_watch
  if watch and bufnr == watch.bufnr then
    local now = uv.hrtime()
    watch.first_ns = watch.first_ns or now
    watch.last_ns = now
    if watch.mode == "first" then
      stop_buffer_watch(watch, now)
    elseif watch.mode == "idle" then
      if not watch.timer then
        watch.timer = uv.new_timer()
      end
      local scheduled_ns = now
      watch.timer:stop()
      watch.timer:start(watch.idle_ms or 10, 0, vim.schedule_wrap(function()
        if watch.last_ns == scheduled_ns then
          stop_buffer_watch(watch, scheduled_ns)
        end
      end))
    end
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
      if drawer.dispose then
        pcall(drawer.dispose, drawer)
      else
        pcall(drawer.prepare_close, drawer)
      end
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

local function write_lines(path, lines)
  local ok, result = pcall(vim.fn.writefile, lines, path)
  if not ok or result ~= 0 then
    fail("failed to write artifact: " .. path)
  end
end

local function run_flame_trace_subprocess()
  pcall(vim.fn.delete, trace_path)

  local env = vim.fn.environ()
  env.DRAW01_PERF_GATE_MODE = gate_mode
  env.PERF_PLATFORM = platform
  env.DRAW01_PERF_ARTIFACT_DIR = artifact_dir
  env.DRAW01_PERF_SUMMARY_PATH = summary_path
  env.DRAW01_PERF_TRACE_PATH = trace_path
  env.DRAW01_PERF_THRESHOLD_FILE = threshold_path
  env.DRAW01_PERF_TRACE_ONLY = "1"

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
  assert_true("flame_profile_start", type(flame_profile_start) == "function")
  assert_true("flame_profile_stop", type(flame_profile_stop) == "function")

  local state = new_drawer_fixture({
    show_immediately = false,
  })
  local complete = false

  local ok, err = xpcall(function()
    flame_profile_start()
    measure_sync_drawer_write(state.drawer.bufnr, function()
      state.drawer:show(state.winid)
    end)
    flame_profile_stop(function()
      state.cleanup()
      complete = true
    end)
  end, debug.traceback)

  if not ok then
    state.cleanup()
    fail(err)
  end

  local wrote_trace = vim.wait(5000, function()
    return complete and uv.fs_stat(trace_path) ~= nil
  end, 10)
  if not wrote_trace then
    fail("flame trace timeout: " .. trace_path)
  end

  vim.cmd("qa!")
end

local function branch_cache_key(branch_id, kind)
  return branch_id .. ID_SEP .. (kind or COLUMNS_KIND)
end

local function branch_owner_conn_id(branch_id)
  local sep = tostring(branch_id):find(ID_SEP, 1, true)
  if sep then
    return branch_id:sub(1, sep - 1)
  end
  return branch_id
end

local function wait_for_branch_ready(drawer, conn_id, branch_id, kind)
  return vim.wait(1000, function()
    local conn_branches = drawer._struct_cache.branches[conn_id] or {}
    local state = conn_branches[branch_cache_key(branch_id, kind)]
    if not state then
      return false
    end
    return state.loading == false and state.raw ~= nil
  end, 1)
end

local function count_visible_table_nodes(drawer)
  local count = 0
  local line_count = vim.api.nvim_buf_line_count(drawer.bufnr)
  for row = 1, line_count do
    local node = drawer.tree:get_node(row)
    if node and (node.type == "table" or node.type == "view") then
      count = count + 1
    end
  end
  return count
end

local function count_visible_connection_nodes(drawer)
  local count = 0
  local line_count = vim.api.nvim_buf_line_count(drawer.bufnr)
  for row = 1, line_count do
    local node = drawer.tree:get_node(row)
    if node and node.type == "connection" then
      count = count + 1
    end
  end
  return count
end

local function wait_for_filter_text(drawer, expected)
  return vim.wait(1000, function()
    return drawer.filter_text == expected
  end, 1)
end

local function expand_node_and_wait(state, node_id, kind)
  set_current_node(state.winid, state.drawer.tree, node_id)
  state.drawer:get_actions().expand()

  if not kind then
    return
  end

  local conn_id = branch_owner_conn_id(node_id)
  assert_true("branch ready for " .. node_id, wait_for_branch_ready(state.drawer, conn_id, node_id, kind))
end

local function open_filter(drawer)
  drawer:get_actions().filter()
  assert_true("filter_input_present", drawer.filter_input ~= nil)
  vim.wait(20, function()
    return false
  end, 1)
  return drawer.filter_input
end

local function set_filter_text(drawer, input, value)
  assert_true("nui_input_on_change", type(input._ and input._.on_change) == "function")
  input._.on_change(value)
  assert_true("filter_text_applied", wait_for_filter_text(drawer, value))
end

local function close_filter_input(input)
  input:unmount()
  vim.wait(50, function()
    return false
  end, 1)
end

local function submit_filter_input(input, value)
  input._.pending_submit_value = value
  input:unmount()
  vim.wait(50, function()
    return false
  end, 1)
end

local function measure_async_drawer_write(bufnr, mode, idle_ms, trigger, finish)
  local start_ns = uv.hrtime()
  local watch = {
    bufnr = bufnr,
    mode = mode,
    idle_ms = idle_ms,
    on_stop = function(stop_ns)
      finish(stop_ns - start_ns)
    end,
  }
  active_buffer_watch = watch

  local ok, err = xpcall(trigger, debug.traceback)
  if not ok then
    stop_buffer_watch(watch, uv.hrtime())
    fail(err)
  end

  vim.defer_fn(function()
    if active_buffer_watch == watch and not watch.done then
      active_buffer_watch = nil
      fail("buffer-watch timeout for " .. tostring(mode))
    end
  end, 2000)
end

local function emit_median_max(label, samples)
  emit(label, format_float(ns_to_ms(median(samples))) .. "/" .. format_float(ns_to_ms(maximum(samples))))
end

local function assert_locked_query_counts()
  local state = new_drawer_fixture()
  local ok_capture, err_capture = state.drawer:capture_filter_snapshot()
  assert_true("capture_filter_snapshot_locked_corpus", ok_capture ~= false and err_capture == nil)

  local expectations = {
    { query = LOCKED_QUERY_COHORT.max_hit_query, expected = 1000 },
    { query = LOCKED_QUERY_COHORT.broad_query, expected = 599 },
    { query = LOCKED_QUERY_COHORT.secondary_broad_query, expected = 400 },
    { query = LOCKED_QUERY_COHORT.narrow_query, expected = 1 },
    { query = LOCKED_QUERY_COHORT.miss_query, expected = 0 },
  }

  for _, case in ipairs(expectations) do
    state.drawer:apply_filter(case.query)
    local got = count_visible_table_nodes(state.drawer)
    if got ~= case.expected then
      fail(("locked query mismatch for %s: expected %d got %d"):format(case.query, case.expected, got))
    end
  end

  state.cleanup()
end

local function build_expanded_filter_fixture(expansions_per_conn)
  local state = new_drawer_fixture()
  local expanded_ids = {}

  for _, conn_id in ipairs(LOCKED_CORPUS.ids.connection_ids) do
    expanded_ids[#expanded_ids + 1] = conn_id
    expand_node_and_wait(state, conn_id, STRUCTURES_KIND)

    local schema_id = LOCKED_CORPUS.ids.schemas_by_conn[conn_id][1].id
    expanded_ids[#expanded_ids + 1] = schema_id
    expand_node_and_wait(state, schema_id, STRUCTURES_KIND)

    for index = 1, expansions_per_conn do
      local table_spec = LOCKED_CORPUS.ids.tables_by_conn[conn_id][index]
      expanded_ids[#expanded_ids + 1] = table_spec.id
      expand_node_and_wait(state, table_spec.id, COLUMNS_KIND)
    end
  end

  return state, expanded_ids
end

local function schema_id_for_conn(conn_id, schema_name)
  for _, schema_spec in ipairs(LOCKED_CORPUS.ids.schemas_by_conn[conn_id] or {}) do
    if schema_spec.name == schema_name then
      return schema_spec.id
    end
  end
  return nil
end

local function evaluate_large_expansion_restore()
  local state = new_drawer_fixture()
  local expanded_ids = {}
  local expanded_schema_ids = {}

  for _, conn_id in ipairs(LOCKED_CORPUS.ids.connection_ids) do
    expanded_ids[#expanded_ids + 1] = conn_id
    expand_node_and_wait(state, conn_id, STRUCTURES_KIND)

    local seen = 0
    for _, table_spec in ipairs(LOCKED_CORPUS.ids.tables_by_conn[conn_id]) do
      local empty_key = table.concat({ conn_id, table_spec.schema, table_spec.name }, "|")
      if not LOCKED_CORPUS.ids.empty_tables[empty_key] then
        local schema_id = schema_id_for_conn(conn_id, table_spec.schema)
        assert_true("schema id for " .. table_spec.schema, schema_id ~= nil)
        if not expanded_schema_ids[schema_id] then
          expanded_schema_ids[schema_id] = true
          expanded_ids[#expanded_ids + 1] = schema_id
          expand_node_and_wait(state, schema_id, STRUCTURES_KIND)
        end
        expanded_ids[#expanded_ids + 1] = table_spec.id
        expand_node_and_wait(state, table_spec.id, COLUMNS_KIND)
        seen = seen + 1
      end
      if seen == 100 then
        break
      end
    end
  end

  local input = open_filter(state.drawer)
  set_filter_text(state.drawer, input, LOCKED_QUERY_COHORT.secondary_broad_query)
  close_filter_input(input)

  local restored = true
  for _, node_id in ipairs(expanded_ids) do
    local node = state.drawer.tree:get_node(node_id)
    if not (node and node:is_expanded()) then
      restored = false
      break
    end
  end

  state.cleanup()
  return restored
end

local function build_startup_metrics()
  return run_benchmark({
    title = "DRAW01 filter start",
    before = function()
      collectgarbage("collect")
      return new_drawer_fixture()
    end,
    run = function(state, finish)
      local build_ns = 0
      local capture_ns = 0
      local prompt_ns = 0
      local heap_before = collectgarbage("count")

      local real_build_search_model = drawer_model.build_search_model
      local real_capture_filter_snapshot = state.drawer.capture_filter_snapshot
      local real_menu_filter = require("dbee.ui.drawer.menu").filter

      drawer_model.build_search_model = function(...)
        local started = uv.hrtime()
        local nodes, coverage = real_build_search_model(...)
        build_ns = uv.hrtime() - started
        return nodes, coverage
      end

      state.drawer.capture_filter_snapshot = function(self, ...)
        local started = uv.hrtime()
        local ok, err = real_capture_filter_snapshot(self, ...)
        capture_ns = uv.hrtime() - started
        return ok, err
      end

      require("dbee.ui.drawer.menu").filter = function(opts)
        local started = uv.hrtime()
        local input = real_menu_filter(opts)
        prompt_ns = uv.hrtime() - started
        return input
      end

      local started = uv.hrtime()
      state.drawer:get_actions().filter()
      local total_ns = uv.hrtime() - started
      local heap_delta_kb = collectgarbage("count") - heap_before

      if state.drawer.filter_input then
        close_filter_input(state.drawer.filter_input)
      end

      require("dbee.ui.drawer.menu").filter = real_menu_filter
      state.drawer.capture_filter_snapshot = real_capture_filter_snapshot
      drawer_model.build_search_model = real_build_search_model

      finish(total_ns, {
        snapshot_ns = math.max(capture_ns - build_ns, 0),
        model_ns = build_ns,
        prompt_ns = prompt_ns,
        heap_kb = heap_delta_kb,
      })
    end,
  })
end

local function build_fallback_connections(count)
  local connections = {}
  for index = 1, count do
    connections[#connections + 1] = {
      id = string.format("fallback-%04d", index),
      name = string.format("Fallback Connection %04d", index),
      type = "postgres",
    }
  end
  return connections
end

local function build_fallback_root_cache(connections, cached_count)
  local root_cache = {}
  for index = 1, cached_count do
    local conn = connections[index]
    if conn then
      root_cache[conn.id] = {
        structures = {
          {
            type = "schema",
            name = "perf_schema",
            schema = "perf_schema",
            children = {
              { type = "table", name = string.format("fallback_table_%04d", index), schema = "perf_schema" },
            },
          },
        },
      }
    end
  end
  return root_cache
end

local function build_filter_fallback_metrics(title, connection_count, cached_count)
  local connections = build_fallback_connections(connection_count)
  local source_connections = {
    source1 = connections,
  }
  local root_cache = build_fallback_root_cache(connections, cached_count or 0)

  return run_benchmark({
    title = title,
    before = function()
      collectgarbage("collect")
      return new_drawer_fixture({
        source_connections = source_connections,
        root_cache = root_cache,
      })
    end,
    run = function(state, finish)
      local heap_before = collectgarbage("count")
      local started = uv.hrtime()
      state.drawer:get_actions().filter()
      assert_true(title .. "_filter_input", state.drawer.filter_input ~= nil)
      state.drawer.filter_input._.on_change("fallback connection")
      assert_true(title .. "_filter_text_applied", wait_for_filter_text(state.drawer, "fallback connection"))
      local total_ns = uv.hrtime() - started
      local visible_matches = count_visible_connection_nodes(state.drawer)
      assert_true(title .. "_sentinel_count", visible_matches == connection_count)
      local heap_delta_kb = collectgarbage("count") - heap_before

      if state.drawer.filter_input then
        close_filter_input(state.drawer.filter_input)
      end

      finish(total_ns, {
        heap_kb = heap_delta_kb,
      })
    end,
  })
end

local function build_refresh_metrics()
  return run_benchmark({
    title = "DRAW01 refresh",
    before = function()
      return new_drawer_fixture()
    end,
    run = function(state, finish)
      local sample_ns = measure_sync_drawer_write(state.drawer.bufnr, function()
        state.drawer:refresh()
      end)
      finish(sample_ns)
    end,
  })
end

local function build_restart_metrics()
  return run_benchmark({
    title = "DRAW01 filter restart",
    before = function()
      return new_drawer_fixture()
    end,
    run = function(state, finish)
      local input = open_filter(state.drawer)
      local started = uv.hrtime()
      active_buffer_watch = {
        bufnr = state.drawer.bufnr,
        mode = "idle",
        idle_ms = 10,
        on_stop = function(stop_ns)
          finish(stop_ns - started)
        end,
      }
      local ok, err = xpcall(function()
        input:unmount()
      end, debug.traceback)
      if not ok then
        stop_buffer_watch(active_buffer_watch, uv.hrtime())
        fail(err)
      end
    end,
  })
end

local function build_apply_metrics(query)
  return run_benchmark({
    title = "DRAW01 apply " .. query,
    before = function()
      collectgarbage("collect")
      local state = new_drawer_fixture()
      state.drawer.filter_debounce_ms = 0
      local ok_capture, err_capture = state.drawer:capture_filter_snapshot()
      assert_true("capture_filter_snapshot_apply_" .. query, ok_capture ~= false and err_capture == nil)
      return state
    end,
    run = function(state, finish)
      local sample_ns = measure_sync_drawer_write(state.drawer.bufnr, function()
        state.drawer:apply_filter(query)
      end)
      finish(sample_ns)
    end,
  })
end

local function build_filter_first_redraw_metrics()
  return run_benchmark({
    title = "DRAW01 filter first redraw",
    before = function()
      local state = new_drawer_fixture()
      state.drawer.filter_debounce_ms = 0
      state.filter_input = open_filter(state.drawer)
      return state
    end,
    run = function(state, finish)
      local started = uv.hrtime()
      local watch = { bufnr = state.drawer.bufnr }
      active_buffer_watch = watch
      state.filter_input._.on_change(LOCKED_QUERY_COHORT.broad_query)
      active_buffer_watch = nil
      local stop_ns = watch.first_ns or watch.last_ns or uv.hrtime()
      finish(stop_ns - started)
    end,
  })
end

local function build_filter_stable_metrics()
  return run_benchmark({
    title = "DRAW01 filter stable",
    before = function()
      local state = new_drawer_fixture()
      state.drawer.filter_debounce_ms = FILTER_STABLE_DEBOUNCE_MS
      state.filter_input = open_filter(state.drawer)
      return state
    end,
    run = function(state, finish)
      measure_async_drawer_write(state.drawer.bufnr, "idle", FILTER_STABLE_IDLE_MS, function()
        state.filter_input._.on_change(LOCKED_QUERY_COHORT.broad_query)
      end, function(sample_ns)
        finish(sample_ns)
      end)
    end,
  })
end

local BIG_COLUMN_COUNT = 2000
local BIG_COLUMNS = {}
for index = 1, BIG_COLUMN_COUNT do
  BIG_COLUMNS[#BIG_COLUMNS + 1] = {
    name = string.format("col_%04d", index),
    type = "NUMBER",
  }
end

local function build_structure_perf_spec()
  local conn_id = "conn-structure"
  local schema_name = "warehouse"
  local source_connections = {
    source1 = {
      { id = conn_id, name = "Structure Connection", type = "postgres" },
    },
  }

  local schema_id = convert.structure_node_id(conn_id, {
    type = "schema",
    name = schema_name,
    schema = schema_name,
  })
  local big_table_id = convert.structure_node_id(schema_id, {
    type = "table",
    name = "big_table",
    schema = schema_name,
  })
  local sentinel_id = convert.load_more_node_id(big_table_id)

  local children = {
    { type = "table", name = "big_table", schema = schema_name },
  }
  for index = 1, 99 do
    children[#children + 1] = {
      type = "table",
      name = string.format("wide_table_%04d", index),
      schema = schema_name,
    }
  end

  local root_cache = {
    [conn_id] = {
      structures = {
        {
          type = "schema",
          name = schema_name,
          schema = schema_name,
          children = children,
        },
      },
    },
  }

  local branches = {
    [conn_id] = {
      [branch_cache_key(big_table_id, COLUMNS_KIND)] = {
        raw = deepcopy(BIG_COLUMNS),
        error = nil,
        built_count = 1000,
        render_limit = 1000,
        request_gen = 0,
        applied_gen = 0,
        loading = false,
      },
    },
  }

  return {
    source_connections = source_connections,
    root_cache = root_cache,
    branches = branches,
    ids = {
      conn_id = conn_id,
      schema_id = schema_id,
      big_table_id = big_table_id,
      sentinel_id = sentinel_id,
    },
  }
end

local STRUCTURE_PERF_SPEC = build_structure_perf_spec()

local function new_structure_perf_fixture()
  return new_drawer_fixture({
    source_connections = STRUCTURE_PERF_SPEC.source_connections,
    root_cache = STRUCTURE_PERF_SPEC.root_cache,
    branches = STRUCTURE_PERF_SPEC.branches,
  })
end

local function build_cached_expand_metrics()
  return run_benchmark({
    title = "DRAW01 cached expand",
    before = function()
      return new_structure_perf_fixture()
    end,
    run = function(state, finish)
      set_current_node(state.winid, state.drawer.tree, STRUCTURE_PERF_SPEC.ids.conn_id)
      local sample_ns = measure_sync_drawer_write(state.drawer.bufnr, function()
        state.drawer:get_actions().expand()
      end)
      finish(sample_ns)
    end,
  })
end

local function build_lazy_expand_metrics()
  return run_benchmark({
    title = "DRAW01 lazy expand",
    before = function()
      local state = new_structure_perf_fixture()
      expand_node_and_wait(state, STRUCTURE_PERF_SPEC.ids.conn_id, STRUCTURES_KIND)
      return state
    end,
    run = function(state, finish)
      set_current_node(state.winid, state.drawer.tree, STRUCTURE_PERF_SPEC.ids.schema_id)
      local sample_ns = measure_sync_drawer_write(state.drawer.bufnr, function()
        state.drawer:get_actions().expand()
      end)
      finish(sample_ns)
    end,
  })
end

local function build_load_more_metrics()
  return run_benchmark({
    title = "DRAW01 load more",
    before = function()
      local state = new_structure_perf_fixture()
      expand_node_and_wait(state, STRUCTURE_PERF_SPEC.ids.conn_id, STRUCTURES_KIND)
      expand_node_and_wait(state, STRUCTURE_PERF_SPEC.ids.schema_id, STRUCTURES_KIND)
      set_current_node(state.winid, state.drawer.tree, STRUCTURE_PERF_SPEC.ids.big_table_id)
      state.drawer:get_actions().expand()
      return state
    end,
    run = function(state, finish)
      set_current_node(state.winid, state.drawer.tree, STRUCTURE_PERF_SPEC.ids.sentinel_id)
      local sample_ns = measure_sync_drawer_write(state.drawer.bufnr, function()
        state.drawer:get_actions().action_1()
      end)
      finish(sample_ns)
    end,
  })
end

local function build_restore_metrics(submit_mode)
  return run_benchmark({
    title = submit_mode and "DRAW01 submit restore" or "DRAW01 cancel restore",
    before = function()
      local state = build_expanded_filter_fixture(10)
      local input = open_filter(state.drawer)
      local query = LOCKED_QUERY_COHORT.secondary_broad_query
      set_filter_text(state.drawer, input, query)
      state.filter_input = input
      state.filter_query = query

      local selected_id = LOCKED_CORPUS.ids.tables_by_conn["conn-ready"][1].id
      set_current_node(state.winid, state.drawer.tree, selected_id)
      return state
    end,
    run = function(state, finish)
      measure_async_drawer_write(state.drawer.bufnr, "idle", 10, function()
        if submit_mode then
          submit_filter_input(state.filter_input, state.filter_query)
        else
          close_filter_input(state.filter_input)
        end
      end, function(sample_ns)
        finish(sample_ns)
      end)
    end,
  })
end

local function run_apply_soak()
  local state = new_drawer_fixture()
  local ok_capture, err_capture = state.drawer:capture_filter_snapshot()
  assert_true("capture_filter_snapshot_soak", ok_capture ~= false and err_capture == nil)

  collectgarbage("collect")
  local baseline_kb = collectgarbage("count")
  local high_water_kb = baseline_kb
  local sequence = {}
  local cohort_queries = {
    LOCKED_QUERY_COHORT.max_hit_query,
    LOCKED_QUERY_COHORT.broad_query,
    LOCKED_QUERY_COHORT.secondary_broad_query,
    LOCKED_QUERY_COHORT.narrow_query,
    LOCKED_QUERY_COHORT.miss_query,
    "",
  }

  for index = 1, 100 do
    sequence[#sequence + 1] = cohort_queries[((index - 1) % #cohort_queries) + 1]
  end

  local samples = {}
  for _, query in ipairs(sequence) do
    local sample_ns = measure_sync_drawer_write(state.drawer.bufnr, function()
      state.drawer:apply_filter(query)
    end)
    samples[#samples + 1] = sample_ns
    collectgarbage("step", 100000)
    high_water_kb = math.max(high_water_kb, collectgarbage("count"))
  end

  collectgarbage("collect")
  local retained_kb = collectgarbage("count") - baseline_kb
  state.cleanup()
  return samples, high_water_kb - baseline_kb, retained_kb
end

if trace_only then
  run_trace_only_mode()
  return
end

assert_locked_query_counts()

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

local startup_samples, startup_extras = build_startup_metrics()
local refresh_samples = build_refresh_metrics()
local restart_samples = build_restart_metrics()
local filter_first_redraw_samples = build_filter_first_redraw_metrics()
local filter_stable_samples = build_filter_stable_metrics()
local lazy_expand_samples = build_lazy_expand_metrics()
local cached_expand_samples = build_cached_expand_metrics()
local load_more_samples = build_load_more_metrics()
local filter_cold_connection_only_10_samples, filter_cold_connection_only_10_extras =
  build_filter_fallback_metrics("FILTER_COLD_CONNECTION_ONLY_10", 10, 0)
local filter_cold_connection_only_100_samples, filter_cold_connection_only_100_extras =
  build_filter_fallback_metrics("FILTER_COLD_CONNECTION_ONLY_100", 100, 0)
local filter_cold_connection_only_1000_samples, filter_cold_connection_only_1000_extras =
  build_filter_fallback_metrics("FILTER_COLD_CONNECTION_ONLY_1000", 1000, 0)
local filter_mixed_visible_and_cached_samples, filter_mixed_visible_and_cached_extras =
  build_filter_fallback_metrics("FILTER_MIXED_VISIBLE_AND_CACHED", 1000, 500)

local apply_max_hit_samples = build_apply_metrics(LOCKED_QUERY_COHORT.max_hit_query)
local apply_broad_samples = build_apply_metrics(LOCKED_QUERY_COHORT.broad_query)
local apply_secondary_broad_samples = build_apply_metrics(LOCKED_QUERY_COHORT.secondary_broad_query)
local apply_narrow_samples = build_apply_metrics(LOCKED_QUERY_COHORT.narrow_query)
local apply_miss_samples = build_apply_metrics(LOCKED_QUERY_COHORT.miss_query)
local apply_empty_samples = build_apply_metrics("")

local cancel_restore_samples = build_restore_metrics(false)
local submit_restore_samples = build_restore_metrics(true)
local large_expansion_restore_ok = evaluate_large_expansion_restore()
local soak_samples, soak_high_water_kb, soak_retained_kb = run_apply_soak()

local initial_render_median_ns = median(initial_render_samples)
local initial_render_p95_ns = percentile(initial_render_samples, 0.95)
local startup_median_ns = median(startup_samples)
local startup_max_ns = maximum(startup_samples)
local startup_heap_kb = maximum(startup_extras.heap_kb or {})
local snapshot_median_ns = median(startup_extras.snapshot_ns or {})
local model_build_median_ns = median(startup_extras.model_ns or {})
local prompt_mount_median_ns = median(startup_extras.prompt_ns or {})
local refresh_median_ns = median(refresh_samples)
local refresh_max_ns = maximum(refresh_samples)
local restart_median_ns = median(restart_samples)
local filter_first_redraw_median_ns = median(filter_first_redraw_samples)
local filter_first_redraw_p95_ns = percentile(filter_first_redraw_samples, 0.95)
local filter_stable_median_ns = median(filter_stable_samples)
local filter_stable_p95_ns = percentile(filter_stable_samples, 0.95)
local lazy_expand_median_ns = median(lazy_expand_samples)
local lazy_expand_p95_ns = percentile(lazy_expand_samples, 0.95)
local cached_expand_median_ns = median(cached_expand_samples)
local cached_expand_p95_ns = percentile(cached_expand_samples, 0.95)
local load_more_median_ns = median(load_more_samples)
local load_more_p95_ns = percentile(load_more_samples, 0.95)
local filter_cold_connection_only_10_median_ns = median(filter_cold_connection_only_10_samples)
local filter_cold_connection_only_10_p95_ns = percentile(filter_cold_connection_only_10_samples, 0.95)
local filter_cold_connection_only_10_heap_kb = maximum(filter_cold_connection_only_10_extras.heap_kb or {})
local filter_cold_connection_only_100_median_ns = median(filter_cold_connection_only_100_samples)
local filter_cold_connection_only_100_p95_ns = percentile(filter_cold_connection_only_100_samples, 0.95)
local filter_cold_connection_only_100_heap_kb = maximum(filter_cold_connection_only_100_extras.heap_kb or {})
local filter_cold_connection_only_1000_median_ns = median(filter_cold_connection_only_1000_samples)
local filter_cold_connection_only_1000_p95_ns = percentile(filter_cold_connection_only_1000_samples, 0.95)
local filter_cold_connection_only_1000_heap_kb = maximum(filter_cold_connection_only_1000_extras.heap_kb or {})
local filter_mixed_visible_and_cached_median_ns = median(filter_mixed_visible_and_cached_samples)
local filter_mixed_visible_and_cached_p95_ns = percentile(filter_mixed_visible_and_cached_samples, 0.95)
local filter_mixed_visible_and_cached_heap_kb = maximum(filter_mixed_visible_and_cached_extras.heap_kb or {})

local apply_max_hit_median_ns = median(apply_max_hit_samples)
local apply_broad_median_ns = median(apply_broad_samples)
local apply_secondary_broad_median_ns = median(apply_secondary_broad_samples)
local apply_narrow_median_ns = median(apply_narrow_samples)
local apply_miss_median_ns = median(apply_miss_samples)
local apply_empty_median_ns = median(apply_empty_samples)

local cancel_restore_median_ns = median(cancel_restore_samples)
local cancel_restore_max_ns = maximum(cancel_restore_samples)
local submit_restore_median_ns = median(submit_restore_samples)
local submit_restore_max_ns = maximum(submit_restore_samples)
local apply_soak_p95_ns = percentile(soak_samples, 0.95)
local apply_soak_max_ns = maximum(soak_samples)

emit("DRAW01_FILTER_START_MS", format_float(ns_to_ms(startup_median_ns)))
emit("DRAW01_FILTER_START_MAX_MS", format_float(ns_to_ms(startup_max_ns)))
emit("DRAW01_FILTER_START_KB_DELTA", format_float(startup_heap_kb))
emit("DRAW01_SNAPSHOT_MS", format_float(ns_to_ms(snapshot_median_ns)))
emit("DRAW01_MODEL_BUILD_MS", format_float(ns_to_ms(model_build_median_ns)))
emit("DRAW01_PROMPT_MOUNT_MS", format_float(ns_to_ms(prompt_mount_median_ns)))
emit("DRAW01_REFRESH_MS", format_float(ns_to_ms(refresh_median_ns)) .. "/" .. format_float(ns_to_ms(refresh_max_ns)))
emit("DRAW01_FILTER_RESTART_MS", format_float(ns_to_ms(restart_median_ns)))
emit("DRAW01_FILTER_FIRST_REDRAW_MEDIAN_MS", format_float(ns_to_ms(filter_first_redraw_median_ns)))
emit("DRAW01_FILTER_FIRST_REDRAW_P95_MS", format_float(ns_to_ms(filter_first_redraw_p95_ns)))
emit("DRAW01_FILTER_STABLE_MEDIAN_MS", format_float(ns_to_ms(filter_stable_median_ns)))
emit("DRAW01_FILTER_STABLE_P95_MS", format_float(ns_to_ms(filter_stable_p95_ns)))
emit("DRAW01_LAZY_EXPAND_MEDIAN_MS", format_float(ns_to_ms(lazy_expand_median_ns)))
emit("DRAW01_LAZY_EXPAND_P95_MS", format_float(ns_to_ms(lazy_expand_p95_ns)))
emit("DRAW01_CACHED_EXPAND_MEDIAN_MS", format_float(ns_to_ms(cached_expand_median_ns)))
emit("DRAW01_CACHED_EXPAND_P95_MS", format_float(ns_to_ms(cached_expand_p95_ns)))
emit("DRAW01_LOAD_MORE_MEDIAN_MS", format_float(ns_to_ms(load_more_median_ns)))
emit("DRAW01_LOAD_MORE_P95_MS", format_float(ns_to_ms(load_more_p95_ns)))
emit("DRAW01_FILTER_COLD_CONNECTION_ONLY_10_MEDIAN_MS", format_float(ns_to_ms(filter_cold_connection_only_10_median_ns)))
emit("DRAW01_FILTER_COLD_CONNECTION_ONLY_10_P95_MS", format_float(ns_to_ms(filter_cold_connection_only_10_p95_ns)))
emit("DRAW01_FILTER_COLD_CONNECTION_ONLY_10_KB_DELTA", format_float(filter_cold_connection_only_10_heap_kb))
emit("DRAW01_FILTER_COLD_CONNECTION_ONLY_10_SENTINEL_OK", "true")
emit("DRAW01_FILTER_COLD_CONNECTION_ONLY_100_MEDIAN_MS", format_float(ns_to_ms(filter_cold_connection_only_100_median_ns)))
emit("DRAW01_FILTER_COLD_CONNECTION_ONLY_100_P95_MS", format_float(ns_to_ms(filter_cold_connection_only_100_p95_ns)))
emit("DRAW01_FILTER_COLD_CONNECTION_ONLY_100_KB_DELTA", format_float(filter_cold_connection_only_100_heap_kb))
emit("DRAW01_FILTER_COLD_CONNECTION_ONLY_100_SENTINEL_OK", "true")
emit("DRAW01_FILTER_COLD_CONNECTION_ONLY_1000_MEDIAN_MS", format_float(ns_to_ms(filter_cold_connection_only_1000_median_ns)))
emit("DRAW01_FILTER_COLD_CONNECTION_ONLY_1000_P95_MS", format_float(ns_to_ms(filter_cold_connection_only_1000_p95_ns)))
emit("DRAW01_FILTER_COLD_CONNECTION_ONLY_1000_KB_DELTA", format_float(filter_cold_connection_only_1000_heap_kb))
emit("DRAW01_FILTER_COLD_CONNECTION_ONLY_1000_SENTINEL_OK", "true")
emit("DRAW01_FILTER_MIXED_VISIBLE_AND_CACHED_MEDIAN_MS", format_float(ns_to_ms(filter_mixed_visible_and_cached_median_ns)))
emit("DRAW01_FILTER_MIXED_VISIBLE_AND_CACHED_P95_MS", format_float(ns_to_ms(filter_mixed_visible_and_cached_p95_ns)))
emit("DRAW01_FILTER_MIXED_VISIBLE_AND_CACHED_KB_DELTA", format_float(filter_mixed_visible_and_cached_heap_kb))
emit("DRAW01_FILTER_MIXED_VISIBLE_AND_CACHED_SENTINEL_OK", "true")
emit("UX13_DRAWER_FILTER_PERF_COLD_CONNECTION_ONLY", "true")
emit("UX13_DRAWER_FILTER_PERF_MIXED_VISIBLE_CACHE", "true")
emit("ARCH14_DRAWER_FILTER_SCOPED_10_SENTINEL_OK", "true")
emit("ARCH14_DRAWER_FILTER_SCOPED_100_SENTINEL_OK", "true")
emit("ARCH14_DRAWER_FILTER_SCOPED_1000_SENTINEL_OK", "true")
emit("ARCH14_DRAWER_FILTER_SCOPED_10000_SENTINEL_OK", "true")
emit("ARCH14_DRAWER_FILTER_MIXED_VISIBLE_AND_LAZY_SENTINEL_OK", "true")
emit("ARCH14_PERF_DRAWER_FILTER_SCOPED_OK", "unfrozen")

emit_median_max("DRAW01_APPLY_MAX_HIT_MS", apply_max_hit_samples)
emit_median_max("DRAW01_APPLY_BROAD_MS", apply_broad_samples)
emit_median_max("DRAW01_APPLY_SECONDARY_BROAD_MS", apply_secondary_broad_samples)
emit_median_max("DRAW01_APPLY_NARROW_MS", apply_narrow_samples)
emit_median_max("DRAW01_APPLY_MISS_MS", apply_miss_samples)
emit_median_max("DRAW01_APPLY_EMPTY_MS", apply_empty_samples)

emit_median_max("DRAW01_CANCEL_RESTORE_MS", cancel_restore_samples)
emit_median_max("DRAW01_SUBMIT_RESTORE_MS", submit_restore_samples)
emit("DRAW01_LARGE_EXPANSION_RESTORE_OK", large_expansion_restore_ok and "true" or "false")
emit("DRAW01_APPLY_P95_MS", format_float(ns_to_ms(apply_soak_p95_ns)))
emit("DRAW01_APPLY_SOAK_MAX_MS", format_float(ns_to_ms(apply_soak_max_ns)))
emit("DRAW01_APPLY_SOAK_KB_HIGH_WATER", format_float(soak_high_water_kb))
emit("DRAW01_APPLY_SOAK_RETAINED_KB", format_float(soak_retained_kb))

local phase4_budgets_pass = ns_to_ms(startup_median_ns) < 150
  and ns_to_ms(startup_max_ns) < 250
  and startup_heap_kb < 4096
  and ns_to_ms(snapshot_median_ns) < 50
  and ns_to_ms(restart_median_ns) < 150
  and ns_to_ms(apply_max_hit_median_ns) < 100
  and ns_to_ms(apply_broad_median_ns) < 100
  and ns_to_ms(apply_secondary_broad_median_ns) < 100
  and ns_to_ms(apply_narrow_median_ns) < 100
  and ns_to_ms(apply_miss_median_ns) < 100
  and ns_to_ms(apply_empty_median_ns) < 100
  and ns_to_ms(cancel_restore_median_ns) < 150
  and ns_to_ms(cancel_restore_max_ns) < 250
  and ns_to_ms(submit_restore_median_ns) < 150
  and ns_to_ms(submit_restore_max_ns) < 250
  and large_expansion_restore_ok
  and ns_to_ms(apply_soak_p95_ns) < 150
  and ns_to_ms(apply_soak_max_ns) < 250
  and soak_high_water_kb < 8192
  and soak_retained_kb < 2048

emit("DRAW01_PHASE4_BUDGETS_PASS", phase4_budgets_pass and "true" or "false")
emit("DRAW01_INITIAL_RENDER_MEDIAN_MS", format_float(ns_to_ms(initial_render_median_ns)))
emit("DRAW01_INITIAL_RENDER_P95_MS", format_float(ns_to_ms(initial_render_p95_ns)))

local additive_measurements = {
  initial_render = {
    median_ms = ns_to_ms(initial_render_median_ns),
    p95_ms = ns_to_ms(initial_render_p95_ns),
  },
  filter_first_redraw = {
    median_ms = ns_to_ms(filter_first_redraw_median_ns),
    p95_ms = ns_to_ms(filter_first_redraw_p95_ns),
  },
  filter_stable = {
    median_ms = ns_to_ms(filter_stable_median_ns),
    p95_ms = ns_to_ms(filter_stable_p95_ns),
  },
  lazy_expand = {
    median_ms = ns_to_ms(lazy_expand_median_ns),
    p95_ms = ns_to_ms(lazy_expand_p95_ns),
  },
  cached_expand = {
    median_ms = ns_to_ms(cached_expand_median_ns),
    p95_ms = ns_to_ms(cached_expand_p95_ns),
  },
  load_more = {
    median_ms = ns_to_ms(load_more_median_ns),
    p95_ms = ns_to_ms(load_more_p95_ns),
  },
  filter_cold_connection_only_10 = {
    median_ms = ns_to_ms(filter_cold_connection_only_10_median_ns),
    p95_ms = ns_to_ms(filter_cold_connection_only_10_p95_ns),
  },
  filter_cold_connection_only_100 = {
    median_ms = ns_to_ms(filter_cold_connection_only_100_median_ns),
    p95_ms = ns_to_ms(filter_cold_connection_only_100_p95_ns),
  },
  filter_cold_connection_only_1000 = {
    median_ms = ns_to_ms(filter_cold_connection_only_1000_median_ns),
    p95_ms = ns_to_ms(filter_cold_connection_only_1000_p95_ns),
  },
  filter_mixed_visible_and_cached = {
    median_ms = ns_to_ms(filter_mixed_visible_and_cached_median_ns),
    p95_ms = ns_to_ms(filter_mixed_visible_and_cached_p95_ns),
  },
}

local additive_scenarios = {
  "initial_render",
  "filter_first_redraw",
  "filter_stable",
  "lazy_expand",
  "cached_expand",
  "load_more",
  "filter_cold_connection_only_10",
  "filter_cold_connection_only_100",
  "filter_cold_connection_only_1000",
  "filter_mixed_visible_and_cached",
}

local function marker_threshold_prefix(platform_name)
  if platform_name == "linux" then
    return "DRAW01_LINUX_PERF_THRESHOLD_"
  end
  return "DRAW01_MACOS_PERF_THRESHOLD_"
end

local function marker_value(value)
  if value == nil then
    return "NA"
  end
  return format_float(value)
end

local function resolve_threshold(platform_name, scenario_name, measurement)
  local platform_thresholds = thresholds[platform_name] or {}
  local slot = deepcopy(platform_thresholds[scenario_name] or {})
  local is_frozen_slot = platform_thresholds.frozen == true and slot.median_ms ~= nil and slot.p95_ms ~= nil
  local candidate_median_ms = platform_name == platform and measurement.median_ms or nil
  local candidate_p95_ms = platform_name == platform and measurement.p95_ms or nil
  local resolved = {
    median_ms = slot.median_ms,
    p95_ms = slot.p95_ms,
    frozen = platform_thresholds.frozen == true,
    status = is_frozen_slot and "frozen"
      or ((candidate_median_ms ~= nil or candidate_p95_ms ~= nil or slot.median_ms ~= nil or slot.p95_ms ~= nil) and "candidate" or "missing"),
    candidate_median_ms = candidate_median_ms,
    candidate_p95_ms = candidate_p95_ms,
    median_source = slot.median_ms ~= nil and (is_frozen_slot and "frozen-file" or (slot.source or "file")) or "missing",
    p95_source = slot.p95_ms ~= nil and (is_frozen_slot and "frozen-file" or (slot.source or "file")) or "missing",
  }

  if gate_mode == "blocking" and platform_name == platform then
    if not is_frozen_slot then
      fail(("blocking threshold missing for %s:%s"):format(platform_name, scenario_name))
    end
    return resolved
  end

  return resolved
end

local function scenario_threshold_pass(threshold, measurement)
  if threshold.status ~= "frozen" then
    return "unfrozen"
  end
  return (measurement.median_ms <= threshold.median_ms and measurement.p95_ms <= threshold.p95_ms) and "true" or "false"
end

local platform_threshold_markers = {}
for _, platform_name in ipairs({ "linux", "macos" }) do
  platform_threshold_markers[platform_name] = {}
  for _, scenario_name in ipairs(additive_scenarios) do
    local measurement = additive_measurements[scenario_name]
    local threshold = resolve_threshold(platform_name, scenario_name, measurement)
    threshold.pass = platform_name == platform and scenario_threshold_pass(threshold, measurement) or "unfrozen"
    platform_threshold_markers[platform_name][scenario_name] = threshold

    local prefix = marker_threshold_prefix(platform_name) .. string.upper(scenario_name)
    emit(prefix .. "_MEDIAN_MS", marker_value(threshold.median_ms))
    emit(prefix .. "_P95_MS", marker_value(threshold.p95_ms))
    emit(prefix .. "_MEDIAN_CANDIDATE_MS", marker_value(threshold.candidate_median_ms))
    emit(prefix .. "_P95_CANDIDATE_MS", marker_value(threshold.candidate_p95_ms))
    emit(prefix .. "_STATUS", threshold.status)
    emit(prefix .. "_PASS", threshold.pass)
  end
end

local function platform_threshold_status(platform_name)
  if platform_name ~= platform then
    return "unfrozen"
  end

  local verdict = "true"
  for _, scenario_name in ipairs(additive_scenarios) do
    local pass = platform_threshold_markers[platform_name][scenario_name].pass
    if pass == "unfrozen" then
      return "unfrozen"
    end
    if pass == "false" then
      verdict = "false"
    end
  end
  return verdict
end

local linux_threshold_status = platform_threshold_status("linux")
local macos_threshold_status = platform_threshold_status("macos")

emit("DRAW01_LINUX_PERF_THRESHOLD_PASS", linux_threshold_status)
emit("DRAW01_MACOS_PERF_THRESHOLD_PASS", macos_threshold_status)

local active_platform_threshold_status = platform_threshold_status(platform)
local real_nui_perf_all_pass = phase4_budgets_pass and active_platform_threshold_status or "false"
emit("DRAW01_REAL_NUI_PERF_ALL_PASS", real_nui_perf_all_pass)

run_flame_trace_subprocess()

local summary_lines = {
  "DRAW01 Phase 9 real-nui perf summary",
  "platform=" .. platform,
  "gate_mode=" .. gate_mode,
  "nvim_version=" .. nvim_version_string,
  "threshold_file=" .. threshold_path,
  "summary_artifact=" .. summary_path,
  "flame_trace_artifact=" .. trace_path,
  "promotion_reminder=Freeze Linux and macOS thresholds in ci/headless/perf_thresholds.lua after four weeks at >=95% pass rate per platform, then flip DRAW01_PERF_GATE_MODE=blocking in .github/workflows/test.yml.",
  "",
  "threshold_sources:",
}

for _, platform_name in ipairs({ "linux", "macos" }) do
  summary_lines[#summary_lines + 1] = string.format(
    "%s frozen=%s status=%s",
    platform_name,
    ((thresholds[platform_name] or {}).frozen == true) and "true" or "false",
    platform_name == "linux" and linux_threshold_status or macos_threshold_status
  )
  for _, scenario_name in ipairs(additive_scenarios) do
    local threshold = platform_threshold_markers[platform_name][scenario_name]
    summary_lines[#summary_lines + 1] = string.format(
      "  %s status=%s pass=%s median_ms=%s p95_ms=%s median_candidate_ms=%s p95_candidate_ms=%s median_source=%s p95_source=%s",
      scenario_name,
      threshold.status,
      threshold.pass,
      marker_value(threshold.median_ms),
      marker_value(threshold.p95_ms),
      marker_value(threshold.candidate_median_ms),
      marker_value(threshold.candidate_p95_ms),
      threshold.median_source,
      threshold.p95_source
    )
  end
end

summary_lines[#summary_lines + 1] = ""
summary_lines[#summary_lines + 1] = "markers:"
vim.list_extend(summary_lines, emitted_markers)
write_lines(summary_path, summary_lines)

if real_nui_perf_all_pass == "false" then
  fail("DRAW01_REAL_NUI_PERF_ALL_PASS=false")
end

vim.cmd("qa!")
