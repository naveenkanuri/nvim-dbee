include ci/headless/perf_bootstrap.mk

UNAME_S := $(shell uname -s)

NVIM_BIN ?= nvim
PERF_PLATFORM ?= $(if $(filter Darwin,$(UNAME_S)),macos,linux)
DRAW01_PERF_GATE_MODE ?= advisory
DRAW01_PERF_THRESHOLD_FILE ?= ci/headless/perf_thresholds.lua
PERF_SCRIPT ?= $(CURDIR)/ci/headless/check_drawer_perf.lua
PERF_ARTIFACT_ROOT ?= $(if $(RUNNER_TEMP),$(RUNNER_TEMP)/draw01-perf,$(if $(TMPDIR),$(TMPDIR)nvim-dbee-draw01-perf,/tmp/nvim-dbee-draw01-perf))
DRAW01_PERF_ARTIFACT_DIR ?= $(PERF_ARTIFACT_ROOT)/$(PERF_PLATFORM)
DRAW01_PERF_SUMMARY_PATH ?= $(DRAW01_PERF_ARTIFACT_DIR)/draw01-summary.txt
DRAW01_PERF_TRACE_PATH ?= $(DRAW01_PERF_ARTIFACT_DIR)/draw01-trace.json
LSP01_PERF_GATE_MODE ?= advisory
LSP01_ALLOW_NONPUBLISHABLE_PLATFORM_OVERRIDE ?= 0
LSP01_PERF_THRESHOLD_FILE ?= ci/headless/lsp_perf_thresholds.lua
LSP_PERF_SCRIPT ?= $(CURDIR)/ci/headless/check_lsp_perf.lua
LSP_PERF_ARTIFACT_ROOT ?= $(if $(RUNNER_TEMP),$(RUNNER_TEMP)/lsp01-perf,$(if $(TMPDIR),$(TMPDIR)nvim-dbee-lsp01-perf,/tmp/nvim-dbee-lsp01-perf))
LSP01_PERF_ARTIFACT_DIR ?= $(LSP_PERF_ARTIFACT_ROOT)/$(PERF_PLATFORM)
LSP01_PERF_SUMMARY_PATH ?= $(LSP01_PERF_ARTIFACT_DIR)/lsp01-summary.txt
LSP01_PERF_TRACE_PATH ?= $(LSP01_PERF_ARTIFACT_DIR)/lsp01-trace.json
LSP01_PERF_STATE_HOME ?= $(LSP01_PERF_ARTIFACT_DIR)/state-home
UX13_ROLLUP_SCRIPT ?= $(CURDIR)/ci/headless/check_ux13_rollup.lua
UX13_ROLLUP_ARTIFACT_DIR ?= $(LSP01_PERF_ARTIFACT_DIR)
UX13_ROLLUP_LOG ?= $(UX13_ROLLUP_ARTIFACT_DIR)/ux13-rollup-stdout.log
ARCH14_ROLLUP_SCRIPT ?= $(CURDIR)/ci/headless/check_arch14_rollup.lua
ARCH14_ROLLUP_LOG ?= $(UX13_ROLLUP_LOG)

.PHONY: perf perf-lsp perf-all

perf: perf-bootstrap
	@set -eu; \
	nvim_version="$$( "$(NVIM_BIN)" --version | awk 'NR==1 { print $$2 }' )"; \
	case "$$nvim_version" in \
	  v0.12.*) ;; \
	  *) \
	    printf '%s\n' "make perf requires Neovim v0.12.x, got $$nvim_version" >&2; \
	    printf '%s\n' "NVIM_BIN=$(NVIM_BIN)" >&2; \
	    exit 1; \
	    ;; \
	esac; \
	mkdir -p "$(DRAW01_PERF_ARTIFACT_DIR)"; \
	printf '%s\n' "Running: DRAW01_PERF_GATE_MODE=$(DRAW01_PERF_GATE_MODE) PERF_PLATFORM=$(PERF_PLATFORM) DRAW01_PERF_ARTIFACT_DIR=$(DRAW01_PERF_ARTIFACT_DIR) DRAW01_PERF_SUMMARY_PATH=$(DRAW01_PERF_SUMMARY_PATH) DRAW01_PERF_TRACE_PATH=$(DRAW01_PERF_TRACE_PATH) DRAW01_PERF_THRESHOLD_FILE=$(DRAW01_PERF_THRESHOLD_FILE) $(PERF_NVIM_HEADLESS) -c \"luafile $(PERF_SCRIPT)\""; \
	DRAW01_PERF_GATE_MODE="$(DRAW01_PERF_GATE_MODE)" \
	PERF_PLATFORM="$(PERF_PLATFORM)" \
	DRAW01_PERF_ARTIFACT_DIR="$(DRAW01_PERF_ARTIFACT_DIR)" \
	DRAW01_PERF_SUMMARY_PATH="$(DRAW01_PERF_SUMMARY_PATH)" \
	DRAW01_PERF_TRACE_PATH="$(DRAW01_PERF_TRACE_PATH)" \
	DRAW01_PERF_THRESHOLD_FILE="$(DRAW01_PERF_THRESHOLD_FILE)" \
	$(PERF_NVIM_HEADLESS) -c "luafile $(PERF_SCRIPT)" || { \
	  status="$$?"; \
	  printf '%s\n' "perf failed with status $$status" >&2; \
	  printf '%s\n' "summary path: $(DRAW01_PERF_SUMMARY_PATH)" >&2; \
	  printf '%s\n' "trace path: $(DRAW01_PERF_TRACE_PATH)" >&2; \
	  exit "$$status"; \
	}

perf-lsp: perf-bootstrap
	@set -eu; \
	nvim_version="$$( "$(NVIM_BIN)" --version | awk 'NR==1 { print $$2 }' )"; \
	case "$$nvim_version" in \
	  v0.12.*) ;; \
	  *) \
	    printf '%s\n' "make perf-lsp requires Neovim v0.12.x, got $$nvim_version" >&2; \
	    printf '%s\n' "NVIM_BIN=$(NVIM_BIN)" >&2; \
	    exit 1; \
	    ;; \
	esac; \
	mkdir -p "$(LSP01_PERF_ARTIFACT_DIR)" "$(LSP01_PERF_STATE_HOME)" "$(UX13_ROLLUP_ARTIFACT_DIR)"; \
	: > "$(UX13_ROLLUP_LOG)"; \
	run_logged() { \
	  label="$$1"; \
	  shift; \
	  tmp="$$(mktemp)"; \
	  "$$@" >"$$tmp" 2>&1; \
	  status="$$?"; \
	  cat "$$tmp"; \
	  printf '\n'; \
	  cat "$$tmp" >> "$(UX13_ROLLUP_LOG)"; \
	  printf '\n' >> "$(UX13_ROLLUP_LOG)"; \
	  rm -f "$$tmp"; \
	  if [ "$$status" -ne 0 ]; then \
	    printf '%s\n' "$$label failed with status $$status" >&2; \
	    printf '%s\n' "rollup log path: $(UX13_ROLLUP_LOG)" >&2; \
	    exit "$$status"; \
	  fi; \
	}; \
	printf '%s\n' "Running: LSP01_PERF_GATE_MODE=$(LSP01_PERF_GATE_MODE) LSP01_ALLOW_NONPUBLISHABLE_PLATFORM_OVERRIDE=$(LSP01_ALLOW_NONPUBLISHABLE_PLATFORM_OVERRIDE) PERF_PLATFORM=$(PERF_PLATFORM) LSP01_PERF_ARTIFACT_DIR=$(LSP01_PERF_ARTIFACT_DIR) LSP01_PERF_SUMMARY_PATH=$(LSP01_PERF_SUMMARY_PATH) LSP01_PERF_TRACE_PATH=$(LSP01_PERF_TRACE_PATH) LSP01_PERF_THRESHOLD_FILE=$(LSP01_PERF_THRESHOLD_FILE) XDG_STATE_HOME=$(LSP01_PERF_STATE_HOME) $(PERF_NVIM_HEADLESS) -c \"luafile $(LSP_PERF_SCRIPT)\""; \
	run_logged "perf-lsp" env \
	  LSP01_PERF_GATE_MODE="$(LSP01_PERF_GATE_MODE)" \
	  LSP01_ALLOW_NONPUBLISHABLE_PLATFORM_OVERRIDE="$(LSP01_ALLOW_NONPUBLISHABLE_PLATFORM_OVERRIDE)" \
	  PERF_PLATFORM="$(PERF_PLATFORM)" \
	  LSP01_PERF_ARTIFACT_DIR="$(LSP01_PERF_ARTIFACT_DIR)" \
	  LSP01_PERF_SUMMARY_PATH="$(LSP01_PERF_SUMMARY_PATH)" \
	  LSP01_PERF_TRACE_PATH="$(LSP01_PERF_TRACE_PATH)" \
	  LSP01_PERF_THRESHOLD_FILE="$(LSP01_PERF_THRESHOLD_FILE)" \
	  XDG_STATE_HOME="$(LSP01_PERF_STATE_HOME)" \
	  $(PERF_NVIM_HEADLESS) -c "luafile $(LSP_PERF_SCRIPT)"; \
	for script in \
	  check_schema_filter.lua \
	  check_handler_schema_filter.lua \
	  check_adapter_schema_filter.lua \
	  check_lsp_alias_completion.lua \
	  check_lsp_schema_alias_completion.lua \
	  check_lsp_alias_rebinding.lua \
	  check_lsp_schema_cache_optimization.lua \
	  check_lsp_disk_cache_safety.lua \
	  check_lsp_async_completion.lua \
	  check_lsp_completion_refresh.lua \
	  check_lsp_diagnostics_correctness.lua \
	  check_lsp_diagnostics_debounce.lua \
	  check_lsp_schema_filter_lazy.lua \
	  check_drawer_filter.lua \
	  check_structure_lazy.lua \
	  check_notes_picker.lua \
	  check_connection_lifecycle.lua \
	  check_connection_coordination.lua \
	  check_wizard_input_visible.lua \
	  check_connection_wizard.lua \
	  check_filesource_persistence.lua; \
	do \
	  run_logged "$$script" env XDG_STATE_HOME="$(LSP01_PERF_STATE_HOME)" \
	    $(PERF_NVIM_HEADLESS) -c "luafile $(CURDIR)/ci/headless/$$script"; \
	done; \
	run_logged "go-arch14" env GOCACHE="$(LSP01_PERF_ARTIFACT_DIR)/go-cache" \
	  go -C dbee test ./core ./handler ./adapters; \
	run_logged "perf" env XDG_STATE_HOME="$(LSP01_PERF_STATE_HOME)" $(MAKE) --no-print-directory perf \
	  PERF_PLATFORM="$(PERF_PLATFORM)" \
	  DRAW01_PERF_GATE_MODE="$(DRAW01_PERF_GATE_MODE)" \
	  DRAW01_PERF_ARTIFACT_DIR="$(DRAW01_PERF_ARTIFACT_DIR)" \
	  DRAW01_PERF_SUMMARY_PATH="$(DRAW01_PERF_SUMMARY_PATH)" \
	  DRAW01_PERF_TRACE_PATH="$(DRAW01_PERF_TRACE_PATH)" \
	  DRAW01_PERF_THRESHOLD_FILE="$(DRAW01_PERF_THRESHOLD_FILE)" \
	  NVIM_BIN="$(NVIM_BIN)" \
	  PERF_PLUGIN_ROOT="$(PERF_PLUGIN_ROOT)"; \
	run_logged "ux13-rollup" env UX13_ROLLUP_LOG="$(UX13_ROLLUP_LOG)" \
	  $(PERF_NVIM_HEADLESS) -c "luafile $(UX13_ROLLUP_SCRIPT)"; \
	run_logged "arch14-rollup" env ARCH14_ROLLUP_LOG="$(ARCH14_ROLLUP_LOG)" \
	  $(PERF_NVIM_HEADLESS) -c "luafile $(ARCH14_ROLLUP_SCRIPT)"

perf-all: perf perf-lsp
