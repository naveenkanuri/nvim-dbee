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
