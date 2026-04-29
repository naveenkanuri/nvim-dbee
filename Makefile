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
	mkdir -p "$(LSP01_PERF_ARTIFACT_DIR)" "$(LSP01_PERF_STATE_HOME)"; \
	printf '%s\n' "Running: LSP01_PERF_GATE_MODE=$(LSP01_PERF_GATE_MODE) LSP01_ALLOW_NONPUBLISHABLE_PLATFORM_OVERRIDE=$(LSP01_ALLOW_NONPUBLISHABLE_PLATFORM_OVERRIDE) PERF_PLATFORM=$(PERF_PLATFORM) LSP01_PERF_ARTIFACT_DIR=$(LSP01_PERF_ARTIFACT_DIR) LSP01_PERF_SUMMARY_PATH=$(LSP01_PERF_SUMMARY_PATH) LSP01_PERF_TRACE_PATH=$(LSP01_PERF_TRACE_PATH) LSP01_PERF_THRESHOLD_FILE=$(LSP01_PERF_THRESHOLD_FILE) XDG_STATE_HOME=$(LSP01_PERF_STATE_HOME) $(PERF_NVIM_HEADLESS) -c \"luafile $(LSP_PERF_SCRIPT)\""; \
	LSP01_PERF_GATE_MODE="$(LSP01_PERF_GATE_MODE)" \
	LSP01_ALLOW_NONPUBLISHABLE_PLATFORM_OVERRIDE="$(LSP01_ALLOW_NONPUBLISHABLE_PLATFORM_OVERRIDE)" \
	PERF_PLATFORM="$(PERF_PLATFORM)" \
	LSP01_PERF_ARTIFACT_DIR="$(LSP01_PERF_ARTIFACT_DIR)" \
	LSP01_PERF_SUMMARY_PATH="$(LSP01_PERF_SUMMARY_PATH)" \
	LSP01_PERF_TRACE_PATH="$(LSP01_PERF_TRACE_PATH)" \
	LSP01_PERF_THRESHOLD_FILE="$(LSP01_PERF_THRESHOLD_FILE)" \
	XDG_STATE_HOME="$(LSP01_PERF_STATE_HOME)" \
	$(PERF_NVIM_HEADLESS) -c "luafile $(LSP_PERF_SCRIPT)" || { \
	  status="$$?"; \
	  printf '%s\n' "perf-lsp failed with status $$status" >&2; \
	  printf '%s\n' "summary path: $(LSP01_PERF_SUMMARY_PATH)" >&2; \
	  printf '%s\n' "trace path: $(LSP01_PERF_TRACE_PATH)" >&2; \
	  exit "$$status"; \
	}

perf-all: perf perf-lsp
