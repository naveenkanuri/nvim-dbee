# Shared plugin/bootstrap contract for Phase 9 DRAW-01 real-nui perf runs,
# Phase 10 LSP perf runs, and Phase 11 LSP async/correctness checks.

PERF_PLUGIN_ROOT ?= $(if $(RUNNER_TEMP),$(RUNNER_TEMP)/nvim-dbee-perf-plugins,$(if $(TMPDIR),$(TMPDIR)nvim-dbee-perf-plugins,/tmp/nvim-dbee-perf-plugins))

NUI_NVIM_REPO := https://github.com/MunifTanjim/nui.nvim
NUI_NVIM_COMMIT := de740991c12411b663994b2860f1a4fd0937c130
NUI_NVIM_DIR := $(PERF_PLUGIN_ROOT)/nui.nvim

BENCHMARK_NVIM_REPO := https://github.com/stevearc/benchmark.nvim
BENCHMARK_NVIM_COMMIT := db5861266656a4a72d2c5a801a8a2ebaf670b47f
BENCHMARK_NVIM_DIR := $(PERF_PLUGIN_ROOT)/benchmark.nvim

# benchmark.nvim's flame_profile() requires profile.nvim. Pin it here so trace
# generation does not float independently of the shared bootstrap contract.
PROFILE_NVIM_REPO := https://github.com/stevearc/profile.nvim
PROFILE_NVIM_COMMIT := 30433d7513f0d14665c1cfcea501c90f8a63e003
PROFILE_NVIM_DIR := $(PERF_PLUGIN_ROOT)/profile.nvim

NIO_NVIM_REPO := https://github.com/nvim-neotest/nvim-nio
NIO_NVIM_COMMIT := 21f5324bfac14e22ba26553caf69ec76ae8a7662
NIO_NVIM_DIR := $(PERF_PLUGIN_ROOT)/nvim-nio

# NIO_NVIM_DIR is intentionally included in PERF_RUNTIMEPATH_CMD here, so
# Phase 11 async tests do not own a second runtimepath/pin surface.
PERF_RUNTIMEPATH_CMD = set rtp^=$(NIO_NVIM_DIR) | set rtp^=$(PROFILE_NVIM_DIR) | set rtp^=$(BENCHMARK_NVIM_DIR) | set rtp^=$(NUI_NVIM_DIR) | set rtp+=$(CURDIR)
PERF_NVIM_HEADLESS = $(NVIM_BIN) --headless -u NONE -i NONE -n --cmd "$(PERF_RUNTIMEPATH_CMD)"

.PHONY: perf-bootstrap perf-bootstrap-print

perf-bootstrap:
	@set -eu; \
	test -f ci/headless/perf_bootstrap.mk || { echo "perf-bootstrap: missing shared bootstrap" >&2; exit 1; }; \
	test -f ci/headless/perf_thresholds.lua || { echo "perf-bootstrap: missing DRAW01 threshold source" >&2; exit 1; }; \
	test -f ci/headless/check_drawer_perf.lua || { echo "perf-bootstrap: missing DRAW01 perf harness" >&2; exit 1; }; \
	test -f ci/headless/check_ux13_rollup.lua || { echo "perf-bootstrap: missing UX13 rollup harness" >&2; exit 1; }; \
	grep -q "NUI_NVIM_COMMIT" ci/headless/perf_bootstrap.mk || { echo "perf-bootstrap: missing nui.nvim pin" >&2; exit 1; }; \
	grep -q "BENCHMARK_NVIM_COMMIT" ci/headless/perf_bootstrap.mk || { echo "perf-bootstrap: missing benchmark.nvim pin" >&2; exit 1; }; \
	grep -q "PROFILE_NVIM_COMMIT" ci/headless/perf_bootstrap.mk || { echo "perf-bootstrap: missing profile.nvim pin" >&2; exit 1; }; \
	grep -q "NIO_NVIM_COMMIT" ci/headless/perf_bootstrap.mk || { echo "perf-bootstrap: missing nvim-nio pin" >&2; exit 1; }; \
	grep -q "DRAW01_REAL_NUI_PERF_ALL_PASS" ci/headless/check_drawer_perf.lua || { echo "perf-bootstrap: DRAW01 harness missing rollup marker" >&2; exit 1; }; \
	grep -q "UX13_ALL_PASS" ci/headless/check_ux13_rollup.lua || { echo "perf-bootstrap: UX13 harness missing rollup marker" >&2; exit 1; }; \
	grep -q "include ci/headless/perf_bootstrap.mk" Makefile || { echo "perf-bootstrap: Makefile does not include shared bootstrap" >&2; exit 1; }; \
	mkdir -p "$(PERF_PLUGIN_ROOT)"; \
	checkout_repo() { \
	  repo_url="$$1"; \
	  repo_dir="$$2"; \
	  repo_commit="$$3"; \
	  if [ -z "$$repo_commit" ]; then \
	    echo "perf-bootstrap: missing pin for $$repo_url" >&2; \
	    exit 1; \
	  fi; \
	  if [ ! -d "$$repo_dir/.git" ]; then \
	    rm -rf "$$repo_dir"; \
	    git clone "$$repo_url" "$$repo_dir" >/dev/null 2>&1 || { \
	      echo "perf-bootstrap: clone failed for $$repo_url" >&2; \
	      exit 1; \
	    }; \
	  fi; \
	  git -C "$$repo_dir" fetch --force --tags origin "$$repo_commit" >/dev/null 2>&1 || { \
	    echo "perf-bootstrap: fetch failed for $$repo_url @ $$repo_commit" >&2; \
	    exit 1; \
	  }; \
	  git -C "$$repo_dir" checkout --detach "$$repo_commit" >/dev/null 2>&1 || { \
	    echo "perf-bootstrap: checkout failed for $$repo_url @ $$repo_commit" >&2; \
	    exit 1; \
	  }; \
	  actual_commit="$$(git -C "$$repo_dir" rev-parse HEAD)"; \
	  if [ "$$actual_commit" != "$$repo_commit" ]; then \
	    echo "perf-bootstrap: pin mismatch for $$repo_url (expected $$repo_commit got $$actual_commit)" >&2; \
	    exit 1; \
	  fi; \
	}; \
	checkout_repo "$(NUI_NVIM_REPO)" "$(NUI_NVIM_DIR)" "$(NUI_NVIM_COMMIT)"; \
	checkout_repo "$(BENCHMARK_NVIM_REPO)" "$(BENCHMARK_NVIM_DIR)" "$(BENCHMARK_NVIM_COMMIT)"; \
	checkout_repo "$(PROFILE_NVIM_REPO)" "$(PROFILE_NVIM_DIR)" "$(PROFILE_NVIM_COMMIT)"; \
	checkout_repo "$(NIO_NVIM_REPO)" "$(NIO_NVIM_DIR)" "$(NIO_NVIM_COMMIT)"

perf-bootstrap-print:
	@printf '%s\n' \
	  "PERF_PLUGIN_ROOT=$(PERF_PLUGIN_ROOT)" \
	  "NUI_NVIM_DIR=$(NUI_NVIM_DIR)" \
	  "BENCHMARK_NVIM_DIR=$(BENCHMARK_NVIM_DIR)" \
	  "PROFILE_NVIM_DIR=$(PROFILE_NVIM_DIR)" \
	  "NIO_NVIM_DIR=$(NIO_NVIM_DIR)" \
	  "PERF_RUNTIMEPATH_CMD=$(PERF_RUNTIMEPATH_CMD)" \
	  "PERF_BOOTSTRAP_CONSUMERS=draw01,lsp01,lsp11"
