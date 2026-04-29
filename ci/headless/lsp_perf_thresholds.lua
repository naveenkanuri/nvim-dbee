-- Phase 10 LSP01 advisory-to-blocking threshold source of truth.
--
-- Manual freeze ceremony:
-- 1. Collect four weeks of advisory evidence with >=95% pass rate per platform.
-- 2. Copy adopted Linux and macOS medians/p95s into this file.
-- 3. Set the affected platform(s) to frozen = true.
-- 4. Flip LSP01_PERF_GATE_MODE=blocking in .github/workflows/test.yml in the
--    same change.
--
-- Blocking rule:
-- - If LSP01_PERF_GATE_MODE=blocking and the active platform has frozen = false
--   or is missing a threshold slot, the perf harness must fail closed.

local function candidate()
  return {
    median_ms = nil,
    p95_ms = nil,
    source = "advisory-candidate",
  }
end

local function seeded_p95(p95_ms, source)
  return {
    median_ms = nil,
    p95_ms = p95_ms,
    source = source or "research-seed",
  }
end

local function thresholds()
  return {
    startup_cold = seeded_p95(500),
    startup_warm = seeded_p95(100),
    startup_metadata_fallback = candidate(),

    completion_table_100 = seeded_p95(30),
    completion_table_1000 = seeded_p95(30),
    completion_table_10000 = seeded_p95(30),
    completion_schema = seeded_p95(30),
    completion_keyword = seeded_p95(30),
    completion_column_hit = seeded_p95(30),
    completion_column_miss_sync = seeded_p95(200),

    diagnostics_didchange_100 = seeded_p95(50),
    diagnostics_didchange_1000 = seeded_p95(50),
    diagnostics_didchange_10000 = seeded_p95(50),
    diagnostics_didsave_100 = seeded_p95(50),
    diagnostics_didsave_1000 = seeded_p95(50),
    diagnostics_didsave_10000 = seeded_p95(50),

    alias_simple_select = candidate(),
    alias_nested_cte = candidate(),
    alias_multiline = candidate(),
    alias_multi_join = candidate(),

    cache_build_100 = candidate(),
    cache_build_1000 = seeded_p95(100),
    cache_build_10000 = candidate(),
    cache_load_100 = candidate(),
    cache_load_1000 = candidate(),
    cache_load_10000 = candidate(),
    cache_save_100 = candidate(),
    cache_save_1000 = candidate(),
    cache_save_10000 = candidate(),
  }
end

return {
  linux = vim.tbl_extend("force", { frozen = false }, thresholds()),
  macos = vim.tbl_extend("force", { frozen = false }, thresholds()),
}
