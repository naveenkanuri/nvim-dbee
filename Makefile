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
LSP12_ROLLUP_SCRIPT ?= $(CURDIR)/ci/headless/check_lsp12_rollup.lua
LSP21_ROLLUP_SCRIPT ?= $(CURDIR)/ci/headless/check_lsp21_rollup.lua
ARCH14_ROLLUP_SCRIPT ?= $(CURDIR)/ci/headless/check_arch14_rollup.lua
ARCH14_ROLLUP_LOG ?= $(UX13_ROLLUP_LOG)
WALLET_PLATFORM ?= $(if $(filter Darwin,$(UNAME_S)),macos,linux)
WALLET_ARTIFACT_ROOT ?= $(if $(RUNNER_TEMP),$(RUNNER_TEMP)/wallet-test,$(if $(TMPDIR),$(TMPDIR)nvim-dbee-wallet-test,/tmp/nvim-dbee-wallet-test))
WALLET_ARTIFACT_DIR ?= $(WALLET_ARTIFACT_ROOT)/$(WALLET_PLATFORM)
WALLET_GO_LOG ?= $(WALLET_ARTIFACT_DIR)/wallet-go.log
WALLET_LUA_LOG ?= $(WALLET_ARTIFACT_DIR)/wallet-lua.log
WALLET_ROLLUP_SCRIPT ?= $(CURDIR)/ci/headless/check_oracle_wallet_zip.lua

.PHONY: perf perf-lsp perf-all wallet-test perf-headless ux13-rollup lsp21 lsp21-rollup lsp21-locked-helpers-guard db18-locked-helpers-guard gn23 gn23-rollup gn23-locked-helpers-guard gn23-no-go-rpc-guard

perf-headless: perf-bootstrap
	@mkdir -p "$(LSP01_PERF_STATE_HOME)"
	@if [ -n "$(ARGS)" ]; then \
	  UX13_ROLLUP_LOG="$(UX13_ROLLUP_LOG)" XDG_STATE_HOME="$(LSP01_PERF_STATE_HOME)" $(PERF_NVIM_HEADLESS) $(ARGS); \
	else \
	  $(MAKE) --no-print-directory perf-lsp \
	    PERF_PLATFORM="$(PERF_PLATFORM)" \
	    DRAW01_PERF_GATE_MODE="$(DRAW01_PERF_GATE_MODE)" \
	    LSP01_PERF_GATE_MODE="$(LSP01_PERF_GATE_MODE)" \
	    NVIM_BIN="$(NVIM_BIN)" \
	    PERF_PLUGIN_ROOT="$(PERF_PLUGIN_ROOT)"; \
	fi

lsp21: perf-bootstrap
	@set -eu; \
	mkdir -p "$(LSP01_PERF_STATE_HOME)" "$(UX13_ROLLUP_ARTIFACT_DIR)" "$(LSP01_PERF_ARTIFACT_DIR)/go-cache"; \
	: > "$(UX13_ROLLUP_LOG)"; \
	run_logged() { \
	  label="$$1"; \
	  shift; \
	  tmp="$$(mktemp)"; \
	  set +e; \
	  "$$@" >"$$tmp" 2>&1; \
	  status="$$?"; \
	  set -e; \
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
	run_logged "check_lsp21_completion_annotations.lua" env XDG_STATE_HOME="$(LSP01_PERF_STATE_HOME)" \
	  $(PERF_NVIM_HEADLESS) -l ci/headless/check_lsp21_completion_annotations.lua; \
	run_logged "check_lsp21_reverse_refs.lua" env XDG_STATE_HOME="$(LSP01_PERF_STATE_HOME)" \
	  $(PERF_NVIM_HEADLESS) -l ci/headless/check_lsp21_reverse_refs.lua; \
	run_logged "check_lsp21_perf.lua" env XDG_STATE_HOME="$(LSP01_PERF_STATE_HOME)" \
	  $(PERF_NVIM_HEADLESS) -l ci/headless/check_lsp21_perf.lua; \
	run_logged "go-core" env GOCACHE="$(LSP01_PERF_ARTIFACT_DIR)/go-cache" \
	  go -C dbee test ./core; \
	run_logged "lsp21-locked-helpers-guard" \
	  $(MAKE) --no-print-directory lsp21-locked-helpers-guard; \
	run_logged "lsp21-static-markers" sh -c 'printf "%s\n" "LSP21_RICH16_UX13_PRESERVED_OK=true" "LSP21_STRICT_MARKER_COUNT=67"'

lsp21-rollup: lsp21
	LSP21_ROLLUP_LOG="$(UX13_ROLLUP_LOG)" XDG_STATE_HOME="$(LSP01_PERF_STATE_HOME)" $(PERF_NVIM_HEADLESS) -l ci/headless/check_lsp21_rollup.lua

lsp21-locked-helpers-guard:
	@set -eu; \
	git diff --quiet -- lua/dbee/schema_filter_authority.lua lua/dbee/schema_name_canonical.lua lua/dbee/lsp/epoch_authority.lua; \
	git diff --cached --quiet -- lua/dbee/schema_filter_authority.lua lua/dbee/schema_name_canonical.lua lua/dbee/lsp/epoch_authority.lua; \
	grep -F 'local SCHEMA_CACHE_VERSION = 4' lua/dbee/lsp/schema_cache.lua >/dev/null; \
	grep -F 'epoch_authority.read_with_freshness' lua/dbee/lsp/schema_cache.lua >/dev/null; \
	grep -F 'function SchemaCache:get_reverse_fk_refs' lua/dbee/lsp/schema_cache.lua >/dev/null; \
	grep -F 'self:_fresh_lsp_scope()' lua/dbee/lsp/schema_cache.lua >/dev/null; \
	grep -F 'schema_name_canonical.canonical' lua/dbee/lsp/schema_cache.lua >/dev/null; \
	bad="$$(rg -l 'reverse_fk_refs_by_(target|source)_key' lua ci/headless | grep -v '^lua/dbee/lsp/schema_cache.lua$$' || true)"; \
	if [ -n "$$bad" ]; then printf '%s\n' "$$bad" >&2; exit 1; fi; \
	bad="$$(rg -n 'markers\[[0-9]+\][[:space:]]*=' ci/headless/check_lsp21*.lua lua/dbee/lsp/schema_cache.lua || true)"; \
	if [ -n "$$bad" ]; then printf '%s\n' "$$bad" >&2; exit 1; fi; \
	bad="$$(rg -l '_drop_reverse_fk_refs_for_source' lua ci/headless | grep -v '^lua/dbee/lsp/schema_cache.lua$$' || true)"; \
	if [ -n "$$bad" ]; then printf '%s\n' "$$bad" >&2; exit 1; fi; \
	count="$$(rg -n '_drop_reverse_fk_refs_for_source' lua/dbee/lsp/schema_cache.lua | wc -l | tr -d ' ')"; \
	if [ "$$count" != "3" ]; then printf '%s\n' "_drop_reverse_fk_refs_for_source reference count $$count != 3" >&2; exit 1; fi; \
	save_block="$$(awk '/function SchemaCache:_save_columns_to_disk/{flag=1} flag{print} flag && /^end$$/{exit}' lua/dbee/lsp/schema_cache.lua)"; \
	if printf '%s\n' "$$save_block" | grep -E 'labelDetails|referenced_by|Referenced by|truncated|overflow|reverse-FK' >/dev/null; then \
	  printf '%s\n' "_save_columns_to_disk contains annotation-only fields" >&2; exit 1; \
	fi; \
	printf '%s\n' "LSP21_LOCKED_HELPERS_UNTOUCHED_OK=true"; \
	printf '%s\n' "LSP21_LOCKED_HELPERS_ALL_CONSUMERS_ROUTED_OK=true"; \
	printf '%s\n' "LSP21_CACHE_VERSION4_NO_BUMP_OK=true"

gn23: perf-bootstrap
	@set -eu; \
	mkdir -p "$(LSP01_PERF_STATE_HOME)" "$(UX13_ROLLUP_ARTIFACT_DIR)"; \
	: > "$(UX13_ROLLUP_LOG)"; \
	run_logged() { \
	  label="$$1"; \
	  shift; \
	  tmp="$$(mktemp)"; \
	  set +e; \
	  "$$@" >"$$tmp" 2>&1; \
	  status="$$?"; \
	  set -e; \
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
	for script in \
	  check_folder_scoped_notes.lua \
	  check_notes_picker.lua \
	  check_folder_persistence.lua \
	  check_drawer_folders.lua; \
	do \
	  run_logged "$$script" env UX13_ROLLUP_LOG="$(UX13_ROLLUP_LOG)" XDG_STATE_HOME="$(LSP01_PERF_STATE_HOME)" \
	    $(PERF_NVIM_HEADLESS) -l "ci/headless/$$script"; \
	done; \
	run_logged "gn23-locked-helpers-guard" $(MAKE) --no-print-directory gn23-locked-helpers-guard; \
	run_logged "gn23-no-go-rpc-guard" $(MAKE) --no-print-directory gn23-no-go-rpc-guard

gn23-rollup: gn23
	UX13_ROLLUP_LOG="$(UX13_ROLLUP_LOG)" GN23_ROLLUP_ONLY=1 XDG_STATE_HOME="$(LSP01_PERF_STATE_HOME)" $(PERF_NVIM_HEADLESS) -l ci/headless/check_ux13_rollup.lua

gn23-locked-helpers-guard:
	@set -eu; \
	git diff --exit-code -- lua/dbee/schema_filter_authority.lua lua/dbee/schema_name_canonical.lua lua/dbee/lsp/epoch_authority.lua >/dev/null; \
	git diff --cached --exit-code -- lua/dbee/schema_filter_authority.lua lua/dbee/schema_name_canonical.lua lua/dbee/lsp/epoch_authority.lua >/dev/null

gn23-no-go-rpc-guard:
	@set -eu; \
	if rg -n 'DbeeConnectionGetFolder|DbeeFolder|Dbee.*Folder.*Note|FolderNotes|ConnectionGetFolder' dbee/endpoints.go dbee/handler/handler.go; then \
	  printf '%s\n' "Phase 23 forbids Go RPC folder lookup additions" >&2; \
	  exit 1; \
	fi

db18-locked-helpers-guard:
	@set -eu; \
	mkdir -p "$(UX13_ROLLUP_ARTIFACT_DIR)"; \
	check_empty() { \
	  label="$$1"; \
	  shift; \
	  tmp="$$(mktemp)"; \
	  set +e; \
	  "$$@" >"$$tmp" 2>&1; \
	  status="$$?"; \
	  set -e; \
	  if [ "$$status" -ne 0 ]; then \
	    cat "$$tmp" >&2; \
	    rm -f "$$tmp"; \
	    printf '%s\n' "$$label failed with status $$status" >&2; \
	    exit "$$status"; \
	  fi; \
	  if [ -s "$$tmp" ]; then \
	    cat "$$tmp" >&2; \
	    rm -f "$$tmp"; \
	    printf '%s\n' "$$label produced locked-helper diff output" >&2; \
	    exit 1; \
	  fi; \
	  rm -f "$$tmp"; \
	}; \
	check_empty "git diff locked helpers" git diff -- lua/dbee/schema_filter_authority.lua lua/dbee/schema_name_canonical.lua lua/dbee/lsp/epoch_authority.lua; \
	check_empty "git diff cached locked helpers" git diff --cached -- lua/dbee/schema_filter_authority.lua lua/dbee/schema_name_canonical.lua lua/dbee/lsp/epoch_authority.lua; \
	check_empty "git diff baseline locked helpers" git diff d8a4161..HEAD -- lua/dbee/schema_filter_authority.lua lua/dbee/schema_name_canonical.lua lua/dbee/lsp/epoch_authority.lua; \
	check_empty "git diff baseline locked helper names" git diff --name-only d8a4161..HEAD -- lua/dbee/schema_filter_authority.lua lua/dbee/schema_name_canonical.lua lua/dbee/lsp/epoch_authority.lua; \
	check_empty "git diff cached locked helper names" git diff --cached --name-only -- lua/dbee/schema_filter_authority.lua lua/dbee/schema_name_canonical.lua lua/dbee/lsp/epoch_authority.lua; \
	check_empty "git diff working locked helper names" git diff --name-only -- lua/dbee/schema_filter_authority.lua lua/dbee/schema_name_canonical.lua lua/dbee/lsp/epoch_authority.lua; \
	printf '%s\n' "DB18_LOCKED_HELPERS_GIT_DIFF_OK=true" >> "$(UX13_ROLLUP_LOG)"

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
	  source_tag=""; \
	  case "$$1" in \
	    source:*) source_tag="$${1#source:}"; shift ;; \
	  esac; \
	  label="$$1"; \
	  shift; \
	  tmp="$$(mktemp)"; \
	  if [ -n "$$source_tag" ]; then \
	    printf '===CMD-SOURCE: %s===\n' "$$source_tag" >> "$(UX13_ROLLUP_LOG)"; \
	  fi; \
	  set +e; \
	  "$$@" >"$$tmp" 2>&1; \
	  status="$$?"; \
	  set -e; \
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
	  check_lsp12_hover_resolve.lua \
	  check_lsp12_2_symbols.lua \
	  check_lsp12_3_code_actions.lua \
	  check_lsp_diagnostics_correctness.lua \
	  check_lsp_diagnostics_debounce.lua \
	  check_lsp_schema_filter_lazy.lua \
	  check_drawer_filter.lua \
	  check_structure_lazy.lua \
	  check_folder_scoped_notes.lua \
	  check_notes_picker.lua \
	  check_connection_lifecycle.lua \
	  check_connection_coordination.lua \
	  check_wizard_input_visible.lua \
	  check_connection_wizard.lua \
	  check_filesource_persistence.lua \
	  check_folder_persistence.lua \
	  check_drawer_folders.lua \
	  check_rich_metadata.lua; \
	do \
	  run_logged "$$script" env XDG_STATE_HOME="$(LSP01_PERF_STATE_HOME)" \
	    $(PERF_NVIM_HEADLESS) -c "luafile $(CURDIR)/ci/headless/$$script"; \
	done; \
	run_logged "source:go-test" "rich-pg-go-markers" env GOCACHE="$(LSP01_PERF_ARTIFACT_DIR)/go-cache" \
	  go -C dbee test ./core ./handler ./adapters -run 'TestRichMetadataTypesBackwardCompat|TestRichColumnMarshalPreservesFields|TestPostgresRichMetadataSupport|TestPostgresPG12FloorBehavior|TestPostgresColumnsRichCompositeMetadata|TestPostgresIndexesRichMetadata|TestPostgresSequencesRichMetadata|TestPostgresRichMetadataNoNamedBindsInTests' -v; \
	run_logged "source:go-bench" "rich-pg-go-bench" env GOCACHE="$(LSP01_PERF_ARTIFACT_DIR)/go-cache" \
	  go -C dbee test ./adapters -run 'TestPostgresRichMetadataBenchAggregator' -bench 'BenchmarkPostgresRichMetadataGoParse' -benchtime=20x -benchmem -v; \
	run_logged "source:lua-headless" "check_rich_metadata_postgres.lua" env UX13_ROLLUP_LOG="$(UX13_ROLLUP_LOG)" \
	  $(MAKE) --no-print-directory perf-headless ARGS='-l ci/headless/check_rich_metadata_postgres.lua'; \
	run_logged "db18-locked-helpers-guard" \
	  $(MAKE) --no-print-directory db18-locked-helpers-guard UX13_ROLLUP_LOG="$(UX13_ROLLUP_LOG)"; \
	run_logged "source:db18-go-test" "db18-adapter-current-db-go" env GOCACHE=/tmp/codex-go-cache \
	  go -C dbee test ./adapters -run 'Test(Postgres|SQLServer|Redshift)ListDatabases' -v; \
	db18_go_log="$$(mktemp)"; \
	awk 'found{print} /^===CMD-SOURCE: db18-go-test===$$/{found=1; next}' "$(UX13_ROLLUP_LOG)" > "$$db18_go_log"; \
	if grep -F "no tests to run" "$$db18_go_log" >/dev/null; then \
	  cat "$$db18_go_log" >&2; \
	  rm -f "$$db18_go_log"; \
	  printf '%s\n' "db18 adapter current DB focused tests did not run" >&2; \
	  exit 1; \
	fi; \
	for test_name in \
	  TestPostgresListDatabasesNoAlternatives \
	  TestSQLServerListDatabasesNoAlternatives \
	  TestRedshiftListDatabasesNoAlternatives \
	  TestPostgresListDatabasesWithAlternatives \
	  TestSQLServerListDatabasesWithAlternatives \
	  TestRedshiftListDatabasesWithAlternatives; \
	do \
	  grep -F "=== RUN   $$test_name" "$$db18_go_log" >/dev/null || { cat "$$db18_go_log" >&2; rm -f "$$db18_go_log"; printf '%s\n' "missing DB18 focused RUN line $$test_name" >&2; exit 1; }; \
	  grep -F -- "--- PASS: $$test_name" "$$db18_go_log" >/dev/null || { cat "$$db18_go_log" >&2; rm -f "$$db18_go_log"; printf '%s\n' "missing DB18 focused PASS line $$test_name" >&2; exit 1; }; \
	done; \
	rm -f "$$db18_go_log"; \
	run_logged "source:lua-headless" "check_db_nesting.lua" env UX13_ROLLUP_LOG="$(UX13_ROLLUP_LOG)" \
	  $(MAKE) --no-print-directory perf-headless ARGS='-l ci/headless/check_db_nesting.lua'; \
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
	run_logged "source:lua-headless" "check_lsp21_completion_annotations.lua" env XDG_STATE_HOME="$(LSP01_PERF_STATE_HOME)" \
	  $(PERF_NVIM_HEADLESS) -l ci/headless/check_lsp21_completion_annotations.lua; \
	run_logged "source:lua-headless" "check_lsp21_reverse_refs.lua" env XDG_STATE_HOME="$(LSP01_PERF_STATE_HOME)" \
	  $(PERF_NVIM_HEADLESS) -l ci/headless/check_lsp21_reverse_refs.lua; \
	run_logged "source:lua-headless" "check_lsp21_perf.lua" env XDG_STATE_HOME="$(LSP01_PERF_STATE_HOME)" \
	  $(PERF_NVIM_HEADLESS) -l ci/headless/check_lsp21_perf.lua; \
	run_logged "source:go-test" "lsp21-go-core" env GOCACHE="$(LSP01_PERF_ARTIFACT_DIR)/go-cache" \
	  go -C dbee test ./core; \
	run_logged "lsp21-locked-helpers-guard" \
	  $(MAKE) --no-print-directory lsp21-locked-helpers-guard; \
	run_logged "lsp21-static-markers" sh -c 'printf "%s\n" "LSP21_RICH16_UX13_PRESERVED_OK=true" "LSP21_STRICT_MARKER_COUNT=67"'; \
	run_logged "lsp21-rollup" env LSP21_ROLLUP_LOG="$(UX13_ROLLUP_LOG)" \
	  $(PERF_NVIM_HEADLESS) -l ci/headless/check_lsp21_rollup.lua; \
	run_logged "lsp12-rollup" env LSP12_ROLLUP_LOG="$(UX13_ROLLUP_LOG)" \
	  $(PERF_NVIM_HEADLESS) -c "luafile $(LSP12_ROLLUP_SCRIPT)"; \
	run_logged "arch14-rollup" env ARCH14_ROLLUP_LOG="$(ARCH14_ROLLUP_LOG)" \
	  $(PERF_NVIM_HEADLESS) -c "luafile $(ARCH14_ROLLUP_SCRIPT)"; \
	run_logged "source:ux13-rollup" "ux13-rollup" env UX13_ROLLUP_LOG="$(UX13_ROLLUP_LOG)" \
	  $(PERF_NVIM_HEADLESS) -c "luafile $(UX13_ROLLUP_SCRIPT)"

perf-all: perf perf-lsp

ux13-rollup: perf-lsp

wallet-test: perf-bootstrap
	@set -eu; \
	mkdir -p "$(WALLET_ARTIFACT_DIR)"; \
	: > "$(WALLET_GO_LOG)"; \
	: > "$(WALLET_LUA_LOG)"; \
	run_logged() { \
	  label="$$1"; \
	  log="$$2"; \
	  shift 2; \
	  tmp="$$(mktemp)"; \
	  set +e; \
	  "$$@" >"$$tmp" 2>&1; \
	  status="$$?"; \
	  set -e; \
	  cat "$$tmp"; \
	  cat "$$tmp" >> "$$log"; \
	  rm -f "$$tmp"; \
	  if [ "$$status" -ne 0 ]; then \
	    printf '%s\n' "$$label failed with status $$status" >&2; \
	    printf '%s\n' "log path: $$log" >&2; \
	    exit "$$status"; \
	  fi; \
	}; \
	printf '%s\n' "Running: WALLET_PLATFORM=$(WALLET_PLATFORM) WALLET_ARTIFACT_DIR=$(WALLET_ARTIFACT_DIR)"; \
	run_logged "wallet-go" "$(WALLET_GO_LOG)" env GOCACHE="$(WALLET_ARTIFACT_DIR)/go-cache" \
	  go -C dbee test -count=1 -v ./adapters -run 'TestOracleWallet'; \
	run_logged "wallet-rollup" "$(WALLET_LUA_LOG)" env WALLET_GO_LOG="$(WALLET_GO_LOG)" \
	  $(PERF_NVIM_HEADLESS) -c "luafile $(WALLET_ROLLUP_SCRIPT)"
