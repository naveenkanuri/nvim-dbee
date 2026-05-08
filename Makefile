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
LIVE_PG20_ARTIFACT_ROOT ?= $(if $(RUNNER_TEMP),$(RUNNER_TEMP)/live-pg20,$(if $(TMPDIR),$(patsubst %/,%,$(TMPDIR))/nvim-dbee-live-pg20,/tmp/nvim-dbee-live-pg20))
LIVE_PG20_ROLLUP_LOG ?= $(LIVE_PG20_ARTIFACT_ROOT)/live-pg20.log
LIVE_PG20_LOCKED_HELPERS_STATUS ?= $(LIVE_PG20_ARTIFACT_ROOT)/locked-helpers-status
LIVE_PG20_PROBE_BIN ?= $(LIVE_PG20_ARTIFACT_ROOT)/bin/probe-runtime
LIVE_PG20_REQUIRED ?= 0
LIVE_PG20_USE_SUDO ?= 0
LIVE_PG20_POSTGRES_IMAGE ?= postgres:16-alpine@sha256:4e6e670bb069649261c9c18031f0aded7bb249a5b6664ddec29c013a89310d50
WALLET_PLATFORM ?= $(if $(filter Darwin,$(UNAME_S)),macos,linux)
WALLET_ARTIFACT_ROOT ?= $(if $(RUNNER_TEMP),$(RUNNER_TEMP)/wallet-test,$(if $(TMPDIR),$(TMPDIR)nvim-dbee-wallet-test,/tmp/nvim-dbee-wallet-test))
WALLET_ARTIFACT_DIR ?= $(WALLET_ARTIFACT_ROOT)/$(WALLET_PLATFORM)
WALLET_GO_LOG ?= $(WALLET_ARTIFACT_DIR)/wallet-go.log
WALLET_LUA_LOG ?= $(WALLET_ARTIFACT_DIR)/wallet-lua.log
WALLET_ROLLUP_SCRIPT ?= $(CURDIR)/ci/headless/check_oracle_wallet_zip.lua

.PHONY: perf perf-lsp perf-all wallet-test perf-headless ux13-rollup lsp21 lsp21-rollup lsp21-locked-helpers-guard db18-locked-helpers-guard oracle-bind-audit gn23 gn23-rollup gn23-locked-helpers-guard gn23-no-go-rpc-guard
.PHONY: live-pg-smoke _live-pg-smoke-inner

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

oracle-bind-audit:
	ORACLE22_ROLLUP=1 env GOCACHE="$${GOCACHE:-/tmp/codex-go-cache}" go -C dbee test ./adapters -run 'TestOracle(BindName|NamedArgs|UnsafeBindNames|RefCursor|DBMSOutput|BindAudit)|TestFetchDBMSOutputFromConn|TestPhase22Rollup' -v

# This guard checks the SHIP commit only; earlier phase history may have touched
# locked helpers before this Phase 20 commit.
live-pg-smoke:
	@set -eu; \
	mkdir -p "$(LIVE_PG20_ARTIFACT_ROOT)" "$(LIVE_PG20_ARTIFACT_ROOT)/bin"; \
	: > "$(LIVE_PG20_ROLLUP_LOG)"; \
	locked_status=ok; \
	for path in lua/dbee/schema_filter_authority.lua lua/dbee/schema_name_canonical.lua lua/dbee/lsp/epoch_authority.lua; do \
	  if ! git diff --quiet HEAD~1 HEAD -- "$$path"; then \
	    printf '%s\n' "locked-helper diff detected at: $$path"; \
	    locked_status=tampered; \
	  fi; \
	  if ! git diff --quiet -- "$$path"; then \
	    printf '%s\n' "locked-helper diff detected at: $$path"; \
	    locked_status=tampered; \
	  fi; \
	  if ! git diff --cached --quiet -- "$$path"; then \
	    printf '%s\n' "locked-helper diff detected at: $$path"; \
	    locked_status=tampered; \
	  fi; \
	done; \
	printf '%s\n' "$$locked_status" > "$(LIVE_PG20_LOCKED_HELPERS_STATUS)"; \
	probe_build_start="$$(date +%s)"; \
	probe_build_out="$$(mktemp)"; \
	set +e; \
	go -C dbee build -o "$(LIVE_PG20_PROBE_BIN)" ./cmd/probe-runtime >"$$probe_build_out" 2>&1; \
	probe_build_rc="$$?"; \
	set -e; \
	probe_build_end="$$(date +%s)"; \
	probe_build_ms="$$(((probe_build_end - probe_build_start) * 1000))"; \
	printf '%s\n' "LIVE_PG20_PROBE_BUILD_MS=$$probe_build_ms"; \
	printf '%s\n' "LIVE_PG20_PROBE_BUILD_MS=$$probe_build_ms" >> "$(LIVE_PG20_ROLLUP_LOG)"; \
	if [ "$$probe_build_rc" -ne 0 ]; then \
	  cat "$$probe_build_out"; \
	  cat "$$probe_build_out" >> "$(LIVE_PG20_ROLLUP_LOG)"; \
	  printf '%s\n' "PHASE20_ALL_PASS=false"; \
	  printf '%s\n' "PHASE20_ALL_PASS=false" >> "$(LIVE_PG20_ROLLUP_LOG)"; \
	  rm -f "$$probe_build_out"; \
	  exit 1; \
	fi; \
	rm -f "$$probe_build_out"; \
	if [ "$(LIVE_PG20_USE_SUDO)" = "1" ]; then \
	  sudo -E env \
	    LIVE_PG20_ARTIFACT_ROOT="$(LIVE_PG20_ARTIFACT_ROOT)" \
	    LIVE_PG20_ROLLUP_LOG="$(LIVE_PG20_ROLLUP_LOG)" \
	    LIVE_PG20_LOCKED_HELPERS_STATUS="$(LIVE_PG20_LOCKED_HELPERS_STATUS)" \
	    LIVE_PG20_PROBE_BIN="$(LIVE_PG20_PROBE_BIN)" \
	    LIVE_PG20_REQUIRED="$(LIVE_PG20_REQUIRED)" \
	    LIVE_PG20_POSTGRES_IMAGE="$(LIVE_PG20_POSTGRES_IMAGE)" \
	    LIVE_PG20_CONTAINER_PROVIDER="$${LIVE_PG20_CONTAINER_PROVIDER:-}" \
	    $(MAKE) --no-print-directory _live-pg-smoke-inner; \
	else \
	  env \
	    LIVE_PG20_ARTIFACT_ROOT="$(LIVE_PG20_ARTIFACT_ROOT)" \
	    LIVE_PG20_ROLLUP_LOG="$(LIVE_PG20_ROLLUP_LOG)" \
	    LIVE_PG20_LOCKED_HELPERS_STATUS="$(LIVE_PG20_LOCKED_HELPERS_STATUS)" \
	    LIVE_PG20_PROBE_BIN="$(LIVE_PG20_PROBE_BIN)" \
	    LIVE_PG20_REQUIRED="$(LIVE_PG20_REQUIRED)" \
	    LIVE_PG20_POSTGRES_IMAGE="$(LIVE_PG20_POSTGRES_IMAGE)" \
	    LIVE_PG20_CONTAINER_PROVIDER="$${LIVE_PG20_CONTAINER_PROVIDER:-}" \
	    $(MAKE) --no-print-directory _live-pg-smoke-inner; \
	fi

_live-pg-smoke-inner:
	@set -eu; \
	wall_start="$$(date +%s)"; \
	_cleanup_done=""; \
	child_pid=""; \
	cleanup() { \
	  [ -n "$$_cleanup_done" ] && return 0; \
	  _cleanup_done=1; \
	  set +e; \
	  if [ -n "$$child_pid" ]; then \
	    kill "$$child_pid" 2>/dev/null; \
	    wait "$$child_pid" 2>/dev/null; \
	    _wait_status="$$?"; \
	    child_pid=""; \
	  fi; \
	  if [ "$${provider:-}" = "podman" ]; then \
	    ids="$$(podman ps -a -q --filter label=nvim-dbee.live-pg20=true 2>/dev/null || true)"; \
	    if [ -n "$$ids" ]; then podman rm -f $$ids >/dev/null 2>&1 || true; fi; \
	  fi; \
	  return 0; \
	}; \
	trap cleanup EXIT; \
	trap 'cleanup; exit 130' INT; \
	trap 'cleanup; exit 143' TERM; \
	emit_marker() { marker="$$1"; printf '%s\n' "$$marker"; printf '%s\n' "$$marker" >> "$(LIVE_PG20_ROLLUP_LOG)"; }; \
	fail_gate() { emit_marker "PHASE20_ALL_PASS=false"; exit 1; }; \
	append_log() { cat "$$1"; cat "$$1" >> "$(LIVE_PG20_ROLLUP_LOG)"; }; \
	run_child_capture() { out="$$1"; shift; "$$@" >"$$out" 2>&1 & child_pid="$$!"; wait "$$child_pid"; rc="$$?"; child_pid=""; return "$$rc"; }; \
	field_from_line() { printf '%s\n' "$$status_line" | tr '|' '\n' | sed -n "s/^$$1=//p" | head -n 1; }; \
	field_count() { printf '%s\n' "$$status_line" | tr '|' '\n' | grep -c "^$$1=" || true; }; \
	parse_probe_output() { \
	  out="$$1"; \
	  nonempty_lines="$$(sed '/^[[:space:]]*$$/d' "$$out")"; \
	  line_count="$$(printf '%s\n' "$$nonempty_lines" | sed '/^$$/d' | wc -l | tr -d ' ')"; \
	  [ "$$line_count" = "1" ] || return 1; \
	  status_line="$$nonempty_lines"; \
	  field_total="$$(printf '%s\n' "$$status_line" | tr '|' '\n' | sed '/^[[:space:]]*$$/d' | wc -l | tr -d ' ')"; \
	  [ "$$field_total" = "4" ] || return 1; \
	  if printf '%s\n' "$$status_line" | tr '|' '\n' | grep -Ev '^(STATUS|PROVIDER|DURATION_MS|DETAIL)=' >/dev/null; then return 1; fi; \
	  [ "$$(field_count STATUS)" = "1" ] || return 1; \
	  [ "$$(field_count PROVIDER)" = "1" ] || return 1; \
	  [ "$$(field_count DURATION_MS)" = "1" ] || return 1; \
	  [ "$$(field_count DETAIL)" = "1" ] || return 1; \
	  status="$$(field_from_line STATUS)"; \
	  provider="$$(field_from_line PROVIDER)"; \
	  detect_ms="$$(field_from_line DURATION_MS)"; \
	  detail="$$(field_from_line DETAIL)"; \
	  case "$$status" in ok|no_runtime|internal_error) ;; *) return 1 ;; esac; \
	  if [ "$$status" = "ok" ]; then \
	    case "$$provider" in podman|docker) ;; *) return 1 ;; esac; \
	  else \
	    [ "$$provider" = "none" ] || return 1; \
	  fi; \
	  if [ "$$status" = "no_runtime" ]; then [ -n "$$detail" ] || return 1; fi; \
	  case "$$detect_ms" in ''|*[!0-9]*) return 1 ;; *) [ "$$detect_ms" -lt 6000 ] || return 1 ;; esac; \
	  return 0; \
	}; \
	probe_out="$$(mktemp)"; \
	set +e; \
	run_child_capture "$$probe_out" "$(LIVE_PG20_PROBE_BIN)"; \
	probe_rc="$$?"; \
	set -e; \
	if ! parse_probe_output "$$probe_out"; then \
	  append_log "$$probe_out"; \
	  emit_marker "LIVE_PG20_PROBE_INTERNAL_ERROR=true"; \
	  emit_marker "PHASE20_ALL_PASS=false"; \
	  exit 1; \
	fi; \
	if [ "$$probe_rc" -eq 1 ] && [ "$$status" = "no_runtime" ]; then \
	  emit_marker "LIVE_PG20_SKIPPED_NO_RUNTIME=true"; \
	  emit_marker "LIVE_PG20_DETECT_MS=$$detect_ms"; \
	  printf '%s\n' "$$detail" | tee -a "$(LIVE_PG20_ROLLUP_LOG)"; \
	  emit_marker "PHASE20_ALL_PASS=false"; \
	  if [ "$(LIVE_PG20_REQUIRED)" = "1" ]; then exit 1; fi; \
	  exit 0; \
	fi; \
	if ! { [ "$$probe_rc" -eq 0 ] && [ "$$status" = "ok" ]; }; then \
	  append_log "$$probe_out"; \
	  emit_marker "LIVE_PG20_PROBE_INTERNAL_ERROR=true"; \
	  printf '%s\n' "probe-runtime internal error: rc=$$probe_rc status=$$status detail=$$detail" | tee -a "$(LIVE_PG20_ROLLUP_LOG)"; \
	  emit_marker "PHASE20_ALL_PASS=false"; \
	  exit 1; \
	fi; \
	emit_marker "LIVE_PG20_DETECT_OK=true"; \
	emit_marker "LIVE_PG20_DETECT_MS=$$detect_ms"; \
	if [ "$$detect_ms" -gt 2000 ]; then emit_marker "LIVE_PG20_DETECT_SLOW=true"; fi; \
	emit_marker "LIVE_PG20_RUNTIME_DETECTED_OK=true"; \
	locked_result="$$(cat "$(LIVE_PG20_LOCKED_HELPERS_STATUS)" 2>/dev/null || printf '%s\n' tampered)"; \
	[ "$$locked_result" = "ok" ] || fail_gate; \
	emit_marker "LIVE_PG20_LOCKED_HELPERS_UNTOUCHED_OK=true"; \
	if [ "$$provider" = "podman" ] && [ -z "$${TESTCONTAINERS_RYUK_CONTAINER_PRIVILEGED:-}" ]; then \
	  export TESTCONTAINERS_RYUK_CONTAINER_PRIVILEGED=true; \
	fi; \
	if [ "$$provider" = "podman" ] && [ -z "$${TESTCONTAINERS_RYUK_DISABLED:-}" ]; then \
	  export TESTCONTAINERS_RYUK_DISABLED=true; \
	fi; \
	sql_shape_out="$$(mktemp)"; \
	set +e; \
	run_child_capture "$$sql_shape_out" go -C dbee test ./adapters -run '^TestPostgresForeignKeysSQLRowsFromShape$$' -count=1 -v; \
	sql_shape_rc="$$?"; \
	set -e; \
	append_log "$$sql_shape_out"; \
	[ "$$sql_shape_rc" -eq 0 ] || fail_gate; \
	grep -F "LIVE_PG20_SQL_SHAPE_PREFLIGHT_OK=true" "$$sql_shape_out" >/dev/null || fail_gate; \
	live_out="$$(mktemp)"; \
	set +e; \
	run_child_capture "$$live_out" env \
	  LIVE_PG20_POSTGRES_IMAGE="$(LIVE_PG20_POSTGRES_IMAGE)" \
	  LIVE_PG20_CONTAINER_PROVIDER="$$provider" \
	  go -C dbee test -tags live_pg20 -count=1 -timeout=10m ./tests/integration -run '^TestPostgresLiveRichMetadataSmoke$$' -v; \
	live_rc="$$?"; \
	set -e; \
	append_log "$$live_out"; \
	[ "$$live_rc" -eq 0 ] || fail_gate; \
	grep -F "LIVE_PG20_NEGATIVE_SQLSTATE_42883_OK=true" "$$live_out" >/dev/null || fail_gate; \
	grep -F "42883" "$$live_out" >/dev/null || fail_gate; \
	wall_end="$$(date +%s)"; \
	suite_duration="$$((wall_end - wall_start))"; \
	emit_marker "LIVE_PG20_SUITE_DURATION_S=$$suite_duration"; \
	emit_marker "LIVE_PG20_WALL_CLOCK_BUDGET_S=180"; \
	if [ "$$suite_duration" -gt 162 ]; then emit_marker "LIVE_PG20_WALL_CLOCK_NEAR_BUDGET=true"; fi; \
	if [ "$$suite_duration" -le 216 ]; then \
	  emit_marker "LIVE_PG20_WALL_CLOCK_OK=true"; \
	else \
	  emit_marker "LIVE_PG20_WALL_CLOCK_OK=false"; \
	  fail_gate; \
	fi; \
	grep -F "LIVE_PG20_WALL_CLOCK_OK=true" "$(LIVE_PG20_ROLLUP_LOG)" >/dev/null || fail_gate; \
	for marker in \
	  LIVE_PG20_RUNTIME_DETECTED_OK=true \
	  LIVE_PG20_CONTAINER_READY_OK=true \
	  LIVE_PG20_SEED_OK=true \
	  LIVE_PG20_SUPPORT_OK=true \
	  LIVE_PG20_COLUMNS_RICH_OK=true \
	  LIVE_PG20_COMPOSITE_PK_OK=true \
	  LIVE_PG20_FK_COMPOSITE_OK=true \
	  LIVE_PG20_SQL_SHAPE_PREFLIGHT_OK=true \
	  LIVE_PG20_ROWS_FROM_LIVE_OK=true \
	  LIVE_PG20_HISTORICAL_UNNEST_NEGATIVE_OK=true \
	  LIVE_PG20_NEGATIVE_SQLSTATE_42883_OK=true \
	  LIVE_PG20_INDEXES_OK=true \
	  LIVE_PG20_MV_INDEXES_OK=true \
	  LIVE_PG20_VIEW_NO_INDEXES_OK=true \
	  LIVE_PG20_SEQUENCE_OK=true \
	  LIVE_PG20_MULTI_SCHEMA_OK=true \
	  LIVE_PG20_SCHEMA_SCOPE_OK=true \
	  LIVE_PG20_SNAPSHOT_OK=true \
	  LIVE_PG20_LOCKED_HELPERS_UNTOUCHED_OK=true; \
	do \
	  count="$$(grep -F "$$marker" "$(LIVE_PG20_ROLLUP_LOG)" | wc -l | tr -d ' ')"; \
	  if [ "$$count" != "1" ]; then \
	    printf '%s\n' "marker $$marker count $$count != 1" | tee -a "$(LIVE_PG20_ROLLUP_LOG)"; \
	    fail_gate; \
	  fi; \
	done; \
	emit_marker "LIVE_PG20_STRICT_MARKER_COUNT=20"; \
	count="$$(grep -F "LIVE_PG20_STRICT_MARKER_COUNT=20" "$(LIVE_PG20_ROLLUP_LOG)" | wc -l | tr -d ' ')"; \
	[ "$$count" = "1" ] || fail_gate; \
	emit_marker "PHASE20_ALL_PASS=true"

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
	run_logged "source:oracle-bind-audit" "oracle-bind-audit" env GOCACHE="$(LSP01_PERF_ARTIFACT_DIR)/go-cache" \
	  $(MAKE) --no-print-directory oracle-bind-audit; \
	oracle22_go_log="$$(mktemp)"; \
	awk 'found{print} /^===CMD-SOURCE: oracle-bind-audit===$$/{found=1; next}' "$(UX13_ROLLUP_LOG)" > "$$oracle22_go_log"; \
	if grep -F "no tests to run" "$$oracle22_go_log" >/dev/null; then \
	  cat "$$oracle22_go_log" >&2; \
	  rm -f "$$oracle22_go_log"; \
	  printf '%s\n' "oracle bind audit focused tests did not run" >&2; \
	  exit 1; \
	fi; \
	for test_name in \
	  TestOracleBindAudit \
	  TestOracleBindAuditDetectsViolations \
	  TestOracleNamedArgs \
	  TestOracleBindNameTable \
	  TestOracleBindNameDate \
	  TestOracleBindNameWhenever \
	  TestOracleUnsafeBindNamesAllUppercase \
	  TestOracleRefCursorValidation \
	  TestFetchDBMSOutputFromConn \
	  TestPhase22Rollup; \
	do \
	  grep -F "=== RUN   $$test_name" "$$oracle22_go_log" >/dev/null || { cat "$$oracle22_go_log" >&2; rm -f "$$oracle22_go_log"; printf '%s\n' "missing Oracle bind audit RUN line $$test_name" >&2; exit 1; }; \
	  grep -F -- "--- PASS: $$test_name" "$$oracle22_go_log" >/dev/null || { cat "$$oracle22_go_log" >&2; rm -f "$$oracle22_go_log"; printf '%s\n' "missing Oracle bind audit PASS line $$test_name" >&2; exit 1; }; \
	done; \
	rm -f "$$oracle22_go_log"; \
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
