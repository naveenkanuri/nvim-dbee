# Phase 22 - Oracle Correctness

**Milestone:** v1.4
**Status:** Planned, revised r3 for execute
**Date:** 2026-05-07
**Requirement:** Oracle bind-name correctness / ORA-01745 prevention
**Reference:** `.planning/phases/22-oracle-correctness/22-CONTEXT.md`

## Goal

Close the Oracle reserved/prohibited bind-name bug class by enforcing the `p_` convention for internal Oracle literal binds, validating dynamic user/cursor bind names before they reach the Oracle parser or produce session side effects, and adding a cwd-independent Go AST sentinel plus Makefile-routed rollup gate.

## Scope

Phase 22 contains one executable sub-plan:

| Wave | Plan | Objective | Depends On |
| --- | --- | --- | --- |
| 1 | `22-01-PLAN.md` | Oracle bind-name audit, DBMS_OUTPUT rename, full unsafe-set validation, AST sentinel, Makefile rollup. | None |

Dropped scope:
- Former `(b)` PL/SQL `SELECT INTO :bind` parser fix: already shipped in `d8a4161`.
- Former `(c)` Phase 18 perf cleanup: concrete items are v1.5 backlog and not coupled to Oracle bind correctness.
- Rich-meta X.3 stub adapters: deferred to a separate phase.
- Live Oracle smoke and Lua-side pre-validation: deferred outside Phase 22.

## Inputs Read

- `.planning/phases/22-oracle-correctness/22-CONTEXT.md`
- `dbee/adapters/oracle_driver.go`
- `dbee/adapters/oracle_refcursor.go`
- `dbee/adapters/oracle_plsql.go`
- `dbee/adapters/oracle_driver_dbms_output_test.go`
- `dbee/adapters/oracle_driver_context_test.go`
- `dbee/adapters/oracle_refcursor_test.go`
- `dbee/endpoints.go`
- `lua/dbee/variables.lua`
- `Makefile`
- `.github/workflows/test.yml`
- `ci/headless/check_lsp12_2_symbols.lua`
- `lua/dbee/lsp/context.lua`
- `/Users/naveenkanuri/.claude/projects/-Users-naveenkanuri-Documents-nvim-dbee/memory/project_v14_phase18_shipped.md`

## Locked Contracts

- Do not edit:
  - `lua/dbee/schema_filter_authority.lua`
  - `lua/dbee/schema_name_canonical.lua`
  - `lua/dbee/lsp/epoch_authority.lua`
- No live DB smoke in Phase 22.
- No new external Go dependencies.
- Do not auto-prefix user SQL bind names.
- Safe user bind pass-through remains backward-compatible for names such as `id`, `name`, and `p_schema`.
- Unsafe/reserved user/cursor bind names are rejected before driver execution and before `DBMS_OUTPUT.ENABLE`.
- Internal Oracle literal binds must be `p_`-prefixed.
- `validateOracleBindName` remains Oracle-adapter local, not a fourth locked helper.
- `errors.Join` is required for aggregate validation errors; `dbee/go.mod` declares Go `1.23`, which satisfies the Go 1.20+ requirement.

## Decision Coverage

Joint marker contract: `ORA22-09`, `ORA22-13`, and `ORA22-19` jointly define the Makefile-routed marker boundary. Treat them as one execution contract: test ownership, Makefile routing, and rollup-log capture must change together.

| Decision | Covered By | Success Criterion |
| --- | --- | --- |
| ORA22-01 | `22-01` | Only `22-01-PLAN.md` is produced; no `22-02-PLAN.md`. |
| ORA22-02 | `22-01` | Source scan rejects unprefixed literal `sql.Named("...")` in Oracle production files. |
| ORA22-03 | `22-01` | DBMS_OUTPUT SQL and args use `p_line` / `p_status`; old names absent. |
| ORA22-04 | `22-01` | No SQL rewrite/auto-prefix logic is introduced. |
| ORA22-05 | `22-01` | `oracleNamedArgs` rejects unsafe names and preserves safe names. |
| ORA22-06 | `22-01` | REF CURSOR `param` names are validated before `sql.Named(param, ...)`. |
| ORA22-07 | `22-01` | Existing bind coercion tests still prove safe names pass through unchanged. |
| ORA22-08 | `22-01` | Runtime validator and AST audit use the same docs-backed/project-risk unsafe set. |
| ORA22-09 | `22-01` | Audit marker and rollup marker have separate owners and cannot both emit from audit-only test runs. |
| ORA22-10 | `22-01` | Full Phase 22 uppercase unsafe set is embedded; required non-four reserved examples fail validation; substring-safe names pass. |
| ORA22-11 | `22-01` | Validation and `oracleNamedArgs` error propagation run before `DBMS_OUTPUT.ENABLE`; all three call sites migrate. |
| ORA22-12 | `22-01` | Go AST sentinel scans all production `oracle*.go` files cwd-independently and property-checks literal/dynamic bind sites. |
| ORA22-13 | `22-01` | `make oracle-bind-audit` exists, prints markers to stdout, is captured by `perf-lsp` `run_logged`, and is invoked by `perf-lsp`. |
| ORA22-14 | `22-01` | REF CURSOR grammar matches validator grammar; touched regexes are package-level compiled or manual scanners. |
| ORA22-15 | `22-01` | Non-elevation rationale and backend error-surface contract are documented and tested. |
| ORA22-16 | `22-01` | Existing `$` / `#` REF CURSOR marker parse bug is fixed with validator-equivalent grammar and fuzz cases. |
| ORA22-17 | `22-01` | PL/SQL load-bearing validation occurs inside locked executors before `DBMS_OUTPUT.ENABLE`; no QueryWithBinds double-unlock alternative remains. |
| ORA22-18 | `22-01` | `TestPhase22Rollup` uses helper extraction on one `*testing.T`, not sibling test ordering or shelling out. |
| ORA22-19 | `22-01` | `oracle-bind-audit` is `.PHONY`; `perf-lsp` owns rollup logging and DB18-style slice-grep verification. |
| ORA22-20 | `22-01` | AST audit fails closed on unsupported `sql.Named` first-argument shapes and validates dynamic identifiers by whitelist. |

## Strict Markers

Phase 22 has one strict sub-marker and one rollup gate:

1. `ORACLE22_BIND_AUDIT_OK=true`
2. `PHASE22_ALL_PASS=true`

Marker ownership:
- `ORACLE22_BIND_AUDIT_OK=true` is emitted only by `TestOracleBindAudit` via `t.Log`.
- `PHASE22_ALL_PASS=true` is emitted only by `TestPhase22Rollup` via `t.Log` when `ORACLE22_ROLLUP=1` is set by `make oracle-bind-audit`.
- A bare `go test -run TestOracleBindAudit` must not emit `PHASE22_ALL_PASS=true`.

## Verification Summary

Execution phase should run:

```bash
make oracle-bind-audit
env GOCACHE=/tmp/codex-go-cache go -C dbee test ./adapters
```

Expected marker output from `make oracle-bind-audit`:

```text
ORACLE22_BIND_AUDIT_OK=true
PHASE22_ALL_PASS=true
```

## Threat Model

Primary risk is introducing a breaking rewrite of user SQL binds. Phase 22 avoids that by rejecting unsafe full-name bind names instead of changing SQL or bind keys. Secondary risk is validation after a session side effect; the revised plan requires validation before `DBMS_OUTPUT.ENABLE` in both PL/SQL paths. Lua-side pre-validation is explicitly deferred; backend errors must include the offending bind name and `p_` rename hint. The change does not touch LSP, drawer topology, schema filters, rich metadata SQL beyond bind arguments, or locked helper modules.

## Concerns For Implementation Gate

- `oracleNamedArgs` must become error-bearing at all three production call sites: `oracle_driver.go:252`, `oracle_driver.go:322`, and `oracle_refcursor.go:96`.
- DBMS_OUTPUT rename must change both `BEGIN DBMS_OUTPUT.GET_LINE(:..., :...); END;` and the matching `sql.Named(...)` names.
- The AST sentinel must scan production Oracle files only and assert the expected file list is non-empty.
- Existing REF CURSOR marker parsing must accept Oracle-legal `$` and `#` names such as `:cur$1 /*CURSOR*/`.
- Load-bearing validation belongs inside `executePLSQLLocked` / `executePLSQLWithCursor` before `DBMS_OUTPUT.ENABLE`; do not move it to `QueryWithBinds`.
- `oracle-bind-audit` must not append directly to `UX13_ROLLUP_LOG`; `perf-lsp` `run_logged` owns rollup log writes.
- Do not overreach by rejecting safe names containing unsafe substrings, such as `my_table` or `date_created`.
- Do not emit `PHASE22_ALL_PASS=true` from audit-only tests.
