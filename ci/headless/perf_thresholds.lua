-- Phase 9 advisory-to-blocking threshold source of truth.
--
-- Manual freeze ceremony:
-- 1. Collect four weeks of advisory evidence with >=95% pass rate per platform.
-- 2. Copy the adopted Linux + macOS threshold tables into this file.
-- 3. Set the affected platform(s) to frozen = true.
-- 4. Flip DRAW01_PERF_GATE_MODE=blocking in .github/workflows/test.yml in the
--    same change.
--
-- Blocking rule:
-- - If DRAW01_PERF_GATE_MODE=blocking and the active platform has frozen = false
--   or is missing a threshold slot, the perf harness must fail closed.

return {
  linux = {
    frozen = false,
    initial_render = {
      median_ms = 50,
      p95_ms = nil,
      source = "research-seed",
    },
    filter_first_redraw = {
      median_ms = 16,
      p95_ms = nil,
      source = "research-seed",
    },
    filter_stable = {
      median_ms = 50,
      p95_ms = nil,
      source = "research-seed",
    },
    lazy_expand = {
      median_ms = 30,
      p95_ms = nil,
      source = "research-seed",
    },
    cached_expand = {
      median_ms = nil,
      p95_ms = nil,
      source = "advisory-candidate",
    },
    load_more = {
      median_ms = nil,
      p95_ms = nil,
      source = "advisory-candidate",
    },
    filter_cold_connection_only_10 = {
      median_ms = nil,
      p95_ms = nil,
      source = "advisory-candidate",
    },
    filter_cold_connection_only_100 = {
      median_ms = nil,
      p95_ms = nil,
      source = "advisory-candidate",
    },
    filter_cold_connection_only_1000 = {
      median_ms = nil,
      p95_ms = nil,
      source = "advisory-candidate",
    },
    filter_mixed_visible_and_cached = {
      median_ms = nil,
      p95_ms = nil,
      source = "advisory-candidate",
    },
  },
  macos = {
    frozen = false,
    initial_render = {
      median_ms = nil,
      p95_ms = nil,
      source = "advisory-candidate",
    },
    filter_first_redraw = {
      median_ms = nil,
      p95_ms = nil,
      source = "advisory-candidate",
    },
    filter_stable = {
      median_ms = nil,
      p95_ms = nil,
      source = "advisory-candidate",
    },
    lazy_expand = {
      median_ms = nil,
      p95_ms = nil,
      source = "advisory-candidate",
    },
    cached_expand = {
      median_ms = nil,
      p95_ms = nil,
      source = "advisory-candidate",
    },
    load_more = {
      median_ms = nil,
      p95_ms = nil,
      source = "advisory-candidate",
    },
    filter_cold_connection_only_10 = {
      median_ms = nil,
      p95_ms = nil,
      source = "advisory-candidate",
    },
    filter_cold_connection_only_100 = {
      median_ms = nil,
      p95_ms = nil,
      source = "advisory-candidate",
    },
    filter_cold_connection_only_1000 = {
      median_ms = nil,
      p95_ms = nil,
      source = "advisory-candidate",
    },
    filter_mixed_visible_and_cached = {
      median_ms = nil,
      p95_ms = nil,
      source = "advisory-candidate",
    },
  },
}
